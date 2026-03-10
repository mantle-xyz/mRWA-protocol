// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IStrategyAdapterCore {
    function name() external view returns (string memory);
    function asset() external view returns (address);
    function posToken() external view returns (address);
    function estimatePosAmount(uint256 assetAmount) external view returns (uint256 positionAmount);
    function vault() external view returns (address);
    function totalValue() external view returns (uint256);
    function deposit(uint256 amount, address receiver) external returns (uint256 sharesOrPos);
    function claimToVault(address token, uint256 amount) external returns (uint256 claimed);
    function setPaused(bool p) external;
}
