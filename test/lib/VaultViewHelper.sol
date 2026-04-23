// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";

/**
 * @title VaultViewHelper — stack-depth-safe accessors for MantleYieldVault public mappings
 * @dev `vault.requests(id)` returns 8 values and `vault.inFlightRecords(id)` returns 9.
 *      Without `viaIR` (as in `forge coverage`), each destructuring consumes 8-9 EVM stack
 *      slots at once, easily exceeding the 16-slot limit inside non-trivial test functions.
 *
 *      This library wraps each access pattern in its own `internal view` function so the
 *      tuple destructuring happens in an isolated stack frame.  Use with:
 *
 *          using VaultViewHelper for MantleYieldVault;
 *
 *      Then replace:
 *          (,,,,,,,IMantleYieldVault.RequestStatus status) = vault.requests(id);
 *      With:
 *          IMantleYieldVault.RequestStatus status = vault.reqStatus(id);
 */
library VaultViewHelper {
    // ═══════════════════════════════════════════════════════════════════════
    //  requests()  — RedemptionRequest (8 fields)
    //  [0] id, [1] owner, [2] shares, [3] feeShares,
    //  [4] estimatedAssets, [5] settledAssets, [6] timestamp, [7] status
    // ═══════════════════════════════════════════════════════════════════════

    function reqStatus(MantleYieldVault v, uint256 id)
        internal
        view
        returns (IMantleYieldVault.RequestStatus status)
    {
        (,,,,,,, status) = v.requests(id);
    }

    function reqEstimate(MantleYieldVault v, uint256 id) internal view returns (uint256 estimatedAssets) {
        (,,,, estimatedAssets,,,) = v.requests(id);
    }

    function reqShares(MantleYieldVault v, uint256 id) internal view returns (uint256 shares) {
        (,, shares,,,,,) = v.requests(id);
    }

    function reqSettled(MantleYieldVault v, uint256 id) internal view returns (uint256 settledAssets) {
        (,,,,, settledAssets,,) = v.requests(id);
    }

    function reqFeeShares(MantleYieldVault v, uint256 id) internal view returns (uint256 feeShares) {
        (,,, feeShares,,,,) = v.requests(id);
    }

    function reqOwner(MantleYieldVault v, uint256 id) internal view returns (address owner) {
        (, owner,,,,,,) = v.requests(id);
    }

    // ─── multi-field ────────────────────────────────────────────────────

    function reqSharesAndStatus(MantleYieldVault v, uint256 id)
        internal
        view
        returns (uint256 shares, IMantleYieldVault.RequestStatus status)
    {
        (,, shares,,,,, status) = v.requests(id);
    }

    function reqOwnerAndShares(MantleYieldVault v, uint256 id)
        internal
        view
        returns (address owner, uint256 shares)
    {
        (, owner, shares,,,,,) = v.requests(id);
    }

    function reqCore(MantleYieldVault v, uint256 id)
        internal
        view
        returns (
            uint256 shares,
            uint256 feeShares,
            uint256 estimatedAssets,
            uint256 settledAssets,
            IMantleYieldVault.RequestStatus status
        )
    {
        (,, shares, feeShares, estimatedAssets, settledAssets,, status) = v.requests(id);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  inFlightRecords()  — InFlightRecord (9 fields)
    //  [0] id, [1] adapter, [2] token, [3] tokenAmount,
    //  [4] usdcAmount, [5] settledAmount, [6] isInvest, [7] timestamp, [8] status
    // ═══════════════════════════════════════════════════════════════════════

    function ifStatus(MantleYieldVault v, uint256 id)
        internal
        view
        returns (IMantleYieldVault.InFlightStatus status)
    {
        (,,,,,,,, status) = v.inFlightRecords(id);
    }

    function ifTokenAmount(MantleYieldVault v, uint256 id) internal view returns (uint256 tokenAmount) {
        (,,, tokenAmount,,,,,) = v.inFlightRecords(id);
    }

    function ifUsdcAmount(MantleYieldVault v, uint256 id) internal view returns (uint256 usdcAmount) {
        (,,,, usdcAmount,,,,) = v.inFlightRecords(id);
    }

    function ifSettledAmount(MantleYieldVault v, uint256 id) internal view returns (uint256 settledAmount) {
        (,,,,, settledAmount,,,) = v.inFlightRecords(id);
    }

    function ifTokenAndUsdc(MantleYieldVault v, uint256 id)
        internal
        view
        returns (uint256 tokenAmount, uint256 usdcAmount)
    {
        (,,, tokenAmount, usdcAmount,,,,) = v.inFlightRecords(id);
    }

    function ifSettledAndStatus(MantleYieldVault v, uint256 id)
        internal
        view
        returns (uint256 settledAmount, IMantleYieldVault.InFlightStatus status)
    {
        (,,,,, settledAmount,,, status) = v.inFlightRecords(id);
    }

    function ifFull(MantleYieldVault v, uint256 id)
        internal
        view
        returns (
            address adapter,
            uint256 tokenAmount,
            uint256 usdcAmount,
            bool isInvest,
            IMantleYieldVault.InFlightStatus status
        )
    {
        (, adapter,, tokenAmount, usdcAmount,, isInvest,, status) = v.inFlightRecords(id);
    }

    function ifAdapterAndStatus(MantleYieldVault v, uint256 id)
        internal
        view
        returns (address adapter, bool isInvest, IMantleYieldVault.InFlightStatus status)
    {
        (, adapter,,,,,isInvest,, status) = v.inFlightRecords(id);
    }

    function ifAssetAndAmounts(MantleYieldVault v, uint256 id)
        internal
        view
        returns (address token, uint256 tokenAmount, uint256 usdcAmount)
    {
        (,, token, tokenAmount, usdcAmount,,,,) = v.inFlightRecords(id);
    }
}
