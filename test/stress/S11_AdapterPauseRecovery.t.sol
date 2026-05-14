// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {IStrategyControllerExecutor} from "../../src/interfaces/strategy/IStrategyControllerExecutor.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {VaultViewHelper} from "../lib/VaultViewHelper.sol";
import {StressBase} from "./StressBase.t.sol";

contract S11_AdapterPauseRecovery is StressBase {
    using VaultViewHelper for MantleYieldVault;
    uint256 constant DEPOSIT_AMOUNT = 100_000e6;

    function test_adapterPauseRecovery() external {
        _logCase("S11_AdapterPauseRecovery", "Adapter pause and recovery during operations");

        // Phase 0: Seed deposits
        for (uint256 i = 0; i < _min(users.length / 2, 50); i++) {
            _depositAs(users[i], DEPOSIT_AMOUNT);
        }

        // Phase 1: Normal rebalance (invest into adapters)
        vm.warp(block.timestamp + 3601);
        _rebalance();
        _checkAllInvariants("S11:afterRebalance");

        // Phase 2: Settle invest
        vm.warp(block.timestamp + 1 days);
        _trySettleAllInFlight();
        _checkAllInvariants("S11:afterSettle");

        for (uint256 round = 0; round < ROUNDS && !_shouldStop(); round++) {
            _logRoundStart(round);

            // Phase A: Pause sync adapter mid-cycle
            if (round % 3 == 0) {
                vm.prank(pauser);
                controller.setAdapterPaused(address(realSyncAdapter), true);
                logInfo("[PAUSE] realSyncAdapter paused");
            }

            // Phase B: Attempt rebalance (should skip paused adapter)
            vm.warp(block.timestamp + 3601);
            _rebalance();

            // Phase C: Some user deposits and redeems
            uint256 numOps = _scaledRand(1, 4, 20);
            for (uint256 i = 0; i < numOps; i++) {
                address user = _randUser();
                if (_randBool(60) && usdc.balanceOf(user) >= DEPOSIT_AMOUNT / 10) {
                    _depositAs(user, _randBetween(vault.minDepositAmount(), DEPOSIT_AMOUNT / 10));
                } else {
                    uint256 shares = vault.balanceOf(user);
                    uint256 minRedeem = _effectiveMinRedeemShares();
                    uint256 maxRedeem = vault.maxRedeem(user);
                    if (shares >= minRedeem && maxRedeem >= minRedeem) {
                        uint256 redeemAmt = _randBetween(minRedeem, _min(shares, maxRedeem));
                        if (redeemAmt >= minRedeem) {
                            _redeemAs(user, redeemAmt);
                        }
                    }
                }
            }

            // Phase D: Unpause after 2 rounds
            if (round % 3 == 2) {
                vm.prank(pauser);
                controller.setAdapterPaused(address(realSyncAdapter), false);
                logInfo("[UNPAUSE] realSyncAdapter unpaused");
            }

            _checkAllInvariants(string.concat("S11:round:", _toStr(round)));
            _checkUsdcClosedSystem(string.concat("S11:round:", _toStr(round)));

            // Periodic rate update
            _periodicRateAndPriceUpdate(round, 5, 8);
            _logRoundEnd(round);
            vm.warp(block.timestamp + 1 hours);
        }

        _logPass();
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

        // Settle async adapter invest via mockSubRed
        if (adapter == address(realAsyncAdapter) && investCount > 0) {
            uint256 totalPos;
            for (uint256 i = 0; i < investCount; i++) totalPos += investSettledPos[i];
            vm.prank(admin);
            mockSubRed.settleSubscribe(address(realAsyncAdapter), address(stToken), address(realAsyncAdapter), totalPos);
        }

        // Settle async adapter redeem via mockSubRed (bounded by available balance)
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
