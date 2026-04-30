// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StrategyController} from "./StrategyController.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

/**
 * @title StrategyControllerFactory
 * @notice Deploys StrategyController instances behind a shared UpgradeableBeacon.
 *   - All controllers share the same implementation contract
 *   - Beacon owner can upgrade all controllers atomically via UpgradeableBeacon.upgradeTo()
 *   - Supports two deployment modes:
 *       1. deployController()          — deploy only, caller initializes later
 *       2. deployAndInitController()   — deploy + initialize atomically
 *   - Controller instances are exclusively deployed via BeaconProxy
 */
contract StrategyControllerFactory {
    // =============================================================
    // Errors
    // =============================================================

    error Factory__ZeroAddress();

    // =============================================================
    // Events
    // =============================================================

    event ControllerDeployed(address indexed controller, uint256 index, bool initialized);

    // =============================================================
    // State
    // =============================================================

    UpgradeableBeacon public immutable BEACON;
    address[] public controllers;

    // =============================================================
    // Constructor
    // =============================================================

    /**
     * @param impl Address of the StrategyController implementation contract
     * @param beaconOwner Address that controls beacon upgrades (e.g. multisig / timelock)
     */
    constructor(address impl, address beaconOwner) {
        if (impl == address(0) || beaconOwner == address(0)) revert Factory__ZeroAddress();
        BEACON = new UpgradeableBeacon(impl, beaconOwner);
    }

    // =============================================================
    // Controller Deployment
    // =============================================================

    /**
     * @notice Deploy an uninitialized StrategyController as a BeaconProxy.
     *         Caller must call controller.initialize(...) separately afterwards.
     */
    function deployController() external returns (address controller) {
        BeaconProxy proxy = new BeaconProxy(address(BEACON), "");
        controller = address(proxy);
        controllers.push(controller);

        emit ControllerDeployed(controller, controllers.length - 1, false);
    }

    /**
     * @notice Deploy and atomically initialize a StrategyController as a BeaconProxy.
     * @param vault_ The MantleYieldVault address this controller manages
     * @param admin Address granted DEFAULT_ADMIN_ROLE
     * @param strategyManager Address granted STRATEGY_MANAGER_ROLE
     * @param executorGateway Address granted OPERATOR_EXECUTOR_ROLE (must be a contract)
     * @param bufferTargetBps_ Buffer target in basis points
     * @param rebalanceThresholdBps_ Rebalance threshold in basis points
     * @param rebalanceCooldown_ Minimum seconds between rebalances
     */
    function deployAndInitController(
        address vault_,
        address admin,
        address strategyManager,
        address executorGateway,
        uint16 bufferTargetBps_,
        uint16 rebalanceThresholdBps_,
        uint64 rebalanceCooldown_
    ) external returns (address controller) {
        bytes memory initData = abi.encodeCall(
            StrategyController.initialize,
            (
                vault_,
                admin,
                strategyManager,
                executorGateway,
                bufferTargetBps_,
                rebalanceThresholdBps_,
                rebalanceCooldown_
            )
        );

        BeaconProxy proxy = new BeaconProxy(address(BEACON), initData);
        controller = address(proxy);
        controllers.push(controller);

        emit ControllerDeployed(controller, controllers.length - 1, true);
    }

    // =============================================================
    // View Functions
    // =============================================================

    function controllerCount() external view returns (uint256) {
        return controllers.length;
    }

    function implementation() external view returns (address) {
        return BEACON.implementation();
    }

    function getAllControllers() external view returns (address[] memory) {
        return controllers;
    }
}
