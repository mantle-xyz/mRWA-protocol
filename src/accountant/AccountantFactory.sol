// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {IAccountant} from "../interfaces/accountant/IAccountant.sol";

/**
 * @title AccountantFactory
 * @notice Deploys Accountant instances behind a shared UpgradeableBeacon.
 *   - All accountants share the same implementation contract
 *   - Beacon owner can upgrade all accountants atomically via UpgradeableBeacon.upgradeTo()
 *   - Supports two deployment modes:
 *       1. deployAccountant()          — deploy only, caller initializes later
 *       2. deployAndInitAccountant()   — deploy + initialize atomically
 *   - Accountant instances are exclusively deployed via BeaconProxy
 */
contract AccountantFactory {
    // =============================================================
    // Errors
    // =============================================================

    error Factory__ZeroAddress();

    // =============================================================
    // Events
    // =============================================================

    event AccountantDeployed(address indexed accountant, uint256 index, bool initialized);

    // =============================================================
    // State
    // =============================================================

    UpgradeableBeacon public immutable BEACON;
    address[] public accountants;

    // =============================================================
    // Constructor
    // =============================================================

    /**
     * @param impl Address of the Accountant implementation contract
     * @param beaconOwner Address that controls beacon upgrades (e.g. multisig / timelock)
     */
    constructor(address impl, address beaconOwner) {
        if (impl == address(0) || beaconOwner == address(0)) revert Factory__ZeroAddress();
        BEACON = new UpgradeableBeacon(impl, beaconOwner);
    }

    // =============================================================
    // Accountant Deployment
    // =============================================================

    /**
     * @notice Deploy an uninitialized Accountant as a BeaconProxy.
     *         Caller must call accountant.initialize(...) separately afterwards.
     * @dev Use this when dependent contract addresses (vault, treasury, etc.)
     *      are not yet known at deployment time. The typical flow:
     *        1. accountant = factory.deployAccountant()
     *        2. Deploy vault / other contracts with accountant address
     *        3. accountant.initialize(vault, treasury, initialRate, managementFeeRate, admin)
     *      IMPORTANT: The accountant is unprotected until initialized. In production,
     *      batch steps 1-3 in a single transaction (e.g. via deploy script / multicall)
     *      to prevent front-running.
     */
    function deployAccountant() external returns (address accountant) {
        BeaconProxy proxy = new BeaconProxy(address(BEACON), "");
        accountant = address(proxy);
        accountants.push(accountant);

        emit AccountantDeployed(accountant, accountants.length - 1, false);
    }

    /**
     * @notice Deploy and atomically initialize an Accountant as a BeaconProxy.
     *         Use this when all dependent addresses are already known.
     * @param vault_ The MantleYieldVault address this accountant manages
     * @param treasury_ Address receiving management-fee shares
     * @param initialRate Initial exchange rate (18-decimal precision)
     * @param managementFeeRate_ Annual management fee in basis points
     * @param admin Address granted DEFAULT_ADMIN_ROLE, PAUSER_ROLE, and EXECUTOR_ROLE
     */
    function deployAndInitAccountant(
        address vault_,
        address treasury_,
        uint256 initialRate,
        uint256 managementFeeRate_,
        address admin
    ) external returns (address accountant) {
        bytes memory initData =
            abi.encodeCall(IAccountant.initialize, (vault_, treasury_, initialRate, managementFeeRate_, admin));

        BeaconProxy proxy = new BeaconProxy(address(BEACON), initData);
        accountant = address(proxy);
        accountants.push(accountant);

        emit AccountantDeployed(accountant, accountants.length - 1, true);
    }

    // =============================================================
    // View Functions
    // =============================================================

    function accountantCount() external view returns (uint256) {
        return accountants.length;
    }

    function implementation() external view returns (address) {
        return BEACON.implementation();
    }

    function getAllAccountants() external view returns (address[] memory) {
        return accountants;
    }
}
