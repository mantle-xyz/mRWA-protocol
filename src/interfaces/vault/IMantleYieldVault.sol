// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {InFlightStatus, RequestStatus} from "./types/VaultTypes.sol";

interface ISanctionsOracle {
    function isBlacklisted(address account) external view returns (bool);
}

// =============================================================
// ERC-7540 Interface Definition
// =============================================================

interface IERC7540Redeem {
    event RedeemRequest(address indexed account, uint256 indexed requestId, uint256 shares);

    function pendingRedeemRequest(uint256 requestId, address account) external view returns (uint256 shares);
    function claimableRedeemRequest(uint256 requestId, address account) external view returns (uint256 shares);
}

/**
 * @title IMantleYieldVault
 * @notice Full interface for the ERC-4626 + ERC-7540 async redemption + UUPS upgradeable RWA vault.
 *         Inherits IERC4626 for full ERC-4626 compatibility and IERC7540Redeem for async redemptions.
 */
interface IMantleYieldVault is IERC4626, IERC7540Redeem {
    // =============================================================
    // Structs
    // =============================================================

    struct RedemptionRequest {
        uint256 id;
        address owner;
        uint256 shares;
        uint256 assets;
        uint256 timestamp;
        RequestStatus status;
    }

    struct InFlightRecord {
        uint256 id;
        address adapter;
        address asset;
        uint256 tokenAmount;
        uint256 usdcAmount;
        uint256 settledAmount;
        bool isInvest;
        uint256 timestamp;
        InFlightStatus status;
    }

    // =============================================================
    // Errors
    // =============================================================

    error Vault__Sanctioned(address account);
    error Vault__NotAuthorized();
    error Vault__InvalidState(uint256 requestId, RequestStatus currentStatus);
    error Vault__InsufficientPhysicalCash(uint256 required, uint256 available);
    error Vault__InsufficientFreeCash(uint256 requested, uint256 freeCash);
    error Vault__InsufficientClaimable(uint256 requested, uint256 available);
    error Vault__Underflow(uint256 current, uint256 deduction);
    error Vault__RescueAssetCannotBeUnderlying();
    error Vault__ZeroAmount();
    error Vault__FeeTooHigh(uint256 feeBps, uint256 maxBps);
    error Vault__BelowMinRedeem(uint256 assets, uint256 minimum);
    error Vault__StatusTransitionForbidden(RequestStatus target);
    error Vault__AdapterAlreadyRegistered(address adapter);
    error Vault__AdapterNotRegistered(address adapter);
    error Vault__AdapterHasInFlight(address adapter);
    error Vault__OnlyController();
    error Vault__OnlyAccountant();
    error Vault__ZeroAddress();
    error Vault__ZeroExchangeRate();
    error Vault__ExchangeRateChangeExceedsLimit(uint256 oldRate, uint256 newRate, uint256 maxDeltaBps);
    error Vault__InvalidInFlightState(uint256 inFlightId, InFlightStatus currentStatus);

    // =============================================================
    // Events (vault-specific; RedeemRequest is inherited from IERC7540Redeem)
    // =============================================================

    event RedemptionClaimed(address indexed account, address indexed receiver, uint256 shares, uint256 assets);
    event ExchangeRateUpdated(uint256 oldRate, uint256 newRate);
    event RedemptionFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event MinRedeemAmountUpdated(uint256 oldAmount, uint256 newAmount);
    event AdapterRegistered(address indexed adapter);
    event AdapterRemoved(address indexed adapter);
    event AdapterApproved(address indexed adapter, address indexed token, uint256 amount);
    event RequestBatchUpdated(uint256[] ids, RequestStatus newStatus);
    event InFlightCreated(
        uint256 indexed inFlightId,
        address indexed adapter,
        address asset,
        uint256 tokenAmount,
        uint256 usdcAmount,
        bool isInvest
    );
    event InFlightConfirmed(
        uint256 indexed inFlightId,
        address indexed adapter,
        uint256 tokenAmount,
        uint256 usdcAmount,
        uint256 settledAmount
    );
    event FeeSharesMinted(address indexed treasury, uint256 shares);
    event SanctionsOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event ControllerUpdated(address indexed oldController, address indexed newController);
    event AccountantUpdated(address indexed oldAccountant, address indexed newAccountant);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    // =============================================================
    // Initialization
    // =============================================================

    function initialize(
        IERC20 _asset,
        string memory _name,
        string memory _symbol,
        address _admin,
        address _sanctionsOracle,
        address _controller,
        address _accountant,
        uint256 _redemptionFeeBps,
        uint256 _minRedeemAmount
    ) external;

    // =============================================================
    // State Getters
    // =============================================================

    function PAUSER_ROLE() external view returns (bytes32);
    function MAX_REDEMPTION_FEE() external view returns (uint256);
    function FEE_BASIS() external view returns (uint256);
    function MAX_RATE_CHANGE_BPS() external view returns (uint256);

    function controller() external view returns (address);
    function accountant() external view returns (address);
    function sanctionsOracle() external view returns (ISanctionsOracle);
    function exchangeRate() external view returns (uint256);
    function redemptionFeeBps() external view returns (uint256);
    function minRedeemAmount() external view returns (uint256);
    function totalLockedLiabilities() external view returns (uint256);
    function totalInFlightAssets() external view returns (uint256);
    function totalLockedLiabilitiesFor(uint256[] calldata ids) external view returns (uint256);

    function approveToAdapter(address adapter, uint256 amount) external;
    function addInFlight(uint256 amount) external;
    function removeInFlight(uint256 amount) external;

    function updateRequestBatch(uint256[] calldata ids, uint8 status) external;
    function markRequestsReady(uint256[] calldata ids) external;
}
