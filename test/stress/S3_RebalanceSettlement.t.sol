// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {IStrategyControllerExecutor} from "../../src/interfaces/strategy/IStrategyControllerExecutor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StressBase} from "./StressBase.t.sol";

/// @title S3: Rebalance + Settlement Cycle Stress
/// @notice Validates repeated invest/divest and settlement, checking asset conservation and strategy weights
contract S3_RebalanceSettlement is StressBase {
    uint256 constant LARGE_DEPOSIT = 100_000e6;

    function test_rebalanceSettlementCycle() external {
        // Only run in local mode — we need adapter control
        if (IS_FORK) return;

        _logCase("S3_RebalanceSettlement", unicode"再平衡与结算周期压力测试");

        // Phase 0: Large deposits to give vault ample freeCash
        for (uint256 i = 0; i < _min(users.length / 2, 50); i++) {
            _depositAs(users[i], LARGE_DEPOSIT);
        }
        _checkAllInvariants("S3:init");

        for (uint256 round = 0; round < ROUNDS && !_shouldStop(); round++) {
            _logRoundStart(round);

            // --- Phase A: Inject funds + invest ---
            // 2~3 users deposit to push freeCash above target+threshold
            uint256 numDepositors = _scaledRand(2, 5, 30);
            for (uint256 i = 0; i < numDepositors; i++) {
                address user = _randUser();
                uint256 bal = usdc.balanceOf(user);
                if (bal >= 10_000e6) {
                    _depositAs(user, _randBetween(10_000e6, _min(50_000e6, bal)));
                }
            }

            // Respect rebalance cooldown
            vm.warp(block.timestamp + 3601);

            uint256 investIFBefore = vault.totalInvestInFlight();
            uint256 vaultCashBefore = usdc.balanceOf(address(vault));

            // Trigger rebalance → should invest excess to strategies
            _rebalance();

            uint256 investIFAfter = vault.totalInvestInFlight();
            // investIF should have increased if there was excess cash
            if (vaultCashBefore > 0 && investIFAfter > investIFBefore) {
                // Vault cash should have decreased
                assertLe(
                    usdc.balanceOf(address(vault)),
                    vaultCashBefore,
                    "S3: vault cash should decrease after invest"
                );
            }

            _checkAllInvariants(string.concat("S3:phaseA:", _toStr(round)));

            // --- Phase B: Settle invest in-flight ---
            vm.warp(block.timestamp + 1 days);

            _settleAllInvestInFlight();

            // After settling, totalInvestInFlight should be 0
            assertEq(vault.totalInvestInFlight(), 0, "S3: investIF should be 0 after settle");

            _checkAllInvariants(string.concat("S3:phaseB:", _toStr(round)));

            // --- Phase C: Trigger divest via requestRedeem ---
            uint256 numRedeemers = _scaledRand(1, 5, 30);
            for (uint256 i = 0; i < numRedeemers; i++) {
                address user = _randUser();
                uint256 userShares = vault.balanceOf(user);
                uint256 minRedeem = _effectiveMinRedeemShares();
                if (userShares >= minRedeem) {
                    _requestRedeemAs(user, _randBetween(minRedeem, userShares));
                }
            }

            // Process batch — may trigger divest if freeCash insufficient
            uint256[] memory pendingIds = _getRequestIdsByStatus(IMantleYieldVault.RequestStatus.PENDING);
            if (pendingIds.length > 0) {
                pendingIds = _sortIds(pendingIds);
                _processRedeemBatch(pendingIds);
            }

            _checkAllInvariants(string.concat("S3:phaseC:", _toStr(round)));

            // --- Phase D: Settle redeem in-flight + finalize ---
            vm.warp(block.timestamp + 2 days);

            _settleAllRedeemInFlight();

            assertEq(vault.totalRedeemInFlight(), 0, "S3: redeemIF should be 0 after settle");

            // Finalize processing requests
            uint256[] memory processingIds = _getRequestIdsByStatus(IMantleYieldVault.RequestStatus.PROCESSING);
            if (processingIds.length > 0) {
                processingIds = _sortIds(processingIds);
                uint256[] memory settledAssets = new uint256[](processingIds.length);
                for (uint256 i = 0; i < processingIds.length; i++) {
                    (,, uint256 shares,,,,, ) = vault.requests(processingIds[i]);
                    settledAssets[i] = _min(
                        shares * accountant.getRate() / 1e18,
                        usdc.balanceOf(address(vault))
                    );
                }
                _finalizeRedeemBatch(processingIds, settledAssets);
            }

            _checkAllInvariants(string.concat("S3:phaseD:", _toStr(round)));
            _checkUsdcClosedSystem(string.concat("S3:usdc:", _toStr(round)));

            // Periodic rate & price update
            _periodicRateAndPriceUpdate(round, 5, 5);

            // Top up users periodically
            if (round % 10 == 0) {
                for (uint256 i = 0; i < _min(users.length / 4, 50); i++) {
                    address user = users[i];
                    if (usdc.balanceOf(user) < LARGE_DEPOSIT) {
                        _mintUsdc(user, LARGE_DEPOSIT);
                    }
                }
            }

            _logRoundEnd(round);
        }

        // Final: no ghost in-flight records
        assertEq(vault.totalInvestInFlight(), 0, "S3:final no invest IF");
        assertEq(vault.totalRedeemInFlight(), 0, "S3:final no redeem IF");

        _logPass();
    }

    // --- Settlement helpers ---

    function _settleAllInvestInFlight() internal {
        _settleInvestForAdapter(address(realSyncAdapter));
        _settleInvestForAdapter(address(realAsyncAdapter));
    }

    function _settleInvestForAdapter(address adapter) internal {
        uint256 nextIfId = vault.nextInFlightId();

        // First pass: count matching records
        uint256 count;
        for (uint256 id = _baseInFlightId; id < nextIfId; id++) {
            (, address ifAdapter,,,,, bool isInvest,, IMantleYieldVault.InFlightStatus ifStatus) =
                vault.inFlightRecords(id);
            if (ifStatus == IMantleYieldVault.InFlightStatus.PENDING && isInvest && ifAdapter == adapter) count++;
        }
        if (count == 0) return;

        // Second pass: populate correctly-sized arrays
        uint256[] memory ids = new uint256[](count);
        uint256[] memory settledPos = new uint256[](count);
        uint256[] memory refunds = new uint256[](count);
        uint256 idx;

        for (uint256 id = _baseInFlightId; id < nextIfId; id++) {
            (, address ifAdapter,,uint256 tokenAmt, uint256 usdcAmt,, bool isInvest,, IMantleYieldVault.InFlightStatus ifStatus) =
                vault.inFlightRecords(id);
            if (ifStatus != IMantleYieldVault.InFlightStatus.PENDING || !isInvest) continue;
            if (ifAdapter != adapter) continue;

            ids[idx] = id;
            uint256 expected = tokenAmt > 0 ? tokenAmt : usdcAmt;
            uint256 variance = expected * _randBetween(0, 3) / 100;
            if (_randBool(70)) {
                settledPos[idx] = expected;
            } else {
                settledPos[idx] = expected > variance ? expected - variance : expected;
            }
            refunds[idx] = 0;
            idx++;
        }

        // For async adapter: settle subscribe via mockSubRed — mint ST tokens to adapter
        if (adapter == address(realAsyncAdapter)) {
            uint256 totalPos;
            for (uint256 i = 0; i < count; i++) totalPos += settledPos[i];
            vm.prank(admin);
            mockSubRed.settleSubscribe(address(realAsyncAdapter), address(stToken), address(realAsyncAdapter), totalPos);
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

    function _settleAllRedeemInFlight() internal {
        _settleRedeemForAdapter(address(realSyncAdapter));
        _settleRedeemForAdapter(address(realAsyncAdapter));
    }

    function _settleRedeemForAdapter(address adapter) internal {
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
            settled[idx] = usdcAmt;
            idx++;
        }

        // For async adapter: settle redeem via mockSubRed — transfer USDC back to adapter
        if (adapter == address(realAsyncAdapter)) {
            uint256 totalNeeded;
            for (uint256 j = 0; j < count; j++) totalNeeded += settled[j];
            uint256 subRedBal = usdc.balanceOf(address(mockSubRed));
            if (totalNeeded > subRedBal) {
                totalNeeded = subRedBal;
                if (count > 0) {
                    uint256 perRedeem = totalNeeded / count;
                    for (uint256 j = 0; j < count; j++) settled[j] = perRedeem;
                }
            }
            if (totalNeeded > 0) {
                vm.prank(admin);
                mockSubRed.settleRedeem(
                    address(realAsyncAdapter), address(stToken), address(usdc), address(realAsyncAdapter), totalNeeded
                );
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

    function _trim(uint256[] memory arr, uint256 len) internal pure returns (uint256[] memory) {
        uint256[] memory result = new uint256[](len);
        for (uint256 i = 0; i < len; i++) result[i] = arr[i];
        return result;
    }
}
