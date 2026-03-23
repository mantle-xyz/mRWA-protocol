// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Script, console2} from "forge-std/Script.sol";

contract UpgradeStrategyControllerImpl is Script {
    function run() external {
        uint256 pk = vm.envUint("F_PRIVATE_KEY");
        address beacon = vm.envAddress("F_STRATEGY_CONTROLLER_FACTORY");

        vm.startBroadcast(pk);
        StrategyController newImpl = new StrategyController();
        console2.log("new implementation:", address(newImpl));

        UpgradeableBeacon(beacon).upgradeTo(address(newImpl));
        console2.log("beacon upgraded to:", UpgradeableBeacon(beacon).implementation());
        vm.stopBroadcast();
    }
}
