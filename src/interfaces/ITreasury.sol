// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ITreasury
/// @notice Interface for the DAO Treasury.
interface ITreasury {

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event ETHReceived(
        address indexed sender,
        uint256 amount
    );

    event ETHTransferred(
        address indexed recipient,
        uint256 amount
    );

    event ERC20Transferred(
        address indexed token,
        address indexed recipient,
        uint256 amount
    );

    event SetupAuthoritySet(address indexed authority);
    event AllowanceCreated(uint256 indexed id, address indexed recipient, address token, uint256 amount, uint64 endsAt);
    event AllowanceUpdated(uint256 indexed id, uint256 amount, uint64 endsAt);
    event AllowanceRevoked(uint256 indexed id);
    event AllowanceClaimed(uint256 indexed id, address indexed recipient, uint64 period, uint256 amount);

    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error Unauthorized();
    error ZeroAddress();
    error TransferFailed();
    error InsufficientBalance();
    error InvalidAllowance();
    error AllowanceNotFound();
    error AllowanceEnded();
    /// @param nextAt when the next period opens
    error AllowanceAlreadyClaimed(uint256 nextAt);

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the governance contract.
    function governance()
        external
        view
        returns (address);

    /// @notice Returns the ETH balance.
    function ethBalance()
        external
        view
        returns (uint256);

    /// @notice Returns the balance of an ERC20 token.
    function tokenBalance(
        address token
    )
        external
        view
        returns (uint256);

    /*//////////////////////////////////////////////////////////////
                            EXECUTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Transfers ETH.
    function transferETH(
        address payable recipient,
        uint256 amount
    )
        external;

    /// @notice Transfers ERC20 tokens.
    function transferERC20(
        address token,
        address recipient,
        uint256 amount
    )
        external;

    /// @notice Executes an arbitrary call.
    function execute(
        address target,
        uint256 value,
        bytes calldata data
    )
        external
        returns (bytes memory);

    /*//////////////////////////////////////////////////////////////
                            ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Transfers treasury ownership.
    function transferGovernance(
        address newGovernance
    )
        external;

    /*//////////////////////////////////////////////////////////////
                            ALLOWANCES
    //////////////////////////////////////////////////////////////*/

    function setSetupAuthority(address authority) external;

    function endSetup() external;

    function createAllowance(address recipient, address token, uint256 amount, uint64 endsAt) external returns (uint256 id);

    function updateAllowance(uint256 id, uint256 amount, uint64 endsAt) external;

    function revokeAllowance(uint256 id) external;

    function claimAllowance(uint256 id) external returns (uint256 amount);

    function allowanceCount() external view returns (uint256);

    function claimableAllowance(uint256 id) external view returns (uint256 amount, uint256 nextAt);
}
