// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StressBase} from "./StressBase.t.sol";

/// @title S1: Multi-user Deposit/Redeem Mix Stress
/// @notice Validates sync deposit + sync redeem under high volume with exchange rate fluctuations
contract S1_DepositRedeemMix is StressBase {
    uint256 constant MIN_DEPOSIT = 1e6; // 1 USDC
    uint256 constant MAX_DEPOSIT = 10_000e6; // 10,000 USDC
    uint256 constant RATE_UPDATE_INTERVAL = 10; // every 10 rounds

    function test_depositRedeemMix() external {
        _logCase("S1_DepositRedeemMix", unicode"多用户存款/赎回混合压力测试");

        // Initial deposit so vault has liquidity
        for (uint256 i = 0; i < _min(users.length / 2, 50); i++) {
            _depositAs(users[i], 10_000e6);
        }
        _checkAllInvariants("S1:init");

        for (uint256 round = 0; round < ROUNDS && !_shouldStop(); round++) {
            _logRoundStart(round);

            // Pick proportional number of random users this round
            uint256 numUsers = _scaledRand(1, 4, 50);
            for (uint256 u = 0; u < numUsers; u++) {
                address user = _randUser();
                uint256 userShares = vault.balanceOf(user);
                uint256 userUsdc = usdc.balanceOf(user);

                if (_randBool(60)) {
                    // --- Deposit ---
                    uint256 amount = _randBetween(MIN_DEPOSIT, _min(MAX_DEPOSIT, userUsdc));
                    if (amount >= vault.minDepositAmount() && amount <= userUsdc) {
                        _depositAs(user, amount);
                    }
                } else {
                    // --- Sync Redeem ---
                    if (userShares > 0) {
                        uint256 minRedeem = vault.minRedeemAmount();
                        if (userShares >= minRedeem) {
                            uint256 redeemShares = _randBetween(minRedeem, userShares);
                            // Check if vault has enough freeCash
                            uint256 expectedAssets = gateway.previewRedeem(redeemShares);
                            if (expectedAssets <= vault.getFreeCash()) {
                                _redeemAs(user, redeemShares);
                            }
                        }
                    }
                }
            }

            // Update exchange rate & pos price periodically
            _periodicRateAndPriceUpdate(round, RATE_UPDATE_INTERVAL, RATE_UPDATE_INTERVAL * 2);

            _checkAllInvariants(string.concat("S1:round:", _toStr(round)));

            if (!IS_FORK) {
                _checkUsdcClosedSystem(string.concat("S1:usdc:", _toStr(round)));
            }

            _logRoundEnd(round);

            // Advance time slightly
            vm.warp(block.timestamp + 1 hours);
        }

        // Final: verify share conservation precisely
        uint256 totalShares;
        for (uint256 i = 0; i < users.length; i++) {
            totalShares += vault.balanceOf(users[i]);
        }
        totalShares += vault.balanceOf(treasury);
        totalShares += vault.balanceOf(sanctionSafe);
        totalShares += vault.balanceOf(admin);

        if (!IS_FORK) {
            assertEq(totalShares, vault.totalSupply(), "S1:final share conservation");
        }

        _logPass();
    }
}
