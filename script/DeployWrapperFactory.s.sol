// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {WrapperFactory} from "../src/wrapper/WrapperFactory.sol";
import {GuardWrapper} from "../src/wrapper/GuardWrapper.sol";
import {NFTMarketplaceWrapper} from "../src/marketplace/NFTMarketplaceWrapper.sol";
import {StakeConverter} from "../src/converter/StakeConverter.sol";

/// @title DeployWrapperFactory
/// @notice Deploys the three clone implementations (GuardWrapper,
///         NFTMarketplaceWrapper, StakeConverter) and the per-network
///         WrapperFactory that clones them for each DAO.
///
/// Usage:
///   forge script script/DeployWrapperFactory.s.sol:DeployWrapperFactory \
///     --rpc-url <RPC_URL> \
///     --private-key $PRIVATE_KEY \
///     --broadcast
contract DeployWrapperFactory is Script {
    function run() external returns (WrapperFactory factory) {
        vm.startBroadcast();

        GuardWrapper guard = new GuardWrapper();
        NFTMarketplaceWrapper nft = new NFTMarketplaceWrapper();
        StakeConverter converter = new StakeConverter();
        factory = new WrapperFactory(address(guard), address(nft), address(converter));

        vm.stopBroadcast();

        console.log("GuardWrapper implementation deployed at:", address(guard));
        console.log("NFTMarketplaceWrapper implementation deployed at:", address(nft));
        console.log("StakeConverter implementation deployed at:", address(converter));
        console.log("WrapperFactory deployed at:", address(factory));
    }
}
