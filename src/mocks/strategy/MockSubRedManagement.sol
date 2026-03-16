// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISubRedManagement} from "../../interfaces/adapters/digift/ISubRedManagement.sol";

import {MockERC20Mintable} from "../token/MockERC20Mintable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Mock Digift SubRedManagement: records requests and allows operator settlement.
contract MockSubRedManagement is ISubRedManagement, Ownable {
    using SafeERC20 for IERC20;

    struct PendingFlow {
        uint256 subscribeAsset;
        uint256 redeemPos;
    }

    mapping(address adapter => mapping(address stToken => PendingFlow)) public pending;

    event SubscribeRequested(
        address indexed adapter,
        address indexed stToken,
        address indexed currencyToken,
        uint256 amount,
        uint256 deadline
    );
    event RedeemRequested(
        address indexed adapter,
        address indexed stToken,
        address indexed currencyToken,
        uint256 quantity,
        uint256 deadline
    );
    event SubscribeSettled(
        address indexed adapter, address indexed stToken, address indexed receiver, uint256 mintedPos
    );
    event RedeemSettled(
        address indexed adapter,
        address indexed stToken,
        address indexed currencyToken,
        address receiver,
        uint256 assetsOut
    );

    constructor(address owner_) Ownable(owner_) {}

    function subscribe(address stToken, address currencyToken, uint256 amount, uint256 deadline) external override {
        IERC20(currencyToken).safeTransferFrom(msg.sender, address(this), amount);
        pending[msg.sender][stToken].subscribeAsset += amount;
        emit SubscribeRequested(msg.sender, stToken, currencyToken, amount, deadline);
    }

    function redeem(address stToken, address currencyToken, uint256 quantity, uint256 deadline) external override {
        IERC20(stToken).safeTransferFrom(msg.sender, address(this), quantity);
        pending[msg.sender][stToken].redeemPos += quantity;
        emit RedeemRequested(msg.sender, stToken, currencyToken, quantity, deadline);
    }

    /// @notice Simulate async subscribe settlement by minting ST token to adapter.
    function settleSubscribe(address adapter, address stToken, address receiver, uint256 mintedPos) external onlyOwner {
        PendingFlow storage flow = pending[adapter][stToken];
        if (flow.subscribeAsset == 0) revert("NO_SUBSCRIBE_PENDING");
        flow.subscribeAsset = 0;
        MockERC20Mintable(stToken).mint(receiver, mintedPos);
        emit SubscribeSettled(adapter, stToken, receiver, mintedPos);
    }

    /// @notice Simulate async redeem settlement by sending settlement asset to adapter.
    function settleRedeem(address adapter, address stToken, address currencyToken, address receiver, uint256 assetsOut)
        external
        onlyOwner
    {
        PendingFlow storage flow = pending[adapter][stToken];
        if (flow.redeemPos == 0) revert("NO_REDEEM_PENDING");
        flow.redeemPos = 0;
        IERC20(currencyToken).safeTransfer(receiver, assetsOut);
        emit RedeemSettled(adapter, stToken, currencyToken, receiver, assetsOut);
    }
}
