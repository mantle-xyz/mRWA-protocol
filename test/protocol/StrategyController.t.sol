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

    uint256 public depositCount;
    uint256 public withdrawCount;
    uint256 public asyncCount;
    uint256 public claimCount;
    address public lastClaimToken;
    uint256 public lastClaimAmount;

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

    function estimatePosAmount(uint256 assetAmount) external pure returns (uint256 positionAmount) {
        return assetAmount;
    }

    function vault() external pure returns (address) {
        return address(0);
    }

    function totalValue() external view returns (uint256) {
        return mockedTotalValue;
    }

    function getPrice() external pure returns (uint256) {
        return 1e18;
    }

    function deposit(uint256 amount, address) external returns (uint256 sharesOrPos) {
        if (failDeposit) revert("DEPOSIT_FAIL");
        depositCount++;
        return amount;
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
        return amount;
    }

    function setPaused(bool p) external {
        paused = p;
    }
}

contract MockControllerVault {
    ERC20 public immutable token;

    uint256 public locked;
    uint256 public investInFlightTotal;
    uint256 public redeemInFlightTotal;
    uint256 public inFlightIdCursor;
    mapping(address => uint256) public investInFlightByAdapter;
    mapping(address => uint256) public redeemInFlightByAdapter;

    struct Req {
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
        reqs[id] = Req({estimatedAssets: estimatedAssets, settledAssets: settledAssets, status: status});
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

    function updateRequestBatch(uint256[] calldata ids, IMantleYieldVault.RequestStatus newStatus) external {
        for (uint256 i = 0; i < ids.length; i++) {
            reqs[ids[i]].status = newStatus;
        }
    }

    function markRequestsReady(uint256[] calldata ids, uint256[] calldata settledAssets) external {
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

    function confirmInFlight(uint256 inFlightId, uint256 actualAmount) external {
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
        return (requestId, address(0), 0, r.estimatedAssets, r.settledAssets, 0, r.status);
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
        return (
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
            (address(vault), admin, manager, address(executorGateway), 1000, 200, 1 hours)
        );
        controller = StrategyController(address(new ERC1967Proxy(address(implementation), initData)));

        syncAdapter = new MockStrategyAdapter(address(asset), address(posToken));
        asyncAdapter = new MockStrategyAdapter(address(asset), address(posToken));
    }

    function _registerTwoStrategies() internal {
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 5000, 1, false, true);
        controller.registerStrategy(address(asyncAdapter), 5000, 2, true, true);
        address[] memory ordered = new address[](2);
        ordered[0] = address(syncAdapter);
        ordered[1] = address(asyncAdapter);
        controller.setStrategyOrder(ordered);
        vm.stopPrank();
    }

    function _registerSingleAsyncStrategy() internal {
        vm.startPrank(manager);
        controller.registerStrategy(address(asyncAdapter), 10_000, 1, true, true);
        address[] memory ordered = new address[](1);
        ordered[0] = address(asyncAdapter);
        controller.setStrategyOrder(ordered);
        vm.stopPrank();
    }

    function test_RevertWhen_InitializeWithNonContractExecutor() public {
        StrategyController implementation = new StrategyController();
        bytes memory initData = abi.encodeCall(
            StrategyController.initialize, (address(vault), admin, manager, makeAddr("eoa"), 1000, 200, 1 hours)
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
        controller.registerStrategy(address(syncAdapter), 5000, 1, false, true);
        vm.expectRevert();
        controller.registerStrategy(address(syncAdapter), 5000, 1, false, true);
        vm.stopPrank();
    }

    function test_RevertWhen_SetStrategyOrderDuplicate() public {
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 10000, 1, false, true);
        address[] memory ordered = new address[](2);
        ordered[0] = address(syncAdapter);
        ordered[1] = address(syncAdapter);
        vm.expectRevert();
        controller.setStrategyOrder(ordered);
        vm.stopPrank();
    }

    function test_RevertWhen_SetStrategyOrderWeightNot10000() public {
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 7000, 1, false, true);
        address[] memory ordered = new address[](1);
        ordered[0] = address(syncAdapter);
        vm.expectRevert();
        controller.setStrategyOrder(ordered);
        vm.stopPrank();
    }

    function test_RevertWhen_SetStrategyOrderPriorityInvalid() public {
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 5000, 2, false, true);
        controller.registerStrategy(address(asyncAdapter), 5000, 1, true, true);
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
        bool[] memory activeFlags = new bool[](1);
        activeFlags[0] = true;

        vm.prank(manager);
        vm.expectRevert();
        controller.updateStrategies(adapters, weights, priorities, asyncFlags, activeFlags);
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
        bool[] memory activeFlags = new bool[](1);
        activeFlags[0] = true;

        vm.prank(manager);
        vm.expectRevert();
        controller.updateStrategies(adapters, weights, priorities, asyncFlags, activeFlags);
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

        bool[] memory activeFlags = new bool[](2);
        activeFlags[0] = true;
        activeFlags[1] = true;

        vm.prank(manager);
        controller.updateStrategies(adapters, weights, priorities, asyncFlags, activeFlags);

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

        bool[] memory activeFlags = new bool[](2);
        activeFlags[0] = true;
        activeFlags[1] = true;

        vm.prank(manager);
        vm.expectRevert(StrategyController.UpdateStrategiesLengthMismatch.selector);
        controller.updateStrategies(adapters, weights, priorities, asyncFlags, activeFlags);
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

        bool[] memory activeFlags = new bool[](2);
        activeFlags[0] = true;
        activeFlags[1] = true;

        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(StrategyController.DuplicateStrategyUpdate.selector, address(syncAdapter))
        );
        controller.updateStrategies(adapters, weights, priorities, asyncFlags, activeFlags);
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

        bool[] memory activeFlags = new bool[](2);
        activeFlags[0] = true;
        activeFlags[1] = true;

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(StrategyController.InvalidPriorityOrder.selector, address(asyncAdapter)));
        controller.updateStrategies(adapters, weights, priorities, asyncFlags, activeFlags);

        address[] memory ordered = new address[](2);
        ordered[0] = address(asyncAdapter);
        ordered[1] = address(syncAdapter);

        vm.prank(manager);
        controller.updateStrategiesAndOrder(adapters, weights, priorities, asyncFlags, activeFlags, ordered);

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

        bool[] memory activeFlags = new bool[](2);
        activeFlags[0] = true;
        activeFlags[1] = true;

        address[] memory ordered = new address[](2);
        ordered[0] = address(syncAdapter);
        ordered[1] = address(asyncAdapter);

        vm.prank(manager);
        vm.expectRevert(StrategyController.UpdateStrategiesLengthMismatch.selector);
        controller.updateStrategiesAndOrder(adapters, weights, priorities, asyncFlags, activeFlags, ordered);
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

    function test_ExecutorRoleBoundToExecutorGateway() public view {
        assertTrue(controller.hasRole(controller.EXECUTOR_ROLE(), address(executorGateway)));
        assertFalse(controller.hasRole(controller.EXECUTOR_ROLE(), manager));
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
        controller.processRedeemBatch(ids, 0);
    }

    function test_RebalanceInvestPath_ExecutesDeposits() public {
        _registerTwoStrategies();
        asset.mint(address(vault), 1_000e18);

        vm.warp(2 hours);
        vm.prank(address(executorGateway));
        controller.rebalance();

        assertEq(syncAdapter.depositCount(), 1);
        assertEq(asyncAdapter.depositCount(), 1);
    }

    function test_RebalanceDivestPath_ExecutesSyncAndAsync() public {
        _registerTwoStrategies();
        syncAdapter.setTotalValue(500e18);
        asyncAdapter.setTotalValue(500e18);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(address(executorGateway));
        controller.processRedeemBatch(ids, 700e18);

        assertEq(syncAdapter.withdrawCount(), 1);
        assertEq(asyncAdapter.asyncCount(), 1);
        assertGt(vault.inFlightIdCursor(), 0);
    }

    function test_Rebalance_DivestSkipsFailingStrategy() public {
        _registerTwoStrategies();
        syncAdapter.setTotalValue(500e18);
        asyncAdapter.setTotalValue(500e18);
        syncAdapter.setFailFlags(false, true, false);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(address(executorGateway));
        controller.processRedeemBatch(ids, 700e18);

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
        controller.processRedeemBatch(ids, 1);
    }

    function test_RevertWhen_ProcessRedeemBatchReplay() public {
        _registerTwoStrategies();
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;

        vm.prank(address(executorGateway));
        controller.processRedeemBatch(ids, 0);

        vm.prank(address(executorGateway));
        vm.expectRevert();
        controller.processRedeemBatch(ids, 0);
    }

    function test_RevertWhen_AllocateBeforeProcessing() public {
        _registerTwoStrategies();
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;

        vm.prank(address(executorGateway));
        vm.expectRevert();
        controller.finalizeRedeemBatch(ids);
    }

    function test_RevertWhen_AllocateInsufficientCash() public {
        _registerTwoStrategies();
        uint256[] memory ids = new uint256[](1);
        ids[0] = 11;
        vault.setRequest(11, 100e18, 0, IMantleYieldVault.RequestStatus.PROCESSING);

        vm.prank(address(executorGateway));
        controller.processRedeemBatch(ids, 0);

        vm.prank(address(executorGateway));
        vm.expectRevert();
        controller.finalizeRedeemBatch(ids);
    }

    function test_AllocateSuccess_AndRevertOnReplayReady() public {
        _registerTwoStrategies();
        uint256[] memory ids = new uint256[](1);
        ids[0] = 21;
        vault.setRequest(21, 100e18, 0, IMantleYieldVault.RequestStatus.PROCESSING);
        asset.mint(address(vault), 100e18);

        vm.prank(address(executorGateway));
        controller.processRedeemBatch(ids, 0);

        vm.prank(address(executorGateway));
        controller.finalizeRedeemBatch(ids);

        vm.prank(address(executorGateway));
        vm.expectRevert();
        controller.finalizeRedeemBatch(ids);
    }

    function test_FinalizeRedeemBatch_DoesNotSweepOrConfirmInFlight() public {
        _registerSingleAsyncStrategy();
        uint256[] memory ids = new uint256[](1);
        ids[0] = 22;
        vault.setRequest(22, 100e18, 0, IMantleYieldVault.RequestStatus.PROCESSING);
        asset.mint(address(vault), 100e18);
        uint256 inFlightId = vault.createInFlight(address(asyncAdapter), address(asset), 0, 10e18, false);
        assertEq(vault.totalRedeemInFlight(), 10e18);

        vm.prank(address(executorGateway));
        controller.processRedeemBatch(ids, 0);

        vm.prank(address(executorGateway));
        controller.finalizeRedeemBatch(ids);

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

        vm.prank(address(executorGateway));
        vm.expectRevert(StrategyController.IdsNotSorted.selector);
        controller.finalizeRedeemBatch(ids);
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

        vm.prank(address(executorGateway));
        controller.settleAdapter(address(asyncAdapter), 0, 0, investInFlightIds, new uint256[](0));

        (,,,,,, bool isInvest,, IMantleYieldVault.InFlightStatus status) = vault.inFlightRecords(inFlightId);
        assertTrue(isInvest);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(vault.investInFlightTotal(), 0);
        assertEq(vault.investInFlightByAdapter(address(asyncAdapter)), 0);
    }

    function test_RevertWhen_SettleAdapterInvestInFlightAdapterMismatch() public {
        _registerTwoStrategies();
        uint256 inFlightId = vault.createInFlight(address(syncAdapter), address(posToken), 10e18, 10e18, true);
        uint256[] memory investInFlightIds = new uint256[](1);
        investInFlightIds[0] = inFlightId;

        vm.prank(address(executorGateway));
        vm.expectRevert(abi.encodeWithSelector(StrategyController.InvalidInvestInFlight.selector, inFlightId));
        controller.settleAdapter(address(asyncAdapter), 0, 0, investInFlightIds, new uint256[](0));
    }

    function test_RevertWhen_SettleAdapterInvalidStrategy() public {
        vm.prank(address(executorGateway));
        vm.expectRevert(abi.encodeWithSelector(StrategyController.InvalidStrategy.selector, address(syncAdapter)));
        controller.settleAdapter(address(syncAdapter), 1, 1, new uint256[](0), new uint256[](0));
    }

    function test_RevertWhen_SettleAdapterMissingInvestInFlightIds() public {
        _registerSingleAsyncStrategy();
        vault.createInFlight(address(asyncAdapter), address(posToken), 10e18, 10e18, true);

        vm.prank(address(executorGateway));
        vm.expectRevert(
            abi.encodeWithSelector(StrategyController.InvestInFlightIdsRequired.selector, address(asyncAdapter))
        );
        controller.settleAdapter(address(asyncAdapter), 1e18, 0, new uint256[](0), new uint256[](0));
    }

    function test_RebalanceInvestAsync_DoesNotCreateDuplicateInFlightWhenPendingExists() public {
        _registerSingleAsyncStrategy();
        // Existing pending invest in-flight has large token amount for this adapter.
        vault.createInFlight(address(asyncAdapter), address(posToken), 1_000e18, 1_000e18, true);
        asset.mint(address(vault), 1_000e18);

        vm.warp(2 hours);
        vm.prank(address(executorGateway));
        controller.rebalance();

        assertEq(vault.inFlightIdCursor(), 1);
        assertEq(vault.investInFlightTotal(), 1_000e18);
    }

    function test_RebalanceInvestAsync_PartialPendingDeductsEstimatedCoverage() public {
        _registerSingleAsyncStrategy();
        // Pending invest covers part of the new target gap.
        vault.createInFlight(address(asyncAdapter), address(posToken), 400e18, 400e18, true);
        asset.mint(address(vault), 1_000e18);

        vm.warp(2 hours);
        vm.prank(address(executorGateway));
        controller.rebalance();

        // New in-flight = 460e18 (860 target invest request - 400 pending coverage estimate).
        assertEq(vault.inFlightIdCursor(), 2);
        assertEq(vault.investInFlightTotal(), 860e18);
    }

    function test_SettleAdapter_RedeemFlow_ClaimsAndConfirms() public {
        _registerSingleAsyncStrategy();

        uint256 requestId = 301;
        vault.setRequest(requestId, 100e18, 0, IMantleYieldVault.RequestStatus.PROCESSING);
        uint256[] memory ids = new uint256[](1);
        ids[0] = requestId;
        vm.prank(address(executorGateway));
        controller.processRedeemBatch(ids, 0);

        uint256 redeemInFlightId = vault.createInFlight(address(asyncAdapter), address(posToken), 50e18, 100e18, false);
        assertEq(vault.redeemInFlightTotal(), 100e18);
        assertEq(vault.redeemInFlightByAdapter(address(asyncAdapter)), 100e18);
        uint256[] memory redeemInFlightIds = new uint256[](1);
        redeemInFlightIds[0] = redeemInFlightId;

        asset.mint(address(vault), 100e18);

        vm.prank(address(executorGateway));
        controller.settleAdapter(address(asyncAdapter), 0, 100e18, new uint256[](0), redeemInFlightIds);

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
        controller.processRedeemBatch(ids, 0);

        uint256 investInFlightId = vault.createInFlight(address(asyncAdapter), address(posToken), 25e18, 50e18, true);
        uint256[] memory investInFlightIds = new uint256[](1);
        investInFlightIds[0] = investInFlightId;

        uint256 redeemInFlightId = vault.createInFlight(address(asyncAdapter), address(posToken), 50e18, 100e18, false);
        uint256[] memory redeemInFlightIds = new uint256[](1);
        redeemInFlightIds[0] = redeemInFlightId;
        assertEq(vault.investInFlightTotal(), 50e18);
        assertEq(vault.redeemInFlightTotal(), 100e18);

        asset.mint(address(vault), 100e18);
        vm.prank(address(executorGateway));
        controller.settleAdapter(address(asyncAdapter), 25e18, 100e18, investInFlightIds, redeemInFlightIds);

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
        controller.processRedeemBatch(ids, 0);

        uint256 investInFlightId = vault.createInFlight(address(asyncAdapter), address(posToken), 25e18, 50e18, true);
        uint256[] memory investInFlightIds = new uint256[](1);
        investInFlightIds[0] = investInFlightId;

        uint256 redeemInFlightId = vault.createInFlight(address(syncAdapter), address(posToken), 50e18, 100e18, false);
        uint256[] memory redeemInFlightIds = new uint256[](1);
        redeemInFlightIds[0] = redeemInFlightId;
        assertEq(vault.investInFlightTotal(), 50e18);
        assertEq(vault.redeemInFlightTotal(), 100e18);

        address[] memory adapters = new address[](2);
        adapters[0] = address(asyncAdapter);
        adapters[1] = address(syncAdapter);
        uint256[] memory posAmounts = new uint256[](2);
        posAmounts[0] = 25e18;
        posAmounts[1] = 0;
        uint256[] memory assetAmounts = new uint256[](2);
        assetAmounts[0] = 0;
        assetAmounts[1] = 100e18;

        asset.mint(address(vault), 100e18);
        vm.prank(address(executorGateway));
        controller.settleAdapters(adapters, posAmounts, assetAmounts, investInFlightIds, redeemInFlightIds);

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
        uint256[] memory posAmounts = new uint256[](0);
        uint256[] memory assetAmounts = new uint256[](1);
        assetAmounts[0] = 1e18;

        vm.prank(address(executorGateway));
        vm.expectRevert(StrategyController.ClaimInputsLengthMismatch.selector);
        controller.settleAdapters(adapters, posAmounts, assetAmounts, new uint256[](0), new uint256[](0));
    }

    function test_RevertWhen_SettleAdaptersInvestInFlightAdapterNotIncluded() public {
        _registerTwoStrategies();
        uint256 badInFlightId = vault.createInFlight(address(asyncAdapter), address(posToken), 10e18, 10e18, true);
        uint256[] memory investInFlightIds = new uint256[](1);
        investInFlightIds[0] = badInFlightId;

        address[] memory adapters = new address[](1);
        adapters[0] = address(syncAdapter);
        uint256[] memory posAmounts = new uint256[](1);
        uint256[] memory assetAmounts = new uint256[](1);

        vm.prank(address(executorGateway));
        vm.expectRevert(abi.encodeWithSelector(StrategyController.InvalidInvestInFlight.selector, badInFlightId));
        controller.settleAdapters(adapters, posAmounts, assetAmounts, investInFlightIds, new uint256[](0));
    }

    function test_RevertWhen_SettleAdapterMissingRedeemInFlightIds() public {
        _registerSingleAsyncStrategy();
        vault.createInFlight(address(asyncAdapter), address(posToken), 50e18, 100e18, false);

        vm.prank(address(executorGateway));
        vm.expectRevert(
            abi.encodeWithSelector(StrategyController.RedeemInFlightIdsRequired.selector, address(asyncAdapter))
        );
        controller.settleAdapter(address(asyncAdapter), 0, 1, new uint256[](0), new uint256[](0));
    }

    function test_RevertWhen_SettleAdapterHasPendingRedeemInFlightWithoutIds() public {
        _registerSingleAsyncStrategy();
        vault.createInFlight(address(asyncAdapter), address(posToken), 50e18, 100e18, false);

        vm.prank(address(executorGateway));
        vm.expectRevert(
            abi.encodeWithSelector(StrategyController.RedeemInFlightIdsRequired.selector, address(asyncAdapter))
        );
        controller.settleAdapter(address(asyncAdapter), 0, 100e18, new uint256[](0), new uint256[](0));
    }
}
