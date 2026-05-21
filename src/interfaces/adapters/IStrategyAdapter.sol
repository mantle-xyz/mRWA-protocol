// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAdapterEvents} from "./IAdapterEvents.sol";
import {IStrategyAdapterAsync} from "./IStrategyAdapterAsync.sol";
import {IStrategyAdapterCore} from "./IStrategyAdapterCore.sol";
import {IStrategyAdapterSync} from "./IStrategyAdapterSync.sol";

interface IStrategyAdapter is IAdapterEvents, IStrategyAdapterCore, IStrategyAdapterSync, IStrategyAdapterAsync {}
