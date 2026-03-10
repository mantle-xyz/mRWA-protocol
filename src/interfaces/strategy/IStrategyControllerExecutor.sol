// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Execution-only surface used by OperatorExecutor.
interface IStrategyControllerExecutor {
    function rebalance() external;
    function processRedeemBatch(uint256[] calldata ids, uint256 batchTotalAsset) external;
    function allocateAssetsBatch(uint256[] calldata ids, uint256[] calldata inFlightIds) external;
    function claimAdapterAssets(address adapter, uint256 posAmount, uint256 assetAmount) external;
}
