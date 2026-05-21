// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategyAdapter} from "../../interfaces/adapters/IStrategyAdapter.sol";

import {IDFeedPriceOracle} from "../../interfaces/adapters/digift/IDFeedPriceOracle.sol";
import {IMantleYieldVault} from "../../interfaces/vault/IMantleYieldVault.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title BaseAdapterUpgradeable
/// @notice Upgradeable version of BaseAdapter using ERC-7201 namespaced storage.
///         Designed to be deployed behind a BeaconProxy via a factory.
abstract contract BaseAdapterUpgradeable is
    IStrategyAdapter,
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuard,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    // =============================================================
    //                        CONSTANTS
    // =============================================================

    bytes32 public constant CONTROLLER_ROLE = keccak256("CONTROLLER_ROLE");
    bytes32 public constant ACCOUNTANT_EXECUTOR_ROLE = keccak256("ACCOUNTANT_EXECUTOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // =============================================================
    //                  ERC-7201 NAMESPACED STORAGE
    // =============================================================

    /// @custom:storage-location erc7201:mrwa.storage.BaseAdapter
    struct BaseAdapterStorage {
        IERC20 asset;
        address vault;
        address priceOracle;
        uint256 manualPosTokenPrice;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("mrwa.storage.BaseAdapter")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BASE_ADAPTER_STORAGE_LOCATION =
        0x4390e40ae50d958ff48664d902a4108bf8c8ed4ad29a6242a40810b690868b00;

    function _getBaseAdapterStorage() internal pure returns (BaseAdapterStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := BASE_ADAPTER_STORAGE_LOCATION
        }
    }

    // =============================================================
    //                          ERRORS
    // =============================================================

    error InvalidAmount();
    error InvalidAddress();
    error Unsupported();
    error SweepProtectedToken(address token);
    error InvalidToken(address token);

    // =============================================================
    //                          EVENTS
    // =============================================================

    event ManualPosTokenPriceUpdated(uint256 oldPriceE18, uint256 newPriceE18, address indexed updater);
    event PriceOracleUpdated(address indexed oldOracle, address indexed newOracle, address indexed updater);

    // =============================================================
    //                         MODIFIERS
    // =============================================================

    modifier onlyAdmin() {
        _checkRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _;
    }

    modifier onlyController() {
        _checkRole(CONTROLLER_ROLE, msg.sender);
        _;
    }

    modifier onlyAccountantExecutor() {
        _checkRole(ACCOUNTANT_EXECUTOR_ROLE, msg.sender);
        _;
    }

    // =============================================================
    //                 INITIALIZER (replaces constructor)
    // =============================================================

    function __BaseAdapter_init(
        address vault_,
        address admin_,
        address controller_,
        address accountantExecutor_,
        address priceOracle_
    ) internal onlyInitializing {
        __AccessControl_init();
        __Pausable_init();
        __BaseAdapter_init_unchained(vault_, admin_, controller_, accountantExecutor_, priceOracle_);
    }

    function __BaseAdapter_init_unchained(
        address vault_,
        address admin_,
        address controller_,
        address accountantExecutor_,
        address priceOracle_
    ) internal onlyInitializing {
        if (
            vault_ == address(0) || admin_ == address(0) || controller_ == address(0)
                || accountantExecutor_ == address(0)
        ) {
            revert InvalidAddress();
        }

        BaseAdapterStorage storage s = _getBaseAdapterStorage();
        s.vault = vault_;
        s.asset = IERC20(IMantleYieldVault(vault_).asset());
        s.priceOracle = priceOracle_;

        if (address(s.asset) == address(0)) {
            revert InvalidAddress();
        }

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ACCOUNTANT_EXECUTOR_ROLE, accountantExecutor_);
        _grantRole(CONTROLLER_ROLE, controller_);
        _grantRole(PAUSER_ROLE, controller_);
    }

    // =============================================================
    //                        CORE VIEWS
    // =============================================================

    function asset() external view virtual override returns (address) {
        return address(_getBaseAdapterStorage().asset);
    }

    function posToken() external view virtual override returns (address);

    function estimatePosAmount(uint256 assetAmount) external view virtual override returns (uint256 positionAmount) {
        positionAmount = assetAmount;
    }

    function previewDeposit(uint256 assetAmount)
        external
        view
        virtual
        override
        returns (bool ok, uint256 executableAssetAmount, uint256 expectedPosAmount)
    {
        ok = assetAmount > 0;
        executableAssetAmount = assetAmount;
        expectedPosAmount = 0;
    }

    function previewRedeem(uint256 assetAmount)
        external
        view
        virtual
        override
        returns (bool ok, uint256 executableAssetAmount, uint256 expectedPosAmount)
    {
        ok = assetAmount > 0;
        executableAssetAmount = assetAmount;
        expectedPosAmount = 0;
    }

    /// @notice Position-token quote in 1e18 precision (asset per 1 pos token).
    /// @dev Priority: oracle valid price when configured, otherwise manual price.
    ///      Fallback: no valid source -> 0 (callers decide how to degrade).
    function getPosTokenPrice() public view virtual override returns (uint256) {
        BaseAdapterStorage storage s = _getBaseAdapterStorage();
        if (s.priceOracle != address(0)) {
            uint256 rawPrice = IDFeedPriceOracle(s.priceOracle).getPrice();
            if (rawPrice > 0) {
                uint8 dec = IDFeedPriceOracle(s.priceOracle).decimals();
                return Math.mulDiv(rawPrice, 1e18, 10 ** dec, Math.Rounding.Floor);
            }
            return 0;
        }

        if (s.manualPosTokenPrice > 0) {
            return s.manualPosTokenPrice;
        }

        return 0;
    }

    function vault() external view virtual override returns (address) {
        return _getBaseAdapterStorage().vault;
    }

    function priceOracle() external view virtual override returns (address) {
        return _getBaseAdapterStorage().priceOracle;
    }

    // =============================================================
    //                       CORE ACTIONS
    // =============================================================

    /// @notice Controller-triggered asset return path: move token balance from adapter back to Vault.
    function sweepToVault(address token, uint256 amount)
        external
        virtual
        override
        onlyController
        whenNotPaused
        returns (uint256 claimed)
    {
        if (token == address(0)) {
            revert InvalidToken(token);
        }
        BaseAdapterStorage storage s = _getBaseAdapterStorage();
        uint256 bal = IERC20(token).balanceOf(address(this));
        claimed = amount > bal ? bal : amount;
        if (claimed > 0) {
            IERC20(token).safeTransfer(s.vault, claimed);
        }
    }

    // =============================================================
    //                      ADMIN ACTIONS
    // =============================================================

    function setPaused(bool paused_) external virtual override onlyRole(PAUSER_ROLE) {
        if (paused_ != paused()) {
            if (paused_) {
                _pause();
            } else {
                _unpause();
            }
        }
        emit AdapterPaused(address(this), paused_);
    }

    /// @notice Set manual position-token price (1e18 precision). Set to 0 to clear manual override.
    function setManualPosTokenPrice(uint256 priceE18) external virtual onlyAccountantExecutor {
        BaseAdapterStorage storage s = _getBaseAdapterStorage();
        if (s.priceOracle != address(0)) {
            revert Unsupported();
        }
        uint256 oldPrice = s.manualPosTokenPrice;
        s.manualPosTokenPrice = priceE18;
        emit ManualPosTokenPriceUpdated(oldPrice, priceE18, msg.sender);
    }

    /// @notice Update oracle address. Set to address(0) to disable oracle and use manual pricing.
    function setPriceOracle(address newOracle) external onlyAdmin {
        BaseAdapterStorage storage s = _getBaseAdapterStorage();
        address oldOracle = s.priceOracle;
        s.priceOracle = newOracle;
        emit PriceOracleUpdated(oldOracle, newOracle, msg.sender);
    }

    /// @notice Emergency sweep: transfer all of a token to receiver (admin only)
    function sweep(address token, address receiver) external onlyAdmin {
        if (token == address(0)) {
            revert InvalidToken(token);
        }
        if (receiver == address(0)) {
            revert InvalidAddress();
        }
        BaseAdapterStorage storage s = _getBaseAdapterStorage();
        if (token == address(s.asset)) {
            revert SweepProtectedToken(token);
        }
        address pToken;
        try this.posToken() returns (address t) {
            pToken = t;
        } catch {
            pToken = address(0);
        }
        if (pToken != address(0) && token == pToken) {
            revert SweepProtectedToken(token);
        }
        uint256 bal = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(receiver, bal);
    }

    // =============================================================
    //                      EVENT HELPERS
    // =============================================================

    function _emitAdapterDeposit(uint256 amount, address receiver, uint256 sharesOrPos) internal {
        emit AdapterDeposit(address(this), msg.sender, amount, receiver, sharesOrPos);
    }

    function _emitAdapterWithdrawSync(uint256 amount, address receiver, uint256 actualAmount) internal {
        emit AdapterWithdrawSync(address(this), msg.sender, amount, receiver, actualAmount);
    }

    function _emitAdapterRedeemRequested(uint256 amount, address receiver) internal {
        emit AdapterRedeemRequested(address(this), msg.sender, amount, receiver);
    }

    // =============================================================
    //                   INTERNAL HELPERS
    // =============================================================

    /// @dev Convenience accessor for subclasses to read the vault address.
    function _vault() internal view returns (address) {
        return _getBaseAdapterStorage().vault;
    }

    /// @dev Convenience accessor for subclasses to read the asset.
    function _asset() internal view returns (IERC20) {
        return _getBaseAdapterStorage().asset;
    }
}
