// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategyAdapter} from "../interfaces/adapters/IStrategyAdapter.sol";
import {IControllerVault} from "../interfaces/vault/IControllerVault.sol";
import {InFlightStatus, RequestStatus} from "../interfaces/vault/types/VaultTypes.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract StrategyController is Initializable, AccessControlUpgradeable, ReentrancyGuard {
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 public constant STRATEGY_MANAGER_ROLE = keccak256("STRATEGY_MANAGER_ROLE");

    uint256 public constant BPS_DENOMINATOR = 10_000;

    IERC20 public asset;
    IControllerVault public vault;

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
        address receiptReceiver;
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
    event RedeemBatchReady(uint256 indexed batchSize, uint256 requiredAsset, uint256 clearedInFlightAsset);
    event AdapterAssetsClaimed(
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
    error InvalidRequestState(uint256 id, RequestStatus status);
    error InvalidRedeemInFlight(uint256 inFlightId);

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

        vault = IControllerVault(vault_);
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
    }

    function registerStrategy(
        address adapter,
        uint16 targetWeightBps,
        uint16 priority,
        bool isAsync,
        bool isActive,
        address receiptReceiver
    ) external onlyRole(STRATEGY_MANAGER_ROLE) {
        if (adapter == address(0) || receiptReceiver == address(0)) {
            revert InvalidAddress();
        }
        if (targetWeightBps > BPS_DENOMINATOR) {
            revert InvalidBps();
        }
        if (strategyInfo[adapter].exists) {
            revert InvalidStrategy(adapter);
        }

        strategyInfo[adapter] = StrategyInfo({
            targetWeightBps: targetWeightBps,
            priority: priority,
            isAsync: isAsync,
            isActive: isActive,
            exists: true,
            receiptReceiver: receiptReceiver
        });

        emit StrategyRegistered(adapter, targetWeightBps, priority, isAsync, isActive);
    }

    function updateStrategy(
        address adapter,
        uint16 targetWeightBps,
        uint16 priority,
        bool isAsync,
        bool isActive,
        address receiptReceiver
    ) external onlyRole(STRATEGY_MANAGER_ROLE) {
        if (targetWeightBps > BPS_DENOMINATOR) {
            revert InvalidBps();
        }
        if (receiptReceiver == address(0)) {
            revert InvalidAddress();
        }
        if (!strategyInfo[adapter].exists) {
            revert InvalidStrategy(adapter);
        }

        StrategyInfo storage info = strategyInfo[adapter];
        info.targetWeightBps = targetWeightBps;
        info.priority = priority;
        info.isAsync = isAsync;
        info.isActive = isActive;
        info.receiptReceiver = receiptReceiver;

        emit StrategyUpdated(adapter, targetWeightBps, priority, isAsync, isActive);
    }

    function setStrategyOrder(address[] calldata orderedStrategies) external onlyRole(STRATEGY_MANAGER_ROLE) {
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

    function rebalance() external onlyRole(EXECUTOR_ROLE) nonReentrant {
        if (block.timestamp < uint256(lastRebalance) + uint256(rebalanceCooldown)) {
            revert CooldownNotElapsed();
        }

        (uint256 totalCash, uint256 locked, uint256 freeCash, uint256 netAssets, uint256 targetCash, uint256 threshold)
        = _readRebalanceState();
        emit RebalanceEvaluated(totalCash, locked, freeCash, netAssets, targetCash, threshold);

        if (freeCash > targetCash + threshold) {
            _invest(freeCash - targetCash);
        } else if (freeCash + threshold < targetCash) {
            _divest(targetCash - freeCash);
        }

        lastRebalance = uint64(block.timestamp);
    }

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
        processingBatchDone[batchKey] = true;

        vault.updateRequestBatch(ids, RequestStatus.PROCESSING);

        uint256 freeCash = _freeCash();
        uint256 shortfall;
        if (freeCash < batchTotalAsset) {
            shortfall = batchTotalAsset - freeCash;
            _divest(shortfall);
        }

        emit RedeemBatchProcessing(ids.length, batchTotalAsset, shortfall);
    }

    // =============================================================
    // Business - Redemption Pipeline
    // =============================================================

    function allocateAssetsBatch(uint256[] calldata ids, uint256[] calldata inFlightIds)
        external
        onlyRole(EXECUTOR_ROLE)
        nonReentrant
    {
        _validateSortedIds(ids);

        bytes32 batchKey = _batchKey(ids);
        if (!processingBatchDone[batchKey]) {
            revert BatchNotProcessed(batchKey);
        }
        if (readyBatchDone[batchKey]) {
            revert BatchAlreadyReady(batchKey);
        }

        uint256 clearedInFlightAmount = _confirmRedeemInFlightIds(inFlightIds);

        (uint256 required, uint256[] memory settledAssets) = _batchRequiredAssets(ids);
        uint256 available = asset.balanceOf(address(vault));
        if (available < required) {
            revert InsufficientCashForReady(required, available);
        }

        vault.markRequestsReady(ids, settledAssets);
        readyBatchDone[batchKey] = true;
        emit RedeemBatchReady(ids.length, required, clearedInFlightAmount);
    }

    /// @notice Pull settled assets from adapter back to Vault (operator-driven, event-listener flow).
    function claimAdapterAssets(address adapter, uint256 posAmount, uint256 assetAmount)
        external
        onlyRole(EXECUTOR_ROLE)
        nonReentrant
    {
        StrategyInfo memory info = strategyInfo[adapter];
        if (!info.exists) {
            revert InvalidStrategy(adapter);
        }

        address token = _posToken(adapter);
        uint256 posClaimed;
        uint256 assetClaimed;

        if (token != address(0) && posAmount > 0) {
            posClaimed = IStrategyAdapter(adapter).claimToVault(token, posAmount);
        }
        if (assetAmount > 0) {
            assetClaimed = IStrategyAdapter(adapter).claimToVault(address(asset), assetAmount);
        }

        emit AdapterAssetsClaimed(adapter, token, posClaimed, assetClaimed);
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
        locked = vault.totalLockedLiabilities();
        freeCash = totalCash > locked ? totalCash - locked : 0;
        netAssets = totalCash + _totalStrategyValue() + vault.totalInvestInFlight() + vault.totalRedeemInFlight();
        targetCash = (netAssets * bufferTargetBps) / BPS_DENOMINATOR;
        threshold = (netAssets * rebalanceThresholdBps) / BPS_DENOMINATOR;
    }

    function _freeCash() internal view returns (uint256) {
        uint256 totalCash = asset.balanceOf(address(vault));
        uint256 locked = vault.totalLockedLiabilities();
        return totalCash > locked ? totalCash - locked : 0;
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

            vault.approveToAdapter(adapter, address(asset), alloc);
            try IStrategyAdapter(adapter).deposit(alloc, info.receiptReceiver) returns (uint256 sharesOrPos) {
                if (info.isAsync) {
                    uint256 posAmount = _estimatePosAmount(adapter, alloc, sharesOrPos);
                    if (posAmount > 0) {
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

                // Convert asset amount into position-token amount for protocol redeem.
                uint256 posAmount = _estimatePosAmount(adapter, toWithdrawAsset, toWithdrawAsset);
                if (posAmount == 0) {
                    posAmount = toWithdrawAsset;
                }

                vault.approveToAdapter(adapter, token, posAmount);
                try IStrategyAdapter(adapter).requestRedeemAsync(toWithdrawAsset, address(vault)) {}
                catch {
                    vault.approveToAdapter(adapter, token, 0);
                    emit DivestSkipped(adapter, toWithdrawAsset);
                    continue;
                }
                vault.approveToAdapter(adapter, token, 0);

                uint256 inFlightId = vault.createInFlight(adapter, token, posAmount, toWithdrawAsset, false);
                emit AsyncRedeemRequested(adapter, toWithdrawAsset, inFlightId);
                remaining -= toWithdrawAsset;
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

    function _confirmRedeemInFlightIds(uint256[] calldata inFlightIds) internal returns (uint256 clearedAmount) {
        uint256 len = inFlightIds.length;
        for (uint256 i = 0; i < len; i++) {
            uint256 inFlightId = inFlightIds[i];
            (,,,, uint256 usdcAmount,, bool isInvest,, InFlightStatus status) = vault.inFlightRecords(inFlightId);
            if (isInvest || status != InFlightStatus.PENDING || usdcAmount == 0) {
                revert InvalidRedeemInFlight(inFlightId);
            }

            vault.confirmInFlight(inFlightId, usdcAmount);
            clearedAmount += usdcAmount;
        }
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
            (,,, uint256 estimatedAssets_, uint256 settledAssets_,, RequestStatus status) = vault.requests(ids[i]);
            if (status != RequestStatus.PROCESSING && status != RequestStatus.READY) {
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
