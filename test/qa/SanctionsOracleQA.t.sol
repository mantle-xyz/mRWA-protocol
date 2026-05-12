// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SanctionsOracle} from "../../src/compliance/SanctionsOracle.sol";
import {SanctionsOracleFactory} from "../../src/compliance/SanctionsOracleFactory.sol";
import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Test, console2} from "forge-std/Test.sol";

/**
 * @title  SanctionsOracleQA
 * @notice QA scenario tests for SanctionsOracle (SanctionsOracle 场景).
 */
contract SanctionsOracleQA is Test {
    SanctionsOracle internal oracle;

    address internal admin = makeAddr("admin");
    address internal complianceBot = makeAddr("complianceBot");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal charlie = makeAddr("charlie");

    bytes32 internal COMPLIANCE_ROLE;

    function setUp() public {
        SanctionsOracle impl = new SanctionsOracle();
        SanctionsOracleFactory factory = new SanctionsOracleFactory(address(impl), admin);
        vm.prank(admin);
        address oracleAddr = factory.deployAndInitOracle(admin, complianceBot);
        oracle = SanctionsOracle(oracleAddr);

        COMPLIANCE_ROLE = oracle.COMPLIANCE_ROLE();
    }

    string constant MODULE = unicode"SanctionsOracle 场景";
    string private _caseId;
    string private _caseName;
    string private _buf;

    function _logCase(string memory id, string memory name) internal {
        _caseId = id;
        _caseName = name;
        _buf = "";
        _step(string.concat("testcase module: ", MODULE));
        _step(string.concat("testcase id: ", id));
        _step(string.concat("testcase name: ", name));
        _step("----------------------------------------");
    }

    function _step(string memory msg) internal {
        console2.log(msg);
        _buf = string.concat(_buf, msg, "\n");
    }

    function _logPass() internal {
        _step("----------------------------------------");
        _step("test result: passed");
    }

    // ═══════════════════════════════════════════════════════════════
    //  P0 — Core sanction single-update scenarios
    // ═══════════════════════════════════════════════════════════════

    /// @notice P0: Add a single address to the sanction list.
    ///         isSanctioned returns true and totalSanctionedCount increases.
    function test_UpdateSanctionStatus_AddSingle() public {
        _logCase("test_UpdateSanctionStatus_AddSingle", unicode"单地址加入制裁名单成功");

        _step("[Step 1] Verify alice is not sanctioned before update");
        _step(string.concat("  alice address: ", vm.toString(alice)));
        assertFalse(oracle.isSanctioned(alice));
        _step("  PASS: isSanctioned(alice) == false");
        assertEq(oracle.totalSanctionedCount(), 0);
        _step(string.concat("  totalSanctionedCount: ", vm.toString(oracle.totalSanctionedCount())));
        _step("  PASS: totalSanctionedCount == 0");

        _step("[Step 2] Call updateSanctionStatus(alice, true) as complianceBot");
        vm.prank(complianceBot);
        oracle.updateSanctionStatus(alice, true);
        _step("  updateSanctionStatus executed successfully");

        _step("[Step 3] Verify alice is now sanctioned and count incremented");
        assertTrue(oracle.isSanctioned(alice));
        _step("  PASS: isSanctioned(alice) == true");
        assertEq(oracle.totalSanctionedCount(), 1);
        _step(string.concat("  totalSanctionedCount: ", vm.toString(oracle.totalSanctionedCount())));
        _step("  PASS: totalSanctionedCount == 1");
        _logPass();
    }

    /// @notice P0: Remove a single address from the sanction list.
    ///         isSanctioned returns false and totalSanctionedCount decreases.
    function test_UpdateSanctionStatus_RemoveSingle() public {
        _logCase("test_UpdateSanctionStatus_RemoveSingle", unicode"单地址移出制裁名单成功");

        _step("[Step 1] Setup: sanction alice first");
        _step(string.concat("  alice address: ", vm.toString(alice)));
        vm.prank(complianceBot);
        oracle.updateSanctionStatus(alice, true);
        assertTrue(oracle.isSanctioned(alice));
        _step("  PASS: isSanctioned(alice) == true after setup");
        assertEq(oracle.totalSanctionedCount(), 1);
        _step(string.concat("  totalSanctionedCount: ", vm.toString(oracle.totalSanctionedCount())));
        _step("  PASS: totalSanctionedCount == 1");

        _step("[Step 2] Call updateSanctionStatus(alice, false) to remove sanction");
        vm.prank(complianceBot);
        oracle.updateSanctionStatus(alice, false);
        _step("  updateSanctionStatus executed successfully");

        _step("[Step 3] Verify alice is no longer sanctioned and count decremented");
        assertFalse(oracle.isSanctioned(alice));
        _step("  PASS: isSanctioned(alice) == false");
        assertEq(oracle.totalSanctionedCount(), 0);
        _step(string.concat("  totalSanctionedCount: ", vm.toString(oracle.totalSanctionedCount())));
        _step("  PASS: totalSanctionedCount == 0");
        _logPass();
    }

    /// @notice P0: A caller without COMPLIANCE_ROLE cannot update sanction status.
    function test_UpdateSanctionStatus_RevertNotCompliance() public {
        _logCase("test_UpdateSanctionStatus_RevertNotCompliance", unicode"非 compliance 角色无法更新制裁状态");

        _step("[Step 1] Prepare call from alice who lacks COMPLIANCE_ROLE");
        _step(string.concat("  caller: ", vm.toString(alice)));
        _step(string.concat("  target: ", vm.toString(bob)));
        _step(string.concat("  COMPLIANCE_ROLE: ", vm.toString(COMPLIANCE_ROLE)));

        _step("[Step 2] Expect revert with AccessControlUnauthorizedAccount");
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                alice,
                COMPLIANCE_ROLE
            )
        );
        oracle.updateSanctionStatus(bob, true);
        _step("  PASS: reverted as expected");
        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  P1 — Batch update scenarios
    // ═══════════════════════════════════════════════════════════════

    /// @notice P1: Batch-add multiple addresses. Events are emitted correctly.
    function test_UpdateSanctionStatusBatch_Success() public {
        _logCase("test_UpdateSanctionStatusBatch_Success", unicode"批量更新制裁状态成功");

        _step("[Step 1] Build batch array of 3 addresses");
        address[] memory accounts = new address[](3);
        accounts[0] = alice;
        accounts[1] = bob;
        accounts[2] = charlie;
        _step(string.concat("  accounts[0] (alice):   ", vm.toString(alice)));
        _step(string.concat("  accounts[1] (bob):     ", vm.toString(bob)));
        _step(string.concat("  accounts[2] (charlie): ", vm.toString(charlie)));

        _step("[Step 2] Set up expected events (individual + batch summary)");
        // Expect individual SanctionStatusUpdated events for each address
        vm.expectEmit(true, false, false, true, address(oracle));
        emit ISanctionsOracle.SanctionStatusUpdated(alice, true);

        vm.expectEmit(true, false, false, true, address(oracle));
        emit ISanctionsOracle.SanctionStatusUpdated(bob, true);

        vm.expectEmit(true, false, false, true, address(oracle));
        emit ISanctionsOracle.SanctionStatusUpdated(charlie, true);

        // Expect the batch summary event (batchNonce starts at 0 after setUp used 0 for deployAndInitOracle)
        vm.expectEmit(true, false, false, true, address(oracle));
        emit ISanctionsOracle.BatchSanctionUpdated(oracle.batchNonce(), 3, 3, true);
        _step(string.concat("  batchNonce before call: ", vm.toString(oracle.batchNonce())));

        _step("[Step 3] Call updateSanctionStatusBatch(accounts, true) as complianceBot");
        vm.prank(complianceBot);
        oracle.updateSanctionStatusBatch(accounts, true);
        _step("  batch call executed successfully");

        _step("[Step 4] Verify all addresses are sanctioned and count is correct");
        assertTrue(oracle.isSanctioned(alice));
        _step("  PASS: isSanctioned(alice) == true");
        assertTrue(oracle.isSanctioned(bob));
        _step("  PASS: isSanctioned(bob) == true");
        assertTrue(oracle.isSanctioned(charlie));
        _step("  PASS: isSanctioned(charlie) == true");
        assertEq(oracle.totalSanctionedCount(), 3);
        _step(string.concat("  totalSanctionedCount: ", vm.toString(oracle.totalSanctionedCount())));
        _step("  PASS: totalSanctionedCount == 3");
        _logPass();
    }

    /// @notice P1: Empty array reverts with Oracle__EmptyArray.
    function test_UpdateSanctionStatusBatch_RevertEmptyArray() public {
        _logCase("test_UpdateSanctionStatusBatch_RevertEmptyArray", unicode"空数组批量更新被拒绝");

        _step("[Step 1] Build empty batch array");
        address[] memory accounts = new address[](0);
        _step(string.concat("  array length: ", vm.toString(accounts.length)));

        _step("[Step 2] Call updateSanctionStatusBatch with empty array as complianceBot");
        _step("  Expecting revert with Oracle__EmptyArray");
        vm.prank(complianceBot);
        vm.expectRevert(ISanctionsOracle.Oracle__EmptyArray.selector);
        oracle.updateSanctionStatusBatch(accounts, true);
        _step("  PASS: reverted as expected");
        _logPass();
    }

    /// @notice P1: Array exceeding MAX_BATCH_SIZE reverts with Oracle__BatchTooLarge.
    function test_UpdateSanctionStatusBatch_RevertTooLarge() public {
        _logCase("test_UpdateSanctionStatusBatch_RevertTooLarge", unicode"超过最大批量数被拒绝");

        _step("[Step 1] Query MAX_BATCH_SIZE and build oversized array");
        uint256 maxBatch = oracle.MAX_BATCH_SIZE();
        uint256 tooLarge = maxBatch + 1;
        _step(string.concat("  MAX_BATCH_SIZE: ", vm.toString(maxBatch)));
        _step(string.concat("  array length:   ", vm.toString(tooLarge)));
        address[] memory accounts = new address[](tooLarge);
        for (uint256 i; i < tooLarge; i++) {
            accounts[i] = address(uint160(i + 1)); // non-zero addresses
        }

        _step("[Step 2] Call updateSanctionStatusBatch with oversized array");
        _step("  Expecting revert with Oracle__BatchTooLarge");
        vm.prank(complianceBot);
        vm.expectRevert(
            abi.encodeWithSelector(ISanctionsOracle.Oracle__BatchTooLarge.selector, tooLarge, maxBatch)
        );
        oracle.updateSanctionStatusBatch(accounts, true);
        _step("  PASS: reverted as expected");
        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  P1 — Idempotency & count tracking
    // ═══════════════════════════════════════════════════════════════

    /// @notice P1: Re-setting the same sanction status is idempotent;
    ///         count does not double-increase.
    function test_UpdateSanctionStatus_Idempotent() public {
        _logCase("test_UpdateSanctionStatus_Idempotent", unicode"重复设置相同状态时保持幂等");

        _step("[Step 1] Sanction alice for the first time");
        _step(string.concat("  alice address: ", vm.toString(alice)));
        vm.prank(complianceBot);
        oracle.updateSanctionStatus(alice, true);
        assertEq(oracle.totalSanctionedCount(), 1);
        _step(string.concat("  totalSanctionedCount: ", vm.toString(oracle.totalSanctionedCount())));
        _step("  PASS: totalSanctionedCount == 1 after first sanction");

        _step("[Step 2] Sanction alice again (already sanctioned)");
        vm.prank(complianceBot);
        oracle.updateSanctionStatus(alice, true);
        _step("  second updateSanctionStatus(alice, true) executed");

        _step("[Step 3] Verify count did not double-increase (idempotency)");
        assertTrue(oracle.isSanctioned(alice));
        _step("  PASS: isSanctioned(alice) == true");
        assertEq(oracle.totalSanctionedCount(), 1);
        _step(string.concat("  totalSanctionedCount: ", vm.toString(oracle.totalSanctionedCount())));
        _step("  PASS: totalSanctionedCount == 1 (unchanged, idempotent)");
        _logPass();
    }

    /// @notice P1: totalSanctionedCount accurately tracks adds and removes.
    function test_TotalSanctionedCount_Tracking() public {
        _logCase("test_TotalSanctionedCount_Tracking", unicode"totalSanctionedCount 正确反映增减");

        _step("[Step 1] Add alice and bob to sanction list");
        vm.startPrank(complianceBot);
        oracle.updateSanctionStatus(alice, true);
        oracle.updateSanctionStatus(bob, true);
        assertEq(oracle.totalSanctionedCount(), 2);
        _step(string.concat("  totalSanctionedCount: ", vm.toString(oracle.totalSanctionedCount())));
        _step("  PASS: totalSanctionedCount == 2 after adding alice + bob");

        _step("[Step 2] Add charlie to sanction list");
        oracle.updateSanctionStatus(charlie, true);
        assertEq(oracle.totalSanctionedCount(), 3);
        _step(string.concat("  totalSanctionedCount: ", vm.toString(oracle.totalSanctionedCount())));
        _step("  PASS: totalSanctionedCount == 3 after adding charlie");

        _step("[Step 3] Remove alice from sanction list");
        oracle.updateSanctionStatus(alice, false);
        assertEq(oracle.totalSanctionedCount(), 2);
        _step(string.concat("  totalSanctionedCount: ", vm.toString(oracle.totalSanctionedCount())));
        _step("  PASS: totalSanctionedCount == 2 after removing alice");

        _step("[Step 4] Remove bob from sanction list");
        oracle.updateSanctionStatus(bob, false);
        assertEq(oracle.totalSanctionedCount(), 1);
        _step(string.concat("  totalSanctionedCount: ", vm.toString(oracle.totalSanctionedCount())));
        _step("  PASS: totalSanctionedCount == 1 after removing bob");

        _step("[Step 5] Remove charlie from sanction list");
        oracle.updateSanctionStatus(charlie, false);
        assertEq(oracle.totalSanctionedCount(), 0);
        _step(string.concat("  totalSanctionedCount: ", vm.toString(oracle.totalSanctionedCount())));
        _step("  PASS: totalSanctionedCount == 0 after removing charlie");
        vm.stopPrank();
        _logPass();
    }

    /// @notice P1: batchNonce increments on each batch operation.
    function test_BatchNonce_Increments() public {
        _logCase("test_BatchNonce_Increments", unicode"batchNonce 每次批量操作后递增");

        _step("[Step 1] Record initial batchNonce and build first batch array");
        uint256 nonceBefore = oracle.batchNonce();
        _step(string.concat("  batchNonce before: ", vm.toString(nonceBefore)));
        address[] memory firstBatch = new address[](2);
        firstBatch[0] = alice;
        firstBatch[1] = bob;
        _step(string.concat("  first batch size: ", vm.toString(firstBatch.length)));

        _step("[Step 2] First batch call: updateSanctionStatusBatch([alice, bob], true)");
        vm.prank(complianceBot);
        oracle.updateSanctionStatusBatch(firstBatch, true);
        assertEq(oracle.batchNonce(), nonceBefore + 1);
        _step(string.concat("  batchNonce after: ", vm.toString(oracle.batchNonce())));
        _step("  PASS: batchNonce == nonceBefore + 1");

        _step("[Step 3] Build second batch array [charlie] and call updateSanctionStatusBatch([charlie], false)");
        address[] memory secondBatch = new address[](1);
        secondBatch[0] = charlie;
        vm.prank(complianceBot);
        oracle.updateSanctionStatusBatch(secondBatch, false);
        assertEq(oracle.batchNonce(), nonceBefore + 2);
        _step(string.concat("  batchNonce after: ", vm.toString(oracle.batchNonce())));
        _step("  PASS: batchNonce == nonceBefore + 2");
        _logPass();
    }

    /// @notice P1: Batch containing address(0) reverts with Oracle__ZeroAddress.
    function test_UpdateSanctionStatusBatch_RevertZeroAddress() public {
        _logCase("test_UpdateSanctionStatusBatch_RevertZeroAddress", unicode"批量操作含零地址时被拒绝");

        _step("[Step 1] Build batch array with address(0) in the middle");
        address[] memory accounts = new address[](3);
        accounts[0] = alice;
        accounts[1] = address(0);
        accounts[2] = bob;
        _step(string.concat("  accounts[0] (alice):   ", vm.toString(alice)));
        _step(string.concat("  accounts[1] (zero):    ", vm.toString(address(0))));
        _step(string.concat("  accounts[2] (bob):     ", vm.toString(bob)));

        _step("[Step 2] Call updateSanctionStatusBatch expecting Oracle__ZeroAddress revert");
        vm.prank(complianceBot);
        vm.expectRevert(ISanctionsOracle.Oracle__ZeroAddress.selector);
        oracle.updateSanctionStatusBatch(accounts, true);
        _step("  PASS: reverted as expected");
        _logPass();
    }
}
