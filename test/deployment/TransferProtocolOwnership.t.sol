// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TransferProtocolOwnership} from "../../script/TransferProtocolOwnership.s.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {
    AccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Test} from "forge-std/Test.sol";

contract MockAdminProxy is AccessControl {
    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }
}

contract MockDefaultAdminRulesProxy is AccessControlDefaultAdminRules {
    constructor(uint48 initialDelay, address admin) AccessControlDefaultAdminRules(initialDelay, admin) {}
}

contract MockBeaconImplementation {}

contract MockBeaconFactory {
    UpgradeableBeacon public immutable BEACON;

    constructor(address implementation, address owner) {
        BEACON = new UpgradeableBeacon(implementation, owner);
    }
}

contract TransferProtocolOwnershipTest is Test {
    address internal constant BROADCAST_SENDER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

    MockDefaultAdminRulesProxy internal vault;
    MockDefaultAdminRulesProxy internal gateway;
    MockAdminProxy internal accountant;
    MockAdminProxy internal controller;
    MockAdminProxy internal oracle;
    MockAdminProxy internal accountantExecutor;
    MockAdminProxy internal operatorExecutor;
    MockAdminProxy internal adapter;

    MockBeaconFactory internal vaultFactory;
    MockBeaconFactory internal gatewayFactory;
    MockBeaconFactory internal accountantFactory;
    MockBeaconFactory internal controllerFactory;
    MockBeaconFactory internal oracleFactory;
    MockBeaconFactory internal adapterFactory;

    address internal oldAdmin = BROADCAST_SENDER;
    address internal newAdmin = makeAddr("newAdmin");
    address internal newBeaconOwner = makeAddr("newBeaconOwner");

    function setUp() public {
        vault = new MockDefaultAdminRulesProxy(1 days, oldAdmin);
        gateway = new MockDefaultAdminRulesProxy(1 days, oldAdmin);
        accountant = new MockAdminProxy(oldAdmin);
        controller = new MockAdminProxy(oldAdmin);
        oracle = new MockAdminProxy(oldAdmin);
        accountantExecutor = new MockAdminProxy(oldAdmin);
        operatorExecutor = new MockAdminProxy(oldAdmin);
        adapter = new MockAdminProxy(oldAdmin);

        address impl = address(new MockBeaconImplementation());
        vaultFactory = new MockBeaconFactory(impl, oldAdmin);
        gatewayFactory = new MockBeaconFactory(impl, oldAdmin);
        accountantFactory = new MockBeaconFactory(impl, oldAdmin);
        controllerFactory = new MockBeaconFactory(impl, oldAdmin);
        oracleFactory = new MockBeaconFactory(impl, oldAdmin);
        adapterFactory = new MockBeaconFactory(impl, oldAdmin);

        _setCommonEnv();
    }

    function test_GrantTransferThenRenounceFlow() public {
        vm.setEnv("TRANSFER_RENOUNCE_OLD_ADMIN", "true");
        TransferProtocolOwnership script = new TransferProtocolOwnership();
        vm.expectRevert(bytes("NEW_ADMIN_MISSING"));
        script.run();

        vm.setEnv("TRANSFER_RENOUNCE_OLD_ADMIN", "false");
        vm.setEnv("F_SENDER", vm.toString(oldAdmin));
        bytes32 complianceRole = keccak256("COMPLIANCE_ROLE");
        assertFalse(oracle.hasRole(complianceRole, newAdmin), "new admin should not have COMPLIANCE_ROLE pre-run");
        new TransferProtocolOwnership().run();
        _assertDefaultAdminTransfersScheduled();
        _assertDefaultAdminRulesAdmins(true, false);
        _assertPlainProxyAdmins(true, true);
        _assertBeaconOwners(newBeaconOwner);
        assertTrue(oracle.hasRole(complianceRole, newAdmin), "new admin should have COMPLIANCE_ROLE post-grant");

        _warpPastDefaultAdminTransferSchedule();
        vm.setEnv("TRANSFER_ACCEPT_DEFAULT_ADMIN", "true");
        vm.setEnv("F_SENDER", vm.toString(newAdmin));
        new TransferProtocolOwnership().run();
        _assertDefaultAdminRulesAdmins(false, true);
        _assertPlainProxyAdmins(true, true);
        _assertBeaconOwners(newBeaconOwner);

        vm.setEnv("TRANSFER_RENOUNCE_OLD_ADMIN", "true");
        vm.setEnv("TRANSFER_ACCEPT_DEFAULT_ADMIN", "false");
        vm.setEnv("F_SENDER", vm.toString(oldAdmin));
        new TransferProtocolOwnership().run();
        _assertDefaultAdminRulesAdmins(false, true);
        _assertPlainProxyAdmins(false, true);
        _assertBeaconOwners(newBeaconOwner);
    }

    function _setCommonEnv() internal {
        vm.setEnv("TRANSFER_OLD_ADMIN", vm.toString(oldAdmin));
        vm.setEnv("TRANSFER_NEW_ADMIN", vm.toString(newAdmin));
        vm.setEnv("TRANSFER_NEW_BEACON_OWNER", vm.toString(newBeaconOwner));

        vm.setEnv("TRANSFER_VAULT", vm.toString(address(vault)));
        vm.setEnv("TRANSFER_GATEWAY", vm.toString(address(gateway)));
        vm.setEnv("TRANSFER_ACCOUNTANT", vm.toString(address(accountant)));
        vm.setEnv("TRANSFER_CONTROLLER", vm.toString(address(controller)));
        vm.setEnv("TRANSFER_SANCTIONS_ORACLE", vm.toString(address(oracle)));
        vm.setEnv("TRANSFER_ACCOUNTANT_EXECUTOR", vm.toString(address(accountantExecutor)));
        vm.setEnv("TRANSFER_OPERATOR_EXECUTOR", vm.toString(address(operatorExecutor)));
        vm.setEnv("TRANSFER_ADAPTER", vm.toString(address(adapter)));

        vm.setEnv("TRANSFER_VAULT_FACTORY", vm.toString(address(vaultFactory)));
        vm.setEnv("TRANSFER_GATEWAY_FACTORY", vm.toString(address(gatewayFactory)));
        vm.setEnv("TRANSFER_ACCOUNTANT_FACTORY", vm.toString(address(accountantFactory)));
        vm.setEnv("TRANSFER_CONTROLLER_FACTORY", vm.toString(address(controllerFactory)));
        vm.setEnv("TRANSFER_SANCTIONS_ORACLE_FACTORY", vm.toString(address(oracleFactory)));
        vm.setEnv("TRANSFER_SUBRED_ADAPTER_FACTORY", vm.toString(address(adapterFactory)));
    }

    function _assertDefaultAdminTransfersScheduled() internal view {
        (address vaultPendingAdmin, uint48 vaultSchedule) = vault.pendingDefaultAdmin();
        (address gatewayPendingAdmin, uint48 gatewaySchedule) = gateway.pendingDefaultAdmin();
        assertEq(vaultPendingAdmin, newAdmin);
        assertEq(gatewayPendingAdmin, newAdmin);
        assertGt(vaultSchedule, block.timestamp);
        assertGt(gatewaySchedule, block.timestamp);
    }

    function _warpPastDefaultAdminTransferSchedule() internal {
        (, uint48 vaultSchedule) = vault.pendingDefaultAdmin();
        (, uint48 gatewaySchedule) = gateway.pendingDefaultAdmin();
        uint48 readyAt = vaultSchedule > gatewaySchedule ? vaultSchedule : gatewaySchedule;
        vm.warp(uint256(readyAt) + 1);
    }

    function _assertDefaultAdminRulesAdmins(bool oldExpected, bool newExpected) internal view {
        assertEq(vault.hasRole(bytes32(0), oldAdmin), oldExpected);
        assertEq(gateway.hasRole(bytes32(0), oldAdmin), oldExpected);
        assertEq(vault.hasRole(bytes32(0), newAdmin), newExpected);
        assertEq(gateway.hasRole(bytes32(0), newAdmin), newExpected);
    }

    function _assertPlainProxyAdmins(bool oldExpected, bool newExpected) internal view {
        assertEq(accountant.hasRole(bytes32(0), oldAdmin), oldExpected);
        assertEq(controller.hasRole(bytes32(0), oldAdmin), oldExpected);
        assertEq(oracle.hasRole(bytes32(0), oldAdmin), oldExpected);
        assertEq(accountantExecutor.hasRole(bytes32(0), oldAdmin), oldExpected);
        assertEq(operatorExecutor.hasRole(bytes32(0), oldAdmin), oldExpected);
        assertEq(adapter.hasRole(bytes32(0), oldAdmin), oldExpected);

        assertEq(accountant.hasRole(bytes32(0), newAdmin), newExpected);
        assertEq(controller.hasRole(bytes32(0), newAdmin), newExpected);
        assertEq(oracle.hasRole(bytes32(0), newAdmin), newExpected);
        assertEq(accountantExecutor.hasRole(bytes32(0), newAdmin), newExpected);
        assertEq(operatorExecutor.hasRole(bytes32(0), newAdmin), newExpected);
        assertEq(adapter.hasRole(bytes32(0), newAdmin), newExpected);
    }

    function _assertBeaconOwners(address expectedOwner) internal view {
        assertEq(vaultFactory.BEACON().owner(), expectedOwner);
        assertEq(gatewayFactory.BEACON().owner(), expectedOwner);
        assertEq(accountantFactory.BEACON().owner(), expectedOwner);
        assertEq(controllerFactory.BEACON().owner(), expectedOwner);
        assertEq(oracleFactory.BEACON().owner(), expectedOwner);
        assertEq(adapterFactory.BEACON().owner(), expectedOwner);
    }
}
