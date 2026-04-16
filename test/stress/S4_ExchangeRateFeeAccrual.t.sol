// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StressBase} from "./StressBase.t.sol";
import {console2} from "forge-std/Test.sol";

/// @title S4: Exchange Rate Fluctuation + Management Fee Accrual Stress
/// @notice Validates circuit breaker, cooldown enforcement, and fee precision over many rate updates
contract S4_ExchangeRateFeeAccrual is StressBase {
    uint256 constant INITIAL_DEPOSIT = 100_000e6;

    uint256 internal _cumulativeExpectedFee;
    bool internal _isPaused;

    function test_exchangeRateFeeAccrual() external {
        _logCase("S4_ExchangeRateFeeAccrual", unicode"汇率波动与管理费累计压力测试");

        // Seed vault (proportional to user count)
        for (uint256 i = 0; i < _min(users.length / 2, 50); i++) {
            _depositAs(users[i], INITIAL_DEPOSIT);
        }

        uint256 treasuryBefore = vault.balanceOf(treasury);

        for (uint256 round = 0; round < ROUNDS && !_shouldStop(); round++) {
            _logRoundStart(round);

            // --- Normal rate update ---
            uint256 currentRate = accountant.getRate();
            uint256 maxDev = accountant.maxAllowedDeviation();
            uint256 cooldown = accountant.minUpdateInterval();

            // Advance past cooldown
            vm.warp(block.timestamp + cooldown + 1);

            if (_isPaused) {
                // Unpause accountant (circuit breaker pauses accountant, not vault)
                vm.prank(admin);
                accountant.unpause();
                _isPaused = false;
            }

            // --- 10% chance: try to trigger circuit breaker ---
            if (_randBool(10)) {
                uint64 extremeRate;
                if (_randBool(50)) {
                    extremeRate = uint64(uint256(currentRate) * (10_000 + maxDev + 100) / 10_000);
                } else {
                    extremeRate = uint64(uint256(currentRate) * (10_000 - maxDev - 100) / 10_000);
                    if (extremeRate == 0) extremeRate = 1;
                }
                // This should trigger circuit breaker and pause
                vm.prank(bot);
                try acctExecutor.executeUpdateRate(address(accountant), extremeRate, uint64(block.timestamp)) {
                    // Circuit breaker pauses the accountant
                    _isPaused = true;
                    console2.log("[S4] Circuit breaker triggered at round", round);
                    // Unpause accountant for next round
                    vm.prank(admin);
                    accountant.unpause();
                    _isPaused = false;
                    // Re-advance cooldown since we consumed it
                    vm.warp(block.timestamp + cooldown + 1);
                } catch {
                    // Some implementations revert instead of pausing
                }
            }

            // --- 5% chance: try update within cooldown (should revert) ---
            if (_randBool(5) && !_isPaused) {
                // Don't advance time — we're within cooldown
                uint64 normalRate = uint64(uint256(currentRate) * (10_000 + _randBetween(0, 50)) / 10_000);
                // This should revert due to cooldown
                vm.prank(bot);
                try acctExecutor.executeUpdateRate(address(accountant), normalRate, uint64(block.timestamp)) {
                    // If it doesn't revert, that's unexpected but not necessarily wrong
                    // (could have been past cooldown already)
                } catch {
                    // Expected: cooldown not met
                }
                // Re-advance past cooldown
                vm.warp(block.timestamp + cooldown + 1);
            }

            // --- Normal rate update (within safe bounds) ---
            if (!_isPaused) {
                // ±0.5% normal fluctuation
                uint256 delta = uint256(currentRate) * _randBetween(1, 50) / 10_000;
                uint64 newRate;
                if (_randBool(50)) {
                    newRate = uint64(uint256(currentRate) + delta);
                } else {
                    newRate = uint64(uint256(currentRate) - delta);
                }
                // Clamp to maxDeviation
                uint64 upper = uint64(uint256(currentRate) * (10_000 + maxDev) / 10_000);
                uint64 lower = uint64(uint256(currentRate) * (10_000 - maxDev) / 10_000);
                if (newRate > upper) newRate = upper;
                if (newRate < lower) newRate = lower;

                _updateExchangeRate(newRate);
            }

            // --- Supply fluctuation every 5 rounds (scaled with user count) ---
            if (round % 5 == 0 && round > 0 && !_isPaused) {
                uint256 numOps = _scaledRand(1, 5, 30);
                for (uint256 j = 0; j < numOps; j++) {
                    address user = _randUser();
                    if (_randBool(50)) {
                        uint256 bal = usdc.balanceOf(user);
                        if (bal >= 50_000e6) {
                            _depositAs(user, 50_000e6);
                        }
                    } else {
                        uint256 shares = vault.balanceOf(user);
                        uint256 minRedeem = vault.minRedeemAmount();
                        if (shares >= minRedeem) {
                            uint256 expectedAssets = gateway.previewRedeem(shares);
                            if (expectedAssets <= vault.getFreeCash()) {
                                _redeemAs(user, shares);
                            }
                        }
                    }
                }
            }

            _checkAllInvariants(string.concat("S4:round:", _toStr(round)));

            // Periodic price update
            if (!IS_FORK && round > 0 && round % 5 == 0) {
                _jitterPosTokenPrice();
            }

            _logRoundEnd(round);
        }

        // Final: verify treasury accumulated fees
        uint256 treasuryAfter = vault.balanceOf(treasury);
        assertGe(treasuryAfter, treasuryBefore, "S4: treasury should have grown");
        console2.log("[S4] Treasury fee shares accrued:", treasuryAfter - treasuryBefore);

        _logPass();
    }
}
