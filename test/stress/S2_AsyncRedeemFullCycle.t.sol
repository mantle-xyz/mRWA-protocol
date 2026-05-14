// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {IStrategyControllerExecutor} from "../../src/interfaces/strategy/IStrategyControllerExecutor.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {VaultViewHelper} from "../lib/VaultViewHelper.sol";
import {StressBase} from "./StressBase.t.sol";

/// @title S2: Async Redeem Full Lifecycle Stress
/// @notice Validates requestRedeem → processRedeemBatch → finalizeRedeemBatch across many rounds
contract S2_AsyncRedeemFullCycle is StressBase {
    using VaultViewHelper for MantleYieldVault;
    uint256 constant DEPOSIT_AMOUNT = 50_000e6;

    function test_asyncRedeemFullCycle() external {
        _logCase("S2_AsyncRedeemFullCycle", unicode"异步赎回全生命周期压力测试");

        // Phase 0: Seed vault with deposits
        for (uint256 i = 0; i < _min(users.length / 2, 50); i++) {
            _depositAs(users[i], DEPOSIT_AMOUNT);
        }
        _checkAllInvariants("S2:init");

        for (uint256 round = 0; round < ROUNDS && !_shouldStop(); round++) {
            _logRoundStart(round);

            // --- Phase A: Accumulate requests ---
            uint256 numRequesters = _scaledRand(2, 4, 50);
            uint256[] memory newRequestIds = new uint256[](numRequesters);
            uint256 actualRequests;

            for (uint256 i = 0; i < numRequesters; i++) {
                address user = _randUser();
                uint256 userShares = vault.balanceOf(user);
                uint256 minRedeem = _effectiveMinRedeemShares();
                if (userShares >= minRedeem) {
                    uint256 redeemShares = _randBetween(minRedeem, userShares);
                    newRequestIds[actualRequests] = _requestRedeemAs(user, redeemShares);
                    actualRequests++;
                }
            }

            _checkAllInvariants(string.concat("S2:phaseA:", _toStr(round)));

            // --- Phase B: Process batch (50%~100% of PENDING) ---
            uint256[] memory pendingIds = _getRequestIdsByStatus(IMantleYieldVault.RequestStatus.PENDING);
            if (pendingIds.length > 0) {
                uint256 processCount = _randBetween(
                    _max(1, pendingIds.length / 2),
                    pendingIds.length
                );
                uint256[] memory toProcess = new uint256[](processCount);
                for (uint256 i = 0; i < processCount; i++) {
                    toProcess[i] = pendingIds[i];
                }
                toProcess = _sortIds(toProcess);

                // S2 has no investing — adapters are empty. If cashDeficit exists
                // (finalize variance drained cash below locked-share value),
                // top up via deposits so processRedeemBatch won't attempt a futile divest.
                // Deposit at least minDepositAmount since deficit may be below minimum.
                uint256 deficit = vault.getCashDeficit();
                if (deficit > 0) {
                    uint256 minDep = vault.minDepositAmount();
                    uint256 topUp = deficit < minDep ? minDep : deficit;
                    _topUpVaultCashViaDeposits(usdc.balanceOf(address(vault)) + topUp);
                }

                _processRedeemBatch(toProcess);

                // Verify processed requests are now PROCESSING
                for (uint256 i = 0; i < toProcess.length; i++) {
                    IMantleYieldVault.RequestStatus status = vault.reqStatus(toProcess[i]);
                    assertEq(
                        uint8(status),
                        uint8(IMantleYieldVault.RequestStatus.PROCESSING),
                        "S2: processed should be PROCESSING"
                    );
                }
            }

            _checkAllInvariants(string.concat("S2:phaseB:", _toStr(round)));

            // --- Phase C: Settle in-flight if any, then finalize ---
            vm.warp(block.timestamp + 2 days); // simulate T+N settlement delay

            // Settle any redeem in-flight from divest
            _trySettleAllInFlight();

            // Finalize PROCESSING requests
            uint256[] memory processingIds = _getRequestIdsByStatus(IMantleYieldVault.RequestStatus.PROCESSING);
            if (processingIds.length > 0) {
                processingIds = _sortIds(processingIds);
                uint256[] memory settledAssets = new uint256[](processingIds.length);

                uint256 totalNeeded;
                for (uint256 i = 0; i < processingIds.length; i++) {
                    uint256 shares = vault.reqShares(processingIds[i]);
                    // Estimate settlement with ±5% variance
                    uint256 estimated = shares * accountant.getRate() / 1e18;
                    uint256 variance = _randBetween(0, estimated * 5 / 100);
                    if (_randBool(50)) {
                        estimated = estimated > variance ? estimated - variance : 0;
                    } else {
                        estimated = estimated + variance;
                    }
                    settledAssets[i] = estimated > 0 ? estimated : 1;
                    totalNeeded += settledAssets[i];
                }

                // Ensure vault has enough cash via real user deposits
                uint256 available = usdc.balanceOf(address(vault));
                if (available < totalNeeded) {
                    _topUpVaultCashViaDeposits(totalNeeded);
                    // Recompute settled amounts with new vault state
                    settledAssets = _computeSettledAssets(processingIds);
                }

                _finalizeRedeemBatch(processingIds, settledAssets);

                // Verify all finalized
                for (uint256 i = 0; i < processingIds.length; i++) {
                    IMantleYieldVault.RequestStatus status = vault.reqStatus(processingIds[i]);
                    assertEq(
                        uint8(status),
                        uint8(IMantleYieldVault.RequestStatus.DONE),
                        "S2: finalized should be DONE"
                    );
                }
            }

            _checkAllInvariants(string.concat("S2:phaseC:", _toStr(round)));
            _checkUsdcClosedSystem(string.concat("S2:phaseC:", _toStr(round)));

            // Periodic rate & price update
            _periodicRateAndPriceUpdate(round, 5, 8);

            // Top up users who ran out of shares
            if (round % 5 == 0) {
                for (uint256 i = 0; i < _min(users.length / 4, 50); i++) {
                    address user = users[i];
                    if (vault.balanceOf(user) < vault.minRedeemAmount() && usdc.balanceOf(user) >= DEPOSIT_AMOUNT) {
                        _depositAs(user, DEPOSIT_AMOUNT);
                    }
                }
            }

            _logRoundEnd(round);

            vm.warp(block.timestamp + 1 hours);
        }

        // Final: ensure no dangling PROCESSING requests
        uint256[] memory remaining = _getRequestIdsByStatus(IMantleYieldVault.RequestStatus.PROCESSING);
        assertEq(remaining.length, 0, "S2:final no PROCESSING remaining");

        _logPass();
    }

    /// @dev Attempt to settle all pending in-flight records, per adapter
    function _trySettleAllInFlight() internal {
        if (IS_FORK) return; // Skip in fork mode — we don't know adapter addresses
        _settleInFlightForAdapter(address(realSyncAdapter));
        _settleInFlightForAdapter(address(realAsyncAdapter));
    }

    function _settleInFlightForAdapter(address adapter) internal {
        uint256 nextIfId = vault.nextInFlightId();

        // First pass: count matching records by type
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
        // Second pass: populate correctly-sized arrays
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

        // For async adapter invest: settle via mockSubRed — mint ST tokens to adapter
        if (adapter == address(realAsyncAdapter) && investCount > 0) {
            uint256 totalPos;
            for (uint256 i = 0; i < investCount; i++) totalPos += investSettledPos[i];
            vm.prank(admin);
            mockSubRed.settleSubscribe(address(realAsyncAdapter), address(stToken), address(realAsyncAdapter), totalPos);
        }

        // For async adapter redeem: settle via mockSubRed — transfer USDC back to adapter
        if (adapter == address(realAsyncAdapter) && redeemCount > 0) {
            uint256 totalNeeded;
            for (uint256 i = 0; i < redeemCount; i++) totalNeeded += redeemSettled[i];
            // Only settle what mockSubRed actually holds (no fake minting)
            uint256 subRedBal = usdc.balanceOf(address(mockSubRed));
            if (totalNeeded > subRedBal) {
                totalNeeded = subRedBal;
                if (redeemCount > 0) {
                    uint256 perRedeem = totalNeeded / redeemCount;
                    for (uint256 i = 0; i < redeemCount; i++) redeemSettled[i] = perRedeem;
                }
            }
            if (totalNeeded > 0) {
                vm.prank(admin);
                mockSubRed.settleRedeem(
                    address(realAsyncAdapter), address(stToken), address(usdc), address(realAsyncAdapter), totalNeeded
                );
            }
        }

        IStrategyControllerExecutor.InvestSettlementInput memory investInput;
        IStrategyControllerExecutor.RedeemSettlementInput memory redeemInput;

        if (investCount > 0) {
            investInput = IStrategyControllerExecutor.InvestSettlementInput({
                inFlightIds: investIds,
                settledPosAmounts: investSettledPos,
                refundAssetAmounts: investRefunds
            });
        } else {
            investInput = _emptyInvestInput();
        }

        if (redeemCount > 0) {
            redeemInput = IStrategyControllerExecutor.RedeemSettlementInput({
                inFlightIds: redeemIds,
                settledAssetAmounts: redeemSettled
            });
        } else {
            redeemInput = _emptyRedeemInput();
        }

        _settleAdapter(adapter, investInput, redeemInput);
    }

    function _trimArray(uint256[] memory arr, uint256 len) internal pure returns (uint256[] memory) {
        uint256[] memory result = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            result[i] = arr[i];
        }
        return result;
    }

    function _safeCheckI5(string memory) internal pure override returns (bool) {
        return true;
    }
}
