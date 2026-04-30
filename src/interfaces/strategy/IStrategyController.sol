// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategyControllerExecutor} from "./IStrategyControllerExecutor.sol";
import {IStrategyControllerManager} from "./IStrategyControllerManager.sol";
import {IStrategyControllerView} from "./IStrategyControllerView.sol";

/// @notice Complete StrategyController ABI, split into view, management, and executor surfaces.
interface IStrategyController is IStrategyControllerView, IStrategyControllerManager, IStrategyControllerExecutor {}
