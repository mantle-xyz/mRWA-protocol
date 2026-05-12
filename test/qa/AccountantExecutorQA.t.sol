// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Accountant} from "../../src/accountant/Accountant.sol";
import {AccountantExecutor} from "../../src/accountant/AccountantExecutor.sol";
import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {IMantleVaultGateway} from "../../src/interfaces/vault/IMantleVaultGateway.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {MantleVaultGateway} from "../../src/vault/MantleVaultGateway.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {OperatorExecutor} from "../../src/protocol/OperatorExecutor.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test, console2} from "forge-std/Test.sol";

// ---------------------------------------------------------------------------
// Minimal mocks
// ---------------------------------------------------------------------------

contract MockUSDC_AEQ is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockSanctionsOracle_AEQ is ISanctionsOracle {
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

// ---------------------------------------------------------------------------
// QA Test: AccountantExecutor + Accountant unpause
// ---------------------------------------------------------------------------

contract AccountantExecutorQATest is Test {
    MockUSDC_AEQ internal usdc;
    MockSanctionsOracle_AEQ internal oracle;
    MantleYieldVault internal vault;
    MantleVaultGateway internal gateway;
    Accountant internal accountant;
    AccountantExecutor internal acctExecutor;
    StrategyController internal controller;
    OperatorExecutor internal executor;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal sanctionSafe = makeAddr("sanctionSafe");
    address internal bot = makeAddr("bot");
    address internal acctBot = makeAddr("acctBot");
    address internal nonBot = makeAddr("nonBot");

    string constant MODULE = unicode"AccountantExecutor 执行与 Accountant 暂停恢复场景";
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

    function setUp() public {
        vm.warp(100_000); // large enough timestamp for cooldown arithmetic

        usdc = new MockUSDC_AEQ();
        oracle = new MockSanctionsOracle_AEQ();

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
            abi.encodeCall(Accountant.initialize, (address(vault), 1e18, 0, admin))
        )));

        // Deploy AccountantExecutor
        AccountantExecutor acctExecImpl = new AccountantExecutor();
        acctExecutor = AccountantExecutor(address(new ERC1967Proxy(
            address(acctExecImpl),
            abi.encodeCall(AccountantExecutor.initialize, (admin))
        )));

        // Grant roles
        vm.startPrank(admin);
        acctExecutor.grantRole(acctExecutor.BOT_ROLE(), acctBot);
        accountant.grantRole(accountant.ACCOUNTANT_EXECUTOR_ROLE(), address(acctExecutor));
        vm.stopPrank();

        executor = OperatorExecutor(address(new ERC1967Proxy(
            address(execImpl),
            abi.encodeCall(OperatorExecutor.initialize, (admin, bot))
        )));

        controller = StrategyController(address(new ERC1967Proxy(
            address(new StrategyController()),
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
        vm.stopPrank();
    }

    // =======================================================================
    // 1. executeUpdateRate: bot 通过 AccountantExecutor 更新汇率
    // =======================================================================

    function test_ExecuteUpdateRate_Success() public {
        _logCase("test_ExecuteUpdateRate_Success", unicode"bot 通过 AccountantExecutor 成功更新汇率");

        _step("[Step 1] Advance time past cooldown (20 hours)");
        vm.warp(block.timestamp + 21 hours);

        uint64 newRate = uint64(1.005e18); // 0.5% increase
        uint64 computeTs = uint64(block.timestamp - 1 minutes);

        _step("[Step 2] acctBot calls executeUpdateRate");
        vm.prank(acctBot);
        acctExecutor.executeUpdateRate(address(accountant), newRate, computeTs);

        assertEq(accountant.getRate(), newRate, "rate updated");
        assertEq(vault.exchangeRate(), newRate, "vault reflects new rate");
        _step(string.concat("  new rate: ", vm.toString(uint256(newRate))));

        _logPass();
    }

    function test_ExecuteUpdateRate_OnlyBot() public {
        _logCase("test_ExecuteUpdateRate_OnlyBot", unicode"非 bot 不能调用 `executeUpdateRate`");

        vm.warp(block.timestamp + 21 hours);
        bytes32 botRole = keccak256("BOT_ROLE");
        vm.prank(nonBot);
        vm.expectRevert(abi.encodeWithSelector(
            bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
            nonBot,
            botRole
        ));
        acctExecutor.executeUpdateRate(address(accountant), uint64(1.005e18), uint64(block.timestamp - 1 minutes));

        _logPass();
    }

    function test_ExecuteUpdateRate_DeviationTriggersCircuitBreaker() public {
        _logCase("test_ExecuteUpdateRate_DeviationTriggersCircuitBreaker", unicode"汇率偏差超限触发断路器暂停");

        vm.warp(block.timestamp + 21 hours);

        // Default maxDeviation = 100 bps (1%). Try 5% increase.
        uint64 bigRate = uint64(1.05e18);
        uint64 computeTs = uint64(block.timestamp - 1 minutes);

        _step("[Step 1] Update with large deviation");
        vm.prank(acctBot);
        acctExecutor.executeUpdateRate(address(accountant), bigRate, computeTs);

        _step("[Step 2] Accountant should be paused (circuit breaker)");
        // Rate should NOT have been updated (circuit breaker pauses and returns)
        uint256 initialRate = 1e18; // the rate from initialize()
        assertEq(accountant.getRate(), initialRate, "rate unchanged after circuit breaker");

        // getRateSafe should revert when paused
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        accountant.getRateSafe();
        _step("  accountant paused, getRateSafe reverts");

        _logPass();
    }

    function test_ExecuteUpdateRate_CooldownEnforced() public {
        _logCase("test_ExecuteUpdateRate_CooldownEnforced", unicode"汇率更新冷却期内再次更新被拒绝");

        vm.warp(block.timestamp + 21 hours);

        _step("[Step 1] First update succeeds");
        uint64 computeTs1 = uint64(block.timestamp - 1 minutes);
        vm.prank(acctBot);
        acctExecutor.executeUpdateRate(address(accountant), uint64(1.005e18), computeTs1);

        _step("[Step 2] Advance 1 second so compute timestamp is fresh, but still within cooldown");
        vm.warp(block.timestamp + 1);
        uint64 computeTs2 = uint64(block.timestamp - 1); // > computeTs1, avoids StaleComputeTimestamp
        uint256 cooldownEnd = uint256(accountant.lastUpdateTimestamp()) + uint256(accountant.minUpdateInterval());
        uint256 expectedTimeRemaining = cooldownEnd - block.timestamp;
        vm.prank(acctBot);
        vm.expectRevert(abi.encodeWithSelector(Accountant.Accountant__CooldownNotElapsed.selector, expectedTimeRemaining));
        acctExecutor.executeUpdateRate(address(accountant), uint64(1.006e18), computeTs2);
        _step("  second update reverted (cooldown not elapsed)");

        _step("[Step 3] After 20h, update succeeds");
        vm.warp(block.timestamp + 20 hours + 1);
        uint64 computeTs3 = uint64(block.timestamp - 30 seconds);
        vm.prank(acctBot);
        acctExecutor.executeUpdateRate(address(accountant), uint64(1.006e18), computeTs3);
        assertEq(accountant.getRate(), uint256(uint64(1.006e18)), "rate updated after cooldown");

        _logPass();
    }

    // =======================================================================
    // 1b. executeSettleManagementFee: bot 通过 AccountantExecutor 结算管理费
    // =======================================================================

    function test_ExecuteSettleManagementFee_FullChain() public {
        _logCase(
            "test_ExecuteSettleManagementFee_FullChain",
            unicode"bot 通过 AccountantExecutor.executeSettleManagementFee 全链路结算管理费"
        );

        _step("[Step 1] Set management fee rate and deposit to create totalSupply");
        vm.prank(admin);
        accountant.setManagementFeeRate(100); // 1%

        address depositor = makeAddr("depositor");
        usdc.mint(depositor, 10_000e6);
        vm.startPrank(depositor);
        usdc.approve(address(vault), type(uint256).max);
        gateway.deposit(10_000e6);
        vm.stopPrank();
        uint256 supplyAfterDeposit = vault.totalSupply();
        _step(string.concat("  totalSupply after deposit: ", vm.toString(supplyAfterDeposit)));
        assertGt(supplyAfterDeposit, 0, "should have shares after deposit");

        _step("[Step 2] Seed fee base via executeSettleManagementFee");
        vm.warp(block.timestamp + 1);
        vm.prank(acctBot);
        acctExecutor.executeSettleManagementFee(address(accountant));
        _step("  Fee base seeded (totalSharesLastSettle updated)");

        _step("[Step 3] Warp 180 days and call executeSettleManagementFee");
        vm.warp(block.timestamp + 180 days);
        uint256 treasuryBefore = vault.balanceOf(treasury);
        uint64 feeSettleTsBefore = accountant.lastFeeSettleTimestamp();
        uint256 totalSharesLastSettleBefore = accountant.totalSharesLastSettle();
        uint256 currentSupply = vault.totalSupply();
        vm.prank(acctBot);
        acctExecutor.executeSettleManagementFee(address(accountant));

        _step("[Step 4] Verify fee shares minted to treasury match formula");
        uint256 treasuryAfter = vault.balanceOf(treasury);
        uint256 feeShares = treasuryAfter - treasuryBefore;

        // Compute expected fee from contract formula
        uint256 timeElapsed = vm.getBlockTimestamp() - feeSettleTsBefore;
        uint256 shareBase = currentSupply < totalSharesLastSettleBefore
            ? currentSupply : totalSharesLastSettleBefore;
        uint256 expectedFee = (shareBase * 100 * timeElapsed) / (10_000 * 365 days);
        assertEq(feeShares, expectedFee, "fee shares match contract formula");
        _step(string.concat("  treasury fee shares: ", vm.toString(feeShares)));
        _step(string.concat("  expected by formula: ", vm.toString(expectedFee)));
        _step("  PASS: full chain bot -> executor -> accountant -> vault.mintFeeShares succeeded");

        _logPass();
    }

    // =======================================================================
    // 2. Accountant unpause: admin 从暂停恢复
    // =======================================================================

    function test_Accountant_Unpause() public {
        _logCase("test_Accountant_Unpause", unicode"admin 暂停后恢复 Accountant，`getRateSafe` 恢复可用");

        uint256 rateBefore = accountant.getRate();

        _step("[Step 1] Admin pauses accountant");
        vm.prank(admin);
        accountant.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        accountant.getRateSafe();
        _step("  getRateSafe reverts when paused");

        _step("[Step 2] getRate still works when paused");
        assertEq(accountant.getRate(), rateBefore, "getRate works even when paused");

        _step("[Step 3] Admin unpauses");
        vm.prank(admin);
        accountant.unpause();

        uint256 rate = accountant.getRateSafe();
        assertEq(rate, rateBefore, "getRateSafe works after unpause");

        _logPass();
    }

    function test_Accountant_Unpause_OnlyAdmin() public {
        _logCase("test_Accountant_Unpause_OnlyAdmin", unicode"非 admin 不能 unpause Accountant");

        vm.prank(admin);
        accountant.pause();

        vm.prank(nonBot);
        vm.expectRevert(abi.encodeWithSelector(
            bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
            nonBot,
            bytes32(0)
        ));
        accountant.unpause();

        _logPass();
    }

    // =======================================================================
    // 3. executePause: bot 通过 AccountantExecutor 暂停 Accountant
    // =======================================================================

    function test_ExecutePause_BotCanPause() public {
        _logCase(
            "test_ExecutePause_BotCanPause",
            unicode"bot 通过 `executePause` 暂停 Accountant"
        );

        _step("[Step 1] Grant PAUSER_ROLE to AccountantExecutor on Accountant");
        bytes32 pauserRole = accountant.PAUSER_ROLE();
        vm.prank(admin);
        accountant.grantRole(pauserRole, address(acctExecutor));

        _step("[Step 2] Verify Accountant is NOT paused (getRateSafe works)");
        uint256 rate = accountant.getRateSafe();
        assertGt(rate, 0, "getRateSafe should return rate when not paused");
        _step(string.concat("  rate: ", vm.toString(rate)));

        _step("[Step 3] acctBot calls executePause(accountant)");
        vm.expectEmit(true, false, false, false);
        emit AccountantExecutor.AccountantPaused(address(accountant));
        vm.prank(acctBot);
        acctExecutor.executePause(address(accountant));

        _step("[Step 4] Verify Accountant is now paused");
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        accountant.getRateSafe();
        _step("  getRateSafe reverts with EnforcedPause");

        _logPass();
    }

    function test_ExecutePause_OnlyBot() public {
        _logCase(
            "test_ExecutePause_OnlyBot",
            unicode"非 bot 不能调用 `executePause`"
        );

        _step("[Step 1] Grant PAUSER_ROLE to AccountantExecutor on Accountant");
        bytes32 pauserRole = accountant.PAUSER_ROLE();
        vm.prank(admin);
        accountant.grantRole(pauserRole, address(acctExecutor));

        _step("[Step 2] nonBot attempts executePause -> revert");
        bytes32 botRole = keccak256("BOT_ROLE");
        vm.prank(nonBot);
        vm.expectRevert(abi.encodeWithSelector(
            bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
            nonBot,
            botRole
        ));
        acctExecutor.executePause(address(accountant));
        _step("  reverted with AccessControlUnauthorizedAccount(nonBot, BOT_ROLE)");

        _logPass();
    }

    function test_ExecutePause_StateAfterPause() public {
        _logCase(
            "test_ExecutePause_StateAfterPause",
            unicode"`executePause` 后 `updateExchangeRate` 和 `settleManagementFee` 均被阻断，`getRate()` 仍可用"
        );

        _step("[Step 1] Grant PAUSER_ROLE and pause via executePause");
        bytes32 pauserRole = accountant.PAUSER_ROLE();
        vm.prank(admin);
        accountant.grantRole(pauserRole, address(acctExecutor));
        vm.prank(acctBot);
        acctExecutor.executePause(address(accountant));

        _step("[Step 2] updateExchangeRate reverts with EnforcedPause");
        vm.warp(block.timestamp + 21 hours);
        vm.prank(acctBot);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        acctExecutor.executeUpdateRate(address(accountant), uint64(1.005e18), uint64(block.timestamp - 1 minutes));
        _step("  executeUpdateRate reverted");

        _step("[Step 3] settleManagementFee reverts with EnforcedPause");
        vm.prank(acctBot);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        acctExecutor.executeSettleManagementFee(address(accountant));
        _step("  executeSettleManagementFee reverted");

        _step("[Step 4] getRate() still works while paused");
        uint256 rate = accountant.getRate();
        assertEq(rate, 1e18, "getRate returns current rate even when paused");
        _step(string.concat("  getRate: ", vm.toString(rate)));

        _step("[Step 5] Admin unpauses -> getRateSafe recovers");
        vm.prank(admin);
        accountant.unpause();
        uint256 safeRate = accountant.getRateSafe();
        assertEq(safeRate, 1e18, "getRateSafe works after admin unpause");
        _step("  getRateSafe recovered after unpause");

        _logPass();
    }

    function test_ExecutePause_AlreadyPaused() public {
        _logCase(
            "test_ExecutePause_AlreadyPaused",
            unicode"对已暂停的 Accountant 再次调用 `executePause` 回滚"
        );

        _step("[Step 1] Grant PAUSER_ROLE and pause via executePause");
        bytes32 pauserRole = accountant.PAUSER_ROLE();
        vm.prank(admin);
        accountant.grantRole(pauserRole, address(acctExecutor));
        vm.prank(acctBot);
        acctExecutor.executePause(address(accountant));
        _step("  Accountant paused");

        _step("[Step 2] Call executePause again -> revert EnforcedPause");
        vm.prank(acctBot);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        acctExecutor.executePause(address(accountant));
        _step("  second executePause reverted with EnforcedPause");

        _logPass();
    }

    function test_ExecutePause_EventEmitted() public {
        _logCase(
            "test_ExecutePause_EventEmitted",
            unicode"`executePause` 事件参数验证"
        );

        _step("[Step 1] Grant PAUSER_ROLE to AccountantExecutor");
        bytes32 pauserRole = accountant.PAUSER_ROLE();
        vm.prank(admin);
        accountant.grantRole(pauserRole, address(acctExecutor));

        _step("[Step 2] Expect AccountantPaused event with correct accountant address");
        vm.expectEmit(true, false, false, true);
        emit AccountantExecutor.AccountantPaused(address(accountant));

        vm.prank(acctBot);
        acctExecutor.executePause(address(accountant));
        _step(string.concat("  event AccountantPaused(", vm.toString(address(accountant)), ") emitted"));

        _logPass();
    }
}
