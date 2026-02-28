// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title TimelockUpgradeController - Timelock-gated upgrade governance
/// @notice Wraps OZ TimelockController to enforce delayed upgrades on UUPS proxies.
///         Deploy this as the owner of your proxy so all upgrades go through the timelock.
contract TimelockUpgradeController is TimelockController {
    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors, address admin)
        TimelockController(minDelay, proposers, executors, admin)
    {}
}
