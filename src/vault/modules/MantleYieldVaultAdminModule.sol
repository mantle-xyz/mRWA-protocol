// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC7540Redeem, IMantleYieldVault} from "../../interfaces/vault/IMantleYieldVault.sol";
import {MantleYieldVaultStorage} from "./MantleYieldVaultStorage.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

abstract contract MantleYieldVaultAdminModule is MantleYieldVaultStorage {
    using SafeERC20 for IERC20;

    // =============================================================
    // Admin Only: Redemption Fee Management
    // =============================================================

    function setRedemptionFee(uint256 newFeeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newFeeBps > maxRedemptionFeeBps) revert Vault__FeeTooHigh(newFeeBps, maxRedemptionFeeBps);
        uint256 oldFeeBps = redemptionFeeBps;
        redemptionFeeBps = newFeeBps;
        emit RedemptionFeeUpdated(oldFeeBps, newFeeBps);
        if (totalLockedShares > 0) {
            emit FeeChangedWithLockedShares(totalLockedShares, oldFeeBps, newFeeBps);
        }
    }

    function setMaxRedemptionFee(uint256 newMaxBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMaxBps > FEE_BASIS) revert Vault__FeeTooHigh(newMaxBps, FEE_BASIS);
        uint256 old = maxRedemptionFeeBps;
        maxRedemptionFeeBps = newMaxBps;
        if (redemptionFeeBps > newMaxBps) {
            uint256 oldFee = redemptionFeeBps;
            redemptionFeeBps = newMaxBps;
            emit RedemptionFeeUpdated(oldFee, newMaxBps);
            if (totalLockedShares > 0) {
                emit FeeChangedWithLockedShares(totalLockedShares, oldFee, newMaxBps);
            }
        }
        emit MaxRedemptionFeeUpdated(old, newMaxBps);
    }

    function setMinRedeemAmount(uint256 newAmount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldAmount = minRedeemAmount;
        minRedeemAmount = newAmount;
        emit MinRedeemAmountUpdated(oldAmount, newAmount);
    }

    function setMinDepositAmount(uint256 newAmount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldAmount = minDepositAmount;
        minDepositAmount = newAmount;
        emit MinDepositAmountUpdated(oldAmount, newAmount);
    }

    function setMaxSettlementDeviation(uint256 newBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newBps > MAX_SETTLEMENT_DEVIATION_CEILING) {
            revert Vault__InvalidSettlementDeviation(newBps);
        }
        uint256 old = maxSettlementDeviationBps;
        maxSettlementDeviationBps = newBps;
        emit SettlementDeviationUpdated(old, newBps);
    }

    function setGateway(address newGateway) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newGateway == address(0)) revert Vault__ZeroAddress();
        address old = gateway;
        gateway = newGateway;
        emit GatewayUpdated(old, newGateway);
    }

    function setController(address newController) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newController == address(0)) revert Vault__ZeroAddress();
        address old = controller;
        controller = newController;
        emit ControllerUpdated(old, newController);
    }

    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury == address(0)) revert Vault__ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    function setAccountant(address newAccountant) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newAccountant == address(0)) revert Vault__ZeroAddress();
        address old = accountant;
        accountant = newAccountant;
        emit AccountantUpdated(old, newAccountant);
    }

    // =============================================================
    // Accountant Only
    // =============================================================

    function mintFeeShares(uint256 shares) external onlyAccountant whenNotPaused {
        _mint(treasury, shares);
        emit FeeSharesReceived(treasury, shares, FeeType.Management);
    }

    // =============================================================
    // ERC-165 & Emergency Management
    // =============================================================

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IERC7540Redeem).interfaceId || interfaceId == type(IMantleYieldVault).interfaceId
            || super.supportsInterface(interfaceId);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function rescueTokens(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == asset()) revert Vault__RescueAssetCannotBeUnderlying();
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }
}
