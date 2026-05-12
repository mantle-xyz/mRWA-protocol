// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Accountant} from "../../src/accountant/Accountant.sol";
import {AccountantExecutor} from "../../src/accountant/AccountantExecutor.sol";
import {IAccountant} from "../../src/interfaces/accountant/IAccountant.sol";
import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {IMantleVaultGateway} from "../../src/interfaces/vault/IMantleVaultGateway.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {MantleVaultGateway} from "../../src/vault/MantleVaultGateway.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {VaultFactory} from "../../src/vault/VaultFactory.sol";
import {GatewayFactory} from "../../src/vault/GatewayFactory.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Test, console2} from "forge-std/Test.sol";

// ---------------------------------------------------------------------------
// Mock contracts
// ---------------------------------------------------------------------------

contract MockUSDC_Acc is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Minimal mock vault for Accountant-only tests (no full stack needed).
contract MockVaultForAccountant {
    uint256 public _totalSupply;
    uint256 public lastFeeShares;
    address public immutable _asset;

    constructor(uint256 initialSupply, address asset_) {
        _totalSupply = initialSupply;
        _asset = asset_;
    }

    function mintFeeShares(uint256 shares) external {
        lastFeeShares = shares;
        _totalSupply += shares;
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function asset() external view returns (address) {
        return _asset;
    }
}

contract MockSanctionsOracle_Acc is ISanctionsOracle {
    mapping(address => bool) public sanctioned;
    mapping(address => bool) public whitelisted;

    function initialize(address, address) external override {}

    function isSanctioned(address account) external view override returns (bool) {
        return sanctioned[account];
    }

    function isWhitelisted(address account) external view override returns (bool) {
        return whitelisted[account];
    }

    function setSanctioned(address account, bool status) external {
        sanctioned[account] = status;
    }

    function setWhitelisted(address account, bool status) external {
        whitelisted[account] = status;
    }

    function totalSanctionedCount() external pure override returns (uint256) {
        return 0;
    }

    function totalWhitelistedCount() external pure override returns (uint256) {
        return 0;
    }

    function lastUpdateTimestamp() external pure override returns (uint256) {
        return 0;
    }

    function batchNonce() external pure override returns (uint256) {
        return 0;
    }

    function MAX_BATCH_SIZE() external pure override returns (uint256) {
        return 100;
    }

    function updateSanctionStatus(address, bool) external override {}
    function updateSanctionStatusBatch(address[] calldata, bool) external override {}
    function updateWhitelistStatus(address, bool) external override {}
    function updateWhitelistStatusBatch(address[] calldata, bool) external override {}
}

/**
 * @title  AccountantQATest
 * @notice QA scenario tests for Accountant (Accountant 汇率与管理费场景).
 */
contract AccountantQATest is Test {
    Accountant internal accountant;
    AccountantExecutor internal accountantExecutor;
    MockVaultForAccountant internal mockVault;

    // For Gateway integration sub-tests
    MockUSDC_Acc internal usdc;
    MockSanctionsOracle_Acc internal oracle;
    Accountant internal gatewayAccountant;
    MantleYieldVault internal vault;
    MantleVaultGateway internal gateway;
    VaultFactory internal vaultFactory;
    GatewayFactory internal gatewayFactory;

    address internal admin = makeAddr("admin");
    address internal bot = makeAddr("bot");
    address internal user = makeAddr("user");
    address internal alice = makeAddr("alice");
    address internal treasury = makeAddr("treasury");

    uint64 internal constant INITIAL_RATE = 1e18;
    uint32 internal constant MANAGEMENT_FEE_BPS = 100; // 1%

    string constant MODULE = unicode"Accountant 汇率与管理费场景";
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

    function setUp() public {
        vm.warp(1000);

        // --- Accountant with MockVault ---
        usdc = new MockUSDC_Acc();
        mockVault = new MockVaultForAccountant(1_000_000e18, address(usdc));

        Accountant impl = new Accountant();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), admin);
        BeaconProxy proxy = new BeaconProxy(
            address(beacon),
            abi.encodeCall(Accountant.initialize, (address(mockVault), INITIAL_RATE, MANAGEMENT_FEE_BPS, admin))
        );
        accountant = Accountant(address(proxy));

        AccountantExecutor executorImpl = new AccountantExecutor();
        accountantExecutor = AccountantExecutor(
            address(new ERC1967Proxy(address(executorImpl), abi.encodeCall(AccountantExecutor.initialize, (admin))))
        );

        vm.startPrank(admin);
        accountant.grantRole(accountant.ACCOUNTANT_EXECUTOR_ROLE(), address(accountantExecutor));
        accountantExecutor.grantRole(accountantExecutor.BOT_ROLE(), bot);
        vm.stopPrank();

        // --- Full stack for Gateway integration sub-tests ---
        oracle = new MockSanctionsOracle_Acc();

        MantleYieldVault vaultImpl = new MantleYieldVault();
        Accountant gatewayAccountantImpl = new Accountant();
        MantleVaultGateway gwImpl = new MantleVaultGateway();
        vaultFactory = new VaultFactory(address(vaultImpl), admin);
        gatewayFactory = new GatewayFactory(address(gwImpl), admin);

        address vaultAddr = vaultFactory.deployVault();
        address gwAddr = gatewayFactory.deployGateway();
        vault = MantleYieldVault(vaultAddr);
        gateway = MantleVaultGateway(gwAddr);

        gatewayAccountant = Accountant(
            address(
                new ERC1967Proxy(
                    address(gatewayAccountantImpl),
                    abi.encodeCall(Accountant.initialize, (vaultAddr, INITIAL_RATE, MANAGEMENT_FEE_BPS, admin))
                )
            )
        );

        vm.startPrank(admin);
        gatewayAccountant.grantRole(gatewayAccountant.ACCOUNTANT_EXECUTOR_ROLE(), address(accountantExecutor));
        gatewayAccountant.grantRole(gatewayAccountant.ACCOUNTANT_EXECUTOR_ROLE(), bot);
        vm.stopPrank();

        vm.prank(admin);
        vault.initialize(
            IMantleYieldVault.InitParams({
                asset: IERC20(address(usdc)),
                name: "Mantle RWA Vault",
                symbol: "mRWA",
                admin: admin,
                gateway: gwAddr,
                controller: makeAddr("controller"),
                accountant: address(gatewayAccountant),
                treasury: treasury,
                maxRedemptionFeeBps: 500,
                redemptionFeeBps: 100,
                minRedeemAmount: 0,
                minDepositAmount: 0,
                maxSettlementDeviationBps: 0,
                depositDailyRemaining: type(uint256).max,
                redeemDailyRemaining: type(uint256).max
            })
        );

        vm.prank(admin);
        gateway.initialize(
            IMantleVaultGateway.InitParams({
                vault: vaultAddr,
                sanctionsOracle: ISanctionsOracle(address(oracle)),
                sanctionSafe: treasury,
                admin: admin,
                syncRedeemDisabled: false
            })
        );

        bytes32 vaultPauserRole = vault.PAUSER_ROLE();
        vm.prank(admin);
        vault.grantRole(vaultPauserRole, admin);

        // Fund alice and deposit so vault has shares
        usdc.mint(alice, 10_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        gateway.deposit(1_000e6);
        vm.stopPrank();
    }

    // ── helpers ───────────────────────────────────────────────────

    function _skipCooldown() internal {
        vm.warp(block.timestamp + accountant.minUpdateInterval() + 1);
    }

    function _executeRateUpdate(uint64 newRate, uint64 computeTs) internal {
        vm.prank(bot);
        accountantExecutor.executeUpdateRate(address(accountant), newRate, computeTs);
    }

    function _doUpdate(uint64 newRate) internal {
        _executeRateUpdate(newRate, uint64(vm.getBlockTimestamp()));
    }

    function _executeSettleFee() internal {
        vm.prank(bot);
        accountantExecutor.executeSettleManagementFee(address(accountant));
    }

    function _executeGatewayRateUpdate(uint64 newRate, uint64 computeTs) internal {
        vm.prank(bot);
        accountantExecutor.executeUpdateRate(address(gatewayAccountant), newRate, computeTs);
    }

    function _executeGatewaySettleFee() internal {
        vm.prank(bot);
        accountantExecutor.executeSettleManagementFee(address(gatewayAccountant));
    }

    // =============================================================
    //  P0 — Initialization
    // =============================================================

    function test_Accountant_InitSuccess() public {
        _logCase("test_Accountant_InitSuccess", unicode"Accountant 初始化成功");

        _step("[Step 1] Deploy and initialize Accountant via proxy");
        _step(string.concat("  vault: ", vm.toString(address(mockVault))));
        _step(string.concat("  initialRate: ", vm.toString(uint256(INITIAL_RATE))));
        _step(string.concat("  managementFeeRate: ", vm.toString(uint256(MANAGEMENT_FEE_BPS))));
        _step(string.concat("  admin: ", vm.toString(admin)));

        _step("[Step 2] Verify all default values");
        assertEq(accountant.lastExchangeRate(), INITIAL_RATE);
        _step(string.concat("  lastExchangeRate: ", vm.toString(accountant.lastExchangeRate())));
        _step("  PASS: lastExchangeRate == initialRate");

        assertEq(accountant.managementFeeRate(), MANAGEMENT_FEE_BPS);
        _step(string.concat("  managementFeeRate: ", vm.toString(uint256(accountant.managementFeeRate()))));
        _step("  PASS: managementFeeRate == managementFeeRate_");

        assertEq(accountant.maxAllowedDeviation(), 100);
        _step(string.concat("  maxAllowedDeviation: ", vm.toString(uint256(accountant.maxAllowedDeviation()))));
        _step("  PASS: maxAllowedDeviation == 100 (1% default)");

        assertEq(accountant.minUpdateInterval(), 20 hours);
        _step(string.concat("  minUpdateInterval: ", vm.toString(uint256(accountant.minUpdateInterval()))));
        _step("  PASS: minUpdateInterval == 20 hours");

        assertEq(accountant.maxComputeAge(), 5 minutes);
        _step(string.concat("  maxComputeAge: ", vm.toString(uint256(accountant.maxComputeAge()))));
        _step("  PASS: maxComputeAge == 5 minutes");

        assertTrue(accountant.hasRole(accountant.DEFAULT_ADMIN_ROLE(), admin));
        _step("  PASS: admin has DEFAULT_ADMIN_ROLE");
        assertTrue(accountant.hasRole(accountant.PAUSER_ROLE(), admin));
        _step("  PASS: admin has PAUSER_ROLE");
        assertTrue(accountant.hasRole(accountant.ACCOUNTANT_EXECUTOR_ROLE(), admin));
        _step("  PASS: admin has EXECUTOR_ROLE");

        assertEq(address(accountant.vault()), address(mockVault));
        _step("  PASS: vault() returns correct vault address");

        _logPass();
    }

    function test_Accountant_InitRejectZeroAddrAndInvalidFee() public {
        _logCase("test_Accountant_InitRejectZeroAddrAndInvalidFee", unicode"初始化拒绝零地址与非法费率");

        _step("[Step 1] Deploy new impl for fresh proxy tests");
        Accountant impl = new Accountant();

        _step("[Step 2] vault = address(0) should revert with ZeroAddress");
        vm.expectRevert(Accountant.Accountant__ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl), abi.encodeCall(Accountant.initialize, (address(0), INITIAL_RATE, MANAGEMENT_FEE_BPS, admin))
        );
        _step("  PASS: reverted with ZeroAddress for vault=address(0)");

        _step("[Step 3] admin = address(0) should revert with ZeroAddress");
        vm.expectRevert(Accountant.Accountant__ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(Accountant.initialize, (address(mockVault), INITIAL_RATE, MANAGEMENT_FEE_BPS, address(0)))
        );
        _step("  PASS: reverted with ZeroAddress for admin=address(0)");

        _step("[Step 4] feeRate > MAX_MANAGEMENT_FEE_BPS should revert with InvalidFeeRate");
        uint32 tooHighFee = accountant.MAX_MANAGEMENT_FEE_BPS() + 1;
        vm.expectRevert(abi.encodeWithSelector(Accountant.Accountant__InvalidFeeRate.selector, tooHighFee));
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(Accountant.initialize, (address(mockVault), INITIAL_RATE, tooHighFee, admin))
        );
        _step(string.concat("  PASS: reverted with InvalidFeeRate for fee=", vm.toString(uint256(tooHighFee))));

        _step("[Step 5] initialRate = 0 should revert with InvalidRate");
        vm.expectRevert(Accountant.Accountant__InvalidRate.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(Accountant.initialize, (address(mockVault), 0, MANAGEMENT_FEE_BPS, admin))
        );
        _step("  PASS: reverted with InvalidRate for initialRate=0");

        _logPass();
    }

    // =============================================================
    //  P0 — Rate update scenarios
    // =============================================================

    function test_UpdateExchangeRate_Success() public {
        _logCase("test_UpdateExchangeRate_Success", unicode"正常更新汇率成功");

        _step("[Step 1] Skip cooldown period");
        _skipCooldown();

        _step("[Step 2] Call updateExchangeRate with valid parameters");
        uint64 newRate = 1.005e18;
        uint64 computeTs = uint64(vm.getBlockTimestamp());
        _executeRateUpdate(newRate, computeTs);
        _step(string.concat("  newRate: ", vm.toString(uint256(newRate))));

        _step("[Step 3] Verify rate and timestamp updated");
        assertEq(accountant.lastExchangeRate(), newRate);
        _step("  PASS: lastExchangeRate == newRate");
        assertEq(accountant.lastUpdateTimestamp(), uint64(vm.getBlockTimestamp()));
        _step("  PASS: lastUpdateTimestamp updated");

        _logPass();
    }

    function test_UpdateExchangeRate_ZeroRateRejected() public {
        _logCase("test_UpdateExchangeRate_ZeroRateRejected", unicode"新汇率为 0 被拒绝");

        _step("[Step 1] Skip cooldown and attempt to set rate=0");
        _skipCooldown();
        vm.expectRevert(Accountant.Accountant__InvalidRate.selector);
        _executeRateUpdate(0, uint64(vm.getBlockTimestamp()));
        _step("  PASS: reverted with InvalidRate");

        _logPass();
    }

    function test_UpdateExchangeRate_CircuitBreaker() public {
        _logCase("test_UpdateExchangeRate_CircuitBreaker", unicode"汇率偏差超过阈值时触发 circuit breaker，而非直接回滚");

        _step("[Step 1] Set deviation threshold to 500 bps (5%) for this test");
        vm.prank(admin);
        accountant.setRiskParams(500, 0); // 5% deviation, 0 cooldown
        _step(string.concat("  maxAllowedDeviation: ", vm.toString(uint256(accountant.maxAllowedDeviation()))));

        _step("[Step 2] Skip cooldown and call updateExchangeRate with 10% deviation");
        _skipCooldown();
        uint64 deviatingRate = 1.1e18; // 10% above 1e18
        uint256 oldRate = accountant.lastExchangeRate();

        vm.expectEmit(false, false, false, true, address(accountant));
        emit Accountant.CircuitBreakerTriggered(1000, 500, deviatingRate);
        _executeRateUpdate(deviatingRate, uint64(vm.getBlockTimestamp()));
        _step("  PASS: CircuitBreakerTriggered event emitted");

        _step("[Step 3] Verify Accountant is now paused");
        assertTrue(accountant.paused());
        _step("  PASS: Accountant is paused");

        _step("[Step 4] Verify lastExchangeRate unchanged");
        assertEq(accountant.lastExchangeRate(), oldRate);
        _step("  PASS: lastExchangeRate preserved at old value");

        _logPass();
    }

    function test_ComputeTimestamp_StaleRejected() public {
        _logCase("test_ComputeTimestamp_StaleRejected", unicode"computeTimestamp 回退时被拒绝");

        _step("[Step 1] Skip cooldown");
        _skipCooldown();

        _step("[Step 2] Attempt update with computeTimestamp <= lastComputeTimestamp");
        uint64 lastTs = accountant.lastComputeTimestamp();
        _step(string.concat("  lastComputeTimestamp: ", vm.toString(uint256(lastTs))));

        vm.expectRevert(abi.encodeWithSelector(Accountant.Accountant__StaleComputeTimestamp.selector, lastTs - 1, lastTs));
        _executeRateUpdate(INITIAL_RATE, lastTs - 1);
        _step("  PASS: reverted with StaleComputeTimestamp");

        _logPass();
    }

    function test_ComputeTimestamp_FutureRejected() public {
        _logCase("test_ComputeTimestamp_FutureRejected", unicode"computeTimestamp 在未来时被拒绝");

        _step("[Step 1] Skip cooldown");
        _skipCooldown();

        _step("[Step 2] Attempt update with computeTimestamp > block.timestamp");
        uint256 currentTs = vm.getBlockTimestamp();
        uint64 futureTs = uint64(currentTs + 100);
        _step(string.concat("  futureTs: ", vm.toString(uint256(futureTs))));
        _step(string.concat("  block.timestamp: ", vm.toString(currentTs)));

        vm.expectRevert(
            abi.encodeWithSelector(Accountant.Accountant__FutureComputeTimestamp.selector, futureTs, currentTs)
        );
        _executeRateUpdate(INITIAL_RATE, futureTs);
        _step("  PASS: reverted with FutureComputeTimestamp");

        _logPass();
    }

    function test_ComputeTimestamp_TooOldRejected() public {
        _logCase("test_ComputeTimestamp_TooOldRejected", unicode"computeTimestamp 过旧时被拒绝");

        _step("[Step 1] Skip cooldown so block.timestamp advances significantly");
        _skipCooldown();

        _step("[Step 2] Set maxComputeAge to something we can test (already 5 min default)");
        uint32 maxAge = accountant.maxComputeAge();
        _step(string.concat("  maxComputeAge: ", vm.toString(uint256(maxAge))));

        // Need a computeTimestamp that is newer than lastComputeTimestamp but older than maxAge
        // Warp forward more so there's room
        vm.warp(block.timestamp + 2 hours);
        uint256 currentTs = vm.getBlockTimestamp();
        uint64 tooOldTs = uint64(currentTs - 2 hours);
        // tooOldTs must be > lastComputeTimestamp (which is 1000 from setUp)
        // block.timestamp is now ~ 1000 + 20h + 1 + 2h, tooOldTs ~ 1000 + 20h + 1
        // lastComputeTimestamp is 1000, so tooOldTs > 1000 => OK
        _step(string.concat("  tooOldTs: ", vm.toString(uint256(tooOldTs))));
        _step(string.concat("  block.timestamp: ", vm.toString(currentTs)));

        vm.expectRevert(
            abi.encodeWithSelector(
                Accountant.Accountant__ComputeTimestampTooOld.selector, tooOldTs, currentTs, maxAge
            )
        );
        _executeRateUpdate(INITIAL_RATE, tooOldTs);
        _step("  PASS: reverted with ComputeTimestampTooOld");

        _logPass();
    }

    function test_CooldownNotElapsed() public {
        _logCase("test_CooldownNotElapsed", unicode"冷却期内再次更新汇率被拒绝");

        _step("[Step 1] First update after cooldown");
        _skipCooldown();
        _doUpdate(INITIAL_RATE);
        _step("  First update succeeded");

        _step("[Step 2] Immediately attempt second update (within cooldown)");
        vm.warp(block.timestamp + 1); // just 1 second later
        uint64 newTs = uint64(vm.getBlockTimestamp());

        uint256 cooldownEnd = accountant.lastUpdateTimestamp() + accountant.minUpdateInterval();
        uint256 timeRemaining = cooldownEnd - block.timestamp;
        vm.expectRevert(abi.encodeWithSelector(Accountant.Accountant__CooldownNotElapsed.selector, timeRemaining));
        _executeRateUpdate(INITIAL_RATE, newTs);
        _step("  PASS: reverted with CooldownNotElapsed");

        _logPass();
    }

    function test_UpdateRate_DoesNotAutoSettleManagementFee() public {
        _logCase(
            "test_UpdateRate_DoesNotAutoSettleManagementFee",
            unicode"updateExchangeRate 仅更新汇率，不再自动结算管理费"
        );

        _step("[Step 1] Set minInterval=0 to simplify test, advance time");
        vm.prank(admin);
        accountant.setRiskParams(100, 0); // keep deviation=1%, cooldown=0

        _step("[Step 2] Advance 365 days for fee accrual");
        vm.warp(block.timestamp + 365 days);
        uint256 supply = mockVault._totalSupply();
        uint64 lastFeeSettleTsBefore = accountant.lastFeeSettleTimestamp();
        _step(string.concat("  vault totalSupply: ", vm.toString(supply)));
        _step(string.concat("  managementFeeRate: ", vm.toString(uint256(accountant.managementFeeRate()))));

        _step("[Step 3] Update rate - should NOT trigger fee settlement");
        uint64 newRate = 1.005e18;
        _executeRateUpdate(newRate, uint64(vm.getBlockTimestamp()));
        assertEq(accountant.lastFeeSettleTimestamp(), lastFeeSettleTsBefore, "lastFeeSettleTimestamp unchanged after rate update");
        assertEq(mockVault._totalSupply(), supply, "totalSupply unchanged - no fee minted by rate update");
        assertEq(accountant.lastExchangeRate(), newRate, "rate updated");
        _step("  PASS: updateExchangeRate did not settle fees");

        _logPass();
    }

    function test_SettleManagementFee_MintsFeeShares() public {
        _logCase(
            "test_SettleManagementFee_MintsFeeShares",
            unicode"独立调用 settleManagementFee() 结算管理费并 mint fee shares"
        );

        _step("[Step 1] Advance 365 days for fee accrual");
        vm.warp(block.timestamp + 365 days);
        uint256 supply = mockVault._totalSupply();
        uint64 lastFeeSettleTsBefore = accountant.lastFeeSettleTimestamp();
        uint256 totalSharesLastSettleBefore = accountant.totalSharesLastSettle();
        _step(string.concat("  vault totalSupply: ", vm.toString(supply)));
        _step(string.concat("  managementFeeRate: ", vm.toString(uint256(accountant.managementFeeRate()))));

        _step("[Step 2] Call settleManagementFee independently");
        _executeSettleFee();

        _step("[Step 3] Verify fee shares minted match contract formula");
        uint256 timeElapsed = vm.getBlockTimestamp() - lastFeeSettleTsBefore;
        uint256 shareBase = supply < totalSharesLastSettleBefore ? supply : totalSharesLastSettleBefore;
        uint256 expectedFeeShares = (shareBase * MANAGEMENT_FEE_BPS * timeElapsed) / (10_000 * 365 days);
        assertEq(mockVault._totalSupply(), supply + expectedFeeShares, "totalSupply increased by fee shares");
        assertEq(mockVault.lastFeeShares(), expectedFeeShares, "fee shares match formula");
        _step(string.concat("  expectedFeeShares: ", vm.toString(expectedFeeShares)));
        _step(string.concat("  totalSupply after: ", vm.toString(mockVault._totalSupply())));
        _step("  PASS: fee shares minted via independent settleManagementFee");

        _logPass();
    }

    // =============================================================
    //  P1 — Pause scenarios
    // =============================================================

    function test_GetRate_WhenPaused() public {
        _logCase("test_GetRate_WhenPaused", unicode"getRate() 在暂停时仍可读取最后汇率");

        _step("[Step 1] Pause the Accountant");
        vm.prank(admin);
        accountant.pause();
        assertTrue(accountant.paused());
        _step("  PASS: Accountant is paused");

        _step("[Step 2] Call getRate()");
        uint256 rate = accountant.getRate();
        assertEq(rate, INITIAL_RATE);
        _step(string.concat("  getRate() = ", vm.toString(rate)));
        _step("  PASS: getRate() returns last valid rate while paused");

        _logPass();
    }

    function test_GetRateSafe_RevertsWhenPaused() public {
        _logCase("test_GetRateSafe_RevertsWhenPaused", unicode"getRateSafe() 在暂停时会 revert");

        _step("[Step 1] Pause the Accountant");
        vm.prank(admin);
        accountant.pause();
        assertTrue(accountant.paused());
        _step("  PASS: Accountant is paused");

        _step("[Step 2] Call getRateSafe() expecting revert");
        vm.expectRevert(Pausable.EnforcedPause.selector);
        accountant.getRateSafe();
        _step("  PASS: getRateSafe() reverted with EnforcedPause");

        _logPass();
    }

    function test_AccountantPaused_GatewayWritesPaused() public {
        _logCase("test_AccountantPaused_GatewayWritesPaused", unicode"Accountant 暂停后 Gateway 的写入口统一进入暂停语义");

        _step("[Step 1] Pause the real Accountant wired to Gateway");
        vm.prank(admin);
        gatewayAccountant.pause();
        assertTrue(gatewayAccountant.paused(), "gateway accountant should be paused");
        _step("  gatewayAccountant paused");

        _step("[Step 2] gateway.deposit should revert with EnforcedPause");
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert(MantleVaultGateway.EnforcedPause.selector);
        gateway.deposit(100e6);
        _step("  PASS: gateway.deposit reverted");

        _step("[Step 3] gateway.redeem should revert with EnforcedPause");
        vm.expectRevert(MantleVaultGateway.EnforcedPause.selector);
        gateway.redeem(100e6);
        _step("  PASS: gateway.redeem reverted");

        _step("[Step 4] gateway.requestRedeem should revert with EnforcedPause");
        vm.expectRevert(MantleVaultGateway.EnforcedPause.selector);
        gateway.requestRedeem(100e6);
        _step("  PASS: gateway.requestRedeem reverted");
        vm.stopPrank();

        _logPass();
    }

    function test_VaultPaused_AccountantFeePathFails() public {
        _logCase(
            "test_VaultPaused_AccountantFeePathFails",
            unicode"Vault 暂停时，updateExchangeRate 仍可成功，但 settleManagementFee() 会失败"
        );

        _step("[Step 1] Seed fee base after real user deposit so settleManagementFee will mint shares");
        vm.warp(block.timestamp + 1);
        _executeGatewaySettleFee();
        assertGt(gatewayAccountant.totalSharesLastSettle(), 0, "fee base should be seeded");
        _step("  fee base seeded from current vault totalSupply");

        _step("[Step 2] Configure the real Gateway Accountant with minInterval=0 and advance time");
        vm.prank(admin);
        gatewayAccountant.setRiskParams(100, 0);
        vm.warp(block.timestamp + 30 days);

        _step("[Step 3] Pause the real Vault");
        vm.prank(admin);
        vault.pause();
        assertTrue(vault.paused(), "vault should be paused");
        _step("  vault is paused");

        _step("[Step 4] updateExchangeRate should succeed (no mintFeeShares call)");
        uint64 newRate = 1.001e18;
        _executeGatewayRateUpdate(newRate, uint64(vm.getBlockTimestamp()));
        assertEq(gatewayAccountant.lastExchangeRate(), newRate, "rate updated despite vault pause");
        _step("  PASS: updateExchangeRate succeeded - rate updated despite vault being paused");

        _step("[Step 5] settleManagementFee should revert because vault.mintFeeShares is paused");
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _executeGatewaySettleFee();
        _step("  PASS: settleManagementFee reverted with EnforcedPause");

        _logPass();
    }

    function test_SettleManagementFee_NonExecutorRejected() public {
        _logCase(
            "test_SettleManagementFee_NonExecutorRejected",
            unicode"非 EXECUTOR_ROLE 不可调用 settleManagementFee()"
        );

        _step("[Step 1] Non-executor user calls settleManagementFee directly");
        bytes32 executorRole = accountant.ACCOUNTANT_EXECUTOR_ROLE();
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user,
                executorRole
            )
        );
        accountant.settleManagementFee();
        _step("  PASS: reverted with AccessControlUnauthorizedAccount");

        _logPass();
    }

    function test_SettleManagementFee_AccountantPausedRejected() public {
        _logCase(
            "test_SettleManagementFee_AccountantPausedRejected",
            unicode"Accountant 暂停时 settleManagementFee() 被拒绝"
        );

        _step("[Step 1] Pause the Accountant");
        vm.prank(admin);
        accountant.pause();
        assertTrue(accountant.paused());
        _step("  Accountant is paused");

        _step("[Step 2] Call settleManagementFee via full chain - expect EnforcedPause");
        vm.prank(bot);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        accountantExecutor.executeSettleManagementFee(address(accountant));
        _step("  PASS: settleManagementFee reverted with EnforcedPause");

        _logPass();
    }

    // =============================================================
    //  P1 — Admin setters boundary tests
    // =============================================================

    function test_SetRiskParams_Boundary() public {
        _logCase("test_SetRiskParams_Boundary", unicode"setRiskParams 偏差边界校验");

        _step("[Step 1] setRiskParams(0, 20 hours) should revert");
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(Accountant.Accountant__InvalidDeviation.selector, 0));
        accountant.setRiskParams(0, 20 hours);
        _step("  PASS: reverted with InvalidDeviation(0)");

        _step("[Step 2] setRiskParams(MAX_DEVIATION_CEILING+1, 20 hours) should revert");
        uint32 tooHighDev = accountant.MAX_DEVIATION_CEILING() + 1;
        vm.expectRevert(abi.encodeWithSelector(Accountant.Accountant__InvalidDeviation.selector, tooHighDev));
        accountant.setRiskParams(tooHighDev, 20 hours);
        _step("  PASS: reverted with InvalidDeviation");

        _step("[Step 3] setRiskParams(500, 0) should succeed");
        accountant.setRiskParams(500, 0);
        assertEq(accountant.maxAllowedDeviation(), 500);
        assertEq(accountant.minUpdateInterval(), 0);
        _step("  PASS: setRiskParams(500, 0) succeeded, minInterval=0 allows instant updates");
        vm.stopPrank();

        _logPass();
    }

    function test_SetManagementFeeRate_Boundary() public {
        _logCase("test_SetManagementFeeRate_Boundary", unicode"setManagementFeeRate 边界校验");

        _step("[Step 1] setManagementFeeRate(MAX_MANAGEMENT_FEE_BPS+1) should revert");
        vm.startPrank(admin);
        uint32 tooHighFee = accountant.MAX_MANAGEMENT_FEE_BPS() + 1;
        vm.expectRevert(abi.encodeWithSelector(Accountant.Accountant__InvalidFeeRate.selector, tooHighFee));
        accountant.setManagementFeeRate(tooHighFee);
        _step("  PASS: reverted with InvalidFeeRate");

        _step("[Step 2] setManagementFeeRate(0) should succeed");
        accountant.setManagementFeeRate(0);
        assertEq(accountant.managementFeeRate(), 0);
        _step("  PASS: managementFeeRate set to 0");
        vm.stopPrank();

        _logPass();
    }

    function test_SetMaxComputeAge_Boundary() public {
        _logCase("test_SetMaxComputeAge_Boundary", unicode"setMaxComputeAge 边界校验");

        _step("[Step 1] setMaxComputeAge(0) should revert");
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(Accountant.Accountant__InvalidComputeAge.selector, 0));
        accountant.setMaxComputeAge(0);
        _step("  PASS: reverted with InvalidComputeAge(0)");

        _step("[Step 2] setMaxComputeAge(MAX_COMPUTE_AGE_CEILING+1) should revert");
        uint32 tooOldAge = accountant.MAX_COMPUTE_AGE_CEILING() + 1;
        vm.expectRevert(abi.encodeWithSelector(Accountant.Accountant__InvalidComputeAge.selector, tooOldAge));
        accountant.setMaxComputeAge(tooOldAge);
        _step("  PASS: reverted with InvalidComputeAge");

        _step("[Step 3] setMaxComputeAge(600) should succeed");
        accountant.setMaxComputeAge(600);
        assertEq(accountant.maxComputeAge(), 600);
        _step(string.concat("  maxComputeAge: ", vm.toString(uint256(accountant.maxComputeAge()))));
        _step("  PASS: maxComputeAge updated to 600");
        vm.stopPrank();

        _logPass();
    }

    function test_SetVault_ChangeVault() public {
        _logCase("test_SetVault_ChangeVault", unicode"setVault 更换关联 Vault");

        _step("[Step 1] setVault(address(0)) should revert");
        vm.startPrank(admin);
        vm.expectRevert(Accountant.Accountant__ZeroAddress.selector);
        accountant.setVault(address(0));
        _step("  PASS: reverted with ZeroAddress");

        _step("[Step 2] setVault(vaultB) should succeed");
        address vaultB = makeAddr("vaultB");
        address oldVault = address(accountant.vault());
        vm.expectEmit(true, true, false, true, address(accountant));
        emit Accountant.VaultUpdated(oldVault, vaultB);
        accountant.setVault(vaultB);
        assertEq(address(accountant.vault()), vaultB);
        _step(string.concat("  vault() = ", vm.toString(address(accountant.vault()))));
        _step("  PASS: vault updated and VaultUpdated event emitted");
        vm.stopPrank();

        _logPass();
    }

    // =============================================================
    //  P1 — Fee settlement edge case
    // =============================================================

    function test_FeeSettlement_ZeroTimeDiff() public {
        _logCase("test_FeeSettlement_ZeroTimeDiff", unicode"管理费结算时间差为 0 → 不铸造 shares");

        _step("[Step 1] Verify lastFeeSettleTimestamp == block.timestamp from initialization");
        assertEq(accountant.lastFeeSettleTimestamp(), block.timestamp, "lastFeeSettleTimestamp == block.timestamp");
        _step(string.concat("  lastFeeSettleTimestamp: ", vm.toString(uint256(accountant.lastFeeSettleTimestamp()))));

        _step("[Step 2] Call settleManagementFee immediately (timeElapsed=0)");
        uint256 supplyBefore = mockVault._totalSupply();
        _executeSettleFee();
        _step("  settleManagementFee called");

        _step("[Step 3] Verify no fee shares minted");
        assertEq(mockVault._totalSupply(), supplyBefore, "totalSupply unchanged - timeElapsed=0 means no fee");
        _step(string.concat("  totalSupply unchanged: ", vm.toString(mockVault._totalSupply())));
        _step("  PASS: settleManagementFee called but feeShares=0, no mintFeeShares");

        _logPass();
    }

    function test_SettleManagementFee_UpdatesTotalSharesLastSettle() public {
        _logCase(
            "test_SettleManagementFee_UpdatesTotalSharesLastSettle",
            unicode"settleManagementFee 更新 totalSharesLastSettle 快照"
        );

        _step("[Step 1] Record initial snapshot");
        uint256 s0 = accountant.totalSharesLastSettle();
        uint256 initialSupply = mockVault._totalSupply();
        assertEq(s0, initialSupply, "initial snapshot matches vault totalSupply");
        _step(string.concat("  initial totalSharesLastSettle: ", vm.toString(s0)));

        _step("[Step 2] Warp 180 days and settle (first settle)");
        vm.warp(block.timestamp + 180 days);
        uint64 feeSettleTsBefore1 = accountant.lastFeeSettleTimestamp();
        _executeSettleFee();

        uint256 totalSupplyAfter1 = mockVault._totalSupply();
        uint256 snapshotAfter1 = accountant.totalSharesLastSettle();
        uint256 feeShares1 = totalSupplyAfter1 - initialSupply;

        // Verify fee shares match contract formula
        uint256 timeElapsed1 = vm.getBlockTimestamp() - feeSettleTsBefore1;
        uint256 shareBase1 = initialSupply < s0 ? initialSupply : s0; // min(currentSupply, totalSharesLastSettle)
        uint256 expectedFee1 = (shareBase1 * MANAGEMENT_FEE_BPS * timeElapsed1) / (10_000 * 365 days);
        assertEq(feeShares1, expectedFee1, "first settle fee matches formula");
        _step(string.concat("  fee shares minted: ", vm.toString(feeShares1)));
        _step(string.concat("  expected by formula: ", vm.toString(expectedFee1)));
        _step(string.concat("  totalSupply after 1st settle: ", vm.toString(totalSupplyAfter1)));
        _step(string.concat("  totalSharesLastSettle after 1st: ", vm.toString(snapshotAfter1)));
        // Snapshot captures supply BEFORE mintFeeShares
        assertEq(snapshotAfter1, initialSupply, "snapshot = supply before fee mint");

        _step("[Step 3] Warp another 180 days and settle (second settle)");
        vm.warp(block.timestamp + 180 days);
        uint64 feeSettleTsBefore2 = accountant.lastFeeSettleTimestamp();
        uint256 supplyBefore2 = mockVault._totalSupply();
        _executeSettleFee();

        uint256 snapshotAfter2 = accountant.totalSharesLastSettle();
        uint256 feeShares2 = mockVault._totalSupply() - supplyBefore2;

        // Second settle: shareBase = min(totalSupplyAfter1, snapshotAfter1) = min(S0+fee1, S0) = S0
        uint256 timeElapsed2 = vm.getBlockTimestamp() - feeSettleTsBefore2;
        uint256 shareBase2 = supplyBefore2 < snapshotAfter1 ? supplyBefore2 : snapshotAfter1;
        uint256 expectedFee2 = (shareBase2 * MANAGEMENT_FEE_BPS * timeElapsed2) / (10_000 * 365 days);
        assertEq(feeShares2, expectedFee2, "second settle fee matches formula");
        _step(string.concat("  2nd fee shares: ", vm.toString(feeShares2)));
        _step(string.concat("  2nd expected: ", vm.toString(expectedFee2)));
        _step(string.concat("  totalSharesLastSettle after 2nd: ", vm.toString(snapshotAfter2)));
        // Now snapshot should include the fee shares from first settle
        assertEq(snapshotAfter2, totalSupplyAfter1,
            "snapshot updated to include previously minted fee shares");
        _step("  PASS: totalSharesLastSettle updated to reflect new supply base");

        _logPass();
    }

    function test_SettleAndUpdateRate_OrderIndependent() public {
        _logCase(
            "test_SettleAndUpdateRate_OrderIndependent",
            unicode"settleManagementFee 与 updateExchangeRate 调用顺序不影响费用金额，但影响中间状态"
        );

        // ── Use real Gateway stack (gatewayAccountant + vault + gateway) ──

        _step("[Step 1] Setup: set cooldown=0 on gatewayAccountant, seed fee base, warp 180 days");
        vm.prank(admin);
        gatewayAccountant.setRiskParams(100, 0); // 1% deviation, 0 cooldown
        // Seed fee base so totalSharesLastSettle is populated from current supply
        vm.warp(block.timestamp + 1);
        _executeGatewaySettleFee();

        uint64 feeSettleTsBefore = gatewayAccountant.lastFeeSettleTimestamp();
        uint256 totalSharesLastSettleBefore = gatewayAccountant.totalSharesLastSettle();
        vm.warp(block.timestamp + 180 days);

        // Compute expected fee from contract formula
        uint256 timeElapsed = vm.getBlockTimestamp() - feeSettleTsBefore;
        uint256 currentSupply = vault.totalSupply();
        uint256 shareBase = currentSupply < totalSharesLastSettleBefore
            ? currentSupply : totalSharesLastSettleBefore;
        uint256 expectedFee = (shareBase * MANAGEMENT_FEE_BPS * timeElapsed) / (10_000 * 365 days);

        // Prepare a fresh user for intermediate deposit
        address bob = makeAddr("bob");
        uint256 depositAmount = 500e6;
        usdc.mint(bob, depositAmount * 2); // enough for both scenarios
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);

        uint64 newRate = 1.005e18;

        _step("[Step 2] Snapshot for two-path comparison");
        uint256 snapId = vm.snapshot();

        // ── Scenario A: settle first, user deposits, then update rate ──
        _step("[Scenario A] Settle fee first, then user deposits, then update rate");
        _executeGatewaySettleFee();
        uint256 treasurySharesA = vault.balanceOf(treasury);
        uint256 feeSharesA = treasurySharesA; // treasury only gets fee shares here
        _step(string.concat("  A: fee shares = ", vm.toString(feeSharesA)));
        assertEq(feeSharesA, expectedFee, "A: fee matches formula");

        // User deposits between settle and rate update
        // At this point: fee shares diluted existing holders, but rate is still old (1e18)
        uint256 rateBeforeA = gatewayAccountant.lastExchangeRate();
        assertEq(rateBeforeA, INITIAL_RATE, "A: rate still old after settle");
        vm.prank(bob);
        gateway.deposit(depositAmount);
        uint256 bobSharesA = vault.balanceOf(bob);
        _step(string.concat("  A: bob shares from deposit between settle and rate update = ", vm.toString(bobSharesA)));

        // Now update rate
        _executeGatewayRateUpdate(newRate, uint64(vm.getBlockTimestamp()));
        assertEq(gatewayAccountant.lastExchangeRate(), newRate, "rate updated in A");

        _step("[Revert to snapshot for Scenario B]");
        vm.revertTo(snapId);

        // ── Scenario B: update rate first, user deposits, then settle ──
        _step("[Scenario B] Update rate first, then user deposits, then settle fee");
        _executeGatewayRateUpdate(newRate, uint64(vm.getBlockTimestamp()));
        assertEq(gatewayAccountant.lastExchangeRate(), newRate, "rate updated in B");

        // User deposits between rate update and settle
        // At this point: rate is new (1.005e18), no dilution yet
        vm.prank(bob);
        gateway.deposit(depositAmount);
        uint256 bobSharesB = vault.balanceOf(bob);
        _step(string.concat("  B: bob shares from deposit between rate update and settle = ", vm.toString(bobSharesB)));

        // Now settle fee
        _executeGatewaySettleFee();
        uint256 treasurySharesB = vault.balanceOf(treasury);
        uint256 feeSharesB = treasurySharesB;
        _step(string.concat("  B: fee shares = ", vm.toString(feeSharesB)));
        assertEq(feeSharesB, expectedFee, "B: fee matches formula");

        // ── Verify ──
        _step("[Step 3] Compare fee shares (should be identical)");
        assertEq(feeSharesA, feeSharesB,
            "fee amount identical regardless of order (formula does not depend on exchangeRate)");
        _step(string.concat("  expected by formula: ", vm.toString(expectedFee)));
        _step("  PASS: call order does not affect fee amount");

        _step("[Step 4] Verify intermediate state difference");
        // Scenario A: user deposited after dilution but at old rate → more shares (rate still 1e18)
        // Scenario B: user deposited before dilution but at new rate → fewer shares (rate now 1.005e18)
        assertGt(bobSharesA, bobSharesB,
            "A: user gets more shares (old rate, post-dilution) vs B: fewer shares (new rate, pre-dilution)");
        _step(string.concat("  bob shares A (old rate, diluted): ", vm.toString(bobSharesA)));
        _step(string.concat("  bob shares B (new rate, not diluted): ", vm.toString(bobSharesB)));
        _step("  PASS: intermediate state differs - order matters for user experience");

        _logPass();
    }

    // =============================================================
    //  P0 — Circuit breaker state preservation
    // =============================================================

    function test_CircuitBreaker_NoStateUpdate() public {
        _logCase("test_CircuitBreaker_NoStateUpdate", unicode"circuit breaker 触发后不更新关键状态");

        _step("[Step 1] Set deviation=100 (1%), cooldown=0");
        vm.prank(admin);
        accountant.setRiskParams(100, 0);

        _step("[Step 2] Record state before circuit breaker");
        uint256 rateBefore = accountant.lastExchangeRate();
        uint64 updateTsBefore = accountant.lastUpdateTimestamp();
        uint64 computeTsBefore = accountant.lastComputeTimestamp();
        _step(string.concat("  rateBefore: ", vm.toString(rateBefore)));
        _step(string.concat("  updateTsBefore: ", vm.toString(uint256(updateTsBefore))));
        _step(string.concat("  computeTsBefore: ", vm.toString(uint256(computeTsBefore))));

        _step("[Step 3] Trigger circuit breaker with 5% deviation (> 1% threshold)");
        vm.warp(block.timestamp + 1);
        uint64 deviatingRate = 1.05e18;
        _executeRateUpdate(deviatingRate, uint64(vm.getBlockTimestamp()));
        _step("  Circuit breaker triggered");

        _step("[Step 4] Verify all state unchanged");
        assertEq(accountant.lastExchangeRate(), rateBefore);
        _step("  PASS: lastExchangeRate unchanged");
        assertEq(accountant.lastUpdateTimestamp(), updateTsBefore);
        _step("  PASS: lastUpdateTimestamp unchanged");
        assertEq(accountant.lastComputeTimestamp(), computeTsBefore);
        _step("  PASS: lastComputeTimestamp unchanged");
        assertTrue(accountant.paused());
        _step("  PASS: Accountant is paused");

        _logPass();
    }

    function test_CircuitBreakerRecovery_SettleFeeResumes() public {
        _logCase(
            "test_CircuitBreakerRecovery_SettleFeeResumes",
            unicode"circuit breaker 恢复后 settleManagementFee 可正常调用"
        );

        _step("[Step 1] Trigger circuit breaker to pause Accountant");
        vm.prank(admin);
        accountant.setRiskParams(100, 0); // 1% deviation, 0 cooldown
        vm.warp(block.timestamp + 30 days);
        _executeRateUpdate(1.05e18, uint64(vm.getBlockTimestamp())); // 5% triggers CB
        assertTrue(accountant.paused(), "Accountant should be paused");
        _step("  Accountant paused by circuit breaker");

        _step("[Step 2] Attempt settleManagementFee while paused - should revert");
        vm.prank(bot);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        accountantExecutor.executeSettleManagementFee(address(accountant));
        _step("  PASS: settleManagementFee reverted with EnforcedPause");

        _step("[Step 3] Admin calls emergencyRateUpdate to recover");
        vm.prank(admin);
        accountant.emergencyRateUpdate(1.01e18);
        assertFalse(accountant.paused(), "Accountant should be unpaused");
        _step("  Accountant recovered via emergencyRateUpdate");

        _step("[Step 4] settleManagementFee now succeeds");
        uint64 feeSettleTsBefore = accountant.lastFeeSettleTimestamp();
        uint256 totalSharesLastSettleBefore = accountant.totalSharesLastSettle();
        uint256 supplyBefore = mockVault._totalSupply();
        _executeSettleFee();
        uint256 feeShares = mockVault._totalSupply() - supplyBefore;

        // Verify fee matches contract formula: includes entire 30 days (including pause period)
        uint256 timeElapsed = vm.getBlockTimestamp() - feeSettleTsBefore;
        uint256 shareBase = supplyBefore < totalSharesLastSettleBefore
            ? supplyBefore : totalSharesLastSettleBefore;
        uint256 expectedFee = (shareBase * MANAGEMENT_FEE_BPS * timeElapsed) / (10_000 * 365 days);
        assertEq(feeShares, expectedFee, "fee matches formula (includes pause period)");
        _step(string.concat("  fee shares minted: ", vm.toString(feeShares)));
        _step(string.concat("  expected by formula: ", vm.toString(expectedFee)));
        _step(string.concat("  timeElapsed (includes pause): ", vm.toString(timeElapsed)));
        _step("  PASS: settleManagementFee works after circuit breaker recovery");

        _logPass();
    }

    // =============================================================
    //  P0 — Emergency rate update
    // =============================================================

    function test_EmergencyRateUpdate_BypassDeviationAndCooldown() public {
        _logCase(
            "test_EmergencyRateUpdate_BypassDeviationAndCooldown",
            unicode"admin 可通过 emergencyRateUpdate 绕过偏差与冷却期限制修正汇率"
        );

        _step("[Step 1] Do a normal update first, then attempt 50% deviation via updateExchangeRate");
        _skipCooldown();
        _doUpdate(INITIAL_RATE);
        uint256 oldRate = accountant.lastExchangeRate();
        uint64 emergencyRate = 0.5e18; // 50% deviation from 1e18

        _step("[Step 2] Attempt updateExchangeRate with 50% deviation - triggers circuit breaker, rate unchanged");
        _skipCooldown();
        _executeRateUpdate(emergencyRate, uint64(vm.getBlockTimestamp()));
        assertTrue(accountant.paused(), "circuit breaker should have paused Accountant");
        assertEq(accountant.lastExchangeRate(), oldRate, "rate should be unchanged after circuit breaker");
        _step("  PASS: updateExchangeRate triggered circuit breaker, rate unchanged, Accountant paused");

        _step("[Step 3] Admin calls emergencyRateUpdate to bypass deviation and paused state");
        vm.prank(admin);
        vm.expectEmit(false, false, false, true, address(accountant));
        emit Accountant.EmergencyRateUpdated(oldRate, emergencyRate, block.timestamp);
        accountant.emergencyRateUpdate(emergencyRate);

        _step("[Step 4] Verify rate updated and Accountant unpaused");
        assertEq(accountant.lastExchangeRate(), emergencyRate);
        assertFalse(accountant.paused());
        _step(string.concat("  lastExchangeRate: ", vm.toString(accountant.lastExchangeRate())));
        _step("  PASS: emergencyRateUpdate bypassed deviation, updated rate, and unpaused Accountant");

        _logPass();
    }

    function test_EmergencyRateUpdate_RecoverFromCircuitBreaker() public {
        _logCase(
            "test_EmergencyRateUpdate_RecoverFromCircuitBreaker",
            unicode"emergencyRateUpdate 可在 circuit breaker 后恢复系统可用性"
        );

        _step("[Step 1] Trigger circuit breaker");
        vm.prank(admin);
        accountant.setRiskParams(100, 0); // 1% deviation, 0 cooldown
        vm.warp(block.timestamp + 1);
        _executeRateUpdate(1.05e18, uint64(vm.getBlockTimestamp())); // 5% deviation triggers CB
        assertTrue(accountant.paused());
        _step("  PASS: Accountant paused by circuit breaker");

        _step("[Step 2] Admin calls emergencyRateUpdate to recover");
        uint64 recoveryRate = 1.01e18;
        vm.prank(admin);
        accountant.emergencyRateUpdate(recoveryRate);

        _step("[Step 3] Verify Accountant is unpaused and getRateSafe works");
        assertFalse(accountant.paused());
        _step("  PASS: Accountant is unpaused");

        uint256 rate = accountant.getRateSafe();
        assertEq(rate, recoveryRate);
        _step(string.concat("  getRateSafe() = ", vm.toString(rate)));
        _step("  PASS: getRateSafe() returns recovery rate");

        _logPass();
    }

    function test_EmergencyRateUpdate_NoFeeSettlement() public {
        _logCase(
            "test_EmergencyRateUpdate_NoFeeSettlement",
            unicode"emergencyRateUpdate 不结算管理费（与 updateExchangeRate 一致）"
        );

        _step("[Step 1] Advance 30 days for potential fee accrual");
        vm.warp(block.timestamp + 30 days);

        _step("[Step 2] Record state before emergency update");
        uint64 feeSettleTsBefore = accountant.lastFeeSettleTimestamp();
        uint256 supplyBefore = mockVault._totalSupply();
        _step(string.concat("  lastFeeSettleTimestamp: ", vm.toString(uint256(feeSettleTsBefore))));
        _step(string.concat("  totalSupply: ", vm.toString(supplyBefore)));

        _step("[Step 3] Admin calls emergencyRateUpdate");
        uint64 newRate = 1.01e18;
        vm.prank(admin);
        accountant.emergencyRateUpdate(newRate);

        _step("[Step 4] Verify no fee settlement occurred");
        assertEq(accountant.lastExchangeRate(), newRate, "rate updated");
        assertEq(accountant.lastFeeSettleTimestamp(), feeSettleTsBefore, "lastFeeSettleTimestamp unchanged");
        assertEq(mockVault._totalSupply(), supplyBefore, "totalSupply unchanged - no mintFeeShares called");
        _step("  PASS: emergencyRateUpdate did not settle fees");

        _logPass();
    }

    function test_EmergencyRateUpdate_SucceedsWhenVaultPaused() public {
        _logCase(
            "test_EmergencyRateUpdate_SucceedsWhenVaultPaused",
            unicode"emergencyRateUpdate 在 Vault 暂停时仍可成功"
        );

        _step("[Step 1] Trigger circuit breaker to pause gatewayAccountant (real stack)");
        vm.prank(admin);
        gatewayAccountant.setRiskParams(100, 0); // 1% deviation, 0 cooldown
        vm.warp(block.timestamp + 1);
        _executeGatewayRateUpdate(1.05e18, uint64(vm.getBlockTimestamp())); // 5% triggers CB
        assertTrue(gatewayAccountant.paused(), "gatewayAccountant should be paused by CB");
        _step("  gatewayAccountant paused by circuit breaker");

        _step("[Step 2] Pause the real Vault via admin");
        vm.prank(admin);
        vault.pause();
        assertTrue(vault.paused(), "vault should be paused");
        _step("  real vault is paused");

        _step("[Step 3] Admin calls emergencyRateUpdate - should succeed despite vault pause");
        uint64 recoveryRate = 1.01e18;
        vm.prank(admin);
        gatewayAccountant.emergencyRateUpdate(recoveryRate);

        _step("[Step 4] Verify success - no deadlock");
        assertEq(gatewayAccountant.lastExchangeRate(), recoveryRate, "rate updated");
        assertFalse(gatewayAccountant.paused(), "gatewayAccountant unpaused by emergency update");
        _step("  PASS: emergencyRateUpdate succeeded - vault pause does not block emergency recovery");

        _logPass();
    }

    function test_EmergencyRateUpdate_NonAdminRejected() public {
        _logCase("test_EmergencyRateUpdate_NonAdminRejected", unicode"非 admin 不可调用 emergencyRateUpdate");

        _step("[Step 1] Non-admin user calls emergencyRateUpdate");
        bytes32 adminRole = accountant.DEFAULT_ADMIN_ROLE();
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user,
                adminRole
            )
        );
        accountant.emergencyRateUpdate(1.01e18);
        _step("  PASS: reverted with AccessControlUnauthorizedAccount");

        _logPass();
    }

    function test_EmergencyRateUpdate_ZeroRejected() public {
        _logCase("test_EmergencyRateUpdate_ZeroRejected", unicode"emergencyRateUpdate(0) 被拒绝");

        _step("[Step 1] Admin calls emergencyRateUpdate(0)");
        vm.prank(admin);
        vm.expectRevert(Accountant.Accountant__InvalidRate.selector);
        accountant.emergencyRateUpdate(0);
        _step("  PASS: reverted with InvalidRate");

        _logPass();
    }

    // =============================================================
    //  P1 — AccountantExecutor full chain
    // =============================================================

    function test_AccountantExecutor_SettleFeeFullChain() public {
        _logCase(
            "test_AccountantExecutor_SettleFeeFullChain",
            unicode"AccountantExecutor.executeSettleManagementFee 全链路"
        );

        _step("[Step 1] Seed fee base from current vault supply");
        vm.warp(block.timestamp + 1);
        _executeGatewaySettleFee();
        uint256 totalSharesLastSettleBefore = gatewayAccountant.totalSharesLastSettle();
        assertGt(totalSharesLastSettleBefore, 0, "fee base seeded");
        _step(string.concat("  totalSharesLastSettle: ", vm.toString(totalSharesLastSettleBefore)));

        _step("[Step 2] Advance 180 days for fee accrual");
        vm.warp(block.timestamp + 180 days);
        uint64 feeSettleTsBefore = gatewayAccountant.lastFeeSettleTimestamp();
        uint256 currentSupply = vault.totalSupply();
        uint256 treasuryBefore = vault.balanceOf(treasury);
        _step(string.concat("  vault totalSupply: ", vm.toString(currentSupply)));
        _step(string.concat("  treasury shares before: ", vm.toString(treasuryBefore)));

        _step("[Step 3] Compute expected fee from contract formula");
        uint256 timeElapsed = vm.getBlockTimestamp() - feeSettleTsBefore;
        uint256 shareBase = currentSupply < totalSharesLastSettleBefore
            ? currentSupply : totalSharesLastSettleBefore;
        uint256 expectedFee = (shareBase * MANAGEMENT_FEE_BPS * timeElapsed) / (10_000 * 365 days);
        assertGt(expectedFee, 0, "expected fee > 0");
        _step(string.concat("  expected fee: ", vm.toString(expectedFee)));

        _step("[Step 4] bot -> accountantExecutor.executeSettleManagementFee -> accountant -> vault.mintFeeShares");
        vm.expectEmit(true, true, false, true, address(accountantExecutor));
        emit AccountantExecutor.ManagementFeeSettled(bot, address(gatewayAccountant));
        _executeGatewaySettleFee();
        _step("  PASS: full chain call succeeded");

        _step("[Step 5] Verify fee shares minted to treasury");
        uint256 treasuryAfter = vault.balanceOf(treasury);
        uint256 feeSharesMinted = treasuryAfter - treasuryBefore;
        assertEq(feeSharesMinted, expectedFee, "treasury received fee shares matching formula");
        _step(string.concat("  fee shares minted to treasury: ", vm.toString(feeSharesMinted)));

        _step("[Step 6] Verify lastFeeSettleTimestamp updated");
        assertEq(
            gatewayAccountant.lastFeeSettleTimestamp(),
            uint64(vm.getBlockTimestamp()),
            "lastFeeSettleTimestamp updated"
        );
        _step("  PASS: lastFeeSettleTimestamp updated to current block");

        _logPass();
    }
}
