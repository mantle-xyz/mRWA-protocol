// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISubRedManagement} from "../../interfaces/adapters/digift/ISubRedManagement.sol";
import {AdapterCall, AdapterCodec} from "../../libs/AdapterCodec.sol";
import {BaseAdapter} from "../base/BaseAdapter.sol";
import {SubRedCodec} from "./libs/SubRedCodec.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice Digift SubRed adapter (async-first) for subscribe/redeem orchestration.
 * @dev Controller allocates funds via Vault.approveToAdapter; bot finalizes async lifecycle via execute(payload).
 */
contract SubRedManagementAdapter is BaseAdapter {
    using SafeERC20 for IERC20;

    ISubRedManagement public immutable SUB_RED;
    address public immutable ST_TOKEN;

    uint64 public subscribeDeadlineWindow = 1 hours;
    uint256 public redeemNonce;

    mapping(bytes32 => uint256) public pendingRedeemUSDC;
    mapping(bytes32 => uint256) public claimableRedeemUSDC;

    event RedeemRequested(bytes32 indexed requestId, uint256 amountUSDC, address receiver);
    event RedeemFinalized(bytes32 indexed requestId, uint256 receivedUSDC);
    event SubscribeDeadlineWindowUpdated(uint64 newWindow);

    error InvalidAddress();
    error InvalidAmount();
    error InvalidArrayLength();
    error UnknownAction(uint8 action);
    error NoClaimable(bytes32 requestId);

    constructor(
        address usdc,
        address vault_,
        address subRedManagement,
        address stToken,
        address admin,
        address controller,
        address operator
    ) BaseAdapter(usdc, vault_, admin, controller, operator) {
        if (subRedManagement == address(0) || stToken == address(0)) {
            revert InvalidAddress();
        }
        SUB_RED = ISubRedManagement(subRedManagement);
        ST_TOKEN = stToken;
    }

    function name() external pure override returns (string memory) {
        return "SubRedManagementAdapter";
    }

    function totalValue() external view override returns (uint256) {
        return USDC.balanceOf(address(this));
    }

    function setSubscribeDeadlineWindow(uint64 newWindow) external onlyRole(DEFAULT_ADMIN_ROLE) {
        subscribeDeadlineWindow = newWindow;
        emit SubscribeDeadlineWindowUpdated(newWindow);
    }

    function deposit(uint256 amountUSDC, address) external override onlyController whenNotPaused returns (uint256) {
        if (amountUSDC == 0) {
            revert InvalidAmount();
        }
        // Pull from vault using temporary allowance opened by controller.
        USDC.safeTransferFrom(VAULT, address(this), amountUSDC);
        _subscribe(amountUSDC, uint64(block.timestamp + subscribeDeadlineWindow));
        return amountUSDC;
    }

    function redeemSync(uint256, address) external pure override returns (uint256) {
        revert Unsupported();
    }

    function requestRedeem(uint256 amountUSDC, address receiver)
        external
        override
        onlyController
        whenNotPaused
        returns (bytes32 requestId)
    {
        if (amountUSDC == 0 || receiver == address(0)) {
            revert InvalidAmount();
        }
        uint256 nonce = ++redeemNonce;
        requestId = keccak256(abi.encode(address(this), receiver, amountUSDC, nonce, block.chainid));
        pendingRedeemUSDC[requestId] = amountUSDC;
        emit RedeemRequested(requestId, amountUSDC, receiver);
    }

    function claimRedeem(bytes32 requestId, address receiver)
        external
        override
        onlyController
        whenNotPaused
        returns (uint256 actualUSDC)
    {
        if (receiver == address(0)) {
            revert InvalidAddress();
        }
        actualUSDC = claimableRedeemUSDC[requestId];
        if (actualUSDC == 0) {
            revert NoClaimable(requestId);
        }
        claimableRedeemUSDC[requestId] = 0;
        USDC.safeTransfer(receiver, actualUSDC);
    }

    function execute(bytes calldata payload)
        external
        override
        onlyOperator
        whenNotPaused
        nonReentrant
        returns (bytes32 execId)
    {
        AdapterCall memory c = AdapterCodec.decodeCall(payload);
        _checkCall(c);

        (uint8 action, bytes memory actionData) = SubRedCodec.decodeAction(c.data);
        bytes32 meta;

        if (action == SubRedCodec.ACTION_SUBSCRIBE) {
            SubRedCodec.SubscribeAction memory a = abi.decode(actionData, (SubRedCodec.SubscribeAction));
            _subscribe(a.amountUSDC, a.deadline);
            meta = bytes32(a.amountUSDC);
        } else if (action == SubRedCodec.ACTION_SETTLE_SUBSCRIBER) {
            SubRedCodec.SettleSubscriberAction memory a = abi.decode(actionData, (SubRedCodec.SettleSubscriberAction));
            _settleSubscriber(a);
            meta = bytes32(a.investorList.length);
        } else if (action == SubRedCodec.ACTION_FINALIZE_REDEEM) {
            SubRedCodec.FinalizeRedeemAction memory a = abi.decode(actionData, (SubRedCodec.FinalizeRedeemAction));
            uint256 pending = pendingRedeemUSDC[a.requestId];
            if (pending == 0 || a.receivedUSDC == 0) {
                revert InvalidAmount();
            }
            if (a.receivedUSDC > pending) {
                revert InvalidAmount();
            }

            pendingRedeemUSDC[a.requestId] = pending - a.receivedUSDC;
            claimableRedeemUSDC[a.requestId] += a.receivedUSDC;

            emit RedeemFinalized(a.requestId, a.receivedUSDC);
            meta = a.requestId;
        } else {
            revert UnknownAction(action);
        }

        execId = keccak256(abi.encode(address(this), msg.sender, action, c.salt, c.deadline, c.data));
        emit Execute(execId, action, meta);
    }

    function panic() external override onlyController {
        paused = true;
        emit Paused(true);
        USDC.forceApprove(address(SUB_RED), 0);
    }

    function _subscribe(uint256 amountUSDC, uint64 deadline) internal {
        if (amountUSDC == 0) {
            revert InvalidAmount();
        }
        USDC.forceApprove(address(SUB_RED), amountUSDC);
        SUB_RED.subscribe(ST_TOKEN, address(USDC), amountUSDC, deadline);
        USDC.forceApprove(address(SUB_RED), 0);
    }

    function _settleSubscriber(SubRedCodec.SettleSubscriberAction memory a) internal {
        uint256 len = a.investorList.length;
        if (
            len == 0 || len != a.quantityList.length || len != a.currencyTokenList.length || len != a.amountList.length
                || len != a.feeList.length
        ) {
            revert InvalidArrayLength();
        }

        SUB_RED.settleSubscriber(ST_TOKEN, a.investorList, a.quantityList, a.currencyTokenList, a.amountList, a.feeList);
    }
}
