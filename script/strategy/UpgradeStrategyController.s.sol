// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {StrategyControllerFactory} from "../../src/protocol/StrategyControllerFactory.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Script, console2} from "forge-std/Script.sol";

contract UpgradeStrategyController is Script {
    function run() external {
        address factoryAddr = vm.envAddress("F_STRATEGY_CONTROLLER_FACTORY");
        StrategyControllerFactory factory = StrategyControllerFactory(factoryAddr);
        UpgradeableBeacon beacon = factory.BEACON();

        address oldImpl = beacon.implementation();

        console2.log("=== Upgrade StrategyController Implementation ===");
        console2.log("Factory        :", factoryAddr);
        console2.log("Beacon         :", address(beacon));
        console2.log("Beacon owner   :", beacon.owner());
        console2.log("Old impl       :", oldImpl);

        vm.startBroadcast();

        StrategyController newImpl = new StrategyController();
        beacon.upgradeTo(address(newImpl));

        vm.stopBroadcast();

        console2.log("New impl       :", address(newImpl));
        console2.log("");

        address currentImpl = beacon.implementation();
        console2.log("=== Post-upgrade Verification ===");
        console2.log("Beacon.impl()  :", currentImpl);
        console2.log("Matches new?   :", currentImpl == address(newImpl));
        console2.log("");
        console2.log("=== Upgrade Complete ===");
    }
}
