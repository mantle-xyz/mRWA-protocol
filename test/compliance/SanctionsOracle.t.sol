// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SanctionsOracle} from "../../src/compliance/SanctionsOracle.sol";
import {SanctionsOracleFactory} from "../../src/compliance/SanctionsOracleFactory.sol";
import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Test} from "forge-std/Test.sol";

/**
 * @title  SanctionsOracleTest
 * @notice Comprehensive unit tests for SanctionsOracle (Beacon Proxy edition).
 *
 *         Coverage areas
 *         ──────────────
 *         1. Deployment & Initialization (via BeaconProxy)
 *         2. Read Functions (isSanctioned)
 *         3. Single Update (updateSanctionStatus)
 *         4. Batch Update (updateSanctionStatusBatch)
 *         5. Access Control (role grants, revocations, multi-bot)
 *         6. Complex Scenarios (cycles, count consistency, nonce monotonicity)
 *         7. ERC-165 Interface Detection
 *         8. Fuzz Tests
 *         9. Beacon Proxy Specifics (locked impl, re-init, upgrade, multi-proxy)
 */
contract SanctionsOracleTest is Test {
    // ─────────────────────── infrastructure ───────────────────────
    SanctionsOracle internal implementation;
    SanctionsOracleFactory internal factory;
    UpgradeableBeacon internal beacon;
    SanctionsOracle internal oracle; // proxy, cast to SanctionsOracle

    // ─────────────────────── actors ───────────────────────
    address internal admin = makeAddr("admin");
    address internal complianceBot = makeAddr("complianceBot");
    address internal beaconOwner = makeAddr("beaconOwner");
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
        // 1. Deploy implementation (locked by _disableInitializers in constructor)
        implementation = new SanctionsOracle();

        // 2. Deploy factory (creates UpgradeableBeacon internally)
        factory = new SanctionsOracleFactory(address(implementation), beaconOwner);
        beacon = factory.BEACON();

        // 3. Deploy first oracle proxy via factory
        address oracleAddr = factory.deployAndInitOracle(admin, complianceBot);
        oracle = SanctionsOracle(oracleAddr);

        COMPLIANCE_ROLE = oracle.COMPLIANCE_ROLE();
    }

    // ═════════════════════════════════════════════════════
    //  1. DEPLOYMENT & INITIALIZATION
    // ═════════════════════════════════════════════════════

    function test_initialize_setsRoles() public view {
        assertTrue(oracle.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertTrue(oracle.hasRole(COMPLIANCE_ROLE, complianceBot));
        assertFalse(oracle.hasRole(COMPLIANCE_ROLE, admin));
        assertFalse(oracle.hasRole(DEFAULT_ADMIN_ROLE, complianceBot));
    }

    function test_initialize_setsInitialState() public view {
        assertEq(oracle.totalSanctionedCount(), 0);
        assertEq(oracle.batchNonce(), 0);
        assertEq(oracle.lastUpdateTimestamp(), block.timestamp);
    }

    function test_initialize_revertsOnZeroAdmin() public {
        bytes memory initData = abi.encodeCall(SanctionsOracle.initialize, (address(0), complianceBot));
        vm.expectRevert(ISanctionsOracle.Oracle__ZeroAddress.selector);
        new BeaconProxy(address(beacon), initData);
    }

    function test_initialize_revertsOnZeroComplianceBot() public {
        bytes memory initData = abi.encodeCall(SanctionsOracle.initialize, (admin, address(0)));
        vm.expectRevert(ISanctionsOracle.Oracle__ZeroAddress.selector);
        new BeaconProxy(address(beacon), initData);
    }

    function test_initialize_revertsOnBothZero() public {
        bytes memory initData = abi.encodeCall(SanctionsOracle.initialize, (address(0), address(0)));
        vm.expectRevert(ISanctionsOracle.Oracle__ZeroAddress.selector);
        new BeaconProxy(address(beacon), initData);
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
        vm.prank(complianceBot);
        oracle.updateSanctionStatus(alice, true);

        assertTrue(oracle.isSanctioned(alice));
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
        vm.prank(complianceBot);
        oracle.updateSanctionStatus(alice, true);
        assertEq(oracle.totalSanctionedCount(), 1);

        vm.prank(complianceBot);
        oracle.updateSanctionStatus(alice, false);

        assertFalse(oracle.isSanctioned(alice));
        assertEq(oracle.totalSanctionedCount(), 0);
    }

    function test_single_idempotent_alreadySanctioned() public {
        vm.prank(complianceBot);
        oracle.updateSanctionStatus(alice, true);
        uint256 countBefore = oracle.totalSanctionedCount();
        uint256 tsBefore = oracle.lastUpdateTimestamp();

        vm.warp(block.timestamp + 1 hours);

        vm.prank(complianceBot);
        oracle.updateSanctionStatus(alice, true);

        assertEq(oracle.totalSanctionedCount(), countBefore, "Count should not change on no-op");
        assertEq(oracle.lastUpdateTimestamp(), tsBefore, "Timestamp should not change on no-op");
    }

    function test_single_idempotent_alreadyClean() public {
        uint256 tsBefore = oracle.lastUpdateTimestamp();

        vm.warp(block.timestamp + 1 hours);

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

        vm.expectEmit(true, false, false, true, address(oracle));
        emit ISanctionsOracle.SanctionStatusUpdated(alice, true);

        vm.expectEmit(true, false, false, true, address(oracle));
        emit ISanctionsOracle.BatchSanctionUpdated(0, 1, 1, true);

        oracle.updateSanctionStatus(alice, true);
    }

    function test_single_emitsBatchEvent_onNoOp() public {
        vm.prank(complianceBot);

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
        address[] memory addrs = new address[](3);
        addrs[0] = alice;
        addrs[1] = bob;
        addrs[2] = carol;

        vm.prank(complianceBot);
        oracle.updateSanctionStatusBatch(addrs, true);
        assertEq(oracle.totalSanctionedCount(), 3);

        vm.prank(complianceBot);
        oracle.updateSanctionStatusBatch(addrs, false);

        assertFalse(oracle.isSanctioned(alice));
        assertFalse(oracle.isSanctioned(bob));
        assertFalse(oracle.isSanctioned(carol));
        assertEq(oracle.totalSanctionedCount(), 0);
    }

    function test_batch_partialChanges() public {
        vm.prank(complianceBot);
        oracle.updateSanctionStatus(alice, true);

        address[] memory addrs = new address[](3);
        addrs[0] = alice;
        addrs[1] = bob;
        addrs[2] = carol;

        vm.prank(complianceBot);

        vm.expectEmit(true, false, false, true, address(oracle));
        emit ISanctionsOracle.BatchSanctionUpdated(1, 3, 2, true);

        oracle.updateSanctionStatusBatch(addrs, true);

        assertTrue(oracle.isSanctioned(alice));
        assertTrue(oracle.isSanctioned(bob));
        assertTrue(oracle.isSanctioned(carol));
        assertEq(oracle.totalSanctionedCount(), 3);
    }

    function test_batch_allNoOps() public {
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
        address[] memory addrs = new address[](2);
        addrs[0] = alice;
        addrs[1] = alice;

        vm.prank(complianceBot);
        oracle.updateSanctionStatusBatch(addrs, true);

        assertTrue(oracle.isSanctioned(alice));
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
            addrs[i] = address(uint160(i + 1));
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
        vm.prank(complianceBot);
        oracle.updateSanctionStatus(alice, true);
        uint256 tsBefore = oracle.lastUpdateTimestamp();

        vm.warp(block.timestamp + 1 days);

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

        oracle.updateSanctionStatus(alice, true);
        assertTrue(oracle.isSanctioned(alice));
        assertEq(oracle.totalSanctionedCount(), 1);

        oracle.updateSanctionStatus(alice, false);
        assertFalse(oracle.isSanctioned(alice));
        assertEq(oracle.totalSanctionedCount(), 0);

        oracle.updateSanctionStatus(alice, true);
        assertTrue(oracle.isSanctioned(alice));
        assertEq(oracle.totalSanctionedCount(), 1);

        vm.stopPrank();
    }

    function test_countConsistencyAfterManyOperations() public {
        vm.startPrank(complianceBot);

        oracle.updateSanctionStatus(alice, true);
        oracle.updateSanctionStatus(bob, true);
        oracle.updateSanctionStatus(carol, true);
        oracle.updateSanctionStatus(dave, true);
        oracle.updateSanctionStatus(eve, true);
        assertEq(oracle.totalSanctionedCount(), 5);

        address[] memory unsanctionBatch = new address[](2);
        unsanctionBatch[0] = alice;
        unsanctionBatch[1] = carol;
        oracle.updateSanctionStatusBatch(unsanctionBatch, false);
        assertEq(oracle.totalSanctionedCount(), 3);

        assertFalse(oracle.isSanctioned(alice));
        assertTrue(oracle.isSanctioned(bob));
        assertFalse(oracle.isSanctioned(carol));
        assertTrue(oracle.isSanctioned(dave));
        assertTrue(oracle.isSanctioned(eve));

        address[] memory mixed = new address[](3);
        mixed[0] = alice;
        mixed[1] = bob;
        mixed[2] = carol;
        oracle.updateSanctionStatusBatch(mixed, true);
        assertEq(oracle.totalSanctionedCount(), 5);

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

        oracle.updateSanctionStatus(alice, true); // nonce → 1
        oracle.updateSanctionStatusBatch(addrs, false); // nonce → 2
        oracle.updateSanctionStatus(alice, true); // nonce → 3
        oracle.updateSanctionStatusBatch(addrs, true); // nonce → 4

        assertEq(oracle.batchNonce(), 4);

        vm.stopPrank();
    }

    function test_atomicRevert_noPartialState() public {
        vm.prank(complianceBot);
        oracle.updateSanctionStatus(alice, true);

        address[] memory addrs = new address[](3);
        addrs[0] = bob;
        addrs[1] = address(0);
        addrs[2] = carol;

        vm.prank(complianceBot);
        vm.expectRevert(ISanctionsOracle.Oracle__ZeroAddress.selector);
        oracle.updateSanctionStatusBatch(addrs, true);

        assertFalse(oracle.isSanctioned(bob));
        assertFalse(oracle.isSanctioned(carol));
        assertTrue(oracle.isSanctioned(alice));
        assertEq(oracle.totalSanctionedCount(), 1);
    }

    function test_adminEmergencyUnsanction() public {
        vm.prank(complianceBot);
        oracle.updateSanctionStatus(alice, true);
        assertTrue(oracle.isSanctioned(alice));

        vm.prank(admin);
        oracle.grantRole(COMPLIANCE_ROLE, admin);

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

        oracle.updateSanctionStatus(account, true);
        oracle.updateSanctionStatus(account, true);
        assertEq(oracle.totalSanctionedCount(), 1);

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

    // ═════════════════════════════════════════════════════
    //  9. BEACON PROXY SPECIFICS
    // ═════════════════════════════════════════════════════

    function test_implementation_isLocked() public {
        // Implementation contract must reject initialize calls (locked by _disableInitializers)
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(admin, complianceBot);
    }

    function test_proxy_cannotReinitialize() public {
        // Proxy has already been initialized in setUp; second call must revert
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        oracle.initialize(admin, complianceBot);
    }

    function test_beacon_pointsToImplementation() public view {
        assertEq(beacon.implementation(), address(implementation));
    }

    function test_beacon_upgradeByOwner() public {
        // Set some state before upgrade
        vm.prank(complianceBot);
        oracle.updateSanctionStatus(alice, true);
        assertTrue(oracle.isSanctioned(alice));
        assertEq(oracle.totalSanctionedCount(), 1);
        uint256 nonceBefore = oracle.batchNonce();

        // Deploy a new implementation and upgrade
        SanctionsOracle newImpl = new SanctionsOracle();

        vm.prank(beaconOwner);
        beacon.upgradeTo(address(newImpl));

        assertEq(beacon.implementation(), address(newImpl));

        // State must persist after upgrade
        assertTrue(oracle.isSanctioned(alice));
        assertEq(oracle.totalSanctionedCount(), 1);
        assertEq(oracle.batchNonce(), nonceBefore);

        // New operations must still work
        vm.prank(complianceBot);
        oracle.updateSanctionStatus(bob, true);
        assertTrue(oracle.isSanctioned(bob));
        assertEq(oracle.totalSanctionedCount(), 2);
    }

    function test_beacon_upgradeByNonOwnerReverts() public {
        SanctionsOracle newImpl = new SanctionsOracle();

        vm.prank(unauthorizedUser);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorizedUser));
        beacon.upgradeTo(address(newImpl));
    }

    function test_multipleProxies_independentState() public {
        // Deploy a second proxy from the same beacon
        bytes memory initData = abi.encodeCall(SanctionsOracle.initialize, (admin, complianceBot));
        BeaconProxy proxy2 = new BeaconProxy(address(beacon), initData);
        SanctionsOracle oracle2 = SanctionsOracle(address(proxy2));

        // Sanction alice on oracle1 only
        vm.prank(complianceBot);
        oracle.updateSanctionStatus(alice, true);

        assertTrue(oracle.isSanctioned(alice));
        assertFalse(oracle2.isSanctioned(alice), "Second proxy must have independent state");

        // Sanction bob on oracle2 only
        vm.prank(complianceBot);
        oracle2.updateSanctionStatus(bob, true);

        assertFalse(oracle.isSanctioned(bob), "First proxy must not see second proxy's state");
        assertTrue(oracle2.isSanctioned(bob));

        // Counts must be independent
        assertEq(oracle.totalSanctionedCount(), 1);
        assertEq(oracle2.totalSanctionedCount(), 1);
    }

    function test_multipleProxies_sharedUpgrade() public {
        // Deploy a second proxy
        bytes memory initData = abi.encodeCall(SanctionsOracle.initialize, (admin, complianceBot));
        BeaconProxy proxy2 = new BeaconProxy(address(beacon), initData);
        SanctionsOracle oracle2 = SanctionsOracle(address(proxy2));

        // Set state on both
        vm.prank(complianceBot);
        oracle.updateSanctionStatus(alice, true);
        vm.prank(complianceBot);
        oracle2.updateSanctionStatus(bob, true);

        // Upgrade beacon — both proxies point to new impl atomically
        SanctionsOracle newImpl = new SanctionsOracle();
        vm.prank(beaconOwner);
        beacon.upgradeTo(address(newImpl));

        // Both proxies' state must persist
        assertTrue(oracle.isSanctioned(alice));
        assertTrue(oracle2.isSanctioned(bob));

        // Both proxies must still work
        vm.prank(complianceBot);
        oracle.updateSanctionStatus(carol, true);
        vm.prank(complianceBot);
        oracle2.updateSanctionStatus(dave, true);

        assertTrue(oracle.isSanctioned(carol));
        assertTrue(oracle2.isSanctioned(dave));
    }

    function test_statePersistedAfterUpgrade() public {
        // Build up some complex state
        vm.startPrank(complianceBot);
        oracle.updateSanctionStatus(alice, true);
        oracle.updateSanctionStatus(bob, true);
        oracle.updateSanctionStatus(carol, true);
        oracle.updateSanctionStatus(carol, false); // unsanction carol
        vm.stopPrank();

        uint256 countBefore = oracle.totalSanctionedCount();
        uint256 nonceBefore = oracle.batchNonce();
        uint256 tsBefore = oracle.lastUpdateTimestamp();

        // Upgrade
        SanctionsOracle newImpl = new SanctionsOracle();
        vm.prank(beaconOwner);
        beacon.upgradeTo(address(newImpl));

        // Verify all state persisted
        assertTrue(oracle.isSanctioned(alice));
        assertTrue(oracle.isSanctioned(bob));
        assertFalse(oracle.isSanctioned(carol));
        assertEq(oracle.totalSanctionedCount(), countBefore);
        assertEq(oracle.batchNonce(), nonceBefore);
        assertEq(oracle.lastUpdateTimestamp(), tsBefore);
    }

    // ═════════════════════════════════════════════════════
    //  10. FACTORY
    // ═════════════════════════════════════════════════════

    function test_factory_beaconOwnership() public view {
        assertEq(beacon.owner(), beaconOwner);
    }

    function test_factory_beaconPointsToImpl() public view {
        assertEq(factory.implementation(), address(implementation));
    }

    function test_factory_oracleCountAfterSetUp() public view {
        assertEq(factory.oracleCount(), 1);
        assertEq(factory.oracles(0), address(oracle));
    }

    function test_factory_deployAndInitOracle() public {
        address newOracle = factory.deployAndInitOracle(admin, complianceBot);

        assertEq(factory.oracleCount(), 2);
        assertEq(factory.oracles(1), newOracle);

        SanctionsOracle o = SanctionsOracle(newOracle);
        assertTrue(o.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertTrue(o.hasRole(COMPLIANCE_ROLE, complianceBot));
        assertEq(o.totalSanctionedCount(), 0);
        assertEq(o.lastUpdateTimestamp(), block.timestamp);
    }

    function test_factory_deployOracle_uninitialized() public {
        address newOracle = factory.deployOracle();

        assertEq(factory.oracleCount(), 2);
        assertEq(factory.oracles(1), newOracle);

        // Proxy is uninitialized — no roles granted yet
        SanctionsOracle o = SanctionsOracle(newOracle);
        assertFalse(o.hasRole(DEFAULT_ADMIN_ROLE, admin));

        // Can initialize separately
        o.initialize(admin, complianceBot);
        assertTrue(o.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertTrue(o.hasRole(COMPLIANCE_ROLE, complianceBot));
    }

    function test_factory_deployOracle_emitsEvent() public {
        vm.expectEmit(false, false, false, true, address(factory));
        emit SanctionsOracleFactory.OracleDeployed(address(0), 1, false);

        factory.deployOracle();
    }

    function test_factory_deployAndInitOracle_emitsEvent() public {
        vm.expectEmit(false, false, false, true, address(factory));
        emit SanctionsOracleFactory.OracleDeployed(address(0), 1, true);

        factory.deployAndInitOracle(admin, complianceBot);
    }

    function test_factory_getAllOracles() public {
        address o2 = factory.deployAndInitOracle(admin, complianceBot);
        address o3 = factory.deployOracle();

        address[] memory all = factory.getAllOracles();
        assertEq(all.length, 3);
        assertEq(all[0], address(oracle));
        assertEq(all[1], o2);
        assertEq(all[2], o3);
    }

    function test_factory_revertsOnZeroImpl() public {
        vm.expectRevert(SanctionsOracleFactory.Factory__ZeroAddress.selector);
        new SanctionsOracleFactory(address(0), beaconOwner);
    }

    function test_factory_revertsOnZeroBeaconOwner() public {
        vm.expectRevert(SanctionsOracleFactory.Factory__ZeroAddress.selector);
        new SanctionsOracleFactory(address(implementation), address(0));
    }

    function test_factory_deployAndInit_revertsOnZeroAdmin() public {
        vm.expectRevert(ISanctionsOracle.Oracle__ZeroAddress.selector);
        factory.deployAndInitOracle(address(0), complianceBot);
    }

    function test_factory_deployAndInit_revertsOnZeroBot() public {
        vm.expectRevert(ISanctionsOracle.Oracle__ZeroAddress.selector);
        factory.deployAndInitOracle(admin, address(0));
    }

    function test_factory_multipleOracles_independentState() public {
        address o2Addr = factory.deployAndInitOracle(admin, complianceBot);
        SanctionsOracle o2 = SanctionsOracle(o2Addr);

        vm.prank(complianceBot);
        oracle.updateSanctionStatus(alice, true);

        assertTrue(oracle.isSanctioned(alice));
        assertFalse(o2.isSanctioned(alice));

        vm.prank(complianceBot);
        o2.updateSanctionStatus(bob, true);

        assertFalse(oracle.isSanctioned(bob));
        assertTrue(o2.isSanctioned(bob));
    }

    function test_factory_sharedUpgradeAcrossOracles() public {
        address o2Addr = factory.deployAndInitOracle(admin, complianceBot);
        SanctionsOracle o2 = SanctionsOracle(o2Addr);

        vm.prank(complianceBot);
        oracle.updateSanctionStatus(alice, true);
        vm.prank(complianceBot);
        o2.updateSanctionStatus(bob, true);

        SanctionsOracle newImpl = new SanctionsOracle();
        vm.prank(beaconOwner);
        beacon.upgradeTo(address(newImpl));

        assertEq(factory.implementation(), address(newImpl));

        assertTrue(oracle.isSanctioned(alice));
        assertTrue(o2.isSanctioned(bob));

        vm.prank(complianceBot);
        oracle.updateSanctionStatus(carol, true);
        vm.prank(complianceBot);
        o2.updateSanctionStatus(dave, true);

        assertTrue(oracle.isSanctioned(carol));
        assertTrue(o2.isSanctioned(dave));
    }
}
