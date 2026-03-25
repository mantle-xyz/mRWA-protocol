// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GatewayFactory} from "../../src/vault/GatewayFactory.sol";
import {MantleVaultGateway} from "../../src/vault/MantleVaultGateway.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @title UpgradeGateway
/// @notice Upgrades the MantleVaultGateway implementation behind the shared UpgradeableBeacon.
///         All MantleVaultGateway BeaconProxy instances are upgraded atomically.
///
/// Required env vars:
///   F_GATEWAY_FACTORY  – address of the deployed GatewayFactory
///
/// Usage:
///   # Dry run
///   forge script script/vault/UpgradeGateway.s.sol \
///       --rpc-url mantle_sepolia -vvvv
///
///   # Broadcast
///   forge script script/vault/UpgradeGateway.s.sol \
///       --rpc-url mantle_sepolia --broadcast -vvvv
contract UpgradeGateway is Script {
    function run() external {
        address factoryAddr = vm.envAddress("F_GATEWAY_FACTORY");
        GatewayFactory factory = GatewayFactory(factoryAddr);
        UpgradeableBeacon beacon = factory.BEACON();

        address oldImpl = beacon.implementation();

        console2.log("=== Upgrade Gateway Implementation ===");
        console2.log("Factory        :", factoryAddr);
        console2.log("Beacon         :", address(beacon));
        console2.log("Beacon owner   :", beacon.owner());
        console2.log("Old impl       :", oldImpl);

        vm.startBroadcast();

        MantleVaultGateway newImpl = new MantleVaultGateway();
        beacon.upgradeTo(address(newImpl));

        vm.stopBroadcast();

        console2.log("New impl       :", address(newImpl));
        console2.log("");

        // ── Verification ─────────────────────────────────────────
        address currentImpl = beacon.implementation();
        console2.log("=== Post-upgrade Verification ===");
        console2.log("Beacon.impl()  :", currentImpl);
        console2.log("Matches new?   :", currentImpl == address(newImpl));

        uint256 proxyCount = factory.gatewayCount();
        if (proxyCount > 0) {
            address firstProxy = factory.gateways(0);
            console2.log("");
            console2.log("Proxy[0]       :", firstProxy);
        }

        console2.log("");
        console2.log("=== Upgrade Complete ===");
    }
}
