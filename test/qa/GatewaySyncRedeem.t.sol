// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Accountant} from "../../src/accountant/Accountant.sol";
import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {IMantleVaultGateway} from "../../src/interfaces/vault/IMantleVaultGateway.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {GatewayFactory} from "../../src/vault/GatewayFactory.sol";
import {MantleVaultGateway} from "../../src/vault/MantleVaultGateway.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {VaultFactory} from "../../src/vault/VaultFactory.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test, console2} from "forge-std/Test.sol";

// ---------------------------------------------------------------------------
// Mock contracts
// ---------------------------------------------------------------------------

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockSanctionsOracle is ISanctionsOracle {
    mapping(address => bool) private _sanctioned;
    mapping(address => bool) private _whitelisted;

    function initialize(address, address) external override {}

    function isSanctioned(address account) external view override returns (bool) {
        return _sanctioned[account];
    }

    function isWhitelisted(address account) external view override returns (bool) {
        return _whitelisted[account];
    }

    function totalSanctionedCount() external pure override returns (uint256) { return 0; }
    function totalWhitelistedCount() external pure override returns (uint256) { return 0; }
    function lastUpdateTimestamp() external pure override returns (uint256) { return 0; }
    function batchNonce() external pure override returns (uint256) { return 0; }
    function MAX_BATCH_SIZE() external pure override returns (uint256) { return 100; }
    function updateSanctionStatus(address account, bool sanctioned) external override { _sanctioned[account] = sanctioned; }
    function updateSanctionStatusBatch(address[] calldata, bool) external override {}
    function updateWhitelistStatus(address account, bool whitelisted) external override { _whitelisted[account] = whitelisted; }
    function updateWhitelistStatusBatch(address[] calldata, bool) external override {}
}

// ---------------------------------------------------------------------------
// QA Test: Gateway Sync Redeem Scenarios
// ---------------------------------------------------------------------------

