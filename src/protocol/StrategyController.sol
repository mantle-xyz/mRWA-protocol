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
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 public constant STRATEGY_MANAGER_ROLE = keccak256("STRATEGY_MANAGER_ROLE");

    uint256 public constant BPS_DENOMINATOR = 10_000;

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

    event StrategyRegistered(
        address indexed adapter, uint16 targetWeightBps, uint16 priority, bool isAsync, bool isActive
    );
    event StrategyUpdated(
        address indexed adapter, uint16 targetWeightBps, uint16 priority, bool isAsync, bool isActive
    );
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
    event DivestExecuted(address indexed adapter, uint256 requestedAsset, uint256 receivedAsset);
    event DivestSkipped(address indexed adapter, uint256 requestedAsset);
    event AsyncRedeemRequested(address indexed adapter, uint256 amountAsset, uint256 inFlightId);
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
    error ClaimInputsLengthMismatch();
    error UpdateStrategiesLengthMismatch();
    error DuplicateStrategyUpdate(address adapter);

    constructor() {
        _disableInitializers();
    }

    // =============================================================
    // Initialization
    // =============================================================

    function initialize(
        address vault_,
        address admin,
        address strategyManager,
        address executorGateway,
        uint16 bufferTargetBps_,
        uint16 rebalanceThresholdBps_,
        uint64 rebalanceCooldown_
    ) external initializer {
        if (
            vault_ == address(0) || admin == address(0) || strategyManager == address(0)
                || executorGateway == address(0)
        ) {
            revert InvalidAddress();
        }
        if (executorGateway.code.length == 0) {
            revert InvalidExecutorContract(executorGateway);
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

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(STRATEGY_MANAGER_ROLE, strategyManager);
        _grantRole(EXECUTOR_ROLE, executorGateway);
    }

    // =============================================================
    // Parameter Management
    // =============================================================

    function strategyOrderLength() external view returns (uint256) {
        return strategyOrder.length;
    }

    function setRiskParams(uint16 bufferTargetBps_, uint16 rebalanceThresholdBps_, uint64 rebalanceCooldown_)
        external
        onlyRole(STRATEGY_MANAGER_ROLE)
    {
        if (bufferTargetBps_ > BPS_DENOMINATOR || rebalanceThresholdBps_ > BPS_DENOMINATOR) {
            revert InvalidBps();
        }
        bufferTargetBps = bufferTargetBps_;
        rebalanceThresholdBps = rebalanceThresholdBps_;
        rebalanceCooldown = rebalanceCooldown_;
        emit RiskParamsUpdated(bufferTargetBps_, rebalanceThresholdBps_, rebalanceCooldown_);
    }

    function registerStrategy(address adapter, uint16 targetWeightBps, uint16 priority, bool isAsync, bool isActive)
        external
        onlyRole(STRATEGY_MANAGER_ROLE)
    {
        if (adapter == address(0)) {
            revert InvalidAddress();
        }
        if (targetWeightBps > BPS_DENOMINATOR) {
            revert InvalidBps();
        }
        if (strategyInfo[adapter].exists) {
            revert InvalidStrategy(adapter);
        }

        strategyInfo[adapter] = StrategyInfo({
            targetWeightBps: targetWeightBps, priority: priority, isAsync: isAsync, isActive: isActive, exists: true
        });

        _validateCurrentOrderInvariant();
        emit StrategyRegistered(adapter, targetWeightBps, priority, isAsync, isActive);
    }

    function updateStrategies(
        address[] calldata adapters,
        uint16[] calldata targetWeightBpsList,
        uint16[] calldata priorities,
        bool[] calldata isAsyncList,
        bool[] calldata isActiveList
    ) external onlyRole(STRATEGY_MANAGER_ROLE) {
        _validateUpdateStrategiesInputs(adapters, targetWeightBpsList, priorities, isAsyncList, isActiveList);

        _validateNoDuplicateAdapters(adapters);

        uint256 len = adapters.length;
        for (uint256 i = 0; i < len; i++) {
            _applyStrategyUpdate(adapters[i], targetWeightBpsList[i], priorities[i], isAsyncList[i], isActiveList[i]);
        }

        _validateCurrentOrderInvariant();
    }

    function updateStrategiesAndOrder(
        address[] calldata adapters,
        uint16[] calldata targetWeightBpsList,
        uint16[] calldata priorities,
        bool[] calldata isAsyncList,
        bool[] calldata isActiveList,
        address[] calldata orderedStrategies
    ) external onlyRole(STRATEGY_MANAGER_ROLE) {
        _validateUpdateStrategiesInputs(adapters, targetWeightBpsList, priorities, isAsyncList, isActiveList);
        _validateNoDuplicateAdapters(adapters);

        uint256 len = adapters.length;
        for (uint256 i = 0; i < len; i++) {
            _applyStrategyUpdate(adapters[i], targetWeightBpsList[i], priorities[i], isAsyncList[i], isActiveList[i]);
        }

        _setStrategyOrder(orderedStrategies);
    }

    function setStrategyOrder(address[] calldata orderedStrategies) external onlyRole(STRATEGY_MANAGER_ROLE) {
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
        bool[] calldata isAsyncList,
        bool[] calldata isActiveList
    ) internal pure {
        uint256 len = adapters.length;
        if (
            len != targetWeightBpsList.length || len != priorities.length || len != isAsyncList.length
                || len != isActiveList.length
        ) {
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

    function _applyStrategyUpdate(address adapter, uint16 targetWeightBps, uint16 priority, bool isAsync, bool isActive)
        internal
    {
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
        info.isActive = isActive;

        emit StrategyUpdated(adapter, targetWeightBps, priority, isAsync, isActive);
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

    // =============================================================
    // Emergency Controls
    // =============================================================

    /// @notice Set adapter pause state via controller.
    /// @dev Controller must hold PAUSER_ROLE on target adapter.
    function setAdapterPaused(address adapter, bool paused_) external onlyRole(STRATEGY_MANAGER_ROLE) nonReentrant {
        if (!strategyInfo[adapter].exists) {
            revert InvalidStrategy(adapter);
        }
        IStrategyAdapter(adapter).setPaused(paused_);
        emit AdapterPauseUpdated(adapter, paused_);
    }

    /// @notice Batch set adapter pause state via controller.
    /// @dev Controller must hold PAUSER_ROLE on each target adapter.
    function setAdaptersPaused(address[] calldata adapters, bool paused_)
        external
        onlyRole(STRATEGY_MANAGER_ROLE)
        nonReentrant
    {
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
    function rebalance() external onlyRole(EXECUTOR_ROLE) nonReentrant {
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

        if (freeCash > targetCash + threshold) {
            _invest(freeCash - targetCash);
        } else if (freeCash + threshold < targetCash) {
            _divest(targetCash - freeCash);
        }

        lastRebalance = uint64(block.timestamp);
    }

    /// @notice Move request batch into PROCESSING and trigger divest if free cash is insufficient.
    function processRedeemBatch(uint256[] calldata ids, uint256 batchTotalAsset)
        external
        onlyRole(EXECUTOR_ROLE)
        nonReentrant
    {
        _validateSortedIds(ids);

        bytes32 batchKey = _batchKey(ids);
        if (processingBatchDone[batchKey]) {
            revert BatchAlreadyProcessed(batchKey);
        }

        vault.updateRequestBatch(ids, IMantleYieldVault.RequestStatus.PROCESSING);
        processingBatchDone[batchKey] = true;

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

    /// @notice Finalize redeem batch: mark requests READY after PROCESSING.
    /// @dev Settlement actions (sweep/confirm in-flight) are handled by settleAdapter/settleAdapters.
    function finalizeRedeemBatch(uint256[] calldata ids) external onlyRole(EXECUTOR_ROLE) nonReentrant {
        _validateSortedIds(ids);
        bytes32 batchKey = _batchKey(ids);
        _ensureBatchReadyAllowed(batchKey);
        _markBatchReady(ids, batchKey);
    }

    /// @notice Unified settlement entrypoint for adapter sweep + in-flight confirmations.
    function settleAdapter(
        address adapter,
        uint256 posAmount,
        uint256 assetAmount,
        uint256[] calldata investInFlightIds,
        uint256[] calldata redeemInFlightIds
    ) external onlyRole(EXECUTOR_ROLE) nonReentrant {
        if (
            posAmount > 0 && vault.adapterInvestInFlightTokens(adapter) > 0
                && !_hasPendingInvestInFlightForAdapter(adapter, investInFlightIds)
        ) {
            revert InvestInFlightIdsRequired(adapter);
        }
        if (
            assetAmount > 0 && vault.adapterRedeemInFlightUsdc(adapter) > 0
                && !_hasPendingRedeemInFlightForAdapter(adapter, redeemInFlightIds)
        ) {
            revert RedeemInFlightIdsRequired(adapter);
        }

        _sweepAdapterAssetsToVaultInternal(adapter, posAmount, assetAmount);
        _confirmInvestInFlightIds(adapter, investInFlightIds);
        _confirmRedeemInFlightIds(redeemInFlightIds, adapter);
    }

    /// @notice Multi-adapter settlement in a single transaction.
    /// @dev Sweeps by adapter and confirms invest/redeem in-flight.
    function settleAdapters(
        address[] calldata adapters,
        uint256[] calldata posAmounts,
        uint256[] calldata assetAmounts,
        uint256[] calldata investInFlightIds,
        uint256[] calldata redeemInFlightIds
    ) external onlyRole(EXECUTOR_ROLE) nonReentrant {
        uint256 len = adapters.length;
        if (len != posAmounts.length || len != assetAmounts.length) {
            revert ClaimInputsLengthMismatch();
        }

        for (uint256 i = 0; i < len; i++) {
            address adapter = adapters[i];
            uint256 posAmount = posAmounts[i];
            uint256 assetAmount = assetAmounts[i];

            if (
                posAmount > 0 && vault.adapterInvestInFlightTokens(adapter) > 0
                    && !_hasPendingInvestInFlightForAdapter(adapter, investInFlightIds)
            ) {
                revert InvestInFlightIdsRequired(adapter);
            }
            if (
                assetAmount > 0 && vault.adapterRedeemInFlightUsdc(adapter) > 0
                    && !_hasPendingRedeemInFlightForAdapter(adapter, redeemInFlightIds)
            ) {
                revert RedeemInFlightIdsRequired(adapter);
            }

            _sweepAdapterAssetsToVaultInternal(adapter, posAmount, assetAmount);
        }

        _confirmInvestInFlightIdsForAdapters(adapters, investInFlightIds);
        _confirmRedeemInFlightIdsForAdapters(adapters, redeemInFlightIds);
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
        netAssets = totalCash + _totalStrategyValue() + vault.totalInvestInFlight() + vault.totalRedeemInFlight();
        targetCash = (netAssets * bufferTargetBps) / BPS_DENOMINATOR;
        threshold = (netAssets * rebalanceThresholdBps) / BPS_DENOMINATOR;
    }

    function _freeCash() internal view returns (uint256) {
        return vault.getFreeCash();
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
        uint256 totalAssets = asset.balanceOf(address(vault)) + _totalStrategyValue() + vault.totalInvestInFlight()
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
            // Approximate pending async invest coverage in pos-token units and only invest the uncovered delta.
            if (info.isAsync) {
                uint256 originalAlloc = alloc;
                uint256 pendingInvestPos = vault.adapterInvestInFlightTokens(adapter);
                if (pendingInvestPos > 0) {
                    uint256 estimatedPosForAlloc = _estimatePosAmount(adapter, alloc, alloc);
                    if (pendingInvestPos >= estimatedPosForAlloc) {
                        emit InvestSkipped(adapter, originalAlloc);
                        continue;
                    }

                    alloc = Math.mulDiv(originalAlloc, estimatedPosForAlloc - pendingInvestPos, estimatedPosForAlloc);
                    if (alloc == 0) {
                        emit InvestSkipped(adapter, originalAlloc);
                        continue;
                    }
                }
            }

            vault.approveToAdapter(adapter, address(asset), alloc);
            try IStrategyAdapter(adapter).deposit(alloc, adapter) returns (uint256 sharesOrPos) {
                if (info.isAsync) {
                    uint256 posAmount = _estimatePosAmount(adapter, alloc, sharesOrPos);
                    if (posAmount == 0) {
                        posAmount = alloc;
                    }
                    if (posAmount != 0) {
                        address token = _posToken(adapter);
                        vault.createInFlight(adapter, token, posAmount, alloc, true);
                    }
                }

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
            if (info.isAsync) {
                address token = _posToken(adapter);
                if (token == address(0)) {
                    emit DivestSkipped(adapter, toWithdrawAsset);
                    continue;
                }

                // Prevent duplicate async requests on repeated rebalance:
                // only request the delta that is not already in redeem in-flight for this adapter.
                uint256 pendingRedeemAsset = vault.adapterRedeemInFlightUsdc(adapter);
                uint256 coveredByPending = pendingRedeemAsset >= toWithdrawAsset ? toWithdrawAsset : pendingRedeemAsset;
                uint256 requestAsset = toWithdrawAsset - coveredByPending;
                if (requestAsset == 0) {
                    remaining -= toWithdrawAsset;
                    continue;
                }

                // Convert asset amount into position-token amount for protocol redeem.
                uint256 posAmount = _estimatePosAmount(adapter, requestAsset, requestAsset);
                if (posAmount == 0) {
                    posAmount = requestAsset;
                }

                vault.approveToAdapter(adapter, token, posAmount);
                try IStrategyAdapter(adapter).requestRedeemAsync(requestAsset, adapter) {}
                catch {
                    vault.approveToAdapter(adapter, token, 0);
                    emit DivestSkipped(adapter, requestAsset);
                    continue;
                }
                vault.approveToAdapter(adapter, token, 0);

                uint256 inFlightId = vault.createInFlight(adapter, token, posAmount, requestAsset, false);
                emit AsyncRedeemRequested(adapter, requestAsset, inFlightId);
                remaining -= (coveredByPending + requestAsset);
                continue;
            }

            try IStrategyAdapter(adapter).withdrawSync(toWithdrawAsset, address(vault)) returns (uint256 received) {
                emit DivestExecuted(adapter, toWithdrawAsset, received);
                if (received >= remaining) {
                    remaining = 0;
                } else {
                    remaining -= received;
                }
            } catch {
                emit DivestSkipped(adapter, toWithdrawAsset);
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

    function _confirmRedeemInFlightIds(uint256[] calldata inFlightIds, address expectedAdapter)
        internal
        returns (uint256 clearedAmount)
    {
        uint256 len = inFlightIds.length;
        for (uint256 i = 0; i < len; i++) {
            uint256 inFlightId = inFlightIds[i];
            (, address recordAdapter,,, uint256 usdcAmount,, bool isInvest,, IMantleYieldVault.InFlightStatus status) =
                vault.inFlightRecords(inFlightId);
            bool adapterMismatch = expectedAdapter != address(0) && recordAdapter != expectedAdapter;
            if (adapterMismatch || isInvest || status != IMantleYieldVault.InFlightStatus.PENDING || usdcAmount == 0) {
                revert InvalidRedeemInFlight(inFlightId);
            }

            vault.confirmInFlight(inFlightId, usdcAmount, false);
            clearedAmount += usdcAmount;
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

    function _markBatchReady(uint256[] calldata ids, bytes32 batchKey) internal {
        (uint256 required, uint256[] memory settledAssets) = _batchRequiredAssets(ids);
        uint256 available = asset.balanceOf(address(vault));
        if (available < required) {
            revert InsufficientCashForReady(required, available);
        }

        vault.markRequestsDone(ids, settledAssets);
        readyBatchDone[batchKey] = true;
        emit RedeemBatchReady(ids.length, required);
    }

    function _confirmInvestInFlightIds(address adapter, uint256[] calldata investInFlightIds) internal {
        uint256 len = investInFlightIds.length;
        for (uint256 i = 0; i < len; i++) {
            uint256 inFlightId = investInFlightIds[i];
            (, address recordAdapter,, uint256 tokenAmount,,, bool isInvest,, IMantleYieldVault.InFlightStatus status) =
                vault.inFlightRecords(inFlightId);
            if (
                recordAdapter != adapter || !isInvest || status != IMantleYieldVault.InFlightStatus.PENDING
                    || tokenAmount == 0
            ) {
                revert InvalidInvestInFlight(inFlightId);
            }

            // Invest in-flight settledAmount represents actually received position token amount.
            vault.confirmInFlight(inFlightId, tokenAmount, false);
        }
    }

    function _confirmInvestInFlightIdsForAdapters(address[] calldata adapters, uint256[] calldata investInFlightIds)
        internal
    {
        uint256 len = investInFlightIds.length;
        for (uint256 i = 0; i < len; i++) {
            uint256 inFlightId = investInFlightIds[i];
            (, address recordAdapter,, uint256 tokenAmount,,, bool isInvest,, IMantleYieldVault.InFlightStatus status) =
                vault.inFlightRecords(inFlightId);
            if (
                !_containsAdapter(adapters, recordAdapter) || !isInvest
                    || status != IMantleYieldVault.InFlightStatus.PENDING || tokenAmount == 0
            ) {
                revert InvalidInvestInFlight(inFlightId);
            }

            vault.confirmInFlight(inFlightId, tokenAmount, false);
        }
    }

    function _confirmRedeemInFlightIdsForAdapters(address[] calldata adapters, uint256[] calldata redeemInFlightIds)
        internal
        returns (uint256 clearedAmount)
    {
        uint256 len = redeemInFlightIds.length;
        for (uint256 i = 0; i < len; i++) {
            uint256 inFlightId = redeemInFlightIds[i];
            (, address recordAdapter,,, uint256 usdcAmount,, bool isInvest,, IMantleYieldVault.InFlightStatus status) =
                vault.inFlightRecords(inFlightId);
            if (
                !_containsAdapter(adapters, recordAdapter) || isInvest
                    || status != IMantleYieldVault.InFlightStatus.PENDING || usdcAmount == 0
            ) {
                revert InvalidRedeemInFlight(inFlightId);
            }

            vault.confirmInFlight(inFlightId, usdcAmount, false);
            clearedAmount += usdcAmount;
        }
    }

    function _hasPendingInvestInFlightForAdapter(address adapter, uint256[] calldata investInFlightIds)
        internal
        view
        returns (bool found)
    {
        uint256 len = investInFlightIds.length;
        for (uint256 i = 0; i < len; i++) {
            uint256 inFlightId = investInFlightIds[i];
            (, address recordAdapter,, uint256 tokenAmount,,, bool isInvest,, IMantleYieldVault.InFlightStatus status) =
                vault.inFlightRecords(inFlightId);
            if (
                recordAdapter == adapter && isInvest && status == IMantleYieldVault.InFlightStatus.PENDING
                    && tokenAmount > 0
            ) {
                return true;
            }
        }
        return false;
    }

    function _hasPendingRedeemInFlightForAdapter(address adapter, uint256[] calldata redeemInFlightIds)
        internal
        view
        returns (bool found)
    {
        uint256 len = redeemInFlightIds.length;
        for (uint256 i = 0; i < len; i++) {
            uint256 inFlightId = redeemInFlightIds[i];
            (, address recordAdapter,,, uint256 usdcAmount,, bool isInvest,, IMantleYieldVault.InFlightStatus status) =
                vault.inFlightRecords(inFlightId);
            if (
                recordAdapter == adapter && !isInvest && status == IMantleYieldVault.InFlightStatus.PENDING
                    && usdcAmount > 0
            ) {
                return true;
            }
        }
        return false;
    }

    function _containsAdapter(address[] calldata adapters, address adapter) internal pure returns (bool found) {
        uint256 len = adapters.length;
        for (uint256 i = 0; i < len; i++) {
            if (adapters[i] == adapter) {
                return true;
            }
        }
        return false;
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

    function _batchRequiredAssets(uint256[] calldata ids)
        internal
        view
        returns (uint256 required, uint256[] memory settledAssets)
    {
        settledAssets = new uint256[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            (,,, uint256 estimatedAssets_, uint256 settledAssets_,, IMantleYieldVault.RequestStatus status) =
                vault.requests(ids[i]);
            if (status != IMantleYieldVault.RequestStatus.PROCESSING && status != IMantleYieldVault.RequestStatus.DONE)
            {
                revert InvalidRequestState(ids[i], status);
            }

            // Before READY, request.settledAssets is usually 0. Use estimatedAssets as default settlement.
            uint256 effectiveSettled = settledAssets_ == 0 ? estimatedAssets_ : settledAssets_;
            settledAssets[i] = effectiveSettled;
            required += effectiveSettled;
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
