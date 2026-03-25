// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {VaultFactory} from "../../src/vault/VaultFactory.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @title UpgradeVault
/// @notice Upgrades the MantleYieldVault implementation behind the shared UpgradeableBeacon.
///         All MantleYieldVault BeaconProxy instances are upgraded atomically.
///
/// Required env vars:
///   F_VAULT_FACTORY  – address of the deployed VaultFactory
///
/// Usage:
///   # Dry run
///   forge script script/vault/UpgradeVault.s.sol \
///       --rpc-url mantle_sepolia -vvvv
///
///   # Broadcast
///   forge script script/vault/UpgradeVault.s.sol \
///       --rpc-url mantle_sepolia --broadcast -vvvv
contract UpgradeVault is Script {
    function run() external {
        address factoryAddr = vm.envAddress("F_VAULT_FACTORY");
        VaultFactory factory = VaultFactory(factoryAddr);
        UpgradeableBeacon beacon = factory.BEACON();

        address oldImpl = beacon.implementation();

        console2.log("=== Upgrade Vault Implementation ===");
        console2.log("Factory        :", factoryAddr);
        console2.log("Beacon         :", address(beacon));
        console2.log("Beacon owner   :", beacon.owner());
        console2.log("Old impl       :", oldImpl);

        vm.startBroadcast();

        MantleYieldVault newImpl = new MantleYieldVault();
        beacon.upgradeTo(address(newImpl));

        vm.stopBroadcast();

        console2.log("New impl       :", address(newImpl));
        console2.log("");

        // ── Verification ─────────────────────────────────────────
        address currentImpl = beacon.implementation();
        console2.log("=== Post-upgrade Verification ===");
        console2.log("Beacon.impl()  :", currentImpl);
        console2.log("Matches new?   :", currentImpl == address(newImpl));

        uint256 proxyCount = factory.vaultCount();
        if (proxyCount > 0) {
            address firstProxy = factory.vaults(0);
            MantleYieldVault vault = MantleYieldVault(firstProxy);
            console2.log("");
            console2.log("Proxy[0]       :", firstProxy);
            console2.log("  totalAssets():", vault.totalAssets());
            console2.log("  paused()     :", vault.paused());
        }

        console2.log("");
        console2.log("=== Upgrade Complete ===");
    }
}
