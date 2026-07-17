// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV3Factory, IUniswapV3Pool, IWETH9} from "./interfaces/IUniswapV3.sol";
import {TickMath} from "./libraries/TickMath.sol";

interface IV3PoolOracle {
    function fee() external view returns (uint24);
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

interface ILaunchpadPools {
    function poolOf(address token) external view returns (address);
}

/// @notice Protocol-fee sink that converts everything it receives into the
/// burn token and destroys it. Intended as one of the FeeRouter recipients and
/// as the WETH launch-fee recipient:
///   - WETH pair-fee shares arrive as WETH ERC20 transfers
///   - launch fees arrive wrapped as WETH ERC20 transfers
///   - launched-token fee shares arrive as plain ERC20 transfers
/// `sweep`/`sweepToken` (token -> WETH) and `burn` (wrap any accidentally sent
/// native asset, then WETH -> burn token -> dead address) process the inventory.
///
/// Design constraints inherited from the fee path:
///   - `receive()` accepts accidental or legacy native transfers so they can
///     be wrapped and included in the next burn.
///   - Permissionless sweeps resolve the pool from the launchpad factory's
///     `poolOf` mapping — callers can never steer a swap into a pool of their
///     choosing (a second factory-created pool for the same pair at another
///     fee tier, initialized at a hostile price, would otherwise let them
///     drain the inventory). The owner has `sweepTokenVia` as an explicit
///     escape hatch for tokens without an official pool.
///   - Untrusted swaps are priced against a COMMIT-DELAY-EXECUTE forward
///     TWAP, not the pool oracle ring: V3 only writes ring observations when
///     a swap crosses a tick and pools default to a single slot, so
///     ring-based TWAPs are unreliable here. Instead, anyone may
///     `recordAnchor(pool)`, storing the pool's live `tickCumulative`
///     (observe([0]), which never depends on ring capacity); the anchor
///     becomes usable after `anchorDelay` and expires at `anchorValidity`.
///     Execution prices against the TRUE average tick over the elapsed
///     period — (cumulativeNow - cumulativeRecorded) / elapsed. Because the
///     cumulative is a time integral, an atomic manipulate-record-unwind (or
///     manipulate-execute-unwind) contributes ~zero weight to it: biasing the
///     average requires HOLDING a hostile price for a meaningful fraction of
///     the window, exposed to arbitrage the whole time. There is deliberately
///     NO spot path for untrusted callers; owner-initiated swaps price off
///     spot directly (the owner chooses its own timing).
///   - The anchor tick is shifted at most `maxTickDrift` in the swap
///     direction, so a thin or manipulated pool produces a PARTIAL fill
///     instead of a revert or a bad execution; the remainder waits.
///   - `sweep` isolates each token in a self-call so one bad entry (fee-on-
///     transfer donation, missing pool, drained liquidity) cannot brick the
///     batch.
///   - The burn token is a vanilla OZ ERC20 with no `burn()`, and OZ rejects
///     transfers to address(0), so burning sends to the canonical dead
///     address, which the CTO snapshot logic treats as nonvoting supply.
///   - `burn` is owner-gated so execution timing stays with the operator, but
///     if the owner goes quiet for `PUBLIC_BURN_DELAY` anyone may trigger it,
///     and with ownership renounced it is fully permissionless. The cooldown
///     only re-arms when the WETH balance was consumed in full — a partial
///     fill leaves the public window open, so a hostile dust-burn cannot
///     lock the fallback while inventory remains.
contract NoxaBuyBurner is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error InvalidToken();
    error InvalidPool();
    error NoOfficialPool();
    error BurnTargetNotSet();
    error NothingToSweep();
    error AmountOverflow();
    error InvalidGuardConfig();
    error AnchorNotReady();
    error AnchorPending();
    error UnexpectedCallback();
    error NotSelf();
    error BurnLocked();

    event BurnTargetUpdated(address token, address pool);
    event SwapGuardUpdated(uint32 anchorDelay, uint32 anchorValidity, uint24 maxTickDrift);
    event AnchorRecorded(address indexed pool, int56 tickCumulative, uint256 usableAt, uint256 expiresAt);
    event Swept(address indexed token, address indexed pool, uint256 amountIn, uint256 wethOut);
    event SweepFailed(address indexed token, bytes reason);
    event Burned(uint256 wethIn, uint256 swapOut, uint256 amountBurned);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    struct PriceAnchor {
        int56 tickCumulative;
        uint40 recordedAt;
    }

