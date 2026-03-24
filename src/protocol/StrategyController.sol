// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategyAdapter} from "../interfaces/adapters/IStrategyAdapter.sol";
import {IMantleYieldVault} from "../interfaces/vault/IMantleYieldVault.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract StrategyController is Initializable, AccessControlUpgradeable, ReentrancyGuard {
    bytes32 public constant OPERATOR_EXECUTOR_ROLE = keccak256("OPERATOR_EXECUTOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    uint256 public constant BPS_DENOMINATOR = 10_000;
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
    mapping(bytes32 => bool) public processingBatchDone;
    mapping(bytes32 => bool) public readyBatchDone;

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
        uint256 totalCash,
        uint256 lockedLiabilities,
        uint256 freeCash,
        uint256 netAssets,
        uint256 targetCash,
        uint256 threshold
    );
    event InvestExecuted(address indexed adapter, uint256 amountAsset, uint256 sharesOrPos);
    event InvestSkipped(address indexed adapter, uint256 amountAsset);
    event RebalanceInvest(uint256 requestedAsset, uint256 investedAsset, uint256 remainingAsset);
    event DivestSkipped(address indexed adapter, uint256 requestedAsset);
    /// @notice Unified redeem in-flight record event for both async and sync paths.
    /// @dev inFlightUsdcAmount semantic differs by path:
    ///      - async: equals requestedAsset
    ///      - sync: equals actually received asset amount from withdrawSync
    event RedeemInFlightRecorded(
        address indexed adapter,
        uint256 indexed inFlightId,
        uint256 requestedAsset,
        uint256 inFlightUsdcAmount,
        bool isAsync
    );
    event DivestIncomplete(uint256 remainingAsset);
    event RedeemBatchProcessing(uint256 indexed batchSize, uint256 batchTotalAsset, uint256 shortfallAsset);
    event RedeemBatchReady(uint256 indexed batchSize, uint256 requiredAsset);
    event AdapterAssetsSwept(
        address indexed adapter, address indexed posToken, uint256 posClaimed, uint256 assetClaimed
    );

    error InvalidAddress();
    error InvalidBps();
    error InvalidExecutorContract(address executor);
    error CooldownNotElapsed();
    error InvalidStrategy(address adapter);
    error InvalidPriorityOrder(address adapter);
    error StrategyInactive(address adapter);
    error WeightsMustBe10000(uint256 actualTotalWeight);
    error InsufficientCashForReady(uint256 required, uint256 available);
    error DuplicateStrategyInOrder(address adapter);
    error BatchAlreadyProcessed(bytes32 batchKey);
    error BatchNotProcessed(bytes32 batchKey);
    error BatchAlreadyReady(bytes32 batchKey);
    error IdsNotSorted();
    error InvalidRequestState(uint256 id, IMantleYieldVault.RequestStatus status);
    error InvalidRedeemInFlight(uint256 inFlightId);
    error InvalidInvestInFlight(uint256 inFlightId);
    error InvestInFlightIdsRequired(address adapter);
    error RedeemInFlightIdsRequired(address adapter);
    error SettleAmountsLengthMismatch();
    error InvestSweepAmountMismatch(address adapter, uint256 expected, uint256 claimed);
    error RedeemSweepAmountMismatch(address adapter, uint256 expected, uint256 claimed);
    error ClaimInputsLengthMismatch();
    error UpdateStrategiesLengthMismatch();
    error DuplicateStrategyUpdate(address adapter);
    error StrategyAlreadyActive(address adapter);
    error StrategyAlreadyInactive(address adapter);
    error StrategyInOrder(address adapter);
    error StrategyHasInFlight(address adapter, uint256 pendingInvestTokens, uint256 pendingRedeemUsdc);

    constructor() {
        _disableInitializers();
    }

    // =============================================================
    // Initialization
    // =============================================================

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
            revert InvalidAddress();
        }
        if (operatorExecutor_.code.length == 0) {
            revert InvalidExecutorContract(operatorExecutor_);
        }
        if (bufferTargetBps_ > BPS_DENOMINATOR || rebalanceThresholdBps_ > BPS_DENOMINATOR) {
            revert InvalidBps();
        }

        __AccessControl_init();

        vault = IMantleYieldVault(vault_);
        asset = IERC20(vault.asset());
        if (address(asset) == address(0)) {
            revert InvalidAddress();
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

    /// @notice Read current rebalance accounting state with the same formula used by rebalance().
    function getRebalanceState()
        external
        view
        returns (
            uint256 totalCash,
            uint256 locked,
            uint256 freeCash,
            uint256 netAssets,
            uint256 targetCash,
            uint256 threshold
        )
    {
        return _readRebalanceState();
    }

    /// @notice Preview whether rebalance should run at current block and what action is expected.
    /// @dev action: 0 = NONE, 1 = INVEST, 2 = DIVEST.
    function previewRebalance() external view returns (bool shouldRebalance, uint8 action, uint256 amount) {
        if (block.timestamp < uint256(lastRebalance) + uint256(rebalanceCooldown)) {
            return (false, REBALANCE_ACTION_NONE, 0);
        }

        (,, uint256 freeCash,, uint256 targetCash, uint256 threshold) = _readRebalanceState();
        (action, amount) = _computeRebalanceDecision(freeCash, targetCash, threshold);
        shouldRebalance = action != REBALANCE_ACTION_NONE;
    }

    function setRiskParams(uint16 bufferTargetBps_, uint16 rebalanceThresholdBps_, uint64 rebalanceCooldown_)
        external
        onlyAdmin
    {
        if (bufferTargetBps_ > BPS_DENOMINATOR || rebalanceThresholdBps_ > BPS_DENOMINATOR) {
            revert InvalidBps();
        }
        bufferTargetBps = bufferTargetBps_;
        rebalanceThresholdBps = rebalanceThresholdBps_;
        rebalanceCooldown = rebalanceCooldown_;
        emit RiskParamsUpdated(bufferTargetBps_, rebalanceThresholdBps_, rebalanceCooldown_);
    }

    function registerStrategy(address adapter, uint16 targetWeightBps, uint16 priority, bool isAsync)
        external
        onlyAdmin
    {
        if (adapter == address(0)) {
            revert InvalidAddress();
        }
        if (adapter.code.length == 0) {
            revert InvalidStrategy(adapter);
        }
        if (targetWeightBps > BPS_DENOMINATOR) {
            revert InvalidBps();
        }
        if (strategyInfo[adapter].exists) {
            revert InvalidStrategy(adapter);
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
            revert InvalidStrategy(adapter);
        }
        if (info.isActive) {
            revert StrategyAlreadyActive(adapter);
        }

        _ensureVaultAdapterRegistered(adapter);
        info.isActive = true;

        emit StrategyActivated(adapter);
        emit StrategyUpdated(adapter, info.targetWeightBps, info.priority, info.isAsync, true);
    }

    function deactivateStrategy(address adapter) external onlyAdmin {
        StrategyInfo storage info = strategyInfo[adapter];
        if (!info.exists) {
            revert InvalidStrategy(adapter);
        }
        if (!info.isActive) {
            revert StrategyAlreadyInactive(adapter);
        }
        if (_isAdapterInOrder(adapter)) {
            revert StrategyInOrder(adapter);
        }

        uint256 pendingInvest = vault.adapterInvestInFlightTokens(adapter);
        uint256 pendingRedeem = vault.adapterRedeemInFlightUsdc(adapter);
        if (pendingInvest > 0 || pendingRedeem > 0) {
            revert StrategyHasInFlight(adapter, pendingInvest, pendingRedeem);
        }

        if (vault.isAdapter(adapter)) {
            vault.removeAdapter(adapter);
        }

        info.isActive = false;
        emit StrategyDeactivated(adapter);
        emit StrategyUpdated(adapter, info.targetWeightBps, info.priority, info.isAsync, false);
    }

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
                revert InvalidStrategy(adapter);
            }
            if (!info.isActive) {
                revert StrategyInactive(adapter);
            }
            for (uint256 j = 0; j < i; j++) {
                if (orderedStrategies[j] == adapter) {
                    revert DuplicateStrategyInOrder(adapter);
                }
            }

            if (i > 0 && info.priority < lastPriority) {
                revert InvalidPriorityOrder(adapter);
            }
            lastPriority = info.priority;

            strategyOrder.push(adapter);
            totalActiveWeight += info.targetWeightBps;
        }

        if (totalActiveWeight != BPS_DENOMINATOR) {
            revert WeightsMustBe10000(totalActiveWeight);
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
            revert UpdateStrategiesLengthMismatch();
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
                revert InvalidStrategy(adapter);
            }
            if (!info.isActive) {
                revert StrategyInactive(adapter);
            }
            if (i > 0 && info.priority < lastPriority) {
                revert InvalidPriorityOrder(adapter);
            }
            lastPriority = info.priority;
            totalActiveWeight += info.targetWeightBps;
        }

        if (totalActiveWeight != BPS_DENOMINATOR) {
            revert WeightsMustBe10000(totalActiveWeight);
        }
    }

    function _applyStrategyUpdate(address adapter, uint16 targetWeightBps, uint16 priority, bool isAsync) internal {
        if (targetWeightBps > BPS_DENOMINATOR) {
            revert InvalidBps();
        }
        if (!strategyInfo[adapter].exists) {
            revert InvalidStrategy(adapter);
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
                    revert DuplicateStrategyUpdate(adapter);
                }
            }
        }
    }

    function _ensureVaultAdapterRegistered(address adapter) internal {
        if (!vault.isAdapter(adapter)) {
            vault.registerAdapter(adapter);
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
    /// @dev Controller must hold PAUSER_ROLE on target adapter.
    function setAdapterPaused(address adapter, bool paused_) external onlyPauser nonReentrant {
        if (!strategyInfo[adapter].exists) {
            revert InvalidStrategy(adapter);
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
                revert InvalidStrategy(adapter);
            }
            IStrategyAdapter(adapter).setPaused(paused_);
            emit AdapterPauseUpdated(adapter, paused_);
        }
    }

    // =============================================================
    // Business Entry Points
    // =============================================================

    /// @notice Execute buffer-based rebalance.
    /// @dev Invests when free cash is above target+threshold, divests when below target-threshold.
    function rebalance() external onlyOperatorExecutor nonReentrant {
        if (block.timestamp < uint256(lastRebalance) + uint256(rebalanceCooldown)) {
            revert CooldownNotElapsed();
        }

        (
            uint256 totalCash,
            uint256 locked,
            uint256 freeCash,
            uint256 netAssets,
            uint256 targetCash,
            uint256 threshold
        ) = _readRebalanceState();
        emit RebalanceEvaluated(totalCash, locked, freeCash, netAssets, targetCash, threshold);

        (uint8 action, uint256 amount) = _computeRebalanceDecision(freeCash, targetCash, threshold);
        if (action == REBALANCE_ACTION_INVEST) {
            _invest(amount);
        } else if (action == REBALANCE_ACTION_DIVEST) {
            _divest(amount);
        }

        lastRebalance = uint64(block.timestamp);
    }

    /// @notice Move redemption requests into PROCESSING and divest when free cash is below batch demand.
    /// @dev Batch demand is derived on-chain from `ids` using current `exchangeRate`:
    ///      sum(request.shares * exchangeRate / 1e18).
    function processRedeemBatch(uint256[] calldata ids) external onlyOperatorExecutor nonReentrant {
        _validateSortedIds(ids);

        bytes32 batchKey = _batchKey(ids);
        if (processingBatchDone[batchKey]) {
            revert BatchAlreadyProcessed(batchKey);
        }

        vault.updateRequestBatch(ids, IMantleYieldVault.RequestStatus.PROCESSING);
        processingBatchDone[batchKey] = true;

        uint256 batchTotalAsset = _batchTotalBySharesAndRate(ids);
        uint256 freeCash = _freeCash();
        uint256 shortfall;
        if (freeCash < batchTotalAsset) {
            shortfall = batchTotalAsset - freeCash;
            _divest(shortfall);
        }

        emit RedeemBatchProcessing(ids.length, batchTotalAsset, shortfall);
    }

    // =============================================================
    // Business - Settlement & Redemption
    // =============================================================

    /// @notice Finalize a processed redeem batch with operator-provided per-request settled assets.
    /// @dev Preconditions:
    ///      - `processRedeemBatch(ids)` has already been executed for the same sorted `ids`.
    ///      - Vault has enough underlying balance to cover `sum(settledAssets)`.
    ///      - Requests are still in PROCESSING state and not finalized yet.
    ///      Settlement actions (adapter sweep / in-flight confirmation) are not performed here;
    ///      run settleAdapter/settleAdapters before this function when needed.
    ///      On success, the vault marks requests DONE and transfers settled assets to receivers.
    function finalizeRedeemBatch(uint256[] calldata ids, uint256[] calldata settledAssets)
        external
        onlyOperatorExecutor
        nonReentrant
    {
        _validateSortedIds(ids);
        bytes32 batchKey = _batchKey(ids);
        _ensureBatchReadyAllowed(batchKey);
        _markBatchReady(ids, settledAssets, batchKey);
    }

    /// @notice Settle one adapter by sweeping assets back to vault and confirming in-flight records.
    /// @dev `investSettledAmounts` and `redeemSettledAmounts` are per-id actual settled values.
    ///      Their sums are used as sweep amounts and must match sweep return values.
    function settleAdapter(
        address adapter,
        uint256[] calldata investInFlightIds,
        uint256[] calldata investSettledAmounts,
        uint256[] calldata redeemInFlightIds,
        uint256[] calldata redeemSettledAmounts
    ) external onlyOperatorExecutor nonReentrant {
        _settleAdapterInternal(
            adapter, investInFlightIds, investSettledAmounts, redeemInFlightIds, redeemSettledAmounts
        );
    }

    /// @notice Settle multiple adapters in a single transaction.
    /// @dev Inputs are grouped per adapter index.
    function settleAdapters(
        address[] calldata adapters,
        uint256[][] calldata investInFlightIdsBatch,
        uint256[][] calldata investSettledAmountsBatch,
        uint256[][] calldata redeemInFlightIdsBatch,
        uint256[][] calldata redeemSettledAmountsBatch
    ) external onlyOperatorExecutor nonReentrant {
        if (
            adapters.length != investInFlightIdsBatch.length || adapters.length != investSettledAmountsBatch.length
                || adapters.length != redeemInFlightIdsBatch.length
                || adapters.length != redeemSettledAmountsBatch.length
        ) {
            revert SettleAmountsLengthMismatch();
        }

        uint256 len = adapters.length;
        for (uint256 i = 0; i < len; i++) {
            _settleAdapterInternal(
                adapters[i],
                investInFlightIdsBatch[i],
                investSettledAmountsBatch[i],
                redeemInFlightIdsBatch[i],
                redeemSettledAmountsBatch[i]
            );
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
            uint256 locked,
            uint256 freeCash,
            uint256 netAssets,
            uint256 targetCash,
            uint256 threshold
        )
    {
        totalCash = asset.balanceOf(address(vault));
        freeCash = vault.getFreeCash();
        locked = totalCash > freeCash ? totalCash - freeCash : 0;
        // Net assets uses a unified accounting base:
        // vault cash + deployed strategy value + both sides of pending in-flight.
        // This avoids underestimating AUM during settlement latency.
        netAssets = totalCash + _totalStrategyValue() + vault.totalInvestInFlight() + vault.totalRedeemInFlight();
        // targetCash is the desired free-cash buffer; threshold is hysteresis band.
        // Rebalance only triggers outside [targetCash - threshold, targetCash + threshold].
        targetCash = (netAssets * bufferTargetBps) / BPS_DENOMINATOR;
        threshold = (netAssets * rebalanceThresholdBps) / BPS_DENOMINATOR;
    }

    function _freeCash() internal view returns (uint256) {
        return vault.getFreeCash();
    }

    function _computeRebalanceDecision(uint256 freeCash, uint256 targetCash, uint256 threshold)
        internal
        pure
        returns (uint8 action, uint256 amount)
    {
        if (freeCash > targetCash + threshold) {
            return (REBALANCE_ACTION_INVEST, freeCash - targetCash);
        }
        if (freeCash + threshold < targetCash) {
            return (REBALANCE_ACTION_DIVEST, targetCash - freeCash);
        }
        return (REBALANCE_ACTION_NONE, 0);
    }

    function _totalStrategyValue() internal view returns (uint256 total) {
        uint256 len = strategyOrder.length;
        for (uint256 i = 0; i < len; i++) {
            try IStrategyAdapter(strategyOrder[i]).totalValue() returns (uint256 v) {
                total += v;
            } catch {}
        }
    }

    // =============================================================
    // Business - Rebalance Core
    // =============================================================

    function _invest(uint256 excessCash) internal {
        uint256 totalAssets =
            asset.balanceOf(address(vault)) + _totalStrategyValue() + vault.totalInvestInFlight()
            + vault.totalRedeemInFlight();
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
            if (alloc == 0) {
                continue;
            }
            // Pending invest (sync/async) already covers part of target gap; only invest uncovered delta.
            uint256 originalAlloc = alloc;
            uint256 pendingInvestPos = vault.adapterInvestInFlightTokens(adapter);
            if (pendingInvestPos > 0) {
                // Compare pending coverage against the adapter's full shortfall, not this round's capped alloc.
                // If estimation fails (returns 0 via fallback), skip deduction to avoid asset/pos unit mismatch.
                uint256 estimatedPosForShortfall = _estimatePosAmount(adapter, shortfall, 0);
                if (estimatedPosForShortfall > 0) {
                    if (pendingInvestPos >= estimatedPosForShortfall) {
                        emit InvestSkipped(adapter, originalAlloc);
                        continue;
                    }

                    uint256 uncoveredShortfall =
                        Math.mulDiv(shortfall, estimatedPosForShortfall - pendingInvestPos, estimatedPosForShortfall);
                    alloc = uncoveredShortfall < remaining ? uncoveredShortfall : remaining;
                    if (alloc == 0) {
                        emit InvestSkipped(adapter, originalAlloc);
                        continue;
                    }
                }
            }

            vault.approveToAdapter(adapter, address(asset), alloc);
            try IStrategyAdapter(adapter).deposit(alloc, adapter) returns (uint256 sharesOrPos) {
                uint256 posAmount = _estimatePosAmount(adapter, alloc, sharesOrPos);
                if (posAmount == 0) {
                    posAmount = sharesOrPos == 0 ? alloc : sharesOrPos;
                }

                _recordInvestInFlight(adapter, alloc, posAmount);

                emit InvestExecuted(adapter, alloc, sharesOrPos);
                remaining -= alloc;
            } catch {
                emit InvestSkipped(adapter, alloc);
            }
            vault.approveToAdapter(adapter, address(asset), 0);
        }

        emit RebalanceInvest(requested, requested - remaining, remaining);
    }

    function _divest(uint256 shortfall) internal {
        uint256 remaining = shortfall;
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

            uint256 value;
            try IStrategyAdapter(adapter).totalValue() returns (uint256 v) {
                value = v;
            } catch {
                continue;
            }
            if (value == 0) {
                continue;
            }

            // Asset-denominated amount (e.g. USDC/USDT), not position-token amount.
            uint256 toWithdrawAsset = remaining < value ? remaining : value;
            // Avoid duplicate redeem requests for both sync/async paths: only withdraw uncovered delta.
            uint256 pendingRedeemAsset = vault.adapterRedeemInFlightUsdc(adapter);
            uint256 coveredByPending = pendingRedeemAsset >= toWithdrawAsset ? toWithdrawAsset : pendingRedeemAsset;
            uint256 requestAsset = toWithdrawAsset - coveredByPending;
            if (requestAsset == 0) {
                remaining = _remainingAfterClear(remaining, toWithdrawAsset);
                continue;
            }

            if (info.isAsync) {
                address token = _posToken(adapter);
                if (token == address(0)) {
                    emit DivestSkipped(adapter, requestAsset);
                    remaining = _remainingAfterClear(remaining, coveredByPending);
                    continue;
                }

                // Convert asset amount into position-token amount for protocol redeem.
                uint256 posAmount = _estimatePosAmount(adapter, requestAsset, 0);
                if (posAmount == 0) {
                    emit DivestSkipped(adapter, requestAsset);
                    remaining = _remainingAfterClear(remaining, coveredByPending);
                    continue;
                }

                vault.approveToAdapter(adapter, token, posAmount);
                try IStrategyAdapter(adapter).requestRedeemAsync(requestAsset, adapter) {}
                catch {
                    vault.approveToAdapter(adapter, token, 0);
                    emit DivestSkipped(adapter, requestAsset);
                    remaining = _remainingAfterClear(remaining, coveredByPending);
                    continue;
                }
                vault.approveToAdapter(adapter, token, 0);

                _recordAsyncRedeemInFlight(adapter, token, requestAsset, posAmount);
                remaining = _remainingAfterClear(remaining, coveredByPending + requestAsset);
                continue;
            }

            // Sync redeem path
            address syncPosToken = _posToken(adapter);
            if (syncPosToken == address(0)) {
                emit DivestSkipped(adapter, requestAsset);
                remaining = _remainingAfterClear(remaining, coveredByPending);
                continue;
            }

            uint256 syncPosAmount = _estimatePosAmount(adapter, requestAsset, 0);
            if (syncPosAmount == 0) {
                emit DivestSkipped(adapter, requestAsset);
                remaining = _remainingAfterClear(remaining, coveredByPending);
                continue;
            }
            vault.approveToAdapter(adapter, syncPosToken, syncPosAmount);

            try IStrategyAdapter(adapter).withdrawSync(requestAsset, adapter) returns (uint256 received) {
                _recordSyncRedeemInFlight(adapter, syncPosToken, syncPosAmount, requestAsset, received);
                vault.approveToAdapter(adapter, syncPosToken, 0);
                uint256 cleared = coveredByPending + received;
                remaining = _remainingAfterClear(remaining, cleared);
            } catch {
                vault.approveToAdapter(adapter, syncPosToken, 0);
                emit DivestSkipped(adapter, requestAsset);
                remaining = _remainingAfterClear(remaining, coveredByPending);
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
            revert InvalidStrategy(adapter);
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
        uint256[] calldata inFlightIds,
        uint256[] calldata settledAmounts
    ) internal {
        uint256 len = inFlightIds.length;
        for (uint256 i = 0; i < len; i++) {
            uint256 inFlightId = inFlightIds[i];
            uint256 settledAmount = settledAmounts[i];
            (, address recordAdapter,,, uint256 usdcAmount,, bool isInvest,, IMantleYieldVault.InFlightStatus status) =
                vault.inFlightRecords(inFlightId);
            if (
                recordAdapter != expectedAdapter || isInvest || status != IMantleYieldVault.InFlightStatus.PENDING
                    || usdcAmount == 0
            ) {
                revert InvalidRedeemInFlight(inFlightId);
            }
            vault.confirmInFlight(inFlightId, settledAmount, settledAmount == 0);
        }
    }

    function _ensureBatchReadyAllowed(bytes32 batchKey) internal view {
        if (!processingBatchDone[batchKey]) {
            revert BatchNotProcessed(batchKey);
        }
        if (readyBatchDone[batchKey]) {
            revert BatchAlreadyReady(batchKey);
        }
    }

    function _markBatchReady(uint256[] calldata ids, uint256[] calldata settledAssets, bytes32 batchKey) internal {
        uint256 required = _batchRequiredAssets(ids, settledAssets);
        uint256 available = asset.balanceOf(address(vault));
        if (available < required) {
            revert InsufficientCashForReady(required, available);
        }

        vault.markRequestsDone(ids, settledAssets);
        readyBatchDone[batchKey] = true;
        emit RedeemBatchReady(ids.length, required);
    }

    function _confirmInvestInFlightIds(
        address adapter,
        uint256[] calldata investInFlightIds,
        uint256[] calldata settledAmounts
    ) internal {
        uint256 len = investInFlightIds.length;
        for (uint256 i = 0; i < len; i++) {
            uint256 inFlightId = investInFlightIds[i];
            uint256 settledAmount = settledAmounts[i];
            (, address recordAdapter,, uint256 tokenAmount,,, bool isInvest,, IMantleYieldVault.InFlightStatus status) =
                vault.inFlightRecords(inFlightId);
            if (
                recordAdapter != adapter || !isInvest || status != IMantleYieldVault.InFlightStatus.PENDING
                    || tokenAmount == 0
            ) {
                revert InvalidInvestInFlight(inFlightId);
            }
            vault.confirmInFlight(inFlightId, settledAmount, settledAmount == 0);
        }
    }

    function _sumAmounts(uint256[] calldata amounts) internal pure returns (uint256 total) {
        uint256 len = amounts.length;
        for (uint256 i = 0; i < len; i++) {
            total += amounts[i];
        }
    }

    function _settleAdapterInternal(
        address adapter,
        uint256[] calldata investInFlightIds,
        uint256[] calldata investSettledAmounts,
        uint256[] calldata redeemInFlightIds,
        uint256[] calldata redeemSettledAmounts
    ) internal {
        if (
            investInFlightIds.length != investSettledAmounts.length
                || redeemInFlightIds.length != redeemSettledAmounts.length
        ) {
            revert SettleAmountsLengthMismatch();
        }

        uint256 investToSweep = _sumAmounts(investSettledAmounts);
        uint256 redeemToSweep = _sumAmounts(redeemSettledAmounts);
        (uint256 posClaimed, uint256 assetClaimed) =
            _sweepAdapterAssetsToVaultInternal(adapter, investToSweep, redeemToSweep);
        if (posClaimed != investToSweep) {
            revert InvestSweepAmountMismatch(adapter, investToSweep, posClaimed);
        }
        if (assetClaimed != redeemToSweep) {
            revert RedeemSweepAmountMismatch(adapter, redeemToSweep, assetClaimed);
        }

        _confirmInvestInFlightIds(adapter, investInFlightIds, investSettledAmounts);
        _confirmRedeemInFlightIds(adapter, redeemInFlightIds, redeemSettledAmounts);
    }

    /// @dev Invest path records pending position tokens and waits for off-chain settlement.
    function _recordInvestInFlight(address adapter, uint256 assetAmount, uint256 expectedPos) internal {
        if (assetAmount == 0 || expectedPos == 0) {
            return;
        }

        address token = _posToken(adapter);
        vault.createInFlight(adapter, token, expectedPos, assetAmount, true);
    }

    /// @dev Async redeem path records pending USDC and emits unified in-flight events.
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

    /// @dev Sync redeem path records pending USDC on adapter and waits for off-chain settlement.
    ///      `posAmount` is expected/estimated position-token amount captured at request time.
    ///      For redeem flow, settlement accounting is driven by `receivedAsset` (USDC), while
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

    function _batchRequiredAssets(uint256[] calldata ids, uint256[] calldata settledAssets)
        internal
        view
        returns (uint256 required)
    {
        if (ids.length != settledAssets.length) {
            revert ClaimInputsLengthMismatch();
        }
        for (uint256 i = 0; i < ids.length; i++) {
            (,,,,,, IMantleYieldVault.RequestStatus status) = vault.requests(ids[i]);
            if (status != IMantleYieldVault.RequestStatus.PROCESSING) {
                revert InvalidRequestState(ids[i], status);
            }
            required += settledAssets[i];
        }
    }

    /// @dev Process stage uses current exchange rate to estimate batch settlement amount from request shares.
    function _batchTotalBySharesAndRate(uint256[] calldata ids) internal view returns (uint256 totalAssets) {
        uint256 rate = vault.exchangeRate();
        for (uint256 i = 0; i < ids.length; i++) {
            (,, uint256 shares,,,,) = vault.requests(ids[i]);
            totalAssets += Math.mulDiv(shares, rate, 1e18, Math.Rounding.Floor);
        }
    }

    function _validateSortedIds(uint256[] calldata ids) internal pure {
        for (uint256 i = 1; i < ids.length; i++) {
            if (ids[i] <= ids[i - 1]) {
                revert IdsNotSorted();
            }
        }
    }

    function _batchKey(uint256[] calldata ids) internal pure returns (bytes32) {
        return keccak256(abi.encode(ids));
    }
}
