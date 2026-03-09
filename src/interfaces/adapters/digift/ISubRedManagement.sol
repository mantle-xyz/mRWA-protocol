// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ISubRedManagement {
    function subscribe(address stToken, address currencyToken, uint256 amount, uint256 deadline) external;

    function redeem(address stToken, address currencyToken, uint256 quantity, uint256 deadline) external;
}
