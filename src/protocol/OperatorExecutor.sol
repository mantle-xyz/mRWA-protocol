// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategyControllerExecutor} from "../interfaces/strategy/IStrategyControllerExecutor.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @notice Operator gateway for StrategyController command execution.
 * @dev Grant this contract OPERATOR_EXECUTOR_ROLE on StrategyController after deployment.
 *      Only accounts holding BOT_ROLE can trigger commands.
 *      DEFAULT_ADMIN_ROLE manages BOT_ROLE membership and authorizes upgrades.
 */
contract OperatorExecutor is AccessControlUpgradeable, UUPSUpgradeable {
    // =============================================================
    //                        CONSTANTS
    // =============================================================

    bytes32 public constant BOT_ROLE = keccak256("BOT_ROLE");

    // =============================================================
    //                          EVENTS
    // =============================================================

    event RebalanceExecuted(address indexed operator, address indexed controller);
    event ProcessRedeemBatchExecuted(address indexed operator, address indexed controller, bytes32 idsHash);
    event FinalizeRedeemBatchExecuted(
        address indexed operator, address indexed controller, bytes32 idsHash, bytes32 settledAssetsHash
    );
    event SettleAdapterExecuted(address indexed operator, address indexed controller, address adapter);
    event SettleAdaptersExecuted(address indexed operator, address indexed controller, bytes32 adaptersHash);

    // =============================================================
    //                       CUSTOM ERRORS
    // =============================================================

    error OperatorExecutor__InvalidAddress();
    error OperatorExecutor__InvalidController(address controller);

    // =============================================================
    //                    CONSTRUCTOR / INITIALIZER
    // =============================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, address initialBot) external initializer {
        if (admin == address(0) || initialBot == address(0)) {
            revert OperatorExecutor__InvalidAddress();
        }

        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(BOT_ROLE, initialBot);
    }

    // =============================================================
    //                   EXTERNAL FUNCTIONS
    // =============================================================

    function executeRebalance(address controller_) external onlyRole(BOT_ROLE) {
        IStrategyControllerExecutor targetController = _controllerOf(controller_);
        targetController.rebalance();
        emit RebalanceExecuted(msg.sender, controller_);
    }

    function executeProcessRedeemBatch(address controller_, uint256[] calldata ids) external onlyRole(BOT_ROLE) {
        IStrategyControllerExecutor targetController = _controllerOf(controller_);
        targetController.processRedeemBatch(ids);
        emit ProcessRedeemBatchExecuted(msg.sender, controller_, keccak256(abi.encodePacked(ids)));
    }

    function executeFinalizeRedeemBatch(address controller_, uint256[] calldata ids, uint256[] calldata settledAssets)
        external
        onlyRole(BOT_ROLE)
    {
        IStrategyControllerExecutor targetController = _controllerOf(controller_);
        targetController.finalizeRedeemBatch(ids, settledAssets);
        emit FinalizeRedeemBatchExecuted(
            msg.sender, controller_, keccak256(abi.encodePacked(ids)), keccak256(abi.encodePacked(settledAssets))
        );
    }

    function executeSettleAdapter(
        address controller_,
        address adapter,
        IStrategyControllerExecutor.InvestSettlementInput calldata invest,
        IStrategyControllerExecutor.RedeemSettlementInput calldata redeem
    ) external onlyRole(BOT_ROLE) {
        IStrategyControllerExecutor targetController = _controllerOf(controller_);
        targetController.settleAdapter(adapter, invest, redeem);
        emit SettleAdapterExecuted(msg.sender, controller_, adapter);
    }

    function executeSettleAdapters(
        address controller_,
        address[] calldata adapters,
        IStrategyControllerExecutor.InvestSettlementInput[] calldata investBatch,
        IStrategyControllerExecutor.RedeemSettlementInput[] calldata redeemBatch
    ) external onlyRole(BOT_ROLE) {
        IStrategyControllerExecutor targetController = _controllerOf(controller_);
        targetController.settleAdapters(adapters, investBatch, redeemBatch);
        emit SettleAdaptersExecuted(msg.sender, controller_, keccak256(abi.encodePacked(adapters)));
    }

    // =============================================================
    //                     INTERNAL HELPERS
    // =============================================================

    function _controllerOf(address controller_) internal view returns (IStrategyControllerExecutor targetController) {
        if (controller_ == address(0)) {
            revert OperatorExecutor__InvalidAddress();
        }
        if (controller_.code.length == 0) {
            revert OperatorExecutor__InvalidController(controller_);
        }
        targetController = IStrategyControllerExecutor(controller_);
    }

    // =============================================================
    //                   UPGRADE AUTHORIZATION
    // =============================================================

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
