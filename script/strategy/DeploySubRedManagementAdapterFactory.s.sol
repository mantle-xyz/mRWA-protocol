// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SubRedManagementAdapterFactory} from "../../src/adapters/digift/SubRedManagementAdapterFactory.sol";
import {SubRedManagementAdapter} from "../../src/adapters/digift/SubRedManagementAdapterUpgradeable.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @title DeploySubRedManagementAdapterFactory
/// @notice Deploys a new SubRedManagementAdapterFactory with a real SubRedManagementAdapter
///         implementation behind its UpgradeableBeacon.
///
/// Required env:
/// - ADAPTER_FACTORY_BEACON_OWNER   – address that can upgrade the beacon (e.g. multisig / timelock)
///
/// Usage:
///   # Dry run
///   forge script script/strategy/DeploySubRedManagementAdapterFactory.s.sol \
///       --rpc-url mantle_sepolia -vvvv
///
///   # Broadcast
///   forge script script/strategy/DeploySubRedManagementAdapterFactory.s.sol \
///       --rpc-url mantle_sepolia --broadcast -vvvv
contract DeploySubRedManagementAdapterFactory is Script {
    function run() external returns (SubRedManagementAdapterFactory factory) {
        address beaconOwner = vm.envAddress("ADAPTER_FACTORY_BEACON_OWNER");

        console2.log("=== Deploy SubRedManagementAdapterFactory ===");
        console2.log("Beacon owner:", beaconOwner);

        vm.startBroadcast();

        SubRedManagementAdapter impl = new SubRedManagementAdapter();
        factory = new SubRedManagementAdapterFactory(address(impl), beaconOwner);

        vm.stopBroadcast();

        console2.log("Implementation  :", address(impl));
        console2.log("Factory         :", address(factory));
        console2.log("Beacon          :", address(factory.BEACON()));
        console2.log("Beacon owner    :", factory.BEACON().owner());
        console2.log("Beacon impl     :", factory.implementation());
    }
}
