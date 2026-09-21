// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { ISwitchboard } from "@switchboard-xyz/on-demand-solidity/interfaces/ISwitchboard.sol";

/// @dev Matches SowellianGovernance's IMetricOracle interface exactly -
///      not imported directly to avoid a cross-folder dependency, same
///      pattern already used for the randomness adapters.
interface IMetricOracle {
    function latestValue(bytes32 selector) external view returns (int256 value, uint256 updatedAt);
}

/// @title SwitchboardPriceFeedAdapter
/// @author Marvin Sunday
/// @notice Wraps Switchboard's price/metric feeds behind SowellianGovernance's
///         IMetricOracle interface. One deployment serves every feed on
///         this Switchboard instance - `selector` (the feedId) is
///         supplied per-call, not fixed at deployment.
/// @dev Genuinely stateless beyond the Switchboard address itself -
///      confirmed from Switchboard's own real architecture (the Diamond
///      Pattern: one proxy contract, many feeds addressed by feedId, not
///      separate deployments per feed). Earlier versions of this adapter
///      took a fixed feedId at construction, meaning a fresh adapter had
///      to be deployed for every new metric a DAO wanted to check -
///      real, avoidable friction given Switchboard itself never required
///      that. SowellianGovernance now stores a per-proposal selector
///      specifically so this adapter can be deployed once and reused
///      across any number of feeds and proposals.
///
///      Switchboard feeds are PULL-based, same as their randomness
///      product - someone has to call `updateFeeds()` on the Switchboard
///      contract itself (with a fresh, oracle-signed payload fetched
///      off-chain) before this adapter's `latestValue()` reflects
///      anything current for a given feedId. This adapter does not do
///      that itself; it only reads back whatever was most recently
///      pushed for the requested selector. In practice this needs a
///      keeper - the same operational requirement already flagged for
///      SwitchboardRandomnessAdapter, and one keeper process could cover
///      both if a DAO uses Switchboard for randomness and price data.
///
///      Verified against the real, installed Switchboard on-demand-solidity
///      package (switchboard-xyz/on-demand-solidity, v1.1.0) - not written
///      from documentation snippets alone.
contract SwitchboardPriceFeedAdapter is IMetricOracle {
    ISwitchboard public immutable switchboard;

    error ZeroAddress();
    error FeedDoesNotExist();

    constructor(address switchboard_) {
        if (switchboard_ == address(0)) revert ZeroAddress();
        switchboard = ISwitchboard(switchboard_);
    }

    /// @inheritdoc IMetricOracle
    /// @param selector The Switchboard feedId to read - reverts if this
    ///        feed doesn't actually exist on this Switchboard instance,
    ///        same check the old constructor-time version made, just
    ///        now happening per-call since the feed isn't fixed anymore.
    function latestValue(bytes32 selector) external view returns (int256 value, uint256 updatedAt) {
        if (!switchboard.feedExists(selector)) revert FeedDoesNotExist();
        (int128 rawValue, uint256 timestamp, ) = switchboard.getLatestValue(selector);
        return (int256(rawValue), timestamp);
    }
}
