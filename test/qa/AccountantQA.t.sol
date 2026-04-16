// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Accountant} from "../../src/accountant/Accountant.sol";
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
    uint256 public totalFeeMintCalls;
    bool public pauseFlag;

    function mintFeeShares(uint256 shares) external {
        if (pauseFlag) revert("Pausable: paused");
        lastFeeShares = shares;
        totalFeeMintCalls++;
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function setTotalSupply(uint256 supply) external {
        _totalSupply = supply;
    }

    function setPaused(bool p) external {
        pauseFlag = p;
    }

    function asset() external pure returns (address) {
        return address(0xA);
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

/// @dev Mock accountant used by the real Vault (for Gateway integration sub-tests).
contract MockAccountant_Acc {
    bool public pauseStatus;
    uint256 public exchangeRate = 1e18;
    uint32 public managementFeeRate_ = 100;

    error EnforcedPause();

    function getRate() external view returns (uint256) {
        return exchangeRate;
    }

    function getRateSafe() external view returns (uint256) {
        if (pauseStatus) revert EnforcedPause();
        return exchangeRate;
    }

    function managementFeeRate() external view returns (uint32) {
        return managementFeeRate_;
    }

    function setPauseStatus(bool paused_) external {
        pauseStatus = paused_;
    }

    function setExchangeRate(uint256 newRate) external {
        exchangeRate = newRate;
    }
}

/**
 * @title  AccountantQATest
 * @notice QA scenario tests for Accountant (Accountant 汇率与管理费场景).
 */
contract AccountantQATest is Test {
    Accountant internal accountant;
    MockVaultForAccountant internal mockVault;

    // For Gateway integration sub-tests
    MockUSDC_Acc internal usdc;
    MockSanctionsOracle_Acc internal oracle;
    MockAccountant_Acc internal mockAccountantForGw;
    MantleYieldVault internal vault;
    MantleVaultGateway internal gateway;
    VaultFactory internal vaultFactory;
    GatewayFactory internal gatewayFactory;

    address internal admin = makeAddr("admin");
    address internal executor = makeAddr("executor");
    address internal pauser = makeAddr("pauser");
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
        mockVault = new MockVaultForAccountant();
        mockVault.setTotalSupply(1_000_000e18);

        Accountant impl = new Accountant();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), admin);
        BeaconProxy proxy = new BeaconProxy(
            address(beacon),
            abi.encodeCall(Accountant.initialize, (address(mockVault), INITIAL_RATE, MANAGEMENT_FEE_BPS, admin))
        );
        accountant = Accountant(address(proxy));

        vm.startPrank(admin);
        accountant.grantRole(accountant.EXECUTOR_ROLE(), executor);
        accountant.grantRole(accountant.PAUSER_ROLE(), pauser);
        vm.stopPrank();

        // --- Full stack for Gateway integration sub-tests ---
        usdc = new MockUSDC_Acc();
        oracle = new MockSanctionsOracle_Acc();
        mockAccountantForGw = new MockAccountant_Acc();

        MantleYieldVault vaultImpl = new MantleYieldVault();
        MantleVaultGateway gwImpl = new MantleVaultGateway();
        vaultFactory = new VaultFactory(address(vaultImpl), admin);
        gatewayFactory = new GatewayFactory(address(gwImpl), admin);

        address vaultAddr = vaultFactory.deployVault();
        address gwAddr = gatewayFactory.deployGateway();
        vault = MantleYieldVault(vaultAddr);
        gateway = MantleVaultGateway(gwAddr);

        vm.prank(admin);
        vault.initialize(
            IMantleYieldVault.InitParams({
                asset: IERC20(address(usdc)),
                name: "Mantle RWA Vault",
                symbol: "mRWA",
                admin: admin,
                gateway: gwAddr,
                controller: makeAddr("controller"),
                accountant: address(mockAccountantForGw),
                treasury: treasury,
                maxRedemptionFeeBps: 500,
                redemptionFeeBps: 100,
                minRedeemAmount: 0,
                minDepositAmount: 0
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

    function _doUpdate(uint64 newRate) internal {
        vm.prank(executor);
        accountant.updateExchangeRate(newRate, uint64(block.timestamp));
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
        assertTrue(accountant.hasRole(accountant.EXECUTOR_ROLE(), admin));
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
        vm.expectRevert(Accountant.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl), abi.encodeCall(Accountant.initialize, (address(0), INITIAL_RATE, MANAGEMENT_FEE_BPS, admin))
        );
        _step("  PASS: reverted with ZeroAddress for vault=address(0)");

        _step("[Step 3] admin = address(0) should revert with ZeroAddress");
        vm.expectRevert(Accountant.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(Accountant.initialize, (address(mockVault), INITIAL_RATE, MANAGEMENT_FEE_BPS, address(0)))
        );
        _step("  PASS: reverted with ZeroAddress for admin=address(0)");

        _step("[Step 4] feeRate > MAX_MANAGEMENT_FEE_BPS should revert with InvalidFeeRate");
        uint32 tooHighFee = accountant.MAX_MANAGEMENT_FEE_BPS() + 1;
        vm.expectRevert(abi.encodeWithSelector(Accountant.InvalidFeeRate.selector, tooHighFee));
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(Accountant.initialize, (address(mockVault), INITIAL_RATE, tooHighFee, admin))
        );
        _step(string.concat("  PASS: reverted with InvalidFeeRate for fee=", vm.toString(uint256(tooHighFee))));

        _step("[Step 5] initialRate = 0 should revert with InvalidRate");
        vm.expectRevert(Accountant.InvalidRate.selector);
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
        uint64 computeTs = uint64(block.timestamp);
        vm.prank(executor);
        accountant.updateExchangeRate(newRate, computeTs);
        _step(string.concat("  newRate: ", vm.toString(uint256(newRate))));

        _step("[Step 3] Verify rate and timestamp updated");
        assertEq(accountant.lastExchangeRate(), newRate);
        _step("  PASS: lastExchangeRate == newRate");
        assertEq(accountant.lastUpdateTimestamp(), uint64(block.timestamp));
        _step("  PASS: lastUpdateTimestamp updated");

        _logPass();
    }

    function test_UpdateExchangeRate_ZeroRateRejected() public {
        _logCase("test_UpdateExchangeRate_ZeroRateRejected", unicode"新汇率为 0 被拒绝");

        _step("[Step 1] Skip cooldown and attempt to set rate=0");
        _skipCooldown();
        vm.prank(executor);
        vm.expectRevert(Accountant.InvalidRate.selector);
        accountant.updateExchangeRate(0, uint64(block.timestamp));
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

        vm.prank(executor);
        vm.expectEmit(false, false, false, true, address(accountant));
        emit Accountant.CircuitBreakerTriggered(1000, 500, deviatingRate);
        accountant.updateExchangeRate(deviatingRate, uint64(block.timestamp));
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

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(Accountant.StaleComputeTimestamp.selector, lastTs - 1, lastTs));
        accountant.updateExchangeRate(INITIAL_RATE, lastTs - 1);
        _step("  PASS: reverted with StaleComputeTimestamp");

        _logPass();
    }

    function test_ComputeTimestamp_FutureRejected() public {
        _logCase("test_ComputeTimestamp_FutureRejected", unicode"computeTimestamp 在未来时被拒绝");

        _step("[Step 1] Skip cooldown");
        _skipCooldown();

        _step("[Step 2] Attempt update with computeTimestamp > block.timestamp");
        uint64 futureTs = uint64(block.timestamp + 100);
        _step(string.concat("  futureTs: ", vm.toString(uint256(futureTs))));
        _step(string.concat("  block.timestamp: ", vm.toString(block.timestamp)));

        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(Accountant.FutureComputeTimestamp.selector, futureTs, block.timestamp)
        );
        accountant.updateExchangeRate(INITIAL_RATE, futureTs);
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
        uint64 tooOldTs = uint64(block.timestamp - 2 hours);
        // tooOldTs must be > lastComputeTimestamp (which is 1000 from setUp)
        // block.timestamp is now ~ 1000 + 20h + 1 + 2h, tooOldTs ~ 1000 + 20h + 1
        // lastComputeTimestamp is 1000, so tooOldTs > 1000 => OK
        _step(string.concat("  tooOldTs: ", vm.toString(uint256(tooOldTs))));
        _step(string.concat("  block.timestamp: ", vm.toString(block.timestamp)));

        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(
                Accountant.ComputeTimestampTooOld.selector, tooOldTs, block.timestamp, maxAge
            )
        );
        accountant.updateExchangeRate(INITIAL_RATE, tooOldTs);
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
        uint64 newTs = uint64(block.timestamp);

        vm.prank(executor);
        vm.expectPartialRevert(Accountant.CooldownNotElapsed.selector);
        accountant.updateExchangeRate(INITIAL_RATE, newTs);
        _step("  PASS: reverted with CooldownNotElapsed");

        _logPass();
    }

    function test_UpdateRate_SettlesManagementFee() public {
        _logCase("test_UpdateRate_SettlesManagementFee", unicode"更新汇率时自动结算管理费并 mint fee shares");

        _step("[Step 1] Set minInterval=0 to simplify test, advance time");
        vm.prank(admin);
        accountant.setRiskParams(100, 0); // keep deviation=1%, cooldown=0

        _step("[Step 2] Advance 365 days for fee accrual");
        vm.warp(block.timestamp + 365 days);
        uint256 supply = mockVault._totalSupply();
        _step(string.concat("  vault totalSupply: ", vm.toString(supply)));
        _step(string.concat("  managementFeeRate: ", vm.toString(uint256(accountant.managementFeeRate()))));

        _step("[Step 3] Update rate, triggering fee settlement");
        uint64 newRate = 1.005e18;
        vm.prank(executor);
        accountant.updateExchangeRate(newRate, uint64(block.timestamp));

        _step("[Step 4] Verify mintFeeShares was called");
        assertTrue(mockVault.totalFeeMintCalls() > 0);
        _step(string.concat("  totalFeeMintCalls: ", vm.toString(mockVault.totalFeeMintCalls())));
        _step(string.concat("  lastFeeShares: ", vm.toString(mockVault.lastFeeShares())));

        // Expected: supply * feeRate * timeElapsed / (MAX_BPS * 365 days)
        // ~= 1_000_000e18 * 100 * 365days / (10_000 * 365days) = 1_000_000e18 * 0.01 = 10_000e18
        // The actual is approximate due to time difference from setUp
        assertTrue(mockVault.lastFeeShares() > 0);
        _step("  PASS: fee shares minted > 0");

        assertEq(accountant.lastExchangeRate(), newRate);
        _step("  PASS: rate updated to newRate");

        _logPass();
    }

    // =============================================================
    //  P1 — Pause scenarios
    // =============================================================

    function test_GetRate_WhenPaused() public {
        _logCase("test_GetRate_WhenPaused", unicode"getRate() 在暂停时仍可读取最后汇率");

        _step("[Step 1] Pause the Accountant");
        vm.prank(pauser);
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
        vm.prank(pauser);
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

        _step("[Step 1] Pause the mock accountant used by Gateway");
        mockAccountantForGw.setPauseStatus(true);
        _step("  mockAccountantForGw paused");

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
        _logCase("test_VaultPaused_AccountantFeePathFails", unicode"Vault 暂停时，Accountant 自动结费路径会失败");

        _step("[Step 1] Configure accountant with minInterval=0 and advance time for fee accrual");
        vm.prank(admin);
        accountant.setRiskParams(100, 0);
        vm.warp(block.timestamp + 30 days);

        _step("[Step 2] Pause the mock vault");
        mockVault.setPaused(true);
        _step("  mockVault is paused");

        _step("[Step 3] Attempt updateExchangeRate, expect revert from mintFeeShares");
        vm.prank(executor);
        vm.expectRevert("Pausable: paused");
        accountant.updateExchangeRate(1.001e18, uint64(block.timestamp));
        _step("  PASS: updateExchangeRate reverted because vault is paused");

        _logPass();
    }

    // =============================================================
    //  P1 — Admin setters boundary tests
    // =============================================================

    function test_SetRiskParams_Boundary() public {
        _logCase("test_SetRiskParams_Boundary", unicode"setRiskParams 偏差边界校验");

        _step("[Step 1] setRiskParams(0, 20 hours) should revert");
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(Accountant.InvalidDeviation.selector, 0));
        accountant.setRiskParams(0, 20 hours);
        _step("  PASS: reverted with InvalidDeviation(0)");

        _step("[Step 2] setRiskParams(1001, 20 hours) should revert (> MAX_DEVIATION_CEILING=1000)");
        vm.expectRevert(abi.encodeWithSelector(Accountant.InvalidDeviation.selector, 1001));
        accountant.setRiskParams(1001, 20 hours);
        _step("  PASS: reverted with InvalidDeviation(1001)");

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

        _step("[Step 1] setManagementFeeRate(501) should revert (> MAX_MANAGEMENT_FEE_BPS=500)");
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(Accountant.InvalidFeeRate.selector, 501));
        accountant.setManagementFeeRate(501);
        _step("  PASS: reverted with InvalidFeeRate(501)");

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
        vm.expectRevert(abi.encodeWithSelector(Accountant.InvalidComputeAge.selector, 0));
        accountant.setMaxComputeAge(0);
        _step("  PASS: reverted with InvalidComputeAge(0)");

        _step("[Step 2] setMaxComputeAge(86401) should revert (> 1 day)");
        vm.expectRevert(abi.encodeWithSelector(Accountant.InvalidComputeAge.selector, 86401));
        accountant.setMaxComputeAge(86401);
        _step("  PASS: reverted with InvalidComputeAge(86401)");

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
        vm.expectRevert(Accountant.ZeroAddress.selector);
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

        _step("[Step 1] Set minInterval=0 so we can update immediately");
        vm.prank(admin);
        accountant.setRiskParams(100, 0);

        _step("[Step 2] Warp forward and do first updateExchangeRate to set lastFeeSettleTimestamp = block.timestamp");
        // setUp warp(1000) → lastComputeTimestamp=1000
        // Warp forward so we have room for two distinct computeTs in the same block
        vm.warp(block.timestamp + 1 days);
        uint64 computeTs1 = uint64(block.timestamp - 2);
        vm.prank(executor);
        accountant.updateExchangeRate(INITIAL_RATE, computeTs1);
        _step("  First update done, lastFeeSettleTimestamp = block.timestamp now");

        _step("[Step 3] Immediately do second updateExchangeRate in same block (timeElapsed=0)");
        uint256 feeMintCallsBefore = mockVault.totalFeeMintCalls();
        uint64 computeTs2 = uint64(block.timestamp - 1); // > computeTs1, <= block.timestamp
        vm.prank(executor);
        accountant.updateExchangeRate(1.001e18, computeTs2);
        _step("  Second update done in same block, timeElapsed=0");

        _step("[Step 4] Verify no additional mintFeeShares call");
        assertEq(mockVault.totalFeeMintCalls(), feeMintCallsBefore);
        _step(string.concat("  totalFeeMintCalls: ", vm.toString(mockVault.totalFeeMintCalls())));
        _step("  PASS: _settleManagementFee called but feeShares=0, no mintFeeShares");

        _logPass();
    }

    // =============================================================
    //  P0 — Circuit breaker state preservation
    // =============================================================

    function test_CircuitBreaker_NoStateUpdate() public {
        _logCase("test_CircuitBreaker_NoStateUpdate", unicode"circuit breaker 触发后不更新关键状态且不结算管理费");

        _step("[Step 1] Set deviation=100 (1%), cooldown=0, advance time for fee accrual");
        vm.prank(admin);
        accountant.setRiskParams(100, 0);
        vm.warp(block.timestamp + 30 days);

        _step("[Step 2] Record state before circuit breaker");
        uint256 rateBefore = accountant.lastExchangeRate();
        uint64 updateTsBefore = accountant.lastUpdateTimestamp();
        uint64 computeTsBefore = accountant.lastComputeTimestamp();
        uint64 feeSettleTsBefore = accountant.lastFeeSettleTimestamp();
        uint256 feeMintCallsBefore = mockVault.totalFeeMintCalls();
        uint256 treasuryBalanceBefore = vault.balanceOf(treasury);
        _step(string.concat("  rateBefore: ", vm.toString(rateBefore)));
        _step(string.concat("  updateTsBefore: ", vm.toString(uint256(updateTsBefore))));
        _step(string.concat("  computeTsBefore: ", vm.toString(uint256(computeTsBefore))));
        _step(string.concat("  feeSettleTsBefore: ", vm.toString(uint256(feeSettleTsBefore))));
        _step(string.concat("  treasuryBalance: ", vm.toString(treasuryBalanceBefore)));

        _step("[Step 3] Trigger circuit breaker with 5% deviation (> 1% threshold)");
        uint64 deviatingRate = 1.05e18;
        vm.prank(executor);
        accountant.updateExchangeRate(deviatingRate, uint64(block.timestamp));
        _step("  Circuit breaker triggered");

        _step("[Step 4] Verify all state unchanged");
        assertEq(accountant.lastExchangeRate(), rateBefore);
        _step("  PASS: lastExchangeRate unchanged");
        assertEq(accountant.lastUpdateTimestamp(), updateTsBefore);
        _step("  PASS: lastUpdateTimestamp unchanged");
        assertEq(accountant.lastComputeTimestamp(), computeTsBefore);
        _step("  PASS: lastComputeTimestamp unchanged");
        assertEq(accountant.lastFeeSettleTimestamp(), feeSettleTsBefore);
        _step("  PASS: lastFeeSettleTimestamp unchanged");
        assertEq(mockVault.totalFeeMintCalls(), feeMintCallsBefore);
        _step("  PASS: no mintFeeShares called");
        assertEq(vault.balanceOf(treasury), treasuryBalanceBefore);
        _step("  PASS: treasury balance unchanged");
        assertTrue(accountant.paused());
        _step("  PASS: Accountant is paused");

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
        vm.prank(executor);
        accountant.updateExchangeRate(emergencyRate, uint64(block.timestamp));
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
        vm.prank(executor);
        accountant.updateExchangeRate(1.05e18, uint64(block.timestamp)); // 5% deviation triggers CB
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
        vm.expectRevert(Accountant.InvalidRate.selector);
        accountant.emergencyRateUpdate(0);
        _step("  PASS: reverted with InvalidRate");

        _logPass();
    }
}
