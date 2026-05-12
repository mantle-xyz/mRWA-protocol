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
import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {StrategyControllerFactory} from "../../src/protocol/StrategyControllerFactory.sol";
import {OperatorExecutor} from "../../src/protocol/OperatorExecutor.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
    mapping(address => bool) public sanctioned;
    mapping(address => bool) public whitelisted;

    function initialize(address, address) external override {}

    function isSanctioned(address account) external view override returns (bool) {
        return sanctioned[account];
    }

    function isWhitelisted(address account) external view override returns (bool) {
        return whitelisted[account];
    }

    function totalSanctionedCount() external pure override returns (uint256) {
        return 0;
    }

    function totalWhitelistedCount() external pure override returns (uint256) {
        return 0;
    }

    function lastUpdateTimestamp() external pure override returns (uint256) {
        return 0;
    }

    function batchNonce() external pure override returns (uint256) {
        return 0;
    }

    function MAX_BATCH_SIZE() external pure override returns (uint256) {
        return 100;
    }

    function updateSanctionStatus(address account, bool status) external override { sanctioned[account] = status; }
    function updateSanctionStatusBatch(address[] calldata, bool) external override {}
    function updateWhitelistStatus(address account, bool status) external override { whitelisted[account] = status; }
    function updateWhitelistStatusBatch(address[] calldata, bool) external override {}
}

// ---------------------------------------------------------------------------
// QA Test: Gateway Async Redeem Request Scenarios
// ---------------------------------------------------------------------------

