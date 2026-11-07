// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Distributor} from "../src/distribution/Distributor.sol";
import {Raise} from "../src/distribution/Raise.sol";
import {DistributionFactory} from "../src/distribution/DistributionFactory.sol";
import {Launcher} from "../src/distribution/Launcher.sol";
import {PropFirmVault} from "../src/vault/PropFirmVault.sol";
import {VaultFactory} from "../src/vault/VaultFactory.sol";

/// @title DeployLaunchFactory
/// @notice Deploys the Distributor and Raise implementations and their
///         DistributionFactory, the PropFirmVault implementation and its
///         VaultFactory, and the Launcher, then approves the model factories
///         a launch may call (LAUNCH_FACTORIES, comma-separated; the deploy
///         shells pass the token models' factories from the same run).
///
/// Usage:
///   LAUNCH_FACTORIES=0x...,0x... forge script script/DeployLaunchFactory.s.sol:DeployLaunchFactory \
///     --rpc-url <RPC_URL> --private-key $PRIVATE_KEY --broadcast
contract DeployLaunchFactory is Script {
    function run() external returns (Launcher launcher) {
        address[] memory factories = vm.envOr("LAUNCH_FACTORIES", ",", new address[](0));
        vm.startBroadcast();

        DistributionFactory distribution = new DistributionFactory(address(new Distributor()), address(new Raise()));
        VaultFactory vaults = new VaultFactory(address(new PropFirmVault()));
        launcher = new Launcher(distribution, vaults, msg.sender);
        for (uint256 i = 0; i < factories.length; i++) launcher.approveFactory(factories[i], true);

        vm.stopBroadcast();

        console.log("DistributionFactory deployed at:", address(distribution));
        console.log("VaultFactory deployed at:", address(vaults));
        console.log("Launcher deployed at:", address(launcher));
        console.log("LaunchFactory deployed at:", address(launcher));
        console.log("Factories approved for launches:", factories.length);
    }
}
