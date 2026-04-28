// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAccountant} from "../../interfaces/accountant/IAccountant.sol";
import {IMantleVaultGateway} from "../../interfaces/vault/IMantleVaultGateway.sol";
import {IMantleYieldVault} from "../../interfaces/vault/IMantleYieldVault.sol";

import {
    AccessControlDefaultAdminRulesUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

abstract contract MantleYieldVaultStorage is
    Initializable,
    ERC4626Upgradeable,
    AccessControlDefaultAdminRulesUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    IMantleYieldVault
{
    using SafeERC20 for IERC20;
    using Math for uint256;

    // =============================================================
    // Roles & Privileged Contracts
    // =============================================================

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    address public controller;
    address public accountant;
    address public treasury;
    address public gateway;

    // =============================================================
    // Core State
    // =============================================================

    uint256 public constant FEE_BASIS = 10_000;
    uint256 public maxRedemptionFeeBps;
    uint256 public redemptionFeeBps;
    uint256 public minRedeemAmount;
    uint256 public minDepositAmount;

    uint256 public totalLockedShares;

    // Invest in-flight: USDC sent out -> adapter underlying tokens not yet received
    uint256 public totalInvestInFlight;
    mapping(address adapter => uint256) public adapterInvestInFlightTokens;

    // Redeem in-flight: adapter underlying tokens sent out -> USDC not yet received
    uint256 public totalRedeemInFlight;
    mapping(address adapter => uint256) public adapterRedeemInFlightUsdc;

    uint256 public nextRequestId;
    uint256 public nextInFlightId;

    mapping(uint256 requestId => RedemptionRequest) public requests;
    mapping(uint256 inFlightId => InFlightRecord) public inFlightRecords;

    // =============================================================
    // Per-Owner Aggregated Tracking
    // =============================================================

    mapping(address owner => uint256) internal _pendingShares;

    // =============================================================
    // Adapter Registry
    // =============================================================

    address[] public adapters;
    mapping(address => bool) public isAdapter;

    // Count of redemption requests currently in PENDING status (not yet PROCESSING).
    // Used by controller to gate rebalance divest — prevents pre-empting user liability.
    uint256 public pendingRequestCount;

    // =============================================================
    // Modifiers
    // =============================================================

    modifier onlyController() {
        _onlyController();
        _;
    }

    modifier onlyAccountant() {
        _onlyAccountant();
        _;
    }

    modifier onlyGateway() {
        _onlyGateway();
        _;
    }

    function _onlyController() internal view {
        if (msg.sender != controller) revert Vault__OnlyController();
    }

    function _onlyAccountant() internal view {
        if (msg.sender != accountant) revert Vault__OnlyAccountant();
    }

    function _onlyGateway() internal view {
        if (msg.sender != gateway) revert Vault__OnlyGateway();
    }

    function _accountant() internal view returns (IAccountant) {
        return IAccountant(accountant);
    }

    function _currentExchangeRate() internal view returns (uint256 rate) {
        rate = _accountant().getRate();
        if (rate == 0) revert Vault__ZeroExchangeRate();
    }

    // =============================================================
    // Initialization (OZ upgradeable pattern: _init runs parent inits + unchained,
    // _init_unchained sets only this contract's own state. Constructor with
    // `_disableInitializers()` lives on the deployable leaf contract.)
    // =============================================================

    function __MantleYieldVaultStorage_init(InitParams calldata p) internal onlyInitializing {
        __ERC20_init(p.name, p.symbol);
        __ERC4626_init(p.asset);
        __AccessControlDefaultAdminRules_init(3 days, p.admin);
        __Pausable_init();
        __MantleYieldVaultStorage_init_unchained(p);
    }

    function __MantleYieldVaultStorage_init_unchained(InitParams calldata p) internal onlyInitializing {
        if (
            address(p.asset) == address(0) || p.admin == address(0) || p.controller == address(0)
                || p.accountant == address(0) || p.treasury == address(0) || p.gateway == address(0)
        ) {
            revert Vault__ZeroAddress();
        }

        if (p.maxRedemptionFeeBps > FEE_BASIS) revert Vault__FeeTooHigh(p.maxRedemptionFeeBps, FEE_BASIS);
        if (p.redemptionFeeBps > p.maxRedemptionFeeBps) {
            revert Vault__FeeTooHigh(p.redemptionFeeBps, p.maxRedemptionFeeBps);
        }

        gateway = p.gateway;
        controller = p.controller;
        accountant = p.accountant;
        treasury = p.treasury;
        maxRedemptionFeeBps = p.maxRedemptionFeeBps;
        redemptionFeeBps = p.redemptionFeeBps;
        minRedeemAmount = p.minRedeemAmount;
        minDepositAmount = p.minDepositAmount;
        nextRequestId = 1;
        nextInFlightId = 1;
    }

    // =============================================================
    // AML Compliance Hook (intercepts all share transfers)
    // =============================================================

    function _update(address from, address to, uint256 value) internal virtual override {
        if (from != address(0) && to != address(0)) {
            _requireNotPaused();
            // Allow the dedicated sanctioned-routing path only:
            // Allow only gateway-routed moves into the configured sanctionSafe.
            if (!(msg.sender == gateway && IMantleVaultGateway(gateway).isSanctionSafe(to))) {
                if (gateway == address(0)) revert Vault__OnlyGateway();
                IMantleVaultGateway(gateway).enforceShareTransfer(from, to);
            }
        }
        super._update(from, to, value);
    }
}
