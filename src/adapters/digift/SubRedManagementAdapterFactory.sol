// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISubRedManagementAdapter} from "../../interfaces/adapters/digift/ISubRedManagementAdapter.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

/**
 * @title SubRedManagementAdapterFactory
 * @notice Deploys SubRedManagementAdapter instances behind a shared UpgradeableBeacon.
 *   - All adapters share the same implementation contract
 *   - Beacon owner can upgrade all adapters atomically via UpgradeableBeacon.upgradeTo()
 *   - Supports two deployment modes:
 *       1. deployAdapter()          — deploy only, caller initializes later
 *       2. deployAndInitAdapter()   — deploy + initialize atomically
 *   - Adapter instances are exclusively deployed via BeaconProxy
 */
contract SubRedManagementAdapterFactory {
    // =============================================================
    // Errors
    // =============================================================

    error Factory__ZeroAddress();

    // =============================================================
    // Events
    // =============================================================

    event AdapterDeployed(address indexed adapter, uint256 index, bool initialized);

    // =============================================================
    // State
    // =============================================================

    UpgradeableBeacon public immutable BEACON;
    address[] public adapters;

    // =============================================================
    // Constructor
    // =============================================================

    /**
     * @param impl Address of the SubRedManagementAdapter implementation contract
     * @param beaconOwner Address that controls beacon upgrades (e.g. multisig / timelock)
     */
    constructor(address impl, address beaconOwner) {
        if (impl == address(0) || beaconOwner == address(0)) revert Factory__ZeroAddress();
        BEACON = new UpgradeableBeacon(impl, beaconOwner);
    }

    // =============================================================
    // Adapter Deployment
    // =============================================================

    /**
     * @notice Deploy an uninitialized SubRedManagementAdapter as a BeaconProxy.
     *         Caller must call adapter.initialize(...) separately afterwards.
     * @dev Use this when dependent contract addresses (vault, etc.)
     *      are not yet known at deployment time. The typical flow:
     *        1. adapter = factory.deployAdapter()
     *        2. Deploy vault / other contracts with adapter address
     *        3. adapter.initialize(vault, subRedManagement, stToken, admin, controller, accountantExecutor, priceOracle)
     *      IMPORTANT: The adapter is unprotected until initialized. In production,
     *      batch steps 1-3 in a single transaction (e.g. via deploy script / multicall)
     *      to prevent front-running.
     */
    function deployAdapter() external returns (address adapter) {
        BeaconProxy proxy = new BeaconProxy(address(BEACON), "");
        adapter = address(proxy);
        adapters.push(adapter);

        emit AdapterDeployed(adapter, adapters.length - 1, false);
    }

    /**
     * @notice Deploy and atomically initialize a SubRedManagementAdapter as a BeaconProxy.
     *         Use this when all dependent addresses are already known.
     * @param vault_ Vault that owns strategy funds
     * @param subRedManagement Digift SubRedManagement contract
     * @param stToken Target security token address
     * @param admin Adapter admin role address
     * @param controller StrategyController role address
     * @param accountantExecutor AccountantExecutor role address
     * @param priceOracle_ Optional DFeedPriceOracle address. Pass address(0) for manual pricing.
     */
    function deployAndInitAdapter(
        address vault_,
        address subRedManagement,
        address stToken,
        address admin,
        address controller,
        address accountantExecutor,
        address priceOracle_
    ) external returns (address adapter) {
        bytes memory initData = abi.encodeCall(
            ISubRedManagementAdapter.initialize,
            (vault_, subRedManagement, stToken, admin, controller, accountantExecutor, priceOracle_)
        );

        BeaconProxy proxy = new BeaconProxy(address(BEACON), initData);
        adapter = address(proxy);
        adapters.push(adapter);

        emit AdapterDeployed(adapter, adapters.length - 1, true);
    }

    // =============================================================
    // View Functions
    // =============================================================

    function adapterCount() external view returns (uint256) {
        return adapters.length;
    }

    function implementation() external view returns (address) {
        return BEACON.implementation();
    }

    function getAllAdapters() external view returns (address[] memory) {
        return adapters;
    }
}
