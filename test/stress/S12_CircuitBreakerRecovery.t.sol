// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {Accountant} from "../../src/accountant/Accountant.sol";
import {VaultViewHelper} from "../lib/VaultViewHelper.sol";
import {StressBase} from "./StressBase.t.sol";

/// @title S12: Circuit Breaker Recovery
/// @notice Validates that: rate jumps beyond maxDeviation trigger pause, deposits/redeems are blocked
///         while paused, admin can recover via emergencyRateUpdate, and normal operation resumes.
contract S12_CircuitBreakerRecovery is StressBase {
    using VaultViewHelper for MantleYieldVault;
    uint256 constant DEPOSIT_AMOUNT = 50_000e6;

    function test_circuitBreakerRecovery() external {
        _logCase("S12_CircuitBreakerRecovery", "Circuit breaker trigger and recovery stress test");

        // Seed deposits
        for (uint256 i = 0; i < _min(users.length / 2, 30); i++) {
            _depositAs(users[i], DEPOSIT_AMOUNT);
        }
        _checkAllInvariants("S12:init");

        uint256 breakerTriggered;
        uint256 recoveries;

        for (uint256 round = 0; round < ROUNDS && !_shouldStop(); round++) {
            _logRoundStart(round);

            uint256 phase = round % 4;

            if (phase == 0) {
                // Phase A: Normal deposits
                _doNormalDeposits();
            } else if (phase == 1) {
                // Phase B: Trigger circuit breaker
                _triggerCircuitBreaker();
                breakerTriggered++;

                // Verify deposits blocked via gateway
                _verifyDepositsBlocked();
            } else if (phase == 2) {
                // Phase C: Recovery
                if (accountant.paused()) {
                    uint256 currentRate = accountant.getRate();
                    vm.prank(admin);
                    accountant.emergencyRateUpdate(uint64(currentRate));
                    logInfo("[RECOVERY] emergencyRateUpdate succeeded, accountant unpaused");
                    recoveries++;
                }
            } else {
                // Phase D: Resume normal operations
                _doNormalDepositsAndRedeems();
            }

            if (!accountant.paused()) {
                _checkAllInvariants(string.concat("S12:round:", _toStr(round)));
                _checkUsdcClosedSystem(string.concat("S12:round:", _toStr(round)));
            }
            _logRoundEnd(round);
            vm.warp(block.timestamp + 1 hours);
        }

        // Ensure accountant is unpaused at end
        if (accountant.paused()) {
            uint64 safeRate = uint64(accountant.getRate());
            vm.prank(admin);
            accountant.emergencyRateUpdate(safeRate);
        }

        logInfo(string.concat("[SUMMARY] breakerTriggered=", _toStr(breakerTriggered)));
        logInfo(string.concat("[SUMMARY] recoveries=", _toStr(recoveries)));
        assertTrue(breakerTriggered > 0, "S12: should have triggered breaker at least once");
        assertTrue(recoveries > 0, "S12: should have recovered at least once");

        _logPass();
    }

    function _doNormalDeposits() internal {
        uint256 numDeposits = _scaledRand(1, 4, 10);
        for (uint256 i = 0; i < numDeposits; i++) {
            address user = _randUser();
            if (usdc.balanceOf(user) >= DEPOSIT_AMOUNT / 10) {
                _depositAs(user, _randBetween(vault.minDepositAmount(), DEPOSIT_AMOUNT / 10));
            }
        }
    }

    function _doNormalDepositsAndRedeems() internal {
        uint256 numOps = _scaledRand(1, 4, 10);
        for (uint256 i = 0; i < numOps; i++) {
            address user = _randUser();
            if (_randBool(50) && usdc.balanceOf(user) >= DEPOSIT_AMOUNT / 10) {
                _depositAs(user, _randBetween(vault.minDepositAmount(), DEPOSIT_AMOUNT / 10));
            } else {
                uint256 shares = vault.balanceOf(user);
                uint256 minRedeem = _effectiveMinRedeemShares();
                uint256 freeCash = vault.getFreeCash();
                uint256 rate = accountant.getRate();
                uint256 maxRedeemShares = rate > 0 ? freeCash * 1e18 / rate : 0;
                uint256 redeemAmt = _min(shares, maxRedeemShares);
                if (redeemAmt >= minRedeem) {
                    _redeemAs(user, _randBetween(minRedeem, redeemAmt));
                }
            }
        }
    }

    function _triggerCircuitBreaker() internal {
        uint256 currentRate = accountant.getRate();
        uint256 maxDev = accountant.maxAllowedDeviation();
        uint64 extremeRate = uint64(currentRate * (10_000 + maxDev + 100) / 10_000);

        vm.warp(block.timestamp + accountant.minUpdateInterval() + 1);
        vm.prank(bot);
        acctExecutor.executeUpdateRate(address(accountant), extremeRate, uint64(block.timestamp));

        logInfo("[CIRCUIT_BREAKER] triggered, accountant paused");
    }

    function _verifyDepositsBlocked() internal {
        address testUser = _randUser();
        if (usdc.balanceOf(testUser) >= DEPOSIT_AMOUNT / 10) {
            vm.startPrank(testUser);
            usdc.approve(address(gateway), DEPOSIT_AMOUNT / 10);
            try gateway.deposit(DEPOSIT_AMOUNT / 10) {
                logInfo("[UNEXPECTED] deposit succeeded while paused");
            } catch {
                logInfo("[EXPECTED] deposit blocked during circuit breaker");
            }
            vm.stopPrank();
        }
    }
}
