// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IRandomnessSource } from "../../randomness/IRandomnessSource.sol";

/// @dev Minimal interface into a DAO's StakedGovernanceToken - only what's
///      needed here, so this contract has zero external dependencies (no
///      OpenZeppelin import required).
interface IVotesToken {
    function getPastVotes(address account, uint256 timepoint) external view returns (uint256);
    function getPastTotalSupply(uint256 timepoint) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

/// @title DelegateGovernance
/// @author Marvin Sunday
/// @notice A representative governance model: token holders elect a fixed-size
///         council for a term; only council members propose and vote on DAO
///         actions during that term. Ordinary holders' only direct lever is
///         who they elect (and recall).
/// @dev Drops into the same trusted-`governance` slot on Treasury as the
///      token-weighted Governance.sol - Treasury only ever checks "is the
///      caller my registered governance address?", so this is a genuine
///      swap-in alternative, not a fork of the existing model. Reuses the
///      same StakedGovernanceToken a DAO already has for election and
///      recall voting power, so switching governance models does not
///      require a new token.
///
///      Design choices locked in for this build:
///      - Council votes are equal-weight (one seat = one vote), not scaled
///        by election margin.
///      - The council is `councilSize` numbered seats (optionally labelled,
///        e.g. "Treasurer"). Candidates run for one seat; voters pick at most
///        one candidate per seat; each seat goes to its most-voted candidate.
///        A tie is settled by a random draw (the randomness source, Pyth
///        Entropy, as Sortition uses), or by who declared first when there
///        is no source. A seat nobody runs for keeps its holder.
///      - Recall is supported. A removed delegate's seat sits vacant until
///        the next scheduled election - no special election is triggered.
///      - No term limits. A delegate may run again indefinitely.
contract DelegateGovernance is Initializable {
    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    enum ProposalState {
        Pending,
        Active,
        Succeeded,
        Queued,
        Defeated,
        Executed,
        Cancelled,
        Expired
    }

    enum VoteType {
        Against,
        For,
        Abstain
    }

    struct ProposalAction {
        address target;
        uint256 value;
        bytes data;
    }

    struct CouncilProposal {
        uint256 id;
        ProposalAction[] actions;
        address proposer;
        string metadataURI;
        uint256 createdBlock;
        uint256 startBlock;
        uint256 endBlock;
        uint16 forVotes;
        uint16 againstVotes;
        uint16 abstainVotes;
        uint256 queuedAt;
        bool executed;
        bool cancelled;
    }

    struct CouncilVoteReceipt {
        bool hasVoted;
        VoteType support;
    }

    struct Election {
        uint256 id;
        uint256 candidacyDeadline; // block
        uint256 votingEndBlock; // block
        uint256 snapshotBlock;
        bool finalized;
        address[] candidates;
    }

    struct RecallVote {
        uint256 id;
        address delegate;
        uint256 endBlock; // block
        uint256 snapshotBlock;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        bool finalized;
        bool executed; // true only if the delegate was actually removed
    }

    struct DelegateGovernanceConfig {
        uint16 councilSize;
        uint32 termLength; // seconds
        uint256 candidacyThreshold; // min staked tokens to run, and to initiate a recall
        uint32 candidacyPeriod; // blocks, window to declare candidacy after an election starts
        uint32 electionVotingPeriod; // blocks, after the candidacy window closes
        uint16 councilQuorum; // min council members who must vote on a proposal
        uint16 councilApprovalThresholdBps; // of council votes cast (excl. abstain)
        uint32 votingDelay; // blocks, for council proposals
        uint32 votingPeriod; // blocks
        uint32 timelockDelay; // seconds
        uint32 executionPeriod; // seconds
        uint16 recallQuorumBps; // of total token supply
        uint16 recallApprovalThresholdBps; // of recall votes cast (excl. abstain)
        uint32 recallVotingPeriod; // blocks
    }

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error InvalidConfiguration();
    error NotCouncilMember();
    error CandidacyThresholdNotMet();
    error CandidacyWindowClosed();
    error AlreadyCandidate();
    error NotACandidate();
    error DuplicateCandidate();
    error NoActiveElection();
    error ElectionAlreadyActive();
    error ElectionNotYetVoting();
    error ElectionVotingClosed();
    error ElectionVotingNotEnded();
    error ElectionAlreadyFinalized();
    error AlreadyVotedInElection();
    error TooManyCandidatesSelected();
    error TooEarlyForElection();
    error ProposalNotFound();
    error EmptyProposalActions();
    error EmptyMetadataURI();
    error InvalidProposalAction();
    error ProposalNotActive();
    error AlreadyVoted();
    error CouncilQuorumNotReached();
    error CouncilApprovalNotMet();
    error ProposalAlreadyQueued();
    error ProposalNotExecutable();
    error ProposalAlreadyExecuted();
    error ProposalAlreadyCancelled();
    error ProposalExpired();
    error ExecutionFailed();
    error InvalidValue();
    error Unauthorized();
    error NoActiveRecall();
    error RecallVotingClosed();
    error RecallVotingNotEnded();
    error RecallAlreadyFinalized();
    error NotCurrentlyOnCouncil();
    error InvalidSeat();
    error TwoCandidatesForOneSeat();
    error DrawPending();
    error NoDrawPending();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event ElectionStarted(uint256 indexed electionId, uint256 candidacyDeadline, uint256 votingEndBlock);
    event CandidacyDeclared(uint256 indexed electionId, address indexed candidate);
    event ElectionVoteCast(uint256 indexed electionId, address indexed voter, uint256 weight);
    event ElectionFinalized(uint256 indexed electionId, address[] newCouncil);
    event CouncilProposalCreated(uint256 indexed proposalId, address indexed proposer, string metadataURI);
    event CouncilVoteCast(address indexed delegate, uint256 indexed proposalId, VoteType support);
    event CouncilProposalCancelled(uint256 indexed proposalId, address indexed caller);
    event CouncilProposalQueued(uint256 indexed proposalId, uint256 executeAfter);
    event CouncilProposalExecuted(uint256 indexed proposalId, address indexed executor);
    event RecallInitiated(uint256 indexed recallId, address indexed delegate, address indexed initiator);
    event RecallVoteCast(uint256 indexed recallId, address indexed voter, VoteType support, uint256 weight);
    event RecallFinalized(uint256 indexed recallId, address indexed delegate, bool removed);
    event ConfigUpdated();
    event SeatCandidacyDeclared(uint256 indexed electionId, uint16 indexed seat, address indexed candidate);
    event TieDrawRequested(uint256 indexed electionId, bytes32 requestId);
    event SeatLabelSet(uint16 indexed seat, string label);
    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);
    event GovernanceTokenUpdated(address indexed previousToken, address indexed newToken);

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    string public daoName;
    address public creator;
    address public governanceToken; // the DAO's StakedGovernanceToken
    /// @notice The voting token each election and recall started with, so a
    ///         token change (setGovernanceToken) leaves open ones alone.
    mapping(uint256 => address) public electionToken;
    mapping(uint256 => address) public recallToken;
    address public treasury;
    DelegateGovernanceConfig internal _config;

