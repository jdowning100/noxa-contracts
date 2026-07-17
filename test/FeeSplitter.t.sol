// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";

interface VmFeeSplitter {
    function expectRevert() external;
    function expectRevert(bytes4 revertData) external;
    function expectRevert(bytes calldata revertData) external;
    function prank(address caller) external;
}

contract MockSplitAsset is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }
}

contract FailingSplitAsset is ERC20 {
    bool public transfersBlocked;

    constructor() ERC20("Failing Token", "FAIL") {}

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }

    function setTransfersBlocked(bool blocked) external {
        transfersBlocked = blocked;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (transfersBlocked && from != address(0)) revert("TRANSFER_BLOCKED");
        super._update(from, to, value);
    }
}

contract TaxedSplitAsset is ERC20 {
    constructor() ERC20("Taxed Token", "TAX") {}

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && value != 0) {
            uint256 tax = value / 10;
            super._update(from, to, value - tax);
            if (tax != 0) super._update(from, address(0), tax);
            return;
        }
        super._update(from, to, value);
    }
}

contract FeeSplitterTest {
    VmFeeSplitter private constant vm = VmFeeSplitter(address(uint160(uint256(keccak256("hevm cheat code")))));

    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant CAROL = address(0xCA201);
    address private constant BURNER = address(0xB012);
    address private constant CTO = address(0xC700);
    address private constant STRANGER = address(0xBAD);

    FeeSplitter private splitter;
    MockSplitAsset private token;
    MockSplitAsset private weth;

    function setUp() public {
        (address[] memory recipients, uint16[] memory shares) = _defaultConfig();
        splitter = new FeeSplitter(address(this), address(this), recipients, shares);
        token = new MockSplitAsset("Launch Token", "LAUNCH");
        weth = new MockSplitAsset("Wrapped Ether", "WETH");
    }

    function testOwnerUpdateOnlyChangesFutureDeposits() public {
        (address[] memory firstRecipients, uint16[] memory firstShares) = _halfConfig(ALICE, BOB);
        FeeSplitter adjustable = new FeeSplitter(address(this), address(this), firstRecipients, firstShares);

        token.mint(address(this), 100);
        _deposit(adjustable, token, 100);

        address[] memory secondRecipients = new address[](2);
        secondRecipients[0] = BOB;
        secondRecipients[1] = CAROL;
        uint16[] memory secondShares = new uint16[](2);
        secondShares[0] = 2_500;
        secondShares[1] = 7_500;
        uint256 newEpoch = adjustable.setConfig(secondRecipients, secondShares);

        _assertEq(newEpoch, 2, "wrong returned epoch");
        _assertEq(adjustable.currentEpoch(), 2, "wrong current epoch");
        require(adjustable.epochClosed(1), "old epoch not closed");
        require(!adjustable.epochClosed(2), "new epoch unexpectedly closed");
        _assertEq(adjustable.epochDeposited(1, address(token)), 100, "old deposit changed");
        _assertEq(adjustable.epochShareBps(1, ALICE), 5_000, "old Alice share changed");
        _assertEq(adjustable.epochShareBps(1, BOB), 5_000, "old Bob share changed");
        _assertEq(adjustable.epochShareBps(2, ALICE), 0, "Alice remained in new epoch");
        _assertEq(adjustable.epochShareBps(2, BOB), 2_500, "new Bob share");
        _assertEq(adjustable.epochShareBps(2, CAROL), 7_500, "new Carol share");

        token.mint(address(this), 200);
        _deposit(adjustable, token, 200);
        _assertEq(adjustable.epochDeposited(1, address(token)), 100, "old epoch received new deposit");
        _assertEq(adjustable.epochDeposited(2, address(token)), 200, "new epoch missing deposit");

        _releaseAs(adjustable, 2, token, CAROL);
        _releaseAs(adjustable, 1, token, ALICE);
        _releaseAs(adjustable, 2, token, BOB);
        _releaseAs(adjustable, 1, token, BOB);

        _assertEq(token.balanceOf(ALICE), 50, "historical Alice entitlement");
        _assertEq(token.balanceOf(BOB), 100, "combined Bob entitlement");
        _assertEq(token.balanceOf(CAROL), 150, "future Carol entitlement");
        _assertEq(token.balanceOf(address(adjustable)), 0, "funds left after exact split");
        _assertEq(adjustable.totalRecorded(address(token)), 300, "wrong recorded total");
        _assertEq(adjustable.totalReleased(address(token)), 300, "wrong released total");
        _assertEq(adjustable.accountedBalance(address(token)), 0, "accounting not cleared");
    }

    function testOnlyOwnerCanChangeConfiguration() public {
        (address[] memory recipients, uint16[] memory shares) = _halfConfig(ALICE, BOB);

        vm.expectRevert();
        vm.prank(STRANGER);
        splitter.setConfig(recipients, shares);

        _assertEq(splitter.currentEpoch(), 1, "unauthorized update advanced epoch");
        require(!splitter.epochClosed(1), "unauthorized update closed epoch");

        splitter.setConfig(recipients, shares);
        _assertEq(splitter.currentEpoch(), 2, "owner update failed");
    }

    function testClosedEpochRemainderIsPaidToLastRecipient() public {
        token.mint(address(this), 10_001);
        _deposit(splitter, token, 10_001);

        _releaseAs(splitter, 1, token, ALICE);
        _assertEq(token.balanceOf(ALICE), 3_333, "early Alice claim");
        _assertEq(token.balanceOf(address(splitter)), 6_668, "wrong pre-close balance");

        (address[] memory recipients, uint16[] memory shares) = _defaultConfig();
        splitter.setConfig(recipients, shares);

        _assertEq(splitter.roundingRemainder(1, address(token)), 1, "wrong closed-epoch remainder");
        _assertEq(splitter.releasable(1, address(token), ALICE), 0, "Alice gained a remainder");
        _assertEq(splitter.releasable(1, address(token), BOB), 3_333, "Bob entitlement");
        _assertEq(splitter.releasable(1, address(token), CAROL), 3_335, "Carol entitlement plus remainder");

        _releaseAs(splitter, 1, token, CAROL);
        _releaseAs(splitter, 1, token, BOB);

        _assertEq(token.balanceOf(ALICE), 3_333, "final Alice split");
        _assertEq(token.balanceOf(BOB), 3_333, "final Bob split");
        _assertEq(token.balanceOf(CAROL), 3_335, "final Carol split");
        _assertEq(token.balanceOf(address(splitter)), 0, "closed epoch left rounding dust");
        _assertEq(splitter.totalReleased(address(token)), 10_001, "wrong release total");
    }

    function testUnevenSharesRemainMonotonicAcrossTinyDeposits() public {
        address[] memory recipients = new address[](3);
        recipients[0] = ALICE;
        recipients[1] = BOB;
        recipients[2] = CAROL;
        uint16[] memory shares = new uint16[](3);
        shares[0] = 4_000;
        shares[1] = 2_000;
        shares[2] = 4_000;
        FeeSplitter uneven = new FeeSplitter(address(this), address(this), recipients, shares);

        token.mint(address(this), 5);
        _deposit(uneven, token, 2);
        _assertEq(uneven.releasable(1, address(token), ALICE), 0, "Alice early entitlement");
        _assertEq(uneven.releasable(1, address(token), BOB), 0, "Bob early entitlement");
        _assertEq(uneven.releasable(1, address(token), CAROL), 0, "Carol early entitlement");

        _deposit(uneven, token, 1);
        _releaseAs(uneven, 1, token, CAROL);
        _releaseAs(uneven, 1, token, ALICE);
        _assertEq(token.balanceOf(address(uneven)), 1, "wrong first-period dust");

        _deposit(uneven, token, 2);
        _releaseAs(uneven, 1, token, ALICE);
        _releaseAs(uneven, 1, token, BOB);
        _releaseAs(uneven, 1, token, CAROL);

        _assertEq(token.balanceOf(ALICE), 2, "Alice lifetime split");
        _assertEq(token.balanceOf(BOB), 1, "Bob lifetime split");
        _assertEq(token.balanceOf(CAROL), 2, "Carol lifetime split");
        _assertEq(token.balanceOf(address(uneven)), 0, "tiny deposits left dust");
    }

    function testDirectTransfersRemainUnallocatedAndDoNotChangeClaims() public {
        token.mint(address(this), 130);
        _deposit(splitter, token, 100);
        token.transfer(address(splitter), 30);

        _assertEq(splitter.epochDeposited(1, address(token)), 100, "direct transfer was recorded");
        _assertEq(splitter.totalRecorded(address(token)), 100, "recorded total includes donation");
        _assertEq(splitter.accountedBalance(address(token)), 100, "accounted balance includes donation");
        _assertEq(splitter.unallocatedBalance(address(token)), 30, "wrong unallocated balance");
        _assertEq(splitter.releasable(1, address(token), ALICE), 33, "donation changed Alice claim");

        (address[] memory recipients, uint16[] memory shares) = _defaultConfig();
        splitter.setConfig(recipients, shares);
        _releaseAs(splitter, 1, token, ALICE);
        _releaseAs(splitter, 1, token, BOB);
        _releaseAs(splitter, 1, token, CAROL);

        _assertEq(token.balanceOf(address(splitter)), 30, "unallocated donation was paid");
        _assertEq(splitter.unallocatedBalance(address(token)), 30, "donation accounting changed");
        _assertEq(splitter.accountedBalance(address(token)), 0, "recorded deposit remains accounted");
    }

    function testEachTokenAndEpochHasIndependentAccounting() public {
        token.mint(address(this), 10_000);
        weth.mint(address(this), 20_000);
        _deposit(splitter, token, 10_000);
        _deposit(splitter, weth, 20_000);

        _releaseAs(splitter, 1, token, ALICE);
        _releaseAs(splitter, 1, weth, ALICE);

        _assertEq(token.balanceOf(ALICE), 3_333, "token claim");
        _assertEq(weth.balanceOf(ALICE), 6_666, "WETH claim");
        _assertEq(splitter.releasable(1, address(token), BOB), 3_333, "Bob token accrual");
        _assertEq(splitter.releasable(1, address(weth), BOB), 6_666, "Bob WETH accrual");
        _assertEq(splitter.epochDeposited(1, address(token)), 10_000, "token receipts");
        _assertEq(splitter.epochDeposited(1, address(weth)), 20_000, "WETH receipts");
    }

    function testOnlyConfiguredRecipientCanReleaseItsOwnShare() public {
        token.mint(address(this), 10_000);
        _deposit(splitter, token, 10_000);

        vm.expectRevert(FeeSplitter.NothingToRelease.selector);
        vm.prank(STRANGER);
        splitter.release(1, address(token));

        vm.prank(ALICE);
        splitter.release(1, address(token));
        _assertEq(token.balanceOf(ALICE), 3_333, "recipient release failed");
        _assertEq(token.balanceOf(STRANGER), 0, "stranger received tokens");
    }

    function testOnlyBoundFeeRouterCanRecordDeposits() public {
        token.mint(address(this), 100);
        token.approve(address(splitter), 100);

        vm.expectRevert(FeeSplitter.NotFeeRouter.selector);
        vm.prank(STRANGER);
        splitter.deposit(address(token), 100);

        _assertEq(splitter.epochDeposited(1, address(token)), 0, "unauthorized deposit recorded");
        _assertEq(token.balanceOf(address(splitter)), 0, "unauthorized deposit transferred");

        splitter.deposit(address(token), 100);
        _assertEq(splitter.epochDeposited(1, address(token)), 100, "router deposit not recorded");
        _assertEq(token.balanceOf(address(splitter)), 100, "router deposit not transferred");
    }

    function testDepositRejectsNonBalanceConservingToken() public {
        TaxedSplitAsset taxed = new TaxedSplitAsset();
        taxed.mint(address(this), 100);
        taxed.approve(address(splitter), 100);

        vm.expectRevert(FeeSplitter.UnsupportedToken.selector);
        splitter.deposit(address(taxed), 100);

        _assertEq(taxed.balanceOf(address(this)), 100, "failed deposit charged router");
        _assertEq(taxed.balanceOf(address(splitter)), 0, "failed deposit retained tokens");
        _assertEq(splitter.epochDeposited(1, address(taxed)), 0, "failed deposit recorded");
        _assertEq(splitter.totalRecorded(address(taxed)), 0, "failed deposit changed total");
        _assertEq(splitter.accountedBalance(address(taxed)), 0, "failed deposit changed accounting");
    }

    function testTransferFailureRollsBackReleaseAccounting() public {
        FailingSplitAsset failing = new FailingSplitAsset();
        failing.mint(address(this), 10_000);
        failing.approve(address(splitter), 10_000);
        splitter.deposit(address(failing), 10_000);
        failing.setTransfersBlocked(true);

        vm.expectRevert();
        vm.prank(ALICE);
        splitter.release(1, address(failing));

        _assertEq(splitter.released(1, address(failing), ALICE), 0, "failed transfer recorded release");
        _assertEq(splitter.totalReleased(address(failing)), 0, "failed transfer changed released total");
        _assertEq(splitter.accountedBalance(address(failing)), 10_000, "failed transfer changed accounting");
        _assertEq(failing.balanceOf(address(splitter)), 10_000, "failed transfer lost balance");
    }

    function testFeeRouterRecognizesSplitterAndRecordsExactDeposits() public {
        FeeRouter router = new FeeRouter();
        (address[] memory recipients, uint16[] memory shares) = _defaultConfig();
        FeeSplitter routerSplitter = new FeeSplitter(address(router), address(this), recipients, shares);

        router.setFeeConfig(address(routerSplitter), BURNER, 3_333, 3_333, 3_334);
        router.setLocker(address(this));
        require(router.protocolRecipientIsSplitter(), "router did not recognize splitter");

        token.mint(address(router), 10_000);
        weth.mint(address(router), 10_000);
        router.distribute(address(token), address(weth), 10_000, 10_000, CTO);

        _assertEq(routerSplitter.epochDeposited(1, address(token)), 3_333, "token deposit not recorded");
        _assertEq(routerSplitter.epochDeposited(1, address(weth)), 3_333, "WETH deposit not recorded");
        _assertEq(routerSplitter.accountedBalance(address(token)), 3_333, "token balance not accounted");
        _assertEq(routerSplitter.accountedBalance(address(weth)), 3_333, "WETH balance not accounted");
        _assertEq(token.balanceOf(address(routerSplitter)), 3_333, "splitter token balance");
        _assertEq(weth.balanceOf(address(routerSplitter)), 3_333, "splitter WETH balance");
        _assertEq(token.balanceOf(BURNER), 3_333, "burner token share");
        _assertEq(weth.balanceOf(BURNER), 3_333, "burner WETH share");
        _assertEq(token.balanceOf(CTO), 3_334, "CTO token share");
        _assertEq(weth.balanceOf(CTO), 3_334, "CTO WETH share");
        _assertEq(token.allowance(address(router), address(routerSplitter)), 0, "token approval remains");
        _assertEq(weth.allowance(address(router), address(routerSplitter)), 0, "WETH approval remains");

        routerSplitter.setConfig(recipients, shares);
        _releaseAs(routerSplitter, 1, token, ALICE);
        _releaseAs(routerSplitter, 1, token, BOB);
        _releaseAs(routerSplitter, 1, token, CAROL);
        _releaseAs(routerSplitter, 1, weth, ALICE);
        _releaseAs(routerSplitter, 1, weth, BOB);
        _releaseAs(routerSplitter, 1, weth, CAROL);

        _assertEq(token.balanceOf(ALICE), 1_110, "nested Alice token split");
        _assertEq(token.balanceOf(BOB), 1_110, "nested Bob token split");
        _assertEq(token.balanceOf(CAROL), 1_113, "nested Carol token split");
        _assertEq(weth.balanceOf(ALICE), 1_110, "nested Alice WETH split");
        _assertEq(weth.balanceOf(BOB), 1_110, "nested Bob WETH split");
        _assertEq(weth.balanceOf(CAROL), 1_113, "nested Carol WETH split");
        _assertEq(token.balanceOf(address(routerSplitter)), 0, "nested token dust");
        _assertEq(weth.balanceOf(address(routerSplitter)), 0, "nested WETH dust");
    }

    function testFeeRouterRejectsSplitterAsBurnerRecipient() public {
        FeeRouter router = new FeeRouter();
        (address[] memory recipients, uint16[] memory shares) = _defaultConfig();
        FeeSplitter routerSplitter = new FeeSplitter(address(router), address(this), recipients, shares);

        vm.expectRevert(FeeRouter.InvalidRecipient.selector);
        router.setFeeConfig(ALICE, address(routerSplitter), 3_333, 3_333, 3_334);

        _assertEq(uint256(uint160(router.protocolRecipient())), 0, "failed config changed protocol recipient");
        _assertEq(uint256(uint160(router.burnerRecipient())), 0, "failed config changed burner recipient");

        FeeRouter otherRouter = new FeeRouter();
        FeeSplitter wrongBinding = new FeeSplitter(address(otherRouter), address(this), recipients, shares);
        vm.expectRevert(FeeRouter.InvalidRecipient.selector);
        router.setFeeConfig(address(wrongBinding), BURNER, 3_333, 3_333, 3_334);
    }

    function testInvalidConfigurationsAndArgumentsRevert() public {
        address[] memory noRecipients = new address[](0);
        uint16[] memory noShares = new uint16[](0);
        vm.expectRevert(FeeSplitter.EmptyRecipients.selector);
        new FeeSplitter(address(this), address(this), noRecipients, noShares);

        address[] memory oneRecipient = _singleAddress(ALICE);
        uint16[] memory fullShare = _singleShare(10_000);
        vm.expectRevert(FeeSplitter.ZeroAddress.selector);
        new FeeSplitter(address(0), address(this), oneRecipient, fullShare);

        vm.expectRevert();
        new FeeSplitter(address(this), address(0), oneRecipient, fullShare);

        vm.expectRevert(FeeSplitter.InvalidRecipient.selector);
        new FeeSplitter(address(this), address(this), _singleAddress(address(this)), fullShare);

        address[] memory recipients = new address[](2);
        recipients[0] = ALICE;
        recipients[1] = BOB;
        vm.expectRevert(FeeSplitter.LengthMismatch.selector);
        new FeeSplitter(address(this), address(this), recipients, fullShare);

        uint16[] memory badSum = new uint16[](2);
        badSum[0] = 5_000;
        badSum[1] = 4_999;
        vm.expectRevert(FeeSplitter.InvalidBasisPoints.selector);
        new FeeSplitter(address(this), address(this), recipients, badSum);

        badSum[0] = 6_000;
        badSum[1] = 5_000;
        vm.expectRevert(FeeSplitter.InvalidBasisPoints.selector);
        new FeeSplitter(address(this), address(this), recipients, badSum);

        recipients[1] = ALICE;
        badSum[0] = 5_000;
        badSum[1] = 5_000;
        vm.expectRevert(abi.encodeWithSelector(FeeSplitter.DuplicateRecipient.selector, ALICE));
        new FeeSplitter(address(this), address(this), recipients, badSum);

        recipients[0] = address(0);
        recipients[1] = BOB;
        vm.expectRevert(FeeSplitter.ZeroAddress.selector);
        new FeeSplitter(address(this), address(this), recipients, badSum);

        address[] memory tooManyRecipients = new address[](33);
        uint16[] memory tooManyShares = new uint16[](33);
        for (uint160 i; i < 33; ++i) {
            tooManyRecipients[i] = address(0x1000 + i);
            tooManyShares[i] = i == 32 ? 9_968 : 1;
        }
        vm.expectRevert(FeeSplitter.TooManyRecipients.selector);
        new FeeSplitter(address(this), address(this), tooManyRecipients, tooManyShares);

        recipients[0] = ALICE;
        recipients[1] = BOB;
        badSum[0] = 0;
        badSum[1] = 10_000;
        vm.expectRevert(FeeSplitter.InvalidRecipient.selector);
        new FeeSplitter(address(this), address(this), recipients, badSum);

        vm.expectRevert(FeeSplitter.InvalidAmount.selector);
        splitter.deposit(address(token), 0);

        vm.expectRevert(FeeSplitter.InvalidToken.selector);
        splitter.deposit(address(0), 1);

        vm.expectRevert(FeeSplitter.InvalidToken.selector);
        vm.prank(ALICE);
        splitter.release(1, address(0));

        vm.expectRevert(FeeSplitter.InvalidToken.selector);
        splitter.unallocatedBalance(address(0));
    }

    function testInvalidOwnerUpdateDoesNotCloseCurrentEpoch() public {
        address[] memory recipients = new address[](2);
        recipients[0] = ALICE;
        recipients[1] = BOB;
        uint16[] memory badShares = new uint16[](2);
        badShares[0] = 5_000;
        badShares[1] = 4_999;

        vm.expectRevert(FeeSplitter.InvalidBasisPoints.selector);
        splitter.setConfig(recipients, badShares);

        _assertEq(splitter.currentEpoch(), 1, "failed update advanced epoch");
        require(!splitter.epochClosed(1), "failed update closed current epoch");
        _assertEq(splitter.epochShareBps(1, ALICE), 3_333, "failed update changed shares");
    }

    function testFuzzClosedEpochConservesEveryRecordedUnit(uint128 amount, uint16 aliceSeed, uint16 bobSeed) public {
        if (amount == 0) return;

        uint16 aliceShare = uint16((uint256(aliceSeed) % 9_998) + 1);
        uint256 remaining = 10_000 - aliceShare;
        uint16 bobShare = uint16((uint256(bobSeed) % (remaining - 1)) + 1);
        uint16 carolShare = uint16(10_000 - aliceShare - bobShare);

        address[] memory recipients = new address[](3);
        recipients[0] = ALICE;
        recipients[1] = BOB;
        recipients[2] = CAROL;
        uint16[] memory shares = new uint16[](3);
        shares[0] = aliceShare;
        shares[1] = bobShare;
        shares[2] = carolShare;

        FeeSplitter fuzzSplitter = new FeeSplitter(address(this), address(this), recipients, shares);
        token.mint(address(this), amount);
        _deposit(fuzzSplitter, token, amount);
        fuzzSplitter.setConfig(recipients, shares);

        _releaseIfAny(fuzzSplitter, 1, token, ALICE);
        _releaseIfAny(fuzzSplitter, 1, token, BOB);
        _releaseIfAny(fuzzSplitter, 1, token, CAROL);

        uint256 paid = token.balanceOf(ALICE) + token.balanceOf(BOB) + token.balanceOf(CAROL);
        _assertEq(paid, amount, "closed epoch failed conservation");
        _assertEq(token.balanceOf(address(fuzzSplitter)), 0, "closed epoch retained funds");
        _assertEq(fuzzSplitter.totalRecorded(address(token)), amount, "wrong fuzz receipts");
        _assertEq(fuzzSplitter.totalReleased(address(token)), amount, "wrong fuzz releases");
        _assertEq(fuzzSplitter.accountedBalance(address(token)), 0, "fuzz accounting remains");
    }

    // A recipient removed by a reconfiguration is locked out of the NEW epoch
    // (releasable 0, release reverts) but retains its full claim on the CLOSED
    // epochs it participated in; a newly-added recipient has nothing in epochs
    // that predate it.
    function testRemovedRecipientLosesNewEpochButKeepsClosedEpochs() public {
        (address[] memory r1, uint16[] memory s1) = _halfConfig(ALICE, BOB);
        FeeSplitter adj = new FeeSplitter(address(this), address(this), r1, s1);

        token.mint(address(this), 1_000);
        _deposit(adj, token, 1_000); // epoch 1: ALICE/BOB 5000/5000

        address[] memory r2 = new address[](2);
        r2[0] = BOB;
        r2[1] = CAROL;
        uint16[] memory s2 = new uint16[](2);
        s2[0] = 4_000;
        s2[1] = 6_000;
        adj.setConfig(r2, s2); // epoch 2: ALICE removed, CAROL added
        token.mint(address(this), 1_000);
        _deposit(adj, token, 1_000);

        // ALICE (removed) has no entitlement in the new epoch and cannot release it.
        _assertEq(adj.releasable(2, address(token), ALICE), 0, "removed recipient has new-epoch entitlement");
        vm.expectRevert(FeeSplitter.NothingToRelease.selector);
        vm.prank(ALICE);
        adj.release(2, address(token));

        // ALICE keeps its share of the closed epoch it was part of.
        _assertEq(adj.releasable(1, address(token), ALICE), 500, "removed recipient lost closed-epoch share");
        _releaseAs(adj, 1, token, ALICE);
        _assertEq(token.balanceOf(ALICE), 500, "removed recipient could not claim closed epoch");

        // CAROL (newly added) has nothing in the epoch that predates it.
        _assertEq(adj.releasable(1, address(token), CAROL), 0, "new recipient claimed a pre-existing epoch");
        _assertEq(adj.releasable(2, address(token), CAROL), 600, "new recipient missing its new-epoch share");
    }

    // Many reconfiguration rounds: every closed epoch stays independently and
    // fully claimable, and nothing is stranded across the history.
    function testSurvivesManyReconfigurationRounds() public {
        (address[] memory r, uint16[] memory s) = _halfConfig(ALICE, BOB);
        FeeSplitter adj = new FeeSplitter(address(this), address(this), r, s);

        for (uint256 i; i < 5; ++i) {
            token.mint(address(this), 1_000);
            _deposit(adj, token, 1_000); // deposit into the current epoch
            adj.setConfig(r, s); // reopen the same table -> next epoch
        }
        _assertEq(adj.currentEpoch(), 6, "epoch did not advance once per reconfiguration");

        for (uint256 e = 1; e <= 5; ++e) {
            _releaseAs(adj, e, token, ALICE);
            _releaseAs(adj, e, token, BOB);
        }
        _assertEq(token.balanceOf(ALICE), 2_500, "Alice lifetime across epochs");
        _assertEq(token.balanceOf(BOB), 2_500, "Bob lifetime across epochs");
        _assertEq(token.balanceOf(address(adj)), 0, "residual dust across many epochs");
        _assertEq(adj.totalReleased(address(token)), 5_000, "wrong lifetime released total");
        _assertEq(adj.accountedBalance(address(token)), 0, "accounting not fully cleared");
    }

    // releaseFor lets anyone settle a recipient, but the payment always lands at
    // the recipient (never the caller), so it carries no redirect risk.
    function testAnyoneCanReleaseOnBehalfOfRecipientWithoutRedirect() public {
        token.mint(address(this), 10_000);
        _deposit(splitter, token, 10_000);

        // A stranger settles ALICE's share; funds go to ALICE, not the stranger.
        vm.prank(STRANGER);
        uint256 paid = splitter.releaseFor(1, address(token), ALICE);
        _assertEq(paid, 3_333, "releaseFor returned wrong amount");
        _assertEq(token.balanceOf(ALICE), 3_333, "recipient did not receive its share");
        _assertEq(token.balanceOf(STRANGER), 0, "caller must not receive a redirected payment");

        // Settling again pays nothing (already released) — no double-pay.
        vm.expectRevert(FeeSplitter.NothingToRelease.selector);
        vm.prank(STRANGER);
        splitter.releaseFor(1, address(token), ALICE);

        // A non-recipient owed nothing cannot be dust-griefed into a transfer.
        vm.expectRevert(FeeSplitter.NothingToRelease.selector);
        splitter.releaseFor(1, address(token), STRANGER);

        // Zero recipient is rejected.
        vm.expectRevert(FeeSplitter.ZeroAddress.selector);
        splitter.releaseFor(1, address(token), address(0));

        // Self-service release() still works alongside releaseFor.
        _releaseAs(splitter, 1, token, BOB);
        _assertEq(token.balanceOf(BOB), 3_333, "self-release still works");
    }

    function _deposit(FeeSplitter target, IERC20 asset, uint256 amount) private {
        asset.approve(address(target), amount);
        target.deposit(address(asset), amount);
    }

    function _releaseIfAny(FeeSplitter target, uint256 epoch, IERC20 asset, address recipient) private {
        if (target.releasable(epoch, address(asset), recipient) != 0) {
            _releaseAs(target, epoch, asset, recipient);
        }
    }

    function _releaseAs(FeeSplitter target, uint256 epoch, IERC20 asset, address recipient) private {
        vm.prank(recipient);
        target.release(epoch, address(asset));
    }

    function _defaultConfig() private pure returns (address[] memory recipients, uint16[] memory shares) {
        recipients = new address[](3);
        recipients[0] = ALICE;
        recipients[1] = BOB;
        recipients[2] = CAROL;
        shares = new uint16[](3);
        shares[0] = 3_333;
        shares[1] = 3_333;
        shares[2] = 3_334;
    }

    function _halfConfig(address first, address second)
        private
        pure
        returns (address[] memory recipients, uint16[] memory shares)
    {
        recipients = new address[](2);
        recipients[0] = first;
        recipients[1] = second;
        shares = new uint16[](2);
        shares[0] = 5_000;
        shares[1] = 5_000;
    }

    function _singleAddress(address account) private pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }

    function _singleShare(uint16 share) private pure returns (uint16[] memory shares) {
        shares = new uint16[](1);
        shares[0] = share;
    }

    function _assertEq(uint256 actual, uint256 expected, string memory reason) private pure {
        require(actual == expected, reason);
    }
}
