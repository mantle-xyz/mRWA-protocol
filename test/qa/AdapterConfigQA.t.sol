// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SubRedManagementAdapter} from "../../src/adapters/digift/SubRedManagementAdapter.sol";
import {BaseAdapter} from "../../src/adapters/base/BaseAdapter.sol";
import {IStrategyAdapter} from "../../src/interfaces/adapters/IStrategyAdapter.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test, console2} from "forge-std/Test.sol";

// ---------------------------------------------------------------------------
// Minimal mocks for adapter tests
// ---------------------------------------------------------------------------

contract MockUSDC_ACQ is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockSTToken_ACQ is ERC20 {
    constructor() ERC20("Security Token", "ST") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @dev Minimal SubRedManagement mock (external protocol)
contract MockSubRedManagement_ACQ {
    function subscribe(address, address, uint256, uint64) external {}
    function redeem(address, address, uint256, uint64) external {}
}

/// @dev Minimal price oracle mock matching IDFeedPriceOracle interface.
contract MockPriceOracle_ACQ {
    uint256 public price = 1e18;
    function getPrice() external view returns (uint256) { return price; }
    function decimals() external pure returns (uint8) { return 18; }
    function setPrice(uint256 p) external { price = p; }
}

// ---------------------------------------------------------------------------
// QA Test: Adapter Configuration (setPriceOracle, deadline windows)
// ---------------------------------------------------------------------------

contract AdapterConfigQATest is Test {
    SubRedManagementAdapter internal adapter;
    MantleYieldVault internal vault;
    MockUSDC_ACQ internal usdc;
    MockSTToken_ACQ internal stToken;
    MockSubRedManagement_ACQ internal subRed;
    MockPriceOracle_ACQ internal priceOracle;

    address internal admin = makeAddr("admin");
    address internal adapterController = makeAddr("controller");
    address internal adapterAccountant = makeAddr("accountant");
    address internal nonAdmin = makeAddr("nonAdmin");

    string constant MODULE = unicode"Adapter 配置管理场景";
    string private _buf;

    function _logCase(string memory id, string memory name_) internal {
        _buf = "";
        _step(string.concat("testcase module: ", MODULE));
        _step(string.concat("testcase id: ", id));
        _step(string.concat("testcase name: ", name_));
        _step("----------------------------------------");
    }

    function _step(string memory msg_) internal {
        console2.log(msg_);
        _buf = string.concat(_buf, msg_, "\n");
    }

    function _logPass() internal {
        _step("----------------------------------------");
        _step("test result: passed");
    }

    function setUp() public {
        usdc = new MockUSDC_ACQ();
        stToken = new MockSTToken_ACQ();
        subRed = new MockSubRedManagement_ACQ();
        priceOracle = new MockPriceOracle_ACQ();

        // Deploy real vault (adapter constructor reads vault.asset())
        vault = MantleYieldVault(address(new ERC1967Proxy(
            address(new MantleYieldVault()),
            abi.encodeCall(MantleYieldVault.initialize, IMantleYieldVault.InitParams({
                asset: IERC20(address(usdc)),
                name: "mRWA Vault",
                symbol: "mRWA",
                admin: admin,
                gateway: address(1),
                controller: adapterController,
                accountant: address(1),
                treasury: admin,
                maxRedemptionFeeBps: 500,
                redemptionFeeBps: 100,
                minRedeemAmount: 0,
                minDepositAmount: 0
            }))
        )));

        adapter = new SubRedManagementAdapter(
            address(vault),
            address(subRed),
            address(stToken),
            admin,
            adapterController,
            adapterAccountant,
            address(priceOracle)
        );
    }

    // =======================================================================
    // 1. setPriceOracle: 更换价格预言机
    // =======================================================================

    function test_SetPriceOracle_Success() public {
        _logCase("test_SetPriceOracle_Success", unicode"admin 更换价格预言机地址");

        assertEq(adapter.priceOracle(), address(priceOracle), "initial oracle");

        MockPriceOracle_ACQ newOracle = new MockPriceOracle_ACQ();
        vm.prank(admin);
        adapter.setPriceOracle(address(newOracle));

        assertEq(adapter.priceOracle(), address(newOracle), "oracle updated");

        _logPass();
    }

    function test_SetPriceOracle_SetToZero_FallbackToManualPrice() public {
        _logCase(
            "test_SetPriceOracle_SetToZero_FallbackToManualPrice",
            unicode"setPriceOracle 清零后回退到手动价格，验证完整优先级链路"
        );

        _step("[Step 1] With oracle active, getPosTokenPrice uses oracle");
        // MockPriceOracle returns 1e18 with 18 decimals -> normalized = 1e18 * 1e18 / 1e18 = 1e18
        uint256 priceWithOracle = adapter.getPosTokenPrice();
        assertEq(priceWithOracle, 1e18, "oracle returns 1e18");
        _step(string.concat("  price (oracle active): ", vm.toString(priceWithOracle)));

        _step("[Step 2] setManualPosTokenPrice should revert when oracle is set");
        vm.prank(adapterAccountant);
        vm.expectRevert(BaseAdapter.Unsupported.selector);
        adapter.setManualPosTokenPrice(2e18);
        _step("  reverted: Unsupported() when oracle exists");

        _step("[Step 3] Admin clears oracle to address(0)");
        vm.prank(admin);
        adapter.setPriceOracle(address(0));
        assertEq(adapter.priceOracle(), address(0), "oracle cleared");

        _step("[Step 4] Without oracle and no manual price, default fallback = 1e18");
        uint256 defaultPrice = adapter.getPosTokenPrice();
        assertEq(defaultPrice, 1e18, "default fallback = 1e18");

        _step("[Step 5] Set manual price to 1.5e18 via accountant executor");
        vm.prank(adapterAccountant);
        adapter.setManualPosTokenPrice(1.5e18);
        uint256 manualPrice = adapter.getPosTokenPrice();
        assertEq(manualPrice, 1.5e18, "manual price = 1.5e18");
        _step(string.concat("  price (manual): ", vm.toString(manualPrice)));

        _step("[Step 6] Update manual price to 2e18");
        vm.prank(adapterAccountant);
        adapter.setManualPosTokenPrice(2e18);
        assertEq(adapter.getPosTokenPrice(), 2e18, "manual price updated to 2e18");

        _step("[Step 7] Re-set oracle -> oracle takes priority over manual price");
        MockPriceOracle_ACQ newOracle = new MockPriceOracle_ACQ();
        newOracle.setPrice(3e18); // 3e18 raw, 18 decimals -> normalized = 3e18
        vm.prank(admin);
        adapter.setPriceOracle(address(newOracle));
        uint256 oraclePrice = adapter.getPosTokenPrice();
        assertEq(oraclePrice, 3e18, "oracle takes priority over manual price");
        _step(string.concat("  price (oracle restored): ", vm.toString(oraclePrice)));

        _logPass();
    }

    function test_SetPriceOracle_OnlyAdmin() public {
        _logCase("test_SetPriceOracle_OnlyAdmin", unicode"非 admin 不能更换价格预言机");

        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(
            bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
            nonAdmin,
            bytes32(0)
        ));
        adapter.setPriceOracle(address(1));

        _logPass();
    }

    // =======================================================================
    // 2. setSubscribeDeadlineWindow: 申购截止窗口
    // =======================================================================

    function test_SetSubscribeDeadlineWindow_Success() public {
        _logCase("test_SetSubscribeDeadlineWindow_Success", unicode"admin 修改申购截止窗口");

        _step("[Step 1] Check default = 6 hours");
        assertEq(adapter.subscribeDeadlineWindow(), 6 hours, "default 6h");

        _step("[Step 2] Admin sets to 12 hours");
        vm.prank(admin);
        adapter.setSubscribeDeadlineWindow(12 hours);
        assertEq(adapter.subscribeDeadlineWindow(), 12 hours, "updated to 12h");

        _step("[Step 3] Admin sets to 0 (no deadline)");
        vm.prank(admin);
        adapter.setSubscribeDeadlineWindow(0);
        assertEq(adapter.subscribeDeadlineWindow(), 0, "updated to 0");

        _logPass();
    }

    function test_SetSubscribeDeadlineWindow_OnlyAdmin() public {
        _logCase("test_SetSubscribeDeadlineWindow_OnlyAdmin", unicode"非 admin 不能修改申购截止窗口");

        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(
            bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
            nonAdmin,
            bytes32(0)
        ));
        adapter.setSubscribeDeadlineWindow(1 hours);

        _logPass();
    }

    // =======================================================================
    // 3. setRedeemDeadlineWindow: 赎回截止窗口
    // =======================================================================

    function test_SetRedeemDeadlineWindow_Success() public {
        _logCase("test_SetRedeemDeadlineWindow_Success", unicode"admin 修改赎回截止窗口");

        assertEq(adapter.redeemDeadlineWindow(), 6 hours, "default 6h");

        vm.prank(admin);
        adapter.setRedeemDeadlineWindow(24 hours);
        assertEq(adapter.redeemDeadlineWindow(), 24 hours, "updated to 24h");

        _logPass();
    }

    function test_SetRedeemDeadlineWindow_OnlyAdmin() public {
        _logCase("test_SetRedeemDeadlineWindow_OnlyAdmin", unicode"非 admin 不能修改赎回截止窗口");

        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(
            bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
            nonAdmin,
            bytes32(0)
        ));
        adapter.setRedeemDeadlineWindow(1 hours);

        _logPass();
    }
}
