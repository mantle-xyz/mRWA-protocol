// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Accountant} from "../../src/accountant/Accountant.sol";
import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {IMantleVaultGateway} from "../../src/interfaces/vault/IMantleVaultGateway.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {MantleVaultGateway} from "../../src/vault/MantleVaultGateway.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {OperatorExecutor} from "../../src/protocol/OperatorExecutor.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test, console2} from "forge-std/Test.sol";

// ---------------------------------------------------------------------------
// Minimal mocks
// ---------------------------------------------------------------------------

contract MockUSDC_VAC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockSanctionsOracle_VAC is ISanctionsOracle {
    function initialize(address, address) external {}
    function isSanctioned(address) external pure returns (bool) { return false; }
    function isWhitelisted(address) external pure returns (bool) { return true; }
    function totalSanctionedCount() external pure returns (uint256) { return 0; }
    function totalWhitelistedCount() external pure returns (uint256) { return 0; }
    function lastUpdateTimestamp() external pure returns (uint256) { return 0; }
    function batchNonce() external pure returns (uint256) { return 0; }
    function MAX_BATCH_SIZE() external pure returns (uint256) { return 200; }
    function updateSanctionStatus(address, bool) external {}
    function updateSanctionStatusBatch(address[] calldata, bool) external {}
    function updateWhitelistStatus(address, bool) external {}
    function updateWhitelistStatusBatch(address[] calldata, bool) external {}
}

