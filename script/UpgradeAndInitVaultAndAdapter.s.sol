// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Accountant} from "../src/accountant/Accountant.sol";
import {SubRedManagementAdapterFactory} from "../src/adapters/digift/SubRedManagementAdapterFactory.sol";
import {SubRedManagementAdapter} from "../src/adapters/digift/SubRedManagementAdapterUpgradeable.sol";
import {IMantleYieldVault} from "../src/interfaces/vault/IMantleYieldVault.sol";
import {StrategyController} from "../src/protocol/StrategyController.sol";
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
/// - UPGRADE_INIT_CONTROLLER                  StrategyController BeaconProxy (uninit, from Phase A)
/// - UPGRADE_INIT_ACCOUNTANT                  Accountant BeaconProxy (uninit, from Phase A)
/// - UPGRADE_INIT_ACCOUNTANT_EXECUTOR         AccountantExecutor UUPS proxy (init, from Phase A)
/// - UPGRADE_INIT_OPERATOR_EXECUTOR           OperatorExecutor UUPS proxy (init, from Phase A)
/// - UPGRADE_INIT_TREASURY
/// - UPGRADE_INIT_PAUSER
/// - UPGRADE_INIT_CAP_MANAGER
/// - UPGRADE_INIT_MAX_REDEMPTION_FEE_BPS
/// - UPGRADE_INIT_REDEMPTION_FEE_BPS
/// - UPGRADE_INIT_MIN_REDEEM_AMOUNT
/// - UPGRADE_INIT_MIN_DEPOSIT_AMOUNT
/// - UPGRADE_INIT_ADAPTER_SUBRED_MANAGEMENT
/// - UPGRADE_INIT_ADAPTER_ST_TOKEN
/// - UPGRADE_INIT_ADAPTER_ADMIN
/// - UPGRADE_INIT_ADAPTER_CONTROLLER
/// - UPGRADE_INIT_ADAPTER_ACCOUNTANT
/// - F_INITIAL_RATE                           Accountant.initialize starting exchange rate (1e18)
/// - F_MANAGEMENT_FEE_BPS                     Accountant.initialize management fee bps
/// - F_BUFFER_TARGET_BPS                      StrategyController.initialize buffer target
/// - F_REBALANCE_THRESHOLD_BPS                StrategyController.initialize rebalance threshold
/// - F_REBALANCE_COOLDOWN                     StrategyController.initialize rebalance cooldown (s)
/// - F_SENDER                                 optional preflight; when set, must equal UPGRADE_INIT_ADMIN
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
        address vaultFactoryAddr = vm.envOr("UPGRADE_INIT_VAULT_FACTORY", address(0));
        address adapterFactoryAddr = vm.envOr("UPGRADE_INIT_SUBRED_ADAPTER_FACTORY", address(0));
        address vaultProxy = vm.envOr("UPGRADE_INIT_VAULT_PROXY", address(0));
        address adapterProxy = vm.envOr("UPGRADE_INIT_ADAPTER_PROXY", address(0));
        address admin = vm.envOr("UPGRADE_INIT_ADMIN", address(0));
        address pauser = vm.envOr("UPGRADE_INIT_PAUSER", address(0));
        address capManager = vm.envOr("UPGRADE_INIT_CAP_MANAGER", address(0));
        address usdc = vm.envOr("UPGRADE_INIT_USDC", address(0));
        address gateway = vm.envOr("UPGRADE_INIT_GATEWAY", address(0));
        address treasury = vm.envOr("UPGRADE_INIT_TREASURY", address(0));
        address controllerProxy = vm.envOr("UPGRADE_INIT_CONTROLLER", address(0));
        address accountantProxy = vm.envOr("UPGRADE_INIT_ACCOUNTANT", address(0));
        address accountantExecutor = vm.envOr("UPGRADE_INIT_ACCOUNTANT_EXECUTOR", address(0));
        address operatorExecutor = vm.envOr("UPGRADE_INIT_OPERATOR_EXECUTOR", address(0));
        uint64 initialRate = uint64(vm.envUint("F_INITIAL_RATE"));
        uint32 managementFeeBps = uint32(vm.envUint("F_MANAGEMENT_FEE_BPS"));
        uint16 bufferTargetBps = uint16(vm.envUint("F_BUFFER_TARGET_BPS"));
        uint16 rebalanceThresholdBps = uint16(vm.envUint("F_REBALANCE_THRESHOLD_BPS"));
        uint64 rebalanceCooldown = uint64(vm.envUint("F_REBALANCE_COOLDOWN"));

        _requireNonZero(vaultFactoryAddr, "UPGRADE_INIT_VAULT_FACTORY");
        _requireNonZero(adapterFactoryAddr, "UPGRADE_INIT_SUBRED_ADAPTER_FACTORY");
        _requireNonZero(vaultProxy, "UPGRADE_INIT_VAULT_PROXY");
        _requireNonZero(adapterProxy, "UPGRADE_INIT_ADAPTER_PROXY");
        _requireNonZero(admin, "UPGRADE_INIT_ADMIN");
        _requireNonZero(pauser, "UPGRADE_INIT_PAUSER");
        _requireNonZero(capManager, "UPGRADE_INIT_CAP_MANAGER");
        _requireNonZero(usdc, "UPGRADE_INIT_USDC");
        _requireNonZero(gateway, "UPGRADE_INIT_GATEWAY");
        _requireNonZero(treasury, "UPGRADE_INIT_TREASURY");
        _requireNonZero(controllerProxy, "UPGRADE_INIT_CONTROLLER");
        _requireNonZero(accountantProxy, "UPGRADE_INIT_ACCOUNTANT");
        _requireNonZero(accountantExecutor, "UPGRADE_INIT_ACCOUNTANT_EXECUTOR");
        _requireNonZero(operatorExecutor, "UPGRADE_INIT_OPERATOR_EXECUTOR");
        _requireConfiguredSenderIsAdmin(admin);

        VaultFactory vaultFactory = VaultFactory(vaultFactoryAddr);
        SubRedManagementAdapterFactory adapterFactory = SubRedManagementAdapterFactory(adapterFactoryAddr);

        IMantleYieldVault.InitParams memory vaultParams = IMantleYieldVault.InitParams({
            asset: IERC20(usdc),
            name: vm.envOr("UPGRADE_INIT_VAULT_NAME", string("Mantle RWA Vault")),
            symbol: vm.envOr("UPGRADE_INIT_VAULT_SYMBOL", string("mRWA")),
            admin: admin,
            gateway: gateway,
            controller: controllerProxy,
            accountant: accountantProxy,
            treasury: treasury,
            maxRedemptionFeeBps: vm.envUint("UPGRADE_INIT_MAX_REDEMPTION_FEE_BPS"),
            redemptionFeeBps: vm.envUint("UPGRADE_INIT_REDEMPTION_FEE_BPS"),
            minRedeemAmount: vm.envUint("UPGRADE_INIT_MIN_REDEEM_AMOUNT"),
            minDepositAmount: vm.envUint("UPGRADE_INIT_MIN_DEPOSIT_AMOUNT"),
            maxSettlementDeviationBps: vm.envOr("UPGRADE_INIT_MAX_SETTLEMENT_DEVIATION_BPS", uint256(1000)),
            depositDailyRemaining: vm.envOr("UPGRADE_INIT_DEPOSIT_DAILY_REMAINING", type(uint256).max),
            redeemDailyRemaining: vm.envOr("UPGRADE_INIT_REDEEM_DAILY_REMAINING", type(uint256).max)
        });

        address subRedManagement = vm.envOr("UPGRADE_INIT_ADAPTER_SUBRED_MANAGEMENT", address(0));
        address stToken = vm.envOr("UPGRADE_INIT_ADAPTER_ST_TOKEN", address(0));
        address adapterAdmin = vm.envOr("UPGRADE_INIT_ADAPTER_ADMIN", address(0));
        address adapterController = vm.envOr("UPGRADE_INIT_ADAPTER_CONTROLLER", address(0));
        address adapterAccountant = vm.envOr("UPGRADE_INIT_ADAPTER_ACCOUNTANT", address(0));
        address adapterPriceOracle = vm.envOr("UPGRADE_INIT_ADAPTER_PRICE_ORACLE", address(0));

        _requireNonZero(subRedManagement, "UPGRADE_INIT_ADAPTER_SUBRED_MANAGEMENT");
        _requireNonZero(stToken, "UPGRADE_INIT_ADAPTER_ST_TOKEN");
        _requireNonZero(adapterAdmin, "UPGRADE_INIT_ADAPTER_ADMIN");
        _requireNonZero(adapterController, "UPGRADE_INIT_ADAPTER_CONTROLLER");
        _requireNonZero(adapterAccountant, "UPGRADE_INIT_ADAPTER_ACCOUNTANT");

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
        console2.log("[1/9] Implementations deployed");
        _settleBlock(settleMs);

        vm.startBroadcast();
        vaultBeacon.upgradeTo(address(vaultImpl));
        vm.stopBroadcast();
        console2.log("[2/9] Vault beacon upgraded");
        _settleBlock(settleMs);

        vm.startBroadcast();
        adapterBeacon.upgradeTo(address(adapterImpl));
        vm.stopBroadcast();
        console2.log("[3/9] Adapter beacon upgraded");
        _settleBlock(settleMs);

        vault = MantleYieldVault(vaultProxy);
        if (!_vaultInitialized(vault, admin)) {
            vm.startBroadcast();
            vault.initialize(vaultParams);
            vm.stopBroadcast();
            console2.log("[4/9] Vault initialized");
            _settleBlock(settleMs);
        } else {
            console2.log("[4/9] Vault already initialized, skip");
        }

        Accountant accountant = Accountant(accountantProxy);
        if (!_proxyHasAdmin(accountantProxy, admin)) {
            vm.startBroadcast();
            accountant.initialize(vaultProxy, initialRate, managementFeeBps, admin, pauser, accountantExecutor);
            vm.stopBroadcast();
            console2.log("[5/9] Accountant initialized");
            _settleBlock(settleMs);
        } else {
            console2.log("[5/9] Accountant already initialized, skip");
        }
        if (!accountant.hasRole(accountant.ACCOUNTANT_EXECUTOR_ROLE(), accountantExecutor)) {
            vm.startBroadcast();
            accountant.grantRole(accountant.ACCOUNTANT_EXECUTOR_ROLE(), accountantExecutor);
            vm.stopBroadcast();
            console2.log("      Accountant ACCOUNTANT_EXECUTOR_ROLE -> AccountantExecutor");
            _settleBlock(settleMs);
        }
        if (!accountant.hasRole(accountant.PAUSER_ROLE(), pauser)) {
            vm.startBroadcast();
            accountant.grantRole(accountant.PAUSER_ROLE(), pauser);
            vm.stopBroadcast();
            console2.log("      Accountant PAUSER_ROLE -> pauser");
            _settleBlock(settleMs);
        }
        if (!accountant.hasRole(accountant.PAUSER_ROLE(), accountantExecutor)) {
            vm.startBroadcast();
            accountant.grantRole(accountant.PAUSER_ROLE(), accountantExecutor);
            vm.stopBroadcast();
            console2.log("      Accountant PAUSER_ROLE -> AccountantExecutor");
            _settleBlock(settleMs);
        }

        StrategyController controller = StrategyController(controllerProxy);
        if (!_proxyHasAdmin(controllerProxy, admin)) {
            vm.startBroadcast();
            controller.initialize(
                vaultProxy, admin, operatorExecutor, pauser, bufferTargetBps, rebalanceThresholdBps, rebalanceCooldown
            );
            vm.stopBroadcast();
            console2.log("[6/9] StrategyController initialized");
            _settleBlock(settleMs);
        } else {
            console2.log("[6/9] StrategyController already initialized, skip");
        }

        if (!vault.hasRole(vault.PAUSER_ROLE(), pauser)) {
            vm.startBroadcast();
            vault.grantRole(vault.PAUSER_ROLE(), pauser);
            vm.stopBroadcast();
            console2.log("[7/9] Vault PAUSER_ROLE granted");
            _settleBlock(settleMs);
        } else {
            console2.log("[7/9] Vault PAUSER_ROLE already granted, skip");
        }
        if (!vault.hasRole(vault.CAP_MANAGER_ROLE(), capManager)) {
            vm.startBroadcast();
            vault.grantRole(vault.CAP_MANAGER_ROLE(), capManager);
            vm.stopBroadcast();
            console2.log("      Vault CAP_MANAGER_ROLE granted");
            _settleBlock(settleMs);
        } else {
            console2.log("      Vault CAP_MANAGER_ROLE already granted, skip");
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
            console2.log("[8/9] Adapter initialized");
            _settleBlock(settleMs);
        } else {
            console2.log("[8/9] Adapter already initialized, skip");
        }

        if (manualPosTokenPrice != 0) {
            require(adapterPriceOracle == address(0), "MANUAL_PRICE_WITH_ORACLE");
            vm.startBroadcast();
            adapter.setManualPosTokenPrice(manualPosTokenPrice);
            vm.stopBroadcast();
            console2.log("[9/9] Adapter manual price set");
            _settleBlock(settleMs);
        }

        if (minSubscribeAsset != 0 || subscribeStepAsset != 0 || minRedeemPos != 0 || redeemStepPos != 0) {
            if (!_executionConstraintsMatch(
                    adapter, minSubscribeAsset, subscribeStepAsset, minRedeemPos, redeemStepPos
                )) {
                vm.startBroadcast();
                adapter.setExecutionConstraints(minSubscribeAsset, subscribeStepAsset, minRedeemPos, redeemStepPos);
                vm.stopBroadcast();
                console2.log("[9/9] Adapter execution constraints set");
                _settleBlock(settleMs);
            } else {
                console2.log("[9/9] Adapter execution constraints already set, skip");
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
        console2.log("Vault controller    :", vault.controller());
        console2.log("Vault accountant    :", vault.accountant());
        console2.log("Vault has admin     :", vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
        console2.log("Vault has pauser    :", vault.hasRole(vault.PAUSER_ROLE(), pauser));
        console2.log("Vault has cap mgr   :", vault.hasRole(vault.CAP_MANAGER_ROLE(), capManager));
        console2.log("Accountant vault    :", address(accountant.vault()));
        console2.log("Accountant has admin:", accountant.hasRole(accountant.DEFAULT_ADMIN_ROLE(), admin));
        console2.log(
            "Accountant has EXEC :", accountant.hasRole(accountant.ACCOUNTANT_EXECUTOR_ROLE(), accountantExecutor)
        );
        console2.log("Controller vault    :", address(controller.vault()));
        console2.log("Controller has admin:", controller.hasRole(controller.DEFAULT_ADMIN_ROLE(), admin));
        console2.log("Controller has OPEX :", controller.hasRole(controller.OPERATOR_EXECUTOR_ROLE(), operatorExecutor));
        console2.log("Controller has PAUS :", controller.hasRole(controller.PAUSER_ROLE(), pauser));
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

    function _proxyHasAdmin(address proxy, address admin) internal view returns (bool) {
        (bool ok, bytes memory data) =
            proxy.staticcall(abi.encodeWithSignature("hasRole(bytes32,address)", bytes32(0), admin));
        if (!ok || data.length < 32) return false;
        return abi.decode(data, (bool));
    }

    function _requireNonZero(address value, string memory envName) internal pure {
        require(value != address(0), string.concat(envName, "_ZERO"));
    }

    function _requireConfiguredSenderIsAdmin(address admin) internal view {
        address configuredSender = vm.envOr("F_SENDER", address(0));
        if (configuredSender != address(0)) {
            require(configuredSender == admin, "F_SENDER_MUST_BE_ADMIN");
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
