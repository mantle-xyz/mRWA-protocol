// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {MantleVaultGateway} from "../../src/vault/MantleVaultGateway.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Script, console} from "forge-std/Script.sol";

/**
 * @title Interact
 * @notice Interactive scripts for vault operations. Each contract is a standalone action.
 *
 * Signing modes (applied to all scripts below):
 *   A) Private key  — set USER_PRIVATE_KEY / CONTROLLER_PRIVATE_KEY in .env
 *   B) Ledger       — set USER_ADDRESS / CONTROLLER_ADDRESS in .env, run with --ledger
 *
 * Common env vars:
 *   VAULT_ADDRESS  - deployed vault proxy address
 *   USDC_ADDRESS   - underlying USDC address
 *
 * === User Actions ===
 *
 *   # Deposit (private key)
 *   forge script script/vault/Interact.s.sol:Deposit --rpc-url mantle_sepolia --broadcast -vvv
 *
 *   # Deposit (Ledger)
 *   forge script script/vault/Interact.s.sol:Deposit --rpc-url mantle_sepolia --broadcast --ledger -vvv
 *
 *   # Sync Redeem / Request Async Redeem — same pattern, swap contract name
 *
 *   Note: Async redeem no longer requires ClaimRedeem — controller's MarkRequestsDone transfers USDC directly to users.
 *
 * === Controller Actions ===
 *
 *   # ProcessRequests (PENDING->PROCESSING) / MarkRequestsDone (transfers USDC to users) — same pattern with CONTROLLER_PRIVATE_KEY or CONTROLLER_ADDRESS
 *
 * === View Actions (no broadcast / no signing) ===
 *
 *   forge script script/vault/Interact.s.sol:VaultStatus --rpc-url mantle_sepolia -vvv
 */

// =============================================================
// Shared: Signer resolution helpers
// =============================================================

abstract contract SignerHelper is Script {
    function _resolveGateway(MantleYieldVault vault) internal view returns (MantleVaultGateway) {
        address gatewayAddr = vm.envOr("VAULT_GATEWAY_ADDRESS", address(0));
        if (gatewayAddr == address(0)) {
            gatewayAddr = vault.gateway();
        }
        require(gatewayAddr != address(0), "Gateway not set");
        return MantleVaultGateway(gatewayAddr);
    }

    /// @dev Resolve user signer: try USER_PRIVATE_KEY, fall back to USER_ADDRESS (Ledger).
    function _resolveUser() internal view returns (address user, bool useLedger) {
        uint256 pk = vm.envOr("USER_PRIVATE_KEY", uint256(0));
        if (pk != 0) return (vm.addr(pk), false);
        return (vm.envAddress("USER_ADDRESS"), true);
    }

    function _startUserBroadcast(bool useLedger, address user) internal {
        if (useLedger) {
            vm.startBroadcast(user);
        } else {
            vm.startBroadcast(vm.envUint("USER_PRIVATE_KEY"));
        }
    }

    /// @dev Resolve controller signer: try CONTROLLER_PRIVATE_KEY, fall back to CONTROLLER_ADDRESS (Ledger).
    function _resolveController() internal view returns (address controller, bool useLedger) {
        uint256 pk = vm.envOr("CONTROLLER_PRIVATE_KEY", uint256(0));
        if (pk != 0) return (vm.addr(pk), false);
        return (vm.envAddress("CONTROLLER_ADDRESS"), true);
    }

    function _startControllerBroadcast(bool useLedger, address controller) internal {
        if (useLedger) {
            vm.startBroadcast(controller);
        } else {
            vm.startBroadcast(vm.envUint("CONTROLLER_PRIVATE_KEY"));
        }
    }

    function _parseUintArray(string memory csv) internal pure returns (uint256[] memory) {
        bytes memory b = bytes(csv);
        uint256 count = 1;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == ",") count++;
        }
        uint256[] memory result = new uint256[](count);
        uint256 idx = 0;
        uint256 current = 0;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == ",") {
                result[idx++] = current;
                current = 0;
            } else {
                current = current * 10 + (uint8(b[i]) - 48);
            }
        }
        result[idx] = current;
        return result;
    }
}

// =============================================================
// User: Deposit
// =============================================================

