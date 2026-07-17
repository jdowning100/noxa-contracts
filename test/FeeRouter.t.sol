// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FeeRouter} from "../src/FeeRouter.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface VmFeeRouter {
    function expectRevert() external;
    function expectRevert(bytes4 revertData) external;
    function prank(address caller) external;
}

contract MockFeeAsset is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }
}

// A code-bearing contract that is NOT a FeeSplitter: it exposes no
// feeRouter()/currentEpoch() functions, so _splitterBinding's staticcalls revert
// and it must be classified as a plain recipient (paid by raw transfer).
contract PlainRecipient {
// intentionally empty — just receives ERC20 transfers
}

// A lookalike that exposes the splitter interface but reports epoch 0, which
// _splitterBinding must treat as NON-splitter. Its deposit() reverts so that any
// mistaken splitter routing would fail loudly instead of silently mis-accounting.
contract ZeroEpochLookalike {
    address public feeRouter;

    constructor(address router_) {
        feeRouter = router_;
    }

    function currentEpoch() external pure returns (uint256) {
        return 0;
    }

    function deposit(address, uint256) external pure {
        revert("DEPOSIT_SHOULD_NOT_BE_CALLED");
    }
}

contract FeeRouterTest {
    VmFeeRouter private constant vm = VmFeeRouter(address(uint160(uint256(keccak256("hevm cheat code")))));

    address private constant PROTOCOL = address(0x7001);
    address private constant BURNER = address(0xB001);
    address private constant CTO = address(0xC700);
    address private constant STRANGER = address(0xBAD);

    FeeRouter private router;
    MockFeeAsset private launchedToken;
    MockFeeAsset private weth;

    function setUp() public {
        router = new FeeRouter();
        router.setFeeConfig(PROTOCOL, BURNER, 3_333, 3_333, 3_334);
        router.setLocker(address(this));
        launchedToken = new MockFeeAsset("Launch Token", "LAUNCH");
        weth = new MockFeeAsset("Wrapped Ether", "WETH");
    }

    function testDefaultSplitIs3333_3333_3334AndConservesDust() public {
        uint256 amount = 10_001;
        launchedToken.mint(address(router), amount);
        weth.mint(address(router), amount);

        router.distribute(address(launchedToken), address(weth), amount, amount, CTO);

        _assertEq(launchedToken.balanceOf(PROTOCOL), 3_333, "protocol token");
        _assertEq(launchedToken.balanceOf(BURNER), 3_333, "burner token");
        _assertEq(launchedToken.balanceOf(CTO), 3_335, "CTO token");
        _assertEq(weth.balanceOf(PROTOCOL), 3_333, "protocol WETH");
        _assertEq(weth.balanceOf(BURNER), 3_333, "burner WETH");
        _assertEq(weth.balanceOf(CTO), 3_335, "CTO WETH");
        _assertEq(launchedToken.balanceOf(address(router)), 0, "token dust retained");
        _assertEq(weth.balanceOf(address(router)), 0, "WETH dust retained");
        _assertEq(PROTOCOL.balance, 0, "protocol received native");
        _assertEq(BURNER.balance, 0, "burner received native");
        _assertEq(CTO.balance, 0, "CTO received native");
    }

    function testAdminCanAtomicallySetCustomSplitAndRecipients() public {
        address newProtocol = address(0x7002);
        address newBurner = address(0xB002);
        router.setFeeConfig(newProtocol, newBurner, 2_000, 3_000, 5_000);

        launchedToken.mint(address(router), 10_000);
        weth.mint(address(router), 10_000);
        router.distribute(address(launchedToken), address(weth), 10_000, 10_000, CTO);

        _assertEq(launchedToken.balanceOf(newProtocol), 2_000, "custom protocol token");
        _assertEq(launchedToken.balanceOf(newBurner), 3_000, "custom burner token");
        _assertEq(launchedToken.balanceOf(CTO), 5_000, "custom CTO token");
        _assertEq(weth.balanceOf(newProtocol), 2_000, "custom protocol WETH");
        _assertEq(weth.balanceOf(newBurner), 3_000, "custom burner WETH");
        _assertEq(weth.balanceOf(CTO), 5_000, "custom CTO WETH");
    }

    function testInvalidConfigurationRevertsWithoutPartialUpdate() public {
        vm.expectRevert(FeeRouter.InvalidBasisPoints.selector);
        router.setFeeConfig(address(0x7002), address(0xB002), 3_333, 3_333, 3_333);

        _assertEq(router.protocolRecipient(), PROTOCOL, "protocol partially updated");
        _assertEq(router.burnerRecipient(), BURNER, "burner partially updated");
        _assertEq(router.protocolShareBps(), 3_333, "protocol share partially updated");
        _assertEq(router.burnerShareBps(), 3_333, "burner share partially updated");
        _assertEq(router.ctoShareBps(), 3_334, "CTO share partially updated");

        vm.expectRevert(FeeRouter.ZeroAddress.selector);
        router.setFeeConfig(address(0), BURNER, 3_333, 3_333, 3_334);

        vm.expectRevert(FeeRouter.InvalidRecipient.selector);
        router.setFeeConfig(PROTOCOL, PROTOCOL, 3_333, 3_333, 3_334);

        vm.expectRevert(FeeRouter.InvalidRecipient.selector);
        router.setFeeConfig(address(router), BURNER, 3_333, 3_333, 3_334);
    }

    function testOnlyLockerCanDistribute() public {
        vm.expectRevert(FeeRouter.NotLocker.selector);
        vm.prank(STRANGER);
        router.distribute(address(launchedToken), address(weth), 0, 0, CTO);
    }

    function testUnconfiguredRouterAndZeroCtoRecipientRevert() public {
        FeeRouter unconfigured = new FeeRouter();
        unconfigured.setLocker(address(this));

        vm.expectRevert(FeeRouter.NotConfigured.selector);
        unconfigured.distribute(address(launchedToken), address(weth), 0, 0, CTO);

        vm.expectRevert(FeeRouter.ZeroAddress.selector);
        router.distribute(address(launchedToken), address(weth), 0, 0, address(0));
    }

    function testZeroPercentRecipientsReceiveExactlyZero() public {
        launchedToken.mint(address(router), 3);
        weth.mint(address(router), 3);

        router.setFeeConfig(PROTOCOL, BURNER, 0, 10_000, 0);
        router.distribute(address(launchedToken), address(weth), 1, 1, CTO);
        _assertEq(launchedToken.balanceOf(PROTOCOL), 0, "zero protocol token share");
        _assertEq(launchedToken.balanceOf(BURNER), 1, "full burner token share");
        _assertEq(launchedToken.balanceOf(CTO), 0, "zero CTO token share");

        router.setFeeConfig(PROTOCOL, BURNER, 10_000, 0, 0);
        router.distribute(address(launchedToken), address(weth), 1, 1, CTO);
        _assertEq(launchedToken.balanceOf(PROTOCOL), 1, "full protocol token share");
        _assertEq(launchedToken.balanceOf(BURNER), 1, "zero burner token share");
        _assertEq(launchedToken.balanceOf(CTO), 0, "zero CTO token share after protocol split");

        router.setFeeConfig(PROTOCOL, BURNER, 0, 0, 10_000);
        router.distribute(address(launchedToken), address(weth), 1, 1, CTO);
        _assertEq(launchedToken.balanceOf(PROTOCOL), 1, "zero protocol token share after CTO split");
        _assertEq(launchedToken.balanceOf(BURNER), 1, "zero burner token share after CTO split");
        _assertEq(launchedToken.balanceOf(CTO), 1, "full CTO token share");

        _assertEq(weth.balanceOf(PROTOCOL), 1, "protocol WETH boundary");
        _assertEq(weth.balanceOf(BURNER), 1, "burner WETH boundary");
        _assertEq(weth.balanceOf(CTO), 1, "CTO WETH boundary");
    }

    function testSecondAssetFailureRollsBackFirstAssetTransfers() public {
        launchedToken.mint(address(router), 10_000);

        vm.expectRevert();
        router.distribute(address(launchedToken), address(weth), 10_000, 10_000, CTO);

        _assertEq(launchedToken.balanceOf(address(router)), 10_000, "first asset was not rolled back");
        _assertEq(launchedToken.balanceOf(PROTOCOL), 0, "protocol retained reverted transfer");
        _assertEq(launchedToken.balanceOf(BURNER), 0, "burner retained reverted transfer");
        _assertEq(launchedToken.balanceOf(CTO), 0, "CTO retained reverted transfer");
    }

    function testDistributionDoesNotConsumePreexistingRouterDust() public {
        uint256 distribution = 10_000;
        launchedToken.mint(address(router), distribution + 7);
        weth.mint(address(router), distribution + 11);

        router.distribute(address(launchedToken), address(weth), distribution, distribution, CTO);

        _assertEq(launchedToken.balanceOf(address(router)), 7, "token dust consumed");
        _assertEq(weth.balanceOf(address(router)), 11, "WETH dust consumed");
    }

    function testFuzzSplitConservesEveryAsset(uint128 amount, uint16 protocolBpsSeed, uint16 burnerBpsSeed) public {
        uint16 protocolBps = uint16(uint256(protocolBpsSeed) % 10_001);
        uint16 burnerBps = uint16(uint256(burnerBpsSeed) % (10_001 - protocolBps));
        uint16 ctoBps = uint16(10_000 - uint256(protocolBps) - burnerBps);
        router.setFeeConfig(PROTOCOL, BURNER, protocolBps, burnerBps, ctoBps);

        launchedToken.mint(address(router), amount);
        weth.mint(address(router), amount);
        router.distribute(address(launchedToken), address(weth), amount, amount, CTO);

        _assertEq(
            launchedToken.balanceOf(PROTOCOL) + launchedToken.balanceOf(BURNER) + launchedToken.balanceOf(CTO),
            amount,
            "token split not conserved"
        );
        _assertEq(
            weth.balanceOf(PROTOCOL) + weth.balanceOf(BURNER) + weth.balanceOf(CTO), amount, "WETH split not conserved"
        );
        _assertEq(launchedToken.balanceOf(address(router)), 0, "token retained");
        _assertEq(weth.balanceOf(address(router)), 0, "WETH retained");
    }

    // A code-bearing recipient that is NOT a splitter (no interface, or reports
    // epoch 0) must be classified as a plain recipient and paid by raw transfer —
    // deposit() is never called, so the split still lands correctly.
    function testCodeBearingNonSplitterRecipientsArePaidByRawTransfer() public {
        // (a) a contract with no splitter interface at all.
        PlainRecipient plain = new PlainRecipient();
        router.setFeeConfig(address(plain), BURNER, 3_333, 3_333, 3_334);
        require(!router.protocolRecipientIsSplitter(), "plain contract misclassified as splitter");

        launchedToken.mint(address(router), 10_000);
        weth.mint(address(router), 10_000);
        router.distribute(address(launchedToken), address(weth), 10_000, 10_000, CTO);
        _assertEq(launchedToken.balanceOf(address(plain)), 3_333, "plain recipient token via raw transfer");
        _assertEq(weth.balanceOf(address(plain)), 3_333, "plain recipient WETH via raw transfer");

        // (b) a lookalike that reports epoch 0: also a non-splitter. If it were
        // mistaken for a splitter, distribute() would call its reverting deposit().
        ZeroEpochLookalike lookalike = new ZeroEpochLookalike(address(router));
        router.setFeeConfig(address(lookalike), BURNER, 3_333, 3_333, 3_334);
        require(!router.protocolRecipientIsSplitter(), "zero-epoch lookalike misclassified as splitter");

        launchedToken.mint(address(router), 10_000);
        weth.mint(address(router), 10_000);
        router.distribute(address(launchedToken), address(weth), 10_000, 10_000, CTO);
        _assertEq(launchedToken.balanceOf(address(lookalike)), 3_333, "lookalike token via raw transfer");
        _assertEq(weth.balanceOf(address(lookalike)), 3_333, "lookalike WETH via raw transfer");
    }

    function _assertEq(address actual, address expected, string memory reason) private pure {
        require(actual == expected, reason);
    }

    function _assertEq(uint256 actual, uint256 expected, string memory reason) private pure {
        require(actual == expected, reason);
    }
}
