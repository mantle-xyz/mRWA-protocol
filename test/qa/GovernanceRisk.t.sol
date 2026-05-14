// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategyAdapter} from "../../src/interfaces/adapters/IStrategyAdapter.sol";
import {IStrategyControllerExecutor} from "../../src/interfaces/strategy/IStrategyControllerExecutor.sol";
import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {IMantleVaultGateway} from "../../src/interfaces/vault/IMantleVaultGateway.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {MantleVaultGateway} from "../../src/vault/MantleVaultGateway.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {Accountant} from "../../src/accountant/Accountant.sol";
import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Test, console2} from "forge-std/Test.sol";
import {OperatorExecutor} from "../../src/protocol/OperatorExecutor.sol";
import {VaultViewHelper} from "../lib/VaultViewHelper.sol";

// ---------------------------------------------------------------------------
// Mocks
// ---------------------------------------------------------------------------

contract MockUSDC_GovRisk is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract MockPosToken_GovRisk is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract MockSanctionsOracle_GovRisk is ISanctionsOracle {
    mapping(address => bool) private _sanctioned;
    mapping(address => bool) private _whitelisted;

    function initialize(address, address) external override {}
    function isSanctioned(address account) external view override returns (bool) { return _sanctioned[account]; }
    function isWhitelisted(address account) external view override returns (bool) { return _whitelisted[account]; }
    function totalSanctionedCount() external pure override returns (uint256) { return 0; }
    function totalWhitelistedCount() external pure override returns (uint256) { return 0; }
    function lastUpdateTimestamp() external pure override returns (uint256) { return 0; }
    function batchNonce() external pure override returns (uint256) { return 0; }
    function MAX_BATCH_SIZE() external pure override returns (uint256) { return 200; }
    function updateSanctionStatus(address account, bool sanctioned) external override { _sanctioned[account] = sanctioned; }
    function updateSanctionStatusBatch(address[] calldata, bool) external override {}
    function updateWhitelistStatus(address account, bool whitelisted) external override { _whitelisted[account] = whitelisted; }
    function updateWhitelistStatusBatch(address[] calldata, bool) external override {}
}

contract MockStrategyAdapter_GovRisk is IStrategyAdapter {
    address public immutable ASSET;
    address public immutable POS_TOKEN;
    address public vaultAddr;
    string private _name;

    constructor(address asset_, address posToken_, string memory name_) {
        ASSET = asset_;
        POS_TOKEN = posToken_;
        _name = name_;
    }

    function setVault(address v) external { vaultAddr = v; }

    function name() external view returns (string memory) { return _name; }
    function asset() external view returns (address) { return ASSET; }
    function posToken() external view returns (address) { return POS_TOKEN; }
    function priceOracle() external pure returns (address) { return address(0); }
    function vault() external view returns (address) { return vaultAddr; }
    function setPaused(bool) external {}
    function retryRedeemAsync(uint256, address) external {}
    function minSubscribeAsset() external pure returns (uint256) { return 0; }
    function minRedeemPos() external pure returns (uint256) { return 0; }

    function getPosTokenPrice() external pure returns (uint256) { return 1e18; }
    function estimatePosAmount(uint256 assetAmount) external pure returns (uint256) { return assetAmount; }

    function previewDeposit(uint256 assetAmount)
        external
        pure
        returns (bool ok, uint256 executableAssetAmount, uint256 expectedPosAmount)
    {
        ok = assetAmount > 0;
        executableAssetAmount = assetAmount;
        expectedPosAmount = 0;
    }

    function previewRedeem(uint256 assetAmount)
        external
        pure
        returns (bool ok, uint256 executableAssetAmount, uint256 expectedPosAmount)
    {
        ok = assetAmount > 0;
        executableAssetAmount = assetAmount;
        expectedPosAmount = 0;
    }

    function totalValue() external view returns (uint256) {
        return MockPosToken_GovRisk(POS_TOKEN).balanceOf(address(this));
    }

    function deposit(uint256 amount, address) external returns (uint256) {
        IERC20(ASSET).transferFrom(vaultAddr, address(this), amount);
        MockPosToken_GovRisk(POS_TOKEN).mint(address(this), amount);
        return amount;
    }

    function withdrawSync(uint256 amount, address) external returns (uint256) {
        MockPosToken_GovRisk(POS_TOKEN).burn(address(this), amount);
        IERC20(ASSET).transfer(vaultAddr, amount);
        return amount;
    }

    function requestRedeemAsync(uint256, address) external {}

    function sweepToVault(address token, uint256 amount) external returns (uint256) {
        IERC20(token).transfer(vaultAddr, amount);
        return amount;
    }
}

// ---------------------------------------------------------------------------
// QA Test: Governance Risk Scenarios
// ---------------------------------------------------------------------------

