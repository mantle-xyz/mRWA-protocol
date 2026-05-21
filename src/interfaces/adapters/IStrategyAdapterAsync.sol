// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IStrategyAdapterAsync {
    function requestRedeemAsync(uint256 posAmount, address receiver) external;
    function retryRedeemAsync(uint256 posAmount, address receiver) external;
}
