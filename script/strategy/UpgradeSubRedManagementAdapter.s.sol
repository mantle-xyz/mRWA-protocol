// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SubRedManagementAdapterFactory} from "../../src/adapters/digift/SubRedManagementAdapterFactory.sol";
import {SubRedManagementAdapter} from "../../src/adapters/digift/SubRedManagementAdapterUpgradeable.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @title UpgradeSubRedManagementAdapter
/// @notice Upgrades the SubRedManagementAdapter (upgradeable) implementation behind the shared UpgradeableBeacon.
///         All SubRedManagementAdapter BeaconProxy instances are upgraded atomically.
///
/// Required env vars:
///   F_SUBRED_ADAPTER_FACTORY  – address of the deployed SubRedManagementAdapterFactory
///
/// Usage:
///   # Dry run
///   forge script script/strategy/UpgradeSubRedManagementAdapter.s.sol \
///       --rpc-url mantle_sepolia -vvvv
///
///   # Broadcast
///   forge script script/strategy/UpgradeSubRedManagementAdapter.s.sol \
///       --rpc-url mantle_sepolia --broadcast -vvvv
contract UpgradeSubRedManagementAdapter is Script {
    function run() external {
        address factoryAddr = vm.envAddress("F_SUBRED_ADAPTER_FACTORY");
        SubRedManagementAdapterFactory factory = SubRedManagementAdapterFactory(factoryAddr);
        UpgradeableBeacon beacon = factory.BEACON();

        address oldImpl = beacon.implementation();

        console2.log("=== Upgrade SubRedManagementAdapter Implementation ===");
        console2.log("Factory        :", factoryAddr);
        console2.log("Beacon         :", address(beacon));
        console2.log("Beacon owner   :", beacon.owner());
        console2.log("Old impl       :", oldImpl);

        vm.startBroadcast();

        SubRedManagementAdapter newImpl = new SubRedManagementAdapter();
        beacon.upgradeTo(address(newImpl));

        vm.stopBroadcast();

        console2.log("New impl       :", address(newImpl));
        console2.log("");

        // ── Verification ─────────────────────────────────────────
        address currentImpl = beacon.implementation();
        console2.log("=== Post-upgrade Verification ===");
        console2.log("Beacon.impl()  :", currentImpl);
        console2.log("Matches new?   :", currentImpl == address(newImpl));

        uint256 proxyCount = factory.adapterCount();
        console2.log("Adapter count  :", proxyCount);
        if (proxyCount > 0) {
            address firstProxy = factory.adapters(0);
            SubRedManagementAdapter adapter = SubRedManagementAdapter(firstProxy);
            console2.log("");
            console2.log("Proxy[0]       :", firstProxy);
            console2.log("  name()       :", adapter.name());
            console2.log("  vault()      :", adapter.vault());
            console2.log("  posToken()   :", adapter.posToken());
        }

        console2.log("");
        console2.log("=== Upgrade Complete ===");
    }
}
