// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title TellerWithMultiAssetSupport
 * @notice UUPS proxy contract for MantleYieldVault.
 *   - All business logic resides in the MantleYieldVault implementation
 *   - Initialization is performed via _data calling initialize() at deployment
 *   - Subsequent upgrades are governed by _authorizeUpgrade (DEFAULT_ADMIN_ROLE) in the implementation
 */
contract TellerWithMultiAssetSupport is ERC1967Proxy {
    constructor(address implementation, bytes memory _data) ERC1967Proxy(implementation, _data) {}
}
