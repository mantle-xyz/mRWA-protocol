// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategyAdapter} from "../interfaces/adapters/IStrategyAdapter.sol";

import {ISanctionsOracle} from "../interfaces/compliance/ISanctionsOracle.sol";

import {IERC7540Redeem, IMantleYieldVault} from "../interfaces/vault/IMantleYieldVault.sol";
import {AccessControlDefaultAdminRulesUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title MantleYieldVault (ERC-4626 + ERC-7540 Async Redemption, Beacon Proxy Upgradeable)
 * @notice Production-grade RWA asset vault.
 *   - Deposits: Synchronous (standard ERC-4626 deposit/mint)
 *   - Instant redemptions: ERC-4626 redeem/withdraw (atomic when FreeCash is sufficient, reverts otherwise)
 *   - Async redemptions: ERC-7540 requestRedeem ->confirmInFlight  ->   markRequestsDone
 *   - Deployed via VaultFactory (BeaconProxy), upgrades via UpgradeableBeacon.upgradeTo()
 */
contract MantleYieldVault is
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
    address public sanctionSafe;

    // =============================================================
    // Core State
    // =============================================================

    ISanctionsOracle public sanctionsOracle;
    uint256 public exchangeRate;

    uint256 public constant FEE_BASIS = 10_000;
    uint256 public maxRedemptionFeeBps;
    uint256 public maxRateChangeBps;
    uint256 public redemptionFeeBps;
    uint256 public minRedeemAmount;
    uint256 public minDepositAmount;
    bool public syncRedeemDisabled;

    uint256 public totalLockedShares;

    // Invest in-flight: USDC sent out -> adapter underlying tokens not yet received
    uint256 public totalInvestInFlight; // Total invest in-flight USDC equivalent
    mapping(address adapter => uint256) public adapterInvestInFlightTokens; // Per-adapter invest in-flight token amount

    // Redeem in-flight: adapter underlying tokens sent out -> USDC not yet received
    uint256 public totalRedeemInFlight; // Total redeem in-flight USDC equivalent
    mapping(address adapter => uint256) public adapterRedeemInFlightUsdc; // Per-adapter redeem in-flight USDC amount

    uint256 public nextRequestId;
    uint256 public nextInFlightId;

    mapping(uint256 requestId => RedemptionRequest) public requests;
    mapping(uint256 inFlightId => InFlightRecord) public inFlightRecords;

    // =============================================================
    // Per-Owner Aggregated Tracking
    // =============================================================

    mapping(address owner => uint256) private _pendingShares;

    // =============================================================
    // Adapter Registry
    // =============================================================

    address[] public adapters;
    mapping(address => bool) public isAdapter;

    // =============================================================
    // Modifiers
    // =============================================================

    modifier checkSanctions(address account) {
        _checkSanctions(account);
        _;
    }

    modifier onlyController() {
        _onlyController();
        _;
    }

    modifier onlyAccountant() {
        _onlyAccountant();
        _;
    }

    function _checkSanctions(address account) internal view {
        if (sanctionsOracle.isSanctioned(account)) revert Vault__Sanctioned(account);
    }

    function _onlyController() internal view {
        if (msg.sender != controller) revert Vault__OnlyController();
    }

    function _onlyAccountant() internal view {
        if (msg.sender != accountant) revert Vault__OnlyAccountant();
    }

    // =============================================================
    // Constructor & Initialization
    // =============================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(InitParams calldata p) external initializer {
        if (
            address(p.asset) == address(0) || p.admin == address(0) || p.controller == address(0)
                || p.accountant == address(0) || p.sanctionsOracle == address(0) || p.treasury == address(0)
        ) {
            revert Vault__ZeroAddress();
        }

        __ERC20_init(p.name, p.symbol);
        __ERC4626_init(p.asset);
        __AccessControlDefaultAdminRules_init(3 days, p.admin);
        __Pausable_init();

        if (p.maxRedemptionFeeBps > FEE_BASIS) revert Vault__FeeTooHigh(p.maxRedemptionFeeBps, FEE_BASIS);
        if (p.maxRateChangeBps > FEE_BASIS) revert Vault__FeeTooHigh(p.maxRateChangeBps, FEE_BASIS);
        if (p.redemptionFeeBps > p.maxRedemptionFeeBps) {
            revert Vault__FeeTooHigh(p.redemptionFeeBps, p.maxRedemptionFeeBps);
        }

        sanctionsOracle = ISanctionsOracle(p.sanctionsOracle);
        controller = p.controller;
        accountant = p.accountant;
        treasury = p.treasury;
        sanctionSafe = p.sanctionSafe;
        maxRedemptionFeeBps = p.maxRedemptionFeeBps;
        maxRateChangeBps = p.maxRateChangeBps;
        redemptionFeeBps = p.redemptionFeeBps;
        minRedeemAmount = p.minRedeemAmount;
        minDepositAmount = p.minDepositAmount;
        syncRedeemDisabled = p.syncRedeemDisabled;
        exchangeRate = 1e18;
        nextRequestId = 1;
        nextInFlightId = 1;
    }

    // =============================================================
    // AML Compliance Hook (intercepts all share transfers)
    // =============================================================

    function _update(address from, address to, uint256 value) internal virtual override {
        if (from != address(0) && to != address(0)) {
            _requireNotPaused();
        }
        super._update(from, to, value);
    }

    // =============================================================
    // ERC-7540: Async Redemption Requests
    // =============================================================

    function requestRedeem(uint256 shares)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 requestId)
    {
        if (shares == 0) revert Vault__ZeroAmount();

        if(sanctionsOracle.isSanctioned(msg.sender)) {
            _update(msg.sender, sanctionSafe, shares);
            emit SactionSafeIn(msg.sender, asset(), shares);
            return 0;
        }

        uint256 grossAssets = _convertToAssets(shares, Math.Rounding.Floor);
        uint256 fee = grossAssets.mulDiv(redemptionFeeBps, FEE_BASIS, Math.Rounding.Ceil);
        uint256 estimatedAssets = grossAssets - fee;

        if (estimatedAssets < minRedeemAmount) revert Vault__BelowMinRedeem(estimatedAssets, minRedeemAmount);

        _burn(msg.sender, shares);

        totalLockedShares += shares;
        _pendingShares[msg.sender] += shares;

        requestId = nextRequestId++;
        requests[requestId] = RedemptionRequest({
            id: requestId,
            owner: msg.sender,
            shares: shares,
            estimatedAssets: estimatedAssets,
            settledAssets: 0,
            timestamp: block.timestamp,
            status: RequestStatus.PENDING
        });

        emit RedeemRequest(msg.sender, requestId, shares);
    }

    function pendingRedeemRequest(address account) external view returns (uint256) {
        return _pendingShares[account];
    }

    // =============================================================
    // ERC-4626 Synchronous Redemption (atomic when FreeCash sufficient, reverts otherwise)
    // =============================================================

    function redeem(uint256 shares, address receiver, address owner)
        public
        override(ERC4626Upgradeable, IERC4626)
        nonReentrant
        whenNotPaused
        checkSanctions(receiver)
        returns (uint256)
    {
        if (syncRedeemDisabled) revert Vault__SyncRedeemDisabled();
        if (shares == 0) revert Vault__ZeroAmount();
        return super.redeem(shares, receiver, owner);
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        override(ERC4626Upgradeable, IERC4626)
        nonReentrant
        whenNotPaused
        checkSanctions(receiver)
        returns (uint256)
    {
        if (syncRedeemDisabled) revert Vault__SyncRedeemDisabled();
        if (assets == 0) revert Vault__ZeroAmount();
        return super.withdraw(assets, receiver, owner);
    }

    function previewRedeem(uint256 shares) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        uint256 grossAssets = _convertToAssets(shares, Math.Rounding.Floor);
        uint256 fee = grossAssets.mulDiv(redemptionFeeBps, FEE_BASIS, Math.Rounding.Ceil);
        return grossAssets - fee;
    }

    function previewWithdraw(uint256 assets) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        if (redemptionFeeBps >= FEE_BASIS) return type(uint256).max;
        uint256 grossAssets = assets.mulDiv(FEE_BASIS, FEE_BASIS - redemptionFeeBps, Math.Rounding.Ceil);
        return _convertToShares(grossAssets, Math.Rounding.Ceil);
    }

    function maxDeposit(address) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return (paused() || sanctionsOracle.isSanctioned(msg.sender)) ? 0 : type(uint256).max;
    }

    function maxMint(address) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return (paused() || sanctionsOracle.isSanctioned(msg.sender) )? 0 : type(uint256).max;
    }

    function maxRedeem(address owner) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        if (paused() || syncRedeemDisabled || sanctionsOracle.isSanctioned(owner)) return 0;
        uint256 shares = balanceOf(owner);
        uint256 freeCash = getFreeCash();
        uint256 assetsForAll = previewRedeem(shares);
        if (assetsForAll <= freeCash) return shares;
        uint256 grossFromCash = redemptionFeeBps > 0
            ? freeCash.mulDiv(FEE_BASIS, FEE_BASIS - redemptionFeeBps, Math.Rounding.Floor)
            : freeCash;
        return _convertToShares(grossFromCash, Math.Rounding.Floor);
    }

    function maxWithdraw(address owner) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        if (paused() || syncRedeemDisabled || sanctionsOracle.isSanctioned(owner)) return 0;
        uint256 redeemable = previewRedeem(balanceOf(owner));
        uint256 freeCash = getFreeCash();
        return redeemable < freeCash ? redeemable : freeCash;
    }

    // =============================================================
    // FreeCash Query & Withdrawal Safety Check
    // =============================================================

    function getFreeCash() public view returns (uint256) {
        uint256 physicalBalance = IERC20(asset()).balanceOf(address(this));
        uint256 floatingLocked = previewRedeem(totalLockedShares);
        if (physicalBalance <= floatingLocked) return 0;
        return physicalBalance - floatingLocked;
    }

    function getTokenInfos() external view returns (tokenInfo[] memory) {
        uint256 len = adapters.length;
        tokenInfo[] memory infos = new tokenInfo[](len + 1);
        infos[0] = tokenInfo(asset(), IERC20(asset()).balanceOf(address(this)) + totalRedeemInFlight, IERC20(asset()).balanceOf(address(this)) + totalRedeemInFlight);
        for (uint256 i = 1; i < len; i++) {
            IStrategyAdapter adapter = IStrategyAdapter(adapters[i]);
            IERC20 token = IERC20(adapter.posToken());
            uint256 tokenAmount = adapterInvestInFlightTokens[adapters[i]] + token.balanceOf(address(this));
            uint256 usdcAmount = tokenAmount * adapter.getPrice() / 1e18;
            infos[i] = tokenInfo(adapter.posToken(), tokenAmount, usdcAmount);
        }
        return infos;
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        virtual
        override
    {
        uint256 freeCash = getFreeCash();
        if (assets > freeCash) revert Vault__InsufficientFreeCash(assets, freeCash);
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    // =============================================================
    // Controller Only: Asset Approval, Request Lifecycle & In-Flight Accounting
    // =============================================================

    function registerAdapter(address adapter) external onlyController {
        if (adapter == address(0)) revert Vault__ZeroAddress();
        if (isAdapter[adapter]) revert Vault__AdapterAlreadyRegistered(adapter);
        adapters.push(adapter);
        isAdapter[adapter] = true;
        emit AdapterRegistered(adapter);
    }

    function removeAdapter(address adapter) external onlyController {
        if (!isAdapter[adapter]) revert Vault__AdapterNotRegistered(adapter);
        if (adapterInvestInFlightTokens[adapter] > 0 || adapterRedeemInFlightUsdc[adapter] > 0) {
            revert Vault__AdapterHasInFlight(adapter);
        }
        IERC20(asset()).forceApprove(adapter, 0);
        isAdapter[adapter] = false;
        uint256 len = adapters.length;
        for (uint256 i = 0; i < len; i++) {
            if (adapters[i] == adapter) {
                adapters[i] = adapters[len - 1];
                adapters.pop();
                break;
            }
        }
        emit AdapterRemoved(adapter);
    }

    function getAdapters() external view returns (address[] memory) {
        return adapters;
    }

    function approveToAdapter(address adapter, address token, uint256 amount) external onlyController {
        if (!isAdapter[adapter]) revert Vault__AdapterNotRegistered(adapter);
        IERC20(token).forceApprove(adapter, amount);
        emit AdapterApproved(adapter, token, amount);
    }

    function updateRequestBatch(uint256[] calldata ids, RequestStatus newStatus) external onlyController {
        if (newStatus == RequestStatus.NONE || newStatus == RequestStatus.DONE) {
            revert Vault__StatusTransitionForbidden(newStatus);
        }

        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            RequestStatus current = requests[id].status;
            if (current == RequestStatus.NONE || current == RequestStatus.DONE || (current == RequestStatus.PROCESSING && newStatus == RequestStatus.PENDING)) {
                revert Vault__InvalidState(id, current);
            }
            requests[id].status = newStatus;
        }
        emit RequestBatchUpdated(ids, newStatus);
    }

    /**
     * @notice Mark redemption requests as READY with actual settlement amounts.
     * @dev settledAssets[i] is determined by the controller based on actual adapter returns
     *      or current exchange rate. totalLockedShares is released here.
     * @param ids Request IDs to mark done
     * @param settledAssets Actual USDC amount each request will receive
     */
    function markRequestsDone(uint256[] calldata ids, uint256[] calldata settledAssets) external onlyController {
        if (ids.length != settledAssets.length) revert Vault__LengthMismatch(ids.length, settledAssets.length);

        uint256 doneAssets = 0;
        uint256 releasedShares = 0;

        uint256 physicalCash = IERC20(asset()).balanceOf(address(this));

        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            RedemptionRequest storage req = requests[id];

            if (req.status != RequestStatus.PROCESSING) revert Vault__InvalidState(id, req.status);

            uint256 actual = settledAssets[i];
            if (actual == 0) revert Vault__ZeroAmount();

            if (actual != req.estimatedAssets) {
                emit RequestSettlementAdjusted(id, req.estimatedAssets, actual);
            }

            if (physicalCash < actual) {
                revert Vault__InsufficientPhysicalCash(ids, settledAssets, IERC20(asset()).balanceOf(address(this)));
            }

            req.status = RequestStatus.DONE;
            req.settledAssets = actual;
            releasedShares += req.shares;

            _pendingShares[req.owner] -= req.shares;
            if(sanctionsOracle.isSanctioned(req.owner)){
                IERC20(asset()).safeTransfer(sanctionSafe, actual);
                emit SactionSafeIn(req.owner, asset(), actual);
            } else {
                IERC20(asset()).safeTransfer(req.owner, actual);
                emit RedemptionDone(req.owner, req.owner, req.shares, actual);
            }
            physicalCash -= actual;
        }
        totalLockedShares -= releasedShares;

        emit RequestBatchUpdated(ids, RequestStatus.DONE);

    }

    /**
     * @notice Create an in-flight record for rebalancing operations
     * @param isInvest true = invest (USDC out, waiting for tokens); false = redeem (tokens out, waiting for USDC)
     * @param tokenAmount Invest: expected incoming token amount; Redeem: outgoing token amount
     * @param usdcAmount  Invest: outgoing USDC amount;           Redeem: expected incoming USDC amount
     */
    function createInFlight(address adapter, address token, uint256 tokenAmount, uint256 usdcAmount, bool isInvest)
        external
        onlyController
        returns (uint256 inFlightId)
    {
        if (!isAdapter[adapter]) revert Vault__AdapterNotRegistered(adapter);
        if (usdcAmount == 0 || tokenAmount == 0) revert Vault__ZeroAmount();

        inFlightId = nextInFlightId++;
        inFlightRecords[inFlightId] = InFlightRecord({
            id: inFlightId,
            adapter: adapter,
            token: token,
            tokenAmount: tokenAmount,
            usdcAmount: usdcAmount,
            settledAmount: 0,
            isInvest: isInvest,
            timestamp: block.timestamp,
            status: InFlightStatus.PENDING
        });

        if (isInvest) {
            totalInvestInFlight += usdcAmount;
            adapterInvestInFlightTokens[adapter] += tokenAmount;
        } else {
            totalRedeemInFlight += usdcAmount;
            adapterRedeemInFlightUsdc[adapter] += usdcAmount;
        }

        emit InFlightCreated(inFlightId, adapter, token, tokenAmount, usdcAmount, isInvest);
    }

    /**
     * @notice Confirm an in-flight record (assets have arrived)
     * @param actualAmount Actual settled amount (invest: actual tokens received; redeem: actual USDC received)
     */
    function confirmInFlight(uint256 inFlightId, uint256 actualAmount) external onlyController {
        if (actualAmount == 0) revert Vault__ZeroAmount();
        InFlightRecord storage r = inFlightRecords[inFlightId];
        if (r.status != InFlightStatus.PENDING) revert Vault__InvalidInFlightState(inFlightId, r.status);

        r.status = InFlightStatus.CONFIRMED;
        r.settledAmount = actualAmount;

        if (r.isInvest) {
            // Invest confirmed: tokens arrived, clear USDC in-flight
            if (totalInvestInFlight < r.usdcAmount) revert Vault__Underflow(totalInvestInFlight, r.usdcAmount);
            totalInvestInFlight -= r.usdcAmount;
            adapterInvestInFlightTokens[r.adapter] -= r.tokenAmount;
        } else {
            // Redeem confirmed: USDC arrived, clear USDC in-flight
            if (totalRedeemInFlight < r.usdcAmount) revert Vault__Underflow(totalRedeemInFlight, r.usdcAmount);
            totalRedeemInFlight -= r.usdcAmount;
            adapterRedeemInFlightUsdc[r.adapter] -= r.usdcAmount;
        }

        emit InFlightConfirmed(inFlightId, r.adapter, r.tokenAmount, r.usdcAmount, actualAmount);
    }
    

    // =============================================================
    // Admin Only: Redemption Fee Management
    // =============================================================

    function setRedemptionFee(uint256 newFeeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newFeeBps > maxRedemptionFeeBps) revert Vault__FeeTooHigh(newFeeBps, maxRedemptionFeeBps);
        uint256 oldFeeBps = redemptionFeeBps;
        redemptionFeeBps = newFeeBps;
        emit RedemptionFeeUpdated(oldFeeBps, newFeeBps);
        if (totalLockedShares > 0) {
            emit FeeChangedWithLockedShares(totalLockedShares, oldFeeBps, newFeeBps);
        }
    }

    function setMaxRedemptionFee(uint256 newMaxBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMaxBps > FEE_BASIS) revert Vault__FeeTooHigh(newMaxBps, FEE_BASIS);
        uint256 old = maxRedemptionFeeBps;
        maxRedemptionFeeBps = newMaxBps;
        if (redemptionFeeBps > newMaxBps) {
            uint256 oldFee = redemptionFeeBps;
            redemptionFeeBps = newMaxBps;
            emit RedemptionFeeUpdated(oldFee, newMaxBps);
            if (totalLockedShares > 0) {
                emit FeeChangedWithLockedShares(totalLockedShares, oldFee, newMaxBps);
            }
        }
        emit MaxRedemptionFeeUpdated(old, newMaxBps);
    }

    function setMaxRateChangeBps(uint256 newMaxBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMaxBps > FEE_BASIS) revert Vault__FeeTooHigh(newMaxBps, FEE_BASIS);
        uint256 old = maxRateChangeBps;
        maxRateChangeBps = newMaxBps;
        emit MaxRateChangeBpsUpdated(old, newMaxBps);
    }

    function setSyncRedeemDisabled(bool disabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        syncRedeemDisabled = disabled;
        emit SyncRedeemDisabledUpdated(disabled);
    }

    function setMinRedeemAmount(uint256 newAmount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldAmount = minRedeemAmount;
        minRedeemAmount = newAmount;
        emit MinRedeemAmountUpdated(oldAmount, newAmount);
    }

    function setMinDepositAmount(uint256 newAmount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldAmount = minDepositAmount;
        minDepositAmount = newAmount;
        emit MinDepositAmountUpdated(oldAmount, newAmount);
    }

    function setSanctionsOracle(address newOracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newOracle == address(0)) revert Vault__ZeroAddress();
        address old = address(sanctionsOracle);
        sanctionsOracle = ISanctionsOracle(newOracle);
        emit SanctionsOracleUpdated(old, newOracle);
    }

    function setController(address newController) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newController == address(0)) revert Vault__ZeroAddress();
        address old = controller;
        controller = newController;
        emit ControllerUpdated(old, newController);
    }

    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury == address(0)) revert Vault__ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    function setSanctionSafe(address newSanctionSafe) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newSanctionSafe == address(0)) revert Vault__ZeroAddress();
        address old = sanctionSafe;
        sanctionSafe = newSanctionSafe;
        emit SanctionSafeUpdated(old, newSanctionSafe);
    }

    function setAccountant(address newAccountant) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newAccountant == address(0)) revert Vault__ZeroAddress();
        address old = accountant;
        accountant = newAccountant;
        emit AccountantUpdated(old, newAccountant);
    }

    // =============================================================
    // Accountant Only: Financial Reconciliation
    // =============================================================

    function updateExchangeRate(uint256 newRate) external onlyAccountant {
        if (newRate == 0) revert Vault__ZeroExchangeRate();

        uint256 oldRate = exchangeRate;
        uint256 delta = newRate > oldRate ? newRate - oldRate : oldRate - newRate;
        uint256 maxDelta = oldRate * maxRateChangeBps / FEE_BASIS;
        if (delta > maxDelta) {
            if (!paused()) _pause();
            exchangeRate = newRate;
            emit ExchangeRateChangeExceedsLimit(oldRate, newRate, maxRateChangeBps);
            return;
        }

        exchangeRate = newRate;
        emit ExchangeRateUpdated(oldRate, newRate);
    }

    function mintFeeShares(uint256 shares) external onlyAccountant whenNotPaused {
        uint256 maxMintable = totalSupply() * maxRateChangeBps / FEE_BASIS;
        if (shares > maxMintable) revert Vault__FeeTooHigh(shares, maxMintable);
        _mint(treasury, shares);
        emit FeeSharesMinted(treasury, shares);
    }

    // =============================================================
    // ERC-4626 Deposits (with pause guard)
    // =============================================================

    function deposit(uint256 assets, address receiver)
        public
        override(ERC4626Upgradeable, IERC4626)
        nonReentrant
        whenNotPaused
        checkSanctions(msg.sender)
        checkSanctions(receiver)
        returns (uint256)
    {
        if (assets < minDepositAmount) revert Vault__BelowMinDeposit(assets, minDepositAmount);
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver)
        public
        override(ERC4626Upgradeable, IERC4626)
        nonReentrant
        whenNotPaused
        checkSanctions(msg.sender)
        checkSanctions(receiver)
        returns (uint256)
    {
        uint256 assets = previewMint(shares);
        if (assets < minDepositAmount) revert Vault__BelowMinDeposit(assets, minDepositAmount);
        return super.mint(shares, receiver);
    }

    // =============================================================
    // ERC-4626 Pricing Overrides
    // =============================================================

    function totalAssets() public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        uint256 total = IERC20(asset()).balanceOf(address(this)) + totalInvestInFlight + totalRedeemInFlight;
        uint256 len = adapters.length;
        for (uint256 i = 0; i < len; i++) {
            total += IStrategyAdapter(adapters[i]).totalValue();
        }
        uint256 floatingLocked = previewRedeem(totalLockedShares);
        if (total <= floatingLocked) return 0;
        return total - floatingLocked;
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        return shares.mulDiv(exchangeRate, 1e18, rounding);
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        return assets.mulDiv(1e18, exchangeRate, rounding);
    }

    // =============================================================
    // ERC-165 & ERC-7575
    // =============================================================

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IERC7540Redeem).interfaceId || interfaceId == type(IMantleYieldVault).interfaceId
            || super.supportsInterface(interfaceId);
    }

    function share() external view returns (address) {
        return address(this);
    }

    // =============================================================
    // Emergency Management & Token Rescue
    // =============================================================

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function rescueTokens(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == asset()) revert Vault__RescueAssetCannotBeUnderlying();
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }
}
