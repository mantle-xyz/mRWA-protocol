// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DeploySubRedManagementAdapter} from "../../script/strategy/DeploySubRedManagementAdapter.s.sol";
import {MockSubRedManagement} from "../../src/mocks/strategy/MockSubRedManagement.sol";
import {MockERC20Mintable} from "../../src/mocks/token/MockERC20Mintable.sol";
import {Test} from "forge-std/Test.sol";

contract MockVaultForScript {
    address internal immutable asset_;

    constructor(address assetAddress) {
        asset_ = assetAddress;
    }

    function asset() external view returns (address) {
        return asset_;
    }
}

contract DeploySubRedManagementAdapterScriptTest is Test {
    function test_Run_DoesNotRequireFPrivateKey() public {
        MockERC20Mintable stable = new MockERC20Mintable("Mock Stable", "mStable", 6);
        MockERC20Mintable stToken = new MockERC20Mintable("Mock ST", "mST", 18);
        MockVaultForScript vault = new MockVaultForScript(address(stable));
        MockSubRedManagement subRed = new MockSubRedManagement(address(this));

        vm.setEnv("F_PRIVATE_KEY", "");
        vm.setEnv("ADAPTER_VAULT", vm.toString(address(vault)));
        vm.setEnv("ADAPTER_SUBRED_MANAGEMENT", vm.toString(address(subRed)));
        vm.setEnv("ADAPTER_ST_TOKEN", vm.toString(address(stToken)));
        vm.setEnv("ADAPTER_ADMIN", vm.toString(makeAddr("admin")));
        vm.setEnv("ADAPTER_CONTROLLER", vm.toString(makeAddr("controller")));
        vm.setEnv("ADAPTER_ACCOUNTANT", vm.toString(makeAddr("accountant")));
        vm.setEnv("ADAPTER_PRICE_ORACLE", vm.toString(address(0)));

        DeploySubRedManagementAdapter script = new DeploySubRedManagementAdapter();
        script.run();
    }
}
