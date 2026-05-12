// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Accountant} from "../../src/accountant/Accountant.sol";
import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {IMantleVaultGateway} from "../../src/interfaces/vault/IMantleVaultGateway.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {MantleVaultGateway} from "../../src/vault/MantleVaultGateway.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {VaultFactory} from "../../src/vault/VaultFactory.sol";
import {GatewayFactory} from "../../src/vault/GatewayFactory.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test, console2} from "forge-std/Test.sol";

// ---------------------------------------------------------------------------
// Mock contracts
// ---------------------------------------------------------------------------

contract MockUSDC_DC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockSanctionsOracle_DC is ISanctionsOracle {
    function initialize(address, address) external override {}
    function isSanctioned(address) external pure override returns (bool) { return false; }
    function isWhitelisted(address) external pure override returns (bool) { return true; }
    function totalSanctionedCount() external pure override returns (uint256) { return 0; }
    function totalWhitelistedCount() external pure override returns (uint256) { return 0; }
    function lastUpdateTimestamp() external pure override returns (uint256) { return 0; }
    function batchNonce() external pure override returns (uint256) { return 0; }
    function MAX_BATCH_SIZE() external pure override returns (uint256) { return 200; }
    function updateSanctionStatus(address, bool) external override {}
    function updateSanctionStatusBatch(address[] calldata, bool) external override {}
    function updateWhitelistStatus(address, bool) external override {}
    function updateWhitelistStatusBatch(address[] calldata, bool) external override {}
}

// ---------------------------------------------------------------------------
// QA Test: Daily Cap Scenarios
// ---------------------------------------------------------------------------

