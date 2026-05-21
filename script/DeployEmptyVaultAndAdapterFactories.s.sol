// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EmptyImplementation} from "../src/EmptyImplementation.sol";
import {SubRedManagementAdapterFactory} from "../src/adapters/digift/SubRedManagementAdapterFactory.sol";
import {VaultFactory} from "../src/vault/VaultFactory.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @title DeployEmptyVaultAndAdapterFactories
/// @notice Deploys VaultFactory and SubRedManagementAdapterFactory with an empty implementation.
///         Also deploys one uninitialized BeaconProxy from each factory so addresses can be
///         wired before the real implementations are deployed.
///
/// Required env:
/// - DEPLOY_EMPTY_FACTORIES_BEACON_OWNER  beacon owner for both factories
contract DeployEmptyVaultAndAdapterFactories is Script {
    function run()
        external
        returns (
            EmptyImplementation emptyImpl,
            VaultFactory vaultFactory,
            SubRedManagementAdapterFactory adapterFactory,
            address vaultProxy,
            address adapterProxy
        )
    {
        address admin = vm.envAddress("DEPLOY_EMPTY_FACTORIES_BEACON_OWNER");

        console2.log("=== Deploy Empty Vault + Adapter Factories ===");
        console2.log("Beacon owner:", admin);

        vm.startBroadcast();

        emptyImpl = new EmptyImplementation();
        vaultFactory = new VaultFactory(address(emptyImpl), admin);
        adapterFactory = new SubRedManagementAdapterFactory(address(emptyImpl), admin);

        vaultProxy = vaultFactory.deployVault();
        adapterProxy = adapterFactory.deployAdapter();

        vm.stopBroadcast();

        console2.log("Empty impl           :", address(emptyImpl));
        console2.log("VaultFactory         :", address(vaultFactory));
        console2.log("Vault beacon         :", address(vaultFactory.BEACON()));
        console2.log("Vault proxy (uninit) :", vaultProxy);
        console2.log("AdapterFactory       :", address(adapterFactory));
        console2.log("Adapter beacon       :", address(adapterFactory.BEACON()));
        console2.log("Adapter proxy(uninit):", adapterProxy);
    }
}