    /// @dev OZ ERC20 reverts on transfer to address(0); dead is the burn convention.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    /// @notice How long after the last completed burn anyone (not just the
    /// owner) may trigger the next one.
    uint256 public constant PUBLIC_BURN_DELAY = 2 days;

    IUniswapV3Factory public immutable v3Factory;
    IWETH9 public immutable weth;
    /// @notice Launchpad factory whose `poolOf` mapping is the only pool
    /// source for permissionless sweeps.
    ILaunchpadPools public immutable launchFactory;

    /// @notice Token bought and burned by `burn`. Unset at deployment (the
    /// live token pre-exists this contract); owner-settable via
    /// `setBurnTarget`, with its pool, atomically. Until it is set, fees
    /// simply accumulate here and `burn` reverts.
    address public burnToken;
    /// @notice Canonical burnToken/WETH pool used by `burn`. Owner-settable so
    /// the burn route can follow liquidity migrations.
    address public burnPool;
    /// @notice Timestamp of the last complete burn; anchors the public-burn
    /// fallback. Not re-armed by partial fills.
    uint256 public lastBurnAt;

    /// @notice Commit-delay-execute cumulative snapshots, per pool. See notice.
    mapping(address pool => PriceAnchor) public priceAnchor;
    /// @notice Minimum anchor age before an untrusted caller may swap against
    /// it — the averaging window floor. Manipulating the resulting mean by
    /// X ticks requires holding a price X ticks out (or proportionally
    /// further, for less time) across this window, against arbitrage.
    uint32 public anchorDelay = 300;
    /// @notice Anchor lifetime; after this it is stale and re-recordable.
    uint32 public anchorValidity = 3600;
    /// @notice Max ticks the execution price may drift past the anchor
    /// (1 tick ~= 1 bp). Swaps stop at this bound and partially fill.
    uint24 public maxTickDrift = 300;

    /// @dev Pool allowed to invoke the swap callback for the current swap.
    address private expectedPool;

    constructor(address v3Factory_, address weth_, address launchFactory_, address owner_) Ownable(owner_) {
        if (v3Factory_ == address(0) || weth_ == address(0) || launchFactory_ == address(0)) revert ZeroAddress();
        v3Factory = IUniswapV3Factory(v3Factory_);
        weth = IWETH9(weth_);
        launchFactory = ILaunchpadPools(launchFactory_);
        lastBurnAt = block.timestamp;
    }

    /// @dev Accept accidental or legacy native transfers for the next burn.
    receive() external payable {}

    // ---------------------------------------------------------------- admin

