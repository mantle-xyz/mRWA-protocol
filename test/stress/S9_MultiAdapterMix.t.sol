// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {IStrategyControllerExecutor} from "../../src/interfaces/strategy/IStrategyControllerExecutor.sol";
import {IStrategyAdapter} from "../../src/interfaces/adapters/IStrategyAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {MockSync4626Adapter} from "../../src/adapters/mock/MockSync4626Adapter.sol";
import {MockERC4626Vault} from "../../src/mocks/strategy/MockERC4626Vault.sol";
import {VaultViewHelper} from "../lib/VaultViewHelper.sol";
import {StressBase} from "./StressBase.t.sol";
import {console2} from "forge-std/Test.sol";

/// @title S9: Multi-Adapter Asymmetric Weight Mix
/// @notice Validates rebalance distribution, settlement, and in-flight tracking across 3 adapters
///         with asymmetric weights (40/35/25) and periodic weight + price changes.
contract S9_MultiAdapterMix is StressBase {
    using VaultViewHelper for MantleYieldVault;
    uint256 constant LARGE_DEPOSIT = 200_000e6;

    // Third adapter (deployed in setUp)
    MockSync4626Adapter internal s9Sync2;
    MockERC4626Vault internal s9Target2;

    function setUp() public override {
        super.setUp();
        if (IS_FORK) return;

        // Deploy third adapter with its own ERC4626 target vault
        s9Target2 = new MockERC4626Vault(IERC20(address(usdc)), "SyncVault2", "sVLT2");
        s9Sync2 = new MockSync4626Adapter(
            address(vault), address(s9Target2), admin, address(controller), address(acctExecutor)
        );

        vm.startPrank(admin);

        // Register third adapter with temporary 0 weight (won't be in strategyOrder yet)
        controller.registerStrategy(address(s9Sync2), 0, 3, false);
        controller.activateStrategy(address(s9Sync2));

        // Set new 3-adapter order and reweight atomically
        address[] memory adps = new address[](3);
        uint16[] memory ws = new uint16[](3);
        uint16[] memory ps = new uint16[](3);
        bool[] memory asyncs = new bool[](3);
        adps[0] = address(realSyncAdapter);  ws[0] = 4000; ps[0] = 1; asyncs[0] = false;
        adps[1] = address(realAsyncAdapter); ws[1] = 3500; ps[1] = 2; asyncs[1] = true;
        adps[2] = address(s9Sync2);          ws[2] = 2500; ps[2] = 3; asyncs[2] = false;

        address[] memory order = new address[](3);
        order[0] = address(realSyncAdapter);
        order[1] = address(realAsyncAdapter);
        order[2] = address(s9Sync2);

        controller.updateStrategiesAndOrder(adps, ws, ps, asyncs, order);

        vm.stopPrank();
    }

    function test_multiAdapterMix() external {
        if (IS_FORK) return;

        _logCase("S9_MultiAdapterMix", unicode"多Adapter非对称权重混合压力测试");

        // Initial deposits
        for (uint256 i = 0; i < _min(users.length / 2, 50); i++) {
            _depositAs(users[i], LARGE_DEPOSIT);
        }
        _checkAllInvariants("S9:init");

        for (uint256 round = 0; round < ROUNDS && !_shouldStop(); round++) {
            _logRoundStart(round);

            // ===================== Phase A: Deposits =====================
            _phaseA_deposits(round);

            // ===================== Phase B: Rebalance =====================
            vm.warp(block.timestamp + 3601);
            _rebalance();

            _checkAllInvariants(string.concat("S9:phaseB:", _toStr(round)));

            // ===================== Phase C: Settle Invest =====================
            vm.warp(block.timestamp + 1 days);
            _phaseC_settleInvest(round);

            assertEq(vault.totalInvestInFlight(), 0, string.concat("S9:investIF=0 r:", _toStr(round)));

            // ===================== Phase D: Redeem + Divest + Settle + Finalize =====================
            _phaseD_redeemCycle(round);

            assertEq(vault.totalRedeemInFlight(), 0, string.concat("S9:redeemIF=0 r:", _toStr(round)));

            _checkAllInvariants(string.concat("S9:round:", _toStr(round)));
            _checkUsdcClosedSystem(string.concat("S9:usdc:", _toStr(round)));

            // ===================== Periodic: Price Jitter =====================
            if (round > 0 && round % 10 == 0) {
                _jitterPosTokenPrice();  // async adapter
                _jitterS9Sync2Price();   // sync2 adapter
            }

            // ===================== Periodic: Weight Change =====================
            if (round > 0 && round % 20 == 0) {
                _rotateWeights(round);
            }

            // Rate update
            _periodicRateAndPriceUpdate(round, 5, 5);

            _logRoundEnd(round);
            vm.warp(block.timestamp + 1 hours);
        }

        // Final verification
        assertEq(vault.totalInvestInFlight(), 0, "S9:final investIF=0");
        assertEq(vault.totalRedeemInFlight(), 0, "S9:final redeemIF=0");
        _checkAllInvariants("S9:final");
        _checkUsdcClosedSystem("S9:final:usdc");

        console2.log("[S9] Final totalAssets:", vault.totalAssets());
        console2.log("[S9] sync1 value:", IStrategyAdapter(address(realSyncAdapter)).totalValue());
        console2.log("[S9] async1 value:", IStrategyAdapter(address(realAsyncAdapter)).totalValue());
        console2.log("[S9] sync2 value:", IStrategyAdapter(address(s9Sync2)).totalValue());

        _logPass();
    }

    // =========================================================================
    //  Daily Phases
    // =========================================================================

    function _phaseA_deposits(uint256 round) internal {
        uint256 numDepositors = _scaledRand(2, 5, 30);
        for (uint256 i = 0; i < numDepositors; i++) {
            address user = _randUser();
            uint256 bal = usdc.balanceOf(user);
            uint256 amount = _randBetween(10_000e6, _min(50_000e6, bal));
            if (amount >= vault.minDepositAmount() && amount <= bal) {
                _depositAs(user, amount);
            }
        }

        // Top up periodically (scaled with user count)
        if (round % 10 == 0 && round > 0) {
            for (uint256 i = 0; i < _min(users.length / 4, 50); i++) {
                if (usdc.balanceOf(users[i]) < LARGE_DEPOSIT) {
                    _mintUsdc(users[i], LARGE_DEPOSIT);
                }
            }
        }
    }

    function _phaseC_settleInvest(uint256 round) internal {
        // sync1: normal settlement
        _settleInvestForAdapter(address(realSyncAdapter), 0);

        // sync2: random partial refund (0-30%)
        uint256 sync2Refund = _randBetween(0, 30);
        _settleInvestForAdapter(address(s9Sync2), sync2Refund);

        // async1: normal or partial (0-20%)
        uint256 asyncRefund = _randBool(30) ? _randBetween(5, 20) : 0;
        _settleInvestForAdapter(address(realAsyncAdapter), asyncRefund);
    }

    function _phaseD_redeemCycle(uint256 round) internal {
        // Request redeems
        uint256 numRedeemers = _scaledRand(1, 5, 20);
        for (uint256 i = 0; i < numRedeemers; i++) {
            address user = _randUser();
            uint256 shares = vault.balanceOf(user);
            uint256 minRedeem = _effectiveMinRedeemShares();
            if (shares >= minRedeem) {
                _requestRedeemAs(user, _randBetween(minRedeem, shares));
            }
        }

        // Process batch (may trigger divest across all 3 adapters)
        uint256[] memory pendingIds = _getRequestIdsByStatus(IMantleYieldVault.RequestStatus.PENDING);
        if (pendingIds.length > 0) {
            pendingIds = _sortIds(pendingIds);
            _processRedeemBatch(pendingIds);
        }

        // Settle all redeem in-flights
        vm.warp(block.timestamp + 2 days);
        _settleRedeemForAdapter(address(realSyncAdapter));
        _settleRedeemForAdapter(address(s9Sync2));
        _settleRedeemForAdapter(address(realAsyncAdapter));

        // Finalize
        uint256[] memory processingIds = _getRequestIdsByStatus(IMantleYieldVault.RequestStatus.PROCESSING);
        if (processingIds.length > 0) {
            processingIds = _sortIds(processingIds);
            uint256[] memory settledAssets = new uint256[](processingIds.length);
            uint256 totalNeeded;

            for (uint256 i = 0; i < processingIds.length; i++) {
                uint256 shares = vault.reqShares(processingIds[i]);
                uint256 amount = shares * accountant.getRate() / 1e18;
                if (amount == 0) amount = 1;
                settledAssets[i] = amount;
                totalNeeded += amount;
            }

            // Ensure vault has enough cash via real user deposits
            uint256 available = usdc.balanceOf(address(vault));
            if (available < totalNeeded) {
                _topUpVaultCashViaDeposits(totalNeeded);
                settledAssets = _computeSettledAssets(processingIds);
            }

            _finalizeRedeemBatch(processingIds, settledAssets);
        }
    }

    // =========================================================================
    //  Invest Settlement
    // =========================================================================

    function _settleInvestForAdapter(address adapter, uint256 refundPct) internal {
        uint256 nextIfId = vault.nextInFlightId();

        uint256 count;
        for (uint256 id = _baseInFlightId; id < nextIfId; id++) {
            (address ifAdapter, bool isInvest, IMantleYieldVault.InFlightStatus s) =
                vault.ifAdapterAndStatus(id);
            if (s == IMantleYieldVault.InFlightStatus.PENDING && isInvest && ifAdapter == adapter) count++;
        }
        if (count == 0) return;

        _buildAndSettleInvest(adapter, nextIfId, count, refundPct);
    }

    function _buildAndSettleInvest(address adapter, uint256 nextIfId, uint256 count, uint256 refundPct) internal {
        uint256[] memory ids = new uint256[](count);
        uint256[] memory settledPos = new uint256[](count);
        uint256[] memory refunds = new uint256[](count);
        uint256 idx;

        for (uint256 id = _baseInFlightId; id < nextIfId; id++) {
            (address ifAdapter, bool isInvest, IMantleYieldVault.InFlightStatus s) =
                vault.ifAdapterAndStatus(id);
            if (s != IMantleYieldVault.InFlightStatus.PENDING || !isInvest || ifAdapter != adapter) continue;

            ids[idx] = id;
            _computeInvestEntry(id, idx, refundPct, settledPos, refunds);
            idx++;
        }

        _preSettleInvest(adapter, ids, settledPos, refunds, count);

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

    /// @dev Pure math: compute settled pos and refund USDC for an invest entry
    function _computeInvestEntry(
        uint256 id, uint256 idx, uint256 refundPct,
        uint256[] memory settledPos, uint256[] memory refunds
    ) internal view {
        (uint256 tokenAmt, uint256 usdcAmt) = vault.ifTokenAndUsdc(id);
        uint256 refundUsdc = usdcAmt * refundPct / 100;
        uint256 settled = tokenAmt * (100 - refundPct) / 100;
        settledPos[idx] = settled;
        refunds[idx] = refundUsdc;
    }

    /// @dev Prepare adapter state before invest settlement
    function _preSettleInvest(
        address adapter, uint256[] memory ids, uint256[] memory settledPos, uint256[] memory refunds, uint256 count
    ) internal {
        if (adapter == address(realAsyncAdapter)) {
            // Async adapter: mint ST via settleSubscribe + provide refund USDC
            uint256 totalPos;
            uint256 totalRefund;
            for (uint256 i = 0; i < count; i++) {
                totalPos += settledPos[i];
                totalRefund += refunds[i];
            }
            if (totalPos > 0) {
                vm.prank(admin);
                mockSubRed.settleSubscribe(
                    address(realAsyncAdapter), address(stToken), address(realAsyncAdapter), totalPos
                );
            }
            if (totalRefund > 0) {
                // Invest refund: USDC returns from SubRed via direct transfer
                // (not settleRedeem — that requires a pending redeem position)
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
        } else {
            // Sync adapter (realSyncAdapter or s9Sync2):
            // Adapter has all 4626 shares from deposit, but no USDC.
            // For refund: redeem excess shares from ERC4626 to provide USDC on adapter.
            uint256 totalExcessShares;
            for (uint256 i = 0; i < count; i++) {
                uint256 tokenAmt = vault.ifTokenAmount(ids[i]);
                totalExcessShares += tokenAmt - settledPos[i];
            }
            if (totalExcessShares > 0) {
                address target = _targetVaultFor(adapter);
                vm.prank(adapter);
                uint256 redeemedUsdc = IERC4626(target).redeem(totalExcessShares, adapter, adapter);
                // Adjust refunds to match actual USDC obtained from redeem
                uint256 totalOrigRefund;
                for (uint256 i = 0; i < count; i++) totalOrigRefund += refunds[i];
                if (totalOrigRefund > 0 && redeemedUsdc != totalOrigRefund) {
                    uint256 distributed;
                    for (uint256 i = 0; i < count - 1; i++) {
                        refunds[i] = redeemedUsdc * refunds[i] / totalOrigRefund;
                        distributed += refunds[i];
                    }
                    refunds[count - 1] = redeemedUsdc - distributed;
                }
            }
        }
    }

    // =========================================================================
    //  Redeem Settlement
    // =========================================================================

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

        // For async adapter: settle redeem via mockSubRed — transfer USDC to adapter
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
                    (, uint256 redeemPos) = mockSubRed.pending(address(realAsyncAdapter), address(stToken));
                    if (redeemPos > 0) {
                        vm.prank(admin);
                        mockSubRed.settleRedeem(
                            address(realAsyncAdapter), address(stToken), address(usdc), address(realAsyncAdapter), totalNeeded
                        );
                    } else {
                        vm.prank(address(mockSubRed));
                        usdc.transfer(address(realAsyncAdapter), totalNeeded);
                    }
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
    //  Periodic Actions
    // =========================================================================

    /// @dev Simulate yield on the sync2 ERC4626 vault to change posToken price
    function _jitterS9Sync2Price() internal {
        uint256 totalSupply = s9Target2.totalSupply();
        if (totalSupply == 0) return;

        uint256 totalAssets = s9Target2.totalAssets();
        uint256 currentPrice = totalAssets * 1e18 / totalSupply;

        // Simulate yield: mint 0.01-5% of totalAssets as additional USDC
        uint256 yieldBps = _randBetween(1, 500);
        uint256 yieldAmount = totalAssets * yieldBps / 10_000;
        if (yieldAmount > 0) {
            _simulateYield(s9Target2, yieldAmount);
        }

        uint256 newPrice = s9Target2.totalAssets() * 1e18 / totalSupply;
        logInfo(string.concat("[PRICE_UPDATE] sync2 old=", _toStr(currentPrice), " new=", _toStr(newPrice)));
    }

    function _rotateWeights(uint256 round) internal {
        // Cycle through 3 weight configurations
        uint16 w1; uint16 w2; uint16 w3;
        uint256 config = (round / 20) % 3;
        if (config == 0) {
            w1 = 4000; w2 = 3500; w3 = 2500; // 40/35/25
        } else if (config == 1) {
            w1 = 3000; w2 = 3000; w3 = 4000; // 30/30/40
        } else {
            w1 = 5000; w2 = 2000; w3 = 3000; // 50/20/30
        }

        address[] memory adps = new address[](3);
        uint16[] memory ws = new uint16[](3);
        uint16[] memory ps = new uint16[](3);
        bool[] memory asyncs = new bool[](3);

        adps[0] = address(realSyncAdapter);  ws[0] = w1; ps[0] = 1; asyncs[0] = false;
        adps[1] = address(realAsyncAdapter); ws[1] = w2; ps[1] = 2; asyncs[1] = true;
        adps[2] = address(s9Sync2);          ws[2] = w3; ps[2] = 3; asyncs[2] = false;

        vm.prank(admin);
        controller.updateStrategies(adps, ws, ps, asyncs);

        logInfo(string.concat("[WEIGHT_ROTATE] ", _toStr(w1), "/", _toStr(w2), "/", _toStr(w3)));
    }

    // =========================================================================
    //  Overrides
    // =========================================================================

    /// @dev Override USDC closed-system check to include the third adapter and all related addresses
    function _checkUsdcClosedSystem(string memory ctx) internal view override {
        if (IS_FORK) return;

        uint256 totalInSystem;
        for (uint256 i = 0; i < users.length; i++) {
            totalInSystem += usdc.balanceOf(users[i]);
        }
        totalInSystem += usdc.balanceOf(address(vault));
        totalInSystem += usdc.balanceOf(sanctionSafe);
        // Real sync adapter #1 + its ERC4626 target
        totalInSystem += usdc.balanceOf(address(realSyncAdapter));
        totalInSystem += usdc.balanceOf(address(sync4626Target));
        // Real async adapter + mockSubRed
        totalInSystem += usdc.balanceOf(address(realAsyncAdapter));
        totalInSystem += usdc.balanceOf(address(mockSubRed));
        // Third adapter (sync2) + its ERC4626 target
        totalInSystem += usdc.balanceOf(address(s9Sync2));
        totalInSystem += usdc.balanceOf(address(s9Target2));

        assertEq(totalInSystem, _totalUsdcInjected, string.concat(ctx, " USDC closed system (3-adapter)"));
    }

    // =========================================================================
    //  Helpers
    // =========================================================================

    function _targetVaultFor(address adapter) internal view returns (address) {
        if (adapter == address(realSyncAdapter)) return address(sync4626Target);
        if (adapter == address(s9Sync2)) return address(s9Target2);
        revert("S9: no target for adapter");
    }

    function _adapterTotalValue() internal view override returns (uint256) {
        return IStrategyAdapter(address(realSyncAdapter)).totalValue()
            + IStrategyAdapter(address(realAsyncAdapter)).totalValue()
            + IStrategyAdapter(address(s9Sync2)).totalValue();
    }
}
