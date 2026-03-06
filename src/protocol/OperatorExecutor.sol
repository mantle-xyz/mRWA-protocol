// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategyController} from "../interfaces/strategy/IStrategyController.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/**
 * @notice Operator gateway with EIP-712 signed command execution.
 * @dev Grant this contract EXECUTOR_ROLE on StrategyController after deployment.
 */
contract OperatorExecutor is Initializable, AccessControlUpgradeable, EIP712Upgradeable {
    using ECDSA for bytes32;

    bytes32 public constant SIGNER_ROLE = keccak256("SIGNER_ROLE");

    bytes32 public constant COMMAND_TYPEHASH =
        keccak256("Command(uint8 action,bytes32 dataHash,uint256 nonce,uint64 deadline)");

    uint8 public constant ACTION_REBALANCE = 0;
    uint8 public constant ACTION_PROCESS_REDEEM_BATCH = 1;
    uint8 public constant ACTION_ALLOCATE_ASSETS_BATCH = 2;

    IStrategyController public controller;

    mapping(address => uint256) public nonces;

    struct Command {
        uint8 action;
        bytes data;
        uint256 nonce;
        uint64 deadline;
    }

    event CommandExecuted(
        address indexed signer, address indexed relayer, uint8 indexed action, uint256 nonce, bytes32 commandHash
    );
    event SignerUpdated(address indexed signer, bool allowed);

    error InvalidAddress();
    error DeadlineExpired(uint64 deadline, uint256 blockTs);
    error InvalidSignature();
    error InvalidNonce(address signer, uint256 expected, uint256 provided);
    error InvalidAction(uint8 action);

    constructor() {
        _disableInitializers();
    }

    function initialize(address controller_, address admin, address initialSigner) external initializer {
        if (controller_ == address(0) || admin == address(0) || initialSigner == address(0)) {
            revert InvalidAddress();
        }

        __AccessControl_init();
        __EIP712_init("OperatorExecutor", "1");

        controller = IStrategyController(controller_);

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

    function execute(Command calldata command, bytes calldata signature) external {
        if (command.deadline != 0 && block.timestamp > command.deadline) {
            revert DeadlineExpired(command.deadline, block.timestamp);
        }

        bytes32 commandHash = _hashTypedDataV4(
            keccak256(
                abi.encode(COMMAND_TYPEHASH, command.action, keccak256(command.data), command.nonce, command.deadline)
            )
        );
        address signer = commandHash.recover(signature);
        if (!hasRole(SIGNER_ROLE, signer)) {
            revert InvalidSignature();
        }

        uint256 expectedNonce = nonces[signer];
        if (command.nonce != expectedNonce) {
            revert InvalidNonce(signer, expectedNonce, command.nonce);
        }
        nonces[signer] = expectedNonce + 1;

        if (command.action == ACTION_REBALANCE) {
            controller.rebalance();
        } else if (command.action == ACTION_PROCESS_REDEEM_BATCH) {
            (uint256[] memory ids, uint256 batchTotalUSDC) = abi.decode(command.data, (uint256[], uint256));
            controller.processRedeemBatch(ids, batchTotalUSDC);
        } else if (command.action == ACTION_ALLOCATE_ASSETS_BATCH) {
            (uint256[] memory ids, uint256 clearedInFlightAmount) = abi.decode(command.data, (uint256[], uint256));
            controller.allocateAssetsBatch(ids, clearedInFlightAmount);
        } else {
            revert InvalidAction(command.action);
        }

        emit CommandExecuted(signer, msg.sender, command.action, command.nonce, commandHash);
    }
}
