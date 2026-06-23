// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Accountant} from "../src/accountant/Accountant.sol";
import {AccountantExecutor} from "../src/accountant/AccountantExecutor.sol";
import {AccountantFactory} from "../src/accountant/AccountantFactory.sol";
import {SanctionsOracle} from "../src/compliance/SanctionsOracle.sol";
import {SanctionsOracleFactory} from "../src/compliance/SanctionsOracleFactory.sol";
import {ISanctionsOracle} from "../src/interfaces/compliance/ISanctionsOracle.sol";
import {IMantleVaultGateway} from "../src/interfaces/vault/IMantleVaultGateway.sol";
import {OperatorExecutor} from "../src/protocol/OperatorExecutor.sol";
import {StrategyController} from "../src/protocol/StrategyController.sol";
import {StrategyControllerFactory} from "../src/protocol/StrategyControllerFactory.sol";
import {GatewayFactory} from "../src/vault/GatewayFactory.sol";
import {MantleVaultGateway} from "../src/vault/MantleVaultGateway.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @title DeployRemainingForExistingFactories
/// @notice Phase A of the two-phase deployment when VaultFactory + SubRedManagementAdapterFactory
///         + their (uninit) BeaconProxies already exist on-chain (e.g. from
///         DeployEmptyVaultAndAdapterFactories).
///
///         Deploys every other component required by the protocol and initializes the ones
///         that do not depend on Vault being initialized:
///
///         Initialized in this script:
///           • SanctionsOracle (factory + proxy + admin/compliance roles)
///           • AccountantExecutor (UUPS, admin + BOT_ROLE + FEE_SETTLER_ROLE)
///           • OperatorExecutor (UUPS, admin + BOT_ROLE — granted in initialize())
///           • MantleVaultGateway (factory + proxy; init only stores pointers, no vault calls)
///
///         Deployed UNINIT (defer init to Phase B / UpgradeAndInitVaultAndAdapter):
///           • Accountant (factory + uninit BeaconProxy)
///                — Accountant.initialize() reads vault.totalSupply()
///           • StrategyController (factory + uninit BeaconProxy)
///                — StrategyController.initialize() reads vault.asset()
///
///         Outputs all new addresses to console for filling back into deploy-config yaml.
///
/// Required env (read from deploy-config yaml):
///   F_ADMIN_ADDRESS              – DEFAULT_ADMIN_ROLE on every new proxy + Beacon owner
///   F_COMPLIANCE_BOT_ADDRESS     – SanctionsOracle COMPLIANCE_ROLE
///   F_BOT_ADDRESS                – AccountantExecutor BOT_ROLE
///   F_FEE_SETTLER_ADDRESS        – AccountantExecutor FEE_SETTLER_ROLE
///   F_SIGNER_ADDRESS             – OperatorExecutor BOT_ROLE (initial bot, legacy env name)
///   F_TREASURY_ADDRESS           – Vault treasury (fee share recipient) consumed in Phase B
///   F_SANCTION_SAFE_ADDRESS      – Gateway sanctionSafe init param (compliance escrow address)
///   F_SYNC_REDEEM_DISABLED       – Gateway syncRedeemDisabled init param (true/false)
///   F_WHITELIST_ENABLED          – Gateway whitelist enforcement flag (true/false; default false)
///   EXISTING_VAULT_PROXY         – the uninit Vault BeaconProxy already on-chain
///                                  (used as Gateway.init's vault pointer; Gateway.init does
///                                  not call vault, so uninit pointer is fine)
///   F_SENDER                     – optional preflight; when set, must equal F_ADMIN_ADDRESS
contract DeployRemainingForExistingFactories is Script {
    struct Deployed {
        SanctionsOracle oracleImpl;
        SanctionsOracleFactory oracleFactory;
        SanctionsOracle oracle;
        Accountant accountantImpl;
        AccountantFactory accountantFactory;
        address accountantProxy; // uninit
        AccountantExecutor accountantExecutorImpl;
        AccountantExecutor accountantExecutor;
        OperatorExecutor operatorExecutorImpl;
        OperatorExecutor operatorExecutor;
        StrategyController controllerImpl;
        StrategyControllerFactory controllerFactory;
        address controllerProxy; // uninit
        MantleVaultGateway gatewayImpl;
        GatewayFactory gatewayFactory;
        MantleVaultGateway gateway;
    }

    function run() external returns (Deployed memory d) {
        address admin = vm.envAddress("F_ADMIN_ADDRESS");
        address complianceBot = vm.envAddress("F_COMPLIANCE_BOT_ADDRESS");
        address bot = vm.envAddress("F_BOT_ADDRESS");
        address feeSettler = vm.envAddress("F_FEE_SETTLER_ADDRESS");
        address signer = vm.envAddress("F_SIGNER_ADDRESS");
        address treasury = vm.envAddress("F_TREASURY_ADDRESS");
        address sanctionSafe = vm.envAddress("F_SANCTION_SAFE_ADDRESS");
        address vaultProxy = vm.envAddress("EXISTING_VAULT_PROXY");
        bool syncRedeemDisabled = vm.envBool("F_SYNC_REDEEM_DISABLED");
        bool whitelistEnabled = vm.envOr("F_WHITELIST_ENABLED", false);
        address configuredSender = vm.envOr("F_SENDER", address(0));
        if (configuredSender != address(0)) {
            require(configuredSender == admin, "F_SENDER_MUST_BE_ADMIN");
        }

        console2.log("=== DeployRemainingForExistingFactories (Phase A) ===");
        console2.log("Admin              :", admin);
        console2.log("Existing vault     :", vaultProxy);
        console2.log("Compliance bot     :", complianceBot);
        console2.log("Acct bot           :", bot);
        console2.log("Fee settler        :", feeSettler);
        console2.log("Op signer          :", signer);
        console2.log("Treasury           :", treasury);
        console2.log("SanctionSafe       :", sanctionSafe);
        console2.log("Sync redeem disabled:", syncRedeemDisabled);
        console2.log("Whitelist enabled  :", whitelistEnabled);

        vm.startBroadcast();

        // ─── 1. SanctionsOracle (no deps, init now) ─────────────────────
        d.oracleImpl = new SanctionsOracle();
        d.oracleFactory = new SanctionsOracleFactory(address(d.oracleImpl), admin);
        address oracleAddr = d.oracleFactory.deployAndInitOracle(admin, complianceBot);
        d.oracle = SanctionsOracle(oracleAddr);
        console2.log("[1/6] SanctionsOracle  :", oracleAddr);

        // ─── 2. Accountant (factory + UNINIT proxy; init deferred to Phase B) ───
        d.accountantImpl = new Accountant();
        d.accountantFactory = new AccountantFactory(address(d.accountantImpl), admin);
        d.accountantProxy = d.accountantFactory.deployAccountant();
        console2.log("[2/6] Accountant uninit:", d.accountantProxy);

        // ─── 3. AccountantExecutor UUPS (init now) ──────────────────────
        d.accountantExecutorImpl = new AccountantExecutor();
        address acctExecAddr = address(
            new ERC1967Proxy(address(d.accountantExecutorImpl), abi.encodeCall(AccountantExecutor.initialize, (admin)))
        );
        d.accountantExecutor = AccountantExecutor(acctExecAddr);
        d.accountantExecutor.grantRole(d.accountantExecutor.BOT_ROLE(), bot);
        d.accountantExecutor.grantRole(d.accountantExecutor.FEE_SETTLER_ROLE(), feeSettler);
        console2.log("[3/6] AccountantExec   :", acctExecAddr);

        // ─── 4. OperatorExecutor UUPS (init now; initialize() already grants BOT_ROLE) ───
        d.operatorExecutorImpl = new OperatorExecutor();
        address opExecAddr = address(
            new ERC1967Proxy(
                address(d.operatorExecutorImpl), abi.encodeCall(OperatorExecutor.initialize, (admin, signer))
            )
        );
        d.operatorExecutor = OperatorExecutor(opExecAddr);
        console2.log("[4/6] OperatorExec     :", opExecAddr);

        // ─── 5. StrategyController (factory + UNINIT proxy; init deferred to Phase B) ───
        d.controllerImpl = new StrategyController();
        d.controllerFactory = new StrategyControllerFactory(address(d.controllerImpl), admin);
        d.controllerProxy = d.controllerFactory.deployController();
        console2.log("[5/6] Controller uninit:", d.controllerProxy);

        // ─── 6. Gateway (init now; init only stores pointers) ───────────
        d.gatewayImpl = new MantleVaultGateway();
        d.gatewayFactory = new GatewayFactory(address(d.gatewayImpl), admin);
        address gatewayAddr = d.gatewayFactory
            .deployAndInitGateway(
                IMantleVaultGateway.InitParams({
                    vault: vaultProxy,
                    sanctionsOracle: ISanctionsOracle(oracleAddr),
                    sanctionSafe: sanctionSafe,
                    admin: admin,
                    syncRedeemDisabled: syncRedeemDisabled
                })
            );
        d.gateway = MantleVaultGateway(gatewayAddr);
        if (whitelistEnabled) {
            d.gateway.setWhitelistEnabled(true);
        }
        console2.log("[6/6] Gateway          :", gatewayAddr);

        vm.stopBroadcast();

        // ─── Post-deploy address dump (paste into deploy-config yaml) ───
        console2.log("");
        console2.log("=========== Phase A address dump ===========");
        console2.log("F_SANCTIONS_ORACLE_FACTORY    :", address(d.oracleFactory));
        console2.log("F_SANCTIONS_ORACLE            :", address(d.oracle));
        console2.log("F_ACCOUNTANT_FACTORY          :", address(d.accountantFactory));
        console2.log("F_ACCOUNTANT (uninit)         :", d.accountantProxy);
        console2.log("F_ACCOUNTANT_EXECUTOR         :", address(d.accountantExecutor));
        console2.log("F_OPERATOR_EXECUTOR           :", address(d.operatorExecutor));
        console2.log("F_STRATEGY_CONTROLLER_FACTORY :", address(d.controllerFactory));
        console2.log("F_CONTROLLER_ADDRESS (uninit) :", d.controllerProxy);
        console2.log("F_GATEWAY_FACTORY             :", address(d.gatewayFactory));
        console2.log("F_GATEWAY                     :", address(d.gateway));
        console2.log("");
        console2.log("=========== Phase B yaml fields ===========");
        console2.log("UPGRADE_INIT_GATEWAY             :", address(d.gateway));
        console2.log("UPGRADE_INIT_CONTROLLER          :", d.controllerProxy);
        console2.log("UPGRADE_INIT_ACCOUNTANT          :", d.accountantProxy);
        console2.log("UPGRADE_INIT_ACCOUNTANT_EXECUTOR :", address(d.accountantExecutor));
        console2.log("UPGRADE_INIT_OPERATOR_EXECUTOR   :", address(d.operatorExecutor));
        console2.log("");
        console2.log("=========== Phase A verification ===========");
        console2.log("Oracle has ADMIN     :", d.oracle.hasRole(d.oracle.DEFAULT_ADMIN_ROLE(), admin));
        console2.log("Oracle has COMPLIANCE:", d.oracle.hasRole(d.oracle.COMPLIANCE_ROLE(), complianceBot));
        console2.log(
            "AcctExec has ADMIN   :", d.accountantExecutor.hasRole(d.accountantExecutor.DEFAULT_ADMIN_ROLE(), admin)
        );
        console2.log("AcctExec has BOT     :", d.accountantExecutor.hasRole(d.accountantExecutor.BOT_ROLE(), bot));
        console2.log(
            "AcctExec has FEE     :", d.accountantExecutor.hasRole(d.accountantExecutor.FEE_SETTLER_ROLE(), feeSettler)
        );
        console2.log(
            "OpExec has ADMIN     :", d.operatorExecutor.hasRole(d.operatorExecutor.DEFAULT_ADMIN_ROLE(), admin)
        );
        console2.log("OpExec has BOT       :", d.operatorExecutor.hasRole(d.operatorExecutor.BOT_ROLE(), signer));
        console2.log("Gateway vault        :", address(d.gateway.vault()));
        console2.log("Gateway oracle       :", address(d.gateway.sanctionsOracle()));
        console2.log("Gateway whitelistEnabled :", d.gateway.whitelistEnabled());
    }
}
