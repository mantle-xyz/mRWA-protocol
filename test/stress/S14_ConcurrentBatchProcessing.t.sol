// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {IStrategyControllerExecutor} from "../../src/interfaces/strategy/IStrategyControllerExecutor.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {VaultViewHelper} from "../lib/VaultViewHelper.sol";
import {StressBase} from "./StressBase.t.sol";

/// @title S14: Concurrent Batch Processing
/// @notice Multiple redeem batches in PROCESSING state simultaneously, with interleaved settlement
///         and finalization. Tests that in-flight accounting stays correct under concurrent batches.
contract S14_ConcurrentBatchProcessing is StressBase {
    using VaultViewHelper for MantleYieldVault;
    uint256 constant DEPOSIT_AMOUNT = 100_000e6;

    function test_concurrentBatchProcessing() external {
        _logCase("S14_ConcurrentBatchProcessing", "Concurrent batch processing with interleaved settlement");

        // Seed vault
        for (uint256 i = 0; i < _min(users.length / 2, 50); i++) {
            _depositAs(users[i], DEPOSIT_AMOUNT);
        }

        // Initial rebalance to get funds into adapters
        vm.warp(block.timestamp + 3601);
        _rebalance();
        vm.warp(block.timestamp + 1 days);
        _trySettleAllInFlight();
        _checkAllInvariants("S14:init");

        for (uint256 round = 0; round < ROUNDS && !_shouldStop(); round++) {
            _logRoundStart(round);

            // Phase A: Create two waves of redeem requests
            // Wave 1
            uint256 wave1Count = _scaledRand(2, 4, 20);
            for (uint256 i = 0; i < wave1Count; i++) {
                address user = _randUser();
                uint256 shares = vault.balanceOf(user);
                uint256 minRedeem = _effectiveMinRedeemShares();
                if (shares >= minRedeem) {
                    _requestRedeemAs(user, _randBetween(minRedeem, shares));
                }
            }

            // Process wave 1 as batch
            uint256[] memory pendingIds1 = _getRequestIdsByStatus(IMantleYieldVault.RequestStatus.PENDING);
            if (pendingIds1.length > 0) {
                pendingIds1 = _sortIds(pendingIds1);
                _processRedeemBatch(pendingIds1);
            }

            // Wave 2: top up users then create more requests
            for (uint256 i = 0; i < _min(users.length / 4, 20); i++) {
                address user = users[i];
                if (usdc.balanceOf(user) >= DEPOSIT_AMOUNT / 2) {
                    _depositAs(user, DEPOSIT_AMOUNT / 2);
                }
            }

            uint256 wave2Count = _scaledRand(1, 4, 10);
            for (uint256 i = 0; i < wave2Count; i++) {
                address user = _randUser();
                uint256 shares = vault.balanceOf(user);
                uint256 minRedeem = _effectiveMinRedeemShares();
                if (shares >= minRedeem) {
                    _requestRedeemAs(user, _randBetween(minRedeem, shares));
                }
            }

            // Process wave 2 (now both batches in PROCESSING)
            uint256[] memory pendingIds2 = _getRequestIdsByStatus(IMantleYieldVault.RequestStatus.PENDING);
            if (pendingIds2.length > 0) {
                pendingIds2 = _sortIds(pendingIds2);
                _processRedeemBatch(pendingIds2);
            }

            _checkAllInvariants(string.concat("S14:bothProcessing:", _toStr(round)));

            // Phase B: Settle any in-flight
            vm.warp(block.timestamp + 2 days);
            _trySettleAllInFlight();

            // Phase C: Finalize all PROCESSING requests
            _tryFinalizeProcessing();

            _checkAllInvariants(string.concat("S14:round:", _toStr(round)));
            _checkUsdcClosedSystem(string.concat("S14:usdc:", _toStr(round)));

            _periodicRateAndPriceUpdate(round, 5, 8);
            _logRoundEnd(round);
            vm.warp(block.timestamp + 1 hours);
        }

        // Final: no PROCESSING remaining
        uint256[] memory remaining = _getRequestIdsByStatus(IMantleYieldVault.RequestStatus.PROCESSING);
        assertEq(remaining.length, 0, "S14: no PROCESSING remaining");

        _logPass();
    }

    function _tryFinalizeProcessing() internal {
        uint256[] memory processingIds = _getRequestIdsByStatus(IMantleYieldVault.RequestStatus.PROCESSING);
        if (processingIds.length == 0) return;
        processingIds = _sortIds(processingIds);
        uint256[] memory settledAssets = _computeSettledAssets(processingIds);
        uint256 totalNeeded;
        for (uint256 i = 0; i < settledAssets.length; i++) totalNeeded += settledAssets[i];
        _topUpVaultCashViaDeposits(totalNeeded);
        settledAssets = _computeSettledAssets(processingIds);
        _finalizeRedeemBatch(processingIds, settledAssets);
    }

    function _trySettleAllInFlight() internal {
        _settleInFlightForAdapter(address(realSyncAdapter));
        _settleInFlightForAdapter(address(realAsyncAdapter));
    }

    function _settleInFlightForAdapter(address adapter) internal {
        uint256 nextIfId = vault.nextInFlightId();
        uint256 investCount;
        uint256 redeemCount;
        for (uint256 id = _baseInFlightId; id < nextIfId; id++) {
            (address ifAdapter, bool isInvest, IMantleYieldVault.InFlightStatus ifStatus) =
                vault.ifAdapterAndStatus(id);
            if (ifStatus != IMantleYieldVault.InFlightStatus.PENDING) continue;
            if (ifAdapter != adapter) continue;
            if (isInvest) investCount++;
            else redeemCount++;
        }
        if (investCount == 0 && redeemCount == 0) return;
        _populateAndSettle(adapter, nextIfId, investCount, redeemCount);
    }

    function _populateAndSettle(address adapter, uint256 nextIfId, uint256 investCount, uint256 redeemCount) internal {
        uint256[] memory investIds = new uint256[](investCount);
        uint256[] memory investSettledPos = new uint256[](investCount);
        uint256[] memory investRefunds = new uint256[](investCount);
        uint256[] memory redeemIds = new uint256[](redeemCount);
        uint256[] memory redeemSettled = new uint256[](redeemCount);
        uint256 iIdx;
        uint256 rIdx;

        for (uint256 id = _baseInFlightId; id < nextIfId; id++) {
            (address ifAdapter, bool isInvest, IMantleYieldVault.InFlightStatus ifStatus) =
                vault.ifAdapterAndStatus(id);
            if (ifStatus != IMantleYieldVault.InFlightStatus.PENDING) continue;
            if (ifAdapter != adapter) continue;

            if (isInvest) {
                investIds[iIdx] = id;
                (uint256 tokenAmt, uint256 usdcAmt) = vault.ifTokenAndUsdc(id);
                investSettledPos[iIdx] = tokenAmt > 0 ? tokenAmt : usdcAmt;
                investRefunds[iIdx] = 0;
                iIdx++;
            } else {
                redeemIds[rIdx] = id;
                redeemSettled[rIdx] = vault.ifUsdcAmount(id);
                rIdx++;
            }
        }

        if (adapter == address(realAsyncAdapter) && investCount > 0) {
            uint256 totalPos;
            for (uint256 i = 0; i < investCount; i++) totalPos += investSettledPos[i];
            vm.prank(admin);
            mockSubRed.settleSubscribe(address(realAsyncAdapter), address(stToken), address(realAsyncAdapter), totalPos);
        }

        if (adapter == address(realAsyncAdapter) && redeemCount > 0) {
            uint256 totalNeeded;
            for (uint256 i = 0; i < redeemCount; i++) totalNeeded += redeemSettled[i];
            uint256 subRedBal = usdc.balanceOf(address(mockSubRed));
            if (totalNeeded > subRedBal) {
                totalNeeded = subRedBal;
                uint256 perRedeem = redeemCount > 0 ? totalNeeded / redeemCount : 0;
                for (uint256 i = 0; i < redeemCount; i++) redeemSettled[i] = perRedeem;
            }
            if (totalNeeded > 0) {
                vm.prank(admin);
                mockSubRed.settleRedeem(
                    address(realAsyncAdapter), address(stToken), address(usdc), address(realAsyncAdapter), totalNeeded
                );
            }
        }

        IStrategyControllerExecutor.InvestSettlementInput memory investInput = investCount > 0
            ? IStrategyControllerExecutor.InvestSettlementInput({
                inFlightIds: investIds,
                settledPosAmounts: investSettledPos,
                refundAssetAmounts: investRefunds
            })
            : _emptyInvestInput();

        IStrategyControllerExecutor.RedeemSettlementInput memory redeemInput = redeemCount > 0
            ? IStrategyControllerExecutor.RedeemSettlementInput({
                inFlightIds: redeemIds,
                settledAssetAmounts: redeemSettled
            })
            : _emptyRedeemInput();

        _settleAdapter(adapter, investInput, redeemInput);
    }
}