contract DailyCapQATest is Test {
    MockUSDC_DC internal usdc;
    MockSanctionsOracle_DC internal oracle;
    Accountant internal accountant;
    MantleYieldVault internal vault;
    MantleVaultGateway internal gateway;
    VaultFactory internal vaultFactory;
    GatewayFactory internal gatewayFactory;

    address internal admin = makeAddr("admin");
    address internal capManager = makeAddr("capManager");
    address internal controllerAddr = makeAddr("controller");
    address internal treasuryAddr = makeAddr("treasury");
    address internal sanctionSafe = makeAddr("sanctionSafe");
    address internal userA = makeAddr("userA");
    address internal userB = makeAddr("userB");

    string constant MODULE = unicode"Daily Cap 日限额场景";
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

    /// @dev Helper: deploy full stack with custom daily cap params
    function _deployWithCaps(uint256 depositCap, uint256 redeemCap, uint256 minDeposit, uint256 minRedeem) internal {
        vm.warp(1000);

        usdc = new MockUSDC_DC();
        oracle = new MockSanctionsOracle_DC();

        MantleYieldVault vaultImpl = new MantleYieldVault();
        MantleVaultGateway gwImpl = new MantleVaultGateway();
        Accountant acctImpl = new Accountant();
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
                controller: controllerAddr,
                accountant: address(1),
                treasury: treasuryAddr,
                maxRedemptionFeeBps: 500,
                redemptionFeeBps: 100, // 1%
                minRedeemAmount: minRedeem,
                minDepositAmount: minDeposit,
                maxSettlementDeviationBps: 0,
                depositDailyRemaining: depositCap,
                redeemDailyRemaining: redeemCap
            })
        );

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

        accountant = Accountant(address(new ERC1967Proxy(
            address(acctImpl),
            abi.encodeCall(Accountant.initialize, (address(vault), uint64(1e18), 0, admin))
        )));
        vm.prank(admin);
        vault.setAccountant(address(accountant));

        // Grant CAP_MANAGER_ROLE
        bytes32 capRole = vault.CAP_MANAGER_ROLE();
        vm.prank(admin);
        vault.grantRole(capRole, capManager);
    }

    /// @dev Default setUp: max cap (no limit), no minimum
    function setUp() public {
        _deployWithCaps(type(uint256).max, type(uint256).max, 0, 0);
    }

    /// @dev Helper: fund user and deposit through Gateway (real call chain)
    function _depositToVault(address user, uint256 amount) internal returns (uint256 shares) {
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        shares = gateway.deposit(amount);
        vm.stopPrank();
    }

    // =======================================================================
    // N-66: depositDailyRemaining = 0 时 deposit revert
    // =======================================================================

    function test_DailyCap_DepositBlockedWhenCapZero() public {
        _logCase(
            "test_DailyCap_DepositBlockedWhenCapZero",
            unicode"`depositDailyRemaining = 0` 时 deposit revert"
        );

        _step("[Step 1] capManager sets depositDailyRemaining = 0");
        vm.prank(capManager);
        vault.setDepositDailyRemaining(0);
        assertEq(vault.depositDailyRemaining(), 0);

        _step("[Step 2] User attempts deposit 100e6 -> revert");
        usdc.mint(userA, 100e6);
        vm.startPrank(userA);
        usdc.approve(address(vault), 100e6);
        vm.expectRevert(abi.encodeWithSelector(
            IMantleYieldVault.Vault__DepositDailyCapExceeded.selector, 100e6, 0
        ));
        gateway.deposit(100e6);
        vm.stopPrank();
        _step("  revert Vault__DepositDailyCapExceeded(100e6, 0)");

        _logPass();
    }

    // =======================================================================
    // N-67: deposit 成功后 depositDailyRemaining 减少
    // =======================================================================

    function test_DailyCap_DepositReducesCap() public {
        _logCase(
            "test_DailyCap_DepositReducesCap",
            unicode"deposit 成功后 `depositDailyRemaining` 减少相应数额"
        );

        _step("[Step 1] Set depositDailyRemaining = 5000e6");
        vm.prank(capManager);
        vault.setDepositDailyRemaining(5000e6);

        _step("[Step 2] User deposits 1000e6");
        uint256 capBefore = vault.depositDailyRemaining();
        _depositToVault(userA, 1000e6);
        uint256 capAfter = vault.depositDailyRemaining();

        assertEq(capBefore, 5000e6, "cap before");
        assertEq(capAfter, 4000e6, "cap after = 5000 - 1000");
        _step(string.concat("  cap: ", vm.toString(capBefore), " -> ", vm.toString(capAfter)));

        _logPass();
    }

    // =======================================================================
    // N-68: 连续两笔 deposit 累计超 cap，第二笔 revert
    // =======================================================================

    function test_DailyCap_DepositCumulativeExceedsCap() public {
        _logCase(
            "test_DailyCap_DepositCumulativeExceedsCap",
            unicode"连续两笔 deposit 累计超 cap，第二笔 revert"
        );

        _step("[Step 1] Set depositDailyRemaining = 1500e6");
        vm.prank(capManager);
        vault.setDepositDailyRemaining(1500e6);

        _step("[Step 2] User A deposits 1000e6 -> success, cap remaining = 500e6");
        _depositToVault(userA, 1000e6);
        uint256 remaining = vault.depositDailyRemaining();
        assertEq(remaining, 500e6, "remaining after first deposit");

        _step("[Step 3] User B deposits 600e6 -> revert");
        usdc.mint(userB, 600e6);
        vm.startPrank(userB);
        usdc.approve(address(vault), 600e6);
        vm.expectRevert(abi.encodeWithSelector(
            IMantleYieldVault.Vault__DepositDailyCapExceeded.selector, 600e6, 500e6
        ));
        gateway.deposit(600e6);
        vm.stopPrank();
        _step("  revert Vault__DepositDailyCapExceeded(600e6, 500e6)");

        _logPass();
    }

    // =======================================================================
    // N-69: redeemDailyRemaining = 0 时 requestRedeem revert
    // =======================================================================

    function test_DailyCap_RequestRedeemBlockedWhenCapZero() public {
        _logCase(
            "test_DailyCap_RequestRedeemBlockedWhenCapZero",
            unicode"`redeemDailyRemaining = 0` 时 requestRedeem revert"
        );

        _step("[Step 1] User deposits to get shares");
        uint256 shares = _depositToVault(userA, 1000e6);
        assertGt(shares, 0, "user has shares");

        _step("[Step 2] capManager sets redeemDailyRemaining = 0");
        vm.prank(capManager);
        vault.setRedeemDailyRemaining(0);
        assertEq(vault.redeemDailyRemaining(), 0);

        _step("[Step 3] User requestRedeem -> revert");
        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSelector(
            IMantleYieldVault.Vault__RedeemDailyCapExceeded.selector, shares, 0
        ));
        gateway.requestRedeem(shares);
        _step(string.concat("  revert Vault__RedeemDailyCapExceeded(", vm.toString(shares), ", 0)"));

        _logPass();
    }

    // =======================================================================
    // N-70: requestRedeem 成功后 redeemDailyRemaining 减少
    // =======================================================================

    function test_DailyCap_RequestRedeemReducesCap() public {
        _logCase(
            "test_DailyCap_RequestRedeemReducesCap",
            unicode"requestRedeem 成功后 `redeemDailyRemaining` 减少"
        );

        _step("[Step 1] User deposits to get shares");
        _depositToVault(userA, 5000e6);

        _step("[Step 2] Set redeemDailyRemaining = 5000e6");
        vm.prank(capManager);
        vault.setRedeemDailyRemaining(5000e6);

        _step("[Step 3] User requestRedeem 1000e6 shares");
        uint256 capBefore = vault.redeemDailyRemaining();
        vm.prank(userA);
        gateway.requestRedeem(1000e6);
        uint256 capAfter = vault.redeemDailyRemaining();

        assertEq(capBefore, 5000e6, "cap before");
        assertEq(capAfter, 4000e6, "cap after = 5000 - 1000");
        _step(string.concat("  cap: ", vm.toString(capBefore), " -> ", vm.toString(capAfter)));

        _logPass();
    }

    // =======================================================================
    // N-71: 同步 redeem 也消耗 redeemDailyRemaining
    // =======================================================================

    function test_DailyCap_SyncRedeemConsumesCap() public {
        _logCase(
            "test_DailyCap_SyncRedeemConsumesCap",
            unicode"同步 redeem（`vault.redeem`）也消耗 `redeemDailyRemaining`"
        );

        _step("[Step 1] User deposits to get shares and ensure freeCash");
        _depositToVault(userA, 5000e6);

        _step("[Step 2] Set redeemDailyRemaining = 5000e6");
        vm.prank(capManager);
        vault.setRedeemDailyRemaining(5000e6);

        _step("[Step 3] User sync redeem 1000e6 shares");
        uint256 capBefore = vault.redeemDailyRemaining();
        vm.prank(userA);
        gateway.redeem(1000e6);
        uint256 capAfter = vault.redeemDailyRemaining();

        assertEq(capBefore, 5000e6, "cap before");
        assertEq(capAfter, 4000e6, "cap after = 5000 - 1000");
        _step(string.concat("  cap: ", vm.toString(capBefore), " -> ", vm.toString(capAfter)));

        _logPass();
    }

    // =======================================================================
    // N-72: 连续两笔 requestRedeem 累计超 cap，第二笔 revert
    // =======================================================================

    function test_DailyCap_RequestRedeemCumulativeExceedsCap() public {
        _logCase(
            "test_DailyCap_RequestRedeemCumulativeExceedsCap",
            unicode"连续两笔 requestRedeem 累计超 cap，第二笔 revert"
        );

        _step("[Step 1] Users deposit to get shares");
        _depositToVault(userA, 5000e6);
        _depositToVault(userB, 5000e6);

        _step("[Step 2] Set redeemDailyRemaining = 1500e6");
        vm.prank(capManager);
        vault.setRedeemDailyRemaining(1500e6);

        _step("[Step 3] User A requestRedeem 1000e6 -> success");
        vm.prank(userA);
        gateway.requestRedeem(1000e6);
        uint256 remaining = vault.redeemDailyRemaining();
        assertEq(remaining, 500e6, "remaining after first redeem");

        _step("[Step 4] User B requestRedeem 600e6 -> revert");
        vm.prank(userB);
        vm.expectRevert(abi.encodeWithSelector(
            IMantleYieldVault.Vault__RedeemDailyCapExceeded.selector, 600e6, 500e6
        ));
        gateway.requestRedeem(600e6);
        _step("  revert Vault__RedeemDailyCapExceeded(600e6, 500e6)");

        _logPass();
    }

    // =======================================================================
    // N-73: maxDeposit 返回 depositDailyRemaining
    // =======================================================================

    function test_DailyCap_MaxDepositReturnsCap() public {
        _logCase(
            "test_DailyCap_MaxDepositReturnsCap",
            unicode"`maxDeposit()` 返回 `depositDailyRemaining`（非 paused 且有额度时）"
        );

        _step("[Step 1] Set depositDailyRemaining = 3000e6");
        vm.prank(capManager);
        vault.setDepositDailyRemaining(3000e6);

        _step("[Step 2] maxDeposit should return 3000e6");
        uint256 maxDep = vault.maxDeposit(userA);
        assertEq(maxDep, 3000e6, "maxDeposit == depositDailyRemaining");
        _step(string.concat("  maxDeposit: ", vm.toString(maxDep)));

        _logPass();
    }

    // =======================================================================
    // N-74: maxDeposit 返回 0 当 cap < minDepositAmount
    // =======================================================================

    function test_DailyCap_MaxDepositZeroWhenCapBelowMin() public {
        _logCase(
            "test_DailyCap_MaxDepositZeroWhenCapBelowMin",
            unicode"`maxDeposit()` 返回 0 当 `depositDailyRemaining < minDepositAmount`"
        );

        _step("[Step 1] Redeploy with minDepositAmount = 100e6");
        _deployWithCaps(type(uint256).max, type(uint256).max, 100e6, 0);

        _step("[Step 2] Set depositDailyRemaining = 50 (below minDepositAmount)");
        vm.prank(capManager);
        vault.setDepositDailyRemaining(50);

        _step("[Step 3] maxDeposit should return 0");
        uint256 maxDep = vault.maxDeposit(userA);
        assertEq(maxDep, 0, "maxDeposit == 0 when cap < minDeposit");
        _step(string.concat("  maxDeposit: ", vm.toString(maxDep)));

        _logPass();
    }

    // =======================================================================
    // N-75: maxMint 正确转换 deposit cap 到 shares
    // =======================================================================

    function test_DailyCap_MaxMintConvertsCap() public {
        _logCase(
            "test_DailyCap_MaxMintConvertsCap",
            unicode"`maxMint()` 正确转换 deposit cap 到 shares"
        );

        _step("[Step 1] Set depositDailyRemaining = 1000e6, exchangeRate = 1e18");
        vm.prank(capManager);
        vault.setDepositDailyRemaining(1000e6);

        _step("[Step 2] maxMint should return _convertToShares(1000e6, Floor)");
        uint256 maxMintVal = vault.maxMint(userA);
        // With 1:1 rate and 6-dec asset, previewDeposit(1000e6) = 1000e6 shares
        uint256 expectedShares = vault.previewDeposit(1000e6);
        assertEq(maxMintVal, expectedShares, "maxMint == previewDeposit(cap)");
        _step(string.concat("  maxMint: ", vm.toString(maxMintVal), " expected: ", vm.toString(expectedShares)));

        _logPass();
    }

    // =======================================================================
    // N-76: maxRedeem 受 daily cap 约束
    // =======================================================================

    function test_DailyCap_MaxRedeemConstrainedByCap() public {
        _logCase(
            "test_DailyCap_MaxRedeemConstrainedByCap",
            unicode"`maxRedeem()` 受 daily cap 约束：cap < freeCash-based 时取 cap"
        );

        _step("[Step 1] User deposits 10000e6 (has plenty of shares and freeCash)");
        _depositToVault(userA, 10_000e6);

        _step("[Step 2] Set redeemDailyRemaining = 500e6 (less than user balance)");
        vm.prank(capManager);
        vault.setRedeemDailyRemaining(500e6);

        _step("[Step 3] maxRedeem should return 500e6 (capped by daily limit)");
        uint256 maxR = vault.maxRedeem(userA);
        assertEq(maxR, 500e6, "maxRedeem limited by daily cap");
        _step(string.concat("  maxRedeem: ", vm.toString(maxR)));

        _logPass();
    }

    // =======================================================================
    // N-77: maxRedeem 返回 0 当 cap < minRedeemAmount
    // =======================================================================

    function test_DailyCap_MaxRedeemZeroWhenCapBelowMin() public {
        _logCase(
            "test_DailyCap_MaxRedeemZeroWhenCapBelowMin",
            unicode"`maxRedeem()` 返回 0 当 `redeemDailyRemaining > 0` 但 `< minRedeemAmount`"
        );

        _step("[Step 1] Redeploy with minRedeemAmount = 100e6");
        _deployWithCaps(type(uint256).max, type(uint256).max, 0, 100e6);

        _step("[Step 2] User deposits");
        _depositToVault(userA, 10_000e6);

        _step("[Step 3] Set redeemDailyRemaining = 50 (below minRedeemAmount)");
        vm.prank(capManager);
        vault.setRedeemDailyRemaining(50);

        _step("[Step 4] maxRedeem should return 0");
        uint256 maxR = vault.maxRedeem(userA);
        assertEq(maxR, 0, "maxRedeem == 0 when cap < minRedeem");
        _step(string.concat("  maxRedeem: ", vm.toString(maxR)));

        _logPass();
    }

    // =======================================================================
    // N-78: maxWithdraw 受 daily cap 约束
    // =======================================================================

    function test_DailyCap_MaxWithdrawConstrainedByCap() public {
        _logCase(
            "test_DailyCap_MaxWithdrawConstrainedByCap",
            unicode"`maxWithdraw()` 受 daily cap 约束"
        );

        _step("[Step 1] User deposits 10000e6");
        _depositToVault(userA, 10_000e6);

        _step("[Step 2] Set redeemDailyRemaining = 500e6");
        vm.prank(capManager);
        vault.setRedeemDailyRemaining(500e6);

        _step("[Step 3] maxWithdraw should be limited by cap");
        uint256 maxW = vault.maxWithdraw(userA);
        uint256 capAssets = vault.previewRedeem(500e6);
        assertLe(maxW, capAssets, "maxWithdraw <= previewRedeem(cap)");
        assertGt(maxW, 0, "maxWithdraw > 0 (cap > 0)");
        _step(string.concat("  maxWithdraw: ", vm.toString(maxW), " capAssets: ", vm.toString(capAssets)));

        _logPass();
    }

    // =======================================================================
    // N-79: depositDailyRemaining = type(uint256).max 时无限制
    // =======================================================================

    function test_DailyCap_DepositUnlimitedWhenMaxUint() public {
        _logCase(
            "test_DailyCap_DepositUnlimitedWhenMaxUint",
            unicode"`depositDailyRemaining = type(uint256).max` 时无限制（向后兼容）"
        );

        assertEq(vault.depositDailyRemaining(), type(uint256).max, "initial cap = max");

        _step("[Step 1] Multiple large deposits should all succeed");
        _depositToVault(userA, 100_000e6);
        _depositToVault(userB, 100_000e6);

        _step("[Step 2] depositDailyRemaining should not underflow");
        uint256 capAfter = vault.depositDailyRemaining();
        // type(uint256).max - 200_000e6 is still an astronomically large number
        assertGt(capAfter, type(uint256).max / 2, "cap remains very large");
        _step(string.concat("  cap after two deposits: still very large"));

        _logPass();
    }

    // =======================================================================
    // N-80: redeemDailyRemaining = type(uint256).max 时无限制
    // =======================================================================

    function test_DailyCap_RedeemUnlimitedWhenMaxUint() public {
        _logCase(
            "test_DailyCap_RedeemUnlimitedWhenMaxUint",
            unicode"`redeemDailyRemaining = type(uint256).max` 时无限制（向后兼容）"
        );

        assertEq(vault.redeemDailyRemaining(), type(uint256).max, "initial cap = max");

        _step("[Step 1] Users deposit to get shares");
        _depositToVault(userA, 10_000e6);
        _depositToVault(userB, 10_000e6);

        _step("[Step 2] Multiple requestRedeems should all succeed");
        uint256 sharesA = vault.balanceOf(userA);
        uint256 sharesB = vault.balanceOf(userB);
        vm.prank(userA);
        gateway.requestRedeem(sharesA);
        vm.prank(userB);
        gateway.requestRedeem(sharesB);

        _step("[Step 3] redeemDailyRemaining should remain very large");
        uint256 capAfter = vault.redeemDailyRemaining();
        assertGt(capAfter, type(uint256).max / 2, "cap remains very large");
        _step("  redeemDailyRemaining still very large after multiple redeems");

        _logPass();
    }

    // =======================================================================
    // N-81: capManager reset cap 后恢复存款能力
    // =======================================================================

    function test_DailyCap_ResetCapRestoresDeposit() public {
        _logCase(
            "test_DailyCap_ResetCapRestoresDeposit",
            unicode"capManager reset cap 后恢复存款能力"
        );

        _step("[Step 1] Set depositDailyRemaining = 0, deposit blocked");
        vm.prank(capManager);
        vault.setDepositDailyRemaining(0);

        usdc.mint(userA, 2000e6);
        vm.startPrank(userA);
        usdc.approve(address(vault), 2000e6);
        vm.expectRevert(abi.encodeWithSelector(
            IMantleYieldVault.Vault__DepositDailyCapExceeded.selector, 1000e6, 0
        ));
        gateway.deposit(1000e6);
        vm.stopPrank();
        _step("  deposit blocked (cap = 0)");

        _step("[Step 2] capManager resets cap to 10000e6");
        vm.prank(capManager);
        vault.setDepositDailyRemaining(10_000e6);

        _step("[Step 3] User deposits 1000e6 -> success");
        vm.prank(userA);
        gateway.deposit(1000e6);
        uint256 capAfter = vault.depositDailyRemaining();
        assertEq(capAfter, 9000e6, "cap decreased to 9000e6");
        assertGt(vault.balanceOf(userA), 0, "user received shares");
        _step(string.concat("  deposit succeeded, cap remaining: ", vm.toString(capAfter)));

        _logPass();
    }

    // =======================================================================
    // N-82: 初始化时 daily cap 正确存储
    // =======================================================================

    function test_DailyCap_InitializationStoresCorrectly() public {
        _logCase(
            "test_DailyCap_InitializationStoresCorrectly",
            unicode"初始化时 `depositDailyRemaining` 和 `redeemDailyRemaining` 正确存储"
        );

        _step("[Step 1] Deploy vault with specific cap values");
        _deployWithCaps(5000e6, 10_000e18, 0, 0);

        _step("[Step 2] Verify stored values");
        assertEq(vault.depositDailyRemaining(), 5000e6, "depositDailyRemaining == 5000e6");
        assertEq(vault.redeemDailyRemaining(), 10_000e18, "redeemDailyRemaining == 10000e18");
        _step(string.concat("  depositDailyRemaining: ", vm.toString(vault.depositDailyRemaining())));
        _step(string.concat("  redeemDailyRemaining: ", vm.toString(vault.redeemDailyRemaining())));

        _logPass();
    }

    // =======================================================================
    // N-97: redeemDailyRemaining = 0 时同步 redeem revert
    // =======================================================================

    function test_DailyCap_SyncRedeemBlockedWhenCapZero() public {
        _logCase(
            "test_DailyCap_SyncRedeemBlockedWhenCapZero",
            unicode"`redeemDailyRemaining = 0` 时同步 redeem revert"
        );

        _step("[Step 1] User deposits to get shares");
        uint256 shares = _depositToVault(userA, 1000e6);
        assertGt(shares, 0, "user has shares");

        _step("[Step 2] capManager sets redeemDailyRemaining = 0");
        vm.prank(capManager);
        vault.setRedeemDailyRemaining(0);
        assertEq(vault.redeemDailyRemaining(), 0);

        _step("[Step 3] maxRedeem returns 0 due to cap");
        uint256 maxR = vault.maxRedeem(userA);
        assertEq(maxR, 0, "maxRedeem == 0 when cap == 0");

        _step("[Step 4] User sync redeem -> revert ERC4626ExceededMaxRedeem");
        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSignature(
            "ERC4626ExceededMaxRedeem(address,uint256,uint256)", userA, shares, 0
        ));
        gateway.redeem(shares);
        _step("  revert ERC4626ExceededMaxRedeem -- maxRedeem() already accounts for daily cap");

        _logPass();
    }

    // =======================================================================
    // N-98: 同步 redeem 连续两笔累计超 cap，第二笔 revert
    // =======================================================================

    function test_DailyCap_SyncRedeemCumulativeExceedsCap() public {
        _logCase(
            "test_DailyCap_SyncRedeemCumulativeExceedsCap",
            unicode"同步 redeem 连续两笔累计超 cap，第二笔 revert"
        );

        _step("[Step 1] Users deposit to get shares");
        _depositToVault(userA, 5000e6);
        _depositToVault(userB, 5000e6);

        _step("[Step 2] Set redeemDailyRemaining = 1500e6");
        vm.prank(capManager);
        vault.setRedeemDailyRemaining(1500e6);

        _step("[Step 3] User A sync redeem 1000e6 -> success");
        vm.prank(userA);
        gateway.redeem(1000e6);
        uint256 remaining = vault.redeemDailyRemaining();
        assertEq(remaining, 500e6, "remaining after first redeem");

        _step("[Step 4] User B sync redeem 600e6 -> revert ERC4626ExceededMaxRedeem");
        vm.prank(userB);
        vm.expectRevert(abi.encodeWithSignature(
            "ERC4626ExceededMaxRedeem(address,uint256,uint256)", userB, 600e6, 500e6
        ));
        gateway.redeem(600e6);
        _step("  revert ERC4626ExceededMaxRedeem -- maxRedeem() returns cap remaining 500e6");

        _logPass();
    }

    // =======================================================================
    // N-99: 同步 redeem + 异步 requestRedeem 混合消耗 cap，合计超限时拒绝
    // =======================================================================

    function test_DailyCap_MixedSyncAsyncRedeemExceedsCap() public {
        _logCase(
            "test_DailyCap_MixedSyncAsyncRedeemExceedsCap",
            unicode"同步 redeem + 异步 requestRedeem 混合消耗 cap，合计超限时拒绝"
        );

        _step("[Step 1] Users deposit to get shares");
        _depositToVault(userA, 5000e6);
        _depositToVault(userB, 5000e6);

        _step("[Step 2] Set redeemDailyRemaining = 2000e6");
        vm.prank(capManager);
        vault.setRedeemDailyRemaining(2000e6);

        _step("[Step 3] User A sync redeem 1200e6 -> success, cap remaining = 800e6");
        vm.prank(userA);
        gateway.redeem(1200e6);
        uint256 remaining = vault.redeemDailyRemaining();
        assertEq(remaining, 800e6, "remaining after sync redeem");

        _step("[Step 4] User B requestRedeem 900e6 -> revert (exceeds remaining 800e6)");
        vm.prank(userB);
        vm.expectRevert(abi.encodeWithSelector(
            IMantleYieldVault.Vault__RedeemDailyCapExceeded.selector, 900e6, 800e6
        ));
        gateway.requestRedeem(900e6);
        _step("  revert Vault__RedeemDailyCapExceeded(900e6, 800e6)");

        _logPass();
    }

    // =======================================================================
    // N-100: deposit 恰好等于 cap 的边界 -- 应成功且 cap 归零
    // =======================================================================

    function test_DailyCap_DepositExactlyEqualsCap() public {
        _logCase(
            "test_DailyCap_DepositExactlyEqualsCap",
            unicode"deposit 恰好等于 cap 的边界 -- 应成功且 cap 归零"
        );

        _step("[Step 1] Set depositDailyRemaining = 1000e6");
        vm.prank(capManager);
        vault.setDepositDailyRemaining(1000e6);

        _step("[Step 2] User deposits exactly 1000e6 -> success");
        _depositToVault(userA, 1000e6);
        assertEq(vault.depositDailyRemaining(), 0, "cap exhausted to 0");
        assertGt(vault.balanceOf(userA), 0, "user received shares");
        _step("  depositDailyRemaining == 0");

        _step("[Step 3] Any subsequent deposit should revert");
        usdc.mint(userB, 100e6);
        vm.startPrank(userB);
        usdc.approve(address(vault), 100e6);
        vm.expectRevert(abi.encodeWithSelector(
            IMantleYieldVault.Vault__DepositDailyCapExceeded.selector, 100e6, 0
        ));
        gateway.deposit(100e6);
        vm.stopPrank();
        _step("  subsequent deposit revert Vault__DepositDailyCapExceeded(100e6, 0)");

        _logPass();
    }

    // =======================================================================
    // N-101: redeem 恰好等于 cap 的边界 -- 应成功且 cap 归零
    // =======================================================================

    function test_DailyCap_RedeemExactlyEqualsCap() public {
        _logCase(
            "test_DailyCap_RedeemExactlyEqualsCap",
            unicode"redeem 恰好等于 cap 的边界 -- 应成功且 cap 归零"
        );

        _step("[Step 1] Users deposit to get shares");
        _depositToVault(userA, 5000e6);
        _depositToVault(userB, 5000e6);

        _step("[Step 2] Set redeemDailyRemaining = 1000e6");
        vm.prank(capManager);
        vault.setRedeemDailyRemaining(1000e6);

        _step("[Step 3] User A sync redeem exactly 1000e6 -> success");
        vm.prank(userA);
        gateway.redeem(1000e6);
        assertEq(vault.redeemDailyRemaining(), 0, "cap exhausted to 0");
        _step("  redeemDailyRemaining == 0");

        _step("[Step 4] Any subsequent redeem/requestRedeem should revert");
        vm.prank(userB);
        vm.expectRevert(abi.encodeWithSelector(
            IMantleYieldVault.Vault__RedeemDailyCapExceeded.selector, 100e6, 0
        ));
        gateway.requestRedeem(100e6);
        _step("  subsequent requestRedeem revert Vault__RedeemDailyCapExceeded(100e6, 0)");

        _logPass();
    }

    // =======================================================================
    // N-102: cap 是全局共享而非 per-user -- 多用户交替消耗同一 cap
    // =======================================================================

    function test_DailyCap_GlobalSharedNotPerUser() public {
        _logCase(
            "test_DailyCap_GlobalSharedNotPerUser",
            unicode"cap 是全局共享而非 per-user -- 多用户交替消耗同一 cap"
        );

        _step("[Step 1] Set depositDailyRemaining = 3000e6");
        vm.prank(capManager);
        vault.setDepositDailyRemaining(3000e6);

        _step("[Step 2] User A deposit 1000e6 -> cap remaining = 2000e6");
        _depositToVault(userA, 1000e6);
        assertEq(vault.depositDailyRemaining(), 2000e6, "cap after userA first deposit");

        _step("[Step 3] User B deposit 1500e6 -> cap remaining = 500e6");
        _depositToVault(userB, 1500e6);
        assertEq(vault.depositDailyRemaining(), 500e6, "cap after userB deposit");

        _step("[Step 4] User A deposit 600e6 -> revert (global cap only 500e6 left)");
        usdc.mint(userA, 600e6);
        vm.startPrank(userA);
        usdc.approve(address(vault), 600e6);
        vm.expectRevert(abi.encodeWithSelector(
            IMantleYieldVault.Vault__DepositDailyCapExceeded.selector, 600e6, 500e6
        ));
        gateway.deposit(600e6);
        vm.stopPrank();
        _step("  revert Vault__DepositDailyCapExceeded(600e6, 500e6) -- cap is global");

        _logPass();
    }

    // =======================================================================
    // N-103: Vault 暂停时 maxDeposit/maxRedeem 返回 0（与 cap 无关）
    // =======================================================================

    function test_DailyCap_PausedOverridesCap() public {
        _logCase(
            "test_DailyCap_PausedOverridesCap",
            unicode"Vault 暂停时 maxDeposit/maxRedeem 返回 0（与 cap 无关）"
        );

        _step("[Step 1] Set caps to large values");
        vm.prank(capManager);
        vault.setDepositDailyRemaining(5000e6);
        vm.prank(capManager);
        vault.setRedeemDailyRemaining(5000e6);

        _step("[Step 2] User deposits to get shares");
        _depositToVault(userA, 1000e6);

        _step("[Step 3] Verify maxDeposit/maxRedeem are non-zero before pause");
        assertGt(vault.maxDeposit(userA), 0, "maxDeposit > 0 before pause");
        assertGt(vault.maxRedeem(userA), 0, "maxRedeem > 0 before pause");

        _step("[Step 4] Pause vault");
        vm.startPrank(admin);
        vault.grantRole(vault.PAUSER_ROLE(), admin);
        vault.pause();
        vm.stopPrank();

        _step("[Step 5] maxDeposit/maxRedeem should return 0");
        assertEq(vault.maxDeposit(userA), 0, "maxDeposit == 0 when paused");
        assertEq(vault.maxRedeem(userA), 0, "maxRedeem == 0 when paused");
        _step("  maxDeposit == 0, maxRedeem == 0 (paused overrides cap)");

        _logPass();
    }
}
