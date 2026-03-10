// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SubRedManagementAdapter} from "../../src/adapters/digift/SubRedManagementAdapter.sol";
import {MockSync4626Adapter} from "../../src/adapters/mock/MockSync4626Adapter.sol";
import {MockERC4626Vault} from "../../src/mocks/strategy/MockERC4626Vault.sol";
import {MockSubRedManagement} from "../../src/mocks/strategy/MockSubRedManagement.sol";
import {MockERC20Mintable} from "../../src/mocks/token/MockERC20Mintable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @notice Deploy a full mock strategy stack for testnet integration:
///         - mock asset token (optional)
///         - mock ERC4626 strategy + sync adapter
///         - mock SubRed + async adapter
///
/// Required env:
/// - DEPLOYER_PRIVATE_KEY (or PRIVATE_KEY)
/// - MOCK_VAULT
/// - MOCK_ADMIN
/// - MOCK_CONTROLLER
///
/// Optional env:
/// - MOCK_ASSET (if empty, deploy MockERC20Mintable with 6 decimals)
/// - MOCK_ASSET_NAME (default "Mock USD")
/// - MOCK_ASSET_SYMBOL (default "mUSD")
/// - MOCK_4626_NAME (default "Mock 4626 Position")
/// - MOCK_4626_SYMBOL (default "m4626")
/// - MOCK_ST_NAME (default "Mock ST")
/// - MOCK_ST_SYMBOL (default "mST")
contract DeployMockStrategies is Script {
    function run() external {
        uint256 deployerPk = vm.envOr("DEPLOYER_PRIVATE_KEY", vm.envUint("PRIVATE_KEY"));
        address vault_ = vm.envAddress("MOCK_VAULT");
        address admin = vm.envAddress("MOCK_ADMIN");
        address controller = vm.envAddress("MOCK_CONTROLLER");

        vm.startBroadcast(deployerPk);

        address asset = vm.envOr("MOCK_ASSET", address(0));
        if (asset == address(0)) {
            string memory assetName = vm.envOr("MOCK_ASSET_NAME", string("Mock USD"));
            string memory assetSymbol = vm.envOr("MOCK_ASSET_SYMBOL", string("mUSD"));
            MockERC20Mintable deployedAsset = new MockERC20Mintable(assetName, assetSymbol, 6);
            asset = address(deployedAsset);
        }

        MockERC4626Vault mock4626 = new MockERC4626Vault(
            IERC20(asset),
            vm.envOr("MOCK_4626_NAME", string("Mock 4626 Position")),
            vm.envOr("MOCK_4626_SYMBOL", string("m4626"))
        );
        MockSync4626Adapter syncAdapter = new MockSync4626Adapter(vault_, address(mock4626), admin, controller);

        MockERC20Mintable mockStToken = new MockERC20Mintable(
            vm.envOr("MOCK_ST_NAME", string("Mock ST")), vm.envOr("MOCK_ST_SYMBOL", string("mST")), 18
        );
        MockSubRedManagement mockSubRed = new MockSubRedManagement(admin);
        SubRedManagementAdapter asyncAdapter = new SubRedManagementAdapter(
            vault_, address(mockSubRed), address(mockStToken), admin, controller, address(0)
        );

        vm.stopBroadcast();

        console2.log("mock asset:", asset);
        console2.log("mock4626 vault:", address(mock4626));
        console2.log("sync4626 adapter:", address(syncAdapter));
        console2.log("mock st token:", address(mockStToken));
        console2.log("mock subred:", address(mockSubRed));
        console2.log("async subred adapter:", address(asyncAdapter));
    }
}
