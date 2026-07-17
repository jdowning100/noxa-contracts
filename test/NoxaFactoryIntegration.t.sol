// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LaunchFactory} from "../LaunchFactory_flat.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {LauncherLocker} from "../src/LauncherLocker.sol";
import {LauncherTypes} from "../src/LauncherTypes.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";
import {NoxaCTOFund} from "../src/NoxaCTOFund.sol";
import {CTOFeeVault} from "../src/CTOFeeVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INonfungiblePositionManager} from "../src/interfaces/IUniswapV3.sol";

interface VmIntegration {
    function deal(address account, uint256 newBalance) external;
    function expectRevert(bytes4 revertData) external;
    function prank(address caller) external;
    function roll(uint256 newHeight) external;
}

contract IntegrationProxy {
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    constructor(address implementation, bytes memory initializationCall) {
        assembly ("memory-safe") {
            sstore(IMPLEMENTATION_SLOT, implementation)
        }
        (bool ok, bytes memory result) = implementation.delegatecall(initializationCall);
        if (!ok) _revert(result);
    }

    fallback() external payable {
        _delegate();
    }

    receive() external payable {
        _delegate();
    }

    function _delegate() private {
        address implementation;
        assembly ("memory-safe") {
            implementation := sload(IMPLEMENTATION_SLOT)
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), implementation, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    function _revert(bytes memory result) private pure {
        assembly ("memory-safe") {
            revert(add(result, 32), mload(result))
        }
    }
}

contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "ETH_SEND");
    }
}

contract MockV3Pool {
    address public immutable token0;
    address public immutable token1;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function approveToken(address asset, address spender, uint256 amount) external {
        require(IERC20(asset).approve(spender, amount), "APPROVE");
    }

    function sendToken(address asset, address recipient, uint256 amount) external {
        require(IERC20(asset).transfer(recipient, amount), "SEND_TOKEN");
    }

    function slot0() external pure returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (uint160(1 << 96), 0, 0, 0, 0, 0, true);
    }

    function swap(address, bool, int256, uint160, bytes calldata) external pure returns (int256, int256) {
        revert("NO_INITIAL_BUY");
    }
}

contract MockPositionManager {
    struct StoredPosition {
        address owner;
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 owed0;
        uint128 owed1;
    }

    uint256 private _nextPositionId = 1;
    mapping(uint256 => StoredPosition) private _positions;
    mapping(bytes32 => address) private _pools;

    function factory() external view returns (address) {
        return address(this);
    }

    function createAndInitializePoolIfNecessary(address token0, address token1, uint24 fee, uint160)
        external
        returns (address pool)
    {
        bytes32 key = keccak256(abi.encode(token0, token1, fee));
        pool = _pools[key];
        if (pool == address(0)) {
            pool = address(new MockV3Pool(token0, token1));
            _pools[key] = pool;
        }
    }

    function mint(INonfungiblePositionManager.MintParams calldata params)
        external
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        address pool = _pools[keccak256(abi.encode(params.token0, params.token1, params.fee))];
        require(pool != address(0), "NO_POOL");
        if (params.amount0Desired != 0) {
            require(IERC20(params.token0).transferFrom(msg.sender, pool, params.amount0Desired), "TRANSFER0");
        }
        if (params.amount1Desired != 0) {
            require(IERC20(params.token1).transferFrom(msg.sender, pool, params.amount1Desired), "TRANSFER1");
        }

        tokenId = _nextPositionId++;
        amount0 = params.amount0Desired;
        amount1 = params.amount1Desired;
        uint256 supplied = amount0 + amount1;
        require(supplied <= type(uint128).max, "LIQUIDITY");
        liquidity = uint128(supplied);
        _positions[tokenId] = StoredPosition({
            owner: params.recipient,
            token0: params.token0,
            token1: params.token1,
            fee: params.fee,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidity: liquidity,
            owed0: 0,
            owed1: 0
        });
    }

    function accrueFrom(uint256 tokenId, address payer, uint128 amount0, uint128 amount1) external {
        StoredPosition storage position = _positions[tokenId];
        if (amount0 != 0) {
            require(IERC20(position.token0).transferFrom(payer, address(this), amount0), "FEE0");
            position.owed0 += amount0;
        }
        if (amount1 != 0) {
            require(IERC20(position.token1).transferFrom(payer, address(this), amount1), "FEE1");
            position.owed1 += amount1;
        }
    }

    function collect(INonfungiblePositionManager.CollectParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        StoredPosition storage position = _positions[params.tokenId];
        amount0 = position.owed0 < params.amount0Max ? position.owed0 : params.amount0Max;
        amount1 = position.owed1 < params.amount1Max ? position.owed1 : params.amount1Max;
        position.owed0 -= uint128(amount0);
        position.owed1 -= uint128(amount1);
        if (amount0 != 0) require(IERC20(position.token0).transfer(params.recipient, amount0), "COLLECT0");
        if (amount1 != 0) require(IERC20(position.token1).transfer(params.recipient, amount1), "COLLECT1");
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return _positions[tokenId].owner;
    }

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        StoredPosition storage position = _positions[tokenId];
        return (
            0,
            address(0),
            position.token0,
            position.token1,
            position.fee,
            position.tickLower,
            position.tickUpper,
            position.liquidity,
            0,
            0,
            position.owed0,
            position.owed1
        );
    }
}

