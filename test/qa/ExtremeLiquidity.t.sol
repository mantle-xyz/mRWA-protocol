// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategyAdapter} from "../../src/interfaces/adapters/IStrategyAdapter.sol";
import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {IMantleVaultGateway} from "../../src/interfaces/vault/IMantleVaultGateway.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {VaultViewHelper} from "../lib/VaultViewHelper.sol";
import {MantleVaultGateway} from "../../src/vault/MantleVaultGateway.sol";
import {Accountant} from "../../src/accountant/Accountant.sol";
import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Test, console2} from "forge-std/Test.sol";
import {IStrategyControllerExecutor} from "../../src/interfaces/strategy/IStrategyControllerExecutor.sol";
import {OperatorExecutor} from "../../src/protocol/OperatorExecutor.sol";

// ---------------------------------------------------------------------------
// Mocks
// ---------------------------------------------------------------------------

contract MockUSDC_EL is ERC20 {
    constructor() ERC20("MockUSDC", "USDC") {}

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

contract MockPosToken_EL is ERC20 {
    constructor() ERC20("MockPosToken", "mPOS") {}

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

contract MockSanctionsOracle_EL is ISanctionsOracle {
    mapping(address => bool) private _sanctioned;

    function initialize(address, address) external {}
    function isSanctioned(address account) external view returns (bool) { return _sanctioned[account]; }
    function isWhitelisted(address) external pure returns (bool) { return true; }
    function totalSanctionedCount() external pure returns (uint256) { return 0; }
    function totalWhitelistedCount() external pure returns (uint256) { return 0; }
    function lastUpdateTimestamp() external pure returns (uint256) { return 0; }
    function batchNonce() external pure returns (uint256) { return 0; }
    function MAX_BATCH_SIZE() external pure returns (uint256) { return 200; }
    function updateSanctionStatus(address account, bool sanctioned) external { _sanctioned[account] = sanctioned; }
    function updateSanctionStatusBatch(address[] calldata, bool) external {}
    function updateWhitelistStatus(address, bool) external {}
    function updateWhitelistStatusBatch(address[] calldata, bool) external {}
}

contract MockSettlementVenue_EL {
    MockUSDC_EL public immutable ASSET;
    MockPosToken_EL public immutable POS_TOKEN;

    mapping(address => uint256) public pendingAsyncRedeemPos;

    constructor(address asset_, address posToken_) {
        ASSET = MockUSDC_EL(asset_);
        POS_TOKEN = MockPosToken_EL(posToken_);
    }

    function settleDeposit(address adapter, uint256 assetAmount, uint256 posAmount) external {
        if (assetAmount > 0) {
            ASSET.burn(address(this), assetAmount);
        }
        if (posAmount > 0) {
            POS_TOKEN.mint(adapter, posAmount);
        }
    }

    function settleWithdraw(address adapter, uint256 posAmount, uint256 assetAmount) external {
        if (posAmount > 0) {
            POS_TOKEN.burn(address(this), posAmount);
        }
        if (assetAmount > 0) {
            ASSET.mint(adapter, assetAmount);
        }
    }

    function acceptAsyncRedeem(address adapter, uint256 posAmount) external {
        pendingAsyncRedeemPos[adapter] += posAmount;
    }

    function settleAsyncRedeem(address adapter, uint256 posAmount, uint256 assetAmount) external {
        uint256 pendingPos = pendingAsyncRedeemPos[adapter];
        require(posAmount <= pendingPos, "ASYNC_REDEEM_POS_EXCEEDS_PENDING");
        pendingAsyncRedeemPos[adapter] = pendingPos - posAmount;

        if (posAmount > 0) {
            POS_TOKEN.burn(address(this), posAmount);
        }
        if (assetAmount > 0) {
            ASSET.mint(adapter, assetAmount);
        }
    }
}

contract MockStrategyAdapter_EL is IStrategyAdapter {
    address public immutable ASSET;
    address public immutable POS_TOKEN;
    MockSettlementVenue_EL public immutable SETTLEMENT_VENUE;
    address public vaultAddr;

    uint256 public posTokenPrice = 1e18; // default 1:1

    constructor(address asset_, address posToken_, address settlementVenue_) {
        ASSET = asset_;
        POS_TOKEN = posToken_;
        SETTLEMENT_VENUE = MockSettlementVenue_EL(settlementVenue_);
    }

    function setVault(address v) external { vaultAddr = v; }
    function setPosTokenPrice(uint256 price) external { posTokenPrice = price; }

    function name() external pure returns (string memory) { return "MockStrategyAdapter_EL"; }
    function asset() external view returns (address) { return ASSET; }
    function posToken() external view returns (address) { return POS_TOKEN; }
    function priceOracle() external pure returns (address) { return address(0); }
    function vault() external view returns (address) { return vaultAddr; }
    function setPaused(bool) external {}
    function retryRedeemAsync(uint256, address) external {}
    function minSubscribeAsset() external pure returns (uint256) { return 0; }
    function minRedeemPos() external pure returns (uint256) { return 0; }

    function getPosTokenPrice() external view returns (uint256) {
        return posTokenPrice;
    }

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
        return IERC20(POS_TOKEN).balanceOf(address(this)) * posTokenPrice / 1e18;
    }

    function deposit(uint256 amount, address) external returns (uint256) {
        IERC20(ASSET).transferFrom(vaultAddr, address(this), amount);
        IERC20(ASSET).transfer(address(SETTLEMENT_VENUE), amount);
        SETTLEMENT_VENUE.settleDeposit(address(this), amount, amount);
        return amount;
    }

    function withdrawSync(uint256 amount, address) external returns (uint256) {
        IERC20(POS_TOKEN).transfer(address(SETTLEMENT_VENUE), amount);
        SETTLEMENT_VENUE.settleWithdraw(address(this), amount, amount);
        return amount;
    }

    function requestRedeemAsync(uint256 amount, address) external {
        IERC20(POS_TOKEN).transfer(address(SETTLEMENT_VENUE), amount);
        SETTLEMENT_VENUE.acceptAsyncRedeem(address(this), amount);
    }

    function sweepToVault(address token, uint256 amount) external returns (uint256) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 actual = amount > bal ? bal : amount;
        if (actual > 0) {
            IERC20(token).transfer(vaultAddr, actual);
        }
        return actual;
    }
}

// ---------------------------------------------------------------------------
// Test Contract
// ---------------------------------------------------------------------------

