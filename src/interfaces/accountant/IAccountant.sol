// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAccountant
/// @notice Minimal interface for the Accountant contract, consumed by AccountantExecutor and AccountantFactory
interface IAccountant {
    function initialize(
        address vault_,
        uint64 initialRate,
        uint32 managementFeeRate_,
        uint32 maxAllowedDeviation_,
        uint32 minUpdateInterval_,
        uint32 maxComputeAge_,
        address admin,
        address pauser_,
        address executor_
    ) external;

    function updateExchangeRate(uint64 newRate, uint64 computeTimestamp) external;

    function settleManagementFee() external;

    function getRate() external view returns (uint256);
    function getRateSafe() external view returns (uint256);
    function managementFeeRate() external view returns (uint32);
    function pause() external;
}