    address[] public council;
    mapping(address => bool) public isCouncilMember;
    uint256 public currentTermEnd;

    uint256 public electionCount;
    mapping(uint256 => Election) internal _elections;
    mapping(uint256 => mapping(address => bool)) internal _isCandidate;
    mapping(uint256 => mapping(address => uint256)) internal _electionVotes;
    mapping(uint256 => mapping(address => bool)) internal _hasVotedInElection;
    uint256 internal _activeElectionId;

    uint256 public proposalCount;
    mapping(uint256 => CouncilProposal) internal _proposals;
    mapping(uint256 => mapping(address => CouncilVoteReceipt)) internal _voteReceipts;

    uint256 public recallCount;
    mapping(uint256 => RecallVote) internal _recalls;
    mapping(uint256 => mapping(address => bool)) internal _hasVotedInRecall;

    /// @notice Settles tied seats; zero means ties go to whoever declared first.
    IRandomnessSource public randomnessSource;
    /// @notice A seat's label, e.g. "Treasurer" (set by proposal).
    mapping(uint16 => string) public seatLabel;
    /// @dev Seat + 1 a candidate runs for, per election (0: not running).
    mapping(uint256 => mapping(address => uint16)) internal _seatOf;
    mapping(uint256 => mapping(uint16 => address[])) internal _seatCandidates;
    /// @notice Elections waiting on a random draw to settle tied seats.
    mapping(uint256 => bool) public awaitingDraw;

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyCouncilMember() {
        if (!isCouncilMember[msg.sender]) revert NotCouncilMember();
        _;
    }

