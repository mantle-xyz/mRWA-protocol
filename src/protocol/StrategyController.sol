// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategyAdapter} from "../interfaces/adapters/IStrategyAdapter.sol";
import {IStrategyControllerExecutor} from "../interfaces/strategy/IStrategyControllerExecutor.sol";
import {IMantleYieldVault} from "../interfaces/vault/IMantleYieldVault.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract StrategyController is Initializable, AccessControlUpgradeable, ReentrancyGuard {
    bytes32 public constant OPERATOR_EXECUTOR_ROLE = keccak256("OPERATOR_EXECUTOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant SWEEP_SETTLEMENT_TOLERANCE_PER_ITEM = 1;
    uint8 public constant REBALANCE_ACTION_NONE = 0;
    uint8 public constant REBALANCE_ACTION_INVEST = 1;
    uint8 public constant REBALANCE_ACTION_DIVEST = 2;

    IERC20 public asset;
    IMantleYieldVault public vault;

    uint16 public bufferTargetBps;
    uint16 public rebalanceThresholdBps;
    uint64 public rebalanceCooldown;
    uint64 public lastRebalance;

    struct StrategyInfo {
        uint16 targetWeightBps;
        uint16 priority;
        bool isAsync;
        bool isActive;
        bool exists;
    }

    mapping(address => StrategyInfo) public strategyInfo;
    address[] public strategyOrder;

    modifier onlyAdmin() {
        _checkRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _;
    }

    modifier onlyPauser() {
        _checkRole(PAUSER_ROLE, msg.sender);
        _;
    }

    modifier onlyOperatorExecutor() {
        _checkRole(OPERATOR_EXECUTOR_ROLE, msg.sender);
        _;
    }

    /// @notice Block rate-dependent operator flows whenever the vault or accountant is paused.
    /// @dev Pause on the accountant indicates the published rate is stale or under circuit-breaker;
    ///      pause on the vault is the protocol-wide emergency stop. Both must allow operation.
    modifier whenAccountantAndVaultNotPaused() {
        if (Pausable(address(vault)).paused()) revert Controller__VaultPaused();
        address accountantAddr = vault.accountant();
        if (accountantAddr != address(0) && Pausable(accountantAddr).paused()) {
            revert Controller__AccountantPaused();
        }
        _;
    }

    event StrategyRegistered(
        address indexed adapter, uint16 targetWeightBps, uint16 priority, bool isAsync, bool isActive
    );
    event StrategyUpdated(
        address indexed adapter, uint16 targetWeightBps, uint16 priority, bool isAsync, bool isActive
    );
    event StrategyActivated(address indexed adapter);
    event StrategyDeactivated(address indexed adapter);
    event RiskParamsUpdated(uint16 bufferTargetBps, uint16 rebalanceThresholdBps, uint64 rebalanceCooldown);
    event StrategyOrderUpdated(address[] orderedStrategies);
    event AdapterPauseUpdated(address indexed adapter, bool paused);
    event RebalanceEvaluated(
        uint256 totalCash, uint256 freeCash, uint256 idealCash, uint256 netAssets, uint256 targetCash, uint256 threshold
    );
    event InvestExecuted(address indexed adapter, uint256 amountAsset, uint256 sharesOrPos);
    event InvestSkipped(address indexed adapter, uint256 amountAsset, bytes revertData);
    event RebalanceInvest(uint256 requestedAsset, uint256 investedAsset, uint256 remainingAsset);
    event DivestSkipped(address indexed adapter, uint256 requestedAsset, bytes revertData);
    /// @notice Unified redeem in-flight record event for both async and sync paths.
    /// @dev inFlightStableAmount semantic differs by path:
    ///      - async: equals requestedAsset
    ///      - sync: equals actually received asset amount from withdrawSync
    event RedeemInFlightRecorded(
        address indexed adapter,
        uint256 indexed inFlightId,
        uint256 requestedAsset,
        uint256 inFlightStableAmount,
        bool isAsync
    );
    event DivestIncomplete(uint256 remainingAsset);
    event DivestCoverageRead(address indexed adapter, uint256 remaining, uint256 settledValue, uint256 requestAsset);
    event RedeemBatchProcessing(uint256 indexed batchSize, uint256 batchTotalAsset, uint256 shortfallAsset);
    event RedeemBatchReady(uint256 indexed batchSize, uint256 requiredAsset);
    event AdapterAssetsSwept(
        address indexed adapter, address indexed posToken, uint256 posClaimed, uint256 assetClaimed
    );
    event InvestSettlementRecorded(
        uint256 indexed inFlightId, address indexed adapter, uint256 settledPosAmount, uint256 refundAssetAmount
    );
    event RedeemInFlightRetryRequested(address indexed adapter, uint256 indexed inFlightId, uint256 retryPosAmount);

    error Controller__InvalidAddress();
    error Controller__InvalidBps();
    error Controller__InvalidExecutorContract(address executor);
    error Controller__CooldownNotElapsed();
    error Controller__VaultPaused();
    error Controller__AccountantPaused();
    error Controller__InvalidStrategy(address adapter);
    error Controller__InvalidPriorityOrder(address adapter);
    error Controller__StrategyInactive(address adapter);
    error Controller__WeightsMustBe10000(uint256 actualTotalWeight);
    error Controller__DuplicateController__StrategyInOrder(address adapter);
    error Controller__IdsNotSorted();
    error Controller__InvalidRedeemInFlight(uint256 inFlightId);
    error Controller__InvalidInvestInFlight(uint256 inFlightId);
    error Controller__InvestInFlightIdsRequired(address adapter);
    error Controller__RedeemInFlightIdsRequired(address adapter);
    error Controller__SettleAmountsLengthMismatch();
    error Controller__InvestSweepAmountMismatch(address adapter, uint256 expected, uint256 claimed);
    error Controller__InvestRefundSweepAmountMismatch(address adapter, uint256 expected, uint256 claimed);
    error Controller__RedeemSweepAmountMismatch(address adapter, uint256 expected, uint256 claimed);
    error Controller__InvalidInvestRefundAmount(
        uint256 inFlightId, uint256 refundAssetAmount, uint256 originalAssetAmount
    );
    error Controller__ClaimInputsLengthMismatch();
    error Controller__UpdateStrategiesLengthMismatch();
    error Controller__DuplicateStrategyUpdate(address adapter);
    error Controller__DuplicateStrategyPosToken(address posToken, address existingAdapter, address newAdapter);
    error Controller__InvestPosAmountUnavailable(address adapter, uint256 assetAmount);
    /// @notice Adapter pool (step-aligned total value) is strictly less than the required shortfall.
    ///         Request stays PENDING and can be retried once adapter value grows.
    error Controller__DivestInsufficient(uint256 required, uint256 remaining);
    error Controller__StrategyAlreadyActive(address adapter);
    error Controller__StrategyAlreadyInactive(address adapter);
    error Controller__StrategyInOrder(address adapter);
    error Controller__StrategyHasInFlight(address adapter, uint256 pendingInvestTokens, uint256 pendingRedeemStable);
    error Controller__RetryOnlyAsyncStrategy(address adapter);
    error Controller__InvalidRetryAmount();

    constructor() {
        _disableInitializers();
    }

    // =============================================================
    // Initialization
    // =============================================================

    /**
     * @notice Initialize controller with vault, roles, and risk parameters.
     * @param vault_ Vault address. Must be non-zero.
     * @param admin_ Address granted DEFAULT_ADMIN_ROLE.
     * @param operatorExecutor_ Contract address granted OPERATOR_EXECUTOR_ROLE. Must be a contract.
     * @param pauser_ Address granted PAUSER_ROLE.
     * @param bufferTargetBps_ Target free-cash buffer as bps of net assets. <= 10000.
     * @param rebalanceThresholdBps_ No-op band around buffer target in bps. <= 10000.
     * @param rebalanceCooldown_ Minimum seconds between rebalance executions.
     */
    function initialize(
        address vault_,
        address admin_,
        address operatorExecutor_,
        address pauser_,
        uint16 bufferTargetBps_,
        uint16 rebalanceThresholdBps_,
        uint64 rebalanceCooldown_
    ) external initializer {
        if (vault_ == address(0) || admin_ == address(0) || operatorExecutor_ == address(0) || pauser_ == address(0)) {
            revert Controller__InvalidAddress();
        }
        if (operatorExecutor_.code.length == 0) {
            revert Controller__InvalidExecutorContract(operatorExecutor_);
        }
        if (bufferTargetBps_ > BPS_DENOMINATOR || rebalanceThresholdBps_ > BPS_DENOMINATOR) {
            revert Controller__InvalidBps();
        }

        __AccessControl_init();

        vault = IMantleYieldVault(vault_);
        asset = IERC20(vault.asset());
        if (address(asset) == address(0)) {
            revert Controller__InvalidAddress();
        }
        bufferTargetBps = bufferTargetBps_;
        rebalanceThresholdBps = rebalanceThresholdBps_;
        rebalanceCooldown = rebalanceCooldown_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(OPERATOR_EXECUTOR_ROLE, operatorExecutor_);
        _grantRole(PAUSER_ROLE, pauser_);
    }

    // =============================================================
    // Parameter Management
    // =============================================================

    function strategyOrderLength() external view returns (uint256) {
        return strategyOrder.length;
    }

    /**
     * @notice Read current rebalance accounting state with the same formula used by rebalance().
     * @return totalCash Vault asset balance.
     * @return freeCash Cash available after deducting locked liabilities.
     * @return idealCash freeCash plus redeem in-flight (treated as future cash for invest sizing).
     * @return netAssets vault.totalAssets() — net of floating-locked liabilities.
     * @return targetCash Desired buffer cash (netAssets * bufferTargetBps / 1e4) plus current cash deficit.
     * @return threshold No-op band around targetCash (netAssets * rebalanceThresholdBps / 1e4).
     * @return hasPendingRequest True if there are unprocessed redeem requests blocking divest.
     */
    function getRebalanceState()
        external
        view
        returns (
            uint256 totalCash,
            uint256 freeCash,
            uint256 idealCash,
            uint256 netAssets,
            uint256 targetCash,
            uint256 threshold,
            bool hasPendingRequest
        )
    {
        return _readRebalanceState();
    }

    /**
     * @notice Preview whether rebalance should run at current block and what action is expected.
     * @return shouldRebalance True if rebalance() would perform an action at current block.
     * @return action 0 = NONE, 1 = INVEST, 2 = DIVEST.
     * @return amount Expected asset amount to invest or divest. Zero when action is NONE.
     * @dev Returns NONE during cooldown without further computation.
     */
    function previewRebalance() external view returns (bool shouldRebalance, uint8 action, uint256 amount) {
        if (block.timestamp < uint256(lastRebalance) + uint256(rebalanceCooldown)) {
            return (false, REBALANCE_ACTION_NONE, 0);
        }

        (, uint256 freeCash, uint256 idealCash,, uint256 targetCash, uint256 threshold, bool hasPendingRequest) =
            _readRebalanceState();
        (action, amount) = _computeRebalanceDecision(freeCash, idealCash, targetCash, threshold, hasPendingRequest);
        shouldRebalance = action != REBALANCE_ACTION_NONE;
    }

    /**
     * @notice Update buffer target, threshold, and cooldown.
     * @param bufferTargetBps_ Target free-cash buffer in bps. <= 10000.
     * @param rebalanceThresholdBps_ No-op band in bps. <= 10000.
     * @param rebalanceCooldown_ Minimum seconds between rebalance executions.
     */
    function setRiskParams(uint16 bufferTargetBps_, uint16 rebalanceThresholdBps_, uint64 rebalanceCooldown_)
        external
        onlyAdmin
    {
        if (bufferTargetBps_ > BPS_DENOMINATOR || rebalanceThresholdBps_ > BPS_DENOMINATOR) {
            revert Controller__InvalidBps();
        }
        bufferTargetBps = bufferTargetBps_;
        rebalanceThresholdBps = rebalanceThresholdBps_;
        rebalanceCooldown = rebalanceCooldown_;
        emit RiskParamsUpdated(bufferTargetBps_, rebalanceThresholdBps_, rebalanceCooldown_);
    }

    /**
     * @notice Register a new strategy adapter (initially inactive).
     * @param adapter Adapter contract address. Must be a contract.
     * @param targetWeightBps Target capital weight in bps. <= 10000.
     * @param priority Execution priority for ordering. Order is monotonic non-decreasing.
     * @param isAsync True if adapter uses async redeem flow.
     */
    function registerStrategy(address adapter, uint16 targetWeightBps, uint16 priority, bool isAsync)
        external
        onlyAdmin
    {
        if (adapter == address(0)) {
            revert Controller__InvalidAddress();
        }
        if (adapter.code.length == 0) {
            revert Controller__InvalidStrategy(adapter);
        }
        if (targetWeightBps > BPS_DENOMINATOR) {
            revert Controller__InvalidBps();
        }
        if (strategyInfo[adapter].exists) {
            revert Controller__InvalidStrategy(adapter);
        }

        _ensureVaultAdapterRegistered(adapter);

        strategyInfo[adapter] = StrategyInfo({
            targetWeightBps: targetWeightBps, priority: priority, isAsync: isAsync, isActive: false, exists: true
        });

        _validateCurrentOrderInvariant();
        emit StrategyRegistered(adapter, targetWeightBps, priority, isAsync, false);
    }

    function activateStrategy(address adapter) external onlyAdmin {
        StrategyInfo storage info = strategyInfo[adapter];
        if (!info.exists) {
            revert Controller__InvalidStrategy(adapter);
        }
        if (info.isActive) {
            revert Controller__StrategyAlreadyActive(adapter);
        }

        _ensureVaultAdapterRegistered(adapter);
        info.isActive = true;

        emit StrategyActivated(adapter);
        emit StrategyUpdated(adapter, info.targetWeightBps, info.priority, info.isAsync, true);
    }

    /**
     * @notice Deactivate a strategy and remove it from the vault adapter registry.
     * @param adapter Adapter address.
     * @dev Reverts if adapter is in current strategyOrder, or has any pending invest/redeem in-flight.
     */
    function deactivateStrategy(address adapter) external onlyAdmin {
        StrategyInfo storage info = strategyInfo[adapter];
        if (!info.exists) {
            revert Controller__InvalidStrategy(adapter);
        }
        if (!info.isActive) {
            revert Controller__StrategyAlreadyInactive(adapter);
        }
        if (_isAdapterInOrder(adapter)) {
            revert Controller__StrategyInOrder(adapter);
        }

        uint256 pendingInvest = vault.adapterInvestInFlightTokens(adapter);
        uint256 pendingRedeem = vault.adapterRedeemInFlightStable(adapter);
        if (pendingInvest > 0 || pendingRedeem > 0) {
            revert Controller__StrategyHasInFlight(adapter, pendingInvest, pendingRedeem);
        }

        if (vault.isAdapter(adapter)) {
            vault.removeAdapter(adapter);
        }

        info.isActive = false;
        emit StrategyDeactivated(adapter);
        emit StrategyUpdated(adapter, info.targetWeightBps, info.priority, info.isAsync, false);
    }

    /**
     * @notice Update target weight, priority, and isAsync for multiple strategies atomically.
     * @param adapters Strategies to update.
     * @param targetWeightBpsList New target weights in bps, aligned with adapters.
     * @param priorities New priorities aligned with adapters.
     * @param isAsyncList New isAsync flags aligned with adapters.
     * @dev Validates current order invariant after the update.
     */
    function updateStrategies(
        address[] calldata adapters,
        uint16[] calldata targetWeightBpsList,
        uint16[] calldata priorities,
        bool[] calldata isAsyncList
    ) external onlyAdmin {
        _validateUpdateStrategiesInputs(adapters, targetWeightBpsList, priorities, isAsyncList);

        _validateNoDuplicateAdapters(adapters);

        uint256 len = adapters.length;
        for (uint256 i = 0; i < len; i++) {
            _applyStrategyUpdate(adapters[i], targetWeightBpsList[i], priorities[i], isAsyncList[i]);
        }

        _validateCurrentOrderInvariant();
    }

    /**
     * @notice Update strategies and reset execution order in a single transaction.
     * @param adapters Strategies to update.
     * @param targetWeightBpsList New target weights in bps, aligned with adapters.
     * @param priorities New priorities aligned with adapters.
     * @param isAsyncList New isAsync flags aligned with adapters.
     * @param orderedStrategies New execution order; weights of listed strategies must sum to 10000.
     */
    function updateStrategiesAndOrder(
        address[] calldata adapters,
        uint16[] calldata targetWeightBpsList,
        uint16[] calldata priorities,
        bool[] calldata isAsyncList,
        address[] calldata orderedStrategies
    ) external onlyAdmin {
        _validateUpdateStrategiesInputs(adapters, targetWeightBpsList, priorities, isAsyncList);
        _validateNoDuplicateAdapters(adapters);

        uint256 len = adapters.length;
        for (uint256 i = 0; i < len; i++) {
            _applyStrategyUpdate(adapters[i], targetWeightBpsList[i], priorities[i], isAsyncList[i]);
        }

        _setStrategyOrder(orderedStrategies);
    }

    /**
     * @notice Set the execution order for active strategies.
     * @param orderedStrategies Adapters in priority-monotonic order; weights must sum to 10000.
     */
    function setStrategyOrder(address[] calldata orderedStrategies) external onlyAdmin {
        _setStrategyOrder(orderedStrategies);
    }

    function _setStrategyOrder(address[] calldata orderedStrategies) internal {
        uint256 len = orderedStrategies.length;
        delete strategyOrder;

        uint256 totalActiveWeight;
        uint16 lastPriority;
        for (uint256 i = 0; i < len; i++) {
            address adapter = orderedStrategies[i];
            StrategyInfo memory info = strategyInfo[adapter];
            if (!info.exists) {
                revert Controller__InvalidStrategy(adapter);
            }
            if (!info.isActive) {
                revert Controller__StrategyInactive(adapter);
            }
            for (uint256 j = 0; j < i; j++) {
                if (orderedStrategies[j] == adapter) {
                    revert Controller__DuplicateController__StrategyInOrder(adapter);
                }
            }

            if (i > 0 && info.priority < lastPriority) {
                revert Controller__InvalidPriorityOrder(adapter);
            }
            lastPriority = info.priority;

            strategyOrder.push(adapter);
            totalActiveWeight += info.targetWeightBps;
        }

        if (totalActiveWeight != BPS_DENOMINATOR) {
            revert Controller__WeightsMustBe10000(totalActiveWeight);
        }
        emit StrategyOrderUpdated(orderedStrategies);
    }

    function _validateUpdateStrategiesInputs(
        address[] calldata adapters,
        uint16[] calldata targetWeightBpsList,
        uint16[] calldata priorities,
        bool[] calldata isAsyncList
    ) internal pure {
        uint256 len = adapters.length;
        if (len != targetWeightBpsList.length || len != priorities.length || len != isAsyncList.length) {
            revert Controller__UpdateStrategiesLengthMismatch();
        }
    }

    /// @dev Ensure existing execution order remains coherent after strategy config changes.
    function _validateCurrentOrderInvariant() internal view {
        uint256 len = strategyOrder.length;
        if (len == 0) {
            return;
        }

        uint256 totalActiveWeight;
        uint16 lastPriority;
        for (uint256 i = 0; i < len; i++) {
            address adapter = strategyOrder[i];
            StrategyInfo memory info = strategyInfo[adapter];
            if (!info.exists) {
                revert Controller__InvalidStrategy(adapter);
            }
            if (!info.isActive) {
                revert Controller__StrategyInactive(adapter);
            }
            if (i > 0 && info.priority < lastPriority) {
                revert Controller__InvalidPriorityOrder(adapter);
            }
            lastPriority = info.priority;
            totalActiveWeight += info.targetWeightBps;
        }

        if (totalActiveWeight != BPS_DENOMINATOR) {
            revert Controller__WeightsMustBe10000(totalActiveWeight);
        }
    }

    function _applyStrategyUpdate(address adapter, uint16 targetWeightBps, uint16 priority, bool isAsync) internal {
        if (targetWeightBps > BPS_DENOMINATOR) {
            revert Controller__InvalidBps();
        }
        if (!strategyInfo[adapter].exists) {
            revert Controller__InvalidStrategy(adapter);
        }

        StrategyInfo storage info = strategyInfo[adapter];
        info.targetWeightBps = targetWeightBps;
        info.priority = priority;
        info.isAsync = isAsync;

        emit StrategyUpdated(adapter, targetWeightBps, priority, isAsync, info.isActive);
    }

    function _validateNoDuplicateAdapters(address[] calldata adapters) internal pure {
        uint256 len = adapters.length;
        for (uint256 i = 0; i < len; i++) {
            address adapter = adapters[i];
            for (uint256 j = 0; j < i; j++) {
                if (adapters[j] == adapter) {
                    revert Controller__DuplicateStrategyUpdate(adapter);
                }
            }
        }
    }

    function _ensureVaultAdapterRegistered(address adapter) internal {
        if (!vault.isAdapter(adapter)) {
            _validateUniqueAdapterPosToken(adapter);
            vault.registerAdapter(adapter);
        }
    }

    function _validateUniqueAdapterPosToken(address adapter) internal view {
        address posToken = IStrategyAdapter(adapter).posToken();
        if (posToken == address(0)) {
            revert Controller__InvalidStrategy(adapter);
        }

        address[] memory registeredAdapters = vault.getAdapters();
        uint256 len = registeredAdapters.length;
        for (uint256 i = 0; i < len; i++) {
            address existingAdapter = registeredAdapters[i];
            if (IStrategyAdapter(existingAdapter).posToken() == posToken) {
                revert Controller__DuplicateStrategyPosToken(posToken, existingAdapter, adapter);
            }
        }
    }

    function _isAdapterInOrder(address adapter) internal view returns (bool) {
        uint256 len = strategyOrder.length;
        for (uint256 i = 0; i < len; i++) {
            if (strategyOrder[i] == adapter) {
                return true;
            }
        }
        return false;
    }

    // =============================================================
    // Emergency Controls
    // =============================================================

    /// @notice Set adapter pause state via controller.
    /// @dev Controller must hold PAUSER_ROLE on the target adapter.
    function setAdapterPaused(address adapter, bool paused_) external onlyPauser nonReentrant {
        if (!strategyInfo[adapter].exists) {
            revert Controller__InvalidStrategy(adapter);
        }
        IStrategyAdapter(adapter).setPaused(paused_);
        emit AdapterPauseUpdated(adapter, paused_);
    }

    /// @notice Batch set adapter pause state via controller.
    /// @dev Controller must hold PAUSER_ROLE on each target adapter.
    function setAdaptersPaused(address[] calldata adapters, bool paused_) external onlyPauser nonReentrant {
        uint256 len = adapters.length;
        for (uint256 i = 0; i < len; i++) {
            address adapter = adapters[i];
            if (!strategyInfo[adapter].exists) {
                revert Controller__InvalidStrategy(adapter);
            }
            IStrategyAdapter(adapter).setPaused(paused_);
            emit AdapterPauseUpdated(adapter, paused_);
        }
    }

    // =============================================================
    // Business Entry Points
    // =============================================================

    /**
     * @notice Execute buffer-based rebalance.
     * @dev Invests when idealCash > targetCash + threshold; divests when idealCash + threshold < targetCash.
     *      Reverts if cooldown has not elapsed. Divest is blocked while pending redeem requests exist.
     */
    function rebalance() external onlyOperatorExecutor nonReentrant whenAccountantAndVaultNotPaused {
        if (block.timestamp < uint256(lastRebalance) + uint256(rebalanceCooldown)) {
            revert Controller__CooldownNotElapsed();
        }

        (
            uint256 totalCash,
            uint256 freeCash,
            uint256 idealCash,
            uint256 netAssets,
            uint256 targetCash,
            uint256 threshold,
            bool hasPendingRequest
        ) = _readRebalanceState();
        emit RebalanceEvaluated(totalCash, freeCash, idealCash, netAssets, targetCash, threshold);

        (uint8 action, uint256 amount) =
            _computeRebalanceDecision(freeCash, idealCash, targetCash, threshold, hasPendingRequest);
        if (action == REBALANCE_ACTION_INVEST) {
            _invest(amount, netAssets);
        } else if (action == REBALANCE_ACTION_DIVEST) {
            _divest(amount);
        }

        lastRebalance = uint64(block.timestamp);
    }

    /**
     * @notice Move redemption requests into PROCESSING and divest when free cash is below batch demand.
     * @param ids Request ids to process; must be sorted ascending and unique.
     * @dev Batch demand is derived on-chain from `ids` using current `exchangeRate`:
     *      sum(request.shares * exchangeRate / 1e18). Divest amount is capped by global cash deficit.
     *      Reverts with DivestInsufficient only when adapter pool (step-aligned) is strictly below
     *      shortfall; partial fills due to step residual or below-min are tolerated.
     */
    function processRedeemBatch(uint256[] calldata ids)
        external
        onlyOperatorExecutor
        nonReentrant
        whenAccountantAndVaultNotPaused
    {
        _validateSortedIds(ids);

        uint256 batchTotalAsset = _batchTotalBySharesAndRate(ids);
        uint256 cashDeficit = vault.getCashDeficit();
        // Per-batch semantic: only divest what's needed for this batch, capped by global deficit.
        uint256 shortfall = cashDeficit < batchTotalAsset ? cashDeficit : batchTotalAsset;
        if (shortfall > 0) {
            // Snapshot adapter pool value (step-aligned) BEFORE divest
            // to tell real pool shortage apart from soft conditions (below-min / step residual).
            uint256 adapterPoolBefore = _adapterPoolValue();
            uint256 divestRemaining = _divest(shortfall);
            if (divestRemaining > 0 && adapterPoolBefore < shortfall) {
                // Only revert on true insufficiency (pool strictly below demand). Requests stay
                // PENDING so they can retry when adapter value grows.
                revert Controller__DivestInsufficient(shortfall, divestRemaining);
            }
            // Otherwise (partial fill / every adapter below min / step residual): allow through.
            // Request enters PROCESSING; finalize waits until physical cash arrives via
            //   - later pRB calls that aggregate enough shortfall to clear adapter min, or
            //   - rebalance divest triggered by growing cashDeficit across PROCESSING requests, or
            //   - new user deposits injecting STABLE directly.
        }

        vault.updateRequestBatch(ids, IMantleYieldVault.RequestStatus.PROCESSING);

        emit RedeemBatchProcessing(ids.length, batchTotalAsset, shortfall);
    }

    // =============================================================
    // Business - Settlement & Redemption
    // =============================================================

    /**
     * @notice Finalize a processed redeem batch with operator-provided per-request settled assets.
     * @param ids Sorted ascending request ids previously processed.
     * @param settledAssets Per-request actual asset amount aligned with ids.
     * @dev Preconditions:
     *      - processRedeemBatch(ids) has already executed for the same sorted ids.
     *      - Vault has enough underlying balance to cover sum(settledAssets).
     *      - Requests are still in PROCESSING state and not finalized yet.
     *      Settlement actions (adapter sweep / in-flight confirmation) are not performed here;
     *      run settleAdapter/settleAdapters before this function when needed.
     *      On success, the vault marks requests DONE and transfers settled assets to receivers.
     */
    function finalizeRedeemBatch(uint256[] calldata ids, uint256[] calldata settledAssets)
        external
        onlyOperatorExecutor
        nonReentrant
        whenAccountantAndVaultNotPaused
    {
        _validateSortedIds(ids);
        _markBatchReady(ids, settledAssets);
    }

    /**
     * @notice Manual retry path for async redeem in-flight requests after off-chain alerting.
     * @param adapter Async adapter holding the in-flight record.
     * @param inFlightId Existing PENDING redeem in-flight id on the adapter.
     * @param retryPosAmount Position-token amount to retry. Must be in (0, recorded tokenAmount].
     * @dev Does not mutate vault in-flight/request status; only submits a new adapter-level redeem request.
     */
    function retryRedeemInFlight(address adapter, uint256 inFlightId, uint256 retryPosAmount)
        external
        onlyAdmin
        nonReentrant
    {
        StrategyInfo memory info = strategyInfo[adapter];
        if (!info.exists) {
            revert Controller__InvalidStrategy(adapter);
        }
        if (!info.isAsync) {
            revert Controller__RetryOnlyAsyncStrategy(adapter);
        }
        if (retryPosAmount == 0) {
            revert Controller__InvalidRetryAmount();
        }

        (, address recordAdapter,, uint256 tokenAmount,,, bool isInvest,, IMantleYieldVault.InFlightStatus status) =
            vault.inFlightRecords(inFlightId);
        if (recordAdapter != adapter || isInvest || status != IMantleYieldVault.InFlightStatus.PENDING) {
            revert Controller__InvalidRedeemInFlight(inFlightId);
        }
        if (retryPosAmount > tokenAmount) {
            revert Controller__InvalidRetryAmount();
        }

        IStrategyAdapter(adapter).retryRedeemAsync(retryPosAmount, adapter);
        emit RedeemInFlightRetryRequested(adapter, inFlightId, retryPosAmount);
    }

    /**
     * @notice Settle one adapter by sweeping assets back to vault and confirming in-flight records.
     * @param adapter Target adapter.
     * @param invest Invest in-flight ids and per-id settled position / refund amounts.
     * @param redeem Redeem in-flight ids and per-id settled asset amounts.
     * @dev Invest settlement supports both delivered position tokens and refunded underlying assets.
     */
    function settleAdapter(
        address adapter,
        IStrategyControllerExecutor.InvestSettlementInput calldata invest,
        IStrategyControllerExecutor.RedeemSettlementInput calldata redeem
    ) external onlyOperatorExecutor nonReentrant {
        _settleAdapterInternal(adapter, invest, redeem);
    }

    /**
     * @notice Settle multiple adapters in a single transaction.
     * @param adapters Target adapters.
     * @param investBatch Invest settlement input per adapter index.
     * @param redeemBatch Redeem settlement input per adapter index.
     * @dev All three arrays must have the same length.
     */
    function settleAdapters(
        address[] calldata adapters,
        IStrategyControllerExecutor.InvestSettlementInput[] calldata investBatch,
        IStrategyControllerExecutor.RedeemSettlementInput[] calldata redeemBatch
    ) external onlyOperatorExecutor nonReentrant {
        if (adapters.length != investBatch.length || adapters.length != redeemBatch.length) {
            revert Controller__SettleAmountsLengthMismatch();
        }

        uint256 len = adapters.length;
        for (uint256 i = 0; i < len; i++) {
            _settleAdapterBatchAtIndex(adapters, investBatch, redeemBatch, i);
        }
    }

    // =============================================================
    // Business Helpers
    // =============================================================

    function _readRebalanceState()
        internal
        view
        returns (
            uint256 totalCash,
            uint256 freeCash,
            uint256 idealCash,
            uint256 netAssets,
            uint256 targetCash,
            uint256 threshold,
            bool hasPendingRequest
        )
    {
        // STABLE balance of the vault
        totalCash = asset.balanceOf(address(vault));
        // freeCash = max(totalCash - floatingLockedAssets, 0)
        freeCash = _freeCash();
        // idealCash = current free cash plus redeem proceeds already on the way back.
        // This is only used to reduce extra divest demand, not to increase invest amount.
        idealCash = freeCash + vault.totalRedeemInFlight();
        // Net assets = vault.totalAssets(): deducts floatingLocked so buffer target
        // is sized against actual net value, not gross. More capital-efficient.
        netAssets = vault.totalAssets();
        // targetCash = desired free-cash buffer + any cash deficit required to cover locked liabilities.
        targetCash = (netAssets * bufferTargetBps) / BPS_DENOMINATOR;
        targetCash += vault.getCashDeficit();
        // threshold defines the no-op band around targetCash to avoid rebalance churn.
        threshold = (netAssets * rebalanceThresholdBps) / BPS_DENOMINATOR;
        // hasPendingRequest: whether there are unprocessed redeem requests.
        // Used to block rebalance divest until operator processes them.
        hasPendingRequest = vault.pendingRequestCount() > 0;
    }

    function _freeCash() internal view returns (uint256) {
        return vault.getFreeCash();
    }

    /// @dev Sum of step-aligned executable redeem value across all strategies.
    /// @dev Uses adapter.previewRedeem(totalValue) to get the step-aligned effective amount,
    ///      so a dust residual below the smallest step is correctly excluded from the pool.
    /// @dev Used to distinguish "true insufficient" (pool is not enough) vs "step residual" in processRedeemBatch.
    function _adapterPoolValue() internal view returns (uint256 total) {
        uint256 len = strategyOrder.length;
        for (uint256 i = 0; i < len; i++) {
            address adapter = strategyOrder[i];
            if (!strategyInfo[adapter].isActive) continue;

            uint256 adapterValue;
            try IStrategyAdapter(adapter).totalValue() returns (uint256 v) {
                adapterValue = v;
            } catch {
                continue;
            }
            if (adapterValue == 0) continue;

            // Ask the adapter for the step-aligned executable amount.
            try IStrategyAdapter(adapter)
                .previewRedeem(adapterValue) returns (bool ok, uint256 executableAssetAmount, uint256) {
                if (ok) total += executableAssetAmount;
            } catch {
                // If preview call fails, conservative handling, continue to exclude from total.
            }
        }
    }

    function _computeRebalanceDecision(
        uint256 freeCash,
        uint256 idealCash,
        uint256 targetCash,
        uint256 threshold,
        bool hasPendingRequest
    ) internal pure returns (uint8 action, uint256 amount) {
        // Invest: use idealCash to detect surplus (counts pending redeem in-flight as future cash),
        // but cap the actual invest amount to current freeCash since in-flight hasn't arrived yet.
        if (idealCash > targetCash + threshold) {
            uint256 surplus = idealCash - targetCash;
            amount = surplus > freeCash ? freeCash : surplus;
            return (amount > 0 ? REBALANCE_ACTION_INVEST : REBALANCE_ACTION_NONE, amount);
        }
        // Block rebalance divest if there's a pending user redemption request.
        // Operator must call processRedeemBatch first to handle user liability.
        if (idealCash + threshold < targetCash && !hasPendingRequest) {
            return (REBALANCE_ACTION_DIVEST, targetCash - idealCash);
        }
        return (REBALANCE_ACTION_NONE, 0);
    }

    // =============================================================
    // Business - Rebalance Core
    // =============================================================

    function _invest(uint256 excessCash, uint256 netAssets) internal {
        uint256 totalAssets = netAssets;
        uint256 requested = excessCash;
        uint256 remaining = excessCash;
        uint256 len = strategyOrder.length;

        for (uint256 i = 0; i < len; i++) {
            if (remaining == 0) {
                break;
            }

            address adapter = strategyOrder[i];
            StrategyInfo memory info = strategyInfo[adapter];
            if (!info.isActive) {
                continue;
            }

            uint256 targetBalance = (totalAssets * info.targetWeightBps) / BPS_DENOMINATOR;
            uint256 currentBalance;
            try IStrategyAdapter(adapter).totalValue() returns (uint256 v) {
                currentBalance = v;
            } catch {
                continue;
            }

            if (currentBalance >= targetBalance) {
                continue;
            }

            uint256 shortfall = targetBalance - currentBalance;
            uint256 alloc = shortfall < remaining ? shortfall : remaining;

            // Pending invest (sync/async) already covers part of target gap; only invest uncovered delta.
            uint256 originalAlloc = alloc;
            uint256 pendingInvestPos = vault.adapterInvestInFlightTokens(adapter);

            if (pendingInvestPos > 0) {
                // Compare pending coverage against the adapter's full shortfall, not this round's capped alloc.
                // If estimation fails (returns 0 via fallback), skip deduction to avoid asset/pos unit mismatch.
                uint256 estimatedPosForShortfall = _estimatePosAmount(adapter, shortfall, 0);
                if (estimatedPosForShortfall > 0) {
                    if (pendingInvestPos >= estimatedPosForShortfall) {
                        emit InvestSkipped(adapter, originalAlloc, "");
                        continue;
                    }

                    // uncoveredShortfall = shortfall * (estimatedPos - pendingPos) / estimatedPos
                    uint256 uncoveredShortfall =
                        Math.mulDiv(shortfall, estimatedPosForShortfall - pendingInvestPos, estimatedPosForShortfall);
                    alloc = uncoveredShortfall < remaining ? uncoveredShortfall : remaining;
                    if (alloc == 0) {
                        emit InvestSkipped(adapter, originalAlloc, "");
                        continue;
                    }
                }
            }

            (bool ok, uint256 executableAsset, uint256 expectedPos) = IStrategyAdapter(adapter).previewDeposit(alloc);
            if (!ok || executableAsset == 0) {
                emit InvestSkipped(adapter, alloc, "");
                continue;
            }

            vault.approveToAdapter(adapter, address(asset), executableAsset);
            try IStrategyAdapter(adapter).deposit(executableAsset, adapter) returns (uint256 sharesOrPos) {
                uint256 posAmount = sharesOrPos;
                if (posAmount == 0) posAmount = expectedPos;
                if (posAmount == 0) revert Controller__InvestPosAmountUnavailable(adapter, executableAsset);
                _recordInvestInFlight(adapter, executableAsset, posAmount);
                emit InvestExecuted(adapter, executableAsset, posAmount);
                remaining -= executableAsset;
            } catch (bytes memory revertData) {
                emit InvestSkipped(adapter, executableAsset, revertData);
            }
            vault.approveToAdapter(adapter, address(asset), 0);
        }

        emit RebalanceInvest(requested, requested - remaining, remaining);
    }

    function _divest(uint256 shortfall) internal returns (uint256 remaining) {
        remaining = shortfall;
        uint256 len = strategyOrder.length;

        for (uint256 i = 0; i < len; i++) {
            if (remaining == 0) {
                break;
            }

            address adapter = strategyOrder[i];
            StrategyInfo memory info = strategyInfo[adapter];
            if (!info.isActive) {
                continue;
            }

            uint256 requestAsset = _readDivestCoverage(adapter, remaining);
            if (requestAsset == 0) {
                continue;
            }

            // Preview validates step constraints and returns adjusted amounts.
            (bool redeemOk, uint256 executableRedeem, uint256 redeemPosAmount) =
                IStrategyAdapter(adapter).previewRedeem(requestAsset);
            if (!redeemOk || executableRedeem == 0) {
                emit DivestSkipped(adapter, requestAsset, "");
                continue;
            }
            // Use preview-adjusted asset amount for remaining accounting.
            requestAsset = executableRedeem;
            uint256 posAmount = redeemPosAmount > 0 ? redeemPosAmount : _estimatePosAmount(adapter, requestAsset, 0);
            if (posAmount == 0) {
                emit DivestSkipped(adapter, requestAsset, "");
                continue;
            }

            if (info.isAsync) {
                address token = _posToken(adapter);
                if (token == address(0)) {
                    emit DivestSkipped(adapter, requestAsset, "");
                    continue;
                }

                vault.approveToAdapter(adapter, token, posAmount);
                try IStrategyAdapter(adapter).requestRedeemAsync(posAmount, adapter) {}
                catch (bytes memory revertData) {
                    vault.approveToAdapter(adapter, token, 0);
                    emit DivestSkipped(adapter, requestAsset, revertData);
                    continue;
                }
                vault.approveToAdapter(adapter, token, 0);

                _recordAsyncRedeemInFlight(adapter, token, requestAsset, posAmount);
                remaining = _remainingAfterClear(remaining, requestAsset);
                continue;
            }

            // Sync redeem path
            address syncPosToken = _posToken(adapter);
            if (syncPosToken == address(0)) {
                emit DivestSkipped(adapter, requestAsset, "");
                continue;
            }
            vault.approveToAdapter(adapter, syncPosToken, posAmount);

            try IStrategyAdapter(adapter).withdrawSync(posAmount, adapter) returns (uint256 received) {
                _recordSyncRedeemInFlight(adapter, syncPosToken, posAmount, requestAsset, received);
                vault.approveToAdapter(adapter, syncPosToken, 0);
                remaining = _remainingAfterClear(remaining, received);
            } catch (bytes memory revertData) {
                vault.approveToAdapter(adapter, syncPosToken, 0);
                emit DivestSkipped(adapter, requestAsset, revertData);
            }
        }

        if (remaining > 0) {
            emit DivestIncomplete(remaining);
        }
    }

    // =============================================================
    // In-Flight Accounting Helpers
    // =============================================================

    function _sweepAdapterAssetsToVaultInternal(address adapter, uint256 posAmount, uint256 assetAmount)
        internal
        returns (uint256 posClaimed, uint256 assetClaimed)
    {
        StrategyInfo memory info = strategyInfo[adapter];
        if (!info.exists) {
            revert Controller__InvalidStrategy(adapter);
        }

        address token = _posToken(adapter);
        if (token != address(0) && posAmount > 0) {
            posClaimed = IStrategyAdapter(adapter).sweepToVault(token, posAmount);
        }
        if (assetAmount > 0) {
            assetClaimed = IStrategyAdapter(adapter).sweepToVault(address(asset), assetAmount);
        }
        emit AdapterAssetsSwept(adapter, token, posClaimed, assetClaimed);
    }

    function _confirmRedeemInFlightIds(
        address expectedAdapter,
        IStrategyControllerExecutor.RedeemSettlementInput calldata redeem
    ) internal {
        uint256 len = redeem.inFlightIds.length;
        for (uint256 i = 0; i < len; i++) {
            _confirmSingleRedeemInFlight(expectedAdapter, redeem.inFlightIds[i], redeem.settledAssetAmounts[i]);
        }
    }

    function _markBatchReady(uint256[] calldata ids, uint256[] calldata settledAssets) internal {
        if (ids.length != settledAssets.length) revert Controller__ClaimInputsLengthMismatch();
        uint256 required;
        for (uint256 i = 0; i < ids.length; i++) {
            required += settledAssets[i];
        }
        vault.markRequestsDone(ids, settledAssets);
        emit RedeemBatchReady(ids.length, required);
    }

    function _confirmInvestInFlightIds(
        address adapter,
        IStrategyControllerExecutor.InvestSettlementInput calldata invest
    ) internal {
        uint256 len = invest.inFlightIds.length;
        for (uint256 i = 0; i < len; i++) {
            _confirmSingleInvestInFlight(
                adapter, invest.inFlightIds[i], invest.settledPosAmounts[i], invest.refundAssetAmounts[i]
            );
        }
    }

    function _validateInvestSettlement(
        address adapter,
        IStrategyControllerExecutor.InvestSettlementInput calldata invest
    ) internal view {
        uint256 len = invest.inFlightIds.length;
        for (uint256 i = 0; i < len; i++) {
            (, address recordAdapter,,, uint256 originalAssetAmount,, bool isInvest,,) =
                vault.inFlightRecords(invest.inFlightIds[i]);
            if (recordAdapter != adapter || !isInvest) {
                revert Controller__InvalidInvestInFlight(invest.inFlightIds[i]);
            }
            if (invest.refundAssetAmounts[i] > originalAssetAmount) {
                revert Controller__InvalidInvestRefundAmount(
                    invest.inFlightIds[i], invest.refundAssetAmounts[i], originalAssetAmount
                );
            }
        }
    }

    function _confirmSingleRedeemInFlight(address expectedAdapter, uint256 inFlightId, uint256 settledAmount) internal {
        (, address recordAdapter,,,,, bool isInvest,,) = vault.inFlightRecords(inFlightId);
        if (recordAdapter != expectedAdapter || isInvest) {
            revert Controller__InvalidRedeemInFlight(inFlightId);
        }
        vault.confirmInFlight(inFlightId, settledAmount, settledAmount == 0);
    }

    function _confirmSingleInvestInFlight(
        address adapter,
        uint256 inFlightId,
        uint256 settledPosAmount,
        uint256 refundAssetAmount
    ) internal {
        (, address recordAdapter,,,,, bool isInvest,,) = vault.inFlightRecords(inFlightId);
        if (recordAdapter != adapter || !isInvest) {
            revert Controller__InvalidInvestInFlight(inFlightId);
        }
        vault.confirmInFlight(inFlightId, settledPosAmount, settledPosAmount == 0);
        emit InvestSettlementRecorded(inFlightId, adapter, settledPosAmount, refundAssetAmount);
    }

    function _sumAmounts(uint256[] calldata amounts) internal pure returns (uint256 total) {
        uint256 len = amounts.length;
        for (uint256 i = 0; i < len; i++) {
            total += amounts[i];
        }
    }

    function _isSweepAmountWithinTolerance(uint256 expected, uint256 claimed, uint256 itemCount)
        internal
        pure
        returns (bool)
    {
        if (claimed > expected) {
            return false;
        }
        return expected - claimed <= itemCount * SWEEP_SETTLEMENT_TOLERANCE_PER_ITEM;
    }

    function _settleAdapterBatchAtIndex(
        address[] calldata adapters,
        IStrategyControllerExecutor.InvestSettlementInput[] calldata investBatch,
        IStrategyControllerExecutor.RedeemSettlementInput[] calldata redeemBatch,
        uint256 index
    ) internal {
        _settleAdapterInternal(adapters[index], investBatch[index], redeemBatch[index]);
    }

    function _sweepInvestSettlement(address adapter, IStrategyControllerExecutor.InvestSettlementInput calldata invest)
        internal
    {
        uint256 investPosToSweep = _sumAmounts(invest.settledPosAmounts);
        uint256 investRefundToSweep = _sumAmounts(invest.refundAssetAmounts);

        (uint256 posClaimed, uint256 refundAssetClaimed) =
            _sweepAdapterAssetsToVaultInternal(adapter, investPosToSweep, investRefundToSweep);
        if (!_isSweepAmountWithinTolerance(investPosToSweep, posClaimed, invest.settledPosAmounts.length)) {
            revert Controller__InvestSweepAmountMismatch(adapter, investPosToSweep, posClaimed);
        }
        if (!_isSweepAmountWithinTolerance(investRefundToSweep, refundAssetClaimed, invest.refundAssetAmounts.length)) {
            revert Controller__InvestRefundSweepAmountMismatch(adapter, investRefundToSweep, refundAssetClaimed);
        }
    }

    function _sweepRedeemSettlement(address adapter, IStrategyControllerExecutor.RedeemSettlementInput calldata redeem)
        internal
    {
        uint256 redeemAssetToSweep = _sumAmounts(redeem.settledAssetAmounts);

        (, uint256 redeemAssetClaimed) = _sweepAdapterAssetsToVaultInternal(adapter, 0, redeemAssetToSweep);
        if (!_isSweepAmountWithinTolerance(redeemAssetToSweep, redeemAssetClaimed, redeem.settledAssetAmounts.length)) {
            revert Controller__RedeemSweepAmountMismatch(adapter, redeemAssetToSweep, redeemAssetClaimed);
        }
    }

    function _settleAdapterInternal(
        address adapter,
        IStrategyControllerExecutor.InvestSettlementInput calldata invest,
        IStrategyControllerExecutor.RedeemSettlementInput calldata redeem
    ) internal {
        if (
            invest.inFlightIds.length != invest.settledPosAmounts.length
                || invest.inFlightIds.length != invest.refundAssetAmounts.length
                || redeem.inFlightIds.length != redeem.settledAssetAmounts.length
        ) {
            revert Controller__SettleAmountsLengthMismatch();
        }

        _validateInvestSettlement(adapter, invest);
        _sweepInvestSettlement(adapter, invest);
        _sweepRedeemSettlement(adapter, redeem);

        _confirmInvestInFlightIds(adapter, invest);
        _confirmRedeemInFlightIds(adapter, redeem);
    }

    /// @dev Invest path records pending position tokens and waits for off-chain settlement.
    function _recordInvestInFlight(address adapter, uint256 assetAmount, uint256 expectedPos) internal {
        if (assetAmount == 0 || expectedPos == 0) {
            return;
        }

        address token = _posToken(adapter);
        vault.createInFlight(adapter, token, expectedPos, assetAmount, true);
    }

    /// @dev Async redeem path records pending STABLE and emits unified in-flight events.
    ///      `posAmount` is expected/estimated position-token amount used for request and bookkeeping.
    ///      It may differ from actual protocol consumption under price movement or rounding.
    function _recordAsyncRedeemInFlight(address adapter, address token, uint256 requestedAsset, uint256 posAmount)
        internal
        returns (uint256 inFlightId)
    {
        if (requestedAsset == 0 || posAmount == 0) {
            return 0;
        }

        inFlightId = vault.createInFlight(adapter, token, posAmount, requestedAsset, false);
        emit RedeemInFlightRecorded(adapter, inFlightId, requestedAsset, requestedAsset, true);
    }

    /// @dev Sync redeem path records pending STABLE on adapter and waits for off-chain settlement.
    ///      `posAmount` is expected/estimated position-token amount captured at request time.
    ///      For redeem flow, settlement accounting is driven by `receivedAsset` (STABLE), while
    ///      `posAmount` remains informational/bookkeeping and can deviate from actual token burn.
    function _recordSyncRedeemInFlight(
        address adapter,
        address token,
        uint256 posAmount,
        uint256 requestedAsset,
        uint256 receivedAsset
    ) internal returns (uint256 inFlightId) {
        if (requestedAsset == 0 || receivedAsset == 0 || posAmount == 0) {
            return 0;
        }

        inFlightId = vault.createInFlight(adapter, token, posAmount, receivedAsset, false);
        emit RedeemInFlightRecorded(adapter, inFlightId, requestedAsset, receivedAsset, false);
    }

    function _remainingAfterClear(uint256 remaining, uint256 cleared) internal pure returns (uint256) {
        return cleared >= remaining ? 0 : remaining - cleared;
    }

    function _readDivestCoverage(address adapter, uint256 remaining) internal returns (uint256 requestAsset) {
        uint256 settledValue;
        try IStrategyAdapter(adapter).totalValue() returns (uint256 v) {
            settledValue = v;
        } catch {
            return 0;
        }

        if (settledValue == 0) {
            return 0;
        }

        requestAsset = remaining < settledValue ? remaining : settledValue;
        emit DivestCoverageRead(adapter, remaining, settledValue, requestAsset);
    }

    function _estimatePosAmount(address adapter, uint256 assetAmount, uint256 fallbackAmount)
        internal
        view
        returns (uint256 posAmount)
    {
        try IStrategyAdapter(adapter).estimatePosAmount(assetAmount) returns (uint256 est) {
            posAmount = est;
        } catch {
            posAmount = fallbackAmount;
        }
    }

    function _posToken(address adapter) internal view returns (address token) {
        try IStrategyAdapter(adapter).posToken() returns (address t) {
            token = t;
        } catch {
            token = address(0);
        }
    }

    // =============================================================
    // Batch Validation Helpers
    // =============================================================

    /// @dev Process stage uses current exchange rate to estimate batch settlement amount from request shares.
    function _batchTotalBySharesAndRate(uint256[] calldata ids) internal view returns (uint256 totalAssets) {
        uint256 rate = vault.exchangeRate();
        for (uint256 i = 0; i < ids.length; i++) {
            (,, uint256 shares,,,,,) = vault.requests(ids[i]);
            totalAssets += Math.mulDiv(shares, rate, 1e18, Math.Rounding.Floor);
        }
    }

    function _validateSortedIds(uint256[] calldata ids) internal pure {
        for (uint256 i = 1; i < ids.length; i++) {
            if (ids[i] <= ids[i - 1]) {
                revert Controller__IdsNotSorted();
            }
        }
    }
}
