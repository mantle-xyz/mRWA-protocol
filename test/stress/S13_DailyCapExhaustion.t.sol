// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {VaultViewHelper} from "../lib/VaultViewHelper.sol";
import {StressBase} from "./StressBase.t.sol";

/// @title S13: Daily Cap Exhaustion
/// @notice Sets realistic daily deposit/redeem caps and stress-tests many users hitting those caps.
///         Verifies that caps are enforced correctly and reset properly.
contract S13_DailyCapExhaustion is StressBase {
    using VaultViewHelper for MantleYieldVault;
    uint256 constant DEPOSIT_AMOUNT = 50_000e6;
    uint256 constant DAILY_DEPOSIT_CAP = 500_000e6;
    uint256 constant DAILY_REDEEM_CAP = 500_000e6;

    function setUp() public override {
        super.setUp();

        // Grant CAP_MANAGER_ROLE to admin so we can set daily caps
        vm.startPrank(admin);
        vault.grantRole(vault.CAP_MANAGER_ROLE(), admin);
        vault.setDepositDailyRemaining(DAILY_DEPOSIT_CAP);
        vault.setRedeemDailyRemaining(DAILY_REDEEM_CAP);
        vm.stopPrank();
    }

    function test_dailyCapExhaustion() external {
        _logCase("S13_DailyCapExhaustion", "Daily deposit/redeem cap exhaustion stress test");

        uint256 depositsBlocked;
        uint256 redeemsBlocked;

        for (uint256 round = 0; round < ROUNDS && !_shouldStop(); round++) {
            _logRoundStart(round);

            // Phase A: Many users try to deposit (will exhaust cap)
            uint256 numDepositors = _scaledRand(5, 2, 50);
            for (uint256 i = 0; i < numDepositors; i++) {
                address user = _randUser();
                uint256 amt = _randBetween(vault.minDepositAmount(), DEPOSIT_AMOUNT);
                if (usdc.balanceOf(user) < amt) continue;

                vm.startPrank(user);
                usdc.approve(address(gateway), amt);
                try gateway.deposit(amt) {
                    _statDeposits++;
                } catch {
                    depositsBlocked++;
                }
                vm.stopPrank();
            }

            // Phase B: Many users try sync redeem (will exhaust cap)
            uint256 numRedeemers = _scaledRand(3, 3, 30);
            for (uint256 i = 0; i < numRedeemers; i++) {
                address user = _randUser();
                uint256 shares = vault.balanceOf(user);
                uint256 minRedeem = _effectiveMinRedeemShares();
                if (shares < minRedeem) continue;
                uint256 redeemShares = _randBetween(minRedeem, shares);

                vm.prank(user);
                try gateway.redeem(redeemShares) {
                    _statSyncRedeems++;
                } catch {
                    redeemsBlocked++;
                }
            }

            _checkAllInvariants(string.concat("S13:round:", _toStr(round)));
            _checkUsdcClosedSystem(string.concat("S13:round:", _toStr(round)));

            // Reset caps each "day" (every N rounds)
            if (round % 5 == 4) {
                vm.startPrank(admin);
                vault.setDepositDailyRemaining(DAILY_DEPOSIT_CAP);
                vault.setRedeemDailyRemaining(DAILY_REDEEM_CAP);
                vm.stopPrank();
                logInfo("[CAP_RESET] daily caps reset");
            }

            _logRoundEnd(round);
            vm.warp(block.timestamp + 1 hours);
        }

        logInfo(string.concat("[SUMMARY] depositsBlocked=", _toStr(depositsBlocked)));
        logInfo(string.concat("[SUMMARY] redeemsBlocked=", _toStr(redeemsBlocked)));
        assertTrue(depositsBlocked > 0, "S13: should have hit deposit cap at least once");

        _logPass();
    }
}
