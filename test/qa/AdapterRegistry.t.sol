// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {IMantleVaultGateway} from "../../src/interfaces/vault/IMantleVaultGateway.sol";
import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {IAccountant} from "../../src/interfaces/accountant/IAccountant.sol";
import {IStrategyAdapter} from "../../src/interfaces/adapters/IStrategyAdapter.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {MantleVaultGateway} from "../../src/vault/MantleVaultGateway.sol";
import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {OperatorExecutor} from "../../src/protocol/OperatorExecutor.sol";
import {Accountant} from "../../src/accountant/Accountant.sol";
import {VaultFactory} from "../../src/vault/VaultFactory.sol";
import {GatewayFactory} from "../../src/vault/GatewayFactory.sol";
import {AccountantFactory} from "../../src/accountant/AccountantFactory.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test, console2} from "forge-std/Test.sol";

// ---------------------------------------------------------------------------
// Mock contracts
// ---------------------------------------------------------------------------

contract MockUSDC2 is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockSanctionsOracle2 is ISanctionsOracle {
    function isSanctioned(address) external pure returns (bool) {
        return false;
    }

    function isWhitelisted(address) external pure returns (bool) {
        return true;
    }

    function updateSanctionStatus(address, bool) external {}
    function updateSanctionStatusBatch(address[] calldata, bool) external {}
    function updateWhitelistStatus(address, bool) external {}
    function updateWhitelistStatusBatch(address[] calldata, bool) external {}
    function totalSanctionedCount() external pure returns (uint256) { return 0; }
    function totalWhitelistedCount() external pure returns (uint256) { return 0; }
    function lastUpdateTimestamp() external pure returns (uint256) { return 0; }
    function batchNonce() external pure returns (uint256) { return 0; }
    function MAX_BATCH_SIZE() external pure returns (uint256) { return 200; }
    function COMPLIANCE_ROLE() external pure returns (bytes32) { return keccak256("COMPLIANCE_ROLE"); }
    function initialize(address, address) external {}
}

contract MockPosToken2 is ERC20 {
    constructor() ERC20("Mock Pos Token", "mPOS") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockPendingInvestVenue_AR {
    mapping(address => uint256) public pendingAsset;

    function recordPendingInvest(address adapter, uint256 amount) external {
        pendingAsset[adapter] += amount;
    }
}

contract MockAsyncInvestAdapter_AR is IStrategyAdapter {
    address public immutable ASSET;
    address public immutable POS_TOKEN;
    MockPendingInvestVenue_AR public immutable VENUE;
    address public vaultAddr;

    constructor(address asset_, address posToken_, address venue_) {
        ASSET = asset_;
        POS_TOKEN = posToken_;
        VENUE = MockPendingInvestVenue_AR(venue_);
    }

    function setVault(address vault_) external {
        vaultAddr = vault_;
    }

    function name() external pure returns (string memory) { return "MockAsyncInvestAdapter_AR"; }
    function asset() external view returns (address) { return ASSET; }
    function posToken() external view returns (address) { return POS_TOKEN; }
    function priceOracle() external pure returns (address) { return address(0); }
    function vault() external view returns (address) { return vaultAddr; }
    function setPaused(bool) external {}
    function retryRedeemAsync(uint256, address) external {}
    function minSubscribeAsset() external pure returns (uint256) { return 0; }
    function minRedeemPos() external pure returns (uint256) { return 0; }
    function getPosTokenPrice() external pure returns (uint256) { return 1e18; }
    function estimatePosAmount(uint256 assetAmount) external pure returns (uint256) { return assetAmount; }

    function previewDeposit(uint256 assetAmount)
        external
        pure
        returns (bool ok, uint256 executableAssetAmount, uint256 expectedPosAmount)
    {
        ok = assetAmount > 0;
        executableAssetAmount = assetAmount;
        expectedPosAmount = assetAmount;
    }

    function previewRedeem(uint256)
        external
        pure
        returns (bool ok, uint256 executableAssetAmount, uint256 expectedPosAmount)
    {
        ok = false;
        executableAssetAmount = 0;
        expectedPosAmount = 0;
    }

    function totalValue() external view returns (uint256) {
        return IERC20(POS_TOKEN).balanceOf(address(this));
    }

    function deposit(uint256 amount, address) external returns (uint256) {
        IERC20(ASSET).transferFrom(vaultAddr, address(this), amount);
        IERC20(ASSET).transfer(address(VENUE), amount);
        VENUE.recordPendingInvest(address(this), amount);
        return amount;
    }

    function withdrawSync(uint256, address) external pure returns (uint256) {
        revert("SYNC_DISABLED");
    }

    function requestRedeemAsync(uint256, address) external pure {}

    function sweepToVault(address token, uint256 amount) external returns (uint256) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 actual = amount > bal ? bal : amount;
        if (actual > 0) {
            IERC20(token).transfer(vaultAddr, actual);
        }
        return actual;
    }
}