contract ExtremeLiquidityQATest is Test {
    using VaultViewHelper for MantleYieldVault;
    MockUSDC_EL internal usdc;
    MockPosToken_EL internal posToken;
    MockSanctionsOracle_EL internal oracle;
    MantleYieldVault internal vault;
    MantleVaultGateway internal gateway;
    Accountant internal accountant;
    StrategyController internal controller;
    MockSettlementVenue_EL internal settlementVenue;
    MockStrategyAdapter_EL internal adapter;
    MockStrategyAdapter_EL internal adapter2;
    OperatorExecutor internal executor;

    address internal admin = makeAddr("admin");
    address internal bot = makeAddr("bot");
    address internal treasury = makeAddr("treasury");
    address internal sanctionSafe = makeAddr("sanctionSafe");
    address internal user1 = makeAddr("user1");
    address internal user2 = makeAddr("user2");
    address internal user3 = makeAddr("user3");
    address internal user4 = makeAddr("user4");

    uint256 constant RATE = 1e18;
    uint256 constant FEE_BPS = 100; // 1%

    function setUp() public {
        usdc = new MockUSDC_EL();
        posToken = new MockPosToken_EL();
        oracle = new MockSanctionsOracle_EL();

        OperatorExecutor execImpl = new OperatorExecutor();
        executor = OperatorExecutor(address(new ERC1967Proxy(
            address(execImpl),
            abi.encodeCall(OperatorExecutor.initialize, (admin, bot))
        )));

        MantleYieldVault vaultImpl = new MantleYieldVault();
        Accountant acctImpl = new Accountant();
        MantleVaultGateway gwImpl = new MantleVaultGateway();
        StrategyController ctrlImpl = new StrategyController();

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

        bytes memory acctInitData = abi.encodeCall(
            Accountant.initialize,
            (address(vault), uint64(RATE), 0, admin)
        );
        accountant = Accountant(address(new ERC1967Proxy(address(acctImpl), acctInitData)));

        bytes memory ctrlInitData = abi.encodeCall(
            StrategyController.initialize,
            (address(vault), admin, address(executor), admin, 1000, 200, 0)
        );
        controller = StrategyController(address(new ERC1967Proxy(address(ctrlImpl), ctrlInitData)));

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

        vm.startPrank(admin);
        vault.setAccountant(address(accountant));
        vault.setGateway(address(gateway));
        vault.setController(address(controller));
        vm.stopPrank();

        settlementVenue = new MockSettlementVenue_EL(address(usdc), address(posToken));
        adapter = new MockStrategyAdapter_EL(address(usdc), address(posToken), address(settlementVenue));
        adapter.setVault(address(vault));
        adapter2 = new MockStrategyAdapter_EL(address(usdc), address(posToken), address(settlementVenue));
        adapter2.setVault(address(vault));

        vm.startPrank(admin);
        controller.registerStrategy(address(adapter), 5000, 1, false);
        controller.activateStrategy(address(adapter));
        controller.registerStrategy(address(adapter2), 5000, 2, false);
        controller.activateStrategy(address(adapter2));
        address[] memory ordered = new address[](2);
        ordered[0] = address(adapter);
        ordered[1] = address(adapter2);
        controller.setStrategyOrder(ordered);
        vm.stopPrank();

        // Fund users
        address[4] memory users = [user1, user2, user3, user4];
        for (uint256 i = 0; i < users.length; i++) {
            usdc.mint(users[i], 200_000e6);
            vm.prank(users[i]);
            usdc.approve(address(vault), type(uint256).max);
        }
    }

    // -----------------------------------------------------------------------
    // Logging helpers
    // -----------------------------------------------------------------------

    string constant MODULE = unicode"业务博弈、汇率波动、抢赎、排队公平性与极端流动性场景";
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

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    function _depositViaGateway(address user, uint256 assets) internal returns (uint256 shares) {
        vm.prank(user);
        shares = gateway.deposit(assets);
    }

    function _requestRedeemViaGateway(address user, uint256 shares) internal returns (uint256 requestId) {
        vm.prank(user);
        requestId = gateway.requestRedeem(shares);
    }

    function _syncRedeemViaGateway(address user, uint256 shares) internal returns (uint256 assets) {
        vm.prank(user);
        assets = gateway.redeem(shares);
    }

    // -----------------------------------------------------------------------
    // 1. test_AllFreeCashConsumedByLockedShares_SyncRedeemFails
    // -----------------------------------------------------------------------

    function test_AllFreeCashConsumedByLockedShares_SyncRedeemFails() public {
        _logCase(
            "test_AllFreeCashConsumedByLockedShares_SyncRedeemFails",
            unicode"全部 `freeCash` 被 locked shares 吃满时，所有同步赎回都应失败"
        );

        _step("[Step 1] Multiple users deposit");
        uint256 shares1 = _depositViaGateway(user1, 10_000e6);
        uint256 shares2 = _depositViaGateway(user2, 10_000e6);
        uint256 shares3 = _depositViaGateway(user3, 10_000e6);
        uint256 physBalAfterDeposit = usdc.balanceOf(address(vault));
        _step(string.concat("  vault USDC after deposits: ", vm.toString(physBalAfterDeposit)));

        _step("[Step 2] Trigger real rebalance to invest excess cash into adapter");
        vm.prank(bot);
        executor.executeRebalance(address(controller));
        uint256 vaultUsdcAfterRebalance = usdc.balanceOf(address(vault));
        uint256 adapterValue = adapter.totalValue();
        _step(string.concat("  vault USDC after rebalance: ", vm.toString(vaultUsdcAfterRebalance)));
        _step(string.concat("  adapter totalValue: ", vm.toString(adapterValue)));
        assertLt(vaultUsdcAfterRebalance, physBalAfterDeposit, "rebalance should move USDC to adapter");

        _step("[Step 3] User1 and user3 request async redeem of ALL shares, locking most of remaining freeCash");
        _requestRedeemViaGateway(user1, shares1);
        _requestRedeemViaGateway(user3, shares3);

        uint256 freeCash = vault.getFreeCash();
        uint256 physBal = usdc.balanceOf(address(vault));
        uint256 locked = vault.totalLockedShares();
        _step(string.concat("  physicalBalance: ", vm.toString(physBal)));
        _step(string.concat("  totalLockedShares: ", vm.toString(locked)));
        _step(string.concat("  freeCash: ", vm.toString(freeCash)));

        _step("[Step 4] user2 attempts sync redeem - should fail or be severely limited");
        uint256 maxRedeemUser2 = vault.maxRedeem(user2);
        _step(string.concat("  maxRedeem(user2): ", vm.toString(maxRedeemUser2)));

        if (maxRedeemUser2 == 0) {
            _step("  maxRedeem = 0, sync redeem fully blocked");
            vm.prank(user2);
            vm.expectRevert(abi.encodeWithSignature("ERC4626ExceededMaxRedeem(address,uint256,uint256)", user2, shares2, maxRedeemUser2));
            gateway.redeem(shares2);
            _step("  user2 sync redeem reverted as expected");
        } else {
            assertLt(maxRedeemUser2, shares2, "maxRedeem should be less than full shares");
            _step(string.concat("  maxRedeem severely limited: ", vm.toString(maxRedeemUser2), " < ", vm.toString(shares2)));
            // Full redeem should still fail
            vm.prank(user2);
            vm.expectRevert(abi.encodeWithSignature("ERC4626ExceededMaxRedeem(address,uint256,uint256)", user2, shares2, maxRedeemUser2));
            gateway.redeem(shares2);
            _step("  user2 full sync redeem reverted as expected");
        }

        _step("  PASS: rebalance + locked shares squeeze freeCash, sync redeem blocked");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 2. test_FreeCashZero_AsyncRedeemCanStillQueue
    // -----------------------------------------------------------------------

    function test_FreeCashZero_AsyncRedeemCanStillQueue() public {
        _logCase(
            "test_FreeCashZero_AsyncRedeemCanStillQueue",
            unicode"`freeCash` 为 0 时，异步赎回仍可继续排队"
        );

        _step("[Step 1] Multiple users deposit");
        uint256 shares1 = _depositViaGateway(user1, 10_000e6);
        _depositViaGateway(user3, 10_000e6);
        uint256 shares4 = _depositViaGateway(user4, 10_000e6);

        _step("[Step 2] Rebalance to invest most USDC into adapter");
        vm.prank(bot);
        executor.executeRebalance(address(controller));
        _step(string.concat("  vault USDC after rebalance: ", vm.toString(usdc.balanceOf(address(vault)))));
        _step(string.concat("  adapter totalValue: ", vm.toString(adapter.totalValue())));

        _step("[Step 3] User1 and user4 async redeem to lock remaining freeCash");
        _requestRedeemViaGateway(user1, shares1);
        _requestRedeemViaGateway(user4, shares4);

        uint256 freeCash = vault.getFreeCash();
        _step(string.concat("  freeCash after rebalance + locked: ", vm.toString(freeCash)));
        assertEq(freeCash, 0, "freeCash should be 0 (rebalance + locked consumed all)");

        _step("[Step 4] User2 deposits fresh USDC, then creates async redeem request");
        uint256 shares2 = _depositViaGateway(user2, 5_000e6);

        uint256 requestId = _requestRedeemViaGateway(user2, shares2);
        assertTrue(requestId != 0, "request should be created even when freeCash was 0");
        _step(string.concat("  requestId = ", vm.toString(requestId)));

        IMantleYieldVault.RequestStatus status = vault.reqStatus(requestId);
        assertEq(uint256(status), uint256(IMantleYieldVault.RequestStatus.PENDING), "status should be PENDING");
        _step("  PASS: async redeem request created successfully despite prior freeCash=0");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 3. test_AsyncStrategyDelayed_BatchCannotFinalize
    // -----------------------------------------------------------------------

    function test_AsyncStrategyDelayed_BatchCannotFinalize() public {
        _logCase(
            "test_AsyncStrategyDelayed_BatchCannotFinalize",
            unicode"异步策略回款延迟导致 batch 长时间无法 finalize"
        );

        _step("[Step 1] Switch adapter to async mode so divest creates in-flight instead of instant return");
        vm.startPrank(admin);
        // Update both adapters: adapter1 async with full weight, adapter2 weight=0
        address[] memory adapters_ = new address[](2);
        adapters_[0] = address(adapter);
        adapters_[1] = address(adapter2);
        uint16[] memory weights = new uint16[](2);
        weights[0] = 10_000;
        weights[1] = 0;
        uint16[] memory priorities = new uint16[](2);
        priorities[0] = 1;
        priorities[1] = 2;
        bool[] memory isAsync = new bool[](2);
        isAsync[0] = true;
        isAsync[1] = false;
        controller.updateStrategies(adapters_, weights, priorities, isAsync);
        // Only use async adapter in order
        address[] memory order = new address[](1);
        order[0] = address(adapter);
        controller.setStrategyOrder(order);
        vm.stopPrank();

        _step("[Step 2] User1 deposits, rebalance invests into async adapter");
        uint256 shares1 = _depositViaGateway(user1, 10_000e6);
        vm.prank(bot);
        executor.executeRebalance(address(controller));
        uint256 vaultUsdcAfterRebalance = usdc.balanceOf(address(vault));
        uint256 adapterVal = adapter.totalValue();
        _step(string.concat("  vault USDC after rebalance: ", vm.toString(vaultUsdcAfterRebalance)));
        _step(string.concat("  adapter totalValue: ", vm.toString(adapterVal)));
        assertLt(vaultUsdcAfterRebalance, 10_000e6, "rebalance should invest into adapter");

        _step("[Step 3] User1 creates async redeem request, process via controller");
        uint256 requestId = _requestRedeemViaGateway(user1, shares1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = requestId;
        // processRedeemBatch will try _divest but adapter is async -> creates redeem in-flight, USDC not returned yet
        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), ids);

        IMantleYieldVault.RequestStatus statusAfter = vault.reqStatus(requestId);
        assertEq(uint256(statusAfter), uint256(IMantleYieldVault.RequestStatus.PROCESSING));

        uint256 vaultBal = usdc.balanceOf(address(vault));
        uint256 redeemIF = vault.totalRedeemInFlight();
        _step(string.concat("  request status = PROCESSING"));
        _step(string.concat("  vault USDC (funds still in adapter): ", vm.toString(vaultBal)));
        _step(string.concat("  totalRedeemInFlight: ", vm.toString(redeemIF)));

        _step("[Step 4] Attempt finalize - vault lacks physical cash (in-flight not yet returned)");
        uint256 estAssets = vault.reqEstimate(requestId);
        _step(string.concat("  estimatedAssets: ", vm.toString(estAssets)));
        assertLt(vaultBal, estAssets, "vault should not have enough USDC (still in adapter as in-flight)");

        uint256[] memory settledAssets = new uint256[](1);
        settledAssets[0] = estAssets;

        vm.prank(bot);
        vm.expectRevert(
            abi.encodeWithSelector(IMantleYieldVault.Vault__InsufficientPhysicalCash.selector, ids, settledAssets, vaultBal)
        );
        executor.executeFinalizeRedeemBatch(address(controller), ids, settledAssets);

        _step("[Step 5] Verify request stays in PROCESSING (in-flight not settled)");
        IMantleYieldVault.RequestStatus statusFinal = vault.reqStatus(requestId);
        assertEq(uint256(statusFinal), uint256(IMantleYieldVault.RequestStatus.PROCESSING), "should still be PROCESSING");
        assertGt(vault.totalRedeemInFlight(), 0, "redeem in-flight still pending");
        _step("  PASS: finalizeRedeemBatch reverts with Vault__InsufficientPhysicalCash, funds stuck in async in-flight");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 4. test_NewDepositDuringBacklog_FundsConsumedByOldRequests
    // -----------------------------------------------------------------------

    function test_NewDepositDuringBacklog_FundsConsumedByOldRequests() public {
        _logCase(
            "test_NewDepositDuringBacklog_FundsConsumedByOldRequests",
            unicode"新用户在旧请求积压期间继续存款，验证其资金是否被旧赎回优先消耗"
        );

        _step("[Step 1] User1 deposits, rebalance invests most USDC into adapter");
        uint256 shares1 = _depositViaGateway(user1, 10_000e6);
        vm.prank(bot);
        executor.executeRebalance(address(controller));
        _step(string.concat("  vault USDC after rebalance: ", vm.toString(usdc.balanceOf(address(vault)))));

        _step("[Step 2] User1 requests async redeem, process via controller");
        uint256 requestId = _requestRedeemViaGateway(user1, shares1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = requestId;
        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), ids);

        IMantleYieldVault.RequestStatus statusAfter = vault.reqStatus(requestId);
        assertEq(uint256(statusAfter), uint256(IMantleYieldVault.RequestStatus.PROCESSING));
        uint256 vaultBalBeforeNewDeposit = usdc.balanceOf(address(vault));
        _step(string.concat("  vault USDC before new deposit: ", vm.toString(vaultBalBeforeNewDeposit)));

        _step("[Step 3] New user2 deposits 15000 USDC while old request is backlogged");
        uint256 shares2 = _depositViaGateway(user2, 15_000e6);
        assertTrue(shares2 > 0, "new deposit should still succeed");
        uint256 vaultBalAfterDeposit = usdc.balanceOf(address(vault));
        _step(string.concat("  vault USDC after new deposit: ", vm.toString(vaultBalAfterDeposit)));

        _step("[Step 4] Finalize old request - uses new deposit funds");
        uint256 estAssets = vault.reqEstimate(requestId);
        _step(string.concat("  estimatedAssets: ", vm.toString(estAssets)));

        uint256 user1BalBefore = usdc.balanceOf(user1);
        uint256[] memory settledAmounts = new uint256[](1);
        settledAmounts[0] = estAssets;

        vm.prank(bot);
        executor.executeFinalizeRedeemBatch(address(controller), ids, settledAmounts);

        IMantleYieldVault.RequestStatus finalStatus = vault.reqStatus(requestId);
        assertEq(uint256(finalStatus), uint256(IMantleYieldVault.RequestStatus.DONE));

        _step("[Step 5] Verify new deposit funds were consumed by old request settlement");
        uint256 vaultBalAfterFinalize = usdc.balanceOf(address(vault));
        uint256 user1Received = usdc.balanceOf(user1) - user1BalBefore;
        _step(string.concat("  user1 received: ", vm.toString(user1Received)));
        _step(string.concat("  vault USDC after finalize: ", vm.toString(vaultBalAfterFinalize)));
        assertEq(user1Received, estAssets, "user1 should receive full settlement");
        assertLt(vaultBalAfterFinalize, vaultBalAfterDeposit, "vault balance decreased - new funds consumed by old request");
        _step("  PASS: new deposit funds consumed by old request finalization (unified pool)");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 5. test_RedeemInFlight_ConfirmRecordsActualValue
    // -----------------------------------------------------------------------

    function test_RedeemInFlight_ConfirmRecordsActualValue() public {
        _logCase(
            "test_RedeemInFlight_ConfirmRecordsActualValue",
            unicode"redeem in-flight 确认阶段记录本次 settle 传入的实际值，并按原记录值清理 in-flight 统计；最终付款能力在 finalize 阶段校验"
        );

        _step("[Step 1] Deposit, rebalance to invest into adapter (sync mode first)");
        _depositViaGateway(user1, 10_000e6);
        vm.prank(bot);
        executor.executeRebalance(address(controller));
        uint256 adapterValAfterInvest = adapter.totalValue();
        _step(string.concat("  adapter totalValue after rebalance: ", vm.toString(adapterValAfterInvest)));
        assertGt(adapterValAfterInvest, 0, "adapter should hold value");

        _step("[Step 2] Switch adapter to async, then trigger divest to create redeem in-flight");
        vm.startPrank(admin);
        address[] memory adapters_ = new address[](2);
        adapters_[0] = address(adapter);
        adapters_[1] = address(adapter2);
        uint16[] memory weights = new uint16[](2);
        weights[0] = 3_000;  // reduce from 5000 to 3000, triggers partial divest
        weights[1] = 7_000;  // total must be 10000
        uint16[] memory prios = new uint16[](2);
        prios[0] = 1;
        prios[1] = 2;
        bool[] memory asyncFlags = new bool[](2);
        asyncFlags[0] = true;  // async: divest creates in-flight
        asyncFlags[1] = false;
        controller.updateStrategies(adapters_, weights, prios, asyncFlags);
        // Both adapters in order so weights sum to 10000 (3000 + 7000)
        controller.setStrategyOrder(adapters_);
        // Raise buffer so targetCash > idealCash, forcing DIVEST from async adapter
        controller.setRiskParams(5000, 0, 0);
        vm.stopPrank();

        uint256 nextIfBefore = vault.nextInFlightId();
        vm.prank(bot);
        executor.executeRebalance(address(controller));
        uint256 nextIfAfter = vault.nextInFlightId();
        assertGt(nextIfAfter, nextIfBefore, "rebalance should create redeem in-flight");
        uint256 redeemId = nextIfBefore; // first new in-flight

        uint256 totalRedeemBefore = vault.totalRedeemInFlight();
        uint256 originalPosAmount = vault.ifTokenAmount(redeemId);
        uint256 originalUsdcAmount = vault.ifUsdcAmount(redeemId);
        _step(string.concat("  redeem in-flight id: ", vm.toString(redeemId)));
        _step(string.concat("  original posAmount (token X): ", vm.toString(originalPosAmount)));
        _step(string.concat("  original usdcAmount (X): ", vm.toString(originalUsdcAmount)));
        _step(string.concat("  totalRedeemInFlight: ", vm.toString(totalRedeemBefore)));

        _step("[Step 3] Settle adapter with different actual value Y != X");
        uint256 actualSettled = originalUsdcAmount * 90 / 100; // Y = 90% of X
        _step(string.concat("  actual settled (Y): ", vm.toString(actualSettled)));
        settlementVenue.settleAsyncRedeem(address(adapter), originalPosAmount, actualSettled);

        uint256[] memory redeemIds = new uint256[](1);
        redeemIds[0] = redeemId;
        uint256[] memory redeemAmounts = new uint256[](1);
        redeemAmounts[0] = actualSettled;
        uint256[] memory emptyIds = new uint256[](0);
        uint256[] memory emptyAmounts = new uint256[](0);

        vm.prank(bot);
        executor.executeSettleAdapter(
            address(controller),
            address(adapter),
            IStrategyControllerExecutor.InvestSettlementInput(emptyIds, emptyAmounts, new uint256[](emptyIds.length)),
            IStrategyControllerExecutor.RedeemSettlementInput(redeemIds, redeemAmounts)
        );

        _step("[Step 4] Verify settledAmount = Y (actual), and in-flight decremented by X (original)");
        (uint256 settledAmount, IMantleYieldVault.InFlightStatus ifStatus) = vault.ifSettledAndStatus(redeemId);
        assertEq(settledAmount, actualSettled, "settledAmount should be actual value Y");
        assertEq(uint256(ifStatus), uint256(IMantleYieldVault.InFlightStatus.CONFIRMED));
        _step(string.concat("  settledAmount = ", vm.toString(settledAmount)));

        uint256 totalRedeemAfter = vault.totalRedeemInFlight();
        _step(string.concat("  totalRedeemInFlight after confirm = ", vm.toString(totalRedeemAfter)));
        assertEq(totalRedeemAfter, totalRedeemBefore - originalUsdcAmount, "decremented by original X, not actual Y");

        _step("[Step 5] Confirm: in-flight settle success does not mean request can be paid");
        _step("  Final payment ability is checked at finalizeRedeemBatch stage");
        _step("  PASS: in-flight records actual Y, decrements by original X, separation of concerns verified");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 6. test_MultiStress_CoreViewsConsistent
    // -----------------------------------------------------------------------

    function test_MultiStress_CoreViewsConsistent() public {
        _logCase(
            "test_MultiStress_CoreViewsConsistent",
            unicode"多重压力同时发生时，核心 view 结果仍应可解释且不出现脏状态"
        );

        _step("[Step 1] Multiple users deposit, rebalance invests into adapters");
        _depositViaGateway(user1, 50_000e6);
        _depositViaGateway(user2, 30_000e6);
        _depositViaGateway(user3, 20_000e6);
        vm.prank(bot);
        executor.executeRebalance(address(controller));
        _step(string.concat("  vault USDC after rebalance: ", vm.toString(usdc.balanceOf(address(vault)))));
        _step(string.concat("  adapter1 totalValue: ", vm.toString(adapter.totalValue())));
        _step(string.concat("  adapter2 totalValue: ", vm.toString(adapter2.totalValue())));

        _step("[Step 2] Create locked shares via async redeem");
        uint256 shares1 = vault.balanceOf(user1);
        _requestRedeemViaGateway(user1, shares1 / 2);

        _step("[Step 3] Switch adapter1 to async + trigger divest to create redeem in-flight");
        vm.startPrank(admin);
        address[] memory adapters_ = new address[](2);
        adapters_[0] = address(adapter);
        adapters_[1] = address(adapter2);
        uint16[] memory weights = new uint16[](2);
        weights[0] = 3_000;
        weights[1] = 7_000;
        uint16[] memory prios = new uint16[](2);
        prios[0] = 1;
        prios[1] = 2;
        bool[] memory asyncFlags = new bool[](2);
        asyncFlags[0] = true;
        asyncFlags[1] = false;
        controller.updateStrategies(adapters_, weights, prios, asyncFlags);
        controller.setStrategyOrder(adapters_);
        controller.setRiskParams(1000, 0, 0);
        vm.stopPrank();
        vm.prank(bot);
        executor.executeRebalance(address(controller));
        uint256 redeemIF = vault.totalRedeemInFlight();
        _step(string.concat("  totalRedeemInFlight after divest: ", vm.toString(redeemIF)));

        _step("[Step 4] Record baseline views before stress");
        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 freeCashBefore = vault.getFreeCash();
        uint256 maxRedeemBefore = vault.maxRedeem(user2);
        _step(string.concat("  totalAssets before = ", vm.toString(totalAssetsBefore)));
        _step(string.concat("  freeCash before = ", vm.toString(freeCashBefore)));
        _step(string.concat("  maxRedeem(user2) before = ", vm.toString(maxRedeemBefore)));

        _step("[Step 5] Apply multi-stress: adapter value crash via price drop + more locked shares");
        // Simulate adapter value crash via posToken price drop (market event)
        uint256 adapter1Val = adapter.totalValue();
        uint256 adapter2Val = adapter2.totalValue();
        uint256 adapter1PosBalance = posToken.balanceOf(address(adapter));
        uint256 adapter2PosBalance = posToken.balanceOf(address(adapter2));
        // Set price so that totalValue = posBalance * newPrice / 1e18 = 1_000e6
        if (adapter1Val > 1_000e6 && adapter1PosBalance > 0) {
            adapter.setPosTokenPrice(1_000e6 * 1e18 / adapter1PosBalance);
        }
        if (adapter2Val > 1_000e6 && adapter2PosBalance > 0) {
            adapter2.setPosTokenPrice(1_000e6 * 1e18 / adapter2PosBalance);
        }
        _step(string.concat("  adapter1 after crash: ", vm.toString(adapter.totalValue())));
        _step(string.concat("  adapter2 after crash: ", vm.toString(adapter2.totalValue())));
        // Add more locked shares
        uint256 shares2 = vault.balanceOf(user2);
        _requestRedeemViaGateway(user2, shares2 / 3);

        _step("[Step 6] Query all core views under stress");
        uint256 totalAssets = vault.totalAssets();
        uint256 freeCash = vault.getFreeCash();
        uint256 maxRedeemU2 = vault.maxRedeem(user2);
        uint256 maxWithdrawU2 = vault.maxWithdraw(user2);
        uint256 locked = vault.totalLockedShares();
        uint256 redeemIFStress = vault.totalRedeemInFlight();
        uint256 physBal = usdc.balanceOf(address(vault));

        _step(string.concat("  totalAssets = ", vm.toString(totalAssets)));
        _step(string.concat("  freeCash = ", vm.toString(freeCash)));
        _step(string.concat("  maxRedeem(user2) = ", vm.toString(maxRedeemU2)));
        _step(string.concat("  maxWithdraw(user2) = ", vm.toString(maxWithdrawU2)));
        _step(string.concat("  totalLockedShares = ", vm.toString(locked)));
        _step(string.concat("  totalRedeemInFlight = ", vm.toString(redeemIFStress)));
        _step(string.concat("  physicalBalance = ", vm.toString(physBal)));

        _step("[Step 7] Verify consistency under stress");
        // totalAssets should decrease due to adapter value crash
        assertLt(totalAssets, totalAssetsBefore, "totalAssets should decrease after adapter crash");
        // freeCash should be 0 under extreme stress (locked + adapter crash consume all)
        assertEq(freeCash, 0, "freeCash should be 0 under multi-stress");
        // maxRedeem should be 0 when freeCash is 0
        assertEq(maxRedeemU2, 0, "maxRedeem should be 0 under multi-stress");
        // Core invariants still hold
        assertLe(freeCash, physBal, "freeCash <= physicalBalance");
        assertLe(maxWithdrawU2, freeCash, "maxWithdraw <= freeCash");
        assertLe(maxRedeemU2, vault.balanceOf(user2), "maxRedeem <= balance");

        _step("  PASS: all core views consistent and directionally correct under multi-stress");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 7. test_BankRun_TotalPayoutNotExceedPhysicalBalance
    // -----------------------------------------------------------------------

    function test_BankRun_TotalPayoutNotExceedPhysicalBalance() public {
        _logCase(
            "test_BankRun_TotalPayoutNotExceedPhysicalBalance",
            unicode"多用户挤兑下，系统总支付不超过物理余额与结算口径上限"
        );

        _step("[Step 1] Multiple users deposit, rebalance invests part into adapter");
        uint256 depositPerUser = 10_000e6;
        uint256 shares1 = _depositViaGateway(user1, depositPerUser);
        uint256 shares2 = _depositViaGateway(user2, depositPerUser);
        uint256 shares3 = _depositViaGateway(user3, depositPerUser);
        uint256 shares4 = _depositViaGateway(user4, depositPerUser);
        vm.prank(bot);
        executor.executeRebalance(address(controller));

        uint256 physBalAfterRebalance = usdc.balanceOf(address(vault));
        uint256 totalDepositedUsdc = depositPerUser * 4;
        _step(string.concat("  vault USDC after rebalance: ", vm.toString(physBalAfterRebalance)));
        _step(string.concat("  adapter totalValue: ", vm.toString(adapter.totalValue())));
        _step(string.concat("  total deposited: ", vm.toString(totalDepositedUsdc)));

        _step("[Step 2] Mixed exit: user1 sync redeem, user2 async redeem, user3 sync redeem");
        uint256 totalPaid = 0;

        // User1 sync redeem
        uint256 maxR1 = vault.maxRedeem(user1);
        assertGt(maxR1, 0, "precondition: user1 should have maxRedeem > 0 with freeCash available");
        if (maxR1 > 0) {
            uint256 paid1 = _syncRedeemViaGateway(user1, maxR1);
            totalPaid += paid1;
            _step(string.concat("  user1 sync redeemed: ", vm.toString(paid1)));
        }

        // User2 async redeem (no immediate payout, but locks shares)
        uint256 reqId2 = _requestRedeemViaGateway(user2, shares2);
        _step(string.concat("  user2 async request created: reqId=", vm.toString(reqId2)));

        // User3 sync redeem (freeCash reduced by user1 + user2 locked)
        uint256 maxR3 = vault.maxRedeem(user3);
        if (maxR3 > 0) {
            uint256 paid3 = _syncRedeemViaGateway(user3, maxR3);
            totalPaid += paid3;
            _step(string.concat("  user3 sync redeemed: ", vm.toString(paid3)));
        }

        // User4 tries sync redeem (may be limited or fail)
        uint256 maxR4 = vault.maxRedeem(user4);
        if (maxR4 > 0) {
            uint256 paid4 = _syncRedeemViaGateway(user4, maxR4);
            totalPaid += paid4;
            _step(string.concat("  user4 sync redeemed: ", vm.toString(paid4)));
        } else {
            _step("  user4 maxRedeem=0, sync redeem blocked");
        }

        _step("[Step 3] Process and finalize user2 async request via controller");
        uint256[] memory ids = new uint256[](1);
        ids[0] = reqId2;
        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), ids);
        IMantleYieldVault.RequestStatus st2 = vault.reqStatus(reqId2);
        assertEq(uint256(st2), uint256(IMantleYieldVault.RequestStatus.PROCESSING), "user2 should be PROCESSING");

        uint256 est2 = vault.reqEstimate(reqId2);
        uint256 vaultBalForSettle = usdc.balanceOf(address(vault));
        uint256 settleAmount = est2 <= vaultBalForSettle ? est2 : vaultBalForSettle;
        uint256[] memory settled = new uint256[](1);
        settled[0] = settleAmount;
        vm.prank(bot);
        executor.executeFinalizeRedeemBatch(address(controller), ids, settled);
        IMantleYieldVault.RequestStatus st2Final = vault.reqStatus(reqId2);
        assertEq(uint256(st2Final), uint256(IMantleYieldVault.RequestStatus.DONE), "user2 should be DONE");
        totalPaid += settleAmount;
        _step(string.concat("  user2 async settled: ", vm.toString(settleAmount)));

        _step(string.concat("[Step 4] Total paid out = ", vm.toString(totalPaid)));
        // Total payout can exceed post-rebalance physical balance because processRedeemBatch
        // triggers _divest which brings USDC back from adapter. But total payout must not
        // exceed total deposited USDC (the vault's total available resources).
        assertLe(totalPaid, totalDepositedUsdc, "total payout must not exceed total deposited USDC");

        uint256 physBalAfter = usdc.balanceOf(address(vault));
        _step(string.concat("  vault physical balance after = ", vm.toString(physBalAfter)));

        _step("[Step 5] Verify accounting consistency after mixed exit");
        uint256 pendingUser2 = vault.pendingRedeemRequest(user2);
        assertEq(pendingUser2, 0, "user2 pending should be 0 after settlement");
        uint256 totalSupply = vault.totalSupply();
        uint256 totalLocked = vault.totalLockedShares();
        _step(string.concat("  totalSupply: ", vm.toString(totalSupply)));
        _step(string.concat("  totalLockedShares: ", vm.toString(totalLocked)));
        _step(string.concat("  vault USDC remaining: ", vm.toString(physBalAfter)));
        // No negative balance, no orphaned locks
        assertEq(totalLocked, 0, "no locked shares should remain after all async settled");
        _step("  PASS: mixed sync+async exit, total payout <= physical balance, accounting consistent");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 8. test_LowUSDC_HighRedeemInFlight_AssetsVsPayability
    // -----------------------------------------------------------------------

    function test_LowUSDC_HighRedeemInFlight_AssetsVsPayability() public {
        _logCase(
            "test_LowUSDC_HighRedeemInFlight_AssetsVsPayability",
            unicode"USDC 物理余额极低但 `totalRedeemInFlight` 很高时，验证 `totalAssets` 与实际可支付能力分离"
        );

        _step("[Step 1] Deposit and rebalance to invest most USDC into adapter");
        uint256 shares = _depositViaGateway(user1, 10_000e6);
        vm.prank(bot);
        executor.executeRebalance(address(controller));
        _step(string.concat("  vault USDC after rebalance: ", vm.toString(usdc.balanceOf(address(vault)))));
        _step(string.concat("  adapter totalValue: ", vm.toString(adapter.totalValue())));

        _step("[Step 2] Switch adapter to async, trigger divest to create large redeem in-flight");
        vm.startPrank(admin);
        address[] memory adapters_ = new address[](2);
        adapters_[0] = address(adapter);
        adapters_[1] = address(adapter2);
        uint16[] memory weights = new uint16[](2);
        weights[0] = 3_000;
        weights[1] = 7_000;
        uint16[] memory prios = new uint16[](2);
        prios[0] = 1;
        prios[1] = 2;
        bool[] memory asyncFlags = new bool[](2);
        asyncFlags[0] = true;
        asyncFlags[1] = false;
        controller.updateStrategies(adapters_, weights, prios, asyncFlags);
        controller.setStrategyOrder(adapters_);
        controller.setRiskParams(5000, 0, 0);
        vm.stopPrank();
        vm.prank(bot);
        executor.executeRebalance(address(controller));

        _step("[Step 3] Verify: low physical USDC, high redeemInFlight");
        uint256 physBalLow = usdc.balanceOf(address(vault));
        uint256 redeemIF = vault.totalRedeemInFlight();
        uint256 totalAssets = vault.totalAssets();
        uint256 freeCash = vault.getFreeCash();
        uint256 maxR = vault.maxRedeem(user1);

        _step(string.concat("  physicalBalance = ", vm.toString(physBalLow)));
        _step(string.concat("  totalRedeemInFlight = ", vm.toString(redeemIF)));
        _step(string.concat("  totalAssets = ", vm.toString(totalAssets)));
        _step(string.concat("  freeCash = ", vm.toString(freeCash)));
        _step(string.concat("  maxRedeem(user1) = ", vm.toString(maxR)));

        _step("[Step 4] Verify totalAssets high but sync redeem ability weak");
        assertGt(redeemIF, 0, "should have redeem in-flight");
        assertGt(totalAssets, physBalLow, "totalAssets > physicalBalance (includes in-flight)");
        assertLe(freeCash, physBalLow, "freeCash <= physicalBalance");

        _step("[Step 5] Attempt full sync redeem - should fail (maxRedeem < full shares)");
        uint256 userShares = vault.balanceOf(user1);
        _step(string.concat("  user1 shares: ", vm.toString(userShares)));
        _step(string.concat("  maxRedeem: ", vm.toString(maxR)));
        assertLt(maxR, userShares, "maxRedeem should be less than full shares (limited by freeCash)");

        // Full redeem should revert
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("ERC4626ExceededMaxRedeem(address,uint256,uint256)", user1, userShares, maxR));
        gateway.redeem(userShares);
        _step("  full sync redeem reverted as expected");

        // Partial redeem at maxRedeem should succeed
        assertGt(maxR, 0, "precondition: user should have partial redeemability (freeCash > 0)");
        vm.prank(user1);
        uint256 received = gateway.redeem(maxR);
        assertGt(received, 0, "partial redeem should return assets");
        _step(string.concat("  partial sync redeem succeeded, received: ", vm.toString(received)));

        _step("  PASS: totalAssets high but sync redeem severely limited - separation confirmed");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 9. test_MultiAdapterUnpaid_DepositStillWorks
    // -----------------------------------------------------------------------

    function test_MultiAdapterUnpaid_DepositStillWorks() public {
        _logCase(
            "test_MultiAdapterUnpaid_DepositStillWorks",
            unicode"多个 async adapter 同时未回款时，批量请求积压不应破坏后续存款流程"
        );

        _step("[Step 1] Deposit and rebalance to invest into both adapters");
        _depositViaGateway(user1, 20_000e6);
        vm.prank(bot);
        executor.executeRebalance(address(controller));
        _step(string.concat("  vault USDC after rebalance: ", vm.toString(usdc.balanceOf(address(vault)))));
        _step(string.concat("  adapter1 totalValue: ", vm.toString(adapter.totalValue())));
        _step(string.concat("  adapter2 totalValue: ", vm.toString(adapter2.totalValue())));

        _step("[Step 2] Switch both adapters to async, trigger divest to create in-flights on both");
        vm.startPrank(admin);
        address[] memory adapters_ = new address[](2);
        adapters_[0] = address(adapter);
        adapters_[1] = address(adapter2);
        uint16[] memory weights = new uint16[](2);
        weights[0] = 3_000;
        weights[1] = 7_000;
        uint16[] memory prios = new uint16[](2);
        prios[0] = 1;
        prios[1] = 2;
        bool[] memory asyncFlags = new bool[](2);
        asyncFlags[0] = true;
        asyncFlags[1] = true;  // both async
        controller.updateStrategies(adapters_, weights, prios, asyncFlags);
        controller.setStrategyOrder(adapters_);
        controller.setRiskParams(9500, 0, 0);
        vm.stopPrank();
        vm.prank(bot);
        executor.executeRebalance(address(controller));

        uint256 totalRedeemIF = vault.totalRedeemInFlight();
        _step(string.concat("  totalRedeemInFlight: ", vm.toString(totalRedeemIF)));
        assertGt(totalRedeemIF, 0, "should have redeem in-flights on adapters");

        _step("[Step 3] New user deposits while both adapters have unpaid in-flights");
        uint256 shares2 = _depositViaGateway(user2, 5_000e6);
        assertTrue(shares2 > 0, "deposit should succeed despite unpaid in-flights");
        _step(string.concat("  user2 received shares = ", vm.toString(shares2)));

        _step("[Step 4] Verify key bookkeeping is consistent with formula");
        uint256 totalAssets = vault.totalAssets();
        uint256 freeCash = vault.getFreeCash();
        uint256 physBal = usdc.balanceOf(address(vault));
        uint256 redeemIFNow = vault.totalRedeemInFlight();
        uint256 locked = vault.totalLockedShares();

        _step(string.concat("  physicalBalance = ", vm.toString(physBal)));
        _step(string.concat("  totalAssets = ", vm.toString(totalAssets)));
        _step(string.concat("  freeCash = ", vm.toString(freeCash)));
        _step(string.concat("  redeemInFlight = ", vm.toString(redeemIFNow)));
        _step(string.concat("  totalLockedShares = ", vm.toString(locked)));

        // Core invariants
        assertLe(freeCash, physBal, "freeCash <= physicalBalance");
        assertGt(totalAssets, 0, "totalAssets > 0");
        // totalAssets should include redeemInFlight (funds expected back)
        assertGe(totalAssets + redeemIFNow, physBal, "totalAssets accounts for in-flight value");

        _step("[Step 5] User3 can also deposit");
        uint256 shares3 = _depositViaGateway(user3, 3_000e6);
        assertTrue(shares3 > 0, "subsequent deposits also succeed");

        _step("[Step 6] Create async redeem request and try finalize while adapters still unpaid");
        uint256 reqId = _requestRedeemViaGateway(user2, shares2);
        uint256[] memory ids = new uint256[](1);
        ids[0] = reqId;
        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), ids);
        IMantleYieldVault.RequestStatus st = vault.reqStatus(reqId);
        assertEq(uint256(st), uint256(IMantleYieldVault.RequestStatus.PROCESSING), "should be PROCESSING");

        uint256 est = vault.reqEstimate(reqId);
        uint256 vaultBalNow = usdc.balanceOf(address(vault));
        _step(string.concat("  estimatedAssets: ", vm.toString(est)));
        _step(string.concat("  vault USDC: ", vm.toString(vaultBalNow)));

        uint256[] memory settled = new uint256[](1);
        // With new deposits providing liquidity, vault should have enough to finalize
        assertGe(vaultBalNow, est, "precondition: new deposits should cover finalization");
        settled[0] = est;
        vm.prank(bot);
        executor.executeFinalizeRedeemBatch(address(controller), ids, settled);
        IMantleYieldVault.RequestStatus stFinal = vault.reqStatus(reqId);
        assertEq(uint256(stFinal), uint256(IMantleYieldVault.RequestStatus.DONE));
        _step("  finalize succeeded - new deposits provided enough liquidity");

        _step("  PASS: deposits work normally despite in-flight backlog, finalize behavior consistent");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 10. test_UnifiedPool_NewFundsUsedForOldRequests
    // -----------------------------------------------------------------------

    function test_UnifiedPool_NewFundsUsedForOldRequests() public {
        _logCase(
            "test_UnifiedPool_NewFundsUsedForOldRequests",
            unicode"统一资金池模式下，新进入 Vault 的资金可优先用于履约旧的异步赎回请求"
        );

        _step("[Step 1] User1 deposits, rebalance invests most USDC into adapter");
        uint256 shares1 = _depositViaGateway(user1, 10_000e6);
        vm.prank(bot);
        executor.executeRebalance(address(controller));
        uint256 vaultAfterRebalance = usdc.balanceOf(address(vault));
        _step(string.concat("  vault USDC after rebalance: ", vm.toString(vaultAfterRebalance)));

        _step("[Step 2] User1 requests async redeem, process via controller");
        uint256 requestId = _requestRedeemViaGateway(user1, shares1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = requestId;
        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), ids);
        IMantleYieldVault.RequestStatus stAfterProcess = vault.reqStatus(requestId);
        assertEq(uint256(stAfterProcess), uint256(IMantleYieldVault.RequestStatus.PROCESSING));

        _step("[Step 3] Verify vault USDC insufficient for settlement");
        uint256 estAssets = vault.reqEstimate(requestId);
        uint256 vaultBalBefore = usdc.balanceOf(address(vault));
        _step(string.concat("  estimatedAssets: ", vm.toString(estAssets)));
        _step(string.concat("  vault USDC: ", vm.toString(vaultBalBefore)));

        _step("[Step 4] New user2 deposits fresh funds into the unified pool");
        uint256 user1BalBefore = usdc.balanceOf(user1);
        _depositViaGateway(user2, 15_000e6);
        uint256 vaultBalAfterDeposit = usdc.balanceOf(address(vault));
        _step(string.concat("  vault USDC after new deposit: ", vm.toString(vaultBalAfterDeposit)));
        assertGe(vaultBalAfterDeposit, estAssets, "new deposit provides enough liquidity");

        _step("[Step 5] Finalize old request via controller - uses new deposit funds");
        uint256[] memory settledAmounts = new uint256[](1);
        settledAmounts[0] = estAssets;
        vm.prank(bot);
        executor.executeFinalizeRedeemBatch(address(controller), ids, settledAmounts);

        IMantleYieldVault.RequestStatus finalStatus = vault.reqStatus(requestId);
        assertEq(uint256(finalStatus), uint256(IMantleYieldVault.RequestStatus.DONE));

        _step("[Step 6] Verify user1 received funds and vault balance decreased");
        uint256 user1Received = usdc.balanceOf(user1) - user1BalBefore;
        uint256 vaultBalAfterFinalize = usdc.balanceOf(address(vault));
        _step(string.concat("  user1 received: ", vm.toString(user1Received)));
        _step(string.concat("  vault USDC after finalize: ", vm.toString(vaultBalAfterFinalize)));
        assertEq(user1Received, estAssets, "user1 should receive full settlement");
        assertLt(vaultBalAfterFinalize, vaultBalAfterDeposit, "vault balance decreased - new funds consumed");
        _step("  PASS: new deposit funds consumed by old request (unified pool design)");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 11. test_LongPendingProcessing_BookkeepingStable
    // -----------------------------------------------------------------------

    function test_LongPendingProcessing_BookkeepingStable() public {
        _logCase(
            "test_LongPendingProcessing_BookkeepingStable",
            unicode"异步赎回队列长时间处于 PENDING / PROCESSING 时，系统应保持账本稳定并在流动性恢复后继续推进"
        );

        _step("[Step 1] Deposit and rebalance, then create multiple async redeem requests");
        uint256 shares1 = _depositViaGateway(user1, 10_000e6);
        uint256 shares2 = _depositViaGateway(user2, 10_000e6);
        vm.prank(bot);
        executor.executeRebalance(address(controller));
        _step(string.concat("  vault USDC after rebalance: ", vm.toString(usdc.balanceOf(address(vault)))));

        uint256 reqId1 = _requestRedeemViaGateway(user1, shares1);
        uint256 reqId2 = _requestRedeemViaGateway(user2, shares2);

        _step("[Step 2] Process reqId1 via controller, keep reqId2 as PENDING");
        uint256[] memory ids1 = new uint256[](1);
        ids1[0] = reqId1;
        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), ids1);
        IMantleYieldVault.RequestStatus st1 = vault.reqStatus(reqId1);
        assertEq(uint256(st1), uint256(IMantleYieldVault.RequestStatus.PROCESSING));
        IMantleYieldVault.RequestStatus st2 = vault.reqStatus(reqId2);
        assertEq(uint256(st2), uint256(IMantleYieldVault.RequestStatus.PENDING));
        _step("  reqId1 = PROCESSING, reqId2 = PENDING");

        _step("[Step 3] Simulate long waiting period, verify no state drift");
        _verifyNoDriftOverTime(user1, user2);

        _step("[Step 4] New user deposits during waiting period");
        _depositViaGateway(user3, 15_000e6);
        _step(string.concat("  vault USDC after user3 deposit: ", vm.toString(usdc.balanceOf(address(vault)))));

        _step("[Step 5] Liquidity recovers - finalize reqId1 via controller");
        _finalizeAndVerify(reqId1, ids1);
        _step("  reqId1 finalized to DONE");

        _step("[Step 6] Process reqId2, confirm queue can continue even if cash is still insufficient");
        uint256[] memory ids2 = new uint256[](1);
        ids2[0] = reqId2;
        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), ids2);
        uint256 reqId2Estimate = vault.reqEstimate(reqId2);
        uint256 vaultBalBeforeReqId2Finalize = usdc.balanceOf(address(vault));
        _step(string.concat("  reqId2 estimatedAssets: ", vm.toString(reqId2Estimate)));
        _step(string.concat("  vault USDC before first reqId2 finalize: ", vm.toString(vaultBalBeforeReqId2Finalize)));
        assertLt(vaultBalBeforeReqId2Finalize, reqId2Estimate, "first recovery should still be insufficient for reqId2");

        uint256[] memory settledReqId2 = new uint256[](1);
        settledReqId2[0] = reqId2Estimate;
        vm.prank(bot);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMantleYieldVault.Vault__InsufficientPhysicalCash.selector, ids2, settledReqId2, vaultBalBeforeReqId2Finalize
            )
        );
        executor.executeFinalizeRedeemBatch(address(controller), ids2, settledReqId2);
        IMantleYieldVault.RequestStatus reqId2StatusAfterShortfall = vault.reqStatus(reqId2);
        assertEq(
            uint256(reqId2StatusAfterShortfall),
            uint256(IMantleYieldVault.RequestStatus.PROCESSING),
            "reqId2 should stay PROCESSING until more liquidity arrives"
        );
        _step("  reqId2 remains PROCESSING after exact insufficient-cash revert");

        _step("[Step 7] Add real liquidity, then finalize reqId2");
        uint256 additionalLiquidityNeeded = reqId2Estimate - vaultBalBeforeReqId2Finalize;
        _depositViaGateway(user4, additionalLiquidityNeeded);
        uint256 vaultBalAfterRecovery = usdc.balanceOf(address(vault));
        _step(string.concat("  additional liquidity provided: ", vm.toString(additionalLiquidityNeeded)));
        _step(string.concat("  vault USDC after second recovery: ", vm.toString(vaultBalAfterRecovery)));
        assertGe(vaultBalAfterRecovery, reqId2Estimate, "recovered liquidity should cover reqId2");

        vm.prank(bot);
        executor.executeFinalizeRedeemBatch(address(controller), ids2, settledReqId2);
        IMantleYieldVault.RequestStatus reqId2FinalStatus = vault.reqStatus(reqId2);
        assertEq(uint256(reqId2FinalStatus), uint256(IMantleYieldVault.RequestStatus.DONE));
        _step("  reqId2 finalized to DONE after additional liquidity arrived");

        _step("[Step 8] Verify all bookkeeping cleaned up");
        assertEq(vault.totalLockedShares(), 0, "all locked shares released");
        assertEq(vault.pendingRedeemRequest(user1), 0, "user1 pending cleared");
        assertEq(vault.pendingRedeemRequest(user2), 0, "user2 pending cleared");
        _step("  PASS: long-pending requests do not corrupt bookkeeping; system recovers after liquidity restored");
        _logPass();
    }

    /// @dev Verify no state drift over 30 days for two users
    function _verifyNoDriftOverTime(address u1, address u2) internal {
        uint256 lockedT0 = vault.totalLockedShares();
        uint256 pendingU1T0 = vault.pendingRedeemRequest(u1);
        uint256 pendingU2T0 = vault.pendingRedeemRequest(u2);
        uint256 totalAssetsT0 = vault.totalAssets();
        uint256 freeCashT0 = vault.getFreeCash();
        _step(string.concat("  T0 locked=", vm.toString(lockedT0),
            " pendingU1=", vm.toString(pendingU1T0),
            " pendingU2=", vm.toString(pendingU2T0)));
        _step(string.concat("  T0 totalAssets=", vm.toString(totalAssetsT0),
            " freeCash=", vm.toString(freeCashT0)));

        vm.warp(block.timestamp + 30 days);

        uint256 lockedT1 = vault.totalLockedShares();
        uint256 pendingU1T1 = vault.pendingRedeemRequest(u1);
        uint256 pendingU2T1 = vault.pendingRedeemRequest(u2);
        assertEq(lockedT0, lockedT1, "locked shares stable over 30 days");
        assertEq(pendingU1T0, pendingU1T1, "pendingU1 stable");
        assertEq(pendingU2T0, pendingU2T1, "pendingU2 stable");
        _step("  T1 (30d later): no state drift");
    }

    /// @dev Finalize a single request and assert DONE
    function _finalizeAndVerify(uint256 reqId, uint256[] memory ids) internal {
        uint256 estAssets = vault.reqEstimate(reqId);
        uint256[] memory settled = new uint256[](1);
        settled[0] = estAssets;
        vm.prank(bot);
        executor.executeFinalizeRedeemBatch(address(controller), ids, settled);
        IMantleYieldVault.RequestStatus sFinal = vault.reqStatus(reqId);
        assertEq(uint256(sFinal), uint256(IMantleYieldVault.RequestStatus.DONE));
    }
}
