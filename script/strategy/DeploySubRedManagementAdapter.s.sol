// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SubRedManagementAdapter} from "../../src/adapters/digift/SubRedManagementAdapter.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @title DeploySubRedManagementAdapter
/// @notice Deploy a SubRed adapter using the signer configured by `forge script`.
///
/// Required env:
/// - ADAPTER_VAULT
/// - ADAPTER_SUBRED_MANAGEMENT
/// - ADAPTER_ST_TOKEN
/// - ADAPTER_ADMIN
/// - ADAPTER_CONTROLLER
/// - ADAPTER_ACCOUNTANT
///
/// Optional env:
/// - ADAPTER_PRICE_ORACLE                 (default: address(0))
contract DeploySubRedManagementAdapter is Script {
    function run() external {
        address vault_ = vm.envAddress("ADAPTER_VAULT");
        address subRedManagement = vm.envAddress("ADAPTER_SUBRED_MANAGEMENT");
        address stToken = vm.envAddress("ADAPTER_ST_TOKEN");
        address admin = vm.envAddress("ADAPTER_ADMIN");
        address controllerAddr = vm.envAddress("ADAPTER_CONTROLLER");
        address accountantAddr = vm.envAddress("ADAPTER_ACCOUNTANT");
        address priceOracle = vm.envOr("ADAPTER_PRICE_ORACLE", address(0));

        vm.startBroadcast();

        SubRedManagementAdapter adapter = new SubRedManagementAdapter(
            vault_, subRedManagement, stToken, admin, controllerAddr, accountantAddr, priceOracle
        );

        vm.stopBroadcast();

        console2.log("subred adapter:", address(adapter));
        console2.log("vault:", vault_);
        console2.log("controller:", controllerAddr);
        console2.log("accountant:", accountantAddr);
        console2.log("st token:", stToken);
        console2.log("subred management:", subRedManagement);
        console2.log("price oracle:", priceOracle);
    }
}
