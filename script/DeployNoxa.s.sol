// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FeeRouter} from "../src/FeeRouter.sol";
import {NoxaBuyBurner} from "../src/NoxaBuyBurner.sol";
import {LauncherLocker} from "../src/LauncherLocker.sol";
import {NoxaCTOFund} from "../src/NoxaCTOFund.sol";
import {LaunchFactory} from "../LaunchFactory_flat.sol";
import {LauncherTypes} from "../src/LauncherTypes.sol";
// Named import: the vendored proxy file is a flattened OZ v5 bundle that also declares
// Address/Context/Ownable/StorageSlot; pull in ONLY the proxy symbol to avoid clashes.
import {TransparentUpgradeableProxy} from "../src/proxy/TransparentUpgradeableProxy.sol";

/// @notice Deploys the noxa2 stack to Robinhood Chain (4663).
///
///   Run (broadcast):
///     forge script script/DeployNoxa.s.sol --rpc-url <rpc> --private-key $RH_KEY --broadcast --slow
///
///   Only NoxaCTOFund is upgradeable (behind a TransparentUpgradeableProxy whose constructor
///   deploys the impl-atomic-initialize AND spins up a dedicated ProxyAdmin owned by `owner`).
///   Upgrade later:  ProxyAdmin.upgradeAndCall(proxy, newImpl, "")   (admin addr is in the
///   deploy logs' AdminChanged event). Freeze upgrades: ProxyAdmin.renounceOwnership().
///   The factory / locker / fee-router / burner are immutable by design — a bug
///   is fixed by deploying a fresh generation and re-pointing the frontend + indexer.
///
///   The protocol treasury is the NoxaBuyBurner: all protocol fees (launch fees, ETH pair
///   fees, launched-token fee shares) accumulate there. The NOXA token is NOT deployed
///   here — it already exists on-chain. The burn target starts unset; after deployment
///   the burner owner must:
///     1. ensure a canonical NOXA/WETH V3 pool exists with liquidity,
///     2. call pool.increaseObservationCardinalityNext(>= 8) (permissionless) and let
///        ~30 min of trades populate the oracle (required for permissionless burns/sweeps),
///     3. call burner.setBurnTarget(noxaToken, pool).
///   Until then fees simply accumulate in the burner and burn() reverts.
///
///   POST-DEPLOY HANDOFF (to a multisig/timelock; strongly recommended for production):
///     - ctoProxyAdmin.transferOwnership(multisig)   (CTOFund upgrade rights)
///     - cto.transferOwnership(multisig)             (election parameters, per-token quorum)
///     - factory.transferOwnership(multisig); locker.transferOwnership(multisig)
///     - feeRouter.transferOwnership(multisig)       (treasury pointer, fee splits)
///     - burner.transferOwnership(multisig)          (burn target/guard, rescue, burn timing)
contract DeployNoxa {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    // ---- live Uniswap-V3 fork on Robinhood (verified on-chain to have code) ----
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address constant NPM = 0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3; // NonfungiblePositionManager
    address constant SWAP_ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2;

    // ---- launch economics, mirrored from the original factory's getLaunchConfig(0) ----
    uint24 constant POOL_FEE = 10000; // 1% tier
    int24 constant TICK_SPACING = 200;
    int24 constant INITIAL_TICK = -204200; // ~1.35 ETH starting market cap at 1e9 supply
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;
    uint16 constant MAX_WALLET_BPS = 200; // 2%
    uint16 constant MAX_TX_BPS = 10000; // no per-tx cap
    uint32 constant RESTRICTION_BLOCKS = 366;
    uint24 constant BUY_PAIR_HOP_FEE = 0;
    uint256 constant LAUNCH_FEE = 0.0005 ether;

    // ---- deployment overrides requested ----
    uint256 constant QUORUM_BPS = 2500; // 25% of circulating supply to elect a CTO leader
    uint16 constant PROTOCOL_SHARE_BPS = 5000; // 50% of pair (ETH) fees to treasury
    uint16 constant TOKEN_TREASURY_SHARE_BPS = 5000; // 50% of launched-token fees to treasury

    event Deployed(
        address feeRouter, address locker, address factory, address ctoImpl, address ctoProxy, address burner
    );

    function run() external {
        require(block.chainid == 4663, "WRONG_CHAIN");
        _validateDexDependencies();

        // Deployer owns everything initially; hand off to a multisig later (see header).
        address owner = msg.sender;

        vm.startBroadcast();

        // 1. FeeRouter — 50/50 protocol/creator split on both token and pair fees. The
        //    deployer is a placeholder treasury until the burner exists (constructor
        //    rejects address(0)).
        FeeRouter feeRouter = new FeeRouter(WETH, owner, PROTOCOL_SHARE_BPS, TOKEN_TREASURY_SHARE_BPS);

        // 2. Locker holds LP NFTs permanently; wire it to the router (one-time).
        LauncherLocker locker = new LauncherLocker(payable(address(feeRouter)));
        feeRouter.setLocker(address(locker));

        // 3. Factory (launches disabled until fully wired); wire the locker back to it (one-time).
        LaunchFactory factory = new LaunchFactory(address(locker), LAUNCH_FEE, false);
        locker.setFactory(address(factory));

        // 4. CTOFund behind a transparent proxy — impl deployed, ProxyAdmin auto-created (owner-owned),
        //    initialize() called atomically so the implementation can never be initialized directly.
        NoxaCTOFund ctoImpl = new NoxaCTOFund();
        TransparentUpgradeableProxy ctoProxy = new TransparentUpgradeableProxy(
            address(ctoImpl), owner, abi.encodeCall(NoxaCTOFund.initialize, (address(factory), owner))
        );
        NoxaCTOFund cto = NoxaCTOFund(address(ctoProxy));

        // 5. Bind the fund to the factory (one-time) and set the 25% quorum.
        factory.setCTOFund(address(cto));
        cto.setQuorumBps(QUORUM_BPS);

        // 6. Buy-and-burn treasury. Burn target intentionally unset (see header);
        //    all protocol fees route here from the very first launch.
        NoxaBuyBurner burner = new NoxaBuyBurner(V3_FACTORY, WETH, address(factory), owner);
        feeRouter.setTreasury(address(burner));

        // 7. Register the Uniswap-V3 DEX + the mirrored launch config.
        factory.addDexConfig(
            LauncherTypes.DexConfig({
                dexFactory: V3_FACTORY,
                positionManager: NPM,
                router: SWAP_ROUTER,
                poolFee: POOL_FEE,
                tickSpacing: TICK_SPACING,
                enabled: true
            })
        );
        factory.addLaunchConfig(
            LauncherTypes.LaunchConfig({
                pairToken: WETH,
                dexId: 0,
                initialTick: INITIAL_TICK,
                supply: SUPPLY,
                maxWalletBps: MAX_WALLET_BPS,
                maxTxBps: MAX_TX_BPS,
                restrictionBlocks: RESTRICTION_BLOCKS,
                buyPairHopFee: BUY_PAIR_HOP_FEE,
                enabled: true,
                permissioned: false
            })
        );

        // 8. Open permissionless launches only after every deployment and one-time wire succeeds.
        factory.setLaunchEnabled(true);

        vm.stopBroadcast();

        emit Deployed(
            address(feeRouter), address(locker), address(factory), address(ctoImpl), address(ctoProxy), address(burner)
        );
    }

    function _validateDexDependencies() private view {
        require(WETH.code.length != 0, "WETH_NO_CODE");
        require(V3_FACTORY.code.length != 0, "V3_FACTORY_NO_CODE");
        require(NPM.code.length != 0, "NPM_NO_CODE");
        require(SWAP_ROUTER.code.length != 0, "SWAP_ROUTER_NO_CODE");
        require(IV3FactoryPreflight(V3_FACTORY).feeAmountTickSpacing(POOL_FEE) == TICK_SPACING, "BAD_FEE_TIER");
        require(IPeripheryPreflight(NPM).factory() == V3_FACTORY, "BAD_NPM_FACTORY");
        require(IPeripheryPreflight(NPM).WETH9() == WETH, "BAD_NPM_WETH");
        require(IPeripheryPreflight(SWAP_ROUTER).factory() == V3_FACTORY, "BAD_ROUTER_FACTORY");
        require(IPeripheryPreflight(SWAP_ROUTER).WETH9() == WETH, "BAD_ROUTER_WETH");
        require(INITIAL_TICK % TICK_SPACING == 0, "MISALIGNED_INITIAL_TICK");
    }
}

interface IV3FactoryPreflight {
    function feeAmountTickSpacing(uint24 fee) external view returns (int24);
}

interface IPeripheryPreflight {
    function factory() external view returns (address);
    function WETH9() external view returns (address);
}

interface Vm {
    function startBroadcast() external;
    function stopBroadcast() external;
}
