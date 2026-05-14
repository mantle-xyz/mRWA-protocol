// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {IStrategyControllerExecutor} from "../../src/interfaces/strategy/IStrategyControllerExecutor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {VaultViewHelper} from "../lib/VaultViewHelper.sol";
import {StressBase} from "./StressBase.t.sol";
import {console2} from "forge-std/Test.sol";

/// @title S10: Interleaved Operations Stress
/// @notice Validates protocol correctness when operations overlap in dirty states:
///         - G1: Invest + Redeem in-flights coexist simultaneously
///         - G2: Exchange rate changes between processRedeemBatch and finalizeRedeemBatch
///         - G3: Two PROCESSING batches overlap with out-of-order finalization
///         - G4: Deposits occur while a batch is PROCESSING
///         - G5: Sync redeems occur while a batch is PROCESSING (freeCash constrained)
///         - G6: Rebalance fires while PENDING/PROCESSING requests exist
///         - G7: Kitchen-sink combining G1-G6 in a multi-day simulation
///
/// Unlike S1-S9 which clean all state per round, S10 deliberately operates in dirty states.
contract S10_InterleavedOperations is StressBase {
    using VaultViewHelper for MantleYieldVault;
    uint256 constant LARGE_DEPOSIT = 200_000e6;

    /// @dev Saved batch IDs for overlapping batch tests
    uint256[] private _batch1Ids;
    uint256[] private _batch2Ids;

    function test_interleavedOperations() external {
        if (IS_FORK) return;

        _logCase("S10_InterleavedOperations", unicode"操作交错压力测试");

        // Initial deposits to build capital
        for (uint256 i = 0; i < _min(users.length / 2, 50); i++) {
            _depositAs(users[i], LARGE_DEPOSIT);
        }
        _checkAllInvariants("S10:init");

        for (uint256 round = 0; round < ROUNDS && !_shouldStop(); round++) {
            _logRoundStart(round);

            uint256 caseChoice = round % 7;

            if (caseChoice == 0) {
                _caseA_dualInFlight(round);
            } else if (caseChoice == 1) {
                _caseB_rateChangeMidBatch(round);
            } else if (caseChoice == 2) {
                _caseC_overlappingBatches(round);
            } else if (caseChoice == 3) {
                _caseD_depositDuringProcessing(round);
            } else if (caseChoice == 4) {
                _caseE_syncRedeemDuringProcessing(round);
            } else if (caseChoice == 5) {
                _caseF_rebalanceWithPendingRequests(round);
            } else {
                _caseG_kitchenSink(round);
            }

            // Validate invariants in potentially dirty state
            _checkAllInvariants(string.concat("S10:round:", _toStr(round)));
            _checkUsdcClosedSystem(string.concat("S10:usdc:", _toStr(round)));

            _periodicRateAndPriceUpdate(round, 7, 5);

            // Top up users periodically
            if (round > 0 && round % 7 == 0) {
                _topUpUsers();
            }

            _logRoundEnd(round);
            vm.warp(block.timestamp + 1 hours);
        }

        // Final cleanup: resolve ALL outstanding state
        _cleanupAll();

        assertEq(vault.totalInvestInFlight(), 0, "S10:final investIF=0");
        assertEq(vault.totalRedeemInFlight(), 0, "S10:final redeemIF=0");

        uint256[] memory residualProcessing =
            _getRequestIdsByStatus(IMantleYieldVault.RequestStatus.PROCESSING);
        assertEq(residualProcessing.length, 0, "S10:final no PROCESSING");

        _checkAllInvariants("S10:final");
        _checkUsdcClosedSystem("S10:final:usdc");

        console2.log("[S10] Final totalAssets:", vault.totalAssets());
        console2.log("[S10] Final lockedShares:", vault.totalLockedShares());

        _logPass();
    }

    // =========================================================================
    //  Case A: Dual In-Flight — invest IF + redeem IF coexist (G1)
    // =========================================================================

    function _caseA_dualInFlight(uint256 round) internal {
        logInfo("[CASE_A] dualInFlight start");

        // 1. Ensure enough freeCash to trigger invest on rebalance
        _ensureFreeCash(100_000e6);

        // 2. Rebalance -> creates invest in-flights
        vm.warp(block.timestamp + 3601);
        _rebalance();

        uint256 investIFAfterRebalance = vault.totalInvestInFlight();
        // If rebalance didn't invest (freeCash within threshold), seed adapters manually
        if (investIFAfterRebalance == 0) {
            _settleAllInvest(); // no-op if nothing pending
            logInfo("[CASE_A] rebalance did not invest, settling and continuing");
        }

        // 3. While invest IF may be pending, create requestRedeems
        uint256 numRedeemers = _scaledRand(2, 5, 15);
        for (uint256 i = 0; i < numRedeemers; i++) {
            address user = _randUser();
            uint256 shares = vault.balanceOf(user);
            uint256 minRedeem = _effectiveMinRedeemShares();
            if (shares >= minRedeem) {
                _requestRedeemAs(user, _randBetween(minRedeem, shares));
            }
        }

        // 4. Process batch -> may trigger divest -> creates redeem IF
        uint256[] memory pendingIds = _getRequestIdsByStatus(IMantleYieldVault.RequestStatus.PENDING);
        if (pendingIds.length > 0) {
            pendingIds = _sortIds(pendingIds);
            _processRedeemBatch(pendingIds);
        }

        // 5. KEY ASSERTION: both IFs may coexist
        uint256 investIF = vault.totalInvestInFlight();
        uint256 redeemIF = vault.totalRedeemInFlight();
        if (investIF > 0 && redeemIF > 0) {
            logInfo(string.concat(
                "[CASE_A] DUAL IF: investIF=", _toStr(investIF),
                " redeemIF=", _toStr(redeemIF)
            ));
        }

        // 6. Validate invariants in dual-IF state
        _checkAllInvariants(string.concat("S10:A:dualIF:", _toStr(round)));

        // 7. Cleanup: settle invest first, then redeem, then finalize
        vm.warp(block.timestamp + 1 days);
        _settleAllInvest();

        // After invest settle, redeemIF may still be > 0
        _checkAllInvariants(string.concat("S10:A:postInvestSettle:", _toStr(round)));

        vm.warp(block.timestamp + 1 days);
        _settleAllRedeem();
        _finalizeAllProcessing();
    }

    // =========================================================================
    //  Case B: Rate Change Between Process and Finalize (G2, G8)
    // =========================================================================

    function _caseB_rateChangeMidBatch(uint256 round) internal {
        logInfo("[CASE_B] rateChangeMidBatch start");

        // 1. Ensure adapter has value so divest works
        _ensureAdapterHasValue();

        // 2. Request redeems
        uint256 numRedeemers = _scaledRand(2, 5, 15);
        for (uint256 i = 0; i < numRedeemers; i++) {
            address user = _randUser();
            uint256 shares = vault.balanceOf(user);
            uint256 minRedeem = _effectiveMinRedeemShares();
            if (shares >= minRedeem) {
                _requestRedeemAs(user, _randBetween(minRedeem, shares));
            }
        }

        // 3. Process batch
        uint256[] memory pendingIds = _getRequestIdsByStatus(IMantleYieldVault.RequestStatus.PENDING);
        if (pendingIds.length == 0) return;
        pendingIds = _sortIds(pendingIds);
        _processRedeemBatch(pendingIds);

        uint256 rateBefore = accountant.getRate();

        // 4. CRITICAL: Change rate while batch is PROCESSING
        _jitterExchangeRate();
        uint256 rateAfter = accountant.getRate();
        logInfo(string.concat(
            "[CASE_B] rate changed during PROCESSING: before=", _toStr(rateBefore),
            " after=", _toStr(rateAfter)
        ));

        // 5. Also jitter price while PROCESSING
        if (!IS_FORK) {
            _jitterPosTokenPrice();
        }

        // 6. Validate invariants AFTER rate change, BEFORE finalize
        _checkAllInvariants(string.concat("S10:B:midRateChange:", _toStr(round)));

        // 7. Settle and finalize (using current rate for settledAssets)
        vm.warp(block.timestamp + 2 days);
        _settleAllRedeem();
        _finalizeAllProcessing();
    }

    // =========================================================================
    //  Case C: Overlapping PROCESSING Batches (G3)
    // =========================================================================

    function _caseC_overlappingBatches(uint256 round) internal {
        logInfo("[CASE_C] overlappingBatches start");

        // 1. Ensure adapters have value
        _ensureAdapterHasValue();

        // 2. Request redeems from group A
        uint256 groupACount = _scaledRand(2, 5, 10);
        uint256 groupACreated;
        for (uint256 i = 0; i < groupACount; i++) {
            address user = users[_rand(users.length / 2)]; // first half
            uint256 shares = vault.balanceOf(user);
            uint256 minRedeem = _effectiveMinRedeemShares();
            if (shares >= minRedeem) {
                _requestRedeemAs(user, _randBetween(minRedeem, shares));
                groupACreated++;
            }
        }

        // 3. Process batch 1 (group A)
        uint256[] memory batch1 = _getRequestIdsByStatus(IMantleYieldVault.RequestStatus.PENDING);
        if (batch1.length == 0) return;
        batch1 = _sortIds(batch1);
        _processRedeemBatch(batch1);
        // Save for later finalization
        delete _batch1Ids;
        for (uint256 i = 0; i < batch1.length; i++) _batch1Ids.push(batch1[i]);

        logInfo(string.concat(
            "[CASE_C] batch1 processed: count=", _toStr(batch1.length),
            " lockedShares=", _toStr(vault.totalLockedShares())
        ));

        // 4. Request redeems from group B (while batch1 is PROCESSING!)
        uint256 groupBCount = _scaledRand(2, 5, 10);
        for (uint256 i = 0; i < groupBCount; i++) {
            address user = users[users.length / 2 + _rand(users.length / 2)]; // second half
            uint256 shares = vault.balanceOf(user);
            uint256 minRedeem = _effectiveMinRedeemShares();
            if (shares >= minRedeem) {
                _requestRedeemAs(user, _randBetween(minRedeem, shares));
            }
        }

        // 5. Process batch 2 (group B) -- OVERLAPPING with batch 1!
        uint256[] memory batch2 = _getRequestIdsByStatus(IMantleYieldVault.RequestStatus.PENDING);
        if (batch2.length > 0) {
            batch2 = _sortIds(batch2);
            _processRedeemBatch(batch2);
            delete _batch2Ids;
            for (uint256 i = 0; i < batch2.length; i++) _batch2Ids.push(batch2[i]);

            logInfo(string.concat(
                "[CASE_C] batch2 processed: count=", _toStr(batch2.length),
                " lockedShares=", _toStr(vault.totalLockedShares()),
                " TWO BATCHES PROCESSING"
            ));
        }

        // 6. Validate with TWO PROCESSING batches
        _checkAllInvariants(string.concat("S10:C:dualProcessing:", _toStr(round)));

        // 7. Settle all redeem in-flights
        vm.warp(block.timestamp + 2 days);
        _settleAllRedeem();

        // 8. Out-of-order finalization: 50% chance finalize batch2 first
        if (_batch2Ids.length > 0 && _randBool(50)) {
            logInfo("[CASE_C] out-of-order finalize: batch2 first");
            _finalizeBatchIds(_batch2Ids);
            _checkAllInvariants(string.concat("S10:C:afterBatch2:", _toStr(round)));
            _finalizeBatchIds(_batch1Ids);
        } else {
            _finalizeBatchIds(_batch1Ids);
            if (_batch2Ids.length > 0) {
                _checkAllInvariants(string.concat("S10:C:afterBatch1:", _toStr(round)));
                _finalizeBatchIds(_batch2Ids);
            }
        }

        // Cleanup storage
        delete _batch1Ids;
        delete _batch2Ids;
    }

    // =========================================================================
    //  Case D: Deposit During PROCESSING (G4)
    // =========================================================================

    function _caseD_depositDuringProcessing(uint256 round) internal {
        logInfo("[CASE_D] depositDuringProcessing start");

        // 1. Ensure adapter has value
        _ensureAdapterHasValue();

        // 2. Request redeems to create locked shares
        uint256 numRedeemers = _scaledRand(2, 5, 15);
        for (uint256 i = 0; i < numRedeemers; i++) {
            address user = _randUser();
            uint256 shares = vault.balanceOf(user);
            uint256 minRedeem = _effectiveMinRedeemShares();
            if (shares >= minRedeem) {
                _requestRedeemAs(user, _randBetween(minRedeem, shares));
            }
        }

        // 3. Process batch
        uint256[] memory pendingIds = _getRequestIdsByStatus(IMantleYieldVault.RequestStatus.PENDING);
        if (pendingIds.length == 0) return;
        pendingIds = _sortIds(pendingIds);
        _processRedeemBatch(pendingIds);

        // 4. Snapshot PROCESSING state
        uint256 lockedBefore = vault.totalLockedShares();
        uint256 freeCashBefore = vault.getFreeCash();

        // 5. CRITICAL: Deposit while batch is PROCESSING
        uint256 numDepositors = _scaledRand(2, 5, 15);
        uint256 totalDeposited;
        for (uint256 i = 0; i < numDepositors; i++) {
            address user = _randUser();
            uint256 bal = usdc.balanceOf(user);
            if (bal >= 10_000e6) {
                uint256 amt = _randBetween(10_000e6, _min(50_000e6, bal));
                _depositAs(user, amt);
                totalDeposited += amt;
            }
        }

        // 6. Verify deposit didn't corrupt PROCESSING state
        assertEq(vault.totalLockedShares(), lockedBefore,
            string.concat("S10:D lockedShares unchanged r:", _toStr(round)));

        // FreeCash should have increased (more physical balance, same locked)
        if (totalDeposited > 0) {
            assertGe(vault.getFreeCash(), freeCashBefore,
                string.concat("S10:D freeCash increased r:", _toStr(round)));
        }

        logInfo(string.concat(
            "[CASE_D] deposited=", _toStr(totalDeposited),
            " during PROCESSING, lockedShares=", _toStr(lockedBefore)
        ));

        // 7. Validate invariants in dirty state
        _checkAllInvariants(string.concat("S10:D:midDeposit:", _toStr(round)));

        // 8. Cleanup
        vm.warp(block.timestamp + 2 days);
        _settleAllRedeem();
        _finalizeAllProcessing();
    }

    // =========================================================================
    //  Case E: SyncRedeem During PROCESSING (G5)
    // =========================================================================

    function _caseE_syncRedeemDuringProcessing(uint256 round) internal {
        logInfo("[CASE_E] syncRedeemDuringProcessing start");

        // 1. Ensure adapter has value and vault has cash
        _ensureAdapterHasValue();
        _ensureFreeCash(80_000e6);

        // 2. Request redeems -- locks a significant portion of shares
        uint256 numRedeemers = _scaledRand(2, 5, 10);
        for (uint256 i = 0; i < numRedeemers; i++) {
            address user = _randUser();
            uint256 shares = vault.balanceOf(user);
            uint256 minRedeem = _effectiveMinRedeemShares();
            if (shares >= minRedeem) {
                // Redeem 50-80% of shares to create significant locking
                uint256 redeemShares = shares * _randBetween(50, 80) / 100;
                if (redeemShares >= minRedeem) {
                    _requestRedeemAs(user, redeemShares);
                }
            }
        }

        // 3. Process batch -> locked shares constrain freeCash
        uint256[] memory pendingIds = _getRequestIdsByStatus(IMantleYieldVault.RequestStatus.PENDING);
        if (pendingIds.length == 0) return;
        pendingIds = _sortIds(pendingIds);
        _processRedeemBatch(pendingIds);

        uint256 freeCashAfterProcess = vault.getFreeCash();
        uint256 lockedShares = vault.totalLockedShares();
        logInfo(string.concat(
            "[CASE_E] PROCESSING active: freeCash=", _toStr(freeCashAfterProcess),
            " lockedShares=", _toStr(lockedShares)
        ));

        // 4. CRITICAL: Attempt sync redeems while batch is PROCESSING
        uint256 syncRedeemCount;
        uint256 syncRedeemSkipped;
        uint256 numSyncAttempts = _scaledRand(2, 5, 15);
        for (uint256 i = 0; i < numSyncAttempts; i++) {
            address user = _randUser();
            uint256 shares = vault.balanceOf(user);
            uint256 minRedeem = _effectiveMinRedeemShares();
            if (shares < minRedeem) continue;

            uint256 redeemShares = _randBetween(minRedeem, shares);
            uint256 expectedAssets = gateway.previewRedeem(redeemShares);
            uint256 currentFreeCash = vault.getFreeCash();

            if (expectedAssets <= currentFreeCash && redeemShares >= vault.minRedeemAmount()) {
                // FreeCash sufficient -- syncRedeem should succeed
                _redeemAs(user, redeemShares);
                syncRedeemCount++;
            } else {
                syncRedeemSkipped++;
            }
        }

        logInfo(string.concat(
            "[CASE_E] syncRedeems during PROCESSING: done=", _toStr(syncRedeemCount),
            " skipped=", _toStr(syncRedeemSkipped)
        ));

        // 5. Validate
        _checkAllInvariants(string.concat("S10:E:midSyncRedeem:", _toStr(round)));

        // 6. Cleanup
        vm.warp(block.timestamp + 2 days);
        _settleAllRedeem();
        _finalizeAllProcessing();
    }

    // =========================================================================
    //  Case F: Rebalance With PENDING/PROCESSING Requests (G6, G7)
    // =========================================================================

    function _caseF_rebalanceWithPendingRequests(uint256 round) internal {
        logInfo("[CASE_F] rebalanceWithPendingRequests start");

        // 1. Ensure lots of freeCash so rebalance wants to invest
        _ensureFreeCash(150_000e6);

        // 2. Create PENDING requests (this reduces freeCash via lockedShares)
        uint256 numRedeemers = _scaledRand(2, 5, 10);
        for (uint256 i = 0; i < numRedeemers; i++) {
            address user = _randUser();
            uint256 shares = vault.balanceOf(user);
            uint256 minRedeem = _effectiveMinRedeemShares();
            if (shares >= minRedeem) {
                _requestRedeemAs(user, _randBetween(minRedeem, shares / 2));
            }
        }

        uint256 freeCashWithPending = vault.getFreeCash();
        uint256 lockedWithPending = vault.totalLockedShares();
        logInfo(string.concat(
            "[CASE_F] PENDING requests created: freeCash=", _toStr(freeCashWithPending),
            " lockedShares=", _toStr(lockedWithPending)
        ));

        // 3. CRITICAL: Rebalance while PENDING requests exist
        //    Rebalance should see reduced freeCash (locked shares excluded)
        vm.warp(block.timestamp + 3601);
        _rebalance();

        uint256 investIF = vault.totalInvestInFlight();
        logInfo(string.concat("[CASE_F] rebalance with PENDING: investIF=", _toStr(investIF)));

        _checkAllInvariants(string.concat("S10:F:postRebalance:", _toStr(round)));

        // 4. Now process the PENDING requests -> may trigger divest
        //    This could create redeem IF while invest IF is pending (G1 chain)
        uint256[] memory pendingIds = _getRequestIdsByStatus(IMantleYieldVault.RequestStatus.PENDING);
        if (pendingIds.length > 0) {
            pendingIds = _sortIds(pendingIds);
            _processRedeemBatch(pendingIds);

            uint256 redeemIF = vault.totalRedeemInFlight();
            investIF = vault.totalInvestInFlight();
            if (investIF > 0 && redeemIF > 0) {
                logInfo(string.concat(
                    "[CASE_F] DUAL IF from rebalance+process: investIF=", _toStr(investIF),
                    " redeemIF=", _toStr(redeemIF)
                ));
            }
        }

        _checkAllInvariants(string.concat("S10:F:postProcess:", _toStr(round)));

        // 5. Cleanup
        vm.warp(block.timestamp + 1 days);
        _settleAllInvest();
        vm.warp(block.timestamp + 1 days);
        _settleAllRedeem();
        _finalizeAllProcessing();
    }

    // =========================================================================
    //  Case G: Kitchen Sink -- Full Interleave Simulation (G1-G8 combined)
    // =========================================================================

    function _caseG_kitchenSink(uint256 round) internal {
        logInfo("[CASE_G] kitchenSink start");

        // ========== Day 1: Build up + Rebalance + Request while invest pending ==========
        // Deposits
        uint256 numDepositors = _scaledRand(2, 5, 15);
        for (uint256 i = 0; i < numDepositors; i++) {
            address user = _randUser();
            uint256 bal = usdc.balanceOf(user);
            if (bal >= 10_000e6) {
                _depositAs(user, _randBetween(10_000e6, _min(50_000e6, bal)));
            }
        }

        // Rebalance -> invest IF
        vm.warp(block.timestamp + 3601);
        _rebalance();

        // While invest IF pending -> requestRedeem
        uint256 numRedeemers = _scaledRand(2, 5, 10);
        for (uint256 i = 0; i < numRedeemers; i++) {
            address user = _randUser();
            uint256 shares = vault.balanceOf(user);
            uint256 minRedeem = _effectiveMinRedeemShares();
            if (shares >= minRedeem) {
                _requestRedeemAs(user, _randBetween(minRedeem, shares));
            }
        }

        // Process batch1 -> dual IF possible (G1)
        uint256[] memory batch1 = _getRequestIdsByStatus(IMantleYieldVault.RequestStatus.PENDING);
        if (batch1.length > 0) {
            batch1 = _sortIds(batch1);
            _processRedeemBatch(batch1);
            delete _batch1Ids;
            for (uint256 i = 0; i < batch1.length; i++) _batch1Ids.push(batch1[i]);
        }

        _checkAllInvariants(string.concat("S10:G:day1:", _toStr(round)));

        // ========== Day 2: Rate change + Deposit + SyncRedeem during PROCESSING ==========
        vm.warp(block.timestamp + 1 days);

        // Rate change during PROCESSING (G2)
        _jitterExchangeRate();

        // Deposit during PROCESSING (G4)
        uint256 depositCount = _scaledRand(1, 5, 10);
        for (uint256 i = 0; i < depositCount; i++) {
            address user = _randUser();
            uint256 bal = usdc.balanceOf(user);
            if (bal >= 10_000e6) {
                _depositAs(user, _randBetween(10_000e6, _min(30_000e6, bal)));
            }
        }

        // SyncRedeem during PROCESSING (G5)
        uint256 syncCount = _scaledRand(1, 3, 8);
        for (uint256 i = 0; i < syncCount; i++) {
            address user = _randUser();
            uint256 shares = vault.balanceOf(user);
            uint256 minRedeem = _effectiveMinRedeemShares();
            if (shares < minRedeem) continue;
            uint256 redeemShares = _randBetween(minRedeem, shares / 2);
            uint256 expectedAssets = gateway.previewRedeem(redeemShares);
            if (expectedAssets <= vault.getFreeCash() && redeemShares >= vault.minRedeemAmount()) {
                _redeemAs(user, redeemShares);
            }
        }

        // Settle invest only (partial settle -- redeem IF may remain) (G9 partial)
        _settleAllInvest();

        _checkAllInvariants(string.concat("S10:G:day2:", _toStr(round)));

        // ========== Day 3: New requests + 2nd batch while 1st PROCESSING ==========
        vm.warp(block.timestamp + 1 days);

        // More requestRedeems -> new PENDING while batch1 is PROCESSING (G3)
        numRedeemers = _scaledRand(1, 5, 8);
        for (uint256 i = 0; i < numRedeemers; i++) {
            address user = _randUser();
            uint256 shares = vault.balanceOf(user);
            uint256 minRedeem = _effectiveMinRedeemShares();
            if (shares >= minRedeem) {
                _requestRedeemAs(user, _randBetween(minRedeem, shares));
            }
        }

        // Process batch2 -> overlapping PROCESSING batches (G3)
        uint256[] memory batch2 = _getRequestIdsByStatus(IMantleYieldVault.RequestStatus.PENDING);
        if (batch2.length > 0) {
            batch2 = _sortIds(batch2);
            _processRedeemBatch(batch2);
            delete _batch2Ids;
            for (uint256 i = 0; i < batch2.length; i++) _batch2Ids.push(batch2[i]);

            logInfo(string.concat(
                "[CASE_G] TWO BATCHES PROCESSING: batch1=", _toStr(_batch1Ids.length),
                " batch2=", _toStr(_batch2Ids.length)
            ));
        }

        // Price jitter during dual PROCESSING (G8)
        if (!IS_FORK) {
            _jitterPosTokenPrice();
        }

        _checkAllInvariants(string.concat("S10:G:day3:", _toStr(round)));

        // ========== Day 4: Settle + Out-of-order finalize ==========
        vm.warp(block.timestamp + 2 days);
        _settleAllRedeem();

        // Out-of-order finalize: batch2 first if it exists (G3)
        if (_batch2Ids.length > 0) {
            _finalizeBatchIds(_batch2Ids);
            _checkAllInvariants(string.concat("S10:G:day4a:", _toStr(round)));
        }
        if (_batch1Ids.length > 0) {
            _finalizeBatchIds(_batch1Ids);
        }

        _checkAllInvariants(string.concat("S10:G:day4b:", _toStr(round)));

        // Cleanup storage
        delete _batch1Ids;
        delete _batch2Ids;
    }

    // =========================================================================
    //  Settlement Helpers
    // =========================================================================

    function _settleAllInvest() internal {
        _settleInvestForAdapter(address(realSyncAdapter));
        _settleInvestForAdapter(address(realAsyncAdapter));
    }

    function _settleAllRedeem() internal {
        _settleRedeemForAdapter(address(realSyncAdapter));
        _settleRedeemForAdapter(address(realAsyncAdapter));
    }

    function _settleInvestForAdapter(address adapter) internal {
        uint256 nextIfId = vault.nextInFlightId();

        uint256 count;
        for (uint256 id = _baseInFlightId; id < nextIfId; id++) {
            (address ifAdapter, bool isInvest, IMantleYieldVault.InFlightStatus s) =
                vault.ifAdapterAndStatus(id);
            if (s == IMantleYieldVault.InFlightStatus.PENDING && isInvest && ifAdapter == adapter) count++;
        }
        if (count == 0) return;

        uint256[] memory ids = new uint256[](count);
        uint256[] memory settledPos = new uint256[](count);
        uint256[] memory refunds = new uint256[](count);
        uint256 idx;

        for (uint256 id = _baseInFlightId; id < nextIfId; id++) {
            (address ifAdapter, bool isInvest, IMantleYieldVault.InFlightStatus s) =
                vault.ifAdapterAndStatus(id);
            if (s != IMantleYieldVault.InFlightStatus.PENDING || !isInvest || ifAdapter != adapter) continue;

            ids[idx] = id;
            (uint256 tokenAmt, uint256 usdcAmt) = vault.ifTokenAndUsdc(id);
            uint256 expected = tokenAmt > 0 ? tokenAmt : usdcAmt;
            // Small random variance (0-3% less) to simulate real settlement
            uint256 variance = expected * _randBetween(0, 3) / 100;
            settledPos[idx] = _randBool(70) ? expected : (expected > variance ? expected - variance : expected);
            refunds[idx] = 0;
            idx++;
        }

        // For async adapter: settle subscribe via mockSubRed -- mint ST tokens to adapter
        if (adapter == address(realAsyncAdapter)) {
            uint256 totalPos;
            for (uint256 i = 0; i < count; i++) totalPos += settledPos[i];
            if (totalPos > 0) {
                vm.prank(admin);
                mockSubRed.settleSubscribe(
                    address(realAsyncAdapter), address(stToken), address(realAsyncAdapter), totalPos
                );
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

    function _settleRedeemForAdapter(address adapter) internal {
        uint256 nextIfId = vault.nextInFlightId();

        uint256 count;
        for (uint256 id = _baseInFlightId; id < nextIfId; id++) {
            (address ifAdapter, bool isInvest, IMantleYieldVault.InFlightStatus s) =
                vault.ifAdapterAndStatus(id);
            if (s == IMantleYieldVault.InFlightStatus.PENDING && !isInvest && ifAdapter == adapter) count++;
        }
        if (count == 0) return;

        uint256[] memory ids = new uint256[](count);
        uint256[] memory settled = new uint256[](count);
        uint256 idx;

        for (uint256 id = _baseInFlightId; id < nextIfId; id++) {
            (address ifAdapter, bool isInvest, IMantleYieldVault.InFlightStatus s) =
                vault.ifAdapterAndStatus(id);
            if (s != IMantleYieldVault.InFlightStatus.PENDING || isInvest || ifAdapter != adapter) continue;

            ids[idx] = id;
            settled[idx] = vault.ifUsdcAmount(id);
            idx++;
        }

        // For async adapter: settle redeem via mockSubRed -- transfer USDC to adapter
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
                    vm.prank(admin);
                    mockSubRed.settleRedeem(
                        address(realAsyncAdapter), address(stToken), address(usdc), address(realAsyncAdapter), totalNeeded
                    );
                }
            }
        }
        // Sync adapters: USDC already on adapter from withdrawSync during divest

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
    //  Finalize Helpers
    // =========================================================================

    /// @dev Finalize ALL PROCESSING requests (from any batch)
    function _finalizeAllProcessing() internal {
        uint256[] memory processingIds = _getRequestIdsByStatus(IMantleYieldVault.RequestStatus.PROCESSING);
        if (processingIds.length == 0) return;

        processingIds = _sortIds(processingIds);
        _finalizeBatchIds(processingIds);
    }

    /// @dev Finalize a specific set of request IDs (for overlapping batch support)
    function _finalizeBatchIds(uint256[] memory ids) internal {
        if (ids.length == 0) return;

        // Filter to only PROCESSING (in case some were already finalized)
        uint256 count;
        for (uint256 i = 0; i < ids.length; i++) {
            (,,,,,,, IMantleYieldVault.RequestStatus status) = vault.requests(ids[i]);
            if (status == IMantleYieldVault.RequestStatus.PROCESSING) count++;
        }
        if (count == 0) return;

        uint256[] memory filteredIds = new uint256[](count);
        uint256 idx;
        for (uint256 i = 0; i < ids.length; i++) {
            (,,,,,,, IMantleYieldVault.RequestStatus status) = vault.requests(ids[i]);
            if (status == IMantleYieldVault.RequestStatus.PROCESSING) {
                filteredIds[idx++] = ids[i];
            }
        }
        filteredIds = _sortIds(filteredIds);

        uint256[] memory settledAssets = new uint256[](count);
        uint256 totalNeeded;

        for (uint256 i = 0; i < count; i++) {
            (,, uint256 shares,,,,, ) = vault.requests(filteredIds[i]);
            uint256 amount = shares * accountant.getRate() / 1e18;
            if (amount == 0) amount = 1;
            settledAssets[i] = amount;
            totalNeeded += amount;
        }

        // Ensure vault has enough cash via real user deposits
        uint256 available = usdc.balanceOf(address(vault));
        if (available < totalNeeded) {
            _topUpVaultCashViaDeposits(totalNeeded);
            settledAssets = _computeSettledAssets(filteredIds);
        }

        _finalizeRedeemBatch(filteredIds, settledAssets);
    }

    // =========================================================================
    //  Setup Helpers
    // =========================================================================

    /// @dev Ensure vault has at least `target` freeCash (deposit if needed)
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

    /// @dev Ensure adapters hold value (rebalance + settle invest)
    function _ensureAdapterHasValue() internal {
        _ensureFreeCash(80_000e6);
        vm.warp(block.timestamp + 3601);
        _rebalance();
        if (vault.totalInvestInFlight() > 0) {
            vm.warp(block.timestamp + 1 days);
            _settleAllInvest();
        }
        // Respect cooldown for next rebalance
        vm.warp(block.timestamp + 3601);
    }

    /// @dev Top up users with low USDC balance
    function _topUpUsers() internal {
        for (uint256 i = 0; i < _min(users.length / 4, 50); i++) {
            if (usdc.balanceOf(users[i]) < LARGE_DEPOSIT) {
                _mintUsdc(users[i], LARGE_DEPOSIT);
            }
        }
    }

    /// @dev Final cleanup: resolve all outstanding invest/redeem/processing
    function _cleanupAll() internal {
        // Settle invest
        if (vault.totalInvestInFlight() > 0) {
            vm.warp(block.timestamp + 1 days);
            _settleAllInvest();
        }
        // Settle redeem
        if (vault.totalRedeemInFlight() > 0) {
            vm.warp(block.timestamp + 2 days);
            _settleAllRedeem();
        }
        // Finalize all PROCESSING
        _finalizeAllProcessing();
    }
}
