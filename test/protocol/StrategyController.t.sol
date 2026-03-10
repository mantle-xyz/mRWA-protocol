// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IStrategyAdapter} from "../../src/interfaces/adapters/IStrategyAdapter.sol";
import {IControllerVault} from "../../src/interfaces/vault/IControllerVault.sol";
import {InFlightStatus, RequestStatus} from "../../src/interfaces/vault/types/VaultTypes.sol";
import {StrategyController} from "../../src/protocol/StrategyController.sol";

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

    function estimatePosAmount(uint256 assetAmount) external pure returns (uint256 positionAmount) {
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

    function claimToVault(address, uint256 amount) external pure returns (uint256 claimed) {
        return amount;
    }

    function setPaused(bool p) external {
        paused = p;
    }
}

contract MockControllerVault is IControllerVault {
    ERC20 public immutable token;

    uint256 public locked;
    uint256 public investInFlightTotal;
    uint256 public redeemInFlightTotal;
    uint256 public inFlightIdCursor;

    struct Req {
        uint256 estimatedAssets;
        uint256 settledAssets;
        RequestStatus status;
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
        InFlightStatus status;
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

    function setRequest(uint256 id, uint256 estimatedAssets, uint256 settledAssets, RequestStatus status) external {
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

    function approveToAdapter(address adapter, address approveToken, uint256 amount) external {
        ERC20(approveToken).approve(adapter, amount);
    }

    function updateRequestBatch(uint256[] calldata ids, RequestStatus newStatus) external {
        for (uint256 i = 0; i < ids.length; i++) {
            reqs[ids[i]].status = newStatus;
        }
    }

    function markRequestsReady(uint256[] calldata ids, uint256[] calldata settledAssets) external {
        for (uint256 i = 0; i < ids.length; i++) {
            reqs[ids[i]].settledAssets = settledAssets[i];
            reqs[ids[i]].status = RequestStatus.READY;
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
            status: InFlightStatus.PENDING
        });
        if (isInvest) {
            investInFlightTotal += usdcAmount;
        } else {
            redeemInFlightTotal += usdcAmount;
        }
    }

    function confirmInFlight(uint256 inFlightId, uint256 actualAmount) external {
        InFlight storage f = flights[inFlightId];
        f.settledAmount = actualAmount;
        f.status = InFlightStatus.CONFIRMED;
        if (f.isInvest && investInFlightTotal >= f.usdcAmount) {
            investInFlightTotal -= f.usdcAmount;
        }
        if (!f.isInvest && redeemInFlightTotal >= f.usdcAmount) {
            redeemInFlightTotal -= f.usdcAmount;
        }
    }

    function requests(uint256 requestId)
        external
        view
        returns (uint256, address, uint256, uint256, uint256, uint256, RequestStatus)
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
            InFlightStatus status
        )
    {
        InFlight memory f = flights[inFlightId];
        return (f.id, f.adapter, f.assetAddr, f.tokenAmount, f.usdcAmount, f.settledAmount, f.isInvest, f.timestamp, f.status);
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
            StrategyController.initialize, (address(vault), admin, manager, address(executorGateway), 1000, 200, 1 hours)
        );
        controller = StrategyController(address(new ERC1967Proxy(address(implementation), initData)));

        syncAdapter = new MockStrategyAdapter(address(asset), address(posToken));
        asyncAdapter = new MockStrategyAdapter(address(asset), address(posToken));
    }

    function _registerTwoStrategies() internal {
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 5000, 1, false, true, address(syncAdapter));
        controller.registerStrategy(address(asyncAdapter), 5000, 2, true, true, address(asyncAdapter));
        address[] memory ordered = new address[](2);
        ordered[0] = address(syncAdapter);
        ordered[1] = address(asyncAdapter);
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
        controller.registerStrategy(address(syncAdapter), 5000, 1, false, true, address(syncAdapter));
        vm.expectRevert();
        controller.registerStrategy(address(syncAdapter), 5000, 1, false, true, address(syncAdapter));
        vm.stopPrank();
    }

    function test_RevertWhen_SetStrategyOrderDuplicate() public {
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 10000, 1, false, true, address(syncAdapter));
        address[] memory ordered = new address[](2);
        ordered[0] = address(syncAdapter);
        ordered[1] = address(syncAdapter);
        vm.expectRevert();
        controller.setStrategyOrder(ordered);
        vm.stopPrank();
    }

    function test_RevertWhen_SetStrategyOrderWeightNot10000() public {
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 7000, 1, false, true, address(syncAdapter));
        address[] memory ordered = new address[](1);
        ordered[0] = address(syncAdapter);
        vm.expectRevert();
        controller.setStrategyOrder(ordered);
        vm.stopPrank();
    }

    function test_RevertWhen_SetStrategyOrderPriorityInvalid() public {
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 5000, 2, false, true, address(syncAdapter));
        controller.registerStrategy(address(asyncAdapter), 5000, 1, true, true, address(asyncAdapter));
        address[] memory ordered = new address[](2);
        ordered[0] = address(syncAdapter);
        ordered[1] = address(asyncAdapter);
        vm.expectRevert();
        controller.setStrategyOrder(ordered);
        vm.stopPrank();
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
        uint256[] memory inFlightIds = new uint256[](0);

        vm.prank(address(executorGateway));
        vm.expectRevert();
        controller.allocateAssetsBatch(ids, inFlightIds);
    }

    function test_RevertWhen_AllocateInsufficientCash() public {
        _registerTwoStrategies();
        uint256[] memory ids = new uint256[](1);
        ids[0] = 11;
        vault.setRequest(11, 100e18, 0, RequestStatus.PROCESSING);

        vm.prank(address(executorGateway));
        controller.processRedeemBatch(ids, 0);

        uint256[] memory inFlightIds = new uint256[](0);
        vm.prank(address(executorGateway));
        vm.expectRevert();
        controller.allocateAssetsBatch(ids, inFlightIds);
    }

    function test_AllocateSuccess_AndRevertOnReplayReady() public {
        _registerTwoStrategies();
        uint256[] memory ids = new uint256[](1);
        ids[0] = 21;
        vault.setRequest(21, 100e18, 0, RequestStatus.PROCESSING);
        asset.mint(address(vault), 100e18);

        vm.prank(address(executorGateway));
        controller.processRedeemBatch(ids, 0);

        uint256[] memory inFlightIds = new uint256[](0);
        vm.prank(address(executorGateway));
        controller.allocateAssetsBatch(ids, inFlightIds);

        vm.prank(address(executorGateway));
        vm.expectRevert();
        controller.allocateAssetsBatch(ids, inFlightIds);
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

    function test_RevertWhen_ClaimAdapterAssetsInvalidStrategy() public {
        vm.prank(address(executorGateway));
        vm.expectRevert(abi.encodeWithSelector(StrategyController.InvalidStrategy.selector, address(syncAdapter)));
        controller.claimAdapterAssets(address(syncAdapter), 1, 1);
    }
}
