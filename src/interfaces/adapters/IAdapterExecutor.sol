// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAdapterExecutor {
    /// @notice Bot-only 执行入口：payload 内编码具体 action 与参数
    function execute(bytes calldata payload) external returns (bytes32 execId);
}
