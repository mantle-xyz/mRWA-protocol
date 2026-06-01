// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Accountant} from "../src/accountant/Accountant.sol";
import {AccountantExecutor} from "../src/accountant/AccountantExecutor.sol";
import {AccountantFactory} from "../src/accountant/AccountantFactory.sol";
import {SubRedManagementAdapterFactory} from "../src/adapters/digift/SubRedManagementAdapterFactory.sol";
import {SubRedManagementAdapter} from "../src/adapters/digift/SubRedManagementAdapterUpgradeable.sol";
import {SanctionsOracle} from "../src/compliance/SanctionsOracle.sol";
import {SanctionsOracleFactory} from "../src/compliance/SanctionsOracleFactory.sol";
import {ISanctionsOracle} from "../src/interfaces/compliance/ISanctionsOracle.sol";
import {IMantleVaultGateway} from "../src/interfaces/vault/IMantleVaultGateway.sol";
import {IMantleYieldVault} from "../src/interfaces/vault/IMantleYieldVault.sol";
import {OperatorExecutor} from "../src/protocol/OperatorExecutor.sol";
import {StrategyController} from "../src/protocol/StrategyController.sol";
import {StrategyControllerFactory} from "../src/protocol/StrategyControllerFactory.sol";
import {GatewayFactory} from "../src/vault/GatewayFactory.sol";
import {MantleVaultGateway} from "../src/vault/MantleVaultGateway.sol";
import {MantleYieldVault} from "../src/vault/MantleYieldVault.sol";
import {VaultFactory} from "../src/vault/VaultFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @title DeployInstance
/// @notice Deploys a new mRWA protocol instance by calling existing on-chain factories.
///         No new implementations or factory contracts are deployed —
///         all BeaconProxy instances share the existing beacons and implementations.
///
///         Use this instead of DeployAll when the protocol stack is already live
///         and you only need a new set of proxy instances (e.g. a second vault).
///
/// Deployment order (mirrors DeployAll circular-dep resolution):
///   Phase 1 – Oracle (no deps)
///   Phase 2 – Vault / Gateway / Controller as uninit BeaconProxies
///   Phase 3 – Accountant (vault addr known)
///   Phase 4 – OperatorExecutor + AccountantExecutor (fresh UUPS, no factory)
///   Phase 5 – Initialize deferred proxies (Vault → Gateway → Controller)
///   Phase 6 – Wire roles
///
/// Required env vars (all present in deploy-config YAML):
///   F_SANCTIONS_ORACLE_FACTORY   – SanctionsOracleFactory address
///   F_VAULT_FACTORY              – VaultFactory address
///   F_GATEWAY_FACTORY            – GatewayFactory address
///   F_ACCOUNTANT_FACTORY         – AccountantFactory address
///   F_STRATEGY_CONTROLLER_FACTORY – StrategyControllerFactory address
///   F_ADMIN_ADDRESS
///   F_STABLE_ADDRESS
///   F_COMPLIANCE_BOT_ADDRESS
///   F_OPERATOR_EXECUTOR          – existing OperatorExecutor proxy (reused)
///   F_ACCOUNTANT_EXECUTOR        – existing AccountantExecutor proxy (reused)
///   F_TREASURY_ADDRESS
///   F_PAUSER_ADDRESS
///   F_CAP_MANAGER_ADDRESS
///   F_INITIAL_RATE
///   F_MANAGEMENT_FEE_BPS
///   F_MAX_ALLOWED_DEVIATION_BPS
///   F_MIN_UPDATE_INTERVAL_SECONDS
///   F_MAX_COMPUTE_AGE_SECONDS
///   F_BUFFER_TARGET_BPS
///   F_REBALANCE_THRESHOLD_BPS
///   F_REBALANCE_COOLDOWN
///   F_MAX_REDEMPTION_FEE_BPS
///   F_REDEMPTION_FEE_BPS
///   F_MIN_REDEEM_AMOUNT
///   F_MIN_DEPOSIT_AMOUNT
///   F_SYNC_REDEEM_DISABLED
///   F_WHITELIST_ENABLED          – Gateway whitelist enforcement flag (true/false; default false)
///
/// Optional adapter env (omit F_SUBRED_ADAPTER_FACTORY to skip adapter deployment):
///   F_SUBRED_ADAPTER_FACTORY     – SubRedManagementAdapterFactory address
///   F_ADAPTER_SUBRED_MANAGEMENT  – Digift SubRedManagement contract address
///   F_ADAPTER_ST_TOKEN           – Target security token address
///   F_ADAPTER_PRICE_ORACLE       – DFeedPriceOracle address (default: address(0))
///   F_ADAPTER_MANUAL_POS_TOKEN_PRICE – Manual pos token price (default: 0)
///   F_ADAPTER_SUBSCRIBE_STEP_ASSET   – Subscribe step size (default: 0)
///   F_ADAPTER_REDEEM_STEP_POS        – Redeem step size (default: 0)
///   F_ADAPTER_MIN_SUBSCRIBE_ASSET    – Min subscribe amount (default: 0)
///   F_ADAPTER_MIN_REDEEM_POS         – Min redeem amount (default: 0)
contract DeployInstance is Script {
    struct Deployed {
        SanctionsOracle oracle;
        MantleYieldVault vault;
        MantleVaultGateway gateway;
        Accountant accountant;
        AccountantExecutor accountantExecutor;
        StrategyController controller;
        OperatorExecutor operatorExecutor;
        SubRedManagementAdapter adapter;
    }

    function run() external returns (Deployed memory d) {
        // ─── Load existing factories ──────────────────────────────
        SanctionsOracleFactory oracleFactory = SanctionsOracleFactory(vm.envAddress("F_SANCTIONS_ORACLE_FACTORY"));
        VaultFactory vaultFactory = VaultFactory(vm.envAddress("F_VAULT_FACTORY"));
        GatewayFactory gatewayFactory = GatewayFactory(vm.envAddress("F_GATEWAY_FACTORY"));
        AccountantFactory accountantFactory = AccountantFactory(vm.envAddress("F_ACCOUNTANT_FACTORY"));
        StrategyControllerFactory controllerFactory =
            StrategyControllerFactory(vm.envAddress("F_STRATEGY_CONTROLLER_FACTORY"));

        // ─── Load params ──────────────────────────────────────────
        address admin = vm.envAddress("F_ADMIN_ADDRESS");
        address stable = vm.envAddress("F_STABLE_ADDRESS");
        address complianceBot = vm.envAddress("F_COMPLIANCE_BOT_ADDRESS");
        address treasury = vm.envAddress("F_TREASURY_ADDRESS");
        address pauser = vm.envAddress("F_PAUSER_ADDRESS");
        address capManager = vm.envAddress("F_CAP_MANAGER_ADDRESS");
        uint64 initialRate = uint64(vm.envUint("F_INITIAL_RATE"));
        uint32 managementFeeBps = uint32(vm.envUint("F_MANAGEMENT_FEE_BPS"));
        uint32 maxAllowedDeviation = uint32(vm.envUint("F_MAX_ALLOWED_DEVIATION_BPS"));
        uint32 minUpdateInterval = uint32(vm.envUint("F_MIN_UPDATE_INTERVAL_SECONDS"));
        uint32 maxComputeAge = uint32(vm.envUint("F_MAX_COMPUTE_AGE_SECONDS"));
        uint16 bufferTargetBps = uint16(vm.envUint("F_BUFFER_TARGET_BPS"));
        uint16 rebalanceThresholdBps = uint16(vm.envUint("F_REBALANCE_THRESHOLD_BPS"));
        uint64 rebalanceCooldown = uint64(vm.envUint("F_REBALANCE_COOLDOWN"));

        console2.log("=== DeployInstance: New Protocol Instance via Existing Factories ===");
        console2.log("OracleFactory      :", address(oracleFactory));
        console2.log("VaultFactory       :", address(vaultFactory));
        console2.log("GatewayFactory     :", address(gatewayFactory));
        console2.log("AccountantFactory  :", address(accountantFactory));
        console2.log("ControllerFactory  :", address(controllerFactory));
        console2.log("Beacon impl (vault):", vaultFactory.implementation());
        console2.log("Admin              :", admin);

        vm.startBroadcast();

        // ── Phase 1: SanctionsOracle ─────────────────────────────────
        address oracleAddr = oracleFactory.deployAndInitOracle(admin, complianceBot);
        d.oracle = SanctionsOracle(oracleAddr);
        console2.log("[1] Oracle         :", oracleAddr);

        // ── Phase 2: Uninit BeaconProxies (circular dep resolution) ──
        address vaultAddr = vaultFactory.deployVault();
        address gatewayAddr = gatewayFactory.deployGateway();
        address controllerAddr = controllerFactory.deployController();
        console2.log("[2] Vault  (uninit):", vaultAddr);
        console2.log("[2] Gteway (uninit):", gatewayAddr);
        console2.log("[2] Ctrl   (uninit):", controllerAddr);

        // ── Phase 3: Reuse existing UUPS executor proxies ────────────
        address opExecAddr = vm.envAddress("F_OPERATOR_EXECUTOR");
        address acctExecAddr = vm.envAddress("F_ACCOUNTANT_EXECUTOR");
        d.operatorExecutor = OperatorExecutor(opExecAddr);
        d.accountantExecutor = AccountantExecutor(acctExecAddr);
        console2.log("[3] OpExecutor (reused)  :", opExecAddr);
        console2.log("[3] AcctExecutor (reused):", acctExecAddr);

        // ── Phase 4: Accountant (vault + executor addrs known) ───────
        address accountantAddr = accountantFactory.deployAndInitAccountant(
            vaultAddr,
            initialRate,
            managementFeeBps,
            maxAllowedDeviation,
            minUpdateInterval,
            maxComputeAge,
            admin,
            pauser,
            acctExecAddr
        );
        d.accountant = Accountant(accountantAddr);
        console2.log("[4] Accountant     :", accountantAddr);

        // ── Phase 5: Initialize deferred proxies ──────────────────────
        // Vault first — Controller.initialize reads vault.asset()
        d.vault = MantleYieldVault(vaultAddr);
        d.vault
            .initialize(
                IMantleYieldVault.InitParams({
                    asset: IERC20(stable),
                    name: "Mantle RWA Vault",
                    symbol: "mRWA",
                    admin: admin,
                    gateway: gatewayAddr,
                    controller: controllerAddr,
                    accountant: accountantAddr,
                    treasury: treasury,
                    maxRedemptionFeeBps: vm.envUint("F_MAX_REDEMPTION_FEE_BPS"),
                    redemptionFeeBps: vm.envUint("F_REDEMPTION_FEE_BPS"),
                    minRedeemAmount: vm.envUint("F_MIN_REDEEM_AMOUNT"),
                    minDepositAmount: vm.envUint("F_MIN_DEPOSIT_AMOUNT"),
                    maxSettlementDeviationBps: vm.envOr("F_MAX_SETTLEMENT_DEVIATION_BPS", uint256(1000)),
                    depositDailyRemaining: vm.envOr("F_DEPOSIT_DAILY_REMAINING", type(uint256).max),
                    redeemDailyRemaining: vm.envOr("F_REDEEM_DAILY_REMAINING", type(uint256).max)
                })
            );

        d.gateway = MantleVaultGateway(gatewayAddr);
        bool whitelistEnabled = vm.envOr("F_WHITELIST_ENABLED", false);
        d.gateway
            .initialize(
                IMantleVaultGateway.InitParams({
                    vault: vaultAddr,
                    sanctionsOracle: ISanctionsOracle(oracleAddr),
                    sanctionSafe: admin,
                    admin: admin,
                    syncRedeemDisabled: vm.envBool("F_SYNC_REDEEM_DISABLED"),
                    whitelistEnabled: whitelistEnabled
                })
            );
        console2.log("Gateway whitelist  :", whitelistEnabled ? "ENABLED" : "disabled");

        d.controller = StrategyController(controllerAddr);
        d.controller
            .initialize(vaultAddr, admin, opExecAddr, pauser, bufferTargetBps, rebalanceThresholdBps, rebalanceCooldown);
        console2.log("[5] All deferred proxies initialized");

        // ── Phase 6: Wire roles ───────────────────────────────────────
        // Grant the existing AccountantExecutor access to the new Accountant instance.
        // BOT_ROLE on the executor itself is already configured — no change needed there.
        d.accountant.grantRole(d.accountant.ACCOUNTANT_EXECUTOR_ROLE(), acctExecAddr);
        d.vault.grantRole(d.vault.PAUSER_ROLE(), pauser);
        d.vault.grantRole(d.vault.CAP_MANAGER_ROLE(), capManager);
        console2.log("[6] Roles wired");

        // ── Phase 7 (optional): Deploy adapter via existing factory ───
        address adapterFactoryAddr = vm.envOr("F_SUBRED_ADAPTER_FACTORY", address(0));
        if (adapterFactoryAddr != address(0)) {
            SubRedManagementAdapterFactory adapterFactory = SubRedManagementAdapterFactory(adapterFactoryAddr);
            address adapterSubRed = vm.envAddress("F_ADAPTER_SUBRED_MANAGEMENT");
            address adapterStToken = vm.envAddress("F_ADAPTER_ST_TOKEN");
            address adapterPriceOracle = vm.envOr("F_ADAPTER_PRICE_ORACLE", address(0));
            uint256 adapterManualPrice = vm.envOr("F_ADAPTER_MANUAL_POS_TOKEN_PRICE", uint256(0));

            address adapterAddr = adapterFactory.deployAndInitAdapter(
                vaultAddr, adapterSubRed, adapterStToken, admin, controllerAddr, acctExecAddr, adapterPriceOracle
            );
            d.adapter = SubRedManagementAdapter(adapterAddr);

            if (adapterManualPrice != 0) {
                require(adapterPriceOracle == address(0), "MANUAL_PRICE_WITH_ORACLE");
                d.adapter.setManualPosTokenPrice(adapterManualPrice);
            }

            uint256 subscribeStep = vm.envOr("F_ADAPTER_SUBSCRIBE_STEP_ASSET", uint256(0));
            uint256 redeemStep = vm.envOr("F_ADAPTER_REDEEM_STEP_POS", uint256(0));
            uint256 minSubscribe = vm.envOr("F_ADAPTER_MIN_SUBSCRIBE_ASSET", uint256(0));
            uint256 minRedeem = vm.envOr("F_ADAPTER_MIN_REDEEM_POS", uint256(0));
            if (subscribeStep != 0 || redeemStep != 0 || minSubscribe != 0 || minRedeem != 0) {
                d.adapter.setExecutionConstraints(minSubscribe, subscribeStep, minRedeem, redeemStep);
            }
            console2.log("[7] Adapter deployed:", adapterAddr);
        } else {
            console2.log("[7] Adapter skipped (F_SUBRED_ADAPTER_FACTORY not set)");
        }

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Instance Deployed ===");
        console2.log("Oracle             :", oracleAddr);
        console2.log("Vault              :", vaultAddr);
        console2.log("Gateway            :", gatewayAddr);
        console2.log("Accountant         :", accountantAddr);
        console2.log("Controller         :", controllerAddr);
        console2.log("OperatorExecutor   :", opExecAddr);
        console2.log("AccountantExecutor :", acctExecAddr);
        if (address(d.adapter) != address(0)) {
            console2.log("Adapter            :", address(d.adapter));
        }
        console2.log("");
        console2.log("All proxies share beacons with existing instances.");
        console2.log("UpgradeAll will upgrade this instance atomically with the rest.");
    }
}
