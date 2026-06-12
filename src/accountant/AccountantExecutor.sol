// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAccountant} from "../interfaces/accountant/IAccountant.sol";
import {IStrategyAdapterCore} from "../interfaces/adapters/IStrategyAdapterCore.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title AccountantExecutor
/// @notice Authorized relay for Accountant operations and adapter manual price updates.
///         BOT_ROLE can trigger exchange rate updates and adapter manual price
///         updates, and FEE_SETTLER_ROLE can trigger management fee settlement.
///         DEFAULT_ADMIN_ROLE manages executor role membership and authorizes upgrades.
contract AccountantExecutor is AccessControlUpgradeable, UUPSUpgradeable {
    // =============================================================
    //                        CONSTANTS
    // =============================================================

    bytes32 public constant BOT_ROLE = keccak256("BOT_ROLE");
    bytes32 public constant FEE_SETTLER_ROLE = keccak256("FEE_SETTLER_ROLE");

    // =============================================================
    //                          EVENTS
    // =============================================================

    event RateUpdateExecuted(address indexed executor, uint256 newRate, uint256 computeTimestamp);
    event ManagementFeeSettled(address indexed executor, address indexed accountant);
    event AccountantPaused(address indexed accountant);
    event ManualPosTokenPriceSet(address indexed executor, address indexed adapter, uint256 priceE18);
    // =============================================================
    //                       CUSTOM ERRORS
    // =============================================================

    error AccountantExecutor__ZeroAddress();

    // =============================================================
    //                    CONSTRUCTOR / INITIALIZER
    // =============================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin) external initializer {
        if (admin == address(0)) revert AccountantExecutor__ZeroAddress();

        __AccessControl_init();

        _setRoleAdmin(BOT_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(FEE_SETTLER_ROLE, DEFAULT_ADMIN_ROLE);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // =============================================================
    //                   EXTERNAL FUNCTIONS
    // =============================================================

    /// @notice Trigger an exchange rate update on the Accountant.
    /// @param accountant_ The Accountant contract to call
    /// @param newRate The new exchange rate to push
    /// @param computeTimestamp Off-chain computation timestamp for staleness check
    function executeUpdateRate(address accountant_, uint64 newRate, uint64 computeTimestamp)
        external
        onlyRole(BOT_ROLE)
    {
        if (accountant_ == address(0)) revert AccountantExecutor__ZeroAddress();
        IAccountant(accountant_).updateExchangeRate(newRate, computeTimestamp);
        emit RateUpdateExecuted(msg.sender, newRate, computeTimestamp);
    }

    /// @notice Trigger a management fee settlement on the Accountant.
    /// @param accountant_ The Accountant contract to call
    function executeSettleManagementFee(address accountant_) external onlyRole(FEE_SETTLER_ROLE) {
        if (accountant_ == address(0)) revert AccountantExecutor__ZeroAddress();
        IAccountant(accountant_).settleManagementFee();
        emit ManagementFeeSettled(msg.sender, accountant_);
    }

    /// @notice Set the manual position-token price on an adapter (1e18 precision).
    /// @dev Relay for adapters running in manual-price mode (no oracle configured).
    ///      The adapter itself rejects the call when an oracle is set.
    /// @param adapter_ The adapter contract to call
    /// @param priceE18 New nonzero manual price in 1e18 precision
    function executeSetManualPosTokenPrice(address adapter_, uint256 priceE18) external onlyRole(BOT_ROLE) {
        if (adapter_ == address(0)) revert AccountantExecutor__ZeroAddress();
        IStrategyAdapterCore(adapter_).setManualPosTokenPrice(priceE18);
        emit ManualPosTokenPriceSet(msg.sender, adapter_, priceE18);
    }

    // =============================================================
    //                   UPGRADE AUTHORIZATION
    // =============================================================

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    function executePause(address accountant_) external onlyRole(BOT_ROLE) {
        IAccountant(accountant_).pause();
        emit AccountantPaused(accountant_);
    }
}
