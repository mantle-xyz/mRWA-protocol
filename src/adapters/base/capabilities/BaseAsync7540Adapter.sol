// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseAdapter} from "../BaseAdapter.sol";

/// @notice Shared async capability for T+N strategies.
/// @dev In-flight accounting is owned by Vault; adapters only emit request events and call external protocols.
abstract contract BaseAsync7540Adapter is BaseAdapter {
    constructor(address vault_, address admin, address controller, address accountant, address priceOracle_)
        BaseAdapter(vault_, admin, controller, accountant, priceOracle_)
    {}

    /// @notice Async strategies generally do not support atomic withdraw.
    function withdrawSync(uint256, address) external pure virtual override returns (uint256) {
        revert Adapter__Unsupported();
    }

    /// @notice Retry path is adapter-specific and must be explicitly implemented by concrete async adapters.
    function retryRedeemAsync(uint256, address) external virtual override {
        revert Adapter__Unsupported();
    }

    /**
     * @notice Emit the standardized async redeem request event.
     * @param posAmount Requested protocol redeem quantity.
     * @dev For quantity-driven adapters, the emitted amount is position-token quantity,
     *      not an asset-denominated accounting value.
     * @param receiver Receiver recorded in the standardized async redeem request event.
     */
    function _registerAsyncRedeem(uint256 posAmount, address receiver) internal {
        if (posAmount == 0) {
            revert Adapter__InvalidAmount();
        }
        if (receiver == address(0)) {
            revert Adapter__InvalidAddress();
        }

        _emitAdapterRedeemRequested(posAmount, receiver);
    }
}
