// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OperatorExecutor} from "../../src/protocol/OperatorExecutor.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @title UpgradeOperatorExecutor
/// @notice Upgrades the OperatorExecutor UUPS proxy to a new implementation.
///         Caller must hold DEFAULT_ADMIN_ROLE on the proxy.
///
/// Required env vars:
///   F_OPERATOR_EXECUTOR  – address of the deployed OperatorExecutor proxy
///
/// Usage:
///   # Dry run
///   forge script script/protocol/UpgradeOperatorExecutor.s.sol \
///       --rpc-url mantle_sepolia -vvvv
///
///   # Broadcast
///   forge script script/protocol/UpgradeOperatorExecutor.s.sol \
///       --rpc-url mantle_sepolia --broadcast -vvvv
contract UpgradeOperatorExecutor is Script {
    function run() external {
        address proxyAddr = vm.envAddress("F_OPERATOR_EXECUTOR");
        OperatorExecutor proxy = OperatorExecutor(proxyAddr);

        address oldImpl = address(uint160(uint256(vm.load(proxyAddr, ERC1967Utils.IMPLEMENTATION_SLOT))));

        console2.log("=== Upgrade OperatorExecutor ===");
        console2.log("Proxy          :", proxyAddr);
        console2.log("Old impl       :", oldImpl);

        vm.startBroadcast();

        OperatorExecutor newImpl = new OperatorExecutor();
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
