// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseAdapter} from "../BaseAdapter.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Shared helper layer for ERC-4626 based synchronous strategies.
abstract contract BaseSync4626Adapter is BaseAdapter {
    using SafeERC20 for IERC20;

    IERC4626 public immutable TARGET_4626;

    constructor(address vault_, address target4626, address admin, address controller, address accountant)
        BaseAdapter(vault_, admin, controller, accountant, address(0))
    {
        TARGET_4626 = IERC4626(target4626);
    }

    /// @notice Sync-only strategies generally do not implement async request flow.
    function requestRedeemAsync(uint256, address) external pure virtual override {
        revert Unsupported();
    }

    /// @notice Sync-only strategies do not support retrying async redeem requests.
    function retryRedeemAsync(uint256, address) external pure virtual override {
        revert Unsupported();
    }

    function _erc4626Deposit(uint256 amount, address receiver) internal returns (uint256 sharesOrPos) {
        ASSET.forceApprove(address(TARGET_4626), amount);
        sharesOrPos = TARGET_4626.deposit(amount, receiver);
        ASSET.forceApprove(address(TARGET_4626), 0);
        _emitAdapterDeposit(amount, receiver, sharesOrPos);
    }

    function _erc4626Redeem(uint256 shares, address receiver, address owner) internal returns (uint256 actualAssets) {
        actualAssets = TARGET_4626.redeem(shares, receiver, owner);
        _emitAdapterWithdrawSync(shares, receiver, actualAssets);
    }
}
