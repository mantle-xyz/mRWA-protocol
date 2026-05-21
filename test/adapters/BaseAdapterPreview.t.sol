// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockSync4626Adapter} from "../../src/adapters/mock/MockSync4626Adapter.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";

contract PreviewMockAsset is ERC20 {
    constructor() ERC20("PreviewAsset", "pAST") {}
}

contract PreviewMockVault {
    address internal immutable asset_;

    constructor(address assetAddress) {
        asset_ = assetAddress;
    }

    function asset() external view returns (address) {
        return asset_;
    }
}

contract BaseAdapterPreviewTest is Test {
    function test_DefaultPreviewPassesThroughAmounts() public {
        PreviewMockAsset asset = new PreviewMockAsset();
        PreviewMockVault vault = new PreviewMockVault(address(asset));
        MockSync4626Adapter adapter =
            new MockSync4626Adapter(address(vault), address(0x1234), address(this), address(this), address(this));

        (bool depositOk, uint256 executableDeposit, uint256 expectedDepositPos) = adapter.previewDeposit(123e18);
        (bool redeemOk, uint256 executableRedeem, uint256 expectedRedeemPos) = adapter.previewRedeem(456e18);

        assertTrue(depositOk);
        assertEq(executableDeposit, 123e18);
        assertEq(expectedDepositPos, 0);

        assertTrue(redeemOk);
        assertEq(executableRedeem, 456e18);
        assertEq(expectedRedeemPos, 0);
    }
}
