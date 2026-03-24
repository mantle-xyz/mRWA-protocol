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
        return vault.depositFor(msg.sender, assets, msg.sender);
    }

    function redeem(uint256 shares) external nonReentrant returns (uint256 assets) {
        if (syncRedeemDisabled) revert IMantleYieldVault.Vault__SyncRedeemDisabled();
        if (_isSubscribeRedeemPaused()) revert EnforcedPause();
        if (isSanctioned(msg.sender)) {
            vault.routeSanctionedShares(msg.sender, msg.sender, shares);
            return 0;
        }
        _requireWhitelisted(msg.sender);
        return vault.redeemFor(msg.sender, shares, msg.sender, msg.sender);
    }

    function requestRedeem(uint256 shares) external override nonReentrant returns (uint256 requestId) {
        if (_isSubscribeRedeemPaused()) revert EnforcedPause();
        if (isSanctioned(msg.sender)) {
            vault.routeSanctionedShares(msg.sender, msg.sender, shares);
            return 0;
        }
        _requireNotSanctioned(msg.sender);
        _requireWhitelisted(msg.sender);
        return vault.requestRedeemFor(msg.sender, msg.sender, shares);
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

    function resolveRedemptionReceiver(address owner)
        external
        view
        override
        returns (address receiver, bool sanctioned)
    {
        _onlyVault();
        sanctioned = isSanctioned(owner);
        receiver = sanctioned ? sanctionSafe : owner;
    }

    function maxRedeem(address owner) external view override returns (uint256) {
        if (_isSubscribeRedeemPaused() || isSanctioned(owner)) return 0;
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
        return vault.maxDeposit(owner);
    }

    function managementFeeRate() external view override returns (uint256) {
        return IAccountant(vault.accountant()).managementFeeRate();
    }

    function redemptionFeeBps() external view override returns (uint256) {
        return vault.redemptionFeeBps();
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
        try IAccountant(vault.accountant()).getRateSafe() returns (uint64) {
            return false;
        } catch {
            return true;
        }
    }
}
