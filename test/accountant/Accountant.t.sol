// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Accountant} from "../../src/accountant/Accountant.sol";
import {AccountantExecutor} from "../../src/accountant/AccountantExecutor.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Test} from "forge-std/Test.sol";

// =============================================================
//                           MOCKS
// =============================================================

contract MockAccountant {
    uint256 public lastNewRate;
    uint256 public lastComputeTimestamp;
    uint256 public callCount;
    uint256 public settleCallCount;

    function updateExchangeRate(uint64 newRate, uint64 computeTimestamp) external {
        lastNewRate = newRate;
        lastComputeTimestamp = computeTimestamp;
        callCount++;
    }

    function settleManagementFee() external {
        settleCallCount++;
    }
}

contract MockVault {
    uint256 public exchangeRate;
    uint256 public _totalSupply;

    uint256 public lastFeeShares;
    uint256 public totalFeeMintCalls;

    function mintFeeShares(uint256 shares) external {
        lastFeeShares = shares;
        totalFeeMintCalls++;
    }

    function updateExchangeRate(uint256 newRate) external {
        exchangeRate = newRate;
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function setTotalSupply(uint256 supply) external {
        _totalSupply = supply;
    }

    function asset() external pure returns (address) {
        return address(0xA);
    }
}

// =============================================================
//                   ACCOUNTANT UNIT TESTS
// =============================================================

contract AccountantTest is Test {
    Accountant public accountant;
    MockVault public vault;
    UpgradeableBeacon public beacon;

    address public admin = makeAddr("admin");
    address public executor = makeAddr("executor");
    address public pauser = makeAddr("pauser");
    address public user = makeAddr("user");

    uint64 public constant INITIAL_RATE = 1e18;
    uint32 public constant MANAGEMENT_FEE_BPS = 50; // 0.5%

    function setUp() public {
        vm.warp(1000);

        vault = new MockVault();

        Accountant impl = new Accountant();
        beacon = new UpgradeableBeacon(address(impl), admin);
        BeaconProxy proxy =
            new BeaconProxy(address(beacon), _initData(address(vault), INITIAL_RATE, MANAGEMENT_FEE_BPS));
        accountant = Accountant(address(proxy));
    }

    // ── helpers ───────────────────────────────────────────────────

    function _skipCooldown() internal {
        vm.warp(block.timestamp + accountant.minUpdateInterval() + 1);
    }

    function _doUpdate(uint64 newRate) internal {
        vm.prank(executor);
        accountant.updateExchangeRate(newRate, uint64(block.timestamp));
    }

    function _settleFee() internal {
        vm.prank(executor);
        accountant.settleManagementFee();
    }

    function _initData(address vault_, uint64 initialRate, uint32 managementFeeRate_)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeCall(Accountant.initialize, (vault_, initialRate, managementFeeRate_, admin, pauser, executor));
    }

    // =============================================================
    //                    INITIALIZER TESTS
    // =============================================================

    function test_initialize_setsStateCorrectly() public view {
        assertEq(address(accountant.vault()), address(vault));
        assertEq(accountant.lastExchangeRate(), INITIAL_RATE);
        assertEq(accountant.managementFeeRate(), MANAGEMENT_FEE_BPS);
        assertEq(accountant.maxAllowedDeviation(), 100);
        assertEq(accountant.minUpdateInterval(), 20 hours);
        assertEq(accountant.maxComputeAge(), 5 minutes);
        assertEq(accountant.lastUpdateTimestamp(), 1000);
        assertEq(accountant.lastFeeSettleTimestamp(), 1000);
        assertEq(accountant.totalSharesLastSettle(), 0);
        assertEq(accountant.lastComputeTimestamp(), 1000);
    }

    function test_initialize_setsRolesCorrectly() public view {
        assertTrue(accountant.hasRole(accountant.DEFAULT_ADMIN_ROLE(), admin));
        assertFalse(accountant.hasRole(accountant.PAUSER_ROLE(), admin));
        assertFalse(accountant.hasRole(accountant.ACCOUNTANT_EXECUTOR_ROLE(), admin));
        assertTrue(accountant.hasRole(accountant.PAUSER_ROLE(), pauser));
        assertTrue(accountant.hasRole(accountant.PAUSER_ROLE(), executor));
        assertTrue(accountant.hasRole(accountant.ACCOUNTANT_EXECUTOR_ROLE(), executor));
        assertEq(accountant.getRoleAdmin(accountant.PAUSER_ROLE()), accountant.DEFAULT_ADMIN_ROLE());
        assertEq(accountant.getRoleAdmin(accountant.ACCOUNTANT_EXECUTOR_ROLE()), accountant.DEFAULT_ADMIN_ROLE());
    }

    function test_initialize_revertsOnDoubleInit() public {
        vm.expectRevert();
        accountant.initialize(address(vault), INITIAL_RATE, MANAGEMENT_FEE_BPS, admin, pauser, executor);
    }

    function test_initialize_revertsWhenVaultIsZero() public {
        vm.expectRevert(Accountant.Accountant__ZeroAddress.selector);
        new BeaconProxy(address(beacon), _initData(address(0), INITIAL_RATE, MANAGEMENT_FEE_BPS));
    }

    function test_initialize_revertsWhenAdminIsZero() public {
        vm.expectRevert(Accountant.Accountant__ZeroAddress.selector);
        new BeaconProxy(
            address(beacon),
            abi.encodeCall(
                Accountant.initialize, (address(vault), INITIAL_RATE, MANAGEMENT_FEE_BPS, address(0), pauser, executor)
            )
        );
    }

    function test_initialize_revertsWhenPauserIsZero() public {
        vm.expectRevert(Accountant.Accountant__ZeroAddress.selector);
        new BeaconProxy(
            address(beacon),
            abi.encodeCall(
                Accountant.initialize, (address(vault), INITIAL_RATE, MANAGEMENT_FEE_BPS, admin, address(0), executor)
            )
        );
    }

    function test_initialize_revertsWhenExecutorIsZero() public {
        vm.expectRevert(Accountant.Accountant__ZeroAddress.selector);
        new BeaconProxy(
            address(beacon),
            abi.encodeCall(
                Accountant.initialize, (address(vault), INITIAL_RATE, MANAGEMENT_FEE_BPS, admin, pauser, address(0))
            )
        );
    }

    function test_initialize_revertsWhenRateIsZero() public {
        vm.expectRevert(Accountant.Accountant__InvalidRate.selector);
        new BeaconProxy(address(beacon), _initData(address(vault), 0, MANAGEMENT_FEE_BPS));
    }

    function test_initialize_revertsWhenFeeExceedsCap() public {
        uint32 tooHigh = accountant.MAX_MANAGEMENT_FEE_BPS() + 1;
        vm.expectRevert(abi.encodeWithSelector(Accountant.Accountant__InvalidFeeRate.selector, tooHigh));
        new BeaconProxy(address(beacon), _initData(address(vault), INITIAL_RATE, tooHigh));
    }

    function test_initialize_allowsZeroFeeRate() public {
        BeaconProxy proxy = new BeaconProxy(address(beacon), _initData(address(vault), INITIAL_RATE, uint32(0)));
        assertEq(Accountant(address(proxy)).managementFeeRate(), 0);
    }

    function test_initialize_allowsMaxFeeRate() public {
        uint32 maxFee = accountant.MAX_MANAGEMENT_FEE_BPS();
        BeaconProxy proxy = new BeaconProxy(address(beacon), _initData(address(vault), INITIAL_RATE, maxFee));
        assertEq(Accountant(address(proxy)).managementFeeRate(), maxFee);
    }

    // =============================================================
    //              UPDATE EXCHANGE RATE — HAPPY PATH
    // =============================================================

    function test_updateExchangeRate_succeeds() public {
        _skipCooldown();

        uint64 newRate = 1.005e18;
        _doUpdate(newRate);

        assertEq(accountant.lastExchangeRate(), newRate);
        assertEq(accountant.getRate(), newRate);
        assertEq(accountant.lastUpdateTimestamp(), block.timestamp);
        assertEq(accountant.lastComputeTimestamp(), block.timestamp);
    }

    function test_updateExchangeRate_emitsEvent() public {
        _skipCooldown();

        uint64 newRate = 1.005e18;

        vm.expectEmit(false, false, false, true);
        emit Accountant.ExchangeRateUpdated(INITIAL_RATE, newRate, block.timestamp);

        _doUpdate(newRate);
    }

    function test_updateExchangeRate_consecutiveUpdates() public {
        _skipCooldown();

        uint64 computeTs1 = uint64(block.timestamp);
        vm.prank(executor);
        accountant.updateExchangeRate(1.005e18, computeTs1);

        uint64 computeTs2 = computeTs1 + uint64(accountant.minUpdateInterval()) + 1;
        vm.warp(computeTs2);

        vm.prank(executor);
        accountant.updateExchangeRate(1.009e18, computeTs2);

        assertEq(accountant.lastExchangeRate(), 1.009e18);
        assertEq(accountant.lastComputeTimestamp(), computeTs2);
    }

    function test_updateExchangeRate_rateDecrease() public {
        _skipCooldown();

        uint64 newRate = 0.995e18; // 0.5% decrease
        _doUpdate(newRate);
        assertEq(accountant.lastExchangeRate(), newRate);
    }

    // =============================================================
    //              UPDATE EXCHANGE RATE — ACCESS CONTROL
    // =============================================================

    function test_updateExchangeRate_revertsWhenNotExecutor() public {
        _skipCooldown();

        bytes32 role = accountant.ACCOUNTANT_EXECUTOR_ROLE();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, role));
        vm.prank(user);
        accountant.updateExchangeRate(1.005e18, uint64(block.timestamp));
    }

    function test_updateExchangeRate_revertsWhenCalledByPauser() public {
        _skipCooldown();

        bytes32 role = accountant.ACCOUNTANT_EXECUTOR_ROLE();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, pauser, role));
        vm.prank(pauser);
        accountant.updateExchangeRate(1.005e18, uint64(block.timestamp));
    }

    // =============================================================
    //              UPDATE EXCHANGE RATE — PAUSED
    // =============================================================

    function test_updateExchangeRate_revertsWhenPaused() public {
        vm.prank(pauser);
        accountant.pause();

        _skipCooldown();

        vm.expectRevert();
        _doUpdate(1.005e18);
    }

    // =============================================================
    //              UPDATE EXCHANGE RATE — ZERO RATE
    // =============================================================

    function test_updateExchangeRate_revertsWhenRateIsZero() public {
        _skipCooldown();

        vm.expectRevert(Accountant.Accountant__InvalidRate.selector);
        _doUpdate(0);
    }

    // =============================================================
    //              COOLDOWN CIRCUIT BREAKER
    // =============================================================

    function test_updateExchangeRate_revertsWhenCooldownNotElapsed() public {
        vm.expectRevert();
        _doUpdate(1.005e18);
    }

    function test_updateExchangeRate_revertsWithTimeRemaining() public {
        vm.warp(block.timestamp + 1 hours);

        uint256 cooldownEnd = 1000 + accountant.minUpdateInterval();
        uint256 remaining = cooldownEnd - block.timestamp;

        vm.expectRevert(abi.encodeWithSelector(Accountant.Accountant__CooldownNotElapsed.selector, remaining));
        _doUpdate(1.005e18);
    }

    function test_updateExchangeRate_succeedsAtExactCooldownBoundary() public {
        vm.warp(1000 + accountant.minUpdateInterval());

        _doUpdate(1.005e18);
        assertEq(accountant.lastExchangeRate(), 1.005e18);
    }

    function test_updateExchangeRate_cooldownResetsAfterUpdate() public {
        _skipCooldown();
        _doUpdate(1.005e18);

        vm.expectRevert();
        vm.prank(executor);
        accountant.updateExchangeRate(1.006e18, uint64(block.timestamp + 1));
    }

    // =============================================================
    //              DEVIATION CIRCUIT BREAKER
    // =============================================================

    function test_updateExchangeRate_pausesWhenDeviationExceeded_up() public {
        _skipCooldown();

        uint64 tooHighRate = 1.02e18; // 2% up, max is 1%

        vm.expectEmit(false, false, false, true);
        emit Accountant.CircuitBreakerTriggered(200, accountant.maxAllowedDeviation(), tooHighRate);

        _doUpdate(tooHighRate);

        assertTrue(accountant.paused());
        assertEq(accountant.lastExchangeRate(), INITIAL_RATE, "Rate should NOT be updated");
    }

    function test_updateExchangeRate_pausesWhenDeviationExceeded_down() public {
        _skipCooldown();

        uint64 tooLowRate = 0.98e18; // 2% down

        vm.expectEmit(false, false, false, true);
        emit Accountant.CircuitBreakerTriggered(200, accountant.maxAllowedDeviation(), tooLowRate);

        _doUpdate(tooLowRate);

        assertTrue(accountant.paused());
        assertEq(accountant.lastExchangeRate(), INITIAL_RATE, "Rate should NOT be updated");
    }

    function test_updateExchangeRate_succeedsAtMaxDeviationBoundary() public {
        _skipCooldown();

        uint64 boundaryRate = 1.01e18; // exactly 1% = 100 bps
        _doUpdate(boundaryRate);
        assertEq(accountant.lastExchangeRate(), boundaryRate);
    }

    function test_updateExchangeRate_succeedsWithZeroDeviation() public {
        _skipCooldown();

        _doUpdate(INITIAL_RATE);
        assertEq(accountant.lastExchangeRate(), INITIAL_RATE);
    }

    // =============================================================
    //              COMPUTE TIMESTAMP VALIDATION
    // =============================================================

    function test_updateExchangeRate_revertsWhenComputeTimestampStale() public {
        _skipCooldown();

        uint64 computeTs1 = uint64(block.timestamp);
        vm.prank(executor);
        accountant.updateExchangeRate(1.005e18, computeTs1);

        _skipCooldown();

        vm.expectRevert(
            abi.encodeWithSelector(Accountant.Accountant__StaleComputeTimestamp.selector, computeTs1, computeTs1)
        );
        vm.prank(executor);
        accountant.updateExchangeRate(1.006e18, computeTs1);
    }

    function test_updateExchangeRate_revertsWhenComputeTimestampEqual() public {
        _skipCooldown();

        uint64 computeTs = uint64(block.timestamp);
        vm.prank(executor);
        accountant.updateExchangeRate(1.005e18, computeTs);

        _skipCooldown();

        vm.expectRevert(
            abi.encodeWithSelector(Accountant.Accountant__StaleComputeTimestamp.selector, computeTs, computeTs)
        );
        vm.prank(executor);
        accountant.updateExchangeRate(1.006e18, computeTs);
    }

    function test_updateExchangeRate_revertsWhenComputeTimestampInFuture() public {
        _skipCooldown();

        uint64 futureTs = uint64(block.timestamp + 1);

        vm.expectRevert(
            abi.encodeWithSelector(Accountant.Accountant__FutureComputeTimestamp.selector, futureTs, block.timestamp)
        );
        vm.prank(executor);
        accountant.updateExchangeRate(1.005e18, futureTs);
    }

    function test_updateExchangeRate_revertsWhenComputeTimestampTooOld() public {
        _skipCooldown();

        uint256 maxAge = accountant.maxComputeAge();
        uint64 staleTs = uint64(block.timestamp - maxAge - 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                Accountant.Accountant__ComputeTimestampTooOld.selector, staleTs, block.timestamp, maxAge
            )
        );
        vm.prank(executor);
        accountant.updateExchangeRate(1.005e18, staleTs);
    }

    function test_updateExchangeRate_succeedsAtMaxComputeAgeBoundary() public {
        _skipCooldown();

        uint256 maxAge = accountant.maxComputeAge();
        uint64 borderTs = uint64(block.timestamp - maxAge);

        vm.prank(executor);
        accountant.updateExchangeRate(1.005e18, borderTs);
        assertEq(accountant.lastComputeTimestamp(), borderTs);
    }

    // =============================================================
    //                    FEE SETTLEMENT
    // =============================================================

    /// @dev Same-block call short-circuits on timeElapsed == 0; snapshot stays untouched.
    function test_settleManagementFee_isNoOpInSameBlock() public {
        vault.setTotalSupply(100_000e18);

        uint64 timestampBefore = accountant.lastFeeSettleTimestamp();
        uint256 snapshotBefore = accountant.totalSharesLastSettle();

        _settleFee();

        assertEq(vault.totalFeeMintCalls(), 0);
        assertEq(accountant.lastFeeSettleTimestamp(), timestampBefore);
        assertEq(accountant.totalSharesLastSettle(), snapshotBefore);
    }

    /// @dev First settle after init primes the snapshot but mints nothing,
    ///      because shareBase = min(currentSupply, 0) = 0.
    function test_settleManagementFee_firstCallPrimesSnapshotWithoutMint() public {
        vault.setTotalSupply(100_000e18);

        skip(1);
        _settleFee();

        assertEq(vault.totalFeeMintCalls(), 0);
        assertEq(accountant.totalSharesLastSettle(), 100_000e18);
        assertEq(accountant.lastFeeSettleTimestamp(), uint64(block.timestamp));
    }

    /// @dev After priming, a subsequent settle mints shares per
    ///      (shareBase * feeBps * elapsed) / (MAX_BPS * 365 days)
    ///      and emits FeesDistributed.
    function test_settleManagementFee_mintsExpectedSharesAndEmits() public {
        uint256 totalShares = 100_000e18;
        vault.setTotalSupply(totalShares);

        skip(1);
        _settleFee(); // prime

        skip(20 hours);
        uint256 elapsed = block.timestamp - accountant.lastFeeSettleTimestamp();
        uint256 expected = (totalShares * MANAGEMENT_FEE_BPS * elapsed) / (10_000 * 365 days);

        vm.expectEmit(false, false, false, true);
        emit Accountant.FeesDistributed(expected);
        _settleFee();

        assertEq(vault.lastFeeShares(), expected);
        assertEq(vault.totalFeeMintCalls(), 1);
        assertEq(accountant.lastFeeSettleTimestamp(), uint64(block.timestamp));
        assertEq(accountant.totalSharesLastSettle(), totalShares);
    }

    function test_settleManagementFee_noFeeWhenZeroSupply() public {
        vault.setTotalSupply(0);

        skip(1);
        _settleFee();

        assertEq(vault.totalFeeMintCalls(), 0);
    }

    /// @dev With fee rate = 0, even a primed-and-elapsed settle mints nothing.
    function test_settleManagementFee_noFeeWhenZeroFeeRate() public {
        vm.prank(admin);
        accountant.setManagementFeeRate(0);

        vault.setTotalSupply(100_000e18);

        skip(1);
        _settleFee(); // prime
        skip(20 hours);
        _settleFee(); // would mint if rate were non-zero

        assertEq(vault.totalFeeMintCalls(), 0);
    }

    /// @dev When supply rises between settles, fee uses the prior (smaller) snapshot.
    function test_settleManagementFee_supplyRisesUsesSnapshot() public {
        vault.setTotalSupply(100_000e18);

        skip(1);
        _settleFee(); // prime with 100k

        vault.setTotalSupply(500_000e18);
        skip(20 hours);
        uint256 elapsed = block.timestamp - accountant.lastFeeSettleTimestamp();

        _settleFee();

        // shareBase = min(500k, 100k) = 100k
        uint256 expected = (100_000e18 * uint256(MANAGEMENT_FEE_BPS) * elapsed) / (10_000 * 365 days);
        assertEq(vault.lastFeeShares(), expected);
        assertEq(accountant.totalSharesLastSettle(), 500_000e18);
    }

    /// @dev When supply falls between settles, fee uses the current (smaller) supply.
    function test_settleManagementFee_supplyFallsUsesCurrent() public {
        vault.setTotalSupply(500_000e18);

        skip(1);
        _settleFee(); // prime with 500k

        vault.setTotalSupply(100_000e18);
        skip(20 hours);
        uint256 elapsed = block.timestamp - accountant.lastFeeSettleTimestamp();

        _settleFee();

        // shareBase = min(100k, 500k) = 100k
        uint256 expected = (100_000e18 * uint256(MANAGEMENT_FEE_BPS) * elapsed) / (10_000 * 365 days);
        assertEq(vault.lastFeeShares(), expected);
        assertEq(accountant.totalSharesLastSettle(), 100_000e18);
    }

    /// @dev Each non-zero-elapsed call mints fees independently for its own period.
    function test_settleManagementFee_accumulatesAcrossCalls() public {
        vault.setTotalSupply(1_000_000e18);

        skip(1);
        _settleFee(); // prime, no mint

        skip(20 hours);
        _settleFee();
        uint256 firstFee = vault.lastFeeShares();
        assertGt(firstFee, 0);

        skip(20 hours);
        _settleFee();
        uint256 secondFee = vault.lastFeeShares();
        assertGt(secondFee, 0);

        assertEq(vault.totalFeeMintCalls(), 2);
    }

    function test_settleManagementFee_revertsWhenNotExecutor() public {
        vm.expectRevert();
        vm.prank(user);
        accountant.settleManagementFee();
    }

    function test_settleManagementFee_revertsWhenPaused() public {
        vm.prank(pauser);
        accountant.pause();

        vm.expectRevert();
        _settleFee();
    }

    // =============================================================
    //                    getRate / getRateSafe
    // =============================================================

    function test_getRate_returnsCurrentRate() public view {
        assertEq(accountant.getRate(), INITIAL_RATE);
    }

    function test_getRate_updatesAfterExchangeRateChange() public {
        _skipCooldown();
        uint64 newRate = 1.005e18;
        _doUpdate(newRate);
        assertEq(accountant.getRate(), newRate);
    }

    function test_getRate_worksWhenPaused() public {
        vm.prank(pauser);
        accountant.pause();
        assertEq(accountant.getRate(), INITIAL_RATE);
    }

    function test_getRateSafe_returnsCurrentRate() public view {
        assertEq(accountant.getRateSafe(), INITIAL_RATE);
    }

    function test_getRateSafe_revertsWhenPaused() public {
        vm.prank(pauser);
        accountant.pause();

        vm.expectRevert();
        accountant.getRateSafe();
    }

    function test_getRateSafe_worksAfterUnpause() public {
        vm.prank(pauser);
        accountant.pause();

        vm.prank(admin);
        accountant.unpause();

        assertEq(accountant.getRateSafe(), INITIAL_RATE);
    }

    // =============================================================
    //            EMERGENCY UPDATE EXCHANGE RATE
    // =============================================================

    function test_emergencyRateUpdate_succeeds() public {
        uint64 newRate = 0.5e18; // 50% crash — far beyond normal deviation limit
        vm.prank(admin);
        accountant.emergencyRateUpdate(newRate);

        assertEq(accountant.lastExchangeRate(), newRate);
        assertEq(accountant.getRate(), newRate);
        assertEq(accountant.lastUpdateTimestamp(), block.timestamp);
        assertEq(accountant.lastComputeTimestamp(), block.timestamp);
    }

    function test_emergencyRateUpdate_emitsEvent() public {
        uint64 newRate = 0.8e18;

        vm.expectEmit(false, false, false, true);
        emit Accountant.EmergencyRateUpdated(INITIAL_RATE, newRate, block.timestamp);

        vm.prank(admin);
        accountant.emergencyRateUpdate(newRate);
    }

    function test_emergencyRateUpdate_revertsWhenNotAdmin() public {
        bytes32 adminRole = accountant.DEFAULT_ADMIN_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, adminRole)
        );
        vm.prank(user);
        accountant.emergencyRateUpdate(0.5e18);
    }

    function test_emergencyRateUpdate_revertsWhenExecutorCalls() public {
        bytes32 adminRole = accountant.DEFAULT_ADMIN_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, executor, adminRole)
        );
        vm.prank(executor);
        accountant.emergencyRateUpdate(0.5e18);
    }

    function test_emergencyRateUpdate_revertsWhenRateIsZero() public {
        vm.expectRevert(Accountant.Accountant__InvalidRate.selector);
        vm.prank(admin);
        accountant.emergencyRateUpdate(0);
    }

    function test_emergencyRateUpdate_bypassesDeviationCheck() public {
        uint64 crashRate = 0.5e18; // 50% drop — would revert on updateExchangeRate
        vm.prank(admin);
        accountant.emergencyRateUpdate(crashRate);

        assertEq(accountant.lastExchangeRate(), crashRate);
    }

    function test_emergencyRateUpdate_bypassesCooldown() public {
        // No cooldown skip — call immediately after setUp (timestamp = 1000)
        vm.prank(admin);
        accountant.emergencyRateUpdate(0.99e18);

        assertEq(accountant.lastExchangeRate(), 0.99e18);
    }

    function test_emergencyRateUpdate_unpausesWhenAlreadyPaused() public {
        vm.prank(pauser);
        accountant.pause();
        assertTrue(accountant.paused());

        vm.prank(admin);
        accountant.emergencyRateUpdate(0.8e18);

        assertFalse(accountant.paused());
        assertEq(accountant.lastExchangeRate(), 0.8e18);
    }

    function test_emergencyRateUpdate_worksWhenNotPaused() public {
        assertFalse(accountant.paused());

        vm.prank(admin);
        accountant.emergencyRateUpdate(0.8e18);

        assertFalse(accountant.paused());
        assertEq(accountant.lastExchangeRate(), 0.8e18);
    }

    function test_emergencyRateUpdate_doesNotSettleFees() public {
        uint256 totalShares = 100_000e18;
        vault.setTotalSupply(totalShares);

        // Prime the fee snapshot via an explicit settle first
        skip(1);
        _settleFee();
        assertEq(accountant.totalSharesLastSettle(), totalShares);

        uint256 settleTimestampBefore = accountant.lastFeeSettleTimestamp();
        uint256 feeMintCallsBefore = vault.totalFeeMintCalls();

        // Advance time so fees would otherwise accrue
        vm.warp(block.timestamp + 30 days);

        vm.prank(admin);
        accountant.emergencyRateUpdate(0.5e18);

        // Fees must NOT be settled inside the emergency path; settlement is decoupled
        // and must be triggered explicitly via settleManagementFee().
        assertEq(vault.totalFeeMintCalls(), feeMintCallsBefore, "no fee mint should occur");
        assertEq(accountant.lastFeeSettleTimestamp(), settleTimestampBefore, "settle timestamp unchanged");
        assertEq(accountant.totalSharesLastSettle(), totalShares, "share snapshot unchanged");
    }

    function test_emergencyRateUpdate_blocksNormalUpdateAfterwards() public {
        vm.prank(admin);
        accountant.emergencyRateUpdate(0.5e18);

        // Normal update with 100% deviation triggers circuit breaker → pause
        _skipCooldown();
        _doUpdate(1e18);
        assertTrue(accountant.paused());
        assertEq(accountant.lastExchangeRate(), 0.5e18, "Rate should NOT be overwritten");
    }

    function testFuzz_emergencyRateUpdate(uint64 newRate) public {
        newRate = uint64(bound(newRate, 1, type(uint64).max));

        vm.prank(admin);
        accountant.emergencyRateUpdate(newRate);

        assertEq(accountant.lastExchangeRate(), newRate);
        assertEq(accountant.lastUpdateTimestamp(), block.timestamp);
        assertEq(accountant.lastComputeTimestamp(), block.timestamp);
    }

    // =============================================================
    //                    SET VAULT
    // =============================================================

    function test_setVault_succeeds() public {
        address newVault = makeAddr("newVault");

        vm.prank(admin);
        accountant.setVault(newVault);

        assertEq(address(accountant.vault()), newVault);
    }

    function test_setVault_emitsEvent() public {
        address newVault = makeAddr("newVault");

        vm.expectEmit(true, true, false, false);
        emit Accountant.VaultUpdated(address(vault), newVault);

        vm.prank(admin);
        accountant.setVault(newVault);
    }

    function test_setVault_revertsWhenZero() public {
        vm.expectRevert(Accountant.Accountant__ZeroAddress.selector);
        vm.prank(admin);
        accountant.setVault(address(0));
    }

    function test_setVault_revertsWhenNotAdmin() public {
        bytes32 adminRole = accountant.DEFAULT_ADMIN_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, adminRole)
        );
        vm.prank(user);
        accountant.setVault(makeAddr("v"));
    }

    // =============================================================
    //                    SET RISK PARAMS
    // =============================================================

    function test_setRiskParams_succeeds() public {
        vm.prank(admin);
        accountant.setRiskParams(200, 12 hours);

        assertEq(accountant.maxAllowedDeviation(), 200);
        assertEq(accountant.minUpdateInterval(), 12 hours);
    }

    function test_setRiskParams_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit Accountant.RiskParamsUpdated(200, 12 hours);

        vm.prank(admin);
        accountant.setRiskParams(200, 12 hours);
    }

    function test_setRiskParams_revertsWhenIntervalBelowFloor() public {
        uint32 tooShort = accountant.MIN_UPDATE_INTERVAL_FLOOR() - 1;

        vm.expectRevert(abi.encodeWithSelector(Accountant.Accountant__InvalidUpdateInterval.selector, tooShort));
        vm.prank(admin);
        accountant.setRiskParams(100, tooShort);
    }

    function test_setRiskParams_revertsWhenIntervalZero() public {
        vm.expectRevert(abi.encodeWithSelector(Accountant.Accountant__InvalidUpdateInterval.selector, uint32(0)));
        vm.prank(admin);
        accountant.setRiskParams(100, 0);
    }

    function test_setRiskParams_succeedsAtMinUpdateIntervalFloor() public {
        uint32 minInterval = accountant.MIN_UPDATE_INTERVAL_FLOOR();

        vm.prank(admin);
        accountant.setRiskParams(100, minInterval);
        assertEq(accountant.minUpdateInterval(), minInterval);
    }

    function test_setRiskParams_revertsWhenDeviationZero() public {
        vm.expectRevert(abi.encodeWithSelector(Accountant.Accountant__InvalidDeviation.selector, 0));
        vm.prank(admin);
        accountant.setRiskParams(0, 12 hours);
    }

    function test_setRiskParams_revertsWhenDeviationExceedsCeiling() public {
        uint32 tooHigh = accountant.MAX_DEVIATION_CEILING() + 1;

        vm.expectRevert(abi.encodeWithSelector(Accountant.Accountant__InvalidDeviation.selector, tooHigh));
        vm.prank(admin);
        accountant.setRiskParams(tooHigh, 12 hours);
    }

    function test_setRiskParams_succeedsAtMaxDeviationCeiling() public {
        uint32 maxDev = accountant.MAX_DEVIATION_CEILING();

        vm.prank(admin);
        accountant.setRiskParams(maxDev, 1 hours);
        assertEq(accountant.maxAllowedDeviation(), maxDev);
    }

    function test_setRiskParams_succeedsAtMaxUpdateIntervalCeiling() public {
        uint32 maxInterval = accountant.MAX_UPDATE_INTERVAL_CEILING();

        vm.prank(admin);
        accountant.setRiskParams(100, maxInterval);
        assertEq(accountant.minUpdateInterval(), maxInterval);
    }

    function test_setRiskParams_revertsWhenIntervalExceedsCeiling() public {
        uint32 tooLong = accountant.MAX_UPDATE_INTERVAL_CEILING() + 1;

        vm.expectRevert(abi.encodeWithSelector(Accountant.Accountant__InvalidUpdateInterval.selector, tooLong));
        vm.prank(admin);
        accountant.setRiskParams(100, tooLong);
    }

    function test_setRiskParams_revertsWhenNotAdmin() public {
        bytes32 adminRole = accountant.DEFAULT_ADMIN_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, adminRole)
        );
        vm.prank(user);
        accountant.setRiskParams(200, 12 hours);
    }

    function test_setRiskParams_affectsDeviationCheck() public {
        uint32 floor = accountant.MIN_UPDATE_INTERVAL_FLOOR();

        vm.prank(admin);
        accountant.setRiskParams(200, floor);

        // 2% deviation now accepted
        vm.warp(block.timestamp + floor + 1);
        _doUpdate(1.02e18);
        assertEq(accountant.lastExchangeRate(), 1.02e18);
    }

    function test_setRiskParams_affectsCooldown() public {
        vm.prank(admin);
        accountant.setRiskParams(100, 1 hours);

        vm.warp(block.timestamp + 1 hours);
        _doUpdate(1.005e18);
        assertEq(accountant.lastExchangeRate(), 1.005e18);
    }

    // =============================================================
    //                  SET MAX COMPUTE AGE
    // =============================================================

    function test_setMaxComputeAge_succeeds() public {
        vm.prank(admin);
        accountant.setMaxComputeAge(10 minutes);

        assertEq(accountant.maxComputeAge(), 10 minutes);
    }

    function test_setMaxComputeAge_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit Accountant.MaxComputeAgeUpdated(5 minutes, 10 minutes);

        vm.prank(admin);
        accountant.setMaxComputeAge(10 minutes);
    }

    function test_setMaxComputeAge_revertsWhenZero() public {
        vm.expectRevert(abi.encodeWithSelector(Accountant.Accountant__InvalidComputeAge.selector, 0));
        vm.prank(admin);
        accountant.setMaxComputeAge(0);
    }

    function test_setMaxComputeAge_revertsWhenExceedsCeiling() public {
        uint32 tooOld = accountant.MAX_COMPUTE_AGE_CEILING() + 1;

        vm.expectRevert(abi.encodeWithSelector(Accountant.Accountant__InvalidComputeAge.selector, tooOld));
        vm.prank(admin);
        accountant.setMaxComputeAge(tooOld);
    }

    function test_setMaxComputeAge_succeedsAtCeiling() public {
        uint32 ceiling = accountant.MAX_COMPUTE_AGE_CEILING();

        vm.prank(admin);
        accountant.setMaxComputeAge(ceiling);
        assertEq(accountant.maxComputeAge(), ceiling);
    }

    function test_setMaxComputeAge_revertsWhenNotAdmin() public {
        bytes32 adminRole = accountant.DEFAULT_ADMIN_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, adminRole)
        );
        vm.prank(user);
        accountant.setMaxComputeAge(10 minutes);
    }

    // =============================================================
    //                  SET MANAGEMENT FEE RATE
    // =============================================================

    function test_setManagementFeeRate_succeeds() public {
        vm.prank(admin);
        accountant.setManagementFeeRate(100);

        assertEq(accountant.managementFeeRate(), 100);
    }

    function test_setManagementFeeRate_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit Accountant.ManagementFeeRateUpdated(MANAGEMENT_FEE_BPS, 100);

        vm.prank(admin);
        accountant.setManagementFeeRate(100);
    }

    function test_setManagementFeeRate_allowsZero() public {
        vm.prank(admin);
        accountant.setManagementFeeRate(0);
        assertEq(accountant.managementFeeRate(), 0);
    }

    function test_setManagementFeeRate_revertsWhenExceedsCap() public {
        uint32 tooHigh = accountant.MAX_MANAGEMENT_FEE_BPS() + 1;

        vm.expectRevert(abi.encodeWithSelector(Accountant.Accountant__InvalidFeeRate.selector, tooHigh));
        vm.prank(admin);
        accountant.setManagementFeeRate(tooHigh);
    }

    function test_setManagementFeeRate_succeedsAtMaxCap() public {
        uint32 maxFee = accountant.MAX_MANAGEMENT_FEE_BPS();

        vm.prank(admin);
        accountant.setManagementFeeRate(maxFee);
        assertEq(accountant.managementFeeRate(), maxFee);
    }

    function test_setManagementFeeRate_revertsWhenNotAdmin() public {
        bytes32 adminRole = accountant.DEFAULT_ADMIN_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, adminRole)
        );
        vm.prank(user);
        accountant.setManagementFeeRate(100);
    }

    // =============================================================
    //                    PAUSE / UNPAUSE
    // =============================================================

    function test_pause_succeeds() public {
        vm.prank(pauser);
        accountant.pause();
        assertTrue(accountant.paused());
    }

    function test_pause_adminCannotPause() public {
        bytes32 role = accountant.PAUSER_ROLE();

        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, role));
        vm.prank(admin);
        accountant.pause();
    }

    function test_pause_revertsWhenNotPauser() public {
        bytes32 role = accountant.PAUSER_ROLE();

        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, role));
        vm.prank(user);
        accountant.pause();
    }

    function test_unpause_succeeds() public {
        vm.prank(pauser);
        accountant.pause();

        vm.prank(admin);
        accountant.unpause();
        assertFalse(accountant.paused());
    }

    function test_unpause_revertsWhenNotAdmin() public {
        vm.prank(pauser);
        accountant.pause();

        bytes32 adminRole = accountant.DEFAULT_ADMIN_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, pauser, adminRole)
        );
        vm.prank(pauser);
        accountant.unpause();
    }

    function test_unpause_revertsWhenExecutorCalls() public {
        vm.prank(pauser);
        accountant.pause();

        bytes32 adminRole = accountant.DEFAULT_ADMIN_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, executor, adminRole)
        );
        vm.prank(executor);
        accountant.unpause();
    }

    // =============================================================
    //                      CONSTANTS
    // =============================================================

    function test_constants() public view {
        assertEq(accountant.MAX_BPS(), 10_000);
        assertEq(accountant.RATE_PRECISION(), 1e18);
        assertEq(accountant.MAX_DEVIATION_CEILING(), 1000);
        assertEq(accountant.MAX_MANAGEMENT_FEE_BPS(), 500);
        assertEq(accountant.MAX_COMPUTE_AGE_CEILING(), 1 days);
        assertEq(accountant.MAX_UPDATE_INTERVAL_CEILING(), 7 days);
        assertEq(accountant.MIN_UPDATE_INTERVAL_FLOOR(), 1 minutes);
    }

    // =============================================================
    //                      FUZZ TESTS
    // =============================================================

    function testFuzz_updateWithinDeviation(uint256 rateDelta) public {
        uint256 maxDev = accountant.maxAllowedDeviation();
        rateDelta = bound(rateDelta, 0, (INITIAL_RATE * maxDev) / 10_000);

        _skipCooldown();

        uint64 newRate = uint64(INITIAL_RATE + rateDelta);
        _doUpdate(newRate);
        assertEq(accountant.lastExchangeRate(), newRate);
    }

    function testFuzz_pausesOutsideDeviation(uint256 rateDelta) public {
        uint256 maxDev = accountant.maxAllowedDeviation();
        uint256 minBadDelta = (INITIAL_RATE * (maxDev + 1)) / 10_000;
        rateDelta = bound(rateDelta, minBadDelta, INITIAL_RATE / 2);

        _skipCooldown();

        uint64 newRate = uint64(INITIAL_RATE + rateDelta);

        _doUpdate(newRate);

        assertTrue(accountant.paused());
        assertEq(accountant.lastExchangeRate(), INITIAL_RATE, "Rate should NOT be updated");
    }

    function testFuzz_setManagementFeeRate(uint256 rate) public {
        rate = bound(rate, 0, accountant.MAX_MANAGEMENT_FEE_BPS());

        vm.prank(admin);
        accountant.setManagementFeeRate(uint32(rate));
        assertEq(accountant.managementFeeRate(), rate);
    }

    function testFuzz_setMaxComputeAge(uint256 age) public {
        age = bound(age, 1, accountant.MAX_COMPUTE_AGE_CEILING());

        vm.prank(admin);
        accountant.setMaxComputeAge(uint32(age));
        assertEq(accountant.maxComputeAge(), age);
    }

    function testFuzz_setRiskParams(uint256 deviation, uint256 interval) public {
        deviation = bound(deviation, 1, accountant.MAX_DEVIATION_CEILING());
        interval = bound(interval, accountant.MIN_UPDATE_INTERVAL_FLOOR(), accountant.MAX_UPDATE_INTERVAL_CEILING());

        vm.prank(admin);
        accountant.setRiskParams(uint32(deviation), uint32(interval));
        assertEq(accountant.maxAllowedDeviation(), deviation);
        assertEq(accountant.minUpdateInterval(), interval);
    }

    function testFuzz_feeCalculation(uint256 totalShares, uint256 feeBps) public {
        totalShares = bound(totalShares, 1e18, 1_000_000_000e18);
        feeBps = bound(feeBps, 1, accountant.MAX_MANAGEMENT_FEE_BPS());

        vault.setTotalSupply(totalShares);

        vm.prank(admin);
        accountant.setManagementFeeRate(uint32(feeBps));

        // First call primes snapshot
        skip(1);
        _settleFee();

        // Second call settles fees
        skip(20 hours);
        uint256 elapsed = block.timestamp - accountant.lastFeeSettleTimestamp();

        _settleFee();

        uint256 expectedShares = (totalShares * feeBps * elapsed) / (10_000 * 365 days);

        assertEq(vault.lastFeeShares(), expectedShares);
    }

    function testFuzz_initialize_validFeeRange(uint256 feeBps) public {
        feeBps = bound(feeBps, 0, accountant.MAX_MANAGEMENT_FEE_BPS());

        BeaconProxy proxy = new BeaconProxy(address(beacon), _initData(address(vault), INITIAL_RATE, uint32(feeBps)));
        assertEq(Accountant(address(proxy)).managementFeeRate(), feeBps);
    }
}

