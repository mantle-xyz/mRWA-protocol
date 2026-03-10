// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SanctionsOracle} from "../../src/compliance/SanctionsOracle.sol";
import {ISanctionsOracle} from "../../src/interfaces/oracle/ISanctionsOracle.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Test} from "forge-std/Test.sol";

/**
 * @title  SanctionsOracleTest
 * @notice Comprehensive unit tests for SanctionsOracle.
 *
 *         Coverage areas
 *         ──────────────
 *         1. Deployment & Initialization
 *         2. Read Functions (isSanctioned)
 *         3. Single Update (updateSanctionStatus)
 *         4. Batch Update (updateSanctionStatusBatch)
 *         5. Access Control (role grants, revocations, multi-bot)
 *         6. Complex Scenarios (cycles, count consistency, nonce monotonicity)
 *         7. ERC-165 Interface Detection
 */
contract SanctionsOracleTest is Test {
    // ─────────────────────── state ───────────────────────
    SanctionsOracle internal oracle;

    address internal admin = makeAddr("admin");
    address internal complianceBot = makeAddr("complianceBot");
    address internal unauthorizedUser = makeAddr("unauthorizedUser");

    // Deterministic test addresses
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal eve = makeAddr("eve");

    bytes32 internal COMPLIANCE_ROLE;
    bytes32 internal DEFAULT_ADMIN_ROLE = 0x00;

    // ─────────────────────── setup ──────────────────────

    function setUp() public {
        oracle = new SanctionsOracle(admin, complianceBot);
        COMPLIANCE_ROLE = oracle.COMPLIANCE_ROLE();
    }

    // ═════════════════════════════════════════════════════
    //  1. DEPLOYMENT & INITIALIZATION
    // ═════════════════════════════════════════════════════

    function test_constructor_setsRoles() public view {
        assertTrue(oracle.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertTrue(oracle.hasRole(COMPLIANCE_ROLE, complianceBot));
        assertFalse(oracle.hasRole(COMPLIANCE_ROLE, admin));
        assertFalse(oracle.hasRole(DEFAULT_ADMIN_ROLE, complianceBot));
    }

    function test_constructor_setsInitialState() public view {
        assertEq(oracle.totalSanctionedCount(), 0);
        assertEq(oracle.batchNonce(), 0);
        assertEq(oracle.lastUpdateTimestamp(), block.timestamp);
    }

    function test_constructor_revertsOnZeroAdmin() public {
        vm.expectRevert(ISanctionsOracle.Oracle__ZeroAddress.selector);
        new SanctionsOracle(address(0), complianceBot);
    }

    function test_constructor_revertsOnZeroComplianceBot() public {
        vm.expectRevert(ISanctionsOracle.Oracle__ZeroAddress.selector);
        new SanctionsOracle(admin, address(0));
    }

    function test_constructor_revertsOnBothZero() public {
        vm.expectRevert(ISanctionsOracle.Oracle__ZeroAddress.selector);
        new SanctionsOracle(address(0), address(0));
    }

    function test_constants() public view {
        assertEq(oracle.MAX_BATCH_SIZE(), 200);
        assertEq(oracle.COMPLIANCE_ROLE(), keccak256("COMPLIANCE_ROLE"));
    }

    // ═════════════════════════════════════════════════════
    //  2. READ FUNCTIONS
    // ═════════════════════════════════════════════════════

    function test_isSanctioned_defaultFalse() public view {
        assertFalse(oracle.isSanctioned(alice));
        assertFalse(oracle.isSanctioned(bob));
    }

    function test_isSanctioned_reflectsUpdates() public {
        // Sanction alice
        vm.prank(complianceBot);
        oracle.updateSanctionStatus(alice, true);

        assertTrue(oracle.isSanctioned(alice));

        // Clean address stays false
        assertFalse(oracle.isSanctioned(bob));
    }

    // ═════════════════════════════════════════════════════
    //  3. SINGLE UPDATE — updateSanctionStatus
    // ═════════════════════════════════════════════════════

    function test_single_sanctionCleanAddress() public {
        vm.prank(complianceBot);
        oracle.updateSanctionStatus(alice, true);

        assertTrue(oracle.isSanctioned(alice));
        assertEq(oracle.totalSanctionedCount(), 1);
    }

    function test_single_unsanctionBannedAddress() public {
        // Setup: sanction first
        vm.prank(complianceBot);
        oracle.updateSanctionStatus(alice, true);
        assertEq(oracle.totalSanctionedCount(), 1);

        // Unsanction
        vm.prank(complianceBot);
        oracle.updateSanctionStatus(alice, false);

        assertFalse(oracle.isSanctioned(alice));
        assertEq(oracle.totalSanctionedCount(), 0);
    }

    function test_single_idempotent_alreadySanctioned() public {
        // Sanction alice
        vm.prank(complianceBot);
        oracle.updateSanctionStatus(alice, true);
        uint256 countBefore = oracle.totalSanctionedCount();
        uint256 tsBefore = oracle.lastUpdateTimestamp();

        // Advance time so we can detect timestamp changes
        vm.warp(block.timestamp + 1 hours);

        // Sanction again — no-op
        vm.prank(complianceBot);
        oracle.updateSanctionStatus(alice, true);

        assertEq(oracle.totalSanctionedCount(), countBefore, "Count should not change on no-op");
        assertEq(oracle.lastUpdateTimestamp(), tsBefore, "Timestamp should not change on no-op");
    }

    function test_single_idempotent_alreadyClean() public {
        uint256 tsBefore = oracle.lastUpdateTimestamp();

        vm.warp(block.timestamp + 1 hours);

        // Unsanction a clean address — no-op
        vm.prank(complianceBot);
        oracle.updateSanctionStatus(alice, false);

        assertEq(oracle.totalSanctionedCount(), 0, "Count should stay 0");
        assertEq(oracle.lastUpdateTimestamp(), tsBefore, "Timestamp should not change on no-op");
    }

    function test_single_revertsOnZeroAddress() public {
        vm.prank(complianceBot);
        vm.expectRevert(ISanctionsOracle.Oracle__ZeroAddress.selector);
        oracle.updateSanctionStatus(address(0), true);
    }

    function test_single_revertsUnauthorized() public {
        vm.prank(unauthorizedUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorizedUser, COMPLIANCE_ROLE
            )
        );
        oracle.updateSanctionStatus(alice, true);
    }

    function test_single_emitsEvents_onChange() public {
        vm.prank(complianceBot);

        // Expect SanctionStatusUpdated
        vm.expectEmit(true, false, false, true, address(oracle));
        emit ISanctionsOracle.SanctionStatusUpdated(alice, true);

        // Expect BatchSanctionUpdated (batchId=0, processed=1, changed=1, sanctioned=true)
        vm.expectEmit(true, false, false, true, address(oracle));
        emit ISanctionsOracle.BatchSanctionUpdated(0, 1, 1, true);

        oracle.updateSanctionStatus(alice, true);
    }

    function test_single_emitsBatchEvent_onNoOp() public {
        // Alice is already clean; unsanctioning is a no-op
        vm.prank(complianceBot);

        // Should NOT emit SanctionStatusUpdated
        // But SHOULD emit BatchSanctionUpdated with changed=0
        vm.expectEmit(true, false, false, true, address(oracle));
        emit ISanctionsOracle.BatchSanctionUpdated(0, 1, 0, false);

        oracle.updateSanctionStatus(alice, false);
    }

    function test_single_incrementsBatchNonce() public {
        assertEq(oracle.batchNonce(), 0);

        vm.prank(complianceBot);
        oracle.updateSanctionStatus(alice, true);
        assertEq(oracle.batchNonce(), 1);

        vm.prank(complianceBot);
        oracle.updateSanctionStatus(bob, true);
        assertEq(oracle.batchNonce(), 2);

        // No-op also increments
        vm.prank(complianceBot);
        oracle.updateSanctionStatus(alice, true);
        assertEq(oracle.batchNonce(), 3);
    }

    function test_single_updatesTimestamp() public {
        uint256 t0 = block.timestamp;

        vm.warp(t0 + 1 days);
        vm.prank(complianceBot);
        oracle.updateSanctionStatus(alice, true);

        assertEq(oracle.lastUpdateTimestamp(), t0 + 1 days);
    }

    function test_single_noTimestampUpdateOnNoOp() public {
        vm.prank(complianceBot);
        oracle.updateSanctionStatus(alice, true);
        uint256 tsAfterSanction = oracle.lastUpdateTimestamp();

        vm.warp(block.timestamp + 1 days);

        // Idempotent call
        vm.prank(complianceBot);
        oracle.updateSanctionStatus(alice, true);

        assertEq(oracle.lastUpdateTimestamp(), tsAfterSanction, "Timestamp should not advance on no-op");
    }

    // ═════════════════════════════════════════════════════
    //  4. BATCH UPDATE — updateSanctionStatusBatch
    // ═════════════════════════════════════════════════════

    function test_batch_sanctionMultiple() public {
        address[] memory addrs = new address[](3);
        addrs[0] = alice;
        addrs[1] = bob;
        addrs[2] = carol;

        vm.prank(complianceBot);
        oracle.updateSanctionStatusBatch(addrs, true);

        assertTrue(oracle.isSanctioned(alice));
        assertTrue(oracle.isSanctioned(bob));
        assertTrue(oracle.isSanctioned(carol));
        assertEq(oracle.totalSanctionedCount(), 3);
    }

    function test_batch_unsanctionMultiple() public {
        // Setup: sanction 3 addresses
        address[] memory addrs = new address[](3);
        addrs[0] = alice;
        addrs[1] = bob;
        addrs[2] = carol;

        vm.prank(complianceBot);
        oracle.updateSanctionStatusBatch(addrs, true);
        assertEq(oracle.totalSanctionedCount(), 3);

        // Unsanction all
        vm.prank(complianceBot);
        oracle.updateSanctionStatusBatch(addrs, false);

        assertFalse(oracle.isSanctioned(alice));
        assertFalse(oracle.isSanctioned(bob));
        assertFalse(oracle.isSanctioned(carol));
        assertEq(oracle.totalSanctionedCount(), 0);
    }

    function test_batch_partialChanges() public {
        // Pre-sanction alice
        vm.prank(complianceBot);
        oracle.updateSanctionStatus(alice, true);

        // Batch sanction [alice, bob, carol] — alice is already sanctioned
        address[] memory addrs = new address[](3);
        addrs[0] = alice;
        addrs[1] = bob;
        addrs[2] = carol;

        vm.prank(complianceBot);

        // BatchSanctionUpdated should report changed=2 (bob and carol)
        vm.expectEmit(true, false, false, true, address(oracle));
        emit ISanctionsOracle.BatchSanctionUpdated(1, 3, 2, true); // batchNonce=1 (after single update used 0)

        oracle.updateSanctionStatusBatch(addrs, true);

        assertTrue(oracle.isSanctioned(alice));
        assertTrue(oracle.isSanctioned(bob));
        assertTrue(oracle.isSanctioned(carol));
        assertEq(oracle.totalSanctionedCount(), 3);
    }

    function test_batch_allNoOps() public {
        // Batch unsanction [alice, bob] — both already clean
        address[] memory addrs = new address[](2);
        addrs[0] = alice;
        addrs[1] = bob;

        uint256 tsBefore = oracle.lastUpdateTimestamp();
        vm.warp(block.timestamp + 1 hours);

        vm.prank(complianceBot);
        oracle.updateSanctionStatusBatch(addrs, false);

        assertEq(oracle.totalSanctionedCount(), 0);
        assertEq(oracle.lastUpdateTimestamp(), tsBefore, "Timestamp should not advance on all no-ops");
        assertEq(oracle.batchNonce(), 1, "Nonce should still increment");
    }

    function test_batch_duplicateAddresses() public {
        // Same address twice: [alice, alice]
        address[] memory addrs = new address[](2);
        addrs[0] = alice;
        addrs[1] = alice;

        vm.prank(complianceBot);
        oracle.updateSanctionStatusBatch(addrs, true);

        assertTrue(oracle.isSanctioned(alice));
        // Count must be 1, not 2 (idempotency correctly prevents double-count)
        assertEq(oracle.totalSanctionedCount(), 1, "Duplicate should not double-count");
    }

    function test_batch_revertsOnEmptyArray() public {
        address[] memory empty = new address[](0);

        vm.prank(complianceBot);
        vm.expectRevert(ISanctionsOracle.Oracle__EmptyArray.selector);
        oracle.updateSanctionStatusBatch(empty, true);
    }

    function test_batch_revertsOnExceedMaxSize() public {
        uint256 maxSize = oracle.MAX_BATCH_SIZE();
        uint256 tooLarge = maxSize + 1;
        address[] memory addrs = new address[](tooLarge);
        for (uint256 i; i < tooLarge; i++) {
            addrs[i] = address(uint160(i + 1)); // Avoid address(0)
        }

        vm.prank(complianceBot);
        vm.expectRevert(abi.encodeWithSelector(ISanctionsOracle.Oracle__BatchTooLarge.selector, tooLarge, maxSize));
        oracle.updateSanctionStatusBatch(addrs, true);
    }

    function test_batch_exactMaxSize() public {
        uint256 maxSize = oracle.MAX_BATCH_SIZE();
        address[] memory addrs = new address[](maxSize);
        for (uint256 i; i < maxSize; i++) {
            addrs[i] = address(uint160(i + 1));
        }

        vm.prank(complianceBot);
        oracle.updateSanctionStatusBatch(addrs, true);

        assertEq(oracle.totalSanctionedCount(), maxSize);
    }

    function test_batch_revertsOnZeroAddressFirst() public {
        address[] memory addrs = new address[](2);
        addrs[0] = address(0);
        addrs[1] = alice;

        vm.prank(complianceBot);
        vm.expectRevert(ISanctionsOracle.Oracle__ZeroAddress.selector);
        oracle.updateSanctionStatusBatch(addrs, true);
    }

    function test_batch_revertsOnZeroAddressMiddle() public {
        address[] memory addrs = new address[](3);
        addrs[0] = alice;
        addrs[1] = address(0);
        addrs[2] = bob;

        vm.prank(complianceBot);
        vm.expectRevert(ISanctionsOracle.Oracle__ZeroAddress.selector);
        oracle.updateSanctionStatusBatch(addrs, true);
    }

    function test_batch_revertsUnauthorized() public {
        address[] memory addrs = new address[](1);
        addrs[0] = alice;

        vm.prank(unauthorizedUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorizedUser, COMPLIANCE_ROLE
            )
        );
        oracle.updateSanctionStatusBatch(addrs, true);
    }

    function test_batch_emitsPerAddressEvents() public {
        address[] memory addrs = new address[](2);
        addrs[0] = alice;
        addrs[1] = bob;

        vm.prank(complianceBot);

        vm.expectEmit(true, false, false, true, address(oracle));
        emit ISanctionsOracle.SanctionStatusUpdated(alice, true);

        vm.expectEmit(true, false, false, true, address(oracle));
        emit ISanctionsOracle.SanctionStatusUpdated(bob, true);

        oracle.updateSanctionStatusBatch(addrs, true);
    }

    function test_batch_emitsBatchEvent() public {
        address[] memory addrs = new address[](3);
        addrs[0] = alice;
        addrs[1] = bob;
        addrs[2] = carol;

        vm.prank(complianceBot);

        vm.expectEmit(true, false, false, true, address(oracle));
        emit ISanctionsOracle.BatchSanctionUpdated(0, 3, 3, true);

        oracle.updateSanctionStatusBatch(addrs, true);
    }

    function test_batch_incrementsBatchNonce() public {
        address[] memory addrs = new address[](1);
        addrs[0] = alice;

        assertEq(oracle.batchNonce(), 0);

        vm.prank(complianceBot);
        oracle.updateSanctionStatusBatch(addrs, true);
        assertEq(oracle.batchNonce(), 1);

        vm.prank(complianceBot);
        oracle.updateSanctionStatusBatch(addrs, true); // no-op
        assertEq(oracle.batchNonce(), 2);
    }

    function test_batch_noTimestampUpdateOnAllNoOps() public {
        // Sanction alice first
        vm.prank(complianceBot);
        oracle.updateSanctionStatus(alice, true);
        uint256 tsBefore = oracle.lastUpdateTimestamp();

        vm.warp(block.timestamp + 1 days);

        // Batch sanction [alice] again — all no-ops
        address[] memory addrs = new address[](1);
        addrs[0] = alice;

        vm.prank(complianceBot);
        oracle.updateSanctionStatusBatch(addrs, true);

        assertEq(oracle.lastUpdateTimestamp(), tsBefore, "Timestamp must not advance on all no-ops");
    }

    // ═════════════════════════════════════════════════════
    //  5. ACCESS CONTROL
    // ═════════════════════════════════════════════════════

    function test_adminCanGrantComplianceRole() public {
        address newBot = makeAddr("newBot");

        vm.prank(admin);
        oracle.grantRole(COMPLIANCE_ROLE, newBot);

        assertTrue(oracle.hasRole(COMPLIANCE_ROLE, newBot));

        // New bot can sanction
        vm.prank(newBot);
        oracle.updateSanctionStatus(alice, true);
        assertTrue(oracle.isSanctioned(alice));
    }

    function test_adminCanRevokeComplianceRole() public {
        vm.prank(admin);
        oracle.revokeRole(COMPLIANCE_ROLE, complianceBot);

        assertFalse(oracle.hasRole(COMPLIANCE_ROLE, complianceBot));
    }

    function test_revokedBotCannotUpdate() public {
        vm.prank(admin);
        oracle.revokeRole(COMPLIANCE_ROLE, complianceBot);

        vm.prank(complianceBot);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, complianceBot, COMPLIANCE_ROLE
            )
        );
        oracle.updateSanctionStatus(alice, true);
    }

    function test_multipleComplianceBots() public {
        address botA = makeAddr("botA");
        address botB = makeAddr("botB");

        vm.startPrank(admin);
        oracle.grantRole(COMPLIANCE_ROLE, botA);
        oracle.grantRole(COMPLIANCE_ROLE, botB);
        vm.stopPrank();

        // Both bots can operate independently
        vm.prank(botA);
        oracle.updateSanctionStatus(alice, true);
        assertTrue(oracle.isSanctioned(alice));

        vm.prank(botB);
        oracle.updateSanctionStatus(bob, true);
        assertTrue(oracle.isSanctioned(bob));

        assertEq(oracle.totalSanctionedCount(), 2);
    }

    function test_nonAdminCannotGrantRoles() public {
        vm.prank(unauthorizedUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorizedUser, DEFAULT_ADMIN_ROLE
            )
        );
        oracle.grantRole(COMPLIANCE_ROLE, unauthorizedUser);
    }

    function test_complianceBotCannotGrantRoles() public {
        vm.prank(complianceBot);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, complianceBot, DEFAULT_ADMIN_ROLE
            )
        );
        oracle.grantRole(COMPLIANCE_ROLE, unauthorizedUser);
    }

    // ═════════════════════════════════════════════════════
    //  6. COMPLEX SCENARIOS
    // ═════════════════════════════════════════════════════

    function test_sanctionThenUnsanctionCycle() public {
        vm.startPrank(complianceBot);

        // Sanction
        oracle.updateSanctionStatus(alice, true);
        assertTrue(oracle.isSanctioned(alice));
        assertEq(oracle.totalSanctionedCount(), 1);

        // Unsanction
        oracle.updateSanctionStatus(alice, false);
        assertFalse(oracle.isSanctioned(alice));
        assertEq(oracle.totalSanctionedCount(), 0);

        // Re-sanction
        oracle.updateSanctionStatus(alice, true);
        assertTrue(oracle.isSanctioned(alice));
        assertEq(oracle.totalSanctionedCount(), 1);

        vm.stopPrank();
    }

    function test_countConsistencyAfterManyOperations() public {
        vm.startPrank(complianceBot);

        // Sanction 5 addresses individually
        oracle.updateSanctionStatus(alice, true);
        oracle.updateSanctionStatus(bob, true);
        oracle.updateSanctionStatus(carol, true);
        oracle.updateSanctionStatus(dave, true);
        oracle.updateSanctionStatus(eve, true);
        assertEq(oracle.totalSanctionedCount(), 5);

        // Unsanction 2 via batch
        address[] memory unsanctionBatch = new address[](2);
        unsanctionBatch[0] = alice;
        unsanctionBatch[1] = carol;
        oracle.updateSanctionStatusBatch(unsanctionBatch, false);
        assertEq(oracle.totalSanctionedCount(), 3);

        // Verify specific states
        assertFalse(oracle.isSanctioned(alice));
        assertTrue(oracle.isSanctioned(bob));
        assertFalse(oracle.isSanctioned(carol));
        assertTrue(oracle.isSanctioned(dave));
        assertTrue(oracle.isSanctioned(eve));

        // Batch sanction [alice, bob, carol] — alice & carol are new, bob is no-op
        address[] memory mixed = new address[](3);
        mixed[0] = alice;
        mixed[1] = bob;
        mixed[2] = carol;
        oracle.updateSanctionStatusBatch(mixed, true);
        assertEq(oracle.totalSanctionedCount(), 5);

        // Unsanction all 5
        address[] memory all5 = new address[](5);
        all5[0] = alice;
        all5[1] = bob;
        all5[2] = carol;
        all5[3] = dave;
        all5[4] = eve;
        oracle.updateSanctionStatusBatch(all5, false);
        assertEq(oracle.totalSanctionedCount(), 0);

        vm.stopPrank();
    }

    function test_batchNonceMonotonicity() public {
        vm.startPrank(complianceBot);

        address[] memory addrs = new address[](1);
        addrs[0] = alice;

        // single, batch, single, batch — nonce always increments
        oracle.updateSanctionStatus(alice, true); // nonce → 1
        oracle.updateSanctionStatusBatch(addrs, false); // nonce → 2
        oracle.updateSanctionStatus(alice, true); // nonce → 3
        oracle.updateSanctionStatusBatch(addrs, true); // nonce → 4

        assertEq(oracle.batchNonce(), 4);

        vm.stopPrank();
    }

    function test_atomicRevert_noPartialState() public {
        // Sanction alice first
        vm.prank(complianceBot);
        oracle.updateSanctionStatus(alice, true);

        // Batch: [bob, address(0), carol] — should revert on address(0)
        address[] memory addrs = new address[](3);
        addrs[0] = bob;
        addrs[1] = address(0);
        addrs[2] = carol;

        vm.prank(complianceBot);
        vm.expectRevert(ISanctionsOracle.Oracle__ZeroAddress.selector);
        oracle.updateSanctionStatusBatch(addrs, true);

        // State unchanged: bob and carol should still be clean
        assertFalse(oracle.isSanctioned(bob));
        assertFalse(oracle.isSanctioned(carol));
        assertTrue(oracle.isSanctioned(alice)); // Unchanged from prior operation
        assertEq(oracle.totalSanctionedCount(), 1);
    }

    function test_adminEmergencyUnsanction() public {
        // Compliance bot sanctions alice
        vm.prank(complianceBot);
        oracle.updateSanctionStatus(alice, true);
        assertTrue(oracle.isSanctioned(alice));

        // Admin grants itself COMPLIANCE_ROLE for emergency
        vm.prank(admin);
        oracle.grantRole(COMPLIANCE_ROLE, admin);

        // Admin directly unsanctions
        vm.prank(admin);
        oracle.updateSanctionStatus(alice, false);
        assertFalse(oracle.isSanctioned(alice));
        assertEq(oracle.totalSanctionedCount(), 0);
    }

    // ═════════════════════════════════════════════════════
    //  7. ERC-165 INTERFACE DETECTION
    // ═════════════════════════════════════════════════════

    function test_supportsInterface_ISanctionsOracle() public view {
        bytes4 interfaceId = type(ISanctionsOracle).interfaceId;
        assertTrue(oracle.supportsInterface(interfaceId));
    }

    function test_supportsInterface_IAccessControl() public view {
        bytes4 interfaceId = type(IAccessControl).interfaceId;
        assertTrue(oracle.supportsInterface(interfaceId));
    }

    function test_supportsInterface_ERC165() public view {
        // ERC-165 itself: 0x01ffc9a7
        assertTrue(oracle.supportsInterface(0x01ffc9a7));
    }

    function test_supportsInterface_invalidInterface() public view {
        assertFalse(oracle.supportsInterface(0xdeadbeef));
    }

    // ═════════════════════════════════════════════════════
    //  8. FUZZ TESTS
    // ═════════════════════════════════════════════════════

    function testFuzz_singleUpdate_consistency(address account, bool sanctioned) public {
        vm.assume(account != address(0));

        vm.prank(complianceBot);
        oracle.updateSanctionStatus(account, sanctioned);

        assertEq(oracle.isSanctioned(account), sanctioned);
        assertEq(oracle.totalSanctionedCount(), sanctioned ? 1 : 0);
    }

    function testFuzz_idempotency(address account) public {
        vm.assume(account != address(0));

        vm.startPrank(complianceBot);

        // Double-sanction: count must be 1, not 2
        oracle.updateSanctionStatus(account, true);
        oracle.updateSanctionStatus(account, true);
        assertEq(oracle.totalSanctionedCount(), 1);

        // Double-unsanction: count must be 0
        oracle.updateSanctionStatus(account, false);
        oracle.updateSanctionStatus(account, false);
        assertEq(oracle.totalSanctionedCount(), 0);

        vm.stopPrank();
    }

    function testFuzz_batchSize_boundaryCheck(uint256 size) public {
        size = bound(size, 1, oracle.MAX_BATCH_SIZE());

        address[] memory addrs = new address[](size);
        for (uint256 i; i < size; i++) {
            addrs[i] = address(uint160(i + 1));
        }

        vm.prank(complianceBot);
        oracle.updateSanctionStatusBatch(addrs, true);

        assertEq(oracle.totalSanctionedCount(), size);
    }
}
