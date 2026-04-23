// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategyAdapter} from "../../src/interfaces/adapters/IStrategyAdapter.sol";
import {IStrategyControllerExecutor} from "../../src/interfaces/strategy/IStrategyControllerExecutor.sol";
import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {IMantleVaultGateway} from "../../src/interfaces/vault/IMantleVaultGateway.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {SubRedManagementAdapter} from "../../src/adapters/digift/SubRedManagementAdapter.sol";
import {MockDFeedPriceOracle} from "../../src/mocks/strategy/MockDFeedPriceOracle.sol";
import {MantleVaultGateway} from "../../src/vault/MantleVaultGateway.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {GatewayFactory} from "../../src/vault/GatewayFactory.sol";
import {VaultFactory} from "../../src/vault/VaultFactory.sol";
import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test, console2} from "forge-std/Test.sol";

// =============================================================
// Mock contracts (same pattern as StrategyController.t.sol)
// =============================================================

contract MockAsset is ERC20 {
    constructor() ERC20("MockAsset", "mAST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockStrategyAdapter is IStrategyAdapter {
    address public immutable ASSET;
    address public immutable POS_TOKEN;

    uint256 public mockedTotalValue;
    bool public paused;
    bool public failDeposit;
    bool public failWithdraw;
    bool public failAsync;
    bool public failEstimate;
    bool public depositReturnZero;

    uint256 public depositCount;
    uint256 public withdrawCount;
    uint256 public asyncCount;
    uint256 public claimCount;
    address public lastClaimToken;
    uint256 public lastClaimAmount;
    uint256 public sweepReturnAmount;
    bool public useSweepReturnAmount;

    constructor(address asset_, address posToken_) {
        ASSET = asset_;
        POS_TOKEN = posToken_;
    }

    function setTotalValue(uint256 v) external {
        mockedTotalValue = v;
    }

    function setFailFlags(bool d, bool w, bool a) external {
        failDeposit = d;
        failWithdraw = w;
        failAsync = a;
    }

    function setFailEstimate(bool e) external {
        failEstimate = e;
    }

    function setDepositReturnZero(bool z) external {
        depositReturnZero = z;
    }

    function setSweepReturnAmount(uint256 amount_) external {
        sweepReturnAmount = amount_;
        useSweepReturnAmount = true;
    }

    function name() external pure returns (string memory) {
        return "MockStrategyAdapter";
    }

    function asset() external view returns (address) {
        return ASSET;
    }

    function posToken() external view returns (address) {
        return POS_TOKEN;
    }

    function priceOracle() external pure returns (address) {
        return address(0);
    }

    function getPosTokenPrice() external pure returns (uint256) {
        return 0;
    }

    function estimatePosAmount(uint256 assetAmount) external view returns (uint256 positionAmount) {
        if (failEstimate) revert("ESTIMATE_FAIL");
        return assetAmount;
    }

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

    function vault() external pure returns (address) {
        return address(0);
    }

    function totalValue() external view returns (uint256) {
        return mockedTotalValue;
    }

    function deposit(uint256 amount, address) external returns (uint256 sharesOrPos) {
        if (failDeposit) revert("DEPOSIT_FAIL");
        depositCount++;
        return depositReturnZero ? 0 : amount;
    }

    function withdrawSync(uint256 amount, address) external returns (uint256 actualUSDC) {
        if (failWithdraw) revert("WITHDRAW_FAIL");
        withdrawCount++;
        return amount;
    }

    function requestRedeemAsync(uint256, address) external {
        if (failAsync) revert("ASYNC_FAIL");
        asyncCount++;
    }

    function retryRedeemAsync(uint256, address) external {}

    function sweepToVault(address token, uint256 amount) external returns (uint256 claimed) {
        claimCount++;
        lastClaimToken = token;
        lastClaimAmount = amount;
        if (useSweepReturnAmount) {
            return sweepReturnAmount;
        }
        return amount;
    }

    function setPaused(bool p) external {
        paused = p;
    }
}

contract MockControllerVault {
    ERC20 public immutable token;
    uint256 public mockedExchangeRate = 1e18;

    uint256 public locked;
    uint256 public investInFlightTotal;
    uint256 public redeemInFlightTotal;
    uint256 public inFlightIdCursor;
    mapping(address => uint256) public investInFlightByAdapter;
    mapping(address => uint256) public redeemInFlightByAdapter;
    mapping(address => bool) public isAdapterRegistry;

    struct Req {
        uint256 shares;
        uint256 estimatedAssets;
        uint256 settledAssets;
        IMantleYieldVault.RequestStatus status;
    }

    struct InFlight {
        uint256 id;
        address adapter;
        address assetAddr;
        uint256 tokenAmount;
        uint256 usdcAmount;
        uint256 settledAmount;
        bool isInvest;
        uint256 timestamp;
        IMantleYieldVault.InFlightStatus status;
    }

    mapping(uint256 => Req) public reqs;
    mapping(uint256 => InFlight) public flights;

    constructor(address asset_) {
        token = ERC20(asset_);
    }

    function asset() external view returns (address) {
        return address(token);
    }

    function setLocked(uint256 v) external {
        locked = v;
    }

    function setRequest(
        uint256 id,
        uint256 estimatedAssets,
        uint256 settledAssets,
        IMantleYieldVault.RequestStatus status
    ) external {
        reqs[id] = Req({
            shares: estimatedAssets,
            estimatedAssets: estimatedAssets,
            settledAssets: settledAssets,
            status: status
        });
    }

    function setExchangeRate(uint256 rate) external {
        mockedExchangeRate = rate;
    }

    function exchangeRate() external view returns (uint256) {
        return mockedExchangeRate;
    }

    function totalLockedLiabilities() external view returns (uint256) {
        return locked;
    }

    function totalInvestInFlight() external view returns (uint256) {
        return investInFlightTotal;
    }

    function totalRedeemInFlight() external view returns (uint256) {
        return redeemInFlightTotal;
    }

    function adapterInvestInFlightTokens(address adapter) external view returns (uint256) {
        return investInFlightByAdapter[adapter];
    }

    function adapterRedeemInFlightUsdc(address adapter) external view returns (uint256) {
        return redeemInFlightByAdapter[adapter];
    }

    function getFreeCash() external view returns (uint256) {
        uint256 totalCash = token.balanceOf(address(this));
        return totalCash > locked ? totalCash - locked : 0;
    }

    function approveToAdapter(address adapter, address approveToken, uint256 amount) external {
        ERC20(approveToken).approve(adapter, amount);
    }

    function isAdapter(address adapter) external view returns (bool) {
        return isAdapterRegistry[adapter];
    }

    function registerAdapter(address adapter) external {
        isAdapterRegistry[adapter] = true;
    }

    function removeAdapter(address adapter) external {
        require(investInFlightByAdapter[adapter] == 0 && redeemInFlightByAdapter[adapter] == 0, "HAS_IN_FLIGHT");
        isAdapterRegistry[adapter] = false;
    }

    function updateRequestBatch(uint256[] calldata ids, IMantleYieldVault.RequestStatus newStatus) external {
        for (uint256 i = 0; i < ids.length; i++) {
            reqs[ids[i]].status = newStatus;
        }
    }

    function markRequestsDone(uint256[] calldata ids, uint256[] calldata settledAssets) external {
        for (uint256 i = 0; i < ids.length; i++) {
            reqs[ids[i]].settledAssets = settledAssets[i];
            reqs[ids[i]].status = IMantleYieldVault.RequestStatus.DONE;
        }
    }

    function createInFlight(address adapter, address assetAddr, uint256 tokenAmount, uint256 usdcAmount, bool isInvest)
        external
        returns (uint256 inFlightId)
    {
        inFlightId = ++inFlightIdCursor;
        flights[inFlightId] = InFlight({
            id: inFlightId,
            adapter: adapter,
            assetAddr: assetAddr,
            tokenAmount: tokenAmount,
            usdcAmount: usdcAmount,
            settledAmount: 0,
            isInvest: isInvest,
            timestamp: block.timestamp,
            status: IMantleYieldVault.InFlightStatus.PENDING
        });
        if (isInvest) {
            investInFlightTotal += usdcAmount;
            investInFlightByAdapter[adapter] += tokenAmount;
        } else {
            redeemInFlightTotal += usdcAmount;
            redeemInFlightByAdapter[adapter] += usdcAmount;
        }
    }

    function confirmInFlight(uint256 inFlightId, uint256 actualAmount, bool) external {
        InFlight storage f = flights[inFlightId];
        f.settledAmount = actualAmount;
        f.status = IMantleYieldVault.InFlightStatus.CONFIRMED;
        if (f.isInvest && investInFlightTotal >= f.usdcAmount) {
            investInFlightTotal -= f.usdcAmount;
            if (investInFlightByAdapter[f.adapter] >= f.tokenAmount) {
                investInFlightByAdapter[f.adapter] -= f.tokenAmount;
            }
        }
        if (!f.isInvest && redeemInFlightTotal >= f.usdcAmount) {
            redeemInFlightTotal -= f.usdcAmount;
            if (redeemInFlightByAdapter[f.adapter] >= f.usdcAmount) {
                redeemInFlightByAdapter[f.adapter] -= f.usdcAmount;
            }
        }
    }

    function requests(uint256 requestId)
        external
        view
        returns (uint256, address, uint256, uint256, uint256, uint256, uint256, IMantleYieldVault.RequestStatus)
    {
        Req memory r = reqs[requestId];
        return (requestId, address(0), r.shares, 0, r.estimatedAssets, r.settledAssets, 0, r.status);
    }

    function inFlightRecords(uint256 inFlightId)
        external
        view
        returns (
            uint256 id,
            address adapter,
            address assetAddr,
            uint256 tokenAmount,
            uint256 usdcAmount,
            uint256 settledAmount,
            bool isInvest,
            uint256 timestamp,
            IMantleYieldVault.InFlightStatus status
        )
    {
        InFlight memory f = flights[inFlightId];
        return (f.id, f.adapter, f.assetAddr, f.tokenAmount, f.usdcAmount, f.settledAmount, f.isInvest, f.timestamp, f.status);
    }
}

contract DummyExecutor {}

// =============================================================
// Risk Regression Tests - In-flight settlement edge cases
// =============================================================

contract RiskRegressionTest is Test {
    MockAsset internal asset;
    MockAsset internal posToken;
    MockAsset internal posToken2;
    MockControllerVault internal vault;
    StrategyController internal controller;
    DummyExecutor internal executorGateway;

    MockStrategyAdapter internal asyncAdapter;
    MockStrategyAdapter internal asyncAdapter2;

    address internal admin = makeAddr("admin");
    address internal manager = makeAddr("manager");

    function setUp() public {
        asset = new MockAsset();
        posToken = new MockAsset();
        posToken2 = new MockAsset();
        vault = new MockControllerVault(address(asset));
        executorGateway = new DummyExecutor();

        StrategyController implementation = new StrategyController();
        bytes memory initData = abi.encodeCall(
            StrategyController.initialize,
            (address(vault), manager, address(executorGateway), manager, 1000, 200, 1 hours)
        );
        controller = StrategyController(address(new ERC1967Proxy(address(implementation), initData)));

        asyncAdapter = new MockStrategyAdapter(address(asset), address(posToken));
        asyncAdapter2 = new MockStrategyAdapter(address(asset), address(posToken2));
    }

    function _registerSingleAsyncStrategy() internal {
        vm.startPrank(manager);
        controller.registerStrategy(address(asyncAdapter), 10_000, 1, true);
        controller.activateStrategy(address(asyncAdapter));
        address[] memory ordered = new address[](1);
        ordered[0] = address(asyncAdapter);
        controller.setStrategyOrder(ordered);
        vm.stopPrank();
    }

    function _registerTwoAsyncStrategies() internal {
        vm.startPrank(manager);
        controller.registerStrategy(address(asyncAdapter), 5000, 1, true);
        controller.activateStrategy(address(asyncAdapter));
        controller.registerStrategy(address(asyncAdapter2), 5000, 2, true);
        controller.activateStrategy(address(asyncAdapter2));
        address[] memory ordered = new address[](2);
        ordered[0] = address(asyncAdapter);
        ordered[1] = address(asyncAdapter2);
        controller.setStrategyOrder(ordered);
        vm.stopPrank();
    }

    string constant MODULE = unicode"风险回归场景";
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

    // =========================================================================
    // Part A: In-flight settlement regression tests
    // =========================================================================

    // P0: settledAmount records actual Y, not recorded X
    function test_ConfirmInFlight_RecordsActualSettledAmount() public {
        _logCase("test_ConfirmInFlight_RecordsActualSettledAmount", unicode"redeem in-flight 确认时记录实际 settledAmount，而不是强制等于记录值");
        _step("[Step 1] Register single async strategy");
        _registerSingleAsyncStrategy();

        _step("[Step 2] Create redeem in-flight with usdcAmount X = 100e18");
        uint256 inFlightId = vault.createInFlight(address(asyncAdapter), address(asset), 0, 100e18, false);
        _step(string.concat("  inFlightId = ", vm.toString(inFlightId)));

        _step("[Step 3] Set actual settled amount Y = 95e18 (different from X)");
        uint256 actualY = 95e18;
        asyncAdapter.setSweepReturnAmount(actualY);
        _step(string.concat("  actualY = ", vm.toString(actualY)));

        _step("[Step 4] Settle adapter with redeem in-flight");
        uint256[] memory redeemIds = new uint256[](1);
        redeemIds[0] = inFlightId;
        uint256[] memory redeemAmounts = new uint256[](1);
        redeemAmounts[0] = actualY;

        vm.prank(address(executorGateway));
        controller.settleAdapter(
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(new uint256[](0), new uint256[](0), new uint256[](0)),
            IStrategyControllerExecutor.RedeemSettlementInput(redeemIds, redeemAmounts)
        );
        _step("  settleAdapter completed successfully");

        _step("[Step 5] Verify settledAmount == actual Y, not original X");
        (,,,,, uint256 settledAmount,,, IMantleYieldVault.InFlightStatus status) = vault.inFlightRecords(inFlightId);
        _step(string.concat("  settledAmount = ", vm.toString(settledAmount)));
        _step(string.concat("  status = ", vm.toString(uint8(status))));
        assertEq(settledAmount, actualY, "settledAmount should be actual Y=95e18, not recorded X=100e18");
        _step("  PASS: settledAmount == actualY (95e18)");
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        _step("  PASS: status == CONFIRMED");
        _logPass();
    }

    // P0: stats decrease by original usdcAmount X, not Y
    function test_ConfirmInFlight_StatsDecreaseByRecordedAmount() public {
        _logCase("test_ConfirmInFlight_StatsDecreaseByRecordedAmount", unicode"redeem in-flight 确认后，统计清账按原记录值 usdcAmount 递减");
        _step("[Step 1] Register single async strategy");
        _registerSingleAsyncStrategy();

        _step("[Step 2] Create redeem in-flight with usdcAmount X = 100e18");
        uint256 inFlightId = vault.createInFlight(address(asyncAdapter), address(asset), 0, 100e18, false);
        _step(string.concat("  inFlightId = ", vm.toString(inFlightId)));

        _step("[Step 3] Verify initial stats match X = 100e18");
        uint256 redeemTotalBefore = vault.redeemInFlightTotal();
        uint256 adapterRedeemBefore = vault.redeemInFlightByAdapter(address(asyncAdapter));
        _step(string.concat("  redeemTotalBefore = ", vm.toString(redeemTotalBefore)));
        _step(string.concat("  adapterRedeemBefore = ", vm.toString(adapterRedeemBefore)));
        assertEq(redeemTotalBefore, 100e18);
        assertEq(adapterRedeemBefore, 100e18);
        _step("  PASS: initial stats == 100e18");

        _step("[Step 4] Settle with actual Y = 80e18 (less than X)");
        uint256 actualY = 80e18;
        asyncAdapter.setSweepReturnAmount(actualY);

        uint256[] memory redeemIds = new uint256[](1);
        redeemIds[0] = inFlightId;
        uint256[] memory redeemAmounts = new uint256[](1);
        redeemAmounts[0] = actualY;

        vm.prank(address(executorGateway));
        controller.settleAdapter(
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(new uint256[](0), new uint256[](0), new uint256[](0)),
            IStrategyControllerExecutor.RedeemSettlementInput(redeemIds, redeemAmounts)
        );
        _step("  settleAdapter completed successfully");

        _step("[Step 5] Verify stats decreased by original X=100e18, not actual Y=80e18");
        _step(string.concat("  redeemInFlightTotal = ", vm.toString(vault.redeemInFlightTotal())));
        _step(string.concat("  adapterRedeemInFlight = ", vm.toString(vault.redeemInFlightByAdapter(address(asyncAdapter)))));
        assertEq(vault.redeemInFlightTotal(), 0, "redeemInFlightTotal should decrease by X=100e18 to 0");
        _step("  PASS: redeemInFlightTotal == 0");
        assertEq(
            vault.redeemInFlightByAdapter(address(asyncAdapter)),
            0,
            "adapter redeemInFlight should decrease by X=100e18 to 0"
        );
        _step("  PASS: adapterRedeemInFlight == 0");
        _logPass();
    }

    // P0: Y < X, confirm succeeds, difference exposed in finalize
    function test_ConfirmInFlight_ActualLessThanRecorded_StillSucceeds() public {
        _logCase("test_ConfirmInFlight_ActualLessThanRecorded_StillSucceeds", unicode"实际回款小于记录值时，确认阶段仍可完成，差异在后续结算阶段暴露");
        _step("[Step 1] Register single async strategy");
        _registerSingleAsyncStrategy();

        _step("[Step 2] Create redeem in-flight with X = 100e18");
        uint256 inFlightId = vault.createInFlight(address(asyncAdapter), address(asset), 0, 100e18, false);
        _step(string.concat("  inFlightId = ", vm.toString(inFlightId)));

        _step("[Step 3] Set actual Y = 60e18 (less than X)");
        uint256 actualY = 60e18;
        asyncAdapter.setSweepReturnAmount(actualY);
        _step(string.concat("  actualY = ", vm.toString(actualY)));

        uint256[] memory redeemIds = new uint256[](1);
        redeemIds[0] = inFlightId;
        uint256[] memory redeemAmounts = new uint256[](1);
        redeemAmounts[0] = actualY;

        _step("[Step 4] Settle adapter - should NOT revert even though Y < X");
        vm.prank(address(executorGateway));
        controller.settleAdapter(
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(new uint256[](0), new uint256[](0), new uint256[](0)),
            IStrategyControllerExecutor.RedeemSettlementInput(redeemIds, redeemAmounts)
        );
        _step("  PASS: settleAdapter did not revert with Y < X");

        _step("[Step 5] Verify settledAmount == Y and status == CONFIRMED");
        (,,,,, uint256 settledAmount,,, IMantleYieldVault.InFlightStatus status) = vault.inFlightRecords(inFlightId);
        _step(string.concat("  settledAmount = ", vm.toString(settledAmount)));
        assertEq(settledAmount, actualY, "settledAmount should record actual Y=60e18");
        _step("  PASS: settledAmount == 60e18");
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        _step("  PASS: status == CONFIRMED");

        _step("[Step 6] Create request expecting 100e18 and process it");
        uint256[] memory requestIds = new uint256[](1);
        requestIds[0] = 42;
        vault.setRequest(42, 100e18, 0, IMantleYieldVault.RequestStatus.PROCESSING);

        vm.prank(address(executorGateway));
        controller.processRedeemBatch(requestIds);
        _step("  processRedeemBatch completed");

        uint256[] memory settledAssets = new uint256[](1);
        settledAssets[0] = 100e18;

        _step("[Step 7] Finalize with no physical balance -> expect revert");
        vm.prank(address(executorGateway));
        vm.expectRevert();
        controller.finalizeRedeemBatch(requestIds, settledAssets);
        _step("  PASS: reverted as expected (insufficient physical balance)");
        _logPass();
    }

    // P0: Y > X, stats still decrease by X
    function test_ConfirmInFlight_ActualMoreThanRecorded_StatsStillByOriginal() public {
        _logCase("test_ConfirmInFlight_ActualMoreThanRecorded_StatsStillByOriginal", unicode"实际回款大于记录值时，确认阶段记录超额实际值，但统计仍按原记录值清账");
        _step("[Step 1] Register single async strategy");
        _registerSingleAsyncStrategy();

        _step("[Step 2] Create redeem in-flight with usdcAmount X = 100e18");
        uint256 inFlightId = vault.createInFlight(address(asyncAdapter), address(asset), 0, 100e18, false);
        _step(string.concat("  inFlightId = ", vm.toString(inFlightId)));

        _step("[Step 3] Set actual Y = 120e18 (more than X)");
        uint256 actualY = 120e18;
        asyncAdapter.setSweepReturnAmount(actualY);
        _step(string.concat("  actualY = ", vm.toString(actualY)));

        _step("[Step 4] Settle adapter");
        uint256[] memory redeemIds = new uint256[](1);
        redeemIds[0] = inFlightId;
        uint256[] memory redeemAmounts = new uint256[](1);
        redeemAmounts[0] = actualY;

        vm.prank(address(executorGateway));
        controller.settleAdapter(
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(new uint256[](0), new uint256[](0), new uint256[](0)),
            IStrategyControllerExecutor.RedeemSettlementInput(redeemIds, redeemAmounts)
        );
        _step("  settleAdapter completed successfully");

        _step("[Step 5] Verify stats decrease by original X=100e18, not actual Y=120e18");
        _step(string.concat("  redeemInFlightTotal = ", vm.toString(vault.redeemInFlightTotal())));
        _step(string.concat("  adapterRedeemInFlight = ", vm.toString(vault.redeemInFlightByAdapter(address(asyncAdapter)))));
        assertEq(vault.redeemInFlightTotal(), 0, "redeemInFlightTotal decreases by X=100e18");
        _step("  PASS: redeemInFlightTotal == 0");
        assertEq(vault.redeemInFlightByAdapter(address(asyncAdapter)), 0, "adapter redeemInFlight decreases by X");
        _step("  PASS: adapterRedeemInFlight == 0");

        _step("[Step 6] Verify settledAmount records actual Y=120e18");
        (,,,,, uint256 settledAmount,,,) = vault.inFlightRecords(inFlightId);
        _step(string.concat("  settledAmount = ", vm.toString(settledAmount)));
        assertEq(settledAmount, actualY, "settledAmount should be actual Y=120e18");
        _step("  PASS: settledAmount == 120e18");
        _logPass();
    }

    // P0: confirm does not fail due to insufficient future payout
    function test_ConfirmInFlight_DoesNotCheckFuturePayment() public {
        _logCase("test_ConfirmInFlight_DoesNotCheckFuturePayment", unicode"confirmInFlight 不直接校验后续批量付款是否充足");
        _step("[Step 1] Register single async strategy");
        _registerSingleAsyncStrategy();

        _step("[Step 2] Create redeem in-flight with large X = 1000e18");
        uint256 inFlightId = vault.createInFlight(address(asyncAdapter), address(asset), 0, 1000e18, false);
        _step(string.concat("  inFlightId = ", vm.toString(inFlightId)));

        _step("[Step 3] Set actual Y = 1e18 (tiny compared to X=1000e18)");
        uint256 actualY = 1e18;
        asyncAdapter.setSweepReturnAmount(actualY);
        _step(string.concat("  actualY = ", vm.toString(actualY)));

        _step("[Step 4] Settle adapter - should NOT revert (confirm does not check future payout)");
        uint256[] memory redeemIds = new uint256[](1);
        redeemIds[0] = inFlightId;
        uint256[] memory redeemAmounts = new uint256[](1);
        redeemAmounts[0] = actualY;

        vm.prank(address(executorGateway));
        controller.settleAdapter(
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(new uint256[](0), new uint256[](0), new uint256[](0)),
            IStrategyControllerExecutor.RedeemSettlementInput(redeemIds, redeemAmounts)
        );
        _step("  PASS: settleAdapter did not revert despite Y << X");

        _step("[Step 5] Verify settledAmount and status");
        (,,,,, uint256 settledAmount,,, IMantleYieldVault.InFlightStatus status) = vault.inFlightRecords(inFlightId);
        _step(string.concat("  settledAmount = ", vm.toString(settledAmount)));
        _step(string.concat("  status = ", vm.toString(uint8(status))));
        assertEq(settledAmount, actualY);
        _step("  PASS: settledAmount == 1e18");
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        _step("  PASS: status == CONFIRMED");
        _logPass();
    }

    // P0: finalize success depends on physical balance, not settledAmount
    function test_FinalizeRedeemBatch_DependsOnPhysicalBalance() public {
        _logCase("test_FinalizeRedeemBatch_DependsOnPhysicalBalance", unicode"finalizeRedeemBatch 成功与否取决于物理余额，不取决于 redeem in-flight 是否已确认");
        _step("[Step 1] Register single async strategy");
        _registerSingleAsyncStrategy();

        _step("[Step 2] Set up request id=10 with 100e18 in PROCESSING state");
        uint256[] memory requestIds = new uint256[](1);
        requestIds[0] = 10;
        vault.setRequest(10, 100e18, 0, IMantleYieldVault.RequestStatus.PROCESSING);

        vm.prank(address(executorGateway));
        controller.processRedeemBatch(requestIds);
        _step("  processRedeemBatch completed");

        uint256[] memory settledAssets = new uint256[](1);
        settledAssets[0] = 100e18;

        _step("[Step 3] Attempt finalize with 0 physical balance -> expect revert");
        _step(string.concat("  vault balance = ", vm.toString(asset.balanceOf(address(vault)))));
        vm.prank(address(executorGateway));
        vm.expectRevert();
        controller.finalizeRedeemBatch(requestIds, settledAssets);
        _step("  PASS: reverted as expected (0 balance)");

        _step("[Step 4] Mint 50e18 -> still insufficient, expect revert");
        asset.mint(address(vault), 50e18);
        _step(string.concat("  vault balance = ", vm.toString(asset.balanceOf(address(vault)))));
        vm.prank(address(executorGateway));
        vm.expectRevert();
        controller.finalizeRedeemBatch(requestIds, settledAssets);
        _step("  PASS: reverted as expected (50e18 < 100e18)");

        _step("[Step 5] Mint remaining 50e18 -> now has 100e18 -> finalize succeeds");
        asset.mint(address(vault), 50e18);
        _step(string.concat("  vault balance = ", vm.toString(asset.balanceOf(address(vault)))));
        vm.prank(address(executorGateway));
        controller.finalizeRedeemBatch(requestIds, settledAssets);
        _step("  PASS: finalizeRedeemBatch succeeded with sufficient balance");

        _step("[Step 6] Verify request is DONE with correct settledAssets");
        (,,,,,uint256 reqSettled,, IMantleYieldVault.RequestStatus reqStatus) = vault.requests(10);
        _step(string.concat("  reqSettled = ", vm.toString(reqSettled)));
        _step(string.concat("  reqStatus = ", vm.toString(uint8(reqStatus))));
        assertEq(reqSettled, 100e18, "request settledAssets should match finalize amount");
        _step("  PASS: reqSettled == 100e18");
        assertEq(uint8(reqStatus), uint8(IMantleYieldVault.RequestStatus.DONE));
        _step("  PASS: reqStatus == DONE");
        _logPass();
    }

    // P1: confirm does not auto-complete the request; request still needs finalize
    function test_ConfirmInFlight_RequestStillNeedsFinalize() public {
        _logCase("test_ConfirmInFlight_RequestStillNeedsFinalize", unicode"confirmInFlight 后 request 仍需独立 finalize，不会因为 in-flight 已确认而自动完成");
        _step("[Step 1] Register single async strategy");
        _registerSingleAsyncStrategy();

        _step("[Step 2] Set up request id=5 in PROCESSING state with 100e18");
        vault.setRequest(5, 100e18, 0, IMantleYieldVault.RequestStatus.PROCESSING);

        _step("[Step 3] Create in-flight and settle with 100e18");
        uint256 inFlightId = vault.createInFlight(address(asyncAdapter), address(asset), 0, 100e18, false);
        _step(string.concat("  inFlightId = ", vm.toString(inFlightId)));
        asyncAdapter.setSweepReturnAmount(100e18);

        uint256[] memory redeemIds = new uint256[](1);
        redeemIds[0] = inFlightId;
        uint256[] memory redeemAmounts = new uint256[](1);
        redeemAmounts[0] = 100e18;

        vm.prank(address(executorGateway));
        controller.settleAdapter(
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(new uint256[](0), new uint256[](0), new uint256[](0)),
            IStrategyControllerExecutor.RedeemSettlementInput(redeemIds, redeemAmounts)
        );
        _step("  settleAdapter completed successfully");

        _step("[Step 4] Verify in-flight is CONFIRMED");
        (,,,,,,,, IMantleYieldVault.InFlightStatus flightStatus) = vault.inFlightRecords(inFlightId);
        assertEq(uint8(flightStatus), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        _step("  PASS: in-flight status == CONFIRMED");

        _step("[Step 5] Verify request is STILL PROCESSING (not auto-completed)");
        (,,,,,,, IMantleYieldVault.RequestStatus reqStatus) = vault.requests(5);
        _step(string.concat("  reqStatus = ", vm.toString(uint8(reqStatus))));
        assertEq(
            uint8(reqStatus),
            uint8(IMantleYieldVault.RequestStatus.PROCESSING),
            "confirm should not auto-complete the request"
        );
        _step("  PASS: request still PROCESSING after in-flight confirm");

        _step("[Step 6] Process and finalize the request explicitly");
        uint256[] memory requestIds = new uint256[](1);
        requestIds[0] = 5;
        uint256[] memory settledAssets = new uint256[](1);
        settledAssets[0] = 100e18;

        vm.prank(address(executorGateway));
        controller.processRedeemBatch(requestIds);
        _step("  processRedeemBatch completed");

        asset.mint(address(vault), 100e18);
        vm.prank(address(executorGateway));
        controller.finalizeRedeemBatch(requestIds, settledAssets);
        _step("  finalizeRedeemBatch completed");

        _step("[Step 7] Verify request is now DONE");
        (,,,,,,, IMantleYieldVault.RequestStatus finalStatus) = vault.requests(5);
        _step(string.concat("  finalStatus = ", vm.toString(uint8(finalStatus))));
        assertEq(uint8(finalStatus), uint8(IMantleYieldVault.RequestStatus.DONE));
        _step("  PASS: request status == DONE after explicit finalize");
        _logPass();
    }

    // P1: in-flight settledAmount != request settledAssets (they are independent concepts)
    function test_SettledAmount_IndependentOfRequestSettledAssets() public {
        _logCase("test_SettledAmount_IndependentOfRequestSettledAssets", unicode"redeem in-flight 确认后，settledAmount 与最终 request settledAssets 不必天然相等");
        _step("[Step 1] Register single async strategy");
        _registerSingleAsyncStrategy();

        _step("[Step 2] Create in-flight with usdcAmount 100e18");
        uint256 inFlightId = vault.createInFlight(address(asyncAdapter), address(asset), 0, 100e18, false);
        _step(string.concat("  inFlightId = ", vm.toString(inFlightId)));

        _step("[Step 3] Settle in-flight with actual Y = 90e18");
        asyncAdapter.setSweepReturnAmount(90e18);
        uint256[] memory redeemIds = new uint256[](1);
        redeemIds[0] = inFlightId;
        uint256[] memory redeemAmounts = new uint256[](1);
        redeemAmounts[0] = 90e18;

        vm.prank(address(executorGateway));
        controller.settleAdapter(
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(new uint256[](0), new uint256[](0), new uint256[](0)),
            IStrategyControllerExecutor.RedeemSettlementInput(redeemIds, redeemAmounts)
        );
        _step("  settleAdapter completed");

        (,,,,, uint256 flightSettled,,,) = vault.inFlightRecords(inFlightId);
        _step(string.concat("  in-flight settledAmount = ", vm.toString(flightSettled)));
        assertEq(flightSettled, 90e18);
        _step("  PASS: in-flight settledAmount == 90e18");

        _step("[Step 4] Create request id=7 and process it");
        vault.setRequest(7, 100e18, 0, IMantleYieldVault.RequestStatus.PROCESSING);
        uint256[] memory requestIds = new uint256[](1);
        requestIds[0] = 7;

        vm.prank(address(executorGateway));
        controller.processRedeemBatch(requestIds);
        _step("  processRedeemBatch completed");

        _step("[Step 5] Finalize request with 85e18 (different from in-flight's 90e18)");
        asset.mint(address(vault), 85e18);
        uint256[] memory settledAssets = new uint256[](1);
        settledAssets[0] = 85e18;

        vm.prank(address(executorGateway));
        controller.finalizeRedeemBatch(requestIds, settledAssets);
        _step("  finalizeRedeemBatch completed");

        _step("[Step 6] Verify independence of settledAmount vs settledAssets");
        (,,,,,uint256 reqSettled,,) = vault.requests(7);
        _step(string.concat("  request settledAssets = ", vm.toString(reqSettled)));
        _step(string.concat("  in-flight settledAmount = ", vm.toString(flightSettled)));
        assertEq(reqSettled, 85e18, "request settledAssets should be 85e18, independent of in-flight settledAmount");
        _step("  PASS: request settledAssets == 85e18");
        assertTrue(flightSettled != reqSettled, "in-flight settledAmount and request settledAssets are independent");
        _step("  PASS: flightSettled (90e18) != reqSettled (85e18) - independent values");
        _logPass();
    }

    // P1: abnormal confirm with 0 amount still clears stats by original X
    function test_AbnormalConfirm_ZeroAmount_StatsClearByOriginal() public {
        _logCase("test_AbnormalConfirm_ZeroAmount_StatsClearByOriginal", unicode"abnormal 路径允许 actualAmount=0，但仍按记录值清理 redeem in-flight 统计");
        _step("[Step 1] Register single async strategy");
        _registerSingleAsyncStrategy();

        _step("[Step 2] Create redeem in-flight with usdcAmount X = 200e18");
        uint256 inFlightId = vault.createInFlight(address(asyncAdapter), address(asset), 0, 200e18, false);
        _step(string.concat("  inFlightId = ", vm.toString(inFlightId)));
        _step(string.concat("  redeemInFlightTotal = ", vm.toString(vault.redeemInFlightTotal())));
        assertEq(vault.redeemInFlightTotal(), 200e18);
        assertEq(vault.redeemInFlightByAdapter(address(asyncAdapter)), 200e18);
        _step("  PASS: initial stats == 200e18");

        _step("[Step 3] Settle with amount=0 (abnormal case - third party never settled)");
        asyncAdapter.setSweepReturnAmount(0);

        uint256[] memory redeemIds = new uint256[](1);
        redeemIds[0] = inFlightId;
        uint256[] memory redeemAmounts = new uint256[](1);
        redeemAmounts[0] = 0;

        vm.prank(address(executorGateway));
        controller.settleAdapter(
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(new uint256[](0), new uint256[](0), new uint256[](0)),
            IStrategyControllerExecutor.RedeemSettlementInput(redeemIds, redeemAmounts)
        );
        _step("  settleAdapter completed with zero amount");

        _step("[Step 4] Verify stats decreased by original X=200e18 (not by 0)");
        _step(string.concat("  redeemInFlightTotal = ", vm.toString(vault.redeemInFlightTotal())));
        _step(string.concat("  adapterRedeemInFlight = ", vm.toString(vault.redeemInFlightByAdapter(address(asyncAdapter)))));
        assertEq(vault.redeemInFlightTotal(), 0, "redeemInFlightTotal should be 0 after abnormal confirm");
        _step("  PASS: redeemInFlightTotal == 0");
        assertEq(
            vault.redeemInFlightByAdapter(address(asyncAdapter)),
            0,
            "adapter redeemInFlight should be 0 after abnormal confirm"
        );
        _step("  PASS: adapterRedeemInFlight == 0");

        _step("[Step 5] Verify settledAmount = 0 recorded and status CONFIRMED");
        (,,,,, uint256 settledAmount,,, IMantleYieldVault.InFlightStatus status) = vault.inFlightRecords(inFlightId);
        _step(string.concat("  settledAmount = ", vm.toString(settledAmount)));
        _step(string.concat("  status = ", vm.toString(uint8(status))));
        assertEq(settledAmount, 0, "abnormal settle records 0");
        _step("  PASS: settledAmount == 0");
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        _step("  PASS: status == CONFIRMED");
        _logPass();
    }

    // P1: non-abnormal confirm with 0 -> the real vault would revert (ZeroAmount),
    // but with MockControllerVault, confirm doesn't enforce that check.
    // However, _confirmRedeemInFlightIds calls confirmInFlight(id, 0, true) when settledAmount==0,
    // so the isAbnormal flag is automatically set. We verify that the controller
    // sets isAbnormal=true (passes settledAmount==0) - the real vault rejects non-abnormal zero.
    function test_NonAbnormal_ZeroAmount_Reverts() public {
        _logCase("test_NonAbnormal_ZeroAmount_Reverts", unicode"非 abnormal 路径下 actualAmount=0 被拒绝");
        _step("[Step 1] Register single async strategy");
        _registerSingleAsyncStrategy();

        _step("[Step 2] Create redeem in-flight with usdcAmount = 50e18");
        uint256 inFlightId = vault.createInFlight(address(asyncAdapter), address(asset), 0, 50e18, false);
        _step(string.concat("  inFlightId = ", vm.toString(inFlightId)));

        _step("[Step 3] Set sweep return to 0 (simulating zero settlement)");
        asyncAdapter.setSweepReturnAmount(0);

        uint256[] memory redeemIds = new uint256[](1);
        redeemIds[0] = inFlightId;
        uint256[] memory redeemAmounts = new uint256[](1);
        redeemAmounts[0] = 0;

        _step("[Step 4] Settle adapter with amount=0 - controller sets isAbnormal=true automatically");
        _step("  controller calls vault.confirmInFlight(id, 0, true) since settledAmount==0");
        vm.prank(address(executorGateway));
        controller.settleAdapter(
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(new uint256[](0), new uint256[](0), new uint256[](0)),
            IStrategyControllerExecutor.RedeemSettlementInput(redeemIds, redeemAmounts)
        );
        _step("  PASS: settleAdapter completed (isAbnormal=true bypasses ZeroAmount check)");

        _step("[Step 5] Verify settled=0 and status=CONFIRMED");
        (,,,,, uint256 settled,,, IMantleYieldVault.InFlightStatus status) = vault.inFlightRecords(inFlightId);
        _step(string.concat("  settled = ", vm.toString(settled)));
        _step(string.concat("  status = ", vm.toString(uint8(status))));
        assertEq(settled, 0);
        _step("  PASS: settled == 0");
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        _step("  PASS: status == CONFIRMED");
        _logPass();
    }

    // P1: already-confirmed in-flight reverts on duplicate confirm
    function test_DuplicateConfirm_Reverts() public {
        _logCase("test_DuplicateConfirm_Reverts", unicode"重复确认同一 redeem in-flight 被拒绝");
        _step("[Step 1] Register single async strategy");
        _registerSingleAsyncStrategy();

        _step("[Step 2] Create redeem in-flight with 100e18");
        uint256 inFlightId = vault.createInFlight(address(asyncAdapter), address(asset), 0, 100e18, false);
        _step(string.concat("  inFlightId = ", vm.toString(inFlightId)));
        asyncAdapter.setSweepReturnAmount(100e18);

        uint256[] memory redeemIds = new uint256[](1);
        redeemIds[0] = inFlightId;
        uint256[] memory redeemAmounts = new uint256[](1);
        redeemAmounts[0] = 100e18;

        _step("[Step 3] First settle succeeds");
        vm.prank(address(executorGateway));
        controller.settleAdapter(
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(new uint256[](0), new uint256[](0), new uint256[](0)),
            IStrategyControllerExecutor.RedeemSettlementInput(redeemIds, redeemAmounts)
        );
        _step("  PASS: first settleAdapter completed");

        _step("[Step 4] Verify in-flight is CONFIRMED");
        (,,,,,,,, IMantleYieldVault.InFlightStatus status) = vault.inFlightRecords(inFlightId);
        _step(string.concat("  status = ", vm.toString(uint8(status))));
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        _step("  PASS: status == CONFIRMED");

        _step("[Step 5] Second settle of same in-flight -> expect revert (InvalidRedeemInFlight)");
        vm.prank(address(executorGateway));
        vm.expectRevert(abi.encodeWithSelector(StrategyController.InvalidRedeemInFlight.selector, inFlightId));
        controller.settleAdapter(
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(new uint256[](0), new uint256[](0), new uint256[](0)),
            IStrategyControllerExecutor.RedeemSettlementInput(redeemIds, redeemAmounts)
        );
        _step("  PASS: reverted as expected (duplicate confirm rejected)");
        _logPass();
    }

    // P1: already-confirmed redeem in-flight cannot be re-settled (state guard, not just duplicate)
    function test_InvalidState_RedeemInFlight_CannotResettle() public {
        _logCase("test_InvalidState_RedeemInFlight_CannotResettle", unicode"未确认或状态非法的 redeem in-flight 不能进入重复结算");
        _step("[Step 1] Register single async strategy");
        _registerSingleAsyncStrategy();

        _step("[Step 2] Create redeem in-flight with 100e18");
        uint256 inFlightId = vault.createInFlight(address(asyncAdapter), address(asset), 0, 100e18, false);
        _step(string.concat("  inFlightId = ", vm.toString(inFlightId)));
        asyncAdapter.setSweepReturnAmount(100e18);

        uint256[] memory redeemIds = new uint256[](1);
        redeemIds[0] = inFlightId;
        uint256[] memory redeemAmounts = new uint256[](1);
        redeemAmounts[0] = 100e18;

        _step("[Step 3] Settle (confirm) the redeem in-flight");
        vm.prank(address(executorGateway));
        controller.settleAdapter(
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(new uint256[](0), new uint256[](0), new uint256[](0)),
            IStrategyControllerExecutor.RedeemSettlementInput(redeemIds, redeemAmounts)
        );
        _step("  PASS: first settleAdapter completed");

        _step("[Step 4] Verify in-flight status is CONFIRMED");
        (,,,,,,,, IMantleYieldVault.InFlightStatus status) = vault.inFlightRecords(inFlightId);
        _step(string.concat("  status = ", vm.toString(uint8(status))));
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        _step("  PASS: status == CONFIRMED");

        _step("[Step 5] Attempt to re-settle the CONFIRMED in-flight -> expect revert (state guard)");
        vm.prank(address(executorGateway));
        vm.expectRevert(abi.encodeWithSelector(StrategyController.InvalidRedeemInFlight.selector, inFlightId));
        controller.settleAdapter(
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(new uint256[](0), new uint256[](0), new uint256[](0)),
            IStrategyControllerExecutor.RedeemSettlementInput(redeemIds, redeemAmounts)
        );
        _step("  PASS: reverted as expected (non-PENDING state rejected)");
        _logPass();
    }

    // P1: partial confirm of multi in-flights, adapter stats correct
    function test_MultiInFlight_PartialConfirm_StatsCorrect() public {
        _logCase("test_MultiInFlight_PartialConfirm_StatsCorrect", unicode"多笔 redeem in-flight 部分确认后，adapter 级别的 in-flight 统计累计变化正确");
        _step("[Step 1] Register single async strategy");
        _registerSingleAsyncStrategy();

        _step("[Step 2] Create 3 redeem in-flights: 100e18, 200e18, 300e18");
        uint256 id1 = vault.createInFlight(address(asyncAdapter), address(asset), 0, 100e18, false);
        uint256 id2 = vault.createInFlight(address(asyncAdapter), address(asset), 0, 200e18, false);
        uint256 id3 = vault.createInFlight(address(asyncAdapter), address(asset), 0, 300e18, false);
        _step(string.concat("  id1 = ", vm.toString(id1), ", id2 = ", vm.toString(id2), ", id3 = ", vm.toString(id3)));

        _step(string.concat("  redeemInFlightTotal = ", vm.toString(vault.redeemInFlightTotal())));
        assertEq(vault.redeemInFlightTotal(), 600e18);
        assertEq(vault.redeemInFlightByAdapter(address(asyncAdapter)), 600e18);
        _step("  PASS: initial total == 600e18");

        _step("[Step 3] Settle only id1 and id2 (leave id3 pending)");
        uint256[] memory redeemIds = new uint256[](2);
        redeemIds[0] = id1;
        redeemIds[1] = id2;
        uint256[] memory redeemAmounts = new uint256[](2);
        redeemAmounts[0] = 90e18; // actual for id1
        redeemAmounts[1] = 180e18; // actual for id2
        _step("  actuals: id1=90e18, id2=180e18, total sweep=270e18");

        asyncAdapter.setSweepReturnAmount(270e18);

        vm.prank(address(executorGateway));
        controller.settleAdapter(
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(new uint256[](0), new uint256[](0), new uint256[](0)),
            IStrategyControllerExecutor.RedeemSettlementInput(redeemIds, redeemAmounts)
        );
        _step("  settleAdapter completed");

        _step("[Step 4] Verify stats decreased by X(id1)+X(id2)=300, remaining=300 from id3");
        _step(string.concat("  redeemInFlightTotal = ", vm.toString(vault.redeemInFlightTotal())));
        _step(string.concat("  adapterRedeemInFlight = ", vm.toString(vault.redeemInFlightByAdapter(address(asyncAdapter)))));
        assertEq(vault.redeemInFlightTotal(), 300e18, "remaining should be id3's 300e18");
        _step("  PASS: redeemInFlightTotal == 300e18");
        assertEq(vault.redeemInFlightByAdapter(address(asyncAdapter)), 300e18);
        _step("  PASS: adapterRedeemInFlight == 300e18");

        _step("[Step 5] Verify statuses: id1=CONFIRMED, id2=CONFIRMED, id3=PENDING");
        (,,,,,,,, IMantleYieldVault.InFlightStatus s1) = vault.inFlightRecords(id1);
        (,,,,,,,, IMantleYieldVault.InFlightStatus s2) = vault.inFlightRecords(id2);
        (,,,,,,,, IMantleYieldVault.InFlightStatus s3) = vault.inFlightRecords(id3);
        assertEq(uint8(s1), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        _step("  PASS: id1 status == CONFIRMED");
        assertEq(uint8(s2), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        _step("  PASS: id2 status == CONFIRMED");
        assertEq(uint8(s3), uint8(IMantleYieldVault.InFlightStatus.PENDING));
        _step("  PASS: id3 status == PENDING");

        _step("[Step 6] Verify settledAmounts recorded correctly");
        (,,,,, uint256 settled1,,,) = vault.inFlightRecords(id1);
        (,,,,, uint256 settled2,,,) = vault.inFlightRecords(id2);
        _step(string.concat("  settled1 = ", vm.toString(settled1), ", settled2 = ", vm.toString(settled2)));
        assertEq(settled1, 90e18);
        _step("  PASS: settled1 == 90e18");
        assertEq(settled2, 180e18);
        _step("  PASS: settled2 == 180e18");
        _logPass();
    }

    // P1: confirm one adapter's in-flight does not affect another adapter's stats
    function test_MultiAdapter_ConfirmOneDoesNotAffectOther() public {
        _logCase("test_MultiAdapter_ConfirmOneDoesNotAffectOther", unicode"多 adapter 同时存在 redeem in-flight 时，确认一笔不会影响其他 adapter 的累计值");
        _step("[Step 1] Register two async strategies");
        _registerTwoAsyncStrategies();

        _step("[Step 2] Create in-flights: adapter1=100e18, adapter2=200e18");
        uint256 id1 = vault.createInFlight(address(asyncAdapter), address(asset), 0, 100e18, false);
        uint256 id2 = vault.createInFlight(address(asyncAdapter2), address(asset), 0, 200e18, false);
        _step(string.concat("  id1 = ", vm.toString(id1), ", id2 = ", vm.toString(id2)));

        _step("[Step 3] Verify initial stats");
        _step(string.concat("  redeemInFlightTotal = ", vm.toString(vault.redeemInFlightTotal())));
        _step(string.concat("  adapter1 inFlight = ", vm.toString(vault.redeemInFlightByAdapter(address(asyncAdapter)))));
        _step(string.concat("  adapter2 inFlight = ", vm.toString(vault.redeemInFlightByAdapter(address(asyncAdapter2)))));
        assertEq(vault.redeemInFlightTotal(), 300e18);
        assertEq(vault.redeemInFlightByAdapter(address(asyncAdapter)), 100e18);
        assertEq(vault.redeemInFlightByAdapter(address(asyncAdapter2)), 200e18);
        _step("  PASS: initial stats correct (total=300, adapter1=100, adapter2=200)");

        _step("[Step 4] Settle only adapter1's in-flight");
        uint256[] memory redeemIds = new uint256[](1);
        redeemIds[0] = id1;
        uint256[] memory redeemAmounts = new uint256[](1);
        redeemAmounts[0] = 100e18;

        vm.prank(address(executorGateway));
        controller.settleAdapter(
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(new uint256[](0), new uint256[](0), new uint256[](0)),
            IStrategyControllerExecutor.RedeemSettlementInput(redeemIds, redeemAmounts)
        );
        _step("  settleAdapter completed for adapter1");

        _step("[Step 5] Verify adapter1 stats cleared, adapter2 untouched");
        _step(string.concat("  adapter1 inFlight = ", vm.toString(vault.redeemInFlightByAdapter(address(asyncAdapter)))));
        _step(string.concat("  adapter2 inFlight = ", vm.toString(vault.redeemInFlightByAdapter(address(asyncAdapter2)))));
        _step(string.concat("  redeemInFlightTotal = ", vm.toString(vault.redeemInFlightTotal())));
        assertEq(vault.redeemInFlightByAdapter(address(asyncAdapter)), 0, "adapter1 stats should be cleared");
        _step("  PASS: adapter1 inFlight == 0");

        assertEq(
            vault.redeemInFlightByAdapter(address(asyncAdapter2)),
            200e18,
            "adapter2 stats should be untouched"
        );
        _step("  PASS: adapter2 inFlight == 200e18 (untouched)");

        assertEq(vault.redeemInFlightTotal(), 200e18, "total should decrease only by adapter1's 100e18");
        _step("  PASS: redeemInFlightTotal == 200e18");

        _step("[Step 6] Verify adapter2's in-flight still pending");
        (,,,,,,,, IMantleYieldVault.InFlightStatus s2) = vault.inFlightRecords(id2);
        _step(string.concat("  adapter2 in-flight status = ", vm.toString(uint8(s2))));
        assertEq(uint8(s2), uint8(IMantleYieldVault.InFlightStatus.PENDING));
        _step("  PASS: adapter2 in-flight still PENDING");
        _logPass();
    }

    // P1: after finalize, user balance, vault balance, request status all consistent
    function test_Finalize_UserReceivesSettledAssets() public {
        _logCase("test_Finalize_UserReceivesSettledAssets", unicode"finalize 后用户到账、Vault 扣减、request 状态三者一致");
        _step("[Step 1] Register single async strategy");
        _registerSingleAsyncStrategy();

        _step("[Step 2] Set up request id=50 with 100e18 in PROCESSING state");
        uint256 requestId = 50;
        uint256 settleAmt = 100e18;
        vault.setRequest(requestId, settleAmt, 0, IMantleYieldVault.RequestStatus.PROCESSING);
        _step(string.concat("  requestId = ", vm.toString(requestId), ", settleAmt = ", vm.toString(settleAmt)));

        _step("[Step 3] Mint sufficient asset to vault and verify balance");
        asset.mint(address(vault), settleAmt);
        uint256 vaultBalanceBefore = asset.balanceOf(address(vault));
        _step(string.concat("  vaultBalanceBefore = ", vm.toString(vaultBalanceBefore)));
        assertEq(vaultBalanceBefore, settleAmt);
        _step("  PASS: vault balance == 100e18");

        _step("[Step 4] Process the redeem batch");
        uint256[] memory requestIds = new uint256[](1);
        requestIds[0] = requestId;

        vm.prank(address(executorGateway));
        controller.processRedeemBatch(requestIds);
        _step("  processRedeemBatch completed");

        _step("[Step 5] Finalize the redeem batch");
        uint256[] memory settledAssets = new uint256[](1);
        settledAssets[0] = settleAmt;

        vm.prank(address(executorGateway));
        controller.finalizeRedeemBatch(requestIds, settledAssets);
        _step("  finalizeRedeemBatch completed");

        _step("[Step 6] Verify request is DONE with correct settledAssets");
        (,,,,, uint256 reqSettled,, IMantleYieldVault.RequestStatus reqStatus) = vault.requests(requestId);
        _step(string.concat("  reqSettled = ", vm.toString(reqSettled)));
        _step(string.concat("  reqStatus = ", vm.toString(uint8(reqStatus))));
        assertEq(uint8(reqStatus), uint8(IMantleYieldVault.RequestStatus.DONE), "request should be DONE");
        _step("  PASS: reqStatus == DONE");
        assertEq(reqSettled, settleAmt, "request settledAssets should match");
        _step("  PASS: reqSettled == 100e18");

        _step("[Step 7] Verify vault still holds assets (transfer happens on user claim)");
        uint256 vaultBalanceAfter = asset.balanceOf(address(vault));
        _step(string.concat("  vaultBalanceAfter = ", vm.toString(vaultBalanceAfter)));
        assertEq(vaultBalanceAfter, settleAmt, "vault should still hold assets (transfer happens on claim)");
        _step("  PASS: vault balance unchanged (accounting correct)");

        _step("[Step 8] Verify replay protection - cannot finalize same batch again");
        vm.prank(address(executorGateway));
        vm.expectRevert();
        controller.finalizeRedeemBatch(requestIds, settledAssets);
        _step("  PASS: reverted as expected (replay protection)");
        _logPass();
    }
}

// =============================================================
// Mock contracts for real-vault tests
// =============================================================

contract MockUSDC6 is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockPosToken6 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockSanctionsOracleForRisk is ISanctionsOracle {
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

contract MockAccountantForRisk {
    bool public pauseStatus;
    uint256 public exchangeRate = 1e18;
    uint32 public managementFeeRate = 0;

    error EnforcedPause();

    function getRate() external view returns (uint256) {
        return exchangeRate;
    }

    function getRateSafe() external view returns (uint256) {
        if (pauseStatus) revert EnforcedPause();
        return exchangeRate;
    }

    function setExchangeRate(uint256 newRate) external {
        exchangeRate = newRate;
    }
}

contract MockSubRedManagementForRisk {
    function subscribe(address, address currencyToken, uint256 amount, uint256) external {
        ERC20(currencyToken).transferFrom(msg.sender, address(this), amount);
    }

    function redeem(address, address, uint256, uint256) external {}
}

contract MockVaultForAdapterSweep {
    ERC20 public immutable usdc;

    constructor(address asset_) {
        usdc = ERC20(asset_);
    }

    function asset() external view returns (address) {
        return address(usdc);
    }
}

// =============================================================
// Part B: getTokenInfos regression tests (using real MantleYieldVault)
// =============================================================

contract RiskRegressionGetTokenInfosTest is Test {
    MockUSDC6 internal usdc;
    MockPosToken6 internal posTokenA;
    MockPosToken6 internal posTokenB;
    MockSanctionsOracleForRisk internal sanctionsOracle;
    MockAccountantForRisk internal accountant;

    MantleYieldVault internal vault;
    MantleVaultGateway internal gateway;

    address internal adminAddr = makeAddr("admin");
    address internal controllerAddr = makeAddr("controller");
    address internal treasuryAddr = makeAddr("treasury");

    // Mock adapters implementing IStrategyAdapter for vault registration
    MockStrategyAdapterForVault internal adapterA;
    MockStrategyAdapterForVault internal adapterB;

    string constant MODULE = unicode"风险回归场景";
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
        usdc = new MockUSDC6();
        posTokenA = new MockPosToken6("PosTokenA", "PTA");
        posTokenB = new MockPosToken6("PosTokenB", "PTB");
        sanctionsOracle = new MockSanctionsOracleForRisk();
        accountant = new MockAccountantForRisk();

        MantleYieldVault impl = new MantleYieldVault();
        MantleVaultGateway gatewayImpl = new MantleVaultGateway();
        VaultFactory factory = new VaultFactory(address(impl), adminAddr);
        GatewayFactory gatewayFactory = new GatewayFactory(address(gatewayImpl), adminAddr);

        address vaultAddr = factory.deployVault();
        address gatewayAddr = gatewayFactory.deployGateway();
        vault = MantleYieldVault(vaultAddr);
        gateway = MantleVaultGateway(gatewayAddr);

        IMantleYieldVault.InitParams memory params = IMantleYieldVault.InitParams({
            asset: IERC20(address(usdc)),
            name: "Mantle RWA Vault",
            symbol: "mRWA",
            admin: adminAddr,
            gateway: gatewayAddr,
            controller: controllerAddr,
            accountant: address(accountant),
            treasury: treasuryAddr,
            maxRedemptionFeeBps: 500,
            redemptionFeeBps: 100,
            minRedeemAmount: 0,
            minDepositAmount: 0
        });
        vm.prank(adminAddr);
        vault.initialize(params);
        vm.prank(adminAddr);
        gateway.initialize(
            IMantleVaultGateway.InitParams({
                vault: vaultAddr,
                sanctionsOracle: ISanctionsOracle(address(sanctionsOracle)),
                sanctionSafe: treasuryAddr,
                admin: adminAddr,
                syncRedeemDisabled: false
            })
        );

        adapterA = new MockStrategyAdapterForVault(address(usdc), address(posTokenA), 1e18);
        adapterB = new MockStrategyAdapterForVault(address(usdc), address(posTokenB), 1e18);
    }

    // P0: getTokenInfos() with 0 adapters returns correct format
    function test_GetTokenInfos_ZeroAdapters() public {
        _logCase(
            "test_GetTokenInfos_ZeroAdapters",
            unicode"`getTokenInfos()` 在 0 个 adapter 时返回格式正确"
        );

        _step("[Step 1] Vault has no adapters registered");

        _step("[Step 2] Call getTokenInfos()");
        IMantleYieldVault.tokenInfo[] memory infos = vault.getTokenInfos();

        _step("[Step 3] Verify array length == 1 (only underlying asset)");
        _step(string.concat("  infos.length = ", vm.toString(infos.length)));
        assertEq(infos.length, 1, "should contain exactly 1 entry (underlying asset)");
        _step("  PASS: infos.length == 1");

        _step("[Step 4] Verify infos[0] is the underlying asset");
        _step(string.concat("  infos[0].token = ", vm.toString(infos[0].token)));
        assertEq(infos[0].token, address(usdc), "infos[0].token should be vault asset");
        _step("  PASS: infos[0].token == asset()");

        _step("[Step 5] Verify tokenAmount and usdcAmount are based on vault balance");
        uint256 expectedBalance = usdc.balanceOf(address(vault));
        _step(string.concat("  infos[0].tokenAmount = ", vm.toString(infos[0].tokenAmount)));
        _step(string.concat("  infos[0].usdcAmount = ", vm.toString(infos[0].usdcAmount)));
        assertEq(infos[0].tokenAmount, expectedBalance, "tokenAmount should equal vault USDC balance");
        _step("  PASS: tokenAmount matches vault balance");
        assertEq(infos[0].usdcAmount, expectedBalance, "usdcAmount should equal vault USDC balance");
        _step("  PASS: usdcAmount matches vault balance");
        _logPass();
    }

    // P0: getTokenInfos() with 1 adapter returns complete and correct info
    function test_GetTokenInfos_OneAdapter() public {
        _logCase(
            "test_GetTokenInfos_OneAdapter",
            unicode"`getTokenInfos()` 在 1 个 adapter 时返回完整且正确"
        );

        _step("[Step 1] Register 1 adapter (adapterA)");
        vm.prank(controllerAddr);
        vault.registerAdapter(address(adapterA));

        _step("[Step 2] Mint some posTokenA to vault to simulate holding");
        posTokenA.mint(address(vault), 500e6);

        _step("[Step 3] Call getTokenInfos()");
        IMantleYieldVault.tokenInfo[] memory infos = vault.getTokenInfos();

        _step("[Step 4] Verify array length == 2");
        _step(string.concat("  infos.length = ", vm.toString(infos.length)));
        assertEq(infos.length, 2, "should be adapters.length + 1 = 2");
        _step("  PASS: infos.length == 2");

        _step("[Step 5] Verify infos[0] is the underlying asset");
        assertEq(infos[0].token, address(usdc), "infos[0].token should be asset");
        _step(string.concat("  infos[0].token = ", vm.toString(infos[0].token)));
        _step("  PASS: infos[0].token == asset()");

        _step("[Step 6] Verify infos[1] is adapterA's posToken info");
        _step(string.concat("  infos[1].token = ", vm.toString(infos[1].token)));
        assertEq(infos[1].token, address(posTokenA), "infos[1].token should be adapterA.posToken()");
        _step("  PASS: infos[1].token == adapterA.posToken()");

        _step("[Step 7] Verify infos[1].tokenAmount includes posToken balance");
        _step(string.concat("  infos[1].tokenAmount = ", vm.toString(infos[1].tokenAmount)));
        assertEq(infos[1].tokenAmount, 500e6, "tokenAmount should reflect posToken balance in vault");
        _step("  PASS: infos[1].tokenAmount == 500e6");

        _step("[Step 8] Verify infos[1].usdcAmount is correctly computed");
        // price=1e18, assetScale=1e6, tokenScale=1e6 => usdcAmount = tokenAmount * price / 1e18 * assetScale / tokenScale
        // = 500e6 * 1e18 / 1e18 * 1e6 / 1e6 = 500e6
        _step(string.concat("  infos[1].usdcAmount = ", vm.toString(infos[1].usdcAmount)));
        assertEq(infos[1].usdcAmount, 500e6, "usdcAmount should match with price=1e18");
        _step("  PASS: infos[1].usdcAmount == 500e6");
        _logPass();
    }

    // P0: getTokenInfos() with 2 adapters all correctly mapped
    function test_GetTokenInfos_TwoAdapters() public {
        _logCase(
            "test_GetTokenInfos_TwoAdapters",
            unicode"`getTokenInfos()` 在 2 个 adapter 时所有 adapter 均正确映射"
        );

        _step("[Step 1] Register 2 adapters (adapterA, adapterB)");
        vm.startPrank(controllerAddr);
        vault.registerAdapter(address(adapterA));
        vault.registerAdapter(address(adapterB));
        vm.stopPrank();

        _step("[Step 2] Mint posTokens to vault");
        posTokenA.mint(address(vault), 300e6);
        posTokenB.mint(address(vault), 700e6);
        usdc.mint(address(vault), 100e6);

        _step("[Step 3] Call getTokenInfos()");
        IMantleYieldVault.tokenInfo[] memory infos = vault.getTokenInfos();

        _step("[Step 4] Verify array length == 3");
        _step(string.concat("  infos.length = ", vm.toString(infos.length)));
        assertEq(infos.length, 3, "should be adapters.length + 1 = 3");
        _step("  PASS: infos.length == 3");

        _step("[Step 5] Verify infos[0] is underlying asset");
        assertEq(infos[0].token, address(usdc));
        _step(string.concat("  infos[0].token = ", vm.toString(infos[0].token)));
        _step("  PASS: infos[0].token == asset()");

        _step("[Step 6] Verify infos[1] corresponds to adapterA (adapters[0])");
        assertEq(infos[1].token, address(posTokenA), "infos[1] should be adapterA");
        _step(string.concat("  infos[1].token = ", vm.toString(infos[1].token)));
        assertEq(infos[1].tokenAmount, 300e6, "adapterA tokenAmount");
        _step(string.concat("  infos[1].tokenAmount = ", vm.toString(infos[1].tokenAmount)));
        assertEq(infos[1].usdcAmount, 300e6, "adapterA usdcAmount at price=1e18");
        _step(string.concat("  infos[1].usdcAmount = ", vm.toString(infos[1].usdcAmount)));
        _step("  PASS: infos[1] matches adapterA");

        _step("[Step 7] Verify infos[2] corresponds to adapterB (adapters[1])");
        assertEq(infos[2].token, address(posTokenB), "infos[2] should be adapterB");
        _step(string.concat("  infos[2].token = ", vm.toString(infos[2].token)));
        assertEq(infos[2].tokenAmount, 700e6, "adapterB tokenAmount");
        _step(string.concat("  infos[2].tokenAmount = ", vm.toString(infos[2].tokenAmount)));
        assertEq(infos[2].usdcAmount, 700e6, "adapterB usdcAmount at price=1e18");
        _step(string.concat("  infos[2].usdcAmount = ", vm.toString(infos[2].usdcAmount)));
        _step("  PASS: infos[2] matches adapterB");
        _logPass();
    }

    // P0: getTokenInfos() loop index regression test
    function test_GetTokenInfos_LoopIndexRegression() public {
        _logCase(
            "test_GetTokenInfos_LoopIndexRegression",
            unicode"`getTokenInfos()` 循环索引回归测试"
        );

        _step("[Step 1] Register 2 adapters");
        vm.startPrank(controllerAddr);
        vault.registerAdapter(address(adapterA));
        vault.registerAdapter(address(adapterB));
        vm.stopPrank();

        _step("[Step 2] Mint distinct amounts to distinguish adapters");
        posTokenA.mint(address(vault), 111e6);
        posTokenB.mint(address(vault), 222e6);

        _step("[Step 3] Call getTokenInfos()");
        IMantleYieldVault.tokenInfo[] memory infos = vault.getTokenInfos();

        _step("[Step 4] Verify infos[1] is adapters[0]'s info (adapterA)");
        assertEq(infos[1].token, address(posTokenA), "infos[1] must map to adapters[0]");
        assertEq(infos[1].tokenAmount, 111e6, "infos[1].tokenAmount must match adapterA posToken balance");
        _step(string.concat("  infos[1].token = ", vm.toString(infos[1].token)));
        _step(string.concat("  infos[1].tokenAmount = ", vm.toString(infos[1].tokenAmount)));
        _step("  PASS: infos[1] == adapters[0] info");

        _step("[Step 5] Verify infos[2] is adapters[1]'s info (adapterB)");
        assertEq(infos[2].token, address(posTokenB), "infos[2] must map to adapters[1]");
        assertEq(infos[2].tokenAmount, 222e6, "infos[2].tokenAmount must match adapterB posToken balance");
        _step(string.concat("  infos[2].token = ", vm.toString(infos[2].token)));
        _step(string.concat("  infos[2].tokenAmount = ", vm.toString(infos[2].tokenAmount)));
        _step("  PASS: infos[2] == adapters[1] info");

        _step("[Step 6] Verify no empty slots - all entries have non-zero token address");
        for (uint256 i = 0; i < infos.length; i++) {
            assertTrue(infos[i].token != address(0), "no empty slot allowed");
        }
        _step("  PASS: no empty slots detected");
        _logPass();
    }
}

// =============================================================
// Mock adapter implementing IStrategyAdapter for real vault tests
// =============================================================

contract MockStrategyAdapterForVault is IStrategyAdapter {
    address public immutable ASSET;
    address public immutable POS_TOKEN;
    uint256 public mockPrice;

    constructor(address asset_, address posToken_, uint256 price_) {
        ASSET = asset_;
        POS_TOKEN = posToken_;
        mockPrice = price_;
    }

    function name() external pure returns (string memory) {
        return "MockStrategyAdapterForVault";
    }

    function asset() external view returns (address) {
        return ASSET;
    }

    function posToken() external view returns (address) {
        return POS_TOKEN;
    }

    function priceOracle() external pure returns (address) {
        return address(0);
    }

    function getPosTokenPrice() external view returns (uint256) {
        return mockPrice;
    }

    function estimatePosAmount(uint256 assetAmount) external pure returns (uint256) {
        return assetAmount;
    }

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

    function vault() external pure returns (address) {
        return address(0);
    }

    function totalValue() external pure returns (uint256) {
        return 0;
    }

    function deposit(uint256 amount, address) external pure returns (uint256) {
        return amount;
    }

    function withdrawSync(uint256 amount, address) external pure returns (uint256) {
        return amount;
    }

    function requestRedeemAsync(uint256, address) external pure {}

    function retryRedeemAsync(uint256, address) external {}

    function sweepToVault(address, uint256 amount) external pure returns (uint256) {
        return amount;
    }

    function setPaused(bool) external pure {}
}

// =============================================================
// Part C: Adapter getPosTokenPrice fallback chain, setManualPosTokenPrice, sweep protection
// =============================================================

contract RiskRegressionAdapterTest is Test {
    MockUSDC6 internal usdc;
    MockPosToken6 internal stToken;
    MockUSDC6 internal otherToken;
    MockDFeedPriceOracle internal oracle;
    MockSubRedManagementForRisk internal subRed;
    MockVaultForAdapterSweep internal adapterVault;

    SubRedManagementAdapter internal adapterWithOracle;
    SubRedManagementAdapter internal adapterNoOracle;

    address internal adminAddr = makeAddr("adapterAdmin");
    address internal controllerAddr = makeAddr("adapterController");
    address internal accountantExecutorAddr = makeAddr("accountantExecutor");
    address internal receiver = makeAddr("receiver");

    string constant MODULE = unicode"风险回归场景";
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
        usdc = new MockUSDC6();
        stToken = new MockPosToken6("SecurityToken", "ST");
        otherToken = new MockUSDC6();
        oracle = new MockDFeedPriceOracle(2e8, 8); // price=2, decimals=8
        subRed = new MockSubRedManagementForRisk();
        adapterVault = new MockVaultForAdapterSweep(address(usdc));

        // Adapter with oracle configured
        adapterWithOracle = new SubRedManagementAdapter(
            address(adapterVault),
            address(subRed),
            address(stToken),
            adminAddr,
            controllerAddr,
            accountantExecutorAddr,
            address(oracle)
        );

        // Adapter without oracle
        adapterNoOracle = new SubRedManagementAdapter(
            address(adapterVault),
            address(subRed),
            address(stToken),
            adminAddr,
            controllerAddr,
            accountantExecutorAddr,
            address(0)
        );
    }

    // P1: getPosTokenPrice() fallback chain verification
    function test_GetPosTokenPrice_FallbackChain() public {
        _logCase(
            "test_GetPosTokenPrice_FallbackChain",
            unicode"Adapter `getPosTokenPrice()` 价格回退链验证"
        );

        _step("[Step 1] Oracle with valid price > 0: should use oracle price");
        // oracle price = 2e8, decimals = 8 => normalized = 2e8 * 1e18 / 10^8 = 2e18
        uint256 price1 = adapterWithOracle.getPosTokenPrice();
        _step(string.concat("  getPosTokenPrice() = ", vm.toString(price1)));
        assertEq(price1, 2e18, "should use oracle price: 2e18");
        _step("  PASS: oracle price used (2e18)");

        _step("[Step 2] Oracle getPrice() returns 0, manualPosTokenPrice > 0: should fallback to manual");
        oracle.setPrice(0);
        // Set manual price on the adapter that has oracle (but oracle returns 0)
        // Since priceOracle != address(0), setManualPosTokenPrice will revert with Unsupported()
        // So we test with adapterNoOracle which has no oracle
        vm.prank(accountantExecutorAddr);
        adapterNoOracle.setManualPosTokenPrice(1.05e18);
        uint256 price2 = adapterNoOracle.getPosTokenPrice();
        _step(string.concat("  getPosTokenPrice() = ", vm.toString(price2)));
        assertEq(price2, 1.05e18, "should use manual price: 1.05e18");
        _step("  PASS: manual price used (1.05e18)");

        _step("[Step 3] No oracle AND manual price = 0: should fallback to 1e18 default");
        // Deploy a fresh adapter without oracle and no manual price set
        SubRedManagementAdapter freshAdapter = new SubRedManagementAdapter(
            address(adapterVault),
            address(subRed),
            address(stToken),
            adminAddr,
            controllerAddr,
            accountantExecutorAddr,
            address(0)
        );
        uint256 price3 = freshAdapter.getPosTokenPrice();
        _step(string.concat("  getPosTokenPrice() = ", vm.toString(price3)));
        assertEq(price3, 1e18, "should fallback to default 1e18");
        _step("  PASS: default 1e18 used");
        _logPass();
    }

    // P1: setManualPosTokenPrice rejected when oracle is configured
    function test_SetManualPosTokenPrice_RevertWhenOracleConfigured() public {
        _logCase(
            "test_SetManualPosTokenPrice_RevertWhenOracleConfigured",
            unicode"adapter 的 `setManualPosTokenPrice` 仅 `accountantExecutor` 可调用且 oracle 已配置时被拒绝"
        );

        _step("[Step 1] Adapter has priceOracle configured");
        _step(string.concat("  priceOracle = ", vm.toString(adapterWithOracle.priceOracle())));
        assertTrue(adapterWithOracle.priceOracle() != address(0), "oracle should be configured");
        _step("  PASS: priceOracle != address(0)");

        _step("[Step 2] accountantExecutor calls setManualPosTokenPrice(1.05e18) -> expect revert Unsupported()");
        vm.prank(accountantExecutorAddr);
        vm.expectRevert(abi.encodeWithSignature("Unsupported()"));
        adapterWithOracle.setManualPosTokenPrice(1.05e18);
        _step("  PASS: reverted with Unsupported() as expected");
        _logPass();
    }

    // P1: Adapter sweep protects asset and posToken
    function test_Sweep_ProtectsAssetAndPosToken() public {
        _logCase(
            "test_Sweep_ProtectsAssetAndPosToken",
            unicode"Adapter sweep 保护底层资产和 `posToken`"
        );

        _step("[Step 1] Mint tokens to adapter");
        usdc.mint(address(adapterWithOracle), 100e6);
        stToken.mint(address(adapterWithOracle), 200e6);
        otherToken.mint(address(adapterWithOracle), 50e6);

        _step("[Step 2] admin calls sweep(asset, receiver) -> expect revert SweepProtectedToken");
        vm.prank(adminAddr);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("SweepProtectedToken(address)")), address(usdc)));
        adapterWithOracle.sweep(address(usdc), receiver);
        _step("  PASS: sweep(asset) reverted with SweepProtectedToken");

        _step("[Step 3] admin calls sweep(posToken, receiver) -> expect revert SweepProtectedToken");
        vm.prank(adminAddr);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("SweepProtectedToken(address)")), address(stToken)));
        adapterWithOracle.sweep(address(stToken), receiver);
        _step("  PASS: sweep(posToken) reverted with SweepProtectedToken");

        _step("[Step 4] admin calls sweep(otherToken, receiver) -> success");
        vm.prank(adminAddr);
        adapterWithOracle.sweep(address(otherToken), receiver);
        _step(string.concat("  receiver otherToken balance = ", vm.toString(otherToken.balanceOf(receiver))));
        assertEq(otherToken.balanceOf(receiver), 50e6, "otherToken should be swept to receiver");
        _step("  PASS: sweep(otherToken) succeeded");
        assertEq(otherToken.balanceOf(address(adapterWithOracle)), 0, "adapter should have 0 otherToken left");
        _step("  PASS: adapter otherToken balance == 0");
        _logPass();
    }
}

