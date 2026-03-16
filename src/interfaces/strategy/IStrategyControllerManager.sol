// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Management/governance surface for strategy configuration and emergency controls.
interface IStrategyControllerManager {
    function setRiskParams(uint16 bufferTargetBps_, uint16 rebalanceThresholdBps_, uint64 rebalanceCooldown_) external;

    function registerStrategy(address adapter, uint16 targetWeightBps, uint16 priority, bool isAsync, bool isActive)
        external;

    function updateStrategies(
        address[] calldata adapters,
        uint16[] calldata targetWeightBpsList,
        uint16[] calldata priorities,
        bool[] calldata isAsyncList,
        bool[] calldata isActiveList
    ) external;

    function updateStrategiesAndOrder(
        address[] calldata adapters,
        uint16[] calldata targetWeightBpsList,
        uint16[] calldata priorities,
        bool[] calldata isAsyncList,
        bool[] calldata isActiveList,
        address[] calldata orderedStrategies
    ) external;

    function setStrategyOrder(address[] calldata orderedStrategies) external;
    function setAdapterPaused(address adapter, bool paused_) external;
    function setAdaptersPaused(address[] calldata adapters, bool paused_) external;
}
