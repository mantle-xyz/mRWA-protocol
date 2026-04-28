// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// =============================================================
// ERC-7540 Interface Definition
// =============================================================

interface IERC7540Redeem {
    event RedeemRequest(
        address indexed account,
        uint256 indexed requestId,
        uint256 netShares,
        uint256 estimatedAssets,
        uint256 feeShares
    );

    function requestRedeem(uint256 shares) external returns (uint256 requestId);
    function pendingRedeemRequest(address account) external view returns (uint256 shares);
}

/**
 * @title IMantleYieldVault
 * @notice Full interface for the ERC-4626 + ERC-7540 async redemption RWA vault.
 *         Deployed via VaultFactory (BeaconProxy), upgradeable via UpgradeableBeacon.
 *         Inherits IERC4626 for full ERC-4626 compatibility and IERC7540Redeem for async redemptions.
 */
interface IMantleYieldVault is IERC4626, IERC7540Redeem {
    // =============================================================
    // Enums
    // =============================================================

    enum RequestStatus {
        NONE,
        PENDING,
        PROCESSING,
        DONE
    }

    enum InFlightStatus {
        NONE,
        PENDING,
        CONFIRMED
    }

    // =============================================================
    // Structs
    // =============================================================

    struct InitParams {
        IERC20 asset;
        string name;
        string symbol;
        address admin;
        address gateway;
        address controller;
        address accountant;
        address treasury;
        uint256 maxRedemptionFeeBps;
        uint256 redemptionFeeBps;
        uint256 minRedeemAmount;
        uint256 minDepositAmount;
    }

    struct RedemptionRequest {
        uint256 id;
        address owner;
        uint256 shares; // Net shares after fee deduction (shares - treasuryShare)
        uint256 feeShares; // Fee shares minted to treasury at request time
        uint256 estimatedAssets; // Estimated payout at requestRedeem time (reference only, may differ from settlement)
        uint256 settledAssets; // Actual payout (set by markRequestsDone, 0 until settled)
        uint256 timestamp;
        RequestStatus status;
    }

    struct InFlightRecord {
        uint256 id;
        address adapter;
        address token;
        uint256 tokenAmount;
        uint256 usdcAmount;
        uint256 settledAmount;
        bool isInvest;
        uint256 timestamp;
        InFlightStatus status;
    }

    struct tokenInfo {
        address token;
        uint256 tokenAmount;
        uint256 usdcAmount;
    }

    // =============================================================
    // Errors
    // =============================================================

    error Vault__Sanctioned(address account);
    error Vault__NotAuthorized();
    error Vault__InvalidState(uint256 requestId, RequestStatus currentStatus);
    error Vault__InsufficientPhysicalCash(uint256[] requestIds, uint256[] settledAssets, uint256 physicalCash);
    error Vault__InsufficientFreeCash(uint256 requested, uint256 freeCash);
    error Vault__RescueAssetCannotBeUnderlying();
    error Vault__ZeroAmount();
    error Vault__FeeTooHigh(uint256 feeBps, uint256 maxBps);
    error Vault__BelowMinRedeem(uint256 assets, uint256 minimum);
    error Vault__BelowMinDeposit(uint256 assets, uint256 minimum);
    error Vault__StatusTransitionForbidden(RequestStatus target);
    error Vault__AdapterAlreadyRegistered(address adapter);
    error Vault__AdapterNotRegistered(address adapter);
    error Vault__AdapterHasInFlight(address adapter);
    error Vault__OnlyController();
    error Vault__OnlyAccountant();
    error Vault__OnlyGateway();
    error Vault__ZeroAddress();
    error Vault__SyncRedeemDisabled();
    error Vault__ZeroExchangeRate();
    error Vault__InvalidInFlightState(uint256 inFlightId, InFlightStatus currentStatus);
    error Vault__LengthMismatch(uint256 idsLength, uint256 amountsLength);

    // =============================================================
    // Events (vault-specific; RedeemRequest is inherited from IERC7540Redeem)
    // =============================================================

