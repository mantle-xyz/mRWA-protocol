// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategyAdapterCore} from "../../src/interfaces/adapters/IStrategyAdapterCore.sol";
import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @title RegisterStrategy
/// @notice Deploys a new strategy adapter (optional) and registers it into StrategyController,
///         then updates the strategy order to include the new adapter.
///
/// Required env vars:
///   F_CONTROLLER_ADDRESS         – StrategyController proxy address
///   F_STRATEGY_ADAPTER_ADDRESS   – Pre-deployed adapter address to register.
///                                  If set to address(0) or omitted, no adapter is deployed
///                                  (you should deploy the adapter separately first).
///   F_TARGET_WEIGHT_BPS          – Target allocation weight in basis points (e.g. 5000 = 50%)
///   F_PRIORITY                   – Execution priority (lower = higher priority, e.g. 1)
///   F_IS_ASYNC                   – "true" for async (ERC-7540), "false" for sync (ERC-4626)
///
/// Optional env vars:
///   F_SET_ORDER                  – "true" (default) to call setStrategyOrder after registration.
///                                  When true, the script reads the current order and appends the
///                                  new adapter. Set to "false" to skip (useful when batch-registering
///                                  multiple adapters before a single setStrategyOrder call).
contract RegisterStrategy is Script {
    function run() external {
        address controllerAddr = vm.envAddress("F_CONTROLLER_ADDRESS");
        address adapterAddr = vm.envAddress("F_STRATEGY_ADAPTER_ADDRESS");
        uint16 targetWeightBps = uint16(vm.envUint("F_TARGET_WEIGHT_BPS"));
        uint16 priority = uint16(vm.envUint("F_PRIORITY"));
        bool isAsync = vm.envBool("F_IS_ASYNC");
        bool setOrder = vm.envOr("F_SET_ORDER", true);

        StrategyController controller = StrategyController(controllerAddr);

        console2.log("=== RegisterStrategy ===");
        console2.log("Controller      :", controllerAddr);
        console2.log("Adapter         :", adapterAddr);
        console2.log("TargetWeightBps :", targetWeightBps);
        console2.log("Priority        :", priority);
        console2.log("IsAsync         :", isAsync);
        console2.log("SetOrder        :", setOrder);

        // Pre-flight: read adapter metadata
        IStrategyAdapterCore adapter = IStrategyAdapterCore(adapterAddr);
        console2.log("");
        console2.log("--- Adapter Info ---");
        console2.log("Name            :", adapter.name());
        console2.log("Asset           :", adapter.asset());
        console2.log("Vault           :", adapter.vault());

        vm.startBroadcast();

        // ---- 1. Register strategy in StrategyController ----
        controller.registerStrategy(adapterAddr, targetWeightBps, priority, isAsync);
        console2.log("");
        console2.log("[1] Strategy registered");

        // ---- 1b. Activate strategy ----
        controller.activateStrategy(adapterAddr);
        console2.log("[1b] Strategy activated");

        // ---- 2. Update strategy order (append new adapter) ----
        if (setOrder) {
            uint256 currentLen = controller.strategyOrderLength();
            address[] memory newOrder = new address[](currentLen + 1);

            uint256 insertIdx = currentLen;
            for (uint256 i = 0; i < currentLen; i++) {
                address existing = controller.strategyOrder(i);
                newOrder[i] = existing;
                StrategyController.StrategyInfo memory info = _getStrategyInfo(controller, existing);
                if (info.priority > priority && insertIdx == currentLen) {
                    insertIdx = i;
                }
            }

            if (insertIdx < currentLen) {
                for (uint256 i = currentLen; i > insertIdx; i--) {
                    newOrder[i] = newOrder[i - 1];
                }
                newOrder[insertIdx] = adapterAddr;
            } else {
                newOrder[currentLen] = adapterAddr;
            }

            controller.setStrategyOrder(_toCalldata(newOrder));
            console2.log("[2] Strategy order updated (length:", newOrder.length, ")");
        } else {
            console2.log("[2] Skipped setStrategyOrder");
            console2.log("    setOrder:", setOrder);
        }

        vm.stopBroadcast();

        // ---- Post-deploy verification ----
        console2.log("");
        console2.log("=== Post-register Verification ===");
        (uint16 w, uint16 p, bool async_, bool active_, bool exists_) = controller.strategyInfo(adapterAddr);
        console2.log("Exists          :", exists_);
        console2.log("TargetWeightBps :", w);
        console2.log("Priority        :", p);
        console2.log("IsAsync         :", async_);
        console2.log("IsActive        :", active_);
        console2.log("Order length    :", controller.strategyOrderLength());

        uint256 orderLen = controller.strategyOrderLength();
        if (orderLen > 0) {
            console2.log("");
            console2.log("--- Current Strategy Order ---");
            for (uint256 i = 0; i < orderLen; i++) {
                address s = controller.strategyOrder(i);
                (uint16 sw,,,,) = controller.strategyInfo(s);
                console2.log("  [%d] %s  weight: %d", i, s, sw);
            }
        }
    }

    function _getStrategyInfo(StrategyController controller, address adapter)
        internal
        view
        returns (StrategyController.StrategyInfo memory info)
    {
        (uint16 w, uint16 p, bool async_, bool active_, bool exists_) = controller.strategyInfo(adapter);
        info = StrategyController.StrategyInfo({
            targetWeightBps: w, priority: p, isAsync: async_, isActive: active_, exists: exists_
        });
    }

    function _toCalldata(address[] memory arr) internal pure returns (address[] memory) {
        return arr;
    }
}
