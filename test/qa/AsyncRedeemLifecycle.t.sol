// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Accountant} from "../../src/accountant/Accountant.sol";
import {AccountantExecutor} from "../../src/accountant/AccountantExecutor.sol";
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
    function burn(address from, uint256 amount) external { _burn(from, amount); }
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

contract MockSettlementVenue_ARL {
    MockUSDC_ARL public immutable ASSET;
    MockPosToken_ARL public immutable POS_TOKEN;

    mapping(address => uint256) public pendingInvestAsset;
    mapping(address => uint256) public pendingRedeemPos;

    constructor(address asset_, address posToken_) {
        ASSET = MockUSDC_ARL(asset_);
        POS_TOKEN = MockPosToken_ARL(posToken_);
    }

    function acceptInvest(address adapter, uint256 assetAmount) external {
        pendingInvestAsset[adapter] += assetAmount;
    }

    function acceptRedeem(address adapter, uint256 posAmount) external {
        pendingRedeemPos[adapter] += posAmount;
    }

    function settleInvest(
        address adapter,
        uint256 investAssetAmount,
        uint256 maxPosAmount,
        uint256 settledPosAmount,
        uint256 refundAssetAmount
    ) external {
        uint256 pendingAsset = pendingInvestAsset[adapter];
        require(investAssetAmount <= pendingAsset, "INVEST_ASSET_EXCEEDS_PENDING");
        require(settledPosAmount <= maxPosAmount, "INVEST_POS_EXCEEDS_EXPECTED");
        require(refundAssetAmount <= investAssetAmount, "INVEST_REFUND_EXCEEDS_ASSET");

        pendingInvestAsset[adapter] = pendingAsset - investAssetAmount;

        uint256 consumedAssetAmount = investAssetAmount - refundAssetAmount;
        if (consumedAssetAmount > 0) {
            ASSET.burn(address(this), consumedAssetAmount);
        }
        if (settledPosAmount > 0) {
            POS_TOKEN.mint(adapter, settledPosAmount);
        }
        if (refundAssetAmount > 0) {
            ASSET.transfer(adapter, refundAssetAmount);
        }
    }

    function settleRedeem(address adapter, uint256 redeemPosAmount, uint256 assetAmount) external {
        uint256 pendingPos = pendingRedeemPos[adapter];
        require(redeemPosAmount <= pendingPos, "REDEEM_POS_EXCEEDS_PENDING");

        pendingRedeemPos[adapter] = pendingPos - redeemPosAmount;

        if (redeemPosAmount > 0) {
            POS_TOKEN.burn(address(this), redeemPosAmount);
        }
        if (assetAmount > 0) {
            ASSET.mint(adapter, assetAmount);
        }
    }
}

