// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice 通用 envelope：所有 execute payload 外面都包一层
struct AdapterCall {
    uint64 deadline; // 0 = no deadline
    bytes32 salt; // optional replay protection
    bytes data; // action-specific data
}

library AdapterCodec {
    function decodeCall(bytes calldata payload) internal pure returns (AdapterCall memory c) {
        c = abi.decode(payload, (AdapterCall));
    }
}
