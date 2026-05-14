// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {IStrategyControllerExecutor} from "../../src/interfaces/strategy/IStrategyControllerExecutor.sol";
import {IStrategyAdapter} from "../../src/interfaces/adapters/IStrategyAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {VaultViewHelper} from "../lib/VaultViewHelper.sol";
import {StressBase} from "./StressBase.t.sol";
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
                    && ifAdapter == address(realAsyncAdapter)
            ) {
                targetId = id;
                targetTokenAmt = tokenAmt;
                found = true;
                break;
            }
        }

        if (found && targetTokenAmt > 0) {
            // Real bot checks adapter has stToken balance before retrying
            uint256 adapterStBal = stToken.balanceOf(address(realAsyncAdapter));
            if (adapterStBal > 0) {
                uint256 retryAmt = targetTokenAmt * _randBetween(50, 100) / 100;
                if (retryAmt == 0) retryAmt = 1;
                if (retryAmt > adapterStBal) retryAmt = adapterStBal;
                if (retryAmt > targetTokenAmt) retryAmt = targetTokenAmt;

                vm.prank(admin);
                controller.retryRedeemInFlight(address(realAsyncAdapter), targetId, retryAmt);
                logDebug("retryRedeemInFlight", string.concat("id=", _toStr(targetId), " amt=", _toStr(retryAmt)));
            }
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
                _mintUsdc(user, needed);
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

        // Request redeem from multiple users — use partial shares (20-50%)
        // to keep demand within adapter capacity (real bot would do the same)
        uint256 numRedeemers = _scaledRand(1, 10, 20);
        for (uint256 j = 0; j < numRedeemers; j++) {
            address user = _randUser();
            uint256 shares = vault.balanceOf(user);
            uint256 minRedeem = _effectiveMinRedeemShares();
            if (shares >= minRedeem) {
                uint256 redeemShares = shares * _randBetween(20, 50) / 100;
                if (redeemShares < minRedeem) redeemShares = minRedeem;
                _requestRedeemAs(user, redeemShares);
            }
        }

        uint256[] memory pendingIds = _getRequestIdsByStatus(IMantleYieldVault.RequestStatus.PENDING);
        if (pendingIds.length == 0) return;
        pendingIds = _sortIds(pendingIds);

        // Estimate batch demand and check against available capacity
        uint256 rate = accountant.getRate();
        uint256 batchDemand;
        for (uint256 i = 0; i < pendingIds.length; i++) {
            uint256 sh = vault.reqShares(pendingIds[i]);
            batchDemand += sh * rate / 1e18;
        }
        uint256 available = vault.getFreeCash()
            + IStrategyAdapter(address(realSyncAdapter)).totalValue()
            + IStrategyAdapter(address(realAsyncAdapter)).totalValue();

        if (batchDemand > available) {
            // Trim batch to fit within capacity
            uint256[] memory trimmed = new uint256[](pendingIds.length);
            uint256 runningDemand;
            uint256 kept;
            for (uint256 i = 0; i < pendingIds.length; i++) {
                uint256 sh = vault.reqShares(pendingIds[i]);
                uint256 assetNeeded = sh * rate / 1e18;
                if (runningDemand + assetNeeded <= available) {
                    trimmed[kept] = pendingIds[i];
                    runningDemand += assetNeeded;
                    kept++;
                }
            }
            if (kept == 0) return;
            pendingIds = _trim(trimmed, kept);
        }

        _processRedeemBatch(pendingIds);
    }

    function _settleInvestNormal() internal {
        _settleInvestWithParams(false, 0);
    }

    function _settleInvestWithRefund() internal {
        _settleInvestWithParams(true, 10); // 10% refund
    }

    function _settleInvestWithParams(bool withRefund, uint256 refundPct) internal {
        // Sync 4626 deposits are atomic — no partial refund concept
        _settleInvestForAdapterWithParams(address(realSyncAdapter), false, 0);
        _settleInvestForAdapterWithParams(address(realAsyncAdapter), withRefund, refundPct);
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

        // For async adapter: settle subscribe (mint ST) + provide refund USDC on adapter
        if (adapter == address(realAsyncAdapter)) {
            uint256 totalPos;
            uint256 totalRefund;
            for (uint256 i = 0; i < count; i++) {
                totalPos += settledPos[i];
                totalRefund += refunds[i];
            }
            if (totalPos > 0) {
                vm.prank(admin);
                mockSubRed.settleSubscribe(
                    address(realAsyncAdapter), address(stToken), address(realAsyncAdapter), totalPos
                );
            }
            if (totalRefund > 0) {
                // Invest refund: USDC comes back from SubRed to adapter via direct transfer
                // (not settleRedeem — that requires a pending redeem, but this is invest refund)
                uint256 subRedBal = usdc.balanceOf(address(mockSubRed));
                if (totalRefund > subRedBal) {
                    totalRefund = subRedBal;
                    if (count > 0) {
                        uint256 perRefund = totalRefund / count;
                        for (uint256 i = 0; i < count; i++) refunds[i] = perRefund;
                    }
                }
                if (totalRefund > 0) {
                    vm.prank(address(mockSubRed));
                    usdc.transfer(address(realAsyncAdapter), totalRefund);
                }
            }
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
        uint256 posExpected = tokenAmt > 0 ? tokenAmt : usdcAmt;
        if (withRefund) {
            // settledPos in position-token units, refunds in USDC
            settledPos[idx] = posExpected * (100 - refundPct) / 100;
            refunds[idx] = usdcAmt * refundPct / 100;
        } else {
            settledPos[idx] = posExpected;
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
        _settleRedeemForAdapterWithMul(address(realSyncAdapter), pct);
        _settleRedeemForAdapterWithMul(address(realAsyncAdapter), pct);
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

        // For async adapter: settle redeem via mockSubRed — transfer USDC back to adapter
        if (adapter == address(realAsyncAdapter)) {
            uint256 totalNeeded;
            for (uint256 j = 0; j < count; j++) totalNeeded += settled[j];
            if (totalNeeded > 0) {
                uint256 subRedBal = usdc.balanceOf(address(mockSubRed));
                if (totalNeeded > subRedBal) {
                    totalNeeded = subRedBal;
                    if (count > 0) {
                        uint256 perRedeem = totalNeeded / count;
                        for (uint256 j = 0; j < count; j++) settled[j] = perRedeem;
                    }
                }
                if (totalNeeded > 0) {
                    (, uint256 redeemPos) = mockSubRed.pending(address(realAsyncAdapter), address(stToken));
                    if (redeemPos > 0) {
                        vm.prank(admin);
                        mockSubRed.settleRedeem(
                            address(realAsyncAdapter), address(stToken), address(usdc), address(realAsyncAdapter), totalNeeded
                        );
                    } else {
                        vm.prank(address(mockSubRed));
                        usdc.transfer(address(realAsyncAdapter), totalNeeded);
                    }
                }
            }
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

        // Ensure vault has enough cash via real user deposits
        uint256 available = usdc.balanceOf(address(vault));
        if (available < totalNeeded) {
            _topUpVaultCashViaDeposits(totalNeeded);
            // Recompute settled amounts with new vault state
            settledAssets = _computeSettledAssets(processingIds);
        }

        _finalizeRedeemBatch(processingIds, settledAssets);
    }

    function _trim(uint256[] memory arr, uint256 len) internal pure returns (uint256[] memory) {
        uint256[] memory result = new uint256[](len);
        for (uint256 i = 0; i < len; i++) result[i] = arr[i];
        return result;
    }
}
