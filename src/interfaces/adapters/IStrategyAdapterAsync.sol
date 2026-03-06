// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IStrategyAdapterAsync {
    function requestRedeemAsync(uint256 amount, address receiver) external returns (bytes32 requestId);
}
