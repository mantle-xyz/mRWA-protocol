// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IMantleYieldVault
/// @notice Minimal interface consumed by Accountant and StrategyController
interface IMantleYieldVault {
    // ---- Accountant-only ----

    function updateExchangeRate(uint256 newRate) external;

    function mintFeeShares(address treasury, uint256 shares) external;

    // ---- Controller-only ----

    function approveToAdapter(address adapter, uint256 amount) external;

    function updateRequestBatch(uint256[] calldata ids, uint8 newStatus) external;

    function markRequestsReady(uint256[] calldata ids) external;

    function addInFlight(uint256 amount) external;

    function removeInFlight(uint256 amount) external;

    // ---- Public views ----

    function asset() external view returns (address);

    function exchangeRate() external view returns (uint256);

    function totalLockedLiabilities() external view returns (uint256);

    function totalInFlightAssets() external view returns (uint256);

    function claimableReserves() external view returns (uint256);
}
