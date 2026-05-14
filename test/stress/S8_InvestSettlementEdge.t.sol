// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {IStrategyControllerExecutor} from "../../src/interfaces/strategy/IStrategyControllerExecutor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {VaultViewHelper} from "../lib/VaultViewHelper.sol";
import {StressBase} from "./StressBase.t.sol";
import {console2} from "forge-std/Test.sol";

/// @title S8: Invest Settlement Edge Cases
/// @notice Validates partial invest settlement (5-95% refund) and full refund (underlying asset
///         rejection) scenarios, ensuring vault asset conservation and in-flight record integrity.
contract S8_InvestSettlementEdge is StressBase {
    using VaultViewHelper for MantleYieldVault;
    uint256 constant LARGE_DEPOSIT = 200_000e6;

    function test_investSettlementEdge() external {
        // Only local mode — needs adapter control
        if (IS_FORK) return;

        _logCase("S8_InvestSettlementEdge", unicode"Invest结算边界场景压力测试");

        // Heavy deposits to generate investable cash
        for (uint256 i = 0; i < _min(users.length / 2, 50); i++) {
            _depositAs(users[i], LARGE_DEPOSIT);
        }
        _checkAllInvariants("S8:init");

        for (uint256 round = 0; round < ROUNDS && !_shouldStop(); round++) {
            _logRoundStart(round);

            // Ensure enough freeCash for rebalance to trigger invest
            _ensureFreeCash(100_000e6);

            // Trigger rebalance → invest
            vm.warp(block.timestamp + 3601);
            _rebalance();

            // Settle with varying refund percentages
            uint256 caseChoice = round % 5;
            if (caseChoice == 0) {
                _caseA_normalSettle(round);
            } else if (caseChoice == 1) {
                _caseB_smallRefund(round);
            } else if (caseChoice == 2) {
                _caseC_largeRefund(round);
            } else if (caseChoice == 3) {
                _caseD_fullRefund(round);
            } else {
                _caseE_mixedRefund(round);
            }

            assertEq(vault.totalInvestInFlight(), 0, string.concat("S8:investIF=0 r:", _toStr(round)));
            _checkAllInvariants(string.concat("S8:round:", _toStr(round)));
            _checkUsdcClosedSystem(string.concat("S8:usdc:", _toStr(round)));

            // Periodic rate & price update
            _periodicRateAndPriceUpdate(round, 3, 4);

            _logRoundEnd(round);
            vm.warp(block.timestamp + 1 hours);
        }

        // Final
        assertEq(vault.totalInvestInFlight(), 0, "S8:final investIF=0");
        assertEq(vault.totalRedeemInFlight(), 0, "S8:final redeemIF=0");

        _logPass();
    }

    // =========================================================================
    //  Cases
    // =========================================================================

    /// Case A: Normal full settlement (0% refund) — baseline
    function _caseA_normalSettle(uint256 round) internal {
        _settleInvestWithRefundPctForAdapter(address(realSyncAdapter), 0);
        _settleInvestWithRefundPctForAdapter(address(realAsyncAdapter), 0);
    }

    /// Case B: Small refund (5-15%) — slippage / fees (async only; sync 4626 deposits are atomic)
    function _caseB_smallRefund(uint256 round) internal {
        _settleInvestWithRefundPctForAdapter(address(realSyncAdapter), 0);
        uint256 pct = _randBetween(5, 15);
        _settleInvestWithRefundPctForAdapter(address(realAsyncAdapter), pct);
    }

    /// Case C: Large refund (40-70%) — liquidity shortage (async only)
    function _caseC_largeRefund(uint256 round) internal {
        _settleInvestWithRefundPctForAdapter(address(realSyncAdapter), 0);
        uint256 pct = _randBetween(40, 70);
        _settleInvestWithRefundPctForAdapter(address(realAsyncAdapter), pct);
    }

    /// Case D: Full refund (100%) — underlying asset rejects subscription entirely (async only)
    function _caseD_fullRefund(uint256 round) internal {
        _settleInvestWithRefundPctForAdapter(address(realSyncAdapter), 0);
        _settleInvestWithRefundPctForAdapter(address(realAsyncAdapter), 100);
    }

    /// Case E: Mixed — each async in-flight record gets a random refund percentage
    function _caseE_mixedRefund(uint256 round) internal {
        _settleInvestWithRefundPctForAdapter(address(realSyncAdapter), 0);
        _settleInvestMixedForAdapter(address(realAsyncAdapter));
    }

    // =========================================================================
    //  Settlement Helpers
    // =========================================================================

    /// @dev Settle all PENDING invest in-flights for `adapter` with a uniform refund percentage.
    function _settleInvestWithRefundPctForAdapter(address adapter, uint256 refundPct) internal {
        uint256 nextIfId = vault.nextInFlightId();

        // Count matching records
        uint256 count;
        for (uint256 id = _baseInFlightId; id < nextIfId; id++) {
            (address ifAdapter, bool isInvest, IMantleYieldVault.InFlightStatus s) =
                vault.ifAdapterAndStatus(id);
            if (s == IMantleYieldVault.InFlightStatus.PENDING && isInvest && ifAdapter == adapter) count++;
        }
        if (count == 0) return;

        _buildAndSettleUniformRefund(adapter, nextIfId, count, refundPct);
    }

    function _buildAndSettleUniformRefund(address adapter, uint256 nextIfId, uint256 count, uint256 refundPct) internal {
        uint256[] memory ids = new uint256[](count);
        uint256[] memory settledPos = new uint256[](count);
        uint256[] memory refunds = new uint256[](count);
        uint256 idx;

        for (uint256 id = _baseInFlightId; id < nextIfId; id++) {
            (address ifAdapter, bool isInvest, IMantleYieldVault.InFlightStatus s) =
                vault.ifAdapterAndStatus(id);
            if (s != IMantleYieldVault.InFlightStatus.PENDING || !isInvest || ifAdapter != adapter) continue;

            ids[idx] = id;
            _computeRefundEntry(adapter, id, idx, refundPct, settledPos, refunds);
            idx++;
        }

        _preSettleInvest(adapter, settledPos, refunds, count);

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

    /// @dev Compute settled/refund for a single invest entry (pure math, no side effects)
    function _computeRefundEntry(
        address, uint256 id, uint256 idx, uint256 refundPct,
        uint256[] memory settledPos, uint256[] memory refunds
    ) internal view {
        (uint256 tokenAmt, uint256 usdcAmt) = vault.ifTokenAndUsdc(id);
        uint256 refundUsdc = usdcAmt * refundPct / 100;
        uint256 settled = tokenAmt * (100 - refundPct) / 100;
        settledPos[idx] = settled;
        refunds[idx] = refundUsdc;
    }

    /// @dev Settle each PENDING invest in-flight for `adapter` with a random refund percentage.
    function _settleInvestMixedForAdapter(address adapter) internal {
        uint256 nextIfId = vault.nextInFlightId();

        // Count matching records
        uint256 count;
        for (uint256 id = _baseInFlightId; id < nextIfId; id++) {
            (address ifAdapter, bool isInvest, IMantleYieldVault.InFlightStatus s) =
                vault.ifAdapterAndStatus(id);
            if (s == IMantleYieldVault.InFlightStatus.PENDING && isInvest && ifAdapter == adapter) count++;
        }
        if (count == 0) return;

        _buildAndSettleMixedRefund(adapter, nextIfId, count);
    }

    function _buildAndSettleMixedRefund(address adapter, uint256 nextIfId, uint256 count) internal {
        uint256[] memory ids = new uint256[](count);
        uint256[] memory settledPos = new uint256[](count);
        uint256[] memory refundsArr = new uint256[](count);
        uint256 idx;

        for (uint256 id = _baseInFlightId; id < nextIfId; id++) {
            (address ifAdapter, bool isInvest, IMantleYieldVault.InFlightStatus s) =
                vault.ifAdapterAndStatus(id);
            if (s != IMantleYieldVault.InFlightStatus.PENDING || !isInvest || ifAdapter != adapter) continue;

            ids[idx] = id;
            uint256 refundPct = _pickRandomRefundPct();
            _computeRefundEntry(adapter, id, idx, refundPct, settledPos, refundsArr);
            idx++;
        }

        _preSettleInvest(adapter, settledPos, refundsArr, count);

        _settleAdapter(
            adapter,
            IStrategyControllerExecutor.InvestSettlementInput({
                inFlightIds: ids,
                settledPosAmounts: settledPos,
                refundAssetAmounts: refundsArr
            }),
            _emptyRedeemInput()
        );
    }

    function _pickRandomRefundPct() internal returns (uint256) {
        uint256 pctChoices = _rand(6);
        if (pctChoices == 0) return 0;
        if (pctChoices == 1) return 10;
        if (pctChoices == 2) return 30;
        if (pctChoices == 3) return 50;
        if (pctChoices == 4) return 80;
        return 100;
    }

    // =========================================================================
    //  Helpers
    // =========================================================================

    /// @dev Deposit enough to guarantee rebalance will invest at least `target` USDC
    ///      into adapters.  We deposit `target + buffer` so that after the reserve
    ///      buffer is satisfied, the remainder flows to adapters.
    function _ensureFreeCash(uint256 target) internal {
        address user = users[0];
        uint256 deposit = target + 50_000e6; // overshoot so rebalance has room to invest
        uint256 bal = usdc.balanceOf(user);
        if (bal < deposit) {
            _mintUsdc(user, deposit);
        }
        _depositAs(user, deposit);
    }

    /// @dev Pre-settle invest for real adapters: mint ST (async) or handle 4626 (sync),
    ///      and provide refund USDC on adapter when needed.
    function _preSettleInvest(
        address adapter, uint256[] memory settledPos, uint256[] memory refunds, uint256 count
    ) internal {
        if (adapter == address(realAsyncAdapter)) {
            uint256 totalPos;
            uint256 totalRefund;
            for (uint256 i = 0; i < count; i++) {
                totalPos += settledPos[i];
                totalRefund += refunds[i];
            }
            // Settle subscribe: mint ST to adapter
            if (totalPos > 0) {
                vm.prank(admin);
                mockSubRed.settleSubscribe(
                    address(realAsyncAdapter), address(stToken), address(realAsyncAdapter), totalPos
                );
            }
            // Provide refund USDC on adapter (transfer from mockSubRed, not settleRedeem which requires pending redeem)
            if (totalRefund > 0) {
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
        // Sync adapter: ERC4626 shares and USDC are already on adapter from deposit/redeem flows
    }
}
