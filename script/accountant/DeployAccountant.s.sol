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
///         5. Wires ACCOUNTANT_EXECUTOR_ROLE and BOT_ROLE
///
/// Required env vars (set via deploy-config YAML):
///   F_VAULT_ADDRESS        – MantleYieldVault proxy address
///   F_INITIAL_RATE         – starting exchange rate (18-decimal, e.g. 1e18)
///   F_MANAGEMENT_FEE_BPS   – management fee in bps (e.g. 50 = 0.5%)
///   F_ADMIN_ADDRESS        – admin address (also used as beacon owner)
///   F_BOT_ADDRESS          – bot address to receive BOT_ROLE on the Executor
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
        address admin = vm.envAddress("F_ADMIN_ADDRESS");
        address bot = vm.envAddress("F_BOT_ADDRESS");

        console2.log("=== DeployAccountant ===");
        console2.log("Admin          :", admin);
        console2.log("Vault          :", vaultAddr);
        console2.log("Initial rate   :", initialRate);
        console2.log("Mgmt fee (bps) :", managementFeeBps);
        console2.log("Bot            :", bot);

        vm.startBroadcast();

        // ---- 1. Deploy Accountant implementation (locked) ----
        accountantImpl = new Accountant();
        console2.log("[1/5] Accountant impl    :", address(accountantImpl));

        // ---- 2. Deploy AccountantFactory (creates UpgradeableBeacon internally) ----
        factory = new AccountantFactory(address(accountantImpl), admin);
        console2.log("[2/5] AccountantFactory  :", address(factory));
        console2.log("       Beacon            :", address(factory.BEACON()));

        // ---- 3. Deploy Accountant instance via BeaconProxy ----
        address accountantAddr = factory.deployAndInitAccountant(vaultAddr, initialRate, managementFeeBps, admin);
        accountant = Accountant(accountantAddr);
        console2.log("[3/5] Accountant (proxy) :", accountantAddr);

        // ---- 4. Deploy AccountantExecutor behind UUPS proxy (ERC1967Proxy) ----
        executorImpl = new AccountantExecutor();
        ERC1967Proxy executorProxy =
            new ERC1967Proxy(address(executorImpl), abi.encodeCall(AccountantExecutor.initialize, (admin)));
        executor = AccountantExecutor(address(executorProxy));
        console2.log("[4/5] Executor impl      :", address(executorImpl));
        console2.log("       Executor (UUPS)   :", address(executorProxy));

        // ---- 5. Wire roles ----
        accountant.grantRole(accountant.ACCOUNTANT_EXECUTOR_ROLE(), address(executorProxy));
        executor.grantRole(executor.BOT_ROLE(), bot);
        console2.log("[5/5] Roles wired");
        console2.log("  ACCOUNTANT_EXECUTOR_ROLE -> Executor proxy");
        console2.log("  BOT_ROLE      -> bot:", bot);

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
    }
}