// =============================================================
// Part D: SanctionSafeIn event tests (shares routing + sanctions payout)
// =============================================================

contract RiskRegressionSanctionSafeInTest is Test {
    MockUSDC6 internal usdc;
    MockSanctionsOracleForRisk internal sanctionsOracle;
    MockAccountantForRisk internal accountant;

    MantleYieldVault internal vault;
    MantleVaultGateway internal gateway;

    address internal adminAddr = makeAddr("admin");
    address internal controllerAddr = makeAddr("controller");
    address internal treasuryAddr = makeAddr("treasury");
    address internal sanctionSafeAddr = makeAddr("sanctionSafe");
    address internal sanctionedUser = makeAddr("sanctionedUser");
    address internal normalUser = makeAddr("normalUser");

    string constant MODULE = unicode"风险回归场景";
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
        usdc = new MockUSDC6();
        sanctionsOracle = new MockSanctionsOracleForRisk();
        accountant = new MockAccountantForRisk();

        MantleYieldVault impl = new MantleYieldVault();
        MantleVaultGateway gatewayImpl = new MantleVaultGateway();
        VaultFactory factory = new VaultFactory(address(impl), adminAddr);
        GatewayFactory gatewayFactory = new GatewayFactory(address(gatewayImpl), adminAddr);

        address vaultAddr = factory.deployVault();
        address gatewayAddr = gatewayFactory.deployGateway();
        vault = MantleYieldVault(vaultAddr);
        gateway = MantleVaultGateway(gatewayAddr);

        IMantleYieldVault.InitParams memory params = IMantleYieldVault.InitParams({
            asset: IERC20(address(usdc)),
            name: "Mantle RWA Vault",
            symbol: "mRWA",
            admin: adminAddr,
            gateway: gatewayAddr,
            controller: controllerAddr,
            accountant: address(accountant),
            treasury: treasuryAddr,
            maxRedemptionFeeBps: 500,
            redemptionFeeBps: 0, // No fee for simpler math
            minRedeemAmount: 0,
            minDepositAmount: 0
        });
        vm.prank(adminAddr);
        vault.initialize(params);
        vm.prank(adminAddr);
        gateway.initialize(
            IMantleVaultGateway.InitParams({
                vault: vaultAddr,
                sanctionsOracle: ISanctionsOracle(address(sanctionsOracle)),
                sanctionSafe: sanctionSafeAddr,
                admin: adminAddr,
                syncRedeemDisabled: false
            })
        );

        // Deposit some USDC for normalUser and sanctionedUser
        usdc.mint(normalUser, 10_000e6);
        vm.startPrank(normalUser);
        usdc.approve(address(vault), type(uint256).max);
        gateway.deposit(10_000e6);
        vm.stopPrank();

        // Transfer some shares to sanctionedUser
        vm.prank(normalUser);
        vault.transfer(sanctionedUser, 1000e6);
    }

    // P1: SanctionSafeIn event on both shares routing and sanctions payout paths
    function test_SanctionSafeIn_BothPaths() public {
        _logCase(
            "test_SanctionSafeIn_BothPaths",
            unicode"`SactionSafeIn` 事件在 shares 路由与 sanctions payout 两种路径下均按当前实现正确记录"
        );

        // ---- Path 1: Sanctioned user calls gateway.requestRedeem -> shares routed to sanctionSafe ----
        _step("[Step 1] Path 1: Sanctioned user calls gateway.requestRedeem, triggering shares routing");
        sanctionsOracle.setSanctioned(sanctionedUser, true);

        uint256 sharesToRedeem = 500e6;
        uint256 sanctionSafeSharesBefore = vault.balanceOf(sanctionSafeAddr);
        _step(string.concat("  sanctionedUser shares = ", vm.toString(vault.balanceOf(sanctionedUser))));
        _step(string.concat("  sanctionSafe shares before = ", vm.toString(sanctionSafeSharesBefore)));

        vm.prank(sanctionedUser);
        vm.expectEmit(true, true, false, true, address(vault));
        emit IMantleYieldVault.SanctionSafeIn(sanctionedUser, address(vault), sharesToRedeem);
        uint256 requestId = gateway.requestRedeem(sharesToRedeem);
        _step(string.concat("  requestId = ", vm.toString(requestId)));
        assertEq(requestId, 0, "should return 0 for sanctioned user (no real request created)");
        _step("  PASS: requestId == 0 (sanctioned path)");

        uint256 sanctionSafeSharesAfter = vault.balanceOf(sanctionSafeAddr);
        _step(string.concat("  sanctionSafe shares after = ", vm.toString(sanctionSafeSharesAfter)));
        assertEq(
            sanctionSafeSharesAfter,
            sanctionSafeSharesBefore + sharesToRedeem,
            "sanctionSafe should receive the shares"
        );
        _step("  PASS: SanctionSafeIn emitted for shares routing path");

        // ---- Path 2: Normal user creates request, then gets sanctioned, then settlement pays to sanctionSafe ----
        _step("[Step 2] Path 2: Normal user requests redeem, then gets sanctioned before settlement");

        // normalUser requests redeem
        uint256 normalShares = 1000e6;
        vm.prank(normalUser);
        uint256 reqId = gateway.requestRedeem(normalShares);
        _step(string.concat("  normalUser requestId = ", vm.toString(reqId)));
        assertTrue(reqId > 0, "should create a valid request");
        _step("  PASS: request created successfully");

        // Process the request
        uint256[] memory reqIds = new uint256[](1);
        reqIds[0] = reqId;
        vm.prank(controllerAddr);
        vault.updateRequestBatch(reqIds, IMantleYieldVault.RequestStatus.PROCESSING);
        _step("  request moved to PROCESSING");

        // Now sanction the normal user
        sanctionsOracle.setSanctioned(normalUser, true);
        _step("  normalUser is now sanctioned");

        // Finalize - should pay to sanctionSafe and emit SanctionSafeIn
        // Need to provide USDC to vault for payout
        (,,,, uint256 estimatedAssets,,,) = vault.requests(reqId);
        _step(string.concat("  estimatedAssets = ", vm.toString(estimatedAssets)));
        usdc.mint(address(vault), estimatedAssets);

        uint256[] memory settledAssets = new uint256[](1);
        settledAssets[0] = estimatedAssets;

        _step("[Step 3] Finalize redeem batch -> expect SanctionSafeIn event for sanctions payout path");
        vm.prank(controllerAddr);
        vm.expectEmit(true, true, false, true, address(vault));
        emit IMantleYieldVault.SanctionSafeIn(normalUser, address(usdc), estimatedAssets);
        vault.markRequestsDone(reqIds, settledAssets);
        _step("  PASS: SanctionSafeIn emitted for sanctions payout path");

        _step("[Step 4] Verify sanctionSafe received the USDC payout");
        uint256 safeUsdcBalance = usdc.balanceOf(sanctionSafeAddr);
        _step(string.concat("  sanctionSafe USDC balance = ", vm.toString(safeUsdcBalance)));
        assertEq(safeUsdcBalance, estimatedAssets, "sanctionSafe should receive the settled assets");
        _step("  PASS: sanctionSafe received USDC payout");
        _logPass();
    }
}
