// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategyAdapter} from "../IStrategyAdapter.sol";

/// @title ISubRedManagementAdapter
/// @notice Interface for the upgradeable SubRedManagementAdapter, used by the factory's
///         abi.encodeCall to atomically deploy + initialize a BeaconProxy.
interface ISubRedManagementAdapter is IStrategyAdapter {
    /// @notice Initialize the adapter behind a BeaconProxy.
    /// @param vault_ Vault that owns strategy funds.
    /// @param subRedManagement Digift SubRedManagement contract.
    /// @param stToken_ Target security token address supported by SubRedManagement.
    /// @param admin Adapter admin role address.
    /// @param controller StrategyController role address.
    /// @param accountantExecutor AccountantExecutor role address for manual price updates.
    /// @param priceOracle_ Optional DFeedPriceOracle for the ST token. Pass address(0) to use manual pricing.
    function initialize(
        address vault_,
        address subRedManagement,
        address stToken_,
        address admin,
        address controller,
        address accountantExecutor,
        address priceOracle_
    ) external;
}
