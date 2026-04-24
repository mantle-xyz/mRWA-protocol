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

contract MockUSDC_RS is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockSanctionsOracle_RS is ISanctionsOracle {
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

contract MockPosToken_RS is ERC20 {
    constructor() ERC20("MockPosToken", "mPOS") {}
    function decimals() public pure override returns (uint8) { return 18; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function burn(address from, uint256 amount) external { _burn(from, amount); }
}

contract MockAccountant_RS {
    uint256 public rate = 1e18;
    function getRate() external view returns (uint256) { return rate; }
    function getRateSafe() external view returns (uint256) { return rate; }
    function setExchangeRate(uint256 newRate) external { rate = newRate; }
}

/// @dev Async adapter: totalValue() reads posToken on VAULT, deposit pulls USDC from vault,
///      requestRedeemAsync pulls posToken from vault. withdrawSync returns 0 (pure async).
contract MockAsyncAdapter_RS is IStrategyAdapter {
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
    function name() external pure returns (string memory) { return "MockAsyncAdapter_RS"; }
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
        MockPosToken_RS(POS_TOKEN).mint(address(this), posAmount);
    }

    function withdrawSync(uint256, address) external pure returns (uint256) { return 0; }

    /// @dev M-14/N-14: parameter is now posAmount directly (no conversion needed).
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
        MockUSDC_RS(ASSET).mint(address(this), usdcAmount);
    }
}

// ---------------------------------------------------------------------------
// QA Test: Redeem Settlement Distribution & Multi-Batch Scenarios
// ---------------------------------------------------------------------------

