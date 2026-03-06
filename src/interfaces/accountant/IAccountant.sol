// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAccountant
/// @notice Minimal interface for the Accountant contract, consumed by AccountantExecutor and AccountantFactory
interface IAccountant {
    function initialize(
        address vault_,
        address treasury_,
        uint256 initialRate,
        uint256 managementFeeRate_,
        address admin
    ) external;

    function updateExchangeRate(uint256 newRate, uint256 computeTimestamp) external;
    function settleManagementFee() external;
}
