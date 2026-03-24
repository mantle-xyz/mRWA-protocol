// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategyControllerExecutor} from "../../src/interfaces/strategy/IStrategyControllerExecutor.sol";
import {OperatorExecutor} from "../../src/protocol/OperatorExecutor.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

contract MockStrategyController is IStrategyControllerExecutor {
    error NotExecutorGateway();

    address public executorGateway;
    uint256 public rebalanceCount;
    bytes32 public lastProcessHash;
    bytes32 public lastAllocateHash;
    bytes32 public lastSettleHash;
    bytes32 public lastSettleBatchHash;

    modifier onlyExecutorGateway() {
        if (msg.sender != executorGateway) {
            revert NotExecutorGateway();
        }
        _;
    }

    function setExecutorGateway(address gateway) external {
        executorGateway = gateway;
    }

    function rebalance() external override onlyExecutorGateway {
        rebalanceCount++;
    }

    function processRedeemBatch(uint256[] calldata ids) external override onlyExecutorGateway {
        lastProcessHash = keccak256(abi.encode(ids));
    }

    function finalizeRedeemBatch(uint256[] calldata ids, uint256[] calldata settledAssets)
        external
        override
        onlyExecutorGateway
    {
        lastAllocateHash = keccak256(abi.encode(ids, settledAssets));
    }

    function settleAdapter(
        address adapter,
        uint256[] calldata investInFlightIds,
        uint256[] calldata investSettledAmounts,
        uint256[] calldata redeemInFlightIds,
        uint256[] calldata redeemSettledAmounts
    ) external override onlyExecutorGateway {
        lastSettleHash = keccak256(
            abi.encode(adapter, investInFlightIds, investSettledAmounts, redeemInFlightIds, redeemSettledAmounts)
        );
    }

    function settleAdapters(
        address[] calldata adapters,
        uint256[][] calldata investInFlightIdsBatch,
        uint256[][] calldata investSettledAmountsBatch,
        uint256[][] calldata redeemInFlightIdsBatch,
        uint256[][] calldata redeemSettledAmountsBatch
    ) external override onlyExecutorGateway {
        lastSettleBatchHash = keccak256(
            abi.encode(
                adapters,
                investInFlightIdsBatch,
                investSettledAmountsBatch,
                redeemInFlightIdsBatch,
                redeemSettledAmountsBatch
            )
        );
    }
}

