// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {InFlightStatus, RequestStatus} from "./types/VaultTypes.sol";

interface IControllerVault {
    function asset() external view returns (address);
    function totalLockedLiabilities() external view returns (uint256);
    function totalInvestInFlight() external view returns (uint256);
    function totalRedeemInFlight() external view returns (uint256);

    function approveToAdapter(address adapter, address token, uint256 amount) external;
    function updateRequestBatch(uint256[] calldata ids, RequestStatus newStatus) external;
    function markRequestsReady(uint256[] calldata ids) external;

    function createInFlight(address adapter, address asset, uint256 tokenAmount, uint256 usdcAmount, bool isInvest)
        external
        returns (uint256 inFlightId);
    function confirmInFlight(uint256 inFlightId, uint256 actualAmount) external;

    function requests(uint256 requestId)
        external
        view
        returns (uint256 id, address owner, uint256 shares, uint256 assets, uint256 timestamp, RequestStatus status);

    function inFlightRecords(uint256 inFlightId)
        external
        view
        returns (
            uint256 id,
            address adapter,
            address assetAddr,
            uint256 tokenAmount,
            uint256 usdcAmount,
            uint256 settledAmount,
            bool isInvest,
            uint256 timestamp,
            InFlightStatus status
        );
}