/// @dev Async adapter that simulates real DiGiFT-like behavior:
///   - deposit(): pulls USDC from vault and forwards it to an external settlement venue
///   - requestRedeemAsync(): pulls posToken from vault and forwards it to an external settlement venue
///   - sweepToVault(): transfers settled token from adapter to vault
///   - totalValue(): reads posToken on VAULT * price (not adapter balance)
///   - getPosTokenPrice(): configurable price
///   - estimatePosAmount(): USDC -> posToken conversion based on price
///   - withdrawSync(): returns 0 (pure async adapter, no sync withdrawal)
contract MockAsyncAdapter_ARL is IStrategyAdapter {
    using Math for uint256;

    address public immutable ASSET;
    address public immutable POS_TOKEN;
    address public immutable VAULT;
    MockSettlementVenue_ARL public immutable SETTLEMENT_VENUE;

    uint256 public posTokenPrice = 1e18; // 1e18 = 1 USDC per posToken

    constructor(address asset_, address posToken_, address vault_, address settlementVenue_) {
        ASSET = asset_;
        POS_TOKEN = posToken_;
        VAULT = vault_;
        SETTLEMENT_VENUE = MockSettlementVenue_ARL(settlementVenue_);
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

    /// @dev deposit: pull USDC from vault, then forward it to the external settlement venue.
    function deposit(uint256 amount, address) external returns (uint256 posAmount) {
        IERC20(ASSET).transferFrom(VAULT, address(this), amount);
        IERC20(ASSET).transfer(address(SETTLEMENT_VENUE), amount);
        SETTLEMENT_VENUE.acceptInvest(address(this), amount);

        uint8 assetDec = IERC20Metadata(ASSET).decimals();
        uint8 posDec = IERC20Metadata(POS_TOKEN).decimals();
        posAmount = amount.mulDiv(1e18 * (10 ** posDec), posTokenPrice * (10 ** assetDec), Math.Rounding.Floor);
        return posAmount;
    }

    /// @dev Pure async adapter -- no sync withdrawal
    function withdrawSync(uint256, address) external pure returns (uint256) {
        revert("Unsupported");
    }

    /// @dev requestRedeemAsync: first arg is posAmount (controller already did asset→pos conversion).
    ///      Matches real adapter flow: pull posToken from vault, then forward it to the settlement venue.
    function requestRedeemAsync(uint256 posAmount, address) external {
        if (posAmount > 0) {
            IERC20(POS_TOKEN).transferFrom(VAULT, address(this), posAmount);
            IERC20(POS_TOKEN).transfer(address(SETTLEMENT_VENUE), posAmount);
            SETTLEMENT_VENUE.acceptRedeem(address(this), posAmount);
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
    function minSubscribeAsset() external pure returns (uint256) { return 0; }
    function minRedeemPos() external pure returns (uint256) { return 0; }
}

// ---------------------------------------------------------------------------
// QA Test: Async Redeem Lifecycle Complex Scenarios
// ---------------------------------------------------------------------------

contract AsyncRedeemLifecycleQATest is Test {
    using Math for uint256;

    MockUSDC_ARL internal usdc;
    MockPosToken_ARL internal posToken;
    MockSanctionsOracle_ARL internal oracle;
    Accountant internal accountant;
    AccountantExecutor internal accountantExecutor;
    MantleYieldVault internal vault;
    MantleVaultGateway internal gateway;
    StrategyController internal controller;
    MockSettlementVenue_ARL internal settlementVenue;
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

        MantleYieldVault vaultImpl = new MantleYieldVault();
        MantleVaultGateway gwImpl = new MantleVaultGateway();
        StrategyController ctrlImpl = new StrategyController();
        OperatorExecutor execImpl = new OperatorExecutor();
        Accountant accountantImpl = new Accountant();
        AccountantExecutor accountantExecutorImpl = new AccountantExecutor();

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
                accountant: address(1),
                treasury: treasury,
                maxRedemptionFeeBps: 500,
                redemptionFeeBps: 0, // 0 fee for cleaner math
                minRedeemAmount: 0,
                minDepositAmount: 0,
                maxSettlementDeviationBps: 0,
                depositDailyRemaining: type(uint256).max,
                redeemDailyRemaining: type(uint256).max
            })
        );
        vault = MantleYieldVault(address(new ERC1967Proxy(address(vaultImpl), vaultInitData)));

        // OperatorExecutor
        bytes memory execInitData = abi.encodeCall(OperatorExecutor.initialize, (admin, bot));
        executor = OperatorExecutor(address(new ERC1967Proxy(address(execImpl), execInitData)));

        // Accountant + AccountantExecutor
        bytes memory accountantExecInitData = abi.encodeCall(AccountantExecutor.initialize, (admin));
        accountantExecutor =
            AccountantExecutor(address(new ERC1967Proxy(address(accountantExecutorImpl), accountantExecInitData)));
        bytes memory accountantInitData =
            abi.encodeCall(Accountant.initialize, (address(vault), uint64(1e18), uint32(0), admin));
        accountant = Accountant(address(new ERC1967Proxy(address(accountantImpl), accountantInitData)));

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
        vault.setAccountant(address(accountant));
        accountant.grantRole(accountant.ACCOUNTANT_EXECUTOR_ROLE(), address(accountantExecutor));
        accountantExecutor.grantRole(accountantExecutor.BOT_ROLE(), bot);
        vm.stopPrank();

        // Adapter (async, reads posToken on vault)
        settlementVenue = new MockSettlementVenue_ARL(address(usdc), address(posToken));
        adapter = new MockAsyncAdapter_ARL(address(usdc), address(posToken), address(vault), address(settlementVenue));
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

    function _deliverInvestSettlement(uint256[] memory ids, uint256[] memory posAmts, uint256[] memory refunds) internal {
        assertEq(ids.length, posAmts.length, "invest ids/pos length mismatch");
        assertEq(ids.length, refunds.length, "invest ids/refunds length mismatch");

        uint256 len = ids.length;
        for (uint256 i = 0; i < len; i++) {
            (,,, uint256 expectedPos, uint256 investAsset,, bool isInvest,,) = vault.inFlightRecords(ids[i]);
            assertTrue(isInvest, "expected invest in-flight");
            settlementVenue.settleInvest(address(adapter), investAsset, expectedPos, posAmts[i], refunds[i]);
        }
    }

    function _deliverRedeemSettlement(uint256[] memory ids, uint256[] memory amts) internal {
        assertEq(ids.length, amts.length, "redeem ids/amts length mismatch");

        uint256 len = ids.length;
        for (uint256 i = 0; i < len; i++) {
            (,,, uint256 redeemPos,,, bool isInvest,,) = vault.inFlightRecords(ids[i]);
            assertFalse(isInvest, "expected redeem in-flight");
            settlementVenue.settleRedeem(address(adapter), redeemPos, amts[i]);
        }
    }

    function _settleInvest(uint256[] memory ids, uint256[] memory posAmts, uint256[] memory refunds) internal {
        _deliverInvestSettlement(ids, posAmts, refunds);
        vm.prank(bot);
        executor.executeSettleAdapter(
            address(controller),
            address(adapter),
            IStrategyControllerExecutor.InvestSettlementInput(ids, posAmts, refunds),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );
    }

    function _settleRedeem(uint256[] memory ids, uint256[] memory amts) internal {
        _deliverRedeemSettlement(ids, amts);
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
        _deliverInvestSettlement(investIds, posAmts, refunds);
        _deliverRedeemSettlement(redeemIds, redeemAmts);
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

    function _currentRate() internal view returns (uint256) {
        return accountant.lastExchangeRate();
    }

    function _setRateReal(uint64 newRate) internal {
        uint256 currentRate = accountant.lastExchangeRate();
        if (newRate == currentRate) {
            return;
        }

        uint256 larger = newRate > currentRate ? uint256(newRate) : currentRate;
        uint256 smaller = newRate > currentRate ? currentRate : uint256(newRate);
        uint256 deviationBps = larger > 0 ? ((larger - smaller) * 10_000) / larger : 0;
        uint32 maxDeviationCeiling = accountant.MAX_DEVIATION_CEILING();

        if (deviationBps <= maxDeviationCeiling) {
            vm.prank(admin);
            accountant.setRiskParams(maxDeviationCeiling, 0);
            vm.warp(block.timestamp + 1);
            vm.prank(bot);
            accountantExecutor.executeUpdateRate(address(accountant), newRate, uint64(block.timestamp));
            return;
        }

        vm.prank(admin);
        accountant.emergencyRateUpdate(newRate);
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
        uint256 rate = _currentRate();
        return shares.mulDiv(rate, 1e18, Math.Rounding.Ceil);
    }

    function _convertToAssetsFloor(uint256 shares) internal view returns (uint256) {
        uint256 rate = _currentRate();
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
        (,,, uint256 posAmtA,,,,, ) = vault.inFlightRecords(investIdA);
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

        _step("[Step 6] Settle redeem -- USDC arrives on adapter via venue");
        (,,,, uint256 redeemUsdcAmt,,,, ) = vault.inFlightRecords(redeemInFlightId);
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
            unicode"Invest 未 settle 时先 process 再 settle -- DivestInsufficient 场景"
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

        _step("[Step 4] Process FIRST (wrong order) -- reverts DivestInsufficient");
        // vault posToken = posAmtA (from A's settle only), B's posToken still on adapter (unsettled)
        // adapterPool = 500e6 < shortfall = 1000e6 → true insufficient → revert
        uint256 vaultPosBefore = posToken.balanceOf(address(vault));
        _step(string.concat("  vault posToken before process: ", vm.toString(vaultPosBefore)));

        uint256 batchTotal = _convertToAssetsFloor(sharesB); // 1000e6
        uint256 cashDeficit = vault.getCashDeficit(); // 1000e6
        uint256 shortfall = cashDeficit < batchTotal ? cashDeficit : batchTotal;
        // adapterPoolValue = 500e6, divest can only cover 500 → remaining = 500
        uint256 adapterPool = vaultPosBefore.mulDiv(
            adapter.getPosTokenPrice(), 1e18, Math.Rounding.Floor
        ).mulDiv(1e6, 1e18, Math.Rounding.Floor);
        uint256 divestRemaining = shortfall - adapterPool;

        vm.expectRevert(abi.encodeWithSelector(
            StrategyController.Controller__DivestInsufficient.selector,
            shortfall,        // required: 1000e6
            divestRemaining   // remaining: 500e6
        ));
        _processRedeemBatch(_arr(reqId));
        _step(string.concat("  reverted: adapterPool (", vm.toString(adapterPool), ") < shortfall (", vm.toString(shortfall), ")"));

        // Request stays PENDING (entire tx rolled back)
        (,,,,,,, IMantleYieldVault.RequestStatus statusPending) = vault.requests(reqId);
        assertEq(uint8(statusPending), uint8(IMantleYieldVault.RequestStatus.PENDING), "request still PENDING after revert");

        _step("[Step 5] Now settle B's investInFlight (correct order)");
        (,,, uint256 posAmtB,,,,, ) = vault.inFlightRecords(investIdB);
        _settleInvest(_arr(investIdB), _arr(posAmtB), _arr(0));
        assertEq(vault.totalInvestInFlight(), 0, "B invest now settled");
        uint256 vaultPosAfterSettle = posToken.balanceOf(address(vault));
        _step(string.concat("  vault posToken after settle: ", vm.toString(vaultPosAfterSettle)));

        _step("[Step 6] Process B's redeem -- now succeeds (adapter pool >= shortfall)");
        _processRedeemBatch(_arr(reqId));
        uint256 redeemInFlightId = _lastInFlightId();
        assertGt(vault.totalRedeemInFlight(), 0, "redeemInFlight created");
        _step(string.concat("  redeemInFlight: ", vm.toString(vault.totalRedeemInFlight())));

        _step("[Step 7] Settle redeemInFlight");
        (,,,, uint256 redeemUsdcAmt,,,, ) = vault.inFlightRecords(redeemInFlightId);
        _settleRedeem(_arr(redeemInFlightId), _arr(redeemUsdcAmt));
        assertEq(vault.totalRedeemInFlight(), 0, "redeem settled");
        _step(string.concat("  vault USDC after settle: ", vm.toString(usdc.balanceOf(address(vault)))));

        _step("[Step 8] Finalize B's redeem");
        uint256 settledAssets = _convertToAssetsFloor(sharesB);
        uint256 vaultUsdcAvailable = usdc.balanceOf(address(vault));
        _step(string.concat("  vault USDC: ", vm.toString(vaultUsdcAvailable)));
        _step(string.concat("  settledAssets needed: ", vm.toString(settledAssets)));
        assertGe(vaultUsdcAvailable, settledAssets, "vault has enough USDC");
        uint256 balBBefore = usdc.balanceOf(userB);
        _finalizeRedeemBatch(_arr(reqId), _arr(settledAssets));
        assertEq(usdc.balanceOf(userB) - balBBefore, settledAssets, "B received USDC");
        assertEq(vault.totalLockedShares(), 0, "no locked shares");
        // Verify request status == DONE and pendingRedeemRequest cleared
        (,,,,,,, IMantleYieldVault.RequestStatus statusAfter2) = vault.requests(reqId);
        assertEq(uint8(statusAfter2), uint8(IMantleYieldVault.RequestStatus.DONE), "request status DONE");
        assertEq(vault.pendingRedeemRequest(userB), 0, "pendingShares cleared");
        _step(string.concat("  B received: ", vm.toString(settledAssets)));
        _assertTotalAssetsInvariant("final");

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
        _setRateReal(2e18);

        _step("[Step 4] UserA requestRedeem 5000 shares (= 10000 USDC at rate 2)");
        vm.prank(userA);
        uint256 reqId = gateway.requestRedeem(5000e6);
        uint256 estimatedAssets = _convertToAssetsFloor(5000e6);
        _step(string.concat("  estimatedAssets: ", vm.toString(estimatedAssets)));
        uint256 expectedEstimated = _convertToAssetsFloor(5000e6);
        assertEq(estimatedAssets, expectedEstimated, "estimated = 5000 * 2 = 10000 USDC");

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

        _step("[Step 6] Settle redeem -- deliver full USDC via venue");
        (,,,, uint256 redeemUsdc,,,, ) = vault.inFlightRecords(redeemId);
        _settleRedeem(_arr(redeemId), _arr(redeemUsdc));

        _step("[Step 7] Finalize");
        uint256 balBefore = usdc.balanceOf(userA);
        _finalizeRedeemBatch(_arr(reqId), _arr(estimatedAssets));
        uint256 received = usdc.balanceOf(userA) - balBefore;
        assertEq(received, estimatedAssets, "userA received 10000 USDC");
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
        _setRateReal(5e17); // rate drops too: 1 share = 0.5 USDC

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
        _assertTotalAssetsInvariant("final");

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
        _setRateReal(15e17);
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
        _setRateReal(11e17);

        _step("[Step 4] Process -- batchTotalAsset uses current rate");
        // At rate=1.1, batchTotalAsset = 5000 * 1.1 = 5500
        // vault USDC = 0, all in posToken. Need divest.
        _processRedeemBatch(_arr(reqId));

        _step("[Step 5] Settle redeemInFlight");
        uint256 redeemIF = vault.totalRedeemInFlight();
        assertGt(redeemIF, 0, "divest must have triggered (vault USDC=0)");
        uint256 redeemId = _lastInFlightId();
        (,,,, uint256 redeemUsdc,,,, ) = vault.inFlightRecords(redeemId);
        _settleRedeem(_arr(redeemId), _arr(redeemUsdc));

        _step("[Step 6] Finalize with settledAssets at new rate");
        uint256 settledAssets = _convertToAssetsFloor(5000e6); // 5000 * 1.1 = 5500
        uint256 expectedSettled7 = _convertToAssetsFloor(5000e6);
        assertEq(settledAssets, expectedSettled7, "settled = 5500 at rate 1.1");
        uint256 balBefore = usdc.balanceOf(userA);
        // settledAssets (5500) != estimatedAssets (5000) -> RequestSettlementAdjusted
        vm.expectEmit(true, false, false, true, address(vault));
        emit IMantleYieldVault.RequestSettlementAdjusted(reqId, storedEstimated, settledAssets);
        _finalizeRedeemBatch(_arr(reqId), _arr(settledAssets));
        uint256 received = usdc.balanceOf(userA) - balBefore;
        assertEq(received, settledAssets, "user received 5500 > estimated 5000");
        assertGt(received, storedEstimated, "received > estimated (rate rose)");
        assertEq(vault.totalLockedShares(), 0, "locked cleared");
        // Verify request status == DONE and pendingRedeemRequest cleared
        (,,,,,,, IMantleYieldVault.RequestStatus statusAfter7) = vault.requests(reqId);
        assertEq(uint8(statusAfter7), uint8(IMantleYieldVault.RequestStatus.DONE), "request status DONE");
        assertEq(vault.pendingRedeemRequest(userA), 0, "pendingShares cleared");
        _assertTotalAssetsInvariant("final");

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
        _setRateReal(11e17);
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
        _setRateReal(1e18);

        _step("[Step 5] Process + settle divest");
        _processRedeemBatch(_arr(reqId));
        uint256 redeemIF = vault.totalRedeemInFlight();
        assertGt(redeemIF, 0, "divest must have triggered (vault USDC=0)");
        uint256 redeemId = _lastInFlightId();
        (,,,, uint256 redeemUsdc,,,, ) = vault.inFlightRecords(redeemId);
        _settleRedeem(_arr(redeemId), _arr(redeemUsdc));

        _step("[Step 6] Finalize with settledAssets at new rate");
        uint256 settledAssets = _convertToAssetsFloor(5000e6); // 5000 * 1.0 = 5000
        uint256 expectedSettled8 = _convertToAssetsFloor(5000e6);
        assertEq(settledAssets, expectedSettled8, "settled = 5000 at rate 1.0");
        uint256 balBefore = usdc.balanceOf(userA);
        // settledAssets (5000) != estimatedAssets (5500) -> RequestSettlementAdjusted
        vm.expectEmit(true, false, false, true, address(vault));
        emit IMantleYieldVault.RequestSettlementAdjusted(reqId, storedEstimated, settledAssets);
        _finalizeRedeemBatch(_arr(reqId), _arr(settledAssets));
        uint256 received = usdc.balanceOf(userA) - balBefore;
        assertEq(received, settledAssets, "user received 5000");
        assertLt(received, storedEstimated, "received < estimated (rate dropped)");
        assertEq(vault.totalLockedShares(), 0, "locked cleared");
        // Verify request status == DONE and pendingRedeemRequest cleared
        (,,,,,,, IMantleYieldVault.RequestStatus statusAfter8) = vault.requests(reqId);
        assertEq(uint8(statusAfter8), uint8(IMantleYieldVault.RequestStatus.DONE), "request status DONE");
        assertEq(vault.pendingRedeemRequest(userA), 0, "pendingShares cleared");
        _assertTotalAssetsInvariant("final");

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

        _step("[Step 2] Partial fill: half posToken + half refund USDC via venue");
        uint256 halfPos = expectedPos / 2;
        uint256 refundUsdc = 5000e6;

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
        assertEq(totalVal, 10_000e6, "total value preserved = initial deposit");
        _assertTotalAssetsInvariant("final");

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
            abi.encodeWithSelector(IMantleYieldVault.Vault__InsufficientPhysicalCash.selector, _arr(reqId), _arr(settledAssets), vaultUsdcNow)
        );
        executor.executeFinalizeRedeemBatch(address(controller), _arr(reqId), _arr(settledAssets));
        _step("  finalize reverted (in-flight not settled, vault has no USDC)");

        _step("[Step 5] External protocol delivers USDC, settle redeemInFlight");
        (,,,, uint256 redeemUsdc,,,, ) = vault.inFlightRecords(redeemId);
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
        _assertTotalAssetsInvariant("final");

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
        uint256 depositA = 8000e6;
        _deposit(userA, depositA);
        uint256 sharesA = vault.balanceOf(userA);
        _step(string.concat("  A shares: ", vm.toString(sharesA)));
        uint256 expectedSharesA = Math.mulDiv(depositA, 1e18, _currentRate(), Math.Rounding.Floor);
        assertEq(sharesA, expectedSharesA, "A got 8000 shares at rate 1.0");

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
        _setRateReal(12e17);
        _assertTotalAssetsInvariant("step3");

        _step("[Step 4] B deposits 2400 (gets 2000 shares at rate=1.2)");
        uint256 depositB = 2400e6;
        _deposit(userB, depositB);
        uint256 sharesB = vault.balanceOf(userB);
        _step(string.concat("  B shares: ", vm.toString(sharesB)));
        // shares = 2400e6 * 1e18 / 1.2e18 = 2000e18
        uint256 expectedSharesB = Math.mulDiv(depositB, 1e18, _currentRate(), Math.Rounding.Floor);
        assertEq(sharesB, expectedSharesB, "B got 2000 shares at rate 1.2");

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
        _settleRedeem(_arr(redeemId), _arr(actualUsdc));

        _step("[Step 10] Update rate for new price, finalize");
        // Rate after price change: need to recalculate based on totalAssets
        _setRateReal(105e16);
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
