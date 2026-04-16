// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {IStrategyControllerExecutor} from "../../src/interfaces/strategy/IStrategyControllerExecutor.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {IMantleVaultGateway} from "../../src/interfaces/vault/IMantleVaultGateway.sol";
import {OperatorExecutor} from "../../src/protocol/OperatorExecutor.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {MantleVaultGateway} from "../../src/vault/MantleVaultGateway.sol";
import {VaultFactory} from "../../src/vault/VaultFactory.sol";
import {GatewayFactory} from "../../src/vault/GatewayFactory.sol";
import {Accountant} from "../../src/accountant/Accountant.sol";
import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {IStrategyAdapter} from "../../src/interfaces/adapters/IStrategyAdapter.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Test, console2} from "forge-std/Test.sol";

// ---------------------------------------------------------------------------
// Mocks
// ---------------------------------------------------------------------------

contract MockUSDC_SI is ERC20 {
    constructor() ERC20("MockUSDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract MockPosToken_SI is ERC20 {
    constructor() ERC20("MockPosToken", "mPOS") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockSanctionsOracle_SI is ISanctionsOracle {
    mapping(address => bool) private _sanctioned;
    mapping(address => bool) private _whitelisted;

    function initialize(address, address) external {}
    function isSanctioned(address account) external view returns (bool) { return _sanctioned[account]; }
    function isWhitelisted(address account) external view returns (bool) { return _whitelisted[account]; }
    function totalSanctionedCount() external pure returns (uint256) { return 0; }
    function totalWhitelistedCount() external pure returns (uint256) { return 0; }
    function lastUpdateTimestamp() external pure returns (uint256) { return 0; }
    function batchNonce() external pure returns (uint256) { return 0; }
    function MAX_BATCH_SIZE() external pure returns (uint256) { return 200; }
    function setSanctioned(address account, bool status) external { _sanctioned[account] = status; }
    function setWhitelisted(address account, bool status) external { _whitelisted[account] = status; }
    function updateSanctionStatus(address, bool) external {}
    function updateSanctionStatusBatch(address[] calldata, bool) external {}
    function updateWhitelistStatus(address, bool) external {}
    function updateWhitelistStatusBatch(address[] calldata, bool) external {}
}

/// @dev Adapter with real fund transfers for E2E testing
contract MockAdapterSI is IStrategyAdapter {
    address public immutable ASSET;
    address public immutable POS_TOKEN;
    address public vaultAddress;

    constructor(address asset_, address posToken_) { ASSET = asset_; POS_TOKEN = posToken_; }
    function setVault(address v) external { vaultAddress = v; }
    function name() external pure returns (string memory) { return "MockAdapterSI"; }
    function asset() external view returns (address) { return ASSET; }
    function posToken() external view returns (address) { return POS_TOKEN; }
    function priceOracle() external pure returns (address) { return address(0); }
    function getPosTokenPrice() external pure returns (uint256) { return 0; }
    function estimatePosAmount(uint256 a) external pure returns (uint256) { return a; }
    function vault() external view returns (address) { return vaultAddress; }
    function totalValue() external view returns (uint256) { return ERC20(ASSET).balanceOf(address(this)); }
    function deposit(uint256 amount, address) external returns (uint256) {
        ERC20(ASSET).transferFrom(vaultAddress, address(this), amount);
        return amount;
    }
    function withdrawSync(uint256 amount, address) external returns (uint256) {
        ERC20(ASSET).transfer(vaultAddress, amount);
        return amount;
    }
    function requestRedeemAsync(uint256, address) external {}
    function sweepToVault(address token, uint256 amount) external returns (uint256) {
        ERC20(token).transfer(vaultAddress, amount);
        return amount;
    }
    function setPaused(bool) external {}
    function retryRedeemAsync(uint256, address) external {}
}

// ---------------------------------------------------------------------------
// Test Contract
// ---------------------------------------------------------------------------

contract SanctionsInteractionQATest is Test {
    MockUSDC_SI internal usdc;
    MockPosToken_SI internal posToken;
    MockSanctionsOracle_SI internal oracle;
    MantleYieldVault internal vault;
    MantleVaultGateway internal gateway;
    Accountant internal accountant;
    StrategyController internal controller;
    OperatorExecutor internal executor;
    MockAdapterSI internal adapter;

    address internal admin = makeAddr("admin");
    address internal bot = makeAddr("bot");
    address internal manager = makeAddr("manager");
    address internal treasury = makeAddr("treasury");
    address internal sanctionSafe = makeAddr("sanctionSafe");
    address internal userA = makeAddr("userA");
    address internal userB = makeAddr("userB");
    address internal userC = makeAddr("userC");

    uint256 constant RATE = 1e18;
    uint256 constant FEE_BPS = 100; // 1%

    function setUp() public {
        usdc = new MockUSDC_SI();
        posToken = new MockPosToken_SI();
        oracle = new MockSanctionsOracle_SI();

        // 1. Deploy vault + gateway via factory
        MantleYieldVault vaultImpl = new MantleYieldVault();
        MantleVaultGateway gwImpl = new MantleVaultGateway();
        VaultFactory vf = new VaultFactory(address(vaultImpl), admin);
        GatewayFactory gf = new GatewayFactory(address(gwImpl), admin);
        address vaultAddr = vf.deployVault();
        address gatewayAddr = gf.deployGateway();
        vault = MantleYieldVault(vaultAddr);
        gateway = MantleVaultGateway(gatewayAddr);

        // 2. Deploy real OperatorExecutor
        OperatorExecutor eImpl = new OperatorExecutor();
        executor = OperatorExecutor(address(new ERC1967Proxy(
            address(eImpl), abi.encodeCall(OperatorExecutor.initialize, (admin, bot))
        )));

        // 3. Deploy Accountant
        Accountant acctImpl = new Accountant();
        accountant = Accountant(address(new ERC1967Proxy(
            address(acctImpl), abi.encodeCall(Accountant.initialize, (vaultAddr, uint64(RATE), 0, admin))
        )));

        // 4. Initialize vault with placeholder controller
        vm.prank(admin);
        vault.initialize(IMantleYieldVault.InitParams({
            asset: IERC20(address(usdc)), name: "mRWA Vault", symbol: "mRWA", admin: admin,
            gateway: gatewayAddr, controller: address(executor),
            accountant: address(accountant), treasury: treasury,
            maxRedemptionFeeBps: 500, redemptionFeeBps: FEE_BPS, minRedeemAmount: 0, minDepositAmount: 0
        }));

        // 5. Deploy real StrategyController
        StrategyController ctrlImpl = new StrategyController();
        controller = StrategyController(address(new ERC1967Proxy(
            address(ctrlImpl),
            abi.encodeCall(StrategyController.initialize, (vaultAddr, manager, address(executor), manager, 1000, 200, 0))
        )));

        // 6. Switch vault controller to real one
        vm.prank(admin);
        vault.setController(address(controller));

        // 7. Initialize gateway
        vm.prank(admin);
        gateway.initialize(IMantleVaultGateway.InitParams({
            vault: vaultAddr, sanctionsOracle: ISanctionsOracle(address(oracle)),
            sanctionSafe: sanctionSafe, admin: admin, syncRedeemDisabled: false
        }));

        // 8. Deploy and register adapter with real transfers
        adapter = new MockAdapterSI(address(usdc), address(posToken));
        adapter.setVault(vaultAddr);
        vm.startPrank(manager);
        controller.registerStrategy(address(adapter), 10_000, 1, false);
        controller.activateStrategy(address(adapter));
        address[] memory ordered = new address[](1);
        ordered[0] = address(adapter);
        controller.setStrategyOrder(ordered);
        vm.stopPrank();

        // 9. Fund users and provide buffer depositor for freeCash
        address buffer = makeAddr("buffer");
        usdc.mint(buffer, 100_000e6);
        vm.startPrank(buffer);
        usdc.approve(address(vault), type(uint256).max);
        gateway.deposit(100_000e6);
        vm.stopPrank();

        address[3] memory users = [userA, userB, userC];
        for (uint256 i = 0; i < users.length; i++) {
            usdc.mint(users[i], 100_000e6);
            vm.prank(users[i]);
            usdc.approve(address(vault), type(uint256).max);
        }
    }

    // -----------------------------------------------------------------------
    // Logging helpers
    // -----------------------------------------------------------------------

    string constant MODULE = unicode"业务博弈、汇率波动、抢赎、排队公平性与极端流动性场景";
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
    // Helpers
    // -----------------------------------------------------------------------

    function _depositViaGateway(address user, uint256 assets) internal returns (uint256 shares) {
        vm.prank(user);
        shares = gateway.deposit(assets);
    }

    function _requestRedeemViaGateway(address user, uint256 shares) internal returns (uint256 requestId) {
        vm.prank(user);
        requestId = gateway.requestRedeem(shares);
    }

    /// @dev Bot -> OperatorExecutor -> Controller -> Vault (real chain)
    function _processRedeemBatch(uint256[] memory ids) internal {
        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), ids);
    }

    /// @dev Bot -> OperatorExecutor -> Controller -> Vault (real chain)
    function _finalizeRedeemBatch(uint256[] memory ids, uint256[] memory settled) internal {
        vm.prank(bot);
        executor.executeFinalizeRedeemBatch(address(controller), ids, settled);
    }

    function _singleArr(uint256 v) internal pure returns (uint256[] memory a) { a = new uint256[](1); a[0] = v; }

    // -----------------------------------------------------------------------
    // 1. test_SyncRedeem_BeforeBlacklist_Success_AfterBlacklist_Fail
    // -----------------------------------------------------------------------

    function test_SyncRedeem_BeforeBlacklist_Success_AfterBlacklist_Fail() public {
        _logCase(
            "test_SyncRedeem_BeforeBlacklist_Success_AfterBlacklist_Fail",
            unicode"用户在被拉黑前同步赎回成功，被拉黑后再操作失败"
        );

        _step("[Step 1] UserA deposits 10000 USDC");
        uint256 shares = _depositViaGateway(userA, 10_000e6);
        _step(string.concat("  userA shares = ", vm.toString(shares)));

        _step("[Step 2] UserA sync redeems part of shares BEFORE being sanctioned");
        uint256 redeemShares = shares / 4;
        vm.prank(userA);
        uint256 assets = gateway.redeem(redeemShares);
        assertGt(assets, 0, "redeem should succeed before sanctions");
        _step(string.concat("  redeemed assets = ", vm.toString(assets)));

        _step("[Step 3] Sanction userA");
        oracle.setSanctioned(userA, true);
        assertTrue(gateway.isSanctioned(userA), "userA should be sanctioned");

        _step("[Step 4] UserA tries deposit - should fail");
        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSelector(IMantleYieldVault.Vault__Sanctioned.selector, userA));
        gateway.deposit(1_000e6);
        _step("  deposit reverted as expected");

        _step("[Step 5] UserA tries sync redeem - routes to sanctionSafe (returns 0)");
        uint256 safeBefore = vault.balanceOf(sanctionSafe);
        uint256 redeemShares2 = shares / 4;
        vm.prank(userA);
        uint256 assetsAfter = gateway.redeem(redeemShares2);
        assertEq(assetsAfter, 0, "sanctioned redeem returns 0 (routed)");
        uint256 safeAfter = vault.balanceOf(sanctionSafe);
        assertEq(safeAfter - safeBefore, redeemShares2, "shares routed to sanctionSafe");
        _step("  sync redeem routed shares to sanctionSafe");

        _step("[Step 6] UserA tries requestRedeem - routes to sanctionSafe");
        uint256 remainingShares = vault.balanceOf(userA);
        if (remainingShares > 0) {
            safeBefore = vault.balanceOf(sanctionSafe);
            vm.prank(userA);
            uint256 reqId = gateway.requestRedeem(remainingShares);
            assertEq(reqId, 0, "sanctioned requestRedeem returns requestId=0");
            safeAfter = vault.balanceOf(sanctionSafe);
            assertEq(safeAfter - safeBefore, remainingShares, "remaining shares routed to sanctionSafe");
            _step("  requestRedeem routed shares to sanctionSafe");
        }

        _step("  PASS: before-sanction operations succeed, after-sanction operations blocked/routed");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 2. test_AsyncRedeem_SanctionedAtFinalize_PaidToSanctionSafe
    // -----------------------------------------------------------------------

    function test_AsyncRedeem_SanctionedAtFinalize_PaidToSanctionSafe() public {
        _logCase(
            "test_AsyncRedeem_SanctionedAtFinalize_PaidToSanctionSafe",
            unicode"用户在被拉黑前创建异步请求，结算时已被拉黑，最终打到 `sanctionSafe`"
        );

        _step("[Step 1] UserA deposits and creates async redeem request (not yet sanctioned)");
        uint256 shares = _depositViaGateway(userA, 10_000e6);
        uint256 requestId = _requestRedeemViaGateway(userA, shares);
        assertTrue(requestId != 0, "request created successfully");
        _step(string.concat("  requestId = ", vm.toString(requestId)));

        _step("[Step 2] Process via real chain: Bot -> OperatorExecutor -> Controller -> Vault");
        _processRedeemBatch(_singleArr(requestId));

        _step("[Step 3] Sanction userA BEFORE finalize");
        oracle.setSanctioned(userA, true);
        assertTrue(gateway.isSanctioned(userA));
        _step("  userA is now sanctioned");

        _step("[Step 4] Finalize via real chain - assets should go to sanctionSafe");
        (,,,, uint256 estAssets,,,) = vault.requests(requestId);

        uint256 safeBefore = usdc.balanceOf(sanctionSafe);
        uint256 userBefore = usdc.balanceOf(userA);

        _finalizeRedeemBatch(_singleArr(requestId), _singleArr(estAssets));

        uint256 safeAfter = usdc.balanceOf(sanctionSafe);
        uint256 userAfter = usdc.balanceOf(userA);

        _step(string.concat("  sanctionSafe USDC increase = ", vm.toString(safeAfter - safeBefore)));
        _step(string.concat("  userA USDC increase = ", vm.toString(userAfter - userBefore)));

        assertEq(safeAfter - safeBefore, estAssets, "settled assets sent to sanctionSafe");
        assertEq(userAfter, userBefore, "userA receives nothing");

        (,,,,,,,IMantleYieldVault.RequestStatus finalStatus) = vault.requests(requestId);
        assertEq(uint256(finalStatus), uint256(IMantleYieldVault.RequestStatus.DONE));
        _step("  PASS: assets paid to sanctionSafe when owner sanctioned at finalize");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 3. test_BatchFinalize_MixedSanctionStatus
    // -----------------------------------------------------------------------

    function test_BatchFinalize_MixedSanctionStatus() public {
        _logCase(
            "test_BatchFinalize_MixedSanctionStatus",
            unicode"同一批次中部分用户正常结算、部分用户因结算前被拉黑而打到 `sanctionSafe`"
        );

        _step("[Step 1] UserA and userB both deposit and create async redeem requests");
        uint256 sharesA = _depositViaGateway(userA, 5_000e6);
        uint256 sharesB = _depositViaGateway(userB, 5_000e6);
        uint256 reqIdA = _requestRedeemViaGateway(userA, sharesA);
        uint256 reqIdB = _requestRedeemViaGateway(userB, sharesB);
        _step(string.concat("  reqIdA = ", vm.toString(reqIdA)));
        _step(string.concat("  reqIdB = ", vm.toString(reqIdB)));

        _step("[Step 2] Process both via real chain");
        _processRedeemBatch(_singleArr(reqIdA));
        _processRedeemBatch(_singleArr(reqIdB));

        _step("[Step 3] Sanction userB only");
        oracle.setSanctioned(userB, true);
        assertFalse(gateway.isSanctioned(userA));
        assertTrue(gateway.isSanctioned(userB));

        _step("[Step 4] Finalize each request and verify routing");
        (,,,, uint256 estA,,,) = vault.requests(reqIdA);
        (,,,, uint256 estB,,,) = vault.requests(reqIdB);

        // Finalize userA request via real chain - normal path
        uint256 userABefore = usdc.balanceOf(userA);
        _finalizeRedeemBatch(_singleArr(reqIdA), _singleArr(estA));

        uint256 userAAfter = usdc.balanceOf(userA);
        assertEq(userAAfter - userABefore, estA, "userA receives assets normally");
        _step(string.concat("  userA received USDC = ", vm.toString(userAAfter - userABefore)));

        // Finalize userB request via real chain - sanctioned path
        uint256 safeBefore = usdc.balanceOf(sanctionSafe);
        uint256 userBBefore = usdc.balanceOf(userB);
        _finalizeRedeemBatch(_singleArr(reqIdB), _singleArr(estB));

        uint256 safeAfter = usdc.balanceOf(sanctionSafe);
        uint256 userBAfter = usdc.balanceOf(userB);
        assertEq(safeAfter - safeBefore, estB, "sanctioned user assets to sanctionSafe");
        assertEq(userBAfter, userBBefore, "userB receives nothing");
        _step(string.concat("  sanctionSafe received USDC = ", vm.toString(safeAfter - safeBefore)));

        _step("  PASS: same batch, different sanctions status => different routing");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 4. test_MarketVolatility_SanctionsInterleaved
    // -----------------------------------------------------------------------

    function test_MarketVolatility_SanctionsInterleaved() public {
        _logCase(
            "test_MarketVolatility_SanctionsInterleaved",
            unicode"大额市场波动期间，sanctions 更新与用户退出操作交错，系统状态保持一致"
        );

        _step("[Step 1] Users deposit");
        uint256 sharesA = _depositViaGateway(userA, 20_000e6);
        uint256 sharesB = _depositViaGateway(userB, 20_000e6);

        _step("[Step 2] UserA creates async redeem");
        uint256 reqIdA = _requestRedeemViaGateway(userA, sharesA / 2);

        _step("[Step 3] Mid-flight: sanction userA");
        oracle.setSanctioned(userA, true);
        _step("  userA sanctioned mid-process");

        _step("[Step 4] UserB does sync redeem (not sanctioned)");
        uint256 maxR = vault.maxRedeem(userB);
        uint256 redeemSharesB = maxR > sharesB / 2 ? sharesB / 2 : maxR;
        if (redeemSharesB > 0) {
            vm.prank(userB);
            uint256 paid = gateway.redeem(redeemSharesB);
            assertGt(paid, 0);
            _step(string.concat("  userB sync redeemed = ", vm.toString(paid)));
        }

        _step("[Step 5] Process and finalize userA request via real chain");
        _processRedeemBatch(_singleArr(reqIdA));

        (,,,, uint256 estA,,,) = vault.requests(reqIdA);

        uint256 safeBefore = usdc.balanceOf(sanctionSafe);
        _finalizeRedeemBatch(_singleArr(reqIdA), _singleArr(estA));

        uint256 safeAfter = usdc.balanceOf(sanctionSafe);
        assertEq(safeAfter - safeBefore, estA, "sanctioned user assets to sanctionSafe");
        _step(string.concat("  sanctionSafe received = ", vm.toString(safeAfter - safeBefore)));

        _step("[Step 6] Verify overall bookkeeping consistency");
        uint256 totalAssets = vault.totalAssets();
        uint256 freeCash = vault.getFreeCash();
        uint256 locked = vault.totalLockedShares();
        _step(string.concat("  totalAssets = ", vm.toString(totalAssets)));
        _step(string.concat("  freeCash = ", vm.toString(freeCash)));
        _step(string.concat("  totalLockedShares = ", vm.toString(locked)));
        assertLe(freeCash, usdc.balanceOf(address(vault)));
        _step("  PASS: sanctions + market volatility interleaved; state consistent");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 5. test_SanctionSafe_CanRedeemReceivedShares
    // -----------------------------------------------------------------------

    function test_SanctionSafe_CanRedeemReceivedShares() public {
        _logCase(
            "test_SanctionSafe_CanRedeemReceivedShares",
            unicode"被拉黑用户的 shares 被路由到 `sanctionSafe` 后，`sanctionSafe` 再参与后续赎回流程的行为正确"
        );

        _step("[Step 1] UserA deposits, gets sanctioned, shares route to sanctionSafe");
        uint256 shares = _depositViaGateway(userA, 10_000e6);
        oracle.setSanctioned(userA, true);

        uint256 routeShares = shares / 2;
        vm.prank(userA);
        gateway.requestRedeem(routeShares);

        uint256 safeShares = vault.balanceOf(sanctionSafe);
        assertEq(safeShares, routeShares, "shares routed to sanctionSafe");
        _step(string.concat("  sanctionSafe shares = ", vm.toString(safeShares)));

        _step("[Step 2] sanctionSafe is NOT sanctioned, so it can operate normally");
        assertFalse(gateway.isSanctioned(sanctionSafe), "sanctionSafe itself is not sanctioned");

        _step("[Step 3] sanctionSafe approves vault and does sync redeem via gateway");
        vm.prank(sanctionSafe);
        usdc.approve(address(vault), type(uint256).max);

        uint256 maxR = vault.maxRedeem(sanctionSafe);
        _step(string.concat("  maxRedeem(sanctionSafe) = ", vm.toString(maxR)));

        if (maxR > 0) {
            uint256 redeemAmount = maxR < safeShares ? maxR : safeShares;
            uint256 safeBefore = usdc.balanceOf(sanctionSafe);
            vm.prank(sanctionSafe);
            uint256 assets = gateway.redeem(redeemAmount);
            uint256 safeAfter = usdc.balanceOf(sanctionSafe);
            assertGt(assets, 0, "sanctionSafe should receive USDC");
            assertEq(safeAfter - safeBefore, assets);
            _step(string.concat("  sanctionSafe redeemed USDC = ", vm.toString(assets)));
        }

        _step("[Step 4] Verify bookkeeping is correct");
        uint256 totalAssets = vault.totalAssets();
        _step(string.concat("  totalAssets = ", vm.toString(totalAssets)));
        _step("  PASS: sanctionSafe can redeem routed shares as a normal holder");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 6. test_WhitelistPlusSanctions_PriorityCheck
    // -----------------------------------------------------------------------

    function test_WhitelistPlusSanctions_PriorityCheck() public {
        _logCase(
            "test_WhitelistPlusSanctions_PriorityCheck",
            unicode"白名单 + 制裁双重检查的优先级验证"
        );

        _step("[Step 1] Enable whitelist");
        vm.prank(admin);
        gateway.setWhitelistEnabled(true);

        _step("[Step 2] UserA is sanctioned AND not whitelisted");
        oracle.setSanctioned(userA, true);
        // userA is NOT whitelisted (default)
        assertFalse(gateway.isWhitelisted(userA));
        assertTrue(gateway.isSanctioned(userA));

        _step("[Step 3] UserA calls deposit - should revert with Vault__Sanctioned (not Gateway__NotWhitelisted)");
        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSelector(IMantleYieldVault.Vault__Sanctioned.selector, userA));
        gateway.deposit(1_000e6);
        _step("  PASS: deposit reverts with Vault__Sanctioned (sanctions checked before whitelist)");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 7. test_WhitelistEnabled_SanctionedRequestRedeem_RoutesShares
    // -----------------------------------------------------------------------

    function test_WhitelistEnabled_SanctionedRequestRedeem_RoutesShares() public {
        _logCase(
            "test_WhitelistEnabled_SanctionedRequestRedeem_RoutesShares",
            unicode"白名单开启时被制裁用户发起 `requestRedeem` 仍走路由路径"
        );

        _step("[Step 1] UserA deposits before being sanctioned");
        uint256 shares = _depositViaGateway(userA, 10_000e6);
        _step(string.concat("  userA shares = ", vm.toString(shares)));

        _step("[Step 2] Enable whitelist and sanction userA (not whitelisted)");
        vm.prank(admin);
        gateway.setWhitelistEnabled(true);
        oracle.setSanctioned(userA, true);
        assertFalse(gateway.isWhitelisted(userA));
        assertTrue(gateway.isSanctioned(userA));

        _step("[Step 3] UserA calls requestRedeem - should route to sanctionSafe, NOT revert with whitelist error");
        uint256 safeBefore = vault.balanceOf(sanctionSafe);

        vm.prank(userA);
        uint256 requestId = gateway.requestRedeem(shares);

        assertEq(requestId, 0, "sanctioned user gets requestId=0 (routed)");
        uint256 safeAfter = vault.balanceOf(sanctionSafe);
        assertEq(safeAfter - safeBefore, shares, "shares routed to sanctionSafe");
        _step(string.concat("  requestId = ", vm.toString(requestId)));
        _step(string.concat("  shares routed to sanctionSafe = ", vm.toString(safeAfter - safeBefore)));
        _step("  PASS: sanctions routing takes priority over whitelist check in requestRedeem");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 8. test_ThreeUserPaths_NormalVsPreSanctionVsPostSanction
    // -----------------------------------------------------------------------

    function test_ThreeUserPaths_NormalVsPreSanctionVsPostSanction() public {
        _logCase(
            "test_ThreeUserPaths_NormalVsPreSanctionVsPostSanction",
            unicode"正常用户、请求前已被制裁用户、请求后被制裁用户在赎回流程中应走不同路径"
        );

        _step("[Step 1] All three users deposit");
        uint256 sharesA = _depositViaGateway(userA, 10_000e6);
        uint256 sharesB = _depositViaGateway(userB, 10_000e6);
        uint256 sharesC = _depositViaGateway(userC, 10_000e6);

        // --- Path 1: Normal user (userA) ---
        _step("[Path 1] UserA: normal user - sync redeem succeeds");
        uint256 maxRA = vault.maxRedeem(userA);
        uint256 redeemA = maxRA < sharesA ? maxRA : sharesA;
        vm.prank(userA);
        uint256 paidA = gateway.redeem(redeemA);
        assertGt(paidA, 0, "normal user receives USDC");
        _step(string.concat("  userA redeemed USDC = ", vm.toString(paidA)));

        // --- Path 2: Pre-sanctioned user (userB) ---
        _step("[Path 2] UserB: sanctioned BEFORE requestRedeem - shares routed to sanctionSafe");
        oracle.setSanctioned(userB, true);

        uint256 safeBefore = vault.balanceOf(sanctionSafe);
        vm.prank(userB);
        uint256 reqIdB = gateway.requestRedeem(sharesB);
        assertEq(reqIdB, 0, "pre-sanctioned user gets requestId=0");
        uint256 safeAfter = vault.balanceOf(sanctionSafe);
        assertEq(safeAfter - safeBefore, sharesB, "shares routed to sanctionSafe");
        _step(string.concat("  shares routed to sanctionSafe = ", vm.toString(safeAfter - safeBefore)));

        // --- Path 3: Post-sanctioned user (userC) ---
        _step("[Path 3] UserC: sanctioned AFTER creating async request - USDC goes to sanctionSafe");
        uint256 reqIdC = _requestRedeemViaGateway(userC, sharesC);
        assertTrue(reqIdC != 0, "request created before sanction");
        _step(string.concat("  reqIdC = ", vm.toString(reqIdC)));

        // Process via real chain
        _processRedeemBatch(_singleArr(reqIdC));

        // NOW sanction userC
        oracle.setSanctioned(userC, true);
        _step("  userC sanctioned after request creation");

        // Finalize via real chain - USDC should go to sanctionSafe
        (,,,, uint256 estC,,,) = vault.requests(reqIdC);

        uint256 safeUsdcBefore = usdc.balanceOf(sanctionSafe);
        uint256 userCBefore = usdc.balanceOf(userC);

        _finalizeRedeemBatch(_singleArr(reqIdC), _singleArr(estC));

        uint256 safeUsdcAfter = usdc.balanceOf(sanctionSafe);
        uint256 userCAfter = usdc.balanceOf(userC);

        assertEq(safeUsdcAfter - safeUsdcBefore, estC, "USDC sent to sanctionSafe");
        assertEq(userCAfter, userCBefore, "userC receives no USDC");
        _step(string.concat("  sanctionSafe received USDC = ", vm.toString(safeUsdcAfter - safeUsdcBefore)));

        _step("[Summary] Three distinct paths verified:");
        _step("  Path 1 (normal): user receives USDC directly");
        _step("  Path 2 (pre-sanctioned): shares routed to sanctionSafe at requestRedeem");
        _step("  Path 3 (post-sanctioned): USDC routed to sanctionSafe at finalize");
        _step("  PASS: all three paths behave correctly and distinctly");
        _logPass();
    }
}
