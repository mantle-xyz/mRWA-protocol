// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMantleVaultGateway} from "../../interfaces/vault/IMantleVaultGateway.sol";
import {MantleYieldVaultStorage} from "./MantleYieldVaultStorage.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

abstract contract MantleYieldVaultControllerModule is MantleYieldVaultStorage {
    using SafeERC20 for IERC20;

    // =============================================================
    // Controller Only: Asset Approval, Request Lifecycle & In-Flight Accounting
    // =============================================================

    function registerAdapter(address adapter) external onlyController {
        if (adapter == address(0)) revert Vault__ZeroAddress();
        if (isAdapter[adapter]) revert Vault__AdapterAlreadyRegistered(adapter);
        adapters.push(adapter);
        isAdapter[adapter] = true;
        emit AdapterRegistered(adapter);
    }

    function removeAdapter(address adapter) external onlyController {
        if (!isAdapter[adapter]) revert Vault__AdapterNotRegistered(adapter);
        if (adapterInvestInFlightTokens[adapter] > 0 || adapterRedeemInFlightUsdc[adapter] > 0) {
            revert Vault__AdapterHasInFlight(adapter);
        }
        IERC20(asset()).forceApprove(adapter, 0);
        isAdapter[adapter] = false;
        uint256 len = adapters.length;
        for (uint256 i = 0; i < len; i++) {
            if (adapters[i] == adapter) {
                adapters[i] = adapters[len - 1];
                adapters.pop();
                break;
            }
        }
        emit AdapterRemoved(adapter);
    }

    function getAdapters() external view returns (address[] memory) {
        return adapters;
    }

    function approveToAdapter(address adapter, address token, uint256 amount) external onlyController {
        if (!isAdapter[adapter]) revert Vault__AdapterNotRegistered(adapter);
        IERC20(token).forceApprove(adapter, amount);
        emit AdapterApproved(adapter, token, amount);
    }

    function updateRequestBatch(uint256[] calldata ids, RequestStatus newStatus) external onlyController {
        if (newStatus == RequestStatus.NONE || newStatus == RequestStatus.DONE) {
            revert Vault__StatusTransitionForbidden(newStatus);
        }

        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            RequestStatus current = requests[id].status;
            // Request status is strictly monotonic: transitions must move forward only.
            if (current == RequestStatus.NONE || uint8(newStatus) <= uint8(current)) {
                revert Vault__InvalidState(id, current);
            }
            // Keep global pending count in sync for O(1) pending-request checks.
            if (current == RequestStatus.PENDING && pendingRequestCount > 0) {
                pendingRequestCount--;
            }
            requests[id].status = newStatus;
        }
        emit RequestBatchUpdated(ids, newStatus);
    }

    /**
     * @notice Mark redemption requests as READY with actual settlement amounts.
     * @dev settledAssets[i] is determined by the controller based on actual adapter returns
     *      or current exchange rate. totalLockedShares is released here.
     * @param ids Request IDs to mark done
     * @param settledAssets Actual USDC amount each request will receive
     */
    function markRequestsDone(uint256[] calldata ids, uint256[] calldata settledAssets) external onlyController {
        if (ids.length != settledAssets.length) revert Vault__LengthMismatch(ids.length, settledAssets.length);

        uint256 releasedShares = 0;

        uint256 physicalCash = IERC20(asset()).balanceOf(address(this));

        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            RedemptionRequest storage req = requests[id];

            if (req.status != RequestStatus.PROCESSING) revert Vault__InvalidState(id, req.status);

            uint256 actual = settledAssets[i];
            if (actual == 0) revert Vault__ZeroAmount();

            if (actual != req.estimatedAssets) {
                emit RequestSettlementAdjusted(id, req.estimatedAssets, actual);
            }

            if (physicalCash < actual) {
                revert Vault__InsufficientPhysicalCash(ids, settledAssets, IERC20(asset()).balanceOf(address(this)));
            }

            req.status = RequestStatus.DONE;
            req.settledAssets = actual;
            releasedShares += req.shares;

            _pendingShares[req.owner] -= req.shares;
            (address receiver, bool sanctioned) = gateway != address(0)
                ? IMantleVaultGateway(gateway).resolveRedemptionReceiver(req.owner)
                : (req.owner, false);
            if (sanctioned) {
                IERC20(asset()).safeTransfer(receiver, actual);
                emit SanctionSafeIn(req.owner, asset(), actual);
            } else {
                IERC20(asset()).safeTransfer(receiver, actual);
                emit RedemptionDone(req.owner, receiver, req.shares, actual, req.estimatedAssets);
            }
            physicalCash -= actual;
        }
        totalLockedShares -= releasedShares;

        emit RequestBatchUpdated(ids, RequestStatus.DONE);
    }

    /**
     * @notice Create an in-flight record for rebalancing operations
     * @param isInvest true = invest (USDC out, waiting for tokens); false = redeem (tokens out, waiting for USDC)
     * @param tokenAmount Invest: expected incoming token amount; Redeem: outgoing token amount
     * @param usdcAmount  Invest: outgoing USDC amount;           Redeem: expected incoming USDC amount
     */
    function createInFlight(address adapter, address token, uint256 tokenAmount, uint256 usdcAmount, bool isInvest)
        external
        onlyController
        returns (uint256 inFlightId)
    {
        if (!isAdapter[adapter]) revert Vault__AdapterNotRegistered(adapter);
        if (usdcAmount == 0 || tokenAmount == 0) revert Vault__ZeroAmount();

        inFlightId = nextInFlightId++;
        inFlightRecords[inFlightId] = InFlightRecord({
            id: inFlightId,
            adapter: adapter,
            token: token,
            tokenAmount: tokenAmount,
            usdcAmount: usdcAmount,
            settledAmount: 0,
            isInvest: isInvest,
            timestamp: block.timestamp,
            status: InFlightStatus.PENDING
        });

        if (isInvest) {
            totalInvestInFlight += usdcAmount;
            adapterInvestInFlightTokens[adapter] += tokenAmount;
        } else {
            totalRedeemInFlight += usdcAmount;
            adapterRedeemInFlightUsdc[adapter] += usdcAmount;
        }

        emit InFlightCreated(inFlightId, adapter, token, tokenAmount, usdcAmount, isInvest);
    }

    /**
     * @notice Confirm an in-flight record (assets have arrived)
     * @param actualAmount Actual settled amount (invest: actual tokens received; redeem: actual USDC received)
     */
    function confirmInFlight(uint256 inFlightId, uint256 actualAmount, bool isAbnormal) external onlyController {
        if (actualAmount == 0 && !isAbnormal) revert Vault__ZeroAmount();
        InFlightRecord storage r = inFlightRecords[inFlightId];
        if (r.status != InFlightStatus.PENDING) revert Vault__InvalidInFlightState(inFlightId, r.status);

        r.status = InFlightStatus.CONFIRMED;
        r.settledAmount = actualAmount;

        if (r.isInvest) {
            // Invest confirmed: tokens arrived, clear USDC in-flight
            if (totalInvestInFlight < r.usdcAmount) revert Vault__Underflow(totalInvestInFlight, r.usdcAmount);
            totalInvestInFlight -= r.usdcAmount;
            adapterInvestInFlightTokens[r.adapter] -= r.tokenAmount;
        } else {
            // Redeem confirmed: USDC arrived, clear USDC in-flight
            if (totalRedeemInFlight < r.usdcAmount) revert Vault__Underflow(totalRedeemInFlight, r.usdcAmount);
            totalRedeemInFlight -= r.usdcAmount;
            adapterRedeemInFlightUsdc[r.adapter] -= r.usdcAmount;
        }

        emit InFlightConfirmed(inFlightId, r.adapter, r.tokenAmount, r.usdcAmount, actualAmount);
    }
}
