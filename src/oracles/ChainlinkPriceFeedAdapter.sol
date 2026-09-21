// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @dev Matches SowellianGovernance's IMetricOracle interface exactly -
///      not imported directly to avoid a cross-folder dependency, same
///      pattern already used for the randomness adapters.
interface IMetricOracle {
    function latestValue(bytes32 selector) external view returns (int256 value, uint256 updatedAt);
}

/// @title ChainlinkPriceFeedAdapter
/// @author Marvin Sunday
/// @notice Wraps a Chainlink Data Feed behind SowellianGovernance's
///         IMetricOracle interface.
/// @dev Chainlink Data Feeds are PUSH-based - a decentralized network of
///      independent node operators keeps the feed current automatically,
///      updating on a price-deviation threshold or a minimum heartbeat
///      interval, whichever comes first. Unlike the Switchboard adapter,
///      nothing needs to actively call an update function here - this
///      adapter is a pure read-through. The real constraint is coverage:
///      Chainlink only has deployed feeds for pairs it actually supports
///      on a given chain - verify a feed actually exists for what you
///      need before pointing a proposal at one.
///
///      `latestValue`'s `selector` parameter is deliberately ignored
///      here - Chainlink has no equivalent to Switchboard's one-proxy-
///      many-feeds shape. Each Chainlink price pair is already its own
///      separately-deployed contract on Chainlink's own side, so this
///      adapter stays bound to exactly one feed via its constructor,
///      same as before; the parameter exists only to satisfy the same
///      interface SwitchboardPriceFeedAdapter actually uses it for.
///
///      Verified against the real, installed Chainlink contracts package
///      (chainlink/contracts, v1.4.0) - not written from documentation
///      snippets alone.
contract ChainlinkPriceFeedAdapter is IMetricOracle {
    AggregatorV3Interface public immutable priceFeed;

    error ZeroAddress();

    constructor(address priceFeed_) {
        if (priceFeed_ == address(0)) revert ZeroAddress();
        priceFeed = AggregatorV3Interface(priceFeed_);
    }

    /// @inheritdoc IMetricOracle
    function latestValue(bytes32 /* selector, unused - see contract-level note */) external view returns (int256 value, uint256 updatedAt) {
        (, int256 answer, , uint256 lastUpdatedAt, ) = priceFeed.latestRoundData();
        return (answer, lastUpdatedAt);
    }
}
