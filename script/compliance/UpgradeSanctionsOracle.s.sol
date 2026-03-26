// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SanctionsOracle} from "../../src/compliance/SanctionsOracle.sol";
import {SanctionsOracleFactory} from "../../src/compliance/SanctionsOracleFactory.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @title UpgradeSanctionsOracle
/// @notice Upgrades the SanctionsOracle implementation behind the shared UpgradeableBeacon.
///         All SanctionsOracle BeaconProxy instances are upgraded atomically.
///
/// Required env vars:
///   F_SANCTIONS_ORACLE_FACTORY  – address of the deployed SanctionsOracleFactory
///
/// Usage:
///   # Dry run
///   forge script script/compliance/UpgradeSanctionsOracle.s.sol \
///       --rpc-url mantle_sepolia -vvvv
///
///   # Broadcast
///   forge script script/compliance/UpgradeSanctionsOracle.s.sol \
///       --rpc-url mantle_sepolia --broadcast -vvvv
contract UpgradeSanctionsOracle is Script {
    function run() external {
        address factoryAddr = vm.envAddress("F_SANCTIONS_ORACLE_FACTORY");
        SanctionsOracleFactory factory = SanctionsOracleFactory(factoryAddr);
        UpgradeableBeacon beacon = factory.BEACON();

        address oldImpl = beacon.implementation();

        console2.log("=== Upgrade SanctionsOracle Implementation ===");
        console2.log("Factory        :", factoryAddr);
        console2.log("Beacon         :", address(beacon));
        console2.log("Beacon owner   :", beacon.owner());
        console2.log("Old impl       :", oldImpl);

        vm.startBroadcast();

        SanctionsOracle newImpl = new SanctionsOracle();
        beacon.upgradeTo(address(newImpl));

        vm.stopBroadcast();

        console2.log("New impl       :", address(newImpl));
        console2.log("");

        // ── Verification ─────────────────────────────────────────
        address currentImpl = beacon.implementation();
        console2.log("=== Post-upgrade Verification ===");
        console2.log("Beacon.impl()  :", currentImpl);
        console2.log("Matches new?   :", currentImpl == address(newImpl));

        uint256 proxyCount = factory.oracleCount();
        if (proxyCount > 0) {
            address firstProxy = factory.oracles(0);
            SanctionsOracle oracle = SanctionsOracle(firstProxy);
            console2.log("");
            console2.log("Proxy[0]       :", firstProxy);
            console2.log("  isSanctioned(0x0):", oracle.isSanctioned(address(0)));
        }

        console2.log("");
        console2.log("=== Upgrade Complete ===");
    }
}
