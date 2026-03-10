// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IStrategyAdapterSync {
    function withdrawSync(uint256 amount, address receiver) external returns (uint256 actualUSDC);
}
