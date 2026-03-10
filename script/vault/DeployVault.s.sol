// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {VaultFactory} from "../../src/vault/VaultFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Script, console} from "forge-std/Script.sol";

/**
 * @title DeployVault
 * @notice Deployment script for the MantleYieldVault system (Beacon Proxy).
 *
 * Deploys:
 *   1. MantleYieldVault implementation
 *   2. VaultFactory (creates UpgradeableBeacon internally)
 *   3. First vault instance via deployAndInitVault()
 *   4. Grants PAUSER_ROLE
 *
 * Signing modes:
 *   A) Private key  — set DEPLOYER_PRIVATE_KEY in .env
 *   B) Ledger       — set DEPLOYER_ADDRESS in .env, run with --ledger
 *
 * Usage:
 *   # Private key
 *   forge script script/vault/DeployVault.s.sol:DeployVault \
 *     --rpc-url mantle_sepolia --broadcast --verify -vvv
 *
 *   # Ledger (derivation path default: m/44'/60'/0'/0/0)
 *   forge script script/vault/DeployVault.s.sol:DeployVault \
 *     --rpc-url mantle_sepolia --broadcast --verify --ledger -vvv
 *
 *   # Ledger with custom derivation path
 *   forge script script/vault/DeployVault.s.sol:DeployVault \
 *     --rpc-url mantle_sepolia --broadcast --verify \
 *     --ledger --mnemonic-derivation-path "m/44'/60'/0'/0/1" -vvv
 */
contract DeployVault is Script {
    function run() external {
        (address deployer, bool useLedger) = _resolveDeployer();
        address pauserAddr = vm.envAddress("PAUSER");
        IMantleYieldVault.InitParams memory params = _buildParams(deployer);

        _logConfig(deployer, useLedger, pauserAddr, params);

        if (useLedger) {
            vm.startBroadcast(deployer);
        } else {
            vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        }

        MantleYieldVault impl = new MantleYieldVault();
        console.log("\n[1/4] Implementation deployed:", address(impl));

        VaultFactory factory = new VaultFactory(address(impl), deployer);
        console.log("[2/4] VaultFactory deployed:", address(factory));
        console.log("       Beacon:", address(factory.BEACON()));

        address vault = factory.deployAndInitVault(params);
        console.log("[3/4] Vault deployed:", vault);

        MantleYieldVault v = MantleYieldVault(vault);
        v.grantRole(v.PAUSER_ROLE(), pauserAddr);
        console.log("[4/4] PAUSER_ROLE granted to:", pauserAddr);

        vm.stopBroadcast();

        console.log("\n=== Deployment Complete ===");
        console.log("Factory:", address(factory));
        console.log("Vault:", vault);
        console.log("Implementation:", address(impl));
    }

    function _buildParams(address deployer) internal view returns (IMantleYieldVault.InitParams memory) {
        return IMantleYieldVault.InitParams({
            asset: IERC20(vm.envAddress("USDC_ADDRESS")),
            name: "Mantle RWA Vault",
            symbol: "mRWA",
            admin: deployer,
            sanctionsOracle: vm.envAddress("SANCTIONS_ORACLE"),
            controller: vm.envAddress("CONTROLLER"),
            accountant: vm.envAddress("ACCOUNTANT"),
            treasury: vm.envAddress("TREASURY"),
            maxRedemptionFeeBps: vm.envUint("MAX_REDEMPTION_FEE_BPS"),
            maxRateChangeBps: vm.envUint("MAX_RATE_CHANGE_BPS"),
            redemptionFeeBps: vm.envUint("REDEMPTION_FEE_BPS"),
            minRedeemAmount: vm.envUint("MIN_REDEEM_AMOUNT"),
            minDepositAmount: vm.envUint("MIN_DEPOSIT_AMOUNT"),
            syncRedeemDisabled: vm.envBool("SYNC_REDEEM_DISABLED")
        });
    }

    function _logConfig(address deployer, bool useLedger, address pauserAddr, IMantleYieldVault.InitParams memory p)
        internal
        pure
    {
        console.log("=== Deployment Configuration ===");
        console.log("Deployer (admin):", deployer);
        console.log("Signing mode:", useLedger ? "Ledger" : "PrivateKey");
        console.log("USDC:", address(p.asset));
        console.log("SanctionsOracle:", p.sanctionsOracle);
        console.log("Controller:", p.controller);
        console.log("Accountant:", p.accountant);
        console.log("Treasury:", p.treasury);
        console.log("Pauser:", pauserAddr);
        console.log("MaxRedemptionFeeBps:", p.maxRedemptionFeeBps);
        console.log("MaxRateChangeBps:", p.maxRateChangeBps);
        console.log("RedemptionFeeBps:", p.redemptionFeeBps);
        console.log("MinRedeemAmount:", p.minRedeemAmount);
        console.log("SyncRedeemDisabled:", p.syncRedeemDisabled);
    }

    /// @dev Try DEPLOYER_PRIVATE_KEY first; if empty, fall back to DEPLOYER_ADDRESS (Ledger mode).
    function _resolveDeployer() internal view returns (address deployer, bool useLedger) {
        uint256 pk = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        if (pk != 0) {
            return (vm.addr(pk), false);
        }
        deployer = vm.envAddress("DEPLOYER_ADDRESS");
        return (deployer, true);
    }
}
