// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {NoxaBuyBurner} from "../src/NoxaBuyBurner.sol";
import {Noxa2Token} from "../NoxaToken.sol";
import {LauncherLocker} from "../src/LauncherLocker.sol";
import {LauncherTypes} from "../src/LauncherTypes.sol";
import {LaunchFactory} from "../LaunchFactory_flat.sol";
import {
    IUniswapV3Factory,
    IUniswapV3Pool,
    INonfungiblePositionManager,
    IWETH9
} from "../src/interfaces/IUniswapV3.sol";
import {TickMath} from "../src/libraries/TickMath.sol";

interface VmFork {
    function createSelectFork(string calldata urlOrAlias) external returns (uint256 forkId);
    function deal(address account, uint256 newBalance) external;
    function prank(address caller) external;
    function startPrank(address caller) external;
    function stopPrank() external;
    function roll(uint256 newHeight) external;
    function warp(uint256 newTimestamp) external;
    function expectRevert() external;
    function expectRevert(bytes4 revertData) external;
    function expectRevert(bytes calldata revertData) external;
}

/// @dev ABI for the already-deployed, pre-three-way FeeRouter used only by
/// this legacy fork characterization suite.
interface ILegacyFeeRouter {
    function owner() external view returns (address);
    function setTreasury(address treasury) external;
}

contract MockJunkToken is ERC20 {
    constructor() ERC20("Junk", "JNK") {
        _mint(msg.sender, 1e24);
    }
}

/// @dev Reports a fee but is not canonical on the V3 factory; used to prove a
/// caller-supplied pool cannot reach the swap callback.
contract FakePool {
    function fee() external pure returns (uint24) {
        return 10000;
    }
}