contract Deposit is SignerHelper {
    function run() external {
        (address user, bool useLedger) = _resolveUser();
        address vaultAddr = vm.envAddress("VAULT_ADDRESS");
        address usdcAddr = vm.envAddress("USDC_ADDRESS");
        uint256 amount = vm.envUint("DEPOSIT_AMOUNT");

        MantleYieldVault vault = MantleYieldVault(vaultAddr);
        MantleVaultGateway gateway = _resolveGateway(vault);
        IERC20 usdc = IERC20(usdcAddr);

        console.log("=== Deposit ===");
        console.log("User:", user);
        console.log("Signing mode:", useLedger ? "Ledger" : "PrivateKey");
        console.log("USDC balance:", usdc.balanceOf(user));
        console.log("Deposit amount:", amount);
        console.log("Expected shares:", vault.previewDeposit(amount));

        _startUserBroadcast(useLedger, user);
        usdc.approve(vaultAddr, amount);
        uint256 shares = gateway.deposit(amount);
        vm.stopBroadcast();

        console.log("\nShares received:", shares);
        console.log("New share balance:", vault.balanceOf(user));
    }
}

// =============================================================
// User: Sync Redeem
// =============================================================

contract SyncRedeem is SignerHelper {
    function run() external {
        (address user, bool useLedger) = _resolveUser();
        address vaultAddr = vm.envAddress("VAULT_ADDRESS");

        MantleYieldVault vault = MantleYieldVault(vaultAddr);
        MantleVaultGateway gateway = _resolveGateway(vault);

        uint256 shares = vm.envUint("REDEEM_SHARES");
        uint256 maxRedeemable = vault.maxRedeem(user);

        console.log("=== Sync Redeem ===");
        console.log("User:", user);
        console.log("Signing mode:", useLedger ? "Ledger" : "PrivateKey");
        console.log("Share balance:", vault.balanceOf(user));
        console.log("Shares to redeem:", shares);
        console.log("Max redeemable:", maxRedeemable);
        console.log("Expected USDC (net of fee):", vault.previewRedeem(shares));
        console.log("FreeCash:", vault.getFreeCash());

        require(shares <= maxRedeemable, "Exceeds maxRedeem - use async redeem instead");

        _startUserBroadcast(useLedger, user);
        uint256 assets = gateway.redeem(shares);
        vm.stopBroadcast();

        console.log("\nUSDC received:", assets);
        console.log("Remaining shares:", vault.balanceOf(user));
    }
}

// =============================================================
// User: Request Async Redeem
// =============================================================

contract RequestRedeem is SignerHelper {
    function run() external {
        (address user, bool useLedger) = _resolveUser();
        address vaultAddr = vm.envAddress("VAULT_ADDRESS");

        MantleYieldVault vault = MantleYieldVault(vaultAddr);
        MantleVaultGateway gateway = _resolveGateway(vault);

        uint256 shares = vm.envUint("REDEEM_SHARES");
        uint256 shareBal = vault.balanceOf(user);

        console.log("=== Request Async Redeem ===");
        console.log("User:", user);
        console.log("Signing mode:", useLedger ? "Ledger" : "PrivateKey");
        console.log("Share balance:", shareBal);
        console.log("Shares to request:", shares);

        require(shares <= shareBal, "Insufficient shares");

        _startUserBroadcast(useLedger, user);
        uint256 requestId = gateway.requestRedeem(shares);
        vm.stopBroadcast();

        (,, uint256 reqShares,, uint256 reqAssets,,,) = vault.requests(requestId);

        console.log("\nRequest ID:", requestId);
        console.log("Shares burned:", reqShares);
        console.log("Expected payout (USDC):", reqAssets);
        console.log("Status: PENDING");
        console.log("\nNext: Controller calls ProcessRequests -> MarkRequestsDone (USDC transferred directly to user)");
    }
}

// =============================================================
// Controller: Process Requests (PENDING -> PROCESSING)
// =============================================================

