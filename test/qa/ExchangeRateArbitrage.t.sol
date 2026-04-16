// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Accountant} from "../../src/accountant/Accountant.sol";
import {AccountantExecutor} from "../../src/accountant/AccountantExecutor.sol";
import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {IMantleVaultGateway} from "../../src/interfaces/vault/IMantleVaultGateway.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {MantleVaultGateway} from "../../src/vault/MantleVaultGateway.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {OperatorExecutor} from "../../src/protocol/OperatorExecutor.sol";
import {IStrategyAdapter} from "../../src/interfaces/adapters/IStrategyAdapter.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

// ---------------------------------------------------------------------------
// Mock contracts
// ---------------------------------------------------------------------------

contract MockUSDC_ERA is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockSanctionsOracle_ERA is ISanctionsOracle {
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

contract MockPosToken_ERA is ERC20 {
    constructor() ERC20("MockPosToken", "mPOS") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockStrategyAdapter_ERA is IStrategyAdapter {
    address public immutable ASSET;
    address public immutable POS_TOKEN;
    address public vaultAddr;

    constructor(address asset_, address posToken_) {
        ASSET = asset_;
        POS_TOKEN = posToken_;
    }

    function setVault(address v) external { vaultAddr = v; }
    function name() external pure returns (string memory) { return "MockStrategyAdapter"; }
    function asset() external view returns (address) { return ASSET; }
    function posToken() external view returns (address) { return POS_TOKEN; }
    function priceOracle() external pure returns (address) { return address(0); }
    function getPosTokenPrice() external pure returns (uint256) { return 1e18; }
    function estimatePosAmount(uint256 assetAmount) external pure returns (uint256) { return assetAmount; }
    function vault() external view returns (address) { return vaultAddr; }
    function setPaused(bool) external {}
    function retryRedeemAsync(uint256, address) external {}

    function totalValue() external view returns (uint256) {
        return IERC20(POS_TOKEN).balanceOf(address(this));
    }

    function deposit(uint256 amount, address) external returns (uint256) {
        // Pull USDC from vault (vault already approved via approveToAdapter)
        IERC20(ASSET).transferFrom(vaultAddr, address(this), amount);
        // Mint posToken 1:1
        MockPosToken_ERA(POS_TOKEN).mint(address(this), amount);
        return amount;
    }

    function withdrawSync(uint256 amount, address) external returns (uint256) {
        // Burn posToken and return USDC to vault
        // For simplicity, just transfer USDC back
        IERC20(ASSET).transfer(vaultAddr, amount);
        return amount;
    }

    function requestRedeemAsync(uint256, address) external {}

    function sweepToVault(address token, uint256 amount) external returns (uint256) {
        IERC20(token).transfer(vaultAddr, amount);
        return amount;
    }
}

/// @dev DummyExecutor_ERA kept for reference only; OperatorExecutor is used instead.

// ---------------------------------------------------------------------------
// QA Test: Exchange Rate Arbitrage & Accounting Interleaving Scenarios
// ---------------------------------------------------------------------------

contract ExchangeRateArbitrageQATest is Test {
    MockUSDC_ERA internal usdc;
    MockPosToken_ERA internal posToken;
    MockSanctionsOracle_ERA internal oracle;
    MantleYieldVault internal vault;
    MantleVaultGateway internal gateway;
    Accountant internal accountant;
    StrategyController internal controller;
    MockStrategyAdapter_ERA internal adapter;
    OperatorExecutor internal opExecutor;

    address internal admin = makeAddr("admin");
    address internal executor = makeAddr("executor");
    address internal treasury = makeAddr("treasury");
    address internal sanctionSafe = makeAddr("sanctionSafe");
    address internal userA = makeAddr("userA");
    address internal userB = makeAddr("userB");
    address internal userC = makeAddr("userC");
    address internal bot = makeAddr("bot");

    uint64 internal constant INITIAL_RATE = 1e18;
    uint256 constant FEE_BPS = 100; // 1%
    uint256 constant BPS = 10_000;

    // -----------------------------------------------------------------------
    // Logging helpers
    // -----------------------------------------------------------------------

    string constant MODULE =
        unicode"业务博弈、汇率波动、抢赎、排队公平性与极端流动性场景";
    string private _caseId;
    string private _caseName;
    string private _buf;

    function _logCase(string memory id, string memory name_) internal {
        _caseId = id;
        _caseName = name_;
        _buf = "";
        _step(string.concat("testcase module: ", MODULE));
        _step(string.concat("testcase id: ", id));
        _step(string.concat("testcase name: ", name_));
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
    // setUp
    // -----------------------------------------------------------------------

    function setUp() public {
        vm.warp(1000);

        usdc = new MockUSDC_ERA();
        posToken = new MockPosToken_ERA();
        oracle = new MockSanctionsOracle_ERA();

        // Deploy OperatorExecutor
        OperatorExecutor opImpl = new OperatorExecutor();
        bytes memory opInit = abi.encodeCall(OperatorExecutor.initialize, (admin, bot));
        opExecutor = OperatorExecutor(address(new ERC1967Proxy(address(opImpl), opInit)));

        // Deploy implementations
        MantleYieldVault vaultImpl = new MantleYieldVault();
        Accountant acctImpl = new Accountant();
        MantleVaultGateway gwImpl = new MantleVaultGateway();
        StrategyController ctrlImpl = new StrategyController();

        // Initialize vault (with placeholders)
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
                minDepositAmount: 0
            })
        );
        vault = MantleYieldVault(address(new ERC1967Proxy(address(vaultImpl), vaultInitData)));

        // Initialize accountant with management fee = 100 bps (1%)
        bytes memory acctInitData =
            abi.encodeCall(Accountant.initialize, (address(vault), INITIAL_RATE, 100, admin));
        accountant = Accountant(address(new ERC1967Proxy(address(acctImpl), acctInitData)));

        // Initialize controller
        bytes memory ctrlInitData = abi.encodeCall(
            StrategyController.initialize,
            (address(vault), admin, address(opExecutor), admin, 1000, 200, 0)
        );
        controller = StrategyController(address(new ERC1967Proxy(address(ctrlImpl), ctrlInitData)));

        // Initialize gateway
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

        // Wire up vault references
        vm.startPrank(admin);
        vault.setAccountant(address(accountant));
        vault.setGateway(address(gateway));
        vault.setController(address(controller));
        // Grant EXECUTOR_ROLE on accountant to this test contract so we can call updateExchangeRate
        accountant.grantRole(accountant.EXECUTOR_ROLE(), address(this));
        accountant.grantRole(accountant.EXECUTOR_ROLE(), bot);
        // Widen max deviation to 10% (ceiling is 1000 = 10%) to allow rate changes in tests
        accountant.setRiskParams(1000, 0);
        // Set maxComputeAge to 1 day
        accountant.setMaxComputeAge(1 days);
        vm.stopPrank();

        // Register strategy adapter
        adapter = new MockStrategyAdapter_ERA(address(usdc), address(posToken));
        adapter.setVault(address(vault));
        vm.startPrank(admin);
        controller.registerStrategy(address(adapter), 10_000, 1, false);
        controller.activateStrategy(address(adapter));
        address[] memory ordered = new address[](1);
        ordered[0] = address(adapter);
        controller.setStrategyOrder(ordered);
        vm.stopPrank();

        // Fund users
        usdc.mint(userA, 1_000_000e6);
        usdc.mint(userB, 1_000_000e6);
        usdc.mint(userC, 1_000_000e6);
        vm.prank(userA);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(userB);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(userC);
        usdc.approve(address(vault), type(uint256).max);
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    function _depositForUser(address user, uint256 amount) internal {
        vm.prank(user);
        gateway.deposit(amount);
    }

    /// @dev Warp and update exchange rate. minUpdateInterval=0 so no cooldown issue.
    function _updateRate(uint64 newRate) internal {
        uint64 ts = uint64(block.timestamp);
        accountant.updateExchangeRate(newRate, ts);
    }

    function _warpAndUpdateRate(uint256 warpBy, uint64 newRate) internal {
        vm.warp(block.timestamp + warpBy);
        _updateRate(newRate);
    }

    /// @dev Add liquidity to vault via real deposit flow (simulates additional capital availability)
    function _addVaultLiquidity(uint256 amount) internal {
        address lp = makeAddr("liquidityProvider");
        usdc.mint(lp, amount);
        vm.startPrank(lp);
        usdc.approve(address(vault), type(uint256).max);
        gateway.deposit(amount);
        vm.stopPrank();
    }

    /// @dev Seed the accountant's totalSharesLastSettle by doing a no-op rate update
    ///      after shares exist. This ensures subsequent fee settlements have a non-zero base.
    function _seedFeeBase() internal {
        _warpAndUpdateRate(1, uint64(accountant.lastExchangeRate()));
    }

    // =======================================================================
    // 汇率波动与用户抢跑场景 (lines 330-344)
    // =======================================================================

    // -----------------------------------------------------------------------
    // 1. 汇率上调前用户抢先存款
    // -----------------------------------------------------------------------
    function test_DepositBeforeRateIncrease() public {
        _logCase(
            "test_DepositBeforeRateIncrease",
            unicode"汇率上调前用户抢先存款，验证旧低汇率下获得更多 shares"
        );

        _step("[Step 1] Rate = 1.0e18. userA deposits 1100 USDC before rate increase");
        _depositForUser(userA, 1100e6);
        uint256 sharesA = vault.balanceOf(userA);
        _step(string.concat("  userA shares: ", vm.toString(sharesA)));

        _step("[Step 2] BOT updates rate to 1.1e18");
        _warpAndUpdateRate(1, 1.1e18);

        _step("[Step 3] userB deposits 1100 USDC after rate increase");
        _depositForUser(userB, 1100e6);
        uint256 sharesB = vault.balanceOf(userB);
        _step(string.concat("  userB shares: ", vm.toString(sharesB)));

        _step("[Step 4] Compare shares");
        assertGt(sharesA, sharesB, "userA should have more shares than userB (old low rate)");
        _step(string.concat("  sharesA > sharesB: ", vm.toString(sharesA), " > ", vm.toString(sharesB)));
        uint256 expectedSharesA = 1100e6 * 1e18 / INITIAL_RATE;
        uint256 expectedSharesB = 1100e6 * 1e18 / 1.1e18;
        assertEq(sharesA, expectedSharesA, "sharesA derived from deposit / rate");
        assertEq(sharesB, expectedSharesB, "sharesB derived from deposit / newRate");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 1b. 持续存款期间汇率多次变动
    // -----------------------------------------------------------------------
    function test_ContinuousDepositsAcrossRateChanges() public {
        _logCase(
            "test_ContinuousDepositsAcrossRateChanges",
            unicode"持续存款期间汇率多次变动，验证每次获得的 shares 严格遵循当时汇率"
        );

        // Use rates within 10% deviation threshold: 1.0 -> 1.08 -> 1.0 -> 1.05

        _step("[Step 1] Rate = 1.0e18. userA deposits 1000 USDC");
        _depositForUser(userA, 1000e6);
        uint256 sharesA1 = vault.balanceOf(userA);
        _step(string.concat("  userA shares (rate 1.0): ", vm.toString(sharesA1)));
        assertEq(sharesA1, 1000e6, "shares at rate 1.0 should be 1000e6");

        _step("[Step 2] Rate increases to 1.08e18. userA deposits another 1000 USDC");
        _warpAndUpdateRate(1, 1.08e18);
        _depositForUser(userA, 1000e6);
        uint256 sharesA2 = vault.balanceOf(userA) - sharesA1;
        _step(string.concat("  userA new shares (rate 1.08): ", vm.toString(sharesA2)));
        assertLt(sharesA2, sharesA1, "fewer shares at higher rate");

        _step("[Step 3] Rate decreases to 1.0e18. userA deposits another 1000 USDC");
        _warpAndUpdateRate(1, 1.0e18);
        uint256 sharesBeforeDeposit3 = vault.balanceOf(userA);
        _depositForUser(userA, 1000e6);
        uint256 sharesA3 = vault.balanceOf(userA) - sharesBeforeDeposit3;
        _step(string.concat("  userA new shares (rate 1.0): ", vm.toString(sharesA3)));
        assertEq(sharesA3, sharesA1, "same shares at same rate");

        _step("[Step 4] Rate to 1.05e18. userB deposits 3000 USDC (same total as userA)");
        _warpAndUpdateRate(1, 1.05e18);
        _depositForUser(userB, 3000e6);
        uint256 sharesB = vault.balanceOf(userB);
        uint256 totalSharesA = vault.balanceOf(userA);
        _step(string.concat("  userA total shares (3 deposits): ", vm.toString(totalSharesA)));
        _step(string.concat("  userB total shares (1 deposit at 1.05): ", vm.toString(sharesB)));

        _step("[Step 5] Verify userA got more total shares (deposited at lower avg rate)");
        // userA: 1000e6 (at 1.0) + ~925e6 (at 1.08) + 1000e6 (at 1.0) = ~2925e6
        // userB: 3000e6 * 1e18 / 1.05e18 = ~2857e6
        assertGt(totalSharesA, sharesB, "userA should have more total shares due to lower average rate");
        _step(string.concat("  difference: ", vm.toString(totalSharesA - sharesB)));

        _step("[Step 6] Verify each deposit's shares matches manual calculation");
        uint256 depositAmount = 1000e6;
        uint256 expectedA1 = depositAmount * 1e18 / 1.0e18;
        uint256 expectedA2 = depositAmount * 1e18 / 1.08e18;
        uint256 expectedA3 = depositAmount * 1e18 / 1.0e18;
        assertEq(sharesA1, expectedA1, "deposit 1 shares mismatch");
        assertEq(sharesA2, expectedA2, "deposit 2 shares mismatch");
        assertEq(sharesA3, expectedA3, "deposit 3 shares mismatch");
        _step("  PASS: each deposit strictly follows the rate at that moment");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 2. 汇率下调前用户抢先同步赎回
    // -----------------------------------------------------------------------
    function test_SyncRedeemBeforeRateDecrease() public {
        _logCase(
            "test_SyncRedeemBeforeRateDecrease",
            unicode"汇率下调前用户抢先同步赎回，验证是否把损失留给剩余持有人"
        );

        _step("[Step 1] Set rate = 1.1e18, both users deposit same USDC");
        _warpAndUpdateRate(1, 1.1e18);
        _depositForUser(userA, 1100e6);
        _depositForUser(userB, 1100e6);
        uint256 sharesA = vault.balanceOf(userA);
        uint256 sharesB = vault.balanceOf(userB);
        assertEq(sharesA, sharesB, "should have equal shares");
        _step(string.concat("  both have shares: ", vm.toString(sharesA)));

        _step("[Step 2] userA redeems before rate drop (rate still 1.1e18)");
        vm.prank(userA);
        uint256 assetsA = gateway.redeem(sharesA);
        _step(string.concat("  userA received: ", vm.toString(assetsA)));

        _step("[Step 3] BOT drops rate to 1.0e18");
        _warpAndUpdateRate(1, 1.0e18);

        _step("[Step 4] Check userB remaining value at new rate");
        uint256 userBValue = vault.previewRedeem(vault.balanceOf(userB));
        _step(string.concat("  userB redeemable value: ", vm.toString(userBValue)));
        assertGt(assetsA, userBValue, "userA got more assets at old high rate");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 3. 汇率上调前用户提前同步赎回
    // -----------------------------------------------------------------------
    function test_SyncRedeemBeforeRateIncrease() public {
        _logCase(
            "test_SyncRedeemBeforeRateIncrease",
            unicode"汇率上调前用户提前同步赎回，验证其是否拿到比更新后更少的资产"
        );

        _step("[Step 1] Rate = 1.0e18. Both users deposit 1000 USDC");
        _depositForUser(userA, 1000e6);
        _depositForUser(userB, 1000e6);

        _step("[Step 2] userA redeems before rate increase");
        uint256 sharesA = vault.balanceOf(userA);
        vm.prank(userA);
        uint256 assetsA = gateway.redeem(sharesA);
        _step(string.concat("  userA received: ", vm.toString(assetsA)));

        _step("[Step 3] Rate updated to 1.1e18");
        _warpAndUpdateRate(1, 1.1e18);

        _step("[Step 4] userB redeems maxRedeem after rate increase");
        // After rate increase, each share is worth more USDC. freeCash limits redemption.
        // Mint extra USDC into vault to ensure userB can fully redeem at new rate.
        _addVaultLiquidity(200e6);
        uint256 sharesB = vault.balanceOf(userB);
        uint256 maxR = vault.maxRedeem(userB);
        _step(string.concat("  maxRedeem(userB): ", vm.toString(maxR)));
        vm.prank(userB);
        uint256 assetsB = gateway.redeem(maxR);
        _step(string.concat("  userB received: ", vm.toString(assetsB)));

        assertLt(assetsA, assetsB, "userA (before increase) gets less than userB (after increase)");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 4. 汇率下调前用户抢先发起异步赎回请求
    // -----------------------------------------------------------------------
    function test_AsyncRedeemBeforeRateDecrease() public {
        _logCase(
            "test_AsyncRedeemBeforeRateDecrease",
            unicode"汇率下调前用户抢先发起异步赎回请求，验证 estimatedAssets 与后续 settledAssets 关系"
        );

        _step("[Step 1] Rate = 1.1e18. userA deposits and gets shares");
        _warpAndUpdateRate(1, 1.1e18);
        _depositForUser(userA, 1100e6);
        uint256 shares = vault.balanceOf(userA);
        _step(string.concat("  userA shares: ", vm.toString(shares)));

        _step("[Step 2] userA requests async redeem at high rate");
        vm.prank(userA);
        uint256 reqId = gateway.requestRedeem(shares);
        (,,,, uint256 estimatedAssets,,,) = vault.requests(reqId);
        _step(string.concat("  estimatedAssets (at rate 1.1): ", vm.toString(estimatedAssets)));

        _step("[Step 3] Rate drops to 1.0e18");
        _warpAndUpdateRate(1, 1.0e18);

        _step("[Step 4] Process batch");
        uint256[] memory ids = new uint256[](1);
        ids[0] = reqId;
        vm.prank(bot);
        opExecutor.executeProcessRedeemBatch(address(controller), ids);

        _step("[Step 5] Finalize with settledAssets < estimatedAssets (rate dropped, operator settles less)");
        uint256 reducedSettle = estimatedAssets * 90 / 100;
        _addVaultLiquidity(reducedSettle);
        uint256[] memory settled = new uint256[](1);
        settled[0] = reducedSettle;

        // Expect RequestSettlementAdjusted because settled != estimated
        vm.expectEmit(true, false, false, true, address(vault));
        emit IMantleYieldVault.RequestSettlementAdjusted(reqId, estimatedAssets, reducedSettle);

        vm.prank(bot);
        opExecutor.executeFinalizeRedeemBatch(address(controller), ids, settled);

        (,,,,,uint256 settledResult,,) = vault.requests(reqId);
        assertEq(settledResult, reducedSettle, "settledAssets should be the reduced amount");
        assertLt(settledResult, estimatedAssets, "settledAssets < estimatedAssets after rate drop");
        _step(string.concat("  estimatedAssets (old high rate): ", vm.toString(estimatedAssets)));
        _step(string.concat("  settledAssets (reduced): ", vm.toString(settledResult)));
        _step("  PASS: RequestSettlementAdjusted emitted, settled < estimated reflects rate drop");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 5. 汇率上调前用户发起异步赎回请求
    // -----------------------------------------------------------------------
    function test_AsyncRedeemBeforeRateIncrease() public {
        _logCase(
            "test_AsyncRedeemBeforeRateIncrease",
            unicode"汇率上调前用户发起异步赎回请求，验证 settledAssets 与 estimatedAssets 关系"
        );

        _step("[Step 1] Rate = 1.0e18. userA deposits and requests async redeem");
        _depositForUser(userA, 1000e6);
        uint256 shares = vault.balanceOf(userA);
        vm.prank(userA);
        uint256 reqId = gateway.requestRedeem(shares);
        (,,,, uint256 estimatedAssets,,,) = vault.requests(reqId);
        _step(string.concat("  estimatedAssets at rate 1.0: ", vm.toString(estimatedAssets)));

        _step("[Step 2] Process batch");
        uint256[] memory ids = new uint256[](1);
        ids[0] = reqId;
        vm.prank(bot);
        opExecutor.executeProcessRedeemBatch(address(controller), ids);

        _step("[Step 3] Rate increases to 1.1e18");
        _warpAndUpdateRate(1, 1.1e18);

        _step("[Step 4] Finalize with settledAssets > estimatedAssets (rate rose, operator settles more)");
        uint256 higherSettled = estimatedAssets + 50e6;
        _addVaultLiquidity(higherSettled);
        uint256[] memory settled = new uint256[](1);
        settled[0] = higherSettled;

        vm.expectEmit(true, false, false, true, address(vault));
        emit IMantleYieldVault.RequestSettlementAdjusted(reqId, estimatedAssets, higherSettled);

        vm.prank(bot);
        opExecutor.executeFinalizeRedeemBatch(address(controller), ids, settled);
        (,,,,,uint256 settledResult,,) = vault.requests(reqId);
        assertEq(settledResult, higherSettled, "settledAssets should be higher");
        assertGt(settledResult, estimatedAssets, "settledAssets > estimatedAssets");
        _step(string.concat("  estimatedAssets (old low rate): ", vm.toString(estimatedAssets)));
        _step(string.concat("  settledAssets (higher): ", vm.toString(settledResult)));
        _step("  PASS: RequestSettlementAdjusted emitted, settled > estimated reflects rate increase");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 6. deposit->updateExchangeRate vs updateExchangeRate->deposit
    // -----------------------------------------------------------------------
    function test_DepositOrderVsRateUpdate() public {
        _logCase(
            "test_DepositOrderVsRateUpdate",
            unicode"deposit->updateExchangeRate 与 updateExchangeRate->deposit 顺序颠倒时结果不同"
        );

        _step("[Step 1] Scenario A: userA deposits then rate updates to 1.1e18");
        _depositForUser(userA, 1000e6);
        uint256 sharesA = vault.balanceOf(userA);
        _step(string.concat("  userA shares (deposit at 1.0): ", vm.toString(sharesA)));

        _warpAndUpdateRate(1, 1.1e18);

        _step("[Step 2] Scenario B: rate already at 1.1e18, userB deposits");
        _depositForUser(userB, 1000e6);
        uint256 sharesB = vault.balanceOf(userB);
        _step(string.concat("  userB shares (deposit at 1.1): ", vm.toString(sharesB)));

        assertGt(sharesA, sharesB, "depositing before rate increase yields more shares");
        _step(string.concat("  difference: ", vm.toString(sharesA - sharesB)));

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 7. redeem->updateExchangeRate vs updateExchangeRate->redeem
    // -----------------------------------------------------------------------
    function test_RedeemOrderVsRateUpdate() public {
        _logCase(
            "test_RedeemOrderVsRateUpdate",
            unicode"redeem->updateExchangeRate 与 updateExchangeRate->redeem 顺序颠倒时结果不同"
        );

        _step("[Step 1] Both users deposit at rate 1.0e18");
        _depositForUser(userA, 1000e6);
        _depositForUser(userB, 1000e6);
        uint256 sharesA = vault.balanceOf(userA);
        uint256 sharesB = vault.balanceOf(userB);
        assertEq(sharesA, sharesB, "equal shares");

        _step("[Step 2] Scenario A: userA redeems before rate update");
        vm.prank(userA);
        uint256 assetsA = gateway.redeem(sharesA);
        _step(string.concat("  userA received: ", vm.toString(assetsA)));

        _step("[Step 3] Rate updates to 1.1e18");
        _warpAndUpdateRate(1, 1.1e18);

        _step("[Step 4] Scenario B: userB redeems maxRedeem after rate update");
        // Add liquidity to vault so userB can fully redeem at new rate
        _addVaultLiquidity(200e6);
        uint256 maxR = vault.maxRedeem(userB);
        vm.prank(userB);
        uint256 assetsB = gateway.redeem(maxR);
        _step(string.concat("  userB received: ", vm.toString(assetsB)));

        assertLt(assetsA, assetsB, "redeeming after rate increase yields more assets");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 8. Accountant long stale rate - continuous deposits
    // -----------------------------------------------------------------------
    function test_StaleRateContinuousDeposits() public {
        _logCase(
            "test_StaleRateContinuousDeposits",
            unicode"Accountant 长时间未更新汇率时，用户按 stale rate 连续存款的风险暴露"
        );

        _step("[Step 1] Rate = 1.0e18. Multiple users deposit over time");
        _depositForUser(userA, 1000e6);
        vm.warp(block.timestamp + 7 days);
        _depositForUser(userB, 1000e6);
        vm.warp(block.timestamp + 7 days);
        _depositForUser(userC, 1000e6);

        uint256 sharesA = vault.balanceOf(userA);
        uint256 sharesB = vault.balanceOf(userB);
        uint256 sharesC = vault.balanceOf(userC);
        _step(string.concat("  userA shares: ", vm.toString(sharesA)));
        _step(string.concat("  userB shares: ", vm.toString(sharesB)));
        _step(string.concat("  userC shares: ", vm.toString(sharesC)));

        _step("[Step 2] Rate updates to 1.1e18 (delayed correction)");
        _warpAndUpdateRate(1, 1.1e18);

        _step("[Step 3] Check share values");
        uint256 valueA = vault.previewRedeem(sharesA);
        uint256 valueB = vault.previewRedeem(sharesB);
        uint256 valueC = vault.previewRedeem(sharesC);
        _step(string.concat("  userA value: ", vm.toString(valueA)));
        _step(string.concat("  userB value: ", vm.toString(valueB)));
        _step(string.concat("  userC value: ", vm.toString(valueC)));
        assertEq(sharesA, sharesB, "all got same shares at stale rate");
        assertGt(valueA, 1000e6 * 99 / 100, "value should be higher after rate increase (minus fee)");
        _step("  [Risk] All users deposited at stale low rate, gaining extra value after rate correction");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 9. Accountant long stale rate - continuous redemptions
    // -----------------------------------------------------------------------
    function test_StaleRateContinuousRedemptions() public {
        _logCase(
            "test_StaleRateContinuousRedemptions",
            unicode"Accountant 长时间未更新汇率时，用户按 stale rate 连续赎回的风险暴露"
        );

        _step("[Step 1] Rate = 1.0e18. Users deposit");
        _depositForUser(userA, 1000e6);
        _depositForUser(userB, 1000e6);
        _depositForUser(userC, 1000e6);

        _step("[Step 2] Time passes, rate not updated. userA sync redeems at stale rate");
        vm.warp(block.timestamp + 14 days);
        uint256 sharesA = vault.balanceOf(userA);
        vm.prank(userA);
        uint256 assetsA = gateway.redeem(sharesA);
        _step(string.concat("  userA sync redeemed at stale rate, received: ", vm.toString(assetsA)));

        _step("[Step 3] userC requests async redeem at stale rate");
        uint256 sharesC = vault.balanceOf(userC);
        vm.prank(userC);
        uint256 reqId = gateway.requestRedeem(sharesC);
        (,,,, uint256 estimatedAssetsC,,,) = vault.requests(reqId);
        _step(string.concat("  userC estimatedAssets at stale rate: ", vm.toString(estimatedAssetsC)));

        _step("[Step 4] Rate updates to 0.9e18 (market dropped)");
        _warpAndUpdateRate(1, 0.9e18);

        _step("[Step 5] userB sync redeems at corrected lower rate");
        uint256 sharesB = vault.balanceOf(userB);
        uint256 maxR = vault.maxRedeem(userB);
        vm.prank(userB);
        uint256 assetsB = gateway.redeem(maxR);
        _step(string.concat("  userB sync redeemed at new rate, received: ", vm.toString(assetsB)));

        _step("[Step 6] Finalize userC async request with reduced settlement");
        uint256[] memory ids = new uint256[](1);
        ids[0] = reqId;
        // Process: PENDING -> PROCESSING (triggers divest if needed, pulling USDC from adapter)
        vm.prank(bot);
        opExecutor.executeProcessRedeemBatch(address(controller), ids);
        // Finalize with reduced settlement to demonstrate async settlement risk
        uint256 reducedSettle = estimatedAssetsC * 90 / 100;
        uint256[] memory settled = new uint256[](1);
        settled[0] = reducedSettle;
        vm.prank(bot);
        opExecutor.executeFinalizeRedeemBatch(address(controller), ids, settled);
        _step(string.concat("  userC settled (reduced): ", vm.toString(reducedSettle)));

        _step("[Step 7] Compare all three paths");
        assertGt(assetsA, assetsB, "sync at stale rate > sync at new low rate");
        assertGt(estimatedAssetsC, reducedSettle, "async estimated > actual settled");
        assertGt(assetsA, reducedSettle, "sync at stale > async settled after rate drop");
        _step(string.concat("  userA (sync, stale): ", vm.toString(assetsA)));
        _step(string.concat("  userB (sync, new rate): ", vm.toString(assetsB)));
        _step(string.concat("  userC (async, settled): ", vm.toString(reducedSettle)));
        _step("  [Risk] Stale rate benefits early actors; async users face additional settlement risk");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 10. Management fee settlement coincides with rate update
    // -----------------------------------------------------------------------
    function test_ManagementFeeSettleWithRateUpdate() public {
        _logCase(
            "test_ManagementFeeSettleWithRateUpdate",
            unicode"管理费结算与汇率更新同笔发生时，对前后用户的份额价值影响"
        );

        _step("[Step 1] userA deposits at rate 1.0e18");
        _depositForUser(userA, 10_000e6);

        _step("[Step 2] Seed fee base by doing a rate update (sets totalSharesLastSettle)");
        _seedFeeBase();

        _step("[Step 3] Warp 180 days to accrue management fee");
        vm.warp(block.timestamp + 180 days);
        uint256 totalSupplyBefore = vault.totalSupply();
        _step(string.concat("  totalSupply before rate update: ", vm.toString(totalSupplyBefore)));

        _step("[Step 4] Update rate to 1.05e18 (triggers fee settlement internally)");
        _updateRate(1.05e18);
        uint256 totalSupplyAfter = vault.totalSupply();
        _step(string.concat("  totalSupply after rate update: ", vm.toString(totalSupplyAfter)));
        uint256 feeShares = totalSupplyAfter - totalSupplyBefore;
        _step(string.concat("  fee shares minted to treasury: ", vm.toString(feeShares)));
        assertGt(feeShares, 0, "management fee shares should have been minted");

        _step("[Step 5] userB deposits after rate update + fee settlement");
        _depositForUser(userB, 10_000e6);
        uint256 sharesA = vault.balanceOf(userA);
        uint256 sharesB = vault.balanceOf(userB);
        _step(string.concat("  userA shares: ", vm.toString(sharesA)));
        _step(string.concat("  userB shares at new rate: ", vm.toString(sharesB)));
        assertGt(sharesA, sharesB, "userA at old rate got more shares");
        _step("  Difference includes both rate change AND fee-share dilution");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 11. 汇率上调前抢存后立即异步赎回
    // -----------------------------------------------------------------------
    function test_DepositThenAsyncRedeemAroundRateIncrease() public {
        _logCase(
            "test_DepositThenAsyncRedeemAroundRateIncrease",
            unicode"汇率上调前抢存后立即异步赎回，验证短周期套利闭环"
        );

        _step("[Step 1] Rate = 1.0e18. userA deposits");
        _depositForUser(userA, 1000e6);
        uint256 shares = vault.balanceOf(userA);
        _step(string.concat("  userA shares at rate 1.0: ", vm.toString(shares)));

        _step("[Step 2] Rate increases to 1.1e18");
        _warpAndUpdateRate(1, 1.1e18);

        _step("[Step 3] userA immediately requests async redeem at new high rate");
        vm.prank(userA);
        uint256 reqId = gateway.requestRedeem(shares);
        (,,,, uint256 estimatedAssets,,,) = vault.requests(reqId);
        _step(string.concat("  estimatedAssets at rate 1.1: ", vm.toString(estimatedAssets)));

        // The user deposited 1000 USDC and got 1000e6 shares at rate 1.0
        // At rate 1.1, grossAssets = shares * 1.1 / 1e18 * 1e6 = 1100e6
        // fee = 1100e6 * 1% = 11e6, estimatedAssets = 1089e6
        // This exceeds original 1000e6 (minus any original fee)
        assertGt(estimatedAssets, 1000e6, "estimated assets should exceed original deposit (arbitrage profit)");
        _step("  [Finding] Short-cycle arbitrage window exists: deposit at low rate, redeem at high rate");

        _step("[Step 4] Finalize settlement");
        uint256[] memory ids = new uint256[](1);
        ids[0] = reqId;
        vm.prank(bot);
        opExecutor.executeProcessRedeemBatch(address(controller), ids);
        _addVaultLiquidity(estimatedAssets);
        uint256[] memory settled = new uint256[](1);
        settled[0] = estimatedAssets;
        vm.prank(bot);
        opExecutor.executeFinalizeRedeemBatch(address(controller), ids, settled);

        uint256 userABalance = usdc.balanceOf(userA);
        _step(string.concat("  userA total USDC after settlement: ", vm.toString(userABalance)));
        // userA started with 1_000_000e6, spent 1000e6 on deposit, got back ~1089e6
        assertGt(userABalance, 1_000_000e6, "userA should have more USDC than started (arbitrage profit)");
        _step(string.concat("  profit: ", vm.toString(userABalance - 1_000_000e6)));
        _step("  PASS: short-cycle arbitrage confirmed - deposit low, redeem high yields net profit");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 11b. 汇率上调前抢存后立即同步赎回
    // -----------------------------------------------------------------------
    function test_DepositThenSyncRedeemAroundRateIncrease() public {
        _logCase(
            "test_DepositThenSyncRedeemAroundRateIncrease",
            unicode"汇率上调前抢存后立即同步赎回，验证链上套利闭环（无 operator 干预）"
        );

        uint256 usdcBefore = usdc.balanceOf(userA);
        _step(string.concat("  userA USDC before: ", vm.toString(usdcBefore)));

        _step("[Step 1] Rate = 1.0e18. userA deposits 1000 USDC");
        _depositForUser(userA, 1000e6);
        uint256 shares = vault.balanceOf(userA);
        _step(string.concat("  userA shares at rate 1.0: ", vm.toString(shares)));

        _step("[Step 2] Rate increases to 1.08e18");
        _warpAndUpdateRate(1, 1.08e18);

        _step("[Step 3] userA immediately sync redeems all shares at new high rate");
        // Add liquidity to vault to ensure full redemption at higher rate
        _addVaultLiquidity(100e6);
        uint256 maxR = vault.maxRedeem(userA);
        vm.prank(userA);
        uint256 assetsReceived = gateway.redeem(maxR);
        _step(string.concat("  assets received: ", vm.toString(assetsReceived)));

        _step("[Step 4] Verify arbitrage profit");
        uint256 usdcAfter = usdc.balanceOf(userA);
        // deposited 1000e6, redeemed at 1.08 rate:
        // grossAssets = 1000e6 * 1.08e18 / 1e18 = 1080e6
        // fee = 1080e6 * 1% = 10.8e6 (truncated to 10e6)
        // net = ~1069e6, profit = ~69e6
        uint256 depositCost = 1000e6;
        assertGt(assetsReceived, depositCost, "sync redeem should return more than deposited");
        uint256 profit = assetsReceived - depositCost;
        _step(string.concat("  deposit cost: ", vm.toString(depositCost)));
        _step(string.concat("  net profit: ", vm.toString(profit)));
        assertGt(usdcAfter, usdcBefore, "userA should have more USDC than started");
        _step("  PASS: sync redeem arbitrage confirmed - no operator intervention needed");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 12. 汇率下调前抢赎失败改走异步赎回
    // -----------------------------------------------------------------------
    function test_SyncRedeemFailFallbackToAsync() public {
        _logCase(
            "test_SyncRedeemFailFallbackToAsync",
            unicode"汇率下调前抢赎失败改走异步赎回，比较同步失败与异步排队后的经济结果"
        );

        _step("[Step 1] Both users deposit at rate 1.0e18");
        _depositForUser(userA, 2000e6);
        _depositForUser(userB, 2000e6);
        uint256 vaultBal = usdc.balanceOf(address(vault));
        _step(string.concat("  vault physical USDC: ", vm.toString(vaultBal)));

        _step("[Step 2] Rate increases to 1.1e18, shares now worth more than vault physical balance");
        _warpAndUpdateRate(1, 1.1e18);
        // vault still has 4000e6 USDC, but each user's shares now worth ~2178e6 (2000e6 * 1.1 - fee)
        // total redemption value ~4356e6 > 4000e6 physical balance
        uint256 freeCash = vault.getFreeCash();
        _step(string.concat("  freeCash after rate increase: ", vm.toString(freeCash)));

        _step("[Step 3] userA sync redeems what's available");
        uint256 maxRedeemA = vault.maxRedeem(userA);
        _step(string.concat("  maxRedeem(userA): ", vm.toString(maxRedeemA)));
        vm.prank(userA);
        uint256 assetsA = gateway.redeem(maxRedeemA);
        _step(string.concat("  userA sync redeemed: ", vm.toString(assetsA)));

        _step("[Step 4] userB tries sync redeem full amount - verify it would fail");
        uint256 sharesB = vault.balanceOf(userB);
        uint256 maxRedeemB = vault.maxRedeem(userB);
        _step(string.concat("  userB shares: ", vm.toString(sharesB)));
        _step(string.concat("  maxRedeem(userB) after A drained: ", vm.toString(maxRedeemB)));
        assertLt(maxRedeemB, sharesB, "maxRedeem should be less than full shares (freeCash insufficient)");
        // Verify full redeem would revert with ERC4626ExceededMaxRedeem
        vm.prank(userB);
        vm.expectRevert(abi.encodeWithSelector(
            bytes4(keccak256("ERC4626ExceededMaxRedeem(address,uint256,uint256)")),
            userB, sharesB, maxRedeemB
        ));
        gateway.redeem(sharesB);
        _step("  PASS: full sync redeem reverted as expected");

        _step("[Step 5] userB falls back to async redeem");
        vm.prank(userB);
        uint256 reqId = gateway.requestRedeem(sharesB);
        (,,,, uint256 estimatedAssetsB,,,) = vault.requests(reqId);
        _step(string.concat("  userB estimatedAssets: ", vm.toString(estimatedAssetsB)));

        _step("[Step 6] Rate drops to 1.0e18, then settle with vault's actual remaining balance");
        _warpAndUpdateRate(1, 1.0e18);

        uint256[] memory ids = new uint256[](1);
        ids[0] = reqId;
        vm.prank(bot);
        opExecutor.executeProcessRedeemBatch(address(controller), ids);

        // Settle with whatever USDC vault actually has left (no mint)
        uint256 vaultRemaining = usdc.balanceOf(address(vault));
        _step(string.concat("  vault remaining USDC: ", vm.toString(vaultRemaining)));
        assertLt(vaultRemaining, estimatedAssetsB, "vault has less than estimatedAssets");

        uint256[] memory settled = new uint256[](1);
        settled[0] = vaultRemaining;

        // Expect RequestSettlementAdjusted since settled != estimated
        vm.expectEmit(true, false, false, true, address(vault));
        emit IMantleYieldVault.RequestSettlementAdjusted(reqId, estimatedAssetsB, vaultRemaining);

        vm.prank(bot);
        opExecutor.executeFinalizeRedeemBatch(address(controller), ids, settled);

        _step(string.concat("  userB settled at vault remaining: ", vm.toString(vaultRemaining)));
        assertGt(assetsA, vaultRemaining, "userA (sync, first) got more than userB (async, delayed)");
        _step("  PASS: RequestSettlementAdjusted emitted, first-come-first-served confirmed");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 13. 超限汇率更新触发 circuit breaker
    // -----------------------------------------------------------------------
    function test_CircuitBreakerBlocksWriteOps() public {
        _logCase(
            "test_CircuitBreakerBlocksWriteOps",
            unicode"超限汇率更新触发 circuit breaker 后，用户写入口统一被阻断"
        );

        _step("[Step 1] Set tight deviation (1%) and deposit some funds");
        vm.prank(admin);
        accountant.setRiskParams(100, 0); // 1% max deviation
        _depositForUser(userA, 1000e6);

        _step("[Step 2] Attempt to push rate 20% above current (exceeds 1% limit)");
        vm.warp(block.timestamp + 1);
        accountant.updateExchangeRate(1.2e18, uint64(block.timestamp));
        assertTrue(accountant.paused(), "Accountant should be paused after circuit breaker");
        _step("  Accountant is now paused");

        assertEq(accountant.lastExchangeRate(), 1e18, "Rate should remain at old value");
        _step("  lastExchangeRate still 1.0e18");

        _step("[Step 3] Verify Gateway write ops are blocked");
        vm.prank(userB);
        vm.expectRevert(MantleVaultGateway.EnforcedPause.selector);
        gateway.deposit(100e6);
        _step("  deposit: blocked (EnforcedPause)");

        vm.prank(userA);
        vm.expectRevert(MantleVaultGateway.EnforcedPause.selector);
        gateway.redeem(100e6);
        _step("  redeem: blocked (EnforcedPause)");

        vm.prank(userA);
        vm.expectRevert(MantleVaultGateway.EnforcedPause.selector);
        gateway.requestRedeem(100e6);
        _step("  requestRedeem: blocked (EnforcedPause)");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 14. circuit breaker + emergencyRateUpdate recovery
    // -----------------------------------------------------------------------
    function test_CircuitBreakerRecoveryViaEmergency() public {
        _logCase(
            "test_CircuitBreakerRecoveryViaEmergency",
            unicode"circuit breaker 触发后 admin 用 emergencyRateUpdate 修正汇率并恢复业务"
        );

        _step("[Step 1] Trigger circuit breaker");
        vm.prank(admin);
        accountant.setRiskParams(100, 0); // 1% deviation
        _depositForUser(userA, 1000e6);

        vm.warp(block.timestamp + 1);
        accountant.updateExchangeRate(1.2e18, uint64(block.timestamp));
        assertTrue(accountant.paused(), "should be paused");
        _step("  Circuit breaker triggered, accountant paused");

        _step("[Step 2] Admin calls emergencyRateUpdate with corrected rate");
        vm.prank(admin);
        accountant.emergencyRateUpdate(1.005e18);
        assertFalse(accountant.paused(), "should be unpaused after emergency update");
        assertEq(accountant.lastExchangeRate(), 1.005e18, "rate should be corrected");
        _step(string.concat("  Rate corrected to: ", vm.toString(accountant.lastExchangeRate())));

        _step("[Step 3] Verify deposit restored");
        vm.prank(userB);
        uint256 shares = gateway.deposit(500e6);
        assertGt(shares, 0, "deposit should succeed");
        _step(string.concat("  deposit succeeded, shares: ", vm.toString(shares)));

        _step("[Step 4] Verify redeem restored");
        uint256 maxR = vault.maxRedeem(userA);
        _step(string.concat("  maxRedeem(userA): ", vm.toString(maxR)));
        assertGt(maxR, 0, "should have redeemable shares");
        vm.prank(userA);
        uint256 assets = gateway.redeem(maxR);
        assertGt(assets, 0, "redeem should succeed");
        _step(string.concat("  redeem succeeded, assets: ", vm.toString(assets)));

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 15. BOT超限更新: RateUpdateExecuted vs CircuitBreakerTriggered 并存
    // -----------------------------------------------------------------------
    function test_BotOverLimitUpdateEventsCoexist() public {
        _logCase(
            "test_BotOverLimitUpdateEventsCoexist",
            unicode"运营 BOT 发起超限更新时，RateUpdateExecuted 与实际未更新汇率并存"
        );

        _step("[Step 1] Deploy real AccountantExecutor");
        AccountantExecutor executorImpl = new AccountantExecutor();
        bytes memory execInitData = abi.encodeCall(AccountantExecutor.initialize, (admin));
        AccountantExecutor acctExec =
            AccountantExecutor(address(new ERC1967Proxy(address(executorImpl), execInitData)));

        vm.startPrank(admin);
        acctExec.grantRole(acctExec.BOT_ROLE(), bot);
        accountant.grantRole(accountant.EXECUTOR_ROLE(), address(acctExec));
        accountant.setRiskParams(100, 0); // tight 1% deviation
        vm.stopPrank();

        _depositForUser(userA, 1000e6);
        uint256 rateBefore = accountant.lastExchangeRate();
        _step(string.concat("  rate before: ", vm.toString(rateBefore)));

        _step("[Step 2] BOT calls executeUpdateRate with over-limit rate");
        vm.warp(block.timestamp + 1);
        uint64 badRate = 1.2e18;
        uint64 computeTs = uint64(block.timestamp);

        vm.prank(bot);
        acctExec.executeUpdateRate(address(accountant), badRate, computeTs);

        _step("[Step 3] Verify accountant state");
        assertTrue(accountant.paused(), "Accountant should be paused (circuit breaker)");
        assertEq(accountant.lastExchangeRate(), rateBefore, "Rate should NOT have changed");
        _step(string.concat("  rate after: ", vm.toString(accountant.lastExchangeRate())));
        _step("  [Finding] Executor emits RateUpdateExecuted but Accountant emits CircuitBreakerTriggered");
        _step("  [Finding] lastExchangeRate unchanged - relay success must not be mistaken for rate update");

        _logPass();
    }

    // =======================================================================
    // 会计更新、用户操作与结费交错场景 (lines 395-402)
    // =======================================================================

    // -----------------------------------------------------------------------
    // 16. deposit->updateExchangeRate->redeem vs updateExchangeRate->deposit->redeem
    // -----------------------------------------------------------------------
    function test_DepositRateRedeemOrderMatters() public {
        _logCase(
            "test_DepositRateRedeemOrderMatters",
            unicode"deposit -> updateExchangeRate -> redeem 与 updateExchangeRate -> deposit -> redeem 的最终赎回结果不同"
        );

        _step("[Step 1] Scenario A: deposit -> updateRate -> redeem");
        _depositForUser(userA, 1000e6);
        _warpAndUpdateRate(1, 1.1e18);
        // Add liquidity to cover higher-value redemption
        _addVaultLiquidity(200e6);
        uint256 maxRA = vault.maxRedeem(userA);
        vm.prank(userA);
        uint256 assetsA = gateway.redeem(maxRA);
        _step(string.concat("  Scenario A: deposited at 1.0, redeemed at 1.1, assets: ", vm.toString(assetsA)));

        _step("[Step 2] Scenario B: rate already 1.1, deposit -> redeem");
        _depositForUser(userB, 1000e6);
        uint256 sharesB = vault.balanceOf(userB);
        vm.prank(userB);
        uint256 assetsB = gateway.redeem(sharesB);
        _step(string.concat("  Scenario B: deposited at 1.1, redeemed at 1.1, assets: ", vm.toString(assetsB)));

        // Scenario A: got 1000 shares at 1.0, each share now worth 1.1 USDC
        // Scenario B: got ~909 shares at 1.1, each share worth 1.1 USDC, same rate deposit/redeem
        assertGt(assetsA, assetsB, "Scenario A yields more due to rate timing advantage");
        _step(string.concat("  Difference: ", vm.toString(assetsA - assetsB)));

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 17. requestRedeem->updateRate->finalize vs updateRate->requestRedeem->finalize
    // -----------------------------------------------------------------------
    function test_AsyncRedeemRateUpdateOrderMatters() public {
        _logCase(
            "test_AsyncRedeemRateUpdateOrderMatters",
            unicode"requestRedeem -> updateExchangeRate -> finalize 与 updateExchangeRate -> requestRedeem -> finalize 对异步赎回估值口径的影响不同"
        );

        _step("[Step 1] Scenario A: requestRedeem at rate 1.0 -> update to 1.1 -> finalize");
        _depositForUser(userA, 1000e6);
        uint256 sharesA = vault.balanceOf(userA);
        vm.prank(userA);
        uint256 reqA = gateway.requestRedeem(sharesA);
        (,,,, uint256 estA,,,) = vault.requests(reqA);
        _step(string.concat("  estimatedAssets at rate 1.0: ", vm.toString(estA)));
        _warpAndUpdateRate(1, 1.1e18);

        _step("[Step 2] Scenario B: rate is 1.1, deposit then requestRedeem");
        _depositForUser(userB, 1000e6);
        uint256 sharesB = vault.balanceOf(userB);
        vm.prank(userB);
        uint256 reqB = gateway.requestRedeem(sharesB);
        (,,,, uint256 estB,,,) = vault.requests(reqB);
        _step(string.concat("  estimatedAssets at rate 1.1: ", vm.toString(estB)));

        _step("[Step 3] Verify estimatedAssets differ due to request-time rate");
        // userA: 1000 shares requested at rate 1.0, estA = 1000*1.0*(1-1%) = 990
        // userB: ~909 shares requested at rate 1.1, estB = 909*1.1*(1-1%) ≈ 989
        // userA has more shares, so estA should be >= estB
        _step(string.concat("  estA (requested at 1.0): ", vm.toString(estA)));
        _step(string.concat("  estB (requested at 1.1): ", vm.toString(estB)));
        assertGe(estA, estB, "estA should be >= estB (more shares, requested at lower rate)");

        _step("[Step 4] Finalize both (vault has USDC from deposits)");
        uint256[] memory idsA = new uint256[](1);
        idsA[0] = reqA;
        uint256[] memory idsB = new uint256[](1);
        idsB[0] = reqB;

        vm.prank(bot);
        opExecutor.executeProcessRedeemBatch(address(controller), idsA);
        vm.prank(bot);
        opExecutor.executeProcessRedeemBatch(address(controller), idsB);

        uint256[] memory settledA = new uint256[](1);
        settledA[0] = estA;
        vm.prank(bot);
        opExecutor.executeFinalizeRedeemBatch(address(controller), idsA, settledA);

        uint256[] memory settledB = new uint256[](1);
        settledB[0] = estB;
        vm.prank(bot);
        opExecutor.executeFinalizeRedeemBatch(address(controller), idsB, settledB);

        _step(string.concat("  Settled A: ", vm.toString(estA), ", Settled B: ", vm.toString(estB)));
        _step("  estimatedAssets frozen at request time, settledAssets by operator");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 18. Fee settlement before rate write: user ops differ before/after
    // -----------------------------------------------------------------------
    function test_FeeSettleBeforeRateWrite() public {
        _logCase(
            "test_FeeSettleBeforeRateWrite",
            unicode"自动管理费结算先于汇率写入，验证用户在更新前后操作的差异"
        );

        _step("[Step 1] userA deposits 10000 USDC at rate 1.0");
        _depositForUser(userA, 10_000e6);

        _step("[Step 2] Seed fee base");
        _seedFeeBase();

        _step("[Step 3] Warp 365 days to accrue significant fee");
        vm.warp(block.timestamp + 365 days);

        _step("[Step 4] userB deposits before rate update");
        _depositForUser(userB, 10_000e6);
        uint256 sharesB = vault.balanceOf(userB);
        _step(string.concat("  userB shares (before update): ", vm.toString(sharesB)));

        _step("[Step 5] updateExchangeRate triggers fee settlement atomically");
        uint256 supplyBefore = vault.totalSupply();
        _updateRate(1.05e18);
        uint256 supplyAfter = vault.totalSupply();
        uint256 feeShares = supplyAfter - supplyBefore;
        _step(string.concat("  fee shares minted: ", vm.toString(feeShares)));
        assertGt(feeShares, 0, "should mint fee shares");

        _step("[Step 6] userC deposits after rate update + fee settle");
        _depositForUser(userC, 10_000e6);
        uint256 sharesC = vault.balanceOf(userC);
        _step(string.concat("  userC shares (after update): ", vm.toString(sharesC)));

        assertGt(sharesB, sharesC, "userB got more shares (before fee settle + rate change)");
        _step("  [Finding] Difference includes fee-share dilution + rate change effect");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 19. processRedeemBatch before/after rebalance
    // -----------------------------------------------------------------------
    function test_ProcessBatchBeforeAfterRebalance() public {
        _logCase(
            "test_ProcessBatchBeforeAfterRebalance",
            unicode"processRedeemBatch 前后插入一次 rebalance，验证筹资路径差异"
        );

        _step("[Step 1] Users deposit, userC adds extra liquidity");
        _depositForUser(userA, 5000e6);
        _depositForUser(userB, 5000e6);
        _depositForUser(userC, 50_000e6);  // extra liquidity so rebalance has excess to invest

        _step("[Step 2] userA and userB request async redeem");
        uint256 sharesA = vault.balanceOf(userA);
        uint256 sharesB = vault.balanceOf(userB);
        vm.prank(userA);
        uint256 reqA = gateway.requestRedeem(sharesA);
        vm.prank(userB);
        uint256 reqB = gateway.requestRedeem(sharesB);

        _step("[Step 3] Snapshot state for two-path comparison");
        uint256 snapId = vm.snapshot();

        // ── Path A: directly processRedeemBatch (no rebalance) ──
        _step("[Path A] Process both batches directly (no prior rebalance)");
        uint256[] memory idsA_pathA = new uint256[](1);
        idsA_pathA[0] = reqA;
        vm.prank(bot);
        opExecutor.executeProcessRedeemBatch(address(controller), idsA_pathA);
        uint256[] memory idsB_pathA = new uint256[](1);
        idsB_pathA[0] = reqB;
        vm.prank(bot);
        opExecutor.executeProcessRedeemBatch(address(controller), idsB_pathA);

        uint256 freeCash_pathA = vault.getFreeCash();
        uint256 vaultUsdc_pathA = usdc.balanceOf(address(vault));
        uint256 adapterVal_pathA = adapter.totalValue();
        uint256 nextInFlight_pathA = vault.nextInFlightId();
        _step(string.concat("  Path A freeCash: ", vm.toString(freeCash_pathA)));
        _step(string.concat("  Path A vault USDC: ", vm.toString(vaultUsdc_pathA)));
        _step(string.concat("  Path A adapter value: ", vm.toString(adapterVal_pathA)));
        _step(string.concat("  Path A nextInFlightId: ", vm.toString(nextInFlight_pathA)));

        // ── Revert to snapshot for Path B ──
        vm.revertTo(snapId);

        // ── Path B: rebalance first, then processRedeemBatch ──
        _step("[Path B] Rebalance first (invest excess into adapter), then process");
        vm.prank(bot);
        opExecutor.executeRebalance(address(controller));
        uint256 adapterValAfterRebalance = adapter.totalValue();
        uint256 vaultUsdcAfterRebalance = usdc.balanceOf(address(vault));
        _step(string.concat("  adapter value after rebalance: ", vm.toString(adapterValAfterRebalance)));
        _step(string.concat("  vault USDC after rebalance: ", vm.toString(vaultUsdcAfterRebalance)));
        assertGt(adapterValAfterRebalance, 0, "rebalance should invest into adapter");

        uint256[] memory idsA_pathB = new uint256[](1);
        idsA_pathB[0] = reqA;
        vm.prank(bot);
        opExecutor.executeProcessRedeemBatch(address(controller), idsA_pathB);
        uint256[] memory idsB_pathB = new uint256[](1);
        idsB_pathB[0] = reqB;
        vm.prank(bot);
        opExecutor.executeProcessRedeemBatch(address(controller), idsB_pathB);

        uint256 freeCash_pathB = vault.getFreeCash();
        uint256 vaultUsdc_pathB = usdc.balanceOf(address(vault));
        uint256 adapterVal_pathB = adapter.totalValue();
        uint256 nextInFlight_pathB = vault.nextInFlightId();
        _step(string.concat("  Path B freeCash: ", vm.toString(freeCash_pathB)));
        _step(string.concat("  Path B vault USDC: ", vm.toString(vaultUsdc_pathB)));
        _step(string.concat("  Path B adapter value: ", vm.toString(adapterVal_pathB)));
        _step(string.concat("  Path B nextInFlightId: ", vm.toString(nextInFlight_pathB)));

        _step("[Step 4] Compare two paths");
        // Path A: vault had all USDC, no divest needed
        // Path B: rebalance invested excess, process may trigger divest, creating more in-flights
        assertGt(nextInFlight_pathB, nextInFlight_pathA,
            "Path B should have more in-flight records due to rebalance invest + process divest");
        _step(string.concat("  Path A in-flight count: ", vm.toString(nextInFlight_pathA)));
        _step(string.concat("  Path B in-flight count: ", vm.toString(nextInFlight_pathB)));
        _step(string.concat("  Path A vault USDC: ", vm.toString(vaultUsdc_pathA)));
        _step(string.concat("  Path B vault USDC: ", vm.toString(vaultUsdc_pathB)));
        _step("  PASS: different order leads to different divest path, in-flight count, and freeCash");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 20. Rate update failure: user should not see half-complete state
    // -----------------------------------------------------------------------
    function test_RateUpdateFailureNoHalfState() public {
        _logCase(
            "test_RateUpdateFailureNoHalfState",
            unicode"汇率更新未成功生效时，用户不应读到半完成状态"
        );

        _step("[Step 1] Deposit some funds");
        _depositForUser(userA, 1000e6);
        uint256 rateBefore = accountant.lastExchangeRate();
        uint64 lastCompute = accountant.lastComputeTimestamp();
        uint64 lastUpdate = accountant.lastUpdateTimestamp();

        _step("[Step 2] Case A: revert due to stale computeTimestamp");
        vm.expectRevert(abi.encodeWithSelector(
            Accountant.StaleComputeTimestamp.selector, lastCompute, lastCompute
        ));
        accountant.updateExchangeRate(1.05e18, lastCompute); // same as last -> stale
        _step("  Reverted. Checking state is unchanged:");
        assertEq(accountant.lastExchangeRate(), rateBefore, "rate unchanged after revert");
        assertEq(accountant.lastComputeTimestamp(), lastCompute, "compute ts unchanged");
        assertEq(accountant.lastUpdateTimestamp(), lastUpdate, "update ts unchanged");
        _step("  All state unchanged after revert");

        _step("[Step 3] Case B: circuit breaker (over-deviation)");
        vm.prank(admin);
        accountant.setRiskParams(100, 0); // 1%
        vm.warp(block.timestamp + 1);
        accountant.updateExchangeRate(1.5e18, uint64(block.timestamp)); // 50% deviation
        assertTrue(accountant.paused(), "should be paused");
        assertEq(accountant.lastExchangeRate(), rateBefore, "rate still old value");
        _step("  Circuit breaker: paused, old rate preserved");
        _step("  [Finding] User will never read a partially-written new rate");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 21. processRedeemBatch before/after rate update: batchTotalAsset differs
    // -----------------------------------------------------------------------
    function test_ProcessBatchBeforeAfterRateUpdate() public {
        _logCase(
            "test_ProcessBatchBeforeAfterRateUpdate",
            unicode"更新汇率前后分别 processRedeemBatch，比较链上计算的 batchTotalAsset 差异"
        );

        _step("[Step 1] Two users deposit and request async redeem at rate 1.0");
        _depositForUser(userA, 1000e6);
        _depositForUser(userB, 1000e6);

        uint256 sharesA = vault.balanceOf(userA);
        uint256 sharesB = vault.balanceOf(userB);

        vm.prank(userA);
        uint256 reqA = gateway.requestRedeem(sharesA);
        vm.prank(userB);
        uint256 reqB = gateway.requestRedeem(sharesB);

        _step("[Step 2] Process batch 1 (userA) at rate 1.0, capture batchTotalAsset");
        uint256[] memory ids1 = new uint256[](1);
        ids1[0] = reqA;
        vm.recordLogs();
        vm.prank(bot);
        opExecutor.executeProcessRedeemBatch(address(controller), ids1);
        Vm.Log[] memory logs1 = vm.getRecordedLogs();
        // RedeemBatchProcessing(uint256 indexed batchSize, uint256 batchTotalAsset, uint256 shortfallAsset)
        bytes32 batchEventSig = keccak256("RedeemBatchProcessing(uint256,uint256,uint256)");
        uint256 batchTotalAsset1;
        for (uint256 i = 0; i < logs1.length; i++) {
            if (logs1[i].topics[0] == batchEventSig) {
                (batchTotalAsset1,) = abi.decode(logs1[i].data, (uint256, uint256));
            }
        }
        _step(string.concat("  Batch 1 batchTotalAsset (rate 1.0): ", vm.toString(batchTotalAsset1)));

        _step("[Step 3] Update rate to 1.08");
        _warpAndUpdateRate(1, 1.08e18);

        _step("[Step 4] Process batch 2 (userB) at rate 1.08, capture batchTotalAsset");
        uint256[] memory ids2 = new uint256[](1);
        ids2[0] = reqB;
        vm.recordLogs();
        vm.prank(bot);
        opExecutor.executeProcessRedeemBatch(address(controller), ids2);
        Vm.Log[] memory logs2 = vm.getRecordedLogs();
        uint256 batchTotalAsset2;
        for (uint256 i = 0; i < logs2.length; i++) {
            if (logs2[i].topics[0] == batchEventSig) {
                (batchTotalAsset2,) = abi.decode(logs2[i].data, (uint256, uint256));
            }
        }
        _step(string.concat("  Batch 2 batchTotalAsset (rate 1.08): ", vm.toString(batchTotalAsset2)));

        _step("[Step 5] Verify batchTotalAsset differs due to rate change");
        (,,,, uint256 estA,,,) = vault.requests(reqA);
        (,,,, uint256 estB,,,) = vault.requests(reqB);
        _step(string.concat("  estA (requested at 1.0): ", vm.toString(estA)));
        _step(string.concat("  estB (requested at 1.0): ", vm.toString(estB)));
        // Both requested at same rate → same estimatedAssets
        assertEq(estA, estB, "estimatedAssets should be equal (both requested at rate 1.0)");
        // But batchTotalAsset uses current rate at process time → different
        assertGt(batchTotalAsset2, batchTotalAsset1,
            "batch 2 batchTotalAsset should be higher (processed at higher rate)");
        _step("  PASS: same shares, same estimatedAssets, but different batchTotalAsset due to rate change");

        _step("[Step 6] Finalize both (vault has USDC from deposits)");
        uint256[] memory settledA = new uint256[](1);
        settledA[0] = estA;
        vm.prank(bot);
        opExecutor.executeFinalizeRedeemBatch(address(controller), ids1, settledA);

        uint256[] memory settledB = new uint256[](1);
        settledB[0] = estB;
        vm.prank(bot);
        opExecutor.executeFinalizeRedeemBatch(address(controller), ids2, settledB);

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 22. Fee settlement creates treasury shares, affects user share ratio
    // -----------------------------------------------------------------------
    function test_FeeSettleTreasurySharesAffectRatio() public {
        _logCase(
            "test_FeeSettleTreasurySharesAffectRatio",
            unicode"自动结费导致 treasury 获得新 shares 后，再次赎回会改变剩余用户占比"
        );

        _step("[Step 1] userA deposits");
        _depositForUser(userA, 10_000e6);

        _step("[Step 2] Seed fee base");
        _seedFeeBase();

        uint256 totalBefore = vault.totalSupply();
        uint256 treasurySharesBefore = vault.balanceOf(treasury);
        _step(string.concat("  totalSupply: ", vm.toString(totalBefore)));
        _step(string.concat("  treasury shares: ", vm.toString(treasurySharesBefore)));

        _step("[Step 3] Warp 180 days, trigger fee settlement via rate update");
        vm.warp(block.timestamp + 180 days);
        _updateRate(uint64(accountant.lastExchangeRate())); // same rate, just trigger fee settle
        uint256 totalAfter = vault.totalSupply();
        uint256 treasurySharesAfter = vault.balanceOf(treasury);
        _step(string.concat("  totalSupply after fee settle: ", vm.toString(totalAfter)));
        _step(string.concat("  treasury shares after: ", vm.toString(treasurySharesAfter)));
        assertGt(treasurySharesAfter, treasurySharesBefore, "treasury should have more shares");

        _step("[Step 4] Verify userA's share ratio decreased");
        uint256 userARatio = vault.balanceOf(userA) * 1e18 / totalAfter;
        uint256 userARatioBefore = vault.balanceOf(userA) * 1e18 / totalBefore;
        _step(string.concat("  userA ratio before: ", vm.toString(userARatioBefore)));
        _step(string.concat("  userA ratio after: ", vm.toString(userARatio)));
        assertLt(userARatio, userARatioBefore, "userA's share proportion should decrease after fee mint");

        _step("[Step 5] Treasury redeems its fee shares, verify userA ratio recovers");
        uint256 userASharesBefore = vault.balanceOf(userA);
        uint256 treasuryMaxRedeem = vault.maxRedeem(treasury);
        _step(string.concat("  treasury maxRedeem: ", vm.toString(treasuryMaxRedeem)));
        if (treasuryMaxRedeem > 0) {
            vm.prank(treasury);
            uint256 treasuryAssets = gateway.redeem(treasuryMaxRedeem);
            _step(string.concat("  treasury redeemed assets: ", vm.toString(treasuryAssets)));
            assertGt(treasuryAssets, 0, "treasury should receive assets");
        }

        uint256 totalAfterRedeem = vault.totalSupply();
        uint256 userARatioAfterRedeem = vault.balanceOf(userA) * 1e18 / totalAfterRedeem;
        _step(string.concat("  userA ratio after treasury redeem: ", vm.toString(userARatioAfterRedeem)));
        assertGt(userARatioAfterRedeem, userARatio, "userA ratio should recover after treasury redeems");

        _step("[Step 6] Account book consistency");
        assertEq(vault.balanceOf(userA), userASharesBefore, "userA shares unchanged by treasury redeem");
        _step("  Account book consistent");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 23. circuit breaker -> emergencyRateUpdate -> user resumes
    // -----------------------------------------------------------------------
    function test_CircuitBreakerEmergencyRecoveryFullChain() public {
        _logCase(
            "test_CircuitBreakerEmergencyRecoveryFullChain",
            unicode"circuit breaker -> emergencyRateUpdate -> 用户恢复操作 的顺序链路正确"
        );

        _step("[Step 1] Set tight deviation and deposit");
        vm.prank(admin);
        accountant.setRiskParams(100, 0);
        _depositForUser(userA, 1000e6);

        _step("[Step 2] BOT triggers circuit breaker");
        vm.warp(block.timestamp + 1);
        accountant.updateExchangeRate(1.5e18, uint64(block.timestamp)); // 50% deviation
        assertTrue(accountant.paused(), "should be paused");
        uint256 oldRate = accountant.lastExchangeRate();
        assertEq(oldRate, 1e18, "rate unchanged");
        _step(string.concat("  Paused, old rate: ", vm.toString(oldRate)));

        _step("[Step 3] User tries Gateway ops - all fail");
        vm.prank(userB);
        vm.expectRevert(MantleVaultGateway.EnforcedPause.selector);
        gateway.deposit(100e6);
        _step("  deposit: blocked");

        vm.prank(userA);
        vm.expectRevert(MantleVaultGateway.EnforcedPause.selector);
        gateway.redeem(100e6);
        _step("  redeem: blocked");

        vm.prank(userA);
        vm.expectRevert(MantleVaultGateway.EnforcedPause.selector);
        gateway.requestRedeem(100e6);
        _step("  requestRedeem: blocked");

        _step("[Step 4] Admin calls emergencyRateUpdate");
        vm.prank(admin);
        accountant.emergencyRateUpdate(1.005e18);
        assertFalse(accountant.paused(), "should be unpaused");
        assertEq(accountant.lastExchangeRate(), 1.005e18, "rate updated");
        _step(string.concat("  Rate updated to: ", vm.toString(accountant.lastExchangeRate())));

        _step("[Step 5] User ops restored");
        vm.prank(userB);
        uint256 s = gateway.deposit(500e6);
        assertGt(s, 0, "deposit succeeds");
        _step("  deposit: success");

        uint256 maxR = vault.maxRedeem(userA);
        assertGt(maxR, 0, "should be redeemable");
        uint256 redeemAmount = maxR / 4; // redeem small portion, keep shares for requestRedeem
        vm.prank(userA);
        uint256 a = gateway.redeem(redeemAmount);
        assertGt(a, 0, "redeem succeeds");
        _step("  redeem: success");

        uint256 remainingShares = vault.balanceOf(userA);
        assertGt(remainingShares, 0, "userA should still have shares");
        vm.prank(userA);
        uint256 reqId = gateway.requestRedeem(remainingShares);
        assertGt(reqId, 0, "requestRedeem succeeds");
        _step(string.concat("  requestRedeem: success, reqId=", vm.toString(reqId)));

        _logPass();
    }
}
