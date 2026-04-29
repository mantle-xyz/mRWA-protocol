// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISubRedManagement} from "../../interfaces/adapters/digift/ISubRedManagement.sol";
import {BaseAsync7540AdapterUpgradeable} from "../base/capabilities/BaseAsync7540AdapterUpgradeable.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title SubRedManagementAdapter (Upgradeable)
/// @notice Async-first adapter for Digift SubRed subscribe/redeem flow.
///         Deployed behind a BeaconProxy via SubRedManagementAdapterFactory.
/// @dev Controller drives unified adapter methods. Uses ERC-7201 namespaced storage.
contract SubRedManagementAdapter is BaseAsync7540AdapterUpgradeable {
    using SafeERC20 for IERC20;

    // =============================================================
    //                  ERC-7201 NAMESPACED STORAGE
    // =============================================================

    struct ExecutionConstraints {
        uint256 minSubscribeAsset;
        uint256 subscribeStepAsset;
        uint256 minRedeemPos;
        uint256 redeemStepPos;
    }

    /// @custom:storage-location erc7201:mrwa.storage.SubRedManagementAdapter
    struct SubRedAdapterStorage {
        ISubRedManagement subRed;
        address stToken;
        ExecutionConstraints executionConstraints;
        uint64 subscribeDeadlineWindow;
        uint64 redeemDeadlineWindow;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("mrwa.storage.SubRedManagementAdapter")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SUBRED_ADAPTER_STORAGE_LOCATION =
        0xb22e4412b8a9ccac26fd761a00159c74e4a8f8a39d20b2cbec0aa5b46bffd100;

    function _getSubRedAdapterStorage() private pure returns (SubRedAdapterStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := SUBRED_ADAPTER_STORAGE_LOCATION
        }
    }

    // =============================================================
    //                          EVENTS
    // =============================================================

    event ExecutionConstraintsUpdated(
        uint256 minSubscribeAsset, uint256 subscribeStepAsset, uint256 minRedeemPos, uint256 redeemStepPos
    );
    event SubscribeDeadlineWindowUpdated(uint64 newWindow);
    event RedeemDeadlineWindowUpdated(uint64 newWindow);

    // =============================================================
    //                 CONSTRUCTOR / INITIALIZER
    // =============================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize Digift SubRed adapter.
     * @param vault_ Vault that owns strategy funds.
     * @param subRedManagement Digift SubRedManagement contract.
     * @param stToken_ Target security token address supported by SubRedManagement.
     * @param admin Adapter admin role address.
     * @param controller StrategyController role address.
     * @param accountantExecutor AccountantExecutor role address for manual price updates.
     * @param priceOracle_ Optional DFeedPriceOracle for the ST token. Pass address(0) to use manual pricing.
     */
    function initialize(
        address vault_,
        address subRedManagement,
        address stToken_,
        address admin,
        address controller,
        address accountantExecutor,
        address priceOracle_
    ) external initializer {
        if (subRedManagement == address(0) || stToken_ == address(0)) {
            revert InvalidAddress();
        }

        __BaseAsync7540Adapter_init(vault_, admin, controller, accountantExecutor, priceOracle_);

        SubRedAdapterStorage storage s = _getSubRedAdapterStorage();
        s.subRed = ISubRedManagement(subRedManagement);
        s.stToken = stToken_;
        s.subscribeDeadlineWindow = 6 hours;
        s.redeemDeadlineWindow = 6 hours;
    }

    // =============================================================
    //                       ADAPTER VIEWS
    // =============================================================

    function name() external pure override returns (string memory) {
        return "SubRedManagementAdapter";
    }

    function posToken() external view override returns (address) {
        return _getSubRedAdapterStorage().stToken;
    }

    /// @notice The SubRedManagement contract address.
    function subRed() external view returns (ISubRedManagement) {
        return _getSubRedAdapterStorage().subRed;
    }

    /// @notice The security token address.
    function stToken() external view returns (address) {
        return _getSubRedAdapterStorage().stToken;
    }

    /// @notice Current execution constraints.
    function executionConstraints() external view returns (ExecutionConstraints memory) {
        return _getSubRedAdapterStorage().executionConstraints;
    }

    /// @notice Current subscribe deadline window (seconds).
    function subscribeDeadlineWindow() external view returns (uint64) {
        return _getSubRedAdapterStorage().subscribeDeadlineWindow;
    }

    /// @notice Current redeem deadline window (seconds).
    function redeemDeadlineWindow() external view returns (uint64) {
        return _getSubRedAdapterStorage().redeemDeadlineWindow;
    }

    /**
     * @notice Estimate ST token amount (in ST raw units) for a given asset amount.
     * @dev Uses getPosTokenPrice() in 1e18 precision. Returns 0 when price is unavailable.
     */
    function estimatePosAmount(uint256 amountAsset) external view override returns (uint256 positionAmount) {
        SubRedAdapterStorage storage s = _getSubRedAdapterStorage();
        uint8 assetDecimals = IERC20Metadata(address(_asset())).decimals();
        uint8 stDecimals = IERC20Metadata(s.stToken).decimals();
        return _estimatePosAmount(amountAsset, assetDecimals, stDecimals);
    }

    function _estimatePosAmount(uint256 amountAsset, uint8 assetDecimals, uint8 stDecimals)
        internal
        view
        returns (uint256)
    {
        if (amountAsset == 0) {
            return 0;
        }
        uint256 priceE18 = getPosTokenPrice();
        if (priceE18 == 0) {
            return 0;
        }
        if (stDecimals >= assetDecimals) {
            return Math.mulDiv(amountAsset, 1e18 * (10 ** (stDecimals - assetDecimals)), priceE18, Math.Rounding.Floor);
        }
        return Math.mulDiv(amountAsset, 1e18, priceE18 * (10 ** (assetDecimals - stDecimals)), Math.Rounding.Floor);
    }

    function _estimateAssetAmount(uint256 amountPosRaw, uint8 assetDecimals, uint8 stDecimals, Math.Rounding rounding)
        internal
        view
        returns (uint256)
    {
        if (amountPosRaw == 0) {
            return 0;
        }
        uint256 priceE18 = getPosTokenPrice();
        if (priceE18 == 0) {
            return 0;
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
        SubRedAdapterStorage storage s = _getSubRedAdapterStorage();
        uint8 assetDecimals = IERC20Metadata(address(_asset())).decimals();
        uint8 stDecimals = IERC20Metadata(s.stToken).decimals();
        uint256 settledVaultPosBalance = IERC20(s.stToken).balanceOf(_vault());
        return _estimateAssetAmount(settledVaultPosBalance, assetDecimals, stDecimals, Math.Rounding.Floor);
    }

    /**
     * @notice Preview a deposit aligned to subscribe step and minimum.
     * @param amountAsset Requested asset amount (vault asset raw units).
     * @return ok True when aligned amount is non-zero and meets minSubscribeAsset.
     * @return executableAssetAmount Step-aligned asset amount actually executable. Zero when ok is false.
     * @return expectedPosAmount Estimated position-token amount (ST raw units) for executableAssetAmount.
     */
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
        SubRedAdapterStorage storage s = _getSubRedAdapterStorage();
        ExecutionConstraints memory constraints = s.executionConstraints;
        executableAssetAmount = _floorToStep(amountAsset, constraints.subscribeStepAsset);
        if (executableAssetAmount == 0 || executableAssetAmount < constraints.minSubscribeAsset) {
            return (false, 0, 0);
        }

        uint8 assetDecimals = IERC20Metadata(address(_asset())).decimals();
        uint8 stDecimals = IERC20Metadata(s.stToken).decimals();
        expectedPosAmount = _estimatePosAmount(executableAssetAmount, assetDecimals, stDecimals);
        ok = executableAssetAmount > 0;
    }

    /**
     * @notice Preview a redeem aligned to redeem step and minimum.
     * @param amountAsset Requested asset amount the caller wants to receive.
     * @return ok True when aligned position-token amount is non-zero and meets minRedeemPos.
     * @return executableAssetAmount Asset amount corresponding to the step-aligned position-token amount.
     *         Equals amountAsset when no rounding is applied; otherwise reflects the rounded-up asset cost.
     * @return expectedPosAmount Step-aligned position-token amount (ST raw units) to redeem. Zero when ok is false.
     */
    function previewRedeem(uint256 amountAsset)
        external
        view
        override
        returns (bool ok, uint256 executableAssetAmount, uint256 expectedPosAmount)
    {
        SubRedAdapterStorage storage s = _getSubRedAdapterStorage();
        uint8 assetDecimals = IERC20Metadata(address(_asset())).decimals();
        uint8 stDecimals = IERC20Metadata(s.stToken).decimals();

        uint256 originalPosAmount = _estimatePosAmount(amountAsset, assetDecimals, stDecimals);
        if (originalPosAmount == 0) {
            return (false, 0, 0);
        }

        ExecutionConstraints memory constraints = s.executionConstraints;
        expectedPosAmount = _floorToStep(originalPosAmount, constraints.redeemStepPos);
        if (expectedPosAmount == 0 || expectedPosAmount < constraints.minRedeemPos) {
            return (false, 0, 0);
        }

        if (expectedPosAmount == originalPosAmount) {
            return (true, amountAsset, expectedPosAmount);
        }

        executableAssetAmount = _estimateAssetAmount(expectedPosAmount, assetDecimals, stDecimals, Math.Rounding.Ceil);
        ok = executableAssetAmount > 0;
    }

    // =============================================================
    //                      ADMIN CONTROLS
    // =============================================================

    /**
     * @notice Update subscribe deadline window used by deposit().
     * @param newWindow New deadline window in seconds.
     * @dev Only callable by DEFAULT_ADMIN_ROLE.
     */
    function setSubscribeDeadlineWindow(uint64 newWindow) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _getSubRedAdapterStorage().subscribeDeadlineWindow = newWindow;
        emit SubscribeDeadlineWindowUpdated(newWindow);
    }

    /**
     * @notice Update redeem deadline window used by requestRedeemAsync().
     * @param newWindow New deadline window in seconds.
     * @dev Only callable by DEFAULT_ADMIN_ROLE.
     */
    function setRedeemDeadlineWindow(uint64 newWindow) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _getSubRedAdapterStorage().redeemDeadlineWindow = newWindow;
        emit RedeemDeadlineWindowUpdated(newWindow);
    }

    /**
     * @notice Set the subscribe/redeem minimums and increments enforced by the underlying DigiFt venue.
     * @param minSubscribeAsset_ Min asset amount for subscribe. Zero disables the check.
     * @param subscribeStepAsset_ Subscribe increment in asset raw units. Zero disables step normalization.
     * @param minRedeemPos_ Min position-token amount for redeem. Zero disables the check.
     * @param redeemStepPos_ Redeem increment in position-token raw units. Zero disables step normalization.
     * @dev preview* returns (false, 0, 0) when the aligned amount is below configured minimums.
     */
    function setExecutionConstraints(
        uint256 minSubscribeAsset_,
        uint256 subscribeStepAsset_,
        uint256 minRedeemPos_,
        uint256 redeemStepPos_
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _getSubRedAdapterStorage().executionConstraints = ExecutionConstraints({
            minSubscribeAsset: minSubscribeAsset_,
            subscribeStepAsset: subscribeStepAsset_,
            minRedeemPos: minRedeemPos_,
            redeemStepPos: redeemStepPos_
        });

        emit ExecutionConstraintsUpdated(minSubscribeAsset_, subscribeStepAsset_, minRedeemPos_, redeemStepPos_);
    }

    // =============================================================
    //                    CONTROLLER ACTIONS
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
        _asset().safeTransferFrom(_vault(), address(this), amountAsset);
        _subscribe(amountAsset, uint64(block.timestamp + _getSubRedAdapterStorage().subscribeDeadlineWindow));
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
        SubRedAdapterStorage storage s = _getSubRedAdapterStorage();
        IERC20(s.stToken).safeTransferFrom(_vault(), address(this), posAmount);
        _redeem(posAmount, uint64(block.timestamp + s.redeemDeadlineWindow));
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
        SubRedAdapterStorage storage s = _getSubRedAdapterStorage();
        if (IERC20(s.stToken).balanceOf(address(this)) < retryPosAmount) {
            revert InvalidAmount();
        }

        _redeem(retryPosAmount, uint64(block.timestamp + s.redeemDeadlineWindow));
        _registerAsyncRedeem(retryPosAmount, receiver);
    }

    // =============================================================
    //                  INTERNAL PROTOCOL CALLS
    // =============================================================

    function _subscribe(uint256 amountAsset, uint64 deadline) internal {
        if (amountAsset == 0) {
            revert InvalidAmount();
        }
        SubRedAdapterStorage storage s = _getSubRedAdapterStorage();
        IERC20 assetToken = _asset();
        // Minimum-privilege approval: approve exact amount then reset.
        assetToken.forceApprove(address(s.subRed), amountAsset);
        s.subRed.subscribe(s.stToken, address(assetToken), amountAsset, deadline);
        assetToken.forceApprove(address(s.subRed), 0);
    }

    function _floorToStep(uint256 amount, uint256 step) internal pure returns (uint256) {
        if (step == 0) {
            return amount;
        }
        return amount - (amount % step);
    }

    function _redeem(uint256 quantity, uint64 deadline) internal {
        if (quantity == 0) {
            revert InvalidAmount();
        }
        SubRedAdapterStorage storage s = _getSubRedAdapterStorage();
        // Minimum-privilege approval: approve exact amount then reset.
        IERC20(s.stToken).forceApprove(address(s.subRed), quantity);
        s.subRed.redeem(s.stToken, address(_asset()), quantity, deadline);
        IERC20(s.stToken).forceApprove(address(s.subRed), 0);
    }
}
