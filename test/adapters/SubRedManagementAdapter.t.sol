// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SubRedManagementAdapter} from "../../src/adapters/digift/SubRedManagementAdapter.sol";
import {ISubRedManagement} from "../../src/interfaces/adapters/digift/ISubRedManagement.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("MockUSDC", "mUSDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockSTToken is ERC20 {
    constructor() ERC20("MockST", "mST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockVaultForAdapter {
    ERC20 public immutable usdc;

    constructor(address asset_) {
        usdc = ERC20(asset_);
    }

    function asset() external view returns (address) {
        return address(usdc);
    }

    function approveToAdapter(address adapter, uint256 amount) external {
        usdc.approve(adapter, amount);
    }

    function approveTokenToAdapter(address token, address adapter, uint256 amount) external {
        ERC20(token).approve(adapter, amount);
    }
}

contract MockSubRedManagement is ISubRedManagement {
    address public lastStToken;
    address public lastCurrencyToken;
    uint256 public lastAmount;
    uint256 public lastDeadline;
    uint256 public subscribeCount;
    uint256 public redeemCount;
    address public lastRedeemStToken;
    address public lastRedeemCurrencyToken;
    uint256 public lastRedeemQuantity;
    uint256 public lastRedeemDeadline;

    function subscribe(address stToken, address currencyToken, uint256 amount, uint256 deadline) external override {
        lastStToken = stToken;
        lastCurrencyToken = currencyToken;
        lastAmount = amount;
        lastDeadline = deadline;
        subscribeCount++;

        ERC20(currencyToken).transferFrom(msg.sender, address(this), amount);
    }

    function redeem(address stToken, address currencyToken, uint256 quantity, uint256 deadline) external override {
        lastRedeemStToken = stToken;
        lastRedeemCurrencyToken = currencyToken;
        lastRedeemQuantity = quantity;
        lastRedeemDeadline = deadline;
        redeemCount++;
    }
}

contract SubRedManagementAdapterTest is Test {
    MockUSDC internal usdc;
    MockUSDC internal dustToken;
    MockVaultForAdapter internal vault;
    MockSubRedManagement internal subRed;
    MockSTToken internal stToken;
    SubRedManagementAdapter internal adapter;

    address internal operator = makeAddr("operator");
    address internal receiver = makeAddr("receiver");
    address internal other = makeAddr("other");

    function setUp() public {
        usdc = new MockUSDC();
        dustToken = new MockUSDC();
        vault = new MockVaultForAdapter(address(usdc));
        subRed = new MockSubRedManagement();
        stToken = new MockSTToken();

        adapter = new SubRedManagementAdapter(
            address(vault), address(subRed), address(stToken), address(this), address(this), address(0)
        );
    }

    function test_DepositPullsFromVaultAndSubscribes() public {
        usdc.mint(address(vault), 1_000e18);
        vault.approveToAdapter(address(adapter), 500e18);

        uint256 subscribed = adapter.deposit(100e18, address(0));
        assertEq(subscribed, 100e18);
        assertEq(subRed.subscribeCount(), 1);
        assertEq(subRed.lastStToken(), address(stToken));
        assertEq(subRed.lastCurrencyToken(), address(usdc));
        assertEq(subRed.lastAmount(), 100e18);
        assertEq(usdc.balanceOf(address(subRed)), 100e18);
    }

    function test_RequestRedeemAsyncPullsPosTokenFromVault() public {
        stToken.mint(address(vault), 300e18);
        vault.approveTokenToAdapter(address(stToken), address(adapter), 300e18);

        adapter.requestRedeemAsync(200e18, receiver);
        assertEq(adapter.redeemNonce(), 1);
        assertEq(subRed.redeemCount(), 1);
        assertEq(subRed.lastRedeemStToken(), address(stToken));
        assertEq(subRed.lastRedeemCurrencyToken(), address(usdc));
        assertEq(subRed.lastRedeemQuantity(), 200e18);
        assertEq(stToken.balanceOf(address(adapter)), 200e18);
    }

    function test_SweepToVault_ReturnsTokenBalance() public {
        usdc.mint(address(adapter), 150e18);
        uint256 claimed = adapter.sweepToVault(address(usdc), 100e18);
        assertEq(claimed, 100e18);
        assertEq(usdc.balanceOf(address(vault)), 100e18);
        assertEq(usdc.balanceOf(address(adapter)), 50e18);
    }

    function test_RevertWhen_SweepToVaultCalledByNonController() public {
        vm.prank(other);
        vm.expectRevert();
        adapter.sweepToVault(address(usdc), 1e18);
    }

    function test_RevertWhen_RequestRedeemWithoutVaultPosAllowance() public {
        stToken.mint(address(vault), 100e18);
        vm.expectRevert();
        adapter.requestRedeemAsync(100e18, receiver);
    }

    function test_RevertWhen_SetPausedByUnauthorized() public {
        vm.prank(other);
        vm.expectRevert();
        adapter.setPaused(true);
    }

    function test_SweepDustToken_Success() public {
        dustToken.mint(address(adapter), 15e18);
        adapter.sweep(address(dustToken), receiver);
        assertEq(dustToken.balanceOf(receiver), 15e18);
        assertEq(dustToken.balanceOf(address(adapter)), 0);
    }

    function test_RevertWhen_SweepWithZeroReceiver() public {
        dustToken.mint(address(adapter), 1e18);
        vm.expectRevert();
        adapter.sweep(address(dustToken), address(0));
    }

    function test_RevertWhen_SweepWithZeroToken() public {
        vm.expectRevert();
        adapter.sweep(address(0), receiver);
    }
}
