// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IMantleYieldVault {
    function asset() external view returns (address);

    function totalLockedLiabilities() external view returns (uint256);
    function totalInFlightAssets() external view returns (uint256);
    function totalLockedLiabilitiesFor(uint256[] calldata ids) external view returns (uint256);

    function approveToAdapter(address adapter, uint256 amount) external;
    function addInFlight(uint256 amount) external;
    function removeInFlight(uint256 amount) external;

    function updateRequestBatch(uint256[] calldata ids, uint8 status) external;
    function markRequestsReady(uint256[] calldata ids) external;
}
