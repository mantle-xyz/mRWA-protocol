// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IStrategyAdapterCore {
    function name() external view returns (string memory);
    function asset() external view returns (address);
    function posToken() external view returns (address);
    function priceOracle() external view returns (address);
    /// @notice Position-token quote in 1e18 precision (asset per 1 pos token).
    /// @dev Returns 1e18 when no oracle is configured; returns 0 when oracle price is invalid.
    function getPosTokenPrice() external view returns (uint256);
    function estimatePosAmount(uint256 assetAmount) external view returns (uint256 positionAmount);
    function vault() external view returns (address);
    function totalValue() external view returns (uint256);
    function deposit(uint256 amount, address receiver) external returns (uint256 sharesOrPos);
    function sweepToVault(address token, uint256 amount) external returns (uint256 claimed);
    function setPaused(bool paused) external;
}
