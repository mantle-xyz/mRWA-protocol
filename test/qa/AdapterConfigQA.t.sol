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
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
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
    function decimals() public pure override returns (uint8) { return 18; }
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

    function _floorToStepExpected(uint256 amount, uint256 step) internal pure returns (uint256) {
        if (step == 0) {
            return amount;
        }
        return amount - (amount % step);
    }

    function _estimatePosExpected(uint256 assetAmount, uint256 priceE18) internal view returns (uint256) {
        uint8 assetDecimals = usdc.decimals();
        uint8 stDecimals = stToken.decimals();
        if (assetAmount == 0) {
            return 0;
        }
        if (stDecimals >= assetDecimals) {
            return Math.mulDiv(assetAmount, 1e18 * (10 ** (stDecimals - assetDecimals)), priceE18, Math.Rounding.Floor);
        }
        return Math.mulDiv(assetAmount, 1e18, priceE18 * (10 ** (assetDecimals - stDecimals)), Math.Rounding.Floor);
    }

    function _estimateAssetExpected(uint256 posAmount, uint256 priceE18, Math.Rounding rounding)
        internal
        view
        returns (uint256)
    {
        uint8 assetDecimals = usdc.decimals();
        uint8 stDecimals = stToken.decimals();
        if (posAmount == 0) {
            return 0;
        }
        if (assetDecimals >= stDecimals) {
            return Math.mulDiv(posAmount, priceE18 * (10 ** (assetDecimals - stDecimals)), 1e18, rounding);
        }
        return Math.mulDiv(posAmount, priceE18, 1e18 * (10 ** (stDecimals - assetDecimals)), rounding);
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
                minDepositAmount: 0,
                maxSettlementDeviationBps: 0,
                depositDailyRemaining: type(uint256).max,
                redeemDailyRemaining: type(uint256).max
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
            unicode"setPriceOracle 可设为零地址（回退到手动价格）"
        );

        _step("[Step 1] With oracle active, getPosTokenPrice uses oracle");
        // MockPriceOracle returns 1e18 with 18 decimals -> normalized = 1e18 * 1e18 / 1e18 = 1e18
        uint256 priceWithOracle = adapter.getPosTokenPrice();
        assertEq(priceWithOracle, 1e18, "oracle returns 1e18");
        _step(string.concat("  price (oracle active): ", vm.toString(priceWithOracle)));

        _step("[Step 2] setManualPosTokenPrice should revert when oracle is set");
        vm.prank(adapterAccountant);
        vm.expectRevert(BaseAdapter.Adapter__Unsupported.selector);
        adapter.setManualPosTokenPrice(2e18);
        _step("  reverted: Unsupported() when oracle exists");

        _step("[Step 3] Admin clears oracle to address(0)");
        vm.prank(admin);
        adapter.setPriceOracle(address(0));
        assertEq(adapter.priceOracle(), address(0), "oracle cleared");

        _step("[Step 4] Without oracle and no manual price, default fallback = 0");
        uint256 defaultPrice = adapter.getPosTokenPrice();
        assertEq(defaultPrice, 0, "default fallback = 0 (no oracle, no manual price)");

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

    // =======================================================================
    // N-27. setExecutionConstraints: admin 设置步进值与最小值
    // =======================================================================

    function test_SetExecutionSteps_Success() public {
        _logCase(
            "test_SetExecutionSteps_Success",
            unicode"admin 通过 setExecutionConstraints(minSubscribeAsset_, subscribeStepAsset_, minRedeemPos_, redeemStepPos_) 设置步进值和最小金额"
        );

        _step("[Step 1] Admin calls setExecutionConstraints(0, 100e6, 0, 50e18)");
        vm.prank(admin);
        vm.expectEmit(false, false, false, true, address(adapter));
        emit SubRedManagementAdapter.ExecutionConstraintsUpdated(0, 100e6, 0, 50e18);
        adapter.setExecutionConstraints(0, 100e6, 0, 50e18);

        _step("[Step 2] Verify stored values");
        (uint256 minSub, uint256 subStep, uint256 minRedeem, uint256 redeemStep) = adapter.executionConstraints();
        assertEq(subStep, 100e6, "subscribeStepAsset = 100e6");
        _step(string.concat("  subscribeStepAsset = ", vm.toString(subStep)));
        assertEq(redeemStep, 50e18, "redeemStepPos = 50e18");
        _step(string.concat("  redeemStepPos = ", vm.toString(redeemStep)));

        _logPass();
    }

    // =======================================================================
    // N-28. setExecutionConstraints: 非 admin 被拒绝
    // =======================================================================

    function test_SetExecutionSteps_OnlyAdmin() public {
        _logCase(
            "test_SetExecutionSteps_OnlyAdmin",
            unicode"非 admin 调用 setExecutionConstraints 被拒绝"
        );

        _step("[Step 1] Non-admin calls setExecutionConstraints");
        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(
            bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
            nonAdmin,
            bytes32(0) // DEFAULT_ADMIN_ROLE
        ));
        adapter.setExecutionConstraints(0, 100e6, 0, 50e18);
        _step("  PASS: reverted with AccessControlUnauthorizedAccount");

        _logPass();
    }

    // =======================================================================
    // N-29. _floorToStep 向下对齐（通过 previewDeposit 间接验证）
    // =======================================================================

    function test_FloorToStep_Alignment() public {
        _logCase(
            "test_FloorToStep_Alignment",
            unicode"_floorToStep(amount, step) 返回 amount - (amount % step)；step=0 时返回原值"
        );

        uint256 subscribeStep = 100e6;

        _step("[Step 1] Set subscribeStepAsset=100e6 for previewDeposit-based verification");
        vm.prank(admin);
        adapter.setExecutionConstraints(0, subscribeStep, 0, 0);

        _step("[Step 2] _floorToStep(250e6, 100e6) -> 200e6 (via previewDeposit)");
        (bool ok1, uint256 exec1,) = adapter.previewDeposit(250e6);
        uint256 expectedExec1 = _floorToStepExpected(250e6, subscribeStep);
        assertTrue(ok1, "250e6 aligned to 200e6, ok=true");
        assertEq(exec1, expectedExec1, "executableAssetAmount should follow floor-to-step formula");
        _step(string.concat("  executableAssetAmount = ", vm.toString(exec1)));

        _step("[Step 3] _floorToStep(100e6, 100e6) -> 100e6 (exact multiple)");
        (bool ok2, uint256 exec2,) = adapter.previewDeposit(100e6);
        uint256 expectedExec2 = _floorToStepExpected(100e6, subscribeStep);
        assertTrue(ok2, "100e6 is exact multiple, ok=true");
        assertEq(exec2, expectedExec2, "exact multiple should stay unchanged");

        _step("[Step 4] _floorToStep(99e6, 100e6) -> 0 (below step)");
        (bool ok3, uint256 exec3,) = adapter.previewDeposit(99e6);
        uint256 expectedExec3 = _floorToStepExpected(99e6, subscribeStep);
        assertFalse(ok3, "99e6 < step, aligned to 0, ok=false");
        assertEq(exec3, expectedExec3, "below-step amount should floor to zero");

        _step("[Step 5] step=0 -> passthrough (set subscribeStepAsset=0)");
        vm.prank(admin);
        adapter.setExecutionConstraints(0, 0, 0, 0);
        (bool ok4, uint256 exec4,) = adapter.previewDeposit(250e6);
        uint256 expectedExec4 = _floorToStepExpected(250e6, 0);
        assertTrue(ok4, "step=0 passthrough, ok=true");
        assertEq(exec4, expectedExec4, "step=0 should passthrough");

        _logPass();
    }

    // =======================================================================
    // N-30. previewDeposit 按 subscribeStepAsset 对齐
    // =======================================================================

    function test_PreviewDeposit_StepAlignment() public {
        _logCase(
            "test_PreviewDeposit_StepAlignment",
            unicode"previewDeposit(amountAsset) 将 amountAsset 按 subscribeStepAsset 向下取整，并计算对应的 expectedPosAmount"
        );

        uint256 subscribeStep = 100e6;
        uint256 priceE18 = 2e18;

        _step("[Step 1] Set subscribeStepAsset=100e6, posTokenPrice=2e18");
        vm.prank(admin);
        adapter.setExecutionConstraints(0, subscribeStep, 0, 0);
        // priceOracle already returns 1e18, set to 2e18
        priceOracle.setPrice(priceE18);
        assertEq(adapter.getPosTokenPrice(), priceE18, "price = 2e18");

        // With price=2e18, USDC(6dec), ST(18dec):
        // _estimatePosAmountInternal(asset):
        //   stDecimals(18) >= assetDecimals(6) -> mulDiv(asset, 1e18 * 1e12, 2e18, Floor) = asset * 1e12 / 2

        _step("[Step 2] previewDeposit(250e6) -> aligned to 200e6");
        (bool ok1, uint256 exec1, uint256 pos1) = adapter.previewDeposit(250e6);
        uint256 expectedExec1 = _floorToStepExpected(250e6, subscribeStep);
        uint256 expectedPos1 = _estimatePosExpected(expectedExec1, priceE18);
        assertTrue(ok1, "250e6 -> 200e6, ok=true");
        assertEq(exec1, expectedExec1, "executableAssetAmount should follow floor-to-step formula");
        assertEq(pos1, expectedPos1, "expectedPosAmount computed from formula");
        _step(string.concat("  executableAsset=", vm.toString(exec1), " expectedPos=", vm.toString(pos1)));

        _step("[Step 3] previewDeposit(99e6) -> below step, ok=false");
        (bool ok2, uint256 exec2, uint256 pos2) = adapter.previewDeposit(99e6);
        uint256 expectedExec2 = _floorToStepExpected(99e6, subscribeStep);
        uint256 expectedPos2 = _estimatePosExpected(expectedExec2, priceE18);
        assertFalse(ok2, "99e6 < 100e6 step, ok=false");
        assertEq(exec2, expectedExec2, "below-step amount should floor to zero");
        assertEq(pos2, expectedPos2, "zero executable amount should map to zero pos");

        _step("[Step 4] previewDeposit(100e6) -> exact step multiple");
        (bool ok3, uint256 exec3, uint256 pos3) = adapter.previewDeposit(100e6);
        uint256 expectedExec3 = _floorToStepExpected(100e6, subscribeStep);
        uint256 expectedPos3 = _estimatePosExpected(expectedExec3, priceE18);
        assertTrue(ok3, "100e6 exact multiple, ok=true");
        assertEq(exec3, expectedExec3, "exact multiple should stay unchanged");
        assertEq(pos3, expectedPos3, "expectedPosAmount computed from formula");
        _step(string.concat("  executableAsset=", vm.toString(exec3), " expectedPos=", vm.toString(pos3)));

        _logPass();
    }

    // =======================================================================
    // N-31. previewRedeem 按 redeemStepPos 对齐 + Ceil 反算
    // =======================================================================

    function test_PreviewRedeem_StepAlignment() public {
        _logCase(
            "test_PreviewRedeem_StepAlignment",
            unicode"previewRedeem(amountAsset) 先将 amountAsset 转为 posAmount，再按 redeemStepPos 向下取整，若取整后与原值不同则反向计算 executableAssetAmount (Ceil rounding)"
        );

        uint256 redeemStep = 50e18;
        uint256 priceE18 = 2e18;

        _step("[Step 1] Set redeemStepPos=50e18, posTokenPrice=2e18 (1 pos = 2 USDC)");
        vm.prank(admin);
        adapter.setExecutionConstraints(0, 0, 0, redeemStep);
        priceOracle.setPrice(priceE18);

        // With price=2e18, USDC(6dec), ST(18dec):
        // _estimatePosAmountInternal(amountAsset):
        //   mulDiv(amountAsset, 1e18 * 1e12, 2e18, Floor) = amountAsset * 1e12 / 2
        // _estimateAssetAmount(posAmount, Ceil):
        //   assetDec(6) < stDec(18) -> mulDiv(posAmount, 2e18, 1e18 * 1e12, Ceil) = posAmount * 2 / 1e12 (Ceil)

        _step("[Step 2] previewRedeem(150e6) -> posAmount=75e18, aligned to 50e18, reverse Ceil");
        (bool ok1, uint256 exec1, uint256 pos1) = adapter.previewRedeem(150e6);
        uint256 originalPos1 = _estimatePosExpected(150e6, priceE18);
        uint256 expectedPos1 = _floorToStepExpected(originalPos1, redeemStep);
        uint256 expectedExec1 = _estimateAssetExpected(expectedPos1, priceE18, Math.Rounding.Ceil);
        assertTrue(ok1, "ok=true");
        assertEq(pos1, expectedPos1, "expectedPosAmount should follow floor-to-step formula");
        assertEq(exec1, expectedExec1, "executableAssetAmount should follow reverse Ceil formula");
        _step(string.concat("  executableAsset=", vm.toString(exec1), " expectedPos=", vm.toString(pos1)));

        _step("[Step 3] previewRedeem(100e6) -> posAmount=50e18, exact step, no Ceil needed");
        (bool ok2, uint256 exec2, uint256 pos2) = adapter.previewRedeem(100e6);
        uint256 originalPos2 = _estimatePosExpected(100e6, priceE18);
        uint256 expectedPos2 = _floorToStepExpected(originalPos2, redeemStep);
        assertTrue(ok2, "ok=true");
        assertEq(pos2, expectedPos2, "expectedPosAmount should stay unchanged on exact step");
        assertEq(exec2, 100e6, "exact-step path should keep original asset amount");
        _step(string.concat("  executableAsset=", vm.toString(exec2), " expectedPos=", vm.toString(pos2)));

        _logPass();
    }

    // =======================================================================
    // N-32. deposit 拒绝未对齐金额
    // =======================================================================

    function test_Deposit_RevertUnalignedAmount() public {
        _logCase(
            "test_Deposit_RevertUnalignedAmount",
            unicode"deposit(amountAsset) 内部调用 _previewDeposit，如果 amountAsset != executableAssetAmount（说明未对齐）则 revert InvalidAmount"
        );

        uint256 subscribeStep = 100e6;

        _step("[Step 1] Set subscribeStepAsset=100e6");
        vm.prank(admin);
        adapter.setExecutionConstraints(0, subscribeStep, 0, 0);
        _step("[Step 2] Verify previewDeposit(250e6) returns executableAsset=200e6 != 250e6");
        (bool ok, uint256 exec,) = adapter.previewDeposit(250e6);
        uint256 expectedExec = _floorToStepExpected(250e6, subscribeStep);
        assertTrue(ok, "preview ok=true (200e6 > 0)");
        assertEq(exec, expectedExec, "executableAssetAmount should follow floor-to-step formula");
        _step(string.concat("  previewDeposit(250e6) -> executableAsset=", vm.toString(exec)));

        _step("[Step 3] Controller calls deposit(250e6) directly, expect InvalidAmount revert");
        vm.prank(adapterController);
        vm.expectRevert(BaseAdapter.Adapter__InvalidAmount.selector);
        adapter.deposit(250e6, adapterController);
        _step("  PASS: reverted with InvalidAmount (250e6 != 200e6)");

        _logPass();
    }

    // =======================================================================
    // A1. setMinAmounts: admin 设置最小充值/赎回金额
    // =======================================================================

    function test_SetMinAmounts_Success() public {
        _logCase(
            "test_SetMinAmounts_Success",
            unicode"admin 通过 setExecutionConstraints(minSubscribeAsset_, subscribeStepAsset_, minRedeemPos_, redeemStepPos_) 设置最小充值/赎回金额，验证存储和事件"
        );

        _step("[Step 1] Admin calls setExecutionConstraints(500e6, 0, 100e18, 0)");
        vm.prank(admin);
        vm.expectEmit(false, false, false, true, address(adapter));
        emit SubRedManagementAdapter.ExecutionConstraintsUpdated(500e6, 0, 100e18, 0);
        adapter.setExecutionConstraints(500e6, 0, 100e18, 0);

        _step("[Step 2] Verify stored values");
        (uint256 minSub, uint256 subStep, uint256 minRedeem, uint256 redeemStep) = adapter.executionConstraints();
        assertEq(minSub, 500e6, "minSubscribeAsset = 500e6");
        _step(string.concat("  minSubscribeAsset = ", vm.toString(minSub)));
        assertEq(minRedeem, 100e18, "minRedeemPos = 100e18");
        _step(string.concat("  minRedeemPos = ", vm.toString(minRedeem)));

        _logPass();
    }

    // =======================================================================
    // A2. setMinAmounts: 非 admin 被拒绝
    // =======================================================================

    function test_SetMinAmounts_OnlyAdmin() public {
        _logCase(
            "test_SetMinAmounts_OnlyAdmin",
            unicode"非 admin 调用 setExecutionConstraints 被拒绝"
        );

        _step("[Step 1] Non-admin calls setExecutionConstraints");
        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(
            bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
            nonAdmin,
            bytes32(0) // DEFAULT_ADMIN_ROLE
        ));
        adapter.setExecutionConstraints(500e6, 0, 100e18, 0);
        _step("  PASS: reverted with AccessControlUnauthorizedAccount");

        _logPass();
    }

    // =======================================================================
    // A3. previewDeposit: 低于 minSubscribeAsset 返回 (false, 0, 0)
    // =======================================================================

    function test_PreviewDeposit_BelowMinSubscribeAsset() public {
        _logCase(
            "test_PreviewDeposit_BelowMinSubscribeAsset",
            unicode"previewDeposit 在 executableAssetAmount < minSubscribeAsset 时返回 (false, 0, 0)"
        );

        _step("[Step 1] Set minSubscribeAsset=500e6 (500 USDC)");
        vm.prank(admin);
        adapter.setExecutionConstraints(500e6, 0, 0, 0);

        _step("[Step 2] previewDeposit(400e6) -> below min -> (false, 0, 0)");
        (bool ok1, uint256 exec1, uint256 pos1) = adapter.previewDeposit(400e6);
        assertFalse(ok1, "400e6 < 500e6 min, ok=false");
        assertEq(exec1, 0, "executableAssetAmount = 0");
        assertEq(pos1, 0, "expectedPosAmount = 0");
        _step("  previewDeposit(400e6) = (false, 0, 0)");

        _step("[Step 3] previewDeposit(500e6) -> exactly at min -> ok");
        (bool ok2, uint256 exec2, uint256 pos2) = adapter.previewDeposit(500e6);
        uint256 expectedPos2 = _estimatePosExpected(500e6, priceOracle.price());
        assertTrue(ok2, "500e6 == 500e6 min, ok=true");
        assertEq(exec2, 500e6, "executableAssetAmount = 500e6");
        assertEq(pos2, expectedPos2, "expectedPosAmount matches formula");
        _step(string.concat("  previewDeposit(500e6) = (true, 500e6, ", vm.toString(pos2), ")"));

        _step("[Step 4] previewDeposit(600e6) -> above min -> ok");
        (bool ok3, uint256 exec3, uint256 pos3) = adapter.previewDeposit(600e6);
        uint256 expectedPos3 = _estimatePosExpected(600e6, priceOracle.price());
        assertTrue(ok3, "600e6 > 500e6 min, ok=true");
        assertEq(exec3, 600e6, "executableAssetAmount = 600e6");
        assertEq(pos3, expectedPos3, "expectedPosAmount matches formula");
        _step(string.concat("  previewDeposit(600e6) = (true, 600e6, ", vm.toString(pos3), ")"));

        _logPass();
    }

    // =======================================================================
    // A4. previewRedeem: 低于 minRedeemPos 返回 (false, 0, 0)
    // =======================================================================

    function test_PreviewRedeem_BelowMinRedeemPos() public {
        _logCase(
            "test_PreviewRedeem_BelowMinRedeemPos",
            unicode"previewRedeem 在 expectedPosAmount < minRedeemPos 时返回 (false, 0, 0)"
        );

        _step("[Step 1] Set minRedeemPos=100e18, price=1e18 (1 pos = 1 USDC scaled by decimals)");
        vm.prank(admin);
        adapter.setExecutionConstraints(0, 0, 100e18, 0);
        // priceOracle already at 1e18 -> 1 USDC(6dec) => 1e12 pos (18dec)
        // Actually: _estimatePosAmountInternal(amountAsset):
        //   stDecimals(18) >= assetDecimals(6) -> mulDiv(amountAsset, 1e18 * 1e12, 1e18, Floor) = amountAsset * 1e12
        // So 50e6 USDC -> 50e6 * 1e12 = 50e18 pos
        //    200e6 USDC -> 200e6 * 1e12 = 200e18 pos
        assertEq(priceOracle.price(), 1e18, "price = 1e18");

        _step("[Step 2] previewRedeem(50e6) -> pos=50e18 < 100e18 min -> (false, 0, 0)");
        (bool ok1, uint256 exec1, uint256 pos1) = adapter.previewRedeem(50e6);
        assertFalse(ok1, "50e18 pos < 100e18 min, ok=false");
        assertEq(exec1, 0, "executableAssetAmount = 0");
        assertEq(pos1, 0, "expectedPosAmount = 0");
        _step("  previewRedeem(50e6) = (false, 0, 0)");

        _step("[Step 3] previewRedeem(100e6) -> pos=100e18 == 100e18 min -> ok");
        (bool ok2, uint256 exec2, uint256 pos2) = adapter.previewRedeem(100e6);
        assertTrue(ok2, "100e18 pos == 100e18 min, ok=true");
        assertEq(pos2, 100e18, "expectedPosAmount = 100e18");
        assertEq(exec2, 100e6, "executableAssetAmount = 100e6 (exact step, no ceil needed)");
        _step(string.concat("  previewRedeem(100e6) = (true, ", vm.toString(exec2), ", ", vm.toString(pos2), ")"));

        _step("[Step 4] previewRedeem(200e6) -> pos=200e18 >= 100e18 min -> ok");
        (bool ok3, uint256 exec3, uint256 pos3) = adapter.previewRedeem(200e6);
        assertTrue(ok3, "200e18 pos > 100e18 min, ok=true");
        assertEq(pos3, 200e18, "expectedPosAmount = 200e18");
        assertEq(exec3, 200e6, "executableAssetAmount = 200e6");
        _step(string.concat("  previewRedeem(200e6) = (true, ", vm.toString(exec3), ", ", vm.toString(pos3), ")"));

        _logPass();
    }

    // =======================================================================
    // A5. previewDeposit: step 对齐 + minSubscribeAsset 复合效应
    // =======================================================================

    function test_PreviewDeposit_StepPlusMinCompound() public {
        _logCase(
            "test_PreviewDeposit_StepPlusMinCompound",
            unicode"step 向下对齐后的金额若低于 minSubscribeAsset，previewDeposit 返回 (false, 0, 0)"
        );

        _step("[Step 1] Set subscribeStepAsset=100e6, minSubscribeAsset=500e6");
        vm.prank(admin);
        adapter.setExecutionConstraints(500e6, 100e6, 0, 0);

        _step("[Step 2] previewDeposit(550e6) -> floor to 500e6, 500e6 >= 500e6 min -> ok");
        (bool ok1, uint256 exec1, uint256 pos1) = adapter.previewDeposit(550e6);
        uint256 expectedExec1 = _floorToStepExpected(550e6, 100e6); // 500e6
        uint256 expectedPos1 = _estimatePosExpected(expectedExec1, priceOracle.price());
        assertTrue(ok1, "floor(550,100)=500 >= 500 min, ok=true");
        assertEq(exec1, expectedExec1, "executableAssetAmount = 500e6");
        assertEq(pos1, expectedPos1, "expectedPosAmount matches formula");
        _step(string.concat("  previewDeposit(550e6) = (true, ", vm.toString(exec1), ", ", vm.toString(pos1), ")"));

        _step("[Step 3] previewDeposit(499e6) -> floor to 400e6, 400e6 < 500e6 min -> (false, 0, 0)");
        (bool ok2, uint256 exec2, uint256 pos2) = adapter.previewDeposit(499e6);
        assertFalse(ok2, "floor(499,100)=400 < 500 min, ok=false");
        assertEq(exec2, 0, "executableAssetAmount = 0");
        assertEq(pos2, 0, "expectedPosAmount = 0");
        _step("  previewDeposit(499e6) = (false, 0, 0)");

        _step("[Step 4] previewDeposit(600e6) -> floor to 600e6 (exact), 600e6 >= 500e6 min -> ok");
        (bool ok3, uint256 exec3, uint256 pos3) = adapter.previewDeposit(600e6);
        uint256 expectedExec3 = _floorToStepExpected(600e6, 100e6); // 600e6
        uint256 expectedPos3 = _estimatePosExpected(expectedExec3, priceOracle.price());
        assertTrue(ok3, "floor(600,100)=600 >= 500 min, ok=true");
        assertEq(exec3, expectedExec3, "executableAssetAmount = 600e6");
        assertEq(pos3, expectedPos3, "expectedPosAmount matches formula");
        _step(string.concat("  previewDeposit(600e6) = (true, ", vm.toString(exec3), ", ", vm.toString(pos3), ")"));

        _logPass();
    }

    // =======================================================================
    // A6. setMinAmounts(0,0) 关闭最小值检查
    // =======================================================================

    function test_SetMinAmounts_ZeroDisablesCheck() public {
        _logCase(
            "test_SetMinAmounts_ZeroDisablesCheck",
            unicode"setExecutionConstraints(0, 0, 0, 0) 将最小值重置为 0，恢复无门槛状态"
        );

        _step("[Step 1] Set minSubscribeAsset=500e6 -> previewDeposit(100e6) = false");
        vm.prank(admin);
        adapter.setExecutionConstraints(500e6, 0, 100e18, 0);
        (bool ok1,,) = adapter.previewDeposit(100e6);
        assertFalse(ok1, "100e6 < 500e6 min, ok=false");
        _step("  previewDeposit(100e6) = false (min active)");

        _step("[Step 2] Set minSubscribeAsset=0, minRedeemPos=0 -> disable checks");
        vm.prank(admin);
        vm.expectEmit(false, false, false, true, address(adapter));
        emit SubRedManagementAdapter.ExecutionConstraintsUpdated(0, 0, 0, 0);
        adapter.setExecutionConstraints(0, 0, 0, 0);
        (uint256 minSub,,uint256 minRedeem,) = adapter.executionConstraints();
        assertEq(minSub, 0, "minSubscribeAsset = 0");
        assertEq(minRedeem, 0, "minRedeemPos = 0");

        _step("[Step 3] previewDeposit(100e6) = true (no constraint)");
        (bool ok2, uint256 exec2, uint256 pos2) = adapter.previewDeposit(100e6);
        uint256 expectedPos2 = _estimatePosExpected(100e6, priceOracle.price());
        assertTrue(ok2, "min=0, 100e6 ok=true");
        assertEq(exec2, 100e6, "executableAssetAmount = 100e6");
        assertEq(pos2, expectedPos2, "expectedPosAmount matches formula");
        _step(string.concat("  previewDeposit(100e6) = (true, ", vm.toString(exec2), ", ", vm.toString(pos2), ")"));

        _step("[Step 4] previewRedeem(10e6) = true (no constraint, pos=10e18 >= 0)");
        (bool ok3, uint256 exec3, uint256 pos3) = adapter.previewRedeem(10e6);
        assertTrue(ok3, "min=0, 10e6 ok=true");
        assertGt(pos3, 0, "expectedPosAmount > 0");
        assertGt(exec3, 0, "executableAssetAmount > 0");
        _step(string.concat("  previewRedeem(10e6) = (true, ", vm.toString(exec3), ", ", vm.toString(pos3), ")"));

        _logPass();
    }
}
