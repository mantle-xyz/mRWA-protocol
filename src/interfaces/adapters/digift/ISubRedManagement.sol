// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ISubRedManagement {
    function subscribe(address stToken, address currencyToken, uint256 amount, uint256 deadline) external;

    function settleSubscriber(
        address stToken,
        address[] calldata investorList,
        uint256[] calldata quantityList,
        address[] calldata currencyTokenList,
        uint256[] calldata amountList,
        uint256[] calldata feeList
    ) external;
}
