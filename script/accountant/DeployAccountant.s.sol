// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Accountant} from "../../src/accountant/Accountant.sol";
import {AccountantExecutor} from "../../src/accountant/AccountantExecutor.sol";
import {AccountantFactory} from "../../src/accountant/AccountantFactory.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @title DeployAccountant
/// @notice Deploys the full Accountant stack:
///         1. Accountant implementation
///         2. AccountantFactory (creates UpgradeableBeacon internally)
///         3. Accountant instance via BeaconProxy (through factory)
///         4. AccountantExecutor behind a UUPS proxy (ERC1967Proxy)
///         5. Wires ACCOUNTANT_EXECUTOR_ROLE, BOT_ROLE, and FEE_SETTLER_ROLE
///
/// Required env vars (set via deploy-config YAML):
///   F_VAULT_ADDRESS              – MantleYieldVault proxy address
///   F_INITIAL_RATE               – starting exchange rate (18-decimal, e.g. 1e18)
///   F_MANAGEMENT_FEE_BPS         – management fee in bps (e.g. 50 = 0.5%)
///   F_MAX_ALLOWED_DEVIATION_BPS  – circuit-breaker deviation cap in bps (e.g. 100 = 1%)
///   F_MIN_UPDATE_INTERVAL_SECONDS – minimum seconds between rate updates (e.g. 72000 = 20h)
///   F_MAX_COMPUTE_AGE_SECONDS    – max seconds compute timestamp may lag (e.g. 300 = 5min)
///   F_ADMIN_ADDRESS              – admin address (also used as beacon owner)
///   F_PAUSER_ADDRESS             – address to receive PAUSER_ROLE on the Accountant
///   F_BOT_ADDRESS                – bot address to receive BOT_ROLE on the Executor
///   F_FEE_SETTLER_ADDRESS        – bot address to receive FEE_SETTLER_ROLE on the Executor
contract DeployAccountant is Script {
    function run()
        external
        returns (
            Accountant accountantImpl,
            AccountantFactory factory,
            Accountant accountant,
            AccountantExecutor executorImpl,
            AccountantExecutor executor
        )
    {
        address vaultAddr = vm.envAddress("F_VAULT_ADDRESS");
        uint64 initialRate = uint64(vm.envUint("F_INITIAL_RATE"));
        uint32 managementFeeBps = uint32(vm.envUint("F_MANAGEMENT_FEE_BPS"));
        uint32 maxAllowedDeviation = uint32(vm.envUint("F_MAX_ALLOWED_DEVIATION_BPS"));
        uint32 minUpdateInterval = uint32(vm.envUint("F_MIN_UPDATE_INTERVAL_SECONDS"));
        uint32 maxComputeAge = uint32(vm.envUint("F_MAX_COMPUTE_AGE_SECONDS"));
        address admin = vm.envAddress("F_ADMIN_ADDRESS");
        address pauser = vm.envAddress("F_PAUSER_ADDRESS");
        address bot = vm.envAddress("F_BOT_ADDRESS");
        address feeSettler = vm.envAddress("F_FEE_SETTLER_ADDRESS");

        console2.log("=== DeployAccountant ===");
        console2.log("Admin          :", admin);
        console2.log("Vault          :", vaultAddr);
        console2.log("Initial rate   :", initialRate);
        console2.log("Mgmt fee (bps) :", managementFeeBps);
        console2.log("Max deviation  :", maxAllowedDeviation);
        console2.log("Min interval(s):", minUpdateInterval);
        console2.log("Max age (s)    :", maxComputeAge);
        console2.log("Pauser         :", pauser);
        console2.log("Bot            :", bot);
        console2.log("Fee settler    :", feeSettler);

        vm.startBroadcast();

        // ---- 1. Deploy Accountant implementation (locked) ----
        accountantImpl = new Accountant();
        console2.log("[1/5] Accountant impl    :", address(accountantImpl));

        // ---- 2. Deploy AccountantFactory (creates UpgradeableBeacon internally) ----
        factory = new AccountantFactory(address(accountantImpl), admin);
        console2.log("[2/5] AccountantFactory  :", address(factory));
        console2.log("       Beacon            :", address(factory.BEACON()));

        // ---- 3. Deploy AccountantExecutor behind UUPS proxy (ERC1967Proxy) ----
        executorImpl = new AccountantExecutor();
        ERC1967Proxy executorProxy =
            new ERC1967Proxy(address(executorImpl), abi.encodeCall(AccountantExecutor.initialize, (admin)));
        executor = AccountantExecutor(address(executorProxy));
        console2.log("[3/5] Executor impl      :", address(executorImpl));
        console2.log("       Executor (UUPS)   :", address(executorProxy));

        // ---- 4. Deploy Accountant instance via BeaconProxy ----
        address accountantAddr = factory.deployAndInitAccountant(
            vaultAddr,
            initialRate,
            managementFeeBps,
            maxAllowedDeviation,
            minUpdateInterval,
            maxComputeAge,
            admin,
            pauser,
            address(executorProxy)
        );
        accountant = Accountant(accountantAddr);
        console2.log("[4/5] Accountant (proxy) :", accountantAddr);

        // ---- 5. Wire roles ----
        executor.grantRole(executor.BOT_ROLE(), bot);
        executor.grantRole(executor.FEE_SETTLER_ROLE(), feeSettler);
        console2.log("[5/5] Roles wired");
        console2.log("  BOT_ROLE         -> bot       :", bot);
        console2.log("  FEE_SETTLER_ROLE -> feeSettler:", feeSettler);

        vm.stopBroadcast();

        // Post-deploy verification
        console2.log("");
        console2.log("=== Post-deploy Verification ===");
        console2.log("Beacon -> impl:         ", factory.implementation());
        console2.log("Factory accountant cnt: ", factory.accountantCount());
        console2.log(
            "Has ACCOUNTANT_EXECUTOR_ROLE:",
            accountant.hasRole(accountant.ACCOUNTANT_EXECUTOR_ROLE(), address(executor))
        );
        console2.log("Has BOT_ROLE:           ", executor.hasRole(executor.BOT_ROLE(), bot));
        console2.log("Has FEE_SETTLER_ROLE:   ", executor.hasRole(executor.FEE_SETTLER_ROLE(), feeSettler));
    }
}
