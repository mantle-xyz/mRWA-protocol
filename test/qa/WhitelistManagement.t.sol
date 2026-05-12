// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SanctionsOracle} from "../../src/compliance/SanctionsOracle.sol";
import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test, console2} from "forge-std/Test.sol";

// ---------------------------------------------------------------------------
// QA Test: Whitelist Management
// ---------------------------------------------------------------------------

contract WhitelistManagementQATest is Test {
    SanctionsOracle internal oracle;

    address internal admin = makeAddr("admin");
    address internal compliance = makeAddr("compliance");
    address internal nonCompliance = makeAddr("nonCompliance");
    address internal user1 = makeAddr("user1");
    address internal user2 = makeAddr("user2");
    address internal user3 = makeAddr("user3");

    string constant MODULE = unicode"白名单管理场景";
    string private _buf;

    function _logCase(string memory id, string memory name_) internal {
        _buf = "";
        _step(string.concat("testcase module: ", MODULE));
        _step(string.concat("testcase id: ", id));
        _step(string.concat("testcase name: ", name_));
        _step("----------------------------------------");
    }

    function _step(string memory msg_) internal {
        console2.log(msg_);
        _buf = string.concat(_buf, msg_, "\n");
    }

    function _logPass() internal {
        _step("----------------------------------------");
        _step("test result: passed");
    }

    function setUp() public {
        SanctionsOracle impl = new SanctionsOracle();
        oracle = SanctionsOracle(address(new ERC1967Proxy(
            address(impl),
            abi.encodeCall(SanctionsOracle.initialize, (admin, compliance))
        )));
    }

    // =======================================================================
    // 1. updateWhitelistStatus: 添加/移除白名单
    // =======================================================================

    function test_UpdateWhitelistStatus_AddAndRemove() public {
        _logCase("test_UpdateWhitelistStatus_AddAndRemove", unicode"compliance 角色添加/移除白名单，计数正确");

        assertFalse(oracle.isWhitelisted(user1), "initially not whitelisted");
        assertEq(oracle.totalWhitelistedCount(), 0, "initial count 0");

        _step("[Step 1] Add user1 to whitelist");
        vm.prank(compliance);
        oracle.updateWhitelistStatus(user1, true);
        assertTrue(oracle.isWhitelisted(user1), "user1 whitelisted");
        assertEq(oracle.totalWhitelistedCount(), 1, "count = 1");

        _step("[Step 2] Add user2 to whitelist");
        vm.prank(compliance);
        oracle.updateWhitelistStatus(user2, true);
        assertTrue(oracle.isWhitelisted(user2), "user2 whitelisted");
        assertEq(oracle.totalWhitelistedCount(), 2, "count = 2");

        _step("[Step 3] Remove user1 from whitelist");
        vm.prank(compliance);
        oracle.updateWhitelistStatus(user1, false);
        assertFalse(oracle.isWhitelisted(user1), "user1 removed");
        assertEq(oracle.totalWhitelistedCount(), 1, "count = 1");

        _step("[Step 4] Duplicate add (user2 already whitelisted) - no change");
        vm.prank(compliance);
        oracle.updateWhitelistStatus(user2, true);
        assertEq(oracle.totalWhitelistedCount(), 1, "count unchanged");

        _logPass();
    }

    function test_UpdateWhitelistStatus_RejectsZeroAddress() public {
        _logCase("test_UpdateWhitelistStatus_RejectsZeroAddress", unicode"`updateWhitelistStatus` 拒绝零地址");

        vm.prank(compliance);
        vm.expectRevert(ISanctionsOracle.Oracle__ZeroAddress.selector);
        oracle.updateWhitelistStatus(address(0), true);

        _logPass();
    }

    function test_UpdateWhitelistStatus_OnlyCompliance() public {
        _logCase("test_UpdateWhitelistStatus_OnlyCompliance", unicode"非 compliance 角色不能修改白名单");

        bytes32 complianceRole = keccak256("COMPLIANCE_ROLE");
        vm.prank(nonCompliance);
        vm.expectRevert(abi.encodeWithSelector(
            bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
            nonCompliance,
            complianceRole
        ));
        oracle.updateWhitelistStatus(user1, true);

        _logPass();
    }

    // =======================================================================
    // 2. updateWhitelistStatusBatch: 批量白名单管理
    // =======================================================================

    function test_UpdateWhitelistStatusBatch_Success() public {
        _logCase("test_UpdateWhitelistStatusBatch_Success", unicode"批量添加白名单，计数正确");

        address[] memory users = new address[](3);
        users[0] = user1;
        users[1] = user2;
        users[2] = user3;

        vm.prank(compliance);
        oracle.updateWhitelistStatusBatch(users, true);

        assertTrue(oracle.isWhitelisted(user1), "user1 whitelisted");
        assertTrue(oracle.isWhitelisted(user2), "user2 whitelisted");
        assertTrue(oracle.isWhitelisted(user3), "user3 whitelisted");
        assertEq(oracle.totalWhitelistedCount(), 3, "count = 3");

        _step("[Step 2] Batch remove");
        address[] memory removeUsers = new address[](2);
        removeUsers[0] = user1;
        removeUsers[1] = user2;

        vm.prank(compliance);
        oracle.updateWhitelistStatusBatch(removeUsers, false);

        assertFalse(oracle.isWhitelisted(user1), "user1 removed");
        assertFalse(oracle.isWhitelisted(user2), "user2 removed");
        assertTrue(oracle.isWhitelisted(user3), "user3 still whitelisted");
        assertEq(oracle.totalWhitelistedCount(), 1, "count = 1");

        _logPass();
    }

    function test_UpdateWhitelistStatusBatch_RejectsEmptyArray() public {
        _logCase("test_UpdateWhitelistStatusBatch_RejectsEmptyArray", unicode"批量白名单拒绝空数组");

        address[] memory empty = new address[](0);
        vm.prank(compliance);
        vm.expectRevert(ISanctionsOracle.Oracle__EmptyArray.selector);
        oracle.updateWhitelistStatusBatch(empty, true);

        _logPass();
    }

    function test_UpdateWhitelistStatusBatch_RejectsOverMaxBatch() public {
        _logCase("test_UpdateWhitelistStatusBatch_RejectsOverMaxBatch", unicode"批量白名单拒绝超过 MAX_BATCH_SIZE");

        address[] memory tooMany = new address[](201);
        for (uint256 i = 0; i < 201; i++) {
            tooMany[i] = address(uint160(i + 1));
        }

        vm.prank(compliance);
        vm.expectRevert(abi.encodeWithSelector(ISanctionsOracle.Oracle__BatchTooLarge.selector, 201, 200));
        oracle.updateWhitelistStatusBatch(tooMany, true);

        _logPass();
    }

    // =======================================================================
    // 3. totalWhitelistedCount: 计数追踪
    // =======================================================================

    function test_TotalWhitelistedCount_Tracking() public {
        _logCase("test_TotalWhitelistedCount_Tracking", unicode"`totalWhitelistedCount` 在增删后精确追踪");

        assertEq(oracle.totalWhitelistedCount(), 0, "start at 0");

        vm.startPrank(compliance);
        oracle.updateWhitelistStatus(user1, true);
        assertEq(oracle.totalWhitelistedCount(), 1);

        oracle.updateWhitelistStatus(user2, true);
        assertEq(oracle.totalWhitelistedCount(), 2);

        oracle.updateWhitelistStatus(user1, false);
        assertEq(oracle.totalWhitelistedCount(), 1);

        oracle.updateWhitelistStatus(user1, false); // already removed, no change
        assertEq(oracle.totalWhitelistedCount(), 1, "no double decrement");

        oracle.updateWhitelistStatus(user2, false);
        assertEq(oracle.totalWhitelistedCount(), 0, "back to 0");
        vm.stopPrank();

        _logPass();
    }
}
