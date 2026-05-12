// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Accountant} from "../../src/accountant/Accountant.sol";
import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {IMantleVaultGateway} from "../../src/interfaces/vault/IMantleVaultGateway.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {GatewayFactory} from "../../src/vault/GatewayFactory.sol";
import {MantleVaultGateway} from "../../src/vault/MantleVaultGateway.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {VaultFactory} from "../../src/vault/VaultFactory.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Test, Vm, console2} from "forge-std/Test.sol";

// ---------------------------------------------------------------------------
// Mock contracts
// ---------------------------------------------------------------------------

contract MockUSDC_GD is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockSanctionsOracle_GD is ISanctionsOracle {
    mapping(address => bool) private _sanctioned;
    mapping(address => bool) private _whitelisted;

    function initialize(address, address) external override {}

    function isSanctioned(address account) external view override returns (bool) {
        return _sanctioned[account];
    }

    function isWhitelisted(address account) external view override returns (bool) {
        return _whitelisted[account];
    }

    function totalSanctionedCount() external pure override returns (uint256) { return 0; }
    function totalWhitelistedCount() external pure override returns (uint256) { return 0; }
    function lastUpdateTimestamp() external pure override returns (uint256) { return 0; }
    function batchNonce() external pure override returns (uint256) { return 0; }
    function MAX_BATCH_SIZE() external pure override returns (uint256) { return 100; }
    function updateSanctionStatus(address account, bool sanctioned) external override { _sanctioned[account] = sanctioned; }
    function updateSanctionStatusBatch(address[] calldata, bool) external override {}
    function updateWhitelistStatus(address account, bool whitelisted) external override { _whitelisted[account] = whitelisted; }
    function updateWhitelistStatusBatch(address[] calldata, bool) external override {}
}

// ---------------------------------------------------------------------------
// QA Test: Gateway Deposit Scenarios
// ---------------------------------------------------------------------------

