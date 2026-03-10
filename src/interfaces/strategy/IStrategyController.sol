// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IStrategyController {
    function rebalance() external;
    function processRedeemBatch(uint256[] calldata ids, uint256 batchTotalAsset) external;
    function allocateAssetsBatch(uint256[] calldata ids, uint256[] calldata inFlightIds) external;
    function claimAdapterAssets(address adapter, uint256 posAmount, uint256 assetAmount) external;
    function setAdapterPaused(address adapter, bool paused_) external;
    function setAdaptersPaused(address[] calldata adapters, bool paused_) external;
}
