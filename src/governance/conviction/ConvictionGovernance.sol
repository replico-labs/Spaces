// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @dev Minimal interface into a DAO's StakedGovernanceToken - only the
///      current balance is needed here (see the design note below on why
///      this model has no fixed snapshot block).
interface IBalanceToken {
    function balanceOf(address account) external view returns (uint256);
}

/// @dev Interface into StakedGovernanceToken's optional lock capability.
///      This contract must be set as the token's `authorizedLocker` for
///      these calls to succeed - see StakedGovernanceToken.setAuthorizedLocker.
interface ILockableToken {
    function lock(address account, uint256 amount) external;
    function unlock(address account, uint256 amount) external;
}

/// @title ConvictionGovernance
/// @author Marvin Sunday
/// @notice A conviction-voting governance model: holders continuously 
///         signal support for a proposal (one at a time) rather than
///         casting a single vote in a fixed window. Support accumulates
///         into "conviction" the longer it's sustained; a proposal becomes
///         executable once its conviction crosses a threshold that scales
///         with how much it's requesting.
/// @dev IMPORTANT DESIGN NOTE - read before assuming this matches the
///      academic/1Hive model of conviction voting:
///
///      1. LINEAR RAMP, NOT EXPONENTIAL DECAY. The canonical model computes
///         conviction via fixed-point exponentiation (conviction_new =
///         alpha^n * conviction_old + support * (1 - alpha^n)), giving a
///         smooth compound-decay curve. That formula is a real source of
///         subtle on-chain bugs (precision loss compounding over many
///         updates, overflow at extreme block gaps) and needs fuzz/
///         invariant testing to trust - infrastructure this build could
///         not run. This contract instead moves conviction linearly toward
///         current total support, at a fixed rate per block, clamped so it
///         never overshoots. Same behavioral properties - sustained
///         support outweighs a quick spike, withdrawn support decays back
///         down - verifiable by inspection rather than by fuzzing.
///
///      2. THRESHOLD IS LINEAR IN REQUESTED AMOUNT, NOT A RATIO TO POOL
///         SIZE. The canonical model's required-conviction curve grows
///         nonlinearly as the request approaches the treasury's total
///         balance (division by a shrinking denominator). This contract
///         uses `minThresholdConviction + requestedAmount * thresholdMultiplier`
///         instead - still strictly harder for bigger asks, but without a
///         division that could blow up or divide by zero, and without an
///         external treasury-balance read on every check.
///
///      3. SUPPORT WEIGHT IS FIXED AT THE TIME OF SUPPORTING, AND LOCKED.
///         A holder's contribution to a proposal's support is set to
///         whatever their balance was when they called `support()` - if
///         they acquire more tokens afterward, that extra amount does not
///         automatically join their existing support; they'd need to
///         withdraw and re-support to pick up a larger balance. What IS
///         enforced automatically: the committed amount is locked via
///         StakedGovernanceToken's lock()/unlock() (see
///         setAuthorizedLocker) for as long as it's backing a proposal -
///         it cannot be transferred or unstaked out from under a
///         proposal's conviction while committed, closing the "sell after
///         voting" gap that a pure balance snapshot alone would leave
///         open. This governance contract must be set as the token's
///         authorizedLocker for support()/withdrawSupport() to work -
///         see the deployment notes on StakedGovernanceToken.
///
///      4. ONE ACTIVE SUPPORT PER HOLDER, DAO-WIDE. Supporting a new
///         proposal automatically withdraws support from whatever a
///         holder was previously backing - this is not a simplification,
///         it's the actual anti-gaming rule the real model relies on
///         (without it, one holder could back every proposal at once with
///         full weight each).
///
///      Drops into the same trusted-`governance` slot on Treasury as every
///      other implementation here, and reuses the DAO's existing
///      StakedGovernanceToken.
contract ConvictionGovernance is Initializable {
    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    enum ProposalState {
        Active, // accumulating conviction, not yet queued
        Queued,
        Executed,
        Cancelled,
        Expired
    }

    struct ProposalAction {
        address target;
        uint256 value;
        bytes data;
    }

    struct Proposal {
        uint256 id;
        ProposalAction[] actions;
        address proposer;
        string metadataURI;
        uint256 createdBlock;
        uint256 requestedAmount; // sum of ETH values across actions
        uint256 conviction; // settled as of lastConvictionUpdateBlock
        uint256 lastConvictionUpdateBlock;
        uint256 queuedAt;
        bool executed;
        bool cancelled;
    }

    struct ConvictionGovernanceConfig {
        uint256 convictionGrowthRate; // conviction units gained/lost per block, capped at target
        uint256 minThresholdConviction; // floor required conviction for near-zero requests
        uint256 thresholdMultiplier; // additional required conviction per wei requested
        uint256 proposalThreshold; // raw balance required to propose
        uint32 timelockDelay; // seconds
        uint32 executionPeriod; // seconds
    }

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error InvalidConfiguration();
    error EmptyProposalActions();
    error EmptyMetadataURI();
    error InvalidProposalAction();
    error ProposalThresholdNotMet();
    error ProposalNotFound();
    error ProposalAlreadyExecuted();
    error ProposalAlreadyCancelled();
    error AlreadySupportingThisProposal();
    error NotCurrentlySupporting();
    error ConvictionThresholdNotMet();
    error ProposalAlreadyQueued();
    error ProposalNotExecutable();
    error ProposalExpired();
    error ExecutionFailed();
    error InvalidValue();
    error Unauthorized();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event ProposalCreated(uint256 indexed proposalId, address indexed proposer, string metadataURI, uint256 requestedAmount);
    event Supported(uint256 indexed proposalId, address indexed supporter, uint256 weight);
    event SupportWithdrawn(uint256 indexed proposalId, address indexed supporter, uint256 weight);
    event ProposalCancelled(uint256 indexed proposalId, address indexed caller);
    event ProposalQueued(uint256 indexed proposalId, uint256 executeAfter);
    event ProposalExecuted(uint256 indexed proposalId, address indexed executor);
    event ConfigUpdated();
    event GovernanceTokenUpdated(address indexed previousToken, address indexed newToken);
    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    string public daoName;
    address public creator;
    address public governanceToken;
    address public treasury;
    ConvictionGovernanceConfig internal _config;

    uint256 public proposalCount;
    mapping(uint256 => Proposal) internal _proposals;

    /// @notice Live total support currently backing a proposal.
    mapping(uint256 => uint256) public totalSupport;
    /// @notice Which proposal (0 = none) a holder currently supports.
    mapping(address => uint256) public currentSupportProposal;
    /// @notice A holder's fixed contribution to whichever proposal they support.
    mapping(uint256 => mapping(address => uint256)) public supporterWeight;

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

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
        ConvictionGovernanceConfig memory config_
    ) external initializer {
        if (creator_ == address(0) || governanceToken_ == address(0) || treasury_ == address(0)) {
            revert ZeroAddress();
        }
        _validateConfig(config_);

        daoName = daoName_;
        creator = creator_;
        governanceToken = governanceToken_;
        treasury = treasury_;
        _config = config_;
    }

    /*//////////////////////////////////////////////////////////////
                        PROPOSAL CREATION
    //////////////////////////////////////////////////////////////*/

    function propose(
        ProposalAction[] calldata actions,
        string calldata metadataURI
    ) external returns (uint256 proposalId) {
        _requireProposalThreshold(msg.sender);

        if (actions.length == 0) revert EmptyProposalActions();
        uint256 requestedAmount;
        for (uint256 i = 0; i < actions.length; i++) {
            if (actions[i].target == address(0)) revert InvalidProposalAction();
            requestedAmount += actions[i].value;
        }
        if (bytes(metadataURI).length == 0) revert EmptyMetadataURI();

        proposalId = ++proposalCount;
        Proposal storage p = _proposals[proposalId];
        p.id = proposalId;
        p.proposer = msg.sender;
        p.metadataURI = metadataURI;
        p.createdBlock = block.number;
        p.requestedAmount = requestedAmount;
        p.lastConvictionUpdateBlock = block.number;

        for (uint256 i = 0; i < actions.length; i++) {
            p.actions.push(actions[i]);
        }

        emit ProposalCreated(proposalId, msg.sender, metadataURI, requestedAmount);
    }

    /*//////////////////////////////////////////////////////////////
                        SUPPORT / WITHDRAWAL
    //////////////////////////////////////////////////////////////*/

    /// @notice Backs a proposal with the caller's current staked balance.
    ///         Automatically withdraws support from any other proposal the
    ///         caller was previously backing - only one active support per
    ///         holder DAO-wide.
    function support(uint256 proposalId) external proposalExists(proposalId) {
        Proposal storage p = _proposals[proposalId];
        if (p.executed) revert ProposalAlreadyExecuted();
        if (p.cancelled) revert ProposalAlreadyCancelled();

        uint256 previous = currentSupportProposal[msg.sender];
        if (previous == proposalId) revert AlreadySupportingThisProposal();

        uint256 oldWeight;
        bool hadPrevious = previous != 0;

        if (hadPrevious) {
            _settleConviction(previous);
            oldWeight = supporterWeight[previous][msg.sender];
            totalSupport[previous] -= oldWeight;
            supporterWeight[previous][msg.sender] = 0;
            emit SupportWithdrawn(previous, msg.sender, oldWeight);
        }

        _settleConviction(proposalId);

        uint256 weight = IBalanceToken(governanceToken).balanceOf(msg.sender);
        supporterWeight[proposalId][msg.sender] = weight;
        totalSupport[proposalId] += weight;
        currentSupportProposal[msg.sender] = proposalId;

        // External calls after all local state effects above.
        if (hadPrevious) {
            ILockableToken(governanceToken).unlock(msg.sender, oldWeight);
        }
        ILockableToken(governanceToken).lock(msg.sender, weight);

        emit Supported(proposalId, msg.sender, weight);
    }

    /// @notice Withdraws the caller's support from whatever proposal they
    ///         currently back, freeing their weight to support elsewhere.
    function withdrawSupport() external {
        uint256 current = currentSupportProposal[msg.sender];
        if (current == 0) revert NotCurrentlySupporting();

        _settleConviction(current);
        uint256 weight = supporterWeight[current][msg.sender];
        totalSupport[current] -= weight;
        supporterWeight[current][msg.sender] = 0;
        currentSupportProposal[msg.sender] = 0;

        ILockableToken(governanceToken).unlock(msg.sender, weight);

        emit SupportWithdrawn(current, msg.sender, weight);
    }

    /*//////////////////////////////////////////////////////////////
                        CONVICTION ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    /// @dev Settles a proposal's conviction up to the current block, moving
    ///      it linearly toward `totalSupport`, clamped so it never
    ///      overshoots. Must be called before `totalSupport` changes, so
    ///      the elapsed-block gap is always settled against the support
    ///      level that was actually in effect during that gap.
    function _settleConviction(uint256 proposalId) internal {
        Proposal storage p = _proposals[proposalId];
        uint256 blocksElapsed = block.number - p.lastConvictionUpdateBlock;
        if (blocksElapsed == 0) return;

        uint256 target = totalSupport[proposalId];
        uint256 maxDelta = _config.convictionGrowthRate * blocksElapsed;

        if (p.conviction < target) {
            uint256 gap = target - p.conviction;
            p.conviction += (maxDelta < gap) ? maxDelta : gap;
        } else if (p.conviction > target) {
            uint256 gap = p.conviction - target;
            p.conviction -= (maxDelta < gap) ? maxDelta : gap;
        }

        p.lastConvictionUpdateBlock = block.number;
    }

    /// @notice Previews what a proposal's conviction would settle to right
    ///         now, without writing state - safe to call from a frontend
    ///         at any time.
    function previewConviction(uint256 proposalId) public view proposalExists(proposalId) returns (uint256) {
        Proposal storage p = _proposals[proposalId];
        uint256 blocksElapsed = block.number - p.lastConvictionUpdateBlock;
        if (blocksElapsed == 0) return p.conviction;

        uint256 target = totalSupport[proposalId];
        uint256 maxDelta = _config.convictionGrowthRate * blocksElapsed;

        if (p.conviction < target) {
            uint256 gap = target - p.conviction;
            return p.conviction + ((maxDelta < gap) ? maxDelta : gap);
        } else if (p.conviction > target) {
            uint256 gap = p.conviction - target;
            return p.conviction - ((maxDelta < gap) ? maxDelta : gap);
        }
        return p.conviction;
    }

    /// @notice The conviction a proposal must reach before it can queue.
    function requiredConviction(uint256 proposalId) public view proposalExists(proposalId) returns (uint256) {
        Proposal storage p = _proposals[proposalId];
        return _config.minThresholdConviction + (p.requestedAmount * _config.thresholdMultiplier);
    }

    /*//////////////////////////////////////////////////////////////
                        PROPOSAL CANCELLATION
    //////////////////////////////////////////////////////////////*/

    function cancelProposal(uint256 proposalId) external proposalExists(proposalId) {
        Proposal storage p = _proposals[proposalId];
        if (p.executed) revert ProposalAlreadyExecuted();
        if (p.cancelled) revert ProposalAlreadyCancelled();
        if (msg.sender != p.proposer && msg.sender != address(this)) revert Unauthorized();

        p.cancelled = true;
        emit ProposalCancelled(proposalId, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                        PROPOSAL QUEUEING
    //////////////////////////////////////////////////////////////*/

    function queueProposal(uint256 proposalId) external proposalExists(proposalId) {
        Proposal storage p = _proposals[proposalId];
        if (p.executed) revert ProposalAlreadyExecuted();
        if (p.cancelled) revert ProposalAlreadyCancelled();
        if (p.queuedAt != 0) revert ProposalAlreadyQueued();

        _settleConviction(proposalId);

        if (p.conviction < requiredConviction(proposalId)) revert ConvictionThresholdNotMet();

        p.queuedAt = block.timestamp;
        emit ProposalQueued(proposalId, block.timestamp + _config.timelockDelay);
    }

    /*//////////////////////////////////////////////////////////////
                        PROPOSAL EXECUTION
    //////////////////////////////////////////////////////////////*/

    function executeProposal(uint256 proposalId) external payable proposalExists(proposalId) {
        Proposal storage p = _proposals[proposalId];
        if (p.executed) revert ProposalAlreadyExecuted();
        if (p.cancelled) revert ProposalAlreadyCancelled();
        if (p.queuedAt == 0) revert ProposalNotExecutable();
        if (block.timestamp < p.queuedAt + _config.timelockDelay) revert ProposalNotExecutable();
        if (block.timestamp > p.queuedAt + _config.timelockDelay + _config.executionPeriod) {
            revert ProposalExpired();
        }

        if (msg.value != p.requestedAmount) revert InvalidValue();

        p.executed = true;

        uint256 len = p.actions.length;
        for (uint256 i = 0; i < len; i++) {
            ProposalAction storage action = p.actions[i];
            (bool ok, ) = action.target.call{value: action.value}(action.data);
            if (!ok) revert ExecutionFailed();
        }

        emit ProposalExecuted(proposalId, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                    GOVERNANCE-ONLY ADMIN (self-call)
    //////////////////////////////////////////////////////////////*/

    function updateGovernanceConfig(ConvictionGovernanceConfig calldata newConfig) external onlyGovernance {
        _validateConfig(newConfig);
        _config = newConfig;
        emit ConfigUpdated();
    }

    function setGovernanceToken(address newToken) external onlyGovernance {
        if (newToken == address(0)) revert ZeroAddress();
        emit GovernanceTokenUpdated(governanceToken, newToken);
        governanceToken = newToken;
    }

    function setTreasury(address newTreasury) external onlyGovernance {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function config() external view returns (ConvictionGovernanceConfig memory) {
        return _config;
    }

    function getProposal(uint256 proposalId) external view proposalExists(proposalId) returns (Proposal memory) {
        return _proposals[proposalId];
    }

    function state(uint256 proposalId) public view proposalExists(proposalId) returns (ProposalState) {
        Proposal storage p = _proposals[proposalId];

        if (p.cancelled) return ProposalState.Cancelled;
        if (p.executed) return ProposalState.Executed;

        if (p.queuedAt != 0) {
            if (block.timestamp > p.queuedAt + _config.timelockDelay + _config.executionPeriod) {
                return ProposalState.Expired;
            }
            return ProposalState.Queued;
        }

        return ProposalState.Active;
    }

    function executableAfter(uint256 proposalId) external view proposalExists(proposalId) returns (uint256) {
        Proposal storage p = _proposals[proposalId];
        if (p.queuedAt == 0) return 0;
        return p.queuedAt + _config.timelockDelay;
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL VALIDATION
    //////////////////////////////////////////////////////////////*/

    function _requireProposalThreshold(address proposer) internal view {
        uint256 threshold = _config.proposalThreshold;
        if (threshold == 0) return;

        uint256 balance = IBalanceToken(governanceToken).balanceOf(proposer);
        if (balance < threshold) revert ProposalThresholdNotMet();
    }

    function _validateConfig(ConvictionGovernanceConfig memory c) internal pure {
        if (c.convictionGrowthRate == 0) revert InvalidConfiguration();
    }
}
