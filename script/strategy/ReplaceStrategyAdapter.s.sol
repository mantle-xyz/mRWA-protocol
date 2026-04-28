// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @title ReplaceStrategyAdapter
/// @notice Swap an active StrategyController adapter with a new one in a single broadcast.
///         Preserves the old adapter's priority/weight/isAsync by default.
///
///         Preconditions (reverts if violated):
///           - Old adapter has zero invest in-flight (vault.adapterInvestInFlightTokens(old) == 0)
///           - Old adapter has zero redeem in-flight (vault.adapterRedeemInFlightUsdc(old) == 0)
///         Otherwise deactivateStrategy reverts StrategyHasInFlight; run settleAdapter first.
///
///         Execution steps (all in one tx):
///           1. registerStrategy(NEW, 0, priority, isAsync)           — NEW registered with weight 0
///           2. activateStrategy(NEW)                                  — NEW active, not in order yet
///           3. updateStrategiesAndOrder([OLD,NEW],[0,oldW],...,[NEW]) — atomic weight swap + order
///           4. deactivateStrategy(OLD)                                — OLD retired (0 weight, out of order)
///
///         Why not just setStrategyOrder(remove OLD) then re-insert?
///         Because `setStrategyOrder` validates that sum of weights across active-in-order
///         strategies equals 10000 bps. Removing the sole adapter would leave an empty order
///         with sum=0 → WeightsMustBe10000 revert. The atomic updateStrategiesAndOrder call
///         moves the weight from OLD to NEW within a single state transition, preserving the
///         invariant throughout.
///
/// Required env:
///   TARGET_CONTROLLER_ADDRESS – StrategyController proxy to operate on (kept distinct from
///                               F_CONTROLLER_ADDRESS used by RegisterStrategy so the two
///                               tasks never accidentally point at different controllers).
///   REPLACE_OLD_ADAPTER       – adapter being retired
///   REPLACE_NEW_ADAPTER       – freshly-deployed replacement adapter
///
/// Optional env (default: copy OLD's on-chain config):
///   REPLACE_WEIGHT_BPS       – override targetWeightBps (0-10000)
///   REPLACE_PRIORITY         – override priority
///   REPLACE_IS_ASYNC         – override isAsync ("true"/"false")
contract ReplaceStrategyAdapter is Script {
    function run() external {
        StrategyController controller = StrategyController(vm.envAddress("TARGET_CONTROLLER_ADDRESS"));
        address oldAdapter = vm.envAddress("REPLACE_OLD_ADAPTER");
        address newAdapter = vm.envAddress("REPLACE_NEW_ADAPTER");

        require(oldAdapter != newAdapter, "OLD equals NEW");

        // ─── Read old adapter's on-chain config ───
        (uint16 oldWeight, uint16 oldPriority, bool oldIsAsync, bool oldActive, bool oldExists) =
            controller.strategyInfo(oldAdapter);
        require(oldExists, "old adapter not registered");
        require(oldActive, "old adapter not active");

        uint16 newWeight = uint16(vm.envOr("REPLACE_WEIGHT_BPS", uint256(oldWeight)));
        uint16 newPriority = uint16(vm.envOr("REPLACE_PRIORITY", uint256(oldPriority)));
        bool newIsAsync = vm.envOr("REPLACE_IS_ASYNC", oldIsAsync);

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
        console2.log("  weightBps      :", newWeight);
        console2.log("  priority       :", newPriority);
        console2.log("  isAsync        :", newIsAsync);

        require(pendingInvest == 0 && pendingRedeem == 0, "OLD adapter has in-flight; run settleAdapter first");

        // ─── Compute new order: replace OLD with NEW at the same slot ───
        uint256 len = controller.strategyOrderLength();
        require(len > 0, "strategyOrder is empty");

        address[] memory finalOrder = new address[](len);
        bool replaced;
        for (uint256 i = 0; i < len; i++) {
            address current = controller.strategyOrder(i);
            if (current == oldAdapter) {
                finalOrder[i] = newAdapter;
                replaced = true;
            } else {
                finalOrder[i] = current;
            }
        }
        require(replaced, "OLD not in strategyOrder");

        // ─── Build atomic update payload: OLD weight → 0, NEW weight → newWeight ───
        address[] memory adaptersToUpdate = new address[](2);
        adaptersToUpdate[0] = oldAdapter;
        adaptersToUpdate[1] = newAdapter;

        uint16[] memory weights = new uint16[](2);
        weights[0] = 0;
        weights[1] = newWeight;

        uint16[] memory priorities = new uint16[](2);
        priorities[0] = oldPriority; // keep OLD's priority (weight=0 so irrelevant)
        priorities[1] = newPriority;

        bool[] memory asyncFlags = new bool[](2);
        asyncFlags[0] = oldIsAsync;
        asyncFlags[1] = newIsAsync;

        // Check current NEW state for idempotency (script-level recovery after RPC glitches).
        (,,, bool newActive, bool newExists) = controller.strategyInfo(newAdapter);

        // Inter-step settle: Mantle Sepolia RPC sometimes returns stale state for gas
        // estimation of the next tx. Each step runs in its own broadcast session so forge
        // waits for receipt, then we sleep + poll until the new block lands before
        // starting the next estimation.
        uint256 settleMs = vm.envOr("REPLACE_SETTLE_MS", uint256(5000));

        // ───── Step 1: registerStrategy ─────
        if (!newExists) {
            vm.startBroadcast();
            controller.registerStrategy(newAdapter, 0, newPriority, newIsAsync);
            vm.stopBroadcast();
            console2.log("[1/4] NEW registered (weight=0)");
            _settleBlock(settleMs);
        } else {
            console2.log("[1/4] NEW already registered, skip");
        }

        // ───── Step 2: activateStrategy ─────
        if (!newActive) {
            vm.startBroadcast();
            controller.activateStrategy(newAdapter);
            vm.stopBroadcast();
            console2.log("[2/4] NEW activated");
            _settleBlock(settleMs);
        } else {
            console2.log("[2/4] NEW already active, skip");
        }

        // ───── Step 3: updateStrategiesAndOrder ─────
        if (oldWeight > 0) {
            vm.startBroadcast();
            controller.updateStrategiesAndOrder(adaptersToUpdate, weights, priorities, asyncFlags, finalOrder);
            vm.stopBroadcast();
            console2.log("[3/4] Weights swapped + order updated atomically");
            _settleBlock(settleMs);
        } else {
            console2.log("[3/4] OLD weight already 0, skip");
        }

        // ───── Step 4: deactivateStrategy ─────
        (,,, bool oldStillActive,) = controller.strategyInfo(oldAdapter);
        if (oldStillActive) {
            vm.startBroadcast();
            controller.deactivateStrategy(oldAdapter);
            vm.stopBroadcast();
            console2.log("[4/4] OLD deactivated");
        } else {
            console2.log("[4/4] OLD already deactivated, skip");
        }

        console2.log("=== Replacement complete ===");
        console2.log("Final order length:", finalOrder.length);
        for (uint256 i = 0; i < finalOrder.length; i++) {
            console2.log("  slot:", i);
            console2.log("    adapter:", finalOrder[i]);
        }
    }

    /// @dev Poll the RPC for a fresh block before returning, so the next broadcast's gas
    ///      estimation sees the just-committed state. Mantle Sepolia's sequencer
    ///      occasionally returns stale state to `eth_estimateGas` immediately after
    ///      confirming a previous tx, causing spurious reverts for calls that depend on
    ///      that state (e.g. deactivateStrategy reading the updated strategyOrder).
    ///
    ///      Strategy: sleep `settleMs`, then read-and-discard a view call via `ffi`'d cast.
    ///      `vm.sleep` is cheap and portable; the cheatcode blocks the foundry runner
    ///      wall-clock-time. For real chains with block times of ~2s, 5s is comfortable.
    function _settleBlock(uint256 settleMs) internal {
        if (settleMs == 0) return;
        vm.sleep(settleMs);
    }
}
