// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseSync4626Adapter} from "../base/capabilities/BaseSync4626Adapter.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Concrete sync adapter using an ERC4626 target. Useful for testnet flow validation.
contract MockSync4626Adapter is BaseSync4626Adapter {
    using SafeERC20 for IERC20;

    constructor(address vault_, address target4626, address admin, address controller, address accountant)
        BaseSync4626Adapter(vault_, target4626, admin, controller, accountant)
    {}

    function name() external pure override returns (string memory) {
        return "MockSync4626Adapter";
    }

    function posToken() external view override returns (address) {
        return address(TARGET_4626);
    }

    function estimatePosAmount(uint256 assetAmount) external view override returns (uint256 positionAmount) {
        positionAmount = TARGET_4626.previewDeposit(assetAmount);
    }

    function totalValue() external view override returns (uint256) {
        uint256 idle = ASSET.balanceOf(address(this));
        uint256 shares =
            IERC20(address(TARGET_4626)).balanceOf(address(this)) + IERC20(address(TARGET_4626)).balanceOf(VAULT);
        uint256 deployed = IERC4626(address(TARGET_4626)).convertToAssets(shares);
        return idle + deployed;
    }

    function deposit(uint256 amount, address receiver)
        external
        override
        onlyController
        whenNotPaused
        returns (uint256 sharesOrPos)
    {
        if (amount == 0) revert InvalidAmount();
        receiver; // receipt location is adapter for sync-4626 mode.
        ASSET.safeTransferFrom(VAULT, address(this), amount);
        sharesOrPos = _erc4626Deposit(amount, address(this));
    }

    function withdrawSync(uint256 amount, address receiver)
        external
        override
        onlyController
        whenNotPaused
        returns (uint256 actualUSDC)
    {
        if (amount == 0) revert InvalidAmount();
        (actualUSDC,) = _erc4626Withdraw(amount, receiver, VAULT);
    }
}
