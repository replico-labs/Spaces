// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev The parts of StakedGovernanceToken the converter uses.
interface IConvertibleStaking {
    function underlying() external view returns (address);
    function unstake(uint256 amount) external;
    function stakeFor(address account, uint256 amount) external;
}

/// @dev Who the DAO's Treasury answers to (its governance, or a council).
interface ITreasuryGovernance {
    function governance() external view returns (address);
}

/// @title StakeConverter
/// @notice Moves members' stake from a DAO's old token to its new one in
///         one call. After a token change, the DAO opens a converter
///         (WrapperFactory.createConverter, in the same proposal) at a
///         rate it votes - `rateNum` new tokens for every `rateDen` old -
///         and funds it with the new token from the Treasury. A member
///         then calls convert(amount): their old stake is unstaked, the
///         old tokens go to the Treasury, and the new tokens, at the
///         rate, are staked for them in the new staking contract.
/// @dev It only converts what's funded; the DAO tops it up or closes it
///      by proposal. Closing returns what's left to the Treasury. One
///      clone per conversion, made by WrapperFactory: it holds DAO funds,
///      so it isn't shared between DAOs.
contract StakeConverter is Initializable {
    using SafeERC20 for IERC20;

    /// @notice The old staking contract members convert out of.
    IConvertibleStaking public from;
    /// @notice The new staking contract their stake lands in.
    IConvertibleStaking public to;
    uint256 public rateNum;
    uint256 public rateDen;
    /// @notice Gets the old tokens, and what's left when it closes.
    address public treasury;
    bool public open;

    uint256 private _status;

    event Converted(address indexed account, uint256 amountIn, uint256 amountOut);
    event Closed(uint256 returned);

    error ZeroAddress();
    error InvalidRate();
    error ZeroAmount();
    error ConverterClosed();
    error Underfunded();
    error Unauthorized();
    error Reentrant();

    modifier nonReentrant() {
        if (_status == 2) revert Reentrant();
        _status = 2;
        _;
        _status = 1;
    }

    /// @dev The implementation itself can never be initialized; only clones.
    constructor() {
        _disableInitializers();
    }

    function initialize(address from_, address to_, uint256 rateNum_, uint256 rateDen_, address treasury_) external initializer {
        if (from_ == address(0) || to_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        if (rateNum_ == 0 || rateDen_ == 0 || from_ == to_) revert InvalidRate();
        from = IConvertibleStaking(from_);
        to = IConvertibleStaking(to_);
        rateNum = rateNum_;
        rateDen = rateDen_;
        treasury = treasury_;
        open = true;
        _status = 1;
    }

    /// @notice What converting `amount` of old stake gives.
    function quote(uint256 amount) public view returns (uint256) {
        return (amount * rateNum) / rateDen;
    }

    /// @notice Converts `amount` of the caller's old stake. The caller
    ///         approves this contract for `amount` of the old staking
    ///         token first; only unlocked stake moves.
    function convert(uint256 amount) external nonReentrant returns (uint256 out) {
        if (!open) revert ConverterClosed();
        if (amount == 0) revert ZeroAmount();
        out = quote(amount);
        if (out == 0) revert ZeroAmount();
        IERC20 newToken = IERC20(to.underlying());
        if (newToken.balanceOf(address(this)) < out) revert Underfunded();

        IERC20 oldToken = IERC20(from.underlying());
        IERC20(address(from)).safeTransferFrom(msg.sender, address(this), amount);
        from.unstake(amount);
        oldToken.safeTransfer(treasury, amount);

        newToken.forceApprove(address(to), out);
        to.stakeFor(msg.sender, out);
        emit Converted(msg.sender, amount, out);
    }

    /// @notice Closes the converter and returns the new tokens left in it
    ///         to the Treasury. Only the DAO: its Treasury, or whoever the
    ///         Treasury answers to (the governance, or its council).
    function close() external nonReentrant {
        if (msg.sender != treasury && msg.sender != ITreasuryGovernance(treasury).governance()) revert Unauthorized();
        if (!open) revert ConverterClosed();
        open = false;
        IERC20 newToken = IERC20(to.underlying());
        uint256 left = newToken.balanceOf(address(this));
        if (left > 0) newToken.safeTransfer(treasury, left);
        emit Closed(left);
    }
}
