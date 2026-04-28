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

contract MockUSDC_REC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockSanctionsOracle_REC is ISanctionsOracle {
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

contract MockPosToken_REC is ERC20 {
    constructor() ERC20("MockPosToken", "mPOS") {}
    function decimals() public pure override returns (uint8) { return 18; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function burn(address from, uint256 amount) external { _burn(from, amount); }
}

contract MockAccountant_REC {
    uint256 public rate = 1e18;
    function getRate() external view returns (uint256) { return rate; }
    function getRateSafe() external view returns (uint256) { return rate; }
    function setExchangeRate(uint256 newRate) external { rate = newRate; }
}

contract MockAsyncAdapter_REC is IStrategyAdapter {
    using Math for uint256;

    address public immutable ASSET;
    address public immutable POS_TOKEN;
    address public immutable VAULT;
    uint256 public posTokenPrice = 1e18;

    constructor(address asset_, address posToken_, address vault_) {
        ASSET = asset_;
        POS_TOKEN = posToken_;
        VAULT = vault_;
    }

    function setPosTokenPrice(uint256 p) external { posTokenPrice = p; }
    function name() external pure returns (string memory) { return "MockAsyncAdapter_REC"; }
    function asset() external view returns (address) { return ASSET; }
    function posToken() external view returns (address) { return POS_TOKEN; }
    function priceOracle() external pure returns (address) { return address(0); }
    function getPosTokenPrice() external view returns (uint256) { return posTokenPrice; }
    function vault() external view returns (address) { return VAULT; }

    function totalValue() external view returns (uint256) {
        uint256 vaultPos = IERC20(POS_TOKEN).balanceOf(VAULT);
        uint8 aDec = IERC20Metadata(ASSET).decimals();
        uint8 pDec = IERC20Metadata(POS_TOKEN).decimals();
        return vaultPos.mulDiv(posTokenPrice, 1e18, Math.Rounding.Floor)
            .mulDiv(10 ** aDec, 10 ** pDec, Math.Rounding.Floor);
    }

    function estimatePosAmount(uint256 assetAmount) external view returns (uint256) {
        uint8 aDec = IERC20Metadata(ASSET).decimals();
        uint8 pDec = IERC20Metadata(POS_TOKEN).decimals();
        return assetAmount.mulDiv(1e18 * (10 ** pDec), posTokenPrice * (10 ** aDec), Math.Rounding.Floor);
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

    function deposit(uint256 amount, address) external returns (uint256 posAmount) {
        IERC20(ASSET).transferFrom(VAULT, address(this), amount);
        uint8 aDec = IERC20Metadata(ASSET).decimals();
        uint8 pDec = IERC20Metadata(POS_TOKEN).decimals();
        posAmount = amount.mulDiv(1e18 * (10 ** pDec), posTokenPrice * (10 ** aDec), Math.Rounding.Floor);
        MockPosToken_REC(POS_TOKEN).mint(address(this), posAmount);
    }

    function withdrawSync(uint256, address) external pure returns (uint256) { revert("Unsupported"); }

    /// @dev Controller passes posAmount (position units) directly; no decimal/price re-conversion needed.
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

    function simulateRedeemSettlement(uint256 usdcAmount) external {
        MockUSDC_REC(ASSET).mint(address(this), usdcAmount);
    }
}

// ---------------------------------------------------------------------------
// QA Test: Redeem Edge Cases & Idempotency
// ---------------------------------------------------------------------------

contract RedeemEdgeCasesQATest is Test {
    using Math for uint256;

    MockUSDC_REC internal usdc;
    MockPosToken_REC internal posToken;
    MockSanctionsOracle_REC internal oracle;
    MockAccountant_REC internal mockAccountant;
    MantleYieldVault internal vault;
    MantleVaultGateway internal gateway;
    StrategyController internal controller;
    MockAsyncAdapter_REC internal adapter;
    OperatorExecutor internal executor;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal sanctionSafe = makeAddr("sanctionSafe");
    address internal bot = makeAddr("bot");
    address internal userA = makeAddr("userA");
    address internal userB = makeAddr("userB");

    // -----------------------------------------------------------------------
    // Logging
    // -----------------------------------------------------------------------

    string constant MODULE = unicode"赎回边界与幂等场景";

    function _logCase(string memory id, string memory name_) internal view {
        console2.log(string.concat("testcase module: ", MODULE));
        console2.log(string.concat("testcase id: ", id));
        console2.log(string.concat("testcase name: ", name_));
        console2.log("----------------------------------------");
    }

    function _logPass() internal pure {
        console2.log("----------------------------------------");
        console2.log("test result: passed");
    }

    // -----------------------------------------------------------------------
    // setUp
    // -----------------------------------------------------------------------

    function setUp() public {
        vm.warp(1000);

        usdc = new MockUSDC_REC();
        posToken = new MockPosToken_REC();
        oracle = new MockSanctionsOracle_REC();
        mockAccountant = new MockAccountant_REC();

        MantleYieldVault vaultImpl = new MantleYieldVault();
        MantleVaultGateway gwImpl = new MantleVaultGateway();
        StrategyController ctrlImpl = new StrategyController();
        OperatorExecutor execImpl = new OperatorExecutor();

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
                redemptionFeeBps: 0,
                minRedeemAmount: 0,
                minDepositAmount: 0
            })
        );
        vault = MantleYieldVault(address(new ERC1967Proxy(address(vaultImpl), vaultInitData)));

        bytes memory execInitData = abi.encodeCall(OperatorExecutor.initialize, (admin, bot));
        executor = OperatorExecutor(address(new ERC1967Proxy(address(execImpl), execInitData)));

        bytes memory ctrlInitData = abi.encodeCall(
            StrategyController.initialize,
            (address(vault), admin, address(executor), admin, 0, 0, 0)
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
        vault.setGateway(address(gateway));
        vault.setController(address(controller));
        vm.stopPrank();

        adapter = new MockAsyncAdapter_REC(address(usdc), address(posToken), address(vault));
        vm.startPrank(admin);
        controller.registerStrategy(address(adapter), 10_000, 1, true);
        controller.activateStrategy(address(adapter));
        address[] memory ordered = new address[](1);
        ordered[0] = address(adapter);
        controller.setStrategyOrder(ordered);
        vm.stopPrank();

        address[2] memory users = [userA, userB];
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
        vm.prank(admin);
        controller.setRiskParams(0, 0, 0);
        vm.prank(bot);
        executor.executeRebalance(address(controller));
    }

    function _lastInFlightId() internal view returns (uint256) {
        return vault.nextInFlightId() - 1;
    }

    function _settleInvest(uint256[] memory ids, uint256[] memory posAmts, uint256[] memory refunds) internal {
        vm.prank(bot);
        executor.executeSettleAdapter(
            address(controller), address(adapter),
            IStrategyControllerExecutor.InvestSettlementInput(ids, posAmts, refunds),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );
    }

    function _settleRedeem(uint256[] memory ids, uint256[] memory amts) internal {
        vm.prank(bot);
        executor.executeSettleAdapter(
            address(controller), address(adapter),
            IStrategyControllerExecutor.InvestSettlementInput(new uint256[](0), new uint256[](0), new uint256[](0)),
            IStrategyControllerExecutor.RedeemSettlementInput(ids, amts)
        );
    }

    function _convertToAssetsFloor(uint256 shares) internal view returns (uint256) {
        return shares.mulDiv(mockAccountant.rate(), 1e18, Math.Rounding.Floor);
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

    // =======================================================================
    // 1. Duplicate process same batch -- Vault__InvalidState(PROCESSING) (M-1)
    // =======================================================================

    function test_DuplicateProcess_BatchAlreadyProcessed() public {
        _logCase("test_DuplicateProcess_BatchAlreadyProcessed",
            unicode"同一 batch 重复 process -- 幂等保护 (M-1: BatchAlreadyProcessed -> Vault__InvalidState)");

        _deposit(userA, 5000e6);
        vm.prank(userA);
        uint256 reqId = gateway.requestRedeem(1000e6);

        // First process succeeds
        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), _arr(reqId));

        // Verify request is PROCESSING after first process (M-3: state lives on Vault)
        (,,,,,,, IMantleYieldVault.RequestStatus statusAfterProcess) = vault.requests(reqId);
        assertEq(uint8(statusAfterProcess), uint8(IMantleYieldVault.RequestStatus.PROCESSING), "request PROCESSING after first process");

        // Second process same ids reverts with Vault__InvalidState(id, PROCESSING)
        // because updateRequestBatch requires strictly monotonic transition and PROCESSING <= current=PROCESSING fails.
        vm.prank(bot);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMantleYieldVault.Vault__InvalidState.selector,
                reqId,
                IMantleYieldVault.RequestStatus.PROCESSING
            )
        );
        executor.executeProcessRedeemBatch(address(controller), _arr(reqId));

        _logPass();
    }

    // =======================================================================
    // 2. IDs not sorted -- IdsNotSorted
    // =======================================================================

    function test_IdsNotSorted_Reverts() public {
        _logCase("test_IdsNotSorted_Reverts",
            unicode"processRedeemBatch ids 非严格升序时拒绝");

        _deposit(userA, 5000e6);

        vm.prank(userA);
        uint256 req1 = gateway.requestRedeem(500e6);
        vm.prank(userA);
        uint256 req2 = gateway.requestRedeem(500e6);
        vm.prank(userA);
        uint256 req3 = gateway.requestRedeem(500e6);

        // Pass in reverse order: [3, 1, 2]
        uint256[] memory unsorted = _arr3(req3, req1, req2);

        vm.prank(bot);
        vm.expectRevert(StrategyController.IdsNotSorted.selector);
        executor.executeProcessRedeemBatch(address(controller), unsorted);

        _logPass();
    }

    // =======================================================================
    // 3. Finalize when vault USDC insufficient -- InsufficientCashForReady
    // =======================================================================

    function test_FinalizeInsufficientCash_AfterNewInvest() public {
        _logCase("test_FinalizeInsufficientCash_AfterNewInvest",
            unicode"finalize 时 vault USDC 不足 -- 安全检查");

        // Deposit and keep as cash
        _deposit(userA, 5000e6);
        _deposit(userB, 5000e6);

        // A redeems 1000 shares at rate=1.0
        vm.prank(userA);
        uint256 reqId = gateway.requestRedeem(1000e6);

        // Process (Path B -- freeCash covers it)
        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), _arr(reqId));

        // Invest remaining freeCash (rebalance preserves locked=1000 in vault)
        _investAll();
        // vault USDC = lockedValue = 1000e6 (freeCash protected locked shares)

        // Rate rises: locked 1000 shares now worth 2000 USDC, but vault only has 1000 USDC
        mockAccountant.setExchangeRate(2e18);

        // settledAssets at new rate = 1000 shares * 2.0 = 2000 USDC
        uint256 settled = _convertToAssetsFloor(1000e6);
        assertEq(settled, 2000e6, "settled = 2000 at rate 2.0");

        uint256 available = usdc.balanceOf(address(vault));
        assertLt(available, settled, "vault USDC < settled needed");

        // Attempt finalize -- vault has insufficient USDC
        vm.prank(bot);
        vm.expectRevert(
            abi.encodeWithSelector(StrategyController.InsufficientCashForReady.selector, settled, available)
        );
        executor.executeFinalizeRedeemBatch(address(controller), _arr(reqId), _arr(settled));

        // Verify requests still PROCESSING (atomic rollback)
        (, , , , , , , IMantleYieldVault.RequestStatus statusStillProc) = vault.requests(reqId);
        assertEq(uint8(statusStillProc), uint8(IMantleYieldVault.RequestStatus.PROCESSING), "still PROCESSING after revert");

        // Divest enough to cover the shortfall -- sweep adapter funds back
        adapter.simulateRedeemSettlement(settled - available);
        adapter.sweepToVault(address(usdc), settled - available);
        assertGe(usdc.balanceOf(address(vault)), settled, "vault has enough after sweep");

        // Successful finalize
        uint256 balABefore = usdc.balanceOf(userA);
        vm.prank(bot);
        executor.executeFinalizeRedeemBatch(address(controller), _arr(reqId), _arr(settled));
        assertEq(usdc.balanceOf(userA) - balABefore, settled, "A received settled USDC");

        // Verify DONE + pendingShares cleared
        (, , , , , , , IMantleYieldVault.RequestStatus statusFinal) = vault.requests(reqId);
        assertEq(uint8(statusFinal), uint8(IMantleYieldVault.RequestStatus.DONE), "request status DONE after finalize");
        assertEq(vault.pendingRedeemRequest(userA), 0, "A pendingShares cleared");

        _logPass();
    }

    // =======================================================================
    // 4. Invest + settle ordering issue -- DivestInsufficient revert (M-12)
    // =======================================================================

    function test_InvestNotSettled_ProcessFirst_NeedsExtraRebalance() public {
        _logCase("test_InvestNotSettled_ProcessFirst_NeedsExtraRebalance",
            unicode"investInFlight 未 settle + 先 process (M-12: DivestInsufficient revert; request stays PENDING)");

        // A deposits 500, invest + settle (posToken=500 on vault)
        _deposit(userA, 500e6);
        _investAll();
        uint256 investIdA = _lastInFlightId();
        (,,, uint256 posAmtA,,,,, ) = vault.inFlightRecords(investIdA);
        _settleInvest(_arr(investIdA), _arr(posAmtA), _arr(0));

        // B deposits 1000, invest but NOT settle (investInFlight = 1000)
        _deposit(userB, 1000e6);
        _investAll();
        uint256 investIdB = _lastInFlightId();
        assertEq(vault.totalInvestInFlight(), 1000e6, "B invest in flight");

        // B requestRedeem 1000 shares
        uint256 sharesB = vault.balanceOf(userB);
        vm.prank(userB);
        uint256 reqId = gateway.requestRedeem(sharesB);

        // M-12/M-15: Process FIRST (wrong order) -- adapterPool=500 (A's posToken) < shortfall=1000
        //            → StrategyController.processRedeemBatch reverts with DivestInsufficient.
        //            Request remains PENDING; no in-flight created on this failed path.
        vm.prank(bot);
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyController.DivestInsufficient.selector,
                1000e6,
                500e6
            )
        );
        executor.executeProcessRedeemBatch(address(controller), _arr(reqId));

        // Verify request stayed PENDING and no redeem in-flight was created.
        (,,,,,,, IMantleYieldVault.RequestStatus sAfterRevert) = vault.requests(reqId);
        assertEq(uint8(sAfterRevert), uint8(IMantleYieldVault.RequestStatus.PENDING), "request remains PENDING after revert");
        assertEq(vault.totalRedeemInFlight(), 0, "no redeemInFlight created on revert");

        // Now settle B's investInFlight -- posToken moves from adapter bookkeeping to vault.
        (,,, uint256 posAmtB,,,,, ) = vault.inFlightRecords(investIdB);
        _settleInvest(_arr(investIdB), _arr(posAmtB), _arr(0));
        assertEq(vault.totalInvestInFlight(), 0, "B invest settled");

        // Retry process -- adapterPool=1500 >= shortfall=1000, so succeeds.
        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), _arr(reqId));

        (,,,,,,, IMantleYieldVault.RequestStatus sAfterProc) = vault.requests(reqId);
        assertEq(uint8(sAfterProc), uint8(IMantleYieldVault.RequestStatus.PROCESSING), "request PROCESSING after retry");

        // Settle the single redeemInFlight created by this process.
        uint256 redeemIF = vault.totalRedeemInFlight();
        assertGt(redeemIF, 0, "divest on retry must have created redeemInFlight");
        uint256 redeemId1 = _lastInFlightId();
        (, , , , uint256 usdcAmt, , bool isInvest, , ) = vault.inFlightRecords(redeemId1);
        assertFalse(isInvest, "should be redeem inflight, not invest");
        assertGt(usdcAmt, 0, "redeem inflight should have USDC amount");
        adapter.simulateRedeemSettlement(usdcAmt);
        _settleRedeem(_arr(redeemId1), _arr(usdcAmt));

        // Finalize B's redeem.
        uint256 settledAssets = _convertToAssetsFloor(sharesB);
        uint256 vaultUsdc = usdc.balanceOf(address(vault));
        assertGe(vaultUsdc, settledAssets, "vault has enough after settle");

        uint256 balBBefore = usdc.balanceOf(userB);
        vm.prank(bot);
        executor.executeFinalizeRedeemBatch(address(controller), _arr(reqId), _arr(settledAssets));
        assertEq(usdc.balanceOf(userB) - balBBefore, settledAssets, "B received USDC");
        assertEq(vault.totalLockedShares(), 0, "locked cleared");

        (,,,,,,, IMantleYieldVault.RequestStatus statusDone) = vault.requests(reqId);
        assertEq(uint8(statusDone), uint8(IMantleYieldVault.RequestStatus.DONE), "request DONE");
        assertEq(vault.pendingRedeemRequest(userB), 0, "B pendingShares cleared");

        _logPass();
    }

    // =======================================================================
    // 5. Invest + immediate direction reversal (invest-settle-divest-settle-finalize)
    // =======================================================================

    function test_InvestThenImmediateDivest_FullCycle() public {
        _logCase("test_InvestThenImmediateDivest_FullCycle",
            unicode"Invest + 立即方向反转需要 divest -- 完整 invest-settle-divest-settle-finalize 循环");

        // Deposit 10000, invest + settle
        _deposit(userA, 10_000e6);
        _investAll();
        uint256 investId = _lastInFlightId();
        (,,, uint256 posAmt,,,,, ) = vault.inFlightRecords(investId);
        _settleInvest(_arr(investId), _arr(posAmt), _arr(0));
        assertEq(usdc.balanceOf(address(vault)), 0, "vault USDC = 0");
        assertGt(posToken.balanceOf(address(vault)), 0, "vault has posToken");

        // Immediately request full redeem (direction reversal)
        uint256 sharesA = vault.balanceOf(userA);
        vm.prank(userA);
        uint256 reqId = gateway.requestRedeem(sharesA);

        // Process -- must divest the just-invested posToken
        uint256 batchTotal = _convertToAssetsFloor(sharesA);
        vm.expectEmit(true, false, false, true, address(controller));
        emit StrategyController.RedeemBatchProcessing(1, batchTotal, batchTotal); // shortfall = batchTotal (freeCash=0)
        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), _arr(reqId));
        uint256 redeemId = _lastInFlightId();
        assertGt(vault.totalRedeemInFlight(), 0, "divest triggered");

        // Settle redeem
        (,,,, uint256 redeemUsdc,,,, ) = vault.inFlightRecords(redeemId);
        adapter.simulateRedeemSettlement(redeemUsdc);
        _settleRedeem(_arr(redeemId), _arr(redeemUsdc));

        // Finalize
        uint256 settled = _convertToAssetsFloor(sharesA);
        uint256 balBefore = usdc.balanceOf(userA);
        vm.prank(bot);
        executor.executeFinalizeRedeemBatch(address(controller), _arr(reqId), _arr(settled));

        assertEq(usdc.balanceOf(userA) - balBefore, settled, "A received full amount");
        assertEq(vault.totalLockedShares(), 0, "locked cleared");
        assertEq(posToken.balanceOf(address(vault)), 0, "vault posToken = 0");
        assertEq(vault.totalInvestInFlight(), 0, "no invest IF");
        assertEq(vault.totalRedeemInFlight(), 0, "no redeem IF");

        // Verify DONE + pendingShares cleared
        (,,,,,,, IMantleYieldVault.RequestStatus statusDoneA) = vault.requests(reqId);
        assertEq(uint8(statusDoneA), uint8(IMantleYieldVault.RequestStatus.DONE), "request status DONE");
        assertEq(vault.pendingRedeemRequest(userA), 0, "A pendingShares cleared");

        _logPass();
    }
}