contract GatewayAsyncRedeemQATest is Test {
    MockUSDC internal usdc;
    MockSanctionsOracle internal oracle;
    Accountant internal accountant;
    MantleYieldVault internal vault;
    MantleVaultGateway internal gateway;
    VaultFactory internal factory;
    GatewayFactory internal gatewayFactory;
    StrategyControllerFactory internal controllerFactory;
    StrategyController internal controller;
    OperatorExecutor internal executor;

    address internal admin = makeAddr("admin");
    address internal bot = makeAddr("bot");
    address internal treasuryAddr = makeAddr("treasury");
    address internal sanctionSafe = makeAddr("sanctionSafe");
    address internal userA = makeAddr("userA");

    uint256 constant DEPOSIT_AMOUNT = 10_000e6; // 10000 USDC (enough for various tests)
    uint256 constant FEE_BPS = 100; // 1%
    uint256 constant MIN_REDEEM = 100e6; // minimum redeem amount
    uint256 constant BPS_DENOMINATOR = 10_000;

    function setUp() public {
        vm.warp(1000);

        usdc = new MockUSDC();
        oracle = new MockSanctionsOracle();

        MantleYieldVault impl = new MantleYieldVault();
        MantleVaultGateway gatewayImpl = new MantleVaultGateway();
        StrategyController ctrlImpl = new StrategyController();
        OperatorExecutor execImpl = new OperatorExecutor();
        Accountant acctImpl = new Accountant();

        factory = new VaultFactory(address(impl), admin);
        gatewayFactory = new GatewayFactory(address(gatewayImpl), admin);
        controllerFactory = new StrategyControllerFactory(address(ctrlImpl), admin);

        address vaultAddr = factory.deployVault();
        address gatewayAddr = gatewayFactory.deployGateway();
        address controllerAddr = controllerFactory.deployController();

        // OperatorExecutor - UUPS, init now
        address execAddr = address(
            new ERC1967Proxy(address(execImpl), abi.encodeCall(OperatorExecutor.initialize, (admin, bot)))
        );

        vault = MantleYieldVault(vaultAddr);
        gateway = MantleVaultGateway(gatewayAddr);
        controller = StrategyController(controllerAddr);
        executor = OperatorExecutor(execAddr);

        // Initialize vault with minRedeemAmount set
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
            minRedeemAmount: MIN_REDEEM,
            minDepositAmount: 0,
            maxSettlementDeviationBps: 0,
            depositDailyRemaining: type(uint256).max,
            redeemDailyRemaining: type(uint256).max
        });
        vm.prank(admin);
        vault.initialize(params);

        vm.prank(admin);
        controller.initialize(
            vaultAddr, admin, execAddr, admin, 0, 0, 0
        );

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
            abi.encodeCall(Accountant.initialize, (address(vault), uint64(1e18), 0, admin))
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

    string constant MODULE = unicode"Gateway 异步赎回请求场景";
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
    // 1. User successfully initiates async redeem request (P0)
    // -----------------------------------------------------------------------

    function test_AsyncRedeem_Success() public {
        _logCase(
            "test_AsyncRedeem_Success",
            unicode"用户自己发起异步赎回请求成功"
        );

        uint256 shares = vault.balanceOf(userA);
        _step(string.concat("[Step 1] userA has ", vm.toString(shares), " shares"));

        // Use a portion of shares that will pass minRedeemAmount
        uint256 redeemShares = shares / 2;
        uint256 estimatedNet = vault.previewRedeem(redeemShares);
        _step(string.concat("[Step 2] Requesting redeem for ", vm.toString(redeemShares), " shares"));
        _step(string.concat("[Step 2] Estimated net assets: ", vm.toString(estimatedNet)));
        assertTrue(estimatedNet >= MIN_REDEEM, "estimated net should exceed minRedeemAmount");

        vm.prank(userA);
        uint256 requestId = gateway.requestRedeem(redeemShares);

        _step(string.concat("[Step 3] Returned requestId: ", vm.toString(requestId)));
        assertTrue(requestId != 0, "requestId should be non-zero");

        (
            uint256 id,
            address owner,
            uint256 reqShares,
            ,
            uint256 estAssets,
            ,
            ,
            IMantleYieldVault.RequestStatus status
        ) = vault.requests(requestId);
        _step(string.concat("[Step 4] Request owner: ", vm.toString(owner)));
        _step(string.concat("[Step 4] Request status: ", vm.toString(uint256(status))));
        assertEq(id, requestId, "request id should match");
        assertEq(owner, userA, "request owner should be userA");
        assertEq(uint256(status), uint256(IMantleYieldVault.RequestStatus.PENDING), "status should be PENDING");
        assertTrue(reqShares > 0, "request shares should be > 0");
        assertTrue(estAssets > 0, "estimated assets should be > 0");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 2. Min redeem threshold blocks tiny requests (P0)
    // -----------------------------------------------------------------------

    function test_AsyncRedeem_MinThreshold() public {
        _logCase(
            "test_AsyncRedeem_MinThreshold",
            unicode"最小异步赎回门槛可阻止垃圾小额请求进入队列，避免批处理通道被滥用"
        );

        _step(string.concat("[Step 1] minRedeemAmount: ", vm.toString(MIN_REDEEM)));

        // Construct tiny shares below minRedeemAmount.
        // Contract checks: if (shares < minRedeemAmount) revert Vault__BelowMinRedeem(shares, minRedeemAmount)
        // Use 50e6 shares => 50e6 < 100e6 (minRedeemAmount), so it reverts.
        uint256 tinyShares = 50e6;
        _step(string.concat("[Step 2] Attempt requestRedeem with tiny shares: ", vm.toString(tinyShares)));

        {
            vm.prank(userA);
            vm.expectRevert(abi.encodeWithSelector(IMantleYieldVault.Vault__BelowMinRedeem.selector, tinyShares, MIN_REDEEM));
            gateway.requestRedeem(tinyShares);
            _step("  PASS: tiny request rejected (below minRedeemAmount)");
        }

        // Try a second tiny request
        _step("[Step 3] Attempt another tiny requestRedeem");
        {
            vm.prank(userA);
            vm.expectRevert(abi.encodeWithSelector(IMantleYieldVault.Vault__BelowMinRedeem.selector, tinyShares, MIN_REDEEM));
            gateway.requestRedeem(tinyShares);
            _step("  PASS: second tiny request also rejected");
        }

        // Valid request above threshold
        // Need net >= 100e6. With fee=1%: gross >= ~101.02e6 => shares >= ~101.02e6
        // Use 200e6 shares => gross=200e6, fee=2e6, net=198e6 > 100e6
        uint256 validShares = 200e6;
        _step(string.concat("[Step 4] Attempt requestRedeem with valid shares: ", vm.toString(validShares)));

        vm.prank(userA);
        uint256 requestId = gateway.requestRedeem(validShares);
        assertTrue(requestId != 0, "valid request should return non-zero requestId");
        _step(string.concat("  PASS: valid request created, requestId: ", vm.toString(requestId)));

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 3. Zero shares rejected (P0)
    // -----------------------------------------------------------------------

    function test_AsyncRedeem_ZeroShares() public {
        _logCase(
            "test_AsyncRedeem_ZeroShares",
            unicode"0 shares 发起异步赎回请求被拒绝"
        );

        _step("[Step 1] userA calls gateway.requestRedeem(0)");

        vm.prank(userA);
        vm.expectRevert(IMantleYieldVault.Vault__ZeroAmount.selector);
        gateway.requestRedeem(0);
        _step("  PASS: reverted with Vault__ZeroAmount");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 4. Estimated assets below min redeem rejected (P0)
    // -----------------------------------------------------------------------

    function test_AsyncRedeem_BelowMinRedeem() public {
        _logCase(
            "test_AsyncRedeem_BelowMinRedeem",
            unicode"预计资产小于最小赎回金额时拒绝创建请求"
        );

        _step(string.concat("[Step 1] minRedeemAmount: ", vm.toString(MIN_REDEEM)));

        // Mirror the current contract check exactly:
        // MantleYieldVault._requestRedeem reverts when input shares < minRedeemAmount.
        uint256 tinyShares = MIN_REDEEM - 1;
        uint256 currentRate = vault.exchangeRate();
        uint256 estimatedAssets = vault.previewRedeem(tinyShares);
        _step(string.concat("[Step 2] tinyShares: ", vm.toString(tinyShares)));
        _step(string.concat("[Step 2] exchangeRate: ", vm.toString(currentRate)));
        _step(
            string.concat(
                "[Step 2] contract threshold check uses shares: ",
                vm.toString(tinyShares),
                " < ",
                vm.toString(MIN_REDEEM)
            )
        );
        _step(string.concat("[Step 2] estimated assets at current rate: ", vm.toString(estimatedAssets)));
        assertTrue(tinyShares < MIN_REDEEM, "shares should be below minRedeemAmount");

        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSelector(IMantleYieldVault.Vault__BelowMinRedeem.selector, tinyShares, MIN_REDEEM));
        gateway.requestRedeem(tinyShares);
        _step("  PASS: reverted with Vault__BelowMinRedeem");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 5. Sanctioned user shares routed via special path (P0)
    // -----------------------------------------------------------------------

    function test_AsyncRedeem_SanctionedUserRouted() public {
        _logCase(
            "test_AsyncRedeem_SanctionedUserRouted",
            unicode"被制裁用户异步赎回时走 shares 路由特殊路径"
        );

        uint256 shares = vault.balanceOf(userA);
        _step(string.concat("[Step 1] userA has ", vm.toString(shares), " shares"));

        _step("[Step 2] Mark userA as sanctioned");
        oracle.updateSanctionStatus(userA, true);
        assertTrue(gateway.isSanctioned(userA), "userA should be sanctioned");

        uint256 safeBefore = vault.balanceOf(sanctionSafe);
        uint256 userABefore = vault.balanceOf(userA);
        uint256 lockedBefore = vault.totalLockedShares();
        uint256 redeemShares = 500e6;

        vm.prank(userA);
        vm.expectEmit(true, true, false, true, address(vault));
        // routeSanctionedShares 只移动 shares（vault token），token 字段应为 vault 自身
        emit IMantleYieldVault.SanctionSafeIn(userA, address(vault), redeemShares);
        uint256 requestId = gateway.requestRedeem(redeemShares);

        _step(string.concat("[Step 3] requestRedeem returned requestId: ", vm.toString(requestId)));
        assertEq(requestId, 0, "sanctioned user should get requestId=0");

        uint256 safeAfter = vault.balanceOf(sanctionSafe);
        uint256 userAAfter = vault.balanceOf(userA);
        uint256 lockedAfter = vault.totalLockedShares();
        _step(string.concat("[Step 4] sanctionSafe shares increased by: ", vm.toString(safeAfter - safeBefore)));
        assertEq(safeAfter - safeBefore, redeemShares, "shares should be routed to sanctionSafe");

        _step("[Step 5] Verify userA balance decreased and no lockedShares created");
        assertEq(userABefore - userAAfter, redeemShares, "userA shares should decrease by redeemShares");
        assertEq(lockedAfter, lockedBefore, "totalLockedShares should not change for sanctioned route");
        _step(string.concat("  userA balance decreased by: ", vm.toString(userABefore - userAAfter)));
        _step(string.concat("  totalLockedShares unchanged: ", vm.toString(lockedAfter)));

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 6. estimatedAssets is reference only, not a hard commitment (P0)
    // -----------------------------------------------------------------------

    function test_AsyncRedeem_EstimatedAssetsIsReference() public {
        _logCase(
            "test_AsyncRedeem_EstimatedAssetsIsReference",
            unicode"`estimatedAssets` 仅为请求创建时的参考值，不构成最终兑付金额的硬承诺"
        );

        // Step 1: Request redeem at current rate (1e18)
        uint256 redeemShares = 1_000e6;
        _step(string.concat("[Step 1] userA requests async redeem for ", vm.toString(redeemShares), " shares at rate=1e18"));

        vm.prank(userA);
        uint256 requestId = gateway.requestRedeem(redeemShares);
        assertTrue(requestId != 0, "should create request");

        (,,,, uint256 estimatedAssets, uint256 settledAssets,, IMantleYieldVault.RequestStatus status) =
            vault.requests(requestId);
        _step(string.concat("[Step 2] estimatedAssets at creation: ", vm.toString(estimatedAssets)));
        _step(string.concat("[Step 2] settledAssets at creation: ", vm.toString(settledAssets)));
        assertEq(settledAssets, 0, "settledAssets should be 0 at creation");
        assertEq(uint256(status), uint256(IMantleYieldVault.RequestStatus.PENDING), "status should be PENDING");

        // Step 3: Move to PROCESSING (operator processes the redeem batch)
        _step("[Step 3] Controller moves request to PROCESSING");
        uint256[] memory ids = new uint256[](1);
        ids[0] = requestId;
        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), ids);

        (,,,,,,, IMantleYieldVault.RequestStatus status2) = vault.requests(requestId);
        assertEq(uint256(status2), uint256(IMantleYieldVault.RequestStatus.PROCESSING), "status should be PROCESSING");

        // Step 4: Exchange rate rises before settlement (simulate asset appreciation)
        // estimatedAssets was computed at rate=1e18, now rate goes up to 1.05e18
        // Operator settles at the new rate: settledAssets = netShares * newRate / 1e18
        _step("[Step 4] Exchange rate rises to 1.05e18 before settlement");
        vm.startPrank(admin);
        accountant.setRiskParams(1000, 0); // allow 10% deviation, 0 cooldown
        vm.warp(block.timestamp + 1);
        accountant.updateExchangeRate(uint64(1.05e18), uint64(block.timestamp));
        vm.stopPrank();
        _step(string.concat("  new rate = ", vm.toString(accountant.getRate())));

        // Compute settled amount based on new rate (same as operator would)
        (,, uint256 netShares,,,,, ) = vault.requests(requestId);
        uint256 settledAmount = Math.mulDiv(netShares, accountant.getRate(), 1e18, Math.Rounding.Floor);
        _step(string.concat("  netShares = ", vm.toString(netShares)));
        _step(string.concat("  settledAmount (at new rate) = ", vm.toString(settledAmount)));
        assertGt(settledAmount, estimatedAssets, "settled at higher rate (1.05) should exceed original estimate (1.0)");

        // Step 5: Finalize the redeem batch — vault has enough USDC from original deposits
        _step("[Step 5] Finalize redeem batch with rate-adjusted settledAssets");
        uint256 vaultBalBefore = usdc.balanceOf(address(vault));
        _step(string.concat("  vault USDC balance = ", vm.toString(vaultBalBefore)));
        assertTrue(vaultBalBefore >= settledAmount, "vault should have enough USDC from deposits");

        uint256[] memory settledAmounts = new uint256[](1);
        settledAmounts[0] = settledAmount;
        // Spec: "若不同，应通过 RequestSettlementAdjusted 透明记录"
        vm.expectEmit(true, false, false, true, address(vault));
        emit IMantleYieldVault.RequestSettlementAdjusted(requestId, estimatedAssets, settledAmount);
        vm.prank(bot);
        executor.executeFinalizeRedeemBatch(address(controller), ids, settledAmounts);
        _step("  PASS: RequestSettlementAdjusted event emitted");

        (,,,, uint256 estAfter, uint256 settledAfter,, IMantleYieldVault.RequestStatus status3) =
            vault.requests(requestId);
        _step(string.concat("[Step 6] estimatedAssets (unchanged): ", vm.toString(estAfter)));
        _step(string.concat("[Step 6] settledAssets (rate-adjusted): ", vm.toString(settledAfter)));
        _step(string.concat("[Step 6] status: ", vm.toString(uint256(status3))));

        assertEq(uint256(status3), uint256(IMantleYieldVault.RequestStatus.DONE), "status should be DONE");
        assertEq(estAfter, estimatedAssets, "estimatedAssets should remain unchanged from creation");
        assertEq(settledAfter, settledAmount, "settledAssets should match rate-adjusted amount");
        assertGt(settledAfter, estAfter, "settledAssets > estimatedAssets due to rate increase");
        _step("  PASS: estimatedAssets is reference only; settlement uses actual rate at finalization time");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 7. Accountant paused blocks async redeem (P1)
    // -----------------------------------------------------------------------

    function test_AsyncRedeem_AccountantPaused() public {
        _logCase(
            "test_AsyncRedeem_AccountantPaused",
            unicode"Accountant 暂停导致异步赎回入口暂停"
        );

        _step("[Step 1] Pause the accountant");
        vm.prank(admin);
        accountant.pause();

        uint256 shares = 500e6;
        _step(string.concat("[Step 2] userA calls gateway.requestRedeem(", vm.toString(shares), ")"));

        vm.prank(userA);
        vm.expectRevert(MantleVaultGateway.EnforcedPause.selector);
        gateway.requestRedeem(shares);
        _step("  PASS: reverted with EnforcedPause()");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 8. Whitelist enabled, non-whitelisted user blocked (P0)
    // -----------------------------------------------------------------------

    function test_AsyncRedeem_WhitelistEnabled_NotWhitelisted() public {
        _logCase(
            "test_AsyncRedeem_WhitelistEnabled_NotWhitelisted",
            unicode"`requestRedeem` 白名单开启时未白名单用户被拒绝"
        );

        _step("[Step 1] Admin enables whitelist");
        vm.prank(admin);
        gateway.setWhitelistEnabled(true);
        assertTrue(gateway.whitelistEnabled(), "whitelistEnabled should be true");

        uint256 shares = 500e6;
        _step(string.concat("[Step 2] userA (not whitelisted, not sanctioned) calls requestRedeem(", vm.toString(shares), ")"));

        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSelector(IMantleVaultGateway.Gateway__NotWhitelisted.selector, userA));
        gateway.requestRedeem(shares);
        _step("  PASS: reverted with Gateway__NotWhitelisted(userA)");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 9. Whitelist enabled, whitelisted user can request redeem (P0)
    // -----------------------------------------------------------------------

    function test_AsyncRedeem_WhitelistEnabled_Whitelisted() public {
        _logCase(
            "test_AsyncRedeem_WhitelistEnabled_Whitelisted",
            unicode"`requestRedeem` 白名单开启时白名单用户可操作"
        );

        _step("[Step 1] Admin enables whitelist and whitelists userA");
        vm.prank(admin);
        gateway.setWhitelistEnabled(true);
        oracle.updateWhitelistStatus(userA, true);

        uint256 shares = 500e6;
        _step(string.concat("[Step 2] userA calls requestRedeem(", vm.toString(shares), ")"));

        vm.prank(userA);
        uint256 requestId = gateway.requestRedeem(shares);

        _step(string.concat("[Step 3] Returned requestId: ", vm.toString(requestId)));
        assertTrue(requestId != 0, "requestId should be non-zero");
        _step("  PASS: whitelisted user successfully created request");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 10. Whitelist disabled, non-whitelisted user can request redeem (P1)
    // -----------------------------------------------------------------------

    function test_AsyncRedeem_WhitelistDisabled_NoCheck() public {
        _logCase(
            "test_AsyncRedeem_WhitelistDisabled_NoCheck",
            unicode"`requestRedeem` 白名单关闭时不检查白名单"
        );

        _step("[Step 1] Ensure whitelistEnabled=false (default)");
        assertFalse(gateway.whitelistEnabled(), "whitelistEnabled should be false");
        assertFalse(gateway.isWhitelisted(userA), "userA should NOT be whitelisted");
        assertFalse(gateway.isSanctioned(userA), "userA should NOT be sanctioned");

        uint256 shares = 500e6;
        _step(string.concat("[Step 2] userA (not whitelisted) calls requestRedeem(", vm.toString(shares), ")"));

        vm.prank(userA);
        uint256 requestId = gateway.requestRedeem(shares);

        _step(string.concat("[Step 3] Returned requestId: ", vm.toString(requestId)));
        assertTrue(requestId != 0, "requestId should be non-zero");
        _step("  PASS: non-whitelisted user can requestRedeem when whitelist is disabled");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 11. Whitelist enabled, whitelisted & non-sanctioned user succeeds (P0)
    //     Category: gateway/sanction
    // -----------------------------------------------------------------------

    function test_AsyncRedeem_WhitelistEnabled_WhitelistedNotSanctioned() public {
        _logCase(
            "test_AsyncRedeem_WhitelistEnabled_WhitelistedNotSanctioned",
            unicode"`requestRedeem` 白名单开启时白名单用户可操作"
        );

        _step("[Step 1] Enable whitelist, whitelist userA, ensure not sanctioned");
        vm.prank(admin);
        gateway.setWhitelistEnabled(true);
        oracle.updateWhitelistStatus(userA, true);
        assertTrue(gateway.whitelistEnabled(), "whitelistEnabled should be true");
        assertTrue(gateway.isWhitelisted(userA), "userA should be whitelisted");
        assertFalse(gateway.isSanctioned(userA), "userA should NOT be sanctioned");

        uint256 shares = 500e6;
        uint256 sharesBefore = vault.balanceOf(userA);
        uint256 lockedBefore = vault.totalLockedShares();
        _step(string.concat("[Step 2] userA calls requestRedeem(", vm.toString(shares), ")"));

        vm.prank(userA);
        uint256 requestId = gateway.requestRedeem(shares);

        _step(string.concat("[Step 3] Returned requestId: ", vm.toString(requestId)));
        assertTrue(requestId != 0, "requestId should be non-zero");

        (uint256 id, address owner,,,,,, IMantleYieldVault.RequestStatus status) = vault.requests(requestId);
        assertEq(id, requestId, "request id should match");
        assertEq(owner, userA, "request owner should be userA");
        assertEq(uint256(status), uint256(IMantleYieldVault.RequestStatus.PENDING), "status should be PENDING");

        uint256 sharesAfter = vault.balanceOf(userA);
        uint256 lockedAfter = vault.totalLockedShares();
        assertLt(sharesAfter, sharesBefore, "userA shares should decrease");
        assertGt(lockedAfter, lockedBefore, "totalLockedShares should increase");
        _step("  PASS: whitelisted & non-sanctioned user successfully created async redeem request");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 12. Whitelist disabled, non-whitelisted & non-sanctioned user succeeds (P1)
    //     Category: gateway/sanction
    // -----------------------------------------------------------------------

    function test_AsyncRedeem_WhitelistDisabled_NotWhitelistedNotSanctioned() public {
        _logCase(
            "test_AsyncRedeem_WhitelistDisabled_NotWhitelistedNotSanctioned",
            unicode"`requestRedeem` 白名单关闭时不检查白名单"
        );

        _step("[Step 1] Ensure whitelistEnabled=false, userA not whitelisted and not sanctioned");
        assertFalse(gateway.whitelistEnabled(), "whitelistEnabled should be false");
        assertFalse(gateway.isWhitelisted(userA), "userA should NOT be whitelisted");
        assertFalse(gateway.isSanctioned(userA), "userA should NOT be sanctioned");

        uint256 shares = 500e6;
        uint256 sharesBefore = vault.balanceOf(userA);
        uint256 lockedBefore = vault.totalLockedShares();
        _step(string.concat("[Step 2] userA calls requestRedeem(", vm.toString(shares), ")"));

        vm.prank(userA);
        uint256 requestId = gateway.requestRedeem(shares);

        _step(string.concat("[Step 3] Returned requestId: ", vm.toString(requestId)));
        assertTrue(requestId != 0, "requestId should be non-zero");

        (uint256 id, address owner,,,,,, IMantleYieldVault.RequestStatus status) = vault.requests(requestId);
        assertEq(id, requestId, "request id should match");
        assertEq(owner, userA, "request owner should be userA");
        assertEq(uint256(status), uint256(IMantleYieldVault.RequestStatus.PENDING), "status should be PENDING");

        uint256 sharesAfter = vault.balanceOf(userA);
        uint256 lockedAfter = vault.totalLockedShares();
        assertLt(sharesAfter, sharesBefore, "userA shares should decrease");
        assertGt(lockedAfter, lockedBefore, "totalLockedShares should increase");
        _step("  PASS: non-whitelisted & non-sanctioned user can requestRedeem when whitelist is disabled");

        _logPass();
    }
}
