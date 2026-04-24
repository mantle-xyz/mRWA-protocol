// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @title ReplaceStrategyAdapter
/// @notice Swap an active StrategyController adapter with a new one in a single broadcast.
///         Preserves the old adapter's priority/weight/isAsync config by default.
///
///         Required on-chain preconditions before running:
///           - Old adapter has zero invest in-flight (vault.adapterInvestInFlightTokens(old) == 0)
///           - Old adapter has zero redeem in-flight (vault.adapterRedeemInFlightUsdc(old) == 0)
///         Otherwise deactivateStrategy reverts StrategyHasInFlight; operator must run
///         settleAdapter first to clear in-flight records.
///
///         Execution steps (all in one tx):
///           1. setStrategyOrder(order without OLD)
///           2. deactivateStrategy(OLD)
///           3. registerStrategy(NEW, weight, priority, isAsync)
///           4. activateStrategy(NEW)
///           5. setStrategyOrder(final order with NEW inserted at OLD's position)
///
/// Required env:
///   F_CONTROLLER_ADDRESS     – deployed StrategyController proxy
///   REPLACE_OLD_ADAPTER      – adapter being retired
///   REPLACE_NEW_ADAPTER      – freshly-deployed replacement adapter
///
/// Optional env (default: copy OLD's on-chain config):
///   REPLACE_WEIGHT_BPS       – override targetWeightBps (0-10000)
///   REPLACE_PRIORITY         – override priority
///   REPLACE_IS_ASYNC         – override isAsync ("true"/"false")
contract ReplaceStrategyAdapter is Script {
    function run() external {
        StrategyController controller = StrategyController(vm.envAddress("F_CONTROLLER_ADDRESS"));
        address oldAdapter = vm.envAddress("REPLACE_OLD_ADAPTER");
        address newAdapter = vm.envAddress("REPLACE_NEW_ADAPTER");

        require(oldAdapter != newAdapter, "OLD equals NEW");

        // ─── Read old adapter's on-chain config (for default propagation) ───
        (uint16 oldWeight, uint16 oldPriority, bool oldIsAsync, bool oldActive, bool oldExists) =
            _readStrategyInfo(controller, oldAdapter);
        require(oldExists, "old adapter not registered");
        require(oldActive, "old adapter not active");

        uint16 weight = uint16(vm.envOr("REPLACE_WEIGHT_BPS", uint256(oldWeight)));
        uint16 priority = uint16(vm.envOr("REPLACE_PRIORITY", uint256(oldPriority)));
        bool isAsync = vm.envOr("REPLACE_IS_ASYNC", oldIsAsync);

        // ─── In-flight precondition check ───
        IMantleYieldVault vault = controller.vault();
        uint256 pendingInvest = vault.adapterInvestInFlightTokens(oldAdapter);
        uint256 pendingRedeem = vault.adapterRedeemInFlightUsdc(oldAdapter);

        console2.log("=== Replace Strategy Adapter ===");
        console2.log("Controller       :", address(controller));
        console2.log("OLD adapter      :", oldAdapter);
        console2.log("  weightBps      :", oldWeight);
        console2.log("  priority       :", oldPriority);
        console2.log("  isAsync        :", oldIsAsync);
        console2.log("  invest inFlight:", pendingInvest);
        console2.log("  redeem inFlight:", pendingRedeem);
        console2.log("NEW adapter      :", newAdapter);
        console2.log("  weightBps      :", weight);
        console2.log("  priority       :", priority);
        console2.log("  isAsync        :", isAsync);

        require(pendingInvest == 0 && pendingRedeem == 0, "OLD adapter has in-flight; run settleAdapter first");

        // ─── Compute new order: replace OLD with NEW at the same slot ───
        uint256 len = controller.strategyOrderLength();
        address[] memory currentOrder = new address[](len);
        for (uint256 i = 0; i < len; i++) {
            currentOrder[i] = controller.strategyOrder(i);
        }

        address[] memory orderWithoutOld = new address[](len - _countOccurrences(currentOrder, oldAdapter));
        uint256 oldIndex = type(uint256).max;
        {
            uint256 j;
            for (uint256 i = 0; i < len; i++) {
                if (currentOrder[i] == oldAdapter) {
                    if (oldIndex == type(uint256).max) oldIndex = i;
                    continue;
                }
                orderWithoutOld[j++] = currentOrder[i];
            }
        }
        require(oldIndex != type(uint256).max, "OLD not in strategyOrder");

        address[] memory finalOrder = new address[](orderWithoutOld.length + 1);
        for (uint256 i = 0; i < orderWithoutOld.length; i++) {
            // insert NEW at the same slot index OLD had previously
            if (i == oldIndex) {
                finalOrder[i] = newAdapter;
                finalOrder[i + 1] = orderWithoutOld[i];
                for (uint256 k = i + 1; k < orderWithoutOld.length; k++) {
                    finalOrder[k + 1] = orderWithoutOld[k];
                }
                break;
            }
            finalOrder[i] = orderWithoutOld[i];
        }
        if (oldIndex >= orderWithoutOld.length) {
            // OLD was at the tail
            for (uint256 i = 0; i < orderWithoutOld.length; i++) {
                finalOrder[i] = orderWithoutOld[i];
            }
            finalOrder[orderWithoutOld.length] = newAdapter;
        }

        vm.startBroadcast();

        // 1. Remove OLD from order (must happen before deactivate)
        controller.setStrategyOrder(orderWithoutOld);
        console2.log("[1/5] Order updated (OLD removed)");

        // 2. Deactivate OLD
        controller.deactivateStrategy(oldAdapter);
        console2.log("[2/5] OLD deactivated");

        // 3. Register NEW
        controller.registerStrategy(newAdapter, weight, priority, isAsync);
        console2.log("[3/5] NEW registered");

        // 4. Activate NEW
        controller.activateStrategy(newAdapter);
        console2.log("[4/5] NEW activated");

        // 5. Final order with NEW at OLD's slot
        controller.setStrategyOrder(finalOrder);
        console2.log("[5/5] Final order set (NEW in place of OLD)");

        vm.stopBroadcast();

        console2.log("=== Replacement complete ===");
        console2.log("Final order length:", finalOrder.length);
        for (uint256 i = 0; i < finalOrder.length; i++) {
            console2.log("  [", i);
            console2.log("  ]:", finalOrder[i]);
        }
    }

    function _readStrategyInfo(StrategyController controller, address adapter)
        internal
        view
        returns (uint16 weight, uint16 priority, bool isAsync, bool isActive, bool exists)
    {
        return controller.strategyInfo(adapter);
    }

    function _countOccurrences(address[] memory arr, address target) internal pure returns (uint256 c) {
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == target) c++;
        }
    }
}
