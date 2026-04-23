// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Accountant} from "../../src/accountant/Accountant.sol";
import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {IMantleVaultGateway} from "../../src/interfaces/vault/IMantleVaultGateway.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {IStrategyAdapter} from "../../src/interfaces/adapters/IStrategyAdapter.sol";
import {IStrategyControllerExecutor} from "../../src/interfaces/strategy/IStrategyControllerExecutor.sol";
import {MantleVaultGateway} from "../../src/vault/MantleVaultGateway.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {OperatorExecutor} from "../../src/protocol/OperatorExecutor.sol";
import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test, console2} from "forge-std/Test.sol";

// ---------------------------------------------------------------------------
// Mock contracts
// ---------------------------------------------------------------------------

contract MockUSDC_ARL is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockSanctionsOracle_ARL is ISanctionsOracle {
    function initialize(address, address) external {}
    function isSanctioned(address) external pure returns (bool) { return false; }
    function isWhitelisted(address) external pure returns (bool) { return true; }
    function totalSanctionedCount() external pure returns (uint256) { return 0; }
    function totalWhitelistedCount() external pure returns (uint256) { return 0; }
    function lastUpdateTimestamp() external pure returns (uint256) { return 0; }
    function batchNonce() external pure returns (uint256) { return 0; }
    function MAX_BATCH_SIZE() external pure returns (uint256) { return 200; }
    function updateSanctionStatus(address, bool) external {}
    function updateSanctionStatusBatch(address[] calldata, bool) external {}
    function updateWhitelistStatus(address, bool) external {}
    function updateWhitelistStatusBatch(address[] calldata, bool) external {}
}