/// @notice Fork tests against the live Robinhood deployment (local node on
/// 127.0.0.1:8547). Exercises the full protocol-fee path with the burner as
/// treasury: launch fee -> receive(), LP-fee distribute -> ETH + launched
/// tokens, sweep -> WETH, burn -> NOXA to the dead address.
contract NoxaBuyBurnerForkTest {
    VmFork constant vm = VmFork(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    // Live chain infrastructure (chain 4663).
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address constant NPM = 0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3;
    // Live noxa2 deployment.
    address constant FACTORY = 0x003a2052B2c86E700C43f7FaB47733207B08a264;
    address constant LOCKER = 0x11447d70c0Cb62CaDb21e70Eba8ce616cA5Bf82e;
    address payable constant FEE_ROUTER = payable(0x914f94b62781dd1524D650cefcC916Ca40450397);

    uint24 constant LAUNCH_FEE_TIER = 10000;
    uint256 constant LAUNCH_FEE = 0.0005 ether;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // tick 0

    NoxaBuyBurner burner;
    // Stand-in for the pre-existing on-chain NOXA: the burn target is set
    // post-deployment, so tests deploy a fresh token to burn.
    address noxa;
    address burnPool;
    address launched;
    address launchedPool;
    address constant STRANGER = address(0xBEEF);

    uint256 ethAfterLaunch;
    uint256 ethAfterClaim;
    uint256 tokenBalAfterClaim;

    function setUp() public {
        vm.createSelectFork("http://127.0.0.1:8547");

        burner = new NoxaBuyBurner(V3_FACTORY, WETH, FACTORY, address(this));
        // The real NOXA pre-exists on-chain and is wired via setBurnTarget
        // after deployment; tests mint a fresh stand-in (1M supply to us).
        noxa = address(new Noxa2Token(address(this), "", "", Noxa2Token.Socials("", "", "", "", "")));

        // Seed a NOXA/WETH pool at the launcher tier (1:1 for test simplicity).
        vm.deal(address(this), 1_000_000 ether);
        IWETH9(WETH).deposit{value: 400_000 ether}();
        burnPool = _createPool(LAUNCH_FEE_TIER, 300_000 ether, -200_000, 200_000);
        burner.setBurnTarget(noxa, burnPool);

        // Repoint the protocol treasury at the burner (owner-only, live owner).
        vm.prank(ILegacyFeeRouter(FEE_ROUTER).owner());
        ILegacyFeeRouter(FEE_ROUTER).setTreasury(address(burner));

        // Launch a token through the live factory; the launch fee must land in
        // the burner via its bare receive().
        LauncherTypes.LaunchParams memory params = LauncherTypes.LaunchParams({
            name: "BurnTest",
            symbol: "BT",
            logo: "",
            description: "",
            socials: LauncherTypes.Socials("", "", "", "", ""),
            devWallet: address(this)
        });
        (launched,) = LaunchFactory(payable(FACTORY)).launchToken{value: LAUNCH_FEE}(params, 0, 0, bytes32(uint256(1)));
        launchedPool = IUniswapV3Factory(V3_FACTORY).getPool(launched, WETH, LAUNCH_FEE_TIER);
        ethAfterLaunch = address(burner).balance;

        // Trade both directions past the anti-snipe window so LP fees accrue
        // in WETH and in the launched token, then claim. This suite targets the
        // legacy live router, which unwraps WETH; current-router ERC20-only
        // behavior is covered by FeeRouterTest and NoxaFactoryIntegrationTest.
        vm.roll(block.number + 400);
        uint256 bought = _poolSwap(launchedPool, WETH, 5 ether);
        _poolSwap(launchedPool, launched, bought / 2);
        LauncherLocker(LOCKER).claimFees(launched);
        ethAfterClaim = address(burner).balance;
        tokenBalAfterClaim = IERC20(launched).balanceOf(address(burner));
    }

    // ---------------------------------------------------------------- fee path

    function test_endToEnd_feesFlow_sweep_burn() public {
        require(ethAfterLaunch == LAUNCH_FEE, "launch fee should land in burner");
        require(ethAfterClaim > ethAfterLaunch, "pair-fee share should arrive as ETH");
        require(tokenBalAfterClaim > 0, "token-fee share should arrive as ERC20");

        address[] memory tokens = new address[](1);
        tokens[0] = launched;
        burner.sweep(tokens);
        require(IERC20(launched).balanceOf(address(burner)) == 0, "launched tokens fully swept");
        require(IERC20(WETH).balanceOf(address(burner)) > 0, "sweep proceeds held as WETH");

        uint256 deadBefore = IERC20(noxa).balanceOf(burner.BURN_ADDRESS());
        uint256 burned = burner.burn();
        require(burned > 0, "burn should destroy NOXA");
        require(IERC20(noxa).balanceOf(burner.BURN_ADDRESS()) - deadBefore == burned, "burn accounting");
        require(address(burner).balance == 0, "all ETH consumed");
        require(IERC20(WETH).balanceOf(address(burner)) == 0, "all WETH consumed");
        require(IERC20(noxa).balanceOf(address(burner)) == 0, "no NOXA retained");
    }

    function test_receive_neverReverts() public {
        (bool ok,) = address(burner).call{value: 1 wei}("");
        require(ok, "bare receive must accept ETH");
    }

    // ---------------------------------------------------------------- resilience

    function test_sweep_skipsBadTokens_continuesBatch() public {
        MockJunkToken junk = new MockJunkToken();
        junk.transfer(address(burner), 1e21); // donated token with no official pool

        address[] memory tokens = new address[](3);
        tokens[0] = address(junk);
        tokens[1] = address(0x1234); // not even a token
        tokens[2] = launched;
        burner.sweep(tokens);

        require(IERC20(launched).balanceOf(address(burner)) == 0, "good token still swept");
        require(junk.balanceOf(address(burner)) == 1e21, "junk untouched, rescuable");
    }

    function test_burn_thinPool_partialFill_noRevert_noRearm() public {
        // 0.3% tier pool with tiny liquidity, then far more ETH than it holds.
        address thin = _createPool(3000, 50 ether, -60_000, 60_000);
        burner.setBurnTarget(noxa, thin);
        vm.deal(address(this), 5_000 ether);
        (bool ok,) = address(burner).call{value: 5_000 ether}("");
        require(ok, "fund burner");

        uint256 lastBurnBefore = burner.lastBurnAt();
        uint256 deadBefore = IERC20(noxa).balanceOf(burner.BURN_ADDRESS());
        uint256 burned = burner.burn(); // owner call; must not revert
        require(burned > 0, "partial fill still burns");
        require(IERC20(noxa).balanceOf(burner.BURN_ADDRESS()) > deadBefore, "dead balance grew");
        require(IERC20(WETH).balanceOf(address(burner)) > 0, "unswapped WETH retained for later");
        require(burner.lastBurnAt() == lastBurnBefore, "partial fill must not re-arm public cooldown");
    }

    // A zero-WETH burn must NOT re-arm the public-burn cooldown: otherwise a
    // front-runner could re-lock the public fallback for another
    // PUBLIC_BURN_DELAY the instant the window opens, by calling burn() while
    // the contract holds no WETH (wethIn == wethBalance == 0).
    function test_burn_emptyBalance_doesNotRearmPublicCooldown() public {
        NoxaBuyBurner empty = new NoxaBuyBurner(V3_FACTORY, WETH, FACTORY, address(this));
        empty.setBurnTarget(noxa, burnPool);
        require(
            IERC20(WETH).balanceOf(address(empty)) == 0 && address(empty).balance == 0, "burner must start empty"
        );

        uint256 armedAt = empty.lastBurnAt(); // set at construction
        vm.warp(block.timestamp + empty.PUBLIC_BURN_DELAY() + 1); // open the public window

        // Empty burn by a stranger: no swap happens (no anchor needed), nothing
        // is burned, and — post-fix — the cooldown clock is untouched.
        vm.prank(STRANGER);
        uint256 burned = empty.burn();
        require(burned == 0, "empty burn destroys nothing");
        require(empty.lastBurnAt() == armedAt, "empty burn must not re-arm the public cooldown");

        // The window therefore stays open — a stranger can still burn again
        // immediately (no spurious 2-day re-lock from the empty call).
        vm.prank(STRANGER);
        empty.burn();
        require(empty.lastBurnAt() == armedAt, "second empty burn still must not re-arm");
    }

    // ---------------------------------------------------------------- pool trust

    function test_publicSweep_cannotChoosePool_usesOfficialMapping() public {
        // The permissionless entrypoint takes no pool at all; resolution is
        // factory-only. A non-launched token has no official pool and fails
        // closed even though canonical V3 pools for it could exist.
        MockJunkToken junk = new MockJunkToken();
        junk.transfer(address(burner), 1e21);
        vm.prank(STRANGER);
        vm.expectRevert(NoxaBuyBurner.NoOfficialPool.selector);
        burner.sweepToken(address(junk));
    }

    function test_sweepTokenVia_ownerOnly_rejectsFakePool() public {
        FakePool fake = new FakePool();
        vm.expectRevert(NoxaBuyBurner.InvalidPool.selector);
        burner.sweepTokenVia(launched, address(fake));

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        burner.sweepTokenVia(launched, launchedPool);
    }

    function test_sweepTokenVia_ownerEscapeHatch() public {
        uint256 out = burner.sweepTokenVia(launched, launchedPool);
        require(out > 0, "owner explicit-pool sweep");
    }

    // ---------------------------------------------------------------- anchor gate

    function test_publicSweep_revertsWithoutAnchor() public {
        // No recorded anchor: untrusted callers must not price off spot.
        vm.prank(STRANGER);
        vm.expectRevert(NoxaBuyBurner.AnchorNotReady.selector);
        burner.sweepToken(launched);
    }

    function test_publicSweep_immatureAnchorReverts_maturedAnchorWorks() public {
        vm.prank(STRANGER);
        burner.recordAnchor(launchedPool);

        // Same-block (and any pre-delay) execution is blocked.
        vm.prank(STRANGER);
        vm.expectRevert(NoxaBuyBurner.AnchorNotReady.selector);
        burner.sweepToken(launched);

        // After the delay the anchor is usable by anyone.
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + burner.anchorDelay() + 1);
        vm.prank(STRANGER);
        uint256 out = burner.sweepToken(launched);
        require(out > 0, "matured-anchor public sweep executes");
    }

    function test_publicSweep_atomicManipulation_cannotExtractInventory() public {
        // The reviewer's attack: manipulate spot around both the record and
        // the execution moments, holding nothing in between. With cumulative
        // anchors the average is time-weighted, so the atomic crash carries
        // ~zero weight: the anchor stays honest and the pool now sits far
        // below (anchor - drift), making the sweep revert (SPL) instead of
        // selling the inventory at the hostile price.
        burner.recordAnchor(launchedPool);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + burner.anchorDelay() + 1);

        // Attacker crashes the launched token's price in one shot.
        uint256 attackerTokens = IERC20(launched).balanceOf(address(this));
        _poolSwap(launchedPool, launched, attackerTokens);

        vm.prank(STRANGER);
        vm.expectRevert(); // pool rejects the out-of-bounds price limit
        burner.sweepToken(launched);
    }

    function test_anchor_expiresAndIsRerecordable_notOverwritableWhileLive() public {
        burner.recordAnchor(launchedPool);

        // A live (pending or usable) anchor cannot be replaced.
        vm.expectRevert(NoxaBuyBurner.AnchorPending.selector);
        burner.recordAnchor(launchedPool);
        vm.warp(block.timestamp + burner.anchorDelay() + 1);
        vm.expectRevert(NoxaBuyBurner.AnchorPending.selector);
        burner.recordAnchor(launchedPool);

        // Past validity it is stale: unusable, but re-recordable.
        vm.warp(block.timestamp + burner.anchorValidity() + 1);
        vm.prank(STRANGER);
        vm.expectRevert(NoxaBuyBurner.AnchorNotReady.selector);
        burner.sweepToken(launched);
        burner.recordAnchor(launchedPool);
    }

    function test_ownerSweep_pricesOffSpot_noAnchorNeeded() public {
        uint256 out = burner.sweepToken(launched); // owner: spot anchor allowed
        require(out > 0, "owner sweep works without an anchor");
    }

    function test_publicBurn_revertsWithoutAnchor() public {
        vm.warp(block.timestamp + burner.PUBLIC_BURN_DELAY() + 1);
        vm.prank(STRANGER);
        vm.expectRevert(NoxaBuyBurner.AnchorNotReady.selector);
        burner.burn();
    }

    // ---------------------------------------------------------------- burn gate

    function test_burn_ownerGate_and_publicFallback() public {
        // Stranger blocked inside the delay window.
        vm.prank(STRANGER);
        vm.expectRevert(NoxaBuyBurner.BurnLocked.selector);
        burner.burn();

        // After the delay, anyone may burn against a matured anchor; the
        // complete burn re-arms the window so the next attempt is blocked.
        vm.warp(block.timestamp + burner.PUBLIC_BURN_DELAY() + 1);
        _matureAnchor(burnPool);
        vm.prank(STRANGER);
        uint256 burned = burner.burn();
        require(burned > 0, "public fallback burn executes");
        vm.prank(STRANGER);
        vm.expectRevert(NoxaBuyBurner.BurnLocked.selector);
        burner.burn();
    }

    function test_burn_permissionlessAfterOwnershipRenounced() public {
        burner.renounceOwnership();
        _matureAnchor(burnPool);
        // No delay gate anymore: back-to-back public burns both execute
        // while the anchor stays valid.
        vm.prank(STRANGER);
        uint256 burned = burner.burn();
        require(burned > 0, "ownerless burn executes immediately");
        (bool ok,) = address(burner).call{value: 1 ether}("");
        require(ok, "fund burner again");
        vm.prank(STRANGER);
        require(burner.burn() > 0, "no re-armed window without an owner");
    }

    // ---------------------------------------------------------------- admin

    function test_burn_revertsUntilTargetConfigured() public {
        // Fresh burner exactly as the deploy script leaves it: no target yet.
        NoxaBuyBurner fresh = new NoxaBuyBurner(V3_FACTORY, WETH, FACTORY, address(this));
        (bool ok,) = address(fresh).call{value: 1 ether}("");
        require(ok, "fees accumulate before target is set");
        vm.expectRevert(NoxaBuyBurner.BurnTargetNotSet.selector);
        fresh.burn();
    }

    function test_setBurnTarget_rejectsWrongPairPool() public {
        vm.expectRevert(NoxaBuyBurner.InvalidPool.selector);
        burner.setBurnTarget(noxa, launchedPool); // canonical, but not NOXA/WETH
    }

    function test_setBurnTarget_switchesToken() public {
        // Retarget burning at the launched token via its canonical pool.
        burner.setBurnTarget(launched, launchedPool);
        uint256 deadBefore = IERC20(launched).balanceOf(burner.BURN_ADDRESS());
        uint256 burned = burner.burn();
        require(burned > 0, "burns retargeted token");
        require(IERC20(launched).balanceOf(burner.BURN_ADDRESS()) - deadBefore == burned, "retarget accounting");
        // The old target is now an ordinary token again: sweepable, not burnable.
        vm.expectRevert(NoxaBuyBurner.InvalidToken.selector);
        burner.sweepToken(launched);
    }

    function test_adminFunctions_onlyOwner() public {
        bytes memory unauthorized = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER);
        vm.startPrank(STRANGER);
        vm.expectRevert(unauthorized);
        burner.setBurnTarget(noxa, burnPool);
        vm.expectRevert(unauthorized);
        burner.setSwapGuard(300, 3600, 300);
        vm.expectRevert(unauthorized);
        burner.rescueToken(noxa, STRANGER, 1);
        vm.stopPrank();
    }

    function test_setSwapGuard_rejectsDegenerateConfig() public {
        vm.expectRevert(NoxaBuyBurner.InvalidGuardConfig.selector);
        burner.setSwapGuard(30, 3600, 300); // sub-minute delay defeats the commit step
        vm.expectRevert(NoxaBuyBurner.InvalidGuardConfig.selector);
        burner.setSwapGuard(300, 300, 300); // validity must exceed the delay
        vm.expectRevert(NoxaBuyBurner.InvalidGuardConfig.selector);
        burner.setSwapGuard(300, 3600, 0); // zero drift blocks every swap
    }

    function test_rescueToken() public {
        MockJunkToken junk = new MockJunkToken();
        junk.transfer(address(burner), 5e20);
        burner.rescueToken(address(junk), STRANGER, 5e20);
        require(junk.balanceOf(STRANGER) == 5e20, "rescued to recipient");
    }

    // ---------------------------------------------------------------- helpers

    function _createPool(uint24 fee, uint256 amountPerSide, int24 tickLower, int24 tickUpper)
        internal
        returns (address pool)
    {
        (address token0, address token1) = WETH < noxa ? (WETH, noxa) : (noxa, WETH);
        pool = INonfungiblePositionManager(NPM).createAndInitializePoolIfNecessary(token0, token1, fee, SQRT_PRICE_1_1);
        IERC20(WETH).approve(NPM, amountPerSide);
        IERC20(noxa).approve(NPM, amountPerSide);
        INonfungiblePositionManager(NPM).mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: fee,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amountPerSide,
                amount1Desired: amountPerSide,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp + 1 hours
            })
        );
    }

    /// @dev Record a price anchor for `pool` and age it past the delay so
    /// untrusted callers can swap against it.
    function _matureAnchor(address pool) internal {
        burner.recordAnchor(pool);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + burner.anchorDelay() + 1);
    }

    /// @dev Direct exact-input pool swap from the test; callback below pays.
    function _poolSwap(address pool, address tokenIn, uint256 amountIn) internal returns (uint256 amountOut) {
        address token0 = IUniswapV3Pool(pool).token0();
        bool zeroForOne = tokenIn == token0;
        (int256 a0, int256 a1) = IUniswapV3Pool(pool).swap(
            address(this),
            zeroForOne,
            int256(amountIn),
            zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1,
            abi.encode(tokenIn)
        );
        amountOut = uint256(-(zeroForOne ? a1 : a0));
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        address tokenIn = abi.decode(data, (address));
        uint256 owed = uint256(amount0Delta > 0 ? amount0Delta : amount1Delta);
        IERC20(tokenIn).transfer(msg.sender, owed);
    }
}
