// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Execution-only surface used by OperatorExecutor.
interface IStrategyControllerExecutor {
    struct InvestSettlementInput {
        uint256[] inFlightIds;
        uint256[] settledPosAmounts;
        uint256[] refundAssetAmounts;
    }

    struct RedeemSettlementInput {
        uint256[] inFlightIds;
        uint256[] settledAssetAmounts;
    }

    function rebalance() external;
    function processRedeemBatch(uint256[] calldata ids) external;
    function finalizeRedeemBatch(uint256[] calldata ids, uint256[] calldata settledAssets) external;
    function settleAdapter(
        address adapter,
        InvestSettlementInput calldata invest,
        RedeemSettlementInput calldata redeem
    ) external;
    function settleAdapters(
        address[] calldata adapters,
        InvestSettlementInput[] calldata investBatch,
        RedeemSettlementInput[] calldata redeemBatch
    ) external;
}