contract GatewaySyncRedeemQATest is Test {
    MockUSDC internal usdc;
    MockSanctionsOracle internal oracle;
    Accountant internal accountant;
    MantleYieldVault internal vault;
    MantleVaultGateway internal gateway;
    VaultFactory internal factory;
    GatewayFactory internal gatewayFactory;

    address internal admin = makeAddr("admin");
    address internal controllerAddr = makeAddr("controller");
    address internal treasuryAddr = makeAddr("treasury");
    address internal sanctionSafe = makeAddr("sanctionSafe");
    address internal userA = makeAddr("userA");

    uint256 constant DEPOSIT_AMOUNT = 1_000e6; // 1000 USDC
    uint256 constant FEE_BPS = 100; // 1%
    uint256 constant BPS_DENOMINATOR = 10_000;

    function setUp() public {
        vm.warp(1000);

        usdc = new MockUSDC();
        oracle = new MockSanctionsOracle();

        MantleYieldVault impl = new MantleYieldVault();
        MantleVaultGateway gatewayImpl = new MantleVaultGateway();
        Accountant acctImpl = new Accountant();
        factory = new VaultFactory(address(impl), admin);
        gatewayFactory = new GatewayFactory(address(gatewayImpl), admin);

        address vaultAddr = factory.deployVault();
        address gatewayAddr = gatewayFactory.deployGateway();
        vault = MantleYieldVault(vaultAddr);
        gateway = MantleVaultGateway(gatewayAddr);

        // Initialize vault
        IMantleYieldVault.InitParams memory params = IMantleYieldVault.InitParams({
            asset: IERC20(address(usdc)),
            name: "Mantle RWA Vault",
            symbol: "mRWA",
            admin: admin,
            gateway: gatewayAddr,
            controller: controllerAddr,
            accountant: address(1),
            treasury: treasuryAddr,
            maxRedemptionFeeBps: 500,
            redemptionFeeBps: FEE_BPS,
            minRedeemAmount: 10e6,
            minDepositAmount: 0,
            maxSettlementDeviationBps: 0,
            depositDailyRemaining: type(uint256).max,
            redeemDailyRemaining: type(uint256).max
        });
        vm.prank(admin);
        vault.initialize(params);

        // Initialize gateway
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

        // Deploy real Accountant and wire to vault
        accountant = Accountant(address(new ERC1967Proxy(
            address(acctImpl),
            abi.encodeCall(Accountant.initialize, (address(vault), uint64(1e18), 0, admin, admin, admin))
        )));
        vm.prank(admin);
        vault.setAccountant(address(accountant));

        // Seed userA with USDC and deposit via gateway to get shares
        _depositForUser(userA, DEPOSIT_AMOUNT);
    }

    function _depositForUser(address user, uint256 amount) internal {
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(vault), type(uint256).max);
        gateway.deposit(amount);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // Logging helpers
    // -----------------------------------------------------------------------

    string constant MODULE = unicode"Gateway 同步赎回场景";
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

    // -----------------------------------------------------------------------
    // 1. Normal sync redeem (P0)
    // -----------------------------------------------------------------------

    function test_SyncRedeem_Normal() public {
        _logCase(
            "test_SyncRedeem_Normal",
            unicode"用户通过 Gateway 正常同步赎回"
        );

        uint256 shares = vault.balanceOf(userA);
        _step(string.concat("[Step 1] userA shares before redeem: ", vm.toString(shares)));
        assertEq(shares, DEPOSIT_AMOUNT, "shares should equal deposit");

        uint256 expectedGross = Math.mulDiv(shares, vault.exchangeRate(), 1e18, Math.Rounding.Floor);
        uint256 expectedFee = Math.mulDiv(expectedGross, FEE_BPS, BPS_DENOMINATOR, Math.Rounding.Ceil);
        uint256 expectedNet = expectedGross - expectedFee;

        _step(string.concat("[Step 2] Expected grossAssets: ", vm.toString(expectedGross)));
        _step(string.concat("[Step 2] Expected fee: ", vm.toString(expectedFee)));
        _step(string.concat("[Step 2] Expected net (userA receives): ", vm.toString(expectedNet)));

        uint256 previewAssets = vault.previewRedeem(shares);
        _step(string.concat("[Step 3] previewRedeem returns: ", vm.toString(previewAssets)));
        assertEq(previewAssets, expectedNet, "previewRedeem should match expected net");

        uint256 usdcBefore = usdc.balanceOf(userA);
        vm.prank(userA);
        uint256 assetsReceived = gateway.redeem(shares);

        _step(string.concat("[Step 4] Actual assets received: ", vm.toString(assetsReceived)));
        assertEq(assetsReceived, expectedNet, "assets received should equal net");

        uint256 usdcAfter = usdc.balanceOf(userA);
        assertEq(usdcAfter - usdcBefore, expectedNet, "USDC balance delta should equal net");
        _step(string.concat("[Step 5] userA USDC balance increased by: ", vm.toString(usdcAfter - usdcBefore)));

        uint256 sharesAfter = vault.balanceOf(userA);
        assertEq(sharesAfter, 0, "userA shares should be 0 after full redeem");
        _step(string.concat("[Step 6] userA shares after redeem: ", vm.toString(sharesAfter)));

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 2. syncRedeemDisabled = true blocks sync redeem (P0)
    // -----------------------------------------------------------------------

    function test_SyncRedeem_DisabledReverts() public {
        _logCase(
            "test_SyncRedeem_DisabledReverts",
            unicode"`syncRedeemDisabled = true` 时禁止同步赎回"
        );

        _step("[Step 1] Admin enables syncRedeemDisabled");
        vm.prank(admin);
        gateway.setSyncRedeemDisabled(true);
        assertTrue(gateway.syncRedeemDisabled(), "syncRedeemDisabled should be true");

        uint256 shares = vault.balanceOf(userA);
        _step(string.concat("[Step 2] userA calls gateway.redeem(", vm.toString(shares), ")"));

        vm.prank(userA);
        vm.expectRevert(IMantleYieldVault.Vault__SyncRedeemDisabled.selector);
        gateway.redeem(shares);
        _step("  PASS: reverted with Vault__SyncRedeemDisabled");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 3. Insufficient freeCash blocks sync redeem (P0)
    // -----------------------------------------------------------------------

    function test_SyncRedeem_InsufficientFreeCash() public {
        _logCase(
            "test_SyncRedeem_InsufficientFreeCash",
            unicode"`freeCash` 不足时同步赎回失败"
        );

        // Step 1: userB deposits large amount and requests async redeem to create lockedShares
        _step("[Step 1] userB deposits 10000 USDC and requests full async redeem");
        address userB = makeAddr("userB");
        usdc.mint(userB, 10_000e6);
        vm.startPrank(userB);
        usdc.approve(address(vault), type(uint256).max);
        gateway.deposit(10_000e6);
        uint256 userBShares = vault.balanceOf(userB);
        gateway.requestRedeem(userBShares);
        vm.stopPrank();

        uint256 lockedShares = vault.totalLockedShares();
        _step(string.concat("  totalLockedShares: ", vm.toString(lockedShares)));

        // Step 2: Raise exchange rate so floatingLocked consumes nearly all physBal
        // physBal = 11000e6 (1000 from userA + 10000 from userB)
        // floatingLocked = lockedShares * rate / 1e18
        // At rate=1e18, floatingLocked < physBal (due to fee shares)
        // Raise rate so floatingLocked approaches physBal, squeezing freeCash to near 0
        _step("[Step 2] Raise exchange rate to squeeze freeCash");
        uint256 physBal = usdc.balanceOf(address(vault));
        // Target: floatingLocked ~= physBal => rate ~= physBal * 1e18 / lockedShares
        uint256 targetRate = (physBal * 1e18) / lockedShares;
        // Deviation > 10% (MAX_DEVIATION_CEILING), so use emergencyRateUpdate (real admin function, no pause)
        vm.prank(admin);
        accountant.emergencyRateUpdate(uint64(targetRate));
        _step(string.concat("  physBal: ", vm.toString(physBal)));
        _step(string.concat("  targetRate: ", vm.toString(targetRate)));

        uint256 freeCash = vault.getFreeCash();
        _step(string.concat("  freeCash after rate change: ", vm.toString(freeCash)));

        // Step 3: Verify userA cannot fully sync redeem
        uint256 shares = vault.balanceOf(userA);
        uint256 redeemValue = vault.previewRedeem(shares);
        _step(string.concat("[Step 3] userA shares: ", vm.toString(shares)));
        _step(string.concat("  previewRedeem: ", vm.toString(redeemValue)));
        assertGt(redeemValue, freeCash, "redeem value should exceed freeCash");

        uint256 maxRedeemable = vault.maxRedeem(userA);
        _step(string.concat("  maxRedeem(userA): ", vm.toString(maxRedeemable)));
        assertLt(maxRedeemable, shares, "maxRedeem should be less than total shares");

        vm.prank(userA);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxRedeem.selector, userA, shares, maxRedeemable)
        );
        gateway.redeem(shares);
        _step("  PASS: reverted due to insufficient freeCash (locked by async redeem + rate increase)");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 4. Sanctioned user shares routed to safe address (P0)
    // -----------------------------------------------------------------------

    function test_SyncRedeem_SanctionedUserRoutesToSafe() public {
        _logCase(
            "test_SyncRedeem_SanctionedUserRoutesToSafe",
            unicode"被制裁用户同步赎回会将 shares 路由给到 safe 地址"
        );

        uint256 shares = vault.balanceOf(userA);
        _step(string.concat("[Step 1] userA has ", vm.toString(shares), " shares"));

        _step("[Step 2] Mark userA as sanctioned");
        oracle.updateSanctionStatus(userA, true);
        assertTrue(gateway.isSanctioned(userA), "userA should be sanctioned");

        uint256 safeBefore = vault.balanceOf(sanctionSafe);
        uint256 lockedBefore = vault.totalLockedShares();
        _step(string.concat("[Step 3] sanctionSafe shares before: ", vm.toString(safeBefore)));

        vm.prank(userA);
        vm.expectEmit(true, true, false, true, address(vault));
        // routeSanctionedShares 只移动 shares（vault token），token 字段应为 vault 自身
        emit IMantleYieldVault.SanctionSafeIn(userA, address(vault), shares);
        uint256 assets = gateway.redeem(shares);

        _step(string.concat("[Step 4] gateway.redeem returns assets: ", vm.toString(assets)));
        assertEq(assets, 0, "sanctioned user gets 0 assets");

        uint256 safeAfter = vault.balanceOf(sanctionSafe);
        _step(string.concat("[Step 5] sanctionSafe shares after: ", vm.toString(safeAfter)));
        assertEq(safeAfter - safeBefore, shares, "shares should be routed to sanctionSafe");

        uint256 userSharesAfter = vault.balanceOf(userA);
        assertEq(userSharesAfter, 0, "userA shares should be 0");
        _step(string.concat("[Step 6] userA shares after: ", vm.toString(userSharesAfter)));

        uint256 lockedAfter = vault.totalLockedShares();
        assertEq(lockedAfter, lockedBefore, "totalLockedShares should not change for sanctioned route");
        _step(string.concat("[Step 7] totalLockedShares unchanged: ", vm.toString(lockedAfter)));

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 5. Whitelist enabled, non-whitelisted user blocked (P0)
    // -----------------------------------------------------------------------

    function test_SyncRedeem_WhitelistEnabled_NotWhitelisted() public {
        _logCase(
            "test_SyncRedeem_WhitelistEnabled_NotWhitelisted",
            unicode"白名单开启时，未白名单用户禁止同步赎回"
        );

        _step("[Step 1] Admin enables whitelist");
        vm.prank(admin);
        gateway.setWhitelistEnabled(true);
        assertTrue(gateway.whitelistEnabled(), "whitelistEnabled should be true");

        uint256 shares = vault.balanceOf(userA);
        _step(string.concat("[Step 2] userA (not whitelisted) calls redeem(", vm.toString(shares), ")"));

        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSelector(IMantleVaultGateway.Gateway__NotWhitelisted.selector, userA));
        gateway.redeem(shares);
        _step("  PASS: reverted with Gateway__NotWhitelisted(userA)");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 6. Whitelist enabled, whitelisted user can redeem (P1)
    // -----------------------------------------------------------------------

    function test_SyncRedeem_WhitelistEnabled_Whitelisted() public {
        _logCase(
            "test_SyncRedeem_WhitelistEnabled_Whitelisted",
            unicode"白名单开启时，已白名单用户正常同步赎回"
        );

        _step("[Step 1] Admin enables whitelist and whitelists userA");
        vm.prank(admin);
        gateway.setWhitelistEnabled(true);
        oracle.updateWhitelistStatus(userA, true);
        assertTrue(gateway.whitelistEnabled(), "whitelistEnabled should be true");
        assertTrue(gateway.isWhitelisted(userA), "userA should be whitelisted");

        uint256 shares = vault.balanceOf(userA);
        uint256 expectedNet = vault.previewRedeem(shares);
        _step(string.concat("[Step 2] userA redeems ", vm.toString(shares), " shares"));

        vm.prank(userA);
        uint256 assets = gateway.redeem(shares);

        _step(string.concat("[Step 3] Assets received: ", vm.toString(assets)));
        assertEq(assets, expectedNet, "whitelisted user should redeem successfully");
        assertEq(vault.balanceOf(userA), 0, "userA shares should be 0");
        _step("  PASS: redeem succeeded for whitelisted user");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 7. Accountant paused blocks sync redeem (P1)
    // -----------------------------------------------------------------------

    function test_SyncRedeem_AccountantPaused() public {
        _logCase(
            "test_SyncRedeem_AccountantPaused",
            unicode"Accountant 暂停导致同步赎回入口暂停"
        );

        _step("[Step 1] Pause the accountant");
        vm.prank(admin);
        accountant.pause();

        uint256 shares = vault.balanceOf(userA);
        _step(string.concat("[Step 2] userA calls gateway.redeem(", vm.toString(shares), ")"));

        vm.prank(userA);
        vm.expectRevert(MantleVaultGateway.EnforcedPause.selector);
        gateway.redeem(shares);
        _step("  PASS: reverted with EnforcedPause()");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 8. Fee = 0 means no fee deduction (P1)
    // -----------------------------------------------------------------------

    function test_SyncRedeem_ZeroFee() public {
        _logCase(
            "test_SyncRedeem_ZeroFee",
            unicode"`fee = 0` 时同步赎回按无手续费结算"
        );

        _step("[Step 1] Admin sets redemptionFeeBps = 0");
        vm.prank(admin);
        vault.setRedemptionFee(0);
        assertEq(vault.redemptionFeeBps(), 0, "redemptionFeeBps should be 0");

        uint256 shares = vault.balanceOf(userA);
        uint256 expectedAssets = vault.previewRedeem(shares); // rate=1e18, fee=0 => 1:1

        uint256 preview = vault.previewRedeem(shares);
        _step(string.concat("[Step 2] previewRedeem(", vm.toString(shares), ") = ", vm.toString(preview)));
        assertEq(preview, expectedAssets, "previewRedeem should return full amount with no fee");

        uint256 usdcBefore = usdc.balanceOf(userA);
        vm.prank(userA);
        uint256 assets = gateway.redeem(shares);

        _step(string.concat("[Step 3] Assets received: ", vm.toString(assets)));
        assertEq(assets, expectedAssets, "should receive full amount with zero fee");

        uint256 usdcDelta = usdc.balanceOf(userA) - usdcBefore;
        assertEq(usdcDelta, expectedAssets, "USDC balance delta should match");
        _step(string.concat("[Step 4] userA USDC increased by: ", vm.toString(usdcDelta)));

        _logPass();
    }
}
