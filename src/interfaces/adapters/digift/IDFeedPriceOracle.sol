// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal interface for Digift DFeedPriceOracle (ST token price in STABLE units).
interface IDFeedPriceOracle {
    function getPrice() external view returns (uint256);
    function decimals() external view returns (uint8);
}
