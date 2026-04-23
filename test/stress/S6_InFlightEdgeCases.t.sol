// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {IStrategyControllerExecutor} from "../../src/interfaces/strategy/IStrategyControllerExecutor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {VaultViewHelper} from "../lib/VaultViewHelper.sol";
import {StressBase, MockUSDC_ST, MockPosToken_ST} from "./StressBase.t.sol";
import {console2} from "forge-std/Test.sol";

/// @title S6: In-Flight Edge Cases Stress
/// @notice Validates in-flight records under abnormal settlement: refund, partial, zero, retry
contract S6_InFlightEdgeCases is StressBase {
    using VaultViewHelper for MantleYieldVault;
    uint256 constant LARGE_DEPOSIT = 200_000e6;

    function test_inFlightEdgeCases() external {
        // Only local mode — needs adapter control
        if (IS_FORK) return;

        _logCase("S6_InFlightEdgeCases", unicode"在途记录边界场景压力测试");

        // Heavy deposit to generate rebalance
        for (uint256 i = 0; i < _min(users.length / 2, 50); i++) {
            _depositAs(users[i], LARGE_DEPOSIT);
        }
        _checkAllInvariants("S6:init");

        for (uint256 round = 0; round < ROUNDS && !_shouldStop(); round++) {
            _logRoundStart(round);

            uint256 caseChoice = round % 6;

            if (caseChoice == 0) {
                _caseA_normalInFlight(round);
            } else if (caseChoice == 1) {
                _caseB_investRefund(round);
            } else if (caseChoice == 2) {
                _caseC_redeemPartialSettlement(round);
            } else if (caseChoice == 3) {
                _caseD_redeemZeroSettlement(round);
            } else if (caseChoice == 4) {
                _caseE_inflightMixed(round);
            } else {
                _caseF_retryAsyncRedeem(round);
            }

            _checkAllInvariants(string.concat("S6:round:", _toStr(round)));
            _checkUsdcClosedSystem(string.concat("S6:usdc:", _toStr(round)));

            // Periodic rate & price update
            _periodicRateAndPriceUpdate(round, 3, 4);

            _logRoundEnd(round);

            vm.warp(block.timestamp + 1 hours);
        }

        // Final cleanup: Cases A/B only settle invest, so redeem IFs from prior
        // rounds may linger.  Sweep any outstanding invest and redeem in-flights
        // before the final assertions.
        if (vault.totalInvestInFlight() > 0) {
            vm.warp(block.timestamp + 1 days);
            _settleInvestNormal();
        }
        if (vault.totalRedeemInFlight() > 0) {
            vm.warp(block.timestamp + 2 days);
            _settleRedeemNormal();
        }
        _finalizeAllProcessing();

        // Final: no ghost in-flight records
        assertEq(vault.totalInvestInFlight(), 0, "S6:final investIF == 0");
        assertEq(vault.totalRedeemInFlight(), 0, "S6:final redeemIF == 0");

        _logPass();
    }

    /// Case A: Normal invest in-flight → normal settle
    function _caseA_normalInFlight(uint256 round) internal {
        _ensureFreeCash(50_000e6);

        vm.warp(block.timestamp + 3601);
        _rebalance();

        uint256 investIF = vault.totalInvestInFlight();
        if (investIF > 0) {
            vm.warp(block.timestamp + 1 days);
            _settleInvestNormal();
            assertEq(vault.totalInvestInFlight(), 0, string.concat("S6:A investIF=0 r:", _toStr(round)));
        }
    }

    /// Case B: Invest with partial refund
    function _caseB_investRefund(uint256 round) internal {
        _ensureFreeCash(80_000e6);

        vm.warp(block.timestamp + 3601);
        _rebalance();

        uint256 investIF = vault.totalInvestInFlight();
        if (investIF > 0) {
            vm.warp(block.timestamp + 1 days);
            _settleInvestWithRefund();
            assertEq(vault.totalInvestInFlight(), 0, string.concat("S6:B investIF=0 r:", _toStr(round)));
        }
    }

    /// Case C: Redeem in-flight with partial settlement (strategy loss)
    function _caseC_redeemPartialSettlement(uint256 round) internal {
        _triggerDivest();

        uint256 redeemIF = vault.totalRedeemInFlight();
        if (redeemIF > 0) {
            vm.warp(block.timestamp + 2 days);
            _settleRedeemPartial();
            assertEq(vault.totalRedeemInFlight(), 0, string.concat("S6:C redeemIF=0 r:", _toStr(round)));
        }

        _finalizeAllProcessing();
    }

    /// Case D: Redeem in-flight with zero settlement (total loss)
    function _caseD_redeemZeroSettlement(uint256 round) internal {
        _triggerDivest();

        uint256 redeemIF = vault.totalRedeemInFlight();
        if (redeemIF > 0) {
            vm.warp(block.timestamp + 2 days);
            _settleRedeemZero();
            assertEq(vault.totalRedeemInFlight(), 0, string.concat("S6:D redeemIF=0 r:", _toStr(round)));
        }

        _finalizeAllProcessing();
    }

    /// Case E: Mixed in-flight states coexist with normal operations
    function _caseE_inflightMixed(uint256 round) internal {
        // Create invest in-flight
        _ensureFreeCash(100_000e6);
        vm.warp(block.timestamp + 3601);
        _rebalance();

        // While invest is pending, do scaled sync operations
        uint256 numSyncOps = _scaledRand(1, 5, 20);
        for (uint256 j = 0; j < numSyncOps; j++) {
            address user = _randUser();
            uint256 shares = vault.balanceOf(user);
            uint256 freeCash = vault.getFreeCash();
            if (shares >= vault.minRedeemAmount()) {
                uint256 expectedAssets = gateway.previewRedeem(shares / 4);
                if (expectedAssets <= freeCash && shares / 4 >= vault.minRedeemAmount()) {
                    _redeemAs(user, shares / 4);
                }
            }
        }

        // Multiple users deposit (scaled)
        uint256 numDepositors = _scaledRand(1, 5, 20);
        for (uint256 j = 0; j < numDepositors; j++) {
            address depositor = _randUser();
            uint256 bal = usdc.balanceOf(depositor);
            if (bal >= 10_000e6) {
                _depositAs(depositor, _randBetween(10_000e6, _min(50_000e6, bal)));
            }
        }

        // Now settle invest
        vm.warp(block.timestamp + 1 days);
        _settleInvestNormal();

        // Create a requestRedeem to trigger divest
        _triggerDivest();

        // Settle redeem
        vm.warp(block.timestamp + 1 days);
        _settleRedeemNormal();

        _finalizeAllProcessing();
    }

    // =========================================================================
    // Case F: Retry async redeem in-flight
    // =========================================================================

    /// Case F: Async redeem retry path — triggerDivest → find PENDING redeem in-flight → retry → settle → finalize
    function _caseF_retryAsyncRedeem(uint256 round) internal {
        _triggerDivest();

        // Find async adapter PENDING redeem in-flight records
        uint256 nextIfId = vault.nextInFlightId();
        uint256 targetId;
        uint256 targetTokenAmt;
        bool found;
        for (uint256 id = _baseInFlightId; id < nextIfId; id++) {
            (, address ifAdapter,, uint256 tokenAmt,,, bool isInvest,, IMantleYieldVault.InFlightStatus ifStatus) =
                vault.inFlightRecords(id);
            if (
                ifStatus == IMantleYieldVault.InFlightStatus.PENDING && !isInvest
                    && ifAdapter == address(asyncAdapter)
            ) {
                targetId = id;
                targetTokenAmt = tokenAmt;
                found = true;
                break;
            }
        }

        if (found && targetTokenAmt > 0) {
            // Retry with partial amount (50-100% of original)
            uint256 retryAmt = targetTokenAmt * _randBetween(50, 100) / 100;
            if (retryAmt == 0) retryAmt = 1;
            if (retryAmt > targetTokenAmt) retryAmt = targetTokenAmt;

            vm.prank(admin);
            controller.retryRedeemInFlight(address(asyncAdapter), targetId, retryAmt);
            logDebug("retryRedeemInFlight", string.concat("id=", _toStr(targetId), " amt=", _toStr(retryAmt)));
        }

        // Settle redeem normally
        vm.warp(block.timestamp + 1 days);
        _settleRedeemNormal();

        _finalizeAllProcessing();

        assertEq(vault.totalRedeemInFlight(), 0, string.concat("S6:F redeemIF=0 r:", _toStr(round)));
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _ensureFreeCash(uint256 target) internal {
        uint256 current = vault.getFreeCash();
        if (current < target) {
            address user = users[0];
            uint256 needed = target - current + 10_000e6;
            uint256 bal = usdc.balanceOf(user);
            if (bal < needed) {
                MockUSDC_ST(address(usdc)).mint(user, needed);
                _totalUsdcInjected += needed;
            }
            _depositAs(user, needed);
        }
    }

    function _triggerDivest() internal {
        // Rebalance first to invest excess
        vm.warp(block.timestamp + 3601);
        _rebalance();

        // Settle invest so strategies hold funds
        vm.warp(block.timestamp + 1 days);
        _settleInvestNormal();
        vm.warp(block.timestamp + 3601);

        // Now requestRedeem from multiple users (scaled) to trigger divest
        uint256 numRedeemers = _scaledRand(1, 10, 20);
        for (uint256 j = 0; j < numRedeemers; j++) {
            address user = _randUser();
            uint256 shares = vault.balanceOf(user);
            uint256 minRedeem = _effectiveMinRedeemShares();
            if (shares >= minRedeem) {
                _requestRedeemAs(user, shares);
            }
        }

        uint256[] memory pendingIds = _getRequestIdsByStatus(IMantleYieldVault.RequestStatus.PENDING);
        if (pendingIds.length > 0) {
            pendingIds = _sortIds(pendingIds);
            _processRedeemBatch(pendingIds);
        }
    }

    function _settleInvestNormal() internal {
        _settleInvestWithParams(false, 0);
    }

    function _settleInvestWithRefund() internal {
        _settleInvestWithParams(true, 10); // 10% refund
    }

    function _settleInvestWithParams(bool withRefund, uint256 refundPct) internal {
        _settleInvestForAdapterWithParams(address(syncAdapter), withRefund, refundPct);
        _settleInvestForAdapterWithParams(address(asyncAdapter), withRefund, refundPct);
    }

    function _settleInvestForAdapterWithParams(address adapter, bool withRefund, uint256 refundPct) internal {
        uint256 nextIfId = vault.nextInFlightId();

        // First pass: count matching records
        uint256 count;
        for (uint256 id = _baseInFlightId; id < nextIfId; id++) {
            (address ifAdapter, bool isInvest, IMantleYieldVault.InFlightStatus ifStatus) =
                vault.ifAdapterAndStatus(id);
            if (ifStatus == IMantleYieldVault.InFlightStatus.PENDING && isInvest && ifAdapter == adapter) count++;
        }
        if (count == 0) return;

        _populateAndSettleInvest(adapter, nextIfId, count, withRefund, refundPct);
    }

    function _populateAndSettleInvest(
        address adapter, uint256 nextIfId, uint256 count, bool withRefund, uint256 refundPct
    ) internal {
        uint256[] memory ids = new uint256[](count);
        uint256[] memory settledPos = new uint256[](count);
        uint256[] memory refunds = new uint256[](count);
        uint256 idx;

        for (uint256 id = _baseInFlightId; id < nextIfId; id++) {
            (address ifAdapter, bool isInvest, IMantleYieldVault.InFlightStatus ifStatus) =
                vault.ifAdapterAndStatus(id);
            if (ifStatus != IMantleYieldVault.InFlightStatus.PENDING || !isInvest || ifAdapter != adapter) continue;

            ids[idx] = id;
            _fillInvestEntry(adapter, id, idx, settledPos, refunds, withRefund, refundPct);
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

    function _fillInvestEntry(
        address adapter, uint256 id, uint256 idx,
        uint256[] memory settledPos, uint256[] memory refunds,
        bool withRefund, uint256 refundPct
    ) internal {
        (uint256 tokenAmt, uint256 usdcAmt) = vault.ifTokenAndUsdc(id);
        uint256 expected = tokenAmt > 0 ? tokenAmt : usdcAmt;
        if (withRefund) {
            uint256 refundAmt = expected * refundPct / 100;
            settledPos[idx] = expected - refundAmt;
            refunds[idx] = refundAmt;
            if (adapter == address(asyncAdapter)) {
                _totalUsdcInjected += asyncAdapter.simulateRedeemSettlement(refundAmt);
            } else {
                MockPosToken_ST(syncAdapter.POS_TOKEN()).burn(adapter, refundAmt);
            }
        } else {
            settledPos[idx] = expected;
            refunds[idx] = 0;
        }
    }

    function _settleRedeemNormal() internal {
        _settleRedeemWithMultiplier(100); // 100% = normal
    }

    function _settleRedeemPartial() internal {
        _settleRedeemWithMultiplier(_randBetween(30, 80)); // 30-80% = partial
    }

    function _settleRedeemZero() internal {
        _settleRedeemWithMultiplier(0); // 0% = total loss
    }

    function _settleRedeemWithMultiplier(uint256 pct) internal {
        _settleRedeemForAdapterWithMul(address(syncAdapter), pct);
        _settleRedeemForAdapterWithMul(address(asyncAdapter), pct);
    }

    function _settleRedeemForAdapterWithMul(address adapter, uint256 pct) internal {
        uint256 nextIfId = vault.nextInFlightId();

        // First pass: count matching records
        uint256 count;
        for (uint256 id = _baseInFlightId; id < nextIfId; id++) {
            (, address ifAdapter,,,,, bool isInvest,, IMantleYieldVault.InFlightStatus ifStatus) =
                vault.inFlightRecords(id);
            if (ifStatus == IMantleYieldVault.InFlightStatus.PENDING && !isInvest && ifAdapter == adapter) count++;
        }
        if (count == 0) return;

        // Second pass: populate correctly-sized arrays
        uint256[] memory ids = new uint256[](count);
        uint256[] memory settled = new uint256[](count);
        uint256 idx;

        for (uint256 id = _baseInFlightId; id < nextIfId; id++) {
            (, address ifAdapter,,, uint256 usdcAmt,, bool isInvest,, IMantleYieldVault.InFlightStatus ifStatus) =
                vault.inFlightRecords(id);
            if (ifStatus != IMantleYieldVault.InFlightStatus.PENDING || isInvest) continue;
            if (ifAdapter != adapter) continue;

            ids[idx] = id;
            settled[idx] = usdcAmt * pct / 100;
            idx++;
        }

        // For async adapter: release USDC from "external protocol" hold before settlement sweep
        if (adapter == address(asyncAdapter)) {
            uint256 totalNeeded;
            for (uint256 j = 0; j < count; j++) totalNeeded += settled[j];
            _totalUsdcInjected += asyncAdapter.simulateRedeemSettlement(totalNeeded);
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

    function _finalizeAllProcessing() internal {
        uint256[] memory processingIds = _getRequestIdsByStatus(IMantleYieldVault.RequestStatus.PROCESSING);
        if (processingIds.length == 0) return;

        processingIds = _sortIds(processingIds);

        uint256[] memory settledAssets = new uint256[](processingIds.length);
        uint256 totalNeeded;

        for (uint256 i = 0; i < processingIds.length; i++) {
            uint256 shares = vault.reqShares(processingIds[i]);
            uint256 amount = shares * accountant.getRate() / 1e18;
            if (amount == 0) amount = 1; // avoid zero — still clears PROCESSING state
            settledAssets[i] = amount;
            totalNeeded += amount;
        }

        // Ensure vault has enough cash (inject shortfall like S2 does)
        uint256 available = usdc.balanceOf(address(vault));
        if (available < totalNeeded) {
            uint256 shortfall = totalNeeded - available;
            MockUSDC_ST(address(usdc)).mint(address(vault), shortfall);
            _totalUsdcInjected += shortfall;
        }

        _finalizeRedeemBatch(processingIds, settledAssets);
    }

    function _trim(uint256[] memory arr, uint256 len) internal pure returns (uint256[] memory) {
        uint256[] memory result = new uint256[](len);
        for (uint256 i = 0; i < len; i++) result[i] = arr[i];
        return result;
    }
}
