// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Execution-only surface used by OperatorExecutor.
interface IStrategyControllerExecutor {
    function rebalance() external;
    function processRedeemBatch(uint256[] calldata ids) external;
    function finalizeRedeemBatch(uint256[] calldata ids, uint256[] calldata settledAssets) external;
    function settleAdapter(
        address adapter,
        uint256[] calldata investInFlightIds,
        uint256[] calldata investSettledAmounts,
        uint256[] calldata redeemInFlightIds,
        uint256[] calldata redeemSettledAmounts
    ) external;
    function settleAdapters(
        address[] calldata adapters,
        uint256[][] calldata investInFlightIdsBatch,
        uint256[][] calldata investSettledAmountsBatch,
        uint256[][] calldata redeemInFlightIdsBatch,
        uint256[][] calldata redeemSettledAmountsBatch
    ) external;
}
