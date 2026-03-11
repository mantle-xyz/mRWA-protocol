// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategyAdapter} from "../../interfaces/adapters/IStrategyAdapter.sol";
import {IMantleYieldVault} from "../../interfaces/vault/IMantleYieldVault.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

abstract contract BaseAdapter is IStrategyAdapter, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant CONTROLLER_ROLE = keccak256("CONTROLLER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    IERC20 public immutable ASSET;
    address public immutable VAULT;
    bool public paused;

    error PausedError();
    error InvalidAmount();
    error InvalidAddress();
    error NotController();
    error Unsupported();
    error SweepProtectedToken(address token);
    error InvalidToken(address token);

    modifier onlyController() {
        if (!hasRole(CONTROLLER_ROLE, msg.sender)) {
            revert NotController();
        }
        _;
    }

    modifier whenNotPaused() {
        if (paused) {
            revert PausedError();
        }
        _;
    }

    constructor(address vault_, address admin, address controller) {
        if (vault_ == address(0) || admin == address(0) || controller == address(0)) {
            revert InvalidAddress();
        }
        VAULT = vault_;
        ASSET = IERC20(IMantleYieldVault(vault_).asset());
        if (address(ASSET) == address(0)) {
            revert InvalidAddress();
        }
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CONTROLLER_ROLE, controller);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(PAUSER_ROLE, controller);
    }

    // =============================================================
    // Core Views
    // =============================================================

    function asset() external view virtual override returns (address) {
        return address(ASSET);
    }

    function posToken() external view virtual override returns (address) {
        return address(0);
    }

    function estimatePosAmount(uint256 assetAmount) external view virtual override returns (uint256 positionAmount) {
        positionAmount = assetAmount;
    }

    function vault() external view virtual override returns (address) {
        return VAULT;
    }

    // =============================================================
    // Core Actions
    // =============================================================

    /// @notice Controller-triggered asset return path: move token balance from adapter back to Vault.
    function claimToVault(address token, uint256 amount)
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
        uint256 bal = IERC20(token).balanceOf(address(this));
        claimed = amount > bal ? bal : amount;
        if (claimed > 0) {
            IERC20(token).safeTransfer(VAULT, claimed);
        }
    }

    // =============================================================
    // Admin Actions
    // =============================================================

    function setPaused(bool p) external {
        require(hasRole(PAUSER_ROLE, msg.sender) || hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "NO_PAUSE_ROLE");
        paused = p;
        emit AdapterPaused(address(this), p);
    }

    /// @notice Emergency sweep: transfer all of a token to receiver (admin only)
    function sweep(address token, address receiver) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(ASSET)) {
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
    // Event Helpers
    // =============================================================

    function _emitAdapterDeposit(uint256 amount, address receiver, uint256 sharesOrPos) internal {
        emit AdapterDeposit(address(this), msg.sender, amount, receiver, sharesOrPos);
    }

    function _emitAdapterWithdrawSync(uint256 amount, address receiver, uint256 actualAmount) internal {
        emit AdapterWithdrawSync(address(this), msg.sender, amount, receiver, actualAmount);
    }

    function _emitAdapterRedeemRequested(uint256 amount, address receiver, bytes32 requestId) internal {
        emit AdapterRedeemRequested(address(this), msg.sender, amount, receiver, requestId);
    }
}
