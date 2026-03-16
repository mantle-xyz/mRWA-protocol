// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAccountant
/// @notice Minimal interface for the Accountant contract, consumed by AccountantExecutor and AccountantFactory
interface IAccountant {
    function initialize(address vault_, uint64 initialRate, uint32 managementFeeRate_, address admin) external;

    function updateExchangeRate(uint64 newRate, uint64 computeTimestamp) external;

    function getRate() external view returns (uint64);
    function getRateSafe() external view returns (uint64);
    function managementFeeRate() external view returns (uint32);
}
