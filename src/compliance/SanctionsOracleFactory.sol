// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISanctionsOracle} from "../interfaces/compliance/ISanctionsOracle.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

/**
 * @title SanctionsOracleFactory
 * @notice Deploys SanctionsOracle instances behind a shared UpgradeableBeacon.
 *   - All oracles share the same implementation contract
 *   - Beacon owner can upgrade all oracles atomically via UpgradeableBeacon.upgradeTo()
 *   - Supports two deployment modes:
 *       1. deployOracle()          — deploy only, caller initializes later
 *       2. deployAndInitOracle()   — deploy + initialize atomically
 *   - Oracle instances are exclusively deployed via BeaconProxy
 */
contract SanctionsOracleFactory {
    // =============================================================
    // Errors
    // =============================================================

    error Factory__ZeroAddress();

    // =============================================================
    // Events
    // =============================================================

    event OracleDeployed(address indexed oracle, uint256 index, bool initialized);

    // =============================================================
    // State
    // =============================================================

    UpgradeableBeacon public immutable BEACON;
    address[] public oracles;

    // =============================================================
    // Constructor
    // =============================================================

    /**
     * @param impl Address of the SanctionsOracle implementation contract (locked via _disableInitializers)
     * @param beaconOwner Address that controls beacon upgrades (e.g. multisig / timelock)
     */
    constructor(address impl, address beaconOwner) {
        if (impl == address(0) || beaconOwner == address(0)) revert Factory__ZeroAddress();
        BEACON = new UpgradeableBeacon(impl, beaconOwner);
    }

    // =============================================================
    // Oracle Deployment
    // =============================================================

    /**
     * @notice Deploy an uninitialized SanctionsOracle as a BeaconProxy.
     *         Caller must call oracle.initialize(...) separately afterwards.
     * @dev Use this when the admin / compliance bot addresses are not yet finalized.
     *      IMPORTANT: The oracle is unprotected until initialized. In production,
     *      batch deploy + initialize in a single transaction to prevent front-running.
     */
    function deployOracle() external returns (address oracle) {
        BeaconProxy proxy = new BeaconProxy(address(BEACON), "");
        oracle = address(proxy);
        oracles.push(oracle);

        emit OracleDeployed(oracle, oracles.length - 1, false);
    }

    /**
     * @notice Deploy and atomically initialize a SanctionsOracle as a BeaconProxy.
     *         Use this when admin and compliance bot addresses are already known.
     * @param admin Address granted DEFAULT_ADMIN_ROLE (typically a multisig / timelock)
     * @param complianceBot Address granted COMPLIANCE_ROLE (off-chain Sanctions Service wallet)
     */
    function deployAndInitOracle(address admin, address complianceBot) external returns (address oracle) {
        bytes memory initData = abi.encodeCall(ISanctionsOracle.initialize, (admin, complianceBot));

        BeaconProxy proxy = new BeaconProxy(address(BEACON), initData);
        oracle = address(proxy);
        oracles.push(oracle);

        emit OracleDeployed(oracle, oracles.length - 1, true);
    }

    // =============================================================
    // View Functions
    // =============================================================

    function oracleCount() external view returns (uint256) {
        return oracles.length;
    }

    function implementation() external view returns (address) {
        return BEACON.implementation();
    }

    function getAllOracles() external view returns (address[] memory) {
        return oracles;
    }
}
