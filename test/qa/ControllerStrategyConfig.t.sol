// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategyAdapter} from "../../src/interfaces/adapters/IStrategyAdapter.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {OperatorExecutor} from "../../src/protocol/OperatorExecutor.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Test, console2} from "forge-std/Test.sol";

// ---------------------------------------------------------------------------
// Mock contracts
// ---------------------------------------------------------------------------

contract MockAsset is ERC20 {
    constructor() ERC20("MockAsset", "mAST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract MockStrategyAdapter is IStrategyAdapter {
    address public immutable ASSET;
    address public immutable POS_TOKEN;
    address public VAULT;

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

    constructor(address asset_, address posToken_) {
        ASSET = asset_;
        POS_TOKEN = posToken_;
    }

    function setVault(address v) external {
        VAULT = v;
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

    function vault() external view returns (address) {
        return VAULT;
    }

    function totalValue() external view returns (uint256) {
        return IERC20(POS_TOKEN).balanceOf(VAULT);
    }

    function deposit(uint256 amount, address) external returns (uint256 sharesOrPos) {
        if (failDeposit) revert("DEPOSIT_FAIL");
        depositCount++;
        if (depositReturnZero) return 0;
        IERC20(ASSET).transferFrom(VAULT, address(this), amount);
        // USDC leaves adapter to SubRed (burn to simulate)
        MockAsset(ASSET).burn(address(this), amount);
        // DiGiFT fulfillment: posToken arrives at adapter
        MockAsset(POS_TOKEN).mint(address(this), amount);
        return amount;
    }

    function withdrawSync(uint256 amount, address) external returns (uint256 actualUSDC) {
        if (failWithdraw) revert("WITHDRAW_FAIL");
        withdrawCount++;
        IERC20(ASSET).transfer(VAULT, amount);
        return amount;
    }

    function requestRedeemAsync(uint256 amount, address) external {
        if (failAsync) revert("ASYNC_FAIL");
        asyncCount++;
        IERC20(POS_TOKEN).transferFrom(VAULT, address(this), amount);
    }

    function sweepToVault(address token, uint256 amount) external returns (uint256 claimed) {
        claimCount++;
        lastClaimToken = token;
        lastClaimAmount = amount;
        uint256 bal = IERC20(token).balanceOf(address(this));
        claimed = amount > bal ? bal : amount;
        if (claimed > 0) {
            IERC20(token).transfer(VAULT, claimed);
        }
    }

    function setPaused(bool p) external {
        paused = p;
    }
    function retryRedeemAsync(uint256, address) external {}
}

contract MockControllerVault {
    ERC20 public immutable token;
    uint256 public mockedExchangeRate = 1e18;

    uint256 public locked;
    uint256 public investInFlightTotal;
    uint256 public redeemInFlightTotal;
    uint256 public nextInFlightId = 1;
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

    function getCashDeficit() external view returns (uint256) {
        uint256 totalCash = token.balanceOf(address(this));
        return locked > totalCash ? locked - totalCash : 0;
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

    function setInvestInFlight(address adapter, uint256 amount) external {
        investInFlightByAdapter[adapter] = amount;
    }

    function setRedeemInFlight(address adapter, uint256 amount) external {
        redeemInFlightByAdapter[adapter] = amount;
    }

    function createInFlight(address adapter, address assetAddr, uint256 tokenAmount, uint256 usdcAmount, bool isInvest)
        external
        returns (uint256 inFlightId)
    {
        inFlightId = nextInFlightId++;
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

// ---------------------------------------------------------------------------
// QA Test: Controller Strategy Config Scenarios
// ---------------------------------------------------------------------------

contract ControllerStrategyConfigTest is Test {
    MockAsset internal asset;
    MockAsset internal posToken;
    MockControllerVault internal vault;
    StrategyController internal controller;
    OperatorExecutor internal executor;

    MockStrategyAdapter internal syncAdapter;
    MockStrategyAdapter internal asyncAdapter;

    address internal manager = makeAddr("manager");
    address internal bot = makeAddr("bot");
    address internal nonAdmin = makeAddr("nonAdmin");

    function setUp() public {
        asset = new MockAsset();
        posToken = new MockAsset();
        vault = new MockControllerVault(address(asset));

        OperatorExecutor execImpl = new OperatorExecutor();
        executor = OperatorExecutor(address(new ERC1967Proxy(
            address(execImpl),
            abi.encodeCall(OperatorExecutor.initialize, (manager, bot))
        )));

        StrategyController implementation = new StrategyController();
        bytes memory initData = abi.encodeCall(
            StrategyController.initialize,
            (address(vault), manager, address(executor), manager, 1000, 200, 1 hours)
        );
        controller = StrategyController(address(new ERC1967Proxy(address(implementation), initData)));

        syncAdapter = new MockStrategyAdapter(address(asset), address(posToken));
        asyncAdapter = new MockStrategyAdapter(address(asset), address(posToken));

        syncAdapter.setVault(address(vault));
        asyncAdapter.setVault(address(vault));
    }

    // -----------------------------------------------------------------------
    // Logging helpers
    // -----------------------------------------------------------------------

    string constant MODULE = unicode"Controller 策略配置场景";
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

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    function _registerAndActivateTwoStrategies() internal {
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

    // -----------------------------------------------------------------------
    // 1. test_Initialize_Success (P0)
    // -----------------------------------------------------------------------

    function test_Initialize_Success() public {
        _logCase("test_Initialize_Success", unicode"StrategyController 初始化成功");

        _step("[Step 1] Verify vault and asset addresses");
        _step(string.concat("  controller.vault() = ", vm.toString(address(controller.vault()))));
        assertEq(address(controller.vault()), address(vault));
        _step("  PASS: vault address matches");
        _step(string.concat("  controller.asset() = ", vm.toString(address(controller.asset()))));
        assertEq(address(controller.asset()), address(asset));
        _step("  PASS: asset address matches");

        _step("[Step 2] Verify role assignments");
        bool hasAdmin = controller.hasRole(controller.DEFAULT_ADMIN_ROLE(), manager);
        _step(string.concat("  manager has DEFAULT_ADMIN_ROLE = ", vm.toString(hasAdmin)));
        assertTrue(hasAdmin);
        _step("  PASS: admin role assigned");
        bool hasOperator = controller.hasRole(controller.OPERATOR_EXECUTOR_ROLE(), address(executor));
        _step(string.concat("  executor has OPERATOR_EXECUTOR_ROLE = ", vm.toString(hasOperator)));
        assertTrue(hasOperator);
        _step("  PASS: operator executor role assigned");
        bool hasPauser = controller.hasRole(controller.PAUSER_ROLE(), manager);
        _step(string.concat("  manager has PAUSER_ROLE = ", vm.toString(hasPauser)));
        assertTrue(hasPauser);
        _step("  PASS: pauser role assigned");

        _step("[Step 3] Verify risk parameters");
        uint256 bufBps = controller.bufferTargetBps();
        uint256 rebalBps = controller.rebalanceThresholdBps();
        uint256 cooldown = controller.rebalanceCooldown();
        _step(string.concat("  bufferTargetBps = ", vm.toString(bufBps)));
        _step(string.concat("  rebalanceThresholdBps = ", vm.toString(rebalBps)));
        _step(string.concat("  rebalanceCooldown = ", vm.toString(cooldown)));
        assertEq(bufBps, 1000);
        assertEq(rebalBps, 200);
        assertEq(cooldown, 1 hours);
        _step("  PASS: risk params match expected values");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 2. test_Initialize_RevertZeroAddress (P0)
    // -----------------------------------------------------------------------

    function test_Initialize_RevertZeroAddress() public {
        _logCase("test_Initialize_RevertZeroAddress", unicode"初始化拒绝零地址及非法参数");
        StrategyController impl = new StrategyController();

        _step("[Step 1] Attempt initialize with zero vault address");
        bytes memory initData = abi.encodeCall(
            StrategyController.initialize,
            (address(0), manager, address(executor), manager, 1000, 200, 1 hours)
        );
        vm.expectRevert(StrategyController.InvalidAddress.selector);
        new ERC1967Proxy(address(impl), initData);
        _step("  PASS: reverted as expected (InvalidAddress)");

        _step("[Step 2] Attempt initialize with zero admin address");
        initData = abi.encodeCall(
            StrategyController.initialize,
            (address(vault), address(0), address(executor), manager, 1000, 200, 1 hours)
        );
        vm.expectRevert(StrategyController.InvalidAddress.selector);
        new ERC1967Proxy(address(impl), initData);
        _step("  PASS: reverted as expected (InvalidAddress)");

        _step("[Step 3] Attempt initialize with zero operator executor address");
        initData = abi.encodeCall(
            StrategyController.initialize,
            (address(vault), manager, address(0), manager, 1000, 200, 1 hours)
        );
        vm.expectRevert(StrategyController.InvalidAddress.selector);
        new ERC1967Proxy(address(impl), initData);
        _step("  PASS: reverted as expected (InvalidAddress)");

        _step("[Step 4] Attempt initialize with zero pauser address");
        initData = abi.encodeCall(
            StrategyController.initialize,
            (address(vault), manager, address(executor), address(0), 1000, 200, 1 hours)
        );
        vm.expectRevert(StrategyController.InvalidAddress.selector);
        new ERC1967Proxy(address(impl), initData);
        _step("  PASS: reverted as expected (InvalidAddress)");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 3. test_Initialize_RevertEOAExecutor (P0)
    // -----------------------------------------------------------------------

    function test_Initialize_RevertEOAExecutor() public {
        _logCase("test_Initialize_RevertEOAExecutor", unicode"初始化拒绝 EOA executor");
        StrategyController impl = new StrategyController();
        address eoaExecutor = makeAddr("eoaExecutor");

        _step("[Step 1] Create EOA address for executor");
        _step(string.concat("  eoaExecutor = ", vm.toString(eoaExecutor)));

        _step("[Step 2] Attempt initialize with EOA executor");
        bytes memory initData = abi.encodeCall(
            StrategyController.initialize,
            (address(vault), manager, eoaExecutor, manager, 1000, 200, 1 hours)
        );
        vm.expectRevert(abi.encodeWithSelector(StrategyController.InvalidExecutorContract.selector, eoaExecutor));
        new ERC1967Proxy(address(impl), initData);
        _step("  PASS: reverted as expected (InvalidExecutorContract)");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 4. test_Initialize_RevertInvalidBps (P0)
    // -----------------------------------------------------------------------

    function test_Initialize_RevertInvalidBps() public {
        _logCase("test_Initialize_RevertInvalidBps", unicode"初始化拒绝非法 BPS 参数");
        StrategyController impl = new StrategyController();

        _step("[Step 1] Attempt initialize with bufferTargetBps = 10001 (> 10000)");
        bytes memory initData = abi.encodeCall(
            StrategyController.initialize,
            (address(vault), manager, address(executor), manager, 10001, 200, 1 hours)
        );
        vm.expectRevert(StrategyController.InvalidBps.selector);
        new ERC1967Proxy(address(impl), initData);
        _step("  PASS: reverted as expected (InvalidBps)");

        _step("[Step 2] Attempt initialize with rebalanceThresholdBps = 10001 (> 10000)");
        initData = abi.encodeCall(
            StrategyController.initialize,
            (address(vault), manager, address(executor), manager, 1000, 10001, 1 hours)
        );
        vm.expectRevert(StrategyController.InvalidBps.selector);
        new ERC1967Proxy(address(impl), initData);
        _step("  PASS: reverted as expected (InvalidBps)");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 5. test_RegisterStrategy_OnlyAdmin (P0)
    // -----------------------------------------------------------------------

    function test_RegisterStrategy_OnlyAdmin() public {
        _logCase("test_RegisterStrategy_OnlyAdmin", unicode"只有 admin 可以注册策略");

        _step("[Step 1] Non-admin attempts to register strategy");
        _step(string.concat("  nonAdmin = ", vm.toString(nonAdmin)));
        bytes32 adminRole = controller.DEFAULT_ADMIN_ROLE();
        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nonAdmin, adminRole));
        controller.registerStrategy(address(syncAdapter), 5000, 1, false);
        _step("  PASS: reverted as expected (access control)");

        _step("[Step 2] Admin registers strategy");
        _step(string.concat("  manager = ", vm.toString(manager)));
        vm.prank(manager);
        controller.registerStrategy(address(syncAdapter), 5000, 1, false);
        _step("  registerStrategy called successfully");

        _step("[Step 3] Verify strategy registered with isActive = false");
        (, , , bool isActive, bool exists) = controller.strategyInfo(address(syncAdapter));
        _step(string.concat("  exists = ", vm.toString(exists)));
        _step(string.concat("  isActive = ", vm.toString(isActive)));
        assertTrue(exists);
        _step("  PASS: strategy exists");
        assertFalse(isActive);
        _step("  PASS: strategy starts inactive");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 6. test_RegisterStrategy_AutoRegistersVaultAdapter (P0)
    // -----------------------------------------------------------------------

    function test_RegisterStrategy_AutoRegistersVaultAdapter() public {
        _logCase("test_RegisterStrategy_AutoRegistersVaultAdapter", unicode"注册策略时自动确保 Vault 已注册 adapter");

        _step("[Step 1] Check adapter not registered in vault before");
        bool before = vault.isAdapterRegistry(address(syncAdapter));
        _step(string.concat("  vault.isAdapter(syncAdapter) = ", vm.toString(before)));
        assertFalse(before);
        _step("  PASS: adapter not registered yet");

        _step("[Step 2] Admin registers strategy");
        vm.prank(manager);
        controller.registerStrategy(address(syncAdapter), 5000, 1, false);
        _step("  registerStrategy called successfully");

        _step("[Step 3] Verify vault auto-registered adapter");
        bool after_ = vault.isAdapterRegistry(address(syncAdapter));
        _step(string.concat("  vault.isAdapter(syncAdapter) = ", vm.toString(after_)));
        assertTrue(after_);
        _step("  PASS: adapter auto-registered in vault");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 7. test_RegisterStrategy_RevertDuplicate (P0)
    // -----------------------------------------------------------------------

    function test_RegisterStrategy_RevertDuplicate() public {
        _logCase("test_RegisterStrategy_RevertDuplicate", unicode"注册重复策略被拒绝");

        _step("[Step 1] Register strategy for the first time");
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 5000, 1, false);
        _step(string.concat("  registered syncAdapter = ", vm.toString(address(syncAdapter))));

        _step("[Step 2] Attempt to register the same strategy again");
        vm.expectRevert(abi.encodeWithSelector(StrategyController.InvalidStrategy.selector, address(syncAdapter)));
        controller.registerStrategy(address(syncAdapter), 5000, 1, false);
        _step("  PASS: reverted as expected (InvalidStrategy - duplicate)");
        vm.stopPrank();
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 8. test_SetStrategyOrder_RevertWeightsNot10000 (P0)
    // -----------------------------------------------------------------------

    function test_SetStrategyOrder_RevertWeightsNot10000() public {
        _logCase("test_SetStrategyOrder_RevertWeightsNot10000", unicode"设置策略顺序时，纳入 order 的 active 策略总权重必须等于 10000");

        _step("[Step 1] Register strategy with weight 7000 (not 10000)");
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 7000, 1, false);
        controller.activateStrategy(address(syncAdapter));
        _step(string.concat("  syncAdapter weight = ", vm.toString(uint256(7000))));

        _step("[Step 2] Attempt setStrategyOrder with total weight != 10000");
        address[] memory ordered = new address[](1);
        ordered[0] = address(syncAdapter);

        vm.expectRevert(abi.encodeWithSelector(StrategyController.WeightsMustBe10000.selector, 7000));
        controller.setStrategyOrder(ordered);
        _step("  PASS: reverted as expected (WeightsMustBe10000)");
        vm.stopPrank();
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 9. test_SetStrategyOrder_RevertInactiveStrategy (P0)
    // -----------------------------------------------------------------------

    function test_SetStrategyOrder_RevertInactiveStrategy() public {
        _logCase("test_SetStrategyOrder_RevertInactiveStrategy", unicode"inactive strategy 不能进入 order");

        _step("[Step 1] Register strategy but do NOT activate");
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 10000, 1, false);
        _step(string.concat("  syncAdapter = ", vm.toString(address(syncAdapter))));

        _step("[Step 2] Attempt setStrategyOrder with inactive strategy");
        address[] memory ordered = new address[](1);
        ordered[0] = address(syncAdapter);

        vm.expectRevert(abi.encodeWithSelector(StrategyController.StrategyInactive.selector, address(syncAdapter)));
        controller.setStrategyOrder(ordered);
        _step("  PASS: reverted as expected (StrategyInactive)");
        vm.stopPrank();
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 10. test_SetStrategyOrder_RevertInvalidPriorityOrder (P1)
    // -----------------------------------------------------------------------

    function test_SetStrategyOrder_RevertInvalidPriorityOrder() public {
        _logCase("test_SetStrategyOrder_RevertInvalidPriorityOrder", unicode"priority 必须非递减");

        _step("[Step 1] Register syncAdapter with priority=2, asyncAdapter with priority=1");
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 5000, 2, false);
        controller.activateStrategy(address(syncAdapter));
        controller.registerStrategy(address(asyncAdapter), 5000, 1, true);
        controller.activateStrategy(address(asyncAdapter));
        _step(string.concat("  syncAdapter priority = ", vm.toString(uint256(2))));
        _step(string.concat("  asyncAdapter priority = ", vm.toString(uint256(1))));

        _step("[Step 2] Attempt setStrategyOrder with descending priority (2 -> 1)");
        address[] memory ordered = new address[](2);
        ordered[0] = address(syncAdapter); // priority 2
        ordered[1] = address(asyncAdapter); // priority 1 < 2 -> invalid

        vm.expectRevert(
            abi.encodeWithSelector(StrategyController.InvalidPriorityOrder.selector, address(asyncAdapter))
        );
        controller.setStrategyOrder(ordered);
        _step("  PASS: reverted as expected (InvalidPriorityOrder)");
        vm.stopPrank();
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 10b. test_SetStrategyOrder_AscendingPriority_Success (P1)
    // -----------------------------------------------------------------------

    function test_SetStrategyOrder_AscendingPriority_Success() public {
        _logCase("test_SetStrategyOrder_AscendingPriority_Success", unicode"priority 递增排列可正常设置 order");

        _step("[Step 1] Register syncAdapter with priority=1, asyncAdapter with priority=2");
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 5000, 1, false);
        controller.activateStrategy(address(syncAdapter));
        controller.registerStrategy(address(asyncAdapter), 5000, 2, true);
        controller.activateStrategy(address(asyncAdapter));
        _step(string.concat("  syncAdapter priority = ", vm.toString(uint256(1))));
        _step(string.concat("  asyncAdapter priority = ", vm.toString(uint256(2))));

        _step("[Step 2] setStrategyOrder with ascending priority (1 -> 2)");
        address[] memory ordered = new address[](2);
        ordered[0] = address(syncAdapter); // priority 1
        ordered[1] = address(asyncAdapter); // priority 2 >= 1 -> valid
        controller.setStrategyOrder(ordered);
        _step("  setStrategyOrder succeeded");

        _step("[Step 3] Verify order is correctly stored");
        uint256 orderLen = controller.strategyOrderLength();
        _step(string.concat("  strategyOrderLength = ", vm.toString(orderLen)));
        assertEq(orderLen, 2);
        assertEq(controller.strategyOrder(0), address(syncAdapter));
        assertEq(controller.strategyOrder(1), address(asyncAdapter));
        _step(string.concat("  order[0] = ", vm.toString(controller.strategyOrder(0)), " (syncAdapter)"));
        _step(string.concat("  order[1] = ", vm.toString(controller.strategyOrder(1)), " (asyncAdapter)"));
        _step("  PASS: ascending priority order accepted");
        vm.stopPrank();
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 11. test_UpdateStrategiesAndOrder_Success (P1)
    // -----------------------------------------------------------------------

    function test_UpdateStrategiesAndOrder_Success() public {
        _logCase("test_UpdateStrategiesAndOrder_Success", unicode"updateStrategiesAndOrder 可同时更新参数与顺序");

        _step("[Step 1] Register and activate both strategies with initial weights 5000/5000");
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 5000, 1, false);
        controller.activateStrategy(address(syncAdapter));
        controller.registerStrategy(address(asyncAdapter), 5000, 2, true);
        controller.activateStrategy(address(asyncAdapter));
        _step(string.concat("  syncAdapter = ", vm.toString(address(syncAdapter))));
        _step(string.concat("  asyncAdapter = ", vm.toString(address(asyncAdapter))));

        _step("[Step 2] Set initial strategy order");
        address[] memory ordered = new address[](2);
        ordered[0] = address(syncAdapter);
        ordered[1] = address(asyncAdapter);
        controller.setStrategyOrder(ordered);
        _step("  initial order set successfully");

        _step("[Step 3] Update strategies and order: change weights to 6000/4000");
        address[] memory adapters = new address[](2);
        adapters[0] = address(syncAdapter);
        adapters[1] = address(asyncAdapter);
        uint16[] memory weights = new uint16[](2);
        weights[0] = 6000;
        weights[1] = 4000;
        uint16[] memory priorities = new uint16[](2);
        priorities[0] = 1;
        priorities[1] = 2;
        bool[] memory isAsyncFlags = new bool[](2);
        isAsyncFlags[0] = false;
        isAsyncFlags[1] = true;

        address[] memory newOrder = new address[](2);
        newOrder[0] = address(syncAdapter);
        newOrder[1] = address(asyncAdapter);

        controller.updateStrategiesAndOrder(adapters, weights, priorities, isAsyncFlags, newOrder);
        _step("  updateStrategiesAndOrder called successfully");

        _step("[Step 4] Verify updated weights and order length");
        (uint16 w1, , , ,) = controller.strategyInfo(address(syncAdapter));
        (uint16 w2, , , ,) = controller.strategyInfo(address(asyncAdapter));
        _step(string.concat("  syncAdapter weight = ", vm.toString(uint256(w1))));
        _step(string.concat("  asyncAdapter weight = ", vm.toString(uint256(w2))));
        assertEq(w1, 6000);
        _step("  PASS: syncAdapter weight updated to 6000");
        assertEq(w2, 4000);
        _step("  PASS: asyncAdapter weight updated to 4000");
        uint256 orderLen = controller.strategyOrderLength();
        _step(string.concat("  strategyOrderLength = ", vm.toString(orderLen)));
        assertEq(orderLen, 2);
        _step("  PASS: order length is 2");
        vm.stopPrank();
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 12. test_StrategyLifecycle_FullCycle (P0)
    // -----------------------------------------------------------------------

    function test_StrategyLifecycle_FullCycle() public {
        _logCase("test_StrategyLifecycle_FullCycle", unicode"策略完整生命周期：register -> activate -> order -> remove from order -> deactivate");
        vm.startPrank(manager);

        _step("[Step 1] Register syncAdapter");
        controller.registerStrategy(address(syncAdapter), 10000, 1, false);
        (, , , bool isActive, bool exists) = controller.strategyInfo(address(syncAdapter));
        _step(string.concat("  exists = ", vm.toString(exists), ", isActive = ", vm.toString(isActive)));
        assertTrue(exists);
        assertFalse(isActive);
        _step("  PASS: registered but inactive");

        _step("[Step 2] Activate syncAdapter");
        controller.activateStrategy(address(syncAdapter));
        (, , , isActive,) = controller.strategyInfo(address(syncAdapter));
        _step(string.concat("  isActive = ", vm.toString(isActive)));
        assertTrue(isActive);
        _step("  PASS: strategy is now active");

        _step("[Step 3] Set strategy order with syncAdapter");
        address[] memory ordered = new address[](1);
        ordered[0] = address(syncAdapter);
        controller.setStrategyOrder(ordered);
        uint256 orderLen = controller.strategyOrderLength();
        _step(string.concat("  strategyOrderLength = ", vm.toString(orderLen)));
        assertEq(orderLen, 1);
        _step("  PASS: order set with 1 strategy");

        _step("[Step 4] Replace syncAdapter in order with asyncAdapter");
        controller.registerStrategy(address(asyncAdapter), 10000, 2, true);
        controller.activateStrategy(address(asyncAdapter));

        address[] memory adapters = new address[](2);
        adapters[0] = address(syncAdapter);
        adapters[1] = address(asyncAdapter);
        uint16[] memory weights = new uint16[](2);
        weights[0] = 0;
        weights[1] = 10000;
        uint16[] memory priorities = new uint16[](2);
        priorities[0] = 1;
        priorities[1] = 2;
        bool[] memory isAsyncFlags = new bool[](2);
        isAsyncFlags[0] = false;
        isAsyncFlags[1] = true;

        address[] memory newOrder = new address[](1);
        newOrder[0] = address(asyncAdapter);
        controller.updateStrategiesAndOrder(adapters, weights, priorities, isAsyncFlags, newOrder);

        orderLen = controller.strategyOrderLength();
        _step(string.concat("  strategyOrderLength = ", vm.toString(orderLen)));
        assertEq(orderLen, 1);
        _step("  PASS: syncAdapter removed from order");

        _step("[Step 5] Deactivate syncAdapter (no longer in order, no in-flight)");
        controller.deactivateStrategy(address(syncAdapter));
        (, , , isActive,) = controller.strategyInfo(address(syncAdapter));
        _step(string.concat("  isActive = ", vm.toString(isActive)));
        assertFalse(isActive);
        _step("  PASS: syncAdapter deactivated successfully");

        vm.stopPrank();
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 13. test_DeactivateStrategy_RevertHasInFlight (P0)
    // -----------------------------------------------------------------------

    function test_DeactivateStrategy_RevertHasInFlight() public {
        _logCase("test_DeactivateStrategy_RevertHasInFlight", unicode"有 in-flight 的策略无法停用");

        _step("[Step 1] Register and activate syncAdapter");
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 10000, 1, false);
        controller.activateStrategy(address(syncAdapter));
        vm.stopPrank();
        _step(string.concat("  syncAdapter = ", vm.toString(address(syncAdapter))));

        _step("[Step 2] Set invest in-flight = 1000, attempt deactivate");
        vault.setInvestInFlight(address(syncAdapter), 1000);
        _step(string.concat("  investInFlight = ", vm.toString(uint256(1000))));

        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(StrategyController.StrategyHasInFlight.selector, address(syncAdapter), 1000, 0)
        );
        controller.deactivateStrategy(address(syncAdapter));
        _step("  PASS: reverted as expected (StrategyHasInFlight invest=1000)");

        _step("[Step 3] Set redeem in-flight = 500, attempt deactivate");
        vault.setInvestInFlight(address(syncAdapter), 0);
        vault.setRedeemInFlight(address(syncAdapter), 500);
        _step(string.concat("  redeemInFlight = ", vm.toString(uint256(500))));

        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(StrategyController.StrategyHasInFlight.selector, address(syncAdapter), 0, 500)
        );
        controller.deactivateStrategy(address(syncAdapter));
        _step("  PASS: reverted as expected (StrategyHasInFlight redeem=500)");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 14. test_DeactivateStrategy_RevertStillInOrder (P0)
    // -----------------------------------------------------------------------

    function test_DeactivateStrategy_RevertStillInOrder() public {
        _logCase("test_DeactivateStrategy_RevertStillInOrder", unicode"在 order 中的策略无法停用，必须先移出 order");

        _step("[Step 1] Register, activate, and add syncAdapter to order");
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 10000, 1, false);
        controller.activateStrategy(address(syncAdapter));
        address[] memory ordered = new address[](1);
        ordered[0] = address(syncAdapter);
        controller.setStrategyOrder(ordered);
        _step(string.concat("  syncAdapter = ", vm.toString(address(syncAdapter))));
        _step(string.concat("  strategyOrderLength = ", vm.toString(controller.strategyOrderLength())));

        _step("[Step 2] Attempt to deactivate while still in order");
        vm.expectRevert(abi.encodeWithSelector(StrategyController.StrategyInOrder.selector, address(syncAdapter)));
        controller.deactivateStrategy(address(syncAdapter));
        _step("  PASS: reverted as expected (StrategyInOrder)");
        vm.stopPrank();
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 15. test_ActivateStrategy_RevertAlreadyActive (P1)
    // -----------------------------------------------------------------------

    function test_ActivateStrategy_RevertAlreadyActive() public {
        _logCase("test_ActivateStrategy_RevertAlreadyActive", unicode"激活已激活的策略被拒绝");

        _step("[Step 1] Register and activate syncAdapter");
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 5000, 1, false);
        controller.activateStrategy(address(syncAdapter));
        _step(string.concat("  syncAdapter = ", vm.toString(address(syncAdapter))));

        _step("[Step 2] Attempt to activate again");
        vm.expectRevert(
            abi.encodeWithSelector(StrategyController.StrategyAlreadyActive.selector, address(syncAdapter))
        );
        controller.activateStrategy(address(syncAdapter));
        _step("  PASS: reverted as expected (StrategyAlreadyActive)");
        vm.stopPrank();
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 16. test_DeactivateStrategy_RevertAlreadyInactive (P1)
    // -----------------------------------------------------------------------

    function test_DeactivateStrategy_RevertAlreadyInactive() public {
        _logCase("test_DeactivateStrategy_RevertAlreadyInactive", unicode"停用已停用的策略被拒绝");

        _step("[Step 1] Register syncAdapter (starts inactive by default)");
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 5000, 1, false);
        (, , , bool isActive,) = controller.strategyInfo(address(syncAdapter));
        _step(string.concat("  isActive = ", vm.toString(isActive)));

        _step("[Step 2] Attempt to deactivate an already inactive strategy");
        vm.expectRevert(
            abi.encodeWithSelector(StrategyController.StrategyAlreadyInactive.selector, address(syncAdapter))
        );
        controller.deactivateStrategy(address(syncAdapter));
        _step("  PASS: reverted as expected (StrategyAlreadyInactive)");
        vm.stopPrank();
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 17. test_UpdateStrategies_RevertLengthMismatch (P1)
    // -----------------------------------------------------------------------

    function test_UpdateStrategies_RevertLengthMismatch() public {
        _logCase("test_UpdateStrategies_RevertLengthMismatch", unicode"updateStrategies 输入数组长度不一致被拒绝");

        _step("[Step 1] Register syncAdapter");
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 5000, 1, false);
        _step(string.concat("  syncAdapter = ", vm.toString(address(syncAdapter))));

        _step("[Step 2] Prepare mismatched arrays (adapters.length=1, weights.length=2)");
        address[] memory adapters = new address[](1);
        adapters[0] = address(syncAdapter);

        uint16[] memory weights = new uint16[](2); // Mismatched length
        weights[0] = 5000;
        weights[1] = 5000;

        uint16[] memory priorities = new uint16[](1);
        priorities[0] = 1;

        bool[] memory isAsyncFlags = new bool[](1);
        isAsyncFlags[0] = false;
        _step(string.concat("  adapters.length = ", vm.toString(uint256(1))));
        _step(string.concat("  weights.length = ", vm.toString(uint256(2))));

        _step("[Step 3] Attempt updateStrategies with mismatched lengths");
        vm.expectRevert(StrategyController.UpdateStrategiesLengthMismatch.selector);
        controller.updateStrategies(adapters, weights, priorities, isAsyncFlags);
        _step("  PASS: reverted as expected (UpdateStrategiesLengthMismatch)");
        vm.stopPrank();
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 18. test_UpdateStrategies_RevertDuplicate (P1)
    // -----------------------------------------------------------------------

    function test_UpdateStrategies_RevertDuplicate() public {
        _logCase("test_UpdateStrategies_RevertDuplicate", unicode"updateStrategies 含重复 adapter 被拒绝");

        _step("[Step 1] Register syncAdapter");
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 5000, 1, false);
        _step(string.concat("  syncAdapter = ", vm.toString(address(syncAdapter))));

        _step("[Step 2] Prepare arrays with duplicate adapter entries");
        address[] memory adapters = new address[](2);
        adapters[0] = address(syncAdapter);
        adapters[1] = address(syncAdapter); // Duplicate
        _step(string.concat("  adapters[0] = adapters[1] = ", vm.toString(address(syncAdapter))));

        uint16[] memory weights = new uint16[](2);
        weights[0] = 5000;
        weights[1] = 5000;

        uint16[] memory priorities = new uint16[](2);
        priorities[0] = 1;
        priorities[1] = 1;

        bool[] memory isAsyncFlags = new bool[](2);
        isAsyncFlags[0] = false;
        isAsyncFlags[1] = false;

        _step("[Step 3] Attempt updateStrategies with duplicate adapter");
        vm.expectRevert(
            abi.encodeWithSelector(StrategyController.DuplicateStrategyUpdate.selector, address(syncAdapter))
        );
        controller.updateStrategies(adapters, weights, priorities, isAsyncFlags);
        _step("  PASS: reverted as expected (DuplicateStrategyUpdate)");
        vm.stopPrank();
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 19. test_SetAdapterPaused_OnlyPauser (P1)
    // -----------------------------------------------------------------------

    function test_SetAdapterPaused_OnlyPauser() public {
        _logCase("test_SetAdapterPaused_OnlyPauser", unicode"setAdapterPaused 仅 PAUSER_ROLE 可调用");

        _step("[Step 1] Register syncAdapter");
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 5000, 1, false);
        vm.stopPrank();
        _step(string.concat("  syncAdapter = ", vm.toString(address(syncAdapter))));

        _step("[Step 2] Non-pauser attempts to pause adapter");
        _step(string.concat("  nonAdmin = ", vm.toString(nonAdmin)));
        bytes32 pauserRole = controller.PAUSER_ROLE();
        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nonAdmin, pauserRole));
        controller.setAdapterPaused(address(syncAdapter), true);
        _step("  PASS: reverted as expected (access control)");

        _step("[Step 3] Pauser (manager) pauses adapter");
        vm.prank(manager);
        controller.setAdapterPaused(address(syncAdapter), true);
        bool pausedState = syncAdapter.paused();
        _step(string.concat("  syncAdapter.paused() = ", vm.toString(pausedState)));
        assertTrue(pausedState);
        _step("  PASS: adapter is paused");

        _step("[Step 4] Pauser unpauses adapter");
        vm.prank(manager);
        controller.setAdapterPaused(address(syncAdapter), false);
        pausedState = syncAdapter.paused();
        _step(string.concat("  syncAdapter.paused() = ", vm.toString(pausedState)));
        assertFalse(pausedState);
        _step("  PASS: adapter is unpaused");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 20. test_SetAdaptersPaused_BatchSuccess (P1)
    // -----------------------------------------------------------------------

    function test_SetAdaptersPaused_BatchSuccess() public {
        _logCase("test_SetAdaptersPaused_BatchSuccess", unicode"setAdaptersPaused 可批量暂停多个 adapter");

        _step("[Step 1] Register both adapters");
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 5000, 1, false);
        controller.registerStrategy(address(asyncAdapter), 5000, 2, true);
        vm.stopPrank();
        _step(string.concat("  syncAdapter = ", vm.toString(address(syncAdapter))));
        _step(string.concat("  asyncAdapter = ", vm.toString(address(asyncAdapter))));

        address[] memory adapters = new address[](2);
        adapters[0] = address(syncAdapter);
        adapters[1] = address(asyncAdapter);

        _step("[Step 2] Batch pause both adapters");
        vm.prank(manager);
        controller.setAdaptersPaused(adapters, true);
        _step(string.concat("  syncAdapter.paused() = ", vm.toString(syncAdapter.paused())));
        _step(string.concat("  asyncAdapter.paused() = ", vm.toString(asyncAdapter.paused())));
        assertTrue(syncAdapter.paused());
        assertTrue(asyncAdapter.paused());
        _step("  PASS: both adapters paused");

        _step("[Step 3] Batch unpause both adapters");
        vm.prank(manager);
        controller.setAdaptersPaused(adapters, false);
        _step(string.concat("  syncAdapter.paused() = ", vm.toString(syncAdapter.paused())));
        _step(string.concat("  asyncAdapter.paused() = ", vm.toString(asyncAdapter.paused())));
        assertFalse(syncAdapter.paused());
        assertFalse(asyncAdapter.paused());
        _step("  PASS: both adapters unpaused");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 21. test_SetAdaptersPaused_RevertUnregistered (P1)
    // -----------------------------------------------------------------------

    function test_SetAdaptersPaused_RevertUnregistered() public {
        _logCase("test_SetAdaptersPaused_RevertUnregistered", unicode"setAdaptersPaused 批量暂停中包含未注册 adapter 时整体回滚");

        _step("[Step 1] Attempt batch pause with unregistered adapter");
        _step(string.concat("  syncAdapter (unregistered) = ", vm.toString(address(syncAdapter))));
        address[] memory adapters = new address[](1);
        adapters[0] = address(syncAdapter);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(StrategyController.InvalidStrategy.selector, address(syncAdapter)));
        controller.setAdaptersPaused(adapters, true);
        _step("  PASS: reverted as expected (InvalidStrategy)");

        _step("[Step 2] Attempt single pause with unregistered adapter");
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(StrategyController.InvalidStrategy.selector, address(syncAdapter)));
        controller.setAdapterPaused(address(syncAdapter), true);
        _step("  PASS: reverted as expected (InvalidStrategy)");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 22. test_UpdateStrategies_RevertNotExists (P1)
    // -----------------------------------------------------------------------

    function test_UpdateStrategies_RevertNotExists() public {
        _logCase("test_UpdateStrategies_RevertNotExists", unicode"updateStrategies 更新不存在的策略被拒绝");

        _step("[Step 1] Prepare update for unregistered syncAdapter");
        _step(string.concat("  syncAdapter (unregistered) = ", vm.toString(address(syncAdapter))));
        address[] memory adapters = new address[](1);
        adapters[0] = address(syncAdapter);

        uint16[] memory weights = new uint16[](1);
        weights[0] = 10000;

        uint16[] memory priorities = new uint16[](1);
        priorities[0] = 1;

        bool[] memory isAsyncFlags = new bool[](1);
        isAsyncFlags[0] = false;

        _step("[Step 2] Attempt updateStrategies for non-existent strategy");
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(StrategyController.InvalidStrategy.selector, address(syncAdapter)));
        controller.updateStrategies(adapters, weights, priorities, isAsyncFlags);
        _step("  PASS: reverted as expected (InvalidStrategy)");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 23. test_PreviewRebalance_MatchesActualRebalance (P1)
    // -----------------------------------------------------------------------

    function test_PreviewRebalance_MatchesActualRebalance() public {
        _logCase("test_PreviewRebalance_MatchesActualRebalance", unicode"getRebalanceState / previewRebalance 与实际 rebalance 决策一致");

        // --- Setup: register strategy, fund vault, skip cooldown ---
        _registerAndActivateTwoStrategies();

        // Fund vault with real token transfer so freeCash >> targetCash (triggers INVEST)
        uint256 vaultFunding = 100_000e18;
        address depositor = makeAddr("depositor_preview");
        asset.mint(depositor, vaultFunding);
        vm.prank(depositor);
        asset.transfer(address(vault), vaultFunding);
        // totalValue of both adapters is naturally 0 (no posToken on vault)
        // Ensure cooldown has elapsed
        vm.warp(block.timestamp + 2 hours);

        _step("[Step 1] Call getRebalanceState() to inspect current state");
        (
            uint256 totalCash,
            uint256 locked,
            uint256 freeCash,
            uint256 netAssets,
            uint256 targetCash,
            uint256 threshold
        ) = controller.getRebalanceState();
        _step(string.concat("  totalCash   = ", vm.toString(totalCash)));
        _step(string.concat("  locked      = ", vm.toString(locked)));
        _step(string.concat("  freeCash    = ", vm.toString(freeCash)));
        _step(string.concat("  netAssets   = ", vm.toString(netAssets)));
        _step(string.concat("  targetCash  = ", vm.toString(targetCash)));
        _step(string.concat("  threshold   = ", vm.toString(threshold)));

        _step("[Step 2] Call previewRebalance() to get expected action");
        (bool shouldRebalance, uint8 action, uint256 amount) = controller.previewRebalance();
        _step(string.concat("  shouldRebalance = ", vm.toString(shouldRebalance)));
        _step(string.concat("  action          = ", vm.toString(uint256(action))));
        _step(string.concat("  amount          = ", vm.toString(amount)));

        // With bufferTargetBps=1000 (10%) and rebalanceThresholdBps=200 (2%):
        // targetCash = netAssets * 10% ; threshold = netAssets * 2%
        // freeCash == totalCash (locked=0) which is far above targetCash + threshold => INVEST
        assertTrue(shouldRebalance, "shouldRebalance must be true");
        assertEq(action, controller.REBALANCE_ACTION_INVEST(), "action must be INVEST");
        assertGt(amount, 0, "invest amount must be > 0");
        _step("  PASS: previewRebalance indicates INVEST with amount > 0");

        // Manually compute expected values to cross-check
        uint256 expectedAction;
        uint256 expectedAmount;
        if (freeCash > targetCash + threshold) {
            expectedAction = 1; // INVEST
            expectedAmount = freeCash - targetCash;
        } else if (freeCash + threshold < targetCash) {
            expectedAction = 2; // DIVEST
            expectedAmount = targetCash - freeCash;
        }
        assertEq(action, expectedAction, "action must match manual computation");
        assertEq(amount, expectedAmount, "amount must match manual computation");
        _step("  PASS: preview values match manual computation from getRebalanceState");

        _step("[Step 3] Execute rebalance() and verify it matches preview");
        // Record balances before rebalance to detect actual invest/divest
        uint256 vaultBalBefore = asset.balanceOf(address(vault));
        uint256 syncDepositsBefore = syncAdapter.depositCount();
        uint256 asyncDepositsBefore = asyncAdapter.depositCount();
        uint256 syncWithdrawsBefore = syncAdapter.withdrawCount();
        uint256 asyncWithdrawsBefore = asyncAdapter.withdrawCount();

        vm.prank(bot);
        executor.executeRebalance(address(controller));
        _step("  rebalance() executed successfully");

        if (action == controller.REBALANCE_ACTION_INVEST()) {
            // At least one adapter should have received a deposit
            uint256 totalDeposits =
                (syncAdapter.depositCount() - syncDepositsBefore) + (asyncAdapter.depositCount() - asyncDepositsBefore);
            assertGt(totalDeposits, 0, "at least one deposit must have occurred for INVEST");
            _step(string.concat("  total deposit calls = ", vm.toString(totalDeposits)));
            _step("  PASS: rebalance performed INVEST as predicted by previewRebalance");
        } else if (action == controller.REBALANCE_ACTION_DIVEST()) {
            // At least one adapter should have received a withdraw
            uint256 totalWithdraws = (syncAdapter.withdrawCount() - syncWithdrawsBefore)
                + (asyncAdapter.withdrawCount() - asyncWithdrawsBefore);
            assertGt(totalWithdraws, 0, "at least one withdraw must have occurred for DIVEST");
            _step(string.concat("  total withdraw calls = ", vm.toString(totalWithdraws)));
            _step("  PASS: rebalance performed DIVEST as predicted by previewRebalance");
        } else {
            // No-op: vault balance should remain unchanged
            uint256 vaultBalAfter = asset.balanceOf(address(vault));
            assertEq(vaultBalAfter, vaultBalBefore, "vault balance must not change for no-op");
            _step("  PASS: rebalance performed NO-OP as predicted by previewRebalance");
        }

        _logPass();
    }
}
