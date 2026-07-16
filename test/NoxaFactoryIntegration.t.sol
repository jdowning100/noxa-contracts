// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LaunchFactory} from "../LaunchFactory_flat.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {LauncherLocker} from "../src/LauncherLocker.sol";
import {LauncherTypes} from "../src/LauncherTypes.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {NoxaCTOFund} from "../src/NoxaCTOFund.sol";
import {CTOFeeVault} from "../src/CTOFeeVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INonfungiblePositionManager} from "../src/interfaces/IUniswapV3.sol";

interface VmIntegration {
    function deal(address account, uint256 newBalance) external;
    function expectRevert(bytes4 revertData) external;
    function prank(address caller) external;
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
    address private constant TREASURY = address(0x7EA5);
    address private constant CLAIM_RECIPIENT = address(0xCA11);

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
        feeRouter = new FeeRouter(address(weth), TREASURY, 2_000, 3_000);
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
        _assertTrue(launchToken.votingExcluded(TREASURY), "treasury can vote");
        _assertTrue(launchToken.restrictionExempt(vault), "vault restriction");
        _assertTrue(launchToken.feeSenderExempt(vault), "vault fee sender");
        _assertEq(launchToken.feeDepositSource(vault), address(feeRouter), "vault deposit source");
        _assertTrue(launchToken.restrictionExempt(address(feeRouter)), "router restriction");
        _assertTrue(launchToken.restrictionExempt(TREASURY), "treasury restriction");
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

        uint256 protocolToken = (uint256(tokenFees) * 3_000) / 10_000;
        uint256 leaderToken = uint256(tokenFees) - protocolToken;
        uint256 protocolNative = (uint256(pairFees) * 2_000) / 10_000;
        uint256 leaderNative = uint256(pairFees) - protocolNative;

        _assertEq(LaunchToken(token).balanceOf(TREASURY), protocolToken, "protocol token split");
        _assertEq(LaunchToken(token).balanceOf(vault), leaderToken, "vault token split");
        _assertEq(LaunchToken(token).votingExcludedSupply(), SUPPLY, "fee inventory became circulating");
        _assertEq(TREASURY.balance, protocolNative, "protocol native split");
        _assertEq(vault.balance, leaderNative, "vault native split");

        vm.prank(DEV_WALLET);
        ctoFund.claimTo(token, CLAIM_RECIPIENT);

        _assertEq(LaunchToken(token).balanceOf(CLAIM_RECIPIENT), leaderToken, "claimed token");
        _assertEq(LaunchToken(token).votingExcludedSupply(), SUPPLY - leaderToken, "claimed token stayed nonvoting");
        _assertEq(CLAIM_RECIPIENT.balance, leaderNative, "claimed native");
        _assertEq(LaunchToken(token).balanceOf(vault), 0, "vault token remains");
        _assertEq(vault.balance, 0, "vault native remains");
    }

    function testOneTimeWiringCannotBeReplaced() public {
        (bool routerOk,) = address(feeRouter).call(abi.encodeCall(FeeRouter.setLocker, (address(0x1234))));
        (bool lockerOk,) = address(locker).call(abi.encodeCall(LauncherLocker.setFactory, (address(0x1234))));
        (bool ctoOk,) = address(factory).call(abi.encodeCall(LaunchFactory.setCTOFund, (address(ctoFund))));
        _assertTrue(!routerOk && !lockerOk && !ctoOk, "one-time wiring changed");
    }

    function testCurrentTreasuryExemptionCanBePermissionlesslySynced() public {
        (address token,) = _launch();
        LauncherTypes.LaunchedToken memory launched = factory.getLaunchedToken(token);
        address newTreasury = address(0x7EA50002);
        MockV3Pool(launched.pool).sendToken(token, newTreasury, 100 ether);
        for (uint160 i = 0; i < 6; ++i) {
            MockV3Pool(launched.pool).sendToken(token, address(uint160(0xA000) + i), 10_000 ether);
        }
        _assertEq(LaunchToken(token).votingExcludedSupply(), SUPPLY - 60_100 ether, "pre-sync aggregate");
        feeRouter.setTreasury(newTreasury);
        _assertTrue(!LaunchToken(token).restrictionExempt(newTreasury), "treasury unexpectedly exempt");

        vm.prank(address(0xB0B));
        factory.syncFeeTreasuryExemption(token);
        _assertTrue(LaunchToken(token).restrictionExempt(newTreasury), "treasury sync failed");
        _assertTrue(!LaunchToken(token).votingExcluded(newTreasury), "sync changed an active round boundary");
        _assertEq(LaunchToken(token).votingExcludedSupply(), SUPPLY - 60_100 ether, "sync changed denominator");

        // Voting exclusion is synchronized atomically with the next exact snapshot.
        ctoFund.openRound(token);
        _assertTrue(LaunchToken(token).votingExcluded(newTreasury), "snapshot left treasury voting");
        _assertEq(
            LaunchToken(token).votingExcludedSupplyAt(1), SUPPLY - 60_000 ether, "snapshot included treasury inventory"
        );
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

        uint256 vaultShare = uint256(tokenFees) - (uint256(tokenFees) * 3_000) / 10_000;
        _assertEq(LaunchToken(token).balanceOf(vault), vaultShare, "canonical fee path missed vault");

        vm.prank(DEV_WALLET);
        ctoFund.claimTo(token, CLAIM_RECIPIENT);
        _assertEq(LaunchToken(token).balanceOf(CLAIM_RECIPIENT), cap + vaultShare, "vault claim stayed capped");
    }

    function _launch() private returns (address token, uint256 positionId) {
        LauncherTypes.LaunchParams memory params = LauncherTypes.LaunchParams({
            name: "Noxa CTO Test",
            symbol: "NCTO",
            logo: "ipfs://logo",
            description: "integration test",
            socials: LauncherTypes.Socials({telegram: "", twitter: "", discord: "", website: "", farcaster: ""}),
            devWallet: DEV_WALLET
        });
        return factory.launchToken(params, 0, 0, keccak256(abi.encode(block.number, address(this))));
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
