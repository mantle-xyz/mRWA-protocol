// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library SubRedCodec {
    uint8 internal constant ACTION_SUBSCRIBE = 1;
    uint8 internal constant ACTION_SETTLE_SUBSCRIBER = 2;
    uint8 internal constant ACTION_FINALIZE_REDEEM = 3;

    struct SubscribeAction {
        uint256 amountUSDC;
        uint64 deadline;
    }

    struct SettleSubscriberAction {
        address[] investorList;
        uint256[] quantityList;
        address[] currencyTokenList;
        uint256[] amountList;
        uint256[] feeList;
    }

    struct FinalizeRedeemAction {
        bytes32 requestId;
        uint256 receivedUSDC;
    }

    function decodeAction(bytes memory data) internal pure returns (uint8 action, bytes memory actionData) {
        (action, actionData) = abi.decode(data, (uint8, bytes));
    }
}