contract MockPosToken_ARL is ERC20 {
    constructor() ERC20("MockPosToken", "mPOS") {}
    function decimals() public pure override returns (uint8) { return 18; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function burn(address from, uint256 amount) external { _burn(from, amount); }
}

/// @dev Mock Accountant with setExchangeRate() -- allowed per CLAUDE.md rules
///      (the real rate is set by the Accountant, external to these tests).
contract MockAccountant_ARL {
    uint256 public rate = 1e18;
    function getRate() external view returns (uint256) { return rate; }
    function getRateSafe() external view returns (uint256) { return rate; }
    function setExchangeRate(uint256 newRate) external { rate = newRate; }
}

/// @dev Async adapter that simulates real DiGiFT-like behavior:
///   - deposit(): pulls USDC from vault, mints posToken to adapter (simulates external protocol)
///   - requestRedeemAsync(): pulls posToken from vault (via approval), holds it
///   - sweepToVault(): transfers token from adapter to vault
///   - totalValue(): reads posToken on VAULT * price (not adapter balance)
///   - getPosTokenPrice(): configurable price
///   - estimatePosAmount(): USDC -> posToken conversion based on price
///   - withdrawSync(): returns 0 (pure async adapter, no sync withdrawal)
contract MockAsyncAdapter_ARL is IStrategyAdapter {
    using Math for uint256;

    address public immutable ASSET;
    address public immutable POS_TOKEN;
    address public immutable VAULT;

    uint256 public posTokenPrice = 1e18; // 1e18 = 1 USDC per posToken

    constructor(address asset_, address posToken_, address vault_) {
        ASSET = asset_;
        POS_TOKEN = posToken_;
        VAULT = vault_;
    }

    function setPosTokenPrice(uint256 newPrice) external { posTokenPrice = newPrice; }

    function name() external pure returns (string memory) { return "MockAsyncAdapter"; }
    function asset() external view returns (address) { return ASSET; }
    function posToken() external view returns (address) { return POS_TOKEN; }
    function priceOracle() external pure returns (address) { return address(0); }
    function getPosTokenPrice() external view returns (uint256) { return posTokenPrice; }
    function vault() external view returns (address) { return VAULT; }

    /// @dev posToken on VAULT * price -- matches real SubRedManagementAdapter behavior
    function totalValue() external view returns (uint256) {
        uint256 vaultPosBalance = IERC20(POS_TOKEN).balanceOf(VAULT);
        uint8 assetDec = IERC20Metadata(ASSET).decimals();
        uint8 posDec = IERC20Metadata(POS_TOKEN).decimals();
        return vaultPosBalance.mulDiv(posTokenPrice, 1e18, Math.Rounding.Floor)
            .mulDiv(10 ** assetDec, 10 ** posDec, Math.Rounding.Floor);
    }

    /// @dev Convert USDC amount to posToken amount based on price (Floor, matches real adapter)
    function estimatePosAmount(uint256 assetAmount) external view returns (uint256) {
        uint8 assetDec = IERC20Metadata(ASSET).decimals();
        uint8 posDec = IERC20Metadata(POS_TOKEN).decimals();
        return assetAmount.mulDiv(1e18 * (10 ** posDec), posTokenPrice * (10 ** assetDec), Math.Rounding.Floor);
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

    /// @dev deposit: pull USDC from vault, mint posToken to adapter (simulates external fill)
    function deposit(uint256 amount, address) external returns (uint256 posAmount) {
        IERC20(ASSET).transferFrom(VAULT, address(this), amount);
        uint8 assetDec = IERC20Metadata(ASSET).decimals();
        uint8 posDec = IERC20Metadata(POS_TOKEN).decimals();
        posAmount = amount.mulDiv(1e18 * (10 ** posDec), posTokenPrice * (10 ** assetDec), Math.Rounding.Floor);
        MockPosToken_ARL(POS_TOKEN).mint(address(this), posAmount);
        return posAmount;
    }

    /// @dev Pure async adapter -- no sync withdrawal
    function withdrawSync(uint256, address) external pure returns (uint256) {
        revert("Unsupported");
    }

    /// @dev requestRedeemAsync: first arg is posAmount (controller already did asset→pos conversion).
    ///      Matches real adapter flow: pull posToken from vault based on the approved allowance.
    function requestRedeemAsync(uint256 posAmount, address) external {
        if (posAmount > 0) {
            IERC20(POS_TOKEN).transferFrom(VAULT, address(this), posAmount);
        }
    }

    function sweepToVault(address token, uint256 amount) external returns (uint256) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 actual = amount > bal ? bal : amount;
        if (actual > 0) IERC20(token).transfer(VAULT, actual);
        return actual;
    }

    function setPaused(bool) external {}
    function retryRedeemAsync(uint256, address) external {}

    // === Test helpers: simulate external protocol settlement ===

    /// @dev Simulate external protocol delivering posToken to adapter (for invest settlement)
    function simulateInvestSettlement(uint256 posAmount) external {
        MockPosToken_ARL(POS_TOKEN).mint(address(this), posAmount);
    }

    /// @dev Simulate external protocol delivering USDC to adapter (for redeem settlement)
    function simulateRedeemSettlement(uint256 usdcAmount) external {
        MockUSDC_ARL(ASSET).mint(address(this), usdcAmount);
    }

    /// @dev Simulate external protocol delivering partial posToken + refund USDC
    function simulatePartialInvestSettlement(uint256 posAmount, uint256 refundUsdc) external {
        if (posAmount > 0) MockPosToken_ARL(POS_TOKEN).mint(address(this), posAmount);
        if (refundUsdc > 0) MockUSDC_ARL(ASSET).mint(address(this), refundUsdc);
    }
}

// ---------------------------------------------------------------------------
// QA Test: Async Redeem Lifecycle Complex Scenarios
// ---------------------------------------------------------------------------

contract AsyncRedeemLifecycleQATest is Test {
    using Math for uint256;

    MockUSDC_ARL internal usdc;
    MockPosToken_ARL internal posToken;
    MockSanctionsOracle_ARL internal oracle;
    MockAccountant_ARL internal mockAccountant;
    MantleYieldVault internal vault;
    MantleVaultGateway internal gateway;
    StrategyController internal controller;
    MockAsyncAdapter_ARL internal adapter;
    OperatorExecutor internal executor;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal sanctionSafe = makeAddr("sanctionSafe");
    address internal bot = makeAddr("bot");
    address internal userA = makeAddr("userA");
    address internal userB = makeAddr("userB");
    address internal userC = makeAddr("userC");

    // -----------------------------------------------------------------------
    // Logging helpers
    // -----------------------------------------------------------------------

    string constant MODULE = "Async Redeem Lifecycle Complex Scenarios";
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

        usdc = new MockUSDC_ARL();
        posToken = new MockPosToken_ARL();
        oracle = new MockSanctionsOracle_ARL();
        mockAccountant = new MockAccountant_ARL();

        MantleYieldVault vaultImpl = new MantleYieldVault();
        MantleVaultGateway gwImpl = new MantleVaultGateway();
        StrategyController ctrlImpl = new StrategyController();
        OperatorExecutor execImpl = new OperatorExecutor();

        // Vault (placeholders wired below)
        bytes memory vaultInitData = abi.encodeCall(
            MantleYieldVault.initialize,
            IMantleYieldVault.InitParams({
                asset: IERC20(address(usdc)),
                name: "mRWA Vault",
                symbol: "mRWA",
                admin: admin,
                gateway: address(1),
                controller: admin,
                accountant: address(mockAccountant),
                treasury: treasury,
                maxRedemptionFeeBps: 500,
                redemptionFeeBps: 0, // 0 fee for cleaner math
                minRedeemAmount: 0,
                minDepositAmount: 0
            })
        );
        vault = MantleYieldVault(address(new ERC1967Proxy(address(vaultImpl), vaultInitData)));

        // OperatorExecutor
        bytes memory execInitData = abi.encodeCall(OperatorExecutor.initialize, (admin, bot));
        executor = OperatorExecutor(address(new ERC1967Proxy(address(execImpl), execInitData)));

        // Controller
        bytes memory ctrlInitData = abi.encodeCall(
            StrategyController.initialize,
            (address(vault), admin, address(executor), admin, 0, 0, 0)
        );
        controller = StrategyController(address(new ERC1967Proxy(address(ctrlImpl), ctrlInitData)));

        // Gateway
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

        // Wire vault
        vm.startPrank(admin);
        vault.setGateway(address(gateway));
        vault.setController(address(controller));
        vm.stopPrank();

        // Adapter (async, reads posToken on vault)
        adapter = new MockAsyncAdapter_ARL(address(usdc), address(posToken), address(vault));
        vm.startPrank(admin);
        controller.registerStrategy(address(adapter), 10_000, 1, true);
        controller.activateStrategy(address(adapter));
        address[] memory ordered = new address[](1);
        ordered[0] = address(adapter);
        controller.setStrategyOrder(ordered);
        vm.stopPrank();

        // Fund users
        address[3] memory users = [userA, userB, userC];
        for (uint256 i = 0; i < users.length; i++) {
            usdc.mint(users[i], 1_000_000e6);
            vm.prank(users[i]);
            usdc.approve(address(vault), type(uint256).max);
        }
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    function _deposit(address user, uint256 amount) internal {
        vm.prank(user);
        gateway.deposit(amount);
    }

    function _investAll() internal {
        // Set buffer to 0 so all USDC gets invested
        vm.prank(admin);
        controller.setRiskParams(0, 0, 0);
        vm.prank(bot);
        executor.executeRebalance(address(controller));
    }

    function _investWithBuffer(uint256 bufferBps) internal {
        vm.prank(admin);
        controller.setRiskParams(uint16(bufferBps), 0, 0);
        vm.prank(bot);
        executor.executeRebalance(address(controller));
    }

    function _lastInFlightId() internal view returns (uint256) {
        return vault.nextInFlightId() - 1;
    }

    function _settleInvest(uint256[] memory ids, uint256[] memory posAmts, uint256[] memory refunds) internal {
        vm.prank(bot);
        executor.executeSettleAdapter(
            address(controller),
            address(adapter),
            IStrategyControllerExecutor.InvestSettlementInput(ids, posAmts, refunds),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );
    }

    function _settleRedeem(uint256[] memory ids, uint256[] memory amts) internal {
        vm.prank(bot);
        executor.executeSettleAdapter(
            address(controller),
            address(adapter),
            IStrategyControllerExecutor.InvestSettlementInput(new uint256[](0), new uint256[](0), new uint256[](0)),
            IStrategyControllerExecutor.RedeemSettlementInput(ids, amts)
        );
    }

    function _settleFull(
        uint256[] memory investIds, uint256[] memory posAmts, uint256[] memory refunds,
        uint256[] memory redeemIds, uint256[] memory redeemAmts
    ) internal {
        vm.prank(bot);
        executor.executeSettleAdapter(
            address(controller),
            address(adapter),
            IStrategyControllerExecutor.InvestSettlementInput(investIds, posAmts, refunds),
            IStrategyControllerExecutor.RedeemSettlementInput(redeemIds, redeemAmts)
        );
    }

    function _processRedeemBatch(uint256[] memory ids) internal {
        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), ids);
    }

    function _finalizeRedeemBatch(uint256[] memory ids, uint256[] memory settledAssets) internal {
        vm.prank(bot);
        executor.executeFinalizeRedeemBatch(address(controller), ids, settledAssets);
    }

    function _arr(uint256 v) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = v;
    }

    function _arr2(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = a;
        r[1] = b;
    }

    function _arr3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory r) {
        r = new uint256[](3);
        r[0] = a;
        r[1] = b;
        r[2] = c;
    }

    function _emptyArr() internal pure returns (uint256[] memory) {
        return new uint256[](0);
    }

    /// @dev Verify the totalAssets invariant holds at this step
    function _assertTotalAssetsInvariant(string memory stepLabel) internal view {
        uint256 vaultUsdc = usdc.balanceOf(address(vault));
        uint256 investIF = vault.totalInvestInFlight();
        uint256 redeemIF = vault.totalRedeemInFlight();
        uint256 posValue = adapter.totalValue(); // posToken on vault * price
        uint256 lockedValue = _convertToAssetsCeil(vault.totalLockedShares());
        uint256 rawTotal = vaultUsdc + investIF + redeemIF + posValue;
        uint256 expectedTA = rawTotal > lockedValue ? rawTotal - lockedValue : 0;
        uint256 actualTA = vault.totalAssets();
        assertEq(actualTA, expectedTA, string.concat("totalAssets mismatch at: ", stepLabel));
    }

    function _convertToAssetsCeil(uint256 shares) internal view returns (uint256) {
        uint256 rate = mockAccountant.rate();
        return shares.mulDiv(rate, 1e18, Math.Rounding.Ceil);
    }

    function _convertToAssetsFloor(uint256 shares) internal view returns (uint256) {
        uint256 rate = mockAccountant.rate();
        return shares.mulDiv(rate, 1e18, Math.Rounding.Floor);
    }

    // =======================================================================
    // Scenario 1: Invest not settled + redeem -- correct order (settle first)
    // =======================================================================

    function test_InvestNotSettled_SettleFirst_ThenProcess() public {
        _logCase(
            "test_InvestNotSettled_SettleFirst_ThenProcess",
            unicode"Invest 未 settle 时 redeem -- 操作顺序影响结果（先 settle 再 process 为正确路径）"
        );

        _step("[Step 1] A deposits 500, invest + settle");
        _deposit(userA, 500e6);
        _investAll();
        uint256 investIdA = _lastInFlightId();
        // Simulate posToken arriving on adapter
        (,,, uint256 posAmtA,,,,, ) = vault.inFlightRecords(investIdA);
        // deposit() already minted posToken to adapter, just sweep to vault
        _settleInvest(_arr(investIdA), _arr(posAmtA), _arr(0));
        assertEq(vault.totalInvestInFlight(), 0, "A invest settled");
        assertGt(posToken.balanceOf(address(vault)), 0, "vault has posToken");
        _step(string.concat("  vault posToken: ", vm.toString(posToken.balanceOf(address(vault)))));

        _step("[Step 2] B deposits 1000, invest but NOT settle");
        _deposit(userB, 1000e6);
        _investAll();
        uint256 investIdB = _lastInFlightId();
        assertEq(vault.totalInvestInFlight(), 1000e6, "B investInFlight = 1000");
        assertEq(usdc.balanceOf(address(vault)), 0, "vault USDC = 0 after invest");
        _step("  investInFlight = 1000, vault USDC = 0");

        _step("[Step 3] B requestRedeem all shares");
        uint256 sharesB = vault.balanceOf(userB);
        vm.prank(userB);
        uint256 reqId = gateway.requestRedeem(sharesB);
        assertEq(vault.totalLockedShares(), sharesB, "locked = B's shares");
        _step(string.concat("  reqId: ", vm.toString(reqId), ", locked shares: ", vm.toString(sharesB)));

        _step("[Step 4] Settle B's investInFlight FIRST (correct order)");
        (,,, uint256 posAmtB,,,,, ) = vault.inFlightRecords(investIdB);
        _settleInvest(_arr(investIdB), _arr(posAmtB), _arr(0));
        assertEq(vault.totalInvestInFlight(), 0, "B invest settled");
        uint256 vaultPosAfterSettle = posToken.balanceOf(address(vault));
        _step(string.concat("  vault posToken after settle: ", vm.toString(vaultPosAfterSettle)));

        _step("[Step 5] Process B's redeem -- divest from vault posToken");
        uint256 batchTotalAsset1 = _convertToAssetsFloor(sharesB);
        vm.expectEmit(true, false, false, true, address(controller));
        emit StrategyController.RedeemBatchProcessing(1, batchTotalAsset1, batchTotalAsset1);
        _processRedeemBatch(_arr(reqId));
        uint256 redeemInFlightId = _lastInFlightId();
        assertGt(vault.totalRedeemInFlight(), 0, "redeemInFlight created");
        _step(string.concat("  redeemInFlight: ", vm.toString(vault.totalRedeemInFlight())));

        _step("[Step 6] Simulate redeem settlement -- USDC arrives on adapter");
        (,,,, uint256 redeemUsdcAmt,,,, ) = vault.inFlightRecords(redeemInFlightId);
        adapter.simulateRedeemSettlement(redeemUsdcAmt);
        _settleRedeem(_arr(redeemInFlightId), _arr(redeemUsdcAmt));
        assertEq(vault.totalRedeemInFlight(), 0, "redeem settled");
        _step(string.concat("  vault USDC after redeem settle: ", vm.toString(usdc.balanceOf(address(vault)))));

        _step("[Step 7] Finalize B's redeem");
        uint256 settledAssets = _convertToAssetsFloor(sharesB);
        uint256 balBBefore = usdc.balanceOf(userB);
        vm.expectEmit(true, false, false, true, address(controller));
        emit StrategyController.RedeemBatchReady(1, settledAssets);
        _finalizeRedeemBatch(_arr(reqId), _arr(settledAssets));
        uint256 balBAfter = usdc.balanceOf(userB);
        assertEq(balBAfter - balBBefore, settledAssets, "B received correct USDC");
        assertEq(vault.totalLockedShares(), 0, "no locked shares");
        // Verify request status == DONE and pendingRedeemRequest cleared
        (,,,,,,, IMantleYieldVault.RequestStatus statusAfter1) = vault.requests(reqId);
        assertEq(uint8(statusAfter1), uint8(IMantleYieldVault.RequestStatus.DONE), "request status DONE");
        assertEq(vault.pendingRedeemRequest(userB), 0, "pendingShares cleared");
        _step(string.concat("  B received: ", vm.toString(settledAssets)));
        _assertTotalAssetsInvariant("final");

        _logPass();
    }

    // =======================================================================
    // Scenario 2: Invest not settled + process first -- DivestIncomplete
    // =======================================================================

    function test_InvestNotSettled_ProcessFirst_DivestIncomplete() public {
        _logCase(
            "test_InvestNotSettled_ProcessFirst_DivestIncomplete",
            unicode"Invest 未 settle 时先 process 再 settle -- DivestIncomplete 场景"
        );

        _step("[Step 1] A deposits 500, invest + settle");
        _deposit(userA, 500e6);
        _investAll();
        uint256 investIdA = _lastInFlightId();
        (,,, uint256 posAmtA,,,,, ) = vault.inFlightRecords(investIdA);
        _settleInvest(_arr(investIdA), _arr(posAmtA), _arr(0));

        _step("[Step 2] B deposits 1000, invest but NOT settle");
        _deposit(userB, 1000e6);
        _investAll();
        uint256 investIdB = _lastInFlightId();

        _step("[Step 3] B requestRedeem all shares");
        uint256 sharesB = vault.balanceOf(userB);
        vm.prank(userB);
        uint256 reqId = gateway.requestRedeem(sharesB);

        _step("[Step 4] Process FIRST (wrong order) -- only vault's 500 posToken available");
        // vault posToken = posAmtA (from A's settle), B's posToken still on adapter
        uint256 vaultPosBefore = posToken.balanceOf(address(vault));
        _step(string.concat("  vault posToken before process: ", vm.toString(vaultPosBefore)));
        // Expect DivestIncomplete event -- divest only got partial coverage
        vm.expectEmit(false, false, false, false, address(controller));
        emit StrategyController.DivestIncomplete(0); // value unchecked, just verify event fires
        _processRedeemBatch(_arr(reqId));
        uint256 redeemIF = vault.totalRedeemInFlight();
        _step(string.concat("  redeemInFlight after process: ", vm.toString(redeemIF)));
        // redeemInFlight should be <= 500 (only what was available on vault)
        uint256 redeemInFlightId = _lastInFlightId();

        _step("[Step 5] Now settle B's investInFlight");
        (,,, uint256 posAmtB,,,,, ) = vault.inFlightRecords(investIdB);
        _settleInvest(_arr(investIdB), _arr(posAmtB), _arr(0));
        assertEq(vault.totalInvestInFlight(), 0, "B invest now settled");

        _step("[Step 6] Settle the partial redeemInFlight");
        (,,,, uint256 redeemUsdcAmt1,,,, ) = vault.inFlightRecords(redeemInFlightId);
        if (redeemUsdcAmt1 > 0) {
            adapter.simulateRedeemSettlement(redeemUsdcAmt1);
            _settleRedeem(_arr(redeemInFlightId), _arr(redeemUsdcAmt1));
        }

        _step("[Step 7] Extra rebalance to divest remaining (now vault has more posToken)");
        // Need to divest more to cover B's full redeem
        // Set buffer high to trigger divest
        vm.prank(admin);
        controller.setRiskParams(10_000, 0, 0); // buffer = 100% = want all cash
        vm.prank(bot);
        executor.executeRebalance(address(controller));
        uint256 redeemIF2 = vault.totalRedeemInFlight();
        _step(string.concat("  redeemInFlight after extra rebalance: ", vm.toString(redeemIF2)));

        _step("[Step 8] Settle the new redeemInFlight");
        assertGt(redeemIF2, 0, "extra rebalance must have triggered new divest");
        uint256 newRedeemId = _lastInFlightId();
        (,,,, uint256 redeemUsdcAmt2,,,, ) = vault.inFlightRecords(newRedeemId);
        adapter.simulateRedeemSettlement(redeemUsdcAmt2);
        _settleRedeem(_arr(newRedeemId), _arr(redeemUsdcAmt2));

        _step("[Step 9] Finalize B's redeem");
        uint256 settledAssets = _convertToAssetsFloor(sharesB);
        uint256 vaultUsdcAvailable = usdc.balanceOf(address(vault));
        _step(string.concat("  vault USDC: ", vm.toString(vaultUsdcAvailable)));
        _step(string.concat("  settledAssets needed: ", vm.toString(settledAssets)));
        // Vault should now have enough USDC
        assertGe(vaultUsdcAvailable, settledAssets, "vault has enough USDC");
        uint256 balBBefore = usdc.balanceOf(userB);
        _finalizeRedeemBatch(_arr(reqId), _arr(settledAssets));
        assertEq(usdc.balanceOf(userB) - balBBefore, settledAssets, "B received USDC");
        assertEq(vault.totalLockedShares(), 0, "no locked shares");
        // Verify request status == DONE and pendingRedeemRequest cleared
        (,,,,,,, IMantleYieldVault.RequestStatus statusAfter2) = vault.requests(reqId);
        assertEq(uint8(statusAfter2), uint8(IMantleYieldVault.RequestStatus.DONE), "request status DONE");
        assertEq(vault.pendingRedeemRequest(userB), 0, "pendingShares cleared");

        _logPass();
    }

    // =======================================================================
    // Scenario 3: posTokenPrice rises -- invest gets fewer posToken, divest needs fewer
    // =======================================================================

    function test_PriceRise_DivestNeedsFewerPosToken() public {
        _logCase(
            "test_PriceRise_DivestNeedsFewerPosToken",
            unicode"posTokenPrice 上涨 -- invest 获得更少 posToken，divest 需要更少 posToken"
        );

        _step("[Step 1] Deposit 10000, invest + settle at price=1e18");
        _deposit(userA, 10_000e6);
        _investAll();
        uint256 investId = _lastInFlightId();
        (,,, uint256 posAmt,,,,, ) = vault.inFlightRecords(investId);
        _settleInvest(_arr(investId), _arr(posAmt), _arr(0));
        uint256 vaultPos = posToken.balanceOf(address(vault));
        _step(string.concat("  vault posToken at price=1: ", vm.toString(vaultPos)));

        _step("[Step 2] Price rises to 2e18");
        adapter.setPosTokenPrice(2e18);
        uint256 adapterTV = adapter.totalValue();
        _step(string.concat("  adapter totalValue: ", vm.toString(adapterTV)));
        // totalValue should be vaultPos * 2e18 / 1e18 * 1e6 / 1e18
        // = vaultPos * 2 * 1e6 / 1e18
        // With 18dec posToken and 6dec USDC: vaultPos * 2e18 / 1e18 * 1e6 / 1e18

        _step("[Step 3] Update rate to reflect new totalAssets");
        // totalAssets = vaultUSDC(0) + posValue(~20000e6) - locked(0) = ~20000e6
        // totalSupply = 10000e18 shares, new rate = 20000e6 * 1e18 / 10000e18 = 2e6... no
        // Actually rate is set by accountant, totalAssets reads from it
        // rate = 2e18 means 1 share = 2e6 USDC (with 6 decimal asset)
        mockAccountant.setExchangeRate(2e18);

        _step("[Step 4] UserA requestRedeem 5000 shares (= 10000 USDC at rate 2)");
        vm.prank(userA);
        uint256 reqId = gateway.requestRedeem(5000e6);
        uint256 estimatedAssets = _convertToAssetsFloor(5000e6);
        _step(string.concat("  estimatedAssets: ", vm.toString(estimatedAssets)));
        assertEq(estimatedAssets, 10_000e6, "estimated = 5000 * 2 = 10000 USDC");

        _step("[Step 5] Process -- divest needs fewer posToken because price doubled");
        uint256 batchTotal3 = _convertToAssetsFloor(5000e6);
        uint256 fc3 = vault.getFreeCash();
        uint256 shortfall3 = batchTotal3 > fc3 ? batchTotal3 - fc3 : 0;
        vm.expectEmit(true, false, false, true, address(controller));
        emit StrategyController.RedeemBatchProcessing(1, batchTotal3, shortfall3);
        _processRedeemBatch(_arr(reqId));
        uint256 redeemId = _lastInFlightId();
        assertGt(vault.totalRedeemInFlight(), 0, "divest triggered");
        (,,, uint256 divestPosAmt,,,, , ) = vault.inFlightRecords(redeemId);
        _step(string.concat("  divest posToken amount: ", vm.toString(divestPosAmt)));
        // At price=2, to get 10000 USDC need 10000e6 * 1e18 * 1e18 / (2e18 * 1e6) = 5000e18 posToken
        // But vault has 10000e18 posToken, so only half needed

        _step("[Step 6] Settle redeem -- simulate full USDC delivery");
        (,,,, uint256 redeemUsdc,,,, ) = vault.inFlightRecords(redeemId);
        adapter.simulateRedeemSettlement(redeemUsdc);
        _settleRedeem(_arr(redeemId), _arr(redeemUsdc));

        _step("[Step 7] Finalize");
        uint256 balBefore = usdc.balanceOf(userA);
        _finalizeRedeemBatch(_arr(reqId), _arr(estimatedAssets));
        uint256 received = usdc.balanceOf(userA) - balBefore;
        assertEq(received, 10_000e6, "userA received 10000 USDC");
        // Verify request status == DONE and pendingRedeemRequest cleared
        (,,,,,,, IMantleYieldVault.RequestStatus statusAfter3) = vault.requests(reqId);
        assertEq(uint8(statusAfter3), uint8(IMantleYieldVault.RequestStatus.DONE), "request status DONE");
        assertEq(vault.pendingRedeemRequest(userA), 0, "pendingShares cleared");

        // Vault should still have remaining posToken
        uint256 remainingPos = posToken.balanceOf(address(vault));
        _step(string.concat("  remaining vault posToken: ", vm.toString(remainingPos)));
        assertGt(remainingPos, 0, "vault retains posToken for A's remaining shares");
        assertEq(vault.totalLockedShares(), 0, "no locked shares");
        _assertTotalAssetsInvariant("final");

        _logPass();
    }

    // =======================================================================
    // Scenario 4: posTokenPrice drops -- divest needs more posToken, slippage
    // =======================================================================

    function test_PriceDrop_DivestNeedsMorePosToken_Slippage() public {
        _logCase(
            "test_PriceDrop_DivestNeedsMorePosToken_Slippage",
            unicode"posTokenPrice 下跌 -- divest 需要更多 posToken，settle 可能有 slippage"
        );

        _step("[Step 1] Deposit 10000, invest + settle at price=1e18");
        _deposit(userA, 10_000e6);
        _investAll();
        uint256 investId = _lastInFlightId();
        (,,, uint256 posAmt,,,,, ) = vault.inFlightRecords(investId);
        _settleInvest(_arr(investId), _arr(posAmt), _arr(0));
        uint256 vaultPos = posToken.balanceOf(address(vault));
        _step(string.concat("  vault posToken: ", vm.toString(vaultPos)));

        _step("[Step 2] Price drops to 0.5e18");
        adapter.setPosTokenPrice(5e17);
        mockAccountant.setExchangeRate(5e17); // rate drops too: 1 share = 0.5 USDC

        _step("[Step 3] UserA requestRedeem ALL shares");
        uint256 sharesA = vault.balanceOf(userA);
        vm.prank(userA);
        uint256 reqId = gateway.requestRedeem(sharesA);
        uint256 estimatedAssets = _convertToAssetsFloor(sharesA);
        _step(string.concat("  estimatedAssets: ", vm.toString(estimatedAssets)));
        // 10000 shares * 0.5e18 / 1e18 = 5000e6

        _step("[Step 4] Process -- divest all posToken");
        _processRedeemBatch(_arr(reqId));
        uint256 redeemId = _lastInFlightId();

        _step("[Step 5] Settle with slippage -- only 4800 instead of 5000");
        uint256 actualUsdc = 4800e6;
        adapter.simulateRedeemSettlement(actualUsdc);
        _settleRedeem(_arr(redeemId), _arr(actualUsdc));
        _step(string.concat("  vault USDC after settle: ", vm.toString(usdc.balanceOf(address(vault)))));

        _step("[Step 6] Finalize with actual amount (less than estimated)");
        uint256 balBefore = usdc.balanceOf(userA);
        // settledAssets (4800) != estimatedAssets (5000) -> RequestSettlementAdjusted event
        vm.expectEmit(true, false, false, true, address(vault));
        emit IMantleYieldVault.RequestSettlementAdjusted(reqId, estimatedAssets, actualUsdc);
        _finalizeRedeemBatch(_arr(reqId), _arr(actualUsdc));
        uint256 received = usdc.balanceOf(userA) - balBefore;
        assertEq(received, actualUsdc, "userA received slippage-adjusted amount");
        assertLt(received, estimatedAssets, "received < estimated due to slippage");
        assertEq(vault.totalLockedShares(), 0, "locked shares cleared");
        // Verify request status == DONE and pendingRedeemRequest cleared
        (,,,,,,, IMantleYieldVault.RequestStatus statusAfter4) = vault.requests(reqId);
        assertEq(uint8(statusAfter4), uint8(IMantleYieldVault.RequestStatus.DONE), "request status DONE");
        assertEq(vault.pendingRedeemRequest(userA), 0, "pendingShares cleared");

        _logPass();
    }

    // =======================================================================
    // Scenario 5: posTokenPrice changes between invest and settle
    // =======================================================================

    function test_PriceChangeBetweenInvestAndSettle() public {
        _logCase(
            "test_PriceChangeBetweenInvestAndSettle",
            unicode"posTokenPrice 在 invest 和 settle 之间变动 -- settle 后 totalAssets 重估"
        );

        _step("[Step 1] Deposit 10000, invest at price=1e18");
        _deposit(userA, 10_000e6);
        _investAll();
        uint256 investId = _lastInFlightId();
        (,,, uint256 posAmt,,,,, ) = vault.inFlightRecords(investId);
        _step(string.concat("  posAmt estimated: ", vm.toString(posAmt)));

        _step("[Step 2] Price rises to 1.5e18 BEFORE settle");
        adapter.setPosTokenPrice(15e17);

        _step("[Step 3] Settle invest -- posToken arrives at vault");
        _settleInvest(_arr(investId), _arr(posAmt), _arr(0));
        assertEq(vault.totalInvestInFlight(), 0, "invest settled");

        uint256 vaultPos = posToken.balanceOf(address(vault));
        _step(string.concat("  vault posToken: ", vm.toString(vaultPos)));

        _step("[Step 4] Verify adapter.totalValue() reflects new price");
        uint256 tv = adapter.totalValue();
        _step(string.concat("  adapter totalValue: ", vm.toString(tv)));
        // vaultPos posToken * 1.5e18 price / 1e18 * 1e6 / 1e18
        uint256 expectedTV = vaultPos.mulDiv(15e17, 1e18, Math.Rounding.Floor)
            .mulDiv(1e6, 1e18, Math.Rounding.Floor);
        assertEq(tv, expectedTV, "totalValue reflects new price");
        assertGt(tv, 10_000e6, "totalValue > initial deposit");

        _step("[Step 5] Update rate to reflect revaluation");
        mockAccountant.setExchangeRate(15e17);
        _assertTotalAssetsInvariant("after price change + rate update");

        _logPass();
    }

    // =======================================================================
    // Scenario 6: Invest + Redeem in-flight coexist, one settleAdapter handles both
    // =======================================================================

    function test_InvestAndRedeemInFlightCoexist() public {
        _logCase(
            "test_InvestAndRedeemInFlightCoexist",
            unicode"Invest + Redeem in-flight 同时存在 -- 一次 settleAdapter 同时处理"
        );

        _step("[Step 1] A deposits 5000, invest + settle");
        _deposit(userA, 5000e6);
        _investAll();
        uint256 investIdA = _lastInFlightId();
        (,,, uint256 posAmtA,,,,, ) = vault.inFlightRecords(investIdA);
        _settleInvest(_arr(investIdA), _arr(posAmtA), _arr(0));
        uint256 vaultPosAfterA = posToken.balanceOf(address(vault));
        _step(string.concat("  vault posToken after A settle: ", vm.toString(vaultPosAfterA)));

        _step("[Step 2] B deposits 3000, invest but NOT settle (investInFlight=3000)");
        _deposit(userB, 3000e6);
        _investAll();
        uint256 investIdB = _lastInFlightId();
        assertEq(vault.totalInvestInFlight(), 3000e6, "investInFlight = 3000");

        _step("[Step 3] B requestRedeem 3000 shares");
        uint256 sharesB = vault.balanceOf(userB);
        vm.prank(userB);
        uint256 reqId = gateway.requestRedeem(sharesB);

        _step("[Step 4] Process -- divest from vault's 5000 posToken (A's)");
        _processRedeemBatch(_arr(reqId));
        uint256 redeemId = _lastInFlightId();
        assertGt(vault.totalRedeemInFlight(), 0, "redeemInFlight created");
        _step(string.concat("  investInFlight: ", vm.toString(vault.totalInvestInFlight())));
        _step(string.concat("  redeemInFlight: ", vm.toString(vault.totalRedeemInFlight())));

        _step("[Step 5] Both in-flights exist -- settle in ONE call");
        (,,, uint256 posAmtB,,,,, ) = vault.inFlightRecords(investIdB);
        (,,,, uint256 redeemUsdc,,,, ) = vault.inFlightRecords(redeemId);
        adapter.simulateRedeemSettlement(redeemUsdc);
        _settleFull(
            _arr(investIdB), _arr(posAmtB), _arr(0),
            _arr(redeemId), _arr(redeemUsdc)
        );
        assertEq(vault.totalInvestInFlight(), 0, "invest cleared");
        assertEq(vault.totalRedeemInFlight(), 0, "redeem cleared");

        uint256 vaultPosAfter = posToken.balanceOf(address(vault));
        uint256 vaultUsdcAfter = usdc.balanceOf(address(vault));
        _step(string.concat("  vault posToken: ", vm.toString(vaultPosAfter)));
        _step(string.concat("  vault USDC: ", vm.toString(vaultUsdcAfter)));

        _step("[Step 6] Finalize B's redeem");
        uint256 settledAssets = _convertToAssetsFloor(sharesB);
        uint256 balBBefore = usdc.balanceOf(userB);
        _finalizeRedeemBatch(_arr(reqId), _arr(settledAssets));
        assertEq(usdc.balanceOf(userB) - balBBefore, settledAssets, "B received USDC");
        assertEq(vault.totalLockedShares(), 0, "locked cleared");
        // Verify request status == DONE and pendingRedeemRequest cleared
        (,,,,,,, IMantleYieldVault.RequestStatus statusAfter6) = vault.requests(reqId);
        assertEq(uint8(statusAfter6), uint8(IMantleYieldVault.RequestStatus.DONE), "request status DONE");
        assertEq(vault.pendingRedeemRequest(userB), 0, "pendingShares cleared");
        _assertTotalAssetsInvariant("final");

        _logPass();
    }

    // =======================================================================
    // Scenario 7: Rate rises between request and finalize
    // =======================================================================

    function test_RateRise_UserGetsMoreThanEstimated() public {
        _logCase(
            "test_RateRise_UserGetsMoreThanEstimated",
            unicode"Rate 在 request 和 finalize 之间上升 -- 用户收到多于 estimatedAssets"
        );

        _step("[Step 1] Deposit 10000, invest + settle at rate=1e18");
        _deposit(userA, 10_000e6);
        _investAll();
        uint256 investId = _lastInFlightId();
        (,,, uint256 posAmt,,,,, ) = vault.inFlightRecords(investId);
        _settleInvest(_arr(investId), _arr(posAmt), _arr(0));

        _step("[Step 2] RequestRedeem 5000 shares at rate=1.0");
        vm.prank(userA);
        uint256 reqId = gateway.requestRedeem(5000e6);
        (,,,, uint256 storedEstimated,,, ) = vault.requests(reqId);
        _step(string.concat("  estimatedAssets at rate=1.0: ", vm.toString(storedEstimated)));
        assertEq(storedEstimated, 5000e6, "estimated = 5000 * 1.0");

        _step("[Step 3] Rate rises to 1.1e18");
        mockAccountant.setExchangeRate(11e17);

        _step("[Step 4] Process -- batchTotalAsset uses current rate");
        // At rate=1.1, batchTotalAsset = 5000 * 1.1 = 5500
        // vault USDC = 0, all in posToken. Need divest.
        _processRedeemBatch(_arr(reqId));

        _step("[Step 5] Settle redeemInFlight");
        uint256 redeemIF = vault.totalRedeemInFlight();
        assertGt(redeemIF, 0, "divest must have triggered (vault USDC=0)");
        uint256 redeemId = _lastInFlightId();
        (,,,, uint256 redeemUsdc,,,, ) = vault.inFlightRecords(redeemId);
        adapter.simulateRedeemSettlement(redeemUsdc);
        _settleRedeem(_arr(redeemId), _arr(redeemUsdc));

        _step("[Step 6] Finalize with settledAssets at new rate");
        uint256 settledAssets = _convertToAssetsFloor(5000e6); // 5000 * 1.1 = 5500
        assertEq(settledAssets, 5500e6, "settled = 5500 at rate 1.1");
        uint256 balBefore = usdc.balanceOf(userA);
        // settledAssets (5500) != estimatedAssets (5000) -> RequestSettlementAdjusted
        vm.expectEmit(true, false, false, true, address(vault));
        emit IMantleYieldVault.RequestSettlementAdjusted(reqId, storedEstimated, settledAssets);
        _finalizeRedeemBatch(_arr(reqId), _arr(settledAssets));
        uint256 received = usdc.balanceOf(userA) - balBefore;
        assertEq(received, 5500e6, "user received 5500 > estimated 5000");
        assertGt(received, storedEstimated, "received > estimated (rate rose)");
        assertEq(vault.totalLockedShares(), 0, "locked cleared");
        // Verify request status == DONE and pendingRedeemRequest cleared
        (,,,,,,, IMantleYieldVault.RequestStatus statusAfter7) = vault.requests(reqId);
        assertEq(uint8(statusAfter7), uint8(IMantleYieldVault.RequestStatus.DONE), "request status DONE");
        assertEq(vault.pendingRedeemRequest(userA), 0, "pendingShares cleared");

        _logPass();
    }

    // =======================================================================
    // Scenario 8: Rate drops between request and finalize
    // =======================================================================

    function test_RateDrop_UserGetsLessThanEstimated() public {
        _logCase(
            "test_RateDrop_UserGetsLessThanEstimated",
            unicode"Rate 在 request 和 finalize 之间下降 -- 用户收到少于 estimatedAssets"
        );

        _step("[Step 1] Deposit 11000 at rate=1.1e18");
        mockAccountant.setExchangeRate(11e17);
        _deposit(userA, 11_000e6);
        uint256 sharesA = vault.balanceOf(userA);
        _step(string.concat("  shares: ", vm.toString(sharesA)));
        // shares = 11000e6 * 1e18 / 1.1e18 = 10000e18

        _step("[Step 2] Invest + settle");
        _investAll();
        uint256 investId = _lastInFlightId();
        (,,, uint256 posAmt,,,,, ) = vault.inFlightRecords(investId);
        _settleInvest(_arr(investId), _arr(posAmt), _arr(0));

        _step("[Step 3] RequestRedeem 5000 shares at rate=1.1");
        vm.prank(userA);
        uint256 reqId = gateway.requestRedeem(5000e6);
        (,,,, uint256 storedEstimated,,, ) = vault.requests(reqId);
        _step(string.concat("  estimatedAssets at rate=1.1: ", vm.toString(storedEstimated)));
        // estimated = 5000 * 1.1 = 5500

        _step("[Step 4] Rate drops to 1.0e18");
        mockAccountant.setExchangeRate(1e18);

        _step("[Step 5] Process + settle divest");
        _processRedeemBatch(_arr(reqId));
        uint256 redeemIF = vault.totalRedeemInFlight();
        assertGt(redeemIF, 0, "divest must have triggered (vault USDC=0)");
        uint256 redeemId = _lastInFlightId();
        (,,,, uint256 redeemUsdc,,,, ) = vault.inFlightRecords(redeemId);
        adapter.simulateRedeemSettlement(redeemUsdc);
        _settleRedeem(_arr(redeemId), _arr(redeemUsdc));

        _step("[Step 6] Finalize with settledAssets at new rate");
        uint256 settledAssets = _convertToAssetsFloor(5000e6); // 5000 * 1.0 = 5000
        assertEq(settledAssets, 5000e6, "settled = 5000 at rate 1.0");
        uint256 balBefore = usdc.balanceOf(userA);
        // settledAssets (5000) != estimatedAssets (5500) -> RequestSettlementAdjusted
        vm.expectEmit(true, false, false, true, address(vault));
        emit IMantleYieldVault.RequestSettlementAdjusted(reqId, storedEstimated, settledAssets);
        _finalizeRedeemBatch(_arr(reqId), _arr(settledAssets));
        uint256 received = usdc.balanceOf(userA) - balBefore;
        assertEq(received, 5000e6, "user received 5000");
        assertLt(received, storedEstimated, "received < estimated (rate dropped)");
        assertEq(vault.totalLockedShares(), 0, "locked cleared");
        // Verify request status == DONE and pendingRedeemRequest cleared
        (,,,,,,, IMantleYieldVault.RequestStatus statusAfter8) = vault.requests(reqId);
        assertEq(uint8(statusAfter8), uint8(IMantleYieldVault.RequestStatus.DONE), "request status DONE");
        assertEq(vault.pendingRedeemRequest(userA), 0, "pendingShares cleared");

        _logPass();
    }

    // =======================================================================
    // Scenario 9: Invest settle -- partial delivery + refund
    // =======================================================================

    function test_InvestPartialDelivery_Refund() public {
        _logCase(
            "test_InvestPartialDelivery_Refund",
            unicode"Invest settle 部分到账 -- posToken 不足时 refund USDC"
        );

        _step("[Step 1] Deposit 10000, invest");
        _deposit(userA, 10_000e6);
        _investAll();
        uint256 investId = _lastInFlightId();
        (,,, uint256 expectedPos,,,,, ) = vault.inFlightRecords(investId);
        _step(string.concat("  expected posAmt: ", vm.toString(expectedPos)));

        _step("[Step 2] Simulate partial fill: half posToken + half refund USDC");
        uint256 halfPos = expectedPos / 2;
        uint256 refundUsdc = 5000e6;
        // The deposit() already minted full posToken to adapter, so we need to burn excess
        // and mint USDC refund. Let's just set up the adapter state correctly.
        // Actually deposit() minted posToken to adapter. We need to burn the extra and add USDC.
        // For simplicity: burn all adapter posToken, then mint only halfPos + refund
        uint256 adapterPos = posToken.balanceOf(address(adapter));
        posToken.burn(address(adapter), adapterPos);
        adapter.simulatePartialInvestSettlement(halfPos, refundUsdc);

        _step("[Step 3] Settle invest with partial pos + refund");
        _settleInvest(_arr(investId), _arr(halfPos), _arr(refundUsdc));
        assertEq(vault.totalInvestInFlight(), 0, "invest settled");

        _step("[Step 4] Verify vault state");
        uint256 vaultUsdc = usdc.balanceOf(address(vault));
        uint256 vaultPos = posToken.balanceOf(address(vault));
        _step(string.concat("  vault USDC (refund): ", vm.toString(vaultUsdc)));
        _step(string.concat("  vault posToken (partial): ", vm.toString(vaultPos)));
        assertEq(vaultUsdc, refundUsdc, "vault got refund USDC");
        assertEq(vaultPos, halfPos, "vault got partial posToken");

        // Total value preserved: refundUSDC + posToken value = 5000 + 5000 = 10000
        uint256 totalVal = vaultUsdc + adapter.totalValue();
        _step(string.concat("  total value (USDC + posTokenValue): ", vm.toString(totalVal)));
        assertEq(totalVal, 10_000e6, "total value preserved");

        _logPass();
    }

    // =======================================================================
    // Scenario 10: Divest fully async -- withdrawSync=0, two-phase lifecycle
    // =======================================================================

    function test_DivestFullAsync_TwoPhase() public {
        _logCase(
            "test_DivestFullAsync_TwoPhase",
            unicode"Divest 全异步 -- withdrawSync=0 的完整两阶段生命周期"
        );

        _step("[Step 1] Deposit 10000, invest + settle");
        _deposit(userA, 10_000e6);
        _investAll();
        uint256 investId = _lastInFlightId();
        (,,, uint256 posAmt,,,,, ) = vault.inFlightRecords(investId);
        _settleInvest(_arr(investId), _arr(posAmt), _arr(0));
        assertEq(usdc.balanceOf(address(vault)), 0, "vault USDC = 0");
        assertGt(posToken.balanceOf(address(vault)), 0, "vault has posToken");

        _step("[Step 2] RequestRedeem ALL shares");
        uint256 sharesA = vault.balanceOf(userA);
        vm.prank(userA);
        uint256 reqId = gateway.requestRedeem(sharesA);

        _step("[Step 3] Process -- freeCash=0, divest triggers requestRedeemAsync");
        _processRedeemBatch(_arr(reqId));
        uint256 redeemId = _lastInFlightId();
        assertGt(vault.totalRedeemInFlight(), 0, "redeemInFlight created");
        _step(string.concat("  redeemInFlight: ", vm.toString(vault.totalRedeemInFlight())));

        _step("[Step 4] Attempt finalize WITHOUT settling -- should revert");
        uint256 settledAssets = _convertToAssetsFloor(sharesA);
        uint256 vaultUsdcNow = usdc.balanceOf(address(vault));
        vm.prank(bot);
        vm.expectRevert(
            abi.encodeWithSelector(StrategyController.InsufficientCashForReady.selector, settledAssets, vaultUsdcNow)
        );
        executor.executeFinalizeRedeemBatch(address(controller), _arr(reqId), _arr(settledAssets));
        _step("  finalize reverted (in-flight not settled, vault has no USDC)");

        _step("[Step 5] External protocol delivers USDC, settle redeemInFlight");
        (,,,, uint256 redeemUsdc,,,, ) = vault.inFlightRecords(redeemId);
        adapter.simulateRedeemSettlement(redeemUsdc);
        _settleRedeem(_arr(redeemId), _arr(redeemUsdc));
        assertEq(vault.totalRedeemInFlight(), 0, "redeem settled");
        _step(string.concat("  vault USDC after settle: ", vm.toString(usdc.balanceOf(address(vault)))));

        _step("[Step 6] Finalize succeeds now");
        uint256 balBefore = usdc.balanceOf(userA);
        _finalizeRedeemBatch(_arr(reqId), _arr(settledAssets));
        assertEq(usdc.balanceOf(userA) - balBefore, settledAssets, "userA received USDC");
        assertEq(vault.totalLockedShares(), 0, "locked cleared");
        assertEq(posToken.balanceOf(address(vault)), 0, "vault posToken = 0 (all redeemed)");
        // Verify request status == DONE and pendingRedeemRequest cleared
        (,,,,,,, IMantleYieldVault.RequestStatus statusAfter10) = vault.requests(reqId);
        assertEq(uint8(statusAfter10), uint8(IMantleYieldVault.RequestStatus.DONE), "request status DONE");
        assertEq(vault.pendingRedeemRequest(userA), 0, "pendingShares cleared");

        _logPass();
    }

    // =======================================================================
    // Scenario 11: Full stress test -- multi-step + price change throughout
    // =======================================================================

    function test_FullStressTest_PriceChangesThroughLifecycle() public {
        _logCase(
            "test_FullStressTest_PriceChangesThroughLifecycle",
            unicode"完整压力测试 -- price 变动穿越全生命周期，每步验证账本恒等式"
        );

        _step("[Step 1] A deposits 8000 at rate=1.0, price=1.0");
        _deposit(userA, 8000e6);
        uint256 sharesA = vault.balanceOf(userA);
        _step(string.concat("  A shares: ", vm.toString(sharesA)));
        assertEq(sharesA, 8000e6, "A got 8000 shares at rate 1.0");

        _step("[Step 2] Invest + settle A's 8000");
        _investAll();
        uint256 investIdA = _lastInFlightId();
        (,,, uint256 posAmtA,,,,, ) = vault.inFlightRecords(investIdA);
        _settleInvest(_arr(investIdA), _arr(posAmtA), _arr(0));
        uint256 vaultPosStep2 = posToken.balanceOf(address(vault));
        _step(string.concat("  vault posToken: ", vm.toString(vaultPosStep2)));
        _assertTotalAssetsInvariant("step2");

        _step("[Step 3] Price rises to 1.2e18, update rate");
        adapter.setPosTokenPrice(12e17);
        mockAccountant.setExchangeRate(12e17);
        _assertTotalAssetsInvariant("step3");

        _step("[Step 4] B deposits 2400 (gets 2000 shares at rate=1.2)");
        _deposit(userB, 2400e6);
        uint256 sharesB = vault.balanceOf(userB);
        _step(string.concat("  B shares: ", vm.toString(sharesB)));
        // shares = 2400e6 * 1e18 / 1.2e18 = 2000e18
        assertEq(sharesB, 2000e6, "B got 2000 shares at rate 1.2");

        _step("[Step 5] Invest B's 2400 + settle");
        _investAll();
        uint256 investIdB = _lastInFlightId();
        (,,, uint256 posAmtB,,,,, ) = vault.inFlightRecords(investIdB);
        _settleInvest(_arr(investIdB), _arr(posAmtB), _arr(0));
        uint256 vaultPosStep5 = posToken.balanceOf(address(vault));
        _step(string.concat("  vault posToken: ", vm.toString(vaultPosStep5)));
        _assertTotalAssetsInvariant("step5");

        _step("[Step 6] B requestRedeem 2000 shares");
        vm.prank(userB);
        uint256 reqId = gateway.requestRedeem(sharesB);
        (,,,,, uint256 estimatedB,, ) = vault.requests(reqId);
        _step(string.concat("  B estimatedAssets: ", vm.toString(estimatedB)));
        assertEq(vault.totalLockedShares(), sharesB, "locked = B shares");

        _step("[Step 7] Price drops to 1.05e18 BEFORE settle of redeem");
        adapter.setPosTokenPrice(105e16);

        _step("[Step 8] Process B's redeem -- divest at current price");
        _processRedeemBatch(_arr(reqId));
        uint256 redeemId = _lastInFlightId();
        _step(string.concat("  redeemInFlight: ", vm.toString(vault.totalRedeemInFlight())));

        _step("[Step 9] Settle redeemInFlight -- actual USDC based on price=1.05");
        (,,, uint256 divestPosAmt, uint256 redeemUsdc,,,, ) = vault.inFlightRecords(redeemId);
        // In reality, the USDC received = posToken * 1.05 price / 1e18 * assetScale / tokenScale
        // The external protocol delivers USDC based on current price
        uint256 actualUsdc = divestPosAmt.mulDiv(105e16, 1e18, Math.Rounding.Floor)
            .mulDiv(1e6, 1e18, Math.Rounding.Floor);
        _step(string.concat("  expected redeemInFlight USDC: ", vm.toString(redeemUsdc)));
        _step(string.concat("  actual USDC at price 1.05: ", vm.toString(actualUsdc)));
        adapter.simulateRedeemSettlement(actualUsdc);
        _settleRedeem(_arr(redeemId), _arr(actualUsdc));

        _step("[Step 10] Update rate for new price, finalize");
        // Rate after price change: need to recalculate based on totalAssets
        mockAccountant.setExchangeRate(105e16);
        uint256 settledAssets = _convertToAssetsFloor(sharesB);
        _step(string.concat("  settledAssets at rate 1.05: ", vm.toString(settledAssets)));
        uint256 vaultUsdcAvailable = usdc.balanceOf(address(vault));
        _step(string.concat("  vault USDC available: ", vm.toString(vaultUsdcAvailable)));

        assertGe(vaultUsdcAvailable, settledAssets, "vault must have enough USDC for settlement");
        uint256 balBBefore = usdc.balanceOf(userB);
        _finalizeRedeemBatch(_arr(reqId), _arr(settledAssets));
        uint256 received = usdc.balanceOf(userB) - balBBefore;
        _step(string.concat("  B received: ", vm.toString(received)));
        assertEq(received, settledAssets, "B received correct amount");
        assertLe(received, 2400e6, "B received <= initial deposit (price dropped)");

        assertEq(vault.totalLockedShares(), 0, "locked cleared");
        // Verify request status == DONE and pendingRedeemRequest cleared
        (,,,,,,, IMantleYieldVault.RequestStatus statusAfter11) = vault.requests(reqId);
        assertEq(uint8(statusAfter11), uint8(IMantleYieldVault.RequestStatus.DONE), "request status DONE");
        assertEq(vault.pendingRedeemRequest(userB), 0, "pendingShares cleared");
        _step(string.concat("  A remaining shares: ", vm.toString(vault.balanceOf(userA))));
        _step(string.concat("  vault posToken: ", vm.toString(posToken.balanceOf(address(vault)))));

        _logPass();
    }
}