contract NoxaFactoryIntegrationTest {
    VmIntegration private constant vm = VmIntegration(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 private constant SUPPLY = 1_000_000 ether;
    address private constant DEV_WALLET = address(0xD3E);
    address private constant PROTOCOL_RECIPIENT = address(0x7EA5);
    address private constant BURNER_RECIPIENT = address(0xB012);
    address private constant CLAIM_RECIPIENT = address(0xCA11);
    address private constant SPLIT_RECIPIENT_A = address(0xA700);
    address private constant SPLIT_RECIPIENT_B = address(0xB700);

    MockWETH private weth;
    MockPositionManager private positionManager;
    FeeRouter private feeRouter;
    LauncherLocker private locker;
    LaunchFactory private factory;
    NoxaCTOFund private ctoFund;

    receive() external payable {}

    function setUp() public {
        vm.deal(address(this), 100 ether);
        weth = new MockWETH();
        positionManager = new MockPositionManager();
        feeRouter = new FeeRouter();
        feeRouter.setFeeConfig(PROTOCOL_RECIPIENT, BURNER_RECIPIENT, 3_333, 3_333, 3_334);
        locker = new LauncherLocker(payable(address(feeRouter)));
        feeRouter.setLocker(address(locker));

        factory = new LaunchFactory(address(locker), 0, true);
        locker.setFactory(address(factory));

        NoxaCTOFund implementation = new NoxaCTOFund();
        IntegrationProxy proxy = new IntegrationProxy(
            address(implementation), abi.encodeCall(NoxaCTOFund.initialize, (address(factory), address(this)))
        );
        ctoFund = NoxaCTOFund(address(proxy));
        factory.setCTOFund(address(ctoFund));

        factory.addLaunchConfig(
            LauncherTypes.LaunchConfig({
                pairToken: address(weth),
                dexId: 0,
                initialTick: 0,
                supply: SUPPLY,
                maxWalletBps: 100,
                maxTxBps: 100,
                restrictionBlocks: 100,
                buyPairHopFee: 0,
                enabled: true,
                permissioned: false
            })
        );
        factory.addDexConfig(
            LauncherTypes.DexConfig({
                dexFactory: address(positionManager),
                positionManager: address(positionManager),
                router: address(0),
                poolFee: 3_000,
                tickSpacing: 60,
                enabled: true
            })
        );
    }

    function testLaunchWiresSnapshotElectionAndCloneVault() public {
        (address token,) = _launch();
        LauncherTypes.LaunchedToken memory launched = factory.getLaunchedToken(token);
        address vault = factory.ctoVaultOf(token);

        _assertEq(launched.feeWallet, DEV_WALLET, "legacy feeWallet changed");
        _assertEq(locker.feeWalletOf(token), vault, "locker not routed to vault");
        _assertEq(ctoFund.leader(token), DEV_WALLET, "initial leader");
        _assertEq(CTOFeeVault(payable(vault)).token(), token, "vault token");
        _assertEq(CTOFeeVault(payable(vault)).pairToken(), address(weth), "vault pair");
        _assertEq(CTOFeeVault(payable(vault)).ctoFund(), address(ctoFund), "vault fund");
        _assertEq(CTOFeeVault(payable(vault)).factory(), address(factory), "vault factory");
        _assertTrue(vault.code.length < 100, "vault is not a minimal clone");

        LaunchToken launchToken = LaunchToken(token);
        _assertTrue(launchToken.votingExcluded(launched.pool), "pool can vote");
        _assertTrue(launchToken.votingExcluded(vault), "vault can vote");
        _assertTrue(launchToken.votingExcluded(address(feeRouter)), "router can vote");
        _assertTrue(launchToken.votingExcluded(PROTOCOL_RECIPIENT), "protocol can vote");
        _assertTrue(launchToken.votingExcluded(BURNER_RECIPIENT), "burner can vote");
        _assertTrue(launchToken.restrictionExempt(vault), "vault restriction");
        _assertTrue(launchToken.feeSenderExempt(vault), "vault fee sender");
        _assertEq(launchToken.feeDepositSource(vault), address(feeRouter), "vault deposit source");
        _assertTrue(launchToken.restrictionExempt(address(feeRouter)), "router restriction");
        _assertTrue(launchToken.restrictionExempt(PROTOCOL_RECIPIENT), "protocol restriction");
        _assertTrue(launchToken.restrictionExempt(BURNER_RECIPIENT), "burner restriction");
        _assertEq(launchToken.balanceOf(launched.pool), SUPPLY, "pool inventory");
    }

    function testPermissionlessFeesReachVaultAndDefaultLeaderCanClaim() public {
        (address token, uint256 positionId) = _launch();
        LauncherTypes.LaunchedToken memory launched = factory.getLaunchedToken(token);
        address vault = factory.ctoVaultOf(token);

        uint128 tokenFees = uint128(1_000 ether);
        uint128 pairFees = uint128(10 ether);
        weth.deposit{value: pairFees}();
        require(weth.transfer(launched.pool, pairFees), "PAIR_TO_POOL");

        MockV3Pool(launched.pool).approveToken(token, address(positionManager), tokenFees);
        MockV3Pool(launched.pool).approveToken(address(weth), address(positionManager), pairFees);
        (uint128 amount0, uint128 amount1) = launched.isToken0 ? (tokenFees, pairFees) : (pairFees, tokenFees);
        positionManager.accrueFrom(positionId, launched.pool, amount0, amount1);

        vm.prank(address(0xB0B));
        locker.claimFees(token);

        uint256 protocolToken = (uint256(tokenFees) * 3_333) / 10_000;
        uint256 burnerToken = (uint256(tokenFees) * 3_333) / 10_000;
        uint256 leaderToken = uint256(tokenFees) - protocolToken - burnerToken;
        uint256 protocolPair = (uint256(pairFees) * 3_333) / 10_000;
        uint256 burnerPair = (uint256(pairFees) * 3_333) / 10_000;
        uint256 leaderPair = uint256(pairFees) - protocolPair - burnerPair;

        _assertEq(LaunchToken(token).balanceOf(PROTOCOL_RECIPIENT), protocolToken, "protocol token split");
        _assertEq(LaunchToken(token).balanceOf(BURNER_RECIPIENT), burnerToken, "burner token split");
        _assertEq(LaunchToken(token).balanceOf(vault), leaderToken, "vault token split");
        _assertEq(LaunchToken(token).votingExcludedSupply(), SUPPLY, "fee inventory became circulating");
        _assertEq(weth.balanceOf(PROTOCOL_RECIPIENT), protocolPair, "protocol WETH split");
        _assertEq(weth.balanceOf(BURNER_RECIPIENT), burnerPair, "burner WETH split");
        _assertEq(weth.balanceOf(vault), leaderPair, "vault WETH split");
        _assertEq(PROTOCOL_RECIPIENT.balance, 0, "protocol received native");
        _assertEq(BURNER_RECIPIENT.balance, 0, "burner received native");
        _assertEq(vault.balance, 0, "vault received native");

        vm.prank(DEV_WALLET);
        ctoFund.claimTo(token, CLAIM_RECIPIENT);

        _assertEq(LaunchToken(token).balanceOf(CLAIM_RECIPIENT), leaderToken, "claimed token");
        _assertEq(LaunchToken(token).votingExcludedSupply(), SUPPLY - leaderToken, "claimed token stayed nonvoting");
        _assertEq(weth.balanceOf(CLAIM_RECIPIENT), leaderPair, "claimed WETH");
        _assertEq(CLAIM_RECIPIENT.balance, 0, "claim unexpectedly unwrapped WETH");
        _assertEq(LaunchToken(token).balanceOf(vault), 0, "vault token remains");
        _assertEq(weth.balanceOf(vault), 0, "vault WETH remains");
    }

    function testLaunchFeeIsWrappedAndSentToBurnerAsWeth() public {
        uint256 fee = 0.5 ether;
        factory.setLaunchFee(fee);

        uint256 burnerNativeBefore = BURNER_RECIPIENT.balance;
        (address token,) = _launchWithValue(fee);
        address vault = factory.ctoVaultOf(token);

        _assertEq(weth.balanceOf(BURNER_RECIPIENT), fee, "burner missing wrapped launch fee");
        _assertEq(weth.balanceOf(PROTOCOL_RECIPIENT), 0, "launch fee entered protocol split");
        _assertEq(weth.balanceOf(vault), 0, "launch fee entered CTO split");
        _assertEq(BURNER_RECIPIENT.balance, burnerNativeBefore, "burner received native launch fee");
        _assertEq(address(factory).balance, 0, "factory retained native launch fee");
        _assertEq(address(feeRouter).balance, 0, "router retained native launch fee");
    }

    function testFeeSplitterCanSubdivideAndReconfigureFutureTokenAndWethFees() public {
        address[] memory recipients = new address[](2);
        recipients[0] = SPLIT_RECIPIENT_A;
        recipients[1] = SPLIT_RECIPIENT_B;
        uint16[] memory shares = new uint16[](2);
        shares[0] = 6_000;
        shares[1] = 4_000;
        FeeSplitter splitter = new FeeSplitter(address(feeRouter), address(this), recipients, shares);

        feeRouter.setFeeConfig(address(splitter), BURNER_RECIPIENT, 3_333, 3_333, 3_334);
        (address token, uint256 positionId) = _launch();
        LauncherTypes.LaunchedToken memory launched = factory.getLaunchedToken(token);

        _assertTrue(LaunchToken(token).restrictionExempt(address(splitter)), "splitter restriction");
        _assertTrue(LaunchToken(token).votingExcluded(address(splitter)), "splitter can vote");
        _assertTrue(!LaunchToken(token).feeSenderExempt(address(splitter)), "splitter got fee-sender privilege");
        _assertEq(LaunchToken(token).feeDepositSource(address(splitter)), address(0), "splitter got deposit privilege");

        uint128 tokenFees = uint128(900 ether);
        uint128 pairFees = uint128(9 ether);
        weth.deposit{value: pairFees}();
        require(weth.transfer(launched.pool, pairFees), "PAIR_TO_POOL");
        MockV3Pool(launched.pool).approveToken(token, address(positionManager), tokenFees);
        MockV3Pool(launched.pool).approveToken(address(weth), address(positionManager), pairFees);
        (uint128 amount0, uint128 amount1) = launched.isToken0 ? (tokenFees, pairFees) : (pairFees, tokenFees);
        positionManager.accrueFrom(positionId, launched.pool, amount0, amount1);

        locker.claimFees(token);

        uint256 protocolToken = (uint256(tokenFees) * 3_333) / 10_000;
        uint256 protocolPair = (uint256(pairFees) * 3_333) / 10_000;
        _assertEq(LaunchToken(token).balanceOf(address(splitter)), protocolToken, "splitter token receipt");
        _assertEq(weth.balanceOf(address(splitter)), protocolPair, "splitter WETH receipt");
        _assertEq(splitter.epochDeposited(1, token), protocolToken, "epoch one token deposit");
        _assertEq(splitter.epochDeposited(1, address(weth)), protocolPair, "epoch one WETH deposit");
        _assertEq(LaunchToken(token).votingExcludedSupply(), SUPPLY, "splitter receipt entered circulation");

        uint256 oldATokenEntitlement = splitter.releasable(1, token, SPLIT_RECIPIENT_A);
        uint256 oldBTokenEntitlement = splitter.releasable(1, token, SPLIT_RECIPIENT_B);
        uint256 oldAPairEntitlement = splitter.releasable(1, address(weth), SPLIT_RECIPIENT_A);
        uint256 oldBPairEntitlement = splitter.releasable(1, address(weth), SPLIT_RECIPIENT_B);

        // These fees accrue in the LP position before the owner changes the
        // split, but FeeSplitter assigns them when FeeRouter later deposits.
        uint128 nextTokenFees = uint128(600 ether);
        uint128 nextPairFees = uint128(6 ether);
        weth.deposit{value: nextPairFees}();
        require(weth.transfer(launched.pool, nextPairFees), "NEXT_PAIR_TO_POOL");
        MockV3Pool(launched.pool).approveToken(token, address(positionManager), nextTokenFees);
        MockV3Pool(launched.pool).approveToken(address(weth), address(positionManager), nextPairFees);
        (amount0, amount1) = launched.isToken0 ? (nextTokenFees, nextPairFees) : (nextPairFees, nextTokenFees);
        positionManager.accrueFrom(positionId, launched.pool, amount0, amount1);

        shares[0] = 2_500;
        shares[1] = 7_500;
        splitter.setConfig(recipients, shares);

        _assertEq(splitter.currentEpoch(), 2, "new splitter epoch not opened");
        _assertTrue(splitter.epochClosed(1), "old splitter epoch not closed");
        _assertEq(
            splitter.releasable(1, token, SPLIT_RECIPIENT_A), oldATokenEntitlement, "old A token entitlement changed"
        );
        _assertEq(
            splitter.releasable(1, token, SPLIT_RECIPIENT_B), oldBTokenEntitlement, "old B token entitlement changed"
        );
        _assertEq(
            splitter.releasable(1, address(weth), SPLIT_RECIPIENT_A),
            oldAPairEntitlement,
            "old A WETH entitlement changed"
        );
        _assertEq(
            splitter.releasable(1, address(weth), SPLIT_RECIPIENT_B),
            oldBPairEntitlement,
            "old B WETH entitlement changed"
        );

        locker.claimFees(token);

        uint256 nextProtocolToken = (uint256(nextTokenFees) * 3_333) / 10_000;
        uint256 nextProtocolPair = (uint256(nextPairFees) * 3_333) / 10_000;
        _assertEq(splitter.epochDeposited(1, token), protocolToken, "old token epoch changed");
        _assertEq(splitter.epochDeposited(1, address(weth)), protocolPair, "old WETH epoch changed");
        _assertEq(splitter.epochDeposited(2, token), nextProtocolToken, "future token deposit missed new epoch");
        _assertEq(splitter.epochDeposited(2, address(weth)), nextProtocolPair, "future WETH deposit missed new epoch");

        vm.prank(SPLIT_RECIPIENT_A);
        splitter.release(1, token);
        vm.prank(SPLIT_RECIPIENT_B);
        splitter.release(1, token);
        vm.prank(SPLIT_RECIPIENT_A);
        splitter.release(1, address(weth));
        vm.prank(SPLIT_RECIPIENT_B);
        splitter.release(1, address(weth));
        vm.prank(SPLIT_RECIPIENT_A);
        splitter.release(2, token);
        vm.prank(SPLIT_RECIPIENT_B);
        splitter.release(2, token);
        vm.prank(SPLIT_RECIPIENT_A);
        splitter.release(2, address(weth));
        vm.prank(SPLIT_RECIPIENT_B);
        splitter.release(2, address(weth));

        uint256 recipientAToken = oldATokenEntitlement + (nextProtocolToken * 2_500) / 10_000;
        uint256 recipientBToken = oldBTokenEntitlement + (nextProtocolToken * 7_500) / 10_000;
        uint256 recipientAPair = oldAPairEntitlement + (nextProtocolPair * 2_500) / 10_000;
        uint256 recipientBPair = oldBPairEntitlement + (nextProtocolPair * 7_500) / 10_000;
        _assertEq(LaunchToken(token).balanceOf(SPLIT_RECIPIENT_A), recipientAToken, "recipient A token");
        _assertEq(LaunchToken(token).balanceOf(SPLIT_RECIPIENT_B), recipientBToken, "recipient B token");
        _assertEq(weth.balanceOf(SPLIT_RECIPIENT_A), recipientAPair, "recipient A WETH");
        _assertEq(weth.balanceOf(SPLIT_RECIPIENT_B), recipientBPair, "recipient B WETH");
        _assertEq(splitter.totalRecorded(token), protocolToken + nextProtocolToken, "recorded token total");
        _assertEq(splitter.totalReleased(token), protocolToken + nextProtocolToken, "released token total");
        _assertEq(splitter.totalRecorded(address(weth)), protocolPair + nextProtocolPair, "recorded WETH total");
        _assertEq(splitter.totalReleased(address(weth)), protocolPair + nextProtocolPair, "released WETH total");
        _assertEq(
            LaunchToken(token).votingExcludedSupply(),
            SUPPLY - protocolToken - nextProtocolToken,
            "claimed protocol fees stayed excluded"
        );
        _assertTrue(!LaunchToken(token).votingExcluded(SPLIT_RECIPIENT_A), "recipient A unexpectedly nonvoting");
        _assertTrue(!LaunchToken(token).votingExcluded(SPLIT_RECIPIENT_B), "recipient B unexpectedly nonvoting");
    }

    function testFeeSplitterClaimsRespectMaxWalletAndDirectTransfersRemainUnallocated() public {
        address[] memory recipients = new address[](1);
        recipients[0] = SPLIT_RECIPIENT_A;
        uint16[] memory shares = new uint16[](1);
        shares[0] = 10_000;
        FeeSplitter splitter = new FeeSplitter(address(feeRouter), address(this), recipients, shares);

        feeRouter.setFeeConfig(address(splitter), BURNER_RECIPIENT, 10_000, 0, 0);
        (address token, uint256 positionId) = _launch();
        LauncherTypes.LaunchedToken memory launched = factory.getLaunchedToken(token);
        uint128 tokenFees = uint128(20_000 ether);
        MockV3Pool(launched.pool).approveToken(token, address(positionManager), tokenFees);
        (uint128 amount0, uint128 amount1) = launched.isToken0 ? (tokenFees, uint128(0)) : (uint128(0), tokenFees);
        positionManager.accrueFrom(positionId, launched.pool, amount0, amount1);

        // Upstream collection succeeds because the splitter itself is exempt.
        locker.claimFees(token);
        _assertEq(LaunchToken(token).balanceOf(address(splitter)), tokenFees, "splitter missing restricted fees");
        _assertEq(splitter.epochDeposited(1, token), tokenFees, "splitter deposit not recorded");
        _assertTrue(!LaunchToken(token).feeSenderExempt(address(splitter)), "splitter got fee-sender privilege");
        _assertEq(LaunchToken(token).feeDepositSource(address(splitter)), address(0), "splitter got deposit privilege");

        MockV3Pool(launched.pool).sendToken(token, CLAIM_RECIPIENT, 1 ether);
        vm.prank(CLAIM_RECIPIENT);
        LaunchToken(token).transfer(address(splitter), 1 ether);
        _assertEq(splitter.epochDeposited(1, token), tokenFees, "direct transfer was allocated");
        _assertEq(splitter.unallocatedBalance(token), 1 ether, "direct transfer not reported as unallocated");
        _assertEq(splitter.releasable(1, token, SPLIT_RECIPIENT_A), tokenFees, "direct transfer changed entitlement");

        vm.expectRevert(LaunchToken.MaxWalletExceeded.selector);
        vm.prank(SPLIT_RECIPIENT_A);
        splitter.release(1, token);

        _assertEq(splitter.releasable(1, token, SPLIT_RECIPIENT_A), tokenFees, "reverted claim changed entitlement");
        vm.roll(LaunchToken(token).restrictionsEndBlock());
        vm.prank(SPLIT_RECIPIENT_A);
        splitter.release(1, token);

        _assertEq(LaunchToken(token).balanceOf(SPLIT_RECIPIENT_A), tokenFees, "post-restriction claim failed");
        _assertEq(LaunchToken(token).balanceOf(address(splitter)), 1 ether, "claim consumed direct transfer");
        _assertEq(splitter.unallocatedBalance(token), 1 ether, "unallocated transfer changed after claim");
    }

    function testFeeRouterAdminCanAtomicallyChangeRecipientsAndShares() public {
        _assertEq(feeRouter.protocolRecipient(), PROTOCOL_RECIPIENT, "wrong default protocol recipient");
        _assertEq(feeRouter.burnerRecipient(), BURNER_RECIPIENT, "wrong default burner recipient");
        _assertEq(feeRouter.protocolShareBps(), 3_333, "wrong default protocol share");
        _assertEq(feeRouter.burnerShareBps(), 3_333, "wrong default burner share");
        _assertEq(feeRouter.ctoShareBps(), 3_334, "wrong default CTO share");

        address newProtocol = address(0x7001);
        address newBurner = address(0xB001);
        feeRouter.setFeeConfig(newProtocol, newBurner, 2_000, 3_000, 5_000);

        _assertEq(feeRouter.protocolRecipient(), newProtocol, "protocol recipient not updated");
        _assertEq(feeRouter.burnerRecipient(), newBurner, "burner recipient not updated");
        _assertEq(feeRouter.protocolShareBps(), 2_000, "protocol share not updated");
        _assertEq(feeRouter.burnerShareBps(), 3_000, "burner share not updated");
        _assertEq(feeRouter.ctoShareBps(), 5_000, "CTO share not updated");

        (bool badSum,) = address(feeRouter)
            .call(
                abi.encodeCall(
                    FeeRouter.setFeeConfig, (newProtocol, newBurner, uint16(3_333), uint16(3_333), uint16(3_333))
                )
            );
        _assertTrue(!badSum, "invalid split accepted");
        _assertEq(feeRouter.ctoShareBps(), 5_000, "invalid split partially applied");

        vm.prank(address(0xB0B));
        (bool unauthorized,) = address(feeRouter)
            .call(
                abi.encodeCall(
                    FeeRouter.setFeeConfig, (newProtocol, newBurner, uint16(3_333), uint16(3_333), uint16(3_334))
                )
            );
        _assertTrue(!unauthorized, "non-owner changed fee config");
    }

    function testOneTimeWiringCannotBeReplaced() public {
        (bool routerOk,) = address(feeRouter).call(abi.encodeCall(FeeRouter.setLocker, (address(0x1234))));
        (bool lockerOk,) = address(locker).call(abi.encodeCall(LauncherLocker.setFactory, (address(0x1234))));
        (bool ctoOk,) = address(factory).call(abi.encodeCall(LaunchFactory.setCTOFund, (address(ctoFund))));
        _assertTrue(!routerOk && !lockerOk && !ctoOk, "one-time wiring changed");
    }

    function testCurrentFeeRecipientExemptionsCanBePermissionlesslySynced() public {
        (address token,) = _launch();
        LauncherTypes.LaunchedToken memory launched = factory.getLaunchedToken(token);
        address newProtocol = address(0x7EA50002);
        address newBurner = address(0xB0120002);
        MockV3Pool(launched.pool).sendToken(token, newProtocol, 100 ether);
        MockV3Pool(launched.pool).sendToken(token, newBurner, 200 ether);
        for (uint160 i = 0; i < 6; ++i) {
            MockV3Pool(launched.pool).sendToken(token, address(uint160(0xA000) + i), 10_000 ether);
        }
        _assertEq(LaunchToken(token).votingExcludedSupply(), SUPPLY - 60_300 ether, "pre-sync aggregate");
        feeRouter.setFeeConfig(newProtocol, newBurner, 3_333, 3_333, 3_334);
        _assertTrue(!LaunchToken(token).restrictionExempt(newProtocol), "protocol unexpectedly exempt");
        _assertTrue(!LaunchToken(token).restrictionExempt(newBurner), "burner unexpectedly exempt");

        vm.prank(address(0xB0B));
        factory.syncFeeRecipientExemptions(token);
        _assertTrue(LaunchToken(token).restrictionExempt(newProtocol), "protocol sync failed");
        _assertTrue(LaunchToken(token).restrictionExempt(newBurner), "burner sync failed");
        _assertTrue(!LaunchToken(token).votingExcluded(newProtocol), "sync changed protocol voting boundary");
        _assertTrue(!LaunchToken(token).votingExcluded(newBurner), "sync changed burner voting boundary");
        _assertEq(LaunchToken(token).votingExcludedSupply(), SUPPLY - 60_300 ether, "sync changed denominator");

        // Voting exclusion is synchronized atomically with the next exact snapshot.
        ctoFund.openRound(token);
        _assertTrue(LaunchToken(token).votingExcluded(newProtocol), "snapshot left protocol voting");
        _assertTrue(LaunchToken(token).votingExcluded(newBurner), "snapshot left burner voting");
        _assertEq(
            LaunchToken(token).votingExcludedSupplyAt(1),
            SUPPLY - 60_000 ether,
            "snapshot included fixed-recipient inventory"
        );
    }

    function testRecipientRotationCannotBlockRestrictedFeeClaim() public {
        (address token, uint256 positionId) = _launch();
        LauncherTypes.LaunchedToken memory launched = factory.getLaunchedToken(token);
        address newProtocol = address(0x7002);
        address newBurner = address(0xB002);
        feeRouter.setFeeConfig(newProtocol, newBurner, 3_333, 3_333, 3_334);

        uint128 tokenFees = uint128(50_000 ether);
        MockV3Pool(launched.pool).approveToken(token, address(positionManager), tokenFees);
        (uint128 amount0, uint128 amount1) = launched.isToken0 ? (tokenFees, uint128(0)) : (uint128(0), tokenFees);
        positionManager.accrueFrom(positionId, launched.pool, amount0, amount1);

        // Each fixed share exceeds maxWalletAmount. claimFees must synchronize
        // the new recipients before FeeRouter transfers to them.
        locker.claimFees(token);

        _assertTrue(LaunchToken(token).restrictionExempt(newProtocol), "rotated protocol not exempt");
        _assertTrue(LaunchToken(token).restrictionExempt(newBurner), "rotated burner not exempt");
        _assertTrue(
            LaunchToken(token).balanceOf(newProtocol) > LaunchToken(token).maxWalletAmount(), "protocol under cap"
        );
        _assertTrue(LaunchToken(token).balanceOf(newBurner) > LaunchToken(token).maxWalletAmount(), "burner under cap");
    }

    function testVaultTokenClaimBypassesOnlyRecipientMaxWalletCheck() public {
        (address token, uint256 positionId) = _launch();
        LauncherTypes.LaunchedToken memory launched = factory.getLaunchedToken(token);
        address vault = factory.ctoVaultOf(token);
        uint256 cap = LaunchToken(token).maxWalletAmount();

        MockV3Pool(launched.pool).sendToken(token, CLAIM_RECIPIENT, cap);

        vm.expectRevert(LaunchToken.InvalidFeeVaultDeposit.selector);
        vm.prank(CLAIM_RECIPIENT);
        LaunchToken(token).transfer(vault, 1 ether);

        uint128 tokenFees = uint128(100 ether);
        MockV3Pool(launched.pool).approveToken(token, address(positionManager), tokenFees);
        (uint128 amount0, uint128 amount1) = launched.isToken0 ? (tokenFees, uint128(0)) : (uint128(0), tokenFees);
        positionManager.accrueFrom(positionId, launched.pool, amount0, amount1);
        locker.claimFees(token);

        uint256 protocolShare = (uint256(tokenFees) * 3_333) / 10_000;
        uint256 burnerShare = (uint256(tokenFees) * 3_333) / 10_000;
        uint256 vaultShare = uint256(tokenFees) - protocolShare - burnerShare;
        _assertEq(LaunchToken(token).balanceOf(vault), vaultShare, "canonical fee path missed vault");

        vm.prank(DEV_WALLET);
        ctoFund.claimTo(token, CLAIM_RECIPIENT);
        _assertEq(LaunchToken(token).balanceOf(CLAIM_RECIPIENT), cap + vaultShare, "vault claim stayed capped");
    }

    function _launch() private returns (address token, uint256 positionId) {
        return _launchWithValue(0);
    }

    function _launchWithValue(uint256 value) private returns (address token, uint256 positionId) {
        LauncherTypes.LaunchParams memory params = LauncherTypes.LaunchParams({
            name: "Noxa CTO Test",
            symbol: "NCTO",
            logo: "ipfs://logo",
            description: "integration test",
            socials: LauncherTypes.Socials({telegram: "", twitter: "", discord: "", website: "", farcaster: ""}),
            devWallet: DEV_WALLET
        });
        return factory.launchToken{value: value}(params, 0, 0, keccak256(abi.encode(block.number, address(this))));
    }

    function _assertEq(address actual, address expected, string memory reason) private pure {
        require(actual == expected, reason);
    }

    function _assertEq(uint256 actual, uint256 expected, string memory reason) private pure {
        require(actual == expected, reason);
    }

    function _assertTrue(bool condition, string memory reason) private pure {
        require(condition, reason);
    }
}
