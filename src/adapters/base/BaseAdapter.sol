// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategyAdapter} from "../../interfaces/adapters/IStrategyAdapter.sol";

import {IDFeedPriceOracle} from "../../interfaces/adapters/digift/IDFeedPriceOracle.sol";
import {IMantleYieldVault} from "../../interfaces/vault/IMantleYieldVault.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

abstract contract BaseAdapter is IStrategyAdapter, AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    bytes32 public constant CONTROLLER_ROLE = keccak256("CONTROLLER_ROLE");
    bytes32 public constant ACCOUNTANT_EXECUTOR_ROLE = keccak256("ACCOUNTANT_EXECUTOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    IERC20 public immutable ASSET;
    address public immutable VAULT;
    address public priceOracle;
    uint256 public manualPosTokenPrice;

    error Adapter__InvalidAmount();
    error Adapter__InvalidAddress();
    error Adapter__Unsupported();
    error Adapter__SweepProtectedToken(address token);
    error Adapter__InvalidToken(address token);

    event ManualPosTokenPriceUpdated(uint256 oldPriceE18, uint256 newPriceE18, address indexed updater);
    event PriceOracleUpdated(address indexed oldOracle, address indexed newOracle, address indexed updater);

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

    constructor(
        address vault_,
        address admin_,
        address controller_,
        address accountantExecutor_,
        address priceOracle_
    ) {
        if (
            vault_ == address(0) || admin_ == address(0) || controller_ == address(0)
                || accountantExecutor_ == address(0)
        ) {
            revert Adapter__InvalidAddress();
        }
        VAULT = vault_;
        ASSET = IERC20(IMantleYieldVault(vault_).asset());
        priceOracle = priceOracle_;
        if (address(ASSET) == address(0)) {
            revert Adapter__InvalidAddress();
        }
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ACCOUNTANT_EXECUTOR_ROLE, accountantExecutor_);
        _grantRole(CONTROLLER_ROLE, controller_);
        _grantRole(PAUSER_ROLE, controller_);
    }

    // =============================================================
    // Core Views
    // =============================================================

    function asset() external view virtual override returns (address) {
        return address(ASSET);
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
        if (priceOracle != address(0)) {
            uint256 rawPrice = IDFeedPriceOracle(priceOracle).getPrice();
            if (rawPrice > 0) {
                uint8 dec = IDFeedPriceOracle(priceOracle).decimals();
                return Math.mulDiv(rawPrice, 1e18, 10 ** dec, Math.Rounding.Floor);
            }
            return 0;
        }

        if (manualPosTokenPrice > 0) {
            return manualPosTokenPrice;
        }

        return 0;
    }

    function vault() external view virtual override returns (address) {
        return VAULT;
    }

    // =============================================================
    // Core Actions
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
            revert Adapter__InvalidToken(token);
        }
        uint256 bal = IERC20(token).balanceOf(address(this));
        claimed = amount > bal ? bal : amount;
        if (claimed > 0) {
            IERC20(token).safeTransfer(VAULT, claimed);
        }
    }

    // =============================================================
    // Admin Actions
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
        if (priceOracle != address(0)) {
            revert Adapter__Unsupported();
        }
        uint256 oldPrice = manualPosTokenPrice;
        manualPosTokenPrice = priceE18;
        emit ManualPosTokenPriceUpdated(oldPrice, priceE18, msg.sender);
    }

    /// @notice Update oracle address. Set to address(0) to disable oracle and use manual pricing.
    function setPriceOracle(address newOracle) external onlyAdmin {
        address oldOracle = priceOracle;
        priceOracle = newOracle;
        emit PriceOracleUpdated(oldOracle, newOracle, msg.sender);
    }

    /// @notice Emergency sweep: transfer all of a token to receiver (admin only)
    function sweep(address token, address receiver) external onlyAdmin {
        if (token == address(0)) {
            revert Adapter__InvalidToken(token);
        }
        if (receiver == address(0)) {
            revert Adapter__InvalidAddress();
        }
        if (token == address(ASSET)) {
            revert Adapter__SweepProtectedToken(token);
        }
        address pToken;
        try this.posToken() returns (address t) {
            pToken = t;
        } catch {
            pToken = address(0);
        }
        if (pToken != address(0) && token == pToken) {
            revert Adapter__SweepProtectedToken(token);
        }
        uint256 bal = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(receiver, bal);
    }

    // =============================================================
    // Event Helpers
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
}
