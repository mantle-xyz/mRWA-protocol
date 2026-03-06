// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Accountant} from "../src/accountant/Accountant.sol";
import {AccountantExecutor} from "../src/accountant/AccountantExecutor.sol";
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
    uint256 public settleManagementFeeCallCount;

    function updateExchangeRate(uint256 newRate, uint256 computeTimestamp) external {
        lastNewRate = newRate;
        lastComputeTimestamp = computeTimestamp;
        callCount++;
    }

    function settleManagementFee() external {
        settleManagementFeeCallCount++;
    }
}

contract MockVault {
    uint256 public exchangeRate;
    uint256 public _totalSupply;

    address public lastFeeTreasury;
    uint256 public lastFeeShares;
    uint256 public totalFeeMintCalls;

    function mintFeeShares(address treasury, uint256 shares) external {
        lastFeeTreasury = treasury;
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
    address public treasuryAddr = makeAddr("treasury");

    uint256 public constant INITIAL_RATE = 1e18;
    uint256 public constant MANAGEMENT_FEE_BPS = 50; // 0.5%

    function setUp() public {
        vm.warp(1000);

        vault = new MockVault();

        Accountant impl = new Accountant();
        beacon = new UpgradeableBeacon(address(impl), admin);
        BeaconProxy proxy = new BeaconProxy(
            address(beacon),
            abi.encodeCall(
                Accountant.initialize, (address(vault), treasuryAddr, INITIAL_RATE, MANAGEMENT_FEE_BPS, admin)
            )
        );
        accountant = Accountant(address(proxy));

        vm.startPrank(admin);
        accountant.grantRole(accountant.EXECUTOR_ROLE(), executor);
        accountant.grantRole(accountant.PAUSER_ROLE(), pauser);
        vm.stopPrank();
    }

    // ── helpers ───────────────────────────────────────────────────

    function _skipCooldown() internal {
        vm.warp(block.timestamp + accountant.minUpdateInterval() + 1);
    }

    function _doUpdate(uint256 newRate) internal {
        vm.prank(executor);
        accountant.updateExchangeRate(newRate, block.timestamp);
    }

    // =============================================================
    //                    INITIALIZER TESTS
    // =============================================================

    function test_initialize_setsStateCorrectly() public view {
        assertEq(address(accountant.vault()), address(vault));
        assertEq(accountant.treasury(), treasuryAddr);
        assertEq(accountant.lastExchangeRate(), INITIAL_RATE);
        assertEq(accountant.managementFeeRate(), MANAGEMENT_FEE_BPS);
        assertEq(accountant.maxAllowedDeviation(), 100);
        assertEq(accountant.minUpdateInterval(), 20 hours);
        assertEq(accountant.maxComputeAge(), 5 minutes);
        assertEq(accountant.lastUpdateTimestamp(), 1000);
        assertEq(accountant.lastFeeSettleTimestamp(), 1000);
        assertEq(accountant.totalSharesLastSettle(), 0);
        assertEq(accountant.lastComputeTimestamp(), 0);
    }

    function test_initialize_setsRolesCorrectly() public view {
        assertTrue(accountant.hasRole(accountant.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(accountant.hasRole(accountant.PAUSER_ROLE(), admin));
        assertTrue(accountant.hasRole(accountant.EXECUTOR_ROLE(), admin));
        assertEq(accountant.getRoleAdmin(accountant.PAUSER_ROLE()), accountant.DEFAULT_ADMIN_ROLE());
        assertEq(accountant.getRoleAdmin(accountant.EXECUTOR_ROLE()), accountant.DEFAULT_ADMIN_ROLE());
    }

    function test_initialize_revertsOnDoubleInit() public {
        vm.expectRevert();
        accountant.initialize(address(vault), treasuryAddr, INITIAL_RATE, MANAGEMENT_FEE_BPS, admin);
    }

    function test_initialize_revertsWhenVaultIsZero() public {
        vm.expectRevert(Accountant.ZeroAddress.selector);
        new BeaconProxy(
            address(beacon),
            abi.encodeCall(Accountant.initialize, (address(0), treasuryAddr, INITIAL_RATE, MANAGEMENT_FEE_BPS, admin))
        );
    }

    function test_initialize_revertsWhenTreasuryIsZero() public {
        vm.expectRevert(Accountant.ZeroAddress.selector);
        new BeaconProxy(
            address(beacon),
            abi.encodeCall(Accountant.initialize, (address(vault), address(0), INITIAL_RATE, MANAGEMENT_FEE_BPS, admin))
        );
    }

    function test_initialize_revertsWhenAdminIsZero() public {
        vm.expectRevert(Accountant.ZeroAddress.selector);
        new BeaconProxy(
            address(beacon),
            abi.encodeCall(
                Accountant.initialize, (address(vault), treasuryAddr, INITIAL_RATE, MANAGEMENT_FEE_BPS, address(0))
            )
        );
    }

    function test_initialize_revertsWhenRateIsZero() public {
        vm.expectRevert(Accountant.InvalidRate.selector);
        new BeaconProxy(
            address(beacon),
            abi.encodeCall(Accountant.initialize, (address(vault), treasuryAddr, 0, MANAGEMENT_FEE_BPS, admin))
        );
    }

    function test_initialize_revertsWhenFeeExceedsCap() public {
        uint256 tooHigh = accountant.MAX_MANAGEMENT_FEE_BPS() + 1;
        vm.expectRevert(abi.encodeWithSelector(Accountant.InvalidFeeRate.selector, tooHigh));
        new BeaconProxy(
            address(beacon),
            abi.encodeCall(Accountant.initialize, (address(vault), treasuryAddr, INITIAL_RATE, tooHigh, admin))
        );
    }

    function test_initialize_allowsZeroFeeRate() public {
        BeaconProxy proxy = new BeaconProxy(
            address(beacon),
            abi.encodeCall(Accountant.initialize, (address(vault), treasuryAddr, INITIAL_RATE, 0, admin))
        );
        assertEq(Accountant(address(proxy)).managementFeeRate(), 0);
    }

    function test_initialize_allowsMaxFeeRate() public {
        uint256 maxFee = accountant.MAX_MANAGEMENT_FEE_BPS();
        BeaconProxy proxy = new BeaconProxy(
            address(beacon),
            abi.encodeCall(Accountant.initialize, (address(vault), treasuryAddr, INITIAL_RATE, maxFee, admin))
        );
        assertEq(Accountant(address(proxy)).managementFeeRate(), maxFee);
    }

    // =============================================================
    //              UPDATE EXCHANGE RATE — HAPPY PATH
    // =============================================================

    function test_updateExchangeRate_succeeds() public {
        _skipCooldown();

        uint256 newRate = 1.005e18;
        _doUpdate(newRate);

        assertEq(accountant.lastExchangeRate(), newRate);
        assertEq(vault.exchangeRate(), newRate);
        assertEq(accountant.lastUpdateTimestamp(), block.timestamp);
        assertEq(accountant.lastComputeTimestamp(), block.timestamp);
    }

    function test_updateExchangeRate_emitsEvent() public {
        _skipCooldown();

        uint256 newRate = 1.005e18;

        vm.expectEmit(false, false, false, true);
        emit Accountant.ExchangeRateUpdated(INITIAL_RATE, newRate, block.timestamp);

        _doUpdate(newRate);
    }

    function test_updateExchangeRate_consecutiveUpdates() public {
        _skipCooldown();

        uint256 computeTs1 = block.timestamp;
        vm.prank(executor);
        accountant.updateExchangeRate(1.005e18, computeTs1);

        _skipCooldown();

        uint256 computeTs2 = block.timestamp;
        vm.prank(executor);
        accountant.updateExchangeRate(1.009e18, computeTs2);

        assertEq(accountant.lastExchangeRate(), 1.009e18);
        assertEq(accountant.lastComputeTimestamp(), computeTs2);
    }

    function test_updateExchangeRate_rateDecrease() public {
        _skipCooldown();

        uint256 newRate = 0.995e18; // 0.5% decrease
        _doUpdate(newRate);
        assertEq(accountant.lastExchangeRate(), newRate);
    }

    // =============================================================
    //              UPDATE EXCHANGE RATE — ACCESS CONTROL
    // =============================================================

    function test_updateExchangeRate_revertsWhenNotExecutor() public {
        _skipCooldown();

        bytes32 role = accountant.EXECUTOR_ROLE();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, role));
        vm.prank(user);
        accountant.updateExchangeRate(1.005e18, block.timestamp);
    }

    function test_updateExchangeRate_revertsWhenCalledByPauser() public {
        _skipCooldown();

        bytes32 role = accountant.EXECUTOR_ROLE();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, pauser, role));
        vm.prank(pauser);
        accountant.updateExchangeRate(1.005e18, block.timestamp);
    }

    // =============================================================
    //              UPDATE EXCHANGE RATE — PAUSED
    // =============================================================

    function test_updateExchangeRate_revertsWhenPaused() public {
        vm.prank(admin);
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

        vm.expectRevert(Accountant.InvalidRate.selector);
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

        vm.expectRevert(abi.encodeWithSelector(Accountant.CooldownNotElapsed.selector, remaining));
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
        accountant.updateExchangeRate(1.006e18, block.timestamp + 1);
    }

    // =============================================================
    //              DEVIATION CIRCUIT BREAKER
    // =============================================================

    function test_updateExchangeRate_revertsWhenDeviationExceeded_up() public {
        _skipCooldown();

        uint256 tooHighRate = 1.02e18; // 2% up, max is 1%
        uint256 deviationBps = 200;

        vm.expectRevert(
            abi.encodeWithSelector(
                Accountant.DeviationExceeded.selector, deviationBps, accountant.maxAllowedDeviation()
            )
        );
        _doUpdate(tooHighRate);
    }

    function test_updateExchangeRate_revertsWhenDeviationExceeded_down() public {
        _skipCooldown();

        uint256 tooLowRate = 0.98e18; // 2% down
        uint256 deviationBps = 200;

        vm.expectRevert(
            abi.encodeWithSelector(
                Accountant.DeviationExceeded.selector, deviationBps, accountant.maxAllowedDeviation()
            )
        );
        _doUpdate(tooLowRate);
    }

    function test_updateExchangeRate_succeedsAtMaxDeviationBoundary() public {
        _skipCooldown();

        uint256 boundaryRate = 1.01e18; // exactly 1% = 100 bps
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

        uint256 computeTs1 = block.timestamp;
        vm.prank(executor);
        accountant.updateExchangeRate(1.005e18, computeTs1);

        _skipCooldown();

        vm.expectRevert(abi.encodeWithSelector(Accountant.StaleComputeTimestamp.selector, computeTs1, computeTs1));
        vm.prank(executor);
        accountant.updateExchangeRate(1.006e18, computeTs1);
    }

    function test_updateExchangeRate_revertsWhenComputeTimestampEqual() public {
        _skipCooldown();

        uint256 computeTs = block.timestamp;
        vm.prank(executor);
        accountant.updateExchangeRate(1.005e18, computeTs);

        _skipCooldown();

        vm.expectRevert(abi.encodeWithSelector(Accountant.StaleComputeTimestamp.selector, computeTs, computeTs));
        vm.prank(executor);
        accountant.updateExchangeRate(1.006e18, computeTs);
    }

    function test_updateExchangeRate_revertsWhenComputeTimestampInFuture() public {
        _skipCooldown();

        uint256 futureTs = block.timestamp + 1;

        vm.expectRevert(abi.encodeWithSelector(Accountant.FutureComputeTimestamp.selector, futureTs, block.timestamp));
        vm.prank(executor);
        accountant.updateExchangeRate(1.005e18, futureTs);
    }

    function test_updateExchangeRate_revertsWhenComputeTimestampTooOld() public {
        _skipCooldown();

        uint256 maxAge = accountant.maxComputeAge();
        uint256 staleTs = block.timestamp - maxAge - 1;

        vm.expectRevert(
            abi.encodeWithSelector(Accountant.ComputeTimestampTooOld.selector, staleTs, block.timestamp, maxAge)
        );
        vm.prank(executor);
        accountant.updateExchangeRate(1.005e18, staleTs);
    }

    function test_updateExchangeRate_succeedsAtMaxComputeAgeBoundary() public {
        _skipCooldown();

        uint256 maxAge = accountant.maxComputeAge();
        uint256 borderTs = block.timestamp - maxAge;

        vm.prank(executor);
        accountant.updateExchangeRate(1.005e18, borderTs);
        assertEq(accountant.lastComputeTimestamp(), borderTs);
    }

    // =============================================================
    //                    FEE SETTLEMENT
    // =============================================================

    function test_settleManagementFee_mintsFeeShares() public {
        uint256 totalShares = 100_000e18;
        vault.setTotalSupply(totalShares);

        // Prime snapshot: totalSharesLastSettle was 0 at init, so first settle
        // uses min(100k, 0) = 0 but updates totalSharesLastSettle to 100k.
        vm.warp(block.timestamp + 1);
        vm.prank(executor);
        accountant.settleManagementFee();
        assertEq(vault.totalFeeMintCalls(), 0, "First settle should mint 0 (snapshot was 0)");

        _skipCooldown();

        uint256 timeElapsed = block.timestamp - accountant.lastFeeSettleTimestamp();
        uint256 expectedShares = (totalShares * MANAGEMENT_FEE_BPS * timeElapsed) / (10_000 * 365 days);

        vm.expectEmit(true, false, false, true);
        emit Accountant.FeesDistributed(treasuryAddr, expectedShares);

        vm.prank(executor);
        accountant.settleManagementFee();

        assertEq(vault.lastFeeTreasury(), treasuryAddr);
        assertEq(vault.lastFeeShares(), expectedShares);
        assertEq(vault.totalFeeMintCalls(), 1);
    }

    function test_settleManagementFee_noFeeWhenZeroSupply() public {
        vault.setTotalSupply(0);

        _skipCooldown();

        vm.prank(executor);
        accountant.settleManagementFee();

        assertEq(vault.totalFeeMintCalls(), 0);
    }

    function test_settleManagementFee_noFeeWhenZeroFeeRate() public {
        vm.prank(admin);
        accountant.setManagementFeeRate(0);

        vault.setTotalSupply(100_000e18);

        _skipCooldown();

        vm.prank(executor);
        accountant.settleManagementFee();

        assertEq(vault.totalFeeMintCalls(), 0);
    }

    function test_settleManagementFee_accumulatesOverTime() public {
        uint256 totalShares = 1_000_000e18;
        vault.setTotalSupply(totalShares);

        // Prime snapshot
        vm.warp(block.timestamp + 1);
        vm.prank(executor);
        accountant.settleManagementFee();

        _skipCooldown();

        vm.prank(executor);
        accountant.settleManagementFee();
        uint256 firstFee = vault.lastFeeShares();
        assertTrue(firstFee > 0);

        _skipCooldown();

        vm.prank(executor);
        accountant.settleManagementFee();
        uint256 secondFee = vault.lastFeeShares();
        assertTrue(secondFee > 0);

        assertEq(vault.totalFeeMintCalls(), 2);
    }

    function test_settleManagementFee_oneYearFullPeriod() public {
        uint256 totalShares = 10_000e18;
        vault.setTotalSupply(totalShares);

        // Prime snapshot
        vm.warp(block.timestamp + 1);
        vm.prank(executor);
        accountant.settleManagementFee();

        vm.warp(block.timestamp + 365 days);

        vm.prank(executor);
        accountant.settleManagementFee();

        uint256 expectedShares = (totalShares * MANAGEMENT_FEE_BPS * 365 days) / (10_000 * 365 days);
        assertEq(vault.lastFeeShares(), expectedShares);
        assertEq(expectedShares, 50e18);
    }

    function test_settleManagementFee_noopWhenCalledTwiceInSameBlock() public {
        uint256 totalShares = 100_000e18;
        vault.setTotalSupply(totalShares);

        // Prime snapshot
        vm.warp(block.timestamp + 1);
        vm.prank(executor);
        accountant.settleManagementFee();

        _skipCooldown();

        vm.prank(executor);
        accountant.settleManagementFee();
        assertEq(vault.totalFeeMintCalls(), 1);

        vm.prank(executor);
        accountant.settleManagementFee();
        assertEq(vault.totalFeeMintCalls(), 1, "Second call in same block should be a no-op");
    }

    function test_settleManagementFee_usesMinOfCurrentAndLastShares() public {
        vault.setTotalSupply(100_000e18);

        // Prime snapshot with 100k
        vm.warp(block.timestamp + 1);
        vm.prank(executor);
        accountant.settleManagementFee();
        assertEq(accountant.totalSharesLastSettle(), 100_000e18);

        // Supply surges to 500k between settlements
        vault.setTotalSupply(500_000e18);

        _skipCooldown();
        uint256 timeElapsed = block.timestamp - accountant.lastFeeSettleTimestamp();

        vm.prank(executor);
        accountant.settleManagementFee();

        // Fee should be based on min(500k, 100k) = 100k, not 500k
        uint256 expectedShares = (100_000e18 * MANAGEMENT_FEE_BPS * timeElapsed) / (10_000 * 365 days);
        assertEq(vault.lastFeeShares(), expectedShares);
        // Snapshot updated to 500k
        assertEq(accountant.totalSharesLastSettle(), 500_000e18);
    }

    function test_settleManagementFee_usesCurrentWhenSupplyDrops() public {
        vault.setTotalSupply(500_000e18);

        // Prime snapshot with 500k
        vm.warp(block.timestamp + 1);
        vm.prank(executor);
        accountant.settleManagementFee();

        // Supply drops to 100k (large redemptions)
        vault.setTotalSupply(100_000e18);

        _skipCooldown();
        uint256 timeElapsed = block.timestamp - accountant.lastFeeSettleTimestamp();

        vm.prank(executor);
        accountant.settleManagementFee();

        // Fee should be based on min(100k, 500k) = 100k
        uint256 expectedShares = (100_000e18 * MANAGEMENT_FEE_BPS * timeElapsed) / (10_000 * 365 days);
        assertEq(vault.lastFeeShares(), expectedShares);
        assertEq(accountant.totalSharesLastSettle(), 100_000e18);
    }

    function test_settleManagementFee_revertsWhenNotExecutor() public {
        bytes32 role = accountant.EXECUTOR_ROLE();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, role));
        vm.prank(user);
        accountant.settleManagementFee();
    }

    function test_settleManagementFee_revertsWhenPaused() public {
        vm.prank(admin);
        accountant.pause();

        vm.expectRevert();
        vm.prank(executor);
        accountant.settleManagementFee();
    }

    function test_settleManagementFee_independentFromRateUpdate() public {
        uint256 totalShares = 100_000e18;
        vault.setTotalSupply(totalShares);

        // Prime snapshot
        vm.warp(block.timestamp + 1);
        vm.prank(executor);
        accountant.settleManagementFee();

        _skipCooldown();

        // Settle fees — now totalSharesLastSettle is primed
        vm.prank(executor);
        accountant.settleManagementFee();
        assertEq(vault.totalFeeMintCalls(), 1);

        // Then update rate — should not mint any fees
        _doUpdate(1.005e18);
        assertEq(vault.totalFeeMintCalls(), 1, "updateExchangeRate should not mint fees");
    }

    function test_updateExchangeRate_doesNotMintFees() public {
        uint256 totalShares = 100_000e18;
        vault.setTotalSupply(totalShares);

        _skipCooldown();
        _doUpdate(1.005e18);

        assertEq(vault.totalFeeMintCalls(), 0, "updateExchangeRate should not trigger fee minting");
    }

    // =============================================================
    //            EMERGENCY UPDATE EXCHANGE RATE
    //            (commented out — function is disabled)
    // =============================================================

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
        vm.expectRevert(Accountant.ZeroAddress.selector);
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
    //                    SET TREASURY
    // =============================================================

    function test_setTreasury_succeeds() public {
        address newTreasury = makeAddr("newTreasury");

        vm.prank(admin);
        accountant.setTreasury(newTreasury);

        assertEq(accountant.treasury(), newTreasury);
    }

    function test_setTreasury_emitsEvent() public {
        address newTreasury = makeAddr("newTreasury");

        vm.expectEmit(true, true, false, false);
        emit Accountant.TreasuryUpdated(treasuryAddr, newTreasury);

        vm.prank(admin);
        accountant.setTreasury(newTreasury);
    }

    function test_setTreasury_revertsWhenZero() public {
        vm.expectRevert(Accountant.ZeroAddress.selector);
        vm.prank(admin);
        accountant.setTreasury(address(0));
    }

    function test_setTreasury_revertsWhenNotAdmin() public {
        bytes32 adminRole = accountant.DEFAULT_ADMIN_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, adminRole)
        );
        vm.prank(user);
        accountant.setTreasury(makeAddr("t"));
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

    function test_setRiskParams_allowsZeroInterval() public {
        vm.prank(admin);
        accountant.setRiskParams(100, 0);
        assertEq(accountant.minUpdateInterval(), 0);
    }

    function test_setRiskParams_revertsWhenDeviationZero() public {
        vm.expectRevert(abi.encodeWithSelector(Accountant.InvalidDeviation.selector, 0));
        vm.prank(admin);
        accountant.setRiskParams(0, 12 hours);
    }

    function test_setRiskParams_revertsWhenDeviationExceedsCeiling() public {
        uint256 tooHigh = accountant.MAX_DEVIATION_CEILING() + 1;

        vm.expectRevert(abi.encodeWithSelector(Accountant.InvalidDeviation.selector, tooHigh));
        vm.prank(admin);
        accountant.setRiskParams(tooHigh, 12 hours);
    }

    function test_setRiskParams_succeedsAtMaxDeviationCeiling() public {
        uint256 maxDev = accountant.MAX_DEVIATION_CEILING();

        vm.prank(admin);
        accountant.setRiskParams(maxDev, 1 hours);
        assertEq(accountant.maxAllowedDeviation(), maxDev);
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
        vm.prank(admin);
        accountant.setRiskParams(200, 0);

        // 2% deviation now accepted
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
        vm.expectRevert(abi.encodeWithSelector(Accountant.InvalidComputeAge.selector, 0));
        vm.prank(admin);
        accountant.setMaxComputeAge(0);
    }

    function test_setMaxComputeAge_revertsWhenExceedsCeiling() public {
        uint256 tooOld = accountant.MAX_COMPUTE_AGE_CEILING() + 1;

        vm.expectRevert(abi.encodeWithSelector(Accountant.InvalidComputeAge.selector, tooOld));
        vm.prank(admin);
        accountant.setMaxComputeAge(tooOld);
    }

    function test_setMaxComputeAge_succeedsAtCeiling() public {
        uint256 ceiling = accountant.MAX_COMPUTE_AGE_CEILING();

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
        uint256 tooHigh = accountant.MAX_MANAGEMENT_FEE_BPS() + 1;

        vm.expectRevert(abi.encodeWithSelector(Accountant.InvalidFeeRate.selector, tooHigh));
        vm.prank(admin);
        accountant.setManagementFeeRate(tooHigh);
    }

    function test_setManagementFeeRate_succeedsAtMaxCap() public {
        uint256 maxFee = accountant.MAX_MANAGEMENT_FEE_BPS();

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

    function test_pause_adminCanPause() public {
        vm.prank(admin);
        accountant.pause();
        assertTrue(accountant.paused());
    }

    function test_pause_revertsWhenNotPauser() public {
        bytes32 role = accountant.PAUSER_ROLE();

        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, role));
        vm.prank(user);
        accountant.pause();
    }

    function test_unpause_succeeds() public {
        vm.prank(admin);
        accountant.pause();

        vm.prank(admin);
        accountant.unpause();
        assertFalse(accountant.paused());
    }

    function test_unpause_revertsWhenNotAdmin() public {
        vm.prank(admin);
        accountant.pause();

        bytes32 adminRole = accountant.DEFAULT_ADMIN_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, pauser, adminRole)
        );
        vm.prank(pauser);
        accountant.unpause();
    }

    function test_unpause_revertsWhenExecutorCalls() public {
        vm.prank(admin);
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
    }

    // =============================================================
    //                      FUZZ TESTS
    // =============================================================

    function testFuzz_updateWithinDeviation(uint256 rateDelta) public {
        uint256 maxDev = accountant.maxAllowedDeviation();
        rateDelta = bound(rateDelta, 0, (INITIAL_RATE * maxDev) / 10_000);

        _skipCooldown();

        uint256 newRate = INITIAL_RATE + rateDelta;
        _doUpdate(newRate);
        assertEq(accountant.lastExchangeRate(), newRate);
    }

    function testFuzz_revertOutsideDeviation(uint256 rateDelta) public {
        uint256 maxDev = accountant.maxAllowedDeviation();
        uint256 minBadDelta = (INITIAL_RATE * (maxDev + 1)) / 10_000;
        rateDelta = bound(rateDelta, minBadDelta, INITIAL_RATE / 2);

        _skipCooldown();

        uint256 newRate = INITIAL_RATE + rateDelta;

        vm.expectRevert();
        _doUpdate(newRate);
    }

    function testFuzz_setManagementFeeRate(uint256 rate) public {
        rate = bound(rate, 0, accountant.MAX_MANAGEMENT_FEE_BPS());

        vm.prank(admin);
        accountant.setManagementFeeRate(rate);
        assertEq(accountant.managementFeeRate(), rate);
    }

    function testFuzz_setMaxComputeAge(uint256 age) public {
        age = bound(age, 1, accountant.MAX_COMPUTE_AGE_CEILING());

        vm.prank(admin);
        accountant.setMaxComputeAge(age);
        assertEq(accountant.maxComputeAge(), age);
    }

    function testFuzz_setRiskParams(uint256 deviation, uint256 interval) public {
        deviation = bound(deviation, 1, accountant.MAX_DEVIATION_CEILING());
        interval = bound(interval, 0, 30 days);

        vm.prank(admin);
        accountant.setRiskParams(deviation, interval);
        assertEq(accountant.maxAllowedDeviation(), deviation);
        assertEq(accountant.minUpdateInterval(), interval);
    }

    function testFuzz_feeCalculation(uint256 totalShares, uint256 feeBps, uint256 elapsed) public {
        totalShares = bound(totalShares, 1e18, 1_000_000_000e18);
        feeBps = bound(feeBps, 1, accountant.MAX_MANAGEMENT_FEE_BPS());
        elapsed = bound(elapsed, 1, 365 days);

        vault.setTotalSupply(totalShares);

        vm.prank(admin);
        accountant.setManagementFeeRate(feeBps);

        // Prime snapshot so totalSharesLastSettle = totalShares
        vm.warp(block.timestamp + 1);
        vm.prank(executor);
        accountant.settleManagementFee();

        vm.warp(block.timestamp + elapsed);

        vm.prank(executor);
        accountant.settleManagementFee();

        uint256 expectedShares = (totalShares * feeBps * elapsed) / (10_000 * 365 days);

        assertEq(vault.lastFeeShares(), expectedShares);
    }

    function testFuzz_initialize_validFeeRange(uint256 feeBps) public {
        feeBps = bound(feeBps, 0, accountant.MAX_MANAGEMENT_FEE_BPS());

        BeaconProxy proxy = new BeaconProxy(
            address(beacon),
            abi.encodeCall(Accountant.initialize, (address(vault), treasuryAddr, INITIAL_RATE, feeBps, admin))
        );
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
        uint256 computeTs = block.timestamp;

        vm.prank(bot);
        executor.executeUpdateRate(newRate, computeTs);

        assertEq(mockAccountant.lastNewRate(), newRate);
        assertEq(mockAccountant.lastComputeTimestamp(), computeTs);
        assertEq(mockAccountant.callCount(), 1);
    }

    function test_executeUpdateRate_emitsEvent() public {
        uint256 newRate = 1.005e18;
        uint256 computeTs = block.timestamp;

        vm.expectEmit(true, false, false, true);
        emit AccountantExecutor.RateUpdateExecuted(bot, newRate, computeTs);

        vm.prank(bot);
        executor.executeUpdateRate(newRate, computeTs);
    }

    function test_executeUpdateRate_consecutiveCalls() public {
        vm.prank(bot);
        executor.executeUpdateRate(1.001e18, block.timestamp);

        vm.prank(bot);
        executor.executeUpdateRate(1.002e18, block.timestamp + 1);

        assertEq(mockAccountant.lastNewRate(), 1.002e18);
        assertEq(mockAccountant.lastComputeTimestamp(), block.timestamp + 1);
        assertEq(mockAccountant.callCount(), 2);
    }

    // =============================================================
    //              EXECUTE SETTLE FEES TESTS
    // =============================================================

    function test_executeSettleManagementFee_succeeds() public {
        vm.prank(bot);
        executor.executeSettleManagementFee();

        assertEq(mockAccountant.settleManagementFeeCallCount(), 1);
    }

    function test_executeSettleManagementFee_emitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit AccountantExecutor.ManagementFeeSettled(bot);

        vm.prank(bot);
        executor.executeSettleManagementFee();
    }

    function test_executeSettleManagementFee_revertsWhenNotBotRole() public {
        bytes32 role = executor.BOT_ROLE();

        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, role));
        vm.prank(user);
        executor.executeSettleManagementFee();
    }

    // =============================================================
    //                  REVERT TESTS
    // =============================================================

    function test_executeUpdateRate_revertsWhenNotExecuteRole() public {
        bytes32 role = executor.BOT_ROLE();

        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, role));
        vm.prank(user);
        executor.executeUpdateRate(1e18, block.timestamp);
    }

    function test_executeUpdateRate_revertsWhenAdminWithoutExecuteRole() public {
        bytes32 role = executor.BOT_ROLE();

        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, role));
        vm.prank(admin);
        executor.executeUpdateRate(1e18, block.timestamp);
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
        executor.executeUpdateRate(1e18, block.timestamp);
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

    function testFuzz_executeUpdateRate(uint256 newRate, uint256 computeTs) public {
        newRate = bound(newRate, 1, type(uint128).max);
        computeTs = bound(computeTs, 1, type(uint128).max);

        vm.prank(bot);
        executor.executeUpdateRate(newRate, computeTs);

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
    address public treasuryAddr = makeAddr("treasury");

    uint256 public constant INITIAL_RATE = 1e18;
    uint256 public constant MANAGEMENT_FEE_BPS = 50; // 0.5%

    function setUp() public {
        vm.warp(1000); // anchor a non-zero starting timestamp

        vault = new MockVault();

        Accountant accImpl = new Accountant();
        accBeacon = new UpgradeableBeacon(address(accImpl), admin);
        BeaconProxy accProxy = new BeaconProxy(
            address(accBeacon),
            abi.encodeCall(
                Accountant.initialize, (address(vault), treasuryAddr, INITIAL_RATE, MANAGEMENT_FEE_BPS, admin)
            )
        );
        accountant = Accountant(address(accProxy));

        AccountantExecutor execImpl = new AccountantExecutor();
        execBeacon = new UpgradeableBeacon(address(execImpl), admin);
        BeaconProxy execProxy = new BeaconProxy(
            address(execBeacon), abi.encodeCall(AccountantExecutor.initialize, (address(accountant), admin))
        );
        executor = AccountantExecutor(address(execProxy));

        vm.startPrank(admin);
        accountant.grantRole(accountant.EXECUTOR_ROLE(), address(executor));
        executor.grantRole(executor.BOT_ROLE(), bot);
        vm.stopPrank();
    }

    // ── helpers ───────────────────────────────────────────────────

    function _skipCooldown() internal {
        vm.warp(block.timestamp + accountant.minUpdateInterval() + 1);
    }

    function _executeUpdate(uint256 newRate) internal {
        vm.prank(bot);
        executor.executeUpdateRate(newRate, block.timestamp);
    }

    // =============================================================
    //                    HAPPY-PATH TESTS
    // =============================================================

    function test_integration_fullFlow() public {
        _skipCooldown();

        uint256 newRate = 1.005e18;
        uint256 computeTs = block.timestamp;

        vm.prank(bot);
        executor.executeUpdateRate(newRate, computeTs);

        assertEq(accountant.lastExchangeRate(), newRate);
        assertEq(vault.exchangeRate(), newRate);
        assertEq(accountant.lastComputeTimestamp(), computeTs);
    }

    function test_integration_consecutiveUpdates() public {
        _skipCooldown();

        uint256 computeTs1 = block.timestamp;
        vm.prank(bot);
        executor.executeUpdateRate(1.005e18, computeTs1);

        _skipCooldown();

        uint256 computeTs2 = block.timestamp;
        vm.prank(bot);
        executor.executeUpdateRate(1.009e18, computeTs2);

        assertEq(accountant.lastExchangeRate(), 1.009e18);
        assertEq(accountant.lastComputeTimestamp(), computeTs2);
    }

    function test_integration_emitsExchangeRateUpdatedEvent() public {
        _skipCooldown();

        uint256 newRate = 1.005e18;

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
        executor.executeUpdateRate(1.005e18, block.timestamp);
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

    function test_integration_revertsWhenDeviationExceeded() public {
        _skipCooldown();

        // Default maxAllowedDeviation = 100 bps (1%). A 2% jump should revert.
        uint256 tooHighRate = 1.02e18;
        uint256 deviationBps = 200;

        vm.expectRevert(
            abi.encodeWithSelector(
                Accountant.DeviationExceeded.selector, deviationBps, accountant.maxAllowedDeviation()
            )
        );
        _executeUpdate(tooHighRate);
    }

    function test_integration_revertsWhenDeviationExceeded_rateDrops() public {
        _skipCooldown();

        // 2% downward deviation
        uint256 tooLowRate = 0.98e18;
        uint256 deviationBps = 200;

        vm.expectRevert(
            abi.encodeWithSelector(
                Accountant.DeviationExceeded.selector, deviationBps, accountant.maxAllowedDeviation()
            )
        );
        _executeUpdate(tooLowRate);
    }

    function test_integration_succeedsAtMaxDeviationBoundary() public {
        _skipCooldown();

        // Exactly 1% deviation (100 bps) should pass
        uint256 boundaryRate = 1.01e18;
        _executeUpdate(boundaryRate);
        assertEq(accountant.lastExchangeRate(), boundaryRate);
    }

    // =============================================================
    //              COMPUTE TIMESTAMP VALIDATION
    // =============================================================

    function test_integration_revertsWhenComputeTimestampStale() public {
        _skipCooldown();

        uint256 computeTs1 = block.timestamp;
        vm.prank(bot);
        executor.executeUpdateRate(1.005e18, computeTs1);

        _skipCooldown();

        // Use same timestamp as before → stale
        vm.expectRevert(abi.encodeWithSelector(Accountant.StaleComputeTimestamp.selector, computeTs1, computeTs1));
        vm.prank(bot);
        executor.executeUpdateRate(1.006e18, computeTs1);
    }

    function test_integration_revertsWhenComputeTimestampInFuture() public {
        _skipCooldown();

        uint256 futureTs = block.timestamp + 1;

        vm.expectRevert(abi.encodeWithSelector(Accountant.FutureComputeTimestamp.selector, futureTs, block.timestamp));
        vm.prank(bot);
        executor.executeUpdateRate(1.005e18, futureTs);
    }

    function test_integration_revertsWhenComputeTimestampTooOld() public {
        _skipCooldown();

        uint256 maxAge = accountant.maxComputeAge();
        uint256 staleTs = block.timestamp - maxAge - 1;
        // staleTs must be > lastComputeTimestamp (0), which is true since block.timestamp is large
        vm.expectRevert(
            abi.encodeWithSelector(Accountant.ComputeTimestampTooOld.selector, staleTs, block.timestamp, maxAge)
        );
        vm.prank(bot);
        executor.executeUpdateRate(1.005e18, staleTs);
    }

    // =============================================================
    //                  ZERO-VALUE VALIDATION
    // =============================================================

    function test_integration_revertsWhenRateIsZero() public {
        _skipCooldown();

        vm.expectRevert(Accountant.InvalidRate.selector);
        _executeUpdate(0);
    }

    // =============================================================
    //                    FEE SETTLEMENT
    // =============================================================

    function test_integration_feeSharesMintedToTreasury() public {
        uint256 totalShares = 100_000e18;
        vault.setTotalSupply(totalShares);

        // Prime snapshot
        vm.warp(block.timestamp + 1);
        vm.prank(bot);
        executor.executeSettleManagementFee();

        _skipCooldown();

        uint256 timeElapsed = block.timestamp - accountant.lastFeeSettleTimestamp();
        uint256 expectedShares = (totalShares * MANAGEMENT_FEE_BPS * timeElapsed) / (10_000 * 365 days);

        vm.expectEmit(true, false, false, true);
        emit Accountant.FeesDistributed(treasuryAddr, expectedShares);

        vm.prank(bot);
        executor.executeSettleManagementFee();

        assertEq(vault.lastFeeTreasury(), treasuryAddr);
        assertEq(vault.lastFeeShares(), expectedShares);
        assertEq(vault.totalFeeMintCalls(), 1);
    }

    function test_integration_zeroFeeWhenManagementFeeIsZero() public {
        vm.prank(admin);
        accountant.setManagementFeeRate(0);

        _skipCooldown();

        vm.prank(bot);
        executor.executeSettleManagementFee();

        assertEq(vault.totalFeeMintCalls(), 0, "No fee shares should be minted when fee rate is 0");
    }

    function test_integration_updateRateDoesNotMintFees() public {
        uint256 totalShares = 100_000e18;
        vault.setTotalSupply(totalShares);

        _skipCooldown();
        _executeUpdate(1.005e18);

        assertEq(vault.totalFeeMintCalls(), 0, "updateExchangeRate should not mint fees");
    }

    // =============================================================
    //                    PAUSE / UNPAUSE
    // =============================================================

    function test_integration_revertsWhenPaused() public {
        vm.prank(admin);
        accountant.pause();

        _skipCooldown();

        vm.expectRevert();
        _executeUpdate(1.005e18);
    }

    function test_integration_succeedsAfterUnpause() public {
        vm.prank(admin);
        accountant.pause();

        vm.prank(admin);
        accountant.unpause();

        _skipCooldown();

        _executeUpdate(1.005e18);
        assertEq(accountant.lastExchangeRate(), 1.005e18);
    }

    function test_integration_pauseRoleCanPause() public {
        address pauser = makeAddr("pauser");

        vm.startPrank(admin);
        accountant.grantRole(accountant.PAUSER_ROLE(), pauser);
        vm.stopPrank();

        vm.prank(pauser);
        accountant.pause();

        _skipCooldown();

        vm.expectRevert();
        _executeUpdate(1.005e18);
    }

    function test_integration_unpauseRequiresAdmin() public {
        address pauser = makeAddr("pauser");
        vm.startPrank(admin);
        accountant.grantRole(accountant.PAUSER_ROLE(), pauser);
        accountant.pause();
        vm.stopPrank();

        bytes32 adminRole = accountant.DEFAULT_ADMIN_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, pauser, adminRole)
        );
        vm.prank(pauser);
        accountant.unpause();
    }

    // =============================================================
    //                 EMERGENCY RATE UPDATE
    //                 (commented out — function is disabled)
    // =============================================================

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
        vm.expectRevert(abi.encodeWithSelector(Accountant.InvalidDeviation.selector, 0));
        vm.prank(admin);
        accountant.setRiskParams(0, 12 hours);
    }

    function test_integration_setRiskParams_revertsWhenDeviationExceedsCeiling() public {
        uint256 tooHigh = accountant.MAX_DEVIATION_CEILING() + 1;
        vm.expectRevert(abi.encodeWithSelector(Accountant.InvalidDeviation.selector, tooHigh));
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
        uint256 tooHigh = accountant.MAX_MANAGEMENT_FEE_BPS() + 1;
        vm.expectRevert(abi.encodeWithSelector(Accountant.InvalidFeeRate.selector, tooHigh));
        vm.prank(admin);
        accountant.setManagementFeeRate(tooHigh);
    }

    function test_integration_setTreasury() public {
        address newTreasury = makeAddr("newTreasury");

        vm.expectEmit(true, true, false, false);
        emit Accountant.TreasuryUpdated(treasuryAddr, newTreasury);

        vm.prank(admin);
        accountant.setTreasury(newTreasury);

        assertEq(accountant.treasury(), newTreasury);
    }

    function test_integration_setTreasury_revertsWhenZero() public {
        vm.expectRevert(Accountant.ZeroAddress.selector);
        vm.prank(admin);
        accountant.setTreasury(address(0));
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
        vm.expectRevert(Accountant.ZeroAddress.selector);
        vm.prank(admin);
        accountant.setVault(address(0));
    }

    function test_integration_setMaxComputeAge() public {
        uint256 newAge = 10 minutes;

        vm.expectEmit(false, false, false, true);
        emit Accountant.MaxComputeAgeUpdated(5 minutes, newAge);

        vm.prank(admin);
        accountant.setMaxComputeAge(newAge);

        assertEq(accountant.maxComputeAge(), newAge);
    }

    function test_integration_setMaxComputeAge_revertsWhenZero() public {
        vm.expectRevert(abi.encodeWithSelector(Accountant.InvalidComputeAge.selector, 0));
        vm.prank(admin);
        accountant.setMaxComputeAge(0);
    }

    function test_integration_setMaxComputeAge_revertsWhenExceedsCeiling() public {
        uint256 tooOld = accountant.MAX_COMPUTE_AGE_CEILING() + 1;
        vm.expectRevert(abi.encodeWithSelector(Accountant.InvalidComputeAge.selector, tooOld));
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
        accountant.setTreasury(makeAddr("t"));

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

        uint256 newRate = INITIAL_RATE + rateDelta;
        _executeUpdate(newRate);
        assertEq(accountant.lastExchangeRate(), newRate);
    }

    function testFuzz_integration_revertOutsideDeviation(uint256 rateDelta) public {
        uint256 maxDev = accountant.maxAllowedDeviation();
        // (maxDev + 1) ensures floor-division in _checkDeviation still exceeds the cap
        uint256 minBadDelta = (INITIAL_RATE * (maxDev + 1)) / 10_000;
        rateDelta = bound(rateDelta, minBadDelta, INITIAL_RATE / 2);

        _skipCooldown();

        uint256 newRate = INITIAL_RATE + rateDelta;

        vm.expectRevert();
        _executeUpdate(newRate);
    }
}
