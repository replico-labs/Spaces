// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

interface IDistributorTreasury {
    function governance() external view returns (address);
}

/// @dev A security council's wrapper answers with the governance it serves.
interface IAnswersToGovernance {
    function governance() external view returns (address);
}

/// @dev Delegate governance: its elected council.
interface ICouncilGovernance {
    function isCouncilMember(address who) external view returns (bool);
}

/// @title Distributor
/// @notice Holds every token a DAO has promised someone - raise shares, team
///         and community shares from a launch, grants by proposal, welcome
///         grants - and lets each owner claim what has vested.
/// @dev One clone per DAO token. An allocation can belong to an address, to
///      a chat account (`account`: a hash of platform and user id, set by the
///      bot), or both:
///      - the owning address can always claim for itself;
///      - for an account, the operator (the bot) claims into that member's
///        current wallet, after checking who they are in the group. That is
///        the one place the bot's word counts.
///      Every allocation is backed by tokens already held here: allocating
///      more than the unpromised balance reverts.
///
///      Admin is whoever the DAO's Treasury answers to (its governance, or
///      the security council's wrapper), read live, so it follows model
///      switches without being told.
contract Distributor is Initializable {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The token handed out.
    address public token;

    /// @notice The DAO's Treasury: admin is whoever it answers to, and
    ///         what's left goes back to it.
    address public treasury;

    /// @notice The bot's operator wallet: claims for chat accounts.
    address public operator;

    /// @notice Contracts that may write allocations (a raise, a launch).
    mapping(address => bool) public isAllocator;

    struct Allocation {
        address owner; // may be zero when only `account` is known
        bytes32 account; // may be zero for an address-only allocation
        uint256 total;
        uint256 claimed;
        uint64 start; // vesting starts
        uint64 cliff; // nothing vests before start + cliff
        uint64 duration; // all vested at start + duration (0: all at start + cliff)
    }

    mapping(uint256 => Allocation) internal _allocations;

    /// @notice How many allocations exist; the latest id.
    uint256 public allocationCount;

    /// @notice Tokens promised and not yet claimed.
    uint256 public outstanding;

    /// @notice After this time the admin may close the Distributor and
    ///         return everything unclaimed to the Treasury (0: never).
    uint64 public claimDeadline;

    /// @notice Whether the Distributor has been closed.
    bool public closed;

    /// @notice A welcome grant's size (0: welcome grants off).
    uint256 public welcomeAmount;

    /// @notice The most welcome grants may hand out in total.
    uint256 public welcomeCap;

    /// @notice Welcome grants handed out so far.
    uint256 public welcomeGranted;

    /// @notice Accounts (or addresses, as bytes32) already welcomed.
    mapping(bytes32 => bool) public welcomed;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Allocated(uint256 indexed id, address indexed owner, bytes32 indexed account, uint256 amount, uint64 start, uint64 cliff, uint64 duration);
    event Claimed(uint256 indexed id, address indexed to, uint256 amount);
    event WelcomeGranted(uint256 indexed id, address indexed member, bytes32 indexed account, address approver);
    event WelcomeTermsSet(uint256 amount, uint256 cap);
    event AllocatorSet(address indexed allocator, bool allowed);
    event OperatorSet(address indexed operator);
    event ClaimDeadlineSet(uint64 deadline);
    event Returned(uint256 amount);
    event Closed(uint256 returned);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error Unauthorized();
    error ZeroAddress();
    error ZeroAmount();
    error NoOwner();
    error NotFunded(uint256 available, uint256 needed);
    error NothingToClaim();
    error NotForAccounts();
    error WelcomeOff();
    error AlreadyWelcomed();
    error WelcomeCapReached();
    error NotCouncilMember();
    error DistributorClosed();
    error TooEarly(uint64 deadline);

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    constructor() {
        _disableInitializers();
    }

    /// @param allocators_ contracts that may allocate from the start (a
    ///        launch, a raise); may be empty.
    function initialize(address token_, address treasury_, address operator_, address[] calldata allocators_, uint64 claimDeadline_)
        external
        initializer
    {
        if (token_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        token = token_;
        treasury = treasury_;
        operator = operator_;
        claimDeadline = claimDeadline_;
        for (uint256 i = 0; i < allocators_.length; i++) {
            if (allocators_[i] == address(0)) revert ZeroAddress();
            isAllocator[allocators_[i]] = true;
            emit AllocatorSet(allocators_[i], true);
        }
    }

    /*//////////////////////////////////////////////////////////////
                              WHO'S WHO
    //////////////////////////////////////////////////////////////*/

    /// @notice Whoever the Treasury answers to: the governance, or the
    ///         council's wrapper.
    function admin() public view returns (address) {
        return IDistributorTreasury(treasury).governance();
    }

    /// @notice The DAO's governance contract, looking through a council's
    ///         wrapper.
    function governanceContract() public view returns (address g) {
        g = admin();
        if (g.code.length == 0) return g;
        try IAnswersToGovernance(g).governance() returns (address inner) {
            if (inner != address(0)) g = inner;
        } catch {}
    }

    modifier onlyAdmin() {
        if (msg.sender != admin()) revert Unauthorized();
        _;
    }

    modifier open() {
        if (closed) revert DistributorClosed();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              ALLOCATING
    //////////////////////////////////////////////////////////////*/

    /// @notice Promises `amount` tokens to `owner` and/or `account`, vesting
    ///         from `start`: nothing before `start + cliff`, then linearly
    ///         until `start + duration` (all at once if `duration <= cliff`).
    ///         The admin (a proposal) or an allocator (a raise, a launch).
    function allocate(address owner, bytes32 account, uint256 amount, uint64 start, uint64 cliff, uint64 duration)
        external
        open
        returns (uint256 id)
    {
        if (msg.sender != admin() && !isAllocator[msg.sender]) revert Unauthorized();
        return _allocate(owner, account, amount, start, cliff, duration);
    }

    function _allocate(address owner, bytes32 account, uint256 amount, uint64 start, uint64 cliff, uint64 duration)
        internal
        returns (uint256 id)
    {
        if (owner == address(0) && account == bytes32(0)) revert NoOwner();
        if (amount == 0) revert ZeroAmount();
        uint256 available = unpromised();
        if (amount > available) revert NotFunded(available, amount);
        outstanding += amount;
        id = ++allocationCount;
        _allocations[id] = Allocation(owner, account, amount, 0, start, cliff, duration);
        emit Allocated(id, owner, account, amount, start, cliff, duration);
    }

    /*//////////////////////////////////////////////////////////////
                               CLAIMING
    //////////////////////////////////////////////////////////////*/

    /// @notice The owning address claims what has vested.
    function claim(uint256 id) external open returns (uint256 amount) {
        Allocation storage a = _allocations[id];
        if (a.owner == address(0) || msg.sender != a.owner) revert Unauthorized();
        return _pay(id, a, a.owner);
    }

    /// @notice The operator claims an account's vested tokens into `to`, the
    ///         member's current wallet (the bot checks who they are first).
    function claimFor(uint256 id, address to) external open returns (uint256 amount) {
        if (msg.sender != operator) revert Unauthorized();
        if (to == address(0)) revert ZeroAddress();
        Allocation storage a = _allocations[id];
        if (a.account == bytes32(0)) revert NotForAccounts();
        return _pay(id, a, to);
    }

    function _pay(uint256 id, Allocation storage a, address to) internal returns (uint256 amount) {
        amount = vested(id) - a.claimed;
        if (amount == 0) revert NothingToClaim();
        a.claimed += amount;
        outstanding -= amount;
        IERC20(token).safeTransfer(to, amount);
        emit Claimed(id, to, amount);
    }

    /// @notice How much of allocation `id` has vested by now.
    function vested(uint256 id) public view returns (uint256) {
        Allocation storage a = _allocations[id];
        uint256 unlock = uint256(a.start) + a.cliff;
        if (block.timestamp < unlock) return 0;
        uint256 end = uint256(a.start) + a.duration;
        if (a.duration <= a.cliff || block.timestamp >= end) return a.total;
        return (a.total * (block.timestamp - a.start)) / a.duration;
    }

    /// @notice What `id`'s owner could claim now.
    function claimable(uint256 id) external view returns (uint256) {
        return vested(id) - _allocations[id].claimed;
    }

    function allocation(uint256 id) external view returns (Allocation memory) {
        return _allocations[id];
    }

    /// @notice Tokens held here and not promised to anyone.
    function unpromised() public view returns (uint256) {
        uint256 held = IERC20(token).balanceOf(address(this));
        return held > outstanding ? held - outstanding : 0;
    }

    /*//////////////////////////////////////////////////////////////
                            WELCOME GRANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Turns welcome grants on (amount above 0) or off, and caps
    ///         their total. A proposal.
    function setWelcome(uint256 amount, uint256 cap) external onlyAdmin {
        welcomeAmount = amount;
        welcomeCap = cap;
        emit WelcomeTermsSet(amount, cap);
    }

    /// @notice A council member of the DAO's governance grants a new member
    ///         their welcome tokens, once they've checked the member has paid
    ///         their dues or registered. One per account (or per address
    ///         when there's no account).
    function grantWelcome(address member, bytes32 account) external open returns (uint256 id) {
        if (welcomeAmount == 0) revert WelcomeOff();
        address g = governanceContract();
        bool member_;
        if (g.code.length > 0) {
            try ICouncilGovernance(g).isCouncilMember(msg.sender) returns (bool yes) {
                member_ = yes;
            } catch {}
        }
        if (!member_) revert NotCouncilMember();
        bytes32 key = account != bytes32(0) ? account : bytes32(uint256(uint160(member)));
        if (key == bytes32(0)) revert NoOwner();
        if (welcomed[key]) revert AlreadyWelcomed();
        if (welcomeGranted + welcomeAmount > welcomeCap) revert WelcomeCapReached();
        welcomed[key] = true;
        welcomeGranted += welcomeAmount;
        id = _allocate(member, account, welcomeAmount, uint64(block.timestamp), 0, 0);
        emit WelcomeGranted(id, member, account, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    function setAllocator(address allocator, bool allowed) external onlyAdmin {
        if (allocator == address(0)) revert ZeroAddress();
        isAllocator[allocator] = allowed;
        emit AllocatorSet(allocator, allowed);
    }

    function setOperator(address operator_) external onlyAdmin {
        operator = operator_;
        emit OperatorSet(operator_);
    }

    function setClaimDeadline(uint64 deadline) external onlyAdmin {
        claimDeadline = deadline;
        emit ClaimDeadlineSet(deadline);
    }

    /// @notice Sends tokens nobody has been promised back to the Treasury.
    function returnUnpromised() external onlyAdmin returns (uint256 amount) {
        amount = unpromised();
        if (amount > 0) IERC20(token).safeTransfer(treasury, amount);
        emit Returned(amount);
    }

    /// @notice After the claim deadline: closes the Distributor and returns
    ///         everything still here, claimed or not, to the Treasury.
    function close() external onlyAdmin open returns (uint256 amount) {
        if (claimDeadline == 0 || block.timestamp < claimDeadline) revert TooEarly(claimDeadline);
        closed = true;
        outstanding = 0;
        amount = IERC20(token).balanceOf(address(this));
        if (amount > 0) IERC20(token).safeTransfer(treasury, amount);
        emit Closed(amount);
    }
}
