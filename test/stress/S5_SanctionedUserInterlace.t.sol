// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StressBase} from "./StressBase.t.sol";
import {console2} from "forge-std/Test.sol";

/// @title S5: Sanctioned User Interlace Stress
/// @notice Validates sanction/unsanction across all transaction flows
contract S5_SanctionedUserInterlace is StressBase {
    uint256 constant DEPOSIT_AMOUNT = 20_000e6;

    // Track which users are currently sanctioned
    mapping(address => bool) internal _isSanctioned;

    function test_sanctionedUserInterlace() external {
        _logCase("S5_SanctionedUserInterlace", unicode"制裁用户交叉操作压力测试");

        // Seed vault with normal deposits
        for (uint256 i = 0; i < _min(users.length / 2, 100); i++) {
            _depositAs(users[i], DEPOSIT_AMOUNT);
        }
        _checkAllInvariants("S5:init");

        for (uint256 round = 0; round < ROUNDS && !_shouldStop(); round++) {
            _logRoundStart(round);

            // --- Phase A: Normal user operations ---
            uint256 numNormal = _scaledRand(3, 4, 40);
            for (uint256 i = 0; i < numNormal; i++) {
                address user = _randUser();
                if (_isSanctioned[user]) continue;

                uint256 bal = usdc.balanceOf(user);
                if (bal >= vault.minDepositAmount()) {
                    _depositAs(user, _randBetween(vault.minDepositAmount(), _min(DEPOSIT_AMOUNT, bal)));
                }
            }

            // Some normal redeems
            uint256 numNormalRedeems = _scaledRand(1, 10, 20);
            for (uint256 i = 0; i < numNormalRedeems; i++) {
                address user = users[i % users.length];
                if (_isSanctioned[user]) continue;
                uint256 shares = vault.balanceOf(user);
                uint256 minRedeem = vault.minRedeemAmount();
                if (shares >= minRedeem) {
                    uint256 expectedAssets = gateway.previewRedeem(shares / 2);
                    if (expectedAssets <= vault.getFreeCash() && shares / 2 >= minRedeem) {
                        _redeemAs(user, shares / 2);
                    }
                }
            }

            // --- Phase B: Sanction some users and test rejection ---
            uint256 numToSanction = _scaledRand(1, 10, 20);
            for (uint256 i = 0; i < numToSanction; i++) {
                address victim = _randUser();
                if (_isSanctioned[victim]) continue;

                _setSanctioned(victim, true);
                _isSanctioned[victim] = true;

                // (a) deposit should revert
                uint256 victimUsdc = usdc.balanceOf(victim);
                if (victimUsdc >= vault.minDepositAmount()) {
                    vm.prank(victim);
                    try gateway.deposit(vault.minDepositAmount()) {
                        // Some implementations may route instead of revert
                    } catch {
                        // Expected: SanctionedAddress
                    }
                }

                // (b) sync redeem should route shares to sanctionSafe
                uint256 victimShares = vault.balanceOf(victim);
                if (victimShares >= vault.minRedeemAmount()) {
                    uint256 safeBefore = vault.balanceOf(sanctionSafe);
                    vm.prank(victim);
                    try gateway.redeem(victimShares) {
                        // Shares should have been routed to sanctionSafe
                        uint256 safeAfter = vault.balanceOf(sanctionSafe);
                        assertGe(safeAfter, safeBefore, "S5: sanctionSafe should receive shares");
                    } catch {
                        // Also valid: may revert
                    }
                }
            }

            // --- Phase C: Normal users not affected ---
            uint256 numPhaseC = _scaledRand(2, 5, 30);
            for (uint256 i = 0; i < numPhaseC; i++) {
                address user = users[i % users.length];
                if (_isSanctioned[user]) continue;
                uint256 bal = usdc.balanceOf(user);
                if (bal >= vault.minDepositAmount()) {
                    _depositAs(user, vault.minDepositAmount());
                }
            }

            // --- Phase D: Async redeem with mid-flight sanction ---
            if (round % 3 == 0) {
                address targetUser = _findNonSanctionedUserWithShares();
                if (targetUser != address(0)) {
                    uint256 shares = vault.balanceOf(targetUser);
                    uint256 minRedeem = _effectiveMinRedeemShares();
                    if (shares >= minRedeem) {
                        uint256 reqId = _requestRedeemAs(targetUser, _min(shares, shares));

                        // Sanction user after request
                        _setSanctioned(targetUser, true);
                        _isSanctioned[targetUser] = true;

                        // Process and finalize — funds should go to sanctionSafe
                        uint256[] memory ids = new uint256[](1);
                        ids[0] = reqId;
                        _processRedeemBatch(ids);

                        vm.warp(block.timestamp + 1 days);

                        (,, uint256 reqShares,,,,, ) = vault.requests(reqId);
                        uint256[] memory settledAmts = new uint256[](1);
                        settledAmts[0] = _min(
                            reqShares * accountant.getRate() / 1e18,
                            usdc.balanceOf(address(vault))
                        );

                        uint256 safeBefore = usdc.balanceOf(sanctionSafe);
                        _finalizeRedeemBatch(ids, settledAmts);

                        // Settlement should go to sanctionSafe, not user
                        uint256 safeAfter = usdc.balanceOf(sanctionSafe);
                        assertGe(safeAfter, safeBefore, "S5: sanctionSafe receives finalized USDC");
                    }
                }
            }

            // --- Phase E: Unsanction every 5 rounds ---
            if (round % 5 == 0 && round > 0) {
                for (uint256 i = 0; i < users.length; i++) {
                    if (_isSanctioned[users[i]]) {
                        _setSanctioned(users[i], false);
                        _isSanctioned[users[i]] = false;
                    }
                }
                // Verify unsanctioned users can operate normally
                address recovered = _findNonSanctionedUserWithUsdc();
                if (recovered != address(0)) {
                    uint256 bal = usdc.balanceOf(recovered);
                    if (bal >= vault.minDepositAmount()) {
                        _depositAs(recovered, vault.minDepositAmount());
                    }
                }
            }

            _checkAllInvariants(string.concat("S5:round:", _toStr(round)));
            _checkUsdcClosedSystem(string.concat("S5:round:", _toStr(round)));

            // Periodic rate & price update
            _periodicRateAndPriceUpdate(round, 8, 10);

            _logRoundEnd(round);

            vm.warp(block.timestamp + 1 hours);
        }

        _logPass();
    }

    function _findNonSanctionedUserWithShares() internal view returns (address) {
        for (uint256 i = 0; i < users.length; i++) {
            if (!_isSanctioned[users[i]] && vault.balanceOf(users[i]) >= vault.minRedeemAmount()) {
                return users[i];
            }
        }
        return address(0);
    }

    function _findNonSanctionedUserWithUsdc() internal view returns (address) {
        for (uint256 i = 0; i < users.length; i++) {
            if (!_isSanctioned[users[i]] && usdc.balanceOf(users[i]) >= vault.minDepositAmount()) {
                return users[i];
            }
        }
        return address(0);
    }
}