    modifier onlyGovernance() {
        if (msg.sender != address(this)) revert Unauthorized();
        _;
    }

    modifier proposalExists(uint256 proposalId) {
        if (proposalId == 0 || proposalId > proposalCount) revert ProposalNotFound();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory daoName_,
        address creator_,
        address governanceToken_,
        address treasury_,
        DelegateGovernanceConfig memory config_,
        address[] memory initialCouncil_,
        address randomnessSource_
    ) external initializer {
        if (creator_ == address(0) || governanceToken_ == address(0) || treasury_ == address(0)) {
            revert ZeroAddress();
        }
        _validateConfig(config_);
        if (initialCouncil_.length != config_.councilSize) revert InvalidConfiguration();

        daoName = daoName_;
        creator = creator_;
        governanceToken = governanceToken_;
        treasury = treasury_;
        _config = config_;
        randomnessSource = IRandomnessSource(randomnessSource_);

        for (uint256 i = 0; i < initialCouncil_.length; i++) {
            address member = initialCouncil_[i];
            if (member == address(0)) revert ZeroAddress();
            council.push(member);
            isCouncilMember[member] = true;
        }
        currentTermEnd = block.timestamp + config_.termLength;
    }

    /*//////////////////////////////////////////////////////////////
                            ELECTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Starts a new council election. Callable by anyone, only once
    ///         the current term has ended and no election is already open.
    function startElection() external returns (uint256 electionId) {
        if (block.timestamp < currentTermEnd) revert TooEarlyForElection();
        if (_activeElectionId != 0 && !_elections[_activeElectionId].finalized) {
            revert ElectionAlreadyActive();
        }

        electionCount++;
        electionId = electionCount;
        _activeElectionId = electionId;

        Election storage election = _elections[electionId];
        election.id = electionId;
        election.candidacyDeadline = block.number + _config.candidacyPeriod;
        election.votingEndBlock = election.candidacyDeadline + _config.electionVotingPeriod;
        election.snapshotBlock = block.number;
        electionToken[electionId] = governanceToken;

        emit ElectionStarted(electionId, election.candidacyDeadline, election.votingEndBlock);
    }

    /// @notice Declares candidacy for `seat` (0 to councilSize - 1) in an
    ///         open election's candidacy window. One seat per election.
    function declareCandidacy(uint256 electionId, uint16 seat) external {
        Election storage election = _elections[electionId];
        if (election.id == 0) revert NoActiveElection();
        if (block.number > election.candidacyDeadline) revert CandidacyWindowClosed();
        if (_isCandidate[electionId][msg.sender]) revert AlreadyCandidate();
        if (seat >= _config.councilSize) revert InvalidSeat();

        uint256 power = IVotesToken(governanceToken).balanceOf(msg.sender);
        if (power < _config.candidacyThreshold) revert CandidacyThresholdNotMet();

        _isCandidate[electionId][msg.sender] = true;
        _seatOf[electionId][msg.sender] = seat + 1;
        _seatCandidates[electionId][seat].push(msg.sender);
        election.candidates.push(msg.sender);

        emit CandidacyDeclared(electionId, msg.sender);
        emit SeatCandidacyDeclared(electionId, seat, msg.sender);
    }

    /// @notice Votes for at most one candidate per seat, using voting power
    ///         snapshotted when the election started; each choice gets the
    ///         voter's whole weight.
    function voteInElection(uint256 electionId, address[] calldata candidates) external {
        Election storage election = _elections[electionId];
        if (election.id == 0) revert NoActiveElection();
        if (block.number <= election.candidacyDeadline) revert ElectionNotYetVoting();
        if (block.number > election.votingEndBlock) revert ElectionVotingClosed();
        if (_hasVotedInElection[electionId][msg.sender]) revert AlreadyVotedInElection();
        if (candidates.length == 0 || candidates.length > _config.councilSize) {
            revert TooManyCandidatesSelected();
        }

        for (uint256 i = 0; i < candidates.length; i++) {
            if (!_isCandidate[electionId][candidates[i]]) revert NotACandidate();
            for (uint256 j = i + 1; j < candidates.length; j++) {
                if (candidates[i] == candidates[j]) revert DuplicateCandidate();
                if (_seatOf[electionId][candidates[i]] == _seatOf[electionId][candidates[j]]) revert TwoCandidatesForOneSeat();
            }
        }

        _hasVotedInElection[electionId][msg.sender] = true;
        uint256 weight = IVotesToken(electionToken[electionId]).getPastVotes(msg.sender, election.snapshotBlock);

        for (uint256 i = 0; i < candidates.length; i++) {
            _electionVotes[electionId][candidates[i]] += weight;
        }

        emit ElectionVoteCast(electionId, msg.sender, weight);
    }

    /// @notice Finalizes an election once voting has closed: each seat goes
    ///         to its most-voted candidate. If a seat is tied and there is a
    ///         randomness source, this requests a draw (send its fee as
    ///         value) and resolveTies seats the council once it's in.
    function finalizeElection(uint256 electionId) external payable {
        Election storage election = _elections[electionId];
        if (election.id == 0) revert NoActiveElection();
        if (block.number <= election.votingEndBlock) revert ElectionVotingNotEnded();
        if (election.finalized) revert ElectionAlreadyFinalized();
        if (awaitingDraw[electionId]) revert DrawPending();

        if (address(randomnessSource) != address(0) && _hasTie(electionId)) {
            awaitingDraw[electionId] = true;
            bytes32 requestId = tieRequestId(electionId);
            randomnessSource.requestRandomness{value: msg.value}(requestId);
            emit TieDrawRequested(electionId, requestId);
            return;
        }
        _seatCouncil(electionId, 0, false);
    }

    /// @notice Seats the council once the draw for tied seats is in.
    function resolveTies(uint256 electionId) external {
        if (!awaitingDraw[electionId]) revert NoDrawPending();
        bytes32 requestId = tieRequestId(electionId);
        if (!randomnessSource.isFulfilled(requestId)) revert DrawPending();
        awaitingDraw[electionId] = false;
        _seatCouncil(electionId, randomnessSource.getRandomness(requestId), true);
    }

    function tieRequestId(uint256 electionId) public view returns (bytes32) {
        return keccak256(abi.encode("delegate-tie", address(this), electionId));
    }

    function _hasTie(uint256 electionId) internal view returns (bool) {
        for (uint16 s = 0; s < _config.councilSize; s++) {
            address[] storage cands = _seatCandidates[electionId][s];
            uint256 best;
            uint256 count;
            for (uint256 i = 0; i < cands.length; i++) {
                uint256 v = _electionVotes[electionId][cands[i]];
                if (i == 0 || v > best) {
                    best = v;
                    count = 1;
                } else if (v == best) {
                    count++;
                }
            }
            if (count > 1) return true;
        }
        return false;
    }

    /// @dev Each seat: its most-voted candidate (a tie: drawn with `rand`, or
    ///      the first to declare); no candidates: the holder stays, unless
    ///      they won another seat, which leaves this one vacant.
    function _seatCouncil(uint256 electionId, uint256 rand, bool useRand) internal {
        Election storage election = _elections[electionId];
        election.finalized = true;
        uint16 seats = _config.councilSize;
        address[] memory next = new address[](seats);
        bool[] memory kept = new bool[](seats);

        for (uint16 s = 0; s < seats; s++) {
            address[] storage cands = _seatCandidates[electionId][s];
            if (cands.length == 0) {
                next[s] = s < council.length ? council[s] : address(0);
                kept[s] = true;
                continue;
            }
            uint256 best;
            uint256 count;
            for (uint256 i = 0; i < cands.length; i++) {
                uint256 v = _electionVotes[electionId][cands[i]];
                if (i == 0 || v > best) {
                    best = v;
                    count = 1;
                } else if (v == best) {
                    count++;
                }
            }
            uint256 pick = useRand && count > 1 ? uint256(keccak256(abi.encode(rand, s))) % count : 0;
            for (uint256 i = 0; i < cands.length; i++) {
                if (_electionVotes[electionId][cands[i]] != best) continue;
                if (pick == 0) {
                    next[s] = cands[i];
                    break;
                }
                pick--;
            }
        }
        // A holder kept on an uncontested seat who also won another seat gives the kept one up.
        for (uint16 s = 0; s < seats; s++) {
            if (!kept[s] || next[s] == address(0)) continue;
            for (uint16 t = 0; t < seats; t++) {
                if (t != s && !kept[t] && next[t] == next[s]) {
                    next[s] = address(0);
                    break;
                }
            }
        }

        for (uint256 i = 0; i < council.length; i++) {
            if (council[i] != address(0)) isCouncilMember[council[i]] = false;
        }
        delete council;
        for (uint16 s = 0; s < seats; s++) {
            council.push(next[s]);
            if (next[s] != address(0)) isCouncilMember[next[s]] = true;
        }

        currentTermEnd = block.timestamp + _config.termLength;

        emit ElectionFinalized(electionId, council);
    }

    /*//////////////////////////////////////////////////////////////
                        COUNCIL PROPOSALS & VOTING
    //////////////////////////////////////////////////////////////*/

