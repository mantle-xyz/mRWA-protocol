// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseAdapter} from "../BaseAdapter.sol";

/// @notice Shared async capability for T+N strategies.
/// @dev In-flight accounting is owned by Vault; adapters only create request ids and call external protocols.
abstract contract BaseAsync7540Adapter is BaseAdapter {
    uint256 public redeemNonce;

    constructor(address vault_, address admin, address controller, address accountant, address priceOracle_)
        BaseAdapter(vault_, admin, controller, accountant, priceOracle_)
    {}

    /// @notice Async strategies generally do not support atomic withdraw.
    function withdrawSync(uint256, address) external pure virtual override returns (uint256) {
        revert Unsupported();
    }

    /**
     * @notice Create a deterministic async redeem request id.
     * @param amount Requested asset amount (vault asset units, e.g. USDC/USDT).
     * @param receiver Receiver used to derive deterministic request id.
     */
    function _registerAsyncRedeem(uint256 amount, address receiver) internal {
        if (amount == 0) {
            revert InvalidAmount();
        }
        if (receiver == address(0)) {
            revert InvalidAddress();
        }

        uint256 nonce = ++redeemNonce;
        bytes32 requestId = keccak256(abi.encode(address(this), receiver, amount, nonce, block.chainid));
        _emitAdapterRedeemRequested(amount, receiver, requestId);
    }
}
