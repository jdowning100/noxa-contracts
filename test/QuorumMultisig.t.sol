// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {QuorumMultisig} from "../src/QuorumMultisig.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";
import {ProxyAdmin, TransparentUpgradeableProxy} from "../src/proxy/TransparentUpgradeableProxy.sol";

interface VmMultisig {
    function deal(address account, uint256 newBalance) external;
    function expectRevert(bytes4 revertData) external;
    function expectRevert(bytes calldata revertData) external;
    function load(address target, bytes32 slot) external view returns (bytes32);
    function prank(address caller) external;
    function warp(uint256 newTimestamp) external;
}

contract MultisigTarget {
    error ForcedFailure();

    uint256 public number;
    uint256 public valueReceived;
    address public caller;
    bool public shouldFail;

    function setShouldFail(bool value) external {
        shouldFail = value;
    }

    function setNumber(uint256 newNumber) external payable {
        if (shouldFail) revert ForcedFailure();
        number = newNumber;
        valueReceived = msg.value;
        caller = msg.sender;
    }

    function reenterApproval(QuorumMultisig wallet, uint256 proposalId) external {
        wallet.approve(proposalId);
    }
}

contract MultisigProxyV1 {
    function version() external pure returns (uint256) {
        return 1;
    }
}

contract MultisigProxyV2 {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract QuorumMultisigTest {
    VmMultisig private constant vm = VmMultisig(address(uint160(uint256(keccak256("hevm cheat code")))));
    bytes32 private constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant CAROL = address(0xCA401);
    address private constant DAVE = address(0xDA7E);
    address private constant ERIN = address(0xE21);
    address private constant STRANGER = address(0xBAD);

    function testConstructorRoundsSixtyPercentUp() external {
        _assertRequired(2, 2);
        _assertRequired(3, 2);
        _assertRequired(4, 3);
        _assertRequired(5, 3);
        _assertRequired(6, 4);
        _assertRequired(7, 5);
        _assertRequired(8, 5);
        _assertRequired(9, 6);
        _assertRequired(10, 6);
    }

    function testConstructorRejectsTooFewDuplicateAndZeroSigners() external {
        address[] memory signers = new address[](1);
        signers[0] = ALICE;
        vm.expectRevert(QuorumMultisig.TooFewSigners.selector);
        new QuorumMultisig(signers);

        signers = new address[](2);
        signers[0] = ALICE;
        signers[1] = address(0);
        vm.expectRevert(QuorumMultisig.InvalidSigner.selector);
        new QuorumMultisig(signers);

        signers[1] = ALICE;
        vm.expectRevert(abi.encodeWithSelector(QuorumMultisig.DuplicateSigner.selector, ALICE));
        new QuorumMultisig(signers);
    }

    function testProposerIsAutomaticallyApprovedAndActionIsStored() external {
        QuorumMultisig wallet = _threeSignerWallet(address(0));
        MultisigTarget target = new MultisigTarget();
        bytes memory data = abi.encodeCall(MultisigTarget.setNumber, (42));

        vm.prank(ALICE);
        uint256 proposalId = wallet.propose(address(target), 3 ether, data);

        (
            address proposer,
            address storedTarget,
            uint256 value,
            uint256 approvalCount,
            uint256 deadline,
            bool executed,
            bool cancelled,
            bytes memory storedData
        ) = wallet.getProposal(proposalId);

        require(proposer == ALICE, "PROPOSER");
        require(storedTarget == address(target), "TARGET");
        require(value == 3 ether, "VALUE");
        require(approvalCount == 1, "APPROVAL_COUNT");
        require(wallet.approvedBy(proposalId, ALICE), "AUTO_APPROVAL");
        require(deadline == block.timestamp + 7 days, "DEADLINE");
        require(!executed && !cancelled, "STATUS");
        require(keccak256(storedData) == keccak256(data), "DATA");
    }

    function testFinalApprovalExecutesArbitraryCallAndETH() external {
        QuorumMultisig wallet = _threeSignerWallet(address(0));
        MultisigTarget target = new MultisigTarget();
        vm.deal(address(wallet), 1 ether);

        vm.prank(ALICE);
        uint256 proposalId = wallet.propose(address(target), 0.4 ether, abi.encodeCall(MultisigTarget.setNumber, (77)));

        vm.prank(BOB);
        wallet.approve(proposalId);

        require(target.number() == 77, "NUMBER");
        require(target.valueReceived() == 0.4 ether, "CALL_VALUE");
        require(target.caller() == address(wallet), "CALLER");
        require(address(wallet).balance == 0.6 ether, "WALLET_BALANCE");

        (,,,,, bool executed,,) = wallet.getProposal(proposalId);
        require(executed, "NOT_EXECUTED");
    }

    function testCanOwnAndAdministerNoxaFeeRouter() external {
        QuorumMultisig wallet = _threeSignerWallet(address(0));
        FeeRouter router = new FeeRouter();
        router.setFeeConfig(address(1), address(2), 3_333, 3_333, 3_334);
        router.transferOwnership(address(wallet));

        vm.prank(ALICE);
        uint256 proposalId = wallet.propose(
            address(router),
            0,
            abi.encodeCall(
                FeeRouter.setFeeConfig, (address(3), address(4), uint16(2_000), uint16(3_000), uint16(5_000))
            )
        );

        vm.prank(BOB);
        wallet.approve(proposalId);

        require(router.owner() == address(wallet), "WRONG_ROUTER_OWNER");
        require(router.protocolRecipient() == address(3), "WRONG_PROTOCOL_RECIPIENT");
        require(router.burnerRecipient() == address(4), "WRONG_BURNER_RECIPIENT");
        require(router.protocolShareBps() == 2_000, "WRONG_PROTOCOL_SHARE");
        require(router.burnerShareBps() == 3_000, "WRONG_BURNER_SHARE");
        require(router.ctoShareBps() == 5_000, "WRONG_CTO_SHARE");
    }

    function testCanOwnAndReconfigureFeeSplitter() external {
        QuorumMultisig wallet = _threeSignerWallet(address(0));
        FeeRouter router = new FeeRouter();

        address[] memory initialRecipients = new address[](2);
        initialRecipients[0] = ALICE;
        initialRecipients[1] = BOB;
        uint16[] memory initialShares = new uint16[](2);
        initialShares[0] = 5_000;
        initialShares[1] = 5_000;
        FeeSplitter splitter = new FeeSplitter(address(router), address(wallet), initialRecipients, initialShares);

        address[] memory newRecipients = new address[](2);
        newRecipients[0] = BOB;
        newRecipients[1] = CAROL;
        uint16[] memory newShares = new uint16[](2);
        newShares[0] = 2_500;
        newShares[1] = 7_500;

        vm.prank(ALICE);
        uint256 proposalId =
            wallet.propose(address(splitter), 0, abi.encodeCall(FeeSplitter.setConfig, (newRecipients, newShares)));

        vm.prank(BOB);
        wallet.approve(proposalId);

        require(splitter.owner() == address(wallet), "WRONG_SPLITTER_OWNER");
        require(splitter.currentEpoch() == 2, "EPOCH_NOT_OPENED");
        require(splitter.epochClosed(1), "OLD_EPOCH_NOT_CLOSED");
        require(splitter.epochShareBps(1, ALICE) == 5_000, "OLD_SHARE_CHANGED");
        require(splitter.epochShareBps(2, BOB) == 2_500, "NEW_BOB_SHARE");
        require(splitter.epochShareBps(2, CAROL) == 7_500, "NEW_CAROL_SHARE");
    }

    function testCanOwnProxyAdminAndUpgradeTransparentProxy() external {
        QuorumMultisig wallet = _threeSignerWallet(address(0));
        MultisigProxyV1 v1 = new MultisigProxyV1();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(v1), address(this), "");

        address adminAddress = address(uint160(uint256(vm.load(address(proxy), ADMIN_SLOT))));
        ProxyAdmin admin = ProxyAdmin(adminAddress);
        admin.transferOwnership(address(wallet));

        MultisigProxyV2 v2 = new MultisigProxyV2();
        bytes memory upgradeCall =
            abi.encodeWithSelector(ProxyAdmin.upgradeAndCall.selector, address(proxy), address(v2), bytes(""));

        vm.prank(ALICE);
        uint256 proposalId = wallet.propose(adminAddress, 0, upgradeCall);

        vm.prank(BOB);
        wallet.approve(proposalId);

        require(admin.owner() == address(wallet), "WRONG_PROXY_ADMIN_OWNER");
        require(MultisigProxyV2(address(proxy)).version() == 2, "UPGRADE_FAILED");
    }

    function testExecutionRevertRollsBackFinalApprovalAndCanRetry() external {
        QuorumMultisig wallet = _threeSignerWallet(address(0));
        MultisigTarget target = new MultisigTarget();
        target.setShouldFail(true);

        vm.prank(ALICE);
        uint256 proposalId = wallet.propose(address(target), 0, abi.encodeCall(MultisigTarget.setNumber, (99)));

        vm.expectRevert(MultisigTarget.ForcedFailure.selector);
        vm.prank(BOB);
        wallet.approve(proposalId);

        (,,, uint256 approvalCount,, bool executed,,) = wallet.getProposal(proposalId);
        require(approvalCount == 1, "FAILED_APPROVAL_PERSISTED");
        require(!wallet.approvedBy(proposalId, BOB), "FAILED_SIGNER_MARKED");
        require(!executed, "FAILED_EXECUTED");

        target.setShouldFail(false);
        vm.prank(BOB);
        wallet.approve(proposalId);
        require(target.number() == 99, "RETRY_FAILED");
    }

    function testNonSignerCannotProposeApproveRevokeOrCancel() external {
        QuorumMultisig wallet = _threeSignerWallet(address(0));
        MultisigTarget target = new MultisigTarget();

        vm.expectRevert(abi.encodeWithSelector(QuorumMultisig.NotSigner.selector, STRANGER));
        vm.prank(STRANGER);
        wallet.propose(address(target), 0, "");

        vm.prank(ALICE);
        uint256 proposalId = wallet.propose(address(target), 0, "");

        vm.expectRevert(abi.encodeWithSelector(QuorumMultisig.NotSigner.selector, STRANGER));
        vm.prank(STRANGER);
        wallet.approve(proposalId);

        vm.expectRevert(abi.encodeWithSelector(QuorumMultisig.NotSigner.selector, STRANGER));
        vm.prank(STRANGER);
        wallet.revokeApproval(proposalId);

        vm.expectRevert(abi.encodeWithSelector(QuorumMultisig.NotSigner.selector, STRANGER));
        vm.prank(STRANGER);
        wallet.cancel(proposalId);
    }

    function testDuplicateApprovalAndSecondExecutionAreRejected() external {
        QuorumMultisig wallet = _fiveSignerWallet();
        MultisigTarget target = new MultisigTarget();

        vm.prank(ALICE);
        uint256 proposalId = wallet.propose(address(target), 0, abi.encodeCall(MultisigTarget.setNumber, (5)));

        vm.prank(BOB);
        wallet.approve(proposalId);

        vm.expectRevert(abi.encodeWithSelector(QuorumMultisig.AlreadyApproved.selector, proposalId, BOB));
        vm.prank(BOB);
        wallet.approve(proposalId);

        vm.prank(CAROL);
        wallet.approve(proposalId);
        require(target.number() == 5, "NOT_EXECUTED");

        vm.expectRevert(abi.encodeWithSelector(QuorumMultisig.ProposalAlreadyExecuted.selector, proposalId));
        vm.prank(DAVE);
        wallet.approve(proposalId);
    }

    function testApprovalCanBeRevokedBeforeQuorum() external {
        QuorumMultisig wallet = _fiveSignerWallet();
        MultisigTarget target = new MultisigTarget();

        vm.prank(ALICE);
        uint256 proposalId = wallet.propose(address(target), 0, abi.encodeCall(MultisigTarget.setNumber, (123)));

        vm.prank(BOB);
        wallet.approve(proposalId);
        vm.prank(BOB);
        wallet.revokeApproval(proposalId);

        vm.prank(CAROL);
        wallet.approve(proposalId);
        require(target.number() == 0, "EXECUTED_BELOW_QUORUM");

        vm.prank(DAVE);
        wallet.approve(proposalId);
        require(target.number() == 123, "NOT_EXECUTED_AT_QUORUM");
    }

    function testOnlyProposerCanCancelAndCancelledProposalCannotExecute() external {
        QuorumMultisig wallet = _threeSignerWallet(address(0));
        MultisigTarget target = new MultisigTarget();

        vm.prank(ALICE);
        uint256 proposalId = wallet.propose(address(target), 0, "");

        vm.expectRevert(abi.encodeWithSelector(QuorumMultisig.NotProposer.selector, proposalId, BOB));
        vm.prank(BOB);
        wallet.cancel(proposalId);

        vm.prank(ALICE);
        wallet.cancel(proposalId);

        vm.expectRevert(abi.encodeWithSelector(QuorumMultisig.ProposalAlreadyCancelled.selector, proposalId));
        vm.prank(BOB);
        wallet.approve(proposalId);
    }

    function testExpiredProposalCannotBeApproved() external {
        QuorumMultisig wallet = _threeSignerWallet(address(0));
        MultisigTarget target = new MultisigTarget();

        vm.prank(ALICE);
        uint256 proposalId = wallet.propose(address(target), 0, "");
        (,,,, uint256 deadline,,,) = wallet.getProposal(proposalId);
        vm.warp(deadline);

        vm.expectRevert(abi.encodeWithSelector(QuorumMultisig.ProposalExpired.selector, proposalId, deadline));
        vm.prank(BOB);
        wallet.approve(proposalId);
    }

    function testReentrantApprovalCannotExecuteNestedCalls() external {
        MultisigTarget target = new MultisigTarget();
        QuorumMultisig wallet = _threeSignerWallet(address(target));

        vm.prank(ALICE);
        uint256 proposalId =
            wallet.propose(address(target), 0, abi.encodeCall(MultisigTarget.reenterApproval, (wallet, 0)));
        require(proposalId == 0, "UNEXPECTED_ID");

        vm.expectRevert(QuorumMultisig.ReentrantCall.selector);
        vm.prank(BOB);
        wallet.approve(proposalId);

        (,,, uint256 approvalCount,, bool executed,,) = wallet.getProposal(proposalId);
        require(approvalCount == 1 && !executed, "REENTRANCY_STATE");
    }

    function testSameActionCanBeProposedMoreThanOnce() external {
        QuorumMultisig wallet = _threeSignerWallet(address(0));
        MultisigTarget target = new MultisigTarget();
        bytes memory data = abi.encodeCall(MultisigTarget.setNumber, (7));

        vm.prank(ALICE);
        uint256 first = wallet.propose(address(target), 0, data);
        vm.prank(BOB);
        uint256 second = wallet.propose(address(target), 0, data);

        require(first == 0 && second == 1, "PROPOSAL_IDS");
        require(wallet.proposalCount() == 2, "PROPOSAL_COUNT");
    }

    function testReceiveAcceptsETH() external {
        QuorumMultisig wallet = _threeSignerWallet(address(0));
        vm.deal(ALICE, 1 ether);

        vm.prank(ALICE);
        (bool success,) = address(wallet).call{value: 0.25 ether}("");
        require(success, "DEPOSIT_FAILED");
        require(address(wallet).balance == 0.25 ether, "DEPOSIT_BALANCE");
    }

    function testProposeRejectsZeroTarget() external {
        QuorumMultisig wallet = _threeSignerWallet(address(0));
        vm.expectRevert(QuorumMultisig.InvalidTarget.selector);
        vm.prank(ALICE);
        wallet.propose(address(0), 0, "");
    }

    function testUnknownProposalIsRejectedByEveryAccessor() external {
        QuorumMultisig wallet = _threeSignerWallet(address(0));
        uint256 ghost = 999;

        vm.expectRevert(abi.encodeWithSelector(QuorumMultisig.ProposalNotFound.selector, ghost));
        vm.prank(ALICE);
        wallet.approve(ghost);

        vm.expectRevert(abi.encodeWithSelector(QuorumMultisig.ProposalNotFound.selector, ghost));
        vm.prank(ALICE);
        wallet.revokeApproval(ghost);

        vm.expectRevert(abi.encodeWithSelector(QuorumMultisig.ProposalNotFound.selector, ghost));
        vm.prank(ALICE);
        wallet.cancel(ghost);

        vm.expectRevert(abi.encodeWithSelector(QuorumMultisig.ProposalNotFound.selector, ghost));
        wallet.getProposal(ghost);
    }

    function testSignerCannotRevokeAnApprovalItNeverGave() external {
        QuorumMultisig wallet = _threeSignerWallet(address(0));
        MultisigTarget target = new MultisigTarget();

        // ALICE proposes (auto-approves). BOB is a signer but has not approved.
        vm.prank(ALICE);
        uint256 proposalId = wallet.propose(address(target), 0, "");

        vm.expectRevert(abi.encodeWithSelector(QuorumMultisig.NotApproved.selector, proposalId, BOB));
        vm.prank(BOB);
        wallet.revokeApproval(proposalId);

        // The proposal is untouched and still executable.
        (,,, uint256 approvalCount,,,,) = wallet.getProposal(proposalId);
        require(approvalCount == 1, "APPROVAL_COUNT_CHANGED");
    }

    function _assertRequired(uint256 signerCount, uint256 expected) private {
        address[] memory signers = new address[](signerCount);
        for (uint256 i; i < signerCount; ++i) {
            signers[i] = address(uint160(i + 1));
        }
        QuorumMultisig wallet = new QuorumMultisig(signers);
        require(wallet.requiredApprovals() == expected, "WRONG_QUORUM");
    }

    function _threeSignerWallet(address thirdSigner) private returns (QuorumMultisig wallet) {
        address[] memory signers = new address[](3);
        signers[0] = ALICE;
        signers[1] = BOB;
        signers[2] = thirdSigner == address(0) ? CAROL : thirdSigner;
        wallet = new QuorumMultisig(signers);
    }

    function _fiveSignerWallet() private returns (QuorumMultisig wallet) {
        address[] memory signers = new address[](5);
        signers[0] = ALICE;
        signers[1] = BOB;
        signers[2] = CAROL;
        signers[3] = DAVE;
        signers[4] = ERIN;
        wallet = new QuorumMultisig(signers);
    }
}