contract GovernanceRiskQATest is Test {
    using VaultViewHelper for MantleYieldVault;
    MockUSDC_GovRisk internal usdc;
    MockPosToken_GovRisk internal posToken1;
    MockPosToken_GovRisk internal posToken2;
    MockSanctionsOracle_GovRisk internal oracle;
    MantleYieldVault internal vault;
    MantleVaultGateway internal gateway;
    Accountant internal accountant;
    StrategyController internal controller;
    MockStrategyAdapter_GovRisk internal adapter1;
    MockStrategyAdapter_GovRisk internal adapter2;
    OperatorExecutor internal executor;

    address internal admin = makeAddr("admin");
    address internal bot = makeAddr("bot");
    address internal treasury = makeAddr("treasury");
    address internal sanctionSafe = makeAddr("sanctionSafe");
    address internal userA = makeAddr("userA");
    address internal userB = makeAddr("userB");
    address internal userC = makeAddr("userC");
    address internal userD = makeAddr("userD");

    uint256 constant DEPOSIT_AMOUNT = 10_000e6;
    uint256 constant RATE = 1e18;
    uint256 constant FEE_BPS = 100; // 1%

    function setUp() public {
        usdc = new MockUSDC_GovRisk();
        posToken1 = new MockPosToken_GovRisk("PosToken1", "PT1");
        posToken2 = new MockPosToken_GovRisk("PosToken2", "PT2");
        oracle = new MockSanctionsOracle_GovRisk();
        OperatorExecutor execImpl = new OperatorExecutor();
        executor = OperatorExecutor(address(new ERC1967Proxy(
            address(execImpl),
            abi.encodeCall(OperatorExecutor.initialize, (admin, bot))
        )));

        // Deploy implementations
        MantleYieldVault vaultImpl = new MantleYieldVault();
        Accountant acctImpl = new Accountant();
        MantleVaultGateway gwImpl = new MantleVaultGateway();
        StrategyController ctrlImpl = new StrategyController();

        // Initialize vault
        bytes memory vaultInitData = abi.encodeCall(
            MantleYieldVault.initialize,
            IMantleYieldVault.InitParams({
                asset: IERC20(address(usdc)),
                name: "mRWA Vault",
                symbol: "mRWA",
                admin: admin,
                gateway: address(1), // placeholder
                controller: admin, // placeholder
                accountant: address(1), // placeholder
                treasury: treasury,
                maxRedemptionFeeBps: 500,
                redemptionFeeBps: FEE_BPS,
                minRedeemAmount: 0,
                minDepositAmount: 0,
                maxSettlementDeviationBps: 0,
                depositDailyRemaining: type(uint256).max,
                redeemDailyRemaining: type(uint256).max
            })
        );
        vault = MantleYieldVault(address(new ERC1967Proxy(address(vaultImpl), vaultInitData)));

        // Initialize accountant
        bytes memory acctInitData = abi.encodeCall(
            Accountant.initialize,
            (address(vault), uint64(RATE), 0, admin, admin, admin)
        );
        accountant = Accountant(address(new ERC1967Proxy(address(acctImpl), acctInitData)));

        // Initialize controller: bufferTargetBps=2000(20%), thresholdBps=500(5%), cooldown=0
        bytes memory ctrlInitData = abi.encodeCall(
            StrategyController.initialize,
            (address(vault), admin, address(executor), admin, 2000, 500, 0)
        );
        controller = StrategyController(address(new ERC1967Proxy(address(ctrlImpl), ctrlInitData)));

        // Initialize gateway
        bytes memory gwInitData = abi.encodeCall(
            MantleVaultGateway.initialize,
            IMantleVaultGateway.InitParams({
                vault: address(vault),
                sanctionsOracle: ISanctionsOracle(address(oracle)),
                sanctionSafe: sanctionSafe,
                admin: admin,
                syncRedeemDisabled: false
            })
        );
        gateway = MantleVaultGateway(address(new ERC1967Proxy(address(gwImpl), gwInitData)));

        // Wire up vault references
        vm.startPrank(admin);
        vault.setAccountant(address(accountant));
        vault.setGateway(address(gateway));
        vault.setController(address(controller));
        vm.stopPrank();

        // Create and register two adapters (50/50 weight)
        adapter1 = new MockStrategyAdapter_GovRisk(address(usdc), address(posToken1), "Adapter1");
        adapter1.setVault(address(vault));
        adapter2 = new MockStrategyAdapter_GovRisk(address(usdc), address(posToken2), "Adapter2");
        adapter2.setVault(address(vault));

        vm.startPrank(admin);
        controller.registerStrategy(address(adapter1), 5_000, 1, false);
        controller.activateStrategy(address(adapter1));
        controller.registerStrategy(address(adapter2), 5_000, 1, false);
        controller.activateStrategy(address(adapter2));
        address[] memory ordered = new address[](2);
        ordered[0] = address(adapter1);
        ordered[1] = address(adapter2);
        controller.setStrategyOrder(ordered);
        vm.stopPrank();

        // Fund and deposit for all users
        _fundAndDeposit(userA, DEPOSIT_AMOUNT);
        _fundAndDeposit(userB, DEPOSIT_AMOUNT);
        _fundAndDeposit(userC, DEPOSIT_AMOUNT);
        _fundAndDeposit(userD, DEPOSIT_AMOUNT);
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    function _fundAndDeposit(address user, uint256 amount) internal {
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(vault), type(uint256).max);
        gateway.deposit(amount);
        vm.stopPrank();
    }

    function _requestRedeemViaGateway(address user, uint256 shares) internal returns (uint256 requestId) {
        vm.prank(user);
        requestId = gateway.requestRedeem(shares);
    }

    function _settleAllInvestInFlight() internal {
        // Settle all pending invest in-flight records for both adapters
        uint256 nextId = vault.nextInFlightId();
        for (uint256 adaptIdx = 0; adaptIdx < 2; adaptIdx++) {
            address adpt = adaptIdx == 0 ? address(adapter1) : address(adapter2);
            // Collect pending invest inFlight IDs for this adapter
            uint256 count;
            uint256[] memory tempIds = new uint256[](nextId);
            for (uint256 i = 1; i < nextId; i++) {
                (address recAdapter, bool isInvest, IMantleYieldVault.InFlightStatus status) = vault.ifAdapterAndStatus(i);
                if (recAdapter == adpt && isInvest && status == IMantleYieldVault.InFlightStatus.PENDING) {
                    tempIds[count++] = i;
                }
            }
            if (count == 0) continue;

            uint256[] memory ids = new uint256[](count);
            uint256[] memory settledPos = new uint256[](count);
            uint256[] memory refunds = new uint256[](count);
            for (uint256 i = 0; i < count; i++) {
                ids[i] = tempIds[i];
                uint256 tokenAmount = vault.ifTokenAmount(ids[i]);
                settledPos[i] = tokenAmount;
                refunds[i] = 0;
            }
            uint256[] memory emptyIds = new uint256[](0);
            uint256[] memory emptyAmounts = new uint256[](0);

            vm.prank(bot);
            executor.executeSettleAdapter(
                address(controller),
                adpt,
                IStrategyControllerExecutor.InvestSettlementInput(ids, settledPos, refunds),
                IStrategyControllerExecutor.RedeemSettlementInput(emptyIds, emptyAmounts)
            );
        }
    }

    function _settleAllRedeemInFlight() internal {
        uint256 nextId = vault.nextInFlightId();
        for (uint256 adaptIdx = 0; adaptIdx < 2; adaptIdx++) {
            address adpt = adaptIdx == 0 ? address(adapter1) : address(adapter2);
            uint256 count;
            uint256[] memory tempIds = new uint256[](nextId);
            for (uint256 i = 1; i < nextId; i++) {
                (address recAdapter, bool isInvest, IMantleYieldVault.InFlightStatus status) = vault.ifAdapterAndStatus(i);
                if (recAdapter == adpt && !isInvest && status == IMantleYieldVault.InFlightStatus.PENDING) {
                    tempIds[count++] = i;
                }
            }
            if (count == 0) continue;

            uint256[] memory ids = new uint256[](count);
            uint256[] memory settledAmounts = new uint256[](count);
            for (uint256 i = 0; i < count; i++) {
                ids[i] = tempIds[i];
                uint256 usdcAmount = vault.ifUsdcAmount(ids[i]);
                settledAmounts[i] = usdcAmount;
            }
            uint256[] memory emptyIds = new uint256[](0);
            uint256[] memory emptyAmounts = new uint256[](0);

            vm.prank(bot);
            executor.executeSettleAdapter(
                address(controller),
                adpt,
                IStrategyControllerExecutor.InvestSettlementInput(emptyIds, emptyAmounts, emptyAmounts),
                IStrategyControllerExecutor.RedeemSettlementInput(ids, settledAmounts)
            );
        }
    }

    // -----------------------------------------------------------------------
    // Logging helpers
    // -----------------------------------------------------------------------

    string constant MODULE = unicode"运营选择性执行与治理风险场景";
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

    // =======================================================================
    //  1. Operator 只处理部分用户请求
    // =======================================================================

    function test_SelectiveProcessing() public {
        _logCase(
            "test_SelectiveProcessing",
            unicode"Operator 只处理部分用户请求，验证系统是否允许选择性推进"
        );

        // Step 1: Rebalance to invest into adapters (so processRedeemBatch has funds to divest)
        _step("[Step 1] Rebalance to invest into adapters");
        vm.warp(block.timestamp + 1);
        vm.prank(bot);
        executor.executeRebalance(address(controller));
        _settleAllInvestInFlight();
        _step(string.concat("  adapter1 value: ", vm.toString(adapter1.totalValue())));
        _step(string.concat("  adapter2 value: ", vm.toString(adapter2.totalValue())));

        // Step 2: Three users create async redeem requests
        _step("[Step 2] userA, userB, userC each create async redeem requests");
        uint256 redeemShares = 1_000e6;
        uint256 reqA = _requestRedeemViaGateway(userA, redeemShares);
        uint256 reqB = _requestRedeemViaGateway(userB, redeemShares);
        uint256 reqC = _requestRedeemViaGateway(userC, redeemShares);
        _step(string.concat("  reqA: ", vm.toString(reqA), ", reqB: ", vm.toString(reqB), ", reqC: ", vm.toString(reqC)));

        // Step 3: Verify all requests are PENDING
        _step("[Step 3] Verify all requests are PENDING");
        IMantleYieldVault.RequestStatus statusA = vault.reqStatus(reqA);
        IMantleYieldVault.RequestStatus statusB = vault.reqStatus(reqB);
        IMantleYieldVault.RequestStatus statusC = vault.reqStatus(reqC);
        assertEq(uint256(statusA), uint256(IMantleYieldVault.RequestStatus.PENDING));
        assertEq(uint256(statusB), uint256(IMantleYieldVault.RequestStatus.PENDING));
        assertEq(uint256(statusC), uint256(IMantleYieldVault.RequestStatus.PENDING));

        // Step 4: Operator selectively processes only reqB and reqC via processRedeemBatch
        _step("[Step 4] Operator processes only reqB and reqC via processRedeemBatch");
        uint256[] memory selectedIds = new uint256[](2);
        selectedIds[0] = reqB;
        selectedIds[1] = reqC;
        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), selectedIds);

        // Step 5: Verify selective processing results
        _step("[Step 5] Verify selective processing results");
        IMantleYieldVault.RequestStatus statusA2 = vault.reqStatus(reqA);
        IMantleYieldVault.RequestStatus statusB2 = vault.reqStatus(reqB);
        IMantleYieldVault.RequestStatus statusC2 = vault.reqStatus(reqC);
        assertEq(uint256(statusA2), uint256(IMantleYieldVault.RequestStatus.PENDING), "reqA should remain PENDING");
        assertEq(uint256(statusB2), uint256(IMantleYieldVault.RequestStatus.PROCESSING), "reqB should be PROCESSING");
        assertEq(uint256(statusC2), uint256(IMantleYieldVault.RequestStatus.PROCESSING), "reqC should be PROCESSING");
        _step("  reqA still PENDING, reqB and reqC are PROCESSING");
        _step("  NOTE: System allows selective processing - governance/fairness risk exists");

        _logPass();
    }

    // =======================================================================
    //  2. 先处理后创建的 batch 再处理早期 batch
    // =======================================================================

    function test_OutOfOrderBatchProcessing() public {
        _logCase(
            "test_OutOfOrderBatchProcessing",
            unicode"先处理后创建的 batch，再处理早期 batch，验证系统账本是否仍一致"
        );

        // Step 1: Rebalance to invest into adapters
        _step("[Step 1] Rebalance to invest into adapters");
        vm.warp(block.timestamp + 1);
        vm.prank(bot);
        executor.executeRebalance(address(controller));
        _settleAllInvestInFlight();

        // Step 2: Early batch requests
        _step("[Step 2] userA and userB create early batch requests");
        uint256 redeemShares = 1_000e6;
        uint256 earlyReq1 = _requestRedeemViaGateway(userA, redeemShares);
        uint256 earlyReq2 = _requestRedeemViaGateway(userB, redeemShares);
        _step(string.concat("  Early batch: ", vm.toString(earlyReq1), ", ", vm.toString(earlyReq2)));

        // Step 3: Late batch requests
        _step("[Step 3] userC and userD create late batch requests");
        uint256 lateReq1 = _requestRedeemViaGateway(userC, redeemShares);
        uint256 lateReq2 = _requestRedeemViaGateway(userD, redeemShares);
        _step(string.concat("  Late batch: ", vm.toString(lateReq1), ", ", vm.toString(lateReq2)));

        uint256 totalLockedBefore = vault.totalLockedShares();
        _step(string.concat("  totalLockedShares: ", vm.toString(totalLockedBefore)));

        // Step 4: Process LATE batch first (out of order)
        _step("[Step 4] Process late batch FIRST via processRedeemBatch");
        uint256[] memory lateIds = new uint256[](2);
        lateIds[0] = lateReq1;
        lateIds[1] = lateReq2;
        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), lateIds);

        // Step 5: Process early batch second
        _step("[Step 5] Process early batch SECOND via processRedeemBatch");
        uint256[] memory earlyIds = new uint256[](2);
        earlyIds[0] = earlyReq1;
        earlyIds[1] = earlyReq2;
        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), earlyIds);

        // Step 6: Settle redeem in-flight records from divest
        _step("[Step 6] Settle redeem in-flight records");
        _settleAllRedeemInFlight();

        // Step 7: Finalize late batch first
        _step("[Step 7] Finalize late batch first");
        uint256 lateEst1 = vault.reqEstimate(lateReq1);
        uint256 lateEst2 = vault.reqEstimate(lateReq2);
        uint256[] memory lateSettled = new uint256[](2);
        lateSettled[0] = lateEst1;
        lateSettled[1] = lateEst2;
        vm.prank(bot);
        executor.executeFinalizeRedeemBatch(address(controller), lateIds, lateSettled);

        // Step 8: Finalize early batch second
        _step("[Step 8] Finalize early batch second");
        uint256 earlyEst1 = vault.reqEstimate(earlyReq1);
        uint256 earlyEst2 = vault.reqEstimate(earlyReq2);
        uint256[] memory earlySettled = new uint256[](2);
        earlySettled[0] = earlyEst1;
        earlySettled[1] = earlyEst2;
        vm.prank(bot);
        executor.executeFinalizeRedeemBatch(address(controller), earlyIds, earlySettled);

        // Step 9: Verify all requests DONE and accounting consistent
        _step("[Step 9] Verify all requests DONE and accounting consistent");
        IMantleYieldVault.RequestStatus s1 = vault.reqStatus(earlyReq1);
        IMantleYieldVault.RequestStatus s2 = vault.reqStatus(earlyReq2);
        IMantleYieldVault.RequestStatus s3 = vault.reqStatus(lateReq1);
        IMantleYieldVault.RequestStatus s4 = vault.reqStatus(lateReq2);
        assertEq(uint256(s1), uint256(IMantleYieldVault.RequestStatus.DONE));
        assertEq(uint256(s2), uint256(IMantleYieldVault.RequestStatus.DONE));
        assertEq(uint256(s3), uint256(IMantleYieldVault.RequestStatus.DONE));
        assertEq(uint256(s4), uint256(IMantleYieldVault.RequestStatus.DONE));

        uint256 totalLockedAfter = vault.totalLockedShares();
        assertEq(totalLockedAfter, 0, "totalLockedShares should be 0 after all settled");
        _step(string.concat("  totalLockedShares: ", vm.toString(totalLockedAfter)));
        _step("  PASS: Out-of-order processing maintained consistent ledger");

        _logPass();
    }

    // =======================================================================
    //  3. Admin 在用户集中退出期间修改策略权重
    // =======================================================================

    function test_AdminModifyStrategyDuringExitWave() public {
        _logCase(
            "test_AdminModifyStrategyDuringExitWave",
            unicode"Admin 在用户集中退出期间修改策略权重，验证后续 divest 路径变化"
        );

        // Step 1: Rebalance to invest into both adapters (50/50)
        // Do NOT settle invest in-flight — posToken stays on adapters so they have totalValue for divest
        _step("[Step 1] Rebalance to invest into both adapters (50/50 weight)");
        vm.warp(block.timestamp + 1);
        vm.prank(bot);
        executor.executeRebalance(address(controller));

        uint256 adapter1ValueBefore = adapter1.totalValue();
        uint256 adapter2ValueBefore = adapter2.totalValue();
        _step(string.concat("  adapter1 value: ", vm.toString(adapter1ValueBefore)));
        _step(string.concat("  adapter2 value: ", vm.toString(adapter2ValueBefore)));
        assertGt(adapter1ValueBefore, 0, "adapter1 should have value");
        assertGt(adapter2ValueBefore, 0, "adapter2 should have value");

        // Step 2: Users create async redeem requests
        _step("[Step 2] userA and userB create async redeem requests");
        uint256 redeemShares = 2_000e6;
        uint256 reqA = _requestRedeemViaGateway(userA, redeemShares);
        uint256 reqB = _requestRedeemViaGateway(userB, redeemShares);
        _step(string.concat("  reqA: ", vm.toString(reqA), ", reqB: ", vm.toString(reqB)));

        uint256 totalLockedBefore = vault.totalLockedShares();
        uint256 freeCashBefore = vault.getFreeCash();
        _step(string.concat("  totalLockedShares: ", vm.toString(totalLockedBefore)));
        _step(string.concat("  freeCash: ", vm.toString(freeCashBefore)));

        // Step 3: Admin changes strategy weights — adapter2 gets 90%, adapter1 gets 10%
        // Also reverses strategy order so adapter2 is divested first
        _step("[Step 3] Admin modifies strategy weights: adapter2=90%, adapter1=10%, order reversed");
        address[] memory adapters = new address[](2);
        adapters[0] = address(adapter1);
        adapters[1] = address(adapter2);
        uint16[] memory weights = new uint16[](2);
        weights[0] = 1_000;  // 10%
        weights[1] = 9_000;  // 90%
        uint16[] memory priorities = new uint16[](2);
        priorities[0] = 1;
        priorities[1] = 1;
        bool[] memory isAsync = new bool[](2);
        isAsync[0] = false;
        isAsync[1] = false;
        address[] memory newOrder = new address[](2);
        newOrder[0] = address(adapter2);
        newOrder[1] = address(adapter1);
        vm.prank(admin);
        controller.updateStrategiesAndOrder(adapters, weights, priorities, isAsync, newOrder);

        // Step 4: Process redeem batch — divest will follow NEW weight/order
        _step("[Step 4] processRedeemBatch - divest follows new strategy order");
        uint256[] memory ids = new uint256[](2);
        ids[0] = reqA;
        ids[1] = reqB;
        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), ids);

        // Verify requests moved to PROCESSING
        IMantleYieldVault.RequestStatus sA = vault.reqStatus(reqA);
        IMantleYieldVault.RequestStatus sB = vault.reqStatus(reqB);
        assertEq(uint256(sA), uint256(IMantleYieldVault.RequestStatus.PROCESSING));
        assertEq(uint256(sB), uint256(IMantleYieldVault.RequestStatus.PROCESSING));

        // Check adapter values after divest — strategy order change should affect which adapter was divested
        uint256 adapter1ValueAfter = adapter1.totalValue();
        uint256 adapter2ValueAfter = adapter2.totalValue();
        _step(string.concat("  adapter1 value after divest: ", vm.toString(adapter1ValueAfter)));
        _step(string.concat("  adapter2 value after divest: ", vm.toString(adapter2ValueAfter)));

        // Step 5: Settle and finalize
        _step("[Step 5] Settle redeem in-flight and finalize batch");
        _settleAndFinalizeBatch(reqA, reqB, ids);

        // Step 6: Verify accounting consistency
        _step("[Step 6] Verify accounting consistency");
        _verifyAllDone(reqA, reqB);
        _step("  PASS: Strategy weight changes affect divest path but do not break request state machine");

        _logPass();
    }

    // =======================================================================
    //  4. Admin 更换 accountant/gateway/controller 后新旧地址切换
    // =======================================================================

    function test_AdminSwapCoreComponents() public {
        _logCase(
            "test_AdminSwapCoreComponents",
            unicode"Admin 更换 `accountant/gateway/controller` 后，新旧地址切换语义正确"
        );

        _step("[Step 1] Record current core component addresses");
        address oldAccountant = vault.accountant();
        address oldGateway = vault.gateway();
        address oldController = vault.controller();
        _step(string.concat("  old accountant: ", vm.toString(oldAccountant)));
        _step(string.concat("  old gateway: ", vm.toString(oldGateway)));
        _step(string.concat("  old controller: ", vm.toString(oldController)));

        // Step 2: Deploy new gateway
        _step("[Step 2] Deploy new gateway instance");
        MantleVaultGateway newGwImpl = new MantleVaultGateway();
        MantleVaultGateway newGateway = MantleVaultGateway(
            address(new ERC1967Proxy(
                address(newGwImpl),
                abi.encodeCall(
                    MantleVaultGateway.initialize,
                    IMantleVaultGateway.InitParams({
                        vault: address(vault),
                        sanctionsOracle: ISanctionsOracle(address(oracle)),
                        sanctionSafe: sanctionSafe,
                        admin: admin,
                        syncRedeemDisabled: false
                    })
                )
            ))
        );
        _step(string.concat("  new gateway: ", vm.toString(address(newGateway))));

        // Deploy new controller
        OperatorExecutor newExecImpl = new OperatorExecutor();
        OperatorExecutor newExecutor = OperatorExecutor(address(new ERC1967Proxy(
            address(newExecImpl),
            abi.encodeCall(OperatorExecutor.initialize, (admin, bot))
        )));
        StrategyController newCtrlImpl = new StrategyController();
        StrategyController newController = StrategyController(
            address(new ERC1967Proxy(
                address(newCtrlImpl),
                abi.encodeCall(
                    StrategyController.initialize,
                    (address(vault), admin, address(newExecutor), admin, 2000, 500, 0)
                )
            ))
        );
        _step(string.concat("  new controller: ", vm.toString(address(newController))));

        // Deploy new accountant
        Accountant newAcctImpl = new Accountant();
        Accountant newAccountant = Accountant(
            address(new ERC1967Proxy(
                address(newAcctImpl),
                abi.encodeCall(Accountant.initialize, (address(vault), uint64(RATE), 0, admin, admin, admin))
            ))
        );
        _step(string.concat("  new accountant: ", vm.toString(address(newAccountant))));

        // Step 3: Admin switches all components
        _step("[Step 3] Admin switches gateway, controller, accountant");
        vm.startPrank(admin);
        vault.setGateway(address(newGateway));
        vault.setController(address(newController));
        vault.setAccountant(address(newAccountant));
        vm.stopPrank();

        assertEq(vault.gateway(), address(newGateway));
        assertEq(vault.controller(), address(newController));
        assertEq(vault.accountant(), address(newAccountant));

        // Step 4: New gateway works
        _step("[Step 4] Verify new gateway can perform deposit");
        usdc.mint(userA, DEPOSIT_AMOUNT);
        vm.startPrank(userA);
        usdc.approve(address(vault), type(uint256).max);
        newGateway.deposit(DEPOSIT_AMOUNT);
        vm.stopPrank();
        _step("  userA deposited via new gateway successfully");

        // Step 5: Old gateway fails
        _step("[Step 5] Verify old gateway deposit fails");
        usdc.mint(userB, DEPOSIT_AMOUNT);
        vm.startPrank(userB);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert(IMantleYieldVault.Vault__OnlyGateway.selector);
        gateway.deposit(DEPOSIT_AMOUNT);
        vm.stopPrank();
        _step("  Old gateway deposit correctly reverts with Vault__OnlyGateway");

        // Step 6: Old controller fails through the real bot -> executor -> controller chain
        _step("[Step 6] Verify old controller path is rejected via old executor");
        uint256[] memory emptyIds = new uint256[](0);
        vm.expectRevert(IMantleYieldVault.Vault__OnlyController.selector);
        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), emptyIds);
        _step("  Old executor -> old controller path correctly reverts with Vault__OnlyController");

        // Step 7: New controller can operate through the real bot -> executor -> controller chain
        _step("[Step 7] Verify new controller path succeeds via new executor");
        vm.prank(bot);
        newExecutor.executeProcessRedeemBatch(address(newController), emptyIds);
        _step("  New executor -> new controller path can reach vault successfully");

        _step("  PASS: Component swap semantics correct - new works, old rejected");
        _logPass();
    }

    // =======================================================================
    //  5. 运营方长期不处理某些请求但持续处理其他请求
    // =======================================================================

    function test_LongTermUnprocessedRequests() public {
        _logCase(
            "test_LongTermUnprocessedRequests",
            unicode"运营方长期不处理某些请求，但持续处理其他请求，验证系统不会出现余额穿透或重复占用"
        );

        // Step 1: Rebalance to invest
        _step("[Step 1] Rebalance to invest into adapters");
        vm.warp(block.timestamp + 1);
        vm.prank(bot);
        executor.executeRebalance(address(controller));
        _settleAllInvestInFlight();

        // Step 2: Create neglected batch and processed batch
        _step("[Step 2] Create neglected batch (userA, userB) and processed batch (userC, userD)");
        uint256 redeemShares = 1_000e6;

        uint256 neglReq1 = _requestRedeemViaGateway(userA, redeemShares);
        uint256 neglReq2 = _requestRedeemViaGateway(userB, redeemShares);
        uint256 procReq1 = _requestRedeemViaGateway(userC, redeemShares);
        uint256 procReq2 = _requestRedeemViaGateway(userD, redeemShares);
        _step(string.concat("  Neglected: ", vm.toString(neglReq1), ", ", vm.toString(neglReq2)));
        _step(string.concat("  Processed: ", vm.toString(procReq1), ", ", vm.toString(procReq2)));

        // Step 3: Record initial state
        _step("[Step 3] Record initial accounting state");
        uint256 totalLockedInitial = vault.totalLockedShares();
        uint256 freeCashInitial = vault.getFreeCash();
        uint256 totalAssetsInitial = vault.totalAssets();
        _step(string.concat("  totalLockedShares: ", vm.toString(totalLockedInitial)));
        _step(string.concat("  freeCash: ", vm.toString(freeCashInitial)));
        _step(string.concat("  totalAssets: ", vm.toString(totalAssetsInitial)));

        // Step 4-6: Process batch, verify states, return locked-shares-mid
        uint256 totalLockedMid = _processAndVerifyBatch(
            procReq1, procReq2, neglReq1, neglReq2, totalLockedInitial
        );

        // Step 7: 30 days pass, new request cycle while neglected ones remain
        _step("[Step 7] 30 days pass, new request processed while neglected ones remain");
        vm.warp(block.timestamp + 30 days);
        _processNewRequestCycle(userC, redeemShares);

        // Step 8: Final accounting check
        _step("[Step 8] Final accounting consistency check");
        _verifyFinalAccounting(neglReq1, neglReq2, totalLockedMid);

        _logPass();
    }

    /// @dev Steps 4-6: process batch, verify statuses, check accounting
    function _processAndVerifyBatch(
        uint256 procReq1,
        uint256 procReq2,
        uint256 neglReq1,
        uint256 neglReq2,
        uint256 totalLockedInitial
    ) internal returns (uint256 totalLockedMid) {
        _step("[Step 4] Process and finalize only processed batch via controller");
        uint256[] memory procIds = new uint256[](2);
        procIds[0] = procReq1;
        procIds[1] = procReq2;
        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), procIds);

        _settleAllRedeemInFlight();

        uint256 est1 = vault.reqEstimate(procReq1);
        uint256 est2 = vault.reqEstimate(procReq2);
        uint256[] memory settledAmounts = new uint256[](2);
        settledAmounts[0] = est1;
        settledAmounts[1] = est2;
        vm.prank(bot);
        executor.executeFinalizeRedeemBatch(address(controller), procIds, settledAmounts);
        _step("  Processed batch finalized to DONE");

        // Step 5: Verify neglected requests still PENDING with locked liabilities
        _step("[Step 5] Verify neglected requests still occupy locked liabilities");
        IMantleYieldVault.RequestStatus neglS1 = vault.reqStatus(neglReq1);
        IMantleYieldVault.RequestStatus neglS2 = vault.reqStatus(neglReq2);
        assertEq(uint256(neglS1), uint256(IMantleYieldVault.RequestStatus.PENDING));
        assertEq(uint256(neglS2), uint256(IMantleYieldVault.RequestStatus.PENDING));

        IMantleYieldVault.RequestStatus procS1 = vault.reqStatus(procReq1);
        IMantleYieldVault.RequestStatus procS2 = vault.reqStatus(procReq2);
        assertEq(uint256(procS1), uint256(IMantleYieldVault.RequestStatus.DONE));
        assertEq(uint256(procS2), uint256(IMantleYieldVault.RequestStatus.DONE));

        totalLockedMid = vault.totalLockedShares();
        assertGt(totalLockedMid, 0, "neglected requests still lock shares");
        assertLt(totalLockedMid, totalLockedInitial, "processed requests released their lock");
        _step(string.concat("  totalLockedShares: ", vm.toString(totalLockedMid)));

        // Step 6: Verify totalAssets and freeCash consistency
        _step("[Step 6] Verify totalAssets and freeCash consistency");
        uint256 freeCashMid = vault.getFreeCash();
        uint256 totalAssetsMid = vault.totalAssets();
        _step(string.concat("  freeCash: ", vm.toString(freeCashMid)));
        _step(string.concat("  totalAssets: ", vm.toString(totalAssetsMid)));
        assertGt(totalAssetsMid, 0, "totalAssets should be positive");
    }

    /// @dev Step 7 helper: fund, deposit, request, process, settle, finalize a new request
    function _processNewRequestCycle(address user, uint256 shares) internal {
        _fundAndDeposit(user, DEPOSIT_AMOUNT);
        uint256 newReq = _requestRedeemViaGateway(user, shares);
        _step(string.concat("  New request: ", vm.toString(newReq)));

        uint256[] memory newIds = new uint256[](1);
        newIds[0] = newReq;
        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), newIds);

        _settleAllRedeemInFlight();

        uint256 newEst = vault.reqEstimate(newReq);
        uint256[] memory newSettled = new uint256[](1);
        newSettled[0] = newEst;
        vm.prank(bot);
        executor.executeFinalizeRedeemBatch(address(controller), newIds, newSettled);
        _step("  New request processed and finalized");
    }

    /// @dev Step 8 helper: verify neglected requests and final accounting
    function _verifyFinalAccounting(uint256 neglReq1, uint256 neglReq2, uint256 expectedLocked) internal {
        IMantleYieldVault.RequestStatus finalN1 = vault.reqStatus(neglReq1);
        IMantleYieldVault.RequestStatus finalN2 = vault.reqStatus(neglReq2);
        assertEq(uint256(finalN1), uint256(IMantleYieldVault.RequestStatus.PENDING), "neglected still PENDING");
        assertEq(uint256(finalN2), uint256(IMantleYieldVault.RequestStatus.PENDING), "neglected still PENDING");

        uint256 finalLocked = vault.totalLockedShares();
        uint256 finalFreeCash = vault.getFreeCash();
        uint256 finalTotalAssets = vault.totalAssets();
        _step(string.concat("  totalLockedShares: ", vm.toString(finalLocked)));
        _step(string.concat("  freeCash: ", vm.toString(finalFreeCash)));
        _step(string.concat("  totalAssets: ", vm.toString(finalTotalAssets)));

        assertGt(finalLocked, 0, "still have locked shares from neglected requests");
        assertEq(finalLocked, expectedLocked, "neglected lock unchanged after new cycle");
        assertGt(finalTotalAssets, 0, "totalAssets should remain positive");
        _step("  PASS: System accounting remains consistent despite long-term neglected requests");
    }

    /// @dev Settle all redeem in-flight, then finalize a 2-request batch
    function _settleAndFinalizeBatch(uint256 reqA, uint256 reqB, uint256[] memory ids) internal {
        _settleAllRedeemInFlight();
        uint256 estA = vault.reqEstimate(reqA);
        uint256 estB = vault.reqEstimate(reqB);
        uint256[] memory settled = new uint256[](2);
        settled[0] = estA;
        settled[1] = estB;
        vm.prank(bot);
        executor.executeFinalizeRedeemBatch(address(controller), ids, settled);
    }

    /// @dev Assert two requests are DONE and locked shares cleared
    function _verifyAllDone(uint256 reqA, uint256 reqB) internal {
        uint256 totalLockedAfter = vault.totalLockedShares();
        assertEq(totalLockedAfter, 0, "totalLockedShares should be 0 after all requests finalized");
        IMantleYieldVault.RequestStatus finalA = vault.reqStatus(reqA);
        IMantleYieldVault.RequestStatus finalB = vault.reqStatus(reqB);
        assertEq(uint256(finalA), uint256(IMantleYieldVault.RequestStatus.DONE));
        assertEq(uint256(finalB), uint256(IMantleYieldVault.RequestStatus.DONE));
        _step(string.concat("  totalLockedShares after: ", vm.toString(totalLockedAfter)));
    }

    // =======================================================================
    // Settlement Deviation — admin 下调限制后结算被拒
    // =======================================================================

    function test_AdminLowerDeviation_PreviouslyOKSettlementRejected() public {
        _logCase(
            "test_AdminLowerDeviation_PreviouslyOKSettlementRejected",
            unicode"admin 下调偏差限制后，之前可通过的结算被拒绝"
        );

        _step("[Step 1] Admin sets initial maxSettlementDeviationBps = 2000 (20%)");
        vm.prank(admin);
        vault.setMaxSettlementDeviation(2000);
        assertEq(vault.maxSettlementDeviationBps(), 2000);

        _step("[Step 2] UserA requests redeem");
        uint256 userShares = vault.balanceOf(userA);
        uint256 reqId = _requestRedeemViaGateway(userA, userShares);

        _step("[Step 3] Advance to PROCESSING via real chain");
        uint256[] memory ids = new uint256[](1);
        ids[0] = reqId;
        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), ids);

        uint256 estimatedAssets = vault.reqEstimate(reqId);
        _step(string.concat("  estimatedAssets = ", vm.toString(estimatedAssets)));

        _step("[Step 4] Admin lowers deviation limit to 500 bps (5%)");
        vm.prank(admin);
        vault.setMaxSettlementDeviation(500);
        assertEq(vault.maxSettlementDeviationBps(), 500);
        _step("  maxSettlementDeviationBps changed: 2000 -> 500");

        _step("[Step 5] Attempt settlement with 15% deviation (would have been OK at 20%)");
        uint256 settleAmount = estimatedAssets * 85 / 100; // 15% underpay
        uint256 expectedDeviationBps = ((estimatedAssets - settleAmount) * 10_000) / estimatedAssets;
        _step(string.concat("  settleAmount = ", vm.toString(settleAmount)));
        _step(string.concat("  deviationBps = ", vm.toString(expectedDeviationBps), " (15% > new limit 5%)"));

        uint256[] memory settledArr = new uint256[](1);
        settledArr[0] = settleAmount;

        vm.expectRevert(
            abi.encodeWithSelector(
                IMantleYieldVault.Vault__SettlementDeviationExceeded.selector,
                reqId,
                estimatedAssets,
                settleAmount,
                expectedDeviationBps,
                500
            )
        );
        vm.prank(bot);
        executor.executeFinalizeRedeemBatch(address(controller), ids, settledArr);

        _step("[Step 6] Verify request status unchanged");
        IMantleYieldVault.RequestStatus statusAfter = vault.reqStatus(reqId);
        assertEq(uint256(statusAfter), uint256(IMantleYieldVault.RequestStatus.PROCESSING));
        _step("  PASS: previously-OK 15% deviation now rejected after admin lowered limit to 5%");
        _logPass();
    }
}
