// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {IStrategyControllerExecutor} from "../../src/interfaces/strategy/IStrategyControllerExecutor.sol";
import {IStrategyAdapter} from "../../src/interfaces/adapters/IStrategyAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    StressBase,
    MockUSDC_ST,
    MockPosToken_ST,
    MockAsyncAdapter_ST,
    MockConfigSyncAdapter_ST
} from "./StressBase.t.sol";
import {console2} from "forge-std/Test.sol";

/// @title S9: Multi-Adapter Asymmetric Weight Mix
/// @notice Validates rebalance distribution, settlement, and in-flight tracking across 3 adapters
///         with asymmetric weights (40/35/25) and periodic weight + price changes.
contract S9_MultiAdapterMix is StressBase {
    uint256 constant LARGE_DEPOSIT = 200_000e6;

    // Third adapter (deployed in setUp)
    MockConfigSyncAdapter_ST internal s9Sync2;
    MockPosToken_ST internal s9PosToken2;

    function setUp() public override {
        super.setUp();
        if (IS_FORK) return;

        // Deploy third adapter with its own posToken
        s9PosToken2 = new MockPosToken_ST("SyncPos2", "sPOS2");
        s9Sync2 = new MockConfigSyncAdapter_ST(address(usdc), address(s9PosToken2), address(vault));

        vm.startPrank(admin);

        // Register third adapter with temporary 0 weight (won't be in strategyOrder yet)
        controller.registerStrategy(address(s9Sync2), 0, 3, false);
        controller.activateStrategy(address(s9Sync2));

        // Set new 3-adapter order and reweight atomically
        address[] memory adps = new address[](3);
        uint16[] memory ws = new uint16[](3);
        uint16[] memory ps = new uint16[](3);
        bool[] memory asyncs = new bool[](3);
        adps[0] = address(syncAdapter);  ws[0] = 4000; ps[0] = 1; asyncs[0] = false;
        adps[1] = address(asyncAdapter); ws[1] = 3500; ps[1] = 2; asyncs[1] = true;
        adps[2] = address(s9Sync2);      ws[2] = 2500; ps[2] = 3; asyncs[2] = false;

        address[] memory order = new address[](3);
        order[0] = address(syncAdapter);
        order[1] = address(asyncAdapter);
        order[2] = address(s9Sync2);

        controller.updateStrategiesAndOrder(adps, ws, ps, asyncs, order);

        vm.stopPrank();
    }

    function test_multiAdapterMix() external {
        if (IS_FORK) return;

        _logCase("S9_MultiAdapterMix", unicode"多Adapter非对称权重混合压力测试");

        // Initial deposits
        for (uint256 i = 0; i < _min(users.length / 2, 50); i++) {
            _depositAs(users[i], LARGE_DEPOSIT);
        }
        _checkAllInvariants("S9:init");

        for (uint256 round = 0; round < ROUNDS && !_shouldStop(); round++) {
            _logRoundStart(round);

            // ===================== Phase A: Deposits =====================
            _phaseA_deposits(round);

            // ===================== Phase B: Rebalance =====================
            vm.warp(block.timestamp + 3601);
            _rebalance();

            _checkAllInvariants(string.concat("S9:phaseB:", _toStr(round)));

            // ===================== Phase C: Settle Invest =====================
            vm.warp(block.timestamp + 1 days);
            _phaseC_settleInvest(round);

            assertEq(vault.totalInvestInFlight(), 0, string.concat("S9:investIF=0 r:", _toStr(round)));

            // ===================== Phase D: Redeem + Divest + Settle + Finalize =====================
            _phaseD_redeemCycle(round);

            assertEq(vault.totalRedeemInFlight(), 0, string.concat("S9:redeemIF=0 r:", _toStr(round)));

            _checkAllInvariants(string.concat("S9:round:", _toStr(round)));
            _checkUsdcClosedSystem(string.concat("S9:usdc:", _toStr(round)));

            // ===================== Periodic: Price Jitter =====================
            if (round > 0 && round % 10 == 0) {
                _jitterPosTokenPrice();  // async adapter
                _jitterS9Sync2Price();   // sync2 adapter
            }

            // ===================== Periodic: Weight Change =====================
            if (round > 0 && round % 20 == 0) {
                _rotateWeights(round);
            }

            // Rate update
            _periodicRateAndPriceUpdate(round, 5, 5);

            _logRoundEnd(round);
            vm.warp(block.timestamp + 1 hours);
        }

        // Final verification
        assertEq(vault.totalInvestInFlight(), 0, "S9:final investIF=0");
        assertEq(vault.totalRedeemInFlight(), 0, "S9:final redeemIF=0");
        _checkAllInvariants("S9:final");
        _checkUsdcClosedSystem("S9:final:usdc");

        console2.log("[S9] Final totalAssets:", vault.totalAssets());
        console2.log("[S9] sync1 value:", IStrategyAdapter(address(syncAdapter)).totalValue());
        console2.log("[S9] async1 value:", IStrategyAdapter(address(asyncAdapter)).totalValue());
        console2.log("[S9] sync2 value:", IStrategyAdapter(address(s9Sync2)).totalValue());

        _logPass();
    }

    // =========================================================================
    //  Daily Phases
    // =========================================================================

    function _phaseA_deposits(uint256 round) internal {
        uint256 numDepositors = _scaledRand(2, 5, 30);
        for (uint256 i = 0; i < numDepositors; i++) {
            address user = _randUser();
            uint256 bal = usdc.balanceOf(user);
            uint256 amount = _randBetween(10_000e6, _min(50_000e6, bal));
            if (amount >= vault.minDepositAmount() && amount <= bal) {
                _depositAs(user, amount);
            }
        }

        // Top up periodically (scaled with user count)
        if (round % 10 == 0 && round > 0) {
            for (uint256 i = 0; i < _min(users.length / 4, 50); i++) {
                if (usdc.balanceOf(users[i]) < LARGE_DEPOSIT) {
                    MockUSDC_ST(address(usdc)).mint(users[i], LARGE_DEPOSIT);
                    _totalUsdcInjected += LARGE_DEPOSIT;
                }
            }
        }
    }

    function _phaseC_settleInvest(uint256 round) internal {
        // sync1: normal settlement
        _settleInvestForAdapter(address(syncAdapter), 0);

        // sync2: random partial refund (0-30%)
        uint256 sync2Refund = _randBetween(0, 30);
        _settleInvestForAdapter(address(s9Sync2), sync2Refund);

        // async1: normal or partial (0-20%)
        uint256 asyncRefund = _randBool(30) ? _randBetween(5, 20) : 0;
        _settleInvestForAdapter(address(asyncAdapter), asyncRefund);
    }

    function _phaseD_redeemCycle(uint256 round) internal {
        // Request redeems
        uint256 numRedeemers = _scaledRand(1, 5, 20);
        for (uint256 i = 0; i < numRedeemers; i++) {
            address user = _randUser();
            uint256 shares = vault.balanceOf(user);
            uint256 minRedeem = _effectiveMinRedeemShares();
            if (shares >= minRedeem) {
                _requestRedeemAs(user, _randBetween(minRedeem, shares));
            }
        }

        // Process batch (may trigger divest across all 3 adapters)
        uint256[] memory pendingIds = _getRequestIdsByStatus(IMantleYieldVault.RequestStatus.PENDING);
        if (pendingIds.length > 0) {
            pendingIds = _sortIds(pendingIds);
            _processRedeemBatch(pendingIds);
        }

        // Settle all redeem in-flights
        vm.warp(block.timestamp + 2 days);
        _settleRedeemForAdapterNormal(address(syncAdapter));
        _settleRedeemForAdapterNormal(address(s9Sync2));
        _settleRedeemForAdapterAsync(address(asyncAdapter));

        // Finalize
        uint256[] memory processingIds = _getRequestIdsByStatus(IMantleYieldVault.RequestStatus.PROCESSING);
        if (processingIds.length > 0) {
            processingIds = _sortIds(processingIds);
            uint256[] memory settledAssets = new uint256[](processingIds.length);
            uint256 totalNeeded;

            for (uint256 i = 0; i < processingIds.length; i++) {
                (,, uint256 shares,,,,, ) = vault.requests(processingIds[i]);
                uint256 amount = shares * accountant.getRate() / 1e18;
                if (amount == 0) amount = 1;
                settledAssets[i] = amount;
                totalNeeded += amount;
            }

            // Inject shortfall if needed
            uint256 available = usdc.balanceOf(address(vault));
            if (available < totalNeeded) {
                uint256 shortfall = totalNeeded - available;
                MockUSDC_ST(address(usdc)).mint(address(vault), shortfall);
                _totalUsdcInjected += shortfall;
            }

            _finalizeRedeemBatch(processingIds, settledAssets);
        }
    }

    // =========================================================================
    //  Settlement Helpers
    // =========================================================================

    function _settleInvestForAdapter(address adapter, uint256 refundPct) internal {
        uint256 nextIfId = vault.nextInFlightId();

        uint256 count;
        for (uint256 id = _baseInFlightId; id < nextIfId; id++) {
            (, address ifAdapter,,,,, bool isInvest,, IMantleYieldVault.InFlightStatus s) =
                vault.inFlightRecords(id);
            if (s == IMantleYieldVault.InFlightStatus.PENDING && isInvest && ifAdapter == adapter) count++;
        }
        if (count == 0) return;

        uint256[] memory ids = new uint256[](count);
        uint256[] memory settledPos = new uint256[](count);
        uint256[] memory refunds = new uint256[](count);
        uint256 idx;

        for (uint256 id = _baseInFlightId; id < nextIfId; id++) {
            (, address ifAdapter,, uint256 tokenAmt, uint256 usdcAmt,, bool isInvest,, IMantleYieldVault.InFlightStatus s) =
                vault.inFlightRecords(id);
            if (s != IMantleYieldVault.InFlightStatus.PENDING || !isInvest || ifAdapter != adapter) continue;

            ids[idx] = id;
            uint256 refundUsdc = usdcAmt * refundPct / 100;
            uint256 settled = tokenAmt * (100 - refundPct) / 100;
            settledPos[idx] = settled;
            refunds[idx] = refundUsdc;

            // Burn excess posTokens
            uint256 excessPos = tokenAmt - settled;
            if (excessPos > 0) {
                MockPosToken_ST(_posTokenOfAdapter(adapter)).burn(adapter, excessPos);
            }

            // For async adapter: release refunded USDC from protocol hold
            if (adapter == address(asyncAdapter) && refundUsdc > 0) {
                _totalUsdcInjected += MockAsyncAdapter_ST(payable(address(asyncAdapter))).simulateRedeemSettlement(refundUsdc);
            }

            idx++;
        }

        _settleAdapter(
            adapter,
            IStrategyControllerExecutor.InvestSettlementInput({
                inFlightIds: ids,
                settledPosAmounts: settledPos,
                refundAssetAmounts: refunds
            }),
            _emptyRedeemInput()
        );
    }

    function _settleRedeemForAdapterNormal(address adapter) internal {
        uint256 nextIfId = vault.nextInFlightId();

        uint256 count;
        for (uint256 id = _baseInFlightId; id < nextIfId; id++) {
            (, address ifAdapter,,,,, bool isInvest,, IMantleYieldVault.InFlightStatus s) =
                vault.inFlightRecords(id);
            if (s == IMantleYieldVault.InFlightStatus.PENDING && !isInvest && ifAdapter == adapter) count++;
        }
        if (count == 0) return;

        uint256[] memory ids = new uint256[](count);
        uint256[] memory settled = new uint256[](count);
        uint256 idx;

        for (uint256 id = _baseInFlightId; id < nextIfId; id++) {
            (, address ifAdapter,,, uint256 usdcAmt,, bool isInvest,, IMantleYieldVault.InFlightStatus s) =
                vault.inFlightRecords(id);
            if (s != IMantleYieldVault.InFlightStatus.PENDING || isInvest || ifAdapter != adapter) continue;

            ids[idx] = id;
            settled[idx] = usdcAmt;
            idx++;
        }

        _settleAdapter(
            adapter,
            _emptyInvestInput(),
            IStrategyControllerExecutor.RedeemSettlementInput({
                inFlightIds: ids,
                settledAssetAmounts: settled
            })
        );
    }

    function _settleRedeemForAdapterAsync(address adapter) internal {
        uint256 nextIfId = vault.nextInFlightId();

        uint256 count;
        for (uint256 id = _baseInFlightId; id < nextIfId; id++) {
            (, address ifAdapter,,,,, bool isInvest,, IMantleYieldVault.InFlightStatus s) =
                vault.inFlightRecords(id);
            if (s == IMantleYieldVault.InFlightStatus.PENDING && !isInvest && ifAdapter == adapter) count++;
        }
        if (count == 0) return;

        uint256[] memory ids = new uint256[](count);
        uint256[] memory settled = new uint256[](count);
        uint256 idx;

        for (uint256 id = _baseInFlightId; id < nextIfId; id++) {
            (, address ifAdapter,,, uint256 usdcAmt,, bool isInvest,, IMantleYieldVault.InFlightStatus s) =
                vault.inFlightRecords(id);
            if (s != IMantleYieldVault.InFlightStatus.PENDING || isInvest || ifAdapter != adapter) continue;

            ids[idx] = id;
            settled[idx] = usdcAmt;
            idx++;
        }

        // Release USDC from "external protocol" hold
        uint256 totalNeeded;
        for (uint256 j = 0; j < count; j++) totalNeeded += settled[j];
        _totalUsdcInjected += MockAsyncAdapter_ST(payable(address(asyncAdapter))).simulateRedeemSettlement(totalNeeded);

        _settleAdapter(
            adapter,
            _emptyInvestInput(),
            IStrategyControllerExecutor.RedeemSettlementInput({
                inFlightIds: ids,
                settledAssetAmounts: settled
            })
        );
    }

    // =========================================================================
    //  Periodic Actions
    // =========================================================================

    function _jitterS9Sync2Price() internal {
        uint256 currentPrice = s9Sync2.posTokenPrice();
        uint256 delta = currentPrice * _randBetween(1, 500) / 10_000; // ±5%
        uint256 newPrice;
        if (_randBool(50)) {
            newPrice = currentPrice + delta;
        } else {
            newPrice = currentPrice > delta ? currentPrice - delta : currentPrice;
        }
        s9Sync2.setPosTokenPrice(newPrice);
        logDebug("S9:sync2 price", newPrice);
    }

    function _rotateWeights(uint256 round) internal {
        // Cycle through 3 weight configurations
        uint16 w1; uint16 w2; uint16 w3;
        uint256 config = (round / 20) % 3;
        if (config == 0) {
            w1 = 4000; w2 = 3500; w3 = 2500; // 40/35/25
        } else if (config == 1) {
            w1 = 3000; w2 = 3000; w3 = 4000; // 30/30/40
        } else {
            w1 = 5000; w2 = 2000; w3 = 3000; // 50/20/30
        }

        address[] memory adps = new address[](3);
        uint16[] memory ws = new uint16[](3);
        uint16[] memory ps = new uint16[](3);
        bool[] memory asyncs = new bool[](3);

        adps[0] = address(syncAdapter);  ws[0] = w1; ps[0] = 1; asyncs[0] = false;
        adps[1] = address(asyncAdapter); ws[1] = w2; ps[1] = 2; asyncs[1] = true;
        adps[2] = address(s9Sync2);      ws[2] = w3; ps[2] = 3; asyncs[2] = false;

        vm.prank(admin);
        controller.updateStrategies(adps, ws, ps, asyncs);

        logDebug("S9:weights rotated", string.concat(_toStr(w1), "/", _toStr(w2), "/", _toStr(w3)));
    }

    // =========================================================================
    //  Overrides
    // =========================================================================

    /// @dev Override USDC closed-system check to include the third adapter
    function _checkUsdcClosedSystem(string memory ctx) internal view override {
        if (IS_FORK) return;

        uint256 totalInSystem;
        for (uint256 i = 0; i < users.length; i++) {
            totalInSystem += usdc.balanceOf(users[i]);
        }
        totalInSystem += usdc.balanceOf(address(vault));
        totalInSystem += usdc.balanceOf(sanctionSafe);
        totalInSystem += usdc.balanceOf(address(syncAdapter));
        totalInSystem += usdc.balanceOf(address(asyncAdapter));
        totalInSystem += usdc.balanceOf(address(s9Sync2));

        assertEq(totalInSystem, _totalUsdcInjected, string.concat(ctx, " USDC closed system (3-adapter)"));
    }

    // =========================================================================
    //  Helpers
    // =========================================================================

    function _posTokenOfAdapter(address adapter) internal view returns (address) {
        if (adapter == address(syncAdapter)) return address(syncPosToken);
        if (adapter == address(asyncAdapter)) return address(asyncPosToken);
        if (adapter == address(s9Sync2)) return address(s9PosToken2);
        revert("S9: unknown adapter");
    }
}