    /// @notice Point burning at a (possibly new) target token and its pool,
    /// atomically so the pair can never disagree. Pass the current token to
    /// only migrate pools. Any balance of a previous target left behind
    /// becomes sweepable like an ordinary token.
    function setBurnTarget(address token, address pool) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (token == address(weth)) revert InvalidToken();
        _requireCanonicalPool(pool, address(weth), token);
        burnToken = token;
        burnPool = pool;
        emit BurnTargetUpdated(token, pool);
    }

    function setSwapGuard(uint32 anchorDelay_, uint32 anchorValidity_, uint24 maxTickDrift_) external onlyOwner {
        if (
            anchorDelay_ < 60 || anchorValidity_ <= anchorDelay_ || maxTickDrift_ == 0
                || maxTickDrift_ > uint24(uint256(int256(TickMath.MAX_TICK)))
        ) revert InvalidGuardConfig();
        anchorDelay = anchorDelay_;
        anchorValidity = anchorValidity_;
        maxTickDrift = maxTickDrift_;
        emit SwapGuardUpdated(anchorDelay_, anchorValidity_, maxTickDrift_);
    }

    /// @notice Escape hatch for balances that can never be swept (no pool,
    /// permanently broken token). Owner-only by definition of "rescue".
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    // ---------------------------------------------------------------- anchors

    /// @notice Snapshot `pool`'s live tick cumulative as the starting point of
    /// a forward TWAP for untrusted swaps through it. Permissionless — the
    /// stored value is a time integral, so a caller manipulating spot in the
    /// recording transaction adds nothing to it. A live (pending or usable)
    /// anchor cannot be overwritten, so nobody can reset the maturation clock
    /// forever; once it expires anyone may record a fresh one.
    function recordAnchor(address pool) external {
        PriceAnchor memory existing = priceAnchor[pool];
        if (existing.recordedAt != 0 && block.timestamp <= uint256(existing.recordedAt) + anchorValidity) {
            revert AnchorPending();
        }
        int56 tickCumulative = _currentTickCumulative(pool);
        priceAnchor[pool] = PriceAnchor(tickCumulative, uint40(block.timestamp));
        emit AnchorRecorded(pool, tickCumulative, block.timestamp + anchorDelay, block.timestamp + anchorValidity);
    }

    // ---------------------------------------------------------------- sweeping

    /// @notice Swap this contract's entire balance of `token` into WETH
    /// through the token's OFFICIAL launchpad pool (`launchFactory.poolOf`).
    /// Callable by anyone; the pool is never caller-influenced. Untrusted
    /// callers need a matured `recordAnchor` snapshot for that pool.
    function sweepToken(address token) external nonReentrant returns (uint256 wethOut) {
        return _sweepResolved(token, msg.sender == owner());
    }

    /// @notice Owner-only sweep through an explicit canonical V3 pool, for
    /// inventory the factory mapping cannot serve (donated tokens with no
    /// official pool, or an official pool whose liquidity migrated).
    function sweepTokenVia(address token, address pool) external onlyOwner nonReentrant returns (uint256 wethOut) {
        if (token == address(weth) || token == burnToken) revert InvalidToken();
        _requireCanonicalPool(pool, token, address(weth));
        return _sweepVia(token, pool, true);
    }

    /// @notice Failure-tolerant batch sweep: each token is processed in an
    /// isolated self-call, so a token with no official pool, drained
    /// liquidity, or fee-on-transfer semantics (whose V3 swap reverts by
    /// design) is skipped with an event instead of bricking the rest.
    function sweep(address[] calldata tokens) external {
        bool trusted = msg.sender == owner();
        for (uint256 i = 0; i < tokens.length; i++) {
            try this.sweepTokenSelf(tokens[i], trusted) {}
            catch (bytes memory reason) {
                emit SweepFailed(tokens[i], reason);
            }
        }
    }

    /// @dev External trampoline so `sweep` can try/catch while preserving the
    /// original caller's trust level; callable only by self.
    function sweepTokenSelf(address token, bool trusted) external nonReentrant {
        if (msg.sender != address(this)) revert NotSelf();
        _sweepResolved(token, trusted);
    }

    function _sweepResolved(address token, bool trusted) private returns (uint256 wethOut) {
        if (token == address(weth) || token == burnToken) revert InvalidToken();
        address pool = launchFactory.poolOf(token);
        if (pool == address(0)) revert NoOfficialPool();
        return _sweepVia(token, pool, trusted);
    }

    function _sweepVia(address token, address pool, bool trusted) private returns (uint256 wethOut) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) revert NothingToSweep();
        (uint256 amountIn, uint256 amountOut) = _swapExactIn(pool, token, address(weth), balance, trusted);
        emit Swept(token, pool, amountIn, amountOut);
        return amountOut;
    }

    // ---------------------------------------------------------------- burning

    /// @notice Wrap all ETH, swap all WETH into the burn token through
    /// `burnPool`, and send every unit held to the dead address. Owner-only,
    /// except that once `PUBLIC_BURN_DELAY` has passed since the last
    /// complete burn anyone may call it; with ownership renounced the gate
    /// disappears entirely (untrusted calls still need a matured anchor for
    /// `burnPool`). The cooldown re-arms only when the whole WETH balance was
    /// consumed — a partial fill (price-limit hit on a thin pool) keeps the
    /// public window open for the remainder.
    function burn() external nonReentrant returns (uint256 amountBurned) {
        if (burnToken == address(0)) revert BurnTargetNotSet();
        address currentOwner = owner();
        bool trusted = currentOwner != address(0) && msg.sender == currentOwner;
        if (!trusted && currentOwner != address(0) && block.timestamp < lastBurnAt + PUBLIC_BURN_DELAY) {
            revert BurnLocked();
        }

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) weth.deposit{value: ethBalance}();

        uint256 wethBalance = weth.balanceOf(address(this));
        uint256 swapOut;
        uint256 wethIn;
        if (wethBalance > 0) {
            (wethIn, swapOut) = _swapExactIn(burnPool, address(weth), burnToken, wethBalance, trusted);
        }
        // Re-arm the public-burn cooldown ONLY when a non-empty WETH balance
        // was consumed in full. A zero-WETH call must stay a no-op for the
        // cooldown, otherwise a front-runner could re-lock the public fallback
        // with an empty burn the instant the window opens (wethIn==wethBalance==0).
        if (wethBalance > 0 && wethIn == wethBalance) lastBurnAt = block.timestamp;

        amountBurned = IERC20(burnToken).balanceOf(address(this));
        if (amountBurned > 0) IERC20(burnToken).safeTransfer(BURN_ADDRESS, amountBurned);
        emit Burned(wethIn, swapOut, amountBurned);
    }

    // ---------------------------------------------------------------- internals

    /// @dev Exact-input single-pool swap with an anchor-bounded price limit.
    /// Returns the amounts actually taken/received (may be a partial fill).
    function _swapExactIn(address pool, address tokenIn, address tokenOut, uint256 amountIn, bool trusted)
        private
        returns (uint256 actualIn, uint256 amountOut)
    {
        if (amountIn > uint256(type(int256).max)) revert AmountOverflow();
        bool zeroForOne = tokenIn < tokenOut;
        uint160 priceLimit = _boundedPriceLimit(pool, zeroForOne, trusted);

        expectedPool = pool;
        (int256 amount0, int256 amount1) =
            IUniswapV3Pool(pool).swap(address(this), zeroForOne, int256(amountIn), priceLimit, abi.encode(tokenIn));
        expectedPool = address(0);

        actualIn = uint256(zeroForOne ? amount0 : amount1);
        amountOut = uint256(-(zeroForOne ? amount1 : amount0));
    }

    /// @dev V3 pools verify their balance delta after this callback, so a
    /// fee-on-transfer `tokenIn` underpays the pool and the pool itself
    /// reverts the whole swap — no special handling needed here.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        if (msg.sender != expectedPool || expectedPool == address(0)) revert UnexpectedCallback();
        address tokenIn = abi.decode(data, (address));
        uint256 owed = uint256(amount0Delta > 0 ? amount0Delta : amount1Delta);
        IERC20(tokenIn).safeTransfer(msg.sender, owed);
    }

    /// @dev Price limit = anchor tick shifted `maxTickDrift` in the swap
    /// direction. Untrusted callers MUST have a matured, unexpired
    /// `recordAnchor` snapshot for the pool; the owner prices off spot (it
    /// chooses its own timing).
    function _boundedPriceLimit(address pool, bool zeroForOne, bool trusted) private view returns (uint160) {
        int24 anchorTick = _anchorTick(pool, trusted);
        int24 drift = int24(maxTickDrift);
        int24 limitTick = zeroForOne ? anchorTick - drift : anchorTick + drift;
        if (limitTick < TickMath.MIN_TICK) limitTick = TickMath.MIN_TICK;
        if (limitTick > TickMath.MAX_TICK) limitTick = TickMath.MAX_TICK;
        uint160 sqrtLimit = TickMath.getSqrtRatioAtTick(limitTick);
        // swap() requires the limit strictly inside the global bounds.
        if (sqrtLimit <= TickMath.MIN_SQRT_RATIO) sqrtLimit = TickMath.MIN_SQRT_RATIO + 1;
        if (sqrtLimit >= TickMath.MAX_SQRT_RATIO) sqrtLimit = TickMath.MAX_SQRT_RATIO - 1;
        return sqrtLimit;
    }

    function _anchorTick(address pool, bool trusted) private view returns (int24) {
        if (trusted) {
            (, int24 spotTick,,,,,) = IUniswapV3Pool(pool).slot0();
            return spotTick;
        }
        PriceAnchor memory anchor = priceAnchor[pool];
        if (anchor.recordedAt == 0) revert AnchorNotReady();
        uint256 elapsed = block.timestamp - anchor.recordedAt;
        if (elapsed < anchorDelay || elapsed > anchorValidity) revert AnchorNotReady();

        // True average tick since recording. Atomic manipulation on either
        // side of the window carries ~zero time weight in this delta.
        int56 delta = _currentTickCumulative(pool) - anchor.tickCumulative;
        int56 mean = delta / int56(uint56(elapsed));
        // Round toward negative infinity like OracleLibrary.
        if (delta < 0 && (delta % int56(uint56(elapsed)) != 0)) mean--;
        return int24(mean);
    }

    /// @dev observe([0]) serves the pool's live tick cumulative regardless of
    /// its observation ring capacity — it can never revert with OLD.
    function _currentTickCumulative(address pool) private view returns (int56) {
        uint32[] memory secondsAgos = new uint32[](1);
        (int56[] memory tickCumulatives,) = IV3PoolOracle(pool).observe(secondsAgos);
        return tickCumulatives[0];
    }

    function _requireCanonicalPool(address pool, address tokenA, address tokenB) private view {
        if (pool == address(0)) revert ZeroAddress();
        uint24 fee = IV3PoolOracle(pool).fee();
        if (v3Factory.getPool(tokenA, tokenB, fee) != pool) revert InvalidPool();
    }
}