contract GatewayDepositQATest is Test {
    MockUSDC_GD internal usdc;
    MockSanctionsOracle_GD internal oracle;
    Accountant internal accountant;
    MantleYieldVault internal vault;
    MantleVaultGateway internal gateway;
    VaultFactory internal vaultFactory;
    GatewayFactory internal gatewayFactory;

    address internal admin = makeAddr("admin");
    address internal controllerAddr = makeAddr("controller");
    address internal treasuryAddr = makeAddr("treasury");
    address internal sanctionSafe = makeAddr("sanctionSafe");
    address internal userA = makeAddr("userA");

    uint256 constant DEPOSIT_AMOUNT = 1000e6;
    uint256 constant MIN_DEPOSIT = 100e6;
    uint256 constant FEE_BPS = 100; // 1%

    function setUp() public {
        vm.warp(1000);

        usdc = new MockUSDC_GD();
        oracle = new MockSanctionsOracle_GD();

        MantleYieldVault vaultImpl = new MantleYieldVault();
        MantleVaultGateway gatewayImpl = new MantleVaultGateway();
        Accountant acctImpl = new Accountant();
        vaultFactory = new VaultFactory(address(vaultImpl), admin);
        gatewayFactory = new GatewayFactory(address(gatewayImpl), admin);

        address vaultAddr = vaultFactory.deployVault();
        address gatewayAddr = gatewayFactory.deployGateway();
        vault = MantleYieldVault(vaultAddr);
        gateway = MantleVaultGateway(gatewayAddr);

        // Initialize vault with minDepositAmount
        vm.prank(admin);
        vault.initialize(
            IMantleYieldVault.InitParams({
                asset: IERC20(address(usdc)),
                name: "Mantle RWA Vault",
                symbol: "mRWA",
                admin: admin,
                gateway: gatewayAddr,
                controller: controllerAddr,
                accountant: address(1),
                treasury: treasuryAddr,
                maxRedemptionFeeBps: 500,
                redemptionFeeBps: FEE_BPS,
                minRedeemAmount: 0,
                minDepositAmount: MIN_DEPOSIT,
                maxSettlementDeviationBps: 0,
                depositDailyRemaining: type(uint256).max,
                redeemDailyRemaining: type(uint256).max
            })
        );

        // Initialize gateway
        vm.prank(admin);
        gateway.initialize(
            IMantleVaultGateway.InitParams({
                vault: vaultAddr,
                sanctionsOracle: ISanctionsOracle(address(oracle)),
                sanctionSafe: sanctionSafe,
                admin: admin,
                syncRedeemDisabled: false
            })
        );

        // Deploy real Accountant and wire to vault
        accountant = Accountant(address(new ERC1967Proxy(
            address(acctImpl),
            abi.encodeCall(Accountant.initialize, (address(vault), uint64(1e18), 0, admin))
        )));
        vm.prank(admin);
        vault.setAccountant(address(accountant));

        // Fund userA
        usdc.mint(userA, 100_000e6);
        vm.prank(userA);
        usdc.approve(address(vault), type(uint256).max);
    }

    // -----------------------------------------------------------------------
    // Logging helpers
    // -----------------------------------------------------------------------

    string constant MODULE = unicode"Gateway 存款场景";
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

    function _step(string memory msg_) internal {
        console2.log(msg_);
        _buf = string.concat(_buf, msg_, "\n");
    }

    function _logPass() internal {
        _step("----------------------------------------");
        _step("test result: passed");
    }

    // -----------------------------------------------------------------------
    // 1. P0: Normal deposit via Gateway
    // -----------------------------------------------------------------------

    function test_Deposit_Normal() public {
        _logCase(
            "test_Deposit_Normal",
            unicode"用户通过 Gateway 正常存款"
        );

        _step("[Step 1] Record state before deposit");
        uint256 vaultUsdcBefore = usdc.balanceOf(address(vault));
        uint256 userUsdcBefore = usdc.balanceOf(userA);
        uint256 userSharesBefore = vault.balanceOf(userA);
        uint256 totalSupplyBefore = vault.totalSupply();
        _step(string.concat("  vault USDC before = ", vm.toString(vaultUsdcBefore)));
        _step(string.concat("  userA USDC before = ", vm.toString(userUsdcBefore)));
        _step(string.concat("  userA shares before = ", vm.toString(userSharesBefore)));

        _step("[Step 2] Compute expected shares using contract formula");
        uint256 expectedShares = vault.previewDeposit(DEPOSIT_AMOUNT);
        _step(string.concat("  rate = ", vm.toString(accountant.getRate())));
        _step(string.concat("  expected shares = ", vm.toString(expectedShares)));

        _step("[Step 3] Expect Deposit event and call gateway.deposit(1000e6)");
        // ERC4626 Deposit(sender=gateway, owner=userA, assets, shares)
        // ERC4626 Deposit(caller=userA, receiver=userA, assets, shares)
        vm.expectEmit(true, true, false, true, address(vault));
        emit IERC4626.Deposit(userA, userA, DEPOSIT_AMOUNT, expectedShares);

        vm.prank(userA);
        uint256 shares = gateway.deposit(DEPOSIT_AMOUNT);
        _step(string.concat("  shares received = ", vm.toString(shares)));

        _step("[Step 4] Verify shares match expected calculation");
        assertEq(shares, expectedShares, "shares should match rate-based calculation");

        _step("[Step 5] Verify Vault USDC increased by deposit amount");
        uint256 vaultUsdcAfter = usdc.balanceOf(address(vault));
        assertEq(vaultUsdcAfter - vaultUsdcBefore, DEPOSIT_AMOUNT, "vault USDC should increase by deposit amount");
        _step(string.concat("  vault USDC after = ", vm.toString(vaultUsdcAfter)));

        _step("[Step 6] Verify userA USDC decreased by deposit amount");
        uint256 userUsdcAfter = usdc.balanceOf(userA);
        assertEq(userUsdcBefore - userUsdcAfter, DEPOSIT_AMOUNT, "userA USDC should decrease by deposit amount");

        _step("[Step 7] Verify userA share balance and totalSupply");
        uint256 userSharesAfter = vault.balanceOf(userA);
        assertEq(userSharesAfter - userSharesBefore, shares, "share balance delta should match returned shares");
        assertEq(vault.totalSupply() - totalSupplyBefore, shares, "totalSupply should increase by shares minted");
        _step(string.concat("  userA shares after = ", vm.toString(userSharesAfter)));
        _step("  PASS: deposit succeeded, USDC transferred, shares minted, Deposit event emitted");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 2. P0: Below minDepositAmount rejected
    // -----------------------------------------------------------------------

    function test_Deposit_BelowMinDeposit() public {
        _logCase(
            "test_Deposit_BelowMinDeposit",
            unicode"存款金额低于 minDepositAmount 时拒绝"
        );

        _step(string.concat("[Step 1] minDepositAmount = ", vm.toString(MIN_DEPOSIT)));

        uint256 tinyAmount = 99e6; // below 100e6
        _step(string.concat("[Step 2] userA calls gateway.deposit(", vm.toString(tinyAmount), ")"));

        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSelector(IMantleYieldVault.Vault__BelowMinDeposit.selector, tinyAmount, MIN_DEPOSIT));
        gateway.deposit(tinyAmount);
        _step("  PASS: reverted with Vault__BelowMinDeposit");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 3. P0: Sanctioned user blocked
    // -----------------------------------------------------------------------

    function test_Deposit_SanctionedUserBlocked() public {
        _logCase(
            "test_Deposit_SanctionedUserBlocked",
            unicode"被制裁用户禁止存款"
        );

        _step("[Step 1] Mark userA as sanctioned");
        oracle.updateSanctionStatus(userA, true);
        assertTrue(gateway.isSanctioned(userA), "userA should be sanctioned");

        _step("[Step 2] userA calls gateway.deposit(1000e6)");
        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSelector(IMantleYieldVault.Vault__Sanctioned.selector, userA));
        gateway.deposit(DEPOSIT_AMOUNT);
        _step("  PASS: reverted with Vault__Sanctioned(userA)");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 4. P0: Whitelist enabled, non-whitelisted user blocked
    // -----------------------------------------------------------------------

    function test_Deposit_WhitelistEnabled_NotWhitelisted() public {
        _logCase(
            "test_Deposit_WhitelistEnabled_NotWhitelisted",
            unicode"白名单开启时，未白名单用户禁止存款"
        );

        _step("[Step 1] Admin enables whitelist");
        vm.prank(admin);
        gateway.setWhitelistEnabled(true);
        assertTrue(gateway.whitelistEnabled(), "whitelistEnabled should be true");

        _step("[Step 2] userA (not whitelisted) calls gateway.deposit(1000e6)");
        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSelector(IMantleVaultGateway.Gateway__NotWhitelisted.selector, userA));
        gateway.deposit(DEPOSIT_AMOUNT);
        _step("  PASS: reverted with Gateway__NotWhitelisted(userA)");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 5. P0: Accountant paused blocks deposit
    // -----------------------------------------------------------------------

    function test_Deposit_AccountantPaused() public {
        _logCase(
            "test_Deposit_AccountantPaused",
            unicode"Accountant 暂停导致 Gateway 存款进入暂停语义"
        );

        _step("[Step 1] Pause the accountant");
        vm.prank(admin);
        accountant.pause();

        _step("[Step 2] userA calls gateway.deposit(1000e6)");
        vm.prank(userA);
        vm.expectRevert(MantleVaultGateway.EnforcedPause.selector);
        gateway.deposit(DEPOSIT_AMOUNT);
        _step("  PASS: reverted with EnforcedPause()");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 6. P1: Vault paused blocks deposit
    // -----------------------------------------------------------------------

    function test_Deposit_VaultPaused() public {
        _logCase(
            "test_Deposit_VaultPaused",
            unicode"Vault 暂停时存款失败"
        );

        _step("[Step 1] Grant PAUSER_ROLE to admin and pause the vault");
        vm.startPrank(admin);
        vault.grantRole(vault.PAUSER_ROLE(), admin);
        vault.pause();
        vm.stopPrank();
        assertTrue(vault.paused(), "vault should be paused");

        _step("[Step 2] userA calls gateway.deposit(1000e6)");
        vm.prank(userA);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        gateway.deposit(DEPOSIT_AMOUNT);
        _step("  PASS: reverted with Pausable.EnforcedPause (vault whenNotPaused)");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 7. P1: Whitelist enabled, whitelisted user succeeds
    // -----------------------------------------------------------------------

    function test_Deposit_WhitelistEnabled_Whitelisted() public {
        _logCase(
            "test_Deposit_WhitelistEnabled_Whitelisted",
            unicode"白名单开启时，已白名单用户正常存款"
        );

        _step("[Step 1] Admin enables whitelist and whitelists userA");
        vm.prank(admin);
        gateway.setWhitelistEnabled(true);
        oracle.updateWhitelistStatus(userA, true);
        assertTrue(gateway.whitelistEnabled(), "whitelistEnabled should be true");
        assertTrue(gateway.isWhitelisted(userA), "userA should be whitelisted");

        _step("[Step 2] Compute expected values");
        uint256 expectedShares = vault.previewDeposit(DEPOSIT_AMOUNT);
        uint256 userUsdcBefore = usdc.balanceOf(userA);

        _step("[Step 3] Expect Deposit event and call gateway.deposit(1000e6)");
        vm.expectEmit(true, true, false, true, address(vault));
        emit IERC4626.Deposit(userA, userA, DEPOSIT_AMOUNT, expectedShares);

        vm.prank(userA);
        uint256 shares = gateway.deposit(DEPOSIT_AMOUNT);

        _step("[Step 4] Verify deposit succeeded with correct amounts");
        assertEq(shares, expectedShares, "shares should match formula");
        assertEq(vault.balanceOf(userA), shares, "userA balance should match");
        assertEq(userUsdcBefore - usdc.balanceOf(userA), DEPOSIT_AMOUNT, "USDC transferred");
        assertEq(usdc.balanceOf(address(vault)), DEPOSIT_AMOUNT, "vault received USDC");
        _step(string.concat("  shares = ", vm.toString(shares)));
        _step("  PASS: whitelisted user deposited, Deposit event emitted, amounts correct");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 8. P1: Exchange rate affects shares received
    // -----------------------------------------------------------------------

    function test_Deposit_ExchangeRateAffectsShares() public {
        _logCase(
            "test_Deposit_ExchangeRateAffectsShares",
            unicode"汇率变化影响存款获得的 shares 数量"
        );

        _step("[Step 1] Set exchange rate to 1.1e18");
        vm.startPrank(admin);
        accountant.setRiskParams(1000, 0); // allow 10% deviation, 0 cooldown
        vm.warp(block.timestamp + 1);
        accountant.updateExchangeRate(uint64(1.1e18), uint64(block.timestamp));
        vm.stopPrank();
        uint256 rate = accountant.getRate();
        assertEq(rate, 1.1e18, "rate should be 1.1e18");

        uint256 depositAmount = 1100e6;
        uint256 expectedShares = vault.previewDeposit(depositAmount);
        _step(string.concat("  expected shares = ", vm.toString(expectedShares)));

        _step(string.concat("[Step 2] Expect Deposit event and call gateway.deposit(", vm.toString(depositAmount), ")"));
        vm.expectEmit(true, true, false, true, address(vault));
        emit IERC4626.Deposit(userA, userA, depositAmount, expectedShares);

        vm.prank(userA);
        uint256 shares = gateway.deposit(depositAmount);

        _step("[Step 3] Verify shares = 1100e6 * 1e18 / 1.1e18 = 1000e6");
        assertEq(shares, expectedShares, "shares should match rate-based calculation");
        assertEq(vault.balanceOf(userA), expectedShares, "balance should match");

        _step("[Step 4] Verify USDC transferred correctly");
        assertEq(usdc.balanceOf(address(vault)), depositAmount, "vault should hold deposited USDC");
        _step(string.concat("  actual shares   = ", vm.toString(shares)));
        _step("  PASS: higher rate yields fewer shares per USDC, Deposit event emitted");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 9. P1: Whitelist disabled, any user can deposit
    // -----------------------------------------------------------------------

    function test_Deposit_WhitelistDisabled_AnyUserCanDeposit() public {
        _logCase(
            "test_Deposit_WhitelistDisabled_AnyUserCanDeposit",
            unicode"白名单关闭时任何用户可正常存款"
        );

        _step("[Step 1] Ensure whitelistEnabled=false (default)");
        assertFalse(gateway.whitelistEnabled(), "whitelistEnabled should be false");
        assertFalse(gateway.isWhitelisted(userA), "userA should NOT be whitelisted");
        assertFalse(gateway.isSanctioned(userA), "userA should NOT be sanctioned");

        _step("[Step 2] userA (not whitelisted) calls gateway.deposit(1000e6)");
        vm.prank(userA);
        uint256 shares = gateway.deposit(DEPOSIT_AMOUNT);

        _step("[Step 3] Verify deposit succeeded");
        assertGt(shares, 0, "shares should be > 0");
        assertEq(vault.balanceOf(userA), shares, "userA balance should match");
        _step(string.concat("  shares = ", vm.toString(shares)));
        _step("  PASS: non-whitelisted user deposited when whitelist is disabled");

        _logPass();
    }
}
