// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice A small on-chain multisig for protocol administration.
/// @dev Signers are fixed for the lifetime of this contract. To rotate signers,
///      deploy a replacement and approve ownership/fund transfers to it.
contract QuorumMultisig {
    uint256 public constant QUORUM_NUMERATOR = 3;
    uint256 public constant QUORUM_DENOMINATOR = 5;
    uint256 public constant PROPOSAL_LIFETIME = 7 days;

    struct Proposal {
        address proposer;
        address target;
        uint256 value;
        uint256 approvalCount;
        uint64 deadline;
        bool executed;
        bool cancelled;
        bytes data;
    }

    error NotSigner(address caller);
    error TooFewSigners();
    error InvalidSigner();
    error DuplicateSigner(address signer);
    error InvalidTarget();
    error ProposalNotFound(uint256 proposalId);
    error ProposalAlreadyExecuted(uint256 proposalId);
    error ProposalAlreadyCancelled(uint256 proposalId);
    error ProposalExpired(uint256 proposalId, uint256 deadline);
    error AlreadyApproved(uint256 proposalId, address signer);
    error NotApproved(uint256 proposalId, address signer);
    error NotProposer(uint256 proposalId, address caller);
    error ReentrantCall();

    event Deposit(address indexed sender, uint256 amount, uint256 balance);
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        address indexed target,
        uint256 value,
        bytes data,
        uint256 deadline
    );
    event ProposalApproved(uint256 indexed proposalId, address indexed signer, uint256 approvalCount);
    event ApprovalRevoked(uint256 indexed proposalId, address indexed signer, uint256 approvalCount);
    event ProposalCancelled(uint256 indexed proposalId, address indexed proposer);
    event ProposalExecuted(uint256 indexed proposalId, address indexed target, uint256 value);

    address[] private _signers;
    mapping(address => bool) public isSigner;

    uint256 public immutable requiredApprovals;
    uint256 public proposalCount;

    mapping(uint256 => Proposal) private _proposals;
    mapping(uint256 => mapping(address => bool)) public approvedBy;

    uint256 private _reentrancyState = 1;

    modifier onlySigner() {
        if (!isSigner[msg.sender]) revert NotSigner(msg.sender);
        _;
    }

    modifier nonReentrant() {
        if (_reentrancyState != 1) revert ReentrantCall();
        _reentrancyState = 2;
        _;
        _reentrancyState = 1;
    }

    constructor(address[] memory signers_) {
        uint256 signerCount = signers_.length;
        if (signerCount < 2) revert TooFewSigners();

        for (uint256 i; i < signerCount; ++i) {
            address signer = signers_[i];
            if (signer == address(0)) revert InvalidSigner();
            if (isSigner[signer]) revert DuplicateSigner(signer);

            isSigner[signer] = true;
            _signers.push(signer);
        }

        // ceil(60% of signerCount), expressed without truncating toward zero.
        requiredApprovals = (signerCount * QUORUM_NUMERATOR + QUORUM_DENOMINATOR - 1) / QUORUM_DENOMINATOR;
    }

    receive() external payable {
        emit Deposit(msg.sender, msg.value, address(this).balance);
    }

    /// @notice Proposes an arbitrary call and automatically records the proposer's approval.
    function propose(address target, uint256 value, bytes calldata data)
        external
        onlySigner
        nonReentrant
        returns (uint256 proposalId)
    {
        if (target == address(0)) revert InvalidTarget();

        proposalId = proposalCount++;
        uint64 deadline = uint64(block.timestamp + PROPOSAL_LIFETIME);

        Proposal storage proposal = _proposals[proposalId];
        proposal.proposer = msg.sender;
        proposal.target = target;
        proposal.value = value;
        proposal.approvalCount = 1;
        proposal.deadline = deadline;
        proposal.data = data;

        approvedBy[proposalId][msg.sender] = true;

        emit ProposalCreated(proposalId, msg.sender, target, value, data, deadline);
        emit ProposalApproved(proposalId, msg.sender, 1);

        // The constructor requires at least two signers, so this branch is
        // currently unreachable. Keeping it makes the quorum invariant explicit.
        if (requiredApprovals == 1) _execute(proposalId, proposal);
    }

    /// @notice Approves a proposal. The approval that reaches quorum executes it atomically.
    /// @dev If the target call reverts, this approval and execution are both rolled back.
    function approve(uint256 proposalId) external onlySigner nonReentrant {
        Proposal storage proposal = _activeProposal(proposalId);
        if (approvedBy[proposalId][msg.sender]) revert AlreadyApproved(proposalId, msg.sender);

        approvedBy[proposalId][msg.sender] = true;
        ++proposal.approvalCount;

        emit ProposalApproved(proposalId, msg.sender, proposal.approvalCount);

        if (proposal.approvalCount >= requiredApprovals) {
            _execute(proposalId, proposal);
        }
    }

    /// @notice Removes the caller's approval while the proposal remains pending.
    function revokeApproval(uint256 proposalId) external onlySigner nonReentrant {
        Proposal storage proposal = _activeProposal(proposalId);
        if (!approvedBy[proposalId][msg.sender]) revert NotApproved(proposalId, msg.sender);

        approvedBy[proposalId][msg.sender] = false;
        --proposal.approvalCount;

        emit ApprovalRevoked(proposalId, msg.sender, proposal.approvalCount);
    }

    /// @notice Cancels a pending proposal. Only its original proposer may cancel it.
    function cancel(uint256 proposalId) external onlySigner nonReentrant {
        Proposal storage proposal = _activeProposal(proposalId);
        if (proposal.proposer != msg.sender) revert NotProposer(proposalId, msg.sender);

        proposal.cancelled = true;
        emit ProposalCancelled(proposalId, msg.sender);
    }

    function getSigners() external view returns (address[] memory) {
        return _signers;
    }

    function getProposal(uint256 proposalId)
        external
        view
        returns (
            address proposer,
            address target,
            uint256 value,
            uint256 approvalCount,
            uint256 deadline,
            bool executed,
            bool cancelled,
            bytes memory data
        )
    {
        Proposal storage proposal = _proposal(proposalId);
        return (
            proposal.proposer,
            proposal.target,
            proposal.value,
            proposal.approvalCount,
            proposal.deadline,
            proposal.executed,
            proposal.cancelled,
            proposal.data
        );
    }

    function _proposal(uint256 proposalId) private view returns (Proposal storage proposal) {
        proposal = _proposals[proposalId];
        if (proposal.target == address(0)) revert ProposalNotFound(proposalId);
    }

    function _activeProposal(uint256 proposalId) private view returns (Proposal storage proposal) {
        proposal = _proposal(proposalId);
        if (proposal.executed) revert ProposalAlreadyExecuted(proposalId);
        if (proposal.cancelled) revert ProposalAlreadyCancelled(proposalId);
        if (block.timestamp >= proposal.deadline) revert ProposalExpired(proposalId, proposal.deadline);
    }

    function _execute(uint256 proposalId, Proposal storage proposal) private {
        // Checks-effects-interactions prevents the same proposal from executing twice.
        proposal.executed = true;

        (bool success, bytes memory result) = proposal.target.call{value: proposal.value}(proposal.data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }

        emit ProposalExecuted(proposalId, proposal.target, proposal.value);
    }
}
