// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategyController as ControllerInterface} from "../../src/interfaces/strategy/IStrategyController.sol";
import {IStrategyControllerExecutor as Executor} from "../../src/interfaces/strategy/IStrategyControllerExecutor.sol";
import {IStrategyControllerManager as Manager} from "../../src/interfaces/strategy/IStrategyControllerManager.sol";
import {IStrategyControllerView as View} from "../../src/interfaces/strategy/IStrategyControllerView.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

contract StrategyControllerInterfacesTest is Test {
    function test_strategyControllerMatchesViewInterfaceSelectors() public view {
        StrategyController controller = StrategyController(address(0));
        View viewInterface = View(address(0));

        {
            function() external view returns (IERC20) actual = controller.asset;
            function() external view returns (IERC20) expected = viewInterface.asset;
            assertEq(actual.selector, expected.selector);
        }
        {
            function() external view returns (IMantleYieldVault) actual = controller.vault;
            function() external view returns (IMantleYieldVault) expected = viewInterface.vault;
            assertEq(actual.selector, expected.selector);
        }
        {
            function() external view returns (uint16) actual = controller.bufferTargetBps;
            function() external view returns (uint16) expected = viewInterface.bufferTargetBps;
            assertEq(actual.selector, expected.selector);
        }
        {
            function() external view returns (uint16) actual = controller.rebalanceThresholdBps;
            function() external view returns (uint16) expected = viewInterface.rebalanceThresholdBps;
            assertEq(actual.selector, expected.selector);
        }
        {
            function() external view returns (uint64) actual = controller.rebalanceCooldown;
            function() external view returns (uint64) expected = viewInterface.rebalanceCooldown;
            assertEq(actual.selector, expected.selector);
        }
        {
            function() external view returns (uint64) actual = controller.lastRebalance;
            function() external view returns (uint64) expected = viewInterface.lastRebalance;
            assertEq(actual.selector, expected.selector);
        }
        {
            function() external view returns (uint256) actual = controller.strategyOrderLength;
            function() external view returns (uint256) expected = viewInterface.strategyOrderLength;
            assertEq(actual.selector, expected.selector);
        }
        {
            function(uint256) external view returns (address) actual = controller.strategyOrder;
            function(uint256) external view returns (address) expected = viewInterface.strategyOrder;
            assertEq(actual.selector, expected.selector);
        }
        {
            function() external view returns (uint256, uint256, uint256, uint256, uint256, uint256, bool) actual =
            controller.getRebalanceState;
            function() external view returns (uint256, uint256, uint256, uint256, uint256, uint256, bool) expected =
            viewInterface.getRebalanceState;
            assertEq(actual.selector, expected.selector);
        }
        {
            function() external view returns (bool, uint8, uint256) actual = controller.previewRebalance;
            function() external view returns (bool, uint8, uint256) expected = viewInterface.previewRebalance;
            assertEq(actual.selector, expected.selector);
        }
        {
            function(address) external view returns (uint16, uint16, bool, bool, bool) actual = controller.strategyInfo;
            function(address) external view returns (uint16, uint16, bool, bool, bool) expected =
            viewInterface.strategyInfo;
            assertEq(actual.selector, expected.selector);
        }
    }

    function test_strategyControllerMatchesManagerInterfaceSelectors() public pure {
        StrategyController controller = StrategyController(address(0));
        Manager managerInterface = Manager(address(0));

        {
            function(uint16, uint16, uint64) external actual = controller.setRiskParams;
            function(uint16, uint16, uint64) external expected = managerInterface.setRiskParams;
            assertEq(actual.selector, expected.selector);
        }
        {
            function(address, uint16, uint16, bool) external actual = controller.registerStrategy;
            function(address, uint16, uint16, bool) external expected = managerInterface.registerStrategy;
            assertEq(actual.selector, expected.selector);
        }
        {
            function(address) external actual = controller.activateStrategy;
            function(address) external expected = managerInterface.activateStrategy;
            assertEq(actual.selector, expected.selector);
        }
        {
            function(address) external actual = controller.deactivateStrategy;
            function(address) external expected = managerInterface.deactivateStrategy;
            assertEq(actual.selector, expected.selector);
        }
        {
            function(address[] memory, uint16[] memory, uint16[] memory, bool[] memory) external actual =
            controller.updateStrategies;
            function(address[] memory, uint16[] memory, uint16[] memory, bool[] memory) external expected =
            managerInterface.updateStrategies;
            assertEq(actual.selector, expected.selector);
        }
        {
            function(address[] memory, uint16[] memory, uint16[] memory, bool[] memory, address[] memory) external
                actual = controller.updateStrategiesAndOrder;
            function(address[] memory, uint16[] memory, uint16[] memory, bool[] memory, address[] memory) external
                expected = managerInterface.updateStrategiesAndOrder;
            assertEq(actual.selector, expected.selector);
        }
        {
            function(address[] memory) external actual = controller.setStrategyOrder;
            function(address[] memory) external expected = managerInterface.setStrategyOrder;
            assertEq(actual.selector, expected.selector);
        }
        {
            function(address, bool) external actual = controller.setAdapterPaused;
            function(address, bool) external expected = managerInterface.setAdapterPaused;
            assertEq(actual.selector, expected.selector);
        }
        {
            function(address[] memory, bool) external actual = controller.setAdaptersPaused;
            function(address[] memory, bool) external expected = managerInterface.setAdaptersPaused;
            assertEq(actual.selector, expected.selector);
        }
    }

    function test_strategyControllerMatchesExecutorInterfaceSelectors() public pure {
        StrategyController controller = StrategyController(address(0));
        Executor executorInterface = Executor(address(0));

        {
            function() external actual = controller.rebalance;
            function() external expected = executorInterface.rebalance;
            assertEq(actual.selector, expected.selector);
        }
        {
            function(uint256[] memory) external actual = controller.processRedeemBatch;
            function(uint256[] memory) external expected = executorInterface.processRedeemBatch;
            assertEq(actual.selector, expected.selector);
        }
        {
            function(uint256[] memory, uint256[] memory) external actual = controller.finalizeRedeemBatch;
            function(uint256[] memory, uint256[] memory) external expected = executorInterface.finalizeRedeemBatch;
            assertEq(actual.selector, expected.selector);
        }
        {
            function(address, Executor.InvestSettlementInput memory, Executor.RedeemSettlementInput memory) external
                actual = controller.settleAdapter;
            function(address, Executor.InvestSettlementInput memory, Executor.RedeemSettlementInput memory) external
                expected = executorInterface.settleAdapter;
            assertEq(actual.selector, expected.selector);
        }
        {
            function(address[] memory, Executor.InvestSettlementInput[] memory, Executor.RedeemSettlementInput[] memory)
                external actual = controller.settleAdapters;
            function(address[] memory, Executor.InvestSettlementInput[] memory, Executor.RedeemSettlementInput[] memory)
                external expected = executorInterface.settleAdapters;
            assertEq(actual.selector, expected.selector);
        }
    }

    function test_aggregateInterfaceIncludesSplitInterfaceSelectors() public pure {
        ControllerInterface controllerInterface = ControllerInterface(address(0));
        View viewInterface = View(address(0));
        Manager managerInterface = Manager(address(0));
        Executor executorInterface = Executor(address(0));

        {
            function() external view returns (IERC20) actual = controllerInterface.asset;
            function() external view returns (IERC20) expected = viewInterface.asset;
            assertEq(actual.selector, expected.selector);
        }
        {
            function(uint16, uint16, uint64) external actual = controllerInterface.setRiskParams;
            function(uint16, uint16, uint64) external expected = managerInterface.setRiskParams;
            assertEq(actual.selector, expected.selector);
        }
        {
            function() external actual = controllerInterface.rebalance;
            function() external expected = executorInterface.rebalance;
            assertEq(actual.selector, expected.selector);
        }
    }
}