    event SanctionSafeIn(address indexed account, address indexed token, uint256 amount);
    event RedemptionDone(
        address indexed account, address indexed receiver, uint256 shares, uint256 assets, uint256 estimatedAssets
    );
    event RedemptionFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event MinRedeemAmountUpdated(uint256 oldAmount, uint256 newAmount);
    event MinDepositAmountUpdated(uint256 oldAmount, uint256 newAmount);
    event AdapterRegistered(address indexed adapter);
    event AdapterRemoved(address indexed adapter);
    event RequestBatchUpdated(uint256[] ids, RequestStatus newStatus);
    event InFlightCreated(
        uint256 indexed inFlightId,
        address indexed adapter,
        address token,
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
    enum FeeType {
        Management,
        Redemption
    }
    event FeeSharesReceived(address indexed treasury, uint256 shares, FeeType feeType);
    event ControllerUpdated(address indexed oldController, address indexed newController);
    event AccountantUpdated(address indexed oldAccountant, address indexed newAccountant);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event RequestSettlementAdjusted(uint256 indexed requestId, uint256 originalAssets, uint256 settledAssets);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event MaxRedemptionFeeUpdated(uint256 oldMaxBps, uint256 newMaxBps);
    event FeeChangedWithLockedShares(uint256 totalLockedShares, uint256 oldFeeBps, uint256 newFeeBps);
    event GatewayUpdated(address indexed oldGateway, address indexed newGateway);

    // =============================================================
    // Initialization
    // =============================================================

    function initialize(InitParams calldata params) external;

    // =============================================================
    // State Getters
    // =============================================================

    function PAUSER_ROLE() external view returns (bytes32);
    function FEE_BASIS() external view returns (uint256);
    function maxRedemptionFeeBps() external view returns (uint256);

    function treasury() external view returns (address);
    function controller() external view returns (address);
    function accountant() external view returns (address);
    function gateway() external view returns (address);
    function exchangeRate() external view returns (uint256);
    function redemptionFeeBps() external view returns (uint256);
    function minRedeemAmount() external view returns (uint256);
    function minDepositAmount() external view returns (uint256);
    function totalLockedShares() external view returns (uint256);

    function totalInvestInFlight() external view returns (uint256);
    function totalRedeemInFlight() external view returns (uint256);
    function adapterInvestInFlightTokens(address adapter) external view returns (uint256);
    function adapterRedeemInFlightUsdc(address adapter) external view returns (uint256);
    function pendingRequestCount() external view returns (uint256);

    function getTokenInfos() external view returns (tokenInfo[] memory);

    function nextRequestId() external view returns (uint256);
    function nextInFlightId() external view returns (uint256);

    function requests(uint256 requestId)
        external
        view
        returns (
            uint256 id,
            address owner,
            uint256 shares,
            uint256 feeShares,
            uint256 estimatedAssets,
            uint256 settledAssets,
            uint256 timestamp,
            RequestStatus status
        );

    function inFlightRecords(uint256 inFlightId)
        external
        view
        returns (
            uint256 id,
            address adapter,
            address token,
            uint256 tokenAmount,
            uint256 usdcAmount,
            uint256 settledAmount,
            bool isInvest,
            uint256 timestamp,
            InFlightStatus status
        );

    function adapters(uint256 index) external view returns (address);
    function isAdapter(address adapter) external view returns (bool);
    function getAdapters() external view returns (address[] memory);
    function getFreeCash() external view returns (uint256);
    function getCashDeficit() external view returns (uint256);

    // =============================================================
    // ERC-7575
    // =============================================================

    function share() external view returns (address);

    // =============================================================
    // Gateway Only
    // =============================================================

    // Note: deposit(uint256, address) and redeem(uint256, address, address)
    // are inherited from IERC4626 — implemented as gateway-only in MantleYieldVault.
    function requestRedeem(address owner, uint256 shares) external returns (uint256 requestId);
    function routeSanctionedShares(address owner, uint256 shares) external;

    // =============================================================
    // Controller Only
    // =============================================================

    function registerAdapter(address adapter) external;
    function removeAdapter(address adapter) external;
    function approveToAdapter(address adapter, address token, uint256 amount) external;
    function updateRequestBatch(uint256[] calldata ids, RequestStatus newStatus) external;
    function markRequestsDone(uint256[] calldata ids, uint256[] calldata settledAssets) external;
    function createInFlight(address adapter, address token, uint256 tokenAmount, uint256 usdcAmount, bool isInvest)
        external
        returns (uint256 inFlightId);
    function confirmInFlight(uint256 inFlightId, uint256 actualAmount, bool isAbnormal) external;

    // =============================================================
    // Admin Only
    // =============================================================

    function setRedemptionFee(uint256 newFeeBps) external;
    function setMaxRedemptionFee(uint256 newMaxBps) external;
    function setMinRedeemAmount(uint256 newAmount) external;
    function setMinDepositAmount(uint256 newAmount) external;
    function setGateway(address newGateway) external;
    function setController(address newController) external;
    function setAccountant(address newAccountant) external;
    function setTreasury(address newTreasury) external;

    // =============================================================
    // Accountant Only
    // =============================================================

    function mintFeeShares(uint256 shares) external;

    // =============================================================
    // Emergency Management
    // =============================================================

    function pause() external;
    function unpause() external;
    function rescueTokens(address token, address to, uint256 amount) external;
}
