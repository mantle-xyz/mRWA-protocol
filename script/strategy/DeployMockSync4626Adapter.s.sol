// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockSync4626Adapter} from "../../src/adapters/mock/MockSync4626Adapter.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @title DeployMockSync4626Adapter
/// @notice Deploys a MockSync4626Adapter instance (non-upgradeable, direct deploy).
///
///         The adapter uses immutable state variables set via constructor, so it is
///         deployed directly rather than through a Factory/BeaconProxy pattern.
///
/// Required env vars (set via deploy-config YAML):
///   F_VAULT_ADDRESS        – MantleYieldVault proxy address
///   F_TARGET_4626_ADDRESS  – ERC-4626 target vault to deposit into
///   F_ADMIN_ADDRESS        – admin address (receives DEFAULT_ADMIN_ROLE + PAUSER_ROLE)
///   F_CONTROLLER_ADDRESS   – StrategyController proxy address (receives CONTROLLER_ROLE + PAUSER_ROLE)
///   F_ACCOUNTANT_ADDRESS   – accountant address (receives ACCOUNTANT_ROLE)
contract DeployMockSync4626Adapter is Script {
    function run() external returns (MockSync4626Adapter adapter) {
        address vaultAddr = vm.envAddress("F_VAULT_ADDRESS");
        address target4626 = vm.envAddress("F_TARGET_4626_ADDRESS");
        address admin = vm.envAddress("F_ADMIN_ADDRESS");
        address controller = vm.envAddress("F_CONTROLLER_ADDRESS");
        address accountant = vm.envAddress("F_ACCOUNTANT_ADDRESS");

        console2.log("=== DeployMockSync4626Adapter ===");
        console2.log("Vault          :", vaultAddr);
        console2.log("Target 4626    :", target4626);
        console2.log("Admin          :", admin);
        console2.log("Controller     :", controller);
        console2.log("Accountant     :", accountant);

        vm.startBroadcast();

        // ---- 1. Deploy MockSync4626Adapter (non-upgradeable) ----
        adapter = new MockSync4626Adapter(vaultAddr, target4626, admin, controller, accountant);
        console2.log("[1/1] Adapter deployed   :", address(adapter));

        vm.stopBroadcast();

        // Post-deploy verification
        console2.log("");
        console2.log("=== Post-deploy Verification ===");
        console2.log("Name:              ", adapter.name());
        console2.log("Asset:             ", adapter.asset());
        console2.log("Vault:             ", adapter.vault());
        console2.log("PosToken:          ", adapter.posToken());
        console2.log("Has ADMIN_ROLE:    ", adapter.hasRole(adapter.DEFAULT_ADMIN_ROLE(), admin));
        console2.log("Has CONTROLLER:    ", adapter.hasRole(adapter.CONTROLLER_ROLE(), controller));
        console2.log("Has ACCOUNTANT:    ", adapter.hasRole(adapter.ACCOUNTANT_ROLE(), accountant));
        console2.log("Has PAUSER (admin):", adapter.hasRole(adapter.PAUSER_ROLE(), admin));
        console2.log("Has PAUSER (ctrl): ", adapter.hasRole(adapter.PAUSER_ROLE(), controller));
    }
}
