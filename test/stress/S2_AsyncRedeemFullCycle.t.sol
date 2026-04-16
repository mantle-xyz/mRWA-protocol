// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {IStrategyControllerExecutor} from "../../src/interfaces/strategy/IStrategyControllerExecutor.sol";
import {StressBase, MockUSDC_ST} from "./StressBase.t.sol";

/// @title S2: Async Redeem Full Lifecycle Stress
/// @notice Validates requestRedeem → processRedeemBatch → finalizeRedeemBatch across many rounds
contract S2_AsyncRedeemFullCycle is StressBase {
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

                _processRedeemBatch(toProcess);

                // Verify processed requests are now PROCESSING
                for (uint256 i = 0; i < toProcess.length; i++) {
                    (,,,,,,,IMantleYieldVault.RequestStatus status) = vault.requests(toProcess[i]);
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
                    (,, uint256 shares,,,,, ) = vault.requests(processingIds[i]);
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

                // Ensure vault has enough cash (inject shortfall if needed)
                uint256 available = usdc.balanceOf(address(vault));
                if (available < totalNeeded) {
                    uint256 shortfall = totalNeeded - available;
                    MockUSDC_ST(address(usdc)).mint(address(vault), shortfall);
                    _totalUsdcInjected += shortfall;
                }

                _finalizeRedeemBatch(processingIds, settledAssets);

                // Verify all finalized
                for (uint256 i = 0; i < processingIds.length; i++) {
                    (,,,,,,,IMantleYieldVault.RequestStatus status) = vault.requests(processingIds[i]);
                    assertEq(
                        uint8(status),
                        uint8(IMantleYieldVault.RequestStatus.DONE),
                        "S2: finalized should be DONE"
                    );
                }
            }

            _checkAllInvariants(string.concat("S2:phaseC:", _toStr(round)));

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
        _settleInFlightForAdapter(address(syncAdapter));
        _settleInFlightForAdapter(address(asyncAdapter));
    }

    function _settleInFlightForAdapter(address adapter) internal {
        uint256 nextIfId = vault.nextInFlightId();

        // First pass: count matching records by type
        uint256 investCount;
        uint256 redeemCount;
        for (uint256 id = _baseInFlightId; id < nextIfId; id++) {
            (, address ifAdapter,,,,, bool isInvest,, IMantleYieldVault.InFlightStatus ifStatus) =
                vault.inFlightRecords(id);
            if (ifStatus != IMantleYieldVault.InFlightStatus.PENDING) continue;
            if (ifAdapter != adapter) continue;
            if (isInvest) investCount++;
            else redeemCount++;
        }

        if (investCount == 0 && redeemCount == 0) return;

        // Second pass: populate correctly-sized arrays
        uint256[] memory investIds = new uint256[](investCount);
        uint256[] memory investSettledPos = new uint256[](investCount);
        uint256[] memory investRefunds = new uint256[](investCount);
        uint256[] memory redeemIds = new uint256[](redeemCount);
        uint256[] memory redeemSettled = new uint256[](redeemCount);
        uint256 iIdx;
        uint256 rIdx;

        for (uint256 id = _baseInFlightId; id < nextIfId; id++) {
            (,address ifAdapter,,uint256 tokenAmt, uint256 usdcAmt,,bool isInvest,,IMantleYieldVault.InFlightStatus ifStatus) =
                vault.inFlightRecords(id);
            if (ifStatus != IMantleYieldVault.InFlightStatus.PENDING) continue;
            if (ifAdapter != adapter) continue;

            if (isInvest) {
                investIds[iIdx] = id;
                investSettledPos[iIdx] = tokenAmt > 0 ? tokenAmt : usdcAmt;
                investRefunds[iIdx] = 0;
                iIdx++;
            } else {
                redeemIds[rIdx] = id;
                redeemSettled[rIdx] = usdcAmt;
                rIdx++;
            }
        }

        // For async adapter redeem: release USDC from "external protocol" hold
        if (adapter == address(asyncAdapter) && redeemCount > 0) {
            uint256 totalNeeded;
            for (uint256 i = 0; i < redeemCount; i++) totalNeeded += redeemSettled[i];
            _totalUsdcInjected += asyncAdapter.simulateRedeemSettlement(totalNeeded);
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
}
