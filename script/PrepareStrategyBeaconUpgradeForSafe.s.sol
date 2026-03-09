// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TimelockUpgradeController} from "../src/governance/TimelockUpgradeController.sol";
import {StrategyController} from "../src/protocol/StrategyController.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Script, console2} from "forge-std/Script.sol";

interface ITimelockOps {
    function schedule(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external;
    function execute(address target, uint256 value, bytes calldata payload, bytes32 predecessor, bytes32 salt)
        external
        payable;
}

contract PrepareStrategyBeaconUpgradeForSafeScript is Script {
    function run() external {
        TimelockUpgradeController timelock = TimelockUpgradeController(payable(vm.envAddress("TIMELOCK_ADDRESS")));
        address beacon = vm.envAddress("STRATEGY_BEACON");
        bytes32 predecessor = vm.envOr("UPGRADE_PREDECESSOR", bytes32(0));
        bytes32 salt = vm.envBytes32("UPGRADE_SALT");
        uint256 delay = vm.envUint("UPGRADE_DELAY");
        bool executeOnchain = vm.envOr("UPGRADE_EXECUTE_ONCHAIN", false);

        address newImplementation = vm.envOr("NEW_IMPLEMENTATION", address(0));
        bool deployNewImplementation = vm.envOr("DEPLOY_NEW_IMPLEMENTATION", false);
        if (deployNewImplementation) {
            uint256 deployerPk = vm.envOr("DEPLOYER_PRIVATE_KEY", vm.envUint("PRIVATE_KEY"));
            vm.startBroadcast(deployerPk);
            StrategyController impl = new StrategyController();
            vm.stopBroadcast();
            newImplementation = address(impl);
            console2.log("deployed new implementation:", newImplementation);
        }
        require(newImplementation != address(0), "NEW_IMPLEMENTATION_NOT_SET");

        bytes memory beaconUpgradeData = abi.encodeCall(UpgradeableBeacon.upgradeTo, (newImplementation));
        bytes memory scheduleCallData =
            abi.encodeCall(ITimelockOps.schedule, (beacon, 0, beaconUpgradeData, predecessor, salt, delay));
        bytes memory executeCallData =
            abi.encodeCall(ITimelockOps.execute, (beacon, 0, beaconUpgradeData, predecessor, salt));
        bytes32 opId = timelock.hashOperation(beacon, 0, beaconUpgradeData, predecessor, salt);

        if (executeOnchain) {
            require(delay == 0, "ONCHAIN_MODE_REQUIRES_ZERO_DELAY");
            uint256 callerPk =
                vm.envOr("UPGRADE_CALLER_PRIVATE_KEY", vm.envOr("DEPLOYER_PRIVATE_KEY", vm.envUint("PRIVATE_KEY")));
            vm.startBroadcast(callerPk);
            timelock.schedule(beacon, 0, beaconUpgradeData, predecessor, salt, delay);
            timelock.execute(beacon, 0, beaconUpgradeData, predecessor, salt);
            vm.stopBroadcast();
            console2.log("onchain schedule+execute completed");
        }

        console2.log("timelock target:", address(timelock));
        console2.log("beacon:", beacon);
        console2.log("new implementation:", newImplementation);
        console2.log("execute onchain:", executeOnchain);
        console2.log("operation id:");
        console2.logBytes32(opId);
        console2.log("safe tx #1 schedule data:");
        console2.logBytes(scheduleCallData);
        console2.log("safe tx #2 execute data:");
        console2.logBytes(executeCallData);
    }
}
