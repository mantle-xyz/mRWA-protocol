// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAccountant} from "../interfaces/accountant/IAccountant.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

/// @title AccountantExecutor
/// @notice Authorized relay for Accountant.updateExchangeRate.
///         Only accounts holding BOT_ROLE can trigger exchange rate updates.
///         DEFAULT_ADMIN_ROLE manages BOT_ROLE membership and authorizes upgrades.
contract AccountantExecutor is AccessControlUpgradeable {
    // =============================================================
    //                        CONSTANTS
    // =============================================================

    bytes32 public constant BOT_ROLE = keccak256("BOT_ROLE");

    // =============================================================
    //                      STATE VARIABLES
    // =============================================================

    IAccountant public accountant;

    // =============================================================
    //                          EVENTS
    // =============================================================

    event RateUpdateExecuted(address indexed executor, uint256 newRate, uint256 computeTimestamp);
    event ManagementFeeSettled(address indexed executor);

    // =============================================================
    //                       CUSTOM ERRORS
    // =============================================================

    error ZeroAddress();

    // =============================================================
    //                    CONSTRUCTOR / INITIALIZER
    // =============================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address accountant_, address admin) external initializer {
        if (accountant_ == address(0) || admin == address(0)) revert ZeroAddress();

        __AccessControl_init();

        accountant = IAccountant(accountant_);

        _setRoleAdmin(BOT_ROLE, DEFAULT_ADMIN_ROLE);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // =============================================================
    //                   EXTERNAL FUNCTIONS
    // =============================================================

    /// @notice Trigger an exchange rate update on the Accountant.
    /// @param newRate The new exchange rate to push
    /// @param computeTimestamp Off-chain computation timestamp for staleness check
    function executeUpdateRate(uint256 newRate, uint256 computeTimestamp) external onlyRole(BOT_ROLE) {
        accountant.updateExchangeRate(newRate, computeTimestamp);
        emit RateUpdateExecuted(msg.sender, newRate, computeTimestamp);
    }

    /// @notice Trigger management fee settlement on the Accountant.
    function executeSettleManagementFee() external onlyRole(BOT_ROLE) {
        accountant.settleManagementFee();
        emit ManagementFeeSettled(msg.sender);
    }
}
