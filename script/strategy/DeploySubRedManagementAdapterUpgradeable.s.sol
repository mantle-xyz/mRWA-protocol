// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SubRedManagementAdapterFactory} from "../../src/adapters/digift/SubRedManagementAdapterFactory.sol";
import {SubRedManagementAdapter} from "../../src/adapters/digift/SubRedManagementAdapterUpgradeable.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @title DeploySubRedManagementAdapterUpgradeable
/// @notice Deploy a SubRed adapter as a BeaconProxy via SubRedManagementAdapterFactory.
///         Uses the upgradeable SubRedManagementAdapter (ERC-7201 storage, initializer pattern).
///         Also configures venue step sizes and min subscribe/redeem amounts so the
///         adapter lands in a production-ready state in a single broadcast.
///
/// Required env:
/// - ADAPTER_FACTORY                          SubRedManagementAdapterFactory address
/// - ADAPTER_VAULT
/// - ADAPTER_SUBRED_MANAGEMENT
/// - ADAPTER_ST_TOKEN
/// - ADAPTER_ADMIN
/// - ADAPTER_CONTROLLER
/// - ADAPTER_ACCOUNTANT
///
/// Optional env (default 0 — adapter treats zero as "no constraint"):
/// - ADAPTER_PRICE_ORACLE                     (default: address(0))
/// - ADAPTER_MANUAL_POS_TOKEN_PRICE           (default: 0)  asset per 1 pos token, 1e18 precision
/// - ADAPTER_SUBSCRIBE_STEP_ASSET             (default: 0)  step size for subscribe, asset raw units
/// - ADAPTER_REDEEM_STEP_POS                  (default: 0)  step size for redeem, posToken raw units
/// - ADAPTER_MIN_SUBSCRIBE_ASSET              (default: 0)  min subscribe amount, asset raw units
/// - ADAPTER_MIN_REDEEM_POS                   (default: 0)  min redeem amount, posToken raw units
contract DeploySubRedManagementAdapterUpgradeable is Script {
    function run() external returns (address adapterAddr) {
        SubRedManagementAdapterFactory factory = SubRedManagementAdapterFactory(vm.envAddress("ADAPTER_FACTORY"));

        address vault_ = vm.envAddress("ADAPTER_VAULT");
        address subRedManagement = vm.envAddress("ADAPTER_SUBRED_MANAGEMENT");
        address stToken = vm.envAddress("ADAPTER_ST_TOKEN");
        address admin = vm.envAddress("ADAPTER_ADMIN");
        address controllerAddr = vm.envAddress("ADAPTER_CONTROLLER");
        address accountantAddr = vm.envAddress("ADAPTER_ACCOUNTANT");
        address priceOracle = vm.envOr("ADAPTER_PRICE_ORACLE", address(0));
        uint256 manualPosTokenPrice = vm.envOr("ADAPTER_MANUAL_POS_TOKEN_PRICE", uint256(0));

        uint256 subscribeStepAsset = vm.envOr("ADAPTER_SUBSCRIBE_STEP_ASSET", uint256(0));
        uint256 redeemStepPos = vm.envOr("ADAPTER_REDEEM_STEP_POS", uint256(0));
        uint256 minSubscribeAsset = vm.envOr("ADAPTER_MIN_SUBSCRIBE_ASSET", uint256(0));
        uint256 minRedeemPos = vm.envOr("ADAPTER_MIN_REDEEM_POS", uint256(0));

        console2.log("=== DeploySubRedManagementAdapterUpgradeable ===");
        console2.log("Factory             :", address(factory));
        console2.log("Beacon              :", address(factory.BEACON()));
        console2.log("Beacon impl         :", factory.implementation());
        console2.log("Vault               :", vault_);
        console2.log("Controller          :", controllerAddr);
        console2.log("Accountant          :", accountantAddr);
        console2.log("ST Token            :", stToken);
        console2.log("SubRed Management   :", subRedManagement);
        console2.log("Price Oracle        :", priceOracle);
        console2.log("Manual Pos Price    :", manualPosTokenPrice);

        vm.startBroadcast();

        adapterAddr = factory.deployAndInitAdapter(
            vault_, subRedManagement, stToken, admin, controllerAddr, accountantAddr, priceOracle
        );

        SubRedManagementAdapter adapter = SubRedManagementAdapter(adapterAddr);

        if (manualPosTokenPrice != 0) {
            require(priceOracle == address(0), "MANUAL_PRICE_WITH_ORACLE");
            adapter.setManualPosTokenPrice(manualPosTokenPrice);
        }

        if (minSubscribeAsset != 0 || subscribeStepAsset != 0 || minRedeemPos != 0 || redeemStepPos != 0) {
            adapter.setExecutionConstraints(minSubscribeAsset, subscribeStepAsset, minRedeemPos, redeemStepPos);
        }

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Deployment Result ===");
        console2.log("Adapter (proxy)     :", adapterAddr);
        console2.log("Adapter vault       :", adapter.vault());
        console2.log("Adapter pos token   :", adapter.posToken());
        console2.log("Adapter price oracle:", adapter.priceOracle());
        console2.log("Adapter count       :", factory.adapterCount());
        console2.log("subscribeStepAsset  :", subscribeStepAsset);
        console2.log("redeemStepPos       :", redeemStepPos);
        console2.log("minSubscribeAsset   :", minSubscribeAsset);
        console2.log("minRedeemPos        :", minRedeemPos);
    }
}
