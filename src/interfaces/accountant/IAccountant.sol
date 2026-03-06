// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAccountant
/// @notice Minimal interface for the Accountant contract, consumed by AccountantExecutor
interface IAccountant {
    function updateExchangeRate(uint256 newRate, uint256 computeTimestamp) external;
    function settleManagementFee() external;
}
