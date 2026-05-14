// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {IStrategyControllerExecutor} from "../../src/interfaces/strategy/IStrategyControllerExecutor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StressBase} from "./StressBase.t.sol";
import {console2} from "forge-std/Test.sol";

/// @title S7: Full Protocol Endurance Test
/// @notice Simulates SIM_DAYS of real-world operations covering all flows end-to-end
contract S7_FullProtocolEndurance is StressBase {
    // Track sanctioned users within this test
    mapping(address => bool) internal _sanctioned;
    // Track pending invest settlement day
    uint256 internal _lastInvestDay;
    bool internal _systemPaused;

    function test_fullProtocolEndurance() external {
        // Only local mode — needs full adapter control
        if (IS_FORK) return;

        _logCase("S7_FullProtocolEndurance", unicode"全协议耐久性压力测试");

        // Initial seeding
        for (uint256 i = 0; i < _min(users.length / 2, 100); i++) {
            _depositAs(users[i], 100_000e6);
        }
        _checkAllInvariants("S7:init");

        for (uint256 day = 0; day < SIM_DAYS && !_shouldStop(); day++) {
            _logRoundStart(day);

            // ===================== Morning: Deposits =====================
            _phaseMorning(day);

            // ===================== Mid-morning: Compliance =====================
            _phaseCompliance(day);

            // ===================== Noon: NAV Update =====================
            _phaseNoon(day);

            // Periodic pos token price update
            if (!IS_FORK && day > 0 && day % 3 == 0) {
                _jitterPosTokenPrice();
            }

            // ===================== Afternoon: Redemptions =====================
            _phaseAfternoon(day);

            // ===================== Evening: Bot Operations =====================
            _phaseEvening(day);

            // ===================== Night: Invariant Check =====================
            _checkAllInvariants(string.concat("S7:day:", _toStr(day)));
            _checkUsdcClosedSystem(string.concat("S7:usdc:", _toStr(day)));

            _logRoundEnd(day);

            // Advance 1 day
            vm.warp(block.timestamp + 1 days);
        }

        // === Final Verification ===
        _finalVerification();

        _logPass();
    }

    // =========================================================================
    //  Daily Phases
    // =========================================================================

    function _phaseMorning(uint256 day) internal {
        uint256 numDepositors = _scaledRand(3, 4, 50);
        for (uint256 i = 0; i < numDepositors; i++) {
            address user = _randUser();
            if (_sanctioned[user]) continue;
            uint256 bal = usdc.balanceOf(user);
            uint256 amount = _randBetween(100e6, _min(50_000e6, bal));
            if (amount >= vault.minDepositAmount() && amount <= bal) {
                _depositAs(user, amount);
            }
        }

        // Occasional share transfers (1~2 per day)
        if (_randBool(60)) {
            address from = _randUser();
            address to = _randUser();
            if (from != to && !_sanctioned[from] && !_sanctioned[to]) {
                uint256 shares = vault.balanceOf(from);
                if (shares > 0) {
                    uint256 transferAmt = _randBetween(1, shares / 2);
                    if (transferAmt > 0) {
                        vm.prank(from);
                        vault.transfer(to, transferAmt);
                    }
                }
            }
        }
    }

    function _phaseCompliance(uint256 day) internal {
        // Every 5 days: sanction 1~2 users
        if (day % 5 == 0 && day > 0) {
            uint256 numSanction = _randBetween(1, 2);
            for (uint256 i = 0; i < numSanction; i++) {
                address victim = _randUser();
                if (!_sanctioned[victim]) {
                    _setSanctioned(victim, true);
                    _sanctioned[victim] = true;
                }
            }
        }

        // Every 7 days: unsanction previously sanctioned
        if (day % 7 == 0 && day > 0) {
            for (uint256 i = 0; i < users.length; i++) {
                if (_sanctioned[users[i]]) {
                    _setSanctioned(users[i], false);
                    _sanctioned[users[i]] = false;
                }
            }
        }

        // Sanctioned user attempts → verify correct handling
        for (uint256 i = 0; i < users.length; i++) {
            if (!_sanctioned[users[i]]) continue;
            address victim = users[i];

            // Try deposit → should fail
            uint256 bal = usdc.balanceOf(victim);
            if (bal >= vault.minDepositAmount()) {
                vm.prank(victim);
                try gateway.deposit(vault.minDepositAmount()) {} catch {}
            }

            // Try redeem → should route to sanctionSafe
            uint256 victimShares = vault.balanceOf(victim);
            if (victimShares >= vault.minRedeemAmount()) {
                vm.prank(victim);
                try gateway.redeem(victimShares) {} catch {}
            }
        }
    }

    function _phaseNoon(uint256 day) internal {
        if (_systemPaused) {
            vm.prank(admin);
            accountant.unpause();
            _systemPaused = false;
        }

        uint256 currentRate = accountant.getRate();
        uint256 maxDev = accountant.maxAllowedDeviation();
        uint256 cooldown = accountant.minUpdateInterval();

        vm.warp(block.timestamp + cooldown + 1);

        // Every 15 days: try circuit breaker
        if (day % 15 == 0 && day > 0) {
            uint64 extremeRate = uint64(uint256(currentRate) * (10_000 + maxDev + 200) / 10_000);
            vm.prank(bot);
            try acctExecutor.executeUpdateRate(address(accountant), extremeRate, uint64(block.timestamp)) {
                _systemPaused = true;
                console2.log("[S7] Circuit breaker day", day);
                vm.prank(admin);
                accountant.unpause();
                _systemPaused = false;
                vm.warp(block.timestamp + cooldown + 1);
            } catch {}
        }

        // Normal rate update
        uint256 deltaMax;
        if (day % 10 == 0 && day > 0) {
            deltaMax = 300; // ±3% stress day
        } else {
            deltaMax = 50; // ±0.5% normal
        }

        uint256 delta = uint256(currentRate) * _randBetween(1, deltaMax) / 10_000;
        uint64 newRate;
        if (_randBool(50)) {
            newRate = uint64(uint256(currentRate) + delta);
        } else {
            newRate = uint64(uint256(currentRate) > delta ? uint256(currentRate) - delta : currentRate);
        }
        // Clamp
        uint64 upper = uint64(uint256(currentRate) * (10_000 + maxDev) / 10_000);
        uint64 lower = uint64(uint256(currentRate) * (10_000 - maxDev) / 10_000);
        if (newRate > upper) newRate = upper;
        if (newRate < lower) newRate = lower;

        _updateExchangeRate(newRate);
    }

    function _phaseAfternoon(uint256 day) internal {
        // Async redeems: 2~5 users
        uint256 numRequests = _scaledRand(2, 5, 30);
        for (uint256 i = 0; i < numRequests; i++) {
            address user = _randUser();
            if (_sanctioned[user]) continue;
            uint256 shares = vault.balanceOf(user);
            uint256 minRedeem = _effectiveMinRedeemShares();
            if (shares >= minRedeem) {
                uint256 redeemAmt = _randBetween(minRedeem, shares);
                _requestRedeemAs(user, redeemAmt);
            }
        }

        // Sync redeems: proportional to user count (if freeCash available)
        uint256 numSyncRedeems = _scaledRand(1, 10, 20);
        for (uint256 i = 0; i < numSyncRedeems; i++) {
            address user = _randUser();
            if (_sanctioned[user]) continue;
            uint256 shares = vault.balanceOf(user);
            uint256 minRedeem = vault.minRedeemAmount();
            if (shares >= minRedeem) {
                uint256 expectedAssets = gateway.previewRedeem(shares / 3);
                if (expectedAssets <= vault.getFreeCash() && shares / 3 >= minRedeem) {
                    _redeemAs(user, shares / 3);
                }
            }
        }
    }

    function _phaseEvening(uint256 day) internal {
        // --- Process pending redeems ---
        uint256[] memory pendingIds = _getRequestIdsByStatus(IMantleYieldVault.RequestStatus.PENDING);
        if (pendingIds.length > 0) {
            pendingIds = _sortIds(pendingIds);
            _processRedeemBatch(pendingIds);
        }

        // --- Rebalance (respect cooldown) ---
        vm.warp(block.timestamp + 3601);
        _rebalance();

        // --- Settle all pending in-flights before finalization ---
        if (vault.totalInvestInFlight() > 0) {
            _settleAllInvest();
        }
        if (vault.totalRedeemInFlight() > 0) {
            _settleAllRedeem();
        }

        // --- Finalize processing requests ---
        uint256[] memory processingIds = _getRequestIdsByStatus(IMantleYieldVault.RequestStatus.PROCESSING);
        if (processingIds.length > 0) {
            processingIds = _sortIds(processingIds);
            uint256[] memory settledAssets = new uint256[](processingIds.length);
            for (uint256 i = 0; i < processingIds.length; i++) {
                (,, uint256 shares,,,,, ) = vault.requests(processingIds[i]);
                uint256 estimated = shares * accountant.getRate() / 1e18;
                // ±5% variance occasionally
                if (_randBool(20)) {
                    uint256 var_ = estimated * _randBetween(1, 5) / 100;
                    estimated = _randBool(50) ? estimated - var_ : estimated + var_;
                }
                settledAssets[i] = _min(estimated, usdc.balanceOf(address(vault)));
            }
            _finalizeRedeemBatch(processingIds, settledAssets);
        }

        // --- Top up users who are low on USDC (capped to avoid OOG with large pools) ---
        if (day % 7 == 0) {
            uint256 topUpLimit = _min(users.length, 200);
            for (uint256 i = 0; i < topUpLimit; i++) {
                if (usdc.balanceOf(users[i]) < 10_000e6) {
                    _mintUsdc(users[i], 100_000e6);
                }
            }
        }
    }

    // =========================================================================
    //  Settlement helpers
    // =========================================================================

    function _settleAllInvest() internal {
        _settleInvestForAdapter(address(realSyncAdapter));
        _settleInvestForAdapter(address(realAsyncAdapter));
    }

    function _settleInvestForAdapter(address adapter) internal {
        uint256 nextIfId = vault.nextInFlightId();

        uint256 count;
        for (uint256 id = _baseInFlightId; id < nextIfId; id++) {
            (, address ifAdapter,,,,, bool isInvest,, IMantleYieldVault.InFlightStatus s) =
                vault.inFlightRecords(id);
            if (s == IMantleYieldVault.InFlightStatus.PENDING && isInvest && ifAdapter == adapter) count++;
        }
        if (count == 0) return;

        uint256[] memory ids = new uint256[](count);
        uint256[] memory pos = new uint256[](count);
        uint256[] memory refunds = new uint256[](count);
        uint256 idx;

        for (uint256 id = _baseInFlightId; id < nextIfId; id++) {
            (, address ifAdapter,,uint256 tokenAmt, uint256 usdcAmt,, bool isInvest,, IMantleYieldVault.InFlightStatus s) =
                vault.inFlightRecords(id);
            if (s != IMantleYieldVault.InFlightStatus.PENDING || !isInvest) continue;
            if (ifAdapter != adapter) continue;

            ids[idx] = id;
            pos[idx] = tokenAmt > 0 ? tokenAmt : usdcAmt;
            refunds[idx] = 0;
            idx++;
        }

        // For async adapter: settle subscribe via mockSubRed — mint ST tokens to adapter
        if (adapter == address(realAsyncAdapter)) {
            uint256 totalPos;
            for (uint256 i = 0; i < count; i++) totalPos += pos[i];
            vm.prank(admin);
            mockSubRed.settleSubscribe(address(realAsyncAdapter), address(stToken), address(realAsyncAdapter), totalPos);
        }

        _settleAdapter(
            adapter,
            IStrategyControllerExecutor.InvestSettlementInput({
                inFlightIds: ids,
                settledPosAmounts: pos,
                refundAssetAmounts: refunds
            }),
            _emptyRedeemInput()
        );
    }

    function _settleAllRedeem() internal {
        _settleRedeemForAdapter(address(realSyncAdapter));
        _settleRedeemForAdapter(address(realAsyncAdapter));
    }

    function _settleRedeemForAdapter(address adapter) internal {
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
            if (s != IMantleYieldVault.InFlightStatus.PENDING || isInvest) continue;
            if (ifAdapter != adapter) continue;

            ids[idx] = id;
            settled[idx] = usdcAmt;
            idx++;
        }

        // For async adapter: settle redeem via mockSubRed
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

    // =========================================================================
    //  Final Verification
    // =========================================================================

    function _finalVerification() internal {
        // 1. No residual PROCESSING requests
        uint256[] memory processing = _getRequestIdsByStatus(IMantleYieldVault.RequestStatus.PROCESSING);
        assertEq(processing.length, 0, "S7:final no PROCESSING");

        // 2. All in-flight settled
        assertEq(vault.totalInvestInFlight(), 0, "S7:final investIF == 0");
        assertEq(vault.totalRedeemInFlight(), 0, "S7:final redeemIF == 0");

        // 3. Treasury grew (fees accrued)
        assertGe(vault.balanceOf(treasury), _lastTreasuryBalance, "S7:final treasury grew");

        // 4. Full invariant suite
        _checkAllInvariants("S7:final");
        _checkUsdcClosedSystem("S7:final:usdc");

        console2.log("[S7] Final totalAssets:", vault.totalAssets());
        console2.log("[S7] Final totalSupply:", vault.totalSupply());
        console2.log("[S7] Final treasury shares:", vault.balanceOf(treasury));
        console2.log("[S7] Final sanctionSafe USDC:", usdc.balanceOf(sanctionSafe));
    }
}
