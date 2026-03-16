// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMantleVaultGateway} from "../interfaces/vault/IMantleVaultGateway.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

/**
 * @title GatewayFactory
 * @notice Deploys MantleVaultGateway instances behind a shared UpgradeableBeacon.
 */
contract GatewayFactory {
    error Factory__ZeroAddress();

    event GatewayDeployed(address indexed gateway, uint256 index, bool initialized);

    UpgradeableBeacon public immutable BEACON;
    address[] public gateways;

    constructor(address impl, address beaconOwner) {
        if (impl == address(0) || beaconOwner == address(0)) revert Factory__ZeroAddress();
        BEACON = new UpgradeableBeacon(impl, beaconOwner);
    }

    function deployGateway() external returns (address gateway) {
        BeaconProxy proxy = new BeaconProxy(address(BEACON), "");
        gateway = address(proxy);
        gateways.push(gateway);
        emit GatewayDeployed(gateway, gateways.length - 1, false);
    }

    function deployAndInitGateway(IMantleVaultGateway.InitParams calldata params) external returns (address gateway) {
        bytes memory initData = abi.encodeCall(IMantleVaultGateway.initialize, (params));
        BeaconProxy proxy = new BeaconProxy(address(BEACON), initData);
        gateway = address(proxy);
        gateways.push(gateway);
        emit GatewayDeployed(gateway, gateways.length - 1, true);
    }

    function gatewayCount() external view returns (uint256) {
        return gateways.length;
    }

    function implementation() external view returns (address) {
        return BEACON.implementation();
    }

    function getAllGateways() external view returns (address[] memory) {
        return gateways;
    }
}

