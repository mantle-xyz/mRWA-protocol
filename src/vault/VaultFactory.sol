// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMantleYieldVault} from "../interfaces/vault/IMantleYieldVault.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

/**
 * @title VaultFactory
 * @notice Deploys MantleYieldVault instances behind a shared UpgradeableBeacon.
 *   - All vaults share the same implementation contract
 *   - Beacon owner can upgrade all vaults atomically via UpgradeableBeacon.upgradeTo()
 *   - Supports two deployment modes:
 *       1. deployVault()          — deploy only, caller initializes later
 *       2. deployAndInitVault()   — deploy + initialize atomically
 *   - Vault instances are exclusively deployed via BeaconProxy
 */
contract VaultFactory {
    // =============================================================
    // Errors
    // =============================================================

    error Factory__ZeroAddress();

    // =============================================================
    // Events
    // =============================================================

    event VaultDeployed(address indexed vault, uint256 index, bool initialized);

    // =============================================================
    // State
    // =============================================================

    UpgradeableBeacon public immutable BEACON;
    address[] public vaults;

    // =============================================================
    // Constructor
    // =============================================================

    /**
     * @param impl Address of the MantleYieldVault implementation contract
     * @param beaconOwner Address that controls beacon upgrades (e.g. multisig / timelock)
     */
    constructor(address impl, address beaconOwner) {
        if (impl == address(0) || beaconOwner == address(0)) revert Factory__ZeroAddress();
        BEACON = new UpgradeableBeacon(impl, beaconOwner);
    }

    // =============================================================
    // Vault Deployment
    // =============================================================

    /**
     * @notice Deploy an uninitialized MantleYieldVault as a BeaconProxy.
     *         Caller must call vault.initialize(...) separately afterwards.
     * @dev Use this when dependent contract addresses (controller, accountant, etc.)
     *      are not yet known at deployment time. The typical flow:
     *        1. vault = factory.deployVault()
     *        2. Deploy controller/accountant with vault address
     *        3. vault.initialize(asset, name, symbol, admin, oracle, controller, accountant, fee, minRedeem)
     *      IMPORTANT: The vault is unprotected until initialized. In production,
     *      batch steps 1-3 in a single transaction (e.g. via deploy script / multicall)
     *      to prevent front-running.
     */
    function deployVault() external returns (address vault) {
        BeaconProxy proxy = new BeaconProxy(address(BEACON), "");
        vault = address(proxy);
        vaults.push(vault);

        emit VaultDeployed(vault, vaults.length - 1, false);
    }

    /**
     * @notice Deploy and atomically initialize a MantleYieldVault as a BeaconProxy.
     *         Use this when all dependent addresses are already known.
     */
    function deployAndInitVault(IMantleYieldVault.InitParams calldata params) external returns (address vault) {
        bytes memory initData = abi.encodeCall(IMantleYieldVault.initialize, (params));

        BeaconProxy proxy = new BeaconProxy(address(BEACON), initData);
        vault = address(proxy);
        vaults.push(vault);

        emit VaultDeployed(vault, vaults.length - 1, true);
    }

    // =============================================================
    // View Functions
    // =============================================================

    function vaultCount() external view returns (uint256) {
        return vaults.length;
    }

    function implementation() external view returns (address) {
        return BEACON.implementation();
    }

    function getAllVaults() external view returns (address[] memory) {
        return vaults;
    }
}
