// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Accountant} from "../src/accountant/Accountant.sol";
import {AccountantExecutor} from "../src/accountant/AccountantExecutor.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @title DeployAccountant
/// @notice Deploys Accountant + AccountantExecutor behind ERC1967 proxies and wires roles.
///
/// Required env vars (set via deploy-config YAML):
///   F_VAULT_ADDRESS        – MantleYieldVault proxy address
///   F_TREASURY_ADDRESS     – fee treasury address
///   F_INITIAL_RATE         – starting exchange rate (18-decimal, e.g. 1e18)
///   F_MANAGEMENT_FEE_BPS   – management fee in bps (e.g. 50 = 0.5%)
///   F_ADMIN_ADDRESS        – admin address
///   F_BOT_ADDRESS          – bot address to receive BOT_ROLE on the Executor
contract DeployAccountant is Script {
    function run() external {
        address vaultAddr = vm.envAddress("F_VAULT_ADDRESS");
        address treasuryAddr = vm.envAddress("F_TREASURY_ADDRESS");
        uint256 initialRate = vm.envUint("F_INITIAL_RATE");
        uint256 managementFeeBps = vm.envUint("F_MANAGEMENT_FEE_BPS");
        address admin = vm.envAddress("F_ADMIN_ADDRESS");
        address bot = vm.envAddress("F_BOT_ADDRESS");

        console2.log("=== DeployAccountant ===");
        console2.log("Admin          :", admin);
        console2.log("Vault          :", vaultAddr);
        console2.log("Treasury       :", treasuryAddr);
        console2.log("Initial rate   :", initialRate);
        console2.log("Mgmt fee (bps) :", managementFeeBps);
        console2.log("Bot            :", bot);

        vm.startBroadcast();

        // ---- 1. Deploy Accountant (implementation + proxy) ----
        Accountant accountantImpl = new Accountant();
        ERC1967Proxy accountantProxy = new ERC1967Proxy(
            address(accountantImpl),
            abi.encodeCall(Accountant.initialize, (vaultAddr, treasuryAddr, initialRate, managementFeeBps, admin))
        );
        Accountant accountant = Accountant(address(accountantProxy));

        console2.log("Accountant impl  :", address(accountantImpl));
        console2.log("Accountant proxy :", address(accountantProxy));

        // ---- 2. Deploy AccountantExecutor (implementation + proxy) ----
        AccountantExecutor executorImpl = new AccountantExecutor();
        ERC1967Proxy executorProxy = new ERC1967Proxy(
            address(executorImpl), abi.encodeCall(AccountantExecutor.initialize, (address(accountantProxy), admin))
        );
        AccountantExecutor executor = AccountantExecutor(address(executorProxy));

        console2.log("Executor impl    :", address(executorImpl));
        console2.log("Executor proxy   :", address(executorProxy));

        // ---- 3. Wire roles ----
        accountant.grantRole(accountant.EXECUTOR_ROLE(), address(executorProxy));
        executor.grantRole(executor.BOT_ROLE(), bot);

        console2.log("Granted EXECUTOR_ROLE on Accountant to Executor proxy");
        console2.log("Granted BOT_ROLE on Executor to bot:", bot);

        vm.stopBroadcast();
    }
}
