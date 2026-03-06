// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {TimelockUpgradeController} from "../src/governance/TimelockUpgradeController.sol";
import {StrategyController} from "../src/protocol/StrategyController.sol";

contract DeployStrategyBeaconWithTimelockScript is Script {
    function run() external {
        uint256 deployerPk = vm.envOr("DEPLOYER_PRIVATE_KEY", vm.envUint("PRIVATE_KEY"));
        address deployer = vm.addr(deployerPk);

        uint256 minDelay = vm.envUint("TIMELOCK_MIN_DELAY");
        address proposer = vm.envAddress("TIMELOCK_PROPOSER");
        address timelockExecutor = vm.envAddress("TIMELOCK_EXECUTOR");
        address timelockAdmin = vm.envOr("TIMELOCK_ADMIN", deployer);
        bool renounceAdmin = vm.envOr("TIMELOCK_RENOUNCE_ADMIN", true);

        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = timelockExecutor;

        vm.startBroadcast(deployerPk);
        TimelockUpgradeController timelock =
            new TimelockUpgradeController(minDelay, proposers, executors, timelockAdmin);
        StrategyController implementation = new StrategyController();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(implementation), address(timelock));

        address firstProxy = address(0);
        if (vm.envOr("STRATEGY_DEPLOY_FIRST_PROXY", false)) {
            address strategyAdmin = vm.envOr("STRATEGY_ADMIN", address(timelock));
            address strategyOperator = vm.envOr("STRATEGY_OPERATOR", strategyAdmin);
            bytes memory initData = abi.encodeCall(
                StrategyController.initialize,
                (
                    vm.envAddress("STRATEGY_VAULT"),
                    strategyAdmin,
                    strategyOperator,
                    vm.envAddress("STRATEGY_EXECUTOR"),
                    uint16(vm.envUint("STRATEGY_BUFFER_TARGET_BPS")),
                    uint16(vm.envUint("STRATEGY_REBALANCE_THRESHOLD_BPS")),
                    uint64(vm.envUint("STRATEGY_REBALANCE_COOLDOWN"))
                )
            );
            firstProxy = address(new BeaconProxy(address(beacon), initData));
        }

        bytes32 adminRole = timelock.DEFAULT_ADMIN_ROLE();
        if (renounceAdmin && timelock.hasRole(adminRole, deployer)) {
            timelock.renounceRole(adminRole, deployer);
        }
        vm.stopBroadcast();

        console2.log("deployer:", deployer);
        console2.log("timelock:", address(timelock));
        console2.log("strategy implementation:", address(implementation));
        console2.log("strategy beacon:", address(beacon));
        console2.log("first strategy proxy:", firstProxy);
    }
}
