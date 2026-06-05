// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAccountant} from "../interfaces/accountant/IAccountant.sol";
import {ISanctionsOracle} from "../interfaces/compliance/ISanctionsOracle.sol";
import {IMantleVaultGateway} from "../interfaces/vault/IMantleVaultGateway.sol";
import {IMantleYieldVault} from "../interfaces/vault/IMantleYieldVault.sol";
import {
    AccessControlDefaultAdminRulesUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title MantleVaultGateway
 * @notice User-facing entrypoint for vault interactions and sanctions enforcement.
 *         Deployed behind BeaconProxy and configured via initialize().
 */
contract MantleVaultGateway is
    Initializable,
    AccessControlDefaultAdminRulesUpgradeable,
    ReentrancyGuard,
    IMantleVaultGateway
{
    error EnforcedPause();

    IMantleYieldVault public vault;
    ISanctionsOracle public sanctionsOracle;
    address public sanctionSafe;
    bool public syncRedeemDisabled;
    bool public whitelistEnabled;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(InitParams calldata params) external override initializer {
        if (
            params.vault == address(0) || address(params.sanctionsOracle) == address(0)
                || params.sanctionSafe == address(0) || params.admin == address(0)
        ) {
            revert IMantleYieldVault.Vault__ZeroAddress();
        }

        __AccessControlDefaultAdminRules_init(3 days, params.admin);
        vault = IMantleYieldVault(params.vault);
        sanctionsOracle = params.sanctionsOracle;
        sanctionSafe = params.sanctionSafe;
        syncRedeemDisabled = params.syncRedeemDisabled;
    }

    function deposit(uint256 assets) external nonReentrant returns (uint256 shares) {
        if (_isSubscribeRedeemPaused()) revert EnforcedPause();
        _requireNotSanctioned(msg.sender);
        _requireWhitelisted(msg.sender);
        return vault.deposit(assets, msg.sender);
    }

    function redeem(uint256 shares) external nonReentrant returns (uint256 assets) {
        if (syncRedeemDisabled) revert IMantleYieldVault.Vault__SyncRedeemDisabled();
        if (_isSubscribeRedeemPaused()) revert EnforcedPause();
        if (isSanctioned(msg.sender)) {
            vault.routeSanctionedShares(msg.sender, shares);
            return 0;
        }
        _requireWhitelisted(msg.sender);
        return vault.redeem(shares, msg.sender, msg.sender);
    }

    function requestRedeem(uint256 shares) external override nonReentrant returns (uint256 requestId) {
        if (_isSubscribeRedeemPaused()) revert EnforcedPause();
        if (isSanctioned(msg.sender)) {
            vault.routeSanctionedShares(msg.sender, shares);
            return 0;
        }
        _requireWhitelisted(msg.sender);
        return vault.requestRedeem(msg.sender, shares);
    }

    function setSyncRedeemDisabled(bool disabled) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        syncRedeemDisabled = disabled;
        emit SyncRedeemDisabledUpdated(disabled);
    }

    function setSanctionsOracle(address newOracle) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newOracle == address(0)) revert IMantleYieldVault.Vault__ZeroAddress();
        address old = address(sanctionsOracle);
        sanctionsOracle = ISanctionsOracle(newOracle);
        emit SanctionsOracleUpdated(old, newOracle);
    }

    function setSanctionSafe(address newSanctionSafe) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newSanctionSafe == address(0)) revert IMantleYieldVault.Vault__ZeroAddress();
        address old = sanctionSafe;
        sanctionSafe = newSanctionSafe;
        emit SanctionSafeUpdated(old, newSanctionSafe);
    }

    function setWhitelistEnabled(bool enabled) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        whitelistEnabled = enabled;
        emit WhitelistEnabledUpdated(enabled);
    }

    function isSanctionSafe(address account) external view override returns (bool) {
        return account == sanctionSafe;
    }

    function isSanctioned(address account) public view override returns (bool) {
        return sanctionsOracle.isSanctioned(account);
    }

    function isWhitelisted(address account) public view override returns (bool) {
        return sanctionsOracle.isWhitelisted(account);
    }

    function enforceShareTransfer(address from, address to) external view override {
        _onlyVault();
        _requireNotSanctioned(from);
        _requireNotSanctioned(to);
    }

    /// @notice Resolve the redemption payout receiver for a given owner.
    /// @dev The returned `sanctioned` flag signals "the payout was rerouted for compliance reasons":
    ///      `true` whenever the owner is sanctioned OR (whitelist is enabled AND the owner is no longer whitelisted).
    ///      In both cases the receiver is `sanctionSafe` so the payout does not reach a non-compliant address,
    ///      while the batch can still finalize without reverting (the vault emits `SanctionSafeIn` on this branch).
    function resolveRedemptionReceiver(address owner)
        external
        view
        override
        returns (address receiver, bool sanctioned)
    {
        _onlyVault();
        bool sanctionedFlag = isSanctioned(owner);
        bool deWhitelisted = whitelistEnabled && !sanctionsOracle.isWhitelisted(owner);
        if (sanctionedFlag || deWhitelisted) {
            sanctioned = true;
            receiver = sanctionSafe;
        } else {
            receiver = owner;
        }
    }

    function maxRedeem(address owner) external view override returns (uint256) {
        if (_isSubscribeRedeemPaused() || isSanctioned(owner)) return 0;
        if (whitelistEnabled && !isWhitelisted(owner)) return 0;
        return vault.maxRedeem(owner);
    }

    function previewRedeem(uint256 shares) external view override returns (uint256) {
        return vault.previewRedeem(shares);
    }

    function previewDeposit(uint256 assets) external view override returns (uint256) {
        return vault.previewDeposit(assets);
    }

    function maxDeposit(address owner) external view override returns (uint256) {
        if (_isSubscribeRedeemPaused() || isSanctioned(owner)) return 0;
        if (whitelistEnabled && !isWhitelisted(owner)) return 0;
        return vault.maxDeposit(owner);
    }

    function managementFeeRate() external view override returns (uint256) {
        return IAccountant(vault.accountant()).managementFeeRate();
    }

    function redemptionFeeBps() external view override returns (uint256) {
        return vault.redemptionFeeBps();
    }

    function minRedeemAmount() external view override returns (uint256) {
        return vault.minRedeemAmount();
    }

    function minDepositAmount() external view override returns (uint256) {
        return vault.minDepositAmount();
    }

    function exchangeRate() external view override returns (uint256) {
        return vault.exchangeRate();
    }

    function totalAssets() external view override returns (uint256) {
        return vault.totalAssets();
    }

    function getTokenInfos() external view override returns (IMantleYieldVault.tokenInfo[] memory) {
        return vault.getTokenInfos();
    }

    function getFreeCash() external view override returns (uint256) {
        return vault.getFreeCash();
    }

    function _onlyVault() internal view {
        if (msg.sender != address(vault)) revert IMantleYieldVault.Vault__NotAuthorized();
    }

    function _requireNotSanctioned(address account) internal view {
        if (isSanctioned(account)) revert IMantleYieldVault.Vault__Sanctioned(account);
    }

    function _requireWhitelisted(address account) internal view {
        if (whitelistEnabled && !isWhitelisted(account)) {
            revert Gateway__NotWhitelisted(account);
        }
    }

    function _isSubscribeRedeemPaused() internal view returns (bool paused_) {
        return Pausable(vault.accountant()).paused();
    }
}