contract ProcessRequests is SignerHelper {
    function run() external {
        (, bool useLedger) = _resolveController();
        address controller;
        (controller, useLedger) = _resolveController();
        address vaultAddr = vm.envAddress("VAULT_ADDRESS");

        MantleYieldVault vault = MantleYieldVault(vaultAddr);
        uint256[] memory ids = _parseUintArray(vm.envString("REQUEST_IDS"));

        console.log("=== Process Requests ===");
        console.log("Controller:", controller);
        console.log("Signing mode:", useLedger ? "Ledger" : "PrivateKey");
        console.log("Request count:", ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            console.log("  ID:", ids[i]);
        }

        _startControllerBroadcast(useLedger, controller);
        vault.updateRequestBatch(ids, IMantleYieldVault.RequestStatus.PROCESSING);
        vm.stopBroadcast();

        console.log("\nAll requests moved to PROCESSING");
        console.log("Next: Ensure USDC is available, then call ReadyRequests");
    }
}

// =============================================================
// Controller: Mark Requests Done (PROCESSING -> DONE, transfers USDC directly to users)
// =============================================================

contract MarkRequestsDone is SignerHelper {
    function run() external {
        (address controller, bool useLedger) = _resolveController();
        address vaultAddr = vm.envAddress("VAULT_ADDRESS");

        MantleYieldVault vault = MantleYieldVault(vaultAddr);
        uint256[] memory ids = _parseUintArray(vm.envString("REQUEST_IDS"));
        uint256[] memory settled = _parseUintArray(vm.envString("SETTLED_AMOUNTS"));

        require(ids.length == settled.length, "REQUEST_IDS and SETTLED_AMOUNTS must have same length");

        console.log("=== Mark Requests Done ===");
        console.log("Controller:", controller);
        console.log("Signing mode:", useLedger ? "Ledger" : "PrivateKey");
        for (uint256 i = 0; i < ids.length; i++) {
            (,,,, uint256 originalAssets,,,) = vault.requests(ids[i]);
            console.log("  ID:", ids[i]);
            console.log("    Original assets:", originalAssets);
            console.log("    Settled assets:", settled[i]);
        }

        _startControllerBroadcast(useLedger, controller);
        vault.markRequestsDone(ids, settled);
        vm.stopBroadcast();

        console.log("\nAll requests marked DONE - USDC transferred directly to request owners");
    }
}

// =============================================================
// View: Vault Status (read-only, no broadcast)
// =============================================================

contract VaultStatus is SignerHelper {
    function run() external view {
        address vaultAddr = vm.envAddress("VAULT_ADDRESS");
        address usdcAddr = vm.envAddress("USDC_ADDRESS");

        MantleYieldVault vault = MantleYieldVault(vaultAddr);
        MantleVaultGateway gateway = _resolveGateway(vault);
        IERC20 usdc = IERC20(usdcAddr);

        console.log("=== Vault Status ===");
        console.log("Vault:", vaultAddr);
        console.log("Asset (USDC):", usdcAddr);
        console.log("");

        console.log("--- Balances ---");
        console.log("USDC in vault:", usdc.balanceOf(vaultAddr));
        console.log("Total shares (totalSupply):", vault.totalSupply());
        console.log("totalAssets:", vault.totalAssets());
        console.log("FreeCash:", vault.getFreeCash());
        console.log("");

        console.log("--- Pricing ---");
        console.log("exchangeRate:", vault.exchangeRate());
        console.log("1000 shares -> USDC (net):", vault.previewRedeem(1000e6));
        console.log("");

        console.log("--- Liabilities ---");
        console.log("totalLockedShares:", vault.totalLockedShares());
        console.log("");

        console.log("--- In-Flight ---");
        console.log("totalInvestInFlight:", vault.totalInvestInFlight());
        console.log("totalRedeemInFlight:", vault.totalRedeemInFlight());
        console.log("");

        console.log("--- Config ---");
        console.log("Controller:", vault.controller());
        console.log("Accountant:", vault.accountant());
        console.log("Treasury:", vault.treasury());
        console.log("Gateway:", address(gateway));
        console.log("SanctionsOracle:", address(gateway.sanctionsOracle()));
        console.log("SanctionSafe:", gateway.sanctionSafe());
        console.log("syncRedeemDisabled:", gateway.syncRedeemDisabled());
        console.log("managementFeeRate:", gateway.managementFeeRate());
        console.log("redemptionFeeBps:", gateway.redemptionFeeBps());
        console.log("minRedeemAmount:", vault.minRedeemAmount());
        console.log("Paused:", vault.paused());
    }
}
