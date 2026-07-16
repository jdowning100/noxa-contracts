// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ICTOFeeVault, INoxaCTOFactory, INoxaSnapshotToken} from "./interfaces/INoxaCTO.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3.sol";
import {OwnableUpgradeable, ReentrancyGuardUpgradeable} from "./utils/Upgradeable.sol";

/// @notice Snapshot-weighted community takeover elections for Noxa launched tokens.
/// @dev Vote weight is the lower of the exact round-open snapshot balance and the account's round-scoped
///      finalized opening-boundary balance. That dual boundary prevents both open-time flash balances and
///      post-open purchases/transfers from acquiring power in the current round. A round remains open until one
///      candidate reaches quorum, at which point voting closes immediately. Each account may vote only once per
///      round. The incumbent remains in office until a challenger actually reaches quorum.
contract NoxaCTOFund is OwnableUpgradeable, ReentrancyGuardUpgradeable {
    uint256 public constant BPS = 10_000;
    error ZeroAddress();
    error UnknownToken();
    error AlreadyInitialized();
    error OnlyFactory();
    error InvalidVault();
    error TooSoon();
    error NoRound();
    error RoundWarming();
    error ZeroCandidate();
    error SupplyTooLow();
    error NoVotingPower();
    error NotLeader();
    error ClaimLocked();
    error InvalidBasisPoints();
    error InvalidPool();
    error PoolLocked();
    error RoundClosed();
    error AlreadyVoted();
    error InvalidTiming();

    INoxaCTOFactory public factory;

    uint256 public quorumBps;
    uint256 public minCircBps;
    uint256 public reopenCooldown;
    uint256 public leaderClaimDelay;
    uint256 public voteHoldSeconds;

    mapping(address token => bool) public initialized;
    mapping(address token => address) public feeVault;
    mapping(address token => address) public leader;
    mapping(address token => uint256) public leaderClaimableAt;

    mapping(address token => uint256) public round;
    mapping(address token => uint256) public roundSnapshotId;
    mapping(address token => uint256) public roundSnapshotTime;
    mapping(address token => uint256) public roundStart;
    mapping(address token => uint256) public roundTotalSupply;
    mapping(address token => uint256) public roundCirculatingSupply;
    mapping(address token => uint256) public roundQuorum;
    /// @notice Earliest time another round may supersede the current round.
    mapping(address token => uint256) public roundReopenAt;
    /// @notice True once a candidate has reached quorum and voting for the round has ended.
    mapping(address token => bool) public roundClosed;
    /// @notice Whether the opening-boundary circulation and quorum have been finalized for the round.
    mapping(address token => bool) public roundFinalized;
    mapping(address token => uint256) public roundVoteStart;
    mapping(address token => uint256) public roundLeaderClaimDelay;
    mapping(address token => uint256) public roundMinimumCirculating;
    mapping(address token => uint256) public roundQuorumBps;

    mapping(address token => mapping(uint256 electionRound => mapping(address candidate => uint256))) public tally;
    mapping(address token => mapping(uint256 electionRound => mapping(address voter => address))) public voterChoice;
    mapping(address token => mapping(uint256 electionRound => mapping(address voter => uint256))) public voterPower;

    event TokenInitialized(address indexed token, address indexed initialLeader, address indexed feeVault);
    event RoundOpened(
        address indexed token, uint256 indexed electionRound, uint256 snapshotId, uint256 voteStartsAt, uint256 reopenAt
    );
    event RoundFinalized(
        address indexed token,
        uint256 indexed electionRound,
        uint256 openingCirculatingSupply,
        uint256 finalizedCirculatingSupply,
        uint256 effectiveCirculatingSupply,
        uint256 quorum
    );
    event Voted(
        address indexed token, address indexed voter, address indexed candidate, uint256 weight, uint256 candidateTally
    );
    event LeaderElected(
        address indexed token, address indexed leader, uint256 indexed electionRound, uint256 claimableAt
    );
    event RoundConcluded(
        address indexed token, uint256 indexed electionRound, address indexed electedLeader, uint256 electedTally
    );
    event Claimed(
        address indexed token,
        address indexed leader,
        address indexed recipient,
        uint256 tokenAmount,
        uint256 pairAmount,
        uint256 nativeAmount
    );
    event QuorumBpsUpdated(uint256 quorumBps);
    event MinCircBpsUpdated(uint256 minCircBps);
    event ReopenCooldownUpdated(uint256 reopenCooldown);
    event LeaderClaimDelayUpdated(uint256 leaderClaimDelay);
    event VoteHoldSecondsUpdated(uint256 voteHoldSeconds);

    /// @dev Locks the implementation; deploy it behind a transparent proxy and initialize atomically.
    constructor() {
        _disableInitializers();
    }

    function initialize(address factory_, address functionalOwner) external initializer {
        if (factory_ == address(0) || functionalOwner == address(0)) revert ZeroAddress();
        __Ownable_init(functionalOwner);
        __ReentrancyGuard_init();
        factory = INoxaCTOFactory(factory_);
        quorumBps = 4_000; // neutral protocol default; deployment sets its own via setQuorumBps
        minCircBps = 500;
        reopenCooldown = 1 days;
        leaderClaimDelay = 4 hours;
    }

    /// @notice Seeds a new launch with its default leader and permanently binds its fee vault.
    /// @dev The factory must store the launch, pool and vault associations before making this call.
    function onCreate(address token, address initialLeader) external {
        if (msg.sender != address(factory)) revert OnlyFactory();
        if (token == address(0) || initialLeader == address(0)) revert ZeroAddress();
        if (initialized[token]) revert AlreadyInitialized();
        if (!factory.isLaunchedToken(token)) revert UnknownToken();
        if (factory.poolOf(token) == address(0)) revert InvalidPool();

        address vault = factory.ctoVaultOf(token);
        if (
            vault == address(0) || ICTOFeeVault(vault).token() != token
                || ICTOFeeVault(vault).ctoFund() != address(this)
        ) revert InvalidVault();

        initialized[token] = true;
        feeVault[token] = vault;
        leader[token] = initialLeader;
        // The default leader may claim immediately. Elected replacements receive an explicit timestamp.
        leaderClaimableAt[token] = 0;
        emit TokenInitialized(token, initialLeader, vault);
    }

    /// @notice Opens a fresh election round and pins its timing and election parameters.
    /// @dev Anyone may open the first round. A later round may supersede the current round after its minimum reopen
    ///      time passes, whether or not the current round reached quorum. The incumbent is not displaced merely by
    ///      opening a round. Circulation is finalized after the opening timestamp.
    function openRound(address token) external nonReentrant returns (uint256 snapshotId) {
        _requireToken(token);
        uint256 previousSnapshot = roundSnapshotId[token];
        if (previousSnapshot != 0 && block.timestamp < roundReopenAt[token]) revert TooSoon();

        // V3 sets `unlocked = false` throughout swap/flash execution. Opening inside such a callback would
        // snapshot tokens temporarily borrowed from the excluded pool as circulating and pin an unreachable
        // quorum even though the borrower's own dual-boundary vote power is correctly zero.
        (,,,,,, bool poolUnlocked) = IUniswapV3Pool(factory.poolOf(token)).slot0();
        if (!poolUnlocked) revert PoolLocked();

        snapshotId = factory.ctoSnapshot(token);
        uint256 totalSupply = INoxaSnapshotToken(token).totalSupplyAt(snapshotId);
        uint256 openingExcluded = INoxaSnapshotToken(token).votingExcludedSupplyAt(snapshotId);
        if (openingExcluded > totalSupply) openingExcluded = totalSupply;
        uint256 minimumCirculating = _ceilBps(totalSupply, minCircBps);
        if (totalSupply - openingExcluded < minimumCirculating) revert SupplyTooLow();

        uint256 newRound = round[token] + 1;
        uint256 voteStartsAt = block.timestamp + voteHoldSeconds + 1;
        uint256 reopenAt = block.timestamp + reopenCooldown;
        round[token] = newRound;
        roundSnapshotId[token] = snapshotId;
        roundSnapshotTime[token] = block.timestamp;
        roundStart[token] = block.timestamp;
        roundTotalSupply[token] = totalSupply;
        roundCirculatingSupply[token] = 0;
        roundQuorum[token] = 0;
        roundReopenAt[token] = reopenAt;
        roundClosed[token] = false;
        roundFinalized[token] = false;
        roundVoteStart[token] = voteStartsAt;
        roundLeaderClaimDelay[token] = leaderClaimDelay;
        roundMinimumCirculating[token] = minimumCirculating;
        roundQuorumBps[token] = quorumBps;

        emit RoundOpened(token, newRound, snapshotId, voteStartsAt, reopenAt);
    }

    /// @notice Finalizes the conservative circulation denominator after the opening timestamp ends.
    /// @dev The larger of exact-open and end-of-timestamp circulation is used. Temporary V3 liquidity or
    /// vault movements therefore cannot lower quorum at either side of the boundary. A temporary increase
    /// can only make quorum more conservative, never enable a cheaper takeover.
    function finalizeRound(address token)
        external
        nonReentrant
        returns (uint256 circulatingSupply, uint256 requiredQuorum)
    {
        _requireToken(token);
        if (roundSnapshotId[token] == 0) revert NoRound();
        return _finalizeRound(token);
    }

    /// @notice Casts the caller's fixed power for `candidate`; each account may vote once per round.
    function vote(address token, address candidate) external nonReentrant {
        _requireToken(token);
        if (candidate == address(0)) revert ZeroCandidate();

        uint256 snapshotId = roundSnapshotId[token];
        if (snapshotId == 0) revert NoRound();
        if (roundClosed[token]) revert RoundClosed();
        if (block.timestamp < roundVoteStart[token]) revert RoundWarming();
        _finalizeRound(token);

        uint256 electionRound = round[token];
        if (voterChoice[token][electionRound][msg.sender] != address(0)) revert AlreadyVoted();

        uint256 snapshotBalance = INoxaSnapshotToken(token).balanceOfAt(msg.sender, snapshotId);
        uint256 finalBoundaryBalance = INoxaSnapshotToken(token).finalizedBalanceAt(msg.sender, snapshotId);
        uint256 weight = snapshotBalance < finalBoundaryBalance ? snapshotBalance : finalBoundaryBalance;
        if (weight == 0) revert NoVotingPower();

        voterChoice[token][electionRound][msg.sender] = candidate;
        voterPower[token][electionRound][msg.sender] = weight;
        uint256 candidateTally = tally[token][electionRound][candidate] + weight;
        tally[token][electionRound][candidate] = candidateTally;
        emit Voted(token, msg.sender, candidate, weight, candidateTally);

        if (candidateTally >= roundQuorum[token]) {
            roundClosed[token] = true;
            if (candidate != leader[token]) {
                leader[token] = candidate;
                uint256 claimableAt = block.timestamp + roundLeaderClaimDelay[token];
                leaderClaimableAt[token] = claimableAt;
                emit LeaderElected(token, candidate, electionRound, claimableAt);
            }
            emit RoundConcluded(token, electionRound, candidate, candidateTally);
        }
    }

    /// @notice Claims all accrued known fee assets to the current leader.
    function claim(address token)
        external
        nonReentrant
        returns (uint256 tokenAmount, uint256 pairAmount, uint256 nativeAmount)
    {
        return _claimTo(token, msg.sender);
    }

    /// @notice Claims to an alternate recipient, useful when the elected leader is a non-payable contract.
    function claimTo(address token, address recipient)
        external
        nonReentrant
        returns (uint256 tokenAmount, uint256 pairAmount, uint256 nativeAmount)
    {
        if (recipient == address(0)) revert ZeroAddress();
        return _claimTo(token, recipient);
    }

    function isClaimableLeader(address token, address account) external view returns (bool) {
        return initialized[token] && account == leader[token] && block.timestamp >= leaderClaimableAt[token];
    }

    function _claimTo(address token, address recipient)
        private
        returns (uint256 tokenAmount, uint256 pairAmount, uint256 nativeAmount)
    {
        _requireToken(token);
        address currentLeader = leader[token];
        if (msg.sender != currentLeader) revert NotLeader();
        if (block.timestamp < leaderClaimableAt[token]) revert ClaimLocked();

        (tokenAmount, pairAmount, nativeAmount) = ICTOFeeVault(feeVault[token]).claimTo(recipient);
        emit Claimed(token, currentLeader, recipient, tokenAmount, pairAmount, nativeAmount);
    }

    function _finalizeRound(address token) private returns (uint256 circulatingSupply, uint256 requiredQuorum) {
        if (roundFinalized[token]) return (roundCirculatingSupply[token], roundQuorum[token]);

        uint256 snapshotTime = roundSnapshotTime[token];
        if (block.timestamp <= snapshotTime) revert RoundWarming();

        uint256 totalSupply = roundTotalSupply[token];
        uint256 openingExcluded = INoxaSnapshotToken(token).votingExcludedSupplyAt(roundSnapshotId[token]);
        uint256 finalizedExcluded = INoxaSnapshotToken(token).finalizedVotingExcludedSupplyAt(roundSnapshotId[token]);
        if (openingExcluded > totalSupply) openingExcluded = totalSupply;
        if (finalizedExcluded > totalSupply) finalizedExcluded = totalSupply;

        uint256 openingCirculating = totalSupply - openingExcluded;
        uint256 finalizedCirculating = totalSupply - finalizedExcluded;
        circulatingSupply = openingCirculating > finalizedCirculating ? openingCirculating : finalizedCirculating;
        if (circulatingSupply < roundMinimumCirculating[token]) revert SupplyTooLow();

        requiredQuorum = _ceilBps(circulatingSupply, roundQuorumBps[token]);
        roundCirculatingSupply[token] = circulatingSupply;
        roundQuorum[token] = requiredQuorum;
        roundFinalized[token] = true;

        emit RoundFinalized(
            token, round[token], openingCirculating, finalizedCirculating, circulatingSupply, requiredQuorum
        );
    }

    /// @dev Computes ceil(value * bps / BPS) without overflowing at very large token supplies.
    function _ceilBps(uint256 value, uint256 bps) private pure returns (uint256 result) {
        uint256 whole = value / BPS;
        uint256 remainderProduct = (value % BPS) * bps;
        result = whole * bps + remainderProduct / BPS;
        if (remainderProduct % BPS != 0) ++result;
    }

    function _requireToken(address token) private view {
        if (!initialized[token] || !factory.isLaunchedToken(token)) revert UnknownToken();
    }

    function setQuorumBps(uint256 value) external onlyOwner {
        if (value == 0 || value > BPS) revert InvalidBasisPoints();
        quorumBps = value;
        emit QuorumBpsUpdated(value);
    }

    function setMinCircBps(uint256 value) external onlyOwner {
        if (value > BPS) revert InvalidBasisPoints();
        minCircBps = value;
        emit MinCircBpsUpdated(value);
    }

    function setReopenCooldown(uint256 value) external onlyOwner {
        if (value <= voteHoldSeconds || value - voteHoldSeconds <= 1) revert InvalidTiming();
        reopenCooldown = value;
        emit ReopenCooldownUpdated(value);
    }

    function setLeaderClaimDelay(uint256 value) external onlyOwner {
        if (value == 0) revert InvalidTiming();
        leaderClaimDelay = value;
        emit LeaderClaimDelayUpdated(value);
    }

    function setVoteHoldSeconds(uint256 value) external onlyOwner {
        if (value >= reopenCooldown || reopenCooldown - value <= 1) revert InvalidTiming();
        voteHoldSeconds = value;
        emit VoteHoldSecondsUpdated(value);
    }

    /// @dev Reserved for future implementation upgrades. Keep this as the final storage field.
    uint256[41] private __gap;
}
