// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SanctionsOracle} from "../../src/compliance/SanctionsOracle.sol";
import {SanctionsOracleFactory} from "../../src/compliance/SanctionsOracleFactory.sol";
import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {IMantleVaultGateway} from "../../src/interfaces/vault/IMantleVaultGateway.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {GatewayFactory} from "../../src/vault/GatewayFactory.sol";
import {MantleVaultGateway} from "../../src/vault/MantleVaultGateway.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {VaultFactory} from "../../src/vault/VaultFactory.sol";
import {Accountant} from "../../src/accountant/Accountant.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IAccessControlDefaultAdminRules} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test, console2} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";

// ---------------------------------------------------------------------------
// Mock contracts
// ---------------------------------------------------------------------------

contract MockUSDC_Role is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockERC20_Role is ERC20 {
    constructor() ERC20("Mock Token", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// ---------------------------------------------------------------------------
// QA Test: Role & Permission Scenarios (from role.xlsx)
// ---------------------------------------------------------------------------

contract RoleQATest is Test {
    MockUSDC_Role internal usdc;
    MockERC20_Role internal mockToken;
    SanctionsOracle internal oracle;
    Accountant internal accountant;

    MantleYieldVault internal vault;
    MantleVaultGateway internal gateway;
    VaultFactory internal vaultFactory;
    GatewayFactory internal gatewayFactory;

    address internal admin = makeAddr("admin");
    address internal complianceBot = makeAddr("complianceBot");
    address internal pauser = makeAddr("pauser");
    address internal controllerAddr = makeAddr("controller");
    address internal treasuryAddr = makeAddr("treasury");
    address internal sanctionSafe = makeAddr("sanctionSafe");
    address internal userA = makeAddr("userA");
    address internal nobody = makeAddr("nobody");

    uint256 constant DEPOSIT = 10_000e6;
    uint256 constant FEE_BPS = 100; // 1%
    uint256 constant MAX_FEE_BPS = 500; // 5%

    function setUp() public {
        usdc = new MockUSDC_Role();
        mockToken = new MockERC20_Role();

        SanctionsOracle oracleImpl = new SanctionsOracle();
        SanctionsOracleFactory oracleFactory = new SanctionsOracleFactory(address(oracleImpl), admin);
        vm.prank(admin);
        oracle = SanctionsOracle(oracleFactory.deployAndInitOracle(admin, complianceBot));

        MantleYieldVault impl = new MantleYieldVault();
        MantleVaultGateway gwImpl = new MantleVaultGateway();
        vaultFactory = new VaultFactory(address(impl), admin);
        gatewayFactory = new GatewayFactory(address(gwImpl), admin);

        address vaultAddr = vaultFactory.deployVault();
        address gwAddr = gatewayFactory.deployGateway();
        vault = MantleYieldVault(vaultAddr);
        gateway = MantleVaultGateway(gwAddr);

        accountant = _deployRealAccountantWithRate(1e18);

        vm.prank(admin);
        vault.initialize(
            IMantleYieldVault.InitParams({
                asset: IERC20(address(usdc)),
                name: "Mantle RWA Vault",
                symbol: "mRWA",
                admin: admin,
                gateway: gwAddr,
                controller: controllerAddr,
                accountant: address(accountant),
                treasury: treasuryAddr,
                maxRedemptionFeeBps: MAX_FEE_BPS,
                redemptionFeeBps: FEE_BPS,
                minRedeemAmount: 1e6,
                minDepositAmount: 1e6,
                maxSettlementDeviationBps: 0,
                depositDailyRemaining: type(uint256).max,
                redeemDailyRemaining: type(uint256).max
            })
        );

        vm.prank(admin);
        gateway.initialize(
            IMantleVaultGateway.InitParams({
                vault: vaultAddr,
                sanctionsOracle: ISanctionsOracle(address(oracle)),
                sanctionSafe: sanctionSafe,
                admin: admin,
                syncRedeemDisabled: false
            })
        );

        // Grant PAUSER_ROLE on Vault
        bytes32 pauserRole = vault.PAUSER_ROLE();
        vm.prank(admin);
        vault.grantRole(pauserRole, pauser);

        // Seed userA with shares
        _depositForUser(userA, DEPOSIT);
    }

    // ── helpers ──

    function _depositForUser(address user, uint256 amount) internal {
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(vault), type(uint256).max);
        gateway.deposit(amount);
        vm.stopPrank();
    }

    function _hasEvent(VmSafe.Log[] memory logs, bytes32 sig) internal pure returns (bool) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) return true;
        }
        return false;
    }

    function _deployRealAccountant() internal returns (Accountant) {
        Accountant acctImpl = new Accountant();
        bytes memory data =
            abi.encodeCall(Accountant.initialize, (address(vault), uint64(1e18), uint32(0), admin));
        return Accountant(address(new ERC1967Proxy(address(acctImpl), data)));
    }

    function _deployRealAccountantWithRate(uint64 initialRate) internal returns (Accountant) {
        Accountant acctImpl = new Accountant();
        bytes memory data =
            abi.encodeCall(Accountant.initialize, (address(vault), initialRate, uint32(0), admin));
        return Accountant(address(new ERC1967Proxy(address(acctImpl), data)));
    }

    function _setWhitelisted(address user, bool status) internal {
        vm.prank(complianceBot);
        oracle.updateWhitelistStatus(user, status);
    }

    function _setSanctioned(address user, bool status) internal {
        vm.prank(complianceBot);
        oracle.updateSanctionStatus(user, status);
    }

    // -----------------------------------------------------------------------
    // Logging helpers
    // -----------------------------------------------------------------------

    string constant MODULE = unicode"管理员与权限场景";
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

    function _step(string memory msg_) internal {
        console2.log(msg_);
        _buf = string.concat(_buf, msg_, "\n");
    }

    function _logPass() internal {
        _step("----------------------------------------");
        _step("test result: passed");
    }

    // ================================================================
    // Case 01 – 只有 admin 可调整赎回费
    // ================================================================

    function test_Case01_OnlyAdminCanSetRedemptionFee() public {
        _logCase("Case-01", unicode"只有 admin 可调整赎回费");

        _step("[Step 1] non-admin (nobody) calls setRedemptionFee(200)");
        _step(string.concat("  caller = ", vm.toString(nobody)));
        bytes32 vAdminRole = vault.DEFAULT_ADMIN_ROLE();
        vm.prank(nobody);
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, nobody, vAdminRole
        ));
        vault.setRedemptionFee(200);
        _step("  reverted as expected (non-admin denied)");

        _step("[Step 2] admin calls setRedemptionFee(200)");
        _step(string.concat("  caller = ", vm.toString(admin)));
        vm.prank(admin);
        vault.setRedemptionFee(200);
        uint256 newFee = vault.redemptionFeeBps();
        assertEq(newFee, 200);
        _step(string.concat("  redemptionFeeBps = ", vm.toString(newFee)));
        _step("  PASS: only admin can set redemption fee");

        _logPass();
    }

    // ================================================================
    // Case 02 – 新赎回费超过 maxRedemptionFeeBps 时被拒绝
    // ================================================================

    function test_Case02_FeeExceedsMaxRejected() public {
        _logCase("Case-02", unicode"新赎回费超过 maxRedemptionFeeBps 时被拒绝");

        uint256 overMax = MAX_FEE_BPS + 1;
        _step(string.concat("[Step 1] current maxRedemptionFeeBps = ", vm.toString(MAX_FEE_BPS)));
        _step(string.concat("[Step 2] admin calls setRedemptionFee(", vm.toString(overMax), ")"));
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IMantleYieldVault.Vault__FeeTooHigh.selector, overMax, MAX_FEE_BPS)
        );
        vault.setRedemptionFee(overMax);
        _step("  reverted with Vault__FeeTooHigh");
        _step("  PASS: fee exceeding max is rejected");

        _logPass();
    }

    // ================================================================
    // Case 03 – 调低 maxRedemptionFeeBps 小于当前费率时自动下调当前费率
    // ================================================================

    function test_Case03_LowerMaxAutoAdjustsFee() public {
        _logCase("Case-03", unicode"调低 maxRedemptionFeeBps 小于当前费率时自动下调当前费率");

        _step(string.concat("[Step 1] current redemptionFeeBps = ", vm.toString(vault.redemptionFeeBps())));
        _step(string.concat("  current maxRedemptionFeeBps = ", vm.toString(vault.maxRedemptionFeeBps())));

        uint256 newMax = 50;
        _step(string.concat("[Step 2] admin calls setMaxRedemptionFee(", vm.toString(newMax), ")"));
        vm.prank(admin);
        vault.setMaxRedemptionFee(newMax);

        uint256 actualMax = vault.maxRedemptionFeeBps();
        uint256 actualFee = vault.redemptionFeeBps();
        _step(string.concat("[Step 3] verify maxRedemptionFeeBps = ", vm.toString(actualMax)));
        _step(string.concat("  verify redemptionFeeBps = ", vm.toString(actualFee)));
        assertEq(actualMax, newMax);
        assertEq(actualFee, newMax, "fee should auto-converge to new max");
        _step("  PASS: fee auto-adjusted to new max");

        _logPass();
    }

    // ================================================================
    // Case 04 – 有 locked shares 时改 fee 触发额外提示事件
    // ================================================================

    function test_Case04_FeeChangeWithLockedSharesEvent() public {
        _logCase("Case-04", unicode"有 locked shares 时改 fee 触发额外提示事件");

        _step("[Step 1] userA requests async redeem to create locked shares");
        vm.prank(userA);
        gateway.requestRedeem(1000e6);
        uint256 locked = vault.totalLockedShares();
        assertTrue(locked > 0, "should have locked shares");
        _step(string.concat("  totalLockedShares = ", vm.toString(locked)));

        _step("[Step 2] admin calls setRedemptionFee(200) and verify events");
        vm.recordLogs();
        vm.prank(admin);
        vault.setRedemptionFee(200);
        VmSafe.Log[] memory logs = vm.getRecordedLogs();

        bool hasFeeUpdated = _hasEvent(logs, keccak256("RedemptionFeeUpdated(uint256,uint256)"));
        bool hasLockedWarning = _hasEvent(logs, keccak256("FeeChangedWithLockedShares(uint256,uint256,uint256)"));
        _step(string.concat("  RedemptionFeeUpdated emitted = ", hasFeeUpdated ? "true" : "false"));
        _step(string.concat("  FeeChangedWithLockedShares emitted = ", hasLockedWarning ? "true" : "false"));
        assertTrue(hasFeeUpdated, "RedemptionFeeUpdated not emitted");
        assertTrue(hasLockedWarning, "FeeChangedWithLockedShares not emitted");
        _step("  PASS: both events emitted when changing fee with locked shares");

        _logPass();
    }

    // ================================================================
    // Case 05 – 只有 accountant 可调用 mintFeeShares
    // ================================================================

    function test_Case05_OnlyAccountantCanMintFeeShares() public {
        _logCase("Case-05", unicode"只有 accountant 可调用 mintFeeShares");

        _step("[Step 1] non-accountant (nobody) calls mintFeeShares(100e18)");
        _step(string.concat("  caller = ", vm.toString(nobody)));
        vm.prank(nobody);
        vm.expectRevert(IMantleYieldVault.Vault__OnlyAccountant.selector);
        vault.mintFeeShares(100e18);
        _step("  reverted as expected");

        _step("[Step 2] accountant calls mintFeeShares(100e18)");
        uint256 treasuryBefore = vault.balanceOf(treasuryAddr);
        _step(string.concat("  treasury shares before = ", vm.toString(treasuryBefore)));
        vm.prank(address(accountant));
        vault.mintFeeShares(100e18);
        uint256 treasuryAfter = vault.balanceOf(treasuryAddr);
        _step(string.concat("  treasury shares after = ", vm.toString(treasuryAfter)));
        assertEq(treasuryAfter, treasuryBefore + 100e18);
        _step("  PASS: only accountant can mint fee shares, minted to treasury");

        _logPass();
    }

    // ================================================================
    // Case 06 – 只有 pauser 可 pause，只有 admin 可 unpause
    // ================================================================

    function test_Case06_PauseUnpauseRoles() public {
        _logCase("Case-06", unicode"只有 pauser 可 pause，只有 admin 可 unpause");

        // ── Vault ──
        _step("[Step 1] nobody calls vault.pause() -> revert");
        bytes32 vPauserRole = vault.PAUSER_ROLE();
        vm.prank(nobody);
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, nobody, vPauserRole
        ));
        vault.pause();
        _step("  reverted (non-pauser denied)");

        _step("[Step 2] pauser calls vault.pause()");
        vm.prank(pauser);
        vault.pause();
        _step(string.concat("  vault.paused() = ", vault.paused() ? "true" : "false"));
        assertTrue(vault.paused());

        _step("[Step 3] nobody calls vault.unpause() -> revert");
        vm.prank(nobody);
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, nobody, bytes32(0)
        ));
        vault.unpause();
        _step("  reverted (non-admin denied)");

        _step("[Step 4] admin calls vault.unpause()");
        vm.prank(admin);
        vault.unpause();
        _step(string.concat("  vault.paused() = ", vault.paused() ? "true" : "false"));
        assertFalse(vault.paused());

        // ── Accountant (real deploy to test roles) ──
        _step("[Step 5] deploy real Accountant for pause/unpause test");
        Accountant acct = _deployRealAccountant();
        _step(string.concat("  accountant addr = ", vm.toString(address(acct))));
        bytes32 acctPauserRole = acct.PAUSER_ROLE();
        bytes32 acctAdminRole = acct.DEFAULT_ADMIN_ROLE();

        _step("[Step 6] nobody calls acct.pause() -> revert");
        vm.prank(nobody);
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, nobody, acctPauserRole
        ));
        acct.pause();
        _step("  reverted (non-pauser denied)");

        _step("[Step 7] admin calls acct.pause()");
        vm.prank(admin);
        acct.pause();
        _step(string.concat("  acct.paused() = ", acct.paused() ? "true" : "false"));
        assertTrue(acct.paused());

        _step("[Step 8] nobody calls acct.unpause() -> revert");
        vm.prank(nobody);
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, nobody, acctAdminRole
        ));
        acct.unpause();
        _step("  reverted (non-admin denied)");

        _step("[Step 9] admin calls acct.unpause()");
        vm.prank(admin);
        acct.unpause();
        _step(string.concat("  acct.paused() = ", acct.paused() ? "true" : "false"));
        assertFalse(acct.paused());
        _step("  PASS: pause/unpause role enforcement verified for Vault and Accountant");

        _logPass();
    }

    // ================================================================
    // Case 07 – rescueTokens 禁止救援底层资产
    // ================================================================

    function test_Case07_RescueTokensRejectsUnderlying() public {
        _logCase("Case-07", unicode"rescueTokens 禁止救援底层资产");

        _step("[Step 1] admin calls rescueTokens(usdc, admin, 1e6)");
        _step(string.concat("  underlying asset = ", vm.toString(address(usdc))));
        vm.prank(admin);
        vm.expectRevert(IMantleYieldVault.Vault__RescueAssetCannotBeUnderlying.selector);
        vault.rescueTokens(address(usdc), admin, 1e6);
        _step("  reverted with Vault__RescueAssetCannotBeUnderlying");
        _step("  PASS: rescue of underlying asset is blocked");

        _logPass();
    }

    // ================================================================
    // Case 08 – rescueTokens 可救援非底层资产
    // ================================================================

    function test_Case08_RescueTokensNonUnderlying() public {
        _logCase("Case-08", unicode"rescueTokens 可救援非底层资产");

        _step("[Step 1] mint 1000e18 mockToken to vault");
        mockToken.mint(address(vault), 1000e18);
        _step(string.concat("  vault mockToken balance = ", vm.toString(mockToken.balanceOf(address(vault)))));

        _step("[Step 2] admin calls rescueTokens(mockToken, admin, 1000e18)");
        vm.recordLogs();
        vm.prank(admin);
        vault.rescueTokens(address(mockToken), admin, 1000e18);
        VmSafe.Log[] memory logs = vm.getRecordedLogs();

        uint256 adminBal = mockToken.balanceOf(admin);
        uint256 vaultBal = mockToken.balanceOf(address(vault));
        _step(string.concat("[Step 3] admin mockToken balance = ", vm.toString(adminBal)));
        _step(string.concat("  vault mockToken balance = ", vm.toString(vaultBal)));
        assertEq(adminBal, 1000e18, "tokens should be rescued");
        assertEq(vaultBal, 0);

        bool hasEvent = _hasEvent(logs, keccak256("TokenRescued(address,address,uint256)"));
        _step(string.concat("  TokenRescued emitted = ", hasEvent ? "true" : "false"));
        assertTrue(hasEvent, "event not emitted");
        _step("  PASS: non-underlying token rescued successfully");

        _logPass();
    }

    // ================================================================
    // Case 09 – 更新 gateway/controller/accountant/treasury 地址时拒绝零地址
    // ================================================================

    function test_Case09_ZeroAddressRejected() public {
        _logCase("Case-09", unicode"更新 gateway/controller/accountant/treasury 地址时拒绝零地址");

        vm.startPrank(admin);

        _step("[Step 1] setGateway(address(0)) -> revert");
        vm.expectRevert(IMantleYieldVault.Vault__ZeroAddress.selector);
        vault.setGateway(address(0));
        _step("  reverted with Vault__ZeroAddress");

        _step("[Step 2] setController(address(0)) -> revert");
        vm.expectRevert(IMantleYieldVault.Vault__ZeroAddress.selector);
        vault.setController(address(0));
        _step("  reverted with Vault__ZeroAddress");

        _step("[Step 3] setAccountant(address(0)) -> revert");
        vm.expectRevert(IMantleYieldVault.Vault__ZeroAddress.selector);
        vault.setAccountant(address(0));
        _step("  reverted with Vault__ZeroAddress");

        _step("[Step 4] setTreasury(address(0)) -> revert");
        vm.expectRevert(IMantleYieldVault.Vault__ZeroAddress.selector);
        vault.setTreasury(address(0));
        _step("  reverted with Vault__ZeroAddress");

        vm.stopPrank();
        _step("  PASS: all four setters reject zero address");

        _logPass();
    }

    // ================================================================
    // Case 10 – Gateway admin 转移遵循 3 天延迟机制
    // ================================================================

    function test_Case10_GatewayAdminTransferDelay() public {
        _logCase("Case-10", unicode"Gateway admin 转移遵循 3 天延迟机制");

        address newAdmin = makeAddr("newAdmin");
        _step(string.concat("[Step 1] admin begins transfer to newAdmin = ", vm.toString(newAdmin)));
        vm.prank(admin);
        gateway.beginDefaultAdminTransfer(newAdmin);
        _step("  beginDefaultAdminTransfer called");

        _step("[Step 2] newAdmin tries to accept immediately -> revert");
        (, uint48 gwSchedule) = gateway.pendingDefaultAdmin();
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminDelay.selector, gwSchedule
        ));
        vm.prank(newAdmin);
        gateway.acceptDefaultAdminTransfer();
        _step("  reverted (delay not elapsed)");

        _step("[Step 3] warp 3 days + 1 second");
        vm.warp(block.timestamp + 3 days + 1);
        _step(string.concat("  block.timestamp = ", vm.toString(block.timestamp)));

        _step("[Step 4] newAdmin accepts transfer");
        vm.prank(newAdmin);
        gateway.acceptDefaultAdminTransfer();

        address currentAdmin = gateway.defaultAdmin();
        _step(string.concat("  gateway.defaultAdmin() = ", vm.toString(currentAdmin)));
        assertEq(currentAdmin, newAdmin);

        bytes32 defaultAdminRole = gateway.DEFAULT_ADMIN_ROLE();
        bool oldHasRole = gateway.hasRole(defaultAdminRole, admin);
        _step(string.concat("  old admin still has role = ", oldHasRole ? "true" : "false"));
        assertFalse(oldHasRole);
        _step("  PASS: gateway admin transfer follows 3-day delay");

        _logPass();
    }

    // ================================================================
    // Case 11 – Vault admin 转移同样遵循 3 天延迟机制
    // ================================================================

    function test_Case11_VaultAdminTransferDelay() public {
        _logCase("Case-11", unicode"Vault admin 转移同样遵循 3 天延迟机制");

        address newAdmin = makeAddr("newAdmin");
        _step(string.concat("[Step 1] admin begins vault admin transfer to newAdmin = ", vm.toString(newAdmin)));
        vm.prank(admin);
        vault.beginDefaultAdminTransfer(newAdmin);
        _step("  beginDefaultAdminTransfer called");

        _step("[Step 2] newAdmin tries to accept immediately -> revert");
        (, uint48 vaultSchedule) = vault.pendingDefaultAdmin();
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminDelay.selector, vaultSchedule
        ));
        vm.prank(newAdmin);
        vault.acceptDefaultAdminTransfer();
        _step("  reverted (delay not elapsed)");

        _step("[Step 3] warp 3 days + 1 second");
        vm.warp(block.timestamp + 3 days + 1);
        _step(string.concat("  block.timestamp = ", vm.toString(block.timestamp)));

        _step("[Step 4] newAdmin accepts transfer");
        vm.prank(newAdmin);
        vault.acceptDefaultAdminTransfer();

        address currentAdmin = vault.defaultAdmin();
        _step(string.concat("  vault.defaultAdmin() = ", vm.toString(currentAdmin)));
        assertEq(currentAdmin, newAdmin);

        bytes32 defaultAdminRole = vault.DEFAULT_ADMIN_ROLE();
        bool oldHasRole = vault.hasRole(defaultAdminRole, admin);
        bool newHasRole = vault.hasRole(defaultAdminRole, newAdmin);
        _step(string.concat("  old admin has role = ", oldHasRole ? "true" : "false"));
        _step(string.concat("  new admin has role = ", newHasRole ? "true" : "false"));
        assertFalse(oldHasRole);
        assertTrue(newHasRole);
        _step("  PASS: vault admin transfer follows 3-day delay");

        _logPass();
    }

    // ================================================================
    // Case 12 – Gateway setSanctionsOracle 更换 Oracle
    // ================================================================

    function test_Case12_SetSanctionsOracle() public {
        _logCase("Case-12", unicode"Gateway setSanctionsOracle 更换 Oracle");

        address oracleB = makeAddr("oracleB");
        _step(string.concat("[Step 1] current oracle = ", vm.toString(address(gateway.sanctionsOracle()))));

        _step("[Step 2] admin calls setSanctionsOracle(address(0)) -> revert");
        vm.prank(admin);
        vm.expectRevert(IMantleYieldVault.Vault__ZeroAddress.selector);
        gateway.setSanctionsOracle(address(0));
        _step("  reverted with Vault__ZeroAddress");

        _step(string.concat("[Step 3] admin calls setSanctionsOracle(", vm.toString(oracleB), ")"));
        vm.recordLogs();
        vm.prank(admin);
        gateway.setSanctionsOracle(oracleB);
        VmSafe.Log[] memory logs = vm.getRecordedLogs();

        address newOracle = address(gateway.sanctionsOracle());
        _step(string.concat("  gateway.sanctionsOracle() = ", vm.toString(newOracle)));
        assertEq(newOracle, oracleB);

        bool hasEvent = _hasEvent(logs, keccak256("SanctionsOracleUpdated(address,address)"));
        _step(string.concat("  SanctionsOracleUpdated emitted = ", hasEvent ? "true" : "false"));
        assertTrue(hasEvent);
        _step("  PASS: sanctions oracle updated with event");

        _logPass();
    }

    // ================================================================
    // Case 13 – Gateway setSanctionSafe 更换制裁安全地址
    // ================================================================

    function test_Case13_SetSanctionSafe() public {
        _logCase("Case-13", unicode"Gateway setSanctionSafe 更换制裁安全地址");

        address safeB = makeAddr("safeB");
        _step(string.concat("[Step 1] current sanctionSafe = ", vm.toString(gateway.sanctionSafe())));

        _step("[Step 2] admin calls setSanctionSafe(address(0)) -> revert");
        vm.prank(admin);
        vm.expectRevert(IMantleYieldVault.Vault__ZeroAddress.selector);
        gateway.setSanctionSafe(address(0));
        _step("  reverted with Vault__ZeroAddress");

        _step(string.concat("[Step 3] admin calls setSanctionSafe(", vm.toString(safeB), ")"));
        vm.recordLogs();
        vm.prank(admin);
        gateway.setSanctionSafe(safeB);
        VmSafe.Log[] memory logs = vm.getRecordedLogs();

        address newSafe = gateway.sanctionSafe();
        _step(string.concat("  gateway.sanctionSafe() = ", vm.toString(newSafe)));
        assertEq(newSafe, safeB);

        bool hasEvent = _hasEvent(logs, keccak256("SanctionSafeUpdated(address,address)"));
        _step(string.concat("  SanctionSafeUpdated emitted = ", hasEvent ? "true" : "false"));
        assertTrue(hasEvent);
        _step("  PASS: sanction safe updated with event");

        _logPass();
    }

    // ================================================================
    // Case 14 – Gateway setSyncRedeemDisabled 开关同步赎回
    // ================================================================

    function test_Case14_ToggleSyncRedeemDisabled() public {
        _logCase("Case-14", unicode"Gateway setSyncRedeemDisabled 开关同步赎回");

        _step(string.concat("[Step 1] current syncRedeemDisabled = ", gateway.syncRedeemDisabled() ? "true" : "false"));

        _step("[Step 2] admin disables sync redeem");
        vm.recordLogs();
        vm.prank(admin);
        gateway.setSyncRedeemDisabled(true);
        _step(string.concat("  syncRedeemDisabled = ", gateway.syncRedeemDisabled() ? "true" : "false"));
        assertTrue(gateway.syncRedeemDisabled());
        assertTrue(_hasEvent(vm.getRecordedLogs(), keccak256("SyncRedeemDisabledUpdated(bool)")));
        _step("  SyncRedeemDisabledUpdated emitted");

        _step("[Step 3] userA tries to redeem -> revert");
        vm.prank(userA);
        vm.expectRevert(IMantleYieldVault.Vault__SyncRedeemDisabled.selector);
        gateway.redeem(100e6);
        _step("  reverted with Vault__SyncRedeemDisabled");

        _step("[Step 4] admin re-enables sync redeem");
        vm.recordLogs();
        vm.prank(admin);
        gateway.setSyncRedeemDisabled(false);
        _step(string.concat("  syncRedeemDisabled = ", gateway.syncRedeemDisabled() ? "true" : "false"));
        assertFalse(gateway.syncRedeemDisabled());
        assertTrue(_hasEvent(vm.getRecordedLogs(), keccak256("SyncRedeemDisabledUpdated(bool)")));
        _step("  SyncRedeemDisabledUpdated emitted");

        _step("[Step 5] userA redeems successfully");
        vm.prank(userA);
        uint256 assets = gateway.redeem(100e6);
        _step(string.concat("  assets received = ", vm.toString(assets)));
        assertTrue(assets > 0, "redeem should succeed");
        _step("  PASS: sync redeem toggle works correctly");

        _logPass();
    }

    // ================================================================
    // Case 15 – Vault setGateway/setController/setAccountant/setTreasury 热切换
    // ================================================================

    function test_Case15_VaultHotSwap() public {
        _logCase("Case-15", unicode"Vault setGateway/setController/setAccountant/setTreasury 热切换");

        // ── setGateway ──
        _step("[Step 1] deploy and init new gateway");
        address newGwAddr = gatewayFactory.deployGateway();
        MantleVaultGateway newGw = MantleVaultGateway(newGwAddr);
        vm.prank(admin);
        newGw.initialize(
            IMantleVaultGateway.InitParams({
                vault: address(vault),
                sanctionsOracle: ISanctionsOracle(address(oracle)),
                sanctionSafe: sanctionSafe,
                admin: admin,
                syncRedeemDisabled: false
            })
        );
        _step(string.concat("  new gateway = ", vm.toString(newGwAddr)));

        _step("[Step 2] admin calls vault.setGateway(newGateway)");
        vm.recordLogs();
        vm.prank(admin);
        vault.setGateway(newGwAddr);
        bool hasGwEvent = _hasEvent(vm.getRecordedLogs(), keccak256("GatewayUpdated(address,address)"));
        _step(string.concat("  GatewayUpdated emitted = ", hasGwEvent ? "true" : "false"));
        assertTrue(hasGwEvent);

        _step("[Step 3] deposit through new gateway");
        usdc.mint(userA, 1000e6);
        vm.prank(userA);
        uint256 shares = newGw.deposit(1000e6);
        _step(string.concat("  shares = ", vm.toString(shares)));
        assertTrue(shares > 0, "deposit via new gateway should work");

        // ── setAccountant ──
        _step("[Step 4] deploy real accountant and update rate to 2e18 through real path");
        Accountant newAcct = _deployRealAccountant();
        vm.prank(admin);
        newAcct.emergencyRateUpdate(2e18);

        _step("[Step 5] admin calls vault.setAccountant(newAccountant)");
        vm.recordLogs();
        vm.prank(admin);
        vault.setAccountant(address(newAcct));
        bool hasAcctEvent = _hasEvent(vm.getRecordedLogs(), keccak256("AccountantUpdated(address,address)"));
        _step(string.concat("  AccountantUpdated emitted = ", hasAcctEvent ? "true" : "false"));
        assertTrue(hasAcctEvent);

        uint256 rate = vault.exchangeRate();
        _step(string.concat("[Step 6] vault.exchangeRate() = ", vm.toString(rate)));
        assertEq(rate, 2e18, "should use new accountant rate");
        _step("  PASS: hot swap of gateway and accountant verified");

        _logPass();
    }

    // ================================================================
    // Case 16 – 只有 admin 可调用 setWhitelistEnabled
    // ================================================================

    function test_Case16_OnlyAdminSetWhitelistEnabled() public {
        _logCase("Case-16", unicode"只有 admin 可调用 setWhitelistEnabled");

        _step("[Step 1] non-admin calls setWhitelistEnabled(true) -> revert");
        bytes32 gwDefaultAdmin = gateway.DEFAULT_ADMIN_ROLE();
        vm.prank(nobody);
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, nobody, gwDefaultAdmin
        ));
        gateway.setWhitelistEnabled(true);
        _step("  reverted (non-admin denied)");

        _step("[Step 2] admin enables whitelist");
        vm.recordLogs();
        vm.prank(admin);
        gateway.setWhitelistEnabled(true);
        _step(string.concat("  whitelistEnabled = ", gateway.whitelistEnabled() ? "true" : "false"));
        assertTrue(gateway.whitelistEnabled());
        assertTrue(_hasEvent(vm.getRecordedLogs(), keccak256("WhitelistEnabledUpdated(bool)")));
        _step("  WhitelistEnabledUpdated emitted");

        _step("[Step 3] admin disables whitelist");
        vm.recordLogs();
        vm.prank(admin);
        gateway.setWhitelistEnabled(false);
        _step(string.concat("  whitelistEnabled = ", gateway.whitelistEnabled() ? "true" : "false"));
        assertFalse(gateway.whitelistEnabled());
        assertTrue(_hasEvent(vm.getRecordedLogs(), keccak256("WhitelistEnabledUpdated(bool)")));
        _step("  WhitelistEnabledUpdated emitted");
        _step("  PASS: only admin can toggle whitelist");

        _logPass();
    }

    // ================================================================
    // Case 17 – whitelistEnabled=false 时，不校验 whitelist
    // ================================================================

    function test_Case17_WhitelistDisabledNoCheck() public {
        _logCase("Case-17", unicode"whitelistEnabled=false 时，不校验 whitelist");

        _step(string.concat("[Step 1] whitelistEnabled = ", gateway.whitelistEnabled() ? "true" : "false"));
        _step(
            string.concat("  userA whitelisted = ", oracle.isWhitelisted(userA) ? "true" : "false")
        );
        assertFalse(gateway.whitelistEnabled());
        assertFalse(oracle.isWhitelisted(userA));

        _step("[Step 2] userA deposits 1000e6");
        usdc.mint(userA, 1000e6);
        vm.startPrank(userA);
        uint256 shares = gateway.deposit(1000e6);
        _step(string.concat("  shares = ", vm.toString(shares)));
        assertTrue(shares > 0, "deposit should succeed");

        _step("[Step 3] userA sync redeems 100e6");
        uint256 assets = gateway.redeem(100e6);
        _step(string.concat("  assets = ", vm.toString(assets)));
        assertTrue(assets > 0, "redeem should succeed");

        _step("[Step 4] userA async requestRedeem 100e6");
        uint256 reqId = gateway.requestRedeem(100e6);
        _step(string.concat("  requestId = ", vm.toString(reqId)));
        assertTrue(reqId > 0, "requestRedeem should succeed");
        vm.stopPrank();
        _step("  PASS: all operations succeed without whitelist when whitelistEnabled=false");

        _logPass();
    }

    // ================================================================
    // Case 18 – whitelistEnabled=true 时，非白名单用户被拒绝
    // ================================================================

    function test_Case18_WhitelistEnabledNonWhitelistedRejected() public {
        _logCase("Case-18", unicode"whitelistEnabled=true 时，非白名单用户被拒绝");

        _step("[Step 1] admin enables whitelist");
        vm.prank(admin);
        gateway.setWhitelistEnabled(true);
        _step(string.concat("  whitelistEnabled = ", gateway.whitelistEnabled() ? "true" : "false"));
        _step(
            string.concat("  userA whitelisted = ", oracle.isWhitelisted(userA) ? "true" : "false")
        );
        assertFalse(oracle.isWhitelisted(userA));

        _step("[Step 2] userA deposit -> revert");
        usdc.mint(userA, 1000e6);
        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSelector(IMantleVaultGateway.Gateway__NotWhitelisted.selector, userA));
        gateway.deposit(1000e6);
        _step("  reverted with Gateway__NotWhitelisted");

        _step("[Step 3] userA redeem -> revert");
        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSelector(IMantleVaultGateway.Gateway__NotWhitelisted.selector, userA));
        gateway.redeem(100e6);
        _step("  reverted with Gateway__NotWhitelisted");

        _step("[Step 4] userA requestRedeem -> revert");
        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSelector(IMantleVaultGateway.Gateway__NotWhitelisted.selector, userA));
        gateway.requestRedeem(100e6);
        _step("  reverted with Gateway__NotWhitelisted");
        _step("  PASS: non-whitelisted user blocked on all operations");

        _logPass();
    }

    // ================================================================
    // Case 19 – whitelistEnabled=true 时，白名单用户可正常操作
    // ================================================================

    function test_Case19_WhitelistEnabledWhitelistedCanOperate() public {
        _logCase("Case-19", unicode"whitelistEnabled=true 时，白名单用户可正常操作");

        _step("[Step 1] admin enables whitelist and whitelists userA");
        vm.prank(admin);
        gateway.setWhitelistEnabled(true);
        _setWhitelisted(userA, true);
        _step(string.concat("  whitelistEnabled = ", gateway.whitelistEnabled() ? "true" : "false"));
        _step(
            string.concat("  userA whitelisted = ", oracle.isWhitelisted(userA) ? "true" : "false")
        );

        _step("[Step 2] userA deposits 1000e6");
        usdc.mint(userA, 1000e6);
        vm.startPrank(userA);
        uint256 shares = gateway.deposit(1000e6);
        _step(string.concat("  shares = ", vm.toString(shares)));
        assertTrue(shares > 0, "deposit should succeed");

        _step("[Step 3] userA sync redeems 100e6");
        uint256 assets = gateway.redeem(100e6);
        _step(string.concat("  assets = ", vm.toString(assets)));
        assertTrue(assets > 0, "redeem should succeed");

        _step("[Step 4] userA async requestRedeem 100e6");
        uint256 reqId = gateway.requestRedeem(100e6);
        _step(string.concat("  requestId = ", vm.toString(reqId)));
        assertTrue(reqId > 0, "requestRedeem should succeed");
        vm.stopPrank();
        _step("  PASS: whitelisted user can deposit/redeem/requestRedeem");

        _logPass();
    }

    // ================================================================
    // Case 20 – Accountant pause 后 Gateway deposit/redeem/requestRedeem 都被阻断
    // ================================================================

    function test_Case20_AccountantPauseBlocksGateway() public {
        _logCase("Case-20", unicode"Accountant pause 后 Gateway deposit/redeem/requestRedeem 都被阻断");

        _step("[Step 1] swap vault to a real accountant and pause it through the real role-gated path");
        Accountant acct = _deployRealAccountant();
        vm.prank(admin);
        vault.setAccountant(address(acct));
        vm.prank(admin);
        acct.pause();
        _step(string.concat("  accountant paused = ", acct.paused() ? "true" : "false"));

        _step("[Step 2] userA deposit -> revert");
        usdc.mint(userA, 1000e6);
        vm.prank(userA);
        vm.expectRevert(MantleVaultGateway.EnforcedPause.selector);
        gateway.deposit(1000e6);
        _step("  reverted with EnforcedPause");

        _step("[Step 3] userA redeem -> revert");
        vm.prank(userA);
        vm.expectRevert(MantleVaultGateway.EnforcedPause.selector);
        gateway.redeem(100e18);
        _step("  reverted with EnforcedPause");

        _step("[Step 4] userA requestRedeem -> revert");
        vm.prank(userA);
        vm.expectRevert(MantleVaultGateway.EnforcedPause.selector);
        gateway.requestRedeem(100e18);
        _step("  reverted with EnforcedPause");
        _step("  PASS: accountant pause blocks all gateway operations");

        _logPass();
    }

    // ================================================================
    // Case 21 – 被制裁用户 requestRedeem 时走 sanctionSafe 路由
    // ================================================================

    function test_Case21_SanctionedRequestRedeemRoutes() public {
        _logCase("Case-21", unicode"被制裁用户 requestRedeem 时走 sanctionSafe 路由");

        uint256 shares = vault.balanceOf(userA);
        _step(string.concat("[Step 1] userA shares = ", vm.toString(shares)));
        assertTrue(shares > 0, "userA should have shares");

        _step("[Step 2] mark userA as sanctioned");
        _setSanctioned(userA, true);
        _step(string.concat("  userA sanctioned = ", oracle.isSanctioned(userA) ? "true" : "false"));

        uint256 safeBefore = vault.balanceOf(sanctionSafe);
        _step(string.concat("[Step 3] sanctionSafe shares before = ", vm.toString(safeBefore)));

        _step("[Step 4] userA calls requestRedeem(shares)");
        vm.prank(userA);
        uint256 reqId = gateway.requestRedeem(shares);
        _step(string.concat("  returned reqId = ", vm.toString(reqId)));
        assertEq(reqId, 0, "should return 0");

        uint256 userSharesAfter = vault.balanceOf(userA);
        uint256 safeAfter = vault.balanceOf(sanctionSafe);
        _step(string.concat("[Step 5] userA shares after = ", vm.toString(userSharesAfter)));
        _step(string.concat("  sanctionSafe shares after = ", vm.toString(safeAfter)));
        assertEq(userSharesAfter, 0, "user shares should be 0");
        assertEq(safeAfter, shares, "shares should go to sanctionSafe");
        _step("  PASS: sanctioned user's shares routed to sanctionSafe");

        _logPass();
    }

    // ================================================================
    // Case 22 – 被制裁用户不能 deposit 或同步 redeem
    // ================================================================

    function test_Case22_SanctionedCannotDepositOrRedeem() public {
        _logCase("Case-22", unicode"被制裁用户不能 deposit 或同步 redeem");

        uint256 sharesBefore = vault.balanceOf(userA);
        _step(string.concat("[Step 1] userA shares = ", vm.toString(sharesBefore)));

        _step("[Step 2] mark userA as sanctioned");
        _setSanctioned(userA, true);
        _step(string.concat("  userA sanctioned = ", oracle.isSanctioned(userA) ? "true" : "false"));

        _step("[Step 3] userA deposit -> revert Vault__Sanctioned");
        usdc.mint(userA, 1000e6);
        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSelector(IMantleYieldVault.Vault__Sanctioned.selector, userA));
        gateway.deposit(1000e6);
        _step("  reverted with Vault__Sanctioned");

        _step("[Step 4] userA redeem -> routes shares to sanctionSafe (returns 0)");
        vm.prank(userA);
        uint256 assets = gateway.redeem(sharesBefore);
        _step(string.concat("  assets returned = ", vm.toString(assets)));
        assertEq(assets, 0, "sanctioned redeem returns 0");

        uint256 safeShares = vault.balanceOf(sanctionSafe);
        _step(string.concat("  sanctionSafe shares = ", vm.toString(safeShares)));
        assertEq(safeShares, sharesBefore, "shares routed to safe");
        _step("  PASS: sanctioned user blocked on deposit, shares routed on redeem");

        _logPass();
    }

    // ================================================================
    // Case 23 – 只有 Gateway 可调用 Vault 的 deposit/redeem/requestRedeem/routeSanctionedShares
    // ================================================================

    function test_Case23_OnlyGatewayCanCallVaultGatewayFunctions() public {
        _logCase("Case-23", unicode"只有 Gateway 可调用 Vault 的 deposit/redeem/requestRedeem/routeSanctionedShares");

        vm.startPrank(nobody);

        _step(string.concat("[Step 1] nobody calls vault.deposit() -> revert"));
        vm.expectRevert(IMantleYieldVault.Vault__OnlyGateway.selector);
        vault.deposit(1e6, nobody);
        _step("  reverted with Vault__OnlyGateway");

        _step("[Step 2] nobody calls vault.redeem() -> revert");
        vm.expectRevert(IMantleYieldVault.Vault__OnlyGateway.selector);
        vault.redeem(1e18, nobody, nobody);
        _step("  reverted with Vault__OnlyGateway");

        _step("[Step 3] nobody calls vault.requestRedeem() -> revert");
        vm.expectRevert(IMantleYieldVault.Vault__OnlyGateway.selector);
        vault.requestRedeem(nobody, 1e18);
        _step("  reverted with Vault__OnlyGateway");

        _step("[Step 4] nobody calls vault.routeSanctionedShares() -> revert");
        vm.expectRevert(IMantleYieldVault.Vault__OnlyGateway.selector);
        vault.routeSanctionedShares(nobody, 1e18);
        _step("  reverted with Vault__OnlyGateway");

        vm.stopPrank();
        _step("  PASS: all vault gateway functions restricted to gateway only");

        _logPass();
    }

    // ================================================================
    // Case 24 – 只有 Vault 可调用 Gateway 的 enforceShareTransfer/resolveRedemptionReceiver
    // ================================================================

    function test_Case24_OnlyVaultCanCallGatewayVaultFunctions() public {
        _logCase("Case-24", unicode"只有 Vault 可调用 Gateway 的 enforceShareTransfer/resolveRedemptionReceiver");

        vm.startPrank(nobody);

        _step("[Step 1] nobody calls gateway.enforceShareTransfer() -> revert");
        vm.expectRevert(IMantleYieldVault.Vault__NotAuthorized.selector);
        gateway.enforceShareTransfer(userA, userA);
        _step("  reverted with Vault__NotAuthorized");

        _step("[Step 2] nobody calls gateway.resolveRedemptionReceiver() -> revert");
        vm.expectRevert(IMantleYieldVault.Vault__NotAuthorized.selector);
        gateway.resolveRedemptionReceiver(userA);
        _step("  reverted with Vault__NotAuthorized");

        vm.stopPrank();
        _step("  PASS: gateway vault functions restricted to vault only");

        _logPass();
    }

    // ================================================================
    // Case 25 – 非 pending admin 不能 acceptDefaultAdminTransfer
    // ================================================================

    function test_Case25_NonPendingAdminCannotAccept() public {
        _logCase("Case-25", unicode"非 pending admin 不能 acceptDefaultAdminTransfer");

        address newAdmin = makeAddr("newAdmin");
        _step(string.concat("[Step 1] admin begins transfer to newAdmin = ", vm.toString(newAdmin)));
        vm.prank(admin);
        gateway.beginDefaultAdminTransfer(newAdmin);

        _step("[Step 2] warp 3 days + 1 second");
        vm.warp(block.timestamp + 3 days + 1);
        _step(string.concat("  block.timestamp = ", vm.toString(block.timestamp)));

        _step("[Step 3] nobody tries to accept -> revert");
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControlDefaultAdminRules.AccessControlInvalidDefaultAdmin.selector, nobody
        ));
        vm.prank(nobody);
        gateway.acceptDefaultAdminTransfer();
        _step("  reverted (not the pending admin)");

        _step("[Step 4] newAdmin accepts successfully");
        vm.prank(newAdmin);
        gateway.acceptDefaultAdminTransfer();
        address currentAdmin = gateway.defaultAdmin();
        _step(string.concat("  gateway.defaultAdmin() = ", vm.toString(currentAdmin)));
        assertEq(currentAdmin, newAdmin);
        _step("  PASS: only pending admin can accept transfer");

        _logPass();
    }

    // ================================================================
    // Case 26 – admin transfer 生效前，旧 admin 仍拥有完整 admin 权限
    // ================================================================

    function test_Case26_OldAdminRetainsRightsDuringDelay() public {
        _logCase("Case-26", unicode"admin transfer 生效前，旧 admin 仍拥有完整 admin 权限");

        address newAdmin = makeAddr("newAdmin");
        _step(string.concat("[Step 1] admin begins transfer to newAdmin = ", vm.toString(newAdmin)));
        vm.prank(admin);
        gateway.beginDefaultAdminTransfer(newAdmin);

        _step("[Step 2] old admin can still call admin-only functions during delay");
        vm.prank(admin);
        gateway.setSyncRedeemDisabled(true);
        _step(string.concat("  syncRedeemDisabled = ", gateway.syncRedeemDisabled() ? "true" : "false"));
        assertTrue(gateway.syncRedeemDisabled());

        _step("[Step 3] warp 3 days + 1 second, new admin accepts");
        vm.warp(block.timestamp + 3 days + 1);
        vm.prank(newAdmin);
        gateway.acceptDefaultAdminTransfer();
        _step(string.concat("  gateway.defaultAdmin() = ", vm.toString(gateway.defaultAdmin())));

        _step("[Step 4] old admin loses power -> revert");
        bytes32 gwAdminRole = gateway.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, admin, gwAdminRole
        ));
        gateway.setSyncRedeemDisabled(false);
        _step("  reverted (old admin no longer authorized)");

        _step("[Step 5] new admin has power");
        vm.prank(newAdmin);
        gateway.setSyncRedeemDisabled(false);
        _step(string.concat("  syncRedeemDisabled = ", gateway.syncRedeemDisabled() ? "true" : "false"));
        assertFalse(gateway.syncRedeemDisabled());
        _step("  PASS: old admin retains rights during delay, loses them after transfer");

        _logPass();
    }

    // ================================================================
    // Case 27 – setGateway(newGateway) 后旧 Gateway 失效
    // ================================================================

    function test_Case27_OldGatewayInvalidatedAfterSwap() public {
        _logCase("Case-27", unicode"setGateway(newGateway) 后旧 Gateway 失效");

        _step("[Step 1] deploy and init new gateway");
        address newGwAddr = gatewayFactory.deployGateway();
        MantleVaultGateway newGw = MantleVaultGateway(newGwAddr);
        vm.prank(admin);
        newGw.initialize(
            IMantleVaultGateway.InitParams({
                vault: address(vault),
                sanctionsOracle: ISanctionsOracle(address(oracle)),
                sanctionSafe: sanctionSafe,
                admin: admin,
                syncRedeemDisabled: false
            })
        );
        _step(string.concat("  new gateway = ", vm.toString(newGwAddr)));

        _step("[Step 2] admin calls vault.setGateway(newGateway)");
        vm.prank(admin);
        vault.setGateway(newGwAddr);
        _step("  gateway swapped");

        _step("[Step 3] old gateway deposit -> revert");
        usdc.mint(userA, 1000e6);
        vm.prank(userA);
        vm.expectRevert(IMantleYieldVault.Vault__OnlyGateway.selector);
        gateway.deposit(1000e6);
        _step("  reverted (old gateway no longer authorized)");

        _step("[Step 4] new gateway deposit succeeds");
        vm.prank(userA);
        uint256 shares = newGw.deposit(1000e6);
        _step(string.concat("  shares = ", vm.toString(shares)));
        assertTrue(shares > 0, "new gateway should work");
        _step("  PASS: old gateway invalidated after swap");

        _logPass();
    }

    // ================================================================
    // Case 28 – setAccountant(newAccountant) 后旧 Accountant 失去权限
    // ================================================================

    function test_Case28_OldAccountantLosesAccess() public {
        _logCase("Case-28", unicode"setAccountant(newAccountant) 后旧 Accountant 失去权限");

        _step("[Step 1] old accountant mints fee shares");
        vm.prank(address(accountant));
        vault.mintFeeShares(10e18);
        uint256 treasuryBal = vault.balanceOf(treasuryAddr);
        _step(string.concat("  treasury shares = ", vm.toString(treasuryBal)));

        _step("[Step 2] swap to new accountant");
        Accountant newAcct = _deployRealAccountantWithRate(1e18);
        _step(string.concat("  new accountant = ", vm.toString(address(newAcct))));
        vm.prank(admin);
        vault.setAccountant(address(newAcct));
        _step("  accountant swapped");

        _step("[Step 3] old accountant mintFeeShares -> revert");
        vm.prank(address(accountant));
        vm.expectRevert(IMantleYieldVault.Vault__OnlyAccountant.selector);
        vault.mintFeeShares(10e18);
        _step("  reverted (old accountant no longer authorized)");

        _step("[Step 4] new accountant mintFeeShares succeeds");
        vm.prank(address(newAcct));
        vault.mintFeeShares(10e18);
        uint256 treasuryBalAfter = vault.balanceOf(treasuryAddr);
        _step(string.concat("  treasury shares after = ", vm.toString(treasuryBalAfter)));
        _step("  PASS: old accountant loses access after swap");

        _logPass();
    }

    // ================================================================
    // Case 29 – setRedemptionFee(0) 成功，支持零赎回费
    // ================================================================

    function test_Case29_ZeroRedemptionFee() public {
        _logCase("Case-29", unicode"setRedemptionFee(0) 成功，支持零赎回费");

        _step(string.concat("[Step 1] current redemptionFeeBps = ", vm.toString(vault.redemptionFeeBps())));

        _step("[Step 2] admin calls setRedemptionFee(0)");
        vm.recordLogs();
        vm.prank(admin);
        vault.setRedemptionFee(0);
        VmSafe.Log[] memory logs = vm.getRecordedLogs();

        uint256 newFee = vault.redemptionFeeBps();
        _step(string.concat("  redemptionFeeBps = ", vm.toString(newFee)));
        assertEq(newFee, 0);

        bool hasEvent = _hasEvent(logs, keccak256("RedemptionFeeUpdated(uint256,uint256)"));
        _step(string.concat("  RedemptionFeeUpdated emitted = ", hasEvent ? "true" : "false"));
        assertTrue(hasEvent);
        _step("  PASS: zero redemption fee accepted");

        _logPass();
    }

    // ================================================================
    // Case 30 – setRedemptionFee(maxRedemptionFeeBps) 成功，支持上限边界值
    // ================================================================

    function test_Case30_MaxBoundaryRedemptionFee() public {
        _logCase("Case-30", unicode"setRedemptionFee(maxRedemptionFeeBps) 成功，支持上限边界值");

        _step(string.concat("[Step 1] maxRedemptionFeeBps = ", vm.toString(MAX_FEE_BPS)));

        _step(string.concat("[Step 2] admin calls setRedemptionFee(", vm.toString(MAX_FEE_BPS), ")"));
        vm.prank(admin);
        vault.setRedemptionFee(MAX_FEE_BPS);
        uint256 newFee = vault.redemptionFeeBps();
        _step(string.concat("  redemptionFeeBps = ", vm.toString(newFee)));
        assertEq(newFee, MAX_FEE_BPS, "should not revert at boundary");
        _step("  PASS: max boundary fee accepted");

        _logPass();
    }

    // ================================================================
    // Case 31 – 只有 admin 可调用 rescueTokens
    // ================================================================

    function test_Case31_OnlyAdminCanRescueTokens() public {
        _logCase("Case-31", unicode"只有 admin 可调用 rescueTokens");

        _step("[Step 1] mint 500e18 mockToken to vault");
        mockToken.mint(address(vault), 500e18);
        _step(string.concat("  vault mockToken balance = ", vm.toString(mockToken.balanceOf(address(vault)))));

        _step("[Step 2] non-admin calls rescueTokens -> revert");
        bytes32 vaultAdminRole = vault.DEFAULT_ADMIN_ROLE();
        vm.prank(nobody);
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, nobody, vaultAdminRole
        ));
        vault.rescueTokens(address(mockToken), nobody, 500e18);
        _step("  reverted (non-admin denied)");

        _step("[Step 3] admin calls rescueTokens(mockToken, admin, 500e18)");
        vm.prank(admin);
        vault.rescueTokens(address(mockToken), admin, 500e18);
        uint256 adminBal = mockToken.balanceOf(admin);
        _step(string.concat("  admin mockToken balance = ", vm.toString(adminBal)));
        assertEq(adminBal, 500e18);
        _step("  PASS: only admin can rescue tokens");

        _logPass();
    }
}
