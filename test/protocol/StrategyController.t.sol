// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategyAdapter} from "../../src/interfaces/adapters/IStrategyAdapter.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";

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
            shares: estimatedAssets, estimatedAssets: estimatedAssets, settledAssets: settledAssets, status: status
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
        returns (uint256, address, uint256, uint256, uint256, uint256, IMantleYieldVault.RequestStatus)
    {
        Req memory r = reqs[requestId];
        return (requestId, address(0), r.shares, r.estimatedAssets, r.settledAssets, 0, r.status);
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
        return
            (
                f.id,
                f.adapter,
                f.assetAddr,
                f.tokenAmount,
                f.usdcAmount,
                f.settledAmount,
                f.isInvest,
                f.timestamp,
                f.status
            );
    }
}

contract DummyExecutor {}

contract StrategyControllerUnitTest is Test {
    MockAsset internal asset;
    MockAsset internal posToken;
    MockControllerVault internal vault;
    StrategyController internal controller;
    DummyExecutor internal executorGateway;

    MockStrategyAdapter internal syncAdapter;
    MockStrategyAdapter internal asyncAdapter;

    address internal admin = makeAddr("admin");
    address internal manager = makeAddr("manager");

    function setUp() public {
        asset = new MockAsset();
        posToken = new MockAsset();
        vault = new MockControllerVault(address(asset));
        executorGateway = new DummyExecutor();

        StrategyController implementation = new StrategyController();
        bytes memory initData = abi.encodeCall(
            StrategyController.initialize,
            (address(vault), manager, address(executorGateway), manager, 1000, 200, 1 hours)
        );
        controller = StrategyController(address(new ERC1967Proxy(address(implementation), initData)));

        syncAdapter = new MockStrategyAdapter(address(asset), address(posToken));
        asyncAdapter = new MockStrategyAdapter(address(asset), address(posToken));
    }

    function _registerTwoStrategies() internal {
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 5000, 1, false);
        controller.activateStrategy(address(syncAdapter));
        controller.registerStrategy(address(asyncAdapter), 5000, 2, true);
        controller.activateStrategy(address(asyncAdapter));
        address[] memory ordered = new address[](2);
        ordered[0] = address(syncAdapter);
        ordered[1] = address(asyncAdapter);
        controller.setStrategyOrder(ordered);
        vm.stopPrank();
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

    function _registerSingleSyncStrategy() internal {
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 10_000, 1, false);
        controller.activateStrategy(address(syncAdapter));
        address[] memory ordered = new address[](1);
        ordered[0] = address(syncAdapter);
        controller.setStrategyOrder(ordered);
        vm.stopPrank();
    }

    function test_RevertWhen_InitializeWithNonContractExecutor() public {
        StrategyController implementation = new StrategyController();
        bytes memory initData = abi.encodeCall(
            StrategyController.initialize, (address(vault), manager, makeAddr("eoa"), manager, 1000, 200, 1 hours)
        );
        vm.expectRevert();
        new ERC1967Proxy(address(implementation), initData);
    }

    function test_RevertWhen_SetRiskParamsByNonManager() public {
        vm.expectRevert();
        controller.setRiskParams(100, 100, 1);
    }

    function test_RevertWhen_RegisterDuplicateStrategy() public {
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 5000, 1, false);
        vm.expectRevert();
        controller.registerStrategy(address(syncAdapter), 5000, 1, false);
        vm.stopPrank();
    }

    function test_RevertWhen_SetStrategyOrderDuplicate() public {
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 10000, 1, false);
        controller.activateStrategy(address(syncAdapter));
        address[] memory ordered = new address[](2);
        ordered[0] = address(syncAdapter);
        ordered[1] = address(syncAdapter);
        vm.expectRevert();
        controller.setStrategyOrder(ordered);
        vm.stopPrank();
    }

    function test_RevertWhen_SetStrategyOrderWeightNot10000() public {
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 7000, 1, false);
        controller.activateStrategy(address(syncAdapter));
        address[] memory ordered = new address[](1);
        ordered[0] = address(syncAdapter);
        vm.expectRevert();
        controller.setStrategyOrder(ordered);
        vm.stopPrank();
    }

    function test_RevertWhen_SetStrategyOrderPriorityInvalid() public {
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 5000, 2, false);
        controller.activateStrategy(address(syncAdapter));
        controller.registerStrategy(address(asyncAdapter), 5000, 1, true);
        controller.activateStrategy(address(asyncAdapter));
        address[] memory ordered = new address[](2);
        ordered[0] = address(syncAdapter);
        ordered[1] = address(asyncAdapter);
        vm.expectRevert();
        controller.setStrategyOrder(ordered);
        vm.stopPrank();
    }

    function test_RevertWhen_UpdateStrategiesSingleAdapterBreaksActiveWeightInvariant() public {
        _registerTwoStrategies();

        address[] memory adapters = new address[](1);
        adapters[0] = address(syncAdapter);
        uint16[] memory weights = new uint16[](1);
        weights[0] = 7000;
        uint16[] memory priorities = new uint16[](1);
        priorities[0] = 1;
        bool[] memory asyncFlags = new bool[](1);
        asyncFlags[0] = false;

        vm.prank(manager);
        vm.expectRevert();
        controller.updateStrategies(adapters, weights, priorities, asyncFlags);
    }

    function test_RevertWhen_UpdateStrategiesSingleAdapterBreaksPriorityInvariant() public {
        _registerTwoStrategies();

        address[] memory adapters = new address[](1);
        adapters[0] = address(asyncAdapter);
        uint16[] memory weights = new uint16[](1);
        weights[0] = 5000;
        uint16[] memory priorities = new uint16[](1);
        priorities[0] = 0;
        bool[] memory asyncFlags = new bool[](1);
        asyncFlags[0] = true;

        vm.prank(manager);
        vm.expectRevert();
        controller.updateStrategies(adapters, weights, priorities, asyncFlags);
    }

    function test_UpdateStrategies_AllowsAtomicWeightShift() public {
        _registerTwoStrategies();

        address[] memory adapters = new address[](2);
        adapters[0] = address(syncAdapter);
        adapters[1] = address(asyncAdapter);

        uint16[] memory weights = new uint16[](2);
        weights[0] = 6000;
        weights[1] = 4000;

        uint16[] memory priorities = new uint16[](2);
        priorities[0] = 1;
        priorities[1] = 2;

        bool[] memory asyncFlags = new bool[](2);
        asyncFlags[0] = false;
        asyncFlags[1] = true;

        vm.prank(manager);
        controller.updateStrategies(adapters, weights, priorities, asyncFlags);

        (uint16 syncWeight, uint16 syncPriority, bool syncIsAsync, bool syncIsActive, bool syncExists) =
            controller.strategyInfo(address(syncAdapter));
        (uint16 asyncWeight,,,,) = controller.strategyInfo(address(asyncAdapter));

        assertEq(syncWeight, 6000);
        assertEq(asyncWeight, 4000);
        assertEq(syncPriority, 1);
        assertEq(syncIsAsync, false);
        assertTrue(syncIsActive);
        assertTrue(syncExists);
    }

    function test_RevertWhen_UpdateStrategiesLengthMismatch() public {
        _registerTwoStrategies();

        address[] memory adapters = new address[](2);
        adapters[0] = address(syncAdapter);
        adapters[1] = address(asyncAdapter);

        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;

        uint16[] memory priorities = new uint16[](2);
        priorities[0] = 1;
        priorities[1] = 2;

        bool[] memory asyncFlags = new bool[](2);
        asyncFlags[0] = false;
        asyncFlags[1] = true;

        vm.prank(manager);
        vm.expectRevert(StrategyController.UpdateStrategiesLengthMismatch.selector);
        controller.updateStrategies(adapters, weights, priorities, asyncFlags);
    }

    function test_RevertWhen_UpdateStrategiesDuplicateAdapter() public {
        _registerTwoStrategies();

        address[] memory adapters = new address[](2);
        adapters[0] = address(syncAdapter);
        adapters[1] = address(syncAdapter);

        uint16[] memory weights = new uint16[](2);
        weights[0] = 5000;
        weights[1] = 5000;

        uint16[] memory priorities = new uint16[](2);
        priorities[0] = 1;
        priorities[1] = 1;

        bool[] memory asyncFlags = new bool[](2);
        asyncFlags[0] = false;
        asyncFlags[1] = false;

        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(StrategyController.DuplicateStrategyUpdate.selector, address(syncAdapter))
        );
        controller.updateStrategies(adapters, weights, priorities, asyncFlags);
    }

    function test_UpdateStrategiesAndOrder_AllowsAtomicPriorityAndOrderShift() public {
        _registerTwoStrategies();

        address[] memory adapters = new address[](2);
        adapters[0] = address(syncAdapter);
        adapters[1] = address(asyncAdapter);

        uint16[] memory weights = new uint16[](2);
        weights[0] = 5000;
        weights[1] = 5000;

        uint16[] memory priorities = new uint16[](2);
        priorities[0] = 2;
        priorities[1] = 1;

        bool[] memory asyncFlags = new bool[](2);
        asyncFlags[0] = false;
        asyncFlags[1] = true;

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(StrategyController.InvalidPriorityOrder.selector, address(asyncAdapter)));
        controller.updateStrategies(adapters, weights, priorities, asyncFlags);

        address[] memory ordered = new address[](2);
        ordered[0] = address(asyncAdapter);
        ordered[1] = address(syncAdapter);

        vm.prank(manager);
        controller.updateStrategiesAndOrder(adapters, weights, priorities, asyncFlags, ordered);

        assertEq(controller.strategyOrder(0), address(asyncAdapter));
        assertEq(controller.strategyOrder(1), address(syncAdapter));

        (, uint16 syncPriority,,,) = controller.strategyInfo(address(syncAdapter));
        (, uint16 asyncPriority,,,) = controller.strategyInfo(address(asyncAdapter));
        assertEq(syncPriority, 2);
        assertEq(asyncPriority, 1);
    }

    function test_RevertWhen_UpdateStrategiesAndOrderLengthMismatch() public {
        _registerTwoStrategies();

        address[] memory adapters = new address[](2);
        adapters[0] = address(syncAdapter);
        adapters[1] = address(asyncAdapter);

        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;

        uint16[] memory priorities = new uint16[](2);
        priorities[0] = 1;
        priorities[1] = 2;

        bool[] memory asyncFlags = new bool[](2);
        asyncFlags[0] = false;
        asyncFlags[1] = true;

        address[] memory ordered = new address[](2);
        ordered[0] = address(syncAdapter);
        ordered[1] = address(asyncAdapter);

        vm.prank(manager);
        vm.expectRevert(StrategyController.UpdateStrategiesLengthMismatch.selector);
        controller.updateStrategiesAndOrder(adapters, weights, priorities, asyncFlags, ordered);
    }

    function test_RevertWhen_RebalanceBeforeCooldown() public {
        _registerTwoStrategies();
        asset.mint(address(vault), 1_000e18);

        vm.warp(2 hours);
        vm.prank(address(executorGateway));
        controller.rebalance();

        vm.prank(address(executorGateway));
        vm.expectRevert(StrategyController.CooldownNotElapsed.selector);
        controller.rebalance();
    }

    function test_GetRebalanceState_ReturnsExpectedAccountingState() public {
        _registerSingleSyncStrategy();
        syncAdapter.setTotalValue(2_000e18);
        asset.mint(address(vault), 1_000e18);
        vault.setLocked(200e18);
        vault.createInFlight(address(syncAdapter), address(posToken), 10e18, 300e18, true);
        vault.createInFlight(address(syncAdapter), address(posToken), 10e18, 100e18, false);

        (
            uint256 totalCash,
            uint256 locked,
            uint256 freeCash,
            uint256 netAssets,
            uint256 targetCash,
            uint256 threshold
        ) = controller.getRebalanceState();

        assertEq(totalCash, 1_000e18);
        assertEq(locked, 200e18);
        assertEq(freeCash, 800e18);
        assertEq(netAssets, 3_400e18);
        assertEq(targetCash, 340e18);
        assertEq(threshold, 68e18);
    }

    function test_PreviewRebalance_ReturnsNoneWithinThresholdBand() public {
        asset.mint(address(vault), 1_000e18);
        vault.setLocked(900e18);

        vm.warp(2 hours);
        (bool shouldRebalance, uint8 action, uint256 amount) = controller.previewRebalance();

        assertFalse(shouldRebalance);
        assertEq(action, controller.REBALANCE_ACTION_NONE());
        assertEq(amount, 0);
    }

    function test_PreviewRebalance_ReturnsInvestDecision() public {
        asset.mint(address(vault), 1_000e18);

        vm.warp(2 hours);
        (bool shouldRebalance, uint8 action, uint256 amount) = controller.previewRebalance();

        assertTrue(shouldRebalance);
        assertEq(action, controller.REBALANCE_ACTION_INVEST());
        assertEq(amount, 900e18);
    }

    function test_PreviewRebalance_ReturnsDivestDecision() public {
        _registerSingleSyncStrategy();
        syncAdapter.setTotalValue(3_000e18);
        asset.mint(address(vault), 1_000e18);
        vault.setLocked(900e18);

        vm.warp(2 hours);
        (bool shouldRebalance, uint8 action, uint256 amount) = controller.previewRebalance();

        assertTrue(shouldRebalance);
        assertEq(action, controller.REBALANCE_ACTION_DIVEST());
        assertEq(amount, 300e18);
    }

    function test_PreviewRebalance_ReturnsNoneInsideCooldown() public {
        asset.mint(address(vault), 1_000e18);

        vm.warp(2 hours);
        vm.prank(address(executorGateway));
        controller.rebalance();

        (bool shouldRebalance, uint8 action, uint256 amount) = controller.previewRebalance();
        assertFalse(shouldRebalance);
        assertEq(action, controller.REBALANCE_ACTION_NONE());
        assertEq(amount, 0);
    }

    function test_ExecutorRoleBoundToExecutorGateway() public view {
        assertTrue(controller.hasRole(controller.OPERATOR_EXECUTOR_ROLE(), address(executorGateway)));
        assertFalse(controller.hasRole(controller.OPERATOR_EXECUTOR_ROLE(), manager));
    }

    function test_RevertWhen_RebalanceCalledByNonExecutor() public {
        _registerTwoStrategies();
        asset.mint(address(vault), 1_000e18);

        vm.warp(2 hours);
        vm.prank(makeAddr("notExecutor"));
        vm.expectRevert();
        controller.rebalance();
    }

    function test_RevertWhen_ProcessBatchCalledByNonExecutor() public {
        _registerTwoStrategies();
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;

        vm.prank(makeAddr("notExecutor"));
        vm.expectRevert();
        controller.processRedeemBatch(ids);
    }

    function test_RebalanceInvestPath_ExecutesDeposits() public {
        _registerTwoStrategies();
        asset.mint(address(vault), 1_000e18);

        vm.warp(2 hours);
        vm.prank(address(executorGateway));
        controller.rebalance();

        assertEq(syncAdapter.depositCount(), 1);
        assertEq(asyncAdapter.depositCount(), 1);
        assertEq(syncAdapter.claimCount(), 0);
        assertEq(vault.inFlightIdCursor(), 2);
        (,,,,,, bool firstIsInvest,, IMantleYieldVault.InFlightStatus firstStatus) = vault.inFlightRecords(1);
        assertTrue(firstIsInvest);
        assertEq(uint8(firstStatus), uint8(IMantleYieldVault.InFlightStatus.PENDING));
        (,,,,,, bool secondIsInvest,, IMantleYieldVault.InFlightStatus secondStatus) = vault.inFlightRecords(2);
        assertTrue(secondIsInvest);
        assertEq(uint8(secondStatus), uint8(IMantleYieldVault.InFlightStatus.PENDING));
    }

    function test_RebalanceDivestPath_ExecutesSyncAndAsync() public {
        _registerTwoStrategies();
        syncAdapter.setTotalValue(500e18);
        asyncAdapter.setTotalValue(500e18);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vault.setRequest(1, 700e18, 0, IMantleYieldVault.RequestStatus.PENDING);
        vm.prank(address(executorGateway));
        controller.processRedeemBatch(ids);

        assertEq(syncAdapter.withdrawCount(), 1);
        assertEq(asyncAdapter.asyncCount(), 1);
        assertEq(syncAdapter.claimCount(), 0);
        assertEq(vault.inFlightIdCursor(), 2);
        (,,,,,, bool firstIsInvest,, IMantleYieldVault.InFlightStatus firstStatus) = vault.inFlightRecords(1);
        assertFalse(firstIsInvest);
        assertEq(uint8(firstStatus), uint8(IMantleYieldVault.InFlightStatus.PENDING));
        (,,,,,, bool secondIsInvest,, IMantleYieldVault.InFlightStatus secondStatus) = vault.inFlightRecords(2);
        assertFalse(secondIsInvest);
        assertEq(uint8(secondStatus), uint8(IMantleYieldVault.InFlightStatus.PENDING));
    }

    function test_Rebalance_DivestSkipsFailingStrategy() public {
        _registerTwoStrategies();
        syncAdapter.setTotalValue(500e18);
        asyncAdapter.setTotalValue(500e18);
        syncAdapter.setFailFlags(false, true, false);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vault.setRequest(1, 700e18, 0, IMantleYieldVault.RequestStatus.PENDING);
        vm.prank(address(executorGateway));
        controller.processRedeemBatch(ids);

        assertEq(syncAdapter.withdrawCount(), 0);
        assertEq(asyncAdapter.asyncCount(), 1);
    }

    function test_RevertWhen_ProcessRedeemBatchIdsNotSorted() public {
        _registerTwoStrategies();
        uint256[] memory ids = new uint256[](2);
        ids[0] = 2;
        ids[1] = 1;

        vm.prank(address(executorGateway));
        vm.expectRevert(StrategyController.IdsNotSorted.selector);
        controller.processRedeemBatch(ids);
    }

    function test_RevertWhen_ProcessRedeemBatchReplay() public {
        _registerTwoStrategies();
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;

        vm.prank(address(executorGateway));
        controller.processRedeemBatch(ids);

        vm.prank(address(executorGateway));
        vm.expectRevert();
        controller.processRedeemBatch(ids);
    }

    function test_RevertWhen_AllocateBeforeProcessing() public {
        _registerTwoStrategies();
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        uint256[] memory settledAssets = new uint256[](1);
        settledAssets[0] = 1;

        vm.prank(address(executorGateway));
        vm.expectRevert();
        controller.finalizeRedeemBatch(ids, settledAssets);
    }

    function test_RevertWhen_AllocateInsufficientCash() public {
        _registerTwoStrategies();
        uint256[] memory ids = new uint256[](1);
        ids[0] = 11;
        uint256[] memory settledAssets = new uint256[](1);
        settledAssets[0] = 100e18;
        vault.setRequest(11, 100e18, 0, IMantleYieldVault.RequestStatus.PROCESSING);

        vm.prank(address(executorGateway));
        controller.processRedeemBatch(ids);

        vm.prank(address(executorGateway));
        vm.expectRevert();
        controller.finalizeRedeemBatch(ids, settledAssets);
    }

    function test_AllocateSuccess_AndRevertOnReplayReady() public {
        _registerTwoStrategies();
        uint256[] memory ids = new uint256[](1);
        ids[0] = 21;
        uint256[] memory settledAssets = new uint256[](1);
        settledAssets[0] = 100e18;
        vault.setRequest(21, 100e18, 0, IMantleYieldVault.RequestStatus.PROCESSING);
        asset.mint(address(vault), 100e18);

        vm.prank(address(executorGateway));
        controller.processRedeemBatch(ids);

        vm.prank(address(executorGateway));
        controller.finalizeRedeemBatch(ids, settledAssets);

        vm.prank(address(executorGateway));
        vm.expectRevert();
        controller.finalizeRedeemBatch(ids, settledAssets);
    }

    function test_FinalizeRedeemBatch_DoesNotSweepOrConfirmInFlight() public {
        _registerSingleAsyncStrategy();
        uint256[] memory ids = new uint256[](1);
        ids[0] = 22;
        uint256[] memory settledAssetsInput = new uint256[](1);
        settledAssetsInput[0] = 100e18;
        vault.setRequest(22, 100e18, 0, IMantleYieldVault.RequestStatus.PROCESSING);
        asset.mint(address(vault), 100e18);
        uint256 inFlightId = vault.createInFlight(address(asyncAdapter), address(asset), 0, 10e18, false);
        assertEq(vault.totalRedeemInFlight(), 10e18);

        vm.prank(address(executorGateway));
        controller.processRedeemBatch(ids);

        vm.prank(address(executorGateway));
        controller.finalizeRedeemBatch(ids, settledAssetsInput);

        assertEq(asyncAdapter.claimCount(), 0);
        (,,,,,, bool isInvest,, IMantleYieldVault.InFlightStatus status) = vault.inFlightRecords(inFlightId);
        assertFalse(isInvest);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.PENDING));
        assertEq(vault.totalRedeemInFlight(), 10e18);
        (,,,, uint256 settledAssets,, IMantleYieldVault.RequestStatus reqStatus) = vault.requests(22);
        assertEq(settledAssets, 100e18);
        assertEq(uint8(reqStatus), uint8(IMantleYieldVault.RequestStatus.DONE));
    }

    function test_FinalizeRedeemBatch_RequiresSortedIds() public {
        _registerSingleAsyncStrategy();
        uint256[] memory ids = new uint256[](2);
        ids[0] = 2;
        ids[1] = 1;
        uint256[] memory settledAssets = new uint256[](2);
        settledAssets[0] = 1;
        settledAssets[1] = 1;

        vm.prank(address(executorGateway));
        vm.expectRevert(StrategyController.IdsNotSorted.selector);
        controller.finalizeRedeemBatch(ids, settledAssets);
    }

    function test_SetAdapterPaused_AndBatchPaused() public {
        _registerTwoStrategies();

        vm.prank(manager);
        controller.setAdapterPaused(address(syncAdapter), true);
        assertTrue(syncAdapter.paused());

        address[] memory adapters = new address[](2);
        adapters[0] = address(syncAdapter);
        adapters[1] = address(asyncAdapter);

        vm.prank(manager);
        controller.setAdaptersPaused(adapters, true);
        assertTrue(asyncAdapter.paused());
    }

    function test_SettleAdapter_ConfirmsInvestInFlight() public {
        _registerTwoStrategies();
        uint256 inFlightId = vault.createInFlight(address(asyncAdapter), address(posToken), 10e18, 10e18, true);
        assertEq(vault.investInFlightTotal(), 10e18);
        assertEq(vault.investInFlightByAdapter(address(asyncAdapter)), 10e18);
        uint256[] memory investInFlightIds = new uint256[](1);
        investInFlightIds[0] = inFlightId;
        uint256[] memory investSettledAmounts = new uint256[](1);
        investSettledAmounts[0] = 10e18;

        vm.prank(address(executorGateway));
        controller.settleAdapter(
            address(asyncAdapter), investInFlightIds, investSettledAmounts, new uint256[](0), new uint256[](0)
        );

        (,,,,,, bool isInvest,, IMantleYieldVault.InFlightStatus status) = vault.inFlightRecords(inFlightId);
        assertTrue(isInvest);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(asyncAdapter.claimCount(), 1);
        assertEq(asyncAdapter.lastClaimToken(), address(posToken));
        assertEq(asyncAdapter.lastClaimAmount(), 10e18);
        assertEq(vault.investInFlightTotal(), 0);
        assertEq(vault.investInFlightByAdapter(address(asyncAdapter)), 0);
    }

    function test_SettleAdapter_InvestFlow_UsesClaimedAsActualSettledAmount() public {
        _registerSingleAsyncStrategy();
        uint256 inFlightId = vault.createInFlight(address(asyncAdapter), address(posToken), 100e18, 100e18, true);
        uint256[] memory investInFlightIds = new uint256[](1);
        investInFlightIds[0] = inFlightId;
        uint256[] memory investSettledAmounts = new uint256[](1);
        investSettledAmounts[0] = 99e18;
        asyncAdapter.setSweepReturnAmount(99e18);

        vm.prank(address(executorGateway));
        controller.settleAdapter(
            address(asyncAdapter), investInFlightIds, investSettledAmounts, new uint256[](0), new uint256[](0)
        );

        (,,,,, uint256 settledAmount, bool isInvest,, IMantleYieldVault.InFlightStatus status) =
            vault.inFlightRecords(inFlightId);
        assertTrue(isInvest);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(settledAmount, 99e18);
        assertEq(vault.investInFlightTotal(), 0);
    }

    function test_SettleAdapter_AbnormalInvestWhenThirdPartyNotSettledToAdapter() public {
        _registerSingleAsyncStrategy();
        uint256 inFlightId = vault.createInFlight(address(asyncAdapter), address(posToken), 100e18, 100e18, true);
        uint256[] memory investInFlightIds = new uint256[](1);
        investInFlightIds[0] = inFlightId;
        uint256[] memory investSettledAmounts = new uint256[](1);
        investSettledAmounts[0] = 0;

        vm.prank(address(executorGateway));
        controller.settleAdapter(
            address(asyncAdapter), investInFlightIds, investSettledAmounts, new uint256[](0), new uint256[](0)
        );

        (,,,,, uint256 settledAmount, bool isInvest,, IMantleYieldVault.InFlightStatus status) =
            vault.inFlightRecords(inFlightId);
        assertTrue(isInvest);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(settledAmount, 0);
        assertEq(asyncAdapter.claimCount(), 0);
        assertEq(vault.investInFlightTotal(), 0);
        assertEq(vault.investInFlightByAdapter(address(asyncAdapter)), 0);
    }

    function test_RevertWhen_SettleAdapterInvestInFlightAdapterMismatch() public {
        _registerTwoStrategies();
        uint256 inFlightId = vault.createInFlight(address(syncAdapter), address(posToken), 10e18, 10e18, true);
        uint256[] memory investInFlightIds = new uint256[](1);
        investInFlightIds[0] = inFlightId;
        uint256[] memory investSettledAmounts = new uint256[](1);
        investSettledAmounts[0] = 10e18;

        vm.prank(address(executorGateway));
        vm.expectRevert(abi.encodeWithSelector(StrategyController.InvalidInvestInFlight.selector, inFlightId));
        controller.settleAdapter(
            address(asyncAdapter), investInFlightIds, investSettledAmounts, new uint256[](0), new uint256[](0)
        );
    }

    function test_RevertWhen_SettleAdapterInvalidStrategy() public {
        vm.prank(address(executorGateway));
        vm.expectRevert(abi.encodeWithSelector(StrategyController.InvalidStrategy.selector, address(syncAdapter)));
        controller.settleAdapter(
            address(syncAdapter), new uint256[](0), new uint256[](0), new uint256[](0), new uint256[](0)
        );
    }

    function test_RevertWhen_SettleAdapterMissingInvestInFlightIds() public {
        _registerSingleAsyncStrategy();
        vault.createInFlight(address(asyncAdapter), address(posToken), 10e18, 10e18, true);
        uint256[] memory investSettledAmounts = new uint256[](1);
        investSettledAmounts[0] = 1e18;

        vm.prank(address(executorGateway));
        vm.expectRevert(StrategyController.SettleAmountsLengthMismatch.selector);
        controller.settleAdapter(
            address(asyncAdapter), new uint256[](0), investSettledAmounts, new uint256[](0), new uint256[](0)
        );
    }

    function test_RevertWhen_SettleAdapterInvestClaimedZeroWithProvidedIds() public {
        _registerSingleAsyncStrategy();
        uint256 inFlightId = vault.createInFlight(address(asyncAdapter), address(posToken), 10e18, 10e18, true);
        uint256[] memory investInFlightIds = new uint256[](1);
        investInFlightIds[0] = inFlightId;
        uint256[] memory investSettledAmounts = new uint256[](1);
        investSettledAmounts[0] = 10e18;
        asyncAdapter.setSweepReturnAmount(0);

        vm.prank(address(executorGateway));
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyController.InvestSweepAmountMismatch.selector, address(asyncAdapter), 10e18, 0
            )
        );
        controller.settleAdapter(
            address(asyncAdapter), investInFlightIds, investSettledAmounts, new uint256[](0), new uint256[](0)
        );
    }

    function test_RebalanceInvestAsync_StillInvestsWhenPendingDoesNotCoverFullShortfall() public {
        _registerSingleAsyncStrategy();
        // Existing pending invest in-flight has large token amount for this adapter.
        vault.createInFlight(address(asyncAdapter), address(posToken), 1_000e18, 1_000e18, true);
        asset.mint(address(vault), 1_000e18);

        vm.warp(2 hours);
        vm.prank(address(executorGateway));
        controller.rebalance();

        assertEq(asyncAdapter.depositCount(), 1);
        assertEq(vault.inFlightIdCursor(), 2);
        assertEq(vault.investInFlightTotal(), 1_800e18);
    }

    function test_RebalanceInvestAsync_PartialPendingWithRemainingCapStillInvestsFully() public {
        _registerSingleAsyncStrategy();
        // Pending invest covers part of the new target gap.
        vault.createInFlight(address(asyncAdapter), address(posToken), 400e18, 400e18, true);
        asset.mint(address(vault), 1_000e18);

        vm.warp(2 hours);
        vm.prank(address(executorGateway));
        controller.rebalance();

        // Pending only partially covers shortfall; because remaining is lower than uncovered shortfall,
        // this round still invests the full remaining amount.
        assertEq(vault.inFlightIdCursor(), 2);
        assertEq(vault.investInFlightTotal(), 1_260e18);
    }

    function test_RebalanceInvestAsync_DoesNotSkipWhenPendingOnlyCoversCappedAlloc() public {
        _registerSingleAsyncStrategy();

        vm.prank(manager);
        controller.setRiskParams(0, 0, 0);

        // Historical pending is large and covers this round's capped alloc, but does not cover
        // the adapter's full target shortfall.
        vault.createInFlight(address(asyncAdapter), address(posToken), 1_481_000_000, 1_481_000_000, true);
        asset.mint(address(vault), 2_000_000);

        vm.warp(2 hours);
        vm.prank(address(executorGateway));
        controller.rebalance();

        // Should still invest the uncovered delta (~2,000,000) instead of skipping.
        assertEq(asyncAdapter.depositCount(), 1);
        assertEq(vault.inFlightIdCursor(), 2);
        assertEq(vault.investInFlightTotal(), 1_483_000_000);
    }

    function test_RebalanceInvestSync_StillInvestsWhenPendingDoesNotCoverFullShortfall() public {
        _registerSingleSyncStrategy();
        vault.createInFlight(address(syncAdapter), address(posToken), 1_000e18, 1_000e18, true);
        asset.mint(address(vault), 1_000e18);

        vm.warp(2 hours);
        vm.prank(address(executorGateway));
        controller.rebalance();

        assertEq(syncAdapter.depositCount(), 1);
        assertEq(vault.inFlightIdCursor(), 2);
        assertEq(vault.investInFlightTotal(), 1_800e18);
    }

    function test_RebalanceInvest_EstimateFailAndDepositReturnsZero_Reverts() public {
        _registerSingleAsyncStrategy();
        asyncAdapter.setFailEstimate(true);
        asyncAdapter.setDepositReturnZero(true);
        asset.mint(address(vault), 1_000e18);

        vm.warp(2 hours);
        vm.prank(address(executorGateway));
        // alloc = 900e18 (freeCash 1000e18 - targetCash 100e18)
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyController.InvestPosAmountUnavailable.selector, address(asyncAdapter), 900e18
            )
        );
        controller.rebalance();
    }

    function test_RebalanceInvest_DepositReturnsZeroButEstimateSucceeds() public {
        _registerSingleAsyncStrategy();
        asyncAdapter.setDepositReturnZero(true);
        // estimatePosAmount still works (not failed)
        asset.mint(address(vault), 1_000e18);

        vm.warp(2 hours);
        vm.prank(address(executorGateway));
        controller.rebalance();

        // deposit called, sharesOrPos=0, but estimate gives valid pos → in-flight recorded
        assertEq(asyncAdapter.depositCount(), 1);
        assertEq(vault.inFlightIdCursor(), 1);
        (,,, uint256 tokenAmount, uint256 usdcAmount,,,,) = vault.inFlightRecords(1);
        assertEq(usdcAmount, 900e18);
        assertEq(tokenAmount, 900e18); // from estimatePosAmount
    }

    function test_RebalanceInvest_EstimateFailButDepositReturnsPos_UsesSharosOrPos() public {
        _registerSingleAsyncStrategy();
        asyncAdapter.setFailEstimate(true);
        // deposit returns normal amount (not zero)
        asset.mint(address(vault), 1_000e18);

        vm.warp(2 hours);
        vm.prank(address(executorGateway));
        controller.rebalance();

        assertEq(asyncAdapter.depositCount(), 1);
        assertEq(vault.inFlightIdCursor(), 1);

        // alloc = 900e18, deposit returns 900e18 (sharesOrPos=amount in mock)
        // estimate reverted, fallback=sharesOrPos=900e18
        (,,, uint256 tokenAmount, uint256 usdcAmount,,,,) = vault.inFlightRecords(1);
        assertEq(usdcAmount, 900e18);
        // sharesOrPos != 0, so posAmount = sharesOrPos = 900e18
        // In this mock, asset and pos have the same decimals, so it looks correct.
        // For a real adapter (asset=6dec, pos=18dec), sharesOrPos could still be wrong
        // if deposit() returns asset-denominated value instead of pos-denominated.
        assertEq(tokenAmount, 900e18);
    }

    function test_RebalanceDivestSync_SkipsWhenCoveredByPendingRedeem() public {
        _registerSingleSyncStrategy();
        syncAdapter.setTotalValue(500e18);
        vault.createInFlight(address(syncAdapter), address(posToken), 50e18, 300e18, false);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 901;
        vault.setRequest(901, 300e18, 0, IMantleYieldVault.RequestStatus.PENDING);
        vm.prank(address(executorGateway));
        controller.processRedeemBatch(ids);

        assertEq(syncAdapter.withdrawCount(), 0);
        assertEq(vault.inFlightIdCursor(), 1);
        assertEq(vault.redeemInFlightTotal(), 300e18);
    }

    function test_RebalanceDivestAsync_SkipsWhenEstimateFails() public {
        _registerSingleAsyncStrategy();
        asyncAdapter.setTotalValue(500e18);
        asyncAdapter.setFailEstimate(true);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 811;
        vault.setRequest(811, 300e18, 0, IMantleYieldVault.RequestStatus.PENDING);

        vm.prank(address(executorGateway));
        controller.processRedeemBatch(ids);

        assertEq(asyncAdapter.asyncCount(), 0);
        assertEq(vault.inFlightIdCursor(), 0);
        assertEq(vault.redeemInFlightTotal(), 0);
    }

    function test_RebalanceDivestSync_SkipsWhenEstimateFails() public {
        _registerSingleSyncStrategy();
        syncAdapter.setTotalValue(500e18);
        syncAdapter.setFailEstimate(true);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 812;
        vault.setRequest(812, 300e18, 0, IMantleYieldVault.RequestStatus.PENDING);

        vm.prank(address(executorGateway));
        controller.processRedeemBatch(ids);

        assertEq(syncAdapter.withdrawCount(), 0);
        assertEq(vault.inFlightIdCursor(), 0);
        assertEq(vault.redeemInFlightTotal(), 0);
    }

    function test_SettleAdapter_RedeemFlow_ClaimsAndConfirms() public {
        _registerSingleAsyncStrategy();

        uint256 requestId = 301;
        vault.setRequest(requestId, 100e18, 0, IMantleYieldVault.RequestStatus.PROCESSING);
        uint256[] memory ids = new uint256[](1);
        ids[0] = requestId;
        vm.prank(address(executorGateway));
        controller.processRedeemBatch(ids);

        uint256 redeemInFlightId = vault.createInFlight(address(asyncAdapter), address(posToken), 50e18, 100e18, false);
        assertEq(vault.redeemInFlightTotal(), 100e18);
        assertEq(vault.redeemInFlightByAdapter(address(asyncAdapter)), 100e18);
        uint256[] memory redeemInFlightIds = new uint256[](1);
        redeemInFlightIds[0] = redeemInFlightId;
        uint256[] memory redeemSettledAmounts = new uint256[](1);
        redeemSettledAmounts[0] = 100e18;

        asset.mint(address(vault), 100e18);

        vm.prank(address(executorGateway));
        controller.settleAdapter(
            address(asyncAdapter), new uint256[](0), new uint256[](0), redeemInFlightIds, redeemSettledAmounts
        );

        assertEq(asyncAdapter.claimCount(), 1);
        assertEq(asyncAdapter.lastClaimToken(), address(asset));
        assertEq(asyncAdapter.lastClaimAmount(), 100e18);
        (,,,,,, bool isInvest,, IMantleYieldVault.InFlightStatus status) = vault.inFlightRecords(redeemInFlightId);
        assertTrue(!isInvest);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(vault.redeemInFlightTotal(), 0);
        assertEq(vault.redeemInFlightByAdapter(address(asyncAdapter)), 0);

        (,,,, uint256 settledAssets,, IMantleYieldVault.RequestStatus reqStatus) = vault.requests(requestId);
        assertEq(settledAssets, 0);
        assertEq(uint8(reqStatus), uint8(IMantleYieldVault.RequestStatus.PROCESSING));
    }

    function test_SettleAdapter_InvestAndRedeemTogether() public {
        _registerSingleAsyncStrategy();

        uint256 requestId = 302;
        vault.setRequest(requestId, 100e18, 0, IMantleYieldVault.RequestStatus.PROCESSING);
        uint256[] memory ids = new uint256[](1);
        ids[0] = requestId;
        vm.prank(address(executorGateway));
        controller.processRedeemBatch(ids);

        uint256 investInFlightId = vault.createInFlight(address(asyncAdapter), address(posToken), 25e18, 50e18, true);
        uint256[] memory investInFlightIds = new uint256[](1);
        investInFlightIds[0] = investInFlightId;
        uint256[] memory investSettledAmounts = new uint256[](1);
        investSettledAmounts[0] = 25e18;

        uint256 redeemInFlightId = vault.createInFlight(address(asyncAdapter), address(posToken), 50e18, 100e18, false);
        uint256[] memory redeemInFlightIds = new uint256[](1);
        redeemInFlightIds[0] = redeemInFlightId;
        uint256[] memory redeemSettledAmounts = new uint256[](1);
        redeemSettledAmounts[0] = 100e18;
        assertEq(vault.investInFlightTotal(), 50e18);
        assertEq(vault.redeemInFlightTotal(), 100e18);

        asset.mint(address(vault), 100e18);
        vm.prank(address(executorGateway));
        controller.settleAdapter(
            address(asyncAdapter), investInFlightIds, investSettledAmounts, redeemInFlightIds, redeemSettledAmounts
        );

        (,,,,,, bool investIsInvest,, IMantleYieldVault.InFlightStatus investStatus) =
            vault.inFlightRecords(investInFlightId);
        assertTrue(investIsInvest);
        assertEq(uint8(investStatus), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        (,,,,,, bool redeemIsInvest,, IMantleYieldVault.InFlightStatus redeemStatus) =
            vault.inFlightRecords(redeemInFlightId);
        assertTrue(!redeemIsInvest);
        assertEq(uint8(redeemStatus), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(vault.investInFlightTotal(), 0);
        assertEq(vault.redeemInFlightTotal(), 0);
    }

    function test_SettleAdapters_InvestAndRedeemTogether() public {
        _registerTwoStrategies();

        uint256 requestId = 303;
        vault.setRequest(requestId, 100e18, 0, IMantleYieldVault.RequestStatus.PROCESSING);
        uint256[] memory ids = new uint256[](1);
        ids[0] = requestId;
        vm.prank(address(executorGateway));
        controller.processRedeemBatch(ids);

        uint256 investInFlightId = vault.createInFlight(address(asyncAdapter), address(posToken), 25e18, 50e18, true);
        uint256 redeemInFlightId = vault.createInFlight(address(syncAdapter), address(posToken), 50e18, 100e18, false);
        assertEq(vault.investInFlightTotal(), 50e18);
        assertEq(vault.redeemInFlightTotal(), 100e18);

        address[] memory adapters = new address[](2);
        adapters[0] = address(asyncAdapter);
        adapters[1] = address(syncAdapter);
        uint256[][] memory investInFlightIdsBatch = new uint256[][](2);
        investInFlightIdsBatch[0] = new uint256[](1);
        investInFlightIdsBatch[0][0] = investInFlightId;
        investInFlightIdsBatch[1] = new uint256[](0);
        uint256[][] memory investSettledAmountsBatch = new uint256[][](2);
        investSettledAmountsBatch[0] = new uint256[](1);
        investSettledAmountsBatch[0][0] = 25e18;
        investSettledAmountsBatch[1] = new uint256[](0);
        uint256[][] memory redeemInFlightIdsBatch = new uint256[][](2);
        redeemInFlightIdsBatch[0] = new uint256[](0);
        redeemInFlightIdsBatch[1] = new uint256[](1);
        redeemInFlightIdsBatch[1][0] = redeemInFlightId;
        uint256[][] memory redeemSettledAmountsBatch = new uint256[][](2);
        redeemSettledAmountsBatch[0] = new uint256[](0);
        redeemSettledAmountsBatch[1] = new uint256[](1);
        redeemSettledAmountsBatch[1][0] = 100e18;

        asset.mint(address(vault), 100e18);
        vm.prank(address(executorGateway));
        controller.settleAdapters(
            adapters,
            investInFlightIdsBatch,
            investSettledAmountsBatch,
            redeemInFlightIdsBatch,
            redeemSettledAmountsBatch
        );

        assertEq(asyncAdapter.claimCount(), 1);
        assertEq(asyncAdapter.lastClaimToken(), address(posToken));
        assertEq(asyncAdapter.lastClaimAmount(), 25e18);
        assertEq(syncAdapter.claimCount(), 1);
        assertEq(syncAdapter.lastClaimToken(), address(asset));
        assertEq(syncAdapter.lastClaimAmount(), 100e18);

        (,,,,,, bool investIsInvest,, IMantleYieldVault.InFlightStatus investStatus) =
            vault.inFlightRecords(investInFlightId);
        assertTrue(investIsInvest);
        assertEq(uint8(investStatus), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        (,,,,,, bool redeemIsInvest,, IMantleYieldVault.InFlightStatus redeemStatus) =
            vault.inFlightRecords(redeemInFlightId);
        assertTrue(!redeemIsInvest);
        assertEq(uint8(redeemStatus), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(vault.investInFlightTotal(), 0);
        assertEq(vault.redeemInFlightTotal(), 0);

        (,,,, uint256 settledAssets,, IMantleYieldVault.RequestStatus reqStatus) = vault.requests(requestId);
        assertEq(settledAssets, 0);
        assertEq(uint8(reqStatus), uint8(IMantleYieldVault.RequestStatus.PROCESSING));
    }

    function test_RevertWhen_SettleAdaptersClaimInputLengthMismatch() public {
        _registerTwoStrategies();

        address[] memory adapters = new address[](1);
        adapters[0] = address(asyncAdapter);
        uint256[][] memory investInFlightIdsBatch = new uint256[][](1);
        investInFlightIdsBatch[0] = new uint256[](1);
        investInFlightIdsBatch[0][0] =
            vault.createInFlight(address(asyncAdapter), address(posToken), 10e18, 10e18, true);
        uint256[][] memory investSettledAmountsBatch = new uint256[][](0);
        uint256[][] memory redeemInFlightIdsBatch = new uint256[][](1);
        redeemInFlightIdsBatch[0] = new uint256[](0);
        uint256[][] memory redeemSettledAmountsBatch = new uint256[][](1);
        redeemSettledAmountsBatch[0] = new uint256[](0);

        vm.prank(address(executorGateway));
        vm.expectRevert(StrategyController.SettleAmountsLengthMismatch.selector);
        controller.settleAdapters(
            adapters,
            investInFlightIdsBatch,
            investSettledAmountsBatch,
            redeemInFlightIdsBatch,
            redeemSettledAmountsBatch
        );
    }

    function test_RevertWhen_SettleAdaptersInvestInFlightAdapterNotIncluded() public {
        _registerTwoStrategies();
        uint256 badInFlightId = vault.createInFlight(address(asyncAdapter), address(posToken), 10e18, 10e18, true);

        address[] memory adapters = new address[](1);
        adapters[0] = address(syncAdapter);
        uint256[][] memory investInFlightIdsBatch = new uint256[][](1);
        investInFlightIdsBatch[0] = new uint256[](1);
        investInFlightIdsBatch[0][0] = badInFlightId;
        uint256[][] memory investSettledAmountsBatch = new uint256[][](1);
        investSettledAmountsBatch[0] = new uint256[](1);
        investSettledAmountsBatch[0][0] = 10e18;
        uint256[][] memory redeemInFlightIdsBatch = new uint256[][](1);
        redeemInFlightIdsBatch[0] = new uint256[](0);
        uint256[][] memory redeemSettledAmountsBatch = new uint256[][](1);
        redeemSettledAmountsBatch[0] = new uint256[](0);

        vm.prank(address(executorGateway));
        vm.expectRevert(abi.encodeWithSelector(StrategyController.InvalidInvestInFlight.selector, badInFlightId));
        controller.settleAdapters(
            adapters,
            investInFlightIdsBatch,
            investSettledAmountsBatch,
            redeemInFlightIdsBatch,
            redeemSettledAmountsBatch
        );
    }

    function test_RevertWhen_SettleAdapterMissingRedeemInFlightIds() public {
        _registerSingleAsyncStrategy();
        vault.createInFlight(address(asyncAdapter), address(posToken), 50e18, 100e18, false);
        uint256[] memory redeemSettledAmounts = new uint256[](1);
        redeemSettledAmounts[0] = 1;

        vm.prank(address(executorGateway));
        vm.expectRevert(StrategyController.SettleAmountsLengthMismatch.selector);
        controller.settleAdapter(
            address(asyncAdapter), new uint256[](0), new uint256[](0), new uint256[](0), redeemSettledAmounts
        );
    }

    function test_RevertWhen_SettleAdapterHasPendingRedeemInFlightWithoutIds() public {
        _registerSingleAsyncStrategy();
        uint256 redeemInFlightId = vault.createInFlight(address(asyncAdapter), address(posToken), 50e18, 100e18, false);
        uint256[] memory redeemInFlightIds = new uint256[](1);
        redeemInFlightIds[0] = redeemInFlightId;
        uint256[] memory redeemSettledAmounts = new uint256[](1);
        redeemSettledAmounts[0] = 100e18;
        asyncAdapter.setSweepReturnAmount(0);

        vm.prank(address(executorGateway));
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyController.RedeemSweepAmountMismatch.selector, address(asyncAdapter), 100e18, 0
            )
        );
        controller.settleAdapter(
            address(asyncAdapter), new uint256[](0), new uint256[](0), redeemInFlightIds, redeemSettledAmounts
        );
    }
}
