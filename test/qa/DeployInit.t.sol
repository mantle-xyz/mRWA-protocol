// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {IMantleVaultGateway} from "../../src/interfaces/vault/IMantleVaultGateway.sol";
import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {IAccountant} from "../../src/interfaces/accountant/IAccountant.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {MantleVaultGateway} from "../../src/vault/MantleVaultGateway.sol";
import {Accountant} from "../../src/accountant/Accountant.sol";
import {VaultFactory} from "../../src/vault/VaultFactory.sol";
import {GatewayFactory} from "../../src/vault/GatewayFactory.sol";
import {AccountantFactory} from "../../src/accountant/AccountantFactory.sol";
import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {StrategyControllerFactory} from "../../src/protocol/StrategyControllerFactory.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IAccessControlDefaultAdminRules} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import {Test, console2} from "forge-std/Test.sol";

// ---------------------------------------------------------------------------
// Mock contracts
// ---------------------------------------------------------------------------

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockSanctionsOracle is ISanctionsOracle {
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

/**
 * @title  DeployInitQATest
 * @notice QA scenario tests for deploy and initialization (部署与初始化场景).
 */
contract DeployInitQATest is Test {
    MockUSDC internal usdc;
    MockSanctionsOracle internal oracle;

    MantleYieldVault internal vaultImpl;
    MantleVaultGateway internal gatewayImpl;
    Accountant internal accountantImpl;

    VaultFactory internal vaultFactory;
    GatewayFactory internal gatewayFactory;
    AccountantFactory internal accountantFactory;

    address internal admin = makeAddr("admin");
    address internal controller = makeAddr("controller");
    address internal treasury = makeAddr("treasury");
    address internal sanctionSafe = makeAddr("sanctionSafe");
    address internal attacker = makeAddr("attacker");

    // Deployed via factory in setUp
    MantleYieldVault internal vault;
    MantleVaultGateway internal gw;
    Accountant internal acct;

    function setUp() public {
        usdc = new MockUSDC();
        oracle = new MockSanctionsOracle();

        // Deploy implementation contracts
        vaultImpl = new MantleYieldVault();
        gatewayImpl = new MantleVaultGateway();
        accountantImpl = new Accountant();

        // Deploy factories
        vaultFactory = new VaultFactory(address(vaultImpl), admin);
        gatewayFactory = new GatewayFactory(address(gatewayImpl), admin);
        accountantFactory = new AccountantFactory(address(accountantImpl), admin);

        // Deploy vault first (uninitialized) to get address for accountant
        address vaultAddr = vaultFactory.deployVault();
        vault = MantleYieldVault(vaultAddr);

        // Deploy accountant with vault address
        address acctAddr = accountantFactory.deployAndInitAccountant(
            vaultAddr,
            1e18, // initialRate
            100, // managementFeeRate 1%
            admin,
            admin,
            admin
        );
        acct = Accountant(acctAddr);

        // Deploy gateway (uninitialized) to get address for vault init
        address gwAddr = gatewayFactory.deployGateway();
        gw = MantleVaultGateway(gwAddr);

        // Initialize vault
        IMantleYieldVault.InitParams memory vParams = IMantleYieldVault.InitParams({
            asset: IERC20(address(usdc)),
            name: "Mantle Yield Vault",
            symbol: "mYV",
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

    string constant MODULE = unicode"部署与初始化场景";
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

    // ═══════════════════════════════════════════════════════════════
    //  P0 — VaultFactory deploy
    // ═══════════════════════════════════════════════════════════════

    function test_VaultFactory_DeployValid() public {
        _logCase("test_VaultFactory_DeployValid", unicode"VaultFactory 使用合法参数部署成功");

        _step("[Step 1] Deploy VaultFactory with valid impl and beaconOwner");
        MantleYieldVault impl = new MantleYieldVault();
        VaultFactory factory = new VaultFactory(address(impl), admin);
        _step(string.concat("  factory address: ", vm.toString(address(factory))));
        _step("  PASS: Factory deployed successfully");

        _step("[Step 2] Verify implementation() returns the correct impl address");
        assertEq(factory.implementation(), address(impl));
        _step(string.concat("  implementation(): ", vm.toString(factory.implementation())));
        _step("  PASS: implementation() returns the correct impl");
        _logPass();
    }

    function test_VaultFactory_RevertZeroAddress() public {
        _logCase("test_VaultFactory_RevertZeroAddress", unicode"VaultFactory 构造参数为零地址时拒绝部署");

        _step("[Step 1] Deploy with impl = address(0)");
        vm.expectRevert(VaultFactory.Factory__ZeroAddress.selector);
        new VaultFactory(address(0), admin);
        _step("  PASS: reverted with Factory__ZeroAddress");

        _step("[Step 2] Deploy with beaconOwner = address(0)");
        MantleYieldVault impl = new MantleYieldVault();
        vm.expectRevert(VaultFactory.Factory__ZeroAddress.selector);
        new VaultFactory(address(impl), address(0));
        _step("  PASS: reverted with Factory__ZeroAddress");
        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  P0 — GatewayFactory deploy
    // ═══════════════════════════════════════════════════════════════

    function test_GatewayFactory_RevertZeroAddress() public {
        _logCase("test_GatewayFactory_RevertZeroAddress", unicode"GatewayFactory 构造参数为零地址时拒绝部署");

        _step("[Step 1] Deploy with impl = address(0)");
        vm.expectRevert(GatewayFactory.Factory__ZeroAddress.selector);
        new GatewayFactory(address(0), admin);
        _step("  PASS: reverted with Factory__ZeroAddress");

        _step("[Step 2] Deploy with beaconOwner = address(0)");
        MantleVaultGateway impl = new MantleVaultGateway();
        vm.expectRevert(GatewayFactory.Factory__ZeroAddress.selector);
        new GatewayFactory(address(impl), address(0));
        _step("  PASS: reverted with Factory__ZeroAddress");
        _logPass();
    }

    function test_GatewayFactory_DeployValid() public {
        _logCase("test_GatewayFactory_DeployValid", unicode"GatewayFactory 使用合法参数部署成功");

        _step("[Step 1] Deploy GatewayFactory with valid impl and beaconOwner");
        MantleVaultGateway impl = new MantleVaultGateway();
        GatewayFactory factory = new GatewayFactory(address(impl), admin);
        _step(string.concat("  factory address: ", vm.toString(address(factory))));
        _step("  PASS: Factory deployed successfully");

        _step("[Step 2] Verify implementation() returns the correct impl address");
        assertEq(factory.implementation(), address(impl));
        _step(string.concat("  implementation(): ", vm.toString(factory.implementation())));
        _step("  PASS: implementation() returns the correct impl");
        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  P0 — deployAndInitVault atomic deploy
    // ═══════════════════════════════════════════════════════════════

    function test_DeployAndInitVault() public {
        _logCase("test_DeployAndInitVault", unicode"`deployAndInitVault` 原子部署并初始化 Vault");

        _step("[Step 1] Assemble InitParams");
        // Need a fresh accountant for a fresh vault
        address freshAcctAddr = accountantFactory.deployAndInitAccountant(
            address(vault), // use existing vault as the accountant's vault reference
            1e18,
            100,
            admin,
            admin,
            admin
        );
        address freshGw = gatewayFactory.deployGateway();

        IMantleYieldVault.InitParams memory params = IMantleYieldVault.InitParams({
            asset: IERC20(address(usdc)),
            name: "Test Vault",
            symbol: "tVLT",
            admin: admin,
            gateway: freshGw,
            controller: controller,
            accountant: freshAcctAddr,
            treasury: treasury,
            maxRedemptionFeeBps: 500,
            redemptionFeeBps: 100,
            minRedeemAmount: 1e6,
            minDepositAmount: 1e6,
            maxSettlementDeviationBps: 0,
            depositDailyRemaining: type(uint256).max,
            redeemDailyRemaining: type(uint256).max
        });
        _step("  InitParams assembled");

        _step("[Step 2] Call deployAndInitVault(params)");
        address vaultAddr = vaultFactory.deployAndInitVault(params);
        _step(string.concat("  vault address: ", vm.toString(vaultAddr)));
        _step("  PASS: Vault deployed and initialized");

        _step("[Step 3] Verify key state matches init params");
        IMantleYieldVault v = IMantleYieldVault(vaultAddr);
        assertEq(v.controller(), controller);
        _step(string.concat("  controller: ", vm.toString(v.controller())));
        assertEq(v.accountant(), freshAcctAddr);
        _step(string.concat("  accountant: ", vm.toString(v.accountant())));
        assertEq(v.treasury(), treasury);
        _step(string.concat("  treasury: ", vm.toString(v.treasury())));
        assertEq(v.gateway(), freshGw);
        _step(string.concat("  gateway: ", vm.toString(v.gateway())));
        assertEq(v.nextRequestId(), 1);
        _step(string.concat("  nextRequestId: ", vm.toString(v.nextRequestId())));
        assertEq(v.nextInFlightId(), 1);
        _step(string.concat("  nextInFlightId: ", vm.toString(v.nextInFlightId())));
        _step("  PASS: all key state matches init params");
        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  P0 — deployAndInitGateway atomic deploy
    // ═══════════════════════════════════════════════════════════════

    function test_DeployAndInitGateway() public {
        _logCase("test_DeployAndInitGateway", unicode"`deployAndInitGateway` 原子部署并初始化 Gateway");

        _step("[Step 1] Assemble Gateway InitParams");
        IMantleVaultGateway.InitParams memory params = IMantleVaultGateway.InitParams({
            vault: address(vault),
            sanctionsOracle: ISanctionsOracle(address(oracle)),
            sanctionSafe: sanctionSafe,
            admin: admin,
            syncRedeemDisabled: false
        });
        _step("  InitParams assembled");

        _step("[Step 2] Call deployAndInitGateway(params)");
        address gwAddr = gatewayFactory.deployAndInitGateway(params);
        _step(string.concat("  gateway address: ", vm.toString(gwAddr)));
        _step("  PASS: Gateway deployed and initialized");

        _step("[Step 3] Verify key state matches init params");
        IMantleVaultGateway g = IMantleVaultGateway(gwAddr);
        assertEq(address(g.vault()), address(vault));
        _step(string.concat("  vault: ", vm.toString(address(g.vault()))));
        assertEq(address(g.sanctionsOracle()), address(oracle));
        _step(string.concat("  sanctionsOracle: ", vm.toString(address(g.sanctionsOracle()))));
        assertEq(g.sanctionSafe(), sanctionSafe);
        _step(string.concat("  sanctionSafe: ", vm.toString(g.sanctionSafe())));
        _step("  PASS: Gateway configuration is correct");
        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  P0 — Vault init rejects zero addresses
    // ═══════════════════════════════════════════════════════════════

    function _freshVaultParams() internal view returns (IMantleYieldVault.InitParams memory) {
        return IMantleYieldVault.InitParams({
            asset: IERC20(address(usdc)),
            name: "Test",
            symbol: "T",
            admin: admin,
            gateway: address(gw),
            controller: controller,
            accountant: address(acct),
            treasury: treasury,
            maxRedemptionFeeBps: 500,
            redemptionFeeBps: 100,
            minRedeemAmount: 1e6,
            minDepositAmount: 1e6,
            maxSettlementDeviationBps: 0,
            depositDailyRemaining: type(uint256).max,
            redeemDailyRemaining: type(uint256).max
        });
    }

    function test_VaultInit_RejectZeroAddresses() public {
        _logCase("test_VaultInit_RejectZeroAddresses", unicode"Vault 初始化拒绝关键零地址");

        _step("[Step 1] Deploy uninitialized vault proxy");
        address uninitVault = vaultFactory.deployVault();
        _step(string.concat("  uninit vault: ", vm.toString(uninitVault)));

        _step("[Step 2] Test asset = address(0)");
        IMantleYieldVault.InitParams memory p = _freshVaultParams();
        p.asset = IERC20(address(0));
        vm.expectRevert(IMantleYieldVault.Vault__ZeroAddress.selector);
        IMantleYieldVault(uninitVault).initialize(p);
        _step("  PASS: reverted with Vault__ZeroAddress");

        _step("[Step 3] Test admin = address(0)");
        // Need new proxy each time since we can't re-init
        uninitVault = vaultFactory.deployVault();
        p = _freshVaultParams();
        p.admin = address(0);
        vm.expectRevert(abi.encodeWithSelector(IAccessControlDefaultAdminRules.AccessControlInvalidDefaultAdmin.selector, address(0)));
        IMantleYieldVault(uninitVault).initialize(p);
        _step("  PASS: reverted with AccessControlInvalidDefaultAdmin(address(0))");

        _step("[Step 4] Test controller = address(0)");
        uninitVault = vaultFactory.deployVault();
        p = _freshVaultParams();
        p.controller = address(0);
        vm.expectRevert(IMantleYieldVault.Vault__ZeroAddress.selector);
        IMantleYieldVault(uninitVault).initialize(p);
        _step("  PASS: reverted with Vault__ZeroAddress");

        _step("[Step 5] Test accountant = address(0)");
        uninitVault = vaultFactory.deployVault();
        p = _freshVaultParams();
        p.accountant = address(0);
        vm.expectRevert(IMantleYieldVault.Vault__ZeroAddress.selector);
        IMantleYieldVault(uninitVault).initialize(p);
        _step("  PASS: reverted with Vault__ZeroAddress");

        _step("[Step 6] Test treasury = address(0)");
        uninitVault = vaultFactory.deployVault();
        p = _freshVaultParams();
        p.treasury = address(0);
        vm.expectRevert(IMantleYieldVault.Vault__ZeroAddress.selector);
        IMantleYieldVault(uninitVault).initialize(p);
        _step("  PASS: reverted with Vault__ZeroAddress");

        _step("[Step 7] Test gateway = address(0)");
        uninitVault = vaultFactory.deployVault();
        p = _freshVaultParams();
        p.gateway = address(0);
        vm.expectRevert(IMantleYieldVault.Vault__ZeroAddress.selector);
        IMantleYieldVault(uninitVault).initialize(p);
        _step("  PASS: reverted with Vault__ZeroAddress");
        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  P0 — Vault init rejects invalid fee config
    // ═══════════════════════════════════════════════════════════════

    function test_VaultInit_RejectInvalidFeeConfig() public {
        _logCase("test_VaultInit_RejectInvalidFeeConfig", unicode"Vault 初始化拒绝无效赎回费配置");

        IMantleYieldVault.InitParams memory baseParams = IMantleYieldVault.InitParams({
            asset: IERC20(address(usdc)),
            name: "Test",
            symbol: "T",
            admin: admin,
            gateway: address(gw),
            controller: controller,
            accountant: address(acct),
            treasury: treasury,
            maxRedemptionFeeBps: 500,
            redemptionFeeBps: 100,
            minRedeemAmount: 1e6,
            minDepositAmount: 1e6,
            maxSettlementDeviationBps: 0,
            depositDailyRemaining: type(uint256).max,
            redeemDailyRemaining: type(uint256).max
        });

        _step("[Step 1] Test maxRedemptionFeeBps > 10000");
        address uninitVault = vaultFactory.deployVault();
        IMantleYieldVault.InitParams memory p = baseParams;
        p.maxRedemptionFeeBps = 10_001;
        vm.expectRevert(abi.encodeWithSelector(IMantleYieldVault.Vault__FeeTooHigh.selector, 10_001, 10_000));
        IMantleYieldVault(uninitVault).initialize(p);
        _step("  PASS: reverted with Vault__FeeTooHigh");

        _step("[Step 2] Test redemptionFeeBps > maxRedemptionFeeBps");
        uninitVault = vaultFactory.deployVault();
        p = baseParams;
        p.maxRedemptionFeeBps = 500;
        p.redemptionFeeBps = 600;
        vm.expectRevert(abi.encodeWithSelector(IMantleYieldVault.Vault__FeeTooHigh.selector, 600, 500));
        IMantleYieldVault(uninitVault).initialize(p);
        _step("  PASS: reverted with Vault__FeeTooHigh");
        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  P0 — Gateway init rejects zero addresses
    // ═══════════════════════════════════════════════════════════════

    function test_GatewayInit_RejectZeroAddresses() public {
        _logCase("test_GatewayInit_RejectZeroAddresses", unicode"Gateway 初始化拒绝关键零地址");

        IMantleVaultGateway.InitParams memory baseParams = IMantleVaultGateway.InitParams({
            vault: address(vault),
            sanctionsOracle: ISanctionsOracle(address(oracle)),
            sanctionSafe: sanctionSafe,
            admin: admin,
            syncRedeemDisabled: false
        });

        _step("[Step 1] Test vault = address(0)");
        address uninitGw = gatewayFactory.deployGateway();
        IMantleVaultGateway.InitParams memory p = baseParams;
        p.vault = address(0);
        vm.expectRevert(IMantleYieldVault.Vault__ZeroAddress.selector);
        IMantleVaultGateway(uninitGw).initialize(p);
        _step("  PASS: reverted with Vault__ZeroAddress");

        _step("[Step 2] Test sanctionsOracle = address(0)");
        uninitGw = gatewayFactory.deployGateway();
        p = baseParams;
        p.sanctionsOracle = ISanctionsOracle(address(0));
        vm.expectRevert(IMantleYieldVault.Vault__ZeroAddress.selector);
        IMantleVaultGateway(uninitGw).initialize(p);
        _step("  PASS: reverted with Vault__ZeroAddress");

        _step("[Step 3] Test sanctionSafe = address(0)");
        uninitGw = gatewayFactory.deployGateway();
        p = baseParams;
        p.sanctionSafe = address(0);
        vm.expectRevert(IMantleYieldVault.Vault__ZeroAddress.selector);
        IMantleVaultGateway(uninitGw).initialize(p);
        _step("  PASS: reverted with Vault__ZeroAddress");

        _step("[Step 4] Test admin = address(0)");
        uninitGw = gatewayFactory.deployGateway();
        p = baseParams;
        p.admin = address(0);
        vm.expectRevert(IMantleYieldVault.Vault__ZeroAddress.selector);
        IMantleVaultGateway(uninitGw).initialize(p);
        _step("  PASS: reverted with Vault__ZeroAddress");
        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  P1 — Duplicate init prevention
    // ═══════════════════════════════════════════════════════════════

    function test_DuplicateInit_Prevention() public {
        _logCase("test_DuplicateInit_Prevention", unicode"合约禁止重复初始化");

        _step("[Step 1] Try to re-initialize the already-initialized Vault");
        IMantleYieldVault.InitParams memory vParams = IMantleYieldVault.InitParams({
            asset: IERC20(address(usdc)),
            name: "Re-init",
            symbol: "RI",
            admin: admin,
            gateway: address(gw),
            controller: controller,
            accountant: address(acct),
            treasury: treasury,
            maxRedemptionFeeBps: 500,
            redemptionFeeBps: 100,
            minRedeemAmount: 1e6,
            minDepositAmount: 1e6,
            maxSettlementDeviationBps: 0,
            depositDailyRemaining: type(uint256).max,
            redeemDailyRemaining: type(uint256).max
        });
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(vParams);
        _step("  PASS: Vault re-initialize reverted with InvalidInitialization");

        _step("[Step 2] Try to re-initialize the already-initialized Gateway");
        IMantleVaultGateway.InitParams memory gParams = IMantleVaultGateway.InitParams({
            vault: address(vault),
            sanctionsOracle: ISanctionsOracle(address(oracle)),
            sanctionSafe: sanctionSafe,
            admin: admin,
            syncRedeemDisabled: false
        });
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        gw.initialize(gParams);
        _step("  PASS: Gateway re-initialize reverted with InvalidInitialization");

        _step("[Step 3] Try to re-initialize the already-initialized Accountant");
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        acct.initialize(address(vault), 1e18, 100, admin, admin, admin);
        _step("  PASS: Accountant re-initialize reverted with InvalidInitialization");

        _step("[Step 4] Deploy and initialize a StrategyController via factory, then try re-init");
        StrategyController scImpl = new StrategyController();
        StrategyControllerFactory ctrlFactory = new StrategyControllerFactory(address(scImpl), admin);
        // operatorExecutor must be a contract (code.length > 0), use oracle as a stand-in
        address scAddr = ctrlFactory.deployAndInitController(
            address(vault), admin, address(oracle), admin, 1000, 100, 0
        );
        StrategyController sc = StrategyController(scAddr);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        sc.initialize(address(vault), admin, address(oracle), admin, 1000, 100, 0);
        _step("  PASS: Controller re-initialize reverted with InvalidInitialization");
        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  P0 — Accountant init rejects zero/invalid params
    // ═══════════════════════════════════════════════════════════════

    function test_AccountantInit_RejectInvalid() public {
        _logCase("test_AccountantInit_RejectInvalid", unicode"Accountant 初始化拒绝关键零地址与非法初始汇率/费率");

        _step("[Step 1] Test vault = address(0)");
        address uninitAcct = accountantFactory.deployAccountant();
        vm.expectRevert(Accountant.Accountant__ZeroAddress.selector);
        Accountant(uninitAcct).initialize(address(0), 1e18, 100, admin, admin, admin);
        _step("  PASS: reverted with ZeroAddress()");

        _step("[Step 2] Test admin = address(0)");
        uninitAcct = accountantFactory.deployAccountant();
        vm.expectRevert(Accountant.Accountant__ZeroAddress.selector);
        Accountant(uninitAcct).initialize(address(vault), 1e18, 100, address(0), admin, admin);
        _step("  PASS: reverted with ZeroAddress()");

        _step("[Step 3] Test initialRate = 0");
        uninitAcct = accountantFactory.deployAccountant();
        vm.expectRevert(Accountant.Accountant__InvalidRate.selector);
        Accountant(uninitAcct).initialize(address(vault), 0, 100, admin, admin, admin);
        _step("  PASS: reverted with InvalidRate()");

        _step("[Step 4] Test managementFeeRate exceeds MAX_MANAGEMENT_FEE_BPS");
        uninitAcct = accountantFactory.deployAccountant();
        uint32 tooHighFee = uint32(Accountant(uninitAcct).MAX_MANAGEMENT_FEE_BPS()) + 1;
        vm.expectRevert(abi.encodeWithSelector(Accountant.Accountant__InvalidFeeRate.selector, uint256(tooHighFee)));
        Accountant(uninitAcct).initialize(address(vault), 1e18, tooHighFee, admin, admin, admin);
        _step("  PASS: reverted with InvalidFeeRate()");
        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  P0 — deployAndInitAccountant
    // ═══════════════════════════════════════════════════════════════

    function test_DeployAndInitAccountant() public {
        _logCase("test_DeployAndInitAccountant", unicode"`deployAndInitAccountant` 原子部署并初始化成功");

        _step("[Step 1] Assemble Accountant init params");
        uint64 initialRate = 1e18;
        uint32 mgmtFee = 100;
        _step(string.concat("  initialRate: ", vm.toString(uint256(initialRate))));
        _step(string.concat("  managementFeeRate: ", vm.toString(uint256(mgmtFee))));

        _step("[Step 2] Call deployAndInitAccountant");
        address acctAddr = accountantFactory.deployAndInitAccountant(address(vault), initialRate, mgmtFee, admin, admin, admin);
        Accountant a = Accountant(acctAddr);
        _step(string.concat("  accountant address: ", vm.toString(acctAddr)));
        _step("  PASS: Accountant deployed and initialized");

        _step("[Step 3] Verify key state");
        assertEq(a.lastExchangeRate(), uint256(initialRate));
        _step(string.concat("  lastExchangeRate: ", vm.toString(a.lastExchangeRate())));
        _step("  PASS: lastExchangeRate == initialRate");

        assertEq(a.managementFeeRate(), mgmtFee);
        _step(string.concat("  managementFeeRate: ", vm.toString(uint256(a.managementFeeRate()))));
        _step("  PASS: managementFeeRate correct");

        assertTrue(a.hasRole(a.DEFAULT_ADMIN_ROLE(), admin));
        _step("  PASS: admin has DEFAULT_ADMIN_ROLE");
        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  P1 — Accountant default params after init
    // ═══════════════════════════════════════════════════════════════

    function test_AccountantDefaultParams() public {
        _logCase("test_AccountantDefaultParams", unicode"Accountant 初始化后默认参数正确");

        _step("[Step 1] Read maxAllowedDeviation");
        assertEq(acct.maxAllowedDeviation(), 100);
        _step(string.concat("  maxAllowedDeviation: ", vm.toString(uint256(acct.maxAllowedDeviation()))));
        _step("  PASS: maxAllowedDeviation == 100");

        _step("[Step 2] Read minUpdateInterval");
        assertEq(acct.minUpdateInterval(), 20 hours);
        _step(string.concat("  minUpdateInterval: ", vm.toString(uint256(acct.minUpdateInterval()))));
        _step("  PASS: minUpdateInterval == 20 hours");

        _step("[Step 3] Read maxComputeAge");
        assertEq(acct.maxComputeAge(), 5 minutes);
        _step(string.concat("  maxComputeAge: ", vm.toString(uint256(acct.maxComputeAge()))));
        _step("  PASS: maxComputeAge == 5 minutes");

        _step("[Step 4] Read timestamps");
        uint64 ts = uint64(block.timestamp);
        assertEq(acct.lastComputeTimestamp(), ts);
        _step(string.concat("  lastComputeTimestamp: ", vm.toString(uint256(acct.lastComputeTimestamp()))));
        assertEq(acct.lastUpdateTimestamp(), ts);
        _step(string.concat("  lastUpdateTimestamp: ", vm.toString(uint256(acct.lastUpdateTimestamp()))));
        assertEq(acct.lastFeeSettleTimestamp(), ts);
        _step(string.concat("  lastFeeSettleTimestamp: ", vm.toString(uint256(acct.lastFeeSettleTimestamp()))));
        _step("  PASS: all timestamps == block.timestamp at init");
        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  P1 — Accountant roles after init
    // ═══════════════════════════════════════════════════════════════

    function test_AccountantRolesCheck() public {
        _logCase("test_AccountantRolesCheck", unicode"Accountant 初始化后角色授予正确");

        _step("[Step 1] Check admin has DEFAULT_ADMIN_ROLE");
        assertTrue(acct.hasRole(acct.DEFAULT_ADMIN_ROLE(), admin));
        _step("  PASS: admin has DEFAULT_ADMIN_ROLE");

        _step("[Step 2] Check admin has PAUSER_ROLE");
        assertTrue(acct.hasRole(acct.PAUSER_ROLE(), admin));
        _step("  PASS: admin has PAUSER_ROLE");

        _step("[Step 3] Check admin has EXECUTOR_ROLE");
        assertTrue(acct.hasRole(acct.ACCOUNTANT_EXECUTOR_ROLE(), admin));
        _step("  PASS: admin has EXECUTOR_ROLE");
        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  P1 — deployAndInitVault default state check
    // ═══════════════════════════════════════════════════════════════

    function test_DeployAndInitVault_DefaultState() public {
        _logCase("test_DeployAndInitVault_DefaultState", unicode"`deployAndInitVault` 后关键默认状态正确");

        _step("[Step 1] Call deployAndInitVault with valid params");
        address freshAcctAddr = accountantFactory.deployAndInitAccountant(address(vault), 1e18, 100, admin, admin, admin);
        address freshGw = gatewayFactory.deployGateway();

        IMantleYieldVault.InitParams memory params = IMantleYieldVault.InitParams({
            asset: IERC20(address(usdc)),
            name: "Default State Vault",
            symbol: "DSV",
            admin: admin,
            gateway: freshGw,
            controller: controller,
            accountant: freshAcctAddr,
            treasury: treasury,
            maxRedemptionFeeBps: 500,
            redemptionFeeBps: 100,
            minRedeemAmount: 1e6,
            minDepositAmount: 1e6,
            maxSettlementDeviationBps: 0,
            depositDailyRemaining: type(uint256).max,
            redeemDailyRemaining: type(uint256).max
        });
        address vaultAddr = vaultFactory.deployAndInitVault(params);
        IMantleYieldVault v = IMantleYieldVault(vaultAddr);
        _step(string.concat("  vault address: ", vm.toString(vaultAddr)));

        _step("[Step 2] Verify key configuration and counters");
        assertEq(address(v.asset()), address(usdc));
        _step(string.concat("  asset: ", vm.toString(address(v.asset()))));
        assertEq(v.gateway(), freshGw);
        _step(string.concat("  gateway: ", vm.toString(v.gateway())));
        assertEq(v.controller(), controller);
        _step(string.concat("  controller: ", vm.toString(v.controller())));
        assertEq(v.accountant(), freshAcctAddr);
        _step(string.concat("  accountant: ", vm.toString(v.accountant())));
        assertEq(v.treasury(), treasury);
        _step(string.concat("  treasury: ", vm.toString(v.treasury())));
        assertEq(v.redemptionFeeBps(), 100);
        _step(string.concat("  redemptionFeeBps: ", vm.toString(v.redemptionFeeBps())));
        assertEq(v.maxRedemptionFeeBps(), 500);
        _step(string.concat("  maxRedemptionFeeBps: ", vm.toString(v.maxRedemptionFeeBps())));
        assertEq(v.nextRequestId(), 1);
        _step(string.concat("  nextRequestId: ", vm.toString(v.nextRequestId())));
        assertEq(v.nextInFlightId(), 1);
        _step(string.concat("  nextInFlightId: ", vm.toString(v.nextInFlightId())));
        _step("  PASS: all default state correct");
        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  P1 — deployAndInitGateway default state check
    // ═══════════════════════════════════════════════════════════════

    function test_DeployAndInitGateway_DefaultState() public {
        _logCase("test_DeployAndInitGateway_DefaultState", unicode"`deployAndInitGateway` 后关键默认状态正确");

        _step("[Step 1] Call deployAndInitGateway with valid params");
        IMantleVaultGateway.InitParams memory params = IMantleVaultGateway.InitParams({
            vault: address(vault),
            sanctionsOracle: ISanctionsOracle(address(oracle)),
            sanctionSafe: sanctionSafe,
            admin: admin,
            syncRedeemDisabled: false
        });
        address gwAddr = gatewayFactory.deployAndInitGateway(params);
        IMantleVaultGateway g = IMantleVaultGateway(gwAddr);
        _step(string.concat("  gateway address: ", vm.toString(gwAddr)));

        _step("[Step 2] Verify key configuration and switches");
        assertEq(address(g.vault()), address(vault));
        _step(string.concat("  vault: ", vm.toString(address(g.vault()))));
        assertEq(address(g.sanctionsOracle()), address(oracle));
        _step(string.concat("  sanctionsOracle: ", vm.toString(address(g.sanctionsOracle()))));
        assertEq(g.sanctionSafe(), sanctionSafe);
        _step(string.concat("  sanctionSafe: ", vm.toString(g.sanctionSafe())));
        assertFalse(g.syncRedeemDisabled());
        _step(string.concat("  syncRedeemDisabled: ", vm.toString(g.syncRedeemDisabled())));
        assertFalse(g.whitelistEnabled());
        _step(string.concat("  whitelistEnabled: ", vm.toString(g.whitelistEnabled())));
        _step("  PASS: all default state correct");
        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  P1 — Uninitialized proxy race condition
    // ═══════════════════════════════════════════════════════════════

    function test_UninitializedProxy_RaceCondition() public {
        _logCase("test_UninitializedProxy_RaceCondition", unicode"未初始化代理若被抢初始化，控制权落入抢初始化者");

        _step("[Step 1] Deploy uninitialized vault proxy via deployVault()");
        address uninitVault = vaultFactory.deployVault();
        _step(string.concat("  uninit vault: ", vm.toString(uninitVault)));

        _step("[Step 2] Attacker front-runs initialization");
        address freshAcct = accountantFactory.deployAndInitAccountant(address(vault), 1e18, 100, attacker, attacker, attacker);
        address freshGw = gatewayFactory.deployGateway();

        IMantleYieldVault.InitParams memory params = IMantleYieldVault.InitParams({
            asset: IERC20(address(usdc)),
            name: "Hijacked",
            symbol: "HJK",
            admin: attacker,
            gateway: freshGw,
            controller: attacker,
            accountant: freshAcct,
            treasury: attacker,
            maxRedemptionFeeBps: 500,
            redemptionFeeBps: 100,
            minRedeemAmount: 1e6,
            minDepositAmount: 1e6,
            maxSettlementDeviationBps: 0,
            depositDailyRemaining: type(uint256).max,
            redeemDailyRemaining: type(uint256).max
        });
        vm.prank(attacker);
        IMantleYieldVault(uninitVault).initialize(params);
        _step("  PASS: attacker successfully initialized the proxy");

        _step("[Step 3] Verify control belongs to attacker");
        assertEq(IMantleYieldVault(uninitVault).controller(), attacker);
        _step(string.concat("  controller: ", vm.toString(IMantleYieldVault(uninitVault).controller())));
        assertEq(IMantleYieldVault(uninitVault).treasury(), attacker);
        _step(string.concat("  treasury: ", vm.toString(IMantleYieldVault(uninitVault).treasury())));
        _step("  PASS: control and key config belong to attacker (risk documented)");

        _step("[Step 4] Deploy uninitialized gateway proxy via deployGateway()");
        address uninitGw = gatewayFactory.deployGateway();
        _step(string.concat("  uninit gateway: ", vm.toString(uninitGw)));

        _step("[Step 5] Attacker front-runs gateway initialization");
        IMantleVaultGateway.InitParams memory gParams = IMantleVaultGateway.InitParams({
            vault: address(vault),
            sanctionsOracle: ISanctionsOracle(address(oracle)),
            sanctionSafe: attacker,
            admin: attacker,
            syncRedeemDisabled: false
        });
        vm.prank(attacker);
        IMantleVaultGateway(uninitGw).initialize(gParams);
        _step("  PASS: attacker successfully initialized the gateway proxy");

        _step("[Step 6] Verify gateway control belongs to attacker");
        assertEq(IMantleVaultGateway(uninitGw).sanctionSafe(), attacker);
        _step(string.concat("  sanctionSafe: ", vm.toString(IMantleVaultGateway(uninitGw).sanctionSafe())));
        _step("  PASS: gateway control belongs to attacker (risk documented)");
        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  P1 — Factory proxy view functions after init
    // ═══════════════════════════════════════════════════════════════

    function test_FactoryProxy_ViewFunctionsAfterInit() public {
        _logCase("test_FactoryProxy_ViewFunctionsAfterInit", unicode"Factory 部署的代理初始化后可立即正常读取关键 view");

        _step("[Step 1] Read Vault key views");
        assertEq(address(vault.asset()), address(usdc));
        _step(string.concat("  vault.asset(): ", vm.toString(address(vault.asset()))));
        assertEq(vault.controller(), controller);
        _step(string.concat("  vault.controller(): ", vm.toString(vault.controller())));
        assertEq(vault.accountant(), address(acct));
        _step(string.concat("  vault.accountant(): ", vm.toString(vault.accountant())));
        assertEq(vault.treasury(), treasury);
        _step(string.concat("  vault.treasury(): ", vm.toString(vault.treasury())));
        assertEq(vault.gateway(), address(gw));
        _step(string.concat("  vault.gateway(): ", vm.toString(vault.gateway())));
        _step("  PASS: Vault key views readable and correct");

        _step("[Step 2] Read Gateway key views");
        assertEq(address(gw.vault()), address(vault));
        _step(string.concat("  gw.vault(): ", vm.toString(address(gw.vault()))));
        assertEq(address(gw.sanctionsOracle()), address(oracle));
        _step(string.concat("  gw.sanctionsOracle(): ", vm.toString(address(gw.sanctionsOracle()))));
        assertEq(gw.sanctionSafe(), sanctionSafe);
        _step(string.concat("  gw.sanctionSafe(): ", vm.toString(gw.sanctionSafe())));
        _step("  PASS: Gateway key views readable and correct");

        _step("[Step 3] Read Accountant key views");
        assertEq(acct.lastExchangeRate(), 1e18);
        _step(string.concat("  acct.lastExchangeRate(): ", vm.toString(acct.lastExchangeRate())));
        assertEq(acct.managementFeeRate(), 100);
        _step(string.concat("  acct.managementFeeRate(): ", vm.toString(uint256(acct.managementFeeRate()))));
        _step("  PASS: Accountant key views readable and correct");
        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Settlement Deviation — Init validation
    // ═══════════════════════════════════════════════════════════════

    function test_VaultInit_RejectExcessiveSettlementDeviation() public {
        _logCase(
            "test_VaultInit_RejectExcessiveSettlementDeviation",
            unicode"`maxSettlementDeviationBps` 超过 `MAX_SETTLEMENT_DEVIATION_CEILING` 时初始化失败"
        );

        _step("[Step 1] Deploy fresh vault proxy");
        address uninitVault = vaultFactory.deployVault();

        _step("[Step 2] Attempt init with maxSettlementDeviationBps = 3001 (> ceiling 3000)");
        IMantleYieldVault.InitParams memory p = _freshVaultParams();
        p.maxSettlementDeviationBps = 3001;
        vm.expectRevert(abi.encodeWithSelector(IMantleYieldVault.Vault__InvalidSettlementDeviation.selector, 3001));
        IMantleYieldVault(uninitVault).initialize(p);
        _step("  PASS: reverted with Vault__InvalidSettlementDeviation(3001)");
        _logPass();
    }

    function test_VaultInit_SettlementDeviationZero() public {
        _logCase(
            "test_VaultInit_SettlementDeviationZero",
            unicode"`maxSettlementDeviationBps = 0` 初始化成功（防护关闭模式）"
        );

        _step("[Step 1] Deploy and init vault with maxSettlementDeviationBps = 0");
        address uninitVault = vaultFactory.deployVault();
        IMantleYieldVault.InitParams memory p = _freshVaultParams();
        p.maxSettlementDeviationBps = 0;
        IMantleYieldVault(uninitVault).initialize(p);

        _step("[Step 2] Verify stored value");
        assertEq(IMantleYieldVault(uninitVault).maxSettlementDeviationBps(), 0);
        _step("  PASS: maxSettlementDeviationBps == 0 (guard disabled)");
        _logPass();
    }

    function test_VaultInit_SettlementDeviationAtCeiling() public {
        _logCase(
            "test_VaultInit_SettlementDeviationAtCeiling",
            unicode"`maxSettlementDeviationBps = 3000`（上限值）初始化成功"
        );

        _step("[Step 1] Deploy and init vault with maxSettlementDeviationBps = 3000");
        address uninitVault = vaultFactory.deployVault();
        IMantleYieldVault.InitParams memory p = _freshVaultParams();
        p.maxSettlementDeviationBps = 3000;
        IMantleYieldVault(uninitVault).initialize(p);

        _step("[Step 2] Verify stored value");
        assertEq(IMantleYieldVault(uninitVault).maxSettlementDeviationBps(), 3000);
        _step("  PASS: maxSettlementDeviationBps == 3000 (ceiling)");
        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Daily Cap — Init validation (N-88, N-89)
    // ═══════════════════════════════════════════════════════════════

    function test_VaultInit_DepositDailyRemaining_Zero() public {
        _logCase(
            "test_VaultInit_DepositDailyRemaining_Zero",
            unicode"`depositDailyRemaining = 0` 初始化成功（存款封锁模式）"
        );

        _step("[Step 1] Deploy and init vault with depositDailyRemaining = 0");
        address uninitVault = vaultFactory.deployVault();
        IMantleYieldVault.InitParams memory p = _freshVaultParams();
        p.depositDailyRemaining = 0;
        IMantleYieldVault(uninitVault).initialize(p);

        _step("[Step 2] Verify stored value");
        assertEq(IMantleYieldVault(uninitVault).depositDailyRemaining(), 0, "should be 0");
        _step("  depositDailyRemaining == 0");

        _step("[Step 3] Verify maxDeposit returns 0 (deposit blocked)");
        address someUser = makeAddr("someUser");
        assertEq(IMantleYieldVault(uninitVault).maxDeposit(someUser), 0, "maxDeposit should be 0");
        _step("  maxDeposit(user) == 0 (deposit blocked)");

        _step("[Step 4] Verify deposit attempt reverts");
        uint256 depositAmt = 1e6;
        usdc.mint(someUser, depositAmt);
        vm.prank(someUser);
        usdc.approve(uninitVault, depositAmt);
        vm.prank(address(gw));
        vm.expectRevert(abi.encodeWithSelector(IMantleYieldVault.Vault__DepositDailyCapExceeded.selector, depositAmt, 0));
        IMantleYieldVault(uninitVault).deposit(depositAmt, someUser);
        _step("  deposit reverted with Vault__DepositDailyCapExceeded");

        _step("  PASS: deposit lockdown mode initialized successfully");
        _logPass();
    }

    function test_VaultInit_DepositDailyRemaining_Unlimited() public {
        _logCase(
            "test_VaultInit_DepositDailyRemaining_Unlimited",
            unicode"`depositDailyRemaining = type(uint256).max` 初始化成功（无限额模式）"
        );

        _step("[Step 1] Deploy and init vault with depositDailyRemaining = type(uint256).max");
        address uninitVault = vaultFactory.deployVault();
        IMantleYieldVault.InitParams memory p = _freshVaultParams();
        p.depositDailyRemaining = type(uint256).max;
        IMantleYieldVault(uninitVault).initialize(p);

        _step("[Step 2] Verify stored value");
        assertEq(
            IMantleYieldVault(uninitVault).depositDailyRemaining(),
            type(uint256).max,
            "should be type(uint256).max"
        );
        _step("  depositDailyRemaining == type(uint256).max");
        _step("  PASS: unlimited mode initialized successfully");
        _logPass();
    }
}