/// @dev Dummy ERC20 for rescueTokens test.
contract MockRandomToken_VAC is ERC20 {
    constructor() ERC20("Random Token", "RND") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

// ---------------------------------------------------------------------------
// QA Test: Vault Admin Configuration
// ---------------------------------------------------------------------------

contract VaultAdminConfigQATest is Test {
    MockUSDC_VAC internal usdc;
    MockSanctionsOracle_VAC internal oracle;
    MantleYieldVault internal vault;
    MantleVaultGateway internal gateway;
    Accountant internal accountant;
    StrategyController internal controller;
    OperatorExecutor internal executor;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal sanctionSafe = makeAddr("sanctionSafe");
    address internal bot = makeAddr("bot");
    address internal user = makeAddr("user");
    address internal nonAdmin = makeAddr("nonAdmin");
    address internal capManager = makeAddr("capManager");

    // -----------------------------------------------------------------------
    // Logging helpers
    // -----------------------------------------------------------------------

    string constant MODULE = unicode"Vault 管理配置场景";
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

    // -----------------------------------------------------------------------
    // setUp
    // -----------------------------------------------------------------------

    function setUp() public {
        vm.warp(1000);

        usdc = new MockUSDC_VAC();
        oracle = new MockSanctionsOracle_VAC();

        MantleYieldVault vaultImpl = new MantleYieldVault();
        Accountant acctImpl = new Accountant();
        MantleVaultGateway gwImpl = new MantleVaultGateway();
        StrategyController ctrlImpl = new StrategyController();
        OperatorExecutor execImpl = new OperatorExecutor();

        vault = MantleYieldVault(address(new ERC1967Proxy(
            address(vaultImpl),
            abi.encodeCall(MantleYieldVault.initialize, IMantleYieldVault.InitParams({
                asset: IERC20(address(usdc)),
                name: "mRWA Vault",
                symbol: "mRWA",
                admin: admin,
                gateway: address(1),
                controller: admin,
                accountant: address(1),
                treasury: treasury,
                maxRedemptionFeeBps: 500,
                redemptionFeeBps: 100,
                minRedeemAmount: 0,
                minDepositAmount: 0,
                maxSettlementDeviationBps: 0,
                depositDailyRemaining: type(uint256).max,
                redeemDailyRemaining: type(uint256).max
            }))
        )));

        accountant = Accountant(address(new ERC1967Proxy(
            address(acctImpl),
            abi.encodeCall(Accountant.initialize, (address(vault), 1e18, 0, admin, admin, admin))
        )));

        executor = OperatorExecutor(address(new ERC1967Proxy(
            address(execImpl),
            abi.encodeCall(OperatorExecutor.initialize, (admin, bot))
        )));

        controller = StrategyController(address(new ERC1967Proxy(
            address(ctrlImpl),
            abi.encodeCall(StrategyController.initialize, (
                address(vault), admin, address(executor), admin, 1000, 200, 0
            ))
        )));

        gateway = MantleVaultGateway(address(new ERC1967Proxy(
            address(gwImpl),
            abi.encodeCall(MantleVaultGateway.initialize, IMantleVaultGateway.InitParams({
                vault: address(vault),
                sanctionsOracle: ISanctionsOracle(address(oracle)),
                sanctionSafe: sanctionSafe,
                admin: admin,
                syncRedeemDisabled: false
            }))
        )));

        vm.startPrank(admin);
        vault.setAccountant(address(accountant));
        vault.setGateway(address(gateway));
        vault.setController(address(controller));
        vault.grantRole(vault.CAP_MANAGER_ROLE(), capManager);
        vm.stopPrank();

        // Fund user
        usdc.mint(user, 1_000_000e6);
        vm.prank(user);
        usdc.approve(address(vault), type(uint256).max);
    }

    // =======================================================================
    // 1. setAccountant: 更换 Accountant
    // =======================================================================

    function test_SetAccountant_Success() public {
        _logCase("test_SetAccountant_Success", unicode"admin 更换 Accountant 地址，新 Accountant 立即生效");

        Accountant newAcct = Accountant(address(new ERC1967Proxy(
            address(new Accountant()),
            abi.encodeCall(Accountant.initialize, (address(vault), 1.05e18, 0, admin, admin, admin))
        )));

        vm.prank(admin);
        vault.setAccountant(address(newAcct));

        assertEq(vault.exchangeRate(), 1.05e18, "new accountant rate effective");
        _logPass();
    }

    function test_SetAccountant_RejectsZeroAddress() public {
        _logCase("test_SetAccountant_RejectsZeroAddress", unicode"`setAccountant` 拒绝零地址");

        vm.prank(admin);
        vm.expectRevert(IMantleYieldVault.Vault__ZeroAddress.selector);
        vault.setAccountant(address(0));

        _logPass();
    }

    function test_SetAccountant_OnlyAdmin() public {
        _logCase("test_SetAccountant_OnlyAdmin", unicode"非 admin 不能更换 Accountant");

        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(
            bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
            nonAdmin,
            bytes32(0)
        ));
        vault.setAccountant(address(1));

        _logPass();
    }

    // =======================================================================
    // 2. setController: 更换 Controller
    // =======================================================================

    function test_SetController_Success() public {
        _logCase("test_SetController_Success", unicode"admin 更换 Controller 地址");

        address oldCtrl = vault.controller();
        address newCtrl = makeAddr("newController");
        vm.prank(admin);
        vault.setController(newCtrl);

        assertEq(vault.controller(), newCtrl, "controller updated");

        _step("  controller updated, verifying old controller is rejected");
        vm.prank(oldCtrl);
        vm.expectRevert(IMantleYieldVault.Vault__OnlyController.selector);
        vault.registerAdapter(address(1));
        _step("  old controller correctly reverted with Vault__OnlyController");

        _logPass();
    }

    function test_SetController_RejectsZeroAddress() public {
        _logCase("test_SetController_RejectsZeroAddress", unicode"`setController` 拒绝零地址");

        vm.prank(admin);
        vm.expectRevert(IMantleYieldVault.Vault__ZeroAddress.selector);
        vault.setController(address(0));

        _logPass();
    }

    // =======================================================================
    // 3. setGateway: 更换 Gateway
    // =======================================================================

    function test_SetGateway_Success() public {
        _logCase("test_SetGateway_Success", unicode"admin 更换 Gateway 后，旧 Gateway 无法操作");

        vm.prank(user);
        gateway.deposit(1000e6);

        address newGw = makeAddr("newGateway");
        vm.prank(admin);
        vault.setGateway(newGw);

        vm.prank(user);
        vm.expectRevert(IMantleYieldVault.Vault__OnlyGateway.selector);
        gateway.deposit(500e6);
        _step("  old gateway deposit reverted after switch");

        _logPass();
    }

    function test_SetGateway_RejectsZeroAddress() public {
        _logCase("test_SetGateway_RejectsZeroAddress", unicode"`setGateway` 拒绝零地址");

        vm.prank(admin);
        vm.expectRevert(IMantleYieldVault.Vault__ZeroAddress.selector);
        vault.setGateway(address(0));

        _logPass();
    }

    // =======================================================================
    // 4. setTreasury: 更换 Treasury
    // =======================================================================

    function test_SetTreasury_Success() public {
        _logCase("test_SetTreasury_Success", unicode"admin 更换 Treasury 后，赎回费用流向新 Treasury");

        vm.prank(user);
        gateway.deposit(1000e6);

        address newTreasury = makeAddr("newTreasury");
        vm.prank(admin);
        vault.setTreasury(newTreasury);

        uint256 oldTreasuryBefore = vault.balanceOf(treasury);
        uint256 newTreasuryBefore = vault.balanceOf(newTreasury);

        uint256 shares = vault.balanceOf(user);
        vm.prank(user);
        gateway.redeem(shares);

        uint256 oldTreasuryAfter = vault.balanceOf(treasury);
        uint256 newTreasuryAfter = vault.balanceOf(newTreasury);

        assertEq(oldTreasuryAfter, oldTreasuryBefore, "old treasury should not receive fee");
        assertGt(newTreasuryAfter, newTreasuryBefore, "new treasury should receive fee");
        _step(string.concat("  new treasury fee shares: ", vm.toString(newTreasuryAfter - newTreasuryBefore)));

        _logPass();
    }

    function test_SetTreasury_RejectsZeroAddress() public {
        _logCase("test_SetTreasury_RejectsZeroAddress", unicode"`setTreasury` 拒绝零地址");

        vm.prank(admin);
        vm.expectRevert(IMantleYieldVault.Vault__ZeroAddress.selector);
        vault.setTreasury(address(0));

        _logPass();
    }

    // =======================================================================
    // 5. setMaxRedemptionFee: 调整赎回费率上限
    // =======================================================================

    function test_SetMaxRedemptionFee_Success() public {
        _logCase("test_SetMaxRedemptionFee_Success", unicode"admin 调整赎回费率上限（上调）");

        _step("[Step 1] Current max fee = 500 bps (5%)");
        // Init: maxRedemptionFeeBps=500, redemptionFeeBps=100

        _step("[Step 2] Raise max to 1000 bps");
        vm.prank(admin);
        vault.setMaxRedemptionFee(1000);

        _step("[Step 3] Can now set fee up to 1000 bps");
        vm.prank(admin);
        vault.setRedemptionFee(800);

        _logPass();
    }

    function test_SetMaxRedemptionFee_CapsCurrentFee() public {
        _logCase("test_SetMaxRedemptionFee_CapsCurrentFee", unicode"降低 max 时自动收敛当前 fee");

        _step("[Step 1] Current fee = 100 bps, max = 500 bps");

        _step("[Step 2] Lower max to 50 bps -> current fee should auto-reduce to 50");
        vm.prank(admin);
        vault.setMaxRedemptionFee(50);

        _step("[Step 3] Verify fee was capped");
        assertEq(vault.redemptionFeeBps(), 50, "fee should auto-reduce to new max");

        _logPass();
    }

    function test_SetMaxRedemptionFee_RejectsAboveBasis() public {
        _logCase("test_SetMaxRedemptionFee_RejectsAboveBasis", unicode"`setMaxRedemptionFee` 拒绝超过 10000 bps");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IMantleYieldVault.Vault__FeeTooHigh.selector, 10001, 10000));
        vault.setMaxRedemptionFee(10001);

        _logPass();
    }

    // =======================================================================
    // 6. rescueTokens: 紧急代币回收
    // =======================================================================

    function test_RescueTokens_Success() public {
        _logCase("test_RescueTokens_Success", unicode"admin 回收误入 Vault 的非底层代币");

        MockRandomToken_VAC randomToken = new MockRandomToken_VAC();
        randomToken.mint(address(vault), 1000e18);

        address recipient = makeAddr("recipient");
        vm.prank(admin);
        vault.rescueTokens(address(randomToken), recipient, 1000e18);

        assertEq(randomToken.balanceOf(recipient), 1000e18, "tokens rescued");
        assertEq(randomToken.balanceOf(address(vault)), 0, "vault cleared");

        _logPass();
    }

    function test_RescueTokens_RejectsUnderlyingAsset() public {
        _logCase("test_RescueTokens_RejectsUnderlyingAsset", unicode"`rescueTokens` 拒绝回收底层资产 (USDC)");

        vm.prank(user);
        gateway.deposit(1000e6);

        vm.prank(admin);
        vm.expectRevert(IMantleYieldVault.Vault__RescueAssetCannotBeUnderlying.selector);
        vault.rescueTokens(address(usdc), admin, 1000e6);
        _step("  rescue USDC reverted (protected)");

        _logPass();
    }

    function test_RescueTokens_OnlyAdmin() public {
        _logCase("test_RescueTokens_OnlyAdmin", unicode"非 admin 不能调用 `rescueTokens`");

        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(
            bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
            nonAdmin,
            bytes32(0)
        ));
        vault.rescueTokens(address(usdc), nonAdmin, 1);

        _logPass();
    }

    // =======================================================================
    // Settlement Deviation — Admin setter
    // =======================================================================

    function test_SetMaxSettlementDeviation_Success() public {
        _logCase(
            "test_SetMaxSettlementDeviation_Success",
            unicode"admin 可设置 `maxSettlementDeviationBps` 有效值"
        );

        _step("[Step 1] Record old value");
        uint256 oldBps = vault.maxSettlementDeviationBps();
        _step(string.concat("  old maxSettlementDeviationBps = ", vm.toString(oldBps)));

        _step("[Step 2] Admin sets new value to 1000 (10%)");
        vm.prank(admin);
        vm.expectEmit(false, false, false, true, address(vault));
        emit IMantleYieldVault.SettlementDeviationUpdated(oldBps, 1000);
        vault.setMaxSettlementDeviation(1000);

        assertEq(vault.maxSettlementDeviationBps(), 1000, "should update to 1000");
        _step("  PASS: maxSettlementDeviationBps updated to 1000, event emitted");
        _logPass();
    }

    function test_SetMaxSettlementDeviation_RejectExceedsCeiling() public {
        _logCase(
            "test_SetMaxSettlementDeviation_RejectExceedsCeiling",
            unicode"`setMaxSettlementDeviation` 超过 ceiling 被拒绝"
        );

        _step("[Step 1] Admin tries to set 3001 (> ceiling 3000)");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IMantleYieldVault.Vault__InvalidSettlementDeviation.selector, 3001));
        vault.setMaxSettlementDeviation(3001);
        _step("  PASS: reverted with Vault__InvalidSettlementDeviation(3001)");
        _logPass();
    }

    function test_SetMaxSettlementDeviation_DisableGuard() public {
        _logCase(
            "test_SetMaxSettlementDeviation_DisableGuard",
            unicode"admin 可将 `maxSettlementDeviationBps` 设为 0 以关闭防护"
        );

        _step("[Step 1] First set a non-zero value");
        vm.prank(admin);
        vault.setMaxSettlementDeviation(1000);
        assertEq(vault.maxSettlementDeviationBps(), 1000);
        _step("  maxSettlementDeviationBps = 1000");

        _step("[Step 2] Admin sets to 0 (disable guard)");
        vm.prank(admin);
        vault.setMaxSettlementDeviation(0);
        assertEq(vault.maxSettlementDeviationBps(), 0, "should be 0 (guard disabled)");
        _step("  PASS: maxSettlementDeviationBps = 0 (guard disabled)");
        _logPass();
    }

    function test_SetMaxSettlementDeviation_OnlyAdmin() public {
        _logCase(
            "test_SetMaxSettlementDeviation_OnlyAdmin",
            unicode"非 admin 不能修改 `maxSettlementDeviationBps`"
        );

        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(
            bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
            nonAdmin,
            bytes32(0)
        ));
        vault.setMaxSettlementDeviation(500);
        _step("  PASS: nonAdmin reverted");
        _logPass();
    }

    // =======================================================================
    // CAP_MANAGER_ROLE — Daily cap setters
    // =======================================================================

    function test_SetDepositDailyRemaining_Success() public {
        _logCase(
            "test_SetDepositDailyRemaining_Success",
            unicode"`CAP_MANAGER_ROLE` 可设置 `depositDailyRemaining`"
        );

        _step("[Step 1] Record old value");
        uint256 oldValue = vault.depositDailyRemaining();
        _step(string.concat("  old depositDailyRemaining = ", vm.toString(oldValue)));

        _step("[Step 2] capManager sets depositDailyRemaining to 5000e6");
        vm.prank(capManager);
        vm.expectEmit(false, false, false, true, address(vault));
        emit IMantleYieldVault.DepositDailyRemainingUpdated(oldValue, 5000e6);
        vault.setDepositDailyRemaining(5000e6);

        assertEq(vault.depositDailyRemaining(), 5000e6, "depositDailyRemaining should be 5000e6");
        _step("  PASS: depositDailyRemaining updated to 5000e6, event emitted");
        _logPass();
    }

    function test_SetRedeemDailyRemaining_Success() public {
        _logCase(
            "test_SetRedeemDailyRemaining_Success",
            unicode"`CAP_MANAGER_ROLE` 可设置 `redeemDailyRemaining`"
        );

        _step("[Step 1] Record old value");
        uint256 oldValue = vault.redeemDailyRemaining();
        _step(string.concat("  old redeemDailyRemaining = ", vm.toString(oldValue)));

        _step("[Step 2] capManager sets redeemDailyRemaining to 10000e18");
        vm.prank(capManager);
        vm.expectEmit(false, false, false, true, address(vault));
        emit IMantleYieldVault.RedeemDailyRemainingUpdated(oldValue, 10000e18);
        vault.setRedeemDailyRemaining(10000e18);

        assertEq(vault.redeemDailyRemaining(), 10000e18, "redeemDailyRemaining should be 10000e18");
        _step("  PASS: redeemDailyRemaining updated to 10000e18, event emitted");
        _logPass();
    }

    function test_SetDepositDailyRemaining_OnlyCapManager() public {
        _logCase(
            "test_SetDepositDailyRemaining_OnlyCapManager",
            unicode"非 `CAP_MANAGER_ROLE` 不能设置 `depositDailyRemaining`"
        );

        bytes32 capManagerRole = vault.CAP_MANAGER_ROLE();
        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(
            bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
            nonAdmin,
            capManagerRole
        ));
        vault.setDepositDailyRemaining(5000e6);
        _step("  PASS: nonAdmin reverted with AccessControlUnauthorizedAccount");
        _logPass();
    }

    function test_SetRedeemDailyRemaining_OnlyCapManager() public {
        _logCase(
            "test_SetRedeemDailyRemaining_OnlyCapManager",
            unicode"非 `CAP_MANAGER_ROLE` 不能设置 `redeemDailyRemaining`"
        );

        bytes32 capManagerRole = vault.CAP_MANAGER_ROLE();
        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(
            bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
            nonAdmin,
            capManagerRole
        ));
        vault.setRedeemDailyRemaining(10000e18);
        _step("  PASS: nonAdmin reverted with AccessControlUnauthorizedAccount");
        _logPass();
    }

    function test_SetDepositDailyRemaining_UnlimitedMode() public {
        _logCase(
            "test_SetDepositDailyRemaining_UnlimitedMode",
            unicode"`setDepositDailyRemaining(type(uint256).max)` 恢复无限额模式"
        );

        _step("[Step 1] Set a finite cap first");
        vm.prank(capManager);
        vault.setDepositDailyRemaining(5000e6);
        assertEq(vault.depositDailyRemaining(), 5000e6);
        _step("  depositDailyRemaining = 5000e6");

        _step("[Step 2] capManager restores unlimited mode");
        vm.prank(capManager);
        vault.setDepositDailyRemaining(type(uint256).max);
        assertEq(vault.depositDailyRemaining(), type(uint256).max, "should be type(uint256).max");
        _step("  depositDailyRemaining = type(uint256).max");

        _step("[Step 3] Verify maxDeposit returns type(uint256).max");
        uint256 maxDep = vault.maxDeposit(user);
        assertEq(maxDep, type(uint256).max, "maxDeposit should be unlimited");
        _step(string.concat("  maxDeposit(user) = ", vm.toString(maxDep)));
        _step("  PASS: unlimited mode restored");
        _logPass();
    }

    function test_SetRedeemDailyRemaining_UnlimitedMode() public {
        _logCase(
            "test_SetRedeemDailyRemaining_UnlimitedMode",
            unicode"`setRedeemDailyRemaining(type(uint256).max)` 恢复无限额模式"
        );

        _step("[Step 1] Set a finite cap first");
        vm.prank(capManager);
        vault.setRedeemDailyRemaining(1000e18);
        assertEq(vault.redeemDailyRemaining(), 1000e18);
        _step("  redeemDailyRemaining = 1000e18");

        _step("[Step 2] capManager restores unlimited mode");
        vm.prank(capManager);
        vault.setRedeemDailyRemaining(type(uint256).max);
        assertEq(vault.redeemDailyRemaining(), type(uint256).max, "should be type(uint256).max");
        _step("  redeemDailyRemaining = type(uint256).max");

        _step("[Step 3] Verify maxRedeem is not constrained by daily cap");
        // Deposit some shares first so maxRedeem has something to return
        vm.prank(user);
        gateway.deposit(1000e6);
        uint256 shares = vault.balanceOf(user);
        uint256 maxRed = vault.maxRedeem(user);
        assertEq(maxRed, shares, "maxRedeem should equal user shares (no cap constraint)");
        _step(string.concat("  maxRedeem(user) = ", vm.toString(maxRed)));
        _step("  PASS: unlimited mode restored, maxRedeem not capped");
        _logPass();
    }
}
