// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SanctionsOracle} from "../../src/compliance/SanctionsOracle.sol";
import {SanctionsOracleFactory} from "../../src/compliance/SanctionsOracleFactory.sol";

import {Script, console} from "forge-std/Script.sol";

/**
 * @title  DeploySanctionsOracle
 * @notice Foundry deployment script for the SanctionsOracle via Factory (Beacon Proxy).
 *
 *         Deployment topology
 *         ───────────────────
 *         1. SanctionsOracle (implementation) — logic only, locked via `_disableInitializers()`.
 *         2. SanctionsOracleFactory           — creates the UpgradeableBeacon internally and
 *                                               deploys oracle proxies via `deployAndInitOracle()`.
 *         3. BeaconProxy (oracle)             — user-facing entry point; initialized with `admin` & `complianceBot`.
 *
 *         Environment variables (required)
 *         ────────────────────────────────
 *         • ADMIN_ADDRESS          — Receives DEFAULT_ADMIN_ROLE on the proxy (typically a multisig).
 *         • COMPLIANCE_BOT_ADDRESS — Receives COMPLIANCE_ROLE on the proxy (off-chain Sanctions Service wallet).
 *         • BEACON_OWNER_ADDRESS   — Owns the UpgradeableBeacon (typically a Timelock / multisig).
 *
 *         Usage
 *         ─────
 *         ```bash
 *         # Dry-run (simulate):
 *         forge script script/DeploySanctionsOracle.s.sol --rpc-url $RPC_URL -vvvv
 *
 *         # Broadcast (deploy):
 *         forge script script/DeploySanctionsOracle.s.sol --rpc-url $RPC_URL --broadcast --verify -vvvv
 *         ```
 */
contract DeploySanctionsOracle is Script {
    function run()
        external
        returns (SanctionsOracle implementation, SanctionsOracleFactory factory, SanctionsOracle oracle)
    {
        address admin = vm.envAddress("ADMIN_ADDRESS");
        address complianceBot = vm.envAddress("COMPLIANCE_BOT_ADDRESS");
        address beaconOwner = vm.envAddress("BEACON_OWNER_ADDRESS");

        console.log("=== SanctionsOracle Factory Deployment ===");
        console.log("Admin:          ", admin);
        console.log("Compliance Bot: ", complianceBot);
        console.log("Beacon Owner:   ", beaconOwner);

        vm.startBroadcast();

        // 1. Deploy implementation (locked)
        implementation = new SanctionsOracle();
        console.log("[1/3] Implementation: ", address(implementation));

        // 2. Deploy factory (creates UpgradeableBeacon internally)
        factory = new SanctionsOracleFactory(address(implementation), beaconOwner);
        console.log("[2/3] Factory:        ", address(factory));
        console.log("       Beacon:        ", address(factory.BEACON()));

        // 3. Deploy first oracle proxy via factory
        address oracleAddr = factory.deployAndInitOracle(admin, complianceBot);
        oracle = SanctionsOracle(oracleAddr);
        console.log("[3/3] Oracle (proxy): ", oracleAddr);

        vm.stopBroadcast();

        // Post-deploy verification
        console.log("");
        console.log("=== Post-deploy Verification ===");
        console.log("Beacon -> Impl:      ", factory.implementation());
        console.log("Oracle count:        ", factory.oracleCount());
        console.log("Has ADMIN_ROLE:      ", oracle.hasRole(oracle.DEFAULT_ADMIN_ROLE(), admin));
        console.log("Has COMPLIANCE:      ", oracle.hasRole(oracle.COMPLIANCE_ROLE(), complianceBot));
        console.log("lastUpdateTimestamp: ", oracle.lastUpdateTimestamp());
    }
}