/**
 * @title  AdapterRegistryQATest
 * @notice QA scenario tests for Adapter registration and removal (Adapter 注册与移除场景).
 */
contract AdapterRegistryQATest is Test {
    MockUSDC2 internal usdc;
    MockSanctionsOracle2 internal oracle;

    VaultFactory internal vaultFactory;
    GatewayFactory internal gatewayFactory;
    AccountantFactory internal accountantFactory;

    MantleYieldVault internal vault;
    MantleVaultGateway internal gw;
    Accountant internal acct;

    address internal admin = makeAddr("admin");
    address internal controller = makeAddr("controller");
    address internal treasury = makeAddr("treasury");
    address internal sanctionSafe = makeAddr("sanctionSafe");

    address internal adapterA = makeAddr("adapterA");
    address internal adapterB = makeAddr("adapterB");
    address internal unregisteredAdapter = makeAddr("unregisteredAdapter");
    address internal bot = makeAddr("bot");

    struct RealInvestInFlightStack_AR {
        StrategyController controller;
        OperatorExecutor executor;
        MockPosToken2 posToken;
        MockPendingInvestVenue_AR venue;
        MockAsyncInvestAdapter_AR adapter;
    }

    function setUp() public {
        usdc = new MockUSDC2();
        oracle = new MockSanctionsOracle2();

        // Deploy implementations
        MantleYieldVault vaultImpl = new MantleYieldVault();
        MantleVaultGateway gatewayImpl = new MantleVaultGateway();
        Accountant accountantImpl = new Accountant();

        // Deploy factories
        vaultFactory = new VaultFactory(address(vaultImpl), admin);
        gatewayFactory = new GatewayFactory(address(gatewayImpl), admin);
        accountantFactory = new AccountantFactory(address(accountantImpl), admin);

        // Deploy vault (uninitialized)
        address vaultAddr = vaultFactory.deployVault();
        vault = MantleYieldVault(vaultAddr);

        // Deploy accountant
        address acctAddr = accountantFactory.deployAndInitAccountant(vaultAddr, 1e18, 100, admin, admin, admin);
        acct = Accountant(acctAddr);

        // Deploy gateway (uninitialized)
        address gwAddr = gatewayFactory.deployGateway();
        gw = MantleVaultGateway(gwAddr);

        // Initialize vault
        IMantleYieldVault.InitParams memory vParams = IMantleYieldVault.InitParams({
            asset: IERC20(address(usdc)),
            name: "Adapter Test Vault",
            symbol: "ATV",
            admin: admin,
            gateway: gwAddr,
            controller: controller,
            accountant: acctAddr,
            treasury: treasury,
            maxRedemptionFeeBps: 500,
            redemptionFeeBps: 100,
            minRedeemAmount: 1e6,
            minDepositAmount: 1e6,
            maxSettlementDeviationBps: 0,
            depositDailyRemaining: type(uint256).max,
            redeemDailyRemaining: type(uint256).max
        });
        vault.initialize(vParams);

        // Initialize gateway
        IMantleVaultGateway.InitParams memory gParams = IMantleVaultGateway.InitParams({
            vault: vaultAddr,
            sanctionsOracle: ISanctionsOracle(address(oracle)),
            sanctionSafe: sanctionSafe,
            admin: admin,
            syncRedeemDisabled: false
        });
        gw.initialize(gParams);
    }

    string constant MODULE = unicode"Adapter 注册与移除场景";
    string private _caseId;
    string private _caseName;
    string private _buf;

    function _logCase(string memory id, string memory name) internal {
        _caseId = id;
        _caseName = name;
        _buf = "";
        _step(string.concat("testcase module: ", MODULE));
        _step(string.concat("testcase id: ", id));
        _step(string.concat("testcase name: ", name));
        _step("----------------------------------------");
    }

    function _step(string memory msg) internal {
        console2.log(msg);
        _buf = string.concat(_buf, msg, "\n");
    }

    function _logPass() internal {
        _step("----------------------------------------");
        _step("test result: passed");
    }

    function _depositToVault(address depositor, uint256 amount) internal {
        usdc.mint(depositor, amount);
        vm.startPrank(depositor);
        usdc.approve(address(vault), type(uint256).max);
        gw.deposit(amount);
        vm.stopPrank();
    }

    function _deployRealInvestInFlightStack() internal returns (RealInvestInFlightStack_AR memory stack) {
        OperatorExecutor executorImpl = new OperatorExecutor();
        stack.executor = OperatorExecutor(address(new ERC1967Proxy(
            address(executorImpl),
            abi.encodeCall(OperatorExecutor.initialize, (admin, bot))
        )));

        StrategyController controllerImpl = new StrategyController();
        stack.controller = StrategyController(address(new ERC1967Proxy(
            address(controllerImpl),
            abi.encodeCall(StrategyController.initialize, (address(vault), admin, address(stack.executor), admin, 0, 0, 0))
        )));

        vm.prank(admin);
        vault.setController(address(stack.controller));

        stack.posToken = new MockPosToken2();
        stack.venue = new MockPendingInvestVenue_AR();
        stack.adapter = new MockAsyncInvestAdapter_AR(address(usdc), address(stack.posToken), address(stack.venue));
        stack.adapter.setVault(address(vault));

        vm.startPrank(admin);
        stack.controller.registerStrategy(address(stack.adapter), 10_000, 1, true);
        stack.controller.activateStrategy(address(stack.adapter));
        address[] memory order = new address[](1);
        order[0] = address(stack.adapter);
        stack.controller.setStrategyOrder(order);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    //  P0 — Controller normal register adapter
    // ═══════════════════════════════════════════════════════════════

    function test_RegisterAdapter_Normal() public {
        _logCase("test_RegisterAdapter_Normal", unicode"Controller 正常注册 adapter");

        _step("[Step 1] Controller calls vault.registerAdapter(adapterA)");
        _step(string.concat("  adapter address: ", vm.toString(adapterA)));
        vm.prank(controller);
        vault.registerAdapter(adapterA);
        _step("  registerAdapter executed successfully");

        _step("[Step 2] Verify isAdapter[adapterA] == true");
        assertTrue(vault.isAdapter(adapterA));
        _step("  PASS: isAdapter[adapterA] == true");
        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  P0 — Duplicate register adapter rejected
    // ═══════════════════════════════════════════════════════════════

    function test_RegisterAdapter_DuplicateRejected() public {
        _logCase("test_RegisterAdapter_DuplicateRejected", unicode"重复注册 adapter 被拒绝");

        _step("[Step 1] Register adapterA first time");
        vm.prank(controller);
        vault.registerAdapter(adapterA);
        assertTrue(vault.isAdapter(adapterA));
        _step("  PASS: adapterA registered successfully");

        _step("[Step 2] Try to register adapterA again");
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(IMantleYieldVault.Vault__AdapterAlreadyRegistered.selector, adapterA));
        vault.registerAdapter(adapterA);
        _step("  PASS: reverted with Vault__AdapterAlreadyRegistered");
        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  P0 — Remove non-existent adapter rejected
    // ═══════════════════════════════════════════════════════════════

    function test_RemoveAdapter_NonExistentRejected() public {
        _logCase("test_RemoveAdapter_NonExistentRejected", unicode"移除不存在的 adapter 被拒绝");

        _step("[Step 1] Try to remove unregistered adapter");
        _step(string.concat("  adapter address: ", vm.toString(unregisteredAdapter)));
        vm.prank(controller);
        vm.expectRevert(
            abi.encodeWithSelector(IMantleYieldVault.Vault__AdapterNotRegistered.selector, unregisteredAdapter)
        );
        vault.removeAdapter(unregisteredAdapter);
        _step("  PASS: reverted with Vault__AdapterNotRegistered");
        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  P0 — Remove adapter with in-flight rejected
    // ═══════════════════════════════════════════════════════════════

    function test_RemoveAdapter_WithInFlightRejected() public {
        _logCase("test_RemoveAdapter_WithInFlightRejected", unicode"adapter 存在 in-flight 时禁止移除");

        _step("[Step 1] Deploy real controller/executor stack and register async adapter");
        RealInvestInFlightStack_AR memory stack = _deployRealInvestInFlightStack();
        assertTrue(vault.isAdapter(address(stack.adapter)));
        _step("  PASS: async adapter registered via real StrategyController");

        _step("[Step 2] Deposit to vault and create invest in-flight via real rebalance");
        _depositToVault(makeAddr("depositor"), 1000e6);
        vm.prank(bot);
        stack.executor.executeRebalance(address(stack.controller));

        uint256 pendingInvest = vault.adapterInvestInFlightTokens(address(stack.adapter));
        uint256 venuePendingAsset = stack.venue.pendingAsset(address(stack.adapter));
        assertEq(pendingInvest, 1000e6, "pending invest should come from real rebalance");
        assertEq(venuePendingAsset, 1000e6, "venue should hold the transferred asset while invest is pending");
        _step(string.concat("  adapterInvestInFlightTokens: ", vm.toString(pendingInvest)));
        _step(string.concat("  venue pending asset: ", vm.toString(venuePendingAsset)));
        _step("  PASS: real invest in-flight created without fake vault state injection");

        _step("[Step 3] Try to remove adapterA with in-flight");
        vm.prank(address(stack.controller));
        vm.expectRevert(
            abi.encodeWithSelector(IMantleYieldVault.Vault__AdapterHasInFlight.selector, address(stack.adapter))
        );
        vault.removeAdapter(address(stack.adapter));
        _step("  PASS: reverted with Vault__AdapterHasInFlight");
        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  P1 — Remove adapter without in-flight succeeds
    // ═══════════════════════════════════════════════════════════════

    function test_RemoveAdapter_NoInFlightSucceeds() public {
        _logCase("test_RemoveAdapter_NoInFlightSucceeds", unicode"无 in-flight 时可移除 adapter");

        _step("[Step 1] Register adapterA");
        vm.prank(controller);
        vault.registerAdapter(adapterA);
        assertTrue(vault.isAdapter(adapterA));
        _step("  PASS: adapterA registered");

        _step("[Step 2] Remove adapterA (no in-flight)");
        vm.prank(controller);
        vault.removeAdapter(adapterA);
        _step("  removeAdapter executed successfully");

        _step("[Step 3] Verify isAdapter[adapterA] == false");
        assertFalse(vault.isAdapter(adapterA));
        _step("  PASS: isAdapter[adapterA] == false");
        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  P1 — approveToAdapter rejects unregistered adapter
    // ═══════════════════════════════════════════════════════════════

    function test_ApproveToAdapter_UnregisteredRejected() public {
        _logCase("test_ApproveToAdapter_UnregisteredRejected", unicode"`approveToAdapter` 仅允许已注册 adapter");

        _step("[Step 1] Controller calls approveToAdapter with unregistered adapter");
        _step(string.concat("  adapter address: ", vm.toString(unregisteredAdapter)));
        vm.prank(controller);
        vm.expectRevert(
            abi.encodeWithSelector(IMantleYieldVault.Vault__AdapterNotRegistered.selector, unregisteredAdapter)
        );
        vault.approveToAdapter(unregisteredAdapter, address(usdc), 1000e6);
        _step("  PASS: reverted with Vault__AdapterNotRegistered");
        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  P1 — approveToAdapter normal sets allowance
    // ═══════════════════════════════════════════════════════════════

    function test_ApproveToAdapter_NormalAllowance() public {
        _logCase("test_ApproveToAdapter_NormalAllowance", unicode"`approveToAdapter` 正常设置 allowance");

        _step("[Step 1] Register adapterA");
        vm.prank(controller);
        vault.registerAdapter(adapterA);
        assertTrue(vault.isAdapter(adapterA));
        _step("  PASS: adapterA registered");

        _step("[Step 2] Call approveToAdapter(adapterA, usdc, 1000e6)");
        uint256 amount = 1000e6;
        vm.prank(controller);
        vault.approveToAdapter(adapterA, address(usdc), amount);
        _step("  approveToAdapter executed successfully");

        _step("[Step 3] Verify USDC allowance from vault to adapterA");
        uint256 allowance = usdc.allowance(address(vault), adapterA);
        assertEq(allowance, amount);
        _step(string.concat("  allowance: ", vm.toString(allowance)));
        _step("  PASS: allowance updated to 1000e6");
        _logPass();
    }
}
