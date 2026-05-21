// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategyAdapter} from "../../src/interfaces/adapters/IStrategyAdapter.sol";
import {IStrategyControllerExecutor} from "../../src/interfaces/strategy/IStrategyControllerExecutor.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

error MockDepositCustomError(uint256 amount);
error MockAsyncCustomError(uint256 amount);

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
    bool public failRetry;
    bool public failEstimate;
    bool public failDepositCustomError;
    bool public failAsyncCustomError;
    bool public depositReturnZero;

    uint256 public depositCount;
    uint256 public withdrawCount;
    uint256 public asyncCount;
    uint256 public claimCount;
    address public lastClaimToken;
    uint256 public lastClaimAmount;
    uint256 public sweepReturnAmount;
    uint256 public sweepReturnShortfall;
    bool public useSweepReturnAmount;
    bool public useSweepReturnShortfall;
    uint256 public retryCount;
    uint256 public lastRetryPosAmount;
    address public lastRetryReceiver;

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

    function setFailRetry(bool r) external {
        failRetry = r;
    }

    function setFailDepositCustomError(bool r) external {
        failDepositCustomError = r;
    }

    function setFailAsyncCustomError(bool r) external {
        failAsyncCustomError = r;
    }

    function setDepositReturnZero(bool z) external {
        depositReturnZero = z;
    }

    function setSweepReturnAmount(uint256 amount_) external {
        sweepReturnAmount = amount_;
        useSweepReturnAmount = true;
        useSweepReturnShortfall = false;
    }

    function setSweepReturnShortfall(uint256 shortfall_) external {
        sweepReturnShortfall = shortfall_;
        useSweepReturnShortfall = true;
        useSweepReturnAmount = false;
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
        return (assetAmount > 0, assetAmount, 0);
    }

    function previewRedeem(uint256 assetAmount)
        external
        pure
        returns (bool ok, uint256 executableAssetAmount, uint256 expectedPosAmount)
    {
        return (assetAmount > 0, assetAmount, 0);
    }

    function vault() external pure returns (address) {
        return address(0);
    }

    function totalValue() external view returns (uint256) {
        return mockedTotalValue;
    }

    function deposit(uint256 amount, address) external returns (uint256 sharesOrPos) {
        if (failDepositCustomError) revert MockDepositCustomError(amount);
        if (failDeposit) revert("DEPOSIT_FAIL");
        depositCount++;
        return depositReturnZero ? 0 : amount;
    }

    function withdrawSync(uint256 amount, address) external returns (uint256 actualStable) {
        if (failWithdraw) revert("WITHDRAW_FAIL");
        withdrawCount++;
        return amount;
    }

    function requestRedeemAsync(uint256 amount, address) external {
        if (failAsyncCustomError) revert MockAsyncCustomError(amount);
        if (failAsync) revert("ASYNC_FAIL");
        asyncCount++;
    }

    function retryRedeemAsync(uint256 retryPosAmount, address receiver) external {
        if (failRetry) revert("RETRY_FAIL");
        retryCount++;
        lastRetryPosAmount = retryPosAmount;
        lastRetryReceiver = receiver;
    }

    function sweepToVault(address token, uint256 amount) external returns (uint256 claimed) {
        claimCount++;
        lastClaimToken = token;
        lastClaimAmount = amount;
        if (useSweepReturnAmount) {
            return sweepReturnAmount;
        }
        if (useSweepReturnShortfall) {
            return amount > sweepReturnShortfall ? amount - sweepReturnShortfall : 0;
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
    uint256 public requestIdCursor;
    uint256 public pendingRequestCount;
    mapping(address => uint256) public investInFlightByAdapter;
    mapping(address => uint256) public redeemInFlightByAdapter;
    mapping(address => bool) public isAdapterRegistry;
    address[] public adapterList;

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
        uint256 stableAmount;
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
        IMantleYieldVault.RequestStatus prev = reqs[id].status;
        if (prev == IMantleYieldVault.RequestStatus.PENDING && pendingRequestCount > 0) {
            pendingRequestCount--;
        }
        if (status == IMantleYieldVault.RequestStatus.PENDING) {
            pendingRequestCount++;
        }
        reqs[id] = Req({
            shares: estimatedAssets, estimatedAssets: estimatedAssets, settledAssets: settledAssets, status: status
        });
        if (id >= requestIdCursor) {
            requestIdCursor = id + 1;
        }
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

    function adapterRedeemInFlightStable(address adapter) external view returns (uint256) {
        return redeemInFlightByAdapter[adapter];
    }

    function getFreeCash() external view returns (uint256) {
        uint256 totalCash = token.balanceOf(address(this));
        return totalCash > locked ? totalCash - locked : 0;
    }

    function getCashDeficit() external view returns (uint256) {
        uint256 totalCash = token.balanceOf(address(this));
        return locked > totalCash ? locked - totalCash : 0;
    }

    function totalAssets() external view returns (uint256) {
        uint256 total = token.balanceOf(address(this)) + investInFlightTotal + redeemInFlightTotal;
        // Mock: adapter totalValue is tracked via investInFlightByAdapter as proxy for posToken value.
        // For simplicity, we don't sum adapter.totalValue() here — tests that need posToken value
        // should use mockedTotalAssets override instead.
        if (mockedTotalAssets > 0) return mockedTotalAssets;
        return total > locked ? total - locked : 0;
    }

    uint256 public mockedTotalAssets;

    function setMockedTotalAssets(uint256 v) external {
        mockedTotalAssets = v;
    }

    function approveToAdapter(address adapter, address approveToken, uint256 amount) external {
        ERC20(approveToken).approve(adapter, amount);
    }

    function isAdapter(address adapter) external view returns (bool) {
        return isAdapterRegistry[adapter];
    }

    function getAdapters() external view returns (address[] memory) {
        return adapterList;
    }

    function registerAdapter(address adapter) external {
        adapterList.push(adapter);
        isAdapterRegistry[adapter] = true;
    }

    function removeAdapter(address adapter) external {
        require(investInFlightByAdapter[adapter] == 0 && redeemInFlightByAdapter[adapter] == 0, "HAS_IN_FLIGHT");
        isAdapterRegistry[adapter] = false;
        uint256 len = adapterList.length;
        for (uint256 i = 0; i < len; i++) {
            if (adapterList[i] == adapter) {
                adapterList[i] = adapterList[len - 1];
                adapterList.pop();
                break;
            }
        }
    }

    function updateRequestBatch(uint256[] calldata ids, IMantleYieldVault.RequestStatus newStatus) external {
        for (uint256 i = 0; i < ids.length; i++) {
            IMantleYieldVault.RequestStatus current = reqs[ids[i]].status;
            require(
                current != IMantleYieldVault.RequestStatus.NONE && uint8(newStatus) > uint8(current),
                "INVALID_STATUS_TRANSITION"
            );
            if (current == IMantleYieldVault.RequestStatus.PENDING && pendingRequestCount > 0) {
                pendingRequestCount--;
            }
            reqs[ids[i]].status = newStatus;
        }
    }

    function markRequestsDone(uint256[] calldata ids, uint256[] calldata settledAssets) external {
        require(ids.length == settledAssets.length, "LENGTH_MISMATCH");
        uint256 physicalCash = token.balanceOf(address(this));
        for (uint256 i = 0; i < ids.length; i++) {
            Req storage req = reqs[ids[i]];
            require(req.status == IMantleYieldVault.RequestStatus.PROCESSING, "INVALID_STATE");
            require(settledAssets[i] != 0, "ZERO_AMOUNT");
            require(physicalCash >= settledAssets[i], "INSUFFICIENT_CASH");
            req.settledAssets = settledAssets[i];
            req.status = IMantleYieldVault.RequestStatus.DONE;
            physicalCash -= settledAssets[i];
        }
    }

    function createInFlight(
        address adapter,
        address assetAddr,
        uint256 tokenAmount,
        uint256 stableAmount,
        bool isInvest
    ) external returns (uint256 inFlightId) {
        inFlightId = ++inFlightIdCursor;
        flights[inFlightId] = InFlight({
            id: inFlightId,
            adapter: adapter,
            assetAddr: assetAddr,
            tokenAmount: tokenAmount,
            stableAmount: stableAmount,
            settledAmount: 0,
            isInvest: isInvest,
            timestamp: block.timestamp,
            status: IMantleYieldVault.InFlightStatus.PENDING
        });
        if (isInvest) {
            investInFlightTotal += stableAmount;
            investInFlightByAdapter[adapter] += tokenAmount;
        } else {
            redeemInFlightTotal += stableAmount;
            redeemInFlightByAdapter[adapter] += stableAmount;
        }
    }

    function confirmInFlight(uint256 inFlightId, uint256 actualAmount, bool) external {
        InFlight storage f = flights[inFlightId];
        f.settledAmount = actualAmount;
        f.status = IMantleYieldVault.InFlightStatus.CONFIRMED;
        if (f.isInvest && investInFlightTotal >= f.stableAmount) {
            investInFlightTotal -= f.stableAmount;
            if (investInFlightByAdapter[f.adapter] >= f.tokenAmount) {
                investInFlightByAdapter[f.adapter] -= f.tokenAmount;
            }
        }
        if (!f.isInvest && redeemInFlightTotal >= f.stableAmount) {
            redeemInFlightTotal -= f.stableAmount;
            if (redeemInFlightByAdapter[f.adapter] >= f.stableAmount) {
                redeemInFlightByAdapter[f.adapter] -= f.stableAmount;
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

    function nextRequestId() external view returns (uint256) {
        return requestIdCursor == 0 ? 1 : requestIdCursor;
    }

    function inFlightRecords(uint256 inFlightId)
        external
        view
        returns (
            uint256 id,
            address adapter,
            address assetAddr,
            uint256 tokenAmount,
            uint256 stableAmount,
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
            f.stableAmount,
            f.settledAmount,
            f.isInvest,
            f.timestamp,
            f.status
        );
    }
}

contract DummyExecutor {}

contract StrategyControllerUnitTest is Test {
    event InvestSkipped(address indexed adapter, uint256 amountAsset, bytes revertData);
    event DivestSkipped(address indexed adapter, uint256 requestedAsset, bytes revertData);
    event DivestCoverageRead(address indexed adapter, uint256 remaining, uint256 settledValue, uint256 requestAsset);

    MockAsset internal asset;
    MockAsset internal posToken;
    MockAsset internal asyncPosToken;
    MockControllerVault internal vault;
    StrategyController internal controller;
    DummyExecutor internal executorGateway;

    MockStrategyAdapter internal syncAdapter;
    MockStrategyAdapter internal asyncAdapter;

    address internal admin = makeAddr("admin");
    address internal manager = makeAddr("manager");

    bytes32 internal constant INVEST_SKIPPED_EVENT_SIG = keccak256("InvestSkipped(address,uint256,bytes)");
    bytes32 internal constant DIVEST_SKIPPED_EVENT_SIG = keccak256("DivestSkipped(address,uint256,bytes)");

    function setUp() public {
        asset = new MockAsset();
        posToken = new MockAsset();
        asyncPosToken = new MockAsset();
        vault = new MockControllerVault(address(asset));
        executorGateway = new DummyExecutor();

        StrategyController implementation = new StrategyController();
        bytes memory initData = abi.encodeCall(
            StrategyController.initialize,
            (address(vault), manager, address(executorGateway), manager, 1000, 200, 1 hours)
        );
        controller = StrategyController(address(new ERC1967Proxy(address(implementation), initData)));

        syncAdapter = new MockStrategyAdapter(address(asset), address(posToken));
        asyncAdapter = new MockStrategyAdapter(address(asset), address(asyncPosToken));
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

    function _investSettlement(
        uint256[] memory inFlightIds,
        uint256[] memory settledPosAmounts,
        uint256[] memory refundAssetAmounts
    ) internal pure returns (IStrategyControllerExecutor.InvestSettlementInput memory invest) {
        invest = IStrategyControllerExecutor.InvestSettlementInput({
            inFlightIds: inFlightIds, settledPosAmounts: settledPosAmounts, refundAssetAmounts: refundAssetAmounts
        });
    }

    function _redeemSettlement(uint256[] memory inFlightIds, uint256[] memory settledAssetAmounts)
        internal
        pure
        returns (IStrategyControllerExecutor.RedeemSettlementInput memory redeem)
    {
        redeem = IStrategyControllerExecutor.RedeemSettlementInput({
            inFlightIds: inFlightIds, settledAssetAmounts: settledAssetAmounts
        });
    }

    function _toSingletonArray(uint256 value) internal pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = value;
    }

    function _errorData(string memory reason) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(bytes4(keccak256("Error(string)")), reason);
    }

    function _customErrorData(bytes4 selector, uint256 value) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(selector, value);
    }

    function _assertSkippedLog(
        Vm.Log[] memory logs,
        bytes32 eventSig,
        address expectedAdapter,
        uint256 expectedAmount,
        bytes memory expectedRevertData
    ) internal pure {
        bool found;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 0 || logs[i].topics[0] != eventSig) {
                continue;
            }

            address loggedAdapter = address(uint160(uint256(logs[i].topics[1])));
            (uint256 loggedAmount, bytes memory loggedRevertData) = abi.decode(logs[i].data, (uint256, bytes));

            assertEq(loggedAdapter, expectedAdapter);
            assertEq(loggedAmount, expectedAmount);
            assertEq(loggedRevertData, expectedRevertData);
            found = true;
            break;
        }

        assertTrue(found, "expected skipped event not found");
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

    function test_RevertWhen_RegisterStrategyDuplicatePosToken() public {
        MockStrategyAdapter duplicatePosTokenAdapter = new MockStrategyAdapter(address(asset), address(posToken));

        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 5000, 1, false);
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyController.Controller__DuplicateStrategyPosToken.selector,
                address(posToken),
                address(syncAdapter),
                address(duplicatePosTokenAdapter)
            )
        );
        controller.registerStrategy(address(duplicatePosTokenAdapter), 5000, 2, true);
        vm.stopPrank();
    }

    function test_RevertWhen_ActivateStrategyDuplicatePosToken() public {
        MockStrategyAdapter duplicatePosTokenAdapter = new MockStrategyAdapter(address(asset), address(posToken));

        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 5000, 1, false);
        controller.activateStrategy(address(syncAdapter));
        controller.deactivateStrategy(address(syncAdapter));

        controller.registerStrategy(address(duplicatePosTokenAdapter), 5000, 2, true);

        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyController.Controller__DuplicateStrategyPosToken.selector,
                address(posToken),
                address(duplicatePosTokenAdapter),
                address(syncAdapter)
            )
        );
        controller.activateStrategy(address(syncAdapter));
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
        vm.expectRevert(StrategyController.Controller__UpdateStrategiesLengthMismatch.selector);
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
            abi.encodeWithSelector(
                StrategyController.Controller__DuplicateStrategyUpdate.selector, address(syncAdapter)
            )
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
        vm.expectRevert(
            abi.encodeWithSelector(StrategyController.Controller__InvalidPriorityOrder.selector, address(asyncAdapter))
        );
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
        vm.expectRevert(StrategyController.Controller__UpdateStrategiesLengthMismatch.selector);
        controller.updateStrategiesAndOrder(adapters, weights, priorities, asyncFlags, ordered);
    }

    function test_RevertWhen_RebalanceBeforeCooldown() public {
        _registerTwoStrategies();
        asset.mint(address(vault), 1_000e18);

        vm.warp(2 hours);
        vm.prank(address(executorGateway));
        controller.rebalance();

        vm.prank(address(executorGateway));
        vm.expectRevert(StrategyController.Controller__CooldownNotElapsed.selector);
        controller.rebalance();
    }

    function test_GetRebalanceState_ReturnsExpectedAccountingState() public {
        _registerSingleSyncStrategy();
        syncAdapter.setTotalValue(2_000e18);
        asset.mint(address(vault), 1_000e18);
        vault.setLocked(200e18);
        vault.createInFlight(address(syncAdapter), address(posToken), 10e18, 300e18, true);
        vault.createInFlight(address(syncAdapter), address(posToken), 10e18, 100e18, false);

        // netAssets = vault.totalAssets() = (cash + investIF + redeemIF + posTokenValue) - floatingLocked
        // Mock doesn't sum adapter totalValue, so we set it manually:
        // (1000 + 300 + 100 + 2000) - 200 = 3200
        vault.setMockedTotalAssets(3_200e18);

        (
            uint256 totalCash,
            uint256 freeCash,
            uint256 idealCash,
            uint256 netAssets,
            uint256 targetCash,
            uint256 threshold,
        ) = controller.getRebalanceState();

        assertEq(totalCash, 1_000e18);
        assertEq(freeCash, 800e18);
        assertEq(idealCash, 900e18);
        assertEq(netAssets, 3_200e18);
        assertEq(targetCash, 320e18);
        assertEq(threshold, 64e18);
    }

    function test_GetRebalanceState_AddsCashDeficitToTargetCash() public {
        asset.mint(address(vault), 100e18);
        vault.setLocked(150e18);

        (
            uint256 totalCash,
            uint256 freeCash,
            uint256 idealCash,
            uint256 netAssets,
            uint256 targetCash,
            uint256 threshold,
        ) = controller.getRebalanceState();

        assertEq(totalCash, 100e18);
        assertEq(freeCash, 0);
        assertEq(idealCash, 0);
        // netAssets = vault.totalAssets() = max((100-150), 0) = 0
        assertEq(netAssets, 0);
        // targetCash = 0*10% + cashDeficit(50) = 50
        assertEq(targetCash, 50e18);
        assertEq(threshold, 0);
    }

    function test_GetRebalanceState_IdealCashIncludesRedeemInFlight() public {
        _registerSingleAsyncStrategy();
        asset.mint(address(vault), 100e18);
        vault.createInFlight(address(asyncAdapter), address(posToken), 30e18, 300e18, false);
        vault.setLocked(150e18);

        (uint256 totalCash, uint256 freeCash, uint256 idealCash,,,,) = controller.getRebalanceState();

        assertEq(totalCash, 100e18);
        assertEq(freeCash, 0);
        assertEq(idealCash, 300e18);
    }

    function test_PreviewRebalance_ReturnsNoneWithinThresholdBand() public {
        // freeCash=100 needs to be within [targetCash-threshold, targetCash+threshold]
        // Set netAssets=1000 so targetCash=100, threshold=20 → band [80,120], freeCash=100 → NONE
        asset.mint(address(vault), 100e18);
        vault.setMockedTotalAssets(1_000e18);

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

    function test_PreviewRebalance_InvestAmountCapsToFreeCash() public {
        // Invest uses idealCash = freeCash + totalRedeemInFlight for surplus detection,
        // but caps the actual invest amount to freeCash (in-flight hasn't arrived yet).
        _registerSingleAsyncStrategy();
        asset.mint(address(vault), 1_000e18);
        vault.createInFlight(address(asyncAdapter), address(posToken), 50e18, 500e18, false);

        vm.warp(2 hours);
        (bool shouldRebalance, uint8 action, uint256 amount) = controller.previewRebalance();

        // netAssets = 1000 + 500 (redeemInFlight) + 0 (adapter) - 0 (locked) = 1500
        // targetCash = 1500 * 10% + 0 = 150, threshold = 30
        // freeCash = 1000, idealCash = 1500
        // surplus = idealCash - target = 1350, amount = min(1350, freeCash=1000) = 1000
        assertTrue(shouldRebalance);
        assertEq(action, controller.REBALANCE_ACTION_INVEST());
        assertEq(amount, 1_000e18);
    }

    function test_PreviewRebalance_ReturnsDivestDecision() public {
        _registerSingleSyncStrategy();
        syncAdapter.setTotalValue(3_000e18);
        asset.mint(address(vault), 1_000e18);
        vault.setLocked(900e18);
        // netAssets = (1000+0+0+3000)-900 = 3100
        vault.setMockedTotalAssets(3_100e18);

        vm.warp(2 hours);
        (bool shouldRebalance, uint8 action, uint256 amount) = controller.previewRebalance();

        assertTrue(shouldRebalance);
        assertEq(action, controller.REBALANCE_ACTION_DIVEST());
        // targetCash = 3100*10%+0 = 310, idealCash = 100, divest = 310-100 = 210
        assertEq(amount, 210e18);
    }

    function test_PreviewRebalance_ReturnsDivestDecision_WhenCashDeficitExists() public {
        asset.mint(address(vault), 100e18);
        vault.setLocked(150e18);

        vm.warp(2 hours);
        (bool shouldRebalance, uint8 action, uint256 amount) = controller.previewRebalance();

        assertTrue(shouldRebalance);
        assertEq(action, controller.REBALANCE_ACTION_DIVEST());
        // netAssets=0, targetCash=0+deficit(50)=50, idealCash=0, divest=50
        assertEq(amount, 50e18);
    }

    function test_PreviewRebalance_BlocksDivestWhenOlderPendingRequestExists() public {
        _registerSingleSyncStrategy();

        vm.prank(manager);
        controller.setRiskParams(1000, 0, 1 hours);

        // Older request still pending, latest request already moved to processing.
        // latest-only pending checks will miss this case.
        vault.setRequest(10, 100e18, 0, IMantleYieldVault.RequestStatus.PENDING);
        vault.setRequest(11, 100e18, 0, IMantleYieldVault.RequestStatus.PROCESSING);
        vault.setMockedTotalAssets(1_000e18);

        vm.warp(2 hours);
        (bool shouldRebalance, uint8 action, uint256 amount) = controller.previewRebalance();

        assertFalse(shouldRebalance);
        assertEq(action, controller.REBALANCE_ACTION_NONE());
        assertEq(amount, 0);
    }

    function test_PreviewRebalance_IgnoresDivestWhenRedeemInFlightAlreadyCoversCashDeficit() public {
        _registerSingleAsyncStrategy();

        vm.prank(manager);
        controller.setRiskParams(0, 0, 1 hours);

        vault.createInFlight(address(asyncAdapter), address(posToken), 50e18, 500e18, false);
        vault.setLocked(500e18);

        vm.warp(2 hours);
        (bool shouldRebalance, uint8 action, uint256 amount) = controller.previewRebalance();

        assertFalse(shouldRebalance);
        assertEq(action, controller.REBALANCE_ACTION_NONE());
        assertEq(amount, 0);
    }

    function test_PreviewRebalance_UsesIdealCashToReduceDivestAmount() public {
        _registerSingleAsyncStrategy();

        vm.prank(manager);
        controller.setRiskParams(0, 0, 1 hours);

        asset.mint(address(vault), 100e18);
        vault.createInFlight(address(asyncAdapter), address(posToken), 30e18, 300e18, false);
        vault.setLocked(500e18);

        vm.warp(2 hours);
        (bool shouldRebalance, uint8 action, uint256 amount) = controller.previewRebalance();

        assertTrue(shouldRebalance);
        assertEq(action, controller.REBALANCE_ACTION_DIVEST());
        assertEq(amount, 100e18);
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

    function test_RebalanceInvest_EmitsInvestSkippedWithRevertData_OnDepositRevert() public {
        _registerSingleSyncStrategy();
        asset.mint(address(vault), 1_000e18);
        syncAdapter.setFailFlags(true, false, false);

        vm.recordLogs();
        vm.warp(2 hours);
        vm.prank(address(executorGateway));
        controller.rebalance();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertSkippedLog(logs, INVEST_SKIPPED_EVENT_SIG, address(syncAdapter), 900e18, _errorData("DEPOSIT_FAIL"));
    }

    function test_RebalanceInvest_EmitsInvestSkippedWithRevertData_OnDepositCustomError() public {
        _registerSingleSyncStrategy();
        asset.mint(address(vault), 1_000e18);
        syncAdapter.setFailDepositCustomError(true);

        vm.recordLogs();
        vm.warp(2 hours);
        vm.prank(address(executorGateway));
        controller.rebalance();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertSkippedLog(
            logs,
            INVEST_SKIPPED_EVENT_SIG,
            address(syncAdapter),
            900e18,
            _customErrorData(MockDepositCustomError.selector, 900e18)
        );
    }

    function test_RebalanceDivestPath_ExecutesSyncAndAsync() public {
        _registerTwoStrategies();
        syncAdapter.setTotalValue(500e18);
        asyncAdapter.setTotalValue(500e18);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vault.setRequest(1, 700e18, 0, IMantleYieldVault.RequestStatus.PENDING);
        vault.setLocked(700e18); // cashDeficit = 700 (no physical balance)
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
        // Sync adapter fails, async succeeds. adapter pool total = 1000 >= shortfall 700,
        // so remaining 200 is treated as "best-effort residual" (not true insufficiency) → no revert.
        // Operator must pass adjusted settledAssets at finalize to absorb the shortfall.
        _registerTwoStrategies();
        syncAdapter.setTotalValue(500e18);
        asyncAdapter.setTotalValue(500e18);
        syncAdapter.setFailFlags(false, true, false);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vault.setRequest(1, 700e18, 0, IMantleYieldVault.RequestStatus.PENDING);
        vault.setLocked(700e18);
        vm.prank(address(executorGateway));
        controller.processRedeemBatch(ids);

        assertEq(syncAdapter.withdrawCount(), 0);
        assertEq(asyncAdapter.asyncCount(), 1);
    }

    function test_ProcessRedeemBatch_EmitsDivestSkipped_OnAsyncRedeemRevert() public {
        // Adapter pool = 700 (>= shortfall) but async call reverts → soft skip.
        // Request still advances to PROCESSING; finalize waits for cash via subsequent
        // pRB aggregation, rebalance, or deposits.
        _registerSingleAsyncStrategy();
        asyncAdapter.setTotalValue(700e18);
        asyncAdapter.setFailFlags(false, false, true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vault.setRequest(1, 700e18, 0, IMantleYieldVault.RequestStatus.PENDING);
        vault.setLocked(700e18);

        vm.recordLogs();
        vm.prank(address(executorGateway));
        controller.processRedeemBatch(ids);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertSkippedLog(logs, DIVEST_SKIPPED_EVENT_SIG, address(asyncAdapter), 700e18, _errorData("ASYNC_FAIL"));
    }

    function test_ProcessRedeemBatch_EmitsDivestSkipped_OnAsyncRedeemCustomError() public {
        _registerSingleAsyncStrategy();
        asyncAdapter.setTotalValue(700e18);
        asyncAdapter.setFailAsyncCustomError(true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vault.setRequest(1, 700e18, 0, IMantleYieldVault.RequestStatus.PENDING);
        vault.setLocked(700e18);

        vm.recordLogs();
        vm.prank(address(executorGateway));
        controller.processRedeemBatch(ids);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertSkippedLog(
            logs,
            DIVEST_SKIPPED_EVENT_SIG,
            address(asyncAdapter),
            700e18,
            _customErrorData(MockAsyncCustomError.selector, 700e18)
        );
    }

    function test_ProcessRedeemBatch_RevertsWhenAdapterPoolInsufficient() public {
        // adapter pool = 50 < shortfall 100 → true insufficiency → revert DivestInsufficient.
        _registerSingleAsyncStrategy();
        asyncAdapter.setTotalValue(50e18);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vault.setRequest(1, 100e18, 0, IMantleYieldVault.RequestStatus.PENDING);
        vault.setLocked(100e18);

        vm.prank(address(executorGateway));
        vm.expectRevert(
            abi.encodeWithSelector(StrategyController.Controller__DivestInsufficient.selector, 100e18, 50e18)
        );
        controller.processRedeemBatch(ids);
    }

    function test_RevertWhen_ProcessRedeemBatchIdsNotSorted() public {
        _registerTwoStrategies();
        uint256[] memory ids = new uint256[](2);
        ids[0] = 2;
        ids[1] = 1;

        vm.prank(address(executorGateway));
        vm.expectRevert(StrategyController.Controller__IdsNotSorted.selector);
        controller.processRedeemBatch(ids);
    }

    function test_RevertWhen_ProcessRedeemBatchReplay() public {
        _registerTwoStrategies();
        vault.setRequest(1, 100e18, 0, IMantleYieldVault.RequestStatus.PENDING);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;

        vm.prank(address(executorGateway));
        controller.processRedeemBatch(ids);

        // Second call reverts: vault enforces strictly monotonic status (PROCESSING → PROCESSING forbidden)
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
        vault.setRequest(11, 100e18, 0, IMantleYieldVault.RequestStatus.PENDING);

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
        vault.setRequest(21, 100e18, 0, IMantleYieldVault.RequestStatus.PENDING);
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
        vault.setRequest(22, 100e18, 0, IMantleYieldVault.RequestStatus.PENDING);
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
        (,,,,, uint256 settledAssets,, IMantleYieldVault.RequestStatus reqStatus) = vault.requests(22);
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
        vm.expectRevert(StrategyController.Controller__IdsNotSorted.selector);
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
        uint256[] memory investSettledPosAmounts = new uint256[](1);
        investSettledPosAmounts[0] = 10e18;
        uint256[] memory investRefundAssetAmounts = new uint256[](1);
        investRefundAssetAmounts[0] = 0;

        vm.prank(address(executorGateway));
        controller.settleAdapter(
            address(asyncAdapter),
            _investSettlement(investInFlightIds, investSettledPosAmounts, investRefundAssetAmounts),
            _redeemSettlement(new uint256[](0), new uint256[](0))
        );

        (,,,,,, bool isInvest,, IMantleYieldVault.InFlightStatus status) = vault.inFlightRecords(inFlightId);
        assertTrue(isInvest);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(asyncAdapter.claimCount(), 1);
        assertEq(asyncAdapter.lastClaimToken(), address(asyncPosToken));
        assertEq(asyncAdapter.lastClaimAmount(), 10e18);
        assertEq(vault.investInFlightTotal(), 0);
        assertEq(vault.investInFlightByAdapter(address(asyncAdapter)), 0);
    }

    function test_SettleAdapter_InvestFlow_UsesClaimedAsActualSettledAmount() public {
        _registerSingleAsyncStrategy();
        uint256 inFlightId = vault.createInFlight(address(asyncAdapter), address(posToken), 100e18, 100e18, true);
        uint256[] memory investInFlightIds = new uint256[](1);
        investInFlightIds[0] = inFlightId;
        uint256[] memory investSettledPosAmounts = new uint256[](1);
        investSettledPosAmounts[0] = 99e18;
        uint256[] memory investRefundAssetAmounts = new uint256[](1);
        investRefundAssetAmounts[0] = 0;
        asyncAdapter.setSweepReturnAmount(99e18);

        vm.prank(address(executorGateway));
        controller.settleAdapter(
            address(asyncAdapter),
            _investSettlement(investInFlightIds, investSettledPosAmounts, investRefundAssetAmounts),
            _redeemSettlement(new uint256[](0), new uint256[](0))
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
        uint256[] memory investSettledPosAmounts = new uint256[](1);
        investSettledPosAmounts[0] = 0;
        uint256[] memory investRefundAssetAmounts = new uint256[](1);
        investRefundAssetAmounts[0] = 0;

        vm.prank(address(executorGateway));
        controller.settleAdapter(
            address(asyncAdapter),
            _investSettlement(investInFlightIds, investSettledPosAmounts, investRefundAssetAmounts),
            _redeemSettlement(new uint256[](0), new uint256[](0))
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
        uint256[] memory investSettledPosAmounts = new uint256[](1);
        investSettledPosAmounts[0] = 10e18;
        uint256[] memory investRefundAssetAmounts = new uint256[](1);
        investRefundAssetAmounts[0] = 0;

        vm.prank(address(executorGateway));
        vm.expectRevert(
            abi.encodeWithSelector(StrategyController.Controller__InvalidInvestInFlight.selector, inFlightId)
        );
        controller.settleAdapter(
            address(asyncAdapter),
            _investSettlement(investInFlightIds, investSettledPosAmounts, investRefundAssetAmounts),
            _redeemSettlement(new uint256[](0), new uint256[](0))
        );
    }

    function test_RevertWhen_SettleAdapterInvalidStrategy() public {
        vm.prank(address(executorGateway));
        vm.expectRevert(
            abi.encodeWithSelector(StrategyController.Controller__InvalidStrategy.selector, address(syncAdapter))
        );
        controller.settleAdapter(
            address(syncAdapter),
            _investSettlement(new uint256[](0), new uint256[](0), new uint256[](0)),
            _redeemSettlement(new uint256[](0), new uint256[](0))
        );
    }

    function test_RevertWhen_SettleAdapterMissingInvestInFlightIds() public {
        _registerSingleAsyncStrategy();
        vault.createInFlight(address(asyncAdapter), address(posToken), 10e18, 10e18, true);
        uint256[] memory investSettledPosAmounts = new uint256[](1);
        investSettledPosAmounts[0] = 1e18;
        uint256[] memory investRefundAssetAmounts = new uint256[](1);
        investRefundAssetAmounts[0] = 0;

        vm.prank(address(executorGateway));
        vm.expectRevert(StrategyController.Controller__SettleAmountsLengthMismatch.selector);
        controller.settleAdapter(
            address(asyncAdapter),
            _investSettlement(new uint256[](0), investSettledPosAmounts, investRefundAssetAmounts),
            _redeemSettlement(new uint256[](0), new uint256[](0))
        );
    }

    function test_RevertWhen_SettleAdapterInvestClaimedZeroWithProvidedIds() public {
        _registerSingleAsyncStrategy();
        uint256 inFlightId = vault.createInFlight(address(asyncAdapter), address(posToken), 10e18, 10e18, true);
        uint256[] memory investInFlightIds = new uint256[](1);
        investInFlightIds[0] = inFlightId;
        uint256[] memory investSettledPosAmounts = new uint256[](1);
        investSettledPosAmounts[0] = 10e18;
        uint256[] memory investRefundAssetAmounts = new uint256[](1);
        investRefundAssetAmounts[0] = 0;
        asyncAdapter.setSweepReturnAmount(0);

        vm.prank(address(executorGateway));
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyController.Controller__InvestSweepAmountMismatch.selector, address(asyncAdapter), 10e18, 0
            )
        );
        controller.settleAdapter(
            address(asyncAdapter),
            _investSettlement(investInFlightIds, investSettledPosAmounts, investRefundAssetAmounts),
            _redeemSettlement(new uint256[](0), new uint256[](0))
        );
    }

    function test_SettleAdapterInvest_AllowsOneWeiPositionSweepShortfallPerItem() public {
        _registerSingleAsyncStrategy();
        uint256 inFlightId = vault.createInFlight(address(asyncAdapter), address(posToken), 10e18, 10e18, true);
        uint256[] memory investInFlightIds = new uint256[](1);
        investInFlightIds[0] = inFlightId;
        uint256[] memory investSettledPosAmounts = new uint256[](1);
        investSettledPosAmounts[0] = 10e18;
        uint256[] memory investRefundAssetAmounts = new uint256[](1);
        investRefundAssetAmounts[0] = 0;
        asyncAdapter.setSweepReturnShortfall(1);

        vm.prank(address(executorGateway));
        controller.settleAdapter(
            address(asyncAdapter),
            _investSettlement(investInFlightIds, investSettledPosAmounts, investRefundAssetAmounts),
            _redeemSettlement(new uint256[](0), new uint256[](0))
        );

        (,,,,, uint256 settledAmount, bool isInvest,, IMantleYieldVault.InFlightStatus status) =
            vault.inFlightRecords(inFlightId);
        assertTrue(isInvest);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(settledAmount, 10e18);
    }

    function test_SettleAdapterInvest_AllowsOneWeiRefundSweepShortfallPerItem() public {
        _registerSingleAsyncStrategy();
        uint256 inFlightId = vault.createInFlight(address(asyncAdapter), address(posToken), 10e18, 10e18, true);
        uint256[] memory investInFlightIds = new uint256[](1);
        investInFlightIds[0] = inFlightId;
        uint256[] memory investSettledPosAmounts = new uint256[](1);
        investSettledPosAmounts[0] = 0;
        uint256[] memory investRefundAssetAmounts = new uint256[](1);
        investRefundAssetAmounts[0] = 10e18;
        asyncAdapter.setSweepReturnShortfall(1);

        vm.prank(address(executorGateway));
        controller.settleAdapter(
            address(asyncAdapter),
            _investSettlement(investInFlightIds, investSettledPosAmounts, investRefundAssetAmounts),
            _redeemSettlement(new uint256[](0), new uint256[](0))
        );

        (,,,,, uint256 settledAmount, bool isInvest,, IMantleYieldVault.InFlightStatus status) =
            vault.inFlightRecords(inFlightId);
        assertTrue(isInvest);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(settledAmount, 0);
    }

    function test_RevertWhen_SettleAdapterInvestPositionSweepShortfallExceedsPerItemTolerance() public {
        _registerSingleAsyncStrategy();
        uint256 inFlightId = vault.createInFlight(address(asyncAdapter), address(posToken), 10e18, 10e18, true);
        uint256[] memory investInFlightIds = new uint256[](1);
        investInFlightIds[0] = inFlightId;
        uint256[] memory investSettledPosAmounts = new uint256[](1);
        investSettledPosAmounts[0] = 10e18;
        uint256[] memory investRefundAssetAmounts = new uint256[](1);
        investRefundAssetAmounts[0] = 0;
        asyncAdapter.setSweepReturnShortfall(2);

        vm.prank(address(executorGateway));
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyController.Controller__InvestSweepAmountMismatch.selector,
                address(asyncAdapter),
                10e18,
                10e18 - 2
            )
        );
        controller.settleAdapter(
            address(asyncAdapter),
            _investSettlement(investInFlightIds, investSettledPosAmounts, investRefundAssetAmounts),
            _redeemSettlement(new uint256[](0), new uint256[](0))
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
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyController.Controller__InvestPosAmountUnavailable.selector, address(asyncAdapter), 900e18
            )
        );
        controller.rebalance();
    }

    function test_RebalanceInvest_DepositReturnsZeroButPreviewReturnsZeroPos_Reverts() public {
        _registerSingleAsyncStrategy();
        asyncAdapter.setDepositReturnZero(true);
        asset.mint(address(vault), 1_000e18);

        vm.warp(2 hours);
        vm.prank(address(executorGateway));
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyController.Controller__InvestPosAmountUnavailable.selector, address(asyncAdapter), 900e18
            )
        );
        controller.rebalance();
    }

    function test_RebalanceInvest_EstimateFailAndPreviewReturnsZeroPos_NoInFlight() public {
        _registerSingleAsyncStrategy();
        asyncAdapter.setFailEstimate(true);
        // Mock previewDeposit returns ok=true, expectedPosAmount=0 (default).
        // Controller proceeds to deposit (preview ok), deposit returns amount (mock).
        // sharesOrPos = amount → in-flight recorded with that value.
        asset.mint(address(vault), 1_000e18);

        vm.warp(2 hours);
        vm.prank(address(executorGateway));
        controller.rebalance();

        // deposit called, returns 900e18 (mock returns amount), in-flight recorded
        assertEq(asyncAdapter.depositCount(), 1);
        assertEq(vault.inFlightIdCursor(), 1);
    }

    function test_PaperFlow_A2_ProcessRedeemBatch_CreatesFreshDivestDespiteA1PendingRedeem() public {
        _registerSingleAsyncStrategy();

        // Model the post-A1 state from the paper walkthrough:
        // - vault still holds ST worth 500 asset
        // - there is already one pending redeem worth 500 asset
        asyncAdapter.setTotalValue(500e18);
        vault.createInFlight(address(asyncAdapter), address(posToken), 50e18, 500e18, false);
        vault.setLocked(500e18); // cashDeficit = 500

        uint256[] memory ids = new uint256[](1);
        ids[0] = 901;
        vault.setRequest(901, 500e18, 0, IMantleYieldVault.RequestStatus.PENDING);

        vm.expectEmit(true, true, true, true);
        emit DivestCoverageRead(address(asyncAdapter), 500e18, 500e18, 500e18);

        vm.prank(address(executorGateway));
        controller.processRedeemBatch(ids);

        // A2 should create its own redeem request instead of reusing A1's pending coverage.
        assertEq(asyncAdapter.asyncCount(), 1);
        assertEq(vault.inFlightIdCursor(), 2);
        assertEq(vault.redeemInFlightTotal(), 1_000e18);
    }

    function test_PaperFlow_B_Rebalance_ReusesPendingRedeemCoverage() public {
        _registerSingleAsyncStrategy();

        // Set the rebalance target to come only from cash deficit so the numbers match the paper walkthrough.
        vm.prank(manager);
        controller.setRiskParams(0, 0, 1 hours);

        // Model the post-A1 / pre-B state from the walkthrough:
        // - vault holds no settled ST
        // - there is still one pending redeem worth 500 asset
        // - locked liabilities require 500 cash
        asyncAdapter.setTotalValue(0);
        vault.createInFlight(address(asyncAdapter), address(posToken), 50e18, 500e18, false);
        vault.setLocked(500e18);

        vm.warp(2 hours);
        vm.prank(address(executorGateway));
        controller.rebalance();

        // Rebalance should still treat the old pending redeem as valid coverage.
        assertEq(asyncAdapter.asyncCount(), 0);
        assertEq(vault.inFlightIdCursor(), 1);
        assertEq(vault.redeemInFlightTotal(), 500e18);
    }

    function test_ProcessRedeemBatch_UsesLaterStrategyWhenAsyncPendingRedeemNoLongerCoversShortfall() public {
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
        address[] memory ordered = new address[](2);
        ordered[0] = address(asyncAdapter);
        ordered[1] = address(syncAdapter);
        vm.prank(manager);
        controller.updateStrategiesAndOrder(adapters, weights, priorities, asyncFlags, ordered);

        asyncAdapter.setTotalValue(0);
        syncAdapter.setTotalValue(500e18);
        vault.createInFlight(address(asyncAdapter), address(posToken), 50e18, 300e18, false);
        vault.setLocked(300e18); // cashDeficit = 300

        uint256[] memory ids = new uint256[](1);
        ids[0] = 902;
        vault.setRequest(902, 300e18, 0, IMantleYieldVault.RequestStatus.PENDING);
        vm.prank(address(executorGateway));
        controller.processRedeemBatch(ids);

        assertEq(asyncAdapter.asyncCount(), 0);
        assertEq(vault.inFlightIdCursor(), 2);
        assertEq(vault.redeemInFlightTotal(), 600e18);
        assertEq(syncAdapter.withdrawCount(), 1);
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
        vault.setRequest(requestId, 100e18, 0, IMantleYieldVault.RequestStatus.PENDING);
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
            address(asyncAdapter),
            _investSettlement(new uint256[](0), new uint256[](0), new uint256[](0)),
            _redeemSettlement(redeemInFlightIds, redeemSettledAmounts)
        );

        assertEq(asyncAdapter.claimCount(), 1);
        assertEq(asyncAdapter.lastClaimToken(), address(asset));
        assertEq(asyncAdapter.lastClaimAmount(), 100e18);
        (,,,,,, bool isInvest,, IMantleYieldVault.InFlightStatus status) = vault.inFlightRecords(redeemInFlightId);
        assertTrue(!isInvest);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(vault.redeemInFlightTotal(), 0);
        assertEq(vault.redeemInFlightByAdapter(address(asyncAdapter)), 0);

        (,,,,, uint256 settledAssets,, IMantleYieldVault.RequestStatus reqStatus) = vault.requests(requestId);
        assertEq(settledAssets, 0);
        assertEq(uint8(reqStatus), uint8(IMantleYieldVault.RequestStatus.PROCESSING));
    }

    function test_SettleAdapter_InvestAndRedeemTogether() public {
        _registerSingleAsyncStrategy();

        uint256 requestId = 302;
        vault.setRequest(requestId, 100e18, 0, IMantleYieldVault.RequestStatus.PENDING);
        uint256[] memory ids = new uint256[](1);
        ids[0] = requestId;
        vm.prank(address(executorGateway));
        controller.processRedeemBatch(ids);

        uint256 investInFlightId = vault.createInFlight(address(asyncAdapter), address(posToken), 25e18, 50e18, true);
        uint256[] memory investInFlightIds = new uint256[](1);
        investInFlightIds[0] = investInFlightId;
        uint256[] memory investSettledPosAmounts = new uint256[](1);
        investSettledPosAmounts[0] = 25e18;
        uint256[] memory investRefundAssetAmounts = new uint256[](1);
        investRefundAssetAmounts[0] = 0;

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
            address(asyncAdapter),
            _investSettlement(investInFlightIds, investSettledPosAmounts, investRefundAssetAmounts),
            _redeemSettlement(redeemInFlightIds, redeemSettledAmounts)
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
        vault.setRequest(requestId, 100e18, 0, IMantleYieldVault.RequestStatus.PENDING);
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
        IStrategyControllerExecutor.InvestSettlementInput[] memory investBatch =
            new IStrategyControllerExecutor.InvestSettlementInput[](2);
        investBatch[0] =
            _investSettlement(_toSingletonArray(investInFlightId), _toSingletonArray(25e18), _toSingletonArray(0));
        investBatch[1] = _investSettlement(new uint256[](0), new uint256[](0), new uint256[](0));

        IStrategyControllerExecutor.RedeemSettlementInput[] memory redeemBatch =
            new IStrategyControllerExecutor.RedeemSettlementInput[](2);
        redeemBatch[0] = _redeemSettlement(new uint256[](0), new uint256[](0));
        redeemBatch[1] = _redeemSettlement(_toSingletonArray(redeemInFlightId), _toSingletonArray(100e18));

        asset.mint(address(vault), 100e18);
        vm.prank(address(executorGateway));
        controller.settleAdapters(adapters, investBatch, redeemBatch);

        assertEq(asyncAdapter.claimCount(), 1);
        assertEq(asyncAdapter.lastClaimToken(), address(asyncPosToken));
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

        (,,,,, uint256 settledAssets,, IMantleYieldVault.RequestStatus reqStatus) = vault.requests(requestId);
        assertEq(settledAssets, 0);
        assertEq(uint8(reqStatus), uint8(IMantleYieldVault.RequestStatus.PROCESSING));
    }

    function test_RevertWhen_SettleAdaptersClaimInputLengthMismatch() public {
        _registerTwoStrategies();

        address[] memory adapters = new address[](1);
        adapters[0] = address(asyncAdapter);
        IStrategyControllerExecutor.InvestSettlementInput[] memory investBatch =
            new IStrategyControllerExecutor.InvestSettlementInput[](1);
        investBatch[0] = _investSettlement(
            _toSingletonArray(vault.createInFlight(address(asyncAdapter), address(posToken), 10e18, 10e18, true)),
            _toSingletonArray(10e18),
            new uint256[](0)
        );
        IStrategyControllerExecutor.InvestSettlementInput[] memory investBatchLengthMismatch =
            new IStrategyControllerExecutor.InvestSettlementInput[](0);
        IStrategyControllerExecutor.RedeemSettlementInput[] memory redeemBatch =
            new IStrategyControllerExecutor.RedeemSettlementInput[](1);
        redeemBatch[0] = _redeemSettlement(new uint256[](0), new uint256[](0));

        vm.prank(address(executorGateway));
        vm.expectRevert(StrategyController.Controller__SettleAmountsLengthMismatch.selector);
        controller.settleAdapters(adapters, investBatchLengthMismatch, redeemBatch);
    }

    function test_RevertWhen_SettleAdaptersInvestInFlightAdapterNotIncluded() public {
        _registerTwoStrategies();
        uint256 badInFlightId = vault.createInFlight(address(asyncAdapter), address(posToken), 10e18, 10e18, true);

        address[] memory adapters = new address[](1);
        adapters[0] = address(syncAdapter);
        IStrategyControllerExecutor.InvestSettlementInput[] memory investBatch =
            new IStrategyControllerExecutor.InvestSettlementInput[](1);
        investBatch[0] =
            _investSettlement(_toSingletonArray(badInFlightId), _toSingletonArray(10e18), _toSingletonArray(0));
        IStrategyControllerExecutor.RedeemSettlementInput[] memory redeemBatch =
            new IStrategyControllerExecutor.RedeemSettlementInput[](1);
        redeemBatch[0] = _redeemSettlement(new uint256[](0), new uint256[](0));

        vm.prank(address(executorGateway));
        vm.expectRevert(
            abi.encodeWithSelector(StrategyController.Controller__InvalidInvestInFlight.selector, badInFlightId)
        );
        controller.settleAdapters(adapters, investBatch, redeemBatch);
    }

    function test_RevertWhen_SettleAdapterMissingRedeemInFlightIds() public {
        _registerSingleAsyncStrategy();
        vault.createInFlight(address(asyncAdapter), address(posToken), 50e18, 100e18, false);
        uint256[] memory redeemSettledAmounts = new uint256[](1);
        redeemSettledAmounts[0] = 1;

        vm.prank(address(executorGateway));
        vm.expectRevert(StrategyController.Controller__SettleAmountsLengthMismatch.selector);
        controller.settleAdapter(
            address(asyncAdapter),
            _investSettlement(new uint256[](0), new uint256[](0), new uint256[](0)),
            _redeemSettlement(new uint256[](0), redeemSettledAmounts)
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
                StrategyController.Controller__RedeemSweepAmountMismatch.selector, address(asyncAdapter), 100e18, 0
            )
        );
        controller.settleAdapter(
            address(asyncAdapter),
            _investSettlement(new uint256[](0), new uint256[](0), new uint256[](0)),
            _redeemSettlement(redeemInFlightIds, redeemSettledAmounts)
        );
    }

    function test_SettleAdapterRedeem_AllowsOneWeiAssetSweepShortfallPerItem() public {
        _registerSingleAsyncStrategy();
        uint256 redeemInFlightId = vault.createInFlight(address(asyncAdapter), address(posToken), 50e18, 100e18, false);
        uint256[] memory redeemInFlightIds = new uint256[](1);
        redeemInFlightIds[0] = redeemInFlightId;
        uint256[] memory redeemSettledAmounts = new uint256[](1);
        redeemSettledAmounts[0] = 100e18;
        asyncAdapter.setSweepReturnShortfall(1);

        vm.prank(address(executorGateway));
        controller.settleAdapter(
            address(asyncAdapter),
            _investSettlement(new uint256[](0), new uint256[](0), new uint256[](0)),
            _redeemSettlement(redeemInFlightIds, redeemSettledAmounts)
        );

        (,,,,, uint256 settledAmount, bool isInvest,, IMantleYieldVault.InFlightStatus status) =
            vault.inFlightRecords(redeemInFlightId);
        assertFalse(isInvest);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(settledAmount, 100e18);
    }

    function test_SettleAdapterRedeem_AllowsSweepShortfallEqualToSettlementItemCount() public {
        _registerSingleAsyncStrategy();
        uint256 redeemInFlightIdA = vault.createInFlight(address(asyncAdapter), address(posToken), 50e18, 100e18, false);
        uint256 redeemInFlightIdB = vault.createInFlight(address(asyncAdapter), address(posToken), 50e18, 100e18, false);
        uint256[] memory redeemInFlightIds = new uint256[](2);
        redeemInFlightIds[0] = redeemInFlightIdA;
        redeemInFlightIds[1] = redeemInFlightIdB;
        uint256[] memory redeemSettledAmounts = new uint256[](2);
        redeemSettledAmounts[0] = 100e18;
        redeemSettledAmounts[1] = 100e18;
        asyncAdapter.setSweepReturnShortfall(2);

        vm.prank(address(executorGateway));
        controller.settleAdapter(
            address(asyncAdapter),
            _investSettlement(new uint256[](0), new uint256[](0), new uint256[](0)),
            _redeemSettlement(redeemInFlightIds, redeemSettledAmounts)
        );

        (,,,,, uint256 settledAmountA,,, IMantleYieldVault.InFlightStatus statusA) =
            vault.inFlightRecords(redeemInFlightIdA);
        (,,,,, uint256 settledAmountB,,, IMantleYieldVault.InFlightStatus statusB) =
            vault.inFlightRecords(redeemInFlightIdB);
        assertEq(uint8(statusA), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(uint8(statusB), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(settledAmountA, 100e18);
        assertEq(settledAmountB, 100e18);
    }

    function test_RevertWhen_SettleAdapterRedeemSweepShortfallExceedsPerItemTolerance() public {
        _registerSingleAsyncStrategy();
        uint256 redeemInFlightIdA = vault.createInFlight(address(asyncAdapter), address(posToken), 50e18, 100e18, false);
        uint256 redeemInFlightIdB = vault.createInFlight(address(asyncAdapter), address(posToken), 50e18, 100e18, false);
        uint256[] memory redeemInFlightIds = new uint256[](2);
        redeemInFlightIds[0] = redeemInFlightIdA;
        redeemInFlightIds[1] = redeemInFlightIdB;
        uint256[] memory redeemSettledAmounts = new uint256[](2);
        redeemSettledAmounts[0] = 100e18;
        redeemSettledAmounts[1] = 100e18;
        asyncAdapter.setSweepReturnShortfall(3);

        vm.prank(address(executorGateway));
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyController.Controller__RedeemSweepAmountMismatch.selector,
                address(asyncAdapter),
                200e18,
                200e18 - 3
            )
        );
        controller.settleAdapter(
            address(asyncAdapter),
            _investSettlement(new uint256[](0), new uint256[](0), new uint256[](0)),
            _redeemSettlement(redeemInFlightIds, redeemSettledAmounts)
        );
    }

    function test_RevertWhen_SettleAdapterRedeemSweepClaimExceedsExpected() public {
        _registerSingleAsyncStrategy();
        uint256 redeemInFlightId = vault.createInFlight(address(asyncAdapter), address(posToken), 50e18, 100e18, false);
        uint256[] memory redeemInFlightIds = new uint256[](1);
        redeemInFlightIds[0] = redeemInFlightId;
        uint256[] memory redeemSettledAmounts = new uint256[](1);
        redeemSettledAmounts[0] = 100e18;
        asyncAdapter.setSweepReturnAmount(100e18 + 1);

        vm.prank(address(executorGateway));
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyController.Controller__RedeemSweepAmountMismatch.selector,
                address(asyncAdapter),
                100e18,
                100e18 + 1
            )
        );
        controller.settleAdapter(
            address(asyncAdapter),
            _investSettlement(new uint256[](0), new uint256[](0), new uint256[](0)),
            _redeemSettlement(redeemInFlightIds, redeemSettledAmounts)
        );
    }

    function test_SettleAdapter_InvestPartialRefund_ClaimsPosAndAsset() public {
        _registerSingleAsyncStrategy();
        uint256 inFlightId = vault.createInFlight(address(asyncAdapter), address(posToken), 100e18, 100e18, true);
        uint256[] memory investInFlightIds = new uint256[](1);
        investInFlightIds[0] = inFlightId;
        uint256[] memory investSettledPosAmounts = new uint256[](1);
        investSettledPosAmounts[0] = 70e18;
        uint256[] memory investRefundAssetAmounts = new uint256[](1);
        investRefundAssetAmounts[0] = 30e18;

        asset.mint(address(asyncAdapter), 30e18);
        vm.prank(address(executorGateway));
        controller.settleAdapter(
            address(asyncAdapter),
            _investSettlement(investInFlightIds, investSettledPosAmounts, investRefundAssetAmounts),
            _redeemSettlement(new uint256[](0), new uint256[](0))
        );

        assertEq(asyncAdapter.claimCount(), 2);
        assertEq(asyncAdapter.lastClaimToken(), address(asset));
        assertEq(asyncAdapter.lastClaimAmount(), 30e18);
        assertEq(vault.investInFlightTotal(), 0);
        (,,,,, uint256 settledAmount, bool isInvest,, IMantleYieldVault.InFlightStatus status) =
            vault.inFlightRecords(inFlightId);
        assertTrue(isInvest);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(settledAmount, 70e18);
    }

    function test_SettleAdapter_InvestFullRefund_ClaimsAssetAndConfirmsAbnormal() public {
        _registerSingleAsyncStrategy();
        uint256 inFlightId = vault.createInFlight(address(asyncAdapter), address(posToken), 100e18, 100e18, true);
        uint256[] memory investInFlightIds = new uint256[](1);
        investInFlightIds[0] = inFlightId;
        uint256[] memory investSettledPosAmounts = new uint256[](1);
        investSettledPosAmounts[0] = 0;
        uint256[] memory investRefundAssetAmounts = new uint256[](1);
        investRefundAssetAmounts[0] = 100e18;

        asset.mint(address(asyncAdapter), 100e18);
        vm.prank(address(executorGateway));
        controller.settleAdapter(
            address(asyncAdapter),
            _investSettlement(investInFlightIds, investSettledPosAmounts, investRefundAssetAmounts),
            _redeemSettlement(new uint256[](0), new uint256[](0))
        );

        assertEq(asyncAdapter.claimCount(), 1);
        assertEq(asyncAdapter.lastClaimToken(), address(asset));
        assertEq(asyncAdapter.lastClaimAmount(), 100e18);
        assertEq(vault.investInFlightTotal(), 0);
        (,,,,, uint256 settledAmount, bool isInvest,, IMantleYieldVault.InFlightStatus status) =
            vault.inFlightRecords(inFlightId);
        assertTrue(isInvest);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(settledAmount, 0);
    }

    function test_RevertWhen_SettleAdapterInvestRefundExceedsOriginalAssetAmount() public {
        _registerSingleAsyncStrategy();
        uint256 inFlightId = vault.createInFlight(address(asyncAdapter), address(posToken), 5_000e18, 5_000e18, true);
        uint256[] memory investInFlightIds = new uint256[](1);
        investInFlightIds[0] = inFlightId;
        uint256[] memory investSettledPosAmounts = new uint256[](1);
        investSettledPosAmounts[0] = 0;
        uint256[] memory investRefundAssetAmounts = new uint256[](1);
        investRefundAssetAmounts[0] = 5_001e18;

        bytes4 invalidRefundSelector =
            bytes4(keccak256("Controller__InvalidInvestRefundAmount(uint256,uint256,uint256)"));
        vm.prank(address(executorGateway));
        vm.expectRevert(abi.encodeWithSelector(invalidRefundSelector, inFlightId, 5_001e18, 5_000e18));
        controller.settleAdapter(
            address(asyncAdapter),
            _investSettlement(investInFlightIds, investSettledPosAmounts, investRefundAssetAmounts),
            _redeemSettlement(new uint256[](0), new uint256[](0))
        );
    }

    function test_RetryRedeemInFlight_Success_ForAsyncPendingRedeem() public {
        _registerSingleAsyncStrategy();
        uint256 inFlightId = vault.createInFlight(address(asyncAdapter), address(posToken), 50e18, 100e18, false);

        vm.prank(manager);
        controller.retryRedeemInFlight(address(asyncAdapter), inFlightId, 30e18);

        assertEq(asyncAdapter.retryCount(), 1);
        assertEq(asyncAdapter.lastRetryPosAmount(), 30e18);
        assertEq(asyncAdapter.lastRetryReceiver(), address(asyncAdapter));

        (,,,,,, bool isInvest,, IMantleYieldVault.InFlightStatus status) = vault.inFlightRecords(inFlightId);
        assertFalse(isInvest);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.PENDING));
    }

    function test_RevertWhen_RetryRedeemInFlight_PosAmountExceedsOriginalTokenAmount() public {
        _registerSingleAsyncStrategy();
        uint256 inFlightId = vault.createInFlight(address(asyncAdapter), address(posToken), 50e18, 100e18, false);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(StrategyController.Controller__InvalidRetryAmount.selector));
        controller.retryRedeemInFlight(address(asyncAdapter), inFlightId, 60e18);
    }

    function test_RevertWhen_RetryRedeemInFlight_ByNonAdmin() public {
        _registerSingleAsyncStrategy();
        uint256 inFlightId = vault.createInFlight(address(asyncAdapter), address(posToken), 50e18, 100e18, false);

        vm.expectRevert();
        controller.retryRedeemInFlight(address(asyncAdapter), inFlightId, 50e18);
    }

    function test_RevertWhen_RetryRedeemInFlight_OnSyncStrategy() public {
        _registerSingleSyncStrategy();
        uint256 inFlightId = vault.createInFlight(address(syncAdapter), address(posToken), 50e18, 100e18, false);

        vm.prank(manager);
        vm.expectRevert();
        controller.retryRedeemInFlight(address(syncAdapter), inFlightId, 50e18);
    }
}
