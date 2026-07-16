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
/// burn token and destroys it. Intended as the `FeeRouter.treasury` /
/// launch-fee recipient:
///   - native ETH (unwrapped pair fees, launch fees) arrives via `receive()`
///   - launched-token fee shares arrive as plain ERC20 transfers
/// `sweep`/`sweepToken` (token -> WETH) and `burn` (ETH -> WETH -> burn token
/// -> dead address) then process the inventory.
///
/// Design constraints inherited from the fee path:
///   - `receive()` must never revert: FeeRouter.distribute and LaunchFactory
///     launches send ETH here and bubble failures, so any revert would brick
///     fee collection and new launches. It therefore does nothing.
///   - Permissionless sweeps resolve the pool from the launchpad factory's
///     `poolOf` mapping — callers can never steer a swap into a pool of their
///     choosing (a second factory-created pool for the same pair at another
///     fee tier, initialized at a hostile price, would otherwise let them
///     drain the inventory). The owner has `sweepTokenVia` as an explicit
///     escape hatch for tokens without an official pool.
///   - Swaps by untrusted callers demand a healthy oracle: the pool must
///     carry at least `minObservationCardinality` observations and serve a
///     full `twapWindow` TWAP, otherwise the call reverts with
///     `OracleNotReady`. There is deliberately NO spot fallback for them — a
///     fresh V3 pool stores a single observation, and a spot anchor is
///     attacker-positionable within one transaction. Owner-initiated swaps
///     may fall back to spot (the owner chooses its own timing). Anyone can
///     make a pool oracle-ready by calling its permissionless
///     `increaseObservationCardinalityNext` and letting trades populate it.
///   - The TWAP anchor is shifted at most `maxTickDrift` ticks in the swap
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
    error OracleNotReady();
    error UnexpectedCallback();
    error NotSelf();
    error BurnLocked();

    event BurnTargetUpdated(address token, address pool);
    event SwapGuardUpdated(uint32 twapWindow, uint24 maxTickDrift, uint16 minObservationCardinality);
    event Swept(address indexed token, address indexed pool, uint256 amountIn, uint256 wethOut);
    event SweepFailed(address indexed token, bytes reason);
    event Burned(uint256 wethIn, uint256 swapOut, uint256 amountBurned);
    event Rescued(address indexed token, address indexed to, uint256 amount);

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

    /// @notice TWAP lookback for the swap price guard. Mandatory (and never
    /// spot-substituted) for untrusted callers.
    uint32 public twapWindow = 1800;
    /// @notice Max ticks the execution price may drift past the anchor
    /// (1 tick ~= 1 bp). Swaps stop at this bound and partially fill.
    uint24 public maxTickDrift = 300;
    /// @notice Minimum pool observation cardinality before an untrusted
    /// caller may swap through it. A cardinality-1 pool "TWAP" degenerates to
    /// spot by extrapolation, so 1 is never acceptable.
    uint16 public minObservationCardinality = 8;

    /// @dev Pool allowed to invoke the swap callback for the current swap.
    address private expectedPool;

    constructor(address v3Factory_, address weth_, address launchFactory_, address owner_) Ownable(owner_) {
        if (v3Factory_ == address(0) || weth_ == address(0) || launchFactory_ == address(0)) revert ZeroAddress();
        v3Factory = IUniswapV3Factory(v3Factory_);
        weth = IWETH9(weth_);
        launchFactory = ILaunchpadPools(launchFactory_);
        lastBurnAt = block.timestamp;
    }

    /// @dev Bare ETH sink — see contract notice; must never revert.
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

    function setSwapGuard(uint32 twapWindow_, uint24 maxTickDrift_, uint16 minObservationCardinality_)
        external
        onlyOwner
    {
        if (
            twapWindow_ == 0 || maxTickDrift_ == 0 || maxTickDrift_ > uint24(uint256(int256(TickMath.MAX_TICK)))
                || minObservationCardinality_ < 2
        ) revert InvalidGuardConfig();
        twapWindow = twapWindow_;
        maxTickDrift = maxTickDrift_;
        minObservationCardinality = minObservationCardinality_;
        emit SwapGuardUpdated(twapWindow_, maxTickDrift_, minObservationCardinality_);
    }

    /// @notice Escape hatch for balances that can never be swept (no pool,
    /// permanently broken token). Owner-only by definition of "rescue".
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    // ---------------------------------------------------------------- sweeping

    /// @notice Swap this contract's entire balance of `token` into WETH
    /// through the token's OFFICIAL launchpad pool (`launchFactory.poolOf`).
    /// Callable by anyone; the pool is never caller-influenced.
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
    /// disappears entirely. The cooldown re-arms only when the whole WETH
    /// balance was consumed — a partial fill (price-limit hit on a thin pool)
    /// keeps the public window open for the remainder.
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
        if (wethIn == wethBalance) lastBurnAt = block.timestamp;

        amountBurned = IERC20(burnToken).balanceOf(address(this));
        if (amountBurned > 0) IERC20(burnToken).safeTransfer(BURN_ADDRESS, amountBurned);
        emit Burned(wethIn, swapOut, amountBurned);
    }

    // ---------------------------------------------------------------- internals

    /// @dev Exact-input single-pool swap with a TWAP-anchored price limit.
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
    /// direction. For untrusted callers the anchor MUST be a real TWAP from a
    /// pool with sufficient observation history; for the owner a spot
    /// fallback is tolerated (see contract notice).
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
        uint32 window = twapWindow;
        (, int24 spotTick,, uint16 cardinality,,,) = IUniswapV3Pool(pool).slot0();
        if (!trusted && cardinality < minObservationCardinality) revert OracleNotReady();

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        secondsAgos[1] = 0;
        try IV3PoolOracle(pool).observe(secondsAgos) returns (int56[] memory tickCumulatives, uint160[] memory) {
            int56 delta = tickCumulatives[1] - tickCumulatives[0];
            int56 mean = delta / int56(uint56(window));
            // Round toward negative infinity like OracleLibrary.
            if (delta < 0 && (delta % int56(uint56(window)) != 0)) mean--;
            return int24(mean);
        } catch {
            // Insufficient history for the window: only the owner may proceed
            // on spot; permissionless execution must wait for the oracle.
            if (!trusted) revert OracleNotReady();
            return spotTick;
        }
    }

    function _requireCanonicalPool(address pool, address tokenA, address tokenB) private view {
        if (pool == address(0)) revert ZeroAddress();
        uint24 fee = IV3PoolOracle(pool).fee();
        if (v3Factory.getPool(tokenA, tokenB, fee) != pool) revert InvalidPool();
    }
}
