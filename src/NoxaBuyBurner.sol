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

/// @notice Protocol-fee sink that converts everything it receives into NOXA and
/// burns it. Intended as the `FeeRouter.treasury` / launch-fee recipient:
///   - native ETH (unwrapped pair fees, launch fees) arrives via `receive()`
///   - launched-token fee shares arrive as plain ERC20 transfers
/// Anyone may then call `sweep`/`sweepToken` (token -> WETH) and `burn`
/// (ETH -> WETH -> NOXA -> dead address).
///
/// Design constraints inherited from the fee path:
///   - `receive()` must never revert: FeeRouter.distribute and LaunchFactory
///     launches send ETH here and bubble failures, so any revert would brick
///     fee collection and new launches. It therefore does nothing.
///   - Swaps are exact-input with a price limit derived from the pool TWAP
///     (spot when the pool has no oracle history). A thin or manipulated pool
///     produces a PARTIAL fill instead of a revert or a bad execution; the
///     unswept remainder simply waits for liquidity to return.
///   - `sweep` isolates each token in a self-call so one bad entry (fee-on-
///     transfer donation, missing pool, drained liquidity) cannot brick the
///     batch.
///   - NOXA is a vanilla OZ ERC20 with no `burn()`, and OZ rejects transfers
///     to address(0), so burning sends to the canonical dead address, which
///     the CTO snapshot logic already treats as nonvoting supply.
///   - `burn` is owner-gated so execution timing stays with the operator, but
///     if the owner goes quiet for `PUBLIC_BURN_DELAY` anyone may trigger it,
///     so accrued fees can never be stranded by an absent owner.
contract NoxaBuyBurner is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error InvalidToken();
    error InvalidPool();
    error BurnPoolNotSet();
    error NothingToSweep();
    error AmountOverflow();
    error InvalidDrift();
    error UnexpectedCallback();
    error NotSelf();
    error BurnLocked();

    event BurnTargetUpdated(address token, address pool);
    event SwapGuardUpdated(uint32 twapWindow, uint24 maxTickDrift);
    event Swept(address indexed token, address indexed pool, uint256 amountIn, uint256 wethOut);
    event SweepFailed(address indexed token, bytes reason);
    event Burned(uint256 wethIn, uint256 swapOut, uint256 amountBurned);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    /// @dev OZ ERC20 reverts on transfer to address(0); dead is the burn convention.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    /// @notice How long after the last burn anyone (not just the owner) may
    /// trigger the next one.
    uint256 public constant PUBLIC_BURN_DELAY = 2 days;

    IUniswapV3Factory public immutable v3Factory;
    IWETH9 public immutable weth;
    /// @notice Fee tier of launcher-created pools (1%); used when a sweep
    /// caller does not pass an explicit pool.
    uint24 public immutable defaultPoolFee;

    /// @notice Token bought and burned by `burn`. Owner-settable (with its
    /// pool, atomically) in case the target token is ever redeployed.
    address public burnToken;
    /// @notice Canonical burnToken/WETH pool used by `burn`. Owner-settable so
    /// the burn route can follow liquidity migrations.
    address public burnPool;
    /// @notice Timestamp of the last burn; anchors the public-burn fallback.
    uint256 public lastBurnAt;
    /// @notice TWAP lookback for the swap price guard. 0 disables the TWAP and
    /// anchors the limit to spot instead (weaker: only bounds in-tx movement).
    uint32 public twapWindow = 300;
    /// @notice Max ticks the execution price may drift past the anchor
    /// (1 tick ~= 1 bp). Swaps stop at this bound and partially fill.
    uint24 public maxTickDrift = 500;

    /// @dev Pool allowed to invoke the swap callback for the current swap.
    address private expectedPool;

    constructor(address v3Factory_, address weth_, address burnToken_, uint24 defaultPoolFee_, address owner_)
        Ownable(owner_)
    {
        if (v3Factory_ == address(0) || weth_ == address(0) || burnToken_ == address(0)) revert ZeroAddress();
        v3Factory = IUniswapV3Factory(v3Factory_);
        weth = IWETH9(weth_);
        burnToken = burnToken_;
        defaultPoolFee = defaultPoolFee_;
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

    function setSwapGuard(uint32 twapWindow_, uint24 maxTickDrift_) external onlyOwner {
        if (maxTickDrift_ == 0 || maxTickDrift_ > uint24(uint256(int256(TickMath.MAX_TICK)))) revert InvalidDrift();
        twapWindow = twapWindow_;
        maxTickDrift = maxTickDrift_;
        emit SwapGuardUpdated(twapWindow_, maxTickDrift_);
    }

    /// @notice Escape hatch for balances that can never be swept (no pool,
    /// permanently broken token). Owner-only by definition of "rescue".
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    // ---------------------------------------------------------------- sweeping

    /// @notice Swap this contract's entire balance of `token` into WETH.
    /// @param token Launched (or donated) token to liquidate.
    /// @param pool Optional explicit pool; pass address(0) to use the canonical
    /// `defaultPoolFee` pool. Any explicit pool must be canonical for
    /// (token, WETH) on the V3 factory — this is what stops a caller-supplied
    /// fake pool from stealing the balance via the swap callback.
    function sweepToken(address token, address pool) public nonReentrant returns (uint256 wethOut) {
        if (token == address(weth) || token == burnToken) revert InvalidToken();
        if (pool == address(0)) {
            pool = v3Factory.getPool(token, address(weth), defaultPoolFee);
            if (pool == address(0)) revert InvalidPool();
        } else {
            _requireCanonicalPool(pool, token, address(weth));
        }
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) revert NothingToSweep();

        (uint256 amountIn, uint256 amountOut) = _swapExactIn(pool, token, address(weth), balance);
        emit Swept(token, pool, amountIn, amountOut);
        return amountOut;
    }

    /// @notice Failure-tolerant batch sweep: each token is processed in an
    /// isolated self-call, so a token with no pool, drained liquidity, or
    /// fee-on-transfer semantics (whose V3 swap reverts by design) is skipped
    /// with an event instead of bricking the rest.
    function sweep(address[] calldata tokens) external {
        for (uint256 i = 0; i < tokens.length; i++) {
            try this.sweepTokenSelf(tokens[i]) {}
            catch (bytes memory reason) {
                emit SweepFailed(tokens[i], reason);
            }
        }
    }

    /// @dev External trampoline so `sweep` can try/catch; callable only by self.
    function sweepTokenSelf(address token) external {
        if (msg.sender != address(this)) revert NotSelf();
        sweepToken(token, address(0));
    }

    // ---------------------------------------------------------------- burning

    /// @notice Wrap all ETH, swap all WETH into the burn token through
    /// `burnPool`, and send every unit held to the dead address. Partial fills
    /// (price-limit hit on a thin pool) leave the WETH remainder for a later
    /// call. Owner-only, except that once `PUBLIC_BURN_DELAY` has passed since
    /// the last burn anyone may call it; with ownership renounced the gate
    /// disappears entirely and burning is fully permissionless.
    function burn() external nonReentrant returns (uint256 amountBurned) {
        address currentOwner = owner();
        if (
            currentOwner != address(0) && msg.sender != currentOwner
                && block.timestamp < lastBurnAt + PUBLIC_BURN_DELAY
        ) revert BurnLocked();
        lastBurnAt = block.timestamp;

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) weth.deposit{value: ethBalance}();

        uint256 wethBalance = weth.balanceOf(address(this));
        uint256 swapOut;
        uint256 wethIn;
        if (wethBalance > 0) {
            if (burnPool == address(0)) revert BurnPoolNotSet();
            (wethIn, swapOut) = _swapExactIn(burnPool, address(weth), burnToken, wethBalance);
        }

        amountBurned = IERC20(burnToken).balanceOf(address(this));
        if (amountBurned > 0) IERC20(burnToken).safeTransfer(BURN_ADDRESS, amountBurned);
        emit Burned(wethIn, swapOut, amountBurned);
    }

    // ---------------------------------------------------------------- internals

    /// @dev Exact-input single-pool swap with a TWAP-anchored price limit.
    /// Returns the amounts actually taken/received (may be a partial fill).
    function _swapExactIn(address pool, address tokenIn, address tokenOut, uint256 amountIn)
        private
        returns (uint256 actualIn, uint256 amountOut)
    {
        if (amountIn > uint256(type(int256).max)) revert AmountOverflow();
        bool zeroForOne = tokenIn < tokenOut;
        uint160 priceLimit = _boundedPriceLimit(pool, zeroForOne);

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

    /// @dev Price limit = TWAP tick shifted `maxTickDrift` in the swap
    /// direction (spot tick when the pool has no oracle history, e.g. fresh
    /// launcher pools at observation cardinality 1). Manipulated or thin pools
    /// therefore cap execution at a sane price and partially fill.
    function _boundedPriceLimit(address pool, bool zeroForOne) private view returns (uint160) {
        int24 anchorTick = _anchorTick(pool);
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

    function _anchorTick(address pool) private view returns (int24) {
        uint32 window = twapWindow;
        if (window > 0) {
            uint32[] memory secondsAgos = new uint32[](2);
            secondsAgos[0] = window;
            secondsAgos[1] = 0;
            try IV3PoolOracle(pool).observe(secondsAgos) returns (int56[] memory tickCumulatives, uint160[] memory) {
                int56 delta = tickCumulatives[1] - tickCumulatives[0];
                int56 mean = delta / int56(uint56(window));
                // Round toward negative infinity like OracleLibrary.
                if (delta < 0 && (delta % int56(uint56(window)) != 0)) mean--;
                return int24(mean);
            } catch {}
        }
        (, int24 spotTick,,,,,) = IUniswapV3Pool(pool).slot0();
        return spotTick;
    }

    function _requireCanonicalPool(address pool, address tokenA, address tokenB) private view {
        if (pool == address(0)) revert ZeroAddress();
        uint24 fee = IV3PoolOracle(pool).fee();
        if (v3Factory.getPool(tokenA, tokenB, fee) != pool) revert InvalidPool();
    }
}
