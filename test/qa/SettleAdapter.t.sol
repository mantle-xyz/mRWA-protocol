// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategyAdapter} from "../../src/interfaces/adapters/IStrategyAdapter.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {IStrategyControllerExecutor} from "../../src/interfaces/strategy/IStrategyControllerExecutor.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test, console2} from "forge-std/Test.sol";

// ============================================================
// Mock contracts (SA = SettleAdapter test suite)
// ============================================================

contract MockAssetSA is ERC20 {
    constructor() ERC20("MockAssetSA", "mASA") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockAdapterSA is IStrategyAdapter {
    address public immutable ASSET;
    address public immutable POS_TOKEN;

    uint256 public mockedTotalValue;
    bool public paused;

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

    function setSweepReturnAmount(uint256 amount_) external {
        sweepReturnAmount = amount_;
        useSweepReturnAmount = true;
    }

    function name() external pure returns (string memory) {
        return "MockAdapterSA";
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
    function minSubscribeAsset() external pure returns (uint256) { return 0; }
    function minRedeemPos() external pure returns (uint256) { return 0; }

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
        depositCount++;
        return amount;
    }

    function withdrawSync(uint256 amount, address) external returns (uint256 actualUSDC) {
        withdrawCount++;
        return amount;
    }

    function requestRedeemAsync(uint256, address) external {
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

    function retryRedeemAsync(uint256, address) external {}
}

contract MockVaultSA {
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

contract DummyExecutorSA {}

// ============================================================
// Test contract
// ============================================================

contract SettleAdapterQATest is Test {
    MockAssetSA internal asset;
    MockAssetSA internal posToken;
    MockVaultSA internal vault;
    StrategyController internal controller;
    DummyExecutorSA internal executorGateway;

    MockAdapterSA internal asyncAdapter;
    MockAdapterSA internal asyncAdapter2;

    address internal admin = makeAddr("admin");

    function setUp() public {
        asset = new MockAssetSA();
        posToken = new MockAssetSA();
        vault = new MockVaultSA(address(asset));
        executorGateway = new DummyExecutorSA();

        StrategyController implementation = new StrategyController();
        bytes memory initData = abi.encodeCall(
            StrategyController.initialize,
            (address(vault), admin, address(executorGateway), admin, 1000, 200, 1 hours)
        );
        controller = StrategyController(address(new ERC1967Proxy(address(implementation), initData)));

        asyncAdapter = new MockAdapterSA(address(asset), address(posToken));
        asyncAdapter2 = new MockAdapterSA(address(asset), address(posToken));

        // Register and activate asyncAdapter as a strategy (weight 10000)
        vm.startPrank(admin);
        controller.registerStrategy(address(asyncAdapter), 10_000, 1, true);
        controller.activateStrategy(address(asyncAdapter));
        address[] memory ordered = new address[](1);
        ordered[0] = address(asyncAdapter);
        controller.setStrategyOrder(ordered);
        vm.stopPrank();
    }

    // ----------------------------------------------------------
    // Helpers
    // ----------------------------------------------------------

    function _registerSecondAdapter() internal {
        vm.startPrank(admin);
        // Register and activate second adapter
        controller.registerStrategy(address(asyncAdapter2), 5000, 2, true);
        controller.activateStrategy(address(asyncAdapter2));

        // Atomically update both adapters' weights and set order so invariant holds
        address[] memory adapters = new address[](2);
        adapters[0] = address(asyncAdapter);
        adapters[1] = address(asyncAdapter2);
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5000;
        weights[1] = 5000;
        uint16[] memory priorities = new uint16[](2);
        priorities[0] = 1;
        priorities[1] = 2;
        bool[] memory asyncFlags = new bool[](2);
        asyncFlags[0] = true;
        asyncFlags[1] = true;
        address[] memory ordered = new address[](2);
        ordered[0] = address(asyncAdapter);
        ordered[1] = address(asyncAdapter2);
        controller.updateStrategiesAndOrder(adapters, weights, priorities, asyncFlags, ordered);
        vm.stopPrank();
    }

    function _createInvestInFlight(address adapter, uint256 tokenAmount, uint256 usdcAmount)
        internal
        returns (uint256)
    {
        return vault.createInFlight(adapter, address(posToken), tokenAmount, usdcAmount, true);
    }

    function _createRedeemInFlight(address adapter, uint256 usdcAmount) internal returns (uint256) {
        return vault.createInFlight(adapter, address(asset), 0, usdcAmount, false);
    }

    /// @dev Helper: create a redeem in-flight with a non-zero tokenAmount so it passes the usdcAmount == 0 check.
    function _createRedeemInFlightWithToken(address adapter, uint256 tokenAmount, uint256 usdcAmount)
        internal
        returns (uint256)
    {
        return vault.createInFlight(adapter, address(asset), tokenAmount, usdcAmount, false);
    }

    string constant MODULE = unicode"Settle Adapter 结算场景";
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

    // ----------------------------------------------------------
    // 1. P0: Settle both invest and redeem in-flight
    // ----------------------------------------------------------

    function test_SettleAdapter_InvestAndRedeem_Success() public {
        _logCase("test_SettleAdapter_InvestAndRedeem_Success", unicode"settleAdapter 正常结算：同时处理 invest 与 redeem in-flight");

        _step("[Step 1] Create invest in-flight: tokenAmount=100e18, usdcAmount=100e18");
        uint256 investId = _createInvestInFlight(address(asyncAdapter), 100e18, 100e18);
        _step(string.concat("  investId = ", vm.toString(investId)));

        _step("[Step 2] Create redeem in-flight: tokenAmount=50e18, usdcAmount=50e18");
        uint256 redeemId = _createRedeemInFlightWithToken(address(asyncAdapter), 50e18, 50e18);
        _step(string.concat("  redeemId = ", vm.toString(redeemId)));

        uint256[] memory investIds = new uint256[](1);
        investIds[0] = investId;
        uint256[] memory investAmounts = new uint256[](1);
        investAmounts[0] = 100e18;

        uint256[] memory redeemIds = new uint256[](1);
        redeemIds[0] = redeemId;
        uint256[] memory redeemAmounts = new uint256[](1);
        redeemAmounts[0] = 50e18;

        _step("[Step 3] Call settleAdapter with both invest and redeem arrays via executorGateway");
        vm.prank(address(executorGateway));
        controller.settleAdapter(
                address(asyncAdapter),
                IStrategyControllerExecutor.InvestSettlementInput(investIds, investAmounts, new uint256[](investIds.length)),
                IStrategyControllerExecutor.RedeemSettlementInput(redeemIds, redeemAmounts)
            );
        _step("  settleAdapter call succeeded");

        _step("[Step 4] Verify sweepToVault was called at least twice (posToken + asset)");
        assertGe(asyncAdapter.claimCount(), 2);
        _step(string.concat("  claimCount = ", vm.toString(asyncAdapter.claimCount())));
        _step("  PASS: claimCount >= 2");

        // Verify invest in-flight confirmed
        _step("[Step 5] Verify invest in-flight confirmed with correct settled amount");
        (,,,,, uint256 settledInvest,,,IMantleYieldVault.InFlightStatus investStatus) =
            vault.inFlightRecords(investId);
        assertEq(settledInvest, 100e18);
        assertEq(uint8(investStatus), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        _step(string.concat("  settledInvest = ", vm.toString(settledInvest)));
        _step("  PASS: invest in-flight CONFIRMED with settledAmount=100e18");

        // Verify redeem in-flight confirmed
        _step("[Step 6] Verify redeem in-flight confirmed with correct settled amount");
        (,,,,, uint256 settledRedeem,,,IMantleYieldVault.InFlightStatus redeemStatus) =
            vault.inFlightRecords(redeemId);
        assertEq(settledRedeem, 50e18);
        assertEq(uint8(redeemStatus), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        _step(string.concat("  settledRedeem = ", vm.toString(settledRedeem)));
        _step("  PASS: redeem in-flight CONFIRMED with settledAmount=50e18");
        _logPass();
    }

    // ----------------------------------------------------------
    // 2. P0: Only redeem, empty invest arrays
    // ----------------------------------------------------------

    function test_SettleAdapter_OnlyRedeem_Success() public {
        _logCase("test_SettleAdapter_OnlyRedeem_Success", unicode"settleAdapter 仅结算 redeem 回款（只处理 asset sweep）");

        _step("[Step 1] Create redeem in-flight: tokenAmount=80e18, usdcAmount=80e18");
        uint256 redeemId = _createRedeemInFlightWithToken(address(asyncAdapter), 80e18, 80e18);
        _step(string.concat("  redeemId = ", vm.toString(redeemId)));

        uint256[] memory emptyIds = new uint256[](0);
        uint256[] memory emptyAmounts = new uint256[](0);

        uint256[] memory redeemIds = new uint256[](1);
        redeemIds[0] = redeemId;
        uint256[] memory redeemAmounts = new uint256[](1);
        redeemAmounts[0] = 80e18;

        uint256 claimsBefore = asyncAdapter.claimCount();
        _step(string.concat("[Step 2] Record claimsBefore = ", vm.toString(claimsBefore)));

        _step("[Step 3] Call settleAdapter with empty invest arrays and redeem via executorGateway");
        vm.prank(address(executorGateway));
        controller.settleAdapter(
                address(asyncAdapter),
                IStrategyControllerExecutor.InvestSettlementInput(emptyIds, emptyAmounts, new uint256[](0)),
                IStrategyControllerExecutor.RedeemSettlementInput(redeemIds, redeemAmounts)
            );
        _step("  settleAdapter call succeeded");

        // Only asset sweep should have been called (no posToken sweep for empty invest)
        _step("[Step 4] Verify only asset sweep was called (no posToken sweep for empty invest)");
        assertEq(asyncAdapter.claimCount(), claimsBefore + 1);
        _step(string.concat("  claimCount = ", vm.toString(asyncAdapter.claimCount())));
        assertEq(asyncAdapter.lastClaimToken(), address(asset));
        _step(string.concat("  lastClaimToken = ", vm.toString(asyncAdapter.lastClaimToken())));
        _step("  PASS: only 1 sweep call, token is asset");

        // Verify redeem in-flight confirmed
        _step("[Step 5] Verify redeem in-flight confirmed");
        (,,,,,,,,IMantleYieldVault.InFlightStatus status) = vault.inFlightRecords(redeemId);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        _step("  PASS: redeem in-flight status is CONFIRMED");
        _logPass();
    }

    // ----------------------------------------------------------
    // 3. P0: Only invest, empty redeem arrays
    // ----------------------------------------------------------

    function test_SettleAdapter_OnlyInvest_Success() public {
        _logCase("test_SettleAdapter_OnlyInvest_Success", unicode"settleAdapter 仅结算 invest 到账（只处理 posToken sweep）");

        _step("[Step 1] Create invest in-flight: tokenAmount=120e18, usdcAmount=120e18");
        uint256 investId = _createInvestInFlight(address(asyncAdapter), 120e18, 120e18);
        _step(string.concat("  investId = ", vm.toString(investId)));

        uint256[] memory investIds = new uint256[](1);
        investIds[0] = investId;
        uint256[] memory investAmounts = new uint256[](1);
        investAmounts[0] = 120e18;

        uint256[] memory emptyIds = new uint256[](0);
        uint256[] memory emptyAmounts = new uint256[](0);

        uint256 claimsBefore = asyncAdapter.claimCount();
        _step(string.concat("[Step 2] Record claimsBefore = ", vm.toString(claimsBefore)));

        _step("[Step 3] Call settleAdapter with invest arrays and empty redeem via executorGateway");
        vm.prank(address(executorGateway));
        controller.settleAdapter(
                address(asyncAdapter),
                IStrategyControllerExecutor.InvestSettlementInput(investIds, investAmounts, new uint256[](investIds.length)),
                IStrategyControllerExecutor.RedeemSettlementInput(emptyIds, emptyAmounts)
            );
        _step("  settleAdapter call succeeded");

        // Only posToken sweep should have been called
        _step("[Step 4] Verify only posToken sweep was called (no asset sweep for empty redeem)");
        assertEq(asyncAdapter.claimCount(), claimsBefore + 1);
        _step(string.concat("  claimCount = ", vm.toString(asyncAdapter.claimCount())));
        assertEq(asyncAdapter.lastClaimToken(), address(posToken));
        _step(string.concat("  lastClaimToken = ", vm.toString(asyncAdapter.lastClaimToken())));
        _step("  PASS: only 1 sweep call, token is posToken");

        // Verify invest in-flight confirmed
        _step("[Step 5] Verify invest in-flight confirmed");
        (,,,,,,,,IMantleYieldVault.InFlightStatus status) = vault.inFlightRecords(investId);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        _step("  PASS: invest in-flight status is CONFIRMED");
        _logPass();
    }

    // ----------------------------------------------------------
    // 4. P0: Revert invest length mismatch
    // ----------------------------------------------------------

    function test_SettleAdapter_RevertInvestLengthMismatch() public {
        _logCase("test_SettleAdapter_RevertInvestLengthMismatch", unicode"invest ids 与 invest settledAmounts 长度不一致时被拒绝");

        _step("[Step 1] Prepare invest arrays with mismatched lengths: ids.length=2, amounts.length=1");
        uint256[] memory investIds = new uint256[](2);
        investIds[0] = 1;
        investIds[1] = 2;
        uint256[] memory investAmounts = new uint256[](1);
        investAmounts[0] = 100e18;
        _step(string.concat("  investIds.length = ", vm.toString(investIds.length)));
        _step(string.concat("  investAmounts.length = ", vm.toString(investAmounts.length)));

        uint256[] memory emptyIds = new uint256[](0);
        uint256[] memory emptyAmounts = new uint256[](0);

        _step("[Step 2] Call settleAdapter expecting SettleAmountsLengthMismatch revert");
        vm.prank(address(executorGateway));
        vm.expectRevert(StrategyController.SettleAmountsLengthMismatch.selector);
        controller.settleAdapter(
                address(asyncAdapter),
                IStrategyControllerExecutor.InvestSettlementInput(investIds, investAmounts, new uint256[](investIds.length)),
                IStrategyControllerExecutor.RedeemSettlementInput(emptyIds, emptyAmounts)
            );
        _step("  PASS: reverted as expected");
        _logPass();
    }

    // ----------------------------------------------------------
    // 5. P0: Revert redeem length mismatch
    // ----------------------------------------------------------

    function test_SettleAdapter_RevertRedeemLengthMismatch() public {
        _logCase("test_SettleAdapter_RevertRedeemLengthMismatch", unicode"redeem ids 与 redeem settledAmounts 长度不一致时被拒绝");

        _step("[Step 1] Prepare redeem arrays with mismatched lengths: ids.length=2, amounts.length=1");
        uint256[] memory emptyIds = new uint256[](0);
        uint256[] memory emptyAmounts = new uint256[](0);

        uint256[] memory redeemIds = new uint256[](2);
        redeemIds[0] = 1;
        redeemIds[1] = 2;
        uint256[] memory redeemAmounts = new uint256[](1);
        redeemAmounts[0] = 50e18;
        _step(string.concat("  redeemIds.length = ", vm.toString(redeemIds.length)));
        _step(string.concat("  redeemAmounts.length = ", vm.toString(redeemAmounts.length)));

        _step("[Step 2] Call settleAdapter expecting SettleAmountsLengthMismatch revert");
        vm.prank(address(executorGateway));
        vm.expectRevert(StrategyController.SettleAmountsLengthMismatch.selector);
        controller.settleAdapter(
                address(asyncAdapter),
                IStrategyControllerExecutor.InvestSettlementInput(emptyIds, emptyAmounts, new uint256[](0)),
                IStrategyControllerExecutor.RedeemSettlementInput(redeemIds, redeemAmounts)
            );
        _step("  PASS: reverted as expected");
        _logPass();
    }

    // ----------------------------------------------------------
    // 6. P0: Revert invest sweep mismatch
    // ----------------------------------------------------------

    function test_SettleAdapter_RevertInvestSweepMismatch() public {
        _logCase("test_SettleAdapter_RevertInvestSweepMismatch", unicode"sweep posToken 数量不足时整笔回滚，不存在按 min(requested,balance) 部分成功");

        _step("[Step 1] Create invest in-flight: tokenAmount=100e18, usdcAmount=100e18");
        uint256 investId = _createInvestInFlight(address(asyncAdapter), 100e18, 100e18);
        _step(string.concat("  investId = ", vm.toString(investId)));

        // Adapter returns 80e18 instead of 100e18
        _step("[Step 2] Configure adapter to return 80e18 on sweep (less than expected 100e18)");
        asyncAdapter.setSweepReturnAmount(80e18);

        uint256[] memory investIds = new uint256[](1);
        investIds[0] = investId;
        uint256[] memory investAmounts = new uint256[](1);
        investAmounts[0] = 100e18;

        uint256[] memory emptyIds = new uint256[](0);
        uint256[] memory emptyAmounts = new uint256[](0);

        _step("[Step 3] Call settleAdapter expecting InvestSweepAmountMismatch revert");
        _step("  expected sweep = 100e18, actual sweep = 80e18");
        vm.prank(address(executorGateway));
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyController.InvestSweepAmountMismatch.selector, address(asyncAdapter), 100e18, 80e18
            )
        );
        controller.settleAdapter(
                address(asyncAdapter),
                IStrategyControllerExecutor.InvestSettlementInput(investIds, investAmounts, new uint256[](investIds.length)),
                IStrategyControllerExecutor.RedeemSettlementInput(emptyIds, emptyAmounts)
            );
        _step("  PASS: reverted as expected");
        _logPass();
    }

    // ----------------------------------------------------------
    // 7. P0: Revert redeem sweep mismatch
    // ----------------------------------------------------------

    function test_SettleAdapter_RevertRedeemSweepMismatch() public {
        _logCase("test_SettleAdapter_RevertRedeemSweepMismatch", unicode"sweep asset 数量不足时整笔回滚，不存在按 min(requested,balance) 部分成功");

        _step("[Step 1] Create redeem in-flight: tokenAmount=50e18, usdcAmount=50e18");
        uint256 redeemId = _createRedeemInFlightWithToken(address(asyncAdapter), 50e18, 50e18);
        _step(string.concat("  redeemId = ", vm.toString(redeemId)));

        // Adapter returns 30e18 instead of 50e18
        _step("[Step 2] Configure adapter to return 30e18 on sweep (less than expected 50e18)");
        asyncAdapter.setSweepReturnAmount(30e18);

        uint256[] memory emptyIds = new uint256[](0);
        uint256[] memory emptyAmounts = new uint256[](0);

        uint256[] memory redeemIds = new uint256[](1);
        redeemIds[0] = redeemId;
        uint256[] memory redeemAmounts = new uint256[](1);
        redeemAmounts[0] = 50e18;

        _step("[Step 3] Call settleAdapter expecting RedeemSweepAmountMismatch revert");
        _step("  expected sweep = 50e18, actual sweep = 30e18");
        vm.prank(address(executorGateway));
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyController.RedeemSweepAmountMismatch.selector, address(asyncAdapter), 50e18, 30e18
            )
        );
        controller.settleAdapter(
                address(asyncAdapter),
                IStrategyControllerExecutor.InvestSettlementInput(emptyIds, emptyAmounts, new uint256[](0)),
                IStrategyControllerExecutor.RedeemSettlementInput(redeemIds, redeemAmounts)
            );
        _step("  PASS: reverted as expected");
        _logPass();
    }

    // ----------------------------------------------------------
    // 8. P0: Sweep fail preserves state
    // ----------------------------------------------------------

    function test_SettleAdapter_SweepFailPreservesState() public {
        _logCase("test_SettleAdapter_SweepFailPreservesState", unicode"sweep 校验失败时，对应 in-flight 状态和累计值保持不变");

        _step("[Step 1] Create invest in-flight: tokenAmount=100e18, usdcAmount=100e18");
        uint256 investId = _createInvestInFlight(address(asyncAdapter), 100e18, 100e18);
        _step(string.concat("  investId = ", vm.toString(investId)));

        // Store pre-state
        _step("[Step 2] Record pre-state: in-flight status and investInFlightTotal");
        (,,,,,,,,IMantleYieldVault.InFlightStatus statusBefore) = vault.inFlightRecords(investId);
        uint256 investInFlightBefore = vault.investInFlightTotal();
        _step(string.concat("  statusBefore = ", vm.toString(uint8(statusBefore)), " (PENDING)"));
        _step(string.concat("  investInFlightBefore = ", vm.toString(investInFlightBefore)));

        // Make sweep return wrong amount
        _step("[Step 3] Configure adapter to return wrong sweep amount (80e18 instead of 100e18)");
        asyncAdapter.setSweepReturnAmount(80e18);

        uint256[] memory investIds = new uint256[](1);
        investIds[0] = investId;
        uint256[] memory investAmounts = new uint256[](1);
        investAmounts[0] = 100e18;

        uint256[] memory emptyIds = new uint256[](0);
        uint256[] memory emptyAmounts = new uint256[](0);

        _step("[Step 4] Call settleAdapter expecting revert due to sweep mismatch");
        vm.prank(address(executorGateway));
        vm.expectRevert();
        controller.settleAdapter(
                address(asyncAdapter),
                IStrategyControllerExecutor.InvestSettlementInput(investIds, investAmounts, new uint256[](investIds.length)),
                IStrategyControllerExecutor.RedeemSettlementInput(emptyIds, emptyAmounts)
            );
        _step("  PASS: reverted as expected");

        // Verify state unchanged after revert
        _step("[Step 5] Verify state unchanged after revert");
        (,,,,,,,,IMantleYieldVault.InFlightStatus statusAfter) = vault.inFlightRecords(investId);
        assertEq(uint8(statusAfter), uint8(statusBefore));
        assertEq(uint8(statusAfter), uint8(IMantleYieldVault.InFlightStatus.PENDING));
        _step(string.concat("  statusAfter = ", vm.toString(uint8(statusAfter)), " (still PENDING)"));
        assertEq(vault.investInFlightTotal(), investInFlightBefore);
        _step(string.concat("  investInFlightTotal = ", vm.toString(vault.investInFlightTotal()), " (unchanged)"));
        _step("  PASS: all state preserved after revert");
        _logPass();
    }

    // ----------------------------------------------------------
    // 9. P0: Redeem zero amount triggers abnormal path
    // ----------------------------------------------------------

    function test_SettleAdapter_RedeemZeroAmount_AbnormalPath() public {
        _logCase("test_SettleAdapter_RedeemZeroAmount_AbnormalPath", unicode"redeem settledAmount=0 时走 abnormal confirm 路径");

        _step("[Step 1] Create redeem in-flight: tokenAmount=50e18, usdcAmount=50e18");
        uint256 redeemId = _createRedeemInFlightWithToken(address(asyncAdapter), 50e18, 50e18);
        _step(string.concat("  redeemId = ", vm.toString(redeemId)));

        uint256[] memory emptyIds = new uint256[](0);
        uint256[] memory emptyAmounts = new uint256[](0);

        uint256[] memory redeemIds = new uint256[](1);
        redeemIds[0] = redeemId;
        uint256[] memory redeemAmounts = new uint256[](1);
        redeemAmounts[0] = 0; // zero settled → abnormal
        _step("[Step 2] Set redeemAmounts[0] = 0 to trigger abnormal confirm path");

        uint256 claimsBefore = asyncAdapter.claimCount();
        _step(string.concat("[Step 3] Record claimsBefore = ", vm.toString(claimsBefore)));

        _step("[Step 4] Call settleAdapter with zero redeem amount via executorGateway");
        vm.prank(address(executorGateway));
        controller.settleAdapter(
                address(asyncAdapter),
                IStrategyControllerExecutor.InvestSettlementInput(emptyIds, emptyAmounts, new uint256[](0)),
                IStrategyControllerExecutor.RedeemSettlementInput(redeemIds, redeemAmounts)
            );
        _step("  settleAdapter call succeeded");

        // No asset sweep because redeemToSweep == 0
        _step("[Step 5] Verify no asset sweep was called (redeemToSweep == 0)");
        assertEq(asyncAdapter.claimCount(), claimsBefore);
        _step(string.concat("  claimCount = ", vm.toString(asyncAdapter.claimCount()), " (unchanged)"));
        _step("  PASS: no sweep calls made");

        // Verify in-flight confirmed with settledAmount=0 (abnormal path)
        _step("[Step 6] Verify in-flight confirmed with settledAmount=0 (abnormal path)");
        (,,,,, uint256 settledAmount,,,IMantleYieldVault.InFlightStatus status) = vault.inFlightRecords(redeemId);
        assertEq(settledAmount, 0);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        _step(string.concat("  settledAmount = ", vm.toString(settledAmount)));
        _step("  PASS: in-flight CONFIRMED with settledAmount=0 via abnormal path");
        _logPass();
    }

    // ----------------------------------------------------------
    // 10. P1: Invest zero amount triggers abnormal path
    // ----------------------------------------------------------

    function test_SettleAdapter_InvestZeroAmount_AbnormalPath() public {
        _logCase("test_SettleAdapter_InvestZeroAmount_AbnormalPath", unicode"invest settledAmount=0 时走 abnormal confirm 路径");

        _step("[Step 1] Create invest in-flight: tokenAmount=100e18, usdcAmount=100e18");
        uint256 investId = _createInvestInFlight(address(asyncAdapter), 100e18, 100e18);
        _step(string.concat("  investId = ", vm.toString(investId)));

        uint256[] memory investIds = new uint256[](1);
        investIds[0] = investId;
        uint256[] memory investAmounts = new uint256[](1);
        investAmounts[0] = 0; // zero settled → abnormal
        _step("[Step 2] Set investAmounts[0] = 0 to trigger abnormal confirm path");

        uint256[] memory emptyIds = new uint256[](0);
        uint256[] memory emptyAmounts = new uint256[](0);

        uint256 claimsBefore = asyncAdapter.claimCount();
        _step(string.concat("[Step 3] Record claimsBefore = ", vm.toString(claimsBefore)));

        _step("[Step 4] Call settleAdapter with zero invest amount via executorGateway");
        vm.prank(address(executorGateway));
        controller.settleAdapter(
                address(asyncAdapter),
                IStrategyControllerExecutor.InvestSettlementInput(investIds, investAmounts, new uint256[](investIds.length)),
                IStrategyControllerExecutor.RedeemSettlementInput(emptyIds, emptyAmounts)
            );
        _step("  settleAdapter call succeeded");

        // No posToken sweep because investToSweep == 0
        _step("[Step 5] Verify no posToken sweep was called (investToSweep == 0)");
        assertEq(asyncAdapter.claimCount(), claimsBefore);
        _step(string.concat("  claimCount = ", vm.toString(asyncAdapter.claimCount()), " (unchanged)"));
        _step("  PASS: no sweep calls made");

        // Verify in-flight confirmed with settledAmount=0 (abnormal path)
        _step("[Step 6] Verify in-flight confirmed with settledAmount=0 (abnormal path)");
        (,,,,, uint256 settledAmount,,,IMantleYieldVault.InFlightStatus status) = vault.inFlightRecords(investId);
        assertEq(settledAmount, 0);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        _step(string.concat("  settledAmount = ", vm.toString(settledAmount)));
        _step("  PASS: in-flight CONFIRMED with settledAmount=0 via abnormal path");
        _logPass();
    }

    // ----------------------------------------------------------
    // 11. P1: Revert unregistered strategy
    // ----------------------------------------------------------

    function test_SettleAdapter_RevertUnregisteredStrategy() public {
        _logCase("test_SettleAdapter_RevertUnregisteredStrategy", unicode"未注册策略的 adapter 无法结算");

        _step("[Step 1] Deploy a new unregistered adapter");
        MockAdapterSA unregistered = new MockAdapterSA(address(asset), address(posToken));
        _step(string.concat("  unregistered adapter = ", vm.toString(address(unregistered))));

        _step("[Step 2] Prepare invest arrays with investId=999, amount=100e18");
        uint256[] memory investIds = new uint256[](1);
        investIds[0] = 999;
        uint256[] memory investAmounts = new uint256[](1);
        investAmounts[0] = 100e18;

        uint256[] memory emptyIds = new uint256[](0);
        uint256[] memory emptyAmounts = new uint256[](0);

        _step("[Step 3] Call settleAdapter with unregistered adapter expecting InvalidStrategy revert");
        vm.prank(address(executorGateway));
        vm.expectRevert(
            abi.encodeWithSelector(StrategyController.InvalidStrategy.selector, address(unregistered))
        );
        controller.settleAdapter(
                address(unregistered),
                IStrategyControllerExecutor.InvestSettlementInput(investIds, investAmounts, new uint256[](investIds.length)),
                IStrategyControllerExecutor.RedeemSettlementInput(emptyIds, emptyAmounts)
            );
        _step("  PASS: reverted as expected");
        _logPass();
    }

    // ----------------------------------------------------------
    // 12. P1: Revert wrong adapter in-flight
    // ----------------------------------------------------------

    function test_SettleAdapter_RevertWrongAdapterInFlight() public {
        _logCase("test_SettleAdapter_RevertWrongAdapterInFlight", unicode"invest in-flight 不属于当前 adapter 时被拒绝");

        _step("[Step 1] Register second adapter");
        _registerSecondAdapter();
        _step(string.concat("  asyncAdapter2 = ", vm.toString(address(asyncAdapter2))));

        // Create in-flight for adapter2
        _step("[Step 2] Create invest in-flight owned by asyncAdapter2: tokenAmount=100e18");
        uint256 investId = _createInvestInFlight(address(asyncAdapter2), 100e18, 100e18);
        _step(string.concat("  investId = ", vm.toString(investId)));

        uint256[] memory investIds = new uint256[](1);
        investIds[0] = investId;
        uint256[] memory investAmounts = new uint256[](1);
        investAmounts[0] = 100e18;

        uint256[] memory emptyIds = new uint256[](0);
        uint256[] memory emptyAmounts = new uint256[](0);

        // Try to settle using asyncAdapter (not the owner of this in-flight)
        _step("[Step 3] Call settleAdapter using asyncAdapter (wrong owner) expecting InvalidInvestInFlight revert");
        _step(string.concat("  settling adapter = ", vm.toString(address(asyncAdapter)), " (not the owner)"));
        vm.prank(address(executorGateway));
        vm.expectRevert(
            abi.encodeWithSelector(StrategyController.InvalidInvestInFlight.selector, investId)
        );
        controller.settleAdapter(
                address(asyncAdapter),
                IStrategyControllerExecutor.InvestSettlementInput(investIds, investAmounts, new uint256[](investIds.length)),
                IStrategyControllerExecutor.RedeemSettlementInput(emptyIds, emptyAmounts)
            );
        _step("  PASS: reverted as expected");
        _logPass();
    }

    // ----------------------------------------------------------
    // 12b. P1: Revert wrong adapter redeem in-flight
    // ----------------------------------------------------------

    function test_SettleAdapter_RevertWrongAdapterRedeemInFlight() public {
        _logCase("test_SettleAdapter_RevertWrongAdapterRedeemInFlight", unicode"redeem in-flight 不属于当前 adapter 时被拒绝");

        _step("[Step 1] Register second adapter");
        _registerSecondAdapter();
        _step(string.concat("  asyncAdapter2 = ", vm.toString(address(asyncAdapter2))));

        // Create redeem in-flight for adapter2
        _step("[Step 2] Create redeem in-flight owned by asyncAdapter2: tokenAmount=500e6, usdcAmount=500e6");
        uint256 redeemId = _createRedeemInFlightWithToken(address(asyncAdapter2), 500e6, 500e6);
        _step(string.concat("  redeemId = ", vm.toString(redeemId)));

        uint256[] memory emptyIds = new uint256[](0);
        uint256[] memory emptyAmounts = new uint256[](0);

        uint256[] memory redeemIds = new uint256[](1);
        redeemIds[0] = redeemId;
        uint256[] memory redeemAmounts = new uint256[](1);
        redeemAmounts[0] = 500e6;

        // Try to settle using asyncAdapter (not the owner of this redeem in-flight)
        _step("[Step 3] Call settleAdapter using asyncAdapter (wrong owner) expecting InvalidRedeemInFlight revert");
        _step(string.concat("  settling adapter = ", vm.toString(address(asyncAdapter)), " (not the owner)"));
        vm.prank(address(executorGateway));
        vm.expectRevert(
            abi.encodeWithSelector(StrategyController.InvalidRedeemInFlight.selector, redeemId)
        );
        controller.settleAdapter(
                address(asyncAdapter),
                IStrategyControllerExecutor.InvestSettlementInput(emptyIds, emptyAmounts, new uint256[](0)),
                IStrategyControllerExecutor.RedeemSettlementInput(redeemIds, redeemAmounts)
            );
        _step("  PASS: reverted as expected");
        _logPass();
    }

    // ----------------------------------------------------------
    // 13. P1: Revert already confirmed in-flight
    // ----------------------------------------------------------

    function test_SettleAdapter_RevertAlreadyConfirmedInFlight() public {
        _logCase("test_SettleAdapter_RevertAlreadyConfirmedInFlight", unicode"已确认的 in-flight 不能重复结算");

        _step("[Step 1] Create invest in-flight: tokenAmount=100e18, usdcAmount=100e18");
        uint256 investId = _createInvestInFlight(address(asyncAdapter), 100e18, 100e18);
        _step(string.concat("  investId = ", vm.toString(investId)));

        uint256[] memory investIds = new uint256[](1);
        investIds[0] = investId;
        uint256[] memory investAmounts = new uint256[](1);
        investAmounts[0] = 100e18;

        uint256[] memory emptyIds = new uint256[](0);
        uint256[] memory emptyAmounts = new uint256[](0);

        // First settle succeeds
        _step("[Step 2] First settleAdapter call (should succeed)");
        vm.prank(address(executorGateway));
        controller.settleAdapter(
                address(asyncAdapter),
                IStrategyControllerExecutor.InvestSettlementInput(investIds, investAmounts, new uint256[](investIds.length)),
                IStrategyControllerExecutor.RedeemSettlementInput(emptyIds, emptyAmounts)
            );
        _step("  first settle succeeded");

        _step("[Step 3] Verify in-flight is now CONFIRMED");
        (,,,,,,,,IMantleYieldVault.InFlightStatus statusMid) = vault.inFlightRecords(investId);
        _step(string.concat("  status = ", vm.toString(uint8(statusMid)), " (CONFIRMED)"));

        // Second settle should revert (in-flight already CONFIRMED)
        _step("[Step 4] Second settleAdapter call expecting InvalidInvestInFlight revert");
        vm.prank(address(executorGateway));
        vm.expectRevert(
            abi.encodeWithSelector(StrategyController.InvalidInvestInFlight.selector, investId)
        );
        controller.settleAdapter(
                address(asyncAdapter),
                IStrategyControllerExecutor.InvestSettlementInput(investIds, investAmounts, new uint256[](investIds.length)),
                IStrategyControllerExecutor.RedeemSettlementInput(emptyIds, emptyAmounts)
            );
        _step("  PASS: reverted as expected (cannot re-settle confirmed in-flight)");
        _logPass();
    }

    // ----------------------------------------------------------
    // 14. P0: Batch settle 2 adapters
    // ----------------------------------------------------------

    function test_SettleAdapters_MultiAdapter_Success() public {
        _logCase("test_SettleAdapters_MultiAdapter_Success", unicode"settleAdapters 多 adapter 批量结算 happy path");

        _step("[Step 1] Register second adapter for multi-adapter batch settle");
        _registerSecondAdapter();

        // Create in-flights for both adapters
        _step("[Step 2] Create invest in-flight for adapter1: tokenAmount=100e18");
        uint256 investId1 = _createInvestInFlight(address(asyncAdapter), 100e18, 100e18);
        _step(string.concat("  investId1 = ", vm.toString(investId1)));

        _step("[Step 3] Create redeem in-flight for adapter2: usdcAmount=60e18");
        uint256 redeemId2 = _createRedeemInFlightWithToken(address(asyncAdapter2), 60e18, 60e18);
        _step(string.concat("  redeemId2 = ", vm.toString(redeemId2)));

        address[] memory adapters = new address[](2);
        adapters[0] = address(asyncAdapter);
        adapters[1] = address(asyncAdapter2);

        uint256[][] memory investIdsBatch = new uint256[][](2);
        investIdsBatch[0] = new uint256[](1);
        investIdsBatch[0][0] = investId1;
        investIdsBatch[1] = new uint256[](0);

        uint256[][] memory investAmountsBatch = new uint256[][](2);
        investAmountsBatch[0] = new uint256[](1);
        investAmountsBatch[0][0] = 100e18;
        investAmountsBatch[1] = new uint256[](0);

        uint256[][] memory redeemIdsBatch = new uint256[][](2);
        redeemIdsBatch[0] = new uint256[](0);
        redeemIdsBatch[1] = new uint256[](1);
        redeemIdsBatch[1][0] = redeemId2;

        uint256[][] memory redeemAmountsBatch = new uint256[][](2);
        redeemAmountsBatch[0] = new uint256[](0);
        redeemAmountsBatch[1] = new uint256[](1);
        redeemAmountsBatch[1][0] = 60e18;

        _step("[Step 4] Call settleAdapters with 2 adapters: adapter1 invest, adapter2 redeem");
        IStrategyControllerExecutor.InvestSettlementInput[] memory investBatch = new IStrategyControllerExecutor.InvestSettlementInput[](2);
        investBatch[0] = IStrategyControllerExecutor.InvestSettlementInput(investIdsBatch[0], investAmountsBatch[0], new uint256[](investIdsBatch[0].length));
        investBatch[1] = IStrategyControllerExecutor.InvestSettlementInput(investIdsBatch[1], investAmountsBatch[1], new uint256[](investIdsBatch[1].length));
        IStrategyControllerExecutor.RedeemSettlementInput[] memory redeemBatch = new IStrategyControllerExecutor.RedeemSettlementInput[](2);
        redeemBatch[0] = IStrategyControllerExecutor.RedeemSettlementInput(redeemIdsBatch[0], redeemAmountsBatch[0]);
        redeemBatch[1] = IStrategyControllerExecutor.RedeemSettlementInput(redeemIdsBatch[1], redeemAmountsBatch[1]);
        vm.prank(address(executorGateway));
        controller.settleAdapters(adapters, investBatch, redeemBatch);
        _step("  settleAdapters call succeeded");

        // Verify both in-flights confirmed
        _step("[Step 5] Verify adapter1 invest in-flight confirmed");
        (,,,,,,,,IMantleYieldVault.InFlightStatus status1) = vault.inFlightRecords(investId1);
        assertEq(uint8(status1), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        _step("  PASS: adapter1 invest in-flight is CONFIRMED");

        _step("[Step 6] Verify adapter2 redeem in-flight confirmed");
        (,,,,,,,,IMantleYieldVault.InFlightStatus status2) = vault.inFlightRecords(redeemId2);
        assertEq(uint8(status2), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        _step("  PASS: adapter2 redeem in-flight is CONFIRMED");
        _logPass();
    }

    // ----------------------------------------------------------
    // 15. P1: Batch outer arrays different lengths
    // ----------------------------------------------------------

    function test_SettleAdapters_RevertBatchLengthMismatch() public {
        _logCase("test_SettleAdapters_RevertBatchLengthMismatch", unicode"settleAdapters 外层批量数组长度不一致时被拒绝");

        _step("[Step 1] Prepare batch arrays with mismatched outer lengths");
        address[] memory adapters = new address[](2);
        adapters[0] = address(asyncAdapter);
        adapters[1] = address(asyncAdapter);
        _step(string.concat("  adapters.length = ", vm.toString(adapters.length)));

        // Only 1 element in investIdsBatch vs 2 adapters
        uint256[][] memory investIdsBatch = new uint256[][](1);
        investIdsBatch[0] = new uint256[](0);
        _step(string.concat("  investIdsBatch.length = ", vm.toString(investIdsBatch.length), " (mismatch!)"));

        uint256[][] memory investAmountsBatch = new uint256[][](2);
        investAmountsBatch[0] = new uint256[](0);
        investAmountsBatch[1] = new uint256[](0);

        uint256[][] memory redeemIdsBatch = new uint256[][](2);
        redeemIdsBatch[0] = new uint256[](0);
        redeemIdsBatch[1] = new uint256[](0);

        uint256[][] memory redeemAmountsBatch = new uint256[][](2);
        redeemAmountsBatch[0] = new uint256[](0);
        redeemAmountsBatch[1] = new uint256[](0);

        _step("[Step 2] Call settleAdapters expecting SettleAmountsLengthMismatch revert");
        IStrategyControllerExecutor.InvestSettlementInput[] memory investBatch = new IStrategyControllerExecutor.InvestSettlementInput[](1);
        investBatch[0] = IStrategyControllerExecutor.InvestSettlementInput(investIdsBatch[0], new uint256[](0), new uint256[](0));
        IStrategyControllerExecutor.RedeemSettlementInput[] memory redeemBatch = new IStrategyControllerExecutor.RedeemSettlementInput[](2);
        redeemBatch[0] = IStrategyControllerExecutor.RedeemSettlementInput(redeemIdsBatch[0], redeemAmountsBatch[0]);
        redeemBatch[1] = IStrategyControllerExecutor.RedeemSettlementInput(redeemIdsBatch[1], redeemAmountsBatch[1]);
        vm.prank(address(executorGateway));
        vm.expectRevert(StrategyController.SettleAmountsLengthMismatch.selector);
        controller.settleAdapters(adapters, investBatch, redeemBatch);
        _step("  PASS: reverted as expected");
        _logPass();
    }

    // ----------------------------------------------------------
    // 16. P1: One adapter sweep mismatch rolls back entire batch
    // ----------------------------------------------------------

    function test_SettleAdapters_RevertAnyAdapterFails() public {
        _logCase("test_SettleAdapters_RevertAnyAdapterFails", unicode"settleAdapters 中任一 adapter 结算失败会导致整笔批量结算回滚");

        _step("[Step 1] Register second adapter for multi-adapter batch settle");
        _registerSecondAdapter();

        _step("[Step 2] Create invest in-flight for adapter1: tokenAmount=100e18");
        uint256 investId1 = _createInvestInFlight(address(asyncAdapter), 100e18, 100e18);
        _step(string.concat("  investId1 = ", vm.toString(investId1)));

        _step("[Step 3] Create redeem in-flight for adapter2: usdcAmount=60e18");
        uint256 redeemId2 = _createRedeemInFlightWithToken(address(asyncAdapter2), 60e18, 60e18);
        _step(string.concat("  redeemId2 = ", vm.toString(redeemId2)));

        // Make adapter2 return wrong sweep amount
        _step("[Step 4] Configure adapter2 to return wrong sweep amount (30e18 instead of 60e18)");
        asyncAdapter2.setSweepReturnAmount(30e18);

        address[] memory adapters = new address[](2);
        adapters[0] = address(asyncAdapter);
        adapters[1] = address(asyncAdapter2);

        uint256[][] memory investIdsBatch = new uint256[][](2);
        investIdsBatch[0] = new uint256[](1);
        investIdsBatch[0][0] = investId1;
        investIdsBatch[1] = new uint256[](0);

        uint256[][] memory investAmountsBatch = new uint256[][](2);
        investAmountsBatch[0] = new uint256[](1);
        investAmountsBatch[0][0] = 100e18;
        investAmountsBatch[1] = new uint256[](0);

        uint256[][] memory redeemIdsBatch = new uint256[][](2);
        redeemIdsBatch[0] = new uint256[](0);
        redeemIdsBatch[1] = new uint256[](1);
        redeemIdsBatch[1][0] = redeemId2;

        uint256[][] memory redeemAmountsBatch = new uint256[][](2);
        redeemAmountsBatch[0] = new uint256[](0);
        redeemAmountsBatch[1] = new uint256[](1);
        redeemAmountsBatch[1][0] = 60e18;

        _step("[Step 5] Call settleAdapters expecting RedeemSweepAmountMismatch revert on adapter2");
        IStrategyControllerExecutor.InvestSettlementInput[] memory investBatch = new IStrategyControllerExecutor.InvestSettlementInput[](2);
        investBatch[0] = IStrategyControllerExecutor.InvestSettlementInput(investIdsBatch[0], investAmountsBatch[0], new uint256[](investIdsBatch[0].length));
        investBatch[1] = IStrategyControllerExecutor.InvestSettlementInput(investIdsBatch[1], investAmountsBatch[1], new uint256[](investIdsBatch[1].length));
        IStrategyControllerExecutor.RedeemSettlementInput[] memory redeemBatch = new IStrategyControllerExecutor.RedeemSettlementInput[](2);
        redeemBatch[0] = IStrategyControllerExecutor.RedeemSettlementInput(redeemIdsBatch[0], redeemAmountsBatch[0]);
        redeemBatch[1] = IStrategyControllerExecutor.RedeemSettlementInput(redeemIdsBatch[1], redeemAmountsBatch[1]);
        vm.prank(address(executorGateway));
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyController.RedeemSweepAmountMismatch.selector, address(asyncAdapter2), 60e18, 30e18
            )
        );
        controller.settleAdapters(adapters, investBatch, redeemBatch);
        _step("  PASS: reverted as expected");

        // Verify BOTH in-flights are still PENDING (entire tx rolled back)
        _step("[Step 6] Verify BOTH in-flights are still PENDING (entire tx rolled back)");
        (,,,,,,,,IMantleYieldVault.InFlightStatus status1) = vault.inFlightRecords(investId1);
        assertEq(uint8(status1), uint8(IMantleYieldVault.InFlightStatus.PENDING));
        _step(string.concat("  adapter1 invest status = ", vm.toString(uint8(status1)), " (PENDING)"));

        (,,,,,,,,IMantleYieldVault.InFlightStatus status2) = vault.inFlightRecords(redeemId2);
        assertEq(uint8(status2), uint8(IMantleYieldVault.InFlightStatus.PENDING));
        _step(string.concat("  adapter2 redeem status = ", vm.toString(uint8(status2)), " (PENDING)"));
        _step("  PASS: entire batch rolled back, all in-flights still PENDING");
        _logPass();
    }

    // ----------------------------------------------------------
    // 17. P1: Sweep amount match gates confirmInFlight
    // ----------------------------------------------------------

    function test_SettleAdapter_SweepMatchGatesConfirmInFlight() public {
        _logCase(
            "test_SettleAdapter_SweepMatchGatesConfirmInFlight",
            unicode"settleAdapter 只有在 sweep 金额完全匹配后才会进入 confirmInFlight"
        );

        // ---- Success scenario: sweep returns exact amount ----
        _step("[Step 1] Create invest in-flight for success scenario: tokenAmount=100e18, usdcAmount=100e18");
        uint256 investId = _createInvestInFlight(address(asyncAdapter), 100e18, 100e18);
        _step(string.concat("  investId = ", vm.toString(investId)));

        uint256[] memory investIds = new uint256[](1);
        investIds[0] = investId;
        uint256[] memory investAmounts = new uint256[](1);
        investAmounts[0] = 100e18;

        uint256[] memory emptyIds = new uint256[](0);
        uint256[] memory emptyAmounts = new uint256[](0);

        _step("[Step 2] Call settleAdapter (success scenario: sweep returns exact match)");
        _step("  adapter.sweepToVault will return 100e18 (default behaviour = return amount)");
        uint256 claimsBefore = asyncAdapter.claimCount();
        vm.prank(address(executorGateway));
        controller.settleAdapter(
                address(asyncAdapter),
                IStrategyControllerExecutor.InvestSettlementInput(investIds, investAmounts, new uint256[](investIds.length)),
                IStrategyControllerExecutor.RedeemSettlementInput(emptyIds, emptyAmounts)
            );
        _step("  settleAdapter succeeded");

        _step("  Verify sweep was called first (claimCount incremented)");
        assertGt(asyncAdapter.claimCount(), claimsBefore);
        _step(string.concat("  claimCount = ", vm.toString(asyncAdapter.claimCount()), " > ", vm.toString(claimsBefore)));

        _step("  Verify confirmInFlight was reached: in-flight should be CONFIRMED");
        (,,,,, uint256 settledAmount,,, IMantleYieldVault.InFlightStatus statusOk) =
            vault.inFlightRecords(investId);
        assertEq(uint8(statusOk), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(settledAmount, 100e18);
        _step(string.concat("  status = ", vm.toString(uint8(statusOk)), " (CONFIRMED), settledAmount = ", vm.toString(settledAmount)));
        _step("  PASS: success scenario -- sweep then confirm executed in order");

        // ---- Mismatch scenario: sweep returns less than expected ----
        _step("[Step 3] Create invest in-flight for mismatch scenario: tokenAmount=200e18, usdcAmount=200e18");
        uint256 investId2 = _createInvestInFlight(address(asyncAdapter), 200e18, 200e18);
        _step(string.concat("  investId2 = ", vm.toString(investId2)));

        uint256[] memory investIds2 = new uint256[](1);
        investIds2[0] = investId2;
        uint256[] memory investAmounts2 = new uint256[](1);
        investAmounts2[0] = 200e18;

        _step("[Step 4] Configure adapter to return mismatched sweep amount (150e18 instead of 200e18)");
        asyncAdapter.setSweepReturnAmount(150e18);

        _step("  Call settleAdapter (mismatch scenario: sweep returns 150e18 != expected 200e18)");
        vm.prank(address(executorGateway));
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyController.InvestSweepAmountMismatch.selector, address(asyncAdapter), 200e18, 150e18
            )
        );
        controller.settleAdapter(
                address(asyncAdapter),
                IStrategyControllerExecutor.InvestSettlementInput(investIds2, investAmounts2, new uint256[](investIds2.length)),
                IStrategyControllerExecutor.RedeemSettlementInput(emptyIds, emptyAmounts)
            );
        _step("  PASS: reverted with InvestSweepAmountMismatch");

        _step("  Verify confirmInFlight was NOT called: in-flight should remain PENDING");
        (,,,,,,,,IMantleYieldVault.InFlightStatus statusBad) = vault.inFlightRecords(investId2);
        assertEq(uint8(statusBad), uint8(IMantleYieldVault.InFlightStatus.PENDING));
        _step(string.concat("  status = ", vm.toString(uint8(statusBad)), " (still PENDING)"));
        _step("  PASS: mismatch scenario -- confirmInFlight was not reached");
        _logPass();
    }
}
