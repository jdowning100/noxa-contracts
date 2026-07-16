// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LaunchToken} from "../src/LaunchToken.sol";

interface Vm {
    function expectRevert(bytes4 revertData) external;
    function prank(address sender) external;
    function roll(uint256 newHeight) external;
    function warp(uint256 newTimestamp) external;
}

contract LaunchTokenHistoryTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 private constant SUPPLY = 1_000_000 ether;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant CAROL = address(0xCA401);
    address private constant DAVE = address(0xDA7E);
    address private constant EXCLUDED = address(0xE0C1);
    address private constant FEE_ROUTER = address(0xFEE0);
    address private constant FEE_VAULT = address(0xFA017);

    error AssertEq(uint256 actual, uint256 expected);
    error AssertTrue();

    LaunchToken private token;

    function setUp() public {
        vm.warp(10_000);
        vm.roll(100);
        token = new LaunchToken("Noxa Launch", "NOXA", SUPPLY, 10_000, 10_000, 0);
    }

    function testExactBalancesAcrossMultipleSnapshots() public {
        token.transfer(ALICE, 100 ether);
        token.transfer(BOB, 200 ether);

        uint256 first = token.snapshot();
        _assertEq(first, 1);

        vm.prank(ALICE);
        token.transfer(BOB, 25 ether);
        token.transfer(CAROL, 50 ether);

        vm.warp(10_001);
        uint256 second = token.snapshot();
        _assertEq(second, 2);

        vm.prank(BOB);
        token.transfer(ALICE, 10 ether);
        token.transfer(ALICE, 40 ether);

        vm.warp(10_002);
        uint256 third = token.snapshot();
        _assertEq(third, 3);

        vm.prank(CAROL);
        token.transfer(BOB, 10 ether);

        _assertEq(token.currentSnapshotId(), 3);

        _assertEq(token.balanceOfAt(address(this), first), SUPPLY - 300 ether);
        _assertEq(token.balanceOfAt(ALICE, first), 100 ether);
        _assertEq(token.balanceOfAt(BOB, first), 200 ether);
        _assertEq(token.balanceOfAt(CAROL, first), 0);

        _assertEq(token.balanceOfAt(address(this), second), SUPPLY - 350 ether);
        _assertEq(token.balanceOfAt(ALICE, second), 75 ether);
        _assertEq(token.balanceOfAt(BOB, second), 225 ether);
        _assertEq(token.balanceOfAt(CAROL, second), 50 ether);

        _assertEq(token.balanceOfAt(address(this), third), SUPPLY - 390 ether);
        _assertEq(token.balanceOfAt(ALICE, third), 125 ether);
        _assertEq(token.balanceOfAt(BOB, third), 215 ether);
        _assertEq(token.balanceOfAt(CAROL, third), 50 ether);

        _assertEq(token.totalSupplyAt(first), SUPPLY);
        _assertEq(token.totalSupplyAt(second), SUPPLY);
        _assertEq(token.totalSupplyAt(third), SUPPLY);

        vm.expectRevert(LaunchToken.InvalidSnapshotId.selector);
        token.balanceOfAt(ALICE, 0);
        vm.expectRevert(LaunchToken.InvalidSnapshotId.selector);
        token.totalSupplyAt(4);
    }

    function testSameTimestampChangesCoalesceToFinalBalance() public {
        vm.warp(20_000);
        token.transfer(ALICE, 100 ether);

        vm.warp(20_001);

        // Model a same-timestamp flash loan. The exact snapshot observes the temporary balance,
        // while the round-scoped final boundary is overwritten after repayment.
        token.transfer(ALICE, 40 ether);
        uint256 duringFlash = token.snapshot();
        vm.prank(ALICE);
        token.transfer(address(this), 40 ether);

        // A zero-starting borrower likewise retains only its end-of-timestamp zero balance.
        token.transfer(BOB, 77 ether);
        vm.prank(BOB);
        token.transfer(address(this), 77 ether);

        vm.warp(20_002);

        _assertEq(token.balanceOfAt(ALICE, duringFlash), 140 ether);
        _assertEq(token.finalizedBalanceAt(ALICE, duringFlash), 100 ether);
        _assertEq(token.finalizedBalanceAt(BOB, duringFlash), 0);
        _assertEq(token.balanceOf(ALICE), 100 ether);
        _assertEq(token.balanceOf(BOB), 0);
    }

    function testFinalBoundaryRequiresFinalizedSnapshotTimestamp() public {
        vm.warp(30_000);
        token.transfer(ALICE, 10 ether);
        uint256 opening = token.snapshot();

        vm.expectRevert(LaunchToken.SnapshotAlreadyCreatedThisTimestamp.selector);
        token.snapshot();

        vm.expectRevert(LaunchToken.TimestampNotFinalized.selector);
        token.finalizedBalanceAt(ALICE, opening);

        vm.warp(30_001);
        _assertEq(token.finalizedBalanceAt(ALICE, opening), 10 ether);

        vm.prank(ALICE);
        token.transfer(BOB, 4 ether);
        _assertEq(token.finalizedBalanceAt(ALICE, opening), 10 ether);

        token.setVotingExcluded(ALICE);
        _assertEq(token.finalizedBalanceAt(ALICE, opening), 10 ether);
        uint256 laterRound = token.snapshot();
        vm.warp(30_002);
        _assertEq(token.finalizedBalanceAt(ALICE, laterRound), 0);
    }

    function testSnapshotAndExclusionAreFactoryOnly() public {
        vm.expectRevert(LaunchToken.NotFactory.selector);
        vm.prank(ALICE);
        token.snapshot();

        vm.expectRevert(LaunchToken.NotFactory.selector);
        vm.prank(ALICE);
        token.setVotingExcluded(EXCLUDED);

        vm.expectRevert(LaunchToken.NotFactory.selector);
        vm.prank(ALICE);
        token.setRestrictionExempt(EXCLUDED);

        vm.expectRevert(LaunchToken.NotFactory.selector);
        vm.prank(ALICE);
        token.configureFeeVault(FEE_VAULT, FEE_ROUTER);

        vm.expectRevert(LaunchToken.ZeroAddress.selector);
        token.setVotingExcluded(address(0));

        token.setVotingExcluded(EXCLUDED);
        token.setVotingExcluded(EXCLUDED); // The one-way operation is deliberately idempotent.
        token.setRestrictionExempt(EXCLUDED);

        _assertTrue(token.votingExcluded(EXCLUDED));
        _assertEq(token.votingExcludedFromSnapshotId(EXCLUDED), 1);
        _assertTrue(token.restrictionExempt(EXCLUDED));
        _assertTrue(token.votingExcluded(address(this)));
        _assertTrue(token.votingExcluded(0x000000000000000000000000000000000000dEaD));
    }

    function testExcludedSupplyHasRoundScopedFinalBoundary() public {
        token.setVotingExcluded(EXCLUDED);
        token.transfer(ALICE, 100 ether);
        uint256 opening = token.snapshot();

        vm.prank(ALICE);
        token.transfer(EXCLUDED, 40 ether);
        vm.warp(block.timestamp + 1);

        _assertEq(token.votingExcludedSupplyAt(opening), SUPPLY - 100 ether);
        _assertEq(token.finalizedVotingExcludedSupplyAt(opening), SUPPLY - 60 ether);

        uint256 current = token.snapshot();
        vm.expectRevert(LaunchToken.TimestampNotFinalized.selector);
        token.finalizedVotingExcludedSupplyAt(current);
    }

    function testFeeVaultRejectsHolderDepositsAndAcceptsOnlyConfiguredRouter() public {
        token.setVotingExcluded(FEE_ROUTER);
        token.setVotingExcluded(FEE_VAULT);
        token.configureFeeVault(FEE_VAULT, FEE_ROUTER);
        token.transfer(FEE_ROUTER, 25 ether);
        token.transfer(ALICE, 10 ether);

        vm.expectRevert(LaunchToken.InvalidFeeVaultDeposit.selector);
        vm.prank(ALICE);
        token.transfer(FEE_VAULT, 1 ether);

        vm.prank(ALICE);
        _assertTrue(token.transfer(FEE_VAULT, 0));

        vm.prank(ALICE);
        token.approve(BOB, 1 ether);
        vm.expectRevert(LaunchToken.InvalidFeeVaultDeposit.selector);
        vm.prank(BOB);
        token.transferFrom(ALICE, FEE_VAULT, 1 ether);

        vm.prank(FEE_ROUTER);
        token.transfer(FEE_VAULT, 25 ether);
        _assertEq(token.balanceOf(FEE_VAULT), 25 ether);

        vm.expectRevert(LaunchToken.FeeVaultAlreadyConfigured.selector);
        token.configureFeeVault(FEE_VAULT, FEE_ROUTER);
    }

    function testExcludedAccountStillHasExactSnapshotsButNoFinalBoundaryVotingBalance() public {
        token.setVotingExcluded(EXCLUDED);

        vm.warp(40_000);
        token.transfer(EXCLUDED, 123 ether);
        uint256 opening = token.snapshot();
        _assertEq(token.votingExcludedSupplyAt(opening), SUPPLY);

        vm.warp(40_001);
        vm.prank(EXCLUDED);
        token.transfer(BOB, 23 ether);
        token.transfer(EXCLUDED, 50 ether);

        vm.warp(40_002);

        _assertEq(token.balanceOfAt(EXCLUDED, opening), 123 ether);
        _assertEq(token.balanceOf(EXCLUDED), 150 ether);
        _assertEq(token.finalizedBalanceAt(EXCLUDED, opening), 0);
        _assertEq(token.votingExcludedSupply(), SUPPLY - 23 ether);
    }

    function testExistingTransferRestrictionsArePreserved() public {
        uint256 endBlock = block.number + 10;
        LaunchToken restricted = new LaunchToken("Restricted Noxa", "RNOXA", 1_000 ether, 1_000, 500, endBlock);

        _assertTrue(restricted.restrictionsActive());
        _assertTrue(restricted.restrictionExempt(address(this)));

        // Factory-originating setup transfers bypass max-tx but still respect recipient max-wallet.
        restricted.transfer(ALICE, 100 ether);
        restricted.transfer(BOB, 60 ether);

        vm.expectRevert(LaunchToken.MaxTxExceeded.selector);
        vm.prank(ALICE);
        restricted.transfer(BOB, 51 ether);

        vm.expectRevert(LaunchToken.MaxWalletExceeded.selector);
        vm.prank(ALICE);
        restricted.transfer(BOB, 41 ether);

        // A restriction exemption retains the previous behavior for launch infrastructure.
        restricted.setRestrictionExempt(BOB);
        vm.prank(ALICE);
        restricted.transfer(BOB, 60 ether);
        _assertEq(restricted.balanceOf(BOB), 120 ether);

        restricted.transfer(CAROL, 100 ether);
        restricted.transfer(DAVE, 100 ether);

        vm.roll(endBlock);
        _assertTrue(!restricted.restrictionsActive());

        vm.prank(CAROL);
        restricted.transfer(DAVE, 80 ether);
        _assertEq(restricted.balanceOf(DAVE), 180 ether);
    }

    function _assertEq(uint256 actual, uint256 expected) private pure {
        if (actual != expected) revert AssertEq(actual, expected);
    }

    function _assertTrue(bool condition) private pure {
        if (!condition) revert AssertTrue();
    }
}
