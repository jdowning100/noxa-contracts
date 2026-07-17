// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FeeRouter} from "../src/FeeRouter.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";
import {NoxaBuyBurner} from "../src/NoxaBuyBurner.sol";
import {LauncherLocker} from "../src/LauncherLocker.sol";
import {NoxaCTOFund} from "../src/NoxaCTOFund.sol";
import {LaunchFactory} from "../LaunchFactory_flat.sol";
import {LauncherTypes} from "../src/LauncherTypes.sol";
// Named import: the vendored proxy file is a flattened OZ v5 bundle that also declares
// Address/Context/Ownable/StorageSlot; pull in ONLY the proxy symbol to avoid clashes.
import {TransparentUpgradeableProxy} from "../src/proxy/TransparentUpgradeableProxy.sol";

/// @notice Deploys the noxa2 protocol stack to Robinhood Chain (4663).
///
///   Run (broadcast):
///     export NOXA_SPLIT_RECIPIENTS=0xTeam1,0xTeam2
///     export NOXA_SPLIT_SHARES=6000,4000                 # bps, must sum to 10000
///     forge script script/DeployNoxa.s.sol --rpc-url <rpc> --private-key $RH_KEY --broadcast --slow
///
///   Deploys, in one transaction sequence: FeeRouter, LauncherLocker,
///   LaunchFactory, NoxaCTOFund (behind a TransparentUpgradeableProxy), NoxaBuyBurner,
///   and a FeeSplitter. It does NOT deploy a token or an airdrop.
///
///   Fee flow (LP fees stay as their original ERC20 assets; FeeRouter splits both):
///     33.33% -> FeeSplitter (protocol share, subdivided among NOXA_SPLIT_RECIPIENTS)
///     33.33% -> NoxaBuyBurner
///     33.34% -> the token's CTO fee vault
///   The launch fee is separate: wrapped into WETH and sent directly to the burner.
///
///   BURN TARGET IS UNSET. The token the burner buys and burns pre-exists on-chain and
///   is configured AFTER deployment; the burner owner must:
///     1. ensure a canonical burnToken/WETH V3 pool exists with liquidity,
///     2. call burner.setBurnTarget(burnToken, pool).
///   Until then fees accumulate in the burner and burn() reverts. Untrusted (non-owner)
///   burns/sweeps additionally need a matured burner.recordAnchor(pool) snapshot (record,
///   wait anchorDelay, execute): the burner prices them off a forward TWAP — the pool's
///   tickCumulative delta across the window — so atomic spot manipulation carries zero
///   time weight in the execution bound.
///
///   OWNERSHIP: every Ownable contract is left owned by the deployer. Only NoxaCTOFund is
///   upgradeable (behind the proxy, whose constructor also spins up a ProxyAdmin owned by
///   the deployer). The factory / locker / fee-router / burner / splitter are immutable by
///   design — a bug is fixed by deploying a fresh generation and re-pointing frontend+indexer.
///
///   POST-DEPLOY HANDOFF (manual; strongly recommended to move to an admin multisig you
///   deploy separately, e.g. a Safe):
///     - ctoProxyAdmin.transferOwnership(multisig)   (CTOFund upgrade rights; admin in AdminChanged)
///     - cto.transferOwnership(multisig)             (election parameters, per-token quorum)
///     - factory.transferOwnership(multisig)
///     - locker.transferOwnership(multisig)
///     - feeRouter.transferOwnership(multisig)       (recipient pointers, fee split)
///     - burner.transferOwnership(multisig)          (burn target/guard, rescue, burn timing)
///     - splitter.transferOwnership(multisig)        (protocol-share recipients + shares)
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

    // ---- deployment overrides ----
    uint256 constant QUORUM_BPS = 2500; // 25% of circulating supply to elect a CTO leader
    uint16 constant PROTOCOL_SHARE_BPS = 3333;
    uint16 constant BURNER_SHARE_BPS = 3333;
    uint16 constant CTO_SHARE_BPS = 3334; // receives the indivisible remainder
    uint16 constant TOTAL_BPS = 10000;

    event Deployed(
        address feeRouter,
        address feeSplitter,
        address locker,
        address factory,
        address ctoImpl,
        address ctoProxy,
        address burner
    );

    function run() external {
        require(block.chainid == 4663, "WRONG_CHAIN");
        _validateDexDependencies();

        // ---- operator-provided config (read + validated BEFORE any broadcast, so a
        //      misconfiguration reverts without deploying anything). All fail closed:
        //      an unset env var reverts inside vm.envAddress/vm.envUint. ----
        (address[] memory splitRecipients, uint16[] memory splitShares) = _readSplitterConfig();

        // Deployer owns everything initially; hand off to your admin multisig later (see header).
        address owner = msg.sender;

        vm.startBroadcast();

        // 1. FeeRouter — recipients are configured atomically once the burner and
        //    splitter exist. Launches remain disabled throughout.
        FeeRouter feeRouter = new FeeRouter();

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

        // 5. Bind the fund to the factory (one-time) and set the quorum.
        factory.setCTOFund(address(cto));
        cto.setQuorumBps(QUORUM_BPS);

        // 6. Buy-and-burn recipient. Burn target intentionally unset (see header).
        NoxaBuyBurner burner = new NoxaBuyBurner(V3_FACTORY, WETH, address(factory), owner);

        // 7. FeeSplitter for the protocol share, then wire the full three-way split.
        //    The router auto-detects the splitter (feeRouter()==router, currentEpoch()!=0)
        //    and pushes the protocol leg via deposit(); the sanity check makes that explicit.
        FeeSplitter splitter = new FeeSplitter(address(feeRouter), owner, splitRecipients, splitShares);
        feeRouter.setFeeConfig(address(splitter), address(burner), PROTOCOL_SHARE_BPS, BURNER_SHARE_BPS, CTO_SHARE_BPS);
        require(feeRouter.protocolRecipientIsSplitter(), "SPLITTER_NOT_BOUND");

        // 8. Register the Uniswap-V3 DEX + the mirrored launch config.
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

        // 9. Open permissionless launches only after every deployment and one-time wire succeeds.
        factory.setLaunchEnabled(true);

        vm.stopBroadcast();

        emit Deployed(
            address(feeRouter),
            address(splitter),
            address(locker),
            address(factory),
            address(ctoImpl),
            address(ctoProxy),
            address(burner)
        );
    }

    /// @dev Reads and validates NOXA_SPLIT_RECIPIENTS / NOXA_SPLIT_SHARES (parallel arrays);
    /// shares are bps and must sum to exactly 10000. Reverts (no broadcast) on any problem.
    function _readSplitterConfig() private view returns (address[] memory recipients, uint16[] memory shares) {
        recipients = vm.envAddress("NOXA_SPLIT_RECIPIENTS", ",");
        uint256[] memory raw = vm.envUint("NOXA_SPLIT_SHARES", ",");
        require(recipients.length > 0, "SPLIT_RECIPIENTS_EMPTY");
        require(recipients.length == raw.length, "SPLIT_LENGTH_MISMATCH");

        shares = new uint16[](raw.length);
        uint256 sum;
        for (uint256 i; i < raw.length; ++i) {
            require(raw[i] != 0 && raw[i] <= TOTAL_BPS, "SPLIT_SHARE_OUT_OF_RANGE");
            shares[i] = uint16(raw[i]);
            sum += raw[i];
        }
        require(sum == TOTAL_BPS, "SPLIT_SHARES_!=10000");
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
    function envAddress(string calldata name, string calldata delim) external view returns (address[] memory);
    function envUint(string calldata name, string calldata delim) external view returns (uint256[] memory);
}
