import {MockERC20Mintable} from "../src/mocks/token/MockERC20Mintable.sol";
import {Script, console2} from "forge-std/Script.sol";

contract DeployMockToken is Script {
    function run() external {
        vm.startBroadcast();
        MockERC20Mintable mockToken = new MockERC20Mintable("Mock Token", "MTK", 18);
        console2.log("MockERC20Mintable deployed at", address(mockToken));
        vm.stopBroadcast();
    }
}