    function proposeCouncilAction(
        ProposalAction[] calldata actions,
        string calldata metadataURI
    ) external onlyCouncilMember returns (uint256 proposalId) {
        if (actions.length == 0) revert EmptyProposalActions();
        for (uint256 i = 0; i < actions.length; i++) {
            if (actions[i].target == address(0)) revert InvalidProposalAction();
        }
        if (bytes(metadataURI).length == 0) revert EmptyMetadataURI();

        proposalId = ++proposalCount;
        CouncilProposal storage p = _proposals[proposalId];
        p.id = proposalId;
        p.proposer = msg.sender;
        p.metadataURI = metadataURI;
        p.createdBlock = block.number;
        p.startBlock = block.number + _config.votingDelay;
        p.endBlock = p.startBlock + _config.votingPeriod;

        for (uint256 i = 0; i < actions.length; i++) {
            p.actions.push(actions[i]);
        }

        emit CouncilProposalCreated(proposalId, msg.sender, metadataURI);
    }

    function castCouncilVote(
        uint256 proposalId,
        VoteType support
    ) external onlyCouncilMember proposalExists(proposalId) {
        CouncilProposal storage p = _proposals[proposalId];
        if (p.executed) revert ProposalAlreadyExecuted();
        if (p.cancelled) revert ProposalAlreadyCancelled();
        if (block.number < p.startBlock || block.number > p.endBlock) revert ProposalNotActive();

        CouncilVoteReceipt storage receipt = _voteReceipts[proposalId][msg.sender];
        if (receipt.hasVoted) revert AlreadyVoted();
        receipt.hasVoted = true;
        receipt.support = support;

        if (support == VoteType.For) p.forVotes++;
        else if (support == VoteType.Against) p.againstVotes++;
        else p.abstainVotes++;

        emit CouncilVoteCast(msg.sender, proposalId, support);
    }

