// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {VaultFactory} from "../../src/vault/VaultFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @title DeployVault
/// @notice Deploys the full MantleYieldVault stack:
///         1. MantleYieldVault implementation
///         2. VaultFactory (creates UpgradeableBeacon internally)
///         3. MantleYieldVault instance via BeaconProxy (through factory)
///         4. Grants PAUSER_ROLE
///
/// Required env vars (set via deploy-config YAML):
///   F_ADMIN_ADDRESS           – admin address (also used as beacon owner)
///   F_USDC_ADDRESS            – USDC token address
///   F_SANCTIONS_ORACLE        – SanctionsOracle proxy address
///   F_CONTROLLER_ADDRESS      – StrategyController proxy address
///   F_ACCOUNTANT_ADDRESS      – Accountant proxy address
///   F_TREASURY_ADDRESS        – treasury address for fee shares
///   F_PAUSER_ADDRESS          – address to receive PAUSER_ROLE
///   F_MAX_REDEMPTION_FEE_BPS  – max redemption fee cap in bps
///   F_MAX_RATE_CHANGE_BPS     – max rate change cap in bps
///   F_REDEMPTION_FEE_BPS      – initial redemption fee in bps
///   F_MIN_REDEEM_AMOUNT       – minimum redeem amount
///   F_MIN_DEPOSIT_AMOUNT      – minimum deposit amount
///   F_SYNC_REDEEM_DISABLED    – whether sync redeem is disabled (true/false)
contract DeployVault is Script {
    function run()
        external
        returns (MantleYieldVault vaultImpl, VaultFactory factory, MantleYieldVault vault)
    {
        address admin = vm.envAddress("F_ADMIN_ADDRESS");
        address pauser = vm.envAddress("F_PAUSER_ADDRESS");

        IMantleYieldVault.InitParams memory params = IMantleYieldVault.InitParams({
            asset: IERC20(vm.envAddress("F_USDC_ADDRESS")),
            name: "Mantle RWA Vault",
            symbol: "mRWA",
            admin: admin,
            sanctionsOracle: vm.envAddress("F_SANCTIONS_ORACLE"),
            controller: vm.envAddress("F_CONTROLLER_ADDRESS"),
            accountant: vm.envAddress("F_ACCOUNTANT_ADDRESS"),
            treasury: vm.envAddress("F_TREASURY_ADDRESS"),
            maxRedemptionFeeBps: vm.envUint("F_MAX_REDEMPTION_FEE_BPS"),
            maxRateChangeBps: vm.envUint("F_MAX_RATE_CHANGE_BPS"),
            redemptionFeeBps: vm.envUint("F_REDEMPTION_FEE_BPS"),
            minRedeemAmount: vm.envUint("F_MIN_REDEEM_AMOUNT"),
            minDepositAmount: vm.envUint("F_MIN_DEPOSIT_AMOUNT"),
            syncRedeemDisabled: vm.envBool("F_SYNC_REDEEM_DISABLED")
        });

        console2.log("=== DeployVault ===");
        console2.log("Admin              :", admin);
        console2.log("USDC               :", address(params.asset));
        console2.log("SanctionsOracle    :", params.sanctionsOracle);
        console2.log("Controller         :", params.controller);
        console2.log("Accountant         :", params.accountant);
        console2.log("Treasury           :", params.treasury);
        console2.log("Pauser             :", pauser);
        console2.log("MaxRedemptionFee   :", params.maxRedemptionFeeBps);
        console2.log("MaxRateChange      :", params.maxRateChangeBps);
        console2.log("RedemptionFee      :", params.redemptionFeeBps);
        console2.log("MinRedeem          :", params.minRedeemAmount);
        console2.log("MinDeposit         :", params.minDepositAmount);

        vm.startBroadcast();

        // ---- 1. Deploy MantleYieldVault implementation (locked) ----
        vaultImpl = new MantleYieldVault();
        console2.log("[1/4] Vault impl         :", address(vaultImpl));

        // ---- 2. Deploy VaultFactory (creates UpgradeableBeacon internally) ----
        factory = new VaultFactory(address(vaultImpl), admin);
        console2.log("[2/4] VaultFactory       :", address(factory));
        console2.log("       Beacon            :", address(factory.BEACON()));

        // ---- 3. Deploy MantleYieldVault instance via BeaconProxy ----
        address vaultAddr = factory.deployAndInitVault(params);
        vault = MantleYieldVault(vaultAddr);
        console2.log("[3/4] Vault (proxy)      :", vaultAddr);

        // ---- 4. Grant PAUSER_ROLE ----
        vault.grantRole(vault.PAUSER_ROLE(), pauser);
        console2.log("[4/4] PAUSER_ROLE granted to:", pauser);

        vm.stopBroadcast();

        // Post-deploy verification
        console2.log("");
        console2.log("=== Post-deploy Verification ===");
        console2.log("Beacon -> impl:    ", factory.implementation());
        console2.log("Factory vault cnt: ", factory.vaultCount());
        console2.log("Has ADMIN_ROLE:    ", vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
        console2.log("Has PAUSER_ROLE:   ", vault.hasRole(vault.PAUSER_ROLE(), pauser));
        console2.log("Asset:             ", vault.asset());
        console2.log("Exchange rate:     ", vault.exchangeRate());
    }
}
