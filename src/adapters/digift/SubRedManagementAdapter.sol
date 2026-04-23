// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISubRedManagement} from "../../interfaces/adapters/digift/ISubRedManagement.sol";
import {BaseAsync7540Adapter} from "../base/capabilities/BaseAsync7540Adapter.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Async-first adapter for Digift SubRed subscribe/redeem flow.
/// @dev Controller drives unified adapter methods.
contract SubRedManagementAdapter is BaseAsync7540Adapter {
    using SafeERC20 for IERC20;

    ISubRedManagement public immutable SUB_RED;
    address public immutable ST_TOKEN;

    uint256 public subscribeStepAsset;
    uint256 public redeemStepPos;

    uint64 public subscribeDeadlineWindow = 6 hours;
    uint64 public redeemDeadlineWindow = 6 hours;

    event ExecutionStepsUpdated(uint256 subscribeStepAsset, uint256 redeemStepPos);
    event SubscribeDeadlineWindowUpdated(uint64 newWindow);
    event RedeemDeadlineWindowUpdated(uint64 newWindow);

    /**
     * @notice Initialize Digift SubRed adapter.
     * @param vault_ Vault that owns strategy funds.
     * @param subRedManagement Digift SubRedManagement contract.
     * @param stToken Target security token address supported by SubRedManagement.
     * @param admin Adapter admin role address.
     * @param controller StrategyController role address.
     * @param accountant Accountant role address for manual price updates.
     * @param priceOracle_ Optional DFeedPriceOracle for the ST token. Pass address(0) for 1:1 estimate.
     */
    constructor(
        address vault_,
        address subRedManagement,
        address stToken,
        address admin,
        address controller,
        address accountant,
        address priceOracle_
    ) BaseAsync7540Adapter(vault_, admin, controller, accountant, priceOracle_) {
        if (subRedManagement == address(0) || stToken == address(0)) {
            revert InvalidAddress();
        }
        SUB_RED = ISubRedManagement(subRedManagement);
        ST_TOKEN = stToken;
    }

    // =============================================================
    // Adapter Views
    // =============================================================

    /**
     * @notice Strategy display name.
     */
    function name() external pure override returns (string memory) {
        return "SubRedManagementAdapter";
    }

    function posToken() external view override returns (address) {
        return ST_TOKEN;
    }

    /**
     * @notice Estimate ST token amount (in ST raw units) for a given asset amount.
     * @dev Uses getPosTokenPrice() in 1e18 precision. Falls back to 1:1 human scaling when price source is invalid.
     */
    function estimatePosAmount(uint256 amountAsset) external view override returns (uint256 positionAmount) {
        uint8 assetDecimals = IERC20Metadata(address(ASSET)).decimals();
        uint8 stDecimals = IERC20Metadata(ST_TOKEN).decimals();
        return _estimatePosAmountInternal(amountAsset, assetDecimals, stDecimals);
    }

    function _estimatePosAmountInternal(uint256 amountAsset, uint8 assetDecimals, uint8 stDecimals)
        internal
        view
        returns (uint256)
    {
        if (amountAsset == 0) {
            return 0;
        }
        uint256 priceE18 = getPosTokenPrice();
        if (priceE18 == 0) {
            return _scaleToStRaw(amountAsset, assetDecimals, stDecimals);
        }
        if (stDecimals >= assetDecimals) {
            return Math.mulDiv(amountAsset, 1e18 * (10 ** (stDecimals - assetDecimals)), priceE18, Math.Rounding.Floor);
        }
        return Math.mulDiv(amountAsset, 1e18, priceE18 * (10 ** (assetDecimals - stDecimals)), Math.Rounding.Floor);
    }

    function _scaleToStRaw(uint256 amountAssetRaw, uint8 assetDecimals, uint8 stDecimals)
        internal
        pure
        returns (uint256)
    {
        if (stDecimals >= assetDecimals) {
            return amountAssetRaw * (10 ** (stDecimals - assetDecimals));
        }
        return amountAssetRaw / (10 ** (assetDecimals - stDecimals));
    }

    function _scaleToAssetRaw(uint256 amountStRaw, uint8 stDecimals, uint8 assetDecimals)
        internal
        pure
        returns (uint256)
    {
        if (assetDecimals >= stDecimals) {
            return amountStRaw * (10 ** (assetDecimals - stDecimals));
        }
        return amountStRaw / (10 ** (stDecimals - assetDecimals));
    }

    function _estimateAssetAmount(uint256 amountPosRaw, uint8 assetDecimals, uint8 stDecimals)
        internal
        view
        returns (uint256)
    {
        if (amountPosRaw == 0) {
            return _scaleToAssetRaw(amountPosRaw, stDecimals, assetDecimals);
        }
        uint256 priceE18 = getPosTokenPrice();
        if (priceE18 == 0) {
            return _scaleToAssetRaw(amountPosRaw, stDecimals, assetDecimals);
        }
        if (assetDecimals >= stDecimals) {
            return Math.mulDiv(amountPosRaw, priceE18 * (10 ** (assetDecimals - stDecimals)), 1e18, Math.Rounding.Floor);
        }
        return Math.mulDiv(amountPosRaw, priceE18, 1e18 * (10 ** (stDecimals - assetDecimals)), Math.Rounding.Floor);
    }

    function _estimateAssetAmount(uint256 amountPosRaw, uint8 assetDecimals, uint8 stDecimals, Math.Rounding rounding)
        internal
        view
        returns (uint256)
    {
        if (amountPosRaw == 0) {
            return _scaleToAssetRaw(amountPosRaw, stDecimals, assetDecimals, rounding);
        }
        uint256 priceE18 = getPosTokenPrice();
        if (priceE18 == 0) {
            return _scaleToAssetRaw(amountPosRaw, stDecimals, assetDecimals, rounding);
        }
        if (assetDecimals >= stDecimals) {
            return Math.mulDiv(amountPosRaw, priceE18 * (10 ** (assetDecimals - stDecimals)), 1e18, rounding);
        }
        return Math.mulDiv(amountPosRaw, priceE18, 1e18 * (10 ** (stDecimals - assetDecimals)), rounding);
    }

    /**
     * @notice Settled strategy value: ST tokens held by the vault, converted to asset terms.
     * @dev Excludes ASSET sitting on the adapter — those are unsettled in-flight
     *      proceeds already tracked by vault.totalInvestInFlight / totalRedeemInFlight.
     */
    function totalValue() external view override returns (uint256) {
        uint8 assetDecimals = IERC20Metadata(address(ASSET)).decimals();
        uint8 stDecimals = IERC20Metadata(ST_TOKEN).decimals();
        uint256 settledVaultPosBalance = IERC20(ST_TOKEN).balanceOf(VAULT);
        return _estimateAssetAmount(settledVaultPosBalance, assetDecimals, stDecimals);
    }

    function previewDeposit(uint256 amountAsset)
        external
        view
        override
        returns (bool ok, uint256 executableAssetAmount, uint256 expectedPosAmount)
    {
        return _previewDeposit(amountAsset);
    }

    function _previewDeposit(uint256 amountAsset)
        internal
        view
        returns (bool ok, uint256 executableAssetAmount, uint256 expectedPosAmount)
    {
        executableAssetAmount = _floorToStep(amountAsset, subscribeStepAsset);
        if (executableAssetAmount == 0) {
            return (false, 0, 0);
        }

        uint8 assetDecimals = IERC20Metadata(address(ASSET)).decimals();
        uint8 stDecimals = IERC20Metadata(ST_TOKEN).decimals();
        expectedPosAmount = _estimatePosAmountInternal(executableAssetAmount, assetDecimals, stDecimals);
        ok = executableAssetAmount > 0;
    }

    function previewRedeem(uint256 amountAsset)
        external
        view
        override
        returns (bool ok, uint256 executableAssetAmount, uint256 expectedPosAmount)
    {
        uint8 assetDecimals = IERC20Metadata(address(ASSET)).decimals();
        uint8 stDecimals = IERC20Metadata(ST_TOKEN).decimals();

        uint256 originalPosAmount = _estimatePosAmountInternal(amountAsset, assetDecimals, stDecimals);
        if (originalPosAmount == 0) {
            return (false, 0, 0);
        }

        expectedPosAmount = _floorToStep(originalPosAmount, redeemStepPos);
        if (expectedPosAmount == 0) {
            return (false, 0, 0);
        }

        if (expectedPosAmount == originalPosAmount) {
            return (true, amountAsset, expectedPosAmount);
        }

        executableAssetAmount = _estimateAssetAmount(expectedPosAmount, assetDecimals, stDecimals, Math.Rounding.Ceil);
        ok = executableAssetAmount > 0;
    }

    // =============================================================
    // Admin Controls
    // =============================================================

    /**
     * @notice Update subscribe deadline window used by deposit().
     * @param newWindow New deadline window in seconds.
     * @dev Only callable by DEFAULT_ADMIN_ROLE.
     */
    function setSubscribeDeadlineWindow(uint64 newWindow) external onlyRole(DEFAULT_ADMIN_ROLE) {
        subscribeDeadlineWindow = newWindow;
        emit SubscribeDeadlineWindowUpdated(newWindow);
    }

    /**
     * @notice Update redeem deadline window used by requestRedeemAsync().
     * @param newWindow New deadline window in seconds.
     * @dev Only callable by DEFAULT_ADMIN_ROLE.
     */
    function setRedeemDeadlineWindow(uint64 newWindow) external onlyRole(DEFAULT_ADMIN_ROLE) {
        redeemDeadlineWindow = newWindow;
        emit RedeemDeadlineWindowUpdated(newWindow);
    }

    function setExecutionSteps(uint256 subscribeStepAsset_, uint256 redeemStepPos_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        subscribeStepAsset = subscribeStepAsset_;
        redeemStepPos = redeemStepPos_;

        emit ExecutionStepsUpdated(subscribeStepAsset_, redeemStepPos_);
    }

    // =============================================================
    // Controller Actions
    // =============================================================

    /**
     * @notice Pull funds from Vault and submit subscribe.
     * @param amountAsset Asset amount to subscribe (vault asset raw units).
     * @param receiver Receiver parameter reserved by IStrategyAdapter.
     * @return expectedPosAmount Estimated subscribed position amount (ST raw units).
     * @dev Only callable by controller when not paused.
     */
    function deposit(uint256 amountAsset, address receiver)
        external
        override
        onlyController
        whenNotPaused
        returns (uint256)
    {
        (bool ok, uint256 executableAssetAmount, uint256 previewPosAmount) = _previewDeposit(amountAsset);
        if (!ok || amountAsset != executableAssetAmount) {
            revert InvalidAmount();
        }
        // Controller already validated via previewDeposit(); no redundant checks here.
        ASSET.safeTransferFrom(VAULT, address(this), amountAsset);
        _subscribe(amountAsset, uint64(block.timestamp + subscribeDeadlineWindow));
        _emitAdapterDeposit(amountAsset, receiver, previewPosAmount);
        return previewPosAmount;
    }

    /**
     * @notice Register an async redeem request using position-token quantity.
     * @param posAmount Position-token quantity to redeem (ST raw units).
     * @param receiver Receiver recorded in the adapter-level redeem request event.
     * @dev Only callable by controller when not paused.
     * @dev Pulls position token from vault, then submits redeem request to SubRed.
     */
    function requestRedeemAsync(uint256 posAmount, address receiver) external override onlyController whenNotPaused {
        IERC20(ST_TOKEN).safeTransferFrom(VAULT, address(this), posAmount);
        _redeem(posAmount, uint64(block.timestamp + redeemDeadlineWindow));
        _registerAsyncRedeem(posAmount, receiver);
    }

    /**
     * @notice Retry async redeem using position tokens currently held by this adapter.
     * @param retryPosAmount Position-token amount to redeem from adapter local balance.
     * @param receiver Receiver used for adapter-level async redeem request events.
     * @dev Only callable by controller when not paused.
     */
    function retryRedeemAsync(uint256 retryPosAmount, address receiver) external override onlyController whenNotPaused {
        if (retryPosAmount == 0) {
            revert InvalidAmount();
        }
        if (IERC20(ST_TOKEN).balanceOf(address(this)) < retryPosAmount) {
            revert InvalidAmount();
        }

        _redeem(retryPosAmount, uint64(block.timestamp + redeemDeadlineWindow));
        _registerAsyncRedeem(retryPosAmount, receiver);
    }

    // =============================================================
    // Internal Protocol Calls
    // =============================================================

    /**
     * @notice Internal helper to call SubRed subscribe.
     * @param amountAsset Amount to subscribe (asset raw units).
     * @param deadline Digift subscribe deadline.
     * @dev This function only sends subscribe request.
     */
    function _subscribe(uint256 amountAsset, uint64 deadline) internal {
        if (amountAsset == 0) {
            revert InvalidAmount();
        }
        // Minimum-privilege approval: approve exact amount then reset.
        ASSET.forceApprove(address(SUB_RED), amountAsset);
        SUB_RED.subscribe(ST_TOKEN, address(ASSET), amountAsset, deadline);
        ASSET.forceApprove(address(SUB_RED), 0);
    }

    function _floorToStep(uint256 amount, uint256 step) internal pure returns (uint256) {
        if (step == 0) {
            return amount;
        }
        return amount - (amount % step);
    }

    /**
     * @notice Internal helper to call SubRed redeem.
     * @param quantity Amount of ST token (shares) to redeem.
     * @param deadline Digift redeem deadline.
     * @dev Approves ST_TOKEN to SubRed then calls redeem.
     */
    function _redeem(uint256 quantity, uint64 deadline) internal {
        if (quantity == 0) {
            revert InvalidAmount();
        }
        // Minimum-privilege approval: approve exact amount then reset.
        IERC20(ST_TOKEN).forceApprove(address(SUB_RED), quantity);
        SUB_RED.redeem(ST_TOKEN, address(ASSET), quantity, deadline);
        IERC20(ST_TOKEN).forceApprove(address(SUB_RED), 0);
    }

    function _scaleToAssetRaw(uint256 amountStRaw, uint8 stDecimals, uint8 assetDecimals, Math.Rounding rounding)
        internal
        pure
        returns (uint256)
    {
        if (assetDecimals >= stDecimals) {
            return amountStRaw * (10 ** (assetDecimals - stDecimals));
        }
        uint256 divisor = 10 ** (stDecimals - assetDecimals);
        if (rounding == Math.Rounding.Ceil) {
            return Math.ceilDiv(amountStRaw, divisor);
        }
        return amountStRaw / divisor;
    }
}