    function cancelCouncilProposal(uint256 proposalId) external proposalExists(proposalId) {
        CouncilProposal storage p = _proposals[proposalId];
        if (p.executed) revert ProposalAlreadyExecuted();
        if (p.cancelled) revert ProposalAlreadyCancelled();
        if (msg.sender != p.proposer && msg.sender != address(this)) revert Unauthorized();

        p.cancelled = true;
        emit CouncilProposalCancelled(proposalId, msg.sender);
    }

    function queueCouncilProposal(uint256 proposalId) external proposalExists(proposalId) {
        CouncilProposal storage p = _proposals[proposalId];
        if (p.executed) revert ProposalAlreadyExecuted();
        if (p.cancelled) revert ProposalAlreadyCancelled();
        if (p.queuedAt != 0) revert ProposalAlreadyQueued();
        if (block.number <= p.endBlock) revert ProposalNotActive();

        uint256 participants = uint256(p.forVotes) + p.againstVotes + p.abstainVotes;
        if (participants < _config.councilQuorum) revert CouncilQuorumNotReached();

        uint256 decisive = uint256(p.forVotes) + p.againstVotes;
        if (decisive == 0 || (p.forVotes * 10_000) / decisive < _config.councilApprovalThresholdBps) {
            revert CouncilApprovalNotMet();
        }

        p.queuedAt = block.timestamp;
        emit CouncilProposalQueued(proposalId, block.timestamp + _config.timelockDelay);
    }

