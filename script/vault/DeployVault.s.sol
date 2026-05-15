// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {IMantleVaultGateway} from "../../src/interfaces/vault/IMantleVaultGateway.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {GatewayFactory} from "../../src/vault/GatewayFactory.sol";
import {MantleVaultGateway} from "../../src/vault/MantleVaultGateway.sol";
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
///                              (also used as gateway.sanctionSafe init)
///   F_PAUSER_ADDRESS          – address to receive PAUSER_ROLE
///   F_CAP_MANAGER_ADDRESS     – address to receive CAP_MANAGER_ROLE
///   F_MAX_REDEMPTION_FEE_BPS  – max redemption fee cap in bps
///   F_REDEMPTION_FEE_BPS      – initial redemption fee in bps
///   F_MIN_REDEEM_AMOUNT       – minimum redeem amount
///   F_MIN_DEPOSIT_AMOUNT      – minimum deposit amount
///   F_SYNC_REDEEM_DISABLED    – gateway sync redeem disabled flag (true/false)
///   F_WHITELIST_ENABLED       – gateway whitelist enforcement flag (true/false; default false)
contract DeployVault is Script {
    function run()
        external
        returns (MantleYieldVault vaultImpl, VaultFactory factory, MantleYieldVault vault, MantleVaultGateway gateway)
    {
        address admin = vm.envAddress("F_ADMIN_ADDRESS");
        address pauser = vm.envAddress("F_PAUSER_ADDRESS");
        address capManager = vm.envAddress("F_CAP_MANAGER_ADDRESS");
        address treasury = vm.envAddress("F_TREASURY_ADDRESS");
        address sanctionsOracle = vm.envAddress("F_SANCTIONS_ORACLE");

        IMantleYieldVault.InitParams memory params = IMantleYieldVault.InitParams({
            asset: IERC20(vm.envAddress("F_USDC_ADDRESS")),
            name: "Mantle RWA Vault",
            symbol: "mRWA",
            admin: admin,
            gateway: address(0),
            controller: vm.envAddress("F_CONTROLLER_ADDRESS"),
            accountant: vm.envAddress("F_ACCOUNTANT_ADDRESS"),
            treasury: treasury,
            maxRedemptionFeeBps: vm.envUint("F_MAX_REDEMPTION_FEE_BPS"),
            redemptionFeeBps: vm.envUint("F_REDEMPTION_FEE_BPS"),
            minRedeemAmount: vm.envUint("F_MIN_REDEEM_AMOUNT"),
            minDepositAmount: vm.envUint("F_MIN_DEPOSIT_AMOUNT"),
            maxSettlementDeviationBps: vm.envOr("F_MAX_SETTLEMENT_DEVIATION_BPS", uint256(1000)),
            depositDailyRemaining: vm.envOr("F_DEPOSIT_DAILY_REMAINING", type(uint256).max),
            redeemDailyRemaining: vm.envOr("F_REDEEM_DAILY_REMAINING", type(uint256).max)
        });

        console2.log("=== DeployVault ===");
        console2.log("Admin              :", admin);
        console2.log("USDC               :", address(params.asset));
        console2.log("SanctionsOracle    :", sanctionsOracle);
        console2.log("Controller         :", params.controller);
        console2.log("Accountant         :", params.accountant);
        console2.log("Treasury           :", params.treasury);
        console2.log("Pauser             :", pauser);
        console2.log("CapManager         :", capManager);
        console2.log("MaxRedemptionFee   :", params.maxRedemptionFeeBps);
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

        // ---- 3. Deploy gateway implementation + factory ----
        MantleVaultGateway gatewayImpl = new MantleVaultGateway();
        GatewayFactory gatewayFactory = new GatewayFactory(address(gatewayImpl), admin);

        // ---- 4. Deploy MantleYieldVault instance via BeaconProxy (uninitialized) ----
        address vaultAddr = factory.deployVault();
        vault = MantleYieldVault(vaultAddr);
        console2.log("[3/4] Vault (proxy)      :", vaultAddr);

        // ---- 5. Deploy gateway proxy (uninitialized), then initialize vault + gateway ----
        address gatewayAddr = gatewayFactory.deployGateway();
        gateway = MantleVaultGateway(gatewayAddr);
        params.gateway = address(gateway);
        vault.initialize(params);
        gateway.initialize(
            IMantleVaultGateway.InitParams({
                vault: vaultAddr,
                sanctionsOracle: ISanctionsOracle(sanctionsOracle),
                sanctionSafe: treasury,
                admin: admin,
                syncRedeemDisabled: vm.envBool("F_SYNC_REDEEM_DISABLED")
            })
        );
        if (vm.envOr("F_WHITELIST_ENABLED", false)) {
            gateway.setWhitelistEnabled(true);
        }
        console2.log("[4/5] Vault Gateway      :", params.gateway);
        console2.log("       Whitelist enabled :", gateway.whitelistEnabled());

        // ---- 5. Grant Vault roles ----
        vault.grantRole(vault.PAUSER_ROLE(), pauser);
        vault.grantRole(vault.CAP_MANAGER_ROLE(), capManager);
        console2.log("[5/5] PAUSER_ROLE granted to     :", pauser);
        console2.log("[5/5] CAP_MANAGER_ROLE granted to:", capManager);

        vm.stopBroadcast();

        // Post-deploy verification
        console2.log("");
        console2.log("=== Post-deploy Verification ===");
        console2.log("Beacon -> impl:    ", factory.implementation());
        console2.log("Factory vault cnt: ", factory.vaultCount());
        console2.log("Has ADMIN_ROLE:    ", vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
        console2.log("Has PAUSER_ROLE:   ", vault.hasRole(vault.PAUSER_ROLE(), pauser));
        console2.log("Has CAP_MANAGER:   ", vault.hasRole(vault.CAP_MANAGER_ROLE(), capManager));
        console2.log("Gateway:           ", vault.gateway());
        console2.log("Asset:             ", vault.asset());
        console2.log("Exchange rate:     ", vault.exchangeRate());
    }
}
