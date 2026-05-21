// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Accountant} from "../../src/accountant/Accountant.sol";
import {AccountantFactory} from "../../src/accountant/AccountantFactory.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @title UpgradeAccountant
/// @notice Upgrades the Accountant implementation behind the shared UpgradeableBeacon.
///         All Accountant BeaconProxy instances are upgraded atomically.
///
/// Required env vars:
///   ACCOUNTANT_FACTORY  – address of the deployed AccountantFactory
///
/// Usage:
///   # Dry run
///   forge script script/accountant/UpgradeAccountant.s.sol \
///       --rpc-url mantle_sepolia -vvvv
///
///   # Broadcast
///   forge script script/accountant/UpgradeAccountant.s.sol \
///       --rpc-url mantle_sepolia --broadcast -vvvv
contract UpgradeAccountant is Script {
    function run() external {
        address factoryAddr = vm.envAddress("F_ACCOUNTANT_FACTORY");
        AccountantFactory factory = AccountantFactory(factoryAddr);
        UpgradeableBeacon beacon = factory.BEACON();

        address oldImpl = beacon.implementation();

        console2.log("=== Upgrade Accountant Implementation ===");
        console2.log("Factory        :", factoryAddr);
        console2.log("Beacon         :", address(beacon));
        console2.log("Beacon owner   :", beacon.owner());
        console2.log("Old impl       :", oldImpl);

        vm.startBroadcast();

        Accountant newImpl = new Accountant();
        beacon.upgradeTo(address(newImpl));

        vm.stopBroadcast();

        console2.log("New impl       :", address(newImpl));
        console2.log("");

        // ── Verification ─────────────────────────────────────────
        address currentImpl = beacon.implementation();
        console2.log("=== Post-upgrade Verification ===");
        console2.log("Beacon.impl()  :", currentImpl);
        console2.log("Matches new?   :", currentImpl == address(newImpl));

        uint256 proxyCount = factory.accountantCount();
        if (proxyCount > 0) {
            address firstProxy = factory.accountants(0);
            Accountant acc = Accountant(firstProxy);
            console2.log("");
            console2.log("Proxy[0]       :", firstProxy);
            console2.log("  getRate()    :", acc.getRate());
            console2.log("  paused()     :", acc.paused());
        }

        console2.log("");
        console2.log("=== Upgrade Complete ===");
    }
}
