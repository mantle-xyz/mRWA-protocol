// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {AccountantExecutor} from "../src/accountant/AccountantExecutor.sol";
import {Accountant} from "../src/accountant/Accountant.sol";

// =============================================================
//                       MOCK ACCOUNTANT
// =============================================================

contract MockAccountant {
    uint256 public lastNewRate;
    uint256 public lastAumSnapshot;
    uint256 public lastComputeTimestamp;
    uint256 public callCount;

    function updateExchangeRate(uint256 newRate, uint256 aumSnapshot, uint256 computeTimestamp) external {
        lastNewRate = newRate;
        lastAumSnapshot = aumSnapshot;
        lastComputeTimestamp = computeTimestamp;
        callCount++;
    }
}

// =============================================================
//                       MOCK VAULT
// =============================================================

contract MockVault {
    uint256 public exchangeRate;

    function mintFeeShares(address, uint256) external {}

    function updateExchangeRate(uint256 newRate) external {
        exchangeRate = newRate;
    }

    function asset() external pure returns (address) {
        return address(0xA);
    }
}

// =============================================================
//                  UNIT TESTS (Mock Accountant)
// =============================================================

contract AccountantExecutorTest is Test {
    AccountantExecutor public executor;
    MockAccountant public mockAccountant;
    UpgradeableBeacon public beacon;

    address public admin = makeAddr("admin");
    address public bot = makeAddr("bot");
    address public user = makeAddr("user");

    function setUp() public {
        mockAccountant = new MockAccountant();

        AccountantExecutor impl = new AccountantExecutor();
        beacon = new UpgradeableBeacon(address(impl), admin);
        BeaconProxy proxy = new BeaconProxy(
            address(beacon), abi.encodeCall(AccountantExecutor.initialize, (address(mockAccountant), admin))
        );
        executor = AccountantExecutor(address(proxy));

        bytes32 executeRole = executor.BOT_ROLE();
        vm.prank(admin);
        executor.grantRole(executeRole, bot);
    }

    // =============================================================
    //                  INITIALIZER TESTS
    // =============================================================

    function test_initialize_setsStateCorrectly() public view {
        assertEq(address(executor.accountant()), address(mockAccountant));
        assertTrue(executor.hasRole(executor.DEFAULT_ADMIN_ROLE(), admin));
        assertEq(executor.getRoleAdmin(executor.BOT_ROLE()), executor.DEFAULT_ADMIN_ROLE());
        assertEq(executor.getRoleAdmin(executor.DEFAULT_ADMIN_ROLE()), executor.DEFAULT_ADMIN_ROLE());
    }

    function test_initialize_revertsOnDoubleInit() public {
        vm.expectRevert();
        executor.initialize(address(mockAccountant), admin);
    }

    function test_initialize_revertsWhenAccountantIsZero() public {
        vm.expectRevert(AccountantExecutor.ZeroAddress.selector);
        new BeaconProxy(address(beacon), abi.encodeCall(AccountantExecutor.initialize, (address(0), admin)));
    }

    function test_initialize_revertsWhenAdminIsZero() public {
        vm.expectRevert(AccountantExecutor.ZeroAddress.selector);
        new BeaconProxy(
            address(beacon), abi.encodeCall(AccountantExecutor.initialize, (address(mockAccountant), address(0)))
        );
    }

    // =============================================================
    //                    UPGRADE TESTS
    // =============================================================

    function test_upgrade_succeeds() public {
        AccountantExecutor newImpl = new AccountantExecutor();

        vm.prank(admin);
        beacon.upgradeTo(address(newImpl));

        assertEq(beacon.implementation(), address(newImpl));
        assertEq(address(executor.accountant()), address(mockAccountant));
        assertTrue(executor.hasRole(executor.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_upgrade_revertsWhenNotBeaconOwner() public {
        AccountantExecutor newImpl = new AccountantExecutor();

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user));
        vm.prank(user);
        beacon.upgradeTo(address(newImpl));
    }

    // =============================================================
    //              EXECUTE UPDATE RATE TESTS
    // =============================================================

    function test_executeUpdateRate_succeeds() public {
        uint256 newRate = 1.005e18;
        uint256 aum = 100_000_000e6;
        uint256 computeTs = block.timestamp;

        vm.prank(bot);
        executor.executeUpdateRate(newRate, aum, computeTs);

        assertEq(mockAccountant.lastNewRate(), newRate);
        assertEq(mockAccountant.lastAumSnapshot(), aum);
        assertEq(mockAccountant.lastComputeTimestamp(), computeTs);
        assertEq(mockAccountant.callCount(), 1);
    }

    function test_executeUpdateRate_emitsEvent() public {
        uint256 newRate = 1.005e18;
        uint256 aum = 100_000_000e6;
        uint256 computeTs = block.timestamp;

        vm.expectEmit(true, false, false, true);
        emit AccountantExecutor.RateUpdateExecuted(bot, newRate, aum, computeTs);

        vm.prank(bot);
        executor.executeUpdateRate(newRate, aum, computeTs);
    }

    function test_executeUpdateRate_consecutiveCalls() public {
        vm.prank(bot);
        executor.executeUpdateRate(1.001e18, 100e6, block.timestamp);

        vm.prank(bot);
        executor.executeUpdateRate(1.002e18, 200e6, block.timestamp + 1);

        assertEq(mockAccountant.lastNewRate(), 1.002e18);
        assertEq(mockAccountant.lastAumSnapshot(), 200e6);
        assertEq(mockAccountant.callCount(), 2);
    }

    // =============================================================
    //                  REVERT TESTS
    // =============================================================

    function test_executeUpdateRate_revertsWhenNotExecuteRole() public {
        bytes32 role = executor.BOT_ROLE();

        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, role));
        vm.prank(user);
        executor.executeUpdateRate(1e18, 100e6, block.timestamp);
    }

    function test_executeUpdateRate_revertsWhenAdminWithoutExecuteRole() public {
        bytes32 role = executor.BOT_ROLE();

        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, role));
        vm.prank(admin);
        executor.executeUpdateRate(1e18, 100e6, block.timestamp);
    }

    // =============================================================
    //                  ADMIN / ROLE TESTS
    // =============================================================

    function test_grantExecuteRole_onlyAdmin() public {
        address newExecutor = makeAddr("newExecutor");

        bytes32 adminRole = executor.DEFAULT_ADMIN_ROLE();
        bytes32 executeRole = executor.BOT_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, adminRole)
        );
        vm.prank(user);
        executor.grantRole(executeRole, newExecutor);

        vm.prank(admin);
        executor.grantRole(executeRole, newExecutor);
        assertTrue(executor.hasRole(executeRole, newExecutor));
    }

    function test_revokeExecuteRole_preventsExecution() public {
        bytes32 executeRole = executor.BOT_ROLE();

        vm.prank(admin);
        executor.revokeRole(executeRole, bot);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bot, executeRole)
        );
        vm.prank(bot);
        executor.executeUpdateRate(1e18, 100e6, block.timestamp);
    }

    function test_adminCanManageOtherAdmins() public {
        address newAdmin = makeAddr("newAdmin");
        bytes32 adminRole = executor.DEFAULT_ADMIN_ROLE();

        vm.prank(admin);
        executor.grantRole(adminRole, newAdmin);
        assertTrue(executor.hasRole(adminRole, newAdmin));

        address newExecutor = makeAddr("newExecutor");
        bytes32 executeRole = executor.BOT_ROLE();
        vm.prank(newAdmin);
        executor.grantRole(executeRole, newExecutor);
        assertTrue(executor.hasRole(executeRole, newExecutor));
    }

    function test_defaultAdminRoleCannotManageRoles() public {
        address nobody = makeAddr("nobody");
        bytes32 executeRole = executor.BOT_ROLE();
        bytes32 adminRole = executor.DEFAULT_ADMIN_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nobody, adminRole)
        );
        vm.prank(nobody);
        executor.grantRole(executeRole, nobody);
    }

    // =============================================================
    //                      FUZZ TESTS
    // =============================================================

    function testFuzz_executeUpdateRate(uint256 newRate, uint256 aum, uint256 computeTs) public {
        newRate = bound(newRate, 1, type(uint128).max);
        aum = bound(aum, 1, type(uint128).max);
        computeTs = bound(computeTs, 1, type(uint128).max);

        vm.prank(bot);
        executor.executeUpdateRate(newRate, aum, computeTs);

        assertEq(mockAccountant.lastNewRate(), newRate);
        assertEq(mockAccountant.lastAumSnapshot(), aum);
        assertEq(mockAccountant.lastComputeTimestamp(), computeTs);
    }
}

