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
    bytes32 public constant OPERATOR_MANAGER_ROLE = keccak256("OPERATOR_MANAGER_ROLE");

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

    uint256[] public pendingRedeemInFlightIds;
    uint256 public nextPendingRedeemIndex;

    event StrategyRegistered(
        address indexed adapter, uint16 targetWeightBps, uint16 priority, bool isAsync, bool isActive
    );
    event StrategyUpdated(
        address indexed adapter, uint16 targetWeightBps, uint16 priority, bool isAsync, bool isActive
    );
    event StrategyOrderUpdated(address[] orderedStrategies);
    event RebalanceEvaluated(
        uint256 totalCash,
        uint256 lockedLiabilities,
        uint256 freeCash,
        uint256 netAssets,
        uint256 targetCash,
        uint256 threshold
    );
    event InvestExecuted(address indexed adapter, uint256 amountUSDC, uint256 sharesOrPos);
    event InvestSkipped(address indexed adapter, uint256 amountUSDC);
    event DivestExecuted(address indexed adapter, uint256 requestedUSDC, uint256 receivedUSDC);
    event DivestSkipped(address indexed adapter, uint256 requestedUSDC);
    event AsyncRedeemRequested(address indexed adapter, uint256 amountUSDC, uint256 inFlightId);
    event DivestIncomplete(uint256 remainingUSDC);
    event RedeemBatchProcessing(uint256 indexed batchSize, uint256 batchTotalUSDC, uint256 shortfallUSDC);
    event RedeemBatchReady(uint256 indexed batchSize, uint256 requiredUSDC, uint256 clearedInFlightUSDC);

    error InvalidAddress();
    error InvalidBps();
    error CooldownNotElapsed();
    error InvalidStrategy(address adapter);
    error StrategyInactive(address adapter);
    error WeightsMustBe10000(uint256 actualTotalWeight);
    error InsufficientCashForReady(uint256 required, uint256 available);
    error DuplicateStrategyInOrder(address adapter);
    error BatchAlreadyProcessed(bytes32 batchKey);
    error BatchNotProcessed(bytes32 batchKey);
    error BatchAlreadyReady(bytes32 batchKey);
    error IdsNotSorted();
    error InvalidRequestState(uint256 id, RequestStatus status);
    error InFlightInsufficient(uint256 remaining);
    error InFlightAmountMismatch(uint256 provided, uint256 expected);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address vault_,
        address admin,
        address operator,
        address executor,
        uint16 bufferTargetBps_,
        uint16 rebalanceThresholdBps_,
        uint64 rebalanceCooldown_
    ) external initializer {
        if (vault_ == address(0) || admin == address(0) || executor == address(0)) {
            revert InvalidAddress();
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
        _grantRole(OPERATOR_MANAGER_ROLE, operator);
        _grantRole(EXECUTOR_ROLE, executor);
    }

    function strategyOrderLength() external view returns (uint256) {
        return strategyOrder.length;
    }

    function setRiskParams(uint16 bufferTargetBps_, uint16 rebalanceThresholdBps_, uint64 rebalanceCooldown_)
        external
        onlyRole(OPERATOR_MANAGER_ROLE)
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
    ) external onlyRole(OPERATOR_MANAGER_ROLE) {
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
    ) external onlyRole(OPERATOR_MANAGER_ROLE) {
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

    function setStrategyOrder(address[] calldata orderedStrategies) external onlyRole(OPERATOR_MANAGER_ROLE) {
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
                revert InvalidStrategy(adapter);
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

    function processRedeemBatch(uint256[] calldata ids, uint256 batchTotalUSDC)
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
        if (freeCash < batchTotalUSDC) {
            shortfall = batchTotalUSDC - freeCash;
            _divest(shortfall);
        }

        emit RedeemBatchProcessing(ids.length, batchTotalUSDC, shortfall);
    }

    function allocateAssetsBatch(uint256[] calldata ids, uint256 clearedInFlightAmount)
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

        if (clearedInFlightAmount > 0) {
            _confirmRedeemInFlight(clearedInFlightAmount);
        }

        uint256 required = _batchRequiredAssets(ids);
        uint256 available = asset.balanceOf(address(vault));
        if (available < required) {
            revert InsufficientCashForReady(required, available);
        }

        vault.markRequestsReady(ids);
        readyBatchDone[batchKey] = true;
        emit RedeemBatchReady(ids.length, required, clearedInFlightAmount);
    }

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

    function _invest(uint256 excessCash) internal {
        uint256 len = strategyOrder.length;
        for (uint256 i = 0; i < len; i++) {
            address adapter = strategyOrder[i];
            StrategyInfo memory info = strategyInfo[adapter];
            if (!info.isActive) {
                continue;
            }

            uint256 alloc = (excessCash * info.targetWeightBps) / BPS_DENOMINATOR;
            if (alloc == 0) {
                continue;
            }

            vault.approveToAdapter(adapter, address(asset), alloc);
            try IStrategyAdapter(adapter).deposit(alloc, info.receiptReceiver) returns (uint256 sharesOrPos) {
                emit InvestExecuted(adapter, alloc, sharesOrPos);
            } catch {
                emit InvestSkipped(adapter, alloc);
            }
            vault.approveToAdapter(adapter, address(asset), 0);
        }
    }

    function _divest(uint256 shortfallUSDC) internal {
        uint256 remaining = shortfallUSDC;
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

            uint256 toWithdraw = remaining < value ? remaining : value;
            if (info.isAsync) {
                uint256 inFlightId = vault.createInFlight(adapter, address(asset), 0, toWithdraw, false);
                pendingRedeemInFlightIds.push(inFlightId);
                emit AsyncRedeemRequested(adapter, toWithdraw, inFlightId);
                remaining -= toWithdraw;
                continue;
            }

            try IStrategyAdapter(adapter).withdrawSync(toWithdraw, address(vault)) returns (uint256 received) {
                emit DivestExecuted(adapter, toWithdraw, received);
                if (received >= remaining) {
                    remaining = 0;
                } else {
                    remaining -= received;
                }
            } catch {
                emit DivestSkipped(adapter, toWithdraw);
            }
        }

        if (remaining > 0) {
            emit DivestIncomplete(remaining);
        }
    }

    function _confirmRedeemInFlight(uint256 clearedInFlightAmount) internal {
        uint256 remaining = clearedInFlightAmount;
        uint256 index = nextPendingRedeemIndex;

        while (remaining > 0) {
            if (index >= pendingRedeemInFlightIds.length) {
                revert InFlightInsufficient(remaining);
            }

            uint256 inFlightId = pendingRedeemInFlightIds[index];
            (,,,, uint256 usdcAmount,, bool isInvest,, InFlightStatus status) = vault.inFlightRecords(inFlightId);

            if (isInvest || status != InFlightStatus.PENDING) {
                index++;
                continue;
            }

            if (remaining < usdcAmount) {
                revert InFlightAmountMismatch(remaining, usdcAmount);
            }

            vault.confirmInFlight(inFlightId, usdcAmount);
            remaining -= usdcAmount;
            index++;
        }

        nextPendingRedeemIndex = index;
    }

    function _batchRequiredAssets(uint256[] calldata ids) internal view returns (uint256 required) {
        for (uint256 i = 0; i < ids.length; i++) {
            (,,, uint256 assets_,, RequestStatus status) = vault.requests(ids[i]);
            if (status != RequestStatus.PROCESSING && status != RequestStatus.READY) {
                revert InvalidRequestState(ids[i], status);
            }
            required += assets_;
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
