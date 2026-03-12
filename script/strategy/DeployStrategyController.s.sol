// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {StrategyControllerFactory} from "../../src/protocol/StrategyControllerFactory.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @title DeployStrategyController
/// @notice Deploys the full StrategyController stack:
///         1. StrategyController implementation
///         2. StrategyControllerFactory (creates UpgradeableBeacon internally)
///         3. StrategyController instance via BeaconProxy (through factory)
///
/// Required env vars (set via deploy-config YAML):
///   F_VAULT_ADDRESS                  – MantleYieldVault proxy address
///   F_ADMIN_ADDRESS                  – admin address (also used as beacon owner)
///   F_STRATEGY_MANAGER_ADDRESS       – address granted STRATEGY_MANAGER_ROLE
///   F_EXECUTOR_GATEWAY_ADDRESS       – address granted EXECUTOR_ROLE (must be a contract)
///   F_BUFFER_TARGET_BPS              – buffer target in bps (e.g. 500 = 5%)
///   F_REBALANCE_THRESHOLD_BPS        – rebalance threshold in bps (e.g. 100 = 1%)
///   F_REBALANCE_COOLDOWN             – minimum seconds between rebalances (e.g. 3600)
contract DeployStrategyController is Script {
    function run()
        external
        returns (StrategyController controllerImpl, StrategyControllerFactory factory, StrategyController controller)
    {
        address vaultAddr = vm.envAddress("F_VAULT_ADDRESS");
        address admin = vm.envAddress("F_ADMIN_ADDRESS");
        address strategyManager = vm.envAddress("F_STRATEGY_MANAGER_ADDRESS");
        address executorGateway = vm.envAddress("F_EXECUTOR_GATEWAY_ADDRESS");
        uint16 bufferTargetBps = uint16(vm.envUint("F_BUFFER_TARGET_BPS"));
        uint16 rebalanceThresholdBps = uint16(vm.envUint("F_REBALANCE_THRESHOLD_BPS"));
        uint64 rebalanceCooldown = uint64(vm.envUint("F_REBALANCE_COOLDOWN"));

        console2.log("=== DeployStrategyController ===");
        console2.log("Admin              :", admin);
        console2.log("Vault              :", vaultAddr);
        console2.log("Strategy manager   :", strategyManager);
        console2.log("Executor gateway   :", executorGateway);
        console2.log("Buffer target (bps):", bufferTargetBps);
        console2.log("Rebal threshold    :", rebalanceThresholdBps);
        console2.log("Rebal cooldown (s) :", rebalanceCooldown);

        vm.startBroadcast();

        // ---- 1. Deploy StrategyController implementation (locked) ----
        controllerImpl = new StrategyController();
        console2.log("[1/3] Controller impl    :", address(controllerImpl));

        // ---- 2. Deploy StrategyControllerFactory (creates UpgradeableBeacon internally) ----
        factory = new StrategyControllerFactory(address(controllerImpl), admin);
        console2.log("[2/3] ControllerFactory  :", address(factory));
        console2.log("       Beacon            :", address(factory.BEACON()));

        // ---- 3. Deploy StrategyController instance via BeaconProxy ----
        address controllerAddr = factory.deployAndInitController(
            vaultAddr, admin, strategyManager, executorGateway, bufferTargetBps, rebalanceThresholdBps, rebalanceCooldown
        );
        controller = StrategyController(controllerAddr);
        console2.log("[3/3] Controller (proxy) :", controllerAddr);

        vm.stopBroadcast();

        // Post-deploy verification
        console2.log("");
        console2.log("=== Post-deploy Verification ===");
        console2.log("Beacon -> impl:          ", factory.implementation());
        console2.log("Factory controller cnt:  ", factory.controllerCount());
        console2.log("Has ADMIN_ROLE:          ", controller.hasRole(controller.DEFAULT_ADMIN_ROLE(), admin));
        console2.log("Has STRATEGY_MANAGER:    ", controller.hasRole(controller.STRATEGY_MANAGER_ROLE(), strategyManager));
        console2.log("Has EXECUTOR_ROLE:       ", controller.hasRole(controller.EXECUTOR_ROLE(), executorGateway));
        console2.log("Buffer target bps:       ", controller.bufferTargetBps());
        console2.log("Rebalance threshold bps: ", controller.rebalanceThresholdBps());
        console2.log("Rebalance cooldown:      ", controller.rebalanceCooldown());
    }
}
