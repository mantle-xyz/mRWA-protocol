// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDFeedPriceOracle} from "../../interfaces/adapters/digift/IDFeedPriceOracle.sol";
import {ISubRedManagement} from "../../interfaces/adapters/digift/ISubRedManagement.sol";
import {BaseAsync7540Adapter} from "../base/capabilities/BaseAsync7540Adapter.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Async-first adapter for Digift SubRed subscribe/redeem flow.
/// @dev Controller drives unified adapter methods.
contract SubRedManagementAdapter is BaseAsync7540Adapter {
    using SafeERC20 for IERC20;

    ISubRedManagement public immutable SUB_RED;
    address public immutable ST_TOKEN;

    uint64 public subscribeDeadlineWindow = 6 hours;
    uint64 public redeemDeadlineWindow = 6 hours;

    event SubscribeDeadlineWindowUpdated(uint64 newWindow);
    event RedeemDeadlineWindowUpdated(uint64 newWindow);

    /**
     * @notice Initialize Digift SubRed adapter.
     * @param vault_ Vault that owns strategy funds.
     * @param subRedManagement Digift SubRedManagement contract.
     * @param stToken Target security token (e.g. iSNR, uMINT).
     * @param admin Adapter admin role address.
     * @param controller StrategyController role address.
     * @param priceOracle_ Optional DFeedPriceOracle for ST token (e.g. 0xb5d9870e... for uMINT). Pass address(0) for 1:1 estimate.
     */
    constructor(
        address vault_,
        address subRedManagement,
        address stToken,
        address admin,
        address controller,
        address priceOracle_
    ) BaseAsync7540Adapter(vault_, admin, controller, priceOracle_) {
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
     * @notice Estimate ST token amount (in ST raw units) for a given asset amount using DFeed price when oracle is set.
     * @dev Formula: positionAmount = (amountAsset * 10**oracleDecimals * 10**stDecimals) / (getPrice() * 10**assetDecimals) (floor).
     *      getPrice() is "asset per 1 ST" (e.g. USDC/USDT per 1 ST). Result is in ST token's smallest unit (e.g. 18 decimals).
     *      Rounds down. If priceOracle is zero or getPrice() is 0, returns amountAsset scaled to ST raw (1:1 human).
     */
    function estimatePosAmount(uint256 amountAsset) external view override returns (uint256 positionAmount) {
        uint8 assetDecimals = IERC20Metadata(address(ASSET)).decimals();
        uint8 stDecimals = IERC20Metadata(ST_TOKEN).decimals();

        if (priceOracle == address(0) || amountAsset == 0) {
            // 1:1 in human terms: scale amountAsset to ST raw
            return _scaleToStRaw(amountAsset, assetDecimals, stDecimals);
        }
        uint256 price = IDFeedPriceOracle(priceOracle).getPrice();
        if (price == 0) {
            return _scaleToStRaw(amountAsset, assetDecimals, stDecimals);
        }
        uint8 dec = IDFeedPriceOracle(priceOracle).decimals();
        return (amountAsset * (10 ** dec) * (10 ** stDecimals)) / (price * (10 ** assetDecimals));
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
        if (priceOracle == address(0) || amountPosRaw == 0) {
            return _scaleToAssetRaw(amountPosRaw, stDecimals, assetDecimals);
        }
        uint256 price = IDFeedPriceOracle(priceOracle).getPrice();
        if (price == 0) {
            return _scaleToAssetRaw(amountPosRaw, stDecimals, assetDecimals);
        }
        uint8 dec = IDFeedPriceOracle(priceOracle).decimals();
        return (amountPosRaw * price * (10 ** assetDecimals)) / ((10 ** dec) * (10 ** stDecimals));
    }

    /**
     * @notice Return current strategy value in vault asset units (e.g. USDC/USDT).
     * @dev Value = adapter idle asset + (adapter-held + vault-held) position token value
     *      converted into asset units (oracle if configured).
     */
    function getPrice() external view override returns (uint256) {
        if (priceOracle == address(0)) return 1e18;
        uint256 p = IDFeedPriceOracle(priceOracle).getPrice();
        if (p == 0) return 1e18;
        uint8 dec = IDFeedPriceOracle(priceOracle).decimals();
        return p * 1e18 / (10 ** dec);
    }

    function totalValue() external view override returns (uint256) {
        uint8 assetDecimals = IERC20Metadata(address(ASSET)).decimals();
        uint8 stDecimals = IERC20Metadata(ST_TOKEN).decimals();
        uint256 posBalance = IERC20(ST_TOKEN).balanceOf(address(this)) + IERC20(ST_TOKEN).balanceOf(VAULT);
        uint256 posValue = _estimateAssetAmount(posBalance, assetDecimals, stDecimals);
        return ASSET.balanceOf(address(this)) + posValue;
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

    // =============================================================
    // Controller Actions
    // =============================================================

    /**
     * @notice Pull funds from Vault and submit subscribe.
     * @param amountAsset Asset amount to subscribe (vault asset raw units).
     * @param receiver Receiver parameter reserved by IStrategyAdapter.
     * @return Subscribed position amount (ST raw units).
     * @dev Only callable by controller when not paused.
     */
    function deposit(uint256 amountAsset, address receiver)
        external
        override
        onlyController
        whenNotPaused
        returns (uint256)
    {
        if (amountAsset == 0) {
            revert InvalidAmount();
        }
        receiver;
        // Pull asset from Vault using temporary allowance set by StrategyController.
        ASSET.safeTransferFrom(VAULT, address(this), amountAsset);
        _subscribe(amountAsset, uint64(block.timestamp + subscribeDeadlineWindow));
        _emitAdapterDeposit(amountAsset, receiver, amountAsset);
        return this.estimatePosAmount(amountAsset);
    }

    /**
     * @notice Register an async redeem request.
     * @param amountAsset Requested redeem amount (asset raw units).
     * @dev amountAsset is asset-denominated; ST quantity is derived via estimatePosAmount(amountAsset).
     * @param receiver Final receiver used to derive deterministic requestId.
     * @dev Only callable by controller when not paused.
     * @dev Pulls position token from vault, then submits redeem request to SubRed.
     */
    function requestRedeemAsync(uint256 amountAsset, address receiver) external override onlyController whenNotPaused {
        uint256 quantity = this.estimatePosAmount(amountAsset);
        IERC20(ST_TOKEN).safeTransferFrom(VAULT, address(this), quantity);
        _redeem(quantity, uint64(block.timestamp + redeemDeadlineWindow));
        _registerAsyncRedeem(amountAsset, receiver);
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
}
