// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SubRedManagementAdapter} from "../../src/adapters/digift/SubRedManagementAdapter.sol";
import {BaseAdapter} from "../../src/adapters/base/BaseAdapter.sol";
import {IStrategyAdapter} from "../../src/interfaces/adapters/IStrategyAdapter.sol";
import {IStrategyControllerExecutor} from "../../src/interfaces/strategy/IStrategyControllerExecutor.sol";
import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {IMantleVaultGateway} from "../../src/interfaces/vault/IMantleVaultGateway.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {MantleVaultGateway} from "../../src/vault/MantleVaultGateway.sol";
import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {OperatorExecutor} from "../../src/protocol/OperatorExecutor.sol";
import {Accountant} from "../../src/accountant/Accountant.sol";
import {AccountantExecutor} from "../../src/accountant/AccountantExecutor.sol";
import {MockSubRedManagement} from "../../src/mocks/strategy/MockSubRedManagement.sol";
import {MockERC20Mintable} from "../../src/mocks/token/MockERC20Mintable.sol";
import {MockDFeedPriceOracle} from "../../src/mocks/strategy/MockDFeedPriceOracle.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test, console2} from "forge-std/Test.sol";

// ---------------------------------------------------------------------------
// Minimal SanctionsOracle mock: always whitelisted, never sanctioned
// ---------------------------------------------------------------------------
contract MockSanctionsOracle_AMAF is ISanctionsOracle {
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
// Integration test: Adapter minAmounts buffer erosion scenarios
// ---------------------------------------------------------------------------
contract AdapterMinAmountsFlowTest is Test {
    // Core contracts
    MockERC20Mintable internal usdc;
    MockERC20Mintable internal stToken;
    MockSubRedManagement internal venue;
    MockDFeedPriceOracle internal priceOracle;
    MockSanctionsOracle_AMAF internal sanctions;

    MantleYieldVault internal vault;
    MantleVaultGateway internal gateway;
    Accountant internal accountant;
    AccountantExecutor internal acctExecutor;
    StrategyController internal controller;
    OperatorExecutor internal executor;
    SubRedManagementAdapter internal adapter;

    // Roles
    address internal admin = makeAddr("admin");
    address internal bot = makeAddr("bot");
    address internal acctBot = makeAddr("acctBot");
    address internal treasury = makeAddr("treasury");
    address internal sanctionSafe = makeAddr("sanctionSafe");
    address internal user1 = makeAddr("user1");

    string constant MODULE = unicode"Adapter minAmounts buffer erosion";
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

    // ═══════════════════════════════════════════════════════════════════
    // setUp: deploy full stack with real adapter + real controller
    // ═══════════════════════════════════════════════════════════════════

    function setUp() public {
        vm.warp(100_000);

        // 1. Deploy mock tokens and infrastructure
        usdc = new MockERC20Mintable("USD Coin", "USDC", 6);
        stToken = new MockERC20Mintable("Security Token", "ST", 18);
        venue = new MockSubRedManagement(admin);
        priceOracle = new MockDFeedPriceOracle(1e18, 18);
        // price=1e18 with 18 decimals => normalized = 1e18
        // 1 USDC(6dec) = 1e12 ST(18dec) at this price
        sanctions = new MockSanctionsOracle_AMAF();

        // 2. Deploy implementations
        MantleYieldVault vaultImpl = new MantleYieldVault();
        Accountant acctImpl = new Accountant();
        MantleVaultGateway gwImpl = new MantleVaultGateway();
        StrategyController ctrlImpl = new StrategyController();
        OperatorExecutor execImpl = new OperatorExecutor();
        AccountantExecutor acctExecImpl = new AccountantExecutor();

        // 3. Deploy proxies - vault first (uninitialized)
        vault = MantleYieldVault(address(new ERC1967Proxy(
            address(vaultImpl),
            abi.encodeCall(MantleYieldVault.initialize, IMantleYieldVault.InitParams({
                asset: IERC20(address(usdc)),
                name: "mRWA Vault",
                symbol: "mRWA",
                admin: admin,
                gateway: address(1), // placeholder, will set later
                controller: admin,   // placeholder, will set later
                accountant: address(1), // placeholder, will set later
                treasury: treasury,
                maxRedemptionFeeBps: 500,
                redemptionFeeBps: 0,   // no fees for cleaner test math
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

        acctExecutor = AccountantExecutor(address(new ERC1967Proxy(
            address(acctExecImpl),
            abi.encodeCall(AccountantExecutor.initialize, (admin))
        )));

        executor = OperatorExecutor(address(new ERC1967Proxy(
            address(execImpl),
            abi.encodeCall(OperatorExecutor.initialize, (admin, bot))
        )));

        controller = StrategyController(address(new ERC1967Proxy(
            address(ctrlImpl),
            abi.encodeCall(StrategyController.initialize, (
                address(vault),
                admin,
                address(executor),
                admin,  // pauser
                1000,   // bufferTargetBps = 10%
                200,    // rebalanceThresholdBps = 2%
                0       // rebalanceCooldown = 0
            ))
        )));

        gateway = MantleVaultGateway(address(new ERC1967Proxy(
            address(gwImpl),
            abi.encodeCall(MantleVaultGateway.initialize, IMantleVaultGateway.InitParams({
                vault: address(vault),
                sanctionsOracle: ISanctionsOracle(address(sanctions)),
                sanctionSafe: sanctionSafe,
                admin: admin,
                syncRedeemDisabled: false
            }))
        )));

        // 4. Deploy adapter (non-upgradeable)
        adapter = new SubRedManagementAdapter(
            address(vault),
            address(venue),
            address(stToken),
            admin,
            address(controller),
            address(acctExecutor),
            address(priceOracle)
        );

        // 5. Wire up: vault links to real controller, accountant, gateway
        vm.startPrank(admin);
        vault.setController(address(controller));
        vault.setAccountant(address(accountant));
        vault.setGateway(address(gateway));

        // 6. Grant roles
        acctExecutor.grantRole(acctExecutor.BOT_ROLE(), acctBot);
        accountant.grantRole(accountant.ACCOUNTANT_EXECUTOR_ROLE(), address(acctExecutor));

        // 7. Register and activate adapter strategy
        controller.registerStrategy(address(adapter), 10000, 1, true);
        controller.activateStrategy(address(adapter));
        address[] memory order = new address[](1);
        order[0] = address(adapter);
        controller.setStrategyOrder(order);

        // 8. Set non-zero minAmounts (core of these tests)
        adapter.setExecutionConstraints(500e6, 0, 500e18, 0);

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    // Helper functions
    // ═══════════════════════════════════════════════════════════════════

    function _deposit(address user, uint256 usdcAmount) internal {
        usdc.mint(user, usdcAmount);
        vm.startPrank(user);
        // ERC4626._deposit calls transferFrom(caller, vault, amount), so approve vault not gateway
        usdc.approve(address(vault), type(uint256).max);
        gateway.deposit(usdcAmount);
        vm.stopPrank();
    }

    function _rebalance() internal {
        vm.prank(bot);
        executor.executeRebalance(address(controller));
    }

    function _settleInvest(uint256 inFlightId, uint256 posAmount) internal {
        // 1. Venue settlement: mint ST tokens to adapter (simulating async settlement)
        vm.prank(admin);
        venue.settleSubscribe(address(adapter), address(stToken), address(adapter), posAmount);

        // 2. Controller settlement: sweep ST from adapter to vault + confirm in-flight
        uint256[] memory ids = new uint256[](1);
        ids[0] = inFlightId;
        uint256[] memory pos = new uint256[](1);
        pos[0] = posAmount;
        uint256[] memory ref = new uint256[](1);
        ref[0] = 0;

        IStrategyControllerExecutor.InvestSettlementInput memory inv =
            IStrategyControllerExecutor.InvestSettlementInput(ids, pos, ref);
        IStrategyControllerExecutor.RedeemSettlementInput memory red =
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0));

        vm.prank(bot);
        executor.executeSettleAdapter(address(controller), address(adapter), inv, red);
    }

    function _requestRedeem(address user, uint256 shares) internal returns (uint256 reqId) {
        vm.prank(user);
        reqId = gateway.requestRedeem(shares);
    }

    function _processRedeemBatch(uint256[] memory ids) internal {
        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), ids);
    }

    // ═══════════════════════════════════════════════════════════════════
    // B1. Invest skipped when surplus < minSubscribeAsset
    // ═══════════════════════════════════════════════════════════════════

    function test_InvestSkipped_SurplusBelowMinSubscribeAsset() public {
        _logCase(
            "test_InvestSkipped_SurplusBelowMinSubscribeAsset",
            unicode"surplus < minSubscribeAsset 时 invest 被跳过，freeCash 不减少"
        );

        // minSubscribeAsset = 500e6, bufferTargetBps = 1000 (10%)
        // Deposit 400 USDC -> vault has 400 USDC
        // targetCash = totalAssets * 10% = 400 * 10% = 40
        // surplus = freeCash - targetCash = 400 - 40 = 360 USDC
        // 360 < 500 (minSubscribeAsset) -> invest should be skipped

        _step("[Step 1] User deposits 400 USDC");
        _deposit(user1, 400e6);
        uint256 vaultBalBefore = usdc.balanceOf(address(vault));
        assertEq(vaultBalBefore, 400e6, "vault has 400 USDC");
        _step(string.concat("  vault USDC = ", vm.toString(vaultBalBefore)));

        _step("[Step 2] Bot triggers rebalance -> expect InvestSkipped");
        _rebalance();

        _step("[Step 3] Verify vault USDC unchanged (invest was skipped)");
        uint256 vaultBalAfter = usdc.balanceOf(address(vault));
        assertEq(vaultBalAfter, 400e6, "vault USDC unchanged after skipped invest");
        _step(string.concat("  vault USDC = ", vm.toString(vaultBalAfter)));

        _step("[Step 4] Verify no in-flight records created");
        assertEq(vault.totalInvestInFlight(), 0, "no invest in-flight");
        assertEq(adapter.totalValue(), 0, "adapter totalValue = 0 (no ST in vault)");
        _step("  totalInvestInFlight = 0, adapter.totalValue = 0");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════════
    // B2. Accumulated surplus eventually exceeds min -> invest succeeds
    // ═══════════════════════════════════════════════════════════════════

    function test_InvestSucceeds_AccumulatedSurplusAboveMin() public {
        _logCase(
            "test_InvestSucceeds_AccumulatedSurplusAboveMin",
            unicode"累积存款使 surplus 超过 minSubscribeAsset 后，一次性 invest 成功"
        );

        // minSubscribeAsset = 500e6, bufferTargetBps = 1000 (10%)
        // Phase 1: deposit 400 -> surplus 360 < 500 -> skip
        // Phase 2: deposit 600 -> total 1000 -> surplus = 1000-100 = 900 >= 500 -> invest

        _step("[Step 1] First deposit: 400 USDC -> rebalance -> invest skipped");
        _deposit(user1, 400e6);
        _rebalance();
        assertEq(usdc.balanceOf(address(vault)), 400e6, "vault still 400 USDC after skip");
        assertEq(vault.totalInvestInFlight(), 0, "no in-flight after skip");
        _step("  vault USDC = 400e6, totalInvestInFlight = 0 (skipped)");

        _step("[Step 2] Second deposit: 600 USDC -> vault total = 1000 USDC");
        _deposit(user1, 600e6);
        assertEq(usdc.balanceOf(address(vault)), 1000e6, "vault has 1000 USDC");
        _step("  vault USDC = 1000e6");

        _step("[Step 3] Rebalance -> surplus=900 >= 500 -> invest should succeed");
        // totalAssets = 1000, targetCash = 1000 * 10% = 100, surplus = 1000 - 100 = 900
        // 900 >= 500 (minSubscribeAsset) -> invest 900 USDC
        _rebalance();

        _step("[Step 4] Verify invest executed");
        // After invest: vault should have ~100 USDC (targetCash), rest invested
        uint256 vaultBalAfter = usdc.balanceOf(address(vault));
        uint256 totalInFlight = vault.totalInvestInFlight();
        _step(string.concat("  vault USDC = ", vm.toString(vaultBalAfter)));
        _step(string.concat("  totalInvestInFlight = ", vm.toString(totalInFlight)));

        // totalAssets=1000, bufferBps=10% -> targetCash=100, surplus=900
        // subscribeStepAsset=0, 900 >= 500 (minSubscribeAsset) -> invest 900
        uint256 totalAssets = vault.totalAssets();
        uint256 expectedTargetCash = totalAssets * 1000 / 10000; // bufferTargetBps=1000
        uint256 expectedSurplus = totalAssets - expectedTargetCash;
        assertEq(vaultBalAfter, expectedTargetCash, "vault USDC = targetCash after invest");
        assertEq(totalInFlight, expectedSurplus, "totalInvestInFlight = surplus");

        // Verify in-flight record exists
        uint256 nextInFlightId = vault.nextInFlightId();
        assertGt(nextInFlightId, 1, "in-flight record created");
        _step(string.concat("  nextInFlightId = ", vm.toString(nextInFlightId)));

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════════
    // B3. Divest skipped when pos < minRedeemPos
    // ═══════════════════════════════════════════════════════════════════

    function test_DivestSkipped_ShortfallBelowMinRedeemPos() public {
        _logCase(
            "test_DivestSkipped_ShortfallBelowMinRedeemPos",
            unicode"divest 金额转换为 pos 低于 minRedeemPos 时 divest 被跳过"
        );

        // Strategy: deposit large, invest+settle, then raise buffer to trigger a small divest
        // that converts to pos < minRedeemPos (500e18).

        // Phase 1: deposit 10000 USDC, set buffer=0 to maximize invest, then invest+settle
        _step("[Step 1] Set bufferBps=0 to invest everything");
        vm.prank(admin);
        controller.setRiskParams(0, 0, 0);

        _step("[Step 2] Deposit 10000 USDC and rebalance");
        _deposit(user1, 10000e6);
        _rebalance();

        // Verify invest occurred
        uint256 investedAmount = vault.totalInvestInFlight();
        _step(string.concat("  totalInvestInFlight = ", vm.toString(investedAmount)));
        assertGt(investedAmount, 0, "invest occurred");

        _step("[Step 3] Settle invest (mint ST to adapter, sweep to vault)");
        // With price=1e18: 10000e6 USDC -> 10000e18 ST pos
        uint256 expectedPos = investedAmount * 1e12; // USDC(6dec) -> ST(18dec) at price=1e18
        _settleInvest(1, expectedPos);

        // After settlement: vault holds ST tokens, adapter totalValue reflects this
        uint256 adapterTV = adapter.totalValue();
        _step(string.concat("  adapter.totalValue = ", vm.toString(adapterTV)));
        assertGt(adapterTV, 0, "adapter has value after settlement");

        // Phase 2: set high buffer to trigger small divest
        // minRedeemPos = 500e18, so need divest amount in pos < 500e18
        // That means divest USDC amount < 500e6
        // Set buffer = targetCash that creates a shortfall just below 500 USDC
        _step("[Step 4] Set buffer to trigger small divest (< 500 USDC shortfall)");
        // With 10000 total: setting buffer to 3% -> targetCash = 300
        // Current freeCash = vault USDC balance (should be ~0 after full invest)
        // shortfall = targetCash - freeCash = ~300 USDC
        // 300e6 USDC -> 300e18 pos < 500e18 -> divest skipped
        vm.prank(admin);
        controller.setRiskParams(300, 0, 0); // bufferTargetBps=3%

        _step("[Step 5] Rebalance -> expect DivestSkipped");
        _rebalance();

        _step("[Step 6] Verify divest was skipped (vault balance unchanged)");
        uint256 vaultUsdcAfter = usdc.balanceOf(address(vault));
        _step(string.concat("  vault USDC after rebalance = ", vm.toString(vaultUsdcAfter)));
        // Vault USDC should still be very low (no divest occurred)
        // The exact amount depends on what remained after invest, but totalRedeemInFlight should be 0
        assertEq(vault.totalRedeemInFlight(), 0, "no redeem in-flight (divest skipped)");
        _step("  totalRedeemInFlight = 0 (divest skipped)");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════════
    // B4. processRedeemBatch tolerance: pool > shortfall but divest skip
    // ═══════════════════════════════════════════════════════════════════

    function test_ProcessRedeemBatch_StepResidualTolerance() public {
        _logCase(
            "test_ProcessRedeemBatch_StepResidualTolerance",
            unicode"processRedeemBatch 中 adapter 总池值 > shortfall 但单笔 divest 因 minRedeemPos 被 skip 时，请求仍放行进入 PROCESSING（容忍尾差）"
        );

        // Setup: large deposit -> invest all -> settle -> requestRedeem small amount
        // Then set minRedeemPos high so the small divest is skipped.
        // But since pool > shortfall, the request enters PROCESSING (not revert).

        _step("[Step 1] Set buffer=0, invest everything, settle");
        vm.prank(admin);
        controller.setRiskParams(0, 0, 0);

        _deposit(user1, 10000e6);
        _rebalance();

        uint256 investedAmount = vault.totalInvestInFlight();
        _step(string.concat("  invested = ", vm.toString(investedAmount)));
        uint256 expectedPos = investedAmount * 1e12;
        _settleInvest(1, expectedPos);

        uint256 adapterTV = adapter.totalValue();
        _step(string.concat("  adapter.totalValue = ", vm.toString(adapterTV)));

        _step("[Step 2] Set minRedeemPos to 500e18 (already set in setUp)");
        // minRedeemPos = 500e18 from setUp
        // adapter totalValue = ~10000e6
        // previewRedeem(10000e6) -> pos = 10000e18 >= 500e18 -> ok -> pool ~ 10000e6

        _step("[Step 3] User requests redeem of 200 shares");
        // With rate=1e18, 200 shares ≈ 200 USDC
        uint256 reqId = _requestRedeem(user1, 200e6);
        _step(string.concat("  requestId = ", vm.toString(reqId)));

        _step("[Step 4] processRedeemBatch -> cashDeficit exists, divest needed");
        // vault USDC ≈ 0, cashDeficit = lockedShares value = ~200e6
        // shortfall = min(cashDeficit, batchTotalAsset) ≈ 200e6
        // _adapterPoolValue: previewRedeem(totalValue) -> totalValue ~10000e6 -> pos=10000e18 >= 500e18 -> ok
        //   => pool ≈ 10000e6 > 200e6 shortfall
        // _divest(200e6) -> previewRedeem(200e6) -> pos=200e18 < 500e18 -> (false,0,0) -> DivestSkipped
        // divestRemaining(200) > 0 && adapterPoolBefore(10000) < shortfall(200) -> FALSE
        // => request enters PROCESSING (no revert!)

        uint256[] memory ids = new uint256[](1);
        ids[0] = reqId;
        _processRedeemBatch(ids);

        _step("[Step 5] Verify request entered PROCESSING (not reverted)");
        (, , , , , , , IMantleYieldVault.RequestStatus status) = vault.requests(reqId);
        assertEq(uint8(status), uint8(IMantleYieldVault.RequestStatus.PROCESSING), "request is PROCESSING");
        _step("  request status = PROCESSING (tolerance applied)");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════════
    // B5. processRedeemBatch revert: pool < shortfall -> DivestInsufficient
    // ═══════════════════════════════════════════════════════════════════

    function test_ProcessRedeemBatch_DivestInsufficient_PoolBelowShortfall() public {
        _logCase(
            "test_ProcessRedeemBatch_DivestInsufficient_PoolBelowShortfall",
            unicode"adapter 总池值 < shortfall（因 minRedeemPos 导致 previewRedeem 返回 false -> pool=0）时 revert DivestInsufficient"
        );

        // Setup: deposit 500 USDC -> invest all -> settle
        // Then set minRedeemPos = 600e18 so that adapter's totalValue(500e6) -> pos=500e18 < 600e18
        // -> previewRedeem returns (false, 0, 0) -> adapterPool = 0
        // User redeems 500 shares -> shortfall = 500e6
        // divestRemaining(500) > 0 && adapterPoolBefore(0) < shortfall(500) -> TRUE -> revert!

        _step("[Step 1] Set buffer=0 to invest everything");
        vm.prank(admin);
        controller.setRiskParams(0, 0, 0);

        _step("[Step 2] Deposit 500 USDC, rebalance, settle");
        _deposit(user1, 500e6);
        _rebalance();

        uint256 investedAmount = vault.totalInvestInFlight();
        _step(string.concat("  invested = ", vm.toString(investedAmount)));
        uint256 expectedPos = investedAmount * 1e12;
        _settleInvest(1, expectedPos);

        uint256 adapterTV = adapter.totalValue();
        _step(string.concat("  adapter.totalValue = ", vm.toString(adapterTV)));

        _step("[Step 3] Set minRedeemPos = 600e18 (higher than adapter total pos)");
        vm.prank(admin);
        adapter.setExecutionConstraints(500e6, 0, 600e18, 0);
        // adapter totalValue ≈ 500e6
        // previewRedeem(500e6) -> pos = 500e18 < 600e18 -> (false, 0, 0) -> pool = 0

        _step("[Step 4] User requests redeem of all shares");
        uint256 userShares = vault.balanceOf(user1);
        _step(string.concat("  user shares = ", vm.toString(userShares)));
        uint256 reqId = _requestRedeem(user1, userShares);
        _step(string.concat("  requestId = ", vm.toString(reqId)));

        _step("[Step 5] processRedeemBatch -> expect revert DivestInsufficient");
        // cashDeficit ≈ 500e6 (all shares locked, no USDC in vault)
        // adapterPool = 0 (previewRedeem fails due to high minRedeemPos)
        // shortfall ≈ 500e6
        // _divest(500e6) -> previewRedeem(500e6) -> pos < 600e18 -> skip -> remaining = 500e6
        // remaining(500) > 0 && pool(0) < shortfall(500) -> TRUE -> revert!
        uint256[] memory ids = new uint256[](1);
        ids[0] = reqId;

        // Compute expected shortfall for the revert
        uint256 cashDeficit = vault.getCashDeficit();
        uint256 batchTotalAsset = (userShares * vault.exchangeRate()) / 1e18;
        uint256 expectedShortfall = cashDeficit < batchTotalAsset ? cashDeficit : batchTotalAsset;
        _step(string.concat("  cashDeficit = ", vm.toString(cashDeficit)));
        _step(string.concat("  batchTotalAsset = ", vm.toString(batchTotalAsset)));
        _step(string.concat("  expectedShortfall = ", vm.toString(expectedShortfall)));

        vm.prank(bot);
        vm.expectRevert(
            abi.encodeWithSelector(StrategyController.Controller__DivestInsufficient.selector, expectedShortfall, expectedShortfall)
        );
        executor.executeProcessRedeemBatch(address(controller), ids);
        _step("  PASS: reverted with DivestInsufficient");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════════
    // B6. subscribeStepAsset floor drops surplus below minSubscribeAsset
    // ═══════════════════════════════════════════════════════════════════

    function test_InvestSkipped_StepFloorDropsBelowMin() public {
        _logCase(
            "test_InvestSkipped_StepFloorDropsBelowMin",
            unicode"subscribeStepAsset 对齐后跌破 minSubscribeAsset -- invest 被 skip"
        );

        // minSubscribeAsset=500e6, subscribeStepAsset=1000e6
        // Deposit 800 USDC -> surplus = 800 - 80(targetCash 10%) = 720 USDC
        // _floorToStep(720e6, 1000e6) = 720e6 - (720e6 % 1000e6) = 0
        // 0 < 500e6 (minSubscribeAsset) -> previewDeposit returns (false,0,0) -> InvestSkipped

        _step("[Step 1] Set subscribeStepAsset=1000e6");
        vm.prank(admin);
        adapter.setExecutionConstraints(500e6, 1000e6, 500e18, 0);

        _step("[Step 2] Deposit 800 USDC");
        _deposit(user1, 800e6);
        uint256 vaultBalBefore = usdc.balanceOf(address(vault));
        assertEq(vaultBalBefore, 800e6, "vault has 800 USDC");
        _step(string.concat("  vault USDC = ", vm.toString(vaultBalBefore)));

        _step("[Step 3] Rebalance -> surplus=720, floorToStep(720,1000)=0 < min=500 -> skip");
        _rebalance();

        _step("[Step 4] Verify invest was skipped");
        uint256 vaultBalAfter = usdc.balanceOf(address(vault));
        assertEq(vaultBalAfter, 800e6, "vault USDC unchanged (invest skipped)");
        assertEq(vault.totalInvestInFlight(), 0, "no invest in-flight");
        _step(string.concat("  vault USDC = ", vm.toString(vaultBalAfter)));
        _step("  totalInvestInFlight = 0 (step floor caused skip)");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════════
    // B7. redeemStepPos floor drops pos below minRedeemPos in rebalance
    // ═══════════════════════════════════════════════════════════════════

    function test_DivestSkipped_RedeemStepFloorDropsBelowMin() public {
        _logCase(
            "test_DivestSkipped_RedeemStepFloorDropsBelowMin",
            unicode"redeemStepPos 对齐后跌破 minRedeemPos -- rebalance divest 被 skip"
        );

        // Phase 1: invest everything at buffer=0
        _step("[Step 1] Set buffer=0, invest everything, settle");
        vm.prank(admin);
        controller.setRiskParams(0, 0, 0);

        _deposit(user1, 10000e6);
        _rebalance();

        uint256 investedAmount = vault.totalInvestInFlight();
        _step(string.concat("  invested = ", vm.toString(investedAmount)));
        uint256 expectedPos = investedAmount * 1e12;
        _settleInvest(1, expectedPos);

        uint256 adapterTV = adapter.totalValue();
        _step(string.concat("  adapter.totalValue = ", vm.toString(adapterTV)));

        // Phase 2: set redeemStepPos=1000e18, minRedeemPos=500e18
        // Then set buffer=7% -> targetCash=700 -> shortfall~=700
        // shortfall 700e6 -> pos=700e18 -> floorToStep(700e18, 1000e18)=0 < 500e18 -> skip
        _step("[Step 2] Set redeemStepPos=1000e18");
        vm.prank(admin);
        adapter.setExecutionConstraints(500e6, 0, 500e18, 1000e18);

        _step("[Step 3] Set buffer=7% to trigger small divest");
        vm.prank(admin);
        controller.setRiskParams(700, 0, 0); // bufferTargetBps=7%

        _step("[Step 4] Rebalance -> shortfall~=700 USDC -> pos=700e18 -> floorToStep(700,1000)=0 -> skip");
        _rebalance();

        _step("[Step 5] Verify divest was skipped");
        assertEq(vault.totalRedeemInFlight(), 0, "no redeem in-flight (step floor caused skip)");
        _step("  totalRedeemInFlight = 0 (redeemStepPos floor caused skip)");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════════
    // B8. Lower minRedeemPos unblocks DivestInsufficient
    // ═══════════════════════════════════════════════════════════════════

    function test_LowerMinRedeemPos_UnblocksDivestInsufficient() public {
        _logCase(
            "test_LowerMinRedeemPos_UnblocksDivestInsufficient",
            unicode"降低 minRedeemPos 解除 DivestInsufficient 阻塞 -- 运维恢复路径"
        );

        // Same setup as B5: deposit 500, invest all, settle, then set minRedeemPos=600e18
        _step("[Step 1] Set buffer=0, deposit 500 USDC, invest all, settle");
        vm.prank(admin);
        controller.setRiskParams(0, 0, 0);

        _deposit(user1, 500e6);
        _rebalance();

        uint256 investedAmount = vault.totalInvestInFlight();
        uint256 expectedPos = investedAmount * 1e12;
        _settleInvest(1, expectedPos);

        _step("[Step 2] Set minRedeemPos=600e18 (higher than adapter total pos)");
        vm.prank(admin);
        adapter.setExecutionConstraints(500e6, 0, 600e18, 0);

        _step("[Step 3] User requests redeem of all shares");
        uint256 userShares = vault.balanceOf(user1);
        uint256 reqId = _requestRedeem(user1, userShares);
        _step(string.concat("  requestId = ", vm.toString(reqId)));

        _step("[Step 4] processRedeemBatch -> revert DivestInsufficient");
        uint256[] memory ids = new uint256[](1);
        ids[0] = reqId;

        uint256 cashDeficit = vault.getCashDeficit();
        uint256 batchTotalAsset = (userShares * vault.exchangeRate()) / 1e18;
        uint256 expectedShortfall = cashDeficit < batchTotalAsset ? cashDeficit : batchTotalAsset;

        vm.prank(bot);
        vm.expectRevert(
            abi.encodeWithSelector(StrategyController.Controller__DivestInsufficient.selector, expectedShortfall, expectedShortfall)
        );
        executor.executeProcessRedeemBatch(address(controller), ids);
        _step("  reverted as expected");

        // Verify request still PENDING
        (, , , , , , , IMantleYieldVault.RequestStatus statusBefore) = vault.requests(reqId);
        assertEq(uint8(statusBefore), uint8(IMantleYieldVault.RequestStatus.PENDING), "request still PENDING");

        _step("[Step 5] Admin lowers minRedeemPos to 400e18");
        vm.prank(admin);
        adapter.setExecutionConstraints(500e6, 0, 400e18, 0);
        // Now: previewRedeem(500e6) -> pos=500e18 >= 400e18 -> ok -> pool=500e6 >= shortfall

        _step("[Step 6] Retry processRedeemBatch -> succeeds");
        _processRedeemBatch(ids);

        (, , , , , , , IMantleYieldVault.RequestStatus statusAfter) = vault.requests(reqId);
        assertEq(uint8(statusAfter), uint8(IMantleYieldVault.RequestStatus.PROCESSING), "request now PROCESSING");
        _step("  request status = PROCESSING (unblocked after lowering min)");

        _logPass();
    }
}
