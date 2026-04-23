// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategyAdapter} from "../../src/interfaces/adapters/IStrategyAdapter.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {OperatorExecutor} from "../../src/protocol/OperatorExecutor.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test, console2} from "forge-std/Test.sol";
import {IStrategyControllerExecutor} from "../../src/interfaces/strategy/IStrategyControllerExecutor.sol";

contract MockAssetIF is ERC20 {
    constructor() ERC20("MockAsset", "mAST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract MockAdapterIF is IStrategyAdapter {
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
        return "MockAdapterIF";
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
        // Real behavior: pull USDC from vault (vault already approved via approveToAdapter)
        IERC20(ASSET).transferFrom(VAULT, address(this), amount);
        // Real behavior: USDC leaves adapter to SubRed (burn to simulate)
        MockAssetIF(ASSET).burn(address(this), amount);
        // Simulate DiGiFT fulfillment: posToken arrives at adapter
        MockAssetIF(POS_TOKEN).mint(address(this), amount);
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
        // Real behavior: pull posToken from vault (vault approved via approveToAdapter)
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

contract MockVaultIF {
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
        return address(this); // vault 自己作为 share token
    }

    function setGateway(address gateway_) external {
        gateway = gateway_;
    }

    // ============ Gateway Only Methods ============

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

    function setRequest(
        uint256 id,
        address owner,
        uint256 shares,
        uint256 estimatedAssets,
        uint256 settledAssets,
        IMantleYieldVault.RequestStatus status
    ) external {
        reqs[id] = Req({
            id: id,
            owner: owner,
            shares: shares,
            feeShares: 0,
            estimatedAssets: estimatedAssets,
            settledAssets: settledAssets,
            timestamp: block.timestamp,
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

contract InFlightLifecycleTest is Test {
    MockAssetIF internal asset;
    MockAssetIF internal posToken;
    MockVaultIF internal vault;
    StrategyController internal controller;
    OperatorExecutor internal executor;
    MockAdapterIF internal asyncAdapter;

    address internal admin = makeAddr("admin");
    address internal bot = makeAddr("bot");
    address internal manager = makeAddr("manager");

    function setUp() public {
        asset = new MockAssetIF();
        posToken = new MockAssetIF();
        vault = new MockVaultIF(address(asset));

        OperatorExecutor execImpl = new OperatorExecutor();
        executor = OperatorExecutor(address(new ERC1967Proxy(
            address(execImpl),
            abi.encodeCall(OperatorExecutor.initialize, (admin, bot))
        )));

        StrategyController implementation = new StrategyController();
        bytes memory initData = abi.encodeCall(
            StrategyController.initialize,
            (address(vault), manager, address(executor), manager, 1000, 200, 1 hours)
        );
        controller = StrategyController(address(new ERC1967Proxy(address(implementation), initData)));

        asyncAdapter = new MockAdapterIF(address(asset), address(posToken));
        asyncAdapter.setVault(address(vault));

        // Register and activate async adapter with weight 10000
        vm.startPrank(manager);
        controller.registerStrategy(address(asyncAdapter), 10_000, 1, true);
        controller.activateStrategy(address(asyncAdapter));
        address[] memory ordered = new address[](1);
        ordered[0] = address(asyncAdapter);
        controller.setStrategyOrder(ordered);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------
    // Helper: 用户存入 asset，获得 shares (真实调用流程)
    // ---------------------------------------------------------------
    function _depositToVault(address user, uint256 assetAmount) internal returns (uint256 shares) {
        asset.mint(user, assetAmount);
        vm.prank(user);
        asset.approve(address(vault), assetAmount);
        // depositFor does transferFrom(sender, vault, assets) internally
        shares = vault.depositFor(user, assetAmount, user);
    }

    // ---------------------------------------------------------------
    // Helper: 用户发起赎回请求 (真实调用流程)
    // ---------------------------------------------------------------
    function _createRedeemRequest(address user, uint256 shares) internal returns (uint256 requestId) {
        requestId = vault.requestRedeemFor(user, user, shares);
    }

    // ---------------------------------------------------------------
    // Helper: create an invest in-flight via rebalance (真实调用流程)
    // ---------------------------------------------------------------
    function _createInvestInFlightViaRebalance(uint256 investAmount) internal returns (uint256 inFlightId) {
        // Use real deposit flow to get USDC into vault
        address depositor = makeAddr("depositor_invest");
        _depositToVault(depositor, investAmount);

        vm.warp(block.timestamp + 2 hours);
        uint256 idBefore = vault.nextInFlightId();
        vm.prank(bot);
        executor.executeRebalance(address(controller));
        require(vault.nextInFlightId() > idBefore, "No invest in-flight created");
        inFlightId = vault.nextInFlightId() - 1;
    }

    // ---------------------------------------------------------------
    // Helper: create a redeem in-flight via processRedeemBatch (真实调用流程)
    // 关键：processRedeemBatch 只在 freeCash < batchTotalAsset 时才触发 divest
    // 所以需要确保 vault 没有足够的 freeCash，资金在 adapter 中
    // ---------------------------------------------------------------
    function _createRedeemInFlightViaProcessBatch(address user, uint256 assetAmount) internal returns (uint256 inFlightId, uint256 requestId) {
        // 1. User deposits to vault (USDC goes to vault, user gets shares)
        _depositToVault(user, assetAmount);

        // 2. Rebalance to invest USDC to adapter
        vm.warp(block.timestamp + 2 hours);
        uint256 investIdBefore = vault.nextInFlightId();
        vm.prank(bot);
        executor.executeRebalance(address(controller));
        uint256 investId = vault.nextInFlightId() - 1;

        // 3. Settle the invest (sweep posToken from adapter to vault)
        (,,, uint256 tokenAmt,,,,,) = vault.inFlightRecords(investId);
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
        // Now: vault has posToken (totalValue > 0), vault has 0 USDC (freeCash = 0)

        // 4. User requests redeem
        uint256 shares = vault.sharesOf(user);
        requestId = _createRedeemRequest(user, shares);

        // 5. processRedeemBatch - freeCash=0 < batchTotalAsset -> triggers divest
        vm.warp(block.timestamp + 2 hours);
        uint256 idBefore = vault.nextInFlightId();
        uint256[] memory ids = new uint256[](1);
        ids[0] = requestId;
        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), ids);

        require(vault.nextInFlightId() > idBefore, "No redeem in-flight created");
        inFlightId = vault.nextInFlightId() - 1;
    }

    // ---------------------------------------------------------------
    // Helper: create an invest in-flight on the vault mock directly (保留用于边界测试)
    // ---------------------------------------------------------------
    function _createInvestInFlight(uint256 tokenAmt, uint256 usdcAmt) internal returns (uint256) {
        return vault.createInFlight(address(asyncAdapter), address(posToken), tokenAmt, usdcAmt, true);
    }

    // ---------------------------------------------------------------
    // Helper: create a redeem in-flight on the vault mock directly (保留用于边界测试)
    // ---------------------------------------------------------------
    function _createRedeemInFlight(uint256 tokenAmt, uint256 usdcAmt) internal returns (uint256) {
        return vault.createInFlight(address(asyncAdapter), address(asset), tokenAmt, usdcAmt, false);
    }

    string constant MODULE = unicode"In-Flight 生命周期场景";
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

    // ================================================================
    // Test 1 - P0: Create invest in-flight succeeds (真实调用流程)
    // 流程: Vault有freeCash → rebalance() → _invest() → adapter.deposit() → vault.createInFlight()
    // ================================================================
    function test_CreateInvestInFlight_Success() public {
        _logCase("test_CreateInvestInFlight_Success", unicode"Controller 创建 invest in-flight 记录成功");

        _step("[Step 1] Snapshot invest in-flight totals before creation");
        uint256 investBefore = vault.investInFlightTotal();
        uint256 adapterBefore = vault.adapterInvestInFlightTokens(address(asyncAdapter));
        _step(string.concat("  investInFlightTotal before = ", vm.toString(investBefore)));
        _step(string.concat("  adapterInvestInFlightTokens before = ", vm.toString(adapterBefore)));

        _step(unicode"[Step 2] Create invest in-flight via rebalance (真实调用流程)");
        uint256 investAmount = 100e6;
        uint256 id = _createInvestInFlightViaRebalance(investAmount);
        _step(string.concat("  investAmount = ", vm.toString(investAmount)));
        _step(string.concat("  inFlightId = ", vm.toString(id)));

        // Verify id assigned
        assertTrue(id >= 1, "id should be >= 1");
        _step(string.concat("  PASS: id = ", vm.toString(id)));

        _step("[Step 3] Verify in-flight record stored correctly");
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
        ) = vault.inFlightRecords(id);

        _step(string.concat("  recId = ", vm.toString(recId)));
        _step(string.concat("  recAdapter = ", vm.toString(recAdapter)));
        _step(string.concat("  recAsset = ", vm.toString(recAsset)));
        _step(string.concat("  recTokenAmt = ", vm.toString(recTokenAmt)));
        _step(string.concat("  recUsdcAmt = ", vm.toString(recUsdcAmt)));
        _step(string.concat("  recSettled = ", vm.toString(recSettled)));
        _step(string.concat("  recIsInvest = ", vm.toString(recIsInvest)));
        _step(string.concat("  recStatus = ", vm.toString(uint8(recStatus))));

        assertEq(recId, id);
        assertEq(recAdapter, address(asyncAdapter));
        assertEq(recAsset, address(posToken));
        assertTrue(recTokenAmt > 0, "tokenAmt should be > 0");
        assertTrue(recUsdcAmt > 0, "usdcAmt should be > 0");
        assertEq(recSettled, 0);
        assertTrue(recIsInvest);
        assertEq(uint8(recStatus), uint8(IMantleYieldVault.InFlightStatus.PENDING));
        _step("  PASS: all record fields match expected values");

        _step("[Step 4] Verify invest in-flight totals increased");
        _step(string.concat("  investInFlightTotal after = ", vm.toString(vault.investInFlightTotal())));
        _step(string.concat("  adapterInvestInFlightTokens after = ", vm.toString(vault.adapterInvestInFlightTokens(address(asyncAdapter)))));
        assertTrue(vault.investInFlightTotal() > investBefore, "investInFlightTotal should increase");
        assertTrue(vault.adapterInvestInFlightTokens(address(asyncAdapter)) > adapterBefore, "adapterInvestInFlightTokens should increase");
        _step("  PASS: totals increased");
        _logPass();
    }

    // ================================================================
    // Test 2 - P0: Create redeem in-flight succeeds
    // ================================================================
    // Test 2 - P0: Create redeem in-flight succeeds (真实调用流程)
    // 流程: 用户存入 → 发起赎回请求 → processRedeemBatch() → _divest() → vault.createInFlight()
    // ================================================================
    function test_CreateRedeemInFlight_Success() public {
        _logCase("test_CreateRedeemInFlight_Success", unicode"Controller 创建 redeem in-flight 记录成功");

        _step("[Step 1] Snapshot redeem in-flight totals before creation");
        uint256 redeemBefore = vault.redeemInFlightTotal();
        uint256 adapterBefore = vault.adapterRedeemInFlightUsdc(address(asyncAdapter));
        _step(string.concat("  redeemInFlightTotal before = ", vm.toString(redeemBefore)));
        _step(string.concat("  adapterRedeemInFlightUsdc before = ", vm.toString(adapterBefore)));

        _step(unicode"[Step 2] Create redeem in-flight via processRedeemBatch (真实调用流程)");
        address user = makeAddr("redeemUser");
        uint256 redeemAmount = 50e6;
        (uint256 id, uint256 requestId) = _createRedeemInFlightViaProcessBatch(user, redeemAmount);
        _step(string.concat("  user = ", vm.toString(user)));
        _step(string.concat("  redeemAmount = ", vm.toString(redeemAmount)));
        _step(string.concat("  requestId = ", vm.toString(requestId)));
        _step(string.concat("  inFlightId = ", vm.toString(id)));

        assertTrue(id >= 1, "id should be >= 1");
        _step(string.concat("  PASS: id = ", vm.toString(id)));

        _step("[Step 3] Verify in-flight record stored correctly");
        (
            uint256 recId,
            address recAdapter,
            ,
            uint256 recTokenAmt,
            uint256 recUsdcAmt,
            uint256 recSettled,
            bool recIsInvest,
            ,
            IMantleYieldVault.InFlightStatus recStatus
        ) = vault.inFlightRecords(id);

        _step(string.concat("  recId = ", vm.toString(recId)));
        _step(string.concat("  recAdapter = ", vm.toString(recAdapter)));
        _step(string.concat("  recTokenAmt = ", vm.toString(recTokenAmt)));
        _step(string.concat("  recUsdcAmt = ", vm.toString(recUsdcAmt)));
        _step(string.concat("  recSettled = ", vm.toString(recSettled)));
        _step(string.concat("  recIsInvest = ", vm.toString(recIsInvest)));
        _step(string.concat("  recStatus = ", vm.toString(uint8(recStatus))));

        assertEq(recId, id);
        assertEq(recAdapter, address(asyncAdapter));
        assertTrue(recTokenAmt > 0 || recUsdcAmt > 0, "should have token or usdc amount");
        assertEq(recSettled, 0);
        assertFalse(recIsInvest);
        assertEq(uint8(recStatus), uint8(IMantleYieldVault.InFlightStatus.PENDING));
        _step("  PASS: all record fields match expected values");

        _step("[Step 4] Verify redeem in-flight totals increased");
        _step(string.concat("  redeemInFlightTotal after = ", vm.toString(vault.redeemInFlightTotal())));
        _step(string.concat("  adapterRedeemInFlightUsdc after = ", vm.toString(vault.adapterRedeemInFlightUsdc(address(asyncAdapter)))));
        assertTrue(vault.redeemInFlightTotal() > redeemBefore, "redeemInFlightTotal should increase");
        _step("  PASS: totals increased");
        _logPass();
    }

    // ================================================================
    // Test 3 - P0: Settle rejects unregistered adapter
    // ================================================================
    function test_CreateInFlight_RevertUnregisteredAdapter() public {
        _logCase("test_CreateInFlight_RevertUnregisteredAdapter", unicode"未注册 adapter 不能创建 in-flight");

        _step("[Step 1] Deploy an unregistered adapter");
        // Create a second adapter that is NOT registered with the controller
        MockAdapterIF unregisteredAdapter = new MockAdapterIF(address(asset), address(posToken));
        _step(string.concat("  unregisteredAdapter = ", vm.toString(address(unregisteredAdapter))));

        _step("[Step 2] Create invest in-flight on vault for the unregistered adapter");
        // Create an invest in-flight on the vault for the unregistered adapter
        uint256 id = vault.createInFlight(address(unregisteredAdapter), address(posToken), 10e18, 10e18, true);
        _step(string.concat("  inFlightId = ", vm.toString(id)));

        _step("[Step 3] Prepare settleAdapter call with unregistered adapter");
        uint256[] memory investInFlightIds = new uint256[](1);
        investInFlightIds[0] = id;
        uint256[] memory investSettledAmounts = new uint256[](1);
        investSettledAmounts[0] = 10e18;
        _step(string.concat("  caller = bot via executor = ", vm.toString(address(executor))));

        _step("[Step 4] Expect revert with InvalidStrategy for unregistered adapter");
        // settleAdapter should revert because unregisteredAdapter is not a registered strategy
        vm.prank(bot);
        vm.expectRevert(
            abi.encodeWithSelector(StrategyController.InvalidStrategy.selector, address(unregisteredAdapter))
        );
        executor.executeSettleAdapter(
            address(controller),
            address(unregisteredAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(investInFlightIds, investSettledAmounts, new uint256[](investInFlightIds.length)),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );
        _step("  PASS: reverted as expected with InvalidStrategy");
        _logPass();
    }

    // ================================================================
    // Test 4 - P0: Settle rejects zero-amount in-flight (tokenAmount == 0)
    // ================================================================
    function test_CreateInFlight_RevertZeroAmount() public {
        _logCase("test_CreateInFlight_RevertZeroAmount", unicode"0 数量不能创建 in-flight");

        _step("[Step 1] Create invest in-flight with tokenAmount=0 (invalid edge case)");
        // Create an invest in-flight with tokenAmount=0 on the vault
        uint256 id = vault.createInFlight(address(asyncAdapter), address(posToken), 0, 10e18, true);
        _step(string.concat("  inFlightId = ", vm.toString(id)));
        _step(string.concat("  tokenAmount = ", vm.toString(uint256(0)), ", usdcAmount = ", vm.toString(uint256(10e18))));

        _step("[Step 2] Prepare settleAdapter call with settledPos=0 so sweep passes, confirm catches tokenAmount==0");
        uint256[] memory investInFlightIds = new uint256[](1);
        investInFlightIds[0] = id;
        uint256[] memory investSettledAmounts = new uint256[](1);
        investSettledAmounts[0] = 0; // 0 so sweep phase has nothing to sweep, confirm phase checks tokenAmount==0
        uint256[] memory refundAmounts = new uint256[](1);
        refundAmounts[0] = 0;

        _step("[Step 3] Expect revert with InvalidInvestInFlight due to tokenAmount == 0");
        // Sweep phase: totalPos=0 totalRefund=0 -> no sweep -> passes
        // Confirm phase: tokenAmount==0 -> reverts with InvalidInvestInFlight
        vm.prank(bot);
        vm.expectRevert(abi.encodeWithSelector(StrategyController.InvalidInvestInFlight.selector, id));
        executor.executeSettleAdapter(
            address(controller),
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(investInFlightIds, investSettledAmounts, refundAmounts),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );
        _step("  PASS: reverted as expected with InvalidInvestInFlight");
        _logPass();
    }

    // ================================================================
    // Test 5 - P0: Invest 结算：全额成交（pos>0, refund=0）
    // 真实调用流程：rebalance -> settleAdapter
    // ================================================================
    function test_InvestSettlement_FullExecution() public {
        _logCase("test_InvestSettlement_FullExecution", unicode"invest 结算：全额成交（pos>0, refund=0）");

        _step(unicode"[Step 1] Create invest in-flight via rebalance (真实调用流程)");
        uint256 investAmount = 100e6;
        uint256 id = _createInvestInFlightViaRebalance(investAmount);
        _step(string.concat("  invested ", vm.toString(investAmount), " via rebalance"));
        (,,,uint256 tokenAmt, uint256 usdcAmt,, bool isInvest,,) = vault.inFlightRecords(id);
        _step(string.concat("  inFlightId = ", vm.toString(id)));
        _step(string.concat("  tokenAmt = ", vm.toString(tokenAmt)));
        _step(string.concat("  usdcAmt = ", vm.toString(usdcAmt)));
        assertTrue(isInvest, "Should be invest in-flight");

        _step("[Step 2] Adapter already has posToken from real deposit, no additional setup needed");
        // Full execution: pos=tokenAmt, refund=0
        // Adapter has posToken from deposit(), sweepToVault will transfer real tokens
        _step(string.concat("  adapter posToken balance = ", vm.toString(IERC20(address(posToken)).balanceOf(address(asyncAdapter)))));
        _step("  refundAssetAmount = 0 (no asset sweep)");

        uint256[] memory investInFlightIds = new uint256[](1);
        investInFlightIds[0] = id;
        uint256[] memory settledPosAmounts = new uint256[](1);
        settledPosAmounts[0] = tokenAmt;
        uint256[] memory refundAssetAmounts = new uint256[](1);
        refundAssetAmounts[0] = 0; // 全额成交，无退款

        _step(unicode"[Step 3] Call settleAdapter with InvestSettlementInput (真实调用流程)");
        uint256 vaultPosBefore = posToken.balanceOf(address(vault));
        vm.prank(bot);
        executor.executeSettleAdapter(
            address(controller),
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(investInFlightIds, settledPosAmounts, refundAssetAmounts),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );
        uint256 vaultPosAfter = posToken.balanceOf(address(vault));
        assertEq(vaultPosAfter - vaultPosBefore, tokenAmt, "vault should receive posToken from invest settle");
        _step("  settleAdapter executed successfully");

        _step("[Step 4] Verify in-flight record is CONFIRMED with settledAmount = tokenAmt");
        (,,,,, uint256 settledAmount, bool recIsInvest,, IMantleYieldVault.InFlightStatus status) =
            vault.inFlightRecords(id);

        _step(string.concat("  isInvest = ", vm.toString(recIsInvest)));
        _step(string.concat("  status = ", vm.toString(uint8(status))));
        _step(string.concat("  settledAmount = ", vm.toString(settledAmount)));

        assertTrue(recIsInvest);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(settledAmount, tokenAmt);
        _step("  PASS: status is CONFIRMED and settledAmount matches full pos amount");

        _step("[Step 5] Verify invest in-flight totals decreased to zero");
        _step(string.concat("  investInFlightTotal = ", vm.toString(vault.investInFlightTotal())));
        _step(string.concat("  adapterInvestInFlightTokens = ", vm.toString(vault.adapterInvestInFlightTokens(address(asyncAdapter)))));
        assertEq(vault.investInFlightTotal(), 0);
        assertEq(vault.adapterInvestInFlightTokens(address(asyncAdapter)), 0);
        _step("  PASS: totals decreased to zero (full execution, no refund)");
        _logPass();
    }

    // ================================================================
    // Test 6 - P0: Confirm redeem in-flight via settleAdapter (真实调用流程)
    // 流程: 用户存入 → 发起赎回请求 → processRedeemBatch() → settleAdapter()
    // ================================================================
    function test_ConfirmRedeemInFlight_Success() public {
        _logCase("test_ConfirmRedeemInFlight_Success", unicode"confirm redeem in-flight 后状态变为 CONFIRMED 且统计减少");

        _step(unicode"[Step 1] Create redeem in-flight via processRedeemBatch (真实调用流程)");
        address user = makeAddr("redeemUser6");
        uint256 redeemAmount = 80e6;
        (uint256 id, uint256 requestId) = _createRedeemInFlightViaProcessBatch(user, redeemAmount);
        _step(string.concat("  user = ", vm.toString(user)));
        _step(string.concat("  redeemAmount = ", vm.toString(redeemAmount)));
        _step(string.concat("  requestId = ", vm.toString(requestId)));
        _step(string.concat("  inFlightId = ", vm.toString(id)));

        // 获取实际创建的 in-flight 数据
        (,,,, uint256 usdcAmt,,,,) = vault.inFlightRecords(id);

        _step("[Step 2] Mint asset to adapter (simulate DiGiFT sending USDC)");
        // USDC settlement arrives at adapter, not vault
        asset.mint(address(asyncAdapter), usdcAmt);
        _step(string.concat("  minted ", vm.toString(usdcAmt), " to adapter"));

        _step("[Step 3] Call settleAdapter to confirm redeem in-flight");
        uint256[] memory redeemInFlightIds = new uint256[](1);
        redeemInFlightIds[0] = id;
        uint256[] memory redeemSettledAmounts = new uint256[](1);
        redeemSettledAmounts[0] = usdcAmt;

        uint256 vaultUsdcBefore = asset.balanceOf(address(vault));
        vm.prank(bot);
        executor.executeSettleAdapter(
            address(controller),
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(new uint256[](0), new uint256[](0), new uint256[](0)),
            IStrategyControllerExecutor.RedeemSettlementInput(redeemInFlightIds, redeemSettledAmounts)
        );
        uint256 vaultUsdcAfter = asset.balanceOf(address(vault));
        assertEq(vaultUsdcAfter - vaultUsdcBefore, usdcAmt, "vault should receive USDC from redeem settle");
        _step("  settleAdapter executed successfully");

        _step("[Step 4] Verify in-flight record is CONFIRMED");
        // Verify record confirmed
        (,,,,, uint256 settledAmount, bool isInvest,, IMantleYieldVault.InFlightStatus status) =
            vault.inFlightRecords(id);

        _step(string.concat("  isInvest = ", vm.toString(isInvest)));
        _step(string.concat("  status = ", vm.toString(uint8(status))));
        _step(string.concat("  settledAmount = ", vm.toString(settledAmount)));

        assertFalse(isInvest);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(settledAmount, usdcAmt);
        _step("  PASS: status is CONFIRMED and settledAmount matches");

        _step("[Step 5] Verify redeem in-flight totals decreased to zero");
        _step(string.concat("  redeemInFlightTotal = ", vm.toString(vault.redeemInFlightTotal())));
        _step(string.concat("  adapterRedeemInFlightUsdc = ", vm.toString(vault.adapterRedeemInFlightUsdc(address(asyncAdapter)))));
        // Verify totals decreased
        assertEq(vault.redeemInFlightTotal(), 0);
        assertEq(vault.adapterRedeemInFlightUsdc(address(asyncAdapter)), 0);
        _step("  PASS: totals decreased to zero");
        _logPass();
    }

    // ================================================================
    // Test 7 - P1: Confirm in-flight records actual (differing) amount (真实调用流程)
    // 流程: rebalance() → settleAdapter() with differing amount
    // ================================================================
    function test_ConfirmInFlight_ActualAmountDiffers() public {
        _logCase("test_ConfirmInFlight_ActualAmountDiffers", unicode"底层回填资金确认时，应允许按真实到账金额确认 in-flight，并将偏差传导到最终结算");

        _step(unicode"[Step 1] Create invest in-flight via rebalance (真实调用流程)");
        uint256 investAmount = 100e6;
        uint256 id = _createInvestInFlightViaRebalance(investAmount);

        // 获取实际创建的 in-flight 数据
        (,,, uint256 tokenAmt,,,,,) = vault.inFlightRecords(id);
        uint256 actualSettled = tokenAmt * 99 / 100; // 实际到账 99%

        _step(string.concat("  inFlightId = ", vm.toString(id)));
        _step(string.concat("  original tokenAmt = ", vm.toString(tokenAmt)));
        _step(string.concat("  actualSettled (differs) = ", vm.toString(actualSettled)));

        _step("[Step 2] Simulate partial fulfillment: burn excess posToken, mint refund USDC");
        // Adapter has full posToken from deposit. Simulate partial: burn excess, mint USDC refund
        uint256 excessPos = tokenAmt - actualSettled;
        posToken.burn(address(asyncAdapter), excessPos);
        uint256 refundAmount = investAmount - (investAmount * actualSettled / tokenAmt);
        asset.mint(address(asyncAdapter), refundAmount);

        uint256[] memory investInFlightIds = new uint256[](1);
        investInFlightIds[0] = id;
        uint256[] memory investSettledAmounts = new uint256[](1);
        investSettledAmounts[0] = actualSettled;
        uint256[] memory refundAssetAmounts = new uint256[](1);
        refundAssetAmounts[0] = refundAmount;

        vm.prank(bot);
        executor.executeSettleAdapter(
            address(controller),
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(investInFlightIds, investSettledAmounts, refundAssetAmounts),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );
        _step("  settleAdapter executed successfully");

        _step("[Step 3] Verify record is CONFIRMED with actual (differing) amount");
        (,,,,, uint256 settledAmount, bool isInvest2,, IMantleYieldVault.InFlightStatus status) =
            vault.inFlightRecords(id);

        _step(string.concat("  isInvest = ", vm.toString(isInvest2)));
        _step(string.concat("  status = ", vm.toString(uint8(status))));
        _step(string.concat("  settledAmount = ", vm.toString(settledAmount)));

        assertTrue(isInvest2);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        _step("  PASS: status is CONFIRMED");

        // Settled amount reflects actual, not original
        assertEq(settledAmount, actualSettled);
        assertTrue(settledAmount < tokenAmt);
        _step(string.concat("  PASS: settledAmount (", vm.toString(settledAmount), ") < original tokenAmt (", vm.toString(tokenAmt), ")"));
        _logPass();
    }

    // ================================================================
    // Test 8 - P1: Duplicate confirm reverts (already CONFIRMED) (真实调用流程)
    // 流程: rebalance() → settleAdapter() → settleAdapter() (duplicate)
    // ================================================================
    function test_ConfirmInFlight_RevertDuplicateConfirm() public {
        _logCase("test_ConfirmInFlight_RevertDuplicateConfirm", unicode"重复 confirm 同一 in-flight 被拒绝");

        _step(unicode"[Step 1] Create invest in-flight via rebalance (真实调用流程)");
        uint256 investAmount = 50e6;
        uint256 id = _createInvestInFlightViaRebalance(investAmount);
        _step(string.concat("  inFlightId = ", vm.toString(id)));

        // 获取实际创建的 in-flight 数据
        (,,, uint256 tokenAmt,,,,,) = vault.inFlightRecords(id);

        _step("[Step 2] First settleAdapter call to confirm the in-flight");
        // Adapter already has posToken from real deposit

        uint256[] memory investInFlightIds = new uint256[](1);
        investInFlightIds[0] = id;
        uint256[] memory investSettledAmounts = new uint256[](1);
        investSettledAmounts[0] = tokenAmt;
        uint256[] memory refundAssetAmounts = new uint256[](1);
        refundAssetAmounts[0] = 0; // 全额成交

        vm.prank(bot);
        executor.executeSettleAdapter(
            address(controller),
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(investInFlightIds, investSettledAmounts, refundAssetAmounts),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );
        _step("  first settleAdapter executed successfully");

        _step("[Step 3] Verify in-flight is now CONFIRMED");
        // Verify confirmed
        (,,,,,,,, IMantleYieldVault.InFlightStatus status) = vault.inFlightRecords(id);
        _step(string.concat("  status = ", vm.toString(uint8(status))));
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        _step("  PASS: status is CONFIRMED after first settle");

        _step("[Step 4] Second settleAdapter with same id - expect revert");
        // Mint posToken to adapter so sweep phase passes; confirm phase will catch CONFIRMED status
        posToken.mint(address(asyncAdapter), tokenAmt);

        vm.prank(bot);
        vm.expectRevert(abi.encodeWithSelector(StrategyController.InvalidInvestInFlight.selector, id));
        executor.executeSettleAdapter(
            address(controller),
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(investInFlightIds, investSettledAmounts, refundAssetAmounts),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );
        _step("  PASS: reverted as expected with InvalidInvestInFlight (duplicate confirm rejected)");
        _logPass();
    }

    // ================================================================
    // Test 9 - P1: Abnormal confirm allows zero settled amount (真实调用流程)
    // 流程: rebalance() → settleAdapter() with pos=0 (full refund scenario)
    // ================================================================
    function test_ConfirmInFlight_AbnormalAllowsZeroAmount() public {
        _logCase("test_ConfirmInFlight_AbnormalAllowsZeroAmount", unicode"confirmInFlight 在异常确认模式下允许 actualAmount=0");

        _step(unicode"[Step 1] Create invest in-flight via rebalance (真实调用流程)");
        uint256 investAmount = 100e6;
        uint256 id = _createInvestInFlightViaRebalance(investAmount);

        // 获取实际创建的 in-flight 数据
        (,,, uint256 tokenAmt, uint256 usdcAmt,,,,) = vault.inFlightRecords(id);
        _step(string.concat("  inFlightId = ", vm.toString(id)));
        _step(string.concat("  tokenAmt = ", vm.toString(tokenAmt)));
        _step(string.concat("  usdcAmt = ", vm.toString(usdcAmt)));

        _step("[Step 2] Simulate full refund: burn all posToken, mint USDC refund to adapter");
        // Settle with settledAmount = 0 (abnormal flag = true internally when settledAmount == 0)
        uint256 settledPos = 0;
        uint256 refundAsset = investAmount;
        // Burn all posToken on adapter (order cancelled), mint full USDC refund
        posToken.burn(address(asyncAdapter), tokenAmt);
        asset.mint(address(asyncAdapter), refundAsset);
        _step(string.concat("  settledPos = ", vm.toString(settledPos)));
        _step(string.concat("  refundAsset = ", vm.toString(refundAsset)));
        _step("  (triggers abnormal confirm path)");

        uint256[] memory investInFlightIds = new uint256[](1);
        investInFlightIds[0] = id;
        uint256[] memory investSettledAmounts = new uint256[](1);
        investSettledAmounts[0] = settledPos;
        uint256[] memory refundAssetAmounts = new uint256[](1);
        refundAssetAmounts[0] = refundAsset;

        vm.prank(bot);
        executor.executeSettleAdapter(
            address(controller),
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(investInFlightIds, investSettledAmounts, refundAssetAmounts),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );
        _step("  settleAdapter executed successfully (no revert)");

        _step("[Step 3] Verify record is CONFIRMED with settledAmount = 0");
        (,,,,, uint256 settledAmount, bool isInvest,, IMantleYieldVault.InFlightStatus status) =
            vault.inFlightRecords(id);

        _step(string.concat("  isInvest = ", vm.toString(isInvest)));
        _step(string.concat("  status = ", vm.toString(uint8(status))));
        _step(string.concat("  settledAmount = ", vm.toString(settledAmount)));

        assertTrue(isInvest);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(settledAmount, 0);
        _step("  PASS: abnormal confirm accepted with zero settled amount (full refund)");
        _logPass();
    }

    // ================================================================
    // Test 10 - P1: Non-abnormal redeem rejects zero settled amount
    //   For redeem in-flight, usdcAmount == 0 means InvalidRedeemInFlight
    // ================================================================
    function test_ConfirmInFlight_NonAbnormalRejectsZeroAmount() public {
        _logCase("test_ConfirmInFlight_NonAbnormalRejectsZeroAmount", unicode"confirmInFlight 在非异常确认模式下拒绝 actualAmount=0");

        _step("[Step 1] Create redeem in-flight with usdcAmount = 0 (invalid edge case)");
        // Create a redeem in-flight with usdcAmount = 0 (edge case)
        uint256 id = vault.createInFlight(address(asyncAdapter), address(asset), 50e18, 0, false);
        _step(string.concat("  inFlightId = ", vm.toString(id)));
        _step(string.concat("  tokenAmount = ", vm.toString(uint256(50e18)), ", usdcAmount = ", vm.toString(uint256(0))));

        _step("[Step 2] Prepare settleAdapter call with zero settled amounts");
        uint256[] memory redeemInFlightIds = new uint256[](1);
        redeemInFlightIds[0] = id;
        uint256[] memory redeemSettledAmounts = new uint256[](1);
        redeemSettledAmounts[0] = 0;

        _step("  redeemSettledAmounts[0] = 0");

        _step("[Step 3] Expect revert with InvalidRedeemInFlight due to usdcAmount == 0");
        // Controller's _confirmRedeemInFlightIds checks usdcAmount == 0 and reverts
        vm.prank(bot);
        vm.expectRevert(abi.encodeWithSelector(StrategyController.InvalidRedeemInFlight.selector, id));
        executor.executeSettleAdapter(
            address(controller),
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(new uint256[](0), new uint256[](0), new uint256[](0)),
            IStrategyControllerExecutor.RedeemSettlementInput(redeemInFlightIds, redeemSettledAmounts)
        );
        _step("  PASS: reverted as expected with InvalidRedeemInFlight");
        _logPass();
    }

    // ================================================================
    // Test 11 - P0: Invest 结算：部分退款（pos>0, refund>0）(真实调用流程)
    // 流程: rebalance() → settleAdapter() with partial pos and refund
    // ================================================================
    function test_InvestSettlement_PartialRefund() public {
        _logCase("test_InvestSettlement_PartialRefund", unicode"invest 结算：部分退款（pos>0, refund>0）");

        _step(unicode"[Step 1] Create invest in-flight via rebalance (真实调用流程)");
        uint256 investAmount = 100e6;
        uint256 id = _createInvestInFlightViaRebalance(investAmount);

        // 获取实际创建的 in-flight 数据
        (,,, uint256 tokenAmt, uint256 usdcAmt,,,,) = vault.inFlightRecords(id);
        _step(string.concat("  inFlightId = ", vm.toString(id)));
        _step(string.concat("  tokenAmt = ", vm.toString(tokenAmt)));
        _step(string.concat("  usdcAmt = ", vm.toString(usdcAmt)));

        _step("[Step 2] Simulate partial fulfillment (70% pos, 30% refund)");
        uint256 settledPos = tokenAmt * 70 / 100;
        uint256 refundAsset = investAmount * 30 / 100;
        // Burn 30% posToken, mint 30% USDC refund to adapter
        uint256 excessPos = tokenAmt - settledPos;
        posToken.burn(address(asyncAdapter), excessPos);
        asset.mint(address(asyncAdapter), refundAsset);
        _step(string.concat("  settledPos = ", vm.toString(settledPos)));
        _step(string.concat("  refundAsset = ", vm.toString(refundAsset)));

        uint256[] memory investInFlightIds = new uint256[](1);
        investInFlightIds[0] = id;
        uint256[] memory settledPosAmounts = new uint256[](1);
        settledPosAmounts[0] = settledPos;
        uint256[] memory refundAssetAmounts = new uint256[](1);
        refundAssetAmounts[0] = refundAsset;

        _step("[Step 3] Call settleAdapter with InvestSettlementInput");
        vm.prank(bot);
        executor.executeSettleAdapter(
            address(controller),
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(investInFlightIds, settledPosAmounts, refundAssetAmounts),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );
        _step("  settleAdapter executed successfully");

        _step("[Step 4] Verify sweep was called for both posToken and asset");
        // MockAdapterIF 的 claimCount 应该是 2（posToken + asset 各一次）
        assertEq(asyncAdapter.claimCount(), 2);
        _step(string.concat("  claimCount = ", vm.toString(asyncAdapter.claimCount()), " (posToken + asset)"));

        _step("[Step 5] Verify in-flight record is CONFIRMED with settledAmount = settledPos");
        (,,,,, uint256 settledAmount, bool isInvest,, IMantleYieldVault.InFlightStatus status) =
            vault.inFlightRecords(id);

        _step(string.concat("  isInvest = ", vm.toString(isInvest)));
        _step(string.concat("  status = ", vm.toString(uint8(status))));
        _step(string.concat("  settledAmount = ", vm.toString(settledAmount)));

        assertTrue(isInvest);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(settledAmount, settledPos);
        _step("  PASS: status is CONFIRMED, settledAmount reflects partial pos");

        _step("[Step 6] Verify invest in-flight totals decreased");
        assertEq(vault.investInFlightTotal(), 0);
        assertEq(vault.adapterInvestInFlightTokens(address(asyncAdapter)), 0);
        _step("  PASS: totals decreased to zero after partial refund settlement");
        _logPass();
    }

    // ================================================================
    // Test 12 - P0: Invest 结算：全额退款（pos=0, refund>0）(真实调用流程)
    // 流程: rebalance() → settleAdapter() with pos=0 and full refund
    // ================================================================
    function test_InvestSettlement_FullRefund() public {
        _logCase("test_InvestSettlement_FullRefund", unicode"invest 结算：全额退款（pos=0, refund>0）");

        _step(unicode"[Step 1] Create invest in-flight via rebalance (真实调用流程)");
        uint256 investAmount = 100e6;
        uint256 id = _createInvestInFlightViaRebalance(investAmount);

        // 获取实际创建的 in-flight 数据
        (,,, uint256 tokenAmt, uint256 usdcAmt,,,,) = vault.inFlightRecords(id);
        _step(string.concat("  inFlightId = ", vm.toString(id)));
        _step(string.concat("  tokenAmt = ", vm.toString(tokenAmt)));
        _step(string.concat("  usdcAmt = ", vm.toString(usdcAmt)));

        _step("[Step 2] Simulate full refund: burn all posToken, mint USDC refund to adapter");
        // Full refund: pos=0, refund=full (order cancelled)
        uint256 settledPos = 0;
        uint256 refundAsset = investAmount;
        posToken.burn(address(asyncAdapter), tokenAmt);
        asset.mint(address(asyncAdapter), refundAsset);
        _step(string.concat("  settledPosAmount = ", vm.toString(settledPos), " (no pos token)"));
        _step(string.concat("  refundAsset = ", vm.toString(refundAsset)));

        uint256[] memory investInFlightIds = new uint256[](1);
        investInFlightIds[0] = id;
        uint256[] memory settledPosAmounts = new uint256[](1);
        settledPosAmounts[0] = settledPos;
        uint256[] memory refundAssetAmounts = new uint256[](1);
        refundAssetAmounts[0] = refundAsset;

        _step("[Step 3] Call settleAdapter with pos=0, refund=full");
        vm.prank(bot);
        executor.executeSettleAdapter(
            address(controller),
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(investInFlightIds, settledPosAmounts, refundAssetAmounts),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );
        _step("  settleAdapter executed successfully (abnormal confirm path)");

        _step("[Step 4] Verify only asset sweep was called (no posToken sweep for pos=0)");
        assertEq(asyncAdapter.claimCount(), 1);
        assertEq(asyncAdapter.lastClaimToken(), address(asset));
        assertEq(asyncAdapter.lastClaimAmount(), refundAsset);
        _step(string.concat("  claimCount = ", vm.toString(asyncAdapter.claimCount()), " (only asset)"));
        _step(string.concat("  lastClaimToken = asset"));

        _step("[Step 5] Verify in-flight record is CONFIRMED with settledAmount = 0 (abnormal)");
        (,,,,, uint256 settledAmount, bool isInvest,, IMantleYieldVault.InFlightStatus status) =
            vault.inFlightRecords(id);

        _step(string.concat("  isInvest = ", vm.toString(isInvest)));
        _step(string.concat("  status = ", vm.toString(uint8(status))));
        _step(string.concat("  settledAmount = ", vm.toString(settledAmount)));

        assertTrue(isInvest);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(settledAmount, 0); // abnormal confirm: settledAmount = 0
        _step("  PASS: abnormal confirm succeeded, settledAmount = 0 (full refund)");

        _step("[Step 6] Verify invest in-flight totals decreased");
        assertEq(vault.investInFlightTotal(), 0);
        assertEq(vault.adapterInvestInFlightTokens(address(asyncAdapter)), 0);
        _step("  PASS: totals decreased to zero after full refund");
        _logPass();
    }

    // ================================================================
    // Test 13 - P1: Invest 结算：pos sweep 数量不足时回滚 (真实调用流程)
    // 流程: rebalance() → settleAdapter() with mismatched pos sweep
    // ================================================================
    function test_InvestSettlement_RevertPosSweepMismatch() public {
        _logCase("test_InvestSettlement_RevertPosSweepMismatch", unicode"invest 结算：pos sweep 数量不足时整笔回滚");

        _step(unicode"[Step 1] Create invest in-flight via rebalance (真实调用流程)");
        uint256 investAmount = 100e6;
        uint256 id = _createInvestInFlightViaRebalance(investAmount);

        // 获取实际创建的 in-flight 数据
        (,,, uint256 tokenAmt,,,,,) = vault.inFlightRecords(id);
        _step(string.concat("  inFlightId = ", vm.toString(id)));
        _step(string.concat("  tokenAmt = ", vm.toString(tokenAmt)));

        _step("[Step 2] Burn some posToken so adapter has less than expected (90%)");
        uint256 requestedPos = tokenAmt;
        uint256 actualPos = tokenAmt * 90 / 100;
        // Burn 10% posToken so sweep can only return 90%
        uint256 excess = tokenAmt - actualPos;
        posToken.burn(address(asyncAdapter), excess);
        _step(string.concat("  requestedPos = ", vm.toString(requestedPos)));
        _step(string.concat("  actualPos (adapter balance) = ", vm.toString(actualPos)));

        uint256[] memory investInFlightIds = new uint256[](1);
        investInFlightIds[0] = id;
        uint256[] memory settledPosAmounts = new uint256[](1);
        settledPosAmounts[0] = requestedPos;
        uint256[] memory refundAssetAmounts = new uint256[](1);
        refundAssetAmounts[0] = 0;

        _step("[Step 3] Expect revert with InvestSweepAmountMismatch");
        vm.prank(bot);
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyController.InvestSweepAmountMismatch.selector,
                address(asyncAdapter),
                requestedPos,
                actualPos
            )
        );
        executor.executeSettleAdapter(
            address(controller),
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(investInFlightIds, settledPosAmounts, refundAssetAmounts),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );
        _step("  PASS: reverted as expected with InvestSweepAmountMismatch");

        _step("[Step 4] Verify in-flight remains PENDING");
        (,,,,,,,, IMantleYieldVault.InFlightStatus status) = vault.inFlightRecords(id);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.PENDING));
        _step("  PASS: in-flight status still PENDING (rollback succeeded)");
        _logPass();
    }

    // ================================================================
    // Test 14 - P1: Invest 结算：refund sweep 数量不足时回滚 (真实调用流程)
    // 流程: rebalance() → settleAdapter() with mismatched refund sweep
    // ================================================================
    function test_InvestSettlement_RevertRefundSweepMismatch() public {
        _logCase("test_InvestSettlement_RevertRefundSweepMismatch", unicode"invest 结算：refund sweep 数量不足时整笔回滚");

        _step(unicode"[Step 1] Create invest in-flight via rebalance (真实调用流程)");
        uint256 investAmount = 100e6;
        uint256 id = _createInvestInFlightViaRebalance(investAmount);

        // 获取实际创建的 in-flight 数据
        (,,, uint256 tokenAmt,,,,,) = vault.inFlightRecords(id);
        _step(string.concat("  inFlightId = ", vm.toString(id)));
        _step(string.concat("  tokenAmt = ", vm.toString(tokenAmt)));

        _step("[Step 2] Simulate partial fulfillment: posToken ok (70%), but refund short");
        uint256 settledPos = tokenAmt * 70 / 100;
        uint256 requestedRefund = investAmount * 30 / 100; // 30% refund requested
        uint256 actualRefund = requestedRefund * 2 / 3; // only 2/3 of refund available
        // Burn excess posToken (30%), mint only partial USDC refund to adapter
        uint256 excessPos = tokenAmt - settledPos;
        posToken.burn(address(asyncAdapter), excessPos);
        asset.mint(address(asyncAdapter), actualRefund);
        _step(string.concat("  settledPos = ", vm.toString(settledPos)));
        _step(string.concat("  requestedRefund = ", vm.toString(requestedRefund)));
        _step(string.concat("  actualRefund (adapter balance) = ", vm.toString(actualRefund)));

        uint256[] memory investInFlightIds = new uint256[](1);
        investInFlightIds[0] = id;
        uint256[] memory settledPosAmounts = new uint256[](1);
        settledPosAmounts[0] = settledPos;
        uint256[] memory refundAssetAmounts = new uint256[](1);
        refundAssetAmounts[0] = requestedRefund;

        _step("[Step 3] Expect revert with InvestRefundSweepAmountMismatch");
        vm.prank(bot);
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyController.InvestRefundSweepAmountMismatch.selector,
                address(asyncAdapter),
                requestedRefund,
                actualRefund
            )
        );
        executor.executeSettleAdapter(
            address(controller),
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(investInFlightIds, settledPosAmounts, refundAssetAmounts),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );
        _step("  PASS: reverted as expected with InvestRefundSweepAmountMismatch");

        _step("[Step 4] Verify in-flight remains PENDING");
        (,,,,,,,, IMantleYieldVault.InFlightStatus status) = vault.inFlightRecords(id);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.PENDING));
        _step("  PASS: in-flight status still PENDING (rollback succeeded)");
        _logPass();
    }
}
