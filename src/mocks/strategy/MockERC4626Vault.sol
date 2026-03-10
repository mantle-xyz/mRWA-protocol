// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Minimal ERC4626 vault mock for strategy integration tests.
contract MockERC4626Vault is ERC4626 {
    using SafeERC20 for IERC20;

    constructor(IERC20 asset_, string memory name_, string memory symbol_) ERC20(name_, symbol_) ERC4626(asset_) {}

    /// @notice Fund vault with additional underlying to simulate yield.
    function donateYield(uint256 assets) external {
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
    }
}
