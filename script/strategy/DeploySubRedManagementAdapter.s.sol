// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SubRedManagementAdapter} from "../../src/adapters/digift/SubRedManagementAdapter.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @title DeploySubRedManagementAdapter
/// @notice Deploy a SubRed adapter using the signer configured by `forge script`.
///         Also configures venue step sizes and min subscribe/redeem amounts so the
///         adapter lands in a production-ready state in a single broadcast.
///
/// Required env:
/// - ADAPTER_VAULT
/// - ADAPTER_SUBRED_MANAGEMENT
/// - ADAPTER_ST_TOKEN
/// - ADAPTER_ADMIN
/// - ADAPTER_CONTROLLER
/// - ADAPTER_ACCOUNTANT
///
/// Optional env (default 0 — adapter treats zero as "no constraint"):
/// - ADAPTER_PRICE_ORACLE                 (default: address(0))
/// - ADAPTER_MANUAL_POS_TOKEN_PRICE       (default: 0)  asset per 1 pos token, 1e18 precision
/// - ADAPTER_SUBSCRIBE_STEP_ASSET         (default: 0)  step size for subscribe, asset raw units
/// - ADAPTER_REDEEM_STEP_POS              (default: 0)  step size for redeem, posToken raw units
/// - ADAPTER_MIN_SUBSCRIBE_ASSET          (default: 0)  min subscribe amount, asset raw units
/// - ADAPTER_MIN_REDEEM_POS               (default: 0)  min redeem amount, posToken raw units
contract DeploySubRedManagementAdapter is Script {
    function run() external {
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

        vm.startBroadcast();

        SubRedManagementAdapter adapter = new SubRedManagementAdapter(
            vault_, subRedManagement, stToken, admin, controllerAddr, accountantAddr, priceOracle
        );

        if (manualPosTokenPrice != 0) {
            require(priceOracle == address(0), "MANUAL_PRICE_WITH_ORACLE");
            adapter.setManualPosTokenPrice(manualPosTokenPrice);
        }

        // Only call setters when non-zero config is provided, so zero-config deploys
        // don't emit redundant setter txs. Roles are granted in the constructor; if the
        // broadcast signer lacks the matching role, these calls will revert.
        if (minSubscribeAsset != 0 || subscribeStepAsset != 0 || minRedeemPos != 0 || redeemStepPos != 0) {
            adapter.setExecutionConstraints(minSubscribeAsset, subscribeStepAsset, minRedeemPos, redeemStepPos);
        }

        vm.stopBroadcast();

        console2.log("=== SubRedManagementAdapter deployed ===");
        console2.log("adapter             :", address(adapter));
        console2.log("vault               :", vault_);
        console2.log("controller          :", controllerAddr);
        console2.log("accountant          :", accountantAddr);
        console2.log("st token            :", stToken);
        console2.log("subred management   :", subRedManagement);
        console2.log("price oracle        :", priceOracle);
        console2.log("manual pos price    :", manualPosTokenPrice);
        console2.log("subscribeStepAsset  :", subscribeStepAsset);
        console2.log("redeemStepPos       :", redeemStepPos);
        console2.log("minSubscribeAsset   :", minSubscribeAsset);
        console2.log("minRedeemPos        :", minRedeemPos);
    }
}
