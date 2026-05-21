// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseAdapter} from "../BaseAdapter.sol";

/// @notice Shared low-level execution helper for BoringVault-style integrations.
abstract contract BaseBoringVaultAdapter is BaseAdapter {
    address public immutable BORING_VAULT;

    error Adapter__BoringVaultCallFailed(bytes data);

    constructor(address vault_, address boringVault, address admin, address controller, address accountant)
        BaseAdapter(vault_, admin, controller, accountant, address(0))
    {
        BORING_VAULT = boringVault;
    }

    function _callBoringVault(bytes memory data) internal returns (bytes memory result) {
        (bool ok, bytes memory ret) = BORING_VAULT.call(data);
        if (!ok) {
            revert Adapter__BoringVaultCallFailed(ret);
        }
        result = ret;
    }
}