// =============================================================
//          ACCOUNTANT EXECUTOR UNIT TESTS (Mock Accountant)
// =============================================================

contract AccountantExecutorTest is Test {
    AccountantExecutor public executor;
    MockAccountant public mockAccountant;
    UpgradeableBeacon public beacon;

    address public admin = makeAddr("admin");
    address public bot = makeAddr("bot");
    address public feeSettler = makeAddr("feeSettler");
    address public user = makeAddr("user");

    function setUp() public {
        mockAccountant = new MockAccountant();

        AccountantExecutor impl = new AccountantExecutor();
        beacon = new UpgradeableBeacon(address(impl), admin);
        BeaconProxy proxy = new BeaconProxy(address(beacon), abi.encodeCall(AccountantExecutor.initialize, (admin)));
        executor = AccountantExecutor(address(proxy));

        bytes32 executeRole = executor.BOT_ROLE();
        bytes32 feeSettlerRole = executor.FEE_SETTLER_ROLE();
        vm.prank(admin);
        executor.grantRole(executeRole, bot);
        vm.prank(admin);
        executor.grantRole(feeSettlerRole, feeSettler);
    }

    // =============================================================
    //                  INITIALIZER TESTS
    // =============================================================

    function test_initialize_setsStateCorrectly() public view {
        assertTrue(executor.hasRole(executor.DEFAULT_ADMIN_ROLE(), admin));
        assertEq(executor.getRoleAdmin(executor.BOT_ROLE()), executor.DEFAULT_ADMIN_ROLE());
        assertEq(executor.getRoleAdmin(executor.FEE_SETTLER_ROLE()), executor.DEFAULT_ADMIN_ROLE());
        assertEq(executor.getRoleAdmin(executor.DEFAULT_ADMIN_ROLE()), executor.DEFAULT_ADMIN_ROLE());
    }

    function test_initialize_revertsOnDoubleInit() public {
        vm.expectRevert();
        executor.initialize(admin);
    }

    function test_initialize_revertsWhenAdminIsZero() public {
        vm.expectRevert(AccountantExecutor.AccountantExecutor__ZeroAddress.selector);
        new BeaconProxy(address(beacon), abi.encodeCall(AccountantExecutor.initialize, (address(0))));
    }

    // =============================================================
    //                    UPGRADE TESTS
    // =============================================================

    function test_upgrade_succeeds() public {
        AccountantExecutor newImpl = new AccountantExecutor();

        vm.prank(admin);
        beacon.upgradeTo(address(newImpl));

        assertEq(beacon.implementation(), address(newImpl));
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
        uint64 newRate = 1.005e18;
        uint64 computeTs = uint64(block.timestamp);

        vm.prank(bot);
        executor.executeUpdateRate(address(mockAccountant), newRate, computeTs);

        assertEq(mockAccountant.lastNewRate(), newRate);
        assertEq(mockAccountant.lastComputeTimestamp(), computeTs);
        assertEq(mockAccountant.callCount(), 1);
    }

    function test_executeUpdateRate_emitsEvent() public {
        uint64 newRate = 1.005e18;
        uint64 computeTs = uint64(block.timestamp);

        vm.expectEmit(true, false, false, true);
        emit AccountantExecutor.RateUpdateExecuted(bot, newRate, computeTs);

        vm.prank(bot);
        executor.executeUpdateRate(address(mockAccountant), newRate, computeTs);
    }

    function test_executeUpdateRate_consecutiveCalls() public {
        vm.prank(bot);
        executor.executeUpdateRate(address(mockAccountant), 1.001e18, uint64(block.timestamp));

        vm.prank(bot);
        executor.executeUpdateRate(address(mockAccountant), 1.002e18, uint64(block.timestamp + 1));

        assertEq(mockAccountant.lastNewRate(), 1.002e18);
        assertEq(mockAccountant.lastComputeTimestamp(), block.timestamp + 1);
        assertEq(mockAccountant.callCount(), 2);
    }

    // =============================================================
    //                  REVERT TESTS
    // =============================================================

    function test_executeUpdateRate_revertsWhenNotExecuteRole() public {
        bytes32 role = executor.BOT_ROLE();

        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, role));
        vm.prank(user);
        executor.executeUpdateRate(address(mockAccountant), 1e18, uint64(block.timestamp));
    }

    function test_executeUpdateRate_revertsWhenAdminWithoutExecuteRole() public {
        bytes32 role = executor.BOT_ROLE();

        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, role));
        vm.prank(admin);
        executor.executeUpdateRate(address(mockAccountant), 1e18, uint64(block.timestamp));
    }

    function test_executeUpdateRate_revertsWhenAccountantIsZero() public {
        vm.expectRevert(AccountantExecutor.AccountantExecutor__ZeroAddress.selector);
        vm.prank(bot);
        executor.executeUpdateRate(address(0), 1e18, uint64(block.timestamp));
    }

    // =============================================================
    //              EXECUTE SETTLE MANAGEMENT FEE TESTS
    // =============================================================

    function test_executeSettleManagementFee_succeedsWithFeeSettlerRole() public {
        vm.prank(feeSettler);
        executor.executeSettleManagementFee(address(mockAccountant));

        assertEq(mockAccountant.settleCallCount(), 1);
    }

    function test_executeSettleManagementFee_revertsWhenOnlyBotRole() public {
        bytes32 role = executor.FEE_SETTLER_ROLE();

        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bot, role));
        vm.prank(bot);
        executor.executeSettleManagementFee(address(mockAccountant));
    }

    function test_executeSettleManagementFee_revertsWhenAccountantIsZero() public {
        vm.expectRevert(AccountantExecutor.AccountantExecutor__ZeroAddress.selector);
        vm.prank(feeSettler);
        executor.executeSettleManagementFee(address(0));
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
        executor.executeUpdateRate(address(mockAccountant), 1e18, uint64(block.timestamp));
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

    function testFuzz_executeUpdateRate(uint64 newRate, uint64 computeTs) public {
        newRate = uint64(bound(newRate, 1, type(uint64).max));
        computeTs = uint64(bound(computeTs, 1, type(uint64).max));

        vm.prank(bot);
        executor.executeUpdateRate(address(mockAccountant), newRate, computeTs);

        assertEq(mockAccountant.lastNewRate(), newRate);
        assertEq(mockAccountant.lastComputeTimestamp(), computeTs);
    }
}

