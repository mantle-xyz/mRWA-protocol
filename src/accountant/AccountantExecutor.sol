// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAccountant} from "../interfaces/accountant/IAccountant.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title AccountantExecutor
/// @notice Authorized relay for Accountant.updateExchangeRate.
///         BOT_ROLE can trigger exchange rate updates, and FEE_SETTLER_ROLE can
///         trigger management fee settlement.
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

    // =============================================================
    //                   UPGRADE AUTHORIZATION
    // =============================================================

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    function executePause(address accountant_) external onlyRole(BOT_ROLE) {
        IAccountant(accountant_).pause();
        emit AccountantPaused(accountant_);
    }
}