// =============================================================
//              INTEGRATION TEST (Real Accountant)
// =============================================================

contract AccountantExecutorIntegrationTest is Test {
    AccountantExecutor public executor;
    Accountant public accountant;
    MockVault public vault;
    UpgradeableBeacon public accBeacon;
    UpgradeableBeacon public execBeacon;

    address public admin = makeAddr("admin");
    address public bot = makeAddr("bot");

    uint256 public constant INITIAL_RATE = 1e18;

    function setUp() public {
        vault = new MockVault();

        // Deploy Accountant behind beacon proxy
        Accountant accImpl = new Accountant();
        accBeacon = new UpgradeableBeacon(address(accImpl), admin);
        BeaconProxy accProxy = new BeaconProxy(
            address(accBeacon),
            abi.encodeCall(Accountant.initialize, (address(vault), makeAddr("treasury"), INITIAL_RATE, 50, admin))
        );
        accountant = Accountant(address(accProxy));

        // Deploy AccountantExecutor behind beacon proxy
        AccountantExecutor execImpl = new AccountantExecutor();
        execBeacon = new UpgradeableBeacon(address(execImpl), admin);
        BeaconProxy execProxy = new BeaconProxy(
            address(execBeacon), abi.encodeCall(AccountantExecutor.initialize, (address(accountant), admin))
        );
        executor = AccountantExecutor(address(execProxy));

        // Wire roles
        vm.startPrank(admin);
        accountant.grantRole(accountant.EXECUTOR_ROLE(), address(executor));
        executor.grantRole(executor.BOT_ROLE(), bot);
        vm.stopPrank();
    }

    function test_integration_fullFlow() public {
        vm.warp(block.timestamp + 20 hours + 1);

        uint256 newRate = 1.005e18;
        uint256 aum = 100_000_000e6;
        uint256 computeTs = block.timestamp;

        vm.prank(bot);
        executor.executeUpdateRate(newRate, aum, computeTs);

        assertEq(accountant.lastExchangeRate(), newRate);
        assertEq(vault.exchangeRate(), newRate);
        assertEq(accountant.lastComputeTimestamp(), computeTs);
    }

    function test_integration_consecutiveUpdates() public {
        vm.warp(block.timestamp + 20 hours + 1);

        uint256 computeTs1 = block.timestamp;
        vm.prank(bot);
        executor.executeUpdateRate(1.005e18, 100_000_000e6, computeTs1);

        vm.warp(block.timestamp + 20 hours + 1);

        uint256 computeTs2 = block.timestamp;
        vm.prank(bot);
        executor.executeUpdateRate(1.009e18, 100_500_000e6, computeTs2);

        assertEq(accountant.lastExchangeRate(), 1.009e18);
        assertEq(accountant.lastComputeTimestamp(), computeTs2);
    }

    function test_integration_accountantRevertBubblesUp() public {
        vm.prank(bot);
        vm.expectRevert();
        executor.executeUpdateRate(1.005e18, 100_000_000e6, block.timestamp);
    }
}