contract RedeemSettlementQATest is Test {
    using Math for uint256;

    MockUSDC_RS internal usdc;
    MockPosToken_RS internal posToken;
    MockSanctionsOracle_RS internal oracle;
    MockAccountant_RS internal mockAccountant;
    MantleYieldVault internal vault;
    MantleVaultGateway internal gateway;
    StrategyController internal controller;
    MockAsyncAdapter_RS internal adapter;
    OperatorExecutor internal executor;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal sanctionSafe = makeAddr("sanctionSafe");
    address internal bot = makeAddr("bot");
    address internal userA = makeAddr("userA");
    address internal userB = makeAddr("userB");
    address internal userC = makeAddr("userC");

    // -----------------------------------------------------------------------
    // Logging
    // -----------------------------------------------------------------------

    string constant MODULE = "Redeem Settlement Distribution & Multi-Batch Scenarios";

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

        usdc = new MockUSDC_RS();
        posToken = new MockPosToken_RS();
        oracle = new MockSanctionsOracle_RS();
        mockAccountant = new MockAccountant_RS();

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

        adapter = new MockAsyncAdapter_RS(address(usdc), address(posToken), address(vault));
        vm.startPrank(admin);
        controller.registerStrategy(address(adapter), 10_000, 1, true);
        controller.activateStrategy(address(adapter));
        address[] memory ordered = new address[](1);
        ordered[0] = address(adapter);
        controller.setStrategyOrder(ordered);
        vm.stopPrank();

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

    function _processRedeemBatch(uint256[] memory ids) internal {
        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), ids);
    }

    function _finalizeRedeemBatch(uint256[] memory ids, uint256[] memory settledAssets) internal {
        vm.prank(bot);
        executor.executeFinalizeRedeemBatch(address(controller), ids, settledAssets);
    }

    /// @dev Full cycle: deposit -> invest -> settle invest -> return posToken on vault
    function _depositAndInvest(address user, uint256 amount) internal {
        _deposit(user, amount);
        _investAll();
        uint256 iid = _lastInFlightId();
        (,,, uint256 posAmt,,,,, ) = vault.inFlightRecords(iid);
        _settleInvest(_arr(iid), _arr(posAmt), _arr(0));
    }

    /// @dev Deposit without invest -- USDC stays in vault as freeCash
    function _depositCashOnly(address user, uint256 amount) internal {
        _deposit(user, amount);
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
    // 1. Path B basic -- freeCash covers all, no divest
    // =======================================================================

    function test_PathB_FreeCashCoversAll() public {
        _logCase("test_PathB_FreeCashCoversAll",
            unicode"Path B 基础 -- freeCash 充足无 divest，settledAssets=convertToAssets(shares)");

        // 3 users deposit 1000 each. Keep USDC in vault (no invest).
        // Extra 2000 to ensure freeCash far exceeds redeem need.
        _depositCashOnly(userA, 1000e6);
        _depositCashOnly(userB, 1000e6);
        _depositCashOnly(userC, 1000e6);
        // Deposit extra as userA to pad freeCash
        _depositCashOnly(userA, 4000e6);

        uint256 sharesA = 1000e6; // first deposit shares
        uint256 sharesB = vault.balanceOf(userB);
        uint256 sharesC = vault.balanceOf(userC);

        // Each user requests redeem 1000 shares
        vm.prank(userA);
        uint256 reqA = gateway.requestRedeem(sharesA);
        vm.prank(userB);
        uint256 reqB = gateway.requestRedeem(sharesB);
        vm.prank(userC);
        uint256 reqC = gateway.requestRedeem(sharesC);

        // Process batch (sorted ids)
        uint256[] memory ids;
        if (reqA < reqB && reqB < reqC) {
            ids = _arr3(reqA, reqB, reqC);
        } else {
            // Ids are always incrementing from nextRequestId
            ids = _arr3(reqA, reqB, reqC);
        }

        uint256 freeCashBefore = vault.getFreeCash();
        assertGt(freeCashBefore, 3000e6, "freeCash > batch total");

        // Path B: shortfall=0 (freeCash sufficient)
        uint256 batchTotal = 3 * _convertToAssetsFloor(1000e6);
        vm.expectEmit(true, false, false, true, address(controller));
        emit StrategyController.RedeemBatchProcessing(3, batchTotal, 0); // batchSize=3, shortfall=0
        _processRedeemBatch(ids);
        // No in-flight should be created (freeCash was sufficient)
        assertEq(vault.totalRedeemInFlight(), 0, "no redeemInFlight -- Path B");

        // Finalize: each gets convertToAssets(1000 shares) = 1000e6
        uint256 settledPerUser = _convertToAssetsFloor(1000e6);
        assertEq(settledPerUser, 1000e6, "settled = 1000 at rate 1.0");

        uint256 balA = usdc.balanceOf(userA);
        uint256 balB = usdc.balanceOf(userB);
        uint256 balC = usdc.balanceOf(userC);
        _finalizeRedeemBatch(ids, _arr3(settledPerUser, settledPerUser, settledPerUser));

        assertEq(usdc.balanceOf(userA) - balA, settledPerUser, "A received 1000");
        assertEq(usdc.balanceOf(userB) - balB, settledPerUser, "B received 1000");
        assertEq(usdc.balanceOf(userC) - balC, settledPerUser, "C received 1000");
        assertEq(vault.totalLockedShares(), 0, "locked cleared");

        // Verify on-chain state: status DONE and pendingShares cleared
        (,,,,,,, IMantleYieldVault.RequestStatus sA) = vault.requests(reqA);
        assertEq(uint8(sA), uint8(IMantleYieldVault.RequestStatus.DONE), "reqA status DONE");
        assertEq(vault.pendingRedeemRequest(userA), 0, "A pendingShares cleared");
        (,,,,,,, IMantleYieldVault.RequestStatus sB) = vault.requests(reqB);
        assertEq(uint8(sB), uint8(IMantleYieldVault.RequestStatus.DONE), "reqB status DONE");
        assertEq(vault.pendingRedeemRequest(userB), 0, "B pendingShares cleared");
        (,,,,,,, IMantleYieldVault.RequestStatus sC) = vault.requests(reqC);
        assertEq(uint8(sC), uint8(IMantleYieldVault.RequestStatus.DONE), "reqC status DONE");
        assertEq(vault.pendingRedeemRequest(userC), 0, "C pendingShares cleared");

        _logPass();
    }

    // =======================================================================
    // 2. Path B + rate rise
    // =======================================================================

    function test_PathB_RateRise() public {
        _logCase("test_PathB_RateRise",
            unicode"Path B + rate 上升 -- request 时 rate=1.0，finalize 时 rate=1.1");

        _depositCashOnly(userA, 5000e6); // pad with extra cash
        _depositCashOnly(userB, 1000e6);

        uint256 sharesB = vault.balanceOf(userB);
        vm.prank(userB);
        uint256 reqId = gateway.requestRedeem(sharesB);
        (,,,, uint256 estimated,,, ) = vault.requests(reqId);
        assertEq(estimated, 1000e6, "estimated at rate=1.0");

        // Rate rises
        mockAccountant.setExchangeRate(11e17);

        // Process: Path B (no divest, freeCash sufficient)
        uint256 batchTotalB2 = _convertToAssetsFloor(sharesB);
        vm.expectEmit(true, false, false, true, address(controller));
        emit StrategyController.RedeemBatchProcessing(1, batchTotalB2, 0); // batchSize=1, shortfall=0
        _processRedeemBatch(_arr(reqId));
        assertEq(vault.totalRedeemInFlight(), 0, "Path B, no divest");

        // settledAssets at new rate: 1000 shares * 1.1 = 1100 USDC
        uint256 settled = _convertToAssetsFloor(sharesB);
        assertEq(settled, 1100e6, "settled = 1100 at rate 1.1");

        uint256 balBefore = usdc.balanceOf(userB);
        // settled (1100) != estimated (1000) -> RequestSettlementAdjusted
        vm.expectEmit(true, false, false, true, address(vault));
        emit IMantleYieldVault.RequestSettlementAdjusted(reqId, estimated, settled);
        _finalizeRedeemBatch(_arr(reqId), _arr(settled));
        uint256 received = usdc.balanceOf(userB) - balBefore;
        assertEq(received, 1100e6, "B received 1100 > estimated 1000");
        assertGt(received, estimated, "received > estimated");

        // Verify on-chain state: status DONE and pendingShares cleared
        (,,,,,,, IMantleYieldVault.RequestStatus sB2) = vault.requests(reqId);
        assertEq(uint8(sB2), uint8(IMantleYieldVault.RequestStatus.DONE), "reqB status DONE");
        assertEq(vault.pendingRedeemRequest(userB), 0, "B pendingShares cleared");

        _logPass();
    }

    // =======================================================================
    // 3. Path B + rate drop
    // =======================================================================

    function test_PathB_RateDrop() public {
        _logCase("test_PathB_RateDrop",
            unicode"Path B + rate 下降 -- 用户收到少于 estimatedAssets");

        mockAccountant.setExchangeRate(11e17);
        _depositCashOnly(userA, 5000e6);
        _depositCashOnly(userB, 1100e6);

        uint256 sharesB = vault.balanceOf(userB);
        // shares = 1100e6 * 1e18 / 1.1e18 = 1000e6
        vm.prank(userB);
        uint256 reqId = gateway.requestRedeem(sharesB);
        (,,,, uint256 estimated,,, ) = vault.requests(reqId);
        assertEq(estimated, 1100e6, "estimated at rate=1.1");

        // Rate drops
        mockAccountant.setExchangeRate(1e18);

        _processRedeemBatch(_arr(reqId));

        uint256 settled = _convertToAssetsFloor(sharesB);
        assertEq(settled, 1000e6, "settled = 1000 at rate 1.0");

        uint256 balBefore = usdc.balanceOf(userB);
        // settled (1000) != estimated (1100) -> RequestSettlementAdjusted
        vm.expectEmit(true, false, false, true, address(vault));
        emit IMantleYieldVault.RequestSettlementAdjusted(reqId, estimated, settled);
        _finalizeRedeemBatch(_arr(reqId), _arr(settled));
        uint256 received = usdc.balanceOf(userB) - balBefore;
        assertEq(received, 1000e6, "B received 1000 < estimated 1100");
        assertLt(received, estimated, "received < estimated");

        // Verify on-chain state: status DONE and pendingShares cleared
        (,,,,,,, IMantleYieldVault.RequestStatus sB3) = vault.requests(reqId);
        assertEq(uint8(sB3), uint8(IMantleYieldVault.RequestStatus.DONE), "reqB status DONE");
        assertEq(vault.pendingRedeemRequest(userB), 0, "B pendingShares cleared");

        _logPass();
    }

    // =======================================================================
    // 4. Path A basic -- divest full delivery, no loss
    // =======================================================================

    function test_PathA_FullDelivery_NoLoss() public {
        _logCase("test_PathA_FullDelivery_NoLoss",
            unicode"Path A 基础 -- divest 全额到账无磨损");

        // 3 users each deposit 2000 = 6000 total
        _deposit(userA, 2000e6);
        _deposit(userB, 2000e6);
        _deposit(userC, 2000e6);

        // Invest 5000 (keep ~1000 as cash buffer)
        _investWithBuffer(1667); // ~16.67% of 6000 = ~1000
        uint256 iid = _lastInFlightId();
        (,,, uint256 posAmt,,,,, ) = vault.inFlightRecords(iid);
        _settleInvest(_arr(iid), _arr(posAmt), _arr(0));

        uint256 vaultUsdc = usdc.balanceOf(address(vault));
        console2.log("vault USDC after invest:", vaultUsdc);

        // Each user requests redeem 1000 shares, total = 3000
        vm.prank(userA);
        uint256 reqA = gateway.requestRedeem(1000e6);
        vm.prank(userB);
        uint256 reqB = gateway.requestRedeem(1000e6);
        vm.prank(userC);
        uint256 reqC = gateway.requestRedeem(1000e6);
        uint256[] memory ids = _arr3(reqA, reqB, reqC);

        // Process: freeCash < 3000, need divest
        _processRedeemBatch(ids);
        uint256 redeemIF = vault.totalRedeemInFlight();
        assertGt(redeemIF, 0, "divest created redeemInFlight");

        // Settle redeem: full delivery (no slippage)
        uint256 redeemId = _lastInFlightId();
        (,,,, uint256 redeemUsdc,,,, ) = vault.inFlightRecords(redeemId);
        adapter.simulateRedeemSettlement(redeemUsdc);
        _settleRedeem(_arr(redeemId), _arr(redeemUsdc));

        // Finalize: each gets convertToAssets(1000 shares) = 1000 (same as Path B)
        uint256 settledPerUser = _convertToAssetsFloor(1000e6);
        assertEq(settledPerUser, 1000e6, "settled = 1000 at rate 1.0");

        uint256 balA = usdc.balanceOf(userA);
        uint256 balB = usdc.balanceOf(userB);
        uint256 balC = usdc.balanceOf(userC);
        _finalizeRedeemBatch(ids, _arr3(settledPerUser, settledPerUser, settledPerUser));

        assertEq(usdc.balanceOf(userA) - balA, settledPerUser, "A received 1000");
        assertEq(usdc.balanceOf(userB) - balB, settledPerUser, "B received 1000");
        assertEq(usdc.balanceOf(userC) - balC, settledPerUser, "C received 1000");
        assertEq(vault.totalLockedShares(), 0, "locked cleared");

        // Verify on-chain state: status DONE and pendingShares cleared
        (,,,,,,, IMantleYieldVault.RequestStatus sA4) = vault.requests(reqA);
        assertEq(uint8(sA4), uint8(IMantleYieldVault.RequestStatus.DONE), "reqA status DONE");
        assertEq(vault.pendingRedeemRequest(userA), 0, "A pendingShares cleared");
        (,,,,,,, IMantleYieldVault.RequestStatus sB4) = vault.requests(reqB);
        assertEq(uint8(sB4), uint8(IMantleYieldVault.RequestStatus.DONE), "reqB status DONE");
        assertEq(vault.pendingRedeemRequest(userB), 0, "B pendingShares cleared");
        (,,,,,,, IMantleYieldVault.RequestStatus sC4) = vault.requests(reqC);
        assertEq(uint8(sC4), uint8(IMantleYieldVault.RequestStatus.DONE), "reqC status DONE");
        assertEq(vault.pendingRedeemRequest(userC), 0, "C pendingShares cleared");

        _logPass();
    }

    // =======================================================================
    // 5. Path A with slippage -- loss distributed proportionally across batch
    // =======================================================================

    function test_PathA_Slippage_ProportionalLoss() public {
        _logCase("test_PathA_Slippage_ProportionalLoss",
            unicode"Path A 有磨损 -- divest 到账不足，损失按比例分摊到全批次");

        // Setup: vault USDC~1000 (buffer), posToken~5000 (invested)
        // 3 users each have 2000 shares (deposit 2000 each = 6000 total, invest 5000)
        _deposit(userA, 2000e6);
        _deposit(userB, 2000e6);
        _deposit(userC, 2000e6);
        // Invest 5000 (buffer keeps ~1000)
        _investWithBuffer(1667);
        uint256 iid = _lastInFlightId();
        (,,, uint256 posAmt,,,,, ) = vault.inFlightRecords(iid);
        _settleInvest(_arr(iid), _arr(posAmt), _arr(0));

        uint256 vaultUsdc = usdc.balanceOf(address(vault));
        uint256 vaultPos = posToken.balanceOf(address(vault));
        console2.log("vault USDC:", vaultUsdc);
        console2.log("vault posToken:", vaultPos);

        // Each user requests redeem 1000 shares = 1000 USDC each, total=3000
        vm.prank(userA);
        uint256 reqA = gateway.requestRedeem(1000e6);
        vm.prank(userB);
        uint256 reqB = gateway.requestRedeem(1000e6);
        vm.prank(userC);
        uint256 reqC = gateway.requestRedeem(1000e6);

        uint256[] memory ids = _arr3(reqA, reqB, reqC);

        // Process: freeCash might cover some, divest the rest
        _processRedeemBatch(ids);

        uint256 redeemIF = vault.totalRedeemInFlight();
        assertGt(redeemIF, 0, "divest must have triggered (freeCash < batch total)");
        // Settle with slippage: only 60% of expected USDC
        // Real contract: freeCash=0 after lock (physBal=1000 < locked=3000), so divest=3000.
        // With ~1000 buffer, need settle% < 66.7% for loss to be visible.
        // At 60%: total = ~1000 + 3000*0.6 = ~2800, each gets ~933 < estimated 1000.
        uint256 redeemId = _lastInFlightId();
        (,,,, uint256 expectedUsdc,,,, ) = vault.inFlightRecords(redeemId);
        uint256 actualUsdc = expectedUsdc * 60 / 100; // 60% delivery
        adapter.simulateRedeemSettlement(actualUsdc);
        _settleRedeem(_arr(redeemId), _arr(actualUsdc));

        // Calculate actual total available for settlement
        uint256 totalAvailable = usdc.balanceOf(address(vault));
        console2.log("total USDC available for finalize:", totalAvailable);

        // Path A formula: each order gets proportional share
        // cash_portion = batchTotal - inflight_estimated
        // actual_total = cash_portion + inflight_actual
        // settled[i] = estimated[i] * actual_total / batchTotal
        uint256 batchTotal = 3000e6; // 3 * 1000
        uint256 settledA = 1000e6 * totalAvailable / batchTotal;
        uint256 settledB = 1000e6 * totalAvailable / batchTotal;
        uint256 settledC = totalAvailable - settledA - settledB; // give remainder to C to avoid dust

        uint256 balA = usdc.balanceOf(userA);
        uint256 balB = usdc.balanceOf(userB);
        uint256 balC = usdc.balanceOf(userC);

        // All 3 have settled != estimated -> RequestSettlementAdjusted for each
        vm.expectEmit(true, false, false, true, address(vault));
        emit IMantleYieldVault.RequestSettlementAdjusted(reqA, 1000e6, settledA);
        _finalizeRedeemBatch(ids, _arr3(settledA, settledB, settledC));

        uint256 recvA = usdc.balanceOf(userA) - balA;
        uint256 recvB = usdc.balanceOf(userB) - balB;
        uint256 recvC = usdc.balanceOf(userC) - balC;

        // All received same (proportional, same shares)
        assertEq(recvA, settledA, "A received proportional share");
        assertEq(recvB, settledB, "B received proportional share");
        assertEq(recvC, settledC, "C received proportional share");
        // Each received less than estimated 1000
        assertLt(recvA, 1000e6, "A received < estimated");
        // Sum = totalAvailable
        assertEq(recvA + recvB + recvC, totalAvailable, "sum = totalAvailable");
        assertEq(vault.totalLockedShares(), 0, "locked cleared");

        // Verify on-chain state: status DONE and pendingShares cleared
        (,,,,,,, IMantleYieldVault.RequestStatus sA5) = vault.requests(reqA);
        assertEq(uint8(sA5), uint8(IMantleYieldVault.RequestStatus.DONE), "reqA status DONE");
        assertEq(vault.pendingRedeemRequest(userA), 0, "A pendingShares cleared");
        (,,,,,,, IMantleYieldVault.RequestStatus sB5) = vault.requests(reqB);
        assertEq(uint8(sB5), uint8(IMantleYieldVault.RequestStatus.DONE), "reqB status DONE");
        assertEq(vault.pendingRedeemRequest(userB), 0, "B pendingShares cleared");
        (,,,,,,, IMantleYieldVault.RequestStatus sC5) = vault.requests(reqC);
        assertEq(uint8(sC5), uint8(IMantleYieldVault.RequestStatus.DONE), "reqC status DONE");
        assertEq(vault.pendingRedeemRequest(userC), 0, "C pendingShares cleared");

        _logPass();
    }

    // =======================================================================
    // 6. Path A different amounts -- proportional by shares
    // =======================================================================

    function test_PathA_DifferentAmounts_ProportionalByShares() public {
        _logCase("test_PathA_DifferentAmounts_ProportionalByShares",
            unicode"Path A 不同金额 order 同批次 -- 磨损按 shares 占比分配");

        // A=500, B=1500, C=1000 shares to redeem. Total=3000.
        // Setup: invest most, keep some cash
        _deposit(userA, 2000e6);
        _deposit(userB, 2000e6);
        _deposit(userC, 2000e6);
        // Invest 5200, keep 800 as cash
        _investWithBuffer(1334); // ~13.34% of 6000 = ~800
        uint256 iid = _lastInFlightId();
        (,,, uint256 posAmt,,,,, ) = vault.inFlightRecords(iid);
        _settleInvest(_arr(iid), _arr(posAmt), _arr(0));

        // A redeems 500, B redeems 1500, C redeems 1000
        vm.prank(userA);
        uint256 reqA = gateway.requestRedeem(500e6);
        vm.prank(userB);
        uint256 reqB = gateway.requestRedeem(1500e6);
        vm.prank(userC);
        uint256 reqC = gateway.requestRedeem(1000e6);

        uint256[] memory ids = _arr3(reqA, reqB, reqC);
        _processRedeemBatch(ids);

        // Settle redeem with slippage -- divest must have happened
        uint256 redeemIF = vault.totalRedeemInFlight();
        assertGt(redeemIF, 0, "divest must have triggered (freeCash < batch total)");
        uint256 redeemId = _lastInFlightId();
        (,,,, uint256 expectedUsdc,,,, ) = vault.inFlightRecords(redeemId);
        // 90% delivery
        uint256 actualUsdc = expectedUsdc * 90 / 100;
        adapter.simulateRedeemSettlement(actualUsdc);
        _settleRedeem(_arr(redeemId), _arr(actualUsdc));

        uint256 totalAvailable = usdc.balanceOf(address(vault));
        uint256 batchTotal = 3000e6;

        // Proportional: each gets estimated * totalAvailable / batchTotal
        uint256 settledA = uint256(500e6) * totalAvailable / batchTotal;
        uint256 settledB = uint256(1500e6) * totalAvailable / batchTotal;
        uint256 settledC = totalAvailable - settledA - settledB;

        uint256 balA = usdc.balanceOf(userA);
        uint256 balB = usdc.balanceOf(userB);
        uint256 balC = usdc.balanceOf(userC);

        _finalizeRedeemBatch(ids, _arr3(settledA, settledB, settledC));

        assertEq(usdc.balanceOf(userA) - balA, settledA, "A got proportional");
        assertEq(usdc.balanceOf(userB) - balB, settledB, "B got proportional");
        assertEq(usdc.balanceOf(userC) - balC, settledC, "C got proportional");

        // B got ~3x what A got (1500/500 ratio)
        uint256 recvA = usdc.balanceOf(userA) - balA;
        uint256 recvB = usdc.balanceOf(userB) - balB;
        // Allow 1 wei rounding
        assertApproxEqAbs(recvB, recvA * 3, 1, "B received ~3x A");
        assertEq(vault.totalLockedShares(), 0, "locked cleared");

        // Verify on-chain state: status DONE and pendingShares cleared
        (,,,,,,, IMantleYieldVault.RequestStatus sA6) = vault.requests(reqA);
        assertEq(uint8(sA6), uint8(IMantleYieldVault.RequestStatus.DONE), "reqA status DONE");
        assertEq(vault.pendingRedeemRequest(userA), 0, "A pendingShares cleared");
        (,,,,,,, IMantleYieldVault.RequestStatus sB6) = vault.requests(reqB);
        assertEq(uint8(sB6), uint8(IMantleYieldVault.RequestStatus.DONE), "reqB status DONE");
        assertEq(vault.pendingRedeemRequest(userB), 0, "B pendingShares cleared");
        (,,,,,,, IMantleYieldVault.RequestStatus sC6) = vault.requests(reqC);
        assertEq(uint8(sC6), uint8(IMantleYieldVault.RequestStatus.DONE), "reqC status DONE");
        assertEq(vault.pendingRedeemRequest(userC), 0, "C pendingShares cleared");

        _logPass();
    }

    // =======================================================================
    // 7. In-flight not CONFIRMED -- finalize fails, succeeds after settle
    // =======================================================================

    function test_InFlightNotConfirmed_FinalizeFailsThenSucceeds() public {
        _logCase("test_InFlightNotConfirmed_FinalizeFailsThenSucceeds",
            unicode"In-flight 未 CONFIRMED 时 finalize 应失败 -- 多周期协调");

        // Invest all, then redeem
        _deposit(userA, 5000e6);
        _investAll();
        uint256 iid = _lastInFlightId();
        (,,, uint256 posAmt,,,,, ) = vault.inFlightRecords(iid);
        _settleInvest(_arr(iid), _arr(posAmt), _arr(0));

        vm.prank(userA);
        uint256 reqId = gateway.requestRedeem(3000e6);

        _processRedeemBatch(_arr(reqId));
        uint256 redeemId = _lastInFlightId();
        assertGt(vault.totalRedeemInFlight(), 0, "redeemInFlight exists");

        // Attempt finalize without settle -- should revert (vault has no USDC)
        uint256 settled = _convertToAssetsFloor(3000e6);
        uint256 vaultUsdcNow = usdc.balanceOf(address(vault));
        vm.prank(bot);
        vm.expectRevert(
            abi.encodeWithSelector(StrategyController.InsufficientCashForReady.selector, settled, vaultUsdcNow)
        );
        executor.executeFinalizeRedeemBatch(address(controller), _arr(reqId), _arr(settled));

        // Now settle
        (,,,, uint256 redeemUsdc,,,, ) = vault.inFlightRecords(redeemId);
        adapter.simulateRedeemSettlement(redeemUsdc);
        _settleRedeem(_arr(redeemId), _arr(redeemUsdc));

        // Finalize succeeds
        uint256 balBefore = usdc.balanceOf(userA);
        _finalizeRedeemBatch(_arr(reqId), _arr(settled));
        assertEq(usdc.balanceOf(userA) - balBefore, settled, "A received USDC");
        assertEq(vault.totalLockedShares(), 0, "locked cleared");

        // Verify on-chain state: status DONE and pendingShares cleared
        (,,,,,,, IMantleYieldVault.RequestStatus sA7) = vault.requests(reqId);
        assertEq(uint8(sA7), uint8(IMantleYieldVault.RequestStatus.DONE), "reqA status DONE");
        assertEq(vault.pendingRedeemRequest(userA), 0, "A pendingShares cleared");

        _logPass();
    }

    // =======================================================================
    // 8. Two batches -- batch1 finalize affects batch2 settlement
    // =======================================================================

    function test_TwoBatches_Batch1FinalizeAffectsBatch2() public {
        _logCase("test_TwoBatches_Batch1FinalizeAffectsBatch2",
            unicode"两批次 -- 第一批 finalize 释放 lockedShares 后影响第二批 rate");

        // Deposit enough cash to cover both batches (Path B for simplicity)
        _depositCashOnly(userA, 10_000e6);
        _depositCashOnly(userB, 10_000e6);

        // Batch 1: userA redeems 1000 shares
        vm.prank(userA);
        uint256 req1 = gateway.requestRedeem(1000e6);

        // Process + finalize batch 1 at rate=1.0
        _processRedeemBatch(_arr(req1));
        uint256 settled1 = _convertToAssetsFloor(1000e6);
        assertEq(settled1, 1000e6, "batch1 settled at rate 1.0");
        uint256 balA = usdc.balanceOf(userA);
        _finalizeRedeemBatch(_arr(req1), _arr(settled1));
        assertEq(usdc.balanceOf(userA) - balA, 1000e6, "A got 1000");

        // Verify on-chain state: batch1 req status DONE and pendingShares cleared
        (,,,,,,, IMantleYieldVault.RequestStatus sA8a) = vault.requests(req1);
        assertEq(uint8(sA8a), uint8(IMantleYieldVault.RequestStatus.DONE), "req1 status DONE");
        assertEq(vault.pendingRedeemRequest(userA), 0, "A pendingShares cleared after batch1");

        // After batch1 finalize, totalLockedShares decreased
        assertEq(vault.totalLockedShares(), 0, "batch1 locked released");

        // Rate changes before batch 2
        mockAccountant.setExchangeRate(11e17);

        // Batch 2: userB redeems 1000 shares at new rate
        vm.prank(userB);
        uint256 req2 = gateway.requestRedeem(1000e6);

        _processRedeemBatch(_arr(req2));
        uint256 settled2 = _convertToAssetsFloor(1000e6);
        assertEq(settled2, 1100e6, "batch2 settled at rate 1.1");

        uint256 balB = usdc.balanceOf(userB);
        _finalizeRedeemBatch(_arr(req2), _arr(settled2));
        assertEq(usdc.balanceOf(userB) - balB, 1100e6, "B got 1100");

        // Verify on-chain state: batch2 req status DONE and pendingShares cleared
        (,,,,,,, IMantleYieldVault.RequestStatus sB8b) = vault.requests(req2);
        assertEq(uint8(sB8b), uint8(IMantleYieldVault.RequestStatus.DONE), "req2 status DONE");
        assertEq(vault.pendingRedeemRequest(userB), 0, "B pendingShares cleared after batch2");

        // Same shares but different settled amounts
        assertGt(settled2, settled1, "batch2 > batch1 due to rate change");
        assertEq(vault.totalLockedShares(), 0, "all locked cleared");

        _logPass();
    }

    // =======================================================================
    // 9. posTokenPrice drop causes divest shortfall -- slippage distributed
    // =======================================================================

    function test_PriceDrop_DivestShortfall_SlippageDistributed() public {
        _logCase("test_PriceDrop_DivestShortfall_SlippageDistributed",
            unicode"posTokenPrice 下跌导致 divest 到账偏离预估 -- 磨损按比例分摊");

        // Invest 5000, keep ~1000 cash
        _deposit(userA, 3000e6);
        _deposit(userB, 3000e6);
        _investWithBuffer(1667);
        uint256 iid = _lastInFlightId();
        (,,, uint256 posAmt,,,,, ) = vault.inFlightRecords(iid);
        _settleInvest(_arr(iid), _arr(posAmt), _arr(0));

        // 2 users redeem 1000 each, total=2000. freeCash~1000, divest~1000
        vm.prank(userA);
        uint256 reqA = gateway.requestRedeem(1000e6);
        vm.prank(userB);
        uint256 reqB = gateway.requestRedeem(1000e6);

        uint256[] memory ids = _arr2(reqA, reqB);
        _processRedeemBatch(ids);

        // Price drops before settle: posToken worth less
        // Real contract: freeCash=0 after lock (physBal=~1000 < locked=2000), so divest=2000.
        // With ~1000 buffer, need settle% < 50% for loss to be visible.
        // At 40%: total = ~1000 + 2000*0.4 = ~1800, each gets ~900 < estimated 1000.
        uint256 redeemIF = vault.totalRedeemInFlight();
        assertGt(redeemIF, 0, "divest must have triggered");
        uint256 redeemId = _lastInFlightId();
        (,,,, uint256 expectedUsdc,,,, ) = vault.inFlightRecords(redeemId);
        // Price drop: 40% delivery (severe drop to overwhelm cash buffer)
        uint256 actualUsdc = expectedUsdc * 40 / 100;
        adapter.simulateRedeemSettlement(actualUsdc);
        _settleRedeem(_arr(redeemId), _arr(actualUsdc));

        uint256 totalAvailable = usdc.balanceOf(address(vault));
        // Each gets half (equal shares)
        uint256 settledA = totalAvailable / 2;
        uint256 settledB = totalAvailable - settledA;

        uint256 balA = usdc.balanceOf(userA);
        uint256 balB = usdc.balanceOf(userB);
        _finalizeRedeemBatch(ids, _arr2(settledA, settledB));

        uint256 recvA = usdc.balanceOf(userA) - balA;
        uint256 recvB = usdc.balanceOf(userB) - balB;
        assertEq(recvA, settledA, "A got proportional share");
        assertEq(recvB, settledB, "B got proportional share");
        assertLt(recvA, 1000e6, "A got less than estimated due to slippage");
        assertEq(recvA + recvB, totalAvailable, "sum = total available");
        assertEq(vault.totalLockedShares(), 0, "locked cleared");

        // Verify on-chain state: status DONE and pendingShares cleared
        (,,,,,,, IMantleYieldVault.RequestStatus sA9) = vault.requests(reqA);
        assertEq(uint8(sA9), uint8(IMantleYieldVault.RequestStatus.DONE), "reqA status DONE");
        assertEq(vault.pendingRedeemRequest(userA), 0, "A pendingShares cleared");
        (,,,,,,, IMantleYieldVault.RequestStatus sB9) = vault.requests(reqB);
        assertEq(uint8(sB9), uint8(IMantleYieldVault.RequestStatus.DONE), "reqB status DONE");
        assertEq(vault.pendingRedeemRequest(userB), 0, "B pendingShares cleared");

        _logPass();
    }

    // =======================================================================
    // 10. posTokenPrice rise causes divest surplus -- settledAssets > estimated
    // =======================================================================

    function test_PriceRise_DivestSurplus() public {
        _logCase("test_PriceRise_DivestSurplus",
            unicode"posTokenPrice 上涨导致 divest 到账超预估 -- settledAssets 可超 estimatedAssets");

        // Invest 5000, keep 1000 cash
        _deposit(userA, 3000e6);
        _deposit(userB, 3000e6);
        _investWithBuffer(1667);
        uint256 iid = _lastInFlightId();
        (,,, uint256 posAmt,,,,, ) = vault.inFlightRecords(iid);
        _settleInvest(_arr(iid), _arr(posAmt), _arr(0));

        // 2 users redeem 1000 each
        vm.prank(userA);
        uint256 reqA = gateway.requestRedeem(1000e6);
        vm.prank(userB);
        uint256 reqB = gateway.requestRedeem(1000e6);

        uint256[] memory ids = _arr2(reqA, reqB);
        _processRedeemBatch(ids);

        // Price RISES before settle: actual USDC = 120% of expected
        uint256 redeemIF = vault.totalRedeemInFlight();
        assertGt(redeemIF, 0, "divest must have triggered");
        uint256 redeemId = _lastInFlightId();
        (,,,, uint256 expectedUsdc,,,, ) = vault.inFlightRecords(redeemId);
        uint256 actualUsdc = expectedUsdc * 120 / 100;
        adapter.simulateRedeemSettlement(actualUsdc);
        _settleRedeem(_arr(redeemId), _arr(actualUsdc));

        uint256 totalAvailable = usdc.balanceOf(address(vault));
        console2.log("total USDC available (surplus):", totalAvailable);
        assertGt(totalAvailable, 2000e6, "more than 2000 available due to price rise");

        // Can settle more than estimated
        uint256 settledA = totalAvailable / 2;
        uint256 settledB = totalAvailable - settledA;

        uint256 balA = usdc.balanceOf(userA);
        uint256 balB = usdc.balanceOf(userB);
        _finalizeRedeemBatch(ids, _arr2(settledA, settledB));

        uint256 recvA = usdc.balanceOf(userA) - balA;
        assertGt(recvA, 1000e6, "A got MORE than estimated (price rose)");
        assertEq(vault.totalLockedShares(), 0, "locked cleared");

        // Verify on-chain state: status DONE and pendingShares cleared
        (,,,,,,, IMantleYieldVault.RequestStatus sA10) = vault.requests(reqA);
        assertEq(uint8(sA10), uint8(IMantleYieldVault.RequestStatus.DONE), "reqA status DONE");
        assertEq(vault.pendingRedeemRequest(userA), 0, "A pendingShares cleared");
        (,,,,,,, IMantleYieldVault.RequestStatus sB10) = vault.requests(reqB);
        assertEq(uint8(sB10), uint8(IMantleYieldVault.RequestStatus.DONE), "reqB status DONE");
        assertEq(vault.pendingRedeemRequest(userB), 0, "B pendingShares cleared");

        _logPass();
    }

    // =======================================================================
    // 11. PathB + fee=100bps + rate change -- fee+rate interaction
    // =======================================================================

    function test_PathB_WithFee_RateChange() public {
        _logCase("test_PathB_WithFee_RateChange",
            unicode"Path B + fee=100bps + rate 变化 -- fee 与 rate 交叉验证 netShares/estimatedAssets/settled 三者不等");

        // Enable 1% redemption fee
        vm.prank(admin);
        vault.setRedemptionFee(100); // 100 bps = 1%

        // Rate = 1.2
        mockAccountant.setExchangeRate(12e17);

        // Deposit: 1200 USDC at rate 1.2 -> shares = 1200e6 * 1e18 / 1.2e18 = 1000e6
        _depositCashOnly(userA, 10_000e6); // pad for PathB
        _depositCashOnly(userB, 1200e6);
        uint256 sharesB = vault.balanceOf(userB);
        assertEq(sharesB, 1000e6, "B has 1000 shares at rate 1.2");

        // requestRedeem(1000 shares) at rate 1.2, fee=1%
        // Contract formula:
        //   grossAssets = 1000e6 * 1.2e18 / 1e18 = 1200e6
        //   fee = 1200e6 * 100 / 10000 (Ceil) = 12e6
        //   treasuryShare = 1000e6 * 100 / 10000 (Ceil) = 10e6
        //   estimatedAssets = 1200e6 - 12e6 = 1188e6
        //   netShares = 1000e6 - 10e6 = 990e6
        //   totalLockedShares += 990e6
        vm.prank(userB);
        uint256 reqId = gateway.requestRedeem(sharesB);

        // Verify on-chain request data matches contract formula
        (,, uint256 reqShares, uint256 reqFeeShares, uint256 reqEstimated,,, ) = vault.requests(reqId);
        uint256 expectedGrossAssets = Math.mulDiv(1000e6, 12e17, 1e18, Math.Rounding.Floor);
        uint256 expectedFee = Math.mulDiv(expectedGrossAssets, 100, 10_000, Math.Rounding.Ceil);
        uint256 expectedTreasuryShare = Math.mulDiv(1000e6, 100, 10_000, Math.Rounding.Ceil);
        uint256 expectedNetShares = 1000e6 - expectedTreasuryShare;
        uint256 expectedEstimated = expectedGrossAssets - expectedFee;

        assertEq(reqShares, expectedNetShares, "request.shares = netShares (990)");
        assertEq(reqFeeShares, expectedTreasuryShare, "request.feeShares = treasuryShare (10)");
        assertEq(reqEstimated, expectedEstimated, "request.estimatedAssets = grossAssets - fee");
        assertEq(vault.totalLockedShares(), expectedNetShares, "totalLockedShares = netShares");

        // Treasury received fee shares
        assertEq(vault.balanceOf(treasury), expectedTreasuryShare, "treasury got fee shares");

        // Rate drops to 1.0 before process
        mockAccountant.setExchangeRate(1e18);

        // Process: batchTotalAsset = netShares * newRate / 1e18 = 990e6 * 1.0 = 990e6
        uint256 batchTotal = Math.mulDiv(expectedNetShares, 1e18, 1e18, Math.Rounding.Floor);
        uint256 fc = vault.getFreeCash();
        assertGt(fc, batchTotal, "PathB: freeCash > batchTotal");

        vm.expectEmit(true, false, false, true, address(controller));
        emit StrategyController.RedeemBatchProcessing(1, batchTotal, 0);
        _processRedeemBatch(_arr(reqId));
        assertEq(vault.totalRedeemInFlight(), 0, "PathB: no divest");

        // Finalize: settle at new rate -> settledAssets = netShares * 1.0 = 990e6
        uint256 settled = Math.mulDiv(expectedNetShares, 1e18, 1e18, Math.Rounding.Floor);
        assertEq(settled, 990e6, "settled at rate 1.0 = 990");

        // settled (990) != estimated (1188) -> RequestSettlementAdjusted
        uint256 balBefore = usdc.balanceOf(userB);
        vm.expectEmit(true, false, false, true, address(vault));
        emit IMantleYieldVault.RequestSettlementAdjusted(reqId, reqEstimated, settled);
        _finalizeRedeemBatch(_arr(reqId), _arr(settled));

        uint256 received = usdc.balanceOf(userB) - balBefore;
        assertEq(received, settled, "B received settled amount");
        assertLt(received, reqEstimated, "received < estimated (rate dropped + fee)");
        assertEq(vault.totalLockedShares(), 0, "locked cleared");

        // Verify DONE + pendingShares
        (,,,,,,, IMantleYieldVault.RequestStatus s11) = vault.requests(reqId);
        assertEq(uint8(s11), uint8(IMantleYieldVault.RequestStatus.DONE), "request status DONE");
        assertEq(vault.pendingRedeemRequest(userB), 0, "B pendingShares cleared");

        _logPass();
    }

    // =======================================================================
    // 12. PathA + fee=100bps + rate=1.2 + slippage -- full cross-cutting
    // =======================================================================

    function test_PathA_WithFee_RateChange_Slippage() public {
        _logCase("test_PathA_WithFee_RateChange_Slippage",
            unicode"Path A + fee=100bps + rate=1.2 + slippage 60% -- fee/rate/slippage 三重交叉全路径验证");

        // Enable 1% redemption fee
        vm.prank(admin);
        vault.setRedemptionFee(100);

        // Rate = 1.2
        mockAccountant.setExchangeRate(12e17);

        // 3 users deposit 2400 each at rate 1.2 -> 2000 shares each
        _deposit(userA, 2400e6);
        _deposit(userB, 2400e6);
        _deposit(userC, 2400e6);
        uint256 sharesPerUser = vault.balanceOf(userA);
        assertEq(sharesPerUser, 2000e6, "each has 2000 shares at rate 1.2");

        // Invest all
        _investAll();
        uint256 iid = _lastInFlightId();
        (,,, uint256 posAmt,,,,, ) = vault.inFlightRecords(iid);
        _settleInvest(_arr(iid), _arr(posAmt), _arr(0));
        uint256 vaultUsdcAfterInvest = usdc.balanceOf(address(vault));
        console2.log("vault USDC after invest:", vaultUsdcAfterInvest);

        // Each user requestRedeem(1000 shares) at rate 1.2, fee=1%
        // grossAssets = 1000e6 * 1.2e18 / 1e18 = 1200e6
        // fee = 1200e6 * 100 / 10000 (Ceil) = 12e6
        // treasuryShare = 1000e6 * 100 / 10000 (Ceil) = 10e6
        // netShares = 990e6, estimatedAssets = 1188e6
        vm.prank(userA);
        uint256 reqA = gateway.requestRedeem(1000e6);
        vm.prank(userB);
        uint256 reqB = gateway.requestRedeem(1000e6);
        vm.prank(userC);
        uint256 reqC = gateway.requestRedeem(1000e6);

        // Verify netShares stored correctly
        (,, uint256 sharesA,, uint256 estA,,, ) = vault.requests(reqA);
        uint256 expectedTreasuryShare = Math.mulDiv(1000e6, 100, 10_000, Math.Rounding.Ceil);
        uint256 expectedNetShares = 1000e6 - expectedTreasuryShare;
        assertEq(sharesA, expectedNetShares, "request stores netShares (990)");
        assertEq(vault.totalLockedShares(), expectedNetShares * 3, "totalLockedShares = 3 * netShares");

        // Process at rate 1.2
        // batchTotal = 3 * (990e6 * 1.2e18 / 1e18) = 3 * 1188e6 = 3564e6
        uint256 perReqBatchAsset = Math.mulDiv(expectedNetShares, 12e17, 1e18, Math.Rounding.Floor);
        uint256 batchTotal = perReqBatchAsset * 3;
        uint256 fc = vault.getFreeCash();
        uint256 shortfall = batchTotal > fc ? batchTotal - fc : 0;

        vm.expectEmit(true, false, false, true, address(controller));
        emit StrategyController.RedeemBatchProcessing(3, batchTotal, shortfall);

        uint256[] memory ids = _arr3(reqA, reqB, reqC);
        _processRedeemBatch(ids);
        uint256 redeemIF = vault.totalRedeemInFlight();
        assertGt(redeemIF, 0, "PathA: divest triggered");

        // Settle divest at 60% delivery (slippage)
        uint256 redeemId = _lastInFlightId();
        (,,,, uint256 expectedUsdc,,,, ) = vault.inFlightRecords(redeemId);
        uint256 actualUsdc = expectedUsdc * 60 / 100;
        adapter.simulateRedeemSettlement(actualUsdc);
        _settleRedeem(_arr(redeemId), _arr(actualUsdc));

        // Compute settlement: proportional from totalAvailable
        uint256 totalAvailable = usdc.balanceOf(address(vault));
        console2.log("total USDC available for finalize:", totalAvailable);

        uint256 settledA = estA * totalAvailable / batchTotal;
        uint256 settledB = estA * totalAvailable / batchTotal;
        uint256 settledC = totalAvailable - settledA - settledB;

        uint256 balA = usdc.balanceOf(userA);
        uint256 balB = usdc.balanceOf(userB);
        uint256 balC = usdc.balanceOf(userC);

        vm.expectEmit(true, false, false, true, address(vault));
        emit IMantleYieldVault.RequestSettlementAdjusted(reqA, estA, settledA);
        _finalizeRedeemBatch(ids, _arr3(settledA, settledB, settledC));

        uint256 recvA = usdc.balanceOf(userA) - balA;
        uint256 recvB = usdc.balanceOf(userB) - balB;
        uint256 recvC = usdc.balanceOf(userC) - balC;

        // Key assertions: fee + rate + slippage all visible
        assertLt(recvA, estA, "A received < estimated (slippage)");
        assertEq(recvA + recvB + recvC, totalAvailable, "sum = total available");
        assertEq(vault.totalLockedShares(), 0, "locked cleared");

        // Verify treasury got fee shares from all 3 requests
        assertEq(vault.balanceOf(treasury), expectedTreasuryShare * 3, "treasury got all fee shares");

        // Verify DONE + pendingShares
        (,,,,,,, IMantleYieldVault.RequestStatus sA12) = vault.requests(reqA);
        assertEq(uint8(sA12), uint8(IMantleYieldVault.RequestStatus.DONE), "reqA status DONE");
        assertEq(vault.pendingRedeemRequest(userA), 0, "A pendingShares cleared");
        (,,,,,,, IMantleYieldVault.RequestStatus sB12) = vault.requests(reqB);
        assertEq(uint8(sB12), uint8(IMantleYieldVault.RequestStatus.DONE), "reqB status DONE");
        assertEq(vault.pendingRedeemRequest(userB), 0, "B pendingShares cleared");
        (,,,,,,, IMantleYieldVault.RequestStatus sC12) = vault.requests(reqC);
        assertEq(uint8(sC12), uint8(IMantleYieldVault.RequestStatus.DONE), "reqC status DONE");
        assertEq(vault.pendingRedeemRequest(userC), 0, "C pendingShares cleared");

        _logPass();
    }
}
