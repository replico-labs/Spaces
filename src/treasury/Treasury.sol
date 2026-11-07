// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./../interfaces/ITreasury.sol";

/// @dev Clone-compatible version - converted from constructor-based
///      initialization to initialize(), same reasoning as
///      GovernanceToken.sol/StakedGovernanceToken.sol: every factory in
///      this system was embedding this contract's full creation bytecode
///      via `new Treasury(...)`, a major contributor to every factory
///      exceeding Ethereum's 24,576-byte contract size limit. No
///      immutable-to-storage concern here - `governance` was always
///      regular storage, not immutable, so this conversion is otherwise
///      a direct, faithful port of the original constructor's logic.
contract Treasury is Initializable, ITreasury {
    using SafeERC20 for IERC20;

    address public override governance;

    /// @notice How long one allowance period lasts.
    uint256 public constant ALLOWANCE_PERIOD = 30 days;

    /// @notice The longest an allowance can run before it must be renewed by a new proposal.
    uint256 public constant MAX_ALLOWANCE_DURATION = 365 days;

    /// @notice A monthly allowance: `recipient` claims `amount` of `token`
    ///         (address(0) for the native coin) once per 30-day period from
    ///         `start` until `endsAt`. A period not claimed in time lapses.
    struct Allowance {
        address recipient;
        address token;
        uint256 amount;
        uint64 start;
        uint64 endsAt;
        /// @dev The number of the last period paid, counted from 1 (0: none yet).
        uint64 paidThrough;
        bool revoked;
    }

    /// @notice Every allowance this Treasury has granted, by id (from 1).
    mapping(uint256 => Allowance) internal _allowances;

    /// @notice How many allowances have been created; the latest id.
    uint256 public override allowanceCount;

    /// @notice A launch contract that may set the allowances agreed in a
    ///         DAO's launch terms, only in the block the DAO is created in
    ///         (see setSetupAuthority). Zero otherwise.
    address public setupAuthority;

    /// @notice The block setupAuthority may act in.
    uint256 public setupBlock;

    modifier onlyGovernance() {
        if (msg.sender != governance) revert Unauthorized();
        _;
    }

    /// @dev Locks initializers on the implementation contract itself -
    ///      standard OpenZeppelin upgradeable-contracts practice, so
    ///      nobody can call initialize() directly on the implementation
    ///      (only on clones, which get their own independent storage).
    constructor() {
        _disableInitializers();
    }

    function initialize(address governance_) external initializer {
        if (governance_ == address(0)) revert ZeroAddress();
        governance = governance_;
    }

    receive() external payable {
        emit ETHReceived(msg.sender, msg.value);
    }

    function ethBalance() external view override returns (uint256) {
        return address(this).balance;
    }

    function tokenBalance(address token) external view override returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    function transferETH(address payable recipient,uint256 amount)
        external
        override
        onlyGovernance
    {
        if (recipient == address(0)) revert ZeroAddress();
        if (address(this).balance < amount) revert InsufficientBalance();

        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit ETHTransferred(recipient, amount);
    }

    function transferERC20(address token,address recipient,uint256 amount)
        external
        override
        onlyGovernance
    {
        if (recipient == address(0) || token == address(0)) revert ZeroAddress();
        bool ok = IERC20(token).transfer(recipient, amount);
        if (!ok) revert TransferFailed();

        emit ERC20Transferred(token, recipient, amount);
    }

    function execute(address target,uint256 value,bytes calldata data)
        external
        override
        onlyGovernance
        returns (bytes memory)
    {
        if (target == address(0)) revert ZeroAddress();
        (bool ok, bytes memory result)=target.call{value:value}(data);
        if(!ok) revert TransferFailed();
        return result;
    }

    function transferGovernance(address newGovernance)
        external
        override
        onlyGovernance
    {
        if(newGovernance==address(0)) revert ZeroAddress();
        address old=governance;
        governance=newGovernance;
        emit OwnershipTransferred(old,newGovernance);
    }

    /*//////////////////////////////////////////////////////////////
                            ALLOWANCES
    //////////////////////////////////////////////////////////////*/

    /// @notice Grants `recipient` `amount` of `token` (address(0): the
    ///         native coin) every 30 days from now until `endsAt`, at most a
    ///         year away. Only governance: a passed proposal, or the
    ///         security council's wrapper when there is one.
    function createAllowance(address recipient, address token, uint256 amount, uint64 endsAt)
        external
        override
        returns (uint256 id)
    {
        if (msg.sender != governance && !(msg.sender == setupAuthority && block.number == setupBlock)) revert Unauthorized();
        if (recipient == address(0)) revert ZeroAddress();
        _checkTerms(amount, block.timestamp, endsAt);
        id = ++allowanceCount;
        _allowances[id] = Allowance({
            recipient: recipient,
            token: token,
            amount: amount,
            start: uint64(block.timestamp),
            endsAt: endsAt,
            paidThrough: 0,
            revoked: false
        });
        emit AllowanceCreated(id, recipient, token, amount, endsAt);
    }

    /// @notice Lets `authority`, a launch contract creating this DAO, set
    ///         the allowances agreed in its launch terms, in this block only.
    ///         Called by the factory while it's still the governance; a
    ///         creator without code (a wallet) is ignored, so only a launch
    ///         contract ever gets the window.
    function setSetupAuthority(address authority) external override onlyGovernance {
        if (authority.code.length == 0) return;
        setupAuthority = authority;
        setupBlock = block.number;
        emit SetupAuthoritySet(authority);
    }

    /// @notice The launch contract closes its window once it's done.
    function endSetup() external override {
        if (msg.sender != setupAuthority) revert Unauthorized();
        setupAuthority = address(0);
        setupBlock = 0;
        emit SetupAuthoritySet(address(0));
    }

    /// @notice Changes an allowance's amount and end. Periods already paid
    ///         stay paid; the end is still at most a year from its start.
    function updateAllowance(uint256 id, uint256 amount, uint64 endsAt) external override onlyGovernance {
        Allowance storage a = _live(id);
        _checkTerms(amount, a.start, endsAt);
        a.amount = amount;
        a.endsAt = endsAt;
        emit AllowanceUpdated(id, amount, endsAt);
    }

    /// @notice Ends an allowance now: nothing more can be claimed from it.
    function revokeAllowance(uint256 id) external override onlyGovernance {
        Allowance storage a = _live(id);
        a.revoked = true;
        emit AllowanceRevoked(id);
    }

    /// @notice The recipient claims the current period's payment. Missed
    ///         periods lapse: this only ever pays the period it's in.
    function claimAllowance(uint256 id) external override returns (uint256 amount) {
        Allowance storage a = _live(id);
        if (msg.sender != a.recipient) revert Unauthorized();
        if (block.timestamp >= a.endsAt) revert AllowanceEnded();
        uint64 period = _period(a);
        if (period <= a.paidThrough) revert AllowanceAlreadyClaimed(a.start + uint256(period) * ALLOWANCE_PERIOD);
        a.paidThrough = period;
        amount = a.amount;
        if (a.token == address(0)) {
            if (address(this).balance < amount) revert InsufficientBalance();
            (bool ok,) = payable(a.recipient).call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(a.token).safeTransfer(a.recipient, amount);
        }
        emit AllowanceClaimed(id, a.recipient, period, amount);
    }

    /// @notice An allowance's terms and state.
    function allowance(uint256 id) external view returns (Allowance memory) {
        return _allowances[id];
    }

    /// @notice What `claimAllowance(id)` would pay now (0 if nothing), and
    ///         when the next period opens.
    function claimableAllowance(uint256 id) external view override returns (uint256 amount, uint256 nextAt) {
        Allowance storage a = _allowances[id];
        if (a.recipient == address(0) || a.revoked || block.timestamp >= a.endsAt) return (0, 0);
        uint64 period = _period(a);
        nextAt = a.start + uint256(period) * ALLOWANCE_PERIOD;
        if (nextAt >= a.endsAt) nextAt = 0;
        amount = period > a.paidThrough ? a.amount : 0;
    }

    /// @dev The period now, counted from 1.
    function _period(Allowance storage a) internal view returns (uint64) {
        return uint64((block.timestamp - a.start) / ALLOWANCE_PERIOD) + 1;
    }

    function _live(uint256 id) internal view returns (Allowance storage a) {
        a = _allowances[id];
        if (a.recipient == address(0)) revert AllowanceNotFound();
        if (a.revoked) revert AllowanceEnded();
    }

    function _checkTerms(uint256 amount, uint256 start, uint64 endsAt) internal view {
        if (amount == 0) revert InvalidAllowance();
        if (endsAt <= block.timestamp || endsAt > start + MAX_ALLOWANCE_DURATION) revert InvalidAllowance();
    }
}
