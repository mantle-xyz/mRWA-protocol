// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IMantleYieldVault} from "./interfaces/IMantleYieldVault.sol";

/// @title Accountant
/// @notice Risk gateway and fee settlement engine for MantleYieldVault.
///         Receives NAV updates from the off-chain Accountant Service (via AccountantExecutor),
///         enforces on-chain circuit breakers (deviation + cooldown), computes management fees,
///         and atomically applies the new exchange rate to the Vault.
contract Accountant is AccessControlUpgradeable, PausableUpgradeable, ReentrancyGuard {
    // =============================================================
    //                        CONSTANTS
    // =============================================================

    uint256 public constant MAX_BPS = 10_000;
    uint256 public constant RATE_PRECISION = 1e18;
    uint256 public constant MAX_DEVIATION_CEILING = 1000; // 10% absolute cap on configurable deviation
    uint256 public constant MAX_MANAGEMENT_FEE_BPS = 500; // 5% absolute cap on management fee
    uint256 public constant MAX_COMPUTE_AGE_CEILING = 1 days;

    // =============================================================
    //                          ROLES
    // =============================================================

    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // =============================================================
    //                      STATE VARIABLES
    // =============================================================

    IMantleYieldVault public vault;

    address public treasury;
    uint256 public maxAllowedDeviation; // bps (e.g. 100 = 1%)
    uint256 public managementFeeRate; // bps (e.g. 50 = 0.5%)
    uint256 public minUpdateInterval; // seconds (e.g. 20 hours)
    uint256 public lastExchangeRate;
    uint256 public lastUpdateTimestamp;
    uint256 public lastComputeTimestamp;
    uint256 public maxComputeAge; // seconds – reject rates computed too far in the past

    // =============================================================
    //                          EVENTS
    // =============================================================

    event ExchangeRateUpdated(uint256 oldRate, uint256 newRate, uint256 timestamp);
    event FeesDistributed(address indexed treasury, uint256 feeAssets, uint256 sharesMinted);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event RiskParamsUpdated(uint256 maxDeviation, uint256 minInterval);
    event ManagementFeeRateUpdated(uint256 oldRate, uint256 newRate);
    event MaxComputeAgeUpdated(uint256 oldAge, uint256 newAge);
    event VaultUpdated(address indexed oldVault, address indexed newVault);
    event EmergencyRateUpdated(uint256 oldRate, uint256 newRate, uint256 timestamp);

    // =============================================================
    //                       CUSTOM ERRORS
    // =============================================================

    error DeviationExceeded(uint256 deviationBps, uint256 maxAllowed);
    error CooldownNotElapsed(uint256 timeRemaining);
    error ZeroAddress();
    error InvalidRate();
    error InvalidFeeRate(uint256 rate);
    error InvalidDeviation(uint256 deviation);
    error ZeroAum();
    error TransactionExpired(uint256 deadline, uint256 currentTimestamp);
    error StaleComputeTimestamp(uint256 provided, uint256 lastCompute);
    error FutureComputeTimestamp(uint256 provided, uint256 blockTimestamp);
    error ComputeTimestampTooOld(uint256 provided, uint256 blockTimestamp, uint256 maxAge);
    error InvalidComputeAge(uint256 age);

    // =============================================================
    //                    CONSTRUCTOR / INITIALIZER
    // =============================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address vault_,
        address treasury_,
        uint256 initialRate,
        uint256 managementFeeRate_,
        address admin
    ) external initializer {
        if (vault_ == address(0) || treasury_ == address(0) || admin == address(0)) {
            revert ZeroAddress();
        }
        if (initialRate == 0) revert InvalidRate();
        if (managementFeeRate_ > MAX_MANAGEMENT_FEE_BPS) revert InvalidFeeRate(managementFeeRate_);

        __AccessControl_init();
        __Pausable_init();

        vault = IMantleYieldVault(vault_);
        treasury = treasury_;
        managementFeeRate = managementFeeRate_;
        lastExchangeRate = initialRate;
        lastUpdateTimestamp = block.timestamp;

        maxAllowedDeviation = 100; // 1% default
        minUpdateInterval = 20 hours;
        maxComputeAge = 5 minutes;

        _setRoleAdmin(PAUSER_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(EXECUTOR_ROLE, DEFAULT_ADMIN_ROLE);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(EXECUTOR_ROLE, admin);
    }

    // =============================================================
    //                   EXECUTOR FUNCTIONS
    // =============================================================

    /// @notice Atomic NAV update: validate circuit breakers, settle management fee, push new rate.
    /// @param newRate The new exchange rate (18-decimal precision)
    /// @param aumSnapshot Total assets snapshot (USDC 6-decimal) used as fee-calculation base
    /// @param computeTimestamp Off-chain computation timestamp; must be strictly newer than the previous one
    function updateExchangeRate(uint256 newRate, uint256 aumSnapshot, uint256 computeTimestamp)
        external
        onlyRole(EXECUTOR_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (newRate == 0) revert InvalidRate();
        if (aumSnapshot == 0) revert ZeroAum();
        _checkComputeTimestamp(computeTimestamp);
        _checkDeviation(newRate);

        uint256 cachedTimestamp = lastUpdateTimestamp;
        uint256 cooldownEnd = cachedTimestamp + minUpdateInterval;
        if (block.timestamp < cooldownEnd) {
            revert CooldownNotElapsed(cooldownEnd - block.timestamp);
        }

        // --- Fee settlement (mint-before-rate-update) ---
        uint256 timeElapsed = block.timestamp - cachedTimestamp;
        uint256 feeInAssets = (aumSnapshot * managementFeeRate * timeElapsed) / (MAX_BPS * 365 days);

        if (feeInAssets > 0) {
            uint256 sharesToMint = (feeInAssets * RATE_PRECISION) / newRate;

            if (sharesToMint > 0) {
                vault.mintFeeShares(treasury, sharesToMint);
                emit FeesDistributed(treasury, feeInAssets, sharesToMint);
            }
        }

        // --- Apply new exchange rate ---
        uint256 oldRate = lastExchangeRate;
        vault.updateExchangeRate(newRate);

        lastExchangeRate = newRate;
        lastUpdateTimestamp = block.timestamp;
        lastComputeTimestamp = computeTimestamp;

        emit ExchangeRateUpdated(oldRate, newRate, block.timestamp);
    }

    // =============================================================
    //                    ADMIN FUNCTIONS
    // =============================================================

    /// @notice Emergency override: bypass deviation check, auto-pause the system.
    /// @param computeTimestamp Off-chain computation timestamp; must be strictly newer than the previous one
    function emergencyUpdateExchangeRate(uint256 newRate, uint256 computeTimestamp)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        if (newRate == 0) revert InvalidRate();
        _checkComputeTimestamp(computeTimestamp);

        uint256 oldRate = lastExchangeRate;

        vault.updateExchangeRate(newRate);

        lastExchangeRate = newRate;
        lastUpdateTimestamp = block.timestamp;
        lastComputeTimestamp = computeTimestamp;

        _pause();

        emit EmergencyRateUpdated(oldRate, newRate, block.timestamp);
    }

    function setVault(address newVault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newVault == address(0)) revert ZeroAddress();
        address oldVault = address(vault);
        vault = IMantleYieldVault(newVault);
        emit VaultUpdated(oldVault, newVault);
    }

    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury == address(0)) revert ZeroAddress();
        address oldTreasury = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    function setRiskParams(uint256 newMaxDeviation, uint256 newMinInterval) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMaxDeviation == 0 || newMaxDeviation > MAX_DEVIATION_CEILING) {
            revert InvalidDeviation(newMaxDeviation);
        }
        maxAllowedDeviation = newMaxDeviation;
        minUpdateInterval = newMinInterval;
        emit RiskParamsUpdated(newMaxDeviation, newMinInterval);
    }

    function setMaxComputeAge(uint256 newAge) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newAge == 0 || newAge > MAX_COMPUTE_AGE_CEILING) revert InvalidComputeAge(newAge);
        uint256 oldAge = maxComputeAge;
        maxComputeAge = newAge;
        emit MaxComputeAgeUpdated(oldAge, newAge);
    }

    function setManagementFeeRate(uint256 newRate) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newRate > MAX_MANAGEMENT_FEE_BPS) revert InvalidFeeRate(newRate);
        uint256 oldRate = managementFeeRate;
        managementFeeRate = newRate;
        emit ManagementFeeRateUpdated(oldRate, newRate);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // =============================================================
    //                   INTERNAL FUNCTIONS
    // =============================================================

    /// @dev Reverts if computeTimestamp is stale, in the future, or too old.
    function _checkComputeTimestamp(uint256 computeTimestamp) internal view {
        if (computeTimestamp <= lastComputeTimestamp) {
            revert StaleComputeTimestamp(computeTimestamp, lastComputeTimestamp);
        }
        if (computeTimestamp > block.timestamp) {
            revert FutureComputeTimestamp(computeTimestamp, block.timestamp);
        }
        if (block.timestamp - computeTimestamp > maxComputeAge) {
            revert ComputeTimestampTooOld(computeTimestamp, block.timestamp, maxComputeAge);
        }
    }

    /// @dev Reverts if the rate change exceeds maxAllowedDeviation (in bps).
    function _checkDeviation(uint256 newRate) internal view {
        uint256 cached = lastExchangeRate;
        uint256 delta = newRate > cached ? newRate - cached : cached - newRate;
        uint256 deviationBps = (delta * MAX_BPS) / cached;
        if (deviationBps > maxAllowedDeviation) {
            revert DeviationExceeded(deviationBps, maxAllowedDeviation);
        }
    }
}
