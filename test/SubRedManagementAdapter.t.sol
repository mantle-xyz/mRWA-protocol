// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SubRedManagementAdapter} from "../src/adapters/digift/SubRedManagementAdapter.sol";
import {ISubRedManagement} from "../src/interfaces/adapters/digift/ISubRedManagement.sol";
import {AdapterCall} from "../src/libs/AdapterCodec.sol";
import {SubRedCodec} from "../src/adapters/digift/libs/SubRedCodec.sol";
import {BaseAdapter} from "../src/adapters/base/BaseAdapter.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("MockUSDC", "mUSDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockSubRedManagement is ISubRedManagement {
    address public lastStToken;
    address public lastCurrencyToken;
    uint256 public lastAmount;
    uint256 public lastDeadline;
    uint256 public subscribeCount;
    uint256 public settleCount;

    function subscribe(address stToken, address currencyToken, uint256 amount, uint256 deadline) external override {
        lastStToken = stToken;
        lastCurrencyToken = currencyToken;
        lastAmount = amount;
        lastDeadline = deadline;
        subscribeCount++;

        ERC20(currencyToken).transferFrom(msg.sender, address(this), amount);
    }

    function settleSubscriber(
        address,
        address[] calldata,
        uint256[] calldata,
        address[] calldata,
        uint256[] calldata,
        uint256[] calldata
    ) external override {
        settleCount++;
    }
}

contract SubRedManagementAdapterTest is Test {
    MockUSDC internal usdc;
    MockSubRedManagement internal subRed;
    SubRedManagementAdapter internal adapter;

    address internal operator = makeAddr("operator");
    address internal stToken = makeAddr("stToken");
    address internal receiver = makeAddr("receiver");

    function setUp() public {
        usdc = new MockUSDC();
        subRed = new MockSubRedManagement();

        // Use the test contract as vault and controller for simplicity.
        adapter = new SubRedManagementAdapter(
            address(usdc), address(this), address(subRed), stToken, address(this), address(this), operator
        );
    }

    function test_DepositPullsFromVaultAndSubscribes() public {
        usdc.mint(address(this), 1_000e18);
        usdc.approve(address(adapter), 500e18);

        uint256 subscribed = adapter.deposit(100e18, address(0));
        assertEq(subscribed, 100e18);
        assertEq(subRed.subscribeCount(), 1);
        assertEq(subRed.lastStToken(), stToken);
        assertEq(subRed.lastCurrencyToken(), address(usdc));
        assertEq(subRed.lastAmount(), 100e18);
        assertEq(usdc.balanceOf(address(subRed)), 100e18);
    }

    function test_RequestFinalizeClaimFlow() public {
        bytes32 requestId = adapter.requestRedeemAsync(200e18, receiver);
        assertEq(adapter.pendingRedeemUSDC(requestId), 200e18);

        // Simulate physical funds received by adapter before finalize.
        usdc.mint(address(adapter), 150e18);

        SubRedCodec.FinalizeRedeemAction memory finalizeAction =
            SubRedCodec.FinalizeRedeemAction({requestId: requestId, receivedUSDC: 150e18});
        bytes memory actionData = abi.encode(uint8(SubRedCodec.ACTION_FINALIZE_REDEEM), abi.encode(finalizeAction));
        AdapterCall memory envelope = AdapterCall({deadline: uint64(block.timestamp + 1 hours), salt: bytes32("x"), data: actionData});

        vm.prank(operator);
        adapter.execute(abi.encode(envelope));

        assertEq(adapter.pendingRedeemUSDC(requestId), 50e18);
        assertEq(adapter.claimableRedeemUSDC(requestId), 150e18);

        uint256 claimed = adapter.claimRedeem(requestId, receiver);
        assertEq(claimed, 150e18);
        assertEq(adapter.claimableRedeemUSDC(requestId), 0);
        assertEq(usdc.balanceOf(receiver), 150e18);
    }

    function test_RevertWhen_ExecuteCalledByNonOperator() public {
        AdapterCall memory envelope = AdapterCall({deadline: 0, salt: bytes32(0), data: abi.encode(uint8(255), bytes(""))});
        vm.expectRevert(BaseAdapter.NotOperator.selector);
        adapter.execute(abi.encode(envelope));
    }

    function test_RevertWhen_ExecuteDeadlineExpired() public {
        vm.warp(100);
        AdapterCall memory envelope = AdapterCall({
            deadline: uint64(block.timestamp - 1),
            salt: bytes32("late"),
            data: abi.encode(uint8(SubRedCodec.ACTION_SUBSCRIBE), abi.encode(SubRedCodec.SubscribeAction(1, uint64(block.timestamp))))
        });

        vm.prank(operator);
        vm.expectRevert(BaseAdapter.DeadlineExceeded.selector);
        adapter.execute(abi.encode(envelope));
    }

    function test_RevertWhen_ExecuteSaltReused() public {
        bytes32 requestId = adapter.requestRedeemAsync(10e18, receiver);
        usdc.mint(address(adapter), 10e18);

        SubRedCodec.FinalizeRedeemAction memory finalizeAction =
            SubRedCodec.FinalizeRedeemAction({requestId: requestId, receivedUSDC: 10e18});
        bytes memory actionData = abi.encode(uint8(SubRedCodec.ACTION_FINALIZE_REDEEM), abi.encode(finalizeAction));
        AdapterCall memory envelope = AdapterCall({deadline: uint64(block.timestamp + 1 hours), salt: bytes32("dup"), data: actionData});

        vm.prank(operator);
        adapter.execute(abi.encode(envelope));

        vm.prank(operator);
        vm.expectRevert();
        adapter.execute(abi.encode(envelope));
    }
}
