// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Execution-only surface used by OperatorExecutor.
interface IStrategyControllerExecutor {
    function rebalance() external;
    function processRedeemBatch(uint256[] calldata ids, uint256 batchTotalAsset) external;
    function finalizeRedeemBatch(
        uint256[] calldata ids,
        uint256[] calldata inFlightIds,
        address[] calldata sweepAdapters,
        uint256[] calldata posAmounts,
        uint256[] calldata assetAmounts
    ) external;
    function settleAdapter(
        address adapter,
        uint256 posAmount,
        uint256 assetAmount,
        uint256[] calldata investInFlightIds,
        uint256[] calldata redeemInFlightIds,
        uint256[] calldata ids
    ) external;
    function settleAdapters(
        address[] calldata adapters,
        uint256[] calldata posAmounts,
        uint256[] calldata assetAmounts,
        uint256[] calldata investInFlightIds,
        uint256[] calldata redeemInFlightIds,
        uint256[] calldata ids
    ) external;
}