    function executeCouncilProposal(uint256 proposalId) external payable proposalExists(proposalId) {
        CouncilProposal storage p = _proposals[proposalId];
        if (p.executed) revert ProposalAlreadyExecuted();
        if (p.cancelled) revert ProposalAlreadyCancelled();
        if (p.queuedAt == 0) revert ProposalNotExecutable();
        if (block.timestamp < p.queuedAt + _config.timelockDelay) revert ProposalNotExecutable();
        if (block.timestamp > p.queuedAt + _config.timelockDelay + _config.executionPeriod) {
            revert ProposalExpired();
        }

        uint256 totalValue;
        uint256 len = p.actions.length;
        for (uint256 i = 0; i < len; i++) totalValue += p.actions[i].value;
        if (msg.value != totalValue) revert InvalidValue();

        p.executed = true;

        for (uint256 i = 0; i < len; i++) {
            ProposalAction storage action = p.actions[i];
            (bool ok, ) = action.target.call{value: action.value}(action.data);
            if (!ok) revert ExecutionFailed();
        }

        emit CouncilProposalExecuted(proposalId, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                                RECALL
    //////////////////////////////////////////////////////////////*/

    /// @notice Initiates a recall vote against a current council member.
    ///         Anyone meeting the candidacy threshold (reused here as the
    ///         recall-initiation bar) may call this.
    function initiateRecall(address delegate) external returns (uint256 recallId) {
        if (!isCouncilMember[delegate]) revert NotCurrentlyOnCouncil();
        uint256 power = IVotesToken(governanceToken).balanceOf(msg.sender);
        if (power < _config.candidacyThreshold) revert CandidacyThresholdNotMet();

        recallCount++;
        recallId = recallCount;

        RecallVote storage r = _recalls[recallId];
        r.id = recallId;
        r.delegate = delegate;
        r.endBlock = block.number + _config.recallVotingPeriod;
        r.snapshotBlock = block.number;
        recallToken[recallId] = governanceToken;

        emit RecallInitiated(recallId, delegate, msg.sender);
    }

    function voteRecall(uint256 recallId, VoteType support) external {
        RecallVote storage r = _recalls[recallId];
        if (r.id == 0) revert NoActiveRecall();
        if (block.number > r.endBlock) revert RecallVotingClosed();
        if (r.finalized) revert RecallAlreadyFinalized();
        if (_hasVotedInRecall[recallId][msg.sender]) revert AlreadyVoted();

        uint256 weight = IVotesToken(recallToken[recallId]).getPastVotes(msg.sender, r.snapshotBlock);
        _hasVotedInRecall[recallId][msg.sender] = true;

        if (support == VoteType.For) r.forVotes += weight;
        else if (support == VoteType.Against) r.againstVotes += weight;
        else r.abstainVotes += weight;

        emit RecallVoteCast(recallId, msg.sender, support, weight);
    }

    /// @notice Finalizes a recall vote. If quorum and approval are met and
    ///         the target is still on the council, they're removed
    ///         immediately - the seat sits vacant until the next election.
    function finalizeRecall(uint256 recallId) external {
        RecallVote storage r = _recalls[recallId];
        if (r.id == 0) revert NoActiveRecall();
        if (block.number <= r.endBlock) revert RecallVotingNotEnded();
        if (r.finalized) revert RecallAlreadyFinalized();
        r.finalized = true;

        uint256 totalSupply = IVotesToken(recallToken[recallId]).getPastTotalSupply(r.snapshotBlock);
        uint256 participation = r.forVotes + r.againstVotes + r.abstainVotes;
        bool quorumMet = totalSupply != 0 && (participation * 10_000) / totalSupply >= _config.recallQuorumBps;

        uint256 decisive = r.forVotes + r.againstVotes;
        bool approvalMet = decisive != 0 && (r.forVotes * 10_000) / decisive >= _config.recallApprovalThresholdBps;

        if (quorumMet && approvalMet && isCouncilMember[r.delegate]) {
            isCouncilMember[r.delegate] = false;
            for (uint256 i = 0; i < council.length; i++) {
                if (council[i] == r.delegate) {
                    council[i] = address(0); // the seat sits vacant
                    break;
                }
            }
            r.executed = true;
        }

        emit RecallFinalized(recallId, r.delegate, r.executed);
    }

    /*//////////////////////////////////////////////////////////////
                    GOVERNANCE-ONLY ADMIN (self-call)
    //////////////////////////////////////////////////////////////*/

    function updateConfig(DelegateGovernanceConfig calldata newConfig) external onlyGovernance {
        _validateConfig(newConfig);
        _config = newConfig;
        emit ConfigUpdated();
    }

    function setGovernanceToken(address newToken) external onlyGovernance {
        if (newToken == address(0)) revert ZeroAddress();
        emit GovernanceTokenUpdated(governanceToken, newToken);
        governanceToken = newToken;
    }

    function setSeatLabel(uint16 seat, string calldata label) external onlyGovernance {
        if (seat >= _config.councilSize) revert InvalidSeat();
        seatLabel[seat] = label;
        emit SeatLabelSet(seat, label);
    }

    function setRandomnessSource(address source) external onlyGovernance {
        randomnessSource = IRandomnessSource(source);
    }

    function setTreasury(address newTreasury) external onlyGovernance {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function config() external view returns (DelegateGovernanceConfig memory) {
        return _config;
    }

    /// @notice The council by seat; address(0) is a vacant seat.
    function getCouncil() external view returns (address[] memory) {
        return council;
    }

    /// @notice The candidates for `seat` in an election.
    function seatCandidates(uint256 electionId, uint16 seat) external view returns (address[] memory) {
        return _seatCandidates[electionId][seat];
    }

    /// @notice The seat a candidate runs for in an election, and whether they run.
    function seatOf(uint256 electionId, address candidate) external view returns (uint16 seat, bool running) {
        uint16 v = _seatOf[electionId][candidate];
        return (v == 0 ? 0 : v - 1, v != 0);
    }

    function electionVotes(uint256 electionId, address candidate) external view returns (uint256) {
        return _electionVotes[electionId][candidate];
    }

    function getProposal(uint256 proposalId) external view proposalExists(proposalId) returns (CouncilProposal memory) {
        return _proposals[proposalId];
    }

    function getVoteReceipt(uint256 proposalId, address delegate) external view returns (CouncilVoteReceipt memory) {
        return _voteReceipts[proposalId][delegate];
    }

    function getElection(uint256 electionId) external view returns (Election memory) {
        return _elections[electionId];
    }

    function getRecall(uint256 recallId) external view returns (RecallVote memory) {
        return _recalls[recallId];
    }

    function state(uint256 proposalId) public view proposalExists(proposalId) returns (ProposalState) {
        CouncilProposal storage p = _proposals[proposalId];

        if (p.cancelled) return ProposalState.Cancelled;
        if (p.executed) return ProposalState.Executed;
        if (block.number < p.startBlock) return ProposalState.Pending;
        if (block.number <= p.endBlock) return ProposalState.Active;

        if (p.queuedAt != 0) {
            if (block.timestamp > p.queuedAt + _config.timelockDelay + _config.executionPeriod) {
                return ProposalState.Expired;
            }
            return ProposalState.Queued;
        }

        uint256 participants = uint256(p.forVotes) + p.againstVotes + p.abstainVotes;
        uint256 decisive = uint256(p.forVotes) + p.againstVotes;
        bool succeeded = participants >= _config.councilQuorum &&
            decisive != 0 &&
            (p.forVotes * 10_000) / decisive >= _config.councilApprovalThresholdBps;

        return succeeded ? ProposalState.Succeeded : ProposalState.Defeated;
    }

    function executableAfter(uint256 proposalId) external view proposalExists(proposalId) returns (uint256) {
        CouncilProposal storage p = _proposals[proposalId];
        if (p.queuedAt == 0) return 0;
        return p.queuedAt + _config.timelockDelay;
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL VALIDATION
    //////////////////////////////////////////////////////////////*/

    function _validateConfig(DelegateGovernanceConfig memory c) internal pure {
        if (c.councilSize == 0) revert InvalidConfiguration();
        if (c.termLength == 0) revert InvalidConfiguration();
        if (c.candidacyPeriod == 0) revert InvalidConfiguration();
        if (c.electionVotingPeriod == 0) revert InvalidConfiguration();
        if (c.councilQuorum == 0 || c.councilQuorum > c.councilSize) revert InvalidConfiguration();
        if (c.councilApprovalThresholdBps == 0 || c.councilApprovalThresholdBps > 10_000) {
            revert InvalidConfiguration();
        }
        if (c.votingPeriod == 0) revert InvalidConfiguration();
        if (c.recallQuorumBps == 0 || c.recallQuorumBps > 10_000) revert InvalidConfiguration();
        if (c.recallApprovalThresholdBps == 0 || c.recallApprovalThresholdBps > 10_000) {
            revert InvalidConfiguration();
        }
        if (c.recallVotingPeriod == 0) revert InvalidConfiguration();
    }
}
