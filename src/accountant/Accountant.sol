// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMantleYieldVault} from "../interfaces/vault/IMantleYieldVault.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title Accountant
/// @notice Risk gateway and fee settlement engine for MantleYieldVault.
///         Receives NAV updates from the off-chain Accountant Service (via AccountantExecutor),
///         enforces on-chain circuit breakers (deviation + cooldown), computes management fees,
///         and atomically applies the new exchange rate to the Vault.
contract Accountant is AccessControlUpgradeable, PausableUpgradeable, ReentrancyGuard {
    using SafeCast for uint256;

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
    //                  ERC-7201 NAMESPACED STORAGE
    // =============================================================

    /// @custom:storage-location erc7201:mrwa.storage.Accountant
    /// @dev Struct is tightly packed into 4 storage slots:
    ///      slot 0: vault(20) + maxAllowedDeviation(4) + managementFeeRate(4) + minUpdateInterval(4)
    ///      slot 1: treasury(20) + maxComputeAge(4) + lastUpdateTimestamp(8)
    ///      slot 2: lastComputeTimestamp(8) + lastExchangeRate(8) + lastFeeSettleTimestamp(8)
    ///      slot 3: totalSharesLastSettle(32)
    struct AccountantStorage {
        // ── slot 0 ──
        IMantleYieldVault vault;
        uint32 maxAllowedDeviation; // bps (e.g. 100 = 1%)
        uint32 managementFeeRate; // bps (e.g. 100 = 1%)
        // ── slot 1 ──
        address treasury;
        uint32 maxComputeAge; // seconds (e.g. 5 minutes)
        uint32 minUpdateInterval; // seconds (e.g. 20 hours)
        // ── slot 2 ──
        uint64 lastComputeTimestamp;
        uint64 lastExchangeRate;
        uint64 lastUpdateTimestamp;
        uint64 lastFeeSettleTimestamp;
        // ── slot 3 ──
        uint256 totalSharesLastSettle;
    }

    /// @dev ERC-7201 storage location derived from the namespace "mrwa.storage.Accountant".
    ///      Formula: keccak256(abi.encode(uint256(keccak256("mrwa.storage.Accountant")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ACCOUNTANT_STORAGE_LOCATION =
        0x6c92d3e3e5b85f72ef5aed0666c2a5bff81ca952e7397a04503941b502a0e700;

    function _getAccountantStorage() private pure returns (AccountantStorage storage $) {
        assembly {
            $.slot := ACCOUNTANT_STORAGE_LOCATION
        }
    }

    // =============================================================
    //                          EVENTS
    // =============================================================

    event ExchangeRateUpdated(uint256 oldRate, uint256 newRate, uint256 timestamp);
    event FeesDistributed(address indexed treasury, uint256 sharesMinted);
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

        AccountantStorage storage s = _getAccountantStorage();
        s.vault = IMantleYieldVault(vault_);
        s.treasury = treasury_;
        s.managementFeeRate = managementFeeRate_.toUint32();
        s.lastExchangeRate = initialRate.toUint64();
        s.lastUpdateTimestamp = block.timestamp.toUint64();
        s.lastFeeSettleTimestamp = block.timestamp.toUint64();
        s.totalSharesLastSettle = IMantleYieldVault(vault_).totalSupply();
        s.maxAllowedDeviation = 100; // 1% default
        s.minUpdateInterval = 20 hours;
        s.maxComputeAge = 5 minutes;

        _setRoleAdmin(PAUSER_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(EXECUTOR_ROLE, DEFAULT_ADMIN_ROLE);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(EXECUTOR_ROLE, admin);
    }

    // =============================================================
    //                       VIEW FUNCTIONS
    // =============================================================

    function vault() external view returns (IMantleYieldVault) {
        return _getAccountantStorage().vault;
    }

    function treasury() external view returns (address) {
        return _getAccountantStorage().treasury;
    }

    function maxAllowedDeviation() external view returns (uint256) {
        return _getAccountantStorage().maxAllowedDeviation;
    }

    function managementFeeRate() external view returns (uint256) {
        return _getAccountantStorage().managementFeeRate;
    }

    function minUpdateInterval() external view returns (uint256) {
        return _getAccountantStorage().minUpdateInterval;
    }

    function lastExchangeRate() external view returns (uint256) {
        return _getAccountantStorage().lastExchangeRate;
    }

    function lastUpdateTimestamp() external view returns (uint256) {
        return _getAccountantStorage().lastUpdateTimestamp;
    }

    function lastFeeSettleTimestamp() external view returns (uint256) {
        return _getAccountantStorage().lastFeeSettleTimestamp;
    }

    function totalSharesLastSettle() external view returns (uint256) {
        return _getAccountantStorage().totalSharesLastSettle;
    }

    function lastComputeTimestamp() external view returns (uint256) {
        return _getAccountantStorage().lastComputeTimestamp;
    }

    function maxComputeAge() external view returns (uint256) {
        return _getAccountantStorage().maxComputeAge;
    }

    // =============================================================
    //                   EXECUTOR FUNCTIONS
    // =============================================================

    /// @notice Push a new exchange rate after validating circuit breakers.
    /// @param newRate The new exchange rate (18-decimal precision)
    /// @param computeTimestamp Off-chain computation timestamp; must be strictly newer than the previous one
    function updateExchangeRate(uint256 newRate, uint256 computeTimestamp)
        external
        onlyRole(EXECUTOR_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (newRate == 0) revert InvalidRate();

        AccountantStorage storage s = _getAccountantStorage();
        _checkComputeTimestamp(s, computeTimestamp);
        _checkDeviation(s, newRate);

        uint256 cooldownEnd = uint256(s.lastUpdateTimestamp) + s.minUpdateInterval;
        if (block.timestamp < cooldownEnd) {
            revert CooldownNotElapsed(cooldownEnd - block.timestamp);
        }

        uint256 oldRate = s.lastExchangeRate;
        s.vault.updateExchangeRate(newRate);

        s.lastExchangeRate = newRate.toUint64();
        s.lastUpdateTimestamp = block.timestamp.toUint64();
        s.lastComputeTimestamp = computeTimestamp.toUint64();

        emit ExchangeRateUpdated(oldRate, newRate, block.timestamp);
    }

    /// @notice Settle accrued management fees by minting vault shares to the treasury.
    ///         Uses min(currentSupply, lastSettleSupply) as the fee base to prevent
    ///         overcharging when share supply changes drastically between settlements.
    function settleManagementFee() external onlyRole(EXECUTOR_ROLE) whenNotPaused nonReentrant {
        AccountantStorage storage s = _getAccountantStorage();

        uint256 timeElapsed = block.timestamp - s.lastFeeSettleTimestamp;
        if (timeElapsed == 0) return;

        uint256 currentTotalShares = s.vault.totalSupply();
        uint256 shareBase = currentTotalShares < s.totalSharesLastSettle ? currentTotalShares : s.totalSharesLastSettle;
        uint256 sharesToMint = (shareBase * s.managementFeeRate * timeElapsed) / (MAX_BPS * 365 days);

        s.lastFeeSettleTimestamp = block.timestamp.toUint64();
        s.totalSharesLastSettle = currentTotalShares;

        if (sharesToMint > 0) {
            s.vault.mintFeeShares(s.treasury, sharesToMint);
            emit FeesDistributed(s.treasury, sharesToMint);
        }
    }

    // =============================================================
    //                    ADMIN FUNCTIONS
    // =============================================================

    function setVault(address newVault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newVault == address(0)) revert ZeroAddress();
        AccountantStorage storage s = _getAccountantStorage();
        address oldVault = address(s.vault);
        s.vault = IMantleYieldVault(newVault);
        emit VaultUpdated(oldVault, newVault);
    }

    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury == address(0)) revert ZeroAddress();
        AccountantStorage storage s = _getAccountantStorage();
        address oldTreasury = s.treasury;
        s.treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    function setRiskParams(uint256 newMaxDeviation, uint256 newMinInterval) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMaxDeviation == 0 || newMaxDeviation > MAX_DEVIATION_CEILING) {
            revert InvalidDeviation(newMaxDeviation);
        }
        AccountantStorage storage s = _getAccountantStorage();
        s.maxAllowedDeviation = newMaxDeviation.toUint32();
        s.minUpdateInterval = newMinInterval.toUint32();
        emit RiskParamsUpdated(newMaxDeviation, newMinInterval);
    }

    function setMaxComputeAge(uint256 newAge) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newAge == 0 || newAge > MAX_COMPUTE_AGE_CEILING) revert InvalidComputeAge(newAge);
        AccountantStorage storage s = _getAccountantStorage();
        uint256 oldAge = s.maxComputeAge;
        s.maxComputeAge = newAge.toUint32();
        emit MaxComputeAgeUpdated(oldAge, newAge);
    }

    function setManagementFeeRate(uint256 newRate) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newRate > MAX_MANAGEMENT_FEE_BPS) revert InvalidFeeRate(newRate);
        AccountantStorage storage s = _getAccountantStorage();
        uint256 oldRate = s.managementFeeRate;
        s.managementFeeRate = newRate.toUint32();
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
    function _checkComputeTimestamp(AccountantStorage storage s, uint256 computeTimestamp) internal view {
        if (computeTimestamp <= s.lastComputeTimestamp) {
            revert StaleComputeTimestamp(computeTimestamp, s.lastComputeTimestamp);
        }
        if (computeTimestamp > block.timestamp) {
            revert FutureComputeTimestamp(computeTimestamp, block.timestamp);
        }
        if (block.timestamp - computeTimestamp > s.maxComputeAge) {
            revert ComputeTimestampTooOld(computeTimestamp, block.timestamp, s.maxComputeAge);
        }
    }

    /// @dev Reverts if the rate change exceeds maxAllowedDeviation (in bps).
    function _checkDeviation(AccountantStorage storage s, uint256 newRate) internal view {
        uint256 cached = s.lastExchangeRate;
        uint256 delta = newRate > cached ? newRate - cached : cached - newRate;
        uint256 deviationBps = (delta * MAX_BPS) / cached;
        if (deviationBps > s.maxAllowedDeviation) {
            revert DeviationExceeded(deviationBps, s.maxAllowedDeviation);
        }
    }
}
