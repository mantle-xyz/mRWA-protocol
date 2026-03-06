// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StrategyController} from "../src/protocol/StrategyController.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Script, console2} from "forge-std/Script.sol";

contract DeployStrategyBeaconProxyScript is Script {
    function run() external {
        uint256 deployerPk = vm.envOr("DEPLOYER_PRIVATE_KEY", vm.envUint("PRIVATE_KEY"));
        address beacon = vm.envAddress("STRATEGY_BEACON");
        address admin = vm.envAddress("STRATEGY_ADMIN");
        address operator = vm.envAddress("STRATEGY_OPERATOR");
        address vault_ = vm.envAddress("STRATEGY_VAULT");
        if (vault_ == address(0)) {
            revert("STRATEGY_VAULT must be set to a deployed vault address in .env");
        }
        bytes memory initData = abi.encodeCall(
            StrategyController.initialize,
            (
                vault_,
                admin,
                operator,
                vm.envAddress("STRATEGY_EXECUTOR"),
                uint16(vm.envUint("STRATEGY_BUFFER_TARGET_BPS")),
                uint16(vm.envUint("STRATEGY_REBALANCE_THRESHOLD_BPS")),
                uint64(vm.envUint("STRATEGY_REBALANCE_COOLDOWN"))
            )
        );

        vm.startBroadcast(deployerPk);
        BeaconProxy proxy = new BeaconProxy(beacon, initData);
        vm.stopBroadcast();

        console2.log("strategy beacon:", beacon);
        console2.log("strategy proxy:", address(proxy));
        console2.log("strategy admin:", admin);
        console2.log("strategy operator:", operator);
    }
}
