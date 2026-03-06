// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISubRedManagement} from "../../interfaces/adapters/digift/ISubRedManagement.sol";
import {AdapterCall, AdapterCodec} from "../../libs/AdapterCodec.sol";
import {BaseAdapter} from "../base/BaseAdapter.sol";
import {SubRedCodec} from "./libs/SubRedCodec.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Async-first adapter for Digift SubRed subscribe/redeem flow.
/// @dev Controller drives unified adapter methods; operator bot executes protocol-specific actions.
contract SubRedManagementAdapter is BaseAdapter {
    using SafeERC20 for IERC20;

    ISubRedManagement public immutable SUB_RED;
    address public immutable ST_TOKEN;

    uint64 public subscribeDeadlineWindow = 1 hours;
    uint256 public redeemNonce;

    /// @notice Requested redeem amount waiting for finalize.
    mapping(bytes32 => uint256) public pendingRedeemUSDC;
    /// @notice Finalized redeem amount claimable by controller.
    mapping(bytes32 => uint256) public claimableRedeemUSDC;

    event RedeemRequested(bytes32 indexed requestId, uint256 amountUSDC, address receiver);
    event RedeemFinalized(bytes32 indexed requestId, uint256 receivedUSDC);
    event SubscribeDeadlineWindowUpdated(uint64 newWindow);

    error InvalidAddress();
    error InvalidAmount();
    error InvalidArrayLength();
    error UnknownAction(uint8 action);
    error NoClaimable(bytes32 requestId);

    /**
     * @notice Initialize Digift SubRed adapter.
     * @param usdc Base asset used for subscribe/redeem settlement.
     * @param vault_ Vault that owns strategy funds.
     * @param subRedManagement Digift SubRedManagement contract.
     * @param stToken Target security token (e.g. iSNR).
     * @param admin Adapter admin role address.
     * @param controller StrategyController role address.
     * @param operator Operator role address for execute(payload).
     */
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

    /**
     * @notice Strategy display name.
     */
    function name() external pure override returns (string memory) {
        return "SubRedManagementAdapter";
    }

    /**
     * @notice Return current strategy value in USDC units.
     * @dev Conservative value; only idle USDC held by adapter.
     */
    function totalValue() external view override returns (uint256) {
        return USDC.balanceOf(address(this));
    }

    /**
     * @notice Update subscribe deadline window used by deposit().
     * @param newWindow New deadline window in seconds.
     * @dev Only callable by DEFAULT_ADMIN_ROLE.
     */
    function setSubscribeDeadlineWindow(uint64 newWindow) external onlyRole(DEFAULT_ADMIN_ROLE) {
        subscribeDeadlineWindow = newWindow;
        emit SubscribeDeadlineWindowUpdated(newWindow);
    }

    /**
     * @notice Pull funds from Vault and submit subscribe.
     * @param amountUSDC USDC amount to subscribe.
     * @param receiver Receiver parameter reserved by IStrategyAdapter.
     * @return Subscribed amount.
     * @dev Only callable by controller when not paused.
     */
    function deposit(uint256 amountUSDC, address receiver) external override onlyController whenNotPaused returns (uint256) {
        if (amountUSDC == 0) {
            revert InvalidAmount();
        }
        receiver;
        // Pull USDC from Vault using temporary allowance set by StrategyController.
        USDC.safeTransferFrom(VAULT, address(this), amountUSDC);
        _subscribe(amountUSDC, uint64(block.timestamp + subscribeDeadlineWindow));
        return amountUSDC;
    }

    /**
     * @notice Digift flow is async; sync redeem is not supported.
     */
    function withdrawSync(uint256, address) external pure override returns (uint256) {
        revert Unsupported();
    }

    /**
     * @notice Register an async redeem request.
     * @param amountUSDC Requested redeem amount.
     * @param receiver Final receiver used to derive deterministic requestId.
     * @return requestId Unique request key.
     * @dev Only callable by controller when not paused.
     */
    function requestRedeemAsync(uint256 amountUSDC, address receiver)
        external
        override
        onlyController
        whenNotPaused
        returns (bytes32 requestId)
    {
        if (amountUSDC == 0 || receiver == address(0)) {
            revert InvalidAmount();
        }
        // requestId is the async lifecycle key: request -> finalize -> claim.
        uint256 nonce = ++redeemNonce;
        requestId = keccak256(abi.encode(address(this), receiver, amountUSDC, nonce, block.chainid));
        pendingRedeemUSDC[requestId] = amountUSDC;
        emit RedeemRequested(requestId, amountUSDC, receiver);
    }

    /**
     * @notice Transfer finalized redeem proceeds to receiver.
     * @param requestId Redeem request identifier.
     * @param receiver Destination address for claimed USDC.
     * @return actualUSDC Claimed USDC amount.
     * @dev Only callable by controller when not paused.
     */
    function claimRedeem(bytes32 requestId, address receiver) external onlyController whenNotPaused returns (uint256 actualUSDC) {
        if (receiver == address(0)) {
            revert InvalidAddress();
        }
        // Only finalized amounts can be claimed.
        actualUSDC = claimableRedeemUSDC[requestId];
        if (actualUSDC == 0) {
            revert NoClaimable(requestId);
        }
        claimableRedeemUSDC[requestId] = 0;
        USDC.safeTransfer(receiver, actualUSDC);
    }

    /**
     * @notice Execute Digift-specific operator action.
     * @param payload AdapterCall envelope with action payload.
     * @return execId Deterministic execution id.
     * @dev Only callable by OPERATOR_ROLE when not paused.
     */
    function execute(bytes calldata payload)
        external
        override
        onlyOperator
        whenNotPaused
        nonReentrant
        returns (bytes32 execId)
    {
        // Validate shared envelope (deadline + optional replay salt).
        AdapterCall memory c = AdapterCodec.decodeCall(payload);
        _checkCall(c);

        // Route Digift-specific actions.
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

            // Move finalized amount from pending bucket to claimable bucket.
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

    /**
     * @notice Pause adapter and revoke SubRed allowance.
     * @dev Only callable by controller.
     */
    function panic() external override onlyController {
        paused = true;
        emit Paused(true);
        USDC.forceApprove(address(SUB_RED), 0);
    }

    /**
     * @notice Internal helper to call SubRed subscribe.
     * @param amountUSDC Amount to subscribe.
     * @param deadline Digift subscribe deadline.
     */
    function _subscribe(uint256 amountUSDC, uint64 deadline) internal {
        if (amountUSDC == 0) {
            revert InvalidAmount();
        }
        // Minimum-privilege approval: approve exact amount then reset.
        USDC.forceApprove(address(SUB_RED), amountUSDC);
        SUB_RED.subscribe(ST_TOKEN, address(USDC), amountUSDC, deadline);
        USDC.forceApprove(address(SUB_RED), 0);
    }

    /**
     * @notice Internal helper to settle subscriber batch on SubRedManagement.
     * @param a Decoded settle action payload.
     */
    function _settleSubscriber(SubRedCodec.SettleSubscriberAction memory a) internal {
        uint256 len = a.investorList.length;
        if (
            len == 0 || len != a.quantityList.length || len != a.currencyTokenList.length || len != a.amountList.length
                || len != a.feeList.length
        ) {
            revert InvalidArrayLength();
        }

        // Settle distribution/refund through SubRedManagement; does not mint by itself.
        SUB_RED.settleSubscriber(ST_TOKEN, a.investorList, a.quantityList, a.currencyTokenList, a.amountList, a.feeList);
    }
}
