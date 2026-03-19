// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategyControllerExecutor} from "../interfaces/strategy/IStrategyControllerExecutor.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @notice Operator gateway with EIP-712 signed command execution.
 * @dev Grant this contract EXECUTOR_ROLE on StrategyController after deployment.
 */
contract OperatorExecutor is AccessControlUpgradeable, UUPSUpgradeable, EIP712Upgradeable {
    using ECDSA for bytes32;

    bytes32 public constant SIGNER_ROLE = keccak256("SIGNER_ROLE");

    bytes32 public constant REBALANCE_TYPEHASH =
        keccak256("Rebalance(address controller,uint256 nonce,uint64 deadline)");
    bytes32 public constant PROCESS_REDEEM_BATCH_TYPEHASH =
        keccak256("ProcessRedeemBatch(address controller,bytes32 idsHash,uint256 nonce,uint64 deadline)");
    bytes32 public constant FINALIZE_REDEEM_BATCH_TYPEHASH = keccak256(
        "FinalizeRedeemBatch(address controller,bytes32 idsHash,bytes32 settledAssetsHash,uint256 nonce,uint64 deadline)"
    );
    bytes32 public constant SETTLE_ADAPTER_TYPEHASH = keccak256(
        "SettleAdapter(address controller,address adapter,uint256 posAmount,uint256 assetAmount,bytes32 investInFlightIdsHash,bytes32 redeemInFlightIdsHash,uint256 nonce,uint64 deadline)"
    );
    bytes32 public constant SETTLE_ADAPTERS_TYPEHASH = keccak256(
        "SettleAdapters(address controller,bytes32 adaptersHash,bytes32 posAmountsHash,bytes32 assetAmountsHash,bytes32 investInFlightIdsHash,bytes32 redeemInFlightIdsHash,uint256 nonce,uint64 deadline)"
    );

    mapping(address => uint256) public nonces;

    event RebalanceExecuted(
        address indexed signer, address indexed relayer, address indexed controller, uint256 nonce, bytes32 commandHash
    );
    event ProcessRedeemBatchExecuted(
        address indexed signer,
        address indexed relayer,
        address indexed controller,
        uint256 nonce,
        bytes32 idsHash,
        bytes32 commandHash
    );
    event FinalizeRedeemBatchExecuted(
        address indexed signer,
        address indexed relayer,
        address indexed controller,
        uint256 nonce,
        bytes32 idsHash,
        bytes32 settledAssetsHash,
        bytes32 commandHash
    );
    event SettleAdapterExecuted(
        address indexed signer,
        address indexed relayer,
        address indexed controller,
        uint256 nonce,
        address adapter,
        uint256 posAmount,
        uint256 assetAmount,
        bytes32 investInFlightIdsHash,
        bytes32 redeemInFlightIdsHash,
        bytes32 commandHash
    );
    event SettleAdaptersExecuted(
        address indexed signer,
        address indexed relayer,
        address indexed controller,
        uint256 nonce,
        bytes32 adaptersHash,
        bytes32 posAmountsHash,
        bytes32 assetAmountsHash,
        bytes32 investInFlightIdsHash,
        bytes32 redeemInFlightIdsHash,
        bytes32 commandHash
    );
    event SignerUpdated(address indexed signer, bool allowed);

    error InvalidAddress();
    error InvalidController(address controller);
    error DeadlineExpired(uint64 deadline, uint256 blockTs);
    error InvalidSignature();
    error InvalidNonce(address signer, uint256 expected, uint256 provided);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, address initialSigner) external initializer {
        if (admin == address(0) || initialSigner == address(0)) {
            revert InvalidAddress();
        }

        __AccessControl_init();
        __EIP712_init("OperatorExecutor", "1");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(SIGNER_ROLE, initialSigner);
    }

    function setSigner(address signer, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (signer == address(0)) {
            revert InvalidAddress();
        }
        if (allowed) {
            _grantRole(SIGNER_ROLE, signer);
        } else {
            _revokeRole(SIGNER_ROLE, signer);
        }
        emit SignerUpdated(signer, allowed);
    }

    function executeRebalance(address controller_, uint256 nonce, uint64 deadline, bytes calldata signature) external {
        bytes32 structHash = keccak256(abi.encode(REBALANCE_TYPEHASH, controller_, nonce, deadline));
        (address signer, bytes32 commandHash) = _verifyAndConsume(structHash, nonce, deadline, signature);

        IStrategyControllerExecutor targetController = _controllerOf(controller_);
        targetController.rebalance();
        emit RebalanceExecuted(signer, msg.sender, controller_, nonce, commandHash);
    }

    function executeProcessRedeemBatch(
        address controller_,
        uint256[] calldata ids,
        uint256 nonce,
        uint64 deadline,
        bytes calldata signature
    ) external {
        bytes32 idsHash = _hashUint256Array(ids);
        bytes32 structHash = keccak256(abi.encode(PROCESS_REDEEM_BATCH_TYPEHASH, controller_, idsHash, nonce, deadline));
        (address signer, bytes32 commandHash) = _verifyAndConsume(structHash, nonce, deadline, signature);

        IStrategyControllerExecutor targetController = _controllerOf(controller_);
        targetController.processRedeemBatch(ids);
        emit ProcessRedeemBatchExecuted(signer, msg.sender, controller_, nonce, idsHash, commandHash);
    }

    function executeFinalizeRedeemBatch(
        address controller_,
        uint256[] calldata ids,
        uint256[] calldata settledAssets,
        uint256 nonce,
        uint64 deadline,
        bytes calldata signature
    ) external {
        bytes32 idsHash = _hashUint256Array(ids);
        bytes32 settledAssetsHash = _hashUint256Array(settledAssets);
        bytes32 structHash = keccak256(
            abi.encode(FINALIZE_REDEEM_BATCH_TYPEHASH, controller_, idsHash, settledAssetsHash, nonce, deadline)
        );
        (address signer, bytes32 commandHash) = _verifyAndConsume(structHash, nonce, deadline, signature);

        IStrategyControllerExecutor targetController = _controllerOf(controller_);
        targetController.finalizeRedeemBatch(ids, settledAssets);
        emit FinalizeRedeemBatchExecuted(
            signer, msg.sender, controller_, nonce, idsHash, settledAssetsHash, commandHash
        );
    }

    function executeSettleAdapter(
        address controller_,
        address adapter,
        uint256 posAmount,
        uint256 assetAmount,
        uint256[] calldata investInFlightIds,
        uint256[] calldata redeemInFlightIds,
        uint256 nonce,
        uint64 deadline,
        bytes calldata signature
    ) external {
        bytes32 investInFlightIdsHash = _hashUint256Array(investInFlightIds);
        bytes32 redeemInFlightIdsHash = _hashUint256Array(redeemInFlightIds);
        bytes32 structHash = keccak256(
            abi.encode(
                SETTLE_ADAPTER_TYPEHASH,
                controller_,
                adapter,
                posAmount,
                assetAmount,
                investInFlightIdsHash,
                redeemInFlightIdsHash,
                nonce,
                deadline
            )
        );
        (address signer, bytes32 commandHash) = _verifyAndConsume(structHash, nonce, deadline, signature);

        IStrategyControllerExecutor targetController = _controllerOf(controller_);
        targetController.settleAdapter(adapter, posAmount, assetAmount, investInFlightIds, redeemInFlightIds);
        emit SettleAdapterExecuted(
            signer,
            msg.sender,
            controller_,
            nonce,
            adapter,
            posAmount,
            assetAmount,
            investInFlightIdsHash,
            redeemInFlightIdsHash,
            commandHash
        );
    }

    function executeSettleAdapters(
        address controller_,
        address[] calldata adapters,
        uint256[] calldata posAmounts,
        uint256[] calldata assetAmounts,
        uint256[] calldata investInFlightIds,
        uint256[] calldata redeemInFlightIds,
        uint256 nonce,
        uint64 deadline,
        bytes calldata signature
    ) external {
        bytes32 adaptersHash = _hashAddressArray(adapters);
        bytes32 posAmountsHash = _hashUint256Array(posAmounts);
        bytes32 assetAmountsHash = _hashUint256Array(assetAmounts);
        bytes32 investInFlightIdsHash = _hashUint256Array(investInFlightIds);
        bytes32 redeemInFlightIdsHash = _hashUint256Array(redeemInFlightIds);
        bytes32 structHash = keccak256(
            abi.encode(
                SETTLE_ADAPTERS_TYPEHASH,
                controller_,
                adaptersHash,
                posAmountsHash,
                assetAmountsHash,
                investInFlightIdsHash,
                redeemInFlightIdsHash,
                nonce,
                deadline
            )
        );
        (address signer, bytes32 commandHash) = _verifyAndConsume(structHash, nonce, deadline, signature);

        IStrategyControllerExecutor targetController = _controllerOf(controller_);
        targetController.settleAdapters(adapters, posAmounts, assetAmounts, investInFlightIds, redeemInFlightIds);
        emit SettleAdaptersExecuted(
            signer,
            msg.sender,
            controller_,
            nonce,
            adaptersHash,
            posAmountsHash,
            assetAmountsHash,
            investInFlightIdsHash,
            redeemInFlightIdsHash,
            commandHash
        );
    }

    function _verifyAndConsume(bytes32 structHash, uint256 nonce, uint64 deadline, bytes calldata signature)
        internal
        returns (address signer, bytes32 commandHash)
    {
        _checkDeadline(deadline);

        commandHash = _hashTypedDataV4(structHash);
        signer = commandHash.recover(signature);
        if (!hasRole(SIGNER_ROLE, signer)) {
            revert InvalidSignature();
        }

        uint256 expectedNonce = nonces[signer];
        if (nonce != expectedNonce) {
            revert InvalidNonce(signer, expectedNonce, nonce);
        }
        nonces[signer] = expectedNonce + 1;
    }

    function _controllerOf(address controller_) internal view returns (IStrategyControllerExecutor targetController) {
        if (controller_ == address(0)) {
            revert InvalidAddress();
        }
        if (controller_.code.length == 0) {
            revert InvalidController(controller_);
        }
        targetController = IStrategyControllerExecutor(controller_);
    }

    function _checkDeadline(uint64 deadline) internal view {
        if (deadline != 0 && block.timestamp > deadline) {
            revert DeadlineExpired(deadline, block.timestamp);
        }
    }

    function _hashUint256Array(uint256[] calldata arr) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(arr));
    }

    function _hashAddressArray(address[] calldata arr) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(arr));
    }

    // =============================================================
    //                   UPGRADE AUTHORIZATION
    // =============================================================

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
