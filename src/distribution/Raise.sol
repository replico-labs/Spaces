// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

interface IRaiseDistributor {
    function token() external view returns (address);
    function unpromised() external view returns (uint256);
    function allocate(address owner, bytes32 account, uint256 amount, uint64 start, uint64 cliff, uint64 duration) external returns (uint256 id);
}

/// @title Raise
/// @notice A fundraise sold pro rata: contributions stay open for the whole
///         period, past the hard cap too. When it ends, the decider accepts
///         any amount from the soft cap up to everything contributed (no
///         upper limit; the hard cap is the stated target). Everyone gets
///         tokens in proportion to what they put in, and back the same share
///         of what wasn't accepted.
/// @dev Below the soft cap, or with no decision within the decision window,
///      everyone is refunded in full. The accepted money only ever goes to
///      the DAO's Treasury (`fundsTo`): for an existing DAO it's fixed when
///      the raise is made; for a launch, the Launcher (the decider) names
///      the Treasury it has just created.
///
///      After acceptance, `settle` (anyone, in batches) writes each
///      contributor's tokens into the Distributor, vesting as the terms say,
///      and records their refund; `withdrawRefund` (anyone) pays a refund to
///      the address that contributed it.
contract Raise is Initializable {
    using SafeERC20 for IERC20;

    struct Terms {
        address currency; // address(0): the native coin
        uint256 softCap;
        uint256 hardCap; // the stated target; not a ceiling
        uint64 start;
        uint64 end;
        uint256 minContribution; // 0: none
        uint256 maxContribution; // per contributor; 0: none
        uint256 saleSupply; // tokens shared among contributors; 0: set when the amount is accepted (a prop firm's vault shares)
        uint64 vestCliff;
        uint64 vestDuration;
        uint64 decisionWindow; // after `end`
        address fundsTo; // the Treasury; zero for a launch (named on acceptance)
    }

    struct Contribution {
        uint256 amount;
        bytes32 account; // the contributor's chat account, if given
        bool settled;
        uint256 refundOwed;
    }

    Terms internal _terms;

    /// @notice Who accepts an amount: the DAO's governance (or council
    ///         wrapper), or a Launcher for a launch.
    address public decider;

    uint256 public totalContributed;
    uint256 public accepted;
    uint64 public acceptedAt;
    address public distributor;
    address public treasury;
    /// @notice The tokens shared among contributors (the terms', or the one set on acceptance).
    uint256 public saleSupply;

    mapping(address => Contribution) public contributions;
    address[] public contributors;

    event Contributed(address indexed contributor, bytes32 indexed account, uint256 amount, uint256 total);
    event Accepted(uint256 amount, uint256 totalContributed, address treasury, address distributor);
    event Settled(address indexed contributor, uint256 allocationId, uint256 tokens, uint256 refund);
    event Refunded(address indexed contributor, uint256 amount);

    error InvalidTerms();
    error NotOpen();
    error WrongAmount();
    error BelowMinimum(uint256 minimum);
    error AboveMaximum(uint256 maximum);
    error AccountMismatch();
    error Unauthorized();
    error NotEnded();
    error DecisionClosed();
    error AlreadyAccepted();
    error OutOfRange(uint256 softCap, uint256 totalContributed);
    error WrongTreasury();
    error NotFunded(uint256 available, uint256 needed);
    error NotAccepted();
    error NothingOwed();
    error TransferFailed();

    constructor() {
        _disableInitializers();
    }

    function initialize(Terms calldata terms_, address decider_) external initializer {
        if (decider_ == address(0)) revert InvalidTerms();
        if (terms_.end <= terms_.start || terms_.softCap == 0) revert InvalidTerms();
        if (terms_.maxContribution != 0 && terms_.maxContribution < terms_.minContribution) revert InvalidTerms();
        _terms = terms_;
        decider = decider_;
    }

    function terms() external view returns (Terms memory) {
        return _terms;
    }

    function contributorCount() external view returns (uint256) {
        return contributors.length;
    }

    /*//////////////////////////////////////////////////////////////
                              CONTRIBUTING
    //////////////////////////////////////////////////////////////*/

    /// @notice Contributes `amount` (send it as value for the native coin),
    ///         tied to the contributor's chat `account` if given (the same
    ///         account on every contribution from this address).
    function contribute(uint256 amount, bytes32 account) external payable {
        Terms storage t = _terms;
        if (block.timestamp < t.start || block.timestamp >= t.end) revert NotOpen();
        if (amount == 0) revert WrongAmount();
        if (t.currency == address(0)) {
            if (msg.value != amount) revert WrongAmount();
        } else {
            if (msg.value != 0) revert WrongAmount();
            IERC20(t.currency).safeTransferFrom(msg.sender, address(this), amount);
        }
        Contribution storage c = contributions[msg.sender];
        if (c.amount == 0) {
            contributors.push(msg.sender);
            c.account = account;
        } else if (account != bytes32(0) && c.account != account) {
            if (c.account != bytes32(0)) revert AccountMismatch();
            c.account = account;
        }
        c.amount += amount;
        if (c.amount < t.minContribution) revert BelowMinimum(t.minContribution);
        if (t.maxContribution != 0 && c.amount > t.maxContribution) revert AboveMaximum(t.maxContribution);
        totalContributed += amount;
        emit Contributed(msg.sender, c.account, amount, c.amount);
    }

    /*//////////////////////////////////////////////////////////////
                               DECIDING
    //////////////////////////////////////////////////////////////*/

    /// @notice Whether the raise failed: below the soft cap at the end, or
    ///         no amount accepted within the decision window.
    function failed() public view returns (bool) {
        Terms storage t = _terms;
        if (acceptedAt != 0 || block.timestamp < t.end) return false;
        return totalContributed < t.softCap || block.timestamp >= uint256(t.end) + t.decisionWindow;
    }

    /// @notice The decider accepts `amount`, sends it to `treasury_` and
    ///         names the Distributor that holds the sale's tokens.
    function accept(uint256 amount, address treasury_, address distributor_) external {
        if (_terms.saleSupply == 0) revert InvalidTerms();
        _accept(amount, treasury_, distributor_, _terms.saleSupply, true);
    }

    /// @notice For terms without a fixed sale supply (a prop firm, whose
    ///         shares are minted from the accepted money): the decider names
    ///         how many tokens contributors share, and funds the Distributor
    ///         with them right after, in the same transaction.
    function acceptWithSupply(uint256 amount, address treasury_, address distributor_, uint256 supply) external {
        if (_terms.saleSupply != 0 || supply == 0) revert InvalidTerms();
        _accept(amount, treasury_, distributor_, supply, false);
    }

    function _accept(uint256 amount, address treasury_, address distributor_, uint256 supply, bool checkFunded) internal {
        Terms storage t = _terms;
        if (msg.sender != decider) revert Unauthorized();
        if (acceptedAt != 0) revert AlreadyAccepted();
        if (block.timestamp < t.end) revert NotEnded();
        if (block.timestamp >= uint256(t.end) + t.decisionWindow) revert DecisionClosed();
        if (amount < t.softCap || amount > totalContributed) revert OutOfRange(t.softCap, totalContributed);
        if (treasury_ == address(0) || (t.fundsTo != address(0) && treasury_ != t.fundsTo)) revert WrongTreasury();
        if (checkFunded) {
            uint256 available = IRaiseDistributor(distributor_).unpromised();
            if (available < supply) revert NotFunded(available, supply);
        }

        saleSupply = supply;
        accepted = amount;
        acceptedAt = uint64(block.timestamp);
        treasury = treasury_;
        distributor = distributor_;
        _send(treasury_, amount);
        emit Accepted(amount, totalContributed, treasury_, distributor_);
    }

    /*//////////////////////////////////////////////////////////////
                         SETTLING AND REFUNDS
    //////////////////////////////////////////////////////////////*/

    /// @notice After acceptance: writes each contributor's tokens into the
    ///         Distributor and records their refund. Anyone, in batches.
    function settle(address[] calldata who) external {
        if (acceptedAt == 0) revert NotAccepted();
        Terms storage t = _terms;
        uint256 total = totalContributed;
        for (uint256 i = 0; i < who.length; i++) {
            Contribution storage c = contributions[who[i]];
            if (c.amount == 0 || c.settled) continue;
            c.settled = true;
            uint256 tokens = (saleSupply * c.amount) / total;
            // Rounded down, so the refunds never add up to more than what wasn't accepted.
            uint256 refund = (c.amount * (total - accepted)) / total;
            c.refundOwed = refund;
            uint256 id;
            if (tokens > 0) {
                id = IRaiseDistributor(distributor).allocate(who[i], c.account, tokens, acceptedAt, t.vestCliff, t.vestDuration);
            }
            emit Settled(who[i], id, tokens, refund);
        }
    }

    /// @notice Pays `contributor` what they're owed back, to the address
    ///         that contributed: their whole contribution if the raise
    ///         failed, otherwise the part that wasn't accepted (once settled).
    function withdrawRefund(address contributor) external returns (uint256 amount) {
        Contribution storage c = contributions[contributor];
        if (failed()) {
            amount = c.amount;
            c.amount = 0;
        } else {
            amount = c.refundOwed;
            c.refundOwed = 0;
        }
        if (amount == 0) revert NothingOwed();
        _send(contributor, amount);
        emit Refunded(contributor, amount);
    }

    function _send(address to, uint256 amount) internal {
        if (amount == 0) return;
        address currency = _terms.currency;
        if (currency == address(0)) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(currency).safeTransfer(to, amount);
        }
    }
}
