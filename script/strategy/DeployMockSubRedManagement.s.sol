// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockSubRedManagement} from "../../src/mocks/strategy/MockSubRedManagement.sol";
import {MockERC20Mintable} from "../../src/mocks/token/MockERC20Mintable.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @title DeployMockSubRedManagement
/// @notice Deploy a MockSubRedManagement instance for testnet integration.
///
/// Required env:
/// - PRIVATE_KEY (or F_PRIVATE_KEY)
///
/// Optional env:
/// - MOCK_SUBRED_OWNER  (default: deployer)
contract DeployMockSubRedManagement is Script {
    function run() external {
        address owner_ = vm.envAddress("F_ADMIN_ADDRESS");
        address stToken = vm.envAddress("F_ST_TOKEN");

        vm.startBroadcast();

        MockSubRedManagement mockSubRed = new MockSubRedManagement(owner_);

        // ═════════════════════════════════════════════════════════════
        //  Phase 0 (testnet only): Deploy mock token if address is zero
        // ═════════════════════════════════════════════════════════════
        if (stToken == address(0)) {
            MockERC20Mintable mockToken = new MockERC20Mintable("Mock-iSNR", "iSNR", 6);
            stToken = address(mockToken);
            console2.log("[Phase 0] Mock-iSNR deployed:", stToken);
        }

        vm.stopBroadcast();
        console2.log("MockSubRedManagement:", address(mockSubRed));
        console2.log("owner:", owner_);
    }
}
