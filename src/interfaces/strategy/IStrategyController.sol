// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IStrategyController {
    function rebalance() external;
    function processRedeemBatch(uint256[] calldata ids, uint256 batchTotalUSDC) external;
    function allocateAssetsBatch(uint256[] calldata ids, uint256 clearedInFlightAmount) external;
}
