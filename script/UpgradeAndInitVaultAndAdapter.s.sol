// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SubRedManagementAdapterFactory} from "../src/adapters/digift/SubRedManagementAdapterFactory.sol";
import {SubRedManagementAdapter} from "../src/adapters/digift/SubRedManagementAdapterUpgradeable.sol";
import {IMantleYieldVault} from "../src/interfaces/vault/IMantleYieldVault.sol";
import {MantleYieldVault} from "../src/vault/MantleYieldVault.sol";
import {VaultFactory} from "../src/vault/VaultFactory.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @title UpgradeAndInitVaultAndAdapter
/// @notice Upgrades placeholder Vault/Adapter beacon implementations to real implementations,
///         then initializes one Vault proxy and one SubRedManagementAdapter proxy.
///
/// Required env:
/// - UPGRADE_INIT_VAULT_FACTORY
/// - UPGRADE_INIT_SUBRED_ADAPTER_FACTORY
/// - UPGRADE_INIT_VAULT_PROXY
/// - UPGRADE_INIT_ADAPTER_PROXY
/// - UPGRADE_INIT_ADMIN
/// - UPGRADE_INIT_USDC
/// - UPGRADE_INIT_GATEWAY
/// - UPGRADE_INIT_CONTROLLER
/// - UPGRADE_INIT_ACCOUNTANT
/// - UPGRADE_INIT_TREASURY
/// - UPGRADE_INIT_PAUSER
/// - UPGRADE_INIT_MAX_REDEMPTION_FEE_BPS
/// - UPGRADE_INIT_REDEMPTION_FEE_BPS
/// - UPGRADE_INIT_MIN_REDEEM_AMOUNT
/// - UPGRADE_INIT_MIN_DEPOSIT_AMOUNT
/// - UPGRADE_INIT_ADAPTER_SUBRED_MANAGEMENT
/// - UPGRADE_INIT_ADAPTER_ST_TOKEN
/// - UPGRADE_INIT_ADAPTER_ADMIN
/// - UPGRADE_INIT_ADAPTER_CONTROLLER
/// - UPGRADE_INIT_ADAPTER_ACCOUNTANT
///
/// Optional env:
/// - UPGRADE_INIT_VAULT_NAME                       default "Mantle RWA Vault"
/// - UPGRADE_INIT_VAULT_SYMBOL                     default "mRWA"
/// - UPGRADE_INIT_ADAPTER_PRICE_ORACLE             default address(0)
/// - UPGRADE_INIT_ADAPTER_MANUAL_POS_TOKEN_PRICE   default 0
/// - UPGRADE_INIT_ADAPTER_SUBSCRIBE_STEP_ASSET     default 0
/// - UPGRADE_INIT_ADAPTER_REDEEM_STEP_POS          default 0
/// - UPGRADE_INIT_ADAPTER_MIN_SUBSCRIBE_ASSET      default 0
/// - UPGRADE_INIT_ADAPTER_MIN_REDEEM_POS           default 0
/// - UPGRADE_INIT_SETTLE_MS                        default 5000
contract UpgradeAndInitVaultAndAdapter is Script {
    function run() external returns (MantleYieldVault vault, SubRedManagementAdapter adapter) {
        VaultFactory vaultFactory = VaultFactory(vm.envAddress("UPGRADE_INIT_VAULT_FACTORY"));
        SubRedManagementAdapterFactory adapterFactory =
            SubRedManagementAdapterFactory(vm.envAddress("UPGRADE_INIT_SUBRED_ADAPTER_FACTORY"));

        address vaultProxy = vm.envAddress("UPGRADE_INIT_VAULT_PROXY");
        address adapterProxy = vm.envAddress("UPGRADE_INIT_ADAPTER_PROXY");
        address admin = vm.envAddress("UPGRADE_INIT_ADMIN");
        address pauser = vm.envAddress("UPGRADE_INIT_PAUSER");

        IMantleYieldVault.InitParams memory vaultParams = IMantleYieldVault.InitParams({
            asset: IERC20(vm.envAddress("UPGRADE_INIT_USDC")),
            name: vm.envOr("UPGRADE_INIT_VAULT_NAME", string("Mantle RWA Vault")),
            symbol: vm.envOr("UPGRADE_INIT_VAULT_SYMBOL", string("mRWA")),
            admin: admin,
            gateway: vm.envAddress("UPGRADE_INIT_GATEWAY"),
            controller: vm.envAddress("UPGRADE_INIT_CONTROLLER"),
            accountant: vm.envAddress("UPGRADE_INIT_ACCOUNTANT"),
            treasury: vm.envAddress("UPGRADE_INIT_TREASURY"),
            maxRedemptionFeeBps: vm.envUint("UPGRADE_INIT_MAX_REDEMPTION_FEE_BPS"),
            redemptionFeeBps: vm.envUint("UPGRADE_INIT_REDEMPTION_FEE_BPS"),
            minRedeemAmount: vm.envUint("UPGRADE_INIT_MIN_REDEEM_AMOUNT"),
            minDepositAmount: vm.envUint("UPGRADE_INIT_MIN_DEPOSIT_AMOUNT"),
            maxSettlementDeviationBps: vm.envOr("UPGRADE_INIT_MAX_SETTLEMENT_DEVIATION_BPS", uint256(1000)),
            depositDailyRemaining: vm.envOr("UPGRADE_INIT_DEPOSIT_DAILY_REMAINING", type(uint256).max),
            redeemDailyRemaining: vm.envOr("UPGRADE_INIT_REDEEM_DAILY_REMAINING", type(uint256).max)
        });

        address subRedManagement = vm.envAddress("UPGRADE_INIT_ADAPTER_SUBRED_MANAGEMENT");
        address stToken = vm.envAddress("UPGRADE_INIT_ADAPTER_ST_TOKEN");
        address adapterAdmin = vm.envAddress("UPGRADE_INIT_ADAPTER_ADMIN");
        address adapterController = vm.envAddress("UPGRADE_INIT_ADAPTER_CONTROLLER");
        address adapterAccountant = vm.envAddress("UPGRADE_INIT_ADAPTER_ACCOUNTANT");
        address adapterPriceOracle = vm.envOr("UPGRADE_INIT_ADAPTER_PRICE_ORACLE", address(0));

        uint256 manualPosTokenPrice = vm.envOr("UPGRADE_INIT_ADAPTER_MANUAL_POS_TOKEN_PRICE", uint256(0));
        uint256 subscribeStepAsset = vm.envOr("UPGRADE_INIT_ADAPTER_SUBSCRIBE_STEP_ASSET", uint256(0));
        uint256 redeemStepPos = vm.envOr("UPGRADE_INIT_ADAPTER_REDEEM_STEP_POS", uint256(0));
        uint256 minSubscribeAsset = vm.envOr("UPGRADE_INIT_ADAPTER_MIN_SUBSCRIBE_ASSET", uint256(0));
        uint256 minRedeemPos = vm.envOr("UPGRADE_INIT_ADAPTER_MIN_REDEEM_POS", uint256(0));
        uint256 settleMs = vm.envOr("UPGRADE_INIT_SETTLE_MS", uint256(5000));

        UpgradeableBeacon vaultBeacon = vaultFactory.BEACON();
        UpgradeableBeacon adapterBeacon = adapterFactory.BEACON();

        console2.log("=== Upgrade + Initialize Vault + Adapter ===");
        console2.log("VaultFactory        :", address(vaultFactory));
        console2.log("Vault proxy         :", vaultProxy);
        console2.log("Old vault impl      :", vaultBeacon.implementation());
        console2.log("AdapterFactory      :", address(adapterFactory));
        console2.log("Adapter proxy       :", adapterProxy);
        console2.log("Old adapter impl    :", adapterBeacon.implementation());

        vm.startBroadcast();
        MantleYieldVault vaultImpl = new MantleYieldVault();
        SubRedManagementAdapter adapterImpl = new SubRedManagementAdapter();
        vm.stopBroadcast();
        console2.log("[1/7] Implementations deployed");
        _settleBlock(settleMs);

        vm.startBroadcast();
        vaultBeacon.upgradeTo(address(vaultImpl));
        vm.stopBroadcast();
        console2.log("[2/7] Vault beacon upgraded");
        _settleBlock(settleMs);

        vm.startBroadcast();
        adapterBeacon.upgradeTo(address(adapterImpl));
        vm.stopBroadcast();
        console2.log("[3/7] Adapter beacon upgraded");
        _settleBlock(settleMs);

        vault = MantleYieldVault(vaultProxy);
        if (!_vaultInitialized(vault, admin)) {
            vm.startBroadcast();
            vault.initialize(vaultParams);
            vm.stopBroadcast();
            console2.log("[4/7] Vault initialized");
            _settleBlock(settleMs);
        } else {
            console2.log("[4/7] Vault already initialized, skip");
        }

        if (!vault.hasRole(vault.PAUSER_ROLE(), pauser)) {
            vm.startBroadcast();
            vault.grantRole(vault.PAUSER_ROLE(), pauser);
            vm.stopBroadcast();
            console2.log("[5/7] Vault PAUSER_ROLE granted");
            _settleBlock(settleMs);
        } else {
            console2.log("[5/7] Vault PAUSER_ROLE already granted, skip");
        }

        adapter = SubRedManagementAdapter(adapterProxy);
        if (!_adapterInitialized(adapter, vaultProxy)) {
            vm.startBroadcast();
            adapter.initialize(
                vaultProxy,
                subRedManagement,
                stToken,
                adapterAdmin,
                adapterController,
                adapterAccountant,
                adapterPriceOracle
            );
            vm.stopBroadcast();
            console2.log("[6/7] Adapter initialized");
            _settleBlock(settleMs);
        } else {
            console2.log("[6/7] Adapter already initialized, skip");
        }

        if (manualPosTokenPrice != 0) {
            require(adapterPriceOracle == address(0), "MANUAL_PRICE_WITH_ORACLE");
            vm.startBroadcast();
            adapter.setManualPosTokenPrice(manualPosTokenPrice);
            vm.stopBroadcast();
            console2.log("[7/7] Adapter manual price set");
            _settleBlock(settleMs);
        }

        if (minSubscribeAsset != 0 || subscribeStepAsset != 0 || minRedeemPos != 0 || redeemStepPos != 0) {
            if (!_executionConstraintsMatch(
                    adapter, minSubscribeAsset, subscribeStepAsset, minRedeemPos, redeemStepPos
                )) {
                vm.startBroadcast();
                adapter.setExecutionConstraints(minSubscribeAsset, subscribeStepAsset, minRedeemPos, redeemStepPos);
                vm.stopBroadcast();
                console2.log("[7/7] Adapter execution constraints set");
                _settleBlock(settleMs);
            } else {
                console2.log("[7/7] Adapter execution constraints already set, skip");
            }
        }

        console2.log("New vault impl      :", address(vaultImpl));
        console2.log("New adapter impl    :", address(adapterImpl));
        console2.log("");
        console2.log("=== Post-init Verification ===");
        console2.log("Vault beacon impl   :", vaultBeacon.implementation());
        console2.log("Adapter beacon impl :", adapterBeacon.implementation());
        console2.log("Vault asset         :", vault.asset());
        console2.log("Vault gateway       :", vault.gateway());
        console2.log("Vault has admin     :", vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
        console2.log("Vault has pauser    :", vault.hasRole(vault.PAUSER_ROLE(), pauser));
        console2.log("Adapter vault       :", adapter.vault());
        console2.log("Adapter pos token   :", adapter.posToken());
        console2.log("Adapter price oracle:", adapter.priceOracle());
    }

    function _vaultInitialized(MantleYieldVault vault, address admin) internal view returns (bool) {
        try vault.hasRole(bytes32(0), admin) returns (bool hasAdmin) {
            return hasAdmin;
        } catch {
            return false;
        }
    }

    function _adapterInitialized(SubRedManagementAdapter adapter, address expectedVault) internal view returns (bool) {
        try adapter.vault() returns (address currentVault) {
            return currentVault == expectedVault;
        } catch {
            return false;
        }
    }

    function _executionConstraintsMatch(
        SubRedManagementAdapter adapter,
        uint256 minSubscribeAsset,
        uint256 subscribeStepAsset,
        uint256 minRedeemPos,
        uint256 redeemStepPos
    ) internal view returns (bool) {
        try adapter.executionConstraints() returns (SubRedManagementAdapter.ExecutionConstraints memory c) {
            return c.minSubscribeAsset == minSubscribeAsset && c.subscribeStepAsset == subscribeStepAsset
                && c.minRedeemPos == minRedeemPos && c.redeemStepPos == redeemStepPos;
        } catch {
            return false;
        }
    }

    function _settleBlock(uint256 settleMs) internal {
        if (settleMs == 0) return;
        vm.sleep(settleMs);
    }
}
