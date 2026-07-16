// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CTOFeeVault} from "../src/CTOFeeVault.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {NoxaCTOFund} from "../src/NoxaCTOFund.sol";
import {ICTOFeeVault, INoxaCTOFactory, INoxaCTOFund} from "../src/interfaces/INoxaCTO.sol";
import {Clones} from "../src/libraries/Clones.sol";

interface Vm {
    function deal(address account, uint256 newBalance) external;
    function expectRevert(bytes4 revertData) external;
    function prank(address msgSender) external;
    function warp(uint256 newTimestamp) external;
}

/// @dev Tiny immutable implementation proxy used to exercise the real upgradeable implementation.
/// Initialization is performed by delegatecall in the constructor, so the proxy is never exposed
/// in an uninitialized state. The immutable implementation consumes no proxy storage slot.
contract AtomicTestProxy {
    address public immutable implementation;

    constructor(address implementation_, bytes memory initializationCall) payable {
        implementation = implementation_;
        (bool ok, bytes memory result) = implementation_.delegatecall(initializationCall);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
    }

    fallback() external payable {
        _delegate();
    }

    receive() external payable {
        _delegate();
    }

    function _delegate() private {
        address target = implementation;
        assembly ("memory-safe") {
            calldatacopy(0, 0, calldatasize())
            let success := delegatecall(gas(), target, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch success
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

contract MockPairToken is ERC20 {
    constructor() ERC20("Mock Pair", "PAIR") {}

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }
}

contract MockElectionPool {
    bool public unlocked = true;

    function setUnlocked(bool value) external {
        unlocked = value;
    }

    function slot0()
        external
        view
        returns (uint160, int24, uint16, uint16, uint16, uint8, bool)
    {
        return (uint160(1 << 96), 0, 0, 0, 0, 0, unlocked);
    }
}

/// @dev Provides the narrow factory surface used by NoxaCTOFund while deploying the real token and
/// real EIP-1167 fee-vault clones. It deliberately models the production launch ordering: persist all
/// associations and exclusions first, then call onCreate, then distribute initial inventory.
contract MockCTOFactory is INoxaCTOFactory {
    using Clones for address;

    address public ctoFund;
    address public immutable vaultImplementation;

    mapping(address token => bool) public override isLaunchedToken;
    mapping(address token => address) public override poolOf;
    mapping(address token => address) public override ctoVaultOf;

    constructor() {
        vaultImplementation = address(new CTOFeeVault());
    }

    function setCTOFund(address ctoFund_) external {
        require(ctoFund == address(0), "fund already set");
        ctoFund = ctoFund_;
    }

    function launch(address initialLeader, address pool, uint256 supply)
        external
        returns (LaunchToken token, MockPairToken pair, CTOFeeVault vault)
    {
        require(ctoFund != address(0), "fund not set");
        token = new LaunchToken("Noxa Test", "NOXA", supply, 10_000, 10_000, block.number);
        pair = new MockPairToken();

        address vaultAddress = vaultImplementation.clone();
        vault = CTOFeeVault(payable(vaultAddress));
        vault.initialize(address(token), address(pair), ctoFund);

        isLaunchedToken[address(token)] = true;
        poolOf[address(token)] = pool;
        ctoVaultOf[address(token)] = vaultAddress;

        token.setRestrictionExempt(pool);
        token.setRestrictionExempt(vaultAddress);
        token.setVotingExcluded(pool);
        token.setVotingExcluded(vaultAddress);
        token.configureFeeVault(vaultAddress, address(this));

        INoxaCTOFund(ctoFund).onCreate(address(token), initialLeader);
    }

    function ctoSnapshot(address token) external override returns (uint256 snapshotId) {
        require(msg.sender == ctoFund, "only CTO fund");
        require(isLaunchedToken[token], "unknown token");
        snapshotId = LaunchToken(token).snapshot();
    }

    function distribute(address token, address recipient, uint256 amount) external {
        IERC20(token).transfer(recipient, amount);
    }

    function cloneVaultUninitialized() external returns (address) {
        return vaultImplementation.clone();
    }

    function initializeVault(address vault, address token, address pair, address fund) external {
        ICTOFeeVault(vault).initialize(token, pair, fund);
    }
}

/// @dev Intentionally has no receive or payable fallback.
contract NonPayableLeader {
    function claimSelf(NoxaCTOFund fund, address token) external {
        fund.claim(token);
    }

    function claimFor(NoxaCTOFund fund, address token, address recipient) external {
        fund.claimTo(token, recipient);
    }
}

contract PayableRecipient {
    receive() external payable {}
}

contract NoxaCTOCoreTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 private constant UNIT = 1 ether;
    uint256 private constant SUPPLY = 1_000 * UNIT;

    address private constant INITIAL_LEADER = address(0x1111);
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant CAROL = address(0xCA201);
    address private constant FLASH_TRADER = address(0xF1A5);
    address private constant CANDIDATE_ONE = address(0xC001);
    address private constant CANDIDATE_TWO = address(0xC002);
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    MockCTOFactory private factory;
    NoxaCTOFund private implementation;
    AtomicTestProxy private proxy;
    NoxaCTOFund private fund;
    LaunchToken private token;
    MockPairToken private pair;
    CTOFeeVault private vault;
    MockElectionPool private pool;

    function setUp() public {
        vm.warp(block.timestamp + 1_000);
        vm.deal(address(this), 100 ether);

        factory = new MockCTOFactory();
        implementation = new NoxaCTOFund();
        proxy = new AtomicTestProxy(
            address(implementation),
            abi.encodeCall(NoxaCTOFund.initialize, (address(factory), address(this)))
        );
        fund = NoxaCTOFund(address(proxy));
        factory.setCTOFund(address(fund));

        pool = new MockElectionPool();
        (token, pair, vault) = factory.launch(INITIAL_LEADER, address(pool), SUPPLY);

        // Excluded: pool 600, vault 25, dead 15, factory remainder 60 = 700.
        // Circulating: Alice 200 + Bob 100 = 300; default 40% quorum = 120.
        factory.distribute(address(token), address(pool), 600 * UNIT);
        factory.distribute(address(token), ALICE, 200 * UNIT);
        factory.distribute(address(token), BOB, 100 * UNIT);
        factory.distribute(address(token), address(vault), 25 * UNIT);
        factory.distribute(address(token), DEAD, 15 * UNIT);
    }

    function testProxyInitializesAtomicallyAndLocksImplementation() external {
        _assertEq(address(fund.factory()), address(factory), "factory not initialized");
        _assertEq(fund.owner(), address(this), "owner not initialized");
        _assertEq(fund.quorumBps(), 4_000, "wrong quorum default");
        _assertEq(fund.minCircBps(), 500, "wrong circulation default");
        _assertEq(fund.reopenCooldown(), 1 days, "wrong reopen cooldown default");
        _assertEq(fund.leaderClaimDelay(), 4 hours, "wrong claim delay default");

        (bool implementationInitOk,) = address(implementation).call(
            abi.encodeCall(NoxaCTOFund.initialize, (address(factory), address(this)))
        );
        _assertFalse(implementationInitOk, "implementation accepted initialize");

        (bool proxyReinitOk,) = address(fund).call(
            abi.encodeCall(NoxaCTOFund.initialize, (address(factory), address(this)))
        );
        _assertFalse(proxyReinitOk, "proxy accepted second initialize");
    }

    function testOnCreateBindsVaultAndDefaultLeader() external view {
        _assertTrue(fund.initialized(address(token)), "token not initialized");
        _assertEq(fund.feeVault(address(token)), address(vault), "wrong vault");
        _assertEq(fund.leader(address(token)), INITIAL_LEADER, "wrong default leader");
        _assertEq(fund.leaderClaimableAt(address(token)), 0, "default leader should claim immediately");
        _assertEq(vault.token(), address(token), "vault token mismatch");
        _assertEq(vault.ctoFund(), address(fund), "vault fund mismatch");
    }

    function testRoundExcludesProtocolInventoryAndPinsQuorum() external {
        uint256 snapshotId = fund.openRound(address(token));

        _assertEq(snapshotId, 1, "wrong snapshot id");
        _assertEq(token.votingExcludedSupplyAt(snapshotId), 700 * UNIT, "wrong excluded aggregate");
        _assertEq(fund.roundTotalSupply(address(token)), SUPPLY, "wrong total supply");
        _assertEq(fund.roundCirculatingSupply(address(token)), 0, "round finalized too early");

        _finalizeOpeningTimestamp();
        fund.finalizeRound(address(token));
        _assertEq(fund.roundCirculatingSupply(address(token)), 300 * UNIT, "wrong circulating supply");
        _assertEq(fund.roundQuorum(address(token)), 120 * UNIT, "wrong rounded quorum");
        (uint256 finalizedCirculation, uint256 finalizedQuorum) = fund.finalizeRound(address(token));
        _assertEq(finalizedCirculation, 300 * UNIT, "idempotent circulation changed");
        _assertEq(finalizedQuorum, 120 * UNIT, "idempotent quorum changed");

        // Changing both live circulation and the global parameter cannot alter this round's denominator.
        vm.prank(address(pool));
        token.transfer(CAROL, 200 * UNIT);
        fund.setQuorumBps(9_000);
        _assertEq(fund.roundCirculatingSupply(address(token)), 300 * UNIT, "circulation was not pinned");
        _assertEq(fund.roundQuorum(address(token)), 120 * UNIT, "quorum was not pinned");
    }

    function testCannotOpenRoundDuringPoolSwapOrFlash() external {
        pool.setUnlocked(false);
        vm.expectRevert(NoxaCTOFund.PoolLocked.selector);
        fund.openRound(address(token));
        _assertEq(token.currentSnapshotId(), 0, "locked-pool attempt created snapshot");

        pool.setUnlocked(true);
        _assertEq(fund.openRound(address(token)), 1, "unlocked pool did not open");
    }

    function testCannotOpenRoundBeforeMinimumCirculation() external {
        vm.prank(ALICE);
        token.transfer(address(pool), 200 * UNIT);
        vm.prank(BOB);
        token.transfer(address(pool), 100 * UNIT);

        vm.expectRevert(NoxaCTOFund.SupplyTooLow.selector);
        fund.openRound(address(token));
        _assertEq(token.currentSnapshotId(), 0, "failed open retained snapshot");
    }

    function testRoundRemainsOpenPastReopenTimeUntilQuorumThenCloses() external {
        fund.openRound(address(token));
        uint256 reopenAt = fund.roundReopenAt(address(token));
        _finalizeOpeningTimestamp();

        // Passing the minimum interval does not automatically expire the round.
        vm.warp(reopenAt + 30 days);
        vm.prank(BOB);
        fund.vote(address(token), CANDIDATE_ONE);
        _assertFalse(fund.roundClosed(address(token)), "sub-quorum vote closed round");

        vm.prank(ALICE);
        fund.vote(address(token), CANDIDATE_ONE);
        _assertTrue(fund.roundClosed(address(token)), "quorum did not close round");
        _assertEq(fund.leader(address(token)), CANDIDATE_ONE, "quorum did not elect leader");

        vm.expectRevert(NoxaCTOFund.RoundClosed.selector);
        vm.prank(CAROL);
        fund.vote(address(token), CANDIDATE_TWO);

        _assertEq(fund.openRound(address(token)), 2, "fresh round did not open after conclusion");
    }

    function testAnyoneCanSupersedeUnresolvedRoundAfterMinimumReopenTime() external {
        fund.openRound(address(token));
        uint256 reopenAt = fund.roundReopenAt(address(token));
        _finalizeOpeningTimestamp();

        vm.prank(BOB);
        fund.vote(address(token), CANDIDATE_ONE);
        _assertFalse(fund.roundClosed(address(token)), "sub-quorum round unexpectedly closed");

        vm.warp(reopenAt);
        vm.prank(CAROL);
        _assertEq(fund.openRound(address(token)), 2, "unresolved round was not superseded");
        _assertFalse(fund.roundClosed(address(token)), "fresh round inherited closed state");
        _assertEq(fund.tally(address(token), 1, CANDIDATE_ONE), 100 * UNIT, "old tally changed");
        _assertEq(fund.tally(address(token), 2, CANDIDATE_ONE), 0, "old tally leaked into fresh round");
    }

    function testClosedRoundStillEnforcesMinimumReopenTime() external {
        fund.openRound(address(token));
        uint256 reopenAt = fund.roundReopenAt(address(token));
        _finalizeOpeningTimestamp();

        vm.prank(ALICE);
        fund.vote(address(token), CANDIDATE_ONE);
        _assertTrue(fund.roundClosed(address(token)), "quorate round remained open");

        vm.expectRevert(NoxaCTOFund.TooSoon.selector);
        fund.openRound(address(token));

        vm.warp(reopenAt);
        _assertEq(fund.openRound(address(token)), 2, "round did not reopen at pinned minimum");
    }

    function testClaimDelayIsIndependentButEveryRoundRetainsAVotingWindow() external {
        vm.expectRevert(NoxaCTOFund.InvalidTiming.selector);
        fund.setReopenCooldown(1);

        vm.expectRevert(NoxaCTOFund.InvalidTiming.selector);
        fund.setLeaderClaimDelay(0);

        uint256 cooldown = fund.reopenCooldown();
        vm.expectRevert(NoxaCTOFund.InvalidTiming.selector);
        fund.setVoteHoldSeconds(cooldown - 1);

        // Claim delay is independent from reopen spacing, so the requested four-hour delay may be
        // shorter than the one-day minimum between round openings.
        fund.setLeaderClaimDelay(1);
        _assertEq(fund.leaderClaimDelay(), 1, "claim delay not updated");
    }

    function testRoundPinsVoteStartAndLeaderClaimDelay() external {
        fund.setVoteHoldSeconds(3);
        fund.setReopenCooldown(10);
        fund.setLeaderClaimDelay(30);
        fund.openRound(address(token));

        uint256 pinnedVoteStart = fund.roundVoteStart(address(token));
        _assertEq(fund.roundLeaderClaimDelay(address(token)), 30, "claim delay not pinned");

        // These values govern only future rounds.
        fund.setVoteHoldSeconds(0);
        fund.setReopenCooldown(2);
        fund.setLeaderClaimDelay(3);

        vm.warp(pinnedVoteStart - 1);
        vm.expectRevert(NoxaCTOFund.RoundWarming.selector);
        vm.prank(ALICE);
        fund.vote(address(token), CANDIDATE_ONE);

        vm.warp(pinnedVoteStart);
        vm.prank(ALICE);
        fund.vote(address(token), CANDIDATE_ONE);
        _assertEq(
            fund.leaderClaimableAt(address(token)), block.timestamp + 30, "live claim delay leaked into round"
        );
    }

    function testTemporaryPoolDepositCannotLowerFinalizedQuorum() external {
        // Model a one-sided LP mint just before open and removal later in the same timestamp.
        vm.prank(ALICE);
        token.transfer(address(pool), 100 * UNIT);
        fund.openRound(address(token));
        vm.prank(address(pool));
        token.transfer(ALICE, 100 * UNIT);

        _finalizeOpeningTimestamp();
        fund.finalizeRound(address(token));

        _assertEq(fund.roundCirculatingSupply(address(token)), 300 * UNIT, "temporary LP lowered circulation");
        _assertEq(fund.roundQuorum(address(token)), 120 * UNIT, "temporary LP lowered quorum");
    }

    function testTemporaryPoolWithdrawalCanOnlyRaiseFinalizedQuorum() external {
        vm.prank(address(pool));
        token.transfer(ALICE, 100 * UNIT);
        fund.openRound(address(token));
        vm.prank(ALICE);
        token.transfer(address(pool), 100 * UNIT);

        _finalizeOpeningTimestamp();
        fund.finalizeRound(address(token));

        _assertEq(fund.roundCirculatingSupply(address(token)), 400 * UNIT, "unsafe lower boundary chosen");
        _assertEq(fund.roundQuorum(address(token)), 160 * UNIT, "temporary withdrawal lowered quorum");
    }

    function testOnlyConfiguredFeeSourceCanDepositLaunchedTokenIntoVault() external {
        vm.expectRevert(LaunchToken.InvalidFeeVaultDeposit.selector);
        vm.prank(ALICE);
        token.transfer(address(vault), UNIT);

        factory.distribute(address(token), address(vault), UNIT);
        _assertEq(token.balanceOf(address(vault)), 26 * UNIT, "canonical fee deposit failed");
    }

    function testOpeningTimestampFlashBalanceHasNoVote() external {
        vm.prank(address(pool));
        token.transfer(FLASH_TRADER, 150 * UNIT);

        fund.openRound(address(token));

        // Repayment in the opening timestamp overwrites the round-scoped final boundary with zero.
        vm.prank(FLASH_TRADER);
        token.transfer(address(pool), 150 * UNIT);
        _finalizeOpeningTimestamp();

        vm.expectRevert(NoxaCTOFund.NoVotingPower.selector);
        vm.prank(FLASH_TRADER);
        fund.vote(address(token), CANDIDATE_ONE);
    }

    function testPostOpenPurchaseHasNoVote() external {
        fund.openRound(address(token));

        // It is present at the finalized opening timestamp, but absent from the exact opening snapshot.
        vm.prank(address(pool));
        token.transfer(FLASH_TRADER, 150 * UNIT);
        _finalizeOpeningTimestamp();

        vm.expectRevert(NoxaCTOFund.NoVotingPower.selector);
        vm.prank(FLASH_TRADER);
        fund.vote(address(token), CANDIDATE_ONE);
    }

    function testVoteUsesLowerOfSnapshotAndFinalOpeningBalance() external {
        fund.openRound(address(token));

        // Alice held 200 at snapshot but only 75 at the finalized end of the opening timestamp.
        vm.prank(ALICE);
        token.transfer(address(pool), 125 * UNIT);
        _finalizeOpeningTimestamp();

        vm.prank(ALICE);
        fund.vote(address(token), CANDIDATE_ONE);

        _assertEq(fund.voterPower(address(token), 1, ALICE), 75 * UNIT, "did not take lower boundary");
        _assertEq(fund.tally(address(token), 1, CANDIDATE_ONE), 75 * UNIT, "wrong candidate tally");
    }

    function testVoterCannotRevoteWithinRound() external {
        fund.setQuorumBps(10_000);
        fund.openRound(address(token));
        _finalizeOpeningTimestamp();

        vm.prank(ALICE);
        fund.vote(address(token), CANDIDATE_ONE);
        _assertTrue(fund.roundFinalized(address(token)), "vote did not lazily finalize round");
        _assertEq(fund.tally(address(token), 1, CANDIDATE_ONE), 200 * UNIT, "first vote missing");

        vm.expectRevert(NoxaCTOFund.AlreadyVoted.selector);
        vm.prank(ALICE);
        fund.vote(address(token), CANDIDATE_TWO);

        _assertEq(fund.tally(address(token), 1, CANDIDATE_ONE), 200 * UNIT, "first tally changed");
        _assertEq(fund.tally(address(token), 1, CANDIDATE_TWO), 0, "second vote was counted");
        _assertEq(fund.voterPower(address(token), 1, ALICE), 200 * UNIT, "cached power changed");
        _assertEq(fund.voterChoice(address(token), 1, ALICE), CANDIDATE_ONE, "choice changed");
    }

    function testVoteThenTransferCannotGiveRecipientASecondVote() external {
        fund.setQuorumBps(10_000);
        fund.openRound(address(token));
        _finalizeOpeningTimestamp();

        vm.prank(ALICE);
        fund.vote(address(token), CANDIDATE_ONE);
        vm.prank(ALICE);
        token.transfer(BOB, 200 * UNIT);

        vm.prank(BOB);
        fund.vote(address(token), CANDIDATE_TWO);

        _assertEq(token.balanceOf(BOB), 300 * UNIT, "test transfer failed");
        _assertEq(fund.voterPower(address(token), 1, BOB), 100 * UNIT, "transferred tokens voted twice");
        _assertEq(fund.tally(address(token), 1, CANDIDATE_ONE), 200 * UNIT, "sender tally changed");
        _assertEq(fund.tally(address(token), 1, CANDIDATE_TWO), 100 * UNIT, "recipient tally wrong");
    }

    function testElectedLeaderCannotClaimUntilDelayThenReceivesEveryAsset() external {
        fund.openRound(address(token));
        _finalizeOpeningTimestamp();

        vm.prank(ALICE);
        fund.vote(address(token), CANDIDATE_ONE);
        _assertEq(fund.leader(address(token)), CANDIDATE_ONE, "candidate not elected");
        _assertTrue(fund.roundClosed(address(token)), "election remained open after quorum");
        _assertEq(
            fund.leaderClaimableAt(address(token)), block.timestamp + 4 hours, "elected claim delay is not four hours"
        );

        factory.distribute(address(token), address(vault), 10 * UNIT);
        pair.mint(address(vault), 20 * UNIT);
        _sendNative(address(vault), 3 ether);

        vm.expectRevert(NoxaCTOFund.ClaimLocked.selector);
        vm.prank(CANDIDATE_ONE);
        fund.claim(address(token));

        vm.warp(fund.leaderClaimableAt(address(token)));
        uint256 nativeBefore = CANDIDATE_ONE.balance;
        vm.prank(CANDIDATE_ONE);
        (uint256 tokenAmount, uint256 pairAmount, uint256 nativeAmount) = fund.claim(address(token));

        // The vault began with 25 launched tokens that were excluded from voting, then accrued 10 more.
        _assertEq(tokenAmount, 35 * UNIT, "wrong launched-token payout");
        _assertEq(pairAmount, 20 * UNIT, "wrong pair-token payout");
        _assertEq(nativeAmount, 3 ether, "wrong native payout");
        _assertEq(token.balanceOf(CANDIDATE_ONE), 35 * UNIT, "leader missing launched tokens");
        _assertEq(pair.balanceOf(CANDIDATE_ONE), 20 * UNIT, "leader missing pair tokens");
        _assertEq(CANDIDATE_ONE.balance, nativeBefore + 3 ether, "leader missing native asset");
        _assertEq(token.balanceOf(address(vault)), 0, "launched tokens left in vault");
        _assertEq(pair.balanceOf(address(vault)), 0, "pair tokens left in vault");
        _assertEq(address(vault).balance, 0, "native asset left in vault");
    }

    function testNonPayableLeaderCanClaimToPayableRecipient() external {
        NonPayableLeader nonPayableLeader = new NonPayableLeader();
        PayableRecipient recipient = new PayableRecipient();

        fund.setReopenCooldown(2);
        fund.setLeaderClaimDelay(3);
        fund.openRound(address(token));
        _finalizeOpeningTimestamp();
        vm.prank(ALICE);
        fund.vote(address(token), address(nonPayableLeader));

        factory.distribute(address(token), address(vault), 10 * UNIT);
        pair.mint(address(vault), 20 * UNIT);
        _sendNative(address(vault), 3 ether);
        vm.warp(fund.leaderClaimableAt(address(token)));

        // A failed self-payment rolls every preceding token transfer back atomically.
        vm.expectRevert(CTOFeeVault.NativeTransferFailed.selector);
        nonPayableLeader.claimSelf(fund, address(token));
        _assertEq(token.balanceOf(address(vault)), 35 * UNIT, "failed claim leaked launched token");
        _assertEq(pair.balanceOf(address(vault)), 20 * UNIT, "failed claim leaked pair token");

        nonPayableLeader.claimFor(fund, address(token), address(recipient));
        _assertEq(token.balanceOf(address(recipient)), 35 * UNIT, "recipient missing launched token");
        _assertEq(pair.balanceOf(address(recipient)), 20 * UNIT, "recipient missing pair token");
        _assertEq(address(recipient).balance, 3 ether, "recipient missing native asset");
    }

    function testVaultCloneInitializationAuthorizationAndOneTimeLock() external {
        address uninitializedClone = factory.cloneVaultUninitialized();

        vm.expectRevert(CTOFeeVault.NotFactory.selector);
        ICTOFeeVault(uninitializedClone).initialize(address(token), address(pair), address(fund));

        factory.initializeVault(uninitializedClone, address(token), address(pair), address(fund));
        _assertEq(ICTOFeeVault(uninitializedClone).token(), address(token), "clone token not initialized");
        _assertEq(ICTOFeeVault(uninitializedClone).ctoFund(), address(fund), "clone fund not initialized");

        vm.expectRevert(CTOFeeVault.AlreadyInitialized.selector);
        factory.initializeVault(uninitializedClone, address(token), address(pair), address(fund));

        // Read before expectRevert so the getter is not mistaken for the expected reverting call.
        address vaultImplementation = factory.vaultImplementation();
        // The standalone implementation is also permanently initialized/locked by its constructor.
        vm.expectRevert(CTOFeeVault.AlreadyInitialized.selector);
        factory.initializeVault(vaultImplementation, address(token), address(pair), address(fund));

        vm.expectRevert(CTOFeeVault.NotCTOFund.selector);
        vault.claimTo(address(this));
    }

    function _finalizeOpeningTimestamp() private {
        vm.warp(block.timestamp + 1);
    }

    function _sendNative(address recipient, uint256 amount) private {
        (bool ok,) = recipient.call{value: amount}("");
        _assertTrue(ok, "native funding failed");
    }

    function _assertEq(uint256 actual, uint256 expected, string memory reason) private pure {
        require(actual == expected, reason);
    }

    function _assertEq(address actual, address expected, string memory reason) private pure {
        require(actual == expected, reason);
    }

    function _assertTrue(bool value, string memory reason) private pure {
        require(value, reason);
    }

    function _assertFalse(bool value, string memory reason) private pure {
        require(!value, reason);
    }
}
