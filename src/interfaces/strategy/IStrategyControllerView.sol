// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Read-only surface for Accountant/frontends/monitoring.
interface IStrategyControllerView {
    function asset() external view returns (address);
    function vault() external view returns (address);

    function bufferTargetBps() external view returns (uint16);
    function rebalanceThresholdBps() external view returns (uint16);
    function rebalanceCooldown() external view returns (uint64);
    function lastRebalance() external view returns (uint64);

    function strategyOrderLength() external view returns (uint256);
    function strategyOrder(uint256 index) external view returns (address);

    function strategyInfo(address adapter)
        external
        view
        returns (
            uint16 targetWeightBps,
            uint16 priority,
            bool isAsync,
            bool isActive,
            bool exists,
            address receiptReceiver
        );
}
