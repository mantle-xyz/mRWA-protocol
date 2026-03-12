// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockDFeedPriceOracle {
    uint256 internal _price;
    uint8 internal _decimals;

    constructor(uint256 price_, uint8 decimals_) {
        _price = price_;
        _decimals = decimals_;
    }

    function getPrice() external view returns (uint256) {
        return _price;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function setPrice(uint256 price_) external {
        _price = price_;
    }

    function setDecimals(uint8 decimals_) external {
        _decimals = decimals_;
    }
}
