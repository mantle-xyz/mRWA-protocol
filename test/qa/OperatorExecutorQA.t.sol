// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OperatorExecutor} from "../../src/protocol/OperatorExecutor.sol";
import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {IStrategyControllerExecutor} from "../../src/interfaces/strategy/IStrategyControllerExecutor.sol";
import {IStrategyAdapter} from "../../src/interfaces/adapters/IStrategyAdapter.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test, Vm, console2} from "forge-std/Test.sol";

// ---------------------------------------------------------------------------
// Mock Contracts for E2E Testing
// ---------------------------------------------------------------------------

contract MockAssetOE is ERC20 {
    constructor() ERC20("MockAsset", "mAST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract MockAdapterOE is IStrategyAdapter {
    address public immutable ASSET;
    address public immutable POS_TOKEN;
    address public VAULT;

    bool public paused;

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

    function name() external pure returns (string memory) {
        return "MockAdapterOE";
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

    function vault() external view returns (address) {
        return VAULT;
    }

    function totalValue() external view returns (uint256) {
        return IERC20(POS_TOKEN).balanceOf(VAULT);
    }

    function deposit(uint256 amount, address) external returns (uint256 sharesOrPos) {
        depositCount++;
        IERC20(ASSET).transferFrom(VAULT, address(this), amount);
        // USDC leaves adapter to SubRed (burn to simulate)
        MockAssetOE(ASSET).burn(address(this), amount);
        // DiGiFT fulfillment: posToken arrives at adapter
        MockAssetOE(POS_TOKEN).mint(address(this), amount);
        return amount;
    }

    function withdrawSync(uint256 amount, address) external returns (uint256 actualUSDC) {
        withdrawCount++;
        IERC20(ASSET).transfer(VAULT, amount);
        return amount;
    }

    function requestRedeemAsync(uint256 amount, address) external {
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

contract MockVaultOE {
    ERC20 public immutable token;
    uint256 public mockedExchangeRate = 1e18;

    uint256 public investInFlightTotal;
    uint256 public redeemInFlightTotal;
    uint256 public nextInFlightId = 1;
    uint256 public nextRequestId = 1;
    uint256 public totalLockedSharesValue;
    address public gateway;

    mapping(address => uint256) public investInFlightByAdapter;
    mapping(address => uint256) public redeemInFlightByAdapter;
    mapping(address => bool) public isAdapterRegistry;
    mapping(address => uint256) public sharesOf;

    struct Req {
        uint256 id;
        address owner;
        uint256 shares;
        uint256 feeShares;
        uint256 estimatedAssets;
        uint256 settledAssets;
        uint256 timestamp;
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

    function share() external view returns (address) {
        return address(this);
    }

    function setGateway(address gateway_) external {
        gateway = gateway_;
    }

    function depositFor(address sender, uint256 assets, address receiver) external returns (uint256 shares) {
        shares = (assets * 1e18) / mockedExchangeRate;
        sharesOf[receiver] += shares;
        token.transferFrom(sender, address(this), assets);
    }

    function requestRedeemFor(address, address owner, uint256 shares) external returns (uint256 requestId) {
        require(sharesOf[owner] >= shares, "Insufficient shares");
        sharesOf[owner] -= shares;
        totalLockedSharesValue += shares;

        requestId = nextRequestId++;
        uint256 estimatedAssets = (shares * mockedExchangeRate) / 1e18;
        reqs[requestId] = Req({
            id: requestId,
            owner: owner,
            shares: shares,
            feeShares: 0,
            estimatedAssets: estimatedAssets,
            settledAssets: 0,
            timestamp: block.timestamp,
            status: IMantleYieldVault.RequestStatus.PENDING
        });
    }

    function totalLockedShares() external view returns (uint256) {
        return totalLockedSharesValue;
    }

    function setExchangeRate(uint256 rate) external {
        mockedExchangeRate = rate;
    }

    function exchangeRate() external view returns (uint256) {
        return mockedExchangeRate;
    }

    function totalLockedLiabilities() external view returns (uint256) {
        return (totalLockedSharesValue * mockedExchangeRate) / 1e18;
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
        uint256 floatingLocked = (totalLockedSharesValue * mockedExchangeRate) / 1e18;
        return totalCash > floatingLocked ? totalCash - floatingLocked : 0;
    }

    function getCashDeficit() external view returns (uint256) {
        uint256 totalCash = token.balanceOf(address(this));
        uint256 floatingLocked = (totalLockedSharesValue * mockedExchangeRate) / 1e18;
        return floatingLocked > totalCash ? floatingLocked - totalCash : 0;
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
        uint256 releasedShares = 0;
        for (uint256 i = 0; i < ids.length; i++) {
            reqs[ids[i]].settledAssets = settledAssets[i];
            reqs[ids[i]].status = IMantleYieldVault.RequestStatus.DONE;
            // Transfer USDC to request owner (real vault behavior)
            token.transfer(reqs[ids[i]].owner, settledAssets[i]);
            releasedShares += reqs[ids[i]].shares;
        }
        totalLockedSharesValue -= releasedShares;
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
        return (r.id, r.owner, r.shares, r.feeShares, r.estimatedAssets, r.settledAssets, r.timestamp, r.status);
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

/// @dev A trivial V2 used only for the UUPS upgrade tests.
contract OperatorExecutorV2 is OperatorExecutor {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @dev A non-UUPS contract used for upgrade rejection test.
contract NotUUPSContract {
    function version() external pure returns (uint256) {
        return 99;
    }
}

// ---------------------------------------------------------------------------
// QA Test Suite  --  OperatorExecutor 端到端执行场景
// ---------------------------------------------------------------------------

contract OperatorExecutorQATest is Test {
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant BOT_ROLE = keccak256("BOT_ROLE");

    // E2E components
    MockAssetOE internal asset;
    MockAssetOE internal posToken;
    MockVaultOE internal vault;
    StrategyController internal controller;
    OperatorExecutor internal executor;
    MockAdapterOE internal asyncAdapter;

    address internal admin = makeAddr("admin");
    address internal bot = makeAddr("bot");
    address internal manager = makeAddr("manager");

    // -----------------------------------------------------------------------
    // Events (re-declared for vm.expectEmit)
    // -----------------------------------------------------------------------

    event RebalanceExecuted(address indexed operator, address indexed controller);
    event ProcessRedeemBatchExecuted(address indexed operator, address indexed controller, bytes32 idsHash);
    event FinalizeRedeemBatchExecuted(
        address indexed operator, address indexed controller, bytes32 idsHash, bytes32 settledAssetsHash
    );
    event SettleAdapterExecuted(address indexed operator, address indexed controller, address adapter);
    event SettleAdaptersExecuted(address indexed operator, address indexed controller, bytes32 adaptersHash);

    // ─── stack-depth helpers for MockVaultOE (avoids 8/9-slot tuple destructuring) ───

    function _vReqStatus(uint256 id) internal view returns (IMantleYieldVault.RequestStatus s) {
        (,,,,,,, s) = vault.requests(id);
    }

    function _vReqShares(uint256 id) internal view returns (uint256 shares) {
        (,, shares,,,,,) = vault.requests(id);
    }

    function _vReqOwnerAndShares(uint256 id) internal view returns (address owner, uint256 shares) {
        (, owner, shares,,,,,) = vault.requests(id);
    }

    function _vIfTokenAmt(uint256 id) internal view returns (uint256 tokenAmt) {
        (,,, tokenAmt,,,,,) = vault.inFlightRecords(id);
    }

    function _vIfStatus(uint256 id) internal view returns (IMantleYieldVault.InFlightStatus s) {
        (,,,,,,,, s) = vault.inFlightRecords(id);
    }

    function _vIfAssetAndAmounts(uint256 id) internal view returns (address recAsset, uint256 tokenAmt, uint256 usdcAmt) {
        (,, recAsset, tokenAmt, usdcAmt,,,,) = vault.inFlightRecords(id);
    }

    /// @dev Prepare settlement arrays, verify pre-conditions, emit expected event, and execute finalize
    function _prepareFinalizeAndExecute(
        uint256[] memory ids,
        uint256 reqId1,
        uint256 reqId2
    ) internal returns (uint256[] memory settledAssets, address owner1, address owner2, uint256 settled1, uint256 settled2) {
        uint256 shares1;
        uint256 shares2;
        (owner1, shares1) = _vReqOwnerAndShares(reqId1);
        (owner2, shares2) = _vReqOwnerAndShares(reqId2);
        settled1 = (shares1 * vault.exchangeRate()) / 1e18;
        settled2 = (shares2 * vault.exchangeRate()) / 1e18;
        settledAssets = new uint256[](2);
        settledAssets[0] = settled1;
        settledAssets[1] = settled2;

        _emitAndFinalize(ids, settledAssets);
    }

    /// @dev Emit expected event, verify readyBatchDone=false, then execute finalize
    function _emitAndFinalize(uint256[] memory ids, uint256[] memory settledAssets) internal {
        assertFalse(controller.readyBatchDone(keccak256(abi.encode(ids))), "batch should not be ready yet");

        vm.expectEmit(true, true, false, true);
        emit FinalizeRedeemBatchExecuted(
            bot, address(controller),
            keccak256(abi.encodePacked(ids)),
            keccak256(abi.encodePacked(settledAssets))
        );

        vm.prank(bot);
        executor.executeFinalizeRedeemBatch(address(controller), ids, settledAssets);
    }

    // -----------------------------------------------------------------------
    // setUp - 使用真实 StrategyController
    // -----------------------------------------------------------------------

    function setUp() public {
        // 1. Deploy mock tokens
        asset = new MockAssetOE();
        posToken = new MockAssetOE();

        // 2. Deploy mock vault
        vault = new MockVaultOE(address(asset));

        // 3. Deploy OperatorExecutor (this is the executor gateway for Controller)
        OperatorExecutor executorImpl = new OperatorExecutor();
        bytes memory executorInitData = abi.encodeCall(OperatorExecutor.initialize, (admin, bot));
        executor = OperatorExecutor(address(new ERC1967Proxy(address(executorImpl), executorInitData)));

        // 4. Deploy real StrategyController with executor as the gateway
        StrategyController controllerImpl = new StrategyController();
        bytes memory controllerInitData = abi.encodeCall(
            StrategyController.initialize,
            (address(vault), manager, address(executor), manager, 1000, 200, 1 hours)
        );
        controller = StrategyController(address(new ERC1967Proxy(address(controllerImpl), controllerInitData)));

        // 5. Deploy and register async adapter
        asyncAdapter = new MockAdapterOE(address(asset), address(posToken));
        asyncAdapter.setVault(address(vault));

        vm.startPrank(manager);
        controller.registerStrategy(address(asyncAdapter), 10_000, 1, true);
        controller.activateStrategy(address(asyncAdapter));
        address[] memory ordered = new address[](1);
        ordered[0] = address(asyncAdapter);
        controller.setStrategyOrder(ordered);
        vm.stopPrank();
    }

    string constant MODULE = unicode"OperatorExecutor 端到端执行场景";
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
    // E2E Helpers
    // -----------------------------------------------------------------------

    /// @dev Helper: 用户存入 asset，获得 shares
    function _depositToVault(address user, uint256 assetAmount) internal returns (uint256 shares) {
        asset.mint(user, assetAmount);
        vm.prank(user);
        asset.approve(address(vault), assetAmount);
        shares = vault.depositFor(user, assetAmount, user);
    }

    /// @dev Helper: 用户发起赎回请求
    function _createRedeemRequest(address user, uint256 shares) internal returns (uint256 requestId) {
        requestId = vault.requestRedeemFor(user, user, shares);
    }

    /// @dev Helper: 通过 executor 创建 invest in-flight (via rebalance)
    function _createInvestInFlightViaExecutor(uint256 investAmount) internal returns (uint256 inFlightId) {
        address depositor = makeAddr("depositor_invest");
        _depositToVault(depositor, investAmount);
        vm.warp(block.timestamp + 2 hours);
        uint256 cursorBefore = vault.nextInFlightId();
        vm.prank(bot);
        executor.executeRebalance(address(controller));
        require(vault.nextInFlightId() > cursorBefore, "No invest in-flight created");
        inFlightId = vault.nextInFlightId() - 1;
    }

    /// @dev Helper: 通过 executor 创建 redeem in-flight (via processRedeemBatch)
    function _createRedeemInFlightViaExecutor(address user, uint256 assetAmount)
        internal
        returns (uint256 inFlightId, uint256 requestId)
    {
        // 1. User deposits (USDC to vault, shares to user)
        _depositToVault(user, assetAmount);

        // 2. Rebalance to invest USDC to adapter
        vm.warp(block.timestamp + 2 hours);
        vm.prank(bot);
        executor.executeRebalance(address(controller));
        uint256 investId = vault.nextInFlightId() - 1;

        // 3. Settle invest (sweep posToken from adapter to vault)
        uint256 tokenAmt = _vIfTokenAmt(investId);
        uint256[] memory investIds = new uint256[](1);
        investIds[0] = investId;
        uint256[] memory settledPos = new uint256[](1);
        settledPos[0] = tokenAmt;
        uint256[] memory refunds = new uint256[](1);
        refunds[0] = 0;
        vm.prank(bot);
        executor.executeSettleAdapter(
            address(controller),
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(investIds, settledPos, refunds),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );

        // 4. User requests redeem
        uint256 shares = vault.sharesOf(user);
        requestId = _createRedeemRequest(user, shares);

        // 5. processRedeemBatch triggers divest (freeCash=0)
        vm.warp(block.timestamp + 2 hours);
        uint256 cursorBefore = vault.nextInFlightId();
        uint256[] memory ids = new uint256[](1);
        ids[0] = requestId;
        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), ids);

        require(vault.nextInFlightId() > cursorBefore, "No redeem in-flight created");
        inFlightId = vault.nextInFlightId() - 1;
    }

    // =======================================================================
    //  1. test_Initialize_Success  (P0)
    // =======================================================================

    function test_Initialize_Success() public {
        _logCase("test_Initialize_Success", unicode"OperatorExecutor 初始化成功并授予初始 bot 权限");

        _step("[Step 1] Check admin has DEFAULT_ADMIN_ROLE after initialization");
        _step(string.concat("  admin address: ", vm.toString(admin)));
        bool adminHasRole = executor.hasRole(DEFAULT_ADMIN_ROLE, admin);
        _step(string.concat("  hasRole(DEFAULT_ADMIN_ROLE, admin) = ", vm.toString(adminHasRole)));
        assertTrue(adminHasRole, "admin should have DEFAULT_ADMIN_ROLE");
        _step("  PASS: admin has DEFAULT_ADMIN_ROLE");

        _step("[Step 2] Check bot has BOT_ROLE after initialization");
        _step(string.concat("  bot address: ", vm.toString(bot)));
        bool botHasRole = executor.hasRole(BOT_ROLE, bot);
        _step(string.concat("  hasRole(BOT_ROLE, bot) = ", vm.toString(botHasRole)));
        assertTrue(botHasRole, "bot should have BOT_ROLE");
        _step("  PASS: bot has BOT_ROLE");

        _logPass();
    }

    // =======================================================================
    //  2. test_Initialize_RevertZeroAddress  (P0)
    // =======================================================================

    function test_Initialize_RevertZeroAddress() public {
        _logCase("test_Initialize_RevertZeroAddress", unicode"初始化拒绝零地址参数");

        _step("[Step 1] Deploy fresh implementation for zero-address tests");
        OperatorExecutor impl = new OperatorExecutor();
        _step(string.concat("  implementation address: ", vm.toString(address(impl))));

        _step("[Step 2] Attempt initialize with admin=address(0), expect revert InvalidAddress");
        // zero admin
        vm.expectRevert(OperatorExecutor.InvalidAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(OperatorExecutor.initialize, (address(0), bot)));
        _step("  PASS: reverted as expected for zero admin");

        _step("[Step 3] Deploy another implementation and attempt initialize with bot=address(0)");
        // zero bot
        impl = new OperatorExecutor();
        _step(string.concat("  new implementation address: ", vm.toString(address(impl))));
        vm.expectRevert(OperatorExecutor.InvalidAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(OperatorExecutor.initialize, (admin, address(0))));
        _step("  PASS: reverted as expected for zero bot");

        _logPass();
    }

    // =======================================================================
    //  3. test_BotRole_OnlyAdminCanManage  (P0)
    // =======================================================================

    function test_BotRole_OnlyAdminCanManage() public {
        _logCase("test_BotRole_OnlyAdminCanManage", unicode"只有 admin 可以管理 BOT_ROLE");
        address nobody = makeAddr("nobody");
        address newBot = makeAddr("newBot");
        _step(string.concat("[Step 1] Create non-admin address: ", vm.toString(nobody)));

        _step("[Step 2] Attempt grantRole(BOT_ROLE) from non-admin, expect revert");
        vm.prank(nobody);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nobody, DEFAULT_ADMIN_ROLE)
        );
        executor.grantRole(BOT_ROLE, newBot);
        _step("  PASS: reverted as expected for unauthorized grant");

        _step("[Step 3] Attempt revokeRole(BOT_ROLE) from non-admin, expect revert");
        vm.prank(nobody);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nobody, DEFAULT_ADMIN_ROLE)
        );
        executor.revokeRole(BOT_ROLE, bot);
        _step("  PASS: reverted as expected for unauthorized revoke");

        _step("[Step 4] Admin grants BOT_ROLE to newBot - should succeed");
        vm.prank(admin);
        executor.grantRole(BOT_ROLE, newBot);
        assertTrue(executor.hasRole(BOT_ROLE, newBot), "admin should be able to grant BOT_ROLE");
        _step(string.concat("  hasRole(BOT_ROLE, newBot) = ", vm.toString(executor.hasRole(BOT_ROLE, newBot))));
        _step("  PASS: admin grant succeeded");

        _step("[Step 5] Admin revokes BOT_ROLE from newBot - should succeed");
        vm.prank(admin);
        executor.revokeRole(BOT_ROLE, newBot);
        assertFalse(executor.hasRole(BOT_ROLE, newBot), "admin should be able to revoke BOT_ROLE");
        _step(string.concat("  hasRole(BOT_ROLE, newBot) = ", vm.toString(executor.hasRole(BOT_ROLE, newBot))));
        _step("  PASS: admin revoke succeeded");

        _logPass();
    }

    // =======================================================================
    //  4. test_BotRole_NotAutoAdmin  (P1)
    // =======================================================================

    function test_BotRole_NotAutoAdmin() public {
        _logCase("test_BotRole_NotAutoAdmin", unicode"初始 bot 不自动拥有 admin 权限");

        _step("[Step 1] Query whether bot has DEFAULT_ADMIN_ROLE");
        _step(string.concat("  bot address: ", vm.toString(bot)));
        bool botIsAdmin = executor.hasRole(DEFAULT_ADMIN_ROLE, bot);
        _step(string.concat("  hasRole(DEFAULT_ADMIN_ROLE, bot) = ", vm.toString(botIsAdmin)));

        _step("[Step 2] Assert bot does NOT have DEFAULT_ADMIN_ROLE");
        assertFalse(botIsAdmin, "bot should NOT have DEFAULT_ADMIN_ROLE");
        _step("  PASS: bot is not auto-admin");

        _logPass();
    }

    // =======================================================================
    //  5. test_AdminRole_NotAutoBot  (P1)
    // =======================================================================

    function test_AdminRole_NotAutoBot() public {
        _logCase("test_AdminRole_NotAutoBot", unicode"admin 不自动拥有 BOT_ROLE");

        _step("[Step 1] Query whether admin has BOT_ROLE");
        _step(string.concat("  admin address: ", vm.toString(admin)));
        bool adminIsBot = executor.hasRole(BOT_ROLE, admin);
        _step(string.concat("  hasRole(BOT_ROLE, admin) = ", vm.toString(adminIsBot)));

        _step("[Step 2] Assert admin does NOT have BOT_ROLE");
        assertFalse(adminIsBot, "admin should NOT have BOT_ROLE");
        _step("  PASS: admin is not auto-bot");

        _logPass();
    }

    // =======================================================================
    //  6. test_ExecuteRebalance_Success  (P0) - E2E 真实业务流程
    // =======================================================================

    function test_ExecuteRebalance_Success() public {
        _logCase("test_ExecuteRebalance_Success", unicode"Bot 通过 Executor 执行 rebalance，资金从 Vault 进入 Adapter 并创建 invest in-flight");

        _step("[Step 1] Deposit asset to vault to trigger invest on rebalance");
        uint256 investAmount = 100e6;
        address depositor = makeAddr("depositor_rebalance");
        _depositToVault(depositor, investAmount);
        _step(string.concat("  investAmount = ", vm.toString(investAmount)));
        _step(string.concat("  vault freeCash = ", vm.toString(vault.getFreeCash())));

        _step("[Step 2] Skip rebalance cooldown period");
        vm.warp(block.timestamp + 2 hours);

        _step("[Step 3] Record state before rebalance");
        uint256 inFlightCursorBefore = vault.nextInFlightId();
        uint256 depositCountBefore = asyncAdapter.depositCount();
        _step(string.concat("  nextInFlightId before = ", vm.toString(inFlightCursorBefore)));
        _step(string.concat("  adapter.depositCount before = ", vm.toString(depositCountBefore)));

        _step("[Step 4] Set up expected event and execute rebalance via Executor");
        _step(string.concat("  bot: ", vm.toString(bot)));
        _step(string.concat("  controller: ", vm.toString(address(controller))));
        vm.expectEmit(true, true, false, true);
        emit RebalanceExecuted(bot, address(controller));

        vm.prank(bot);
        executor.executeRebalance(address(controller));
        _step("  PASS: executeRebalance completed without revert");

        _step("[Step 5] Verify adapter.deposit() was called (real business flow)");
        assertGt(asyncAdapter.depositCount(), depositCountBefore, "adapter.deposit should be called");
        _step(string.concat("  adapter.depositCount after = ", vm.toString(asyncAdapter.depositCount())));
        _step("  PASS: adapter received deposit call");

        _step("[Step 6] Verify invest in-flight was created");
        assertGt(vault.nextInFlightId(), inFlightCursorBefore, "new in-flight should be created");
        uint256 newInFlightId = vault.nextInFlightId() - 1;
        _step(string.concat("  new inFlightId = ", vm.toString(newInFlightId)));

        (
            uint256 recId,
            address recAdapter,
            address recAsset,
            uint256 recTokenAmt,
            uint256 recUsdcAmt,
            uint256 recSettled,
            bool recIsInvest,
            ,
            IMantleYieldVault.InFlightStatus recStatus
        ) = vault.inFlightRecords(newInFlightId);

        _step(string.concat("  in-flight adapter = ", vm.toString(recAdapter)));
        _step(string.concat("  in-flight tokenAmt = ", vm.toString(recTokenAmt)));
        _step(string.concat("  in-flight usdcAmt = ", vm.toString(recUsdcAmt)));
        _step(string.concat("  in-flight isInvest = ", vm.toString(recIsInvest)));
        _step(string.concat("  in-flight status = ", vm.toString(uint8(recStatus))));

        assertEq(recAdapter, address(asyncAdapter));
        assertTrue(recIsInvest, "should be invest in-flight");
        assertEq(uint8(recStatus), uint8(IMantleYieldVault.InFlightStatus.PENDING));
        _step("  PASS: invest in-flight created with correct data");

        _logPass();
    }

    // =======================================================================
    //  7. test_ExecuteRebalance_RevertNotBot  (P0)
    // =======================================================================

    function test_ExecuteRebalance_RevertNotBot() public {
        _logCase("test_ExecuteRebalance_RevertNotBot", unicode"非 BOT_ROLE 账户不能执行 rebalance");

        address notBot = makeAddr("notBot");
        _step(string.concat("[Step 1] Create non-bot address: ", vm.toString(notBot)));

        _step("[Step 2] Verify notBot does NOT have BOT_ROLE");
        bool hasBotRole = executor.hasRole(BOT_ROLE, notBot);
        _step(string.concat("  hasRole(BOT_ROLE, notBot) = ", vm.toString(hasBotRole)));

        _step("[Step 3] Attempt executeRebalance as notBot, expect revert AccessControlUnauthorizedAccount");
        vm.prank(notBot);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, notBot, BOT_ROLE)
        );
        executor.executeRebalance(address(controller));
        _step("  PASS: reverted as expected");

        _logPass();
    }

    // =======================================================================
    //  8. test_ExecuteRebalance_RevertZeroAddress  (P0)
    // =======================================================================

    function test_ExecuteRebalance_RevertZeroAddress() public {
        _logCase("test_ExecuteRebalance_RevertZeroAddress", unicode"非法 controller 地址被拒绝（零地址与 EOA 分别校验）");

        _step("[Step 1] Call executeRebalance with controller=address(0) as bot");
        _step(string.concat("  bot: ", vm.toString(bot)));
        _step("  controller: address(0)");

        _step("[Step 2] Expect revert with InvalidAddress selector");
        vm.prank(bot);
        vm.expectRevert(OperatorExecutor.InvalidAddress.selector);
        executor.executeRebalance(address(0));
        _step("  PASS: reverted as expected");

        _logPass();
    }

    // =======================================================================
    //  9. test_ExecuteRebalance_RevertEOA  (P0)
    // =======================================================================

    function test_ExecuteRebalance_RevertEOA() public {
        _logCase("test_ExecuteRebalance_RevertEOA", unicode"非法 controller 地址被拒绝（零地址与 EOA 分别校验）");

        address eoaController = makeAddr("eoaController");
        _step(string.concat("[Step 1] Create EOA controller address: ", vm.toString(eoaController)));

        _step("[Step 2] Attempt executeRebalance with EOA controller as bot");
        _step(string.concat("  bot: ", vm.toString(bot)));

        _step("[Step 3] Expect revert with InvalidController selector");
        vm.prank(bot);
        vm.expectRevert(abi.encodeWithSelector(OperatorExecutor.InvalidController.selector, eoaController));
        executor.executeRebalance(eoaController);
        _step("  PASS: reverted as expected");

        _logPass();
    }

    // =======================================================================
    // 10. test_ExecuteRebalance_RevertDownstreamFailure  (P1)
    // =======================================================================

    function test_ExecuteRebalance_RevertDownstreamFailure() public {
        _logCase("test_ExecuteRebalance_RevertDownstreamFailure", unicode"下游 Controller 调用失败时整笔交易回滚");

        _step("[Step 1] First execute a successful rebalance to set lastRebalance");
        _depositToVault(makeAddr("depositor_cooldown"), 100e6);
        vm.warp(block.timestamp + 2 hours);
        vm.prank(bot);
        executor.executeRebalance(address(controller));
        _step(string.concat("  lastRebalance = ", vm.toString(controller.lastRebalance())));

        _step("[Step 2] Attempt another rebalance immediately (within cooldown), expect CooldownNotElapsed");
        _step("  This triggers a real downstream revert from StrategyController");
        vm.prank(bot);
        vm.expectRevert(StrategyController.CooldownNotElapsed.selector);
        executor.executeRebalance(address(controller));
        _step("  PASS: downstream CooldownNotElapsed revert propagated through executor");

        _logPass();
    }

    // =======================================================================
    // 11. test_ProcessRedeemBatch_Success  (P0)
    // =======================================================================

    function test_ProcessRedeemBatch_Success() public {
        _logCase("test_ProcessRedeemBatch_Success", unicode"BOT_ROLE 可成功执行 processRedeemBatch");

        _step("[Step 1] Create real redeem requests in vault");
        address user = makeAddr("redeemer");
        uint256 depositAmount = 300e6;
        uint256 shares = _depositToVault(user, depositAmount);
        _step(string.concat("  deposited ", vm.toString(depositAmount), " got shares = ", vm.toString(shares)));

        uint256 reqId1 = _createRedeemRequest(user, shares / 3);
        uint256 reqId2 = _createRedeemRequest(user, shares / 3);
        uint256 reqId3 = _createRedeemRequest(user, shares / 3);
        _step(string.concat("  requestIds = [", vm.toString(reqId1), ", ", vm.toString(reqId2), ", ", vm.toString(reqId3), "]"));

        _step("[Step 2] Prepare sorted ids array");
        uint256[] memory ids = new uint256[](3);
        ids[0] = reqId1;
        ids[1] = reqId2;
        ids[2] = reqId3;

        bytes32 expectedIdsHash = keccak256(abi.encodePacked(ids));
        _step(string.concat("  expectedIdsHash = ", vm.toString(expectedIdsHash)));

        _step("[Step 3] Compute batchKey for later verification");
        bytes32 batchKey = keccak256(abi.encode(ids));
        _step(string.concat("  batchKey = ", vm.toString(batchKey)));
        bool batchDoneBefore = controller.processingBatchDone(batchKey);
        _step(string.concat("  processingBatchDone before = ", vm.toString(batchDoneBefore)));
        assertFalse(batchDoneBefore, "batch should not be processed yet");

        _step("[Step 4] Set up expected event and execute processRedeemBatch");
        vm.expectEmit(true, true, false, true);
        emit ProcessRedeemBatchExecuted(bot, address(controller), expectedIdsHash);

        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), ids);
        _step("  PASS: executeProcessRedeemBatch completed without revert");

        _step("[Step 5] Verify processingBatchDone flag is set (real StrategyController state)");
        bool batchDoneAfter = controller.processingBatchDone(batchKey);
        _step(string.concat("  processingBatchDone after = ", vm.toString(batchDoneAfter)));
        assertTrue(batchDoneAfter, "batch should be marked as processed");
        _step("  PASS: processingBatchDone flag set on real controller");

        _step("[Step 6] Verify vault request statuses changed to PROCESSING");
        for (uint256 i = 0; i < ids.length; i++) {
            IMantleYieldVault.RequestStatus status = _vReqStatus(ids[i]);
            _step(string.concat("  request[", vm.toString(ids[i]), "] status = ", vm.toString(uint8(status))));
            assertEq(uint8(status), uint8(IMantleYieldVault.RequestStatus.PROCESSING), "request should be PROCESSING");
        }
        _step("  PASS: all requests moved to PROCESSING status");

        _logPass();
    }

    // =======================================================================
    // 12. test_ProcessRedeemBatch_IdsHashCorrect  (P1)
    // =======================================================================

    function test_ProcessRedeemBatch_IdsHashCorrect() public {
        _logCase("test_ProcessRedeemBatch_IdsHashCorrect", unicode"processRedeemBatch 事件中的 idsHash 正确");

        _step("[Step 1] Create real redeem requests and prepare sorted ids");
        address user = makeAddr("redeemer");
        uint256 shares = _depositToVault(user, 200e6);
        uint256 reqId1 = _createRedeemRequest(user, shares / 2);
        uint256 reqId2 = _createRedeemRequest(user, shares / 2);

        uint256[] memory ids = new uint256[](2);
        ids[0] = reqId1;
        ids[1] = reqId2;
        _step(string.concat("  ids = [", vm.toString(reqId1), ", ", vm.toString(reqId2), "]"));

        bytes32 expectedHash = keccak256(abi.encodePacked(ids));
        _step(string.concat("  expectedHash = ", vm.toString(expectedHash)));

        _step("[Step 2] Record logs and execute processRedeemBatch");
        vm.recordLogs();

        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), ids);
        _step("  PASS: call completed without revert");

        _step("[Step 3] Search recorded logs for ProcessRedeemBatchExecuted event");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        _step(string.concat("  total log entries: ", vm.toString(entries.length)));
        // Find ProcessRedeemBatchExecuted event
        bytes32 eventSig = keccak256("ProcessRedeemBatchExecuted(address,address,bytes32)");
        bool found;
        for (uint256 i; i < entries.length; i++) {
            if (entries[i].topics[0] == eventSig) {
                bytes32 emittedHash = abi.decode(entries[i].data, (bytes32));
                _step(string.concat("  emittedHash  = ", vm.toString(emittedHash)));
                assertEq(emittedHash, expectedHash, "idsHash mismatch");
                _step("  PASS: emitted idsHash matches expected");
                found = true;
                break;
            }
        }

        _step("[Step 4] Assert event was found");
        assertTrue(found, "ProcessRedeemBatchExecuted event not found");
        _step("  PASS: event found in logs");

        _logPass();
    }

    // =======================================================================
    // 13. test_FinalizeRedeemBatch_Success  (P0)
    // =======================================================================

    function test_FinalizeRedeemBatch_Success() public {
        _logCase("test_FinalizeRedeemBatch_Success", unicode"BOT_ROLE 可成功执行 finalizeRedeemBatch");

        _step("[Step 1] Create real redeem requests");
        address user = makeAddr("redeemer");
        uint256 depositAmount = 200e6;
        uint256 shares = _depositToVault(user, depositAmount);
        uint256 reqId1 = _createRedeemRequest(user, shares / 2);
        uint256 reqId2 = _createRedeemRequest(user, shares / 2);
        _step(string.concat("  requestIds = [", vm.toString(reqId1), ", ", vm.toString(reqId2), "]"));

        uint256[] memory ids = new uint256[](2);
        ids[0] = reqId1;
        ids[1] = reqId2;

        _step("[Step 2] First call processRedeemBatch (required precondition)");
        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), ids);
        _step("  PASS: processRedeemBatch completed");

        _step("[Step 3] Verify vault has enough cash for settlement (from initial deposit)");
        _step(string.concat("  vault asset balance = ", vm.toString(asset.balanceOf(address(vault)))));

        _step("[Step 4-6] Derive settled, compute hashes, expect event, finalize");
        (uint256[] memory settledAssets, address owner1, address owner2, uint256 settled1, uint256 settled2) =
            _prepareFinalizeAndExecute(ids, reqId1, reqId2);
        _step("  PASS: executeFinalizeRedeemBatch completed without revert");

        _step("[Step 7] Verify readyBatchDone flag is set");
        bytes32 batchKey = keccak256(abi.encode(ids));
        bool readyAfter = controller.readyBatchDone(batchKey);
        _step(string.concat("  readyBatchDone after = ", vm.toString(readyAfter)));
        assertTrue(readyAfter, "batch should be marked as ready");
        _step("  PASS: readyBatchDone flag set on real controller");

        _step("[Step 8] Verify vault request statuses changed to DONE");
        for (uint256 i = 0; i < ids.length; i++) {
            IMantleYieldVault.RequestStatus status = _vReqStatus(ids[i]);
            _step(string.concat("  request[", vm.toString(ids[i]), "] status = ", vm.toString(uint8(status))));
            assertEq(uint8(status), uint8(IMantleYieldVault.RequestStatus.DONE), "request should be DONE");
        }
        _step("  PASS: all requests moved to DONE status");

        _step("[Step 9] Verify owners received USDC from vault");
        assertGe(asset.balanceOf(owner1), settled1, "owner1 should receive USDC");
        assertGe(asset.balanceOf(owner2), settled2, "owner2 should receive USDC");
        _step("  PASS: owners received USDC");

        _logPass();
    }

    // =======================================================================
    // 14. test_FinalizeRedeemBatch_HashesCorrect  (P1)
    // =======================================================================

    function test_FinalizeRedeemBatch_HashesCorrect() public {
        _logCase("test_FinalizeRedeemBatch_HashesCorrect", unicode"finalizeRedeemBatch 事件中的 idsHash / settledAssetsHash 正确");

        _step("[Step 1] Create real redeem requests and process them first");
        address user = makeAddr("redeemer");
        uint256 shares = _depositToVault(user, 200e6);
        uint256 reqId1 = _createRedeemRequest(user, shares / 2);
        uint256 reqId2 = _createRedeemRequest(user, shares / 2);

        uint256[] memory ids = new uint256[](2);
        ids[0] = reqId1;
        ids[1] = reqId2;
        _step(string.concat("  ids = [", vm.toString(reqId1), ", ", vm.toString(reqId2), "]"));

        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), ids);
        _step("  processRedeemBatch completed (precondition)");

        _step("[Step 2] Derive settledAssets from shares * exchangeRate / 1e18 (contract formula) and compute expected hashes");
        uint256 s1 = _vReqShares(reqId1);
        uint256 s2 = _vReqShares(reqId2);
        uint256[] memory settledAssets = new uint256[](2);
        settledAssets[0] = (s1 * vault.exchangeRate()) / 1e18;
        settledAssets[1] = (s2 * vault.exchangeRate()) / 1e18;
        _step(string.concat("  settledAssets[0] = ", vm.toString(settledAssets[0]), " settledAssets[1] = ", vm.toString(settledAssets[1])));

        bytes32 expectedIdsHash = keccak256(abi.encodePacked(ids));
        bytes32 expectedSettledHash = keccak256(abi.encodePacked(settledAssets));
        _step(string.concat("  expectedIdsHash     = ", vm.toString(expectedIdsHash)));
        _step(string.concat("  expectedSettledHash  = ", vm.toString(expectedSettledHash)));

        _step("[Step 3] Record logs and execute finalizeRedeemBatch");
        vm.recordLogs();

        vm.prank(bot);
        executor.executeFinalizeRedeemBatch(address(controller), ids, settledAssets);
        _step("  PASS: call completed without revert");

        _step("[Step 4] Search recorded logs for FinalizeRedeemBatchExecuted event");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        _step(string.concat("  total log entries: ", vm.toString(entries.length)));
        bytes32 eventSig = keccak256("FinalizeRedeemBatchExecuted(address,address,bytes32,bytes32)");
        bool found;
        for (uint256 i; i < entries.length; i++) {
            if (entries[i].topics[0] == eventSig) {
                (bytes32 emittedIdsHash, bytes32 emittedSettledHash) =
                    abi.decode(entries[i].data, (bytes32, bytes32));
                _step(string.concat("  emittedIdsHash     = ", vm.toString(emittedIdsHash)));
                _step(string.concat("  emittedSettledHash  = ", vm.toString(emittedSettledHash)));
                assertEq(emittedIdsHash, expectedIdsHash, "idsHash mismatch");
                assertEq(emittedSettledHash, expectedSettledHash, "settledAssetsHash mismatch");
                _step("  PASS: both hashes match expected values");
                found = true;
                break;
            }
        }

        _step("[Step 5] Assert event was found");
        assertTrue(found, "FinalizeRedeemBatchExecuted event not found");
        _step("  PASS: event found in logs");

        _logPass();
    }

    // =======================================================================
    // 15. test_SettleAdapter_Success  (P0)
    // =======================================================================

    function test_SettleAdapter_Success() public {
        _logCase("test_SettleAdapter_Success", unicode"BOT_ROLE 可成功执行单个 adapter 结算");

        _step("[Step 1] Create invest in-flight via rebalance");
        uint256 investAmount = 100e6;
        uint256 inFlightId = _createInvestInFlightViaExecutor(investAmount);
        _step(string.concat("  inFlightId = ", vm.toString(inFlightId)));

        _step("[Step 2] Verify in-flight record is PENDING");
        IMantleYieldVault.InFlightStatus statusBefore = _vIfStatus(inFlightId);
        _step(string.concat("  in-flight status before = ", vm.toString(uint8(statusBefore))));
        assertEq(uint8(statusBefore), uint8(IMantleYieldVault.InFlightStatus.PENDING), "should be PENDING");

        uint256 investInFlightBefore = vault.totalInvestInFlight();
        _step(string.concat("  totalInvestInFlight before = ", vm.toString(investInFlightBefore)));
        assertGt(investInFlightBefore, 0, "should have pending invest in-flight");

        _step("[Step 3] Get in-flight details for settlement input");
        (address recAsset, uint256 recTokenAmt, uint256 recUsdcAmt) = _vIfAssetAndAmounts(inFlightId);
        _step(string.concat("  tokenAmt = ", vm.toString(recTokenAmt), ", usdcAmt = ", vm.toString(recUsdcAmt)));

        _step("[Step 4] Adapter already has posToken from deposit() during rebalance");
        _step(string.concat("  adapter posToken balance = ", vm.toString(posToken.balanceOf(address(asyncAdapter)))));

        _step("[Step 5] Prepare settlement input and execute settleAdapter");
        uint256[] memory investIds = new uint256[](1);
        investIds[0] = inFlightId;
        uint256[] memory settledPosAmounts = new uint256[](1);
        settledPosAmounts[0] = recTokenAmt;
        uint256[] memory refundAmounts = new uint256[](1);
        refundAmounts[0] = 0;
        uint256[] memory emptyIds = new uint256[](0);
        uint256[] memory emptyAmounts = new uint256[](0);

        vm.expectEmit(true, true, false, true);
        emit SettleAdapterExecuted(bot, address(controller), address(asyncAdapter));

        vm.prank(bot);
        executor.executeSettleAdapter(
            address(controller),
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(investIds, settledPosAmounts, refundAmounts),
            IStrategyControllerExecutor.RedeemSettlementInput(emptyIds, emptyAmounts)
        );
        _step("  PASS: executeSettleAdapter completed without revert");

        _step("[Step 6] Verify in-flight record changed to CONFIRMED");
        IMantleYieldVault.InFlightStatus statusAfter = _vIfStatus(inFlightId);
        _step(string.concat("  in-flight status after = ", vm.toString(uint8(statusAfter))));
        assertEq(uint8(statusAfter), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED), "should be CONFIRMED");
        _step("  PASS: in-flight confirmed on real controller");

        _step("[Step 7] Verify totalInvestInFlight decreased");
        uint256 investInFlightAfter = vault.totalInvestInFlight();
        _step(string.concat("  totalInvestInFlight after = ", vm.toString(investInFlightAfter)));
        assertLt(investInFlightAfter, investInFlightBefore, "invest in-flight should decrease");
        _step("  PASS: totalInvestInFlight reduced after settlement");

        _logPass();
    }

    // =======================================================================
    // 16. test_SettleAdapters_Success  (P0)
    // =======================================================================

    function test_SettleAdapters_Success() public {
        _logCase("test_SettleAdapters_Success", unicode"BOT_ROLE 可成功执行批量 adapter 结算");

        _step("[Step 1] Create invest in-flight via rebalance");
        uint256 investAmount = 100e6;
        uint256 inFlightId = _createInvestInFlightViaExecutor(investAmount);
        _step(string.concat("  inFlightId = ", vm.toString(inFlightId)));

        _step("[Step 2] Get in-flight details");
        uint256 recTokenAmt = _vIfTokenAmt(inFlightId);
        _step(string.concat("  tokenAmt = ", vm.toString(recTokenAmt)));

        _step("[Step 3] Adapter already has posToken from deposit() during rebalance");
        _step(string.concat("  adapter posToken balance = ", vm.toString(posToken.balanceOf(address(asyncAdapter)))));

        _step("[Step 4] Prepare batch settlement input (1 adapter)");
        address[] memory adapters = new address[](1);
        adapters[0] = address(asyncAdapter);

        uint256[] memory investIds = new uint256[](1);
        investIds[0] = inFlightId;
        uint256[] memory settledPosAmounts = new uint256[](1);
        settledPosAmounts[0] = recTokenAmt;
        uint256[] memory refundAmounts = new uint256[](1);
        refundAmounts[0] = 0;
        uint256[] memory emptyArr = new uint256[](0);

        IStrategyControllerExecutor.InvestSettlementInput[] memory investBatch =
            new IStrategyControllerExecutor.InvestSettlementInput[](1);
        investBatch[0] = IStrategyControllerExecutor.InvestSettlementInput(investIds, settledPosAmounts, refundAmounts);

        IStrategyControllerExecutor.RedeemSettlementInput[] memory redeemBatch =
            new IStrategyControllerExecutor.RedeemSettlementInput[](1);
        redeemBatch[0] = IStrategyControllerExecutor.RedeemSettlementInput(emptyArr, emptyArr);

        bytes32 expectedAdaptersHash = keccak256(abi.encodePacked(adapters));
        _step(string.concat("  expectedAdaptersHash = ", vm.toString(expectedAdaptersHash)));

        _step("[Step 5] Set up expected event and execute settleAdapters");
        vm.expectEmit(true, true, false, true);
        emit SettleAdaptersExecuted(bot, address(controller), expectedAdaptersHash);

        vm.prank(bot);
        executor.executeSettleAdapters(address(controller), adapters, investBatch, redeemBatch);
        _step("  PASS: executeSettleAdapters completed without revert");

        _step("[Step 6] Verify in-flight record changed to CONFIRMED");
        IMantleYieldVault.InFlightStatus statusAfter = _vIfStatus(inFlightId);
        _step(string.concat("  in-flight status after = ", vm.toString(uint8(statusAfter))));
        assertEq(uint8(statusAfter), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED), "should be CONFIRMED");
        _step("  PASS: in-flight confirmed via batch settlement on real controller");

        _logPass();
    }

    // =======================================================================
    // 17. test_SettleAdapters_HashCorrect  (P1)
    // =======================================================================

    function test_SettleAdapters_HashCorrect() public {
        _logCase("test_SettleAdapters_HashCorrect", unicode"executeSettleAdapters 事件中的 adaptersHash 正确");

        _step("[Step 1] Use real registered adapter with empty settlement arrays");
        address[] memory adapters = new address[](1);
        adapters[0] = address(asyncAdapter);
        _step(string.concat("  adapter[0]: ", vm.toString(adapters[0])));

        IStrategyControllerExecutor.InvestSettlementInput[] memory emptyInvest = new IStrategyControllerExecutor.InvestSettlementInput[](1);
        emptyInvest[0] = IStrategyControllerExecutor.InvestSettlementInput(new uint256[](0), new uint256[](0), new uint256[](0));
        IStrategyControllerExecutor.RedeemSettlementInput[] memory emptyRedeem = new IStrategyControllerExecutor.RedeemSettlementInput[](1);
        emptyRedeem[0] = IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0));

        bytes32 expectedHash = keccak256(abi.encodePacked(adapters));
        _step(string.concat("  expectedHash = ", vm.toString(expectedHash)));

        _step("[Step 2] Record logs and execute settleAdapters");
        vm.recordLogs();

        vm.prank(bot);
        executor.executeSettleAdapters(address(controller), adapters, emptyInvest, emptyRedeem);
        _step("  PASS: call completed without revert");

        _step("[Step 3] Search recorded logs for SettleAdaptersExecuted event");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        _step(string.concat("  total log entries: ", vm.toString(entries.length)));
        bytes32 eventSig = keccak256("SettleAdaptersExecuted(address,address,bytes32)");
        bool found;
        for (uint256 i; i < entries.length; i++) {
            if (entries[i].topics[0] == eventSig) {
                bytes32 emittedHash = abi.decode(entries[i].data, (bytes32));
                _step(string.concat("  emittedHash = ", vm.toString(emittedHash)));
                assertEq(emittedHash, expectedHash, "adaptersHash mismatch");
                _step("  PASS: adaptersHash matches expected");
                found = true;
                break;
            }
        }

        _step("[Step 4] Assert event was found");
        assertTrue(found, "SettleAdaptersExecuted event not found");
        _step("  PASS: event found in logs");

        _logPass();
    }

    // =======================================================================
    // 18. test_UUPS_OnlyAdminCanUpgrade  (P0)
    // =======================================================================

    function test_UUPS_OnlyAdminCanUpgrade() public {
        _logCase("test_UUPS_OnlyAdminCanUpgrade", unicode"UUPS 升级仅 admin 可执行");

        _step("[Step 1] Deploy OperatorExecutorV2 implementation");
        OperatorExecutorV2 newImpl = new OperatorExecutorV2();
        _step(string.concat("  newImpl address: ", vm.toString(address(newImpl))));

        _step("[Step 2] Non-admin attempts upgrade, expect revert");
        address notAdmin = makeAddr("notAdmin");
        _step(string.concat("  notAdmin: ", vm.toString(notAdmin)));
        vm.prank(notAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, notAdmin, DEFAULT_ADMIN_ROLE
            )
        );
        executor.upgradeToAndCall(address(newImpl), "");
        _step("  PASS: reverted as expected for unauthorized upgrade");

        _step("[Step 3] Admin performs upgrade - should succeed");
        vm.prank(admin);
        executor.upgradeToAndCall(address(newImpl), "");
        uint256 ver = OperatorExecutorV2(address(executor)).version();
        _step(string.concat("  version() = ", vm.toString(ver)));
        assertEq(ver, 2, "admin upgrade should succeed");
        _step("  PASS: admin upgrade succeeded, implementation is V2");

        _logPass();
    }

    // =======================================================================
    // 19. test_UUPS_RolesPreservedAfterUpgrade  (P1)
    // =======================================================================

    function test_UUPS_RolesPreservedAfterUpgrade() public {
        _logCase("test_UUPS_RolesPreservedAfterUpgrade", unicode"升级后角色状态保持不变");

        _step("[Step 1] Deploy V2 implementation and perform upgrade as admin");
        OperatorExecutorV2 newImpl = new OperatorExecutorV2();
        _step(string.concat("  newImpl address: ", vm.toString(address(newImpl))));

        vm.prank(admin);
        executor.upgradeToAndCall(address(newImpl), "");
        _step("  PASS: upgrade completed without revert");

        _step("[Step 2] Verify roles are preserved after upgrade");
        bool adminHasRole = executor.hasRole(DEFAULT_ADMIN_ROLE, admin);
        bool botHasRole = executor.hasRole(BOT_ROLE, bot);
        _step(string.concat("  hasRole(DEFAULT_ADMIN_ROLE, admin) = ", vm.toString(adminHasRole)));
        _step(string.concat("  hasRole(BOT_ROLE, bot) = ", vm.toString(botHasRole)));
        // roles still intact
        assertTrue(adminHasRole, "admin role lost after upgrade");
        assertTrue(botHasRole, "bot role lost after upgrade");
        _step("  PASS: both roles preserved");

        _step("[Step 3] Verify bot can still execute after upgrade");
        _depositToVault(makeAddr("depositor_upgrade"), 100e6);
        vm.warp(block.timestamp + 2 hours);
        uint64 lastRebalanceBefore = controller.lastRebalance();
        vm.prank(bot);
        executor.executeRebalance(address(controller));
        uint64 lastRebalanceAfter = controller.lastRebalance();
        _step(string.concat("  lastRebalance before = ", vm.toString(lastRebalanceBefore)));
        _step(string.concat("  lastRebalance after  = ", vm.toString(lastRebalanceAfter)));
        assertGt(lastRebalanceAfter, lastRebalanceBefore, "execution should work after upgrade");
        _step("  PASS: bot executed rebalance successfully after upgrade");

        _step("[Step 4] Verify implementation is V2");
        uint256 ver = OperatorExecutorV2(address(executor)).version();
        _step(string.concat("  version() = ", vm.toString(ver)));
        // verify V2
        assertEq(ver, 2, "should be V2");
        _step("  PASS: implementation is V2");

        _logPass();
    }

    // =======================================================================
    // 20. test_RevokeBot_ImmediateEffect  (P1)
    // =======================================================================

    function test_RevokeBot_ImmediateEffect() public {
        _logCase("test_RevokeBot_ImmediateEffect", unicode"撤销 bot 后该地址立即失去执行权限");

        _step("[Step 1] Confirm bot can execute before revocation");
        _depositToVault(makeAddr("depositor_revoke"), 100e6);
        vm.warp(block.timestamp + 2 hours);
        uint64 lastRebalanceBefore = controller.lastRebalance();
        vm.prank(bot);
        executor.executeRebalance(address(controller));
        assertGt(controller.lastRebalance(), lastRebalanceBefore, "rebalance should succeed");
        _step("  PASS: bot executed rebalance successfully");

        _step("[Step 2] Admin revokes BOT_ROLE from bot");
        _step(string.concat("  admin: ", vm.toString(admin)));
        _step(string.concat("  bot: ", vm.toString(bot)));
        vm.prank(admin);
        executor.revokeRole(BOT_ROLE, bot);

        _step("[Step 3] Verify bot no longer has BOT_ROLE");
        bool botHasRole = executor.hasRole(BOT_ROLE, bot);
        _step(string.concat("  hasRole(BOT_ROLE, bot) = ", vm.toString(botHasRole)));
        assertFalse(botHasRole, "bot should no longer have BOT_ROLE");
        _step("  PASS: BOT_ROLE revoked");

        _step("[Step 4] Attempt executeRebalance as revoked bot, expect revert");
        vm.warp(block.timestamp + 2 hours);
        vm.prank(bot);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bot, BOT_ROLE)
        );
        executor.executeRebalance(address(controller));
        _step("  PASS: reverted as expected after revocation");

        _logPass();
    }

    // =======================================================================
    // 21. test_GrantBot_ImmediateEffect  (P1)
    // =======================================================================

    function test_GrantBot_ImmediateEffect() public {
        _logCase("test_GrantBot_ImmediateEffect", unicode"新增 bot 后可立即执行操作");

        address newBot = makeAddr("newBot");
        _step(string.concat("[Step 1] Create newBot address: ", vm.toString(newBot)));

        _step("[Step 2] Confirm newBot cannot execute before grant");
        vm.prank(newBot);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, newBot, BOT_ROLE)
        );
        executor.executeRebalance(address(controller));
        _step("  PASS: reverted as expected before grant");

        _step("[Step 3] Admin grants BOT_ROLE to newBot");
        vm.prank(admin);
        executor.grantRole(BOT_ROLE, newBot);

        bool hasRole = executor.hasRole(BOT_ROLE, newBot);
        _step(string.concat("  hasRole(BOT_ROLE, newBot) = ", vm.toString(hasRole)));
        assertTrue(hasRole, "newBot should have BOT_ROLE");
        _step("  PASS: BOT_ROLE granted");

        _step("[Step 4] Verify newBot can execute immediately after grant");
        _depositToVault(makeAddr("depositor_grant"), 100e6);
        vm.warp(block.timestamp + 2 hours);
        uint64 lastRebalanceBefore = controller.lastRebalance();
        vm.prank(newBot);
        executor.executeRebalance(address(controller));
        uint64 lastRebalanceAfter = controller.lastRebalance();
        _step(string.concat("  lastRebalance before = ", vm.toString(lastRebalanceBefore)));
        _step(string.concat("  lastRebalance after  = ", vm.toString(lastRebalanceAfter)));
        assertGt(lastRebalanceAfter, lastRebalanceBefore, "newBot should be able to execute after grant");
        _step("  PASS: newBot executed rebalance successfully");

        _logPass();
    }

    // =======================================================================
    // 22. test_ProcessRedeemBatch_EmptyIds  (P1)
    // =======================================================================

    function test_ProcessRedeemBatch_EmptyIds() public {
        _logCase("test_ProcessRedeemBatch_EmptyIds", unicode"空 ids 数组是否允许取决于下游 Controller");

        _step("[Step 1] Prepare empty ids array");
        uint256[] memory ids = new uint256[](0);
        _step(string.concat("  ids.length = ", vm.toString(ids.length)));

        _step("[Step 2] Bot calls executeProcessRedeemBatch with empty ids");
        bytes32 batchKey = keccak256(abi.encode(ids));
        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), ids);
        _step("  PASS: OperatorExecutor does not validate empty array; call forwarded to downstream");

        _step("[Step 3] Verify empty array was processed by controller");
        bool batchDone = controller.processingBatchDone(batchKey);
        _step(string.concat("  processingBatchDone = ", vm.toString(batchDone)));
        assertTrue(batchDone, "empty batch should be marked as processed");
        _step("  PASS: downstream processed empty ids array");

        _step("[Step 4] Call again with same empty ids - real downstream revert (BatchAlreadyProcessed)");
        _step("  This demonstrates that downstream controller validates and reverts when appropriate");
        vm.prank(bot);
        vm.expectRevert(abi.encodeWithSelector(StrategyController.BatchAlreadyProcessed.selector, batchKey));
        executor.executeProcessRedeemBatch(address(controller), ids);
        _step("  PASS: downstream BatchAlreadyProcessed revert propagated; entire call reverted");

        _logPass();
    }

    // =======================================================================
    // 23. test_FinalizeRedeemBatch_LengthMismatch  (P1)
    // =======================================================================

    function test_FinalizeRedeemBatch_LengthMismatch() public {
        _logCase("test_FinalizeRedeemBatch_LengthMismatch", unicode"ids 与 settledAssets 长度不一致时是否回滚由下游决定");

        _step("[Step 1] Create real requests and process them first");
        address user = makeAddr("redeemer");
        uint256 shares = _depositToVault(user, 200e6);
        uint256 reqId1 = _createRedeemRequest(user, shares / 2);
        uint256 reqId2 = _createRedeemRequest(user, shares / 2);
        _step(string.concat("  requestIds = [", vm.toString(reqId1), ", ", vm.toString(reqId2), "]"));

        uint256[] memory ids = new uint256[](2);
        ids[0] = reqId1;
        ids[1] = reqId2;

        _step("[Step 2] Process the batch first (required precondition for finalize)");
        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), ids);
        _step("  PASS: processRedeemBatch completed");

        _step("[Step 3] Prepare mismatched settledAssets (length 1 vs ids length 2)");
        uint256[] memory settledAssets = new uint256[](1);
        settledAssets[0] = 100e6;
        _step(string.concat("  ids.length = ", vm.toString(ids.length)));
        _step(string.concat("  settledAssets.length = ", vm.toString(settledAssets.length)));

        _step("[Step 4] Bot calls executeFinalizeRedeemBatch with mismatched lengths");
        _step("  OperatorExecutor does not validate array lengths; downstream controller does");
        vm.prank(bot);
        vm.expectRevert(StrategyController.ClaimInputsLengthMismatch.selector);
        executor.executeFinalizeRedeemBatch(address(controller), ids, settledAssets);
        _step("  PASS: downstream ClaimInputsLengthMismatch revert propagated; entire call reverted");

        _step("[Step 5] Verify readyBatchDone remains false (finalize did not succeed)");
        bytes32 batchKey = keccak256(abi.encode(ids));
        bool readyDone = controller.readyBatchDone(batchKey);
        _step(string.concat("  readyBatchDone = ", vm.toString(readyDone)));
        assertFalse(readyDone, "batch should not be marked ready after revert");
        _step("  PASS: downstream revert prevented state change");

        _logPass();
    }

    // =======================================================================
    // 24. test_SettleAdapter_DownstreamParamValidation  (P1)
    // =======================================================================

    function test_SettleAdapter_DownstreamParamValidation() public {
        _logCase("test_SettleAdapter_DownstreamParamValidation", unicode"executeSettleAdapter 是否回滚取决于下游参数校验");

        _step("[Step 1] Prepare mismatched settle input (investIds len != settledPosAmounts len)");
        uint256[] memory investIds = new uint256[](2);
        investIds[0] = 1;
        investIds[1] = 2;
        uint256[] memory investAmounts = new uint256[](1);
        investAmounts[0] = 100e6;
        uint256[] memory refundAmounts = new uint256[](1);
        refundAmounts[0] = 0;
        uint256[] memory emptyArr = new uint256[](0);
        _step(string.concat("  investIds.length = ", vm.toString(investIds.length)));
        _step(string.concat("  investAmounts.length = ", vm.toString(investAmounts.length)));

        _step("[Step 2] Bot calls executeSettleAdapter with mismatched lengths");
        _step("  OperatorExecutor does not validate array lengths; downstream controller does");
        vm.prank(bot);
        vm.expectRevert(StrategyController.SettleAmountsLengthMismatch.selector);
        executor.executeSettleAdapter(
            address(controller),
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(investIds, investAmounts, refundAmounts),
            IStrategyControllerExecutor.RedeemSettlementInput(emptyArr, emptyArr)
        );
        _step("  PASS: downstream SettleAmountsLengthMismatch revert propagated");

        _step("[Step 3] Verify with correctly-lengthed but non-zero posAmount and no adapter balance");
        _step("  Adapter has no posToken, so sweep fails before in-flight validation");
        uint256[] memory fakeIds = new uint256[](1);
        fakeIds[0] = 999;
        uint256[] memory fakeAmounts = new uint256[](1);
        fakeAmounts[0] = 100;
        uint256[] memory fakeRefunds = new uint256[](1);
        fakeRefunds[0] = 0;

        vm.prank(bot);
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyController.InvestSweepAmountMismatch.selector, address(asyncAdapter), uint256(100), uint256(0)
            )
        );
        executor.executeSettleAdapter(
            address(controller),
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(fakeIds, fakeAmounts, fakeRefunds),
            IStrategyControllerExecutor.RedeemSettlementInput(emptyArr, emptyArr)
        );
        _step("  PASS: downstream InvestSweepAmountMismatch revert propagated; entire call reverted");

        _logPass();
    }

    // =======================================================================
    // 25. test_SettleAdapters_BatchDimensionMismatch  (P1)
    // =======================================================================

    function test_SettleAdapters_BatchDimensionMismatch() public {
        _logCase("test_SettleAdapters_BatchDimensionMismatch", unicode"executeSettleAdapters 的批量维度合法性由下游决定");

        _step("[Step 1] Prepare mismatched batch dimensions: 2 adapters but 1 investBatch entry");
        address[] memory adapters = new address[](2);
        adapters[0] = address(asyncAdapter);
        adapters[1] = makeAddr("adapterB");
        _step(string.concat("  adapters.length = ", vm.toString(adapters.length)));

        IStrategyControllerExecutor.InvestSettlementInput[] memory investBatch =
            new IStrategyControllerExecutor.InvestSettlementInput[](1);
        investBatch[0] = IStrategyControllerExecutor.InvestSettlementInput(new uint256[](0), new uint256[](0), new uint256[](0));

        IStrategyControllerExecutor.RedeemSettlementInput[] memory redeemBatch =
            new IStrategyControllerExecutor.RedeemSettlementInput[](2);
        redeemBatch[0] = IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0));
        redeemBatch[1] = IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0));

        _step(string.concat("  adapters.length = ", vm.toString(adapters.length)));
        _step(string.concat("  investBatch.length = ", vm.toString(investBatch.length)));
        _step(string.concat("  redeemBatch.length = ", vm.toString(redeemBatch.length)));

        _step("[Step 2] Bot calls executeSettleAdapters with mismatched batch dimensions");
        _step("  OperatorExecutor does not validate batch dimensions; downstream controller does");
        vm.prank(bot);
        vm.expectRevert(StrategyController.SettleAmountsLengthMismatch.selector);
        executor.executeSettleAdapters(
            address(controller), adapters, investBatch, redeemBatch
        );
        _step("  PASS: downstream SettleAmountsLengthMismatch revert propagated; entire call reverted");

        _logPass();
    }

    // =======================================================================
    // 26. test_UUPS_ExecuteWorksAfterUpgrade  (P1)
    // =======================================================================

    function test_UUPS_ExecuteWorksAfterUpgrade() public {
        _logCase("test_UUPS_ExecuteWorksAfterUpgrade", unicode"升级后执行能力保持正常");

        _step("[Step 1] Deploy V2 implementation and perform upgrade as admin");
        OperatorExecutorV2 newImpl = new OperatorExecutorV2();
        _step(string.concat("  newImpl address: ", vm.toString(address(newImpl))));

        vm.prank(admin);
        executor.upgradeToAndCall(address(newImpl), "");
        _step("  PASS: upgrade completed without revert");

        _step("[Step 2] Verify implementation is V2");
        uint256 ver = OperatorExecutorV2(address(executor)).version();
        _step(string.concat("  version() = ", vm.toString(ver)));
        assertEq(ver, 2, "should be V2");
        _step("  PASS: implementation is V2");

        _step("[Step 3] Verify bot still has BOT_ROLE");
        bool botHasRole = executor.hasRole(BOT_ROLE, bot);
        _step(string.concat("  hasRole(BOT_ROLE, bot) = ", vm.toString(botHasRole)));
        assertTrue(botHasRole, "bot should still have BOT_ROLE after upgrade");
        _step("  PASS: bot role preserved");

        _step("[Step 4] Bot calls executeProcessRedeemBatch after upgrade");
        address user = makeAddr("redeemer");
        uint256 shares = _depositToVault(user, 200e6);
        uint256 reqId1 = _createRedeemRequest(user, shares / 2);
        uint256 reqId2 = _createRedeemRequest(user, shares / 2);
        uint256[] memory ids = new uint256[](2);
        ids[0] = reqId1;
        ids[1] = reqId2;

        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), ids);

        bytes32 batchKey = keccak256(abi.encode(ids));
        bool batchDone = controller.processingBatchDone(batchKey);
        _step(string.concat("  processingBatchDone = ", vm.toString(batchDone)));
        assertTrue(batchDone, "processRedeemBatch should work after upgrade");
        _step("  PASS: executeProcessRedeemBatch routes correctly to downstream after upgrade");

        _step("[Step 5] Bot calls executeRebalance after upgrade (invest flow)");
        _depositToVault(makeAddr("depositor_upgrade2"), 100e6);
        vm.warp(block.timestamp + 2 hours);
        uint64 lastRebalanceBefore = controller.lastRebalance();
        vm.prank(bot);
        executor.executeRebalance(address(controller));
        assertGt(controller.lastRebalance(), lastRebalanceBefore, "rebalance should work after upgrade");
        _step("  PASS: executeRebalance routes correctly to downstream after upgrade");

        _logPass();
    }

    // =======================================================================
    // 27. test_UUPS_DirectImplUpgradeFails  (UUPS spec #4)
    // =======================================================================

    function test_UUPS_DirectImplUpgradeFails() public {
        _logCase("test_UUPS_DirectImplUpgradeFails", unicode"直接对实现合约调用升级应失败");

        _step("[Step 1] Deploy a fresh OperatorExecutor implementation (not behind proxy)");
        OperatorExecutor impl = new OperatorExecutor();
        _step(string.concat("  impl address: ", vm.toString(address(impl))));

        _step("[Step 2] Deploy V2 implementation");
        OperatorExecutorV2 implV2 = new OperatorExecutorV2();
        _step(string.concat("  implV2 address: ", vm.toString(address(implV2))));

        _step("[Step 3] Attempt upgradeToAndCall directly on implementation (not via proxy)");
        _step("  Should revert with UUPSUnauthorizedCallContext (onlyProxy protection)");
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("UUPSUnauthorizedCallContext()"))));
        impl.upgradeToAndCall(address(implV2), "");
        _step("  PASS: direct implementation upgrade reverted as expected");

        _logPass();
    }

    // =======================================================================
    // 28. test_UUPS_UpgradeToNonUUPSFails  (UUPS spec #5)
    // =======================================================================

    function test_UUPS_UpgradeToNonUUPSFails() public {
        _logCase("test_UUPS_UpgradeToNonUUPSFails", unicode"升级到非 UUPS 实现应失败");

        _step("[Step 1] Deploy a non-UUPS contract");
        NotUUPSContract notUups = new NotUUPSContract();
        _step(string.concat("  notUups address: ", vm.toString(address(notUups))));

        _step("[Step 2] Attempt upgradeToAndCall to non-UUPS implementation as admin");
        _step("  Should revert because the target does not satisfy UUPS proxiableUUID check");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("ERC1967InvalidImplementation(address)")), address(notUups)));
        executor.upgradeToAndCall(address(notUups), "");
        _step("  PASS: upgrade to non-UUPS implementation reverted as expected");

        _logPass();
    }
}
