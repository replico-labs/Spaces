// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IValuer
/// @notice What a prop-firm vault's money is worth on one venue, read from
///         the venue itself so the vault never takes the bot's word for it.
interface IValuer {
    /// @return assets the account's value in the vault's asset (e.g. USDC
    ///         units), positions marked to market; 0 for a negative value
    /// @return valid false when a price is stale or invalid: the vault's
    ///         window then waits instead of pricing shares wrong
    function value() external view returns (uint256 assets, bool valid);
}