contract OperatorExecutorTest is Test {
    bytes32 internal constant BOT_ROLE = keccak256("BOT_ROLE");

    MockStrategyController internal controller;
    OperatorExecutor internal executor;

    address internal admin = makeAddr("admin");
    address internal bot = makeAddr("bot");

    function setUp() public {
        controller = new MockStrategyController();
        OperatorExecutor implementation = new OperatorExecutor();
        bytes memory initData = abi.encodeCall(OperatorExecutor.initialize, (admin, bot));
        executor = OperatorExecutor(address(new ERC1967Proxy(address(implementation), initData)));
        controller.setExecutorGateway(address(executor));
    }

    function test_ControllerRejectsDirectCall_NotFromExecutorGateway() public {
        vm.expectRevert(MockStrategyController.NotExecutorGateway.selector);
        controller.rebalance();
    }

    function test_ExecuteRebalance_Routes() public {
        vm.prank(bot);
        executor.executeRebalance(address(controller));

        assertEq(controller.rebalanceCount(), 1);
    }

    function test_ExecuteProcessBatch_Routes() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 3;

        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), ids);

        assertEq(controller.lastProcessHash(), keccak256(abi.encode(ids)));
    }

    function test_ExecuteFinalizeBatch_Routes() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 9;
        uint256[] memory settledAssets = new uint256[](1);
        settledAssets[0] = 123;

        vm.prank(bot);
        executor.executeFinalizeRedeemBatch(address(controller), ids, settledAssets);

        assertEq(controller.lastAllocateHash(), keccak256(abi.encode(ids, settledAssets)));
    }

    function test_ExecuteSettleAdapter_Routes() public {
        uint256[] memory investInFlightIds = new uint256[](1);
        investInFlightIds[0] = 7;
        uint256[] memory investSettledAmounts = new uint256[](1);
        investSettledAmounts[0] = 11;
        uint256[] memory redeemInFlightIds = new uint256[](1);
        redeemInFlightIds[0] = 9;
        uint256[] memory redeemSettledAmounts = new uint256[](1);
        redeemSettledAmounts[0] = 22;

        vm.prank(bot);
        executor.executeSettleAdapter(
            address(controller),
            address(0xBEEF),
            investInFlightIds,
            investSettledAmounts,
            redeemInFlightIds,
            redeemSettledAmounts
        );

        assertEq(
            controller.lastSettleHash(),
            keccak256(
                abi.encode(
                    address(0xBEEF), investInFlightIds, investSettledAmounts, redeemInFlightIds, redeemSettledAmounts
                )
            )
        );
    }

    function test_ExecuteSettleAdapters_Routes() public {
        address[] memory adapters = new address[](2);
        adapters[0] = address(0xA1);
        adapters[1] = address(0xB2);

        uint256[][] memory investInFlightIdsBatch = new uint256[][](2);
        investInFlightIdsBatch[0] = new uint256[](1);
        investInFlightIdsBatch[0][0] = 7;
        investInFlightIdsBatch[1] = new uint256[](0);

        uint256[][] memory investSettledAmountsBatch = new uint256[][](2);
        investSettledAmountsBatch[0] = new uint256[](1);
        investSettledAmountsBatch[0][0] = 11;
        investSettledAmountsBatch[1] = new uint256[](0);

        uint256[][] memory redeemInFlightIdsBatch = new uint256[][](2);
        redeemInFlightIdsBatch[0] = new uint256[](0);
        redeemInFlightIdsBatch[1] = new uint256[](1);
        redeemInFlightIdsBatch[1][0] = 9;

        uint256[][] memory redeemSettledAmountsBatch = new uint256[][](2);
        redeemSettledAmountsBatch[0] = new uint256[](0);
        redeemSettledAmountsBatch[1] = new uint256[](1);
        redeemSettledAmountsBatch[1][0] = 22;

        vm.prank(bot);
        executor.executeSettleAdapters(
            address(controller),
            adapters,
            investInFlightIdsBatch,
            investSettledAmountsBatch,
            redeemInFlightIdsBatch,
            redeemSettledAmountsBatch
        );

        assertEq(
            controller.lastSettleBatchHash(),
            keccak256(
                abi.encode(
                    adapters,
                    investInFlightIdsBatch,
                    investSettledAmountsBatch,
                    redeemInFlightIdsBatch,
                    redeemSettledAmountsBatch
                )
            )
        );
    }

    function test_RevertWhen_CallerNotBot() public {
        address notBot = makeAddr("notBot");
        vm.prank(notBot);
        vm.expectRevert();
        executor.executeRebalance(address(controller));
    }

    function test_BotRole_NewBotCanExecute_AfterGrant() public {
        address newBot = makeAddr("newBot");

        vm.prank(admin);
        executor.grantRole(BOT_ROLE, newBot);

        vm.prank(newBot);
        executor.executeRebalance(address(controller));

        assertEq(controller.rebalanceCount(), 1);
    }

    function test_BotRole_RevokedBotCannotExecute() public {
        vm.prank(admin);
        executor.revokeRole(BOT_ROLE, bot);

        vm.prank(bot);
        vm.expectRevert();
        executor.executeRebalance(address(controller));
    }

    function test_RevertWhen_GrantRoleByNonAdmin() public {
        vm.prank(makeAddr("notAdmin"));
        vm.expectRevert();
        executor.grantRole(BOT_ROLE, makeAddr("hsm"));
    }

    function test_RevertWhen_ZeroController() public {
        vm.prank(bot);
        vm.expectRevert(OperatorExecutor.InvalidAddress.selector);
        executor.executeRebalance(address(0));
    }

    function test_RevertWhen_ControllerIsEOA() public {
        address eoaController = makeAddr("eoaController");

        vm.prank(bot);
        vm.expectRevert(abi.encodeWithSelector(OperatorExecutor.InvalidController.selector, eoaController));
        executor.executeRebalance(eoaController);
    }
}
