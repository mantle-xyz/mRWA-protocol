// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Accountant} from "../src/accountant/Accountant.sol";
import {AccountantExecutor} from "../src/accountant/AccountantExecutor.sol";
import {AccountantFactory} from "../src/accountant/AccountantFactory.sol";
import {SubRedManagementAdapterFactory} from "../src/adapters/digift/SubRedManagementAdapterFactory.sol";
import {SubRedManagementAdapter} from "../src/adapters/digift/SubRedManagementAdapterUpgradeable.sol";
import {SanctionsOracle} from "../src/compliance/SanctionsOracle.sol";
import {SanctionsOracleFactory} from "../src/compliance/SanctionsOracleFactory.sol";
import {ISubRedManagementAdapter} from "../src/interfaces/adapters/digift/ISubRedManagementAdapter.sol";

import {ISanctionsOracle} from "../src/interfaces/compliance/ISanctionsOracle.sol";
import {IMantleVaultGateway} from "../src/interfaces/vault/IMantleVaultGateway.sol";
import {IMantleYieldVault} from "../src/interfaces/vault/IMantleYieldVault.sol";

import {MockERC20Mintable} from "../src/mocks/token/MockERC20Mintable.sol";
import {OperatorExecutor} from "../src/protocol/OperatorExecutor.sol";
import {StrategyController} from "../src/protocol/StrategyController.sol";
import {StrategyControllerFactory} from "../src/protocol/StrategyControllerFactory.sol";
import {GatewayFactory} from "../src/vault/GatewayFactory.sol";
import {MantleVaultGateway} from "../src/vault/MantleVaultGateway.sol";
import {MantleYieldVault} from "../src/vault/MantleYieldVault.sol";
import {VaultFactory} from "../src/vault/VaultFactory.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @title DeployAll
/// @notice One-shot deployment of the full mRWA protocol stack in a single broadcast.
///
///         Deployment topology
///         ───────────────────
///         ┌─ Phase 1: Implementations + Factories ──────────────────────────┐
///         │  SanctionsOracle   impl → SanctionsOracleFactory               │
///         │  MantleYieldVault  impl → VaultFactory                         │
///         │  Accountant        impl → AccountantFactory                    │
///         │  StrategyController impl → StrategyControllerFactory           │
///         │  AccountantExecutor impl  (UUPS, no factory)                   │
///         │  OperatorExecutor   impl  (UUPS, no factory)                  │
///         └─────────────────────────────────────────────────────────────────┘
///         ┌─ Phase 2: Proxies (resolves circular deps) ────────────────────┐
///         │  SanctionsOracle     → BeaconProxy (initialized, no deps)      │
///         │  MantleYieldVault    → BeaconProxy (UNINIT — deferred)         │
///         │  StrategyController  → BeaconProxy (UNINIT — deferred)         │
///         │  Accountant          → BeaconProxy (init: vault + acct exec)   │
///         │  OperatorExecutor    → UUPS proxy (init: admin, bot)           │
///         │  AccountantExecutor  → UUPS proxy (init: accountant)           │
///         └─────────────────────────────────────────────────────────────────┘
///         ┌─ Phase 3: Deferred BeaconProxy initialization ─────────────────┐
///         │  MantleYieldVault.initialize(..., gateway, ...)               │
///         │  StrategyController.initialize(vault, opExec, ...)             │
///         │  (Vault first: Controller reads vault.asset() during init)     │
///         └─────────────────────────────────────────────────────────────────┘
///         ┌─ Phase 4: Wire roles ──────────────────────────────────────────┐
///         │  Accountant   → ACCOUNTANT_EXECUTOR_ROLE → AccountantExecutor  │
///         │  AcctExecutor → BOT_ROLE       → bot                           │
///         │  AcctExecutor → FEE_SETTLER_ROLE → feeSettler                  │
///         │  Vault        → PAUSER_ROLE    → pauser                        │
///         │  Vault        → CAP_MANAGER_ROLE → capManager                  │
///         └─────────────────────────────────────────────────────────────────┘
///
/// Required env vars (set via deploy-config YAML):
///   F_ADMIN_ADDRESS              – protocol-wide admin (beacon owner + DEFAULT_ADMIN_ROLE)
///   F_STABLE_ADDRESS               – STABLE token address
///   F_COMPLIANCE_BOT_ADDRESS     – SanctionsOracle COMPLIANCE_ROLE
///   F_BOT_ADDRESS                – AccountantExecutor BOT_ROLE
///   F_FEE_SETTLER_ADDRESS        – AccountantExecutor FEE_SETTLER_ROLE
///   F_SIGNER_ADDRESS             – OperatorExecutor BOT_ROLE (initial bot, legacy env name)
///   F_TREASURY_ADDRESS           – fee share recipient
///   (also used as gateway sanctionSafe init)
///   F_PAUSER_ADDRESS             – Vault PAUSER_ROLE
///   F_CAP_MANAGER_ADDRESS        – Vault CAP_MANAGER_ROLE
///   F_INITIAL_RATE               – Accountant starting exchange rate (e.g. 1e18)
///   F_MANAGEMENT_FEE_BPS         – Accountant management fee in bps (e.g. 50)
///   F_BUFFER_TARGET_BPS          – StrategyController buffer target
///   F_REBALANCE_THRESHOLD_BPS    – StrategyController rebalance threshold
///   F_REBALANCE_COOLDOWN         – StrategyController rebalance cooldown (seconds)
///   F_MAX_REDEMPTION_FEE_BPS     – Vault max redemption fee cap
///   F_REDEMPTION_FEE_BPS         – Vault initial redemption fee
///   F_MIN_REDEEM_AMOUNT          – Vault minimum redeem amount
///   F_MIN_DEPOSIT_AMOUNT         – Vault minimum deposit amount
///   F_SYNC_REDEEM_DISABLED       – Gateway sync redeem disabled flag (true/false)
///
/// Optional adapter env (omit to skip adapter deployment):
///   F_ADAPTER_SUBRED_MANAGEMENT  – Digift SubRedManagement contract address
///   F_ADAPTER_ST_TOKEN           – Target security token address
///   F_ADAPTER_PRICE_ORACLE       – DFeedPriceOracle address (default: address(0))
///   F_ADAPTER_MANUAL_POS_TOKEN_PRICE – Manual pos token price (default: 0)
///   F_ADAPTER_SUBSCRIBE_STEP_ASSET   – Subscribe step size (default: 0)
///   F_ADAPTER_REDEEM_STEP_POS        – Redeem step size (default: 0)
///   F_ADAPTER_MIN_SUBSCRIBE_ASSET    – Min subscribe amount (default: 0)
///   F_ADAPTER_MIN_REDEEM_POS         – Min redeem amount (default: 0)
contract DeployAll is Script {
    struct Deployed {
        // Factories
        SanctionsOracleFactory oracleFactory;
        VaultFactory vaultFactory;
        GatewayFactory gatewayFactory;
        AccountantFactory accountantFactory;
        StrategyControllerFactory controllerFactory;
        SubRedManagementAdapterFactory adapterFactory;
        // Proxies (user-facing)
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
        // ─── Load env ────────────────────────────────────────────────
        address admin = vm.envAddress("F_ADMIN_ADDRESS");
        address stable = vm.envAddress("F_STABLE_ADDRESS");
        address complianceBot = vm.envAddress("F_COMPLIANCE_BOT_ADDRESS");
        address bot = vm.envAddress("F_BOT_ADDRESS");
        address feeSettler = vm.envAddress("F_FEE_SETTLER_ADDRESS");
        address signer = vm.envAddress("F_SIGNER_ADDRESS");
        address treasury = vm.envAddress("F_TREASURY_ADDRESS");
        address pauser = vm.envAddress("F_PAUSER_ADDRESS");
        address capManager = vm.envAddress("F_CAP_MANAGER_ADDRESS");
        uint64 initialRate = uint64(vm.envUint("F_INITIAL_RATE"));
        uint32 managementFeeBps = uint32(vm.envUint("F_MANAGEMENT_FEE_BPS"));
        uint16 bufferTargetBps = uint16(vm.envUint("F_BUFFER_TARGET_BPS"));
        uint16 rebalanceThresholdBps = uint16(vm.envUint("F_REBALANCE_THRESHOLD_BPS"));
        uint64 rebalanceCooldown = uint64(vm.envUint("F_REBALANCE_COOLDOWN"));

        console2.log("=== DeployAll: Full mRWA Protocol ===");
        console2.log("Admin          :", admin);
        console2.log("Treasury       :", treasury);

        vm.startBroadcast();

        // ═════════════════════════════════════════════════════════════
        //  Phase 0 (testnet only): Deploy mock STABLE if address is zero
        // ═════════════════════════════════════════════════════════════
        if (stable == address(0)) {
            MockERC20Mintable mockStable = new MockERC20Mintable("Stable Coin", "STABLE", 6);
            stable = address(mockStable);
            console2.log("[Phase 0] Mock Stable deployed:", stable);
        }
        console2.log("STABLE           :", stable);

        // ═════════════════════════════════════════════════════════════
        //  Phase 1: Implementations + Factories
        // ═════════════════════════════════════════════════════════════

        SanctionsOracle oracleImpl = new SanctionsOracle();
        d.oracleFactory = new SanctionsOracleFactory(address(oracleImpl), admin);

        MantleYieldVault vaultImpl = new MantleYieldVault();
        d.vaultFactory = new VaultFactory(address(vaultImpl), admin);

        MantleVaultGateway gatewayImpl = new MantleVaultGateway();
        d.gatewayFactory = new GatewayFactory(address(gatewayImpl), admin);

        Accountant accountantImpl = new Accountant();
        d.accountantFactory = new AccountantFactory(address(accountantImpl), admin);

        StrategyController controllerImpl = new StrategyController();
        d.controllerFactory = new StrategyControllerFactory(address(controllerImpl), admin);

        SubRedManagementAdapter adapterImpl = new SubRedManagementAdapter();
        d.adapterFactory = new SubRedManagementAdapterFactory(address(adapterImpl), admin);

        AccountantExecutor accountantExecImpl = new AccountantExecutor();
        OperatorExecutor operatorExecImpl = new OperatorExecutor();

        console2.log("");
        console2.log("[Phase 1] Implementations + Factories");
        console2.log("  OracleFactory      :", address(d.oracleFactory));
        console2.log("  VaultFactory       :", address(d.vaultFactory));
        console2.log("  GatewayFactory     :", address(d.gatewayFactory));
        console2.log("  AccountantFactory  :", address(d.accountantFactory));
        console2.log("  ControllerFactory  :", address(d.controllerFactory));
        console2.log("  AdapterFactory     :", address(d.adapterFactory));
        console2.log("  AcctExecutor impl  :", address(accountantExecImpl));
        console2.log("  OpExecutor impl    :", address(operatorExecImpl));

        // ═════════════════════════════════════════════════════════════
        //  Phase 2: Deploy proxies (resolve circular dependencies)
        //
        //  Dependency graph:
        //    Vault  ──needs──▶ Oracle, Controller, Accountant
        //    Accountant ──needs──▶ Vault
        //    Controller ──needs──▶ Vault, OperatorExecutor
        //    OperatorExecutor ──needs──▶ Controller
        //
        //  Resolution: deploy Vault + Controller as UNINIT BeaconProxies
        //  (via factory), then deploy UUPS proxies with init data, then
        //  deferred-init the BeaconProxies.
        //
        //  Note: ERC1967Proxy cannot be deployed without init data, so
        //  only BeaconProxy (via factory.deploy*()) supports uninit mode.
        // ═════════════════════════════════════════════════════════════

        // 2a. SanctionsOracle — no dependencies, init immediately
        address oracleAddr = d.oracleFactory.deployAndInitOracle(admin, complianceBot);
        d.oracle = SanctionsOracle(oracleAddr);

        // 2b. Vault — UNINIT BeaconProxy (needs controller + accountant)
        address vaultAddr = d.vaultFactory.deployVault();

        // 2c. Gateway — UNINIT BeaconProxy (needs vault + oracle + sanctionSafe)
        address gatewayAddr = d.gatewayFactory.deployGateway();
        d.gateway = MantleVaultGateway(gatewayAddr);

        // 2d. Controller — UNINIT BeaconProxy (needs vault + opExec)
        address controllerAddr = d.controllerFactory.deployController();

        // 2e. OperatorExecutor — UUPS, init now (independent of controller address)
        address opExecAddr = address(
            new ERC1967Proxy(address(operatorExecImpl), abi.encodeCall(OperatorExecutor.initialize, (admin, signer)))
        );
        d.operatorExecutor = OperatorExecutor(opExecAddr);

        // 2f. AccountantExecutor — UUPS, init now
        address acctExecAddr = address(
            new ERC1967Proxy(address(accountantExecImpl), abi.encodeCall(AccountantExecutor.initialize, (admin)))
        );
        d.accountantExecutor = AccountantExecutor(acctExecAddr);

        // 2g. Accountant — init now (vault + AccountantExecutor addresses are known)
        address accountantAddr = d.accountantFactory
            .deployAndInitAccountant(vaultAddr, initialRate, managementFeeBps, admin, pauser, acctExecAddr);
        d.accountant = Accountant(accountantAddr);

        console2.log("");
        console2.log("[Phase 2] Proxies deployed");
        console2.log("  Oracle             :", oracleAddr);
        console2.log("  Vault (uninit)     :", vaultAddr);
        console2.log("  Gateway (uninit)   :", gatewayAddr);
        console2.log("  Controller (uninit):", controllerAddr);
        console2.log("  Accountant         :", accountantAddr);
        console2.log("  OpExecutor (UUPS)  :", opExecAddr);
        console2.log("  AcctExecutor (UUPS):", acctExecAddr);

        // ═════════════════════════════════════════════════════════════
        //  Phase 3: Initialize deferred BeaconProxies
        //  Order matters: Vault first (Controller.initialize reads vault.asset())
        // ═════════════════════════════════════════════════════════════

        // 3a. Vault.initialize (only stores addresses, no external calls)
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

        // 3b. Gateway.initialize
        d.gateway
            .initialize(
                IMantleVaultGateway.InitParams({
                    vault: vaultAddr,
                    sanctionsOracle: ISanctionsOracle(oracleAddr),
                    sanctionSafe: admin,
                    admin: admin,
                    syncRedeemDisabled: vm.envBool("F_SYNC_REDEEM_DISABLED")
                })
            );

        // 3c. StrategyController.initialize (reads vault.asset(), so vault must be init'd)
        d.controller = StrategyController(controllerAddr);
        d.controller
            .initialize(vaultAddr, admin, opExecAddr, pauser, bufferTargetBps, rebalanceThresholdBps, rebalanceCooldown);

        console2.log("");
        console2.log("[Phase 3] Deferred proxies initialized");
        console2.log("  Vault Gateway      :", address(d.gateway));

        // ═════════════════════════════════════════════════════════════
        //  Phase 4: Wire roles
        // ═════════════════════════════════════════════════════════════

        d.accountantExecutor.grantRole(d.accountantExecutor.BOT_ROLE(), bot);
        d.accountantExecutor.grantRole(d.accountantExecutor.FEE_SETTLER_ROLE(), feeSettler);
        d.vault.grantRole(d.vault.PAUSER_ROLE(), pauser);
        d.vault.grantRole(d.vault.CAP_MANAGER_ROLE(), capManager);

        console2.log("");
        console2.log("[Phase 4] Roles wired");
        console2.log("  AcctExecutor BOT_ROLE         -> bot       :", bot);
        console2.log("  AcctExecutor FEE_SETTLER_ROLE -> feeSettler:", feeSettler);
        console2.log("  Vault PAUSER_ROLE             -> pauser    :", pauser);
        console2.log("  Vault CAP_MANAGER_ROLE        -> capMgr    :", capManager);

        // ═════════════════════════════════════════════════════════════
        //  Phase 5 (optional): Deploy upgradeable SubRedManagementAdapter
        //  Skipped when F_ADAPTER_SUBRED_MANAGEMENT is not set.
        // ═════════════════════════════════════════════════════════════

        address adapterSubRed = vm.envOr("F_ADAPTER_SUBRED_MANAGEMENT", address(0));
        if (adapterSubRed != address(0)) {
            address adapterStToken = vm.envAddress("F_ADAPTER_ST_TOKEN");
            address adapterPriceOracle = vm.envOr("F_ADAPTER_PRICE_ORACLE", address(0));
            uint256 adapterManualPrice = vm.envOr("F_ADAPTER_MANUAL_POS_TOKEN_PRICE", uint256(0));

            address adapterAddr = d.adapterFactory
                .deployAndInitAdapter(
                    vaultAddr,
                    adapterSubRed,
                    adapterStToken,
                    admin,
                    controllerAddr,
                    address(d.accountantExecutor),
                    adapterPriceOracle
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

            console2.log("");
            console2.log("[Phase 5] Adapter deployed");
            console2.log("  Adapter (proxy)    :", adapterAddr);
            console2.log("  Adapter vault      :", d.adapter.vault());
            console2.log("  Adapter posToken   :", d.adapter.posToken());
        } else {
            console2.log("");
            console2.log("[Phase 5] Adapter skipped (F_ADAPTER_SUBRED_MANAGEMENT not set)");
        }

        vm.stopBroadcast();

        // ═════════════════════════════════════════════════════════════
        //  Post-deploy verification
        // ═════════════════════════════════════════════════════════════
        console2.log("");
        console2.log("========== Post-deploy Verification ==========");
        console2.log("");
        console2.log("--- SanctionsOracle ---");
        console2.log("  Has ADMIN:       ", d.oracle.hasRole(d.oracle.DEFAULT_ADMIN_ROLE(), admin));
        console2.log("  Has COMPLIANCE:  ", d.oracle.hasRole(d.oracle.COMPLIANCE_ROLE(), complianceBot));
        console2.log("");
        console2.log("--- MantleYieldVault ---");
        console2.log("  Asset:           ", d.vault.asset());
        console2.log("  Exchange rate:   ", d.vault.exchangeRate());
        console2.log("  Has ADMIN:       ", d.vault.hasRole(d.vault.DEFAULT_ADMIN_ROLE(), admin));
        console2.log("  Has PAUSER:      ", d.vault.hasRole(d.vault.PAUSER_ROLE(), pauser));
        console2.log("  Gateway:         ", d.vault.gateway());
        console2.log("");
        console2.log("--- Accountant ---");
        console2.log("  Vault:           ", address(d.accountant.vault()));
        console2.log(
            "  Has EXECUTOR:    ",
            d.accountant.hasRole(d.accountant.ACCOUNTANT_EXECUTOR_ROLE(), address(d.accountantExecutor))
        );
        console2.log("");
        console2.log("--- AccountantExecutor ---");
        console2.log(
            "  Admin:           ", d.accountantExecutor.hasRole(d.accountantExecutor.DEFAULT_ADMIN_ROLE(), admin)
        );
        console2.log("  Has BOT:         ", d.accountantExecutor.hasRole(d.accountantExecutor.BOT_ROLE(), bot));
        console2.log(
            "  Has FEE_SETTLER: ", d.accountantExecutor.hasRole(d.accountantExecutor.FEE_SETTLER_ROLE(), feeSettler)
        );
        console2.log("");
        console2.log("--- StrategyController ---");
        console2.log("  Vault:           ", address(d.controller.vault()));
        console2.log("  Has ADMIN:       ", d.controller.hasRole(d.controller.DEFAULT_ADMIN_ROLE(), admin));
        console2.log("  Has OP_EXECUTOR: ", d.controller.hasRole(d.controller.OPERATOR_EXECUTOR_ROLE(), opExecAddr));
        console2.log("  Has PAUSER:      ", d.controller.hasRole(d.controller.PAUSER_ROLE(), opExecAddr));
        console2.log("");
        console2.log("--- OperatorExecutor ---");
        console2.log("  Controller:      ", "passed per execute call");
        console2.log("  Has BOT:         ", d.operatorExecutor.hasRole(d.operatorExecutor.BOT_ROLE(), signer));
        console2.log("");
        console2.log("--- SubRedManagementAdapterFactory ---");
        console2.log("  Factory:         ", address(d.adapterFactory));
        console2.log("  Beacon:          ", address(d.adapterFactory.BEACON()));
        console2.log("  Adapter count:   ", d.adapterFactory.adapterCount());
        if (address(d.adapter) != address(0)) {
            console2.log("  Adapter[0]:      ", address(d.adapter));
            console2.log("    vault():       ", d.adapter.vault());
            console2.log("    posToken():    ", d.adapter.posToken());
        }
        console2.log("");
        console2.log("========== Deployment Complete ==========");
    }
}
