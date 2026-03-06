// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library SubRedCodec {
    // Action ids carried in AdapterCall.data => abi.encode(uint8 action, bytes actionData)
    uint8 internal constant ACTION_SUBSCRIBE = 1;
    uint8 internal constant ACTION_SETTLE_SUBSCRIBER = 2;
    uint8 internal constant ACTION_FINALIZE_REDEEM = 3;

    // Bot-triggered direct subscribe action.
    struct SubscribeAction {
        uint256 amountUSDC;
        uint64 deadline;
    }

    // Batch settlement payload mirrored from SubRedManagement.settleSubscriber.
    struct SettleSubscriberAction {
        address[] investorList;
        uint256[] quantityList;
        address[] currencyTokenList;
        uint256[] amountList;
        uint256[] feeList;
    }

    // Marks part/all of a pending redeem request as physically received.
    struct FinalizeRedeemAction {
        bytes32 requestId;
        uint256 receivedUSDC;
    }

    function decodeAction(bytes memory data) internal pure returns (uint8 action, bytes memory actionData) {
        (action, actionData) = abi.decode(data, (uint8, bytes));
    }
}
