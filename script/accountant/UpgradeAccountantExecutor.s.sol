// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccountantExecutor} from "../../src/accountant/AccountantExecutor.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @title UpgradeAccountantExecutor
/// @notice Upgrades the AccountantExecutor UUPS proxy to a new implementation.
///         Caller must hold DEFAULT_ADMIN_ROLE on the proxy.
///
/// Required env vars:
///   F_ACCOUNTANT_EXECUTOR  – address of the deployed AccountantExecutor proxy
///
/// Usage:
///   # Dry run
///   forge script script/accountant/UpgradeAccountantExecutor.s.sol \
///       --rpc-url mantle_sepolia -vvvv
///
///   # Broadcast
///   forge script script/accountant/UpgradeAccountantExecutor.s.sol \
///       --rpc-url mantle_sepolia --broadcast -vvvv
contract UpgradeAccountantExecutor is Script {
    function run() external {
        address proxyAddr = vm.envAddress("F_ACCOUNTANT_EXECUTOR");
        AccountantExecutor proxy = AccountantExecutor(proxyAddr);

        address oldImpl = address(uint160(uint256(vm.load(proxyAddr, ERC1967Utils.IMPLEMENTATION_SLOT))));

        console2.log("=== Upgrade AccountantExecutor ===");
        console2.log("Proxy          :", proxyAddr);
        console2.log("Old impl       :", oldImpl);

        vm.startBroadcast();

        AccountantExecutor newImpl = new AccountantExecutor();
        proxy.upgradeToAndCall(address(newImpl), "");

        vm.stopBroadcast();

        address currentImpl = address(uint160(uint256(vm.load(proxyAddr, ERC1967Utils.IMPLEMENTATION_SLOT))));

        console2.log("New impl       :", address(newImpl));
        console2.log("");
        console2.log("=== Post-upgrade Verification ===");
        console2.log("Current impl   :", currentImpl);
        console2.log("Matches new?   :", currentImpl == address(newImpl));
        console2.log("");
        console2.log("=== Upgrade Complete ===");
    }
}