// =============================================================
//        ACCOUNTANT EXECUTOR INTEGRATION TESTS (Real Accountant)
// =============================================================

contract AccountantExecutorIntegrationTest is Test {
    AccountantExecutor public executor;
    Accountant public accountant;
    MockVault public vault;
    UpgradeableBeacon public accBeacon;
    UpgradeableBeacon public execBeacon;

    address public admin = makeAddr("admin");
    address public bot = makeAddr("bot");
    address public feeSettler = makeAddr("feeSettler");
    address public pauser = makeAddr("pauser");

    uint64 public constant INITIAL_RATE = 1e18;
    uint32 public constant MANAGEMENT_FEE_BPS = 50; // 0.5%

    function setUp() public {
        vm.warp(1000); // anchor a non-zero starting timestamp

        vault = new MockVault();

        AccountantExecutor execImpl = new AccountantExecutor();
        execBeacon = new UpgradeableBeacon(address(execImpl), admin);
        BeaconProxy execProxy =
            new BeaconProxy(address(execBeacon), abi.encodeCall(AccountantExecutor.initialize, (admin)));
        executor = AccountantExecutor(address(execProxy));

        Accountant accImpl = new Accountant();
        accBeacon = new UpgradeableBeacon(address(accImpl), admin);
        BeaconProxy accProxy = new BeaconProxy(
            address(accBeacon),
            abi.encodeCall(
                Accountant.initialize,
                (address(vault), INITIAL_RATE, MANAGEMENT_FEE_BPS, admin, pauser, address(executor))
            )
        );
        accountant = Accountant(address(accProxy));

        vm.startPrank(admin);
        executor.grantRole(executor.BOT_ROLE(), bot);
        executor.grantRole(executor.FEE_SETTLER_ROLE(), feeSettler);
        vm.stopPrank();
    }

    // ── helpers ───────────────────────────────────────────────────

    function _skipCooldown() internal {
        vm.warp(block.timestamp + accountant.minUpdateInterval() + 1);
    }

    function _executeUpdate(uint64 newRate) internal {
        vm.prank(bot);
        executor.executeUpdateRate(address(accountant), newRate, uint64(block.timestamp));
    }

    function _settleFee() internal {
        vm.prank(feeSettler);
        executor.executeSettleManagementFee(address(accountant));
    }

    function _pauseViaExecutor() internal {
        vm.prank(bot);
        executor.executePause(address(accountant));
    }

    // =============================================================
    //                    HAPPY-PATH TESTS
    // =============================================================

    function test_integration_fullFlow() public {
        _skipCooldown();

        uint64 newRate = 1.005e18;
        uint64 computeTs = uint64(block.timestamp);

        vm.prank(bot);
        executor.executeUpdateRate(address(accountant), newRate, computeTs);

        assertEq(accountant.lastExchangeRate(), newRate);
        assertEq(accountant.getRate(), newRate);
        assertEq(accountant.lastComputeTimestamp(), computeTs);
    }

    function test_integration_consecutiveUpdates() public {
        _skipCooldown();

        uint64 computeTs1 = uint64(block.timestamp);
        vm.prank(bot);
        executor.executeUpdateRate(address(accountant), 1.005e18, computeTs1);

        uint64 computeTs2 = computeTs1 + uint64(accountant.minUpdateInterval()) + 1;
        vm.warp(computeTs2);

        vm.prank(bot);
        executor.executeUpdateRate(address(accountant), 1.009e18, computeTs2);

        assertEq(accountant.lastExchangeRate(), 1.009e18);
        assertEq(accountant.lastComputeTimestamp(), computeTs2);
    }

    function test_integration_emitsExchangeRateUpdatedEvent() public {
        _skipCooldown();

        uint64 newRate = 1.005e18;

        vm.expectEmit(false, false, false, true);
        emit Accountant.ExchangeRateUpdated(INITIAL_RATE, newRate, block.timestamp);

        _executeUpdate(newRate);
    }

    // =============================================================
    //                  COOLDOWN CIRCUIT BREAKER
    // =============================================================

    function test_integration_revertsWhenCooldownNotElapsed() public {
        vm.prank(bot);
        vm.expectRevert();
        executor.executeUpdateRate(address(accountant), 1.005e18, uint64(block.timestamp));
    }

    function test_integration_succeedsAtExactCooldownBoundary() public {
        uint256 interval = accountant.minUpdateInterval();
        vm.warp(block.timestamp + interval);

        _executeUpdate(1.005e18);
        assertEq(accountant.lastExchangeRate(), 1.005e18);
    }

    // =============================================================
    //                  DEVIATION CIRCUIT BREAKER
    // =============================================================

    function test_integration_pausesWhenDeviationExceeded() public {
        _skipCooldown();

        uint64 tooHighRate = 1.02e18;

        vm.expectEmit(false, false, false, true);
        emit Accountant.CircuitBreakerTriggered(200, accountant.maxAllowedDeviation(), tooHighRate);

        _executeUpdate(tooHighRate);

        assertTrue(accountant.paused());
        assertEq(accountant.lastExchangeRate(), INITIAL_RATE, "Rate should NOT be updated");
    }

    function test_integration_pausesWhenDeviationExceeded_rateDrops() public {
        _skipCooldown();

        uint64 tooLowRate = 0.98e18;

        vm.expectEmit(false, false, false, true);
        emit Accountant.CircuitBreakerTriggered(200, accountant.maxAllowedDeviation(), tooLowRate);

        _executeUpdate(tooLowRate);

        assertTrue(accountant.paused());
        assertEq(accountant.lastExchangeRate(), INITIAL_RATE, "Rate should NOT be updated");
    }

    function test_integration_succeedsAtMaxDeviationBoundary() public {
        _skipCooldown();

        // Exactly 1% deviation (100 bps) should pass
        uint64 boundaryRate = 1.01e18;
        _executeUpdate(boundaryRate);
        assertEq(accountant.lastExchangeRate(), boundaryRate);
    }

    // =============================================================
    //              COMPUTE TIMESTAMP VALIDATION
    // =============================================================

    function test_integration_revertsWhenComputeTimestampStale() public {
        _skipCooldown();

        uint64 computeTs1 = uint64(block.timestamp);
        vm.prank(bot);
        executor.executeUpdateRate(address(accountant), 1.005e18, computeTs1);

        _skipCooldown();

        // Use same timestamp as before → stale
        vm.expectRevert(
            abi.encodeWithSelector(Accountant.Accountant__StaleComputeTimestamp.selector, computeTs1, computeTs1)
        );
        vm.prank(bot);
        executor.executeUpdateRate(address(accountant), 1.006e18, computeTs1);
    }

    function test_integration_revertsWhenComputeTimestampInFuture() public {
        _skipCooldown();

        uint64 futureTs = uint64(block.timestamp + 1);

        vm.expectRevert(
            abi.encodeWithSelector(Accountant.Accountant__FutureComputeTimestamp.selector, futureTs, block.timestamp)
        );
        vm.prank(bot);
        executor.executeUpdateRate(address(accountant), 1.005e18, futureTs);
    }

    function test_integration_revertsWhenComputeTimestampTooOld() public {
        _skipCooldown();

        uint256 maxAge = accountant.maxComputeAge();
        uint64 staleTs = uint64(block.timestamp - maxAge - 1);
        // staleTs must be > lastComputeTimestamp (0), which is true since block.timestamp is large
        vm.expectRevert(
            abi.encodeWithSelector(
                Accountant.Accountant__ComputeTimestampTooOld.selector, staleTs, block.timestamp, maxAge
            )
        );
        vm.prank(bot);
        executor.executeUpdateRate(address(accountant), 1.005e18, staleTs);
    }

    // =============================================================
    //                  ZERO-VALUE VALIDATION
    // =============================================================

    function test_integration_revertsWhenRateIsZero() public {
        _skipCooldown();

        vm.expectRevert(Accountant.Accountant__InvalidRate.selector);
        _executeUpdate(0);
    }

    // =============================================================
    //                    FEE SETTLEMENT
    // =============================================================
    //
    // Note: settleManagementFee semantics are exhaustively covered by the
    // unit tests in AccountantTest. The cases below only check that the
    // separate fee-settlement path operates correctly on a fully-wired
    // proxy (real Accountant + AccountantExecutor in the same suite).
    //
    function test_integration_settleManagementFee() public {
        uint256 totalShares = 100_000e18;
        vault.setTotalSupply(totalShares);

        // First settle primes the snapshot
        skip(1);
        _settleFee();
        assertEq(vault.totalFeeMintCalls(), 0, "First settle primes snapshot, no mint (snapshot was 0)");
        assertEq(accountant.totalSharesLastSettle(), totalShares);

        // Second settle should mint fees
        skip(20 hours);

        uint256 timeElapsed = block.timestamp - accountant.lastFeeSettleTimestamp();
        uint256 expectedShares = (totalShares * MANAGEMENT_FEE_BPS * timeElapsed) / (10_000 * 365 days);

        vm.expectEmit(false, false, false, true);
        emit Accountant.FeesDistributed(expectedShares);

        _settleFee();

        assertEq(vault.lastFeeShares(), expectedShares);
        assertEq(vault.totalFeeMintCalls(), 1);
    }

    // =============================================================
    //                    PAUSE / UNPAUSE
    // =============================================================

    function test_integration_revertsWhenPaused() public {
        _pauseViaExecutor();

        _skipCooldown();

        vm.expectRevert();
        _executeUpdate(1.005e18);
    }

    function test_integration_succeedsAfterUnpause() public {
        _pauseViaExecutor();

        vm.prank(admin);
        accountant.unpause();

        _skipCooldown();

        _executeUpdate(1.005e18);
        assertEq(accountant.lastExchangeRate(), 1.005e18);
    }

    function test_integration_pauseRoleCanPause() public {
        address extraPauser = makeAddr("extraPauser");

        vm.startPrank(admin);
        accountant.grantRole(accountant.PAUSER_ROLE(), extraPauser);
        vm.stopPrank();

        vm.prank(extraPauser);
        accountant.pause();

        _skipCooldown();

        vm.expectRevert();
        _executeUpdate(1.005e18);
    }

    function test_integration_unpauseRequiresAdmin() public {
        vm.prank(pauser);
        accountant.pause();

        bytes32 adminRole = accountant.DEFAULT_ADMIN_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, pauser, adminRole)
        );
        vm.prank(pauser);
        accountant.unpause();
    }

    // =============================================================
    //                 EMERGENCY RATE UPDATE
    // =============================================================

    function test_integration_emergencyRateUpdate_succeeds() public {
        uint64 crashRate = 0.5e18;

        vm.expectEmit(false, false, false, true);
        emit Accountant.EmergencyRateUpdated(INITIAL_RATE, crashRate, block.timestamp);

        vm.prank(admin);
        accountant.emergencyRateUpdate(crashRate);

        assertEq(accountant.lastExchangeRate(), crashRate);
        assertEq(accountant.getRate(), crashRate);
        assertEq(accountant.lastUpdateTimestamp(), block.timestamp);
        assertEq(accountant.lastComputeTimestamp(), block.timestamp);
    }

    function test_integration_emergencyRateUpdate_bypassesDeviationAndCooldown() public {
        // No cooldown skip and 50% drop — both constraints bypassed
        uint64 crashRate = 0.5e18;

        vm.prank(admin);
        accountant.emergencyRateUpdate(crashRate);

        assertEq(accountant.lastExchangeRate(), crashRate);
    }

    function test_integration_emergencyRateUpdate_revertsWhenNotAdmin() public {
        bytes32 adminRole = accountant.DEFAULT_ADMIN_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bot, adminRole)
        );
        vm.prank(bot);
        accountant.emergencyRateUpdate(0.5e18);
    }

    function test_integration_emergencyRateUpdate_unpausesWhenPaused() public {
        _pauseViaExecutor();
        assertTrue(accountant.paused());

        vm.prank(admin);
        accountant.emergencyRateUpdate(0.8e18);

        assertFalse(accountant.paused());
        assertEq(accountant.lastExchangeRate(), 0.8e18);
    }

    function test_integration_emergencyRateUpdate_thenNormalUpdateResumes() public {
        // Emergency crash to 0.99e18
        vm.prank(admin);
        accountant.emergencyRateUpdate(0.99e18);

        // After emergency, normal updates should work within the new rate's deviation band
        _skipCooldown();
        uint64 recoveryRate = 0.995e18; // within 1% of 0.99e18
        _executeUpdate(recoveryRate);
        assertEq(accountant.lastExchangeRate(), recoveryRate);
    }

    function test_integration_emergencyRateUpdate_doesNotSettleFees() public {
        uint256 totalShares = 100_000e18;
        vault.setTotalSupply(totalShares);

        // Prime snapshot via explicit settle (updateExchangeRate no longer settles)
        skip(1);
        _settleFee();

        uint256 settleTimestampBefore = accountant.lastFeeSettleTimestamp();
        uint256 feeMintCallsBefore = vault.totalFeeMintCalls();

        // Advance time so fees would otherwise accrue
        vm.warp(block.timestamp + 30 days);

        vm.prank(admin);
        accountant.emergencyRateUpdate(0.5e18);

        // emergencyRateUpdate is decoupled from fee settlement; admin must call
        // settleManagementFee() (or relay via AccountantExecutor) explicitly.
        assertEq(vault.totalFeeMintCalls(), feeMintCallsBefore, "no fee mint should occur");
        assertEq(accountant.lastFeeSettleTimestamp(), settleTimestampBefore, "settle timestamp unchanged");
        assertEq(accountant.totalSharesLastSettle(), totalShares, "share snapshot unchanged");
    }

    // =============================================================
    //                  ADMIN SETTER FUNCTIONS
    // =============================================================

    function test_integration_setRiskParams() public {
        vm.prank(admin);
        accountant.setRiskParams(200, 12 hours);

        assertEq(accountant.maxAllowedDeviation(), 200);
        assertEq(accountant.minUpdateInterval(), 12 hours);

        // Now 2% deviation should be accepted
        vm.warp(block.timestamp + 12 hours);
        _executeUpdate(1.02e18);
        assertEq(accountant.lastExchangeRate(), 1.02e18);
    }

    function test_integration_setRiskParams_revertsWhenDeviationZero() public {
        vm.expectRevert(abi.encodeWithSelector(Accountant.Accountant__InvalidDeviation.selector, 0));
        vm.prank(admin);
        accountant.setRiskParams(0, 12 hours);
    }

    function test_integration_setRiskParams_revertsWhenDeviationExceedsCeiling() public {
        uint32 tooHigh = accountant.MAX_DEVIATION_CEILING() + 1;
        vm.expectRevert(abi.encodeWithSelector(Accountant.Accountant__InvalidDeviation.selector, tooHigh));
        vm.prank(admin);
        accountant.setRiskParams(tooHigh, 12 hours);
    }

    function test_integration_setManagementFeeRate() public {
        vm.expectEmit(false, false, false, true);
        emit Accountant.ManagementFeeRateUpdated(MANAGEMENT_FEE_BPS, 100);

        vm.prank(admin);
        accountant.setManagementFeeRate(100);

        assertEq(accountant.managementFeeRate(), 100);
    }

    function test_integration_setManagementFeeRate_revertsWhenExceedsCap() public {
        uint32 tooHigh = accountant.MAX_MANAGEMENT_FEE_BPS() + 1;
        vm.expectRevert(abi.encodeWithSelector(Accountant.Accountant__InvalidFeeRate.selector, tooHigh));
        vm.prank(admin);
        accountant.setManagementFeeRate(tooHigh);
    }

    function test_integration_setVault() public {
        address newVault = makeAddr("newVault");

        vm.expectEmit(true, true, false, false);
        emit Accountant.VaultUpdated(address(vault), newVault);

        vm.prank(admin);
        accountant.setVault(newVault);

        assertEq(address(accountant.vault()), newVault);
    }

    function test_integration_setVault_revertsWhenZero() public {
        vm.expectRevert(Accountant.Accountant__ZeroAddress.selector);
        vm.prank(admin);
        accountant.setVault(address(0));
    }

    function test_integration_setMaxComputeAge() public {
        uint32 newAge = 10 minutes;

        vm.expectEmit(false, false, false, true);
        emit Accountant.MaxComputeAgeUpdated(5 minutes, newAge);

        vm.prank(admin);
        accountant.setMaxComputeAge(newAge);

        assertEq(accountant.maxComputeAge(), newAge);
    }

    function test_integration_setMaxComputeAge_revertsWhenZero() public {
        vm.expectRevert(abi.encodeWithSelector(Accountant.Accountant__InvalidComputeAge.selector, 0));
        vm.prank(admin);
        accountant.setMaxComputeAge(0);
    }

    function test_integration_setMaxComputeAge_revertsWhenExceedsCeiling() public {
        uint32 tooOld = accountant.MAX_COMPUTE_AGE_CEILING() + 1;
        vm.expectRevert(abi.encodeWithSelector(Accountant.Accountant__InvalidComputeAge.selector, tooOld));
        vm.prank(admin);
        accountant.setMaxComputeAge(tooOld);
    }

    // =============================================================
    //              ADMIN SETTER ACCESS CONTROL
    // =============================================================

    function test_integration_settersFail_fromNonAdmin() public {
        bytes32 adminRole = accountant.DEFAULT_ADMIN_ROLE();

        vm.startPrank(bot);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bot, adminRole)
        );
        accountant.setRiskParams(200, 12 hours);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bot, adminRole)
        );
        accountant.setManagementFeeRate(100);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bot, adminRole)
        );
        accountant.setVault(makeAddr("v"));

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bot, adminRole)
        );
        accountant.setMaxComputeAge(10 minutes);

        vm.stopPrank();
    }

    // =============================================================
    //                      FUZZ TESTS
    // =============================================================

    function testFuzz_integration_updateWithinDeviation(uint256 rateDelta) public {
        uint256 maxDev = accountant.maxAllowedDeviation();
        rateDelta = bound(rateDelta, 0, (INITIAL_RATE * maxDev) / 10_000);

        _skipCooldown();

        uint64 newRate = uint64(INITIAL_RATE + rateDelta);
        _executeUpdate(newRate);
        assertEq(accountant.lastExchangeRate(), newRate);
    }

    function testFuzz_integration_pausesOutsideDeviation(uint256 rateDelta) public {
        uint256 maxDev = accountant.maxAllowedDeviation();
        uint256 minBadDelta = (INITIAL_RATE * (maxDev + 1)) / 10_000;
        rateDelta = bound(rateDelta, minBadDelta, INITIAL_RATE / 2);

        _skipCooldown();

        uint64 newRate = uint64(INITIAL_RATE + rateDelta);

        _executeUpdate(newRate);

        assertTrue(accountant.paused());
        assertEq(accountant.lastExchangeRate(), INITIAL_RATE, "Rate should NOT be updated");
    }
}
