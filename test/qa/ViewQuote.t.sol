// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SanctionsOracle} from "../../src/compliance/SanctionsOracle.sol";
import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {IStrategyAdapter} from "../../src/interfaces/adapters/IStrategyAdapter.sol";
import {IMantleVaultGateway} from "../../src/interfaces/vault/IMantleVaultGateway.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {MantleVaultGateway} from "../../src/vault/MantleVaultGateway.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {OperatorExecutor} from "../../src/protocol/OperatorExecutor.sol";
import {Accountant} from "../../src/accountant/Accountant.sol";
import {AccountantExecutor} from "../../src/accountant/AccountantExecutor.sol";
import {VaultFactory} from "../../src/vault/VaultFactory.sol";
import {GatewayFactory} from "../../src/vault/GatewayFactory.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IStrategyControllerExecutor} from "../../src/interfaces/strategy/IStrategyControllerExecutor.sol";
import {Test, console2} from "forge-std/Test.sol";

// ---------------------------------------------------------------------------
// Mock contracts
// ---------------------------------------------------------------------------

contract MockUSDC_VQ is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockPosToken_VQ is ERC20 {
    constructor() ERC20("Position Token", "POS") {}

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

contract MockStrategyAdapter_VQ is IStrategyAdapter {
    MockPosToken_VQ public mockPosToken;
    uint256 public mockPrice = 1e18;
    address public immutable ASSET;
    address public immutable VAULT;

    constructor(address asset_, address vault_) {
        ASSET = asset_;
        VAULT = vault_;
        mockPosToken = new MockPosToken_VQ();
    }

    function name() external pure override returns (string memory) {
        return "MockAdapter";
    }

    function asset() external view override returns (address) {
        return ASSET;
    }

    function posToken() external view override returns (address) {
        return address(mockPosToken);
    }

    function priceOracle() external pure override returns (address) {
        return address(0);
    }

    function getPosTokenPrice() external view override returns (uint256) {
        return mockPrice;
    }

    function setMockPrice(uint256 price) external {
        mockPrice = price;
    }

    function estimatePosAmount(uint256 assetAmount) external pure override returns (uint256) {
        return assetAmount;
    }

    function minSubscribeAsset() external pure returns (uint256) { return 0; }
    function minRedeemPos() external pure returns (uint256) { return 0; }

    function previewDeposit(uint256 assetAmount)
        external
        pure
        override
        returns (bool ok, uint256 executableAssetAmount, uint256 expectedPosAmount)
    {
        ok = assetAmount > 0;
        executableAssetAmount = assetAmount;
        expectedPosAmount = assetAmount; // 1:1 at price 1e18
    }

    function previewRedeem(uint256 assetAmount)
        external
        pure
        override
        returns (bool ok, uint256 executableAssetAmount, uint256 expectedPosAmount)
    {
        ok = assetAmount > 0;
        executableAssetAmount = assetAmount;
        expectedPosAmount = assetAmount;
    }

    function vault() external view override returns (address) {
        return VAULT;
    }

    function totalValue() external view override returns (uint256) {
        return IERC20(ASSET).balanceOf(address(this));
    }

    function deposit(uint256 amount, address) external override returns (uint256) {
        IERC20(ASSET).transferFrom(VAULT, address(this), amount);
        mockPosToken.mint(address(this), amount);
        return amount;
    }

    function withdrawSync(uint256 posAmount, address) external override returns (uint256) {
        uint256 bal = IERC20(ASSET).balanceOf(address(this));
        uint256 actual = posAmount > bal ? bal : posAmount;
        if (actual > 0) mockPosToken.burn(address(this), actual);
        return actual;
    }

    function requestRedeemAsync(uint256, address) external pure override {}

    function sweepToVault(address token, uint256 amount) external override returns (uint256) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 actual = amount > bal ? bal : amount;
        if (actual > 0) IERC20(token).transfer(VAULT, actual);
        return actual;
    }

    function setPaused(bool) external pure override {}

    function retryRedeemAsync(uint256, address) external {}
}

/**
 * @title  ViewQuoteQATest
 * @notice QA scenario tests for view/quote functions (查询与报价场景).
 */
contract ViewQuoteQATest is Test {
    MockUSDC_VQ internal usdc;
    SanctionsOracle internal oracle;
    Accountant internal accountant;
    AccountantExecutor internal accountantExecutor;
    MockStrategyAdapter_VQ internal adapter;
    MantleYieldVault internal vault;
    MantleVaultGateway internal gateway;
    StrategyController internal controller;
    OperatorExecutor internal executor;
    VaultFactory internal vaultFactory;
    GatewayFactory internal gatewayFactory;

    address internal admin = makeAddr("admin");
    address internal compliance = makeAddr("compliance");
    address internal bot = makeAddr("bot");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal sanctionedUser = makeAddr("sanctionedUser");

    uint256 constant INITIAL_DEPOSIT = 1_000e6;

    string constant MODULE = unicode"查询与报价场景";
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

    function setUp() public {
        vm.warp(1000);

        usdc = new MockUSDC_VQ();
        SanctionsOracle oracleImpl = new SanctionsOracle();
        oracle = SanctionsOracle(address(new ERC1967Proxy(
            address(oracleImpl),
            abi.encodeCall(SanctionsOracle.initialize, (admin, compliance))
        )));

        // Deploy vault + gateway via factories
        MantleYieldVault vaultImpl = new MantleYieldVault();
        MantleVaultGateway gwImpl = new MantleVaultGateway();
        OperatorExecutor execImpl = new OperatorExecutor();
        Accountant accountantImpl = new Accountant();
        AccountantExecutor accountantExecutorImpl = new AccountantExecutor();
        vaultFactory = new VaultFactory(address(vaultImpl), admin);
        gatewayFactory = new GatewayFactory(address(gwImpl), admin);

        address vaultAddr = vaultFactory.deployVault();
        address gwAddr = gatewayFactory.deployGateway();
        address accountantAddr = address(new ERC1967Proxy(
            address(accountantImpl),
            abi.encodeCall(Accountant.initialize, (vaultAddr, uint64(1e18), uint32(100), admin, admin, admin))
        ));
        address accountantExecutorAddr = address(new ERC1967Proxy(
            address(accountantExecutorImpl),
            abi.encodeCall(AccountantExecutor.initialize, (admin))
        ));
        vault = MantleYieldVault(vaultAddr);
        gateway = MantleVaultGateway(gwAddr);
        accountant = Accountant(accountantAddr);
        accountantExecutor = AccountantExecutor(accountantExecutorAddr);

        vm.startPrank(admin);
        accountant.grantRole(accountant.ACCOUNTANT_EXECUTOR_ROLE(), address(accountantExecutor));
        accountantExecutor.grantRole(accountantExecutor.BOT_ROLE(), bot);
        vm.stopPrank();

        // Initialize vault with a temp controller (will be replaced)
        address tempController = makeAddr("tempController");
        vm.prank(admin);
        vault.initialize(
            IMantleYieldVault.InitParams({
                asset: IERC20(address(usdc)),
                name: "Mantle RWA Vault",
                symbol: "mRWA",
                admin: admin,
                gateway: gwAddr,
                controller: tempController,
                accountant: accountantAddr,
                treasury: treasury,
                maxRedemptionFeeBps: 500,
                redemptionFeeBps: 100,
                minRedeemAmount: 0,
                minDepositAmount: 0,
                maxSettlementDeviationBps: 0,
                depositDailyRemaining: type(uint256).max,
                redeemDailyRemaining: type(uint256).max
            })
        );

        // Deploy real OperatorExecutor via ERC1967Proxy
        executor = OperatorExecutor(address(new ERC1967Proxy(
            address(execImpl),
            abi.encodeCall(OperatorExecutor.initialize, (admin, bot))
        )));

        // Deploy controller via ERC1967Proxy with real executor
        StrategyController controllerImpl = new StrategyController();
        bytes memory initData = abi.encodeCall(
            StrategyController.initialize,
            (vaultAddr, admin, address(executor), admin, 1000, 200, 0)
        );
        controller = StrategyController(address(new ERC1967Proxy(address(controllerImpl), initData)));

        // Update vault controller to the real one
        vm.prank(admin);
        vault.setController(address(controller));

        vm.prank(admin);
        gateway.initialize(
            IMantleVaultGateway.InitParams({
                vault: vaultAddr,
                sanctionsOracle: ISanctionsOracle(address(oracle)),
                sanctionSafe: treasury,
                admin: admin,
                syncRedeemDisabled: false
            })
        );

        // Deploy adapter (needs vault address for real token transfers)
        adapter = new MockStrategyAdapter_VQ(address(usdc), address(vault));

        // Fund and deposit for alice
        usdc.mint(alice, INITIAL_DEPOSIT * 10);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        gateway.deposit(INITIAL_DEPOSIT);
        vm.stopPrank();
    }

    function _depositForUser(address user, uint256 amount) internal {
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(vault), type(uint256).max);
        gateway.deposit(amount);
        vm.stopPrank();
    }

    function _updateSanctionStatus(address account, bool status) internal {
        vm.prank(compliance);
        oracle.updateSanctionStatus(account, status);
    }

    function _setRateReal(uint64 newRate) internal {
        uint256 currentRate = accountant.lastExchangeRate();
        if (newRate == currentRate) {
            return;
        }

        uint256 larger = newRate > currentRate ? uint256(newRate) : currentRate;
        uint256 smaller = newRate > currentRate ? currentRate : uint256(newRate);
        uint256 deviationBps = larger > 0 ? ((larger - smaller) * 10_000) / larger : 0;
        uint32 maxDeviationCeiling = accountant.MAX_DEVIATION_CEILING();

        if (deviationBps <= maxDeviationCeiling) {
            vm.prank(admin);
            accountant.setRiskParams(maxDeviationCeiling, 0);
            vm.warp(block.timestamp + 1);
            vm.prank(bot);
            accountantExecutor.executeUpdateRate(address(accountant), newRate, uint64(block.timestamp));
            return;
        }

        vm.prank(admin);
        accountant.emergencyRateUpdate(newRate);
    }

    // =============================================================
    //  P0 - maxDeposit / maxRedeem for sanctioned users
    // =============================================================

    function test_MaxDeposit_SanctionedReturnsZero() public {
        _logCase("test_MaxDeposit_SanctionedReturnsZero", unicode"`gateway.maxDeposit` 对被制裁用户返回 0");

        _step("[Step 1] Sanction sanctionedUser through the real oracle flow");
        _updateSanctionStatus(sanctionedUser, true);
        assertTrue(oracle.isSanctioned(sanctionedUser));
        _step("  PASS: sanctionedUser is sanctioned");

        _step("[Step 2] Call gateway.maxDeposit(sanctionedUser)");
        uint256 maxDep = gateway.maxDeposit(sanctionedUser);
        assertEq(maxDep, 0);
        _step(string.concat("  maxDeposit: ", vm.toString(maxDep)));
        _step("  PASS: returns 0 for sanctioned user");

        _logPass();
    }

    function test_MaxRedeem_SanctionedReturnsZero() public {
        _logCase("test_MaxRedeem_SanctionedReturnsZero", unicode"`gateway.maxRedeem` 对被制裁用户返回 0");

        _step("[Step 1] Fund sanctionedUser and deposit so the account really holds shares");
        _depositForUser(sanctionedUser, INITIAL_DEPOSIT);
        uint256 sharesBefore = vault.balanceOf(sanctionedUser);
        assertTrue(sharesBefore > 0, "sanctioned user should hold shares before sanction");
        _step(string.concat("  sanctionedUser shares before sanction: ", vm.toString(sharesBefore)));

        _step("[Step 2] Sanction sanctionedUser through the real oracle flow");
        _updateSanctionStatus(sanctionedUser, true);
        assertTrue(oracle.isSanctioned(sanctionedUser));
        _step("  PASS: sanctionedUser is sanctioned");

        _step("[Step 3] Call gateway.maxRedeem(sanctionedUser)");
        uint256 maxRed = gateway.maxRedeem(sanctionedUser);
        assertEq(maxRed, 0);
        _step(string.concat("  maxRedeem: ", vm.toString(maxRed)));
        _step("  PASS: returns 0 for sanctioned user");

        _logPass();
    }

    // =============================================================
    //  P0 - Accountant paused => maxDeposit/maxRedeem return 0
    // =============================================================

    function test_AccountantPaused_MaxDepositMaxRedeemZero() public {
        _logCase(
            "test_AccountantPaused_MaxDepositMaxRedeemZero",
            unicode"Accountant 暂停时 Gateway 的 `maxDeposit/maxRedeem` 返回 0"
        );

        _step("[Step 1] Verify alice holds shares before pausing");
        uint256 aliceShares = vault.balanceOf(alice);
        assertTrue(aliceShares > 0, "alice should hold shares from setUp deposit");
        _step(string.concat("  alice share balance: ", vm.toString(aliceShares)));
        _step("  PASS: alice holds shares");

        _step("[Step 2] Pause the real accountant");
        vm.prank(admin);
        accountant.pause();
        _step("  accountant paused");

        _step("[Step 3] Call gateway.maxDeposit(alice) -- alice is not sanctioned, has shares");
        uint256 maxDep = gateway.maxDeposit(alice);
        assertEq(maxDep, 0);
        _step(string.concat("  maxDeposit(alice): ", vm.toString(maxDep)));
        _step("  PASS: returns 0 when Accountant is paused");

        _step("[Step 4] Call gateway.maxRedeem(alice)");
        uint256 maxRed = gateway.maxRedeem(alice);
        assertEq(maxRed, 0);
        _step(string.concat("  maxRedeem(alice): ", vm.toString(maxRed)));
        _step("  PASS: returns 0 when Accountant is paused");

        _logPass();
    }

    // =============================================================
    //  P1 - syncRedeemDisabled does not affect maxRedeem view
    // =============================================================

    function test_SyncRedeemDisabled_MaxRedeemStillNonZero() public {
        _logCase(
            "test_SyncRedeemDisabled_MaxRedeemStillNonZero",
            unicode"`syncRedeemDisabled` 当前不影响 `gateway.maxRedeem` 的展示值"
        );

        _step("[Step 1] Enable syncRedeemDisabled");
        vm.prank(admin);
        gateway.setSyncRedeemDisabled(true);
        assertTrue(gateway.syncRedeemDisabled());
        _step("  PASS: syncRedeemDisabled is true");

        _step("[Step 2] Query gateway.maxRedeem(alice) -- should still be non-zero");
        uint256 maxRed = gateway.maxRedeem(alice);
        _step(string.concat("  maxRedeem(alice): ", vm.toString(maxRed)));
        assertTrue(maxRed > 0);
        _step("  PASS: maxRedeem > 0 even when syncRedeemDisabled");

        _step("[Step 3] Actual gateway.redeem should fail with SyncRedeemDisabled");
        vm.prank(alice);
        vm.expectRevert(IMantleYieldVault.Vault__SyncRedeemDisabled.selector);
        gateway.redeem(1);
        _step("  PASS: gateway.redeem reverted with Vault__SyncRedeemDisabled");

        _logPass();
    }

    // =============================================================
    //  P1 - Preview consistency
    // =============================================================

    function test_PreviewRedeem_PreviewDeposit_Consistency() public {
        _logCase(
            "test_PreviewRedeem_PreviewDeposit_Consistency",
            unicode"Gateway `previewRedeem/previewDeposit` 与 Vault 一致"
        );

        _step("[Step 1] Set rate to 1.1e18 for interesting values");
        _setRateReal(1.1e18);

        _step("[Step 2] Compare gateway.previewRedeem vs vault.previewRedeem");
        uint256 shares = 100e6;
        uint256 gwPreviewRedeem = gateway.previewRedeem(shares);
        uint256 vaultPreviewRedeem = vault.previewRedeem(shares);
        assertEq(gwPreviewRedeem, vaultPreviewRedeem);
        _step(string.concat("  gateway.previewRedeem(", vm.toString(shares), "): ", vm.toString(gwPreviewRedeem)));
        _step(string.concat("  vault.previewRedeem(", vm.toString(shares), "): ", vm.toString(vaultPreviewRedeem)));
        _step("  PASS: values match");

        _step("[Step 3] Compare gateway.previewDeposit vs vault.previewDeposit");
        uint256 assets = 100e6;
        uint256 gwPreviewDeposit = gateway.previewDeposit(assets);
        uint256 vaultPreviewDeposit = vault.previewDeposit(assets);
        assertEq(gwPreviewDeposit, vaultPreviewDeposit);
        _step(string.concat("  gateway.previewDeposit(", vm.toString(assets), "): ", vm.toString(gwPreviewDeposit)));
        _step(string.concat("  vault.previewDeposit(", vm.toString(assets), "): ", vm.toString(vaultPreviewDeposit)));
        _step("  PASS: values match");

        _logPass();
    }

    // =============================================================
    //  P1 - exchangeRate consistency
    // =============================================================

    function test_ExchangeRate_ConsistentWithAccountant() public {
        _logCase("test_ExchangeRate_ConsistentWithAccountant", unicode"`exchangeRate()` 与 Accountant 当前值一致");

        _step("[Step 1] Set accountant rate to 1.05e18");
        _setRateReal(1.05e18);

        _step("[Step 2] Verify vault.exchangeRate() matches");
        uint256 vaultRate = vault.exchangeRate();
        uint256 accountantRate = accountant.lastExchangeRate();
        assertEq(vaultRate, accountantRate);
        _step(string.concat("  vault.exchangeRate(): ", vm.toString(vaultRate)));
        _step(string.concat("  accountant.exchangeRate(): ", vm.toString(accountantRate)));
        _step("  PASS: vault exchangeRate matches accountant rate");

        _logPass();
    }

    // =============================================================
    //  P1 - share() returns vault address
    // =============================================================

    function test_Share_ReturnsVaultAddress() public {
        _logCase("test_Share_ReturnsVaultAddress", unicode"`share()` 返回 Vault 自身地址");

        _step("[Step 1] Call vault.share()");
        address shareAddr = vault.share();
        assertEq(shareAddr, address(vault));
        _step(string.concat("  share(): ", vm.toString(shareAddr)));
        _step(string.concat("  vault address: ", vm.toString(address(vault))));
        _step("  PASS: share() == address(vault)");

        _logPass();
    }

    // =============================================================
    //  P1 - getFreeCash consistency
    // =============================================================

    function test_GetFreeCash_GatewayMatchesVault() public {
        _logCase("test_GetFreeCash_GatewayMatchesVault", unicode"Gateway 新增 `getFreeCash()` 转调 Vault 结果一致");

        _step("[Step 1] Query gateway.getFreeCash() and vault.getFreeCash()");
        uint256 gwFreeCash = gateway.getFreeCash();
        uint256 vaultFreeCash = vault.getFreeCash();
        assertEq(gwFreeCash, vaultFreeCash);
        _step(string.concat("  gateway.getFreeCash(): ", vm.toString(gwFreeCash)));
        _step(string.concat("  vault.getFreeCash(): ", vm.toString(vaultFreeCash)));
        _step("  PASS: gateway and vault freeCash match");

        _logPass();
    }

    // =============================================================
    //  P1 - strategyOrderLength consistency
    // =============================================================

    function test_StrategyOrderLength_Consistent() public {
        _logCase("test_StrategyOrderLength_Consistent", unicode"`strategyOrderLength()` 与实际 order 一致");

        _step("[Step 1] Initial strategyOrderLength should be 0");
        uint256 len0 = controller.strategyOrderLength();
        assertEq(len0, 0);
        _step(string.concat("  strategyOrderLength: ", vm.toString(len0)));
        _step("  PASS: initial length == 0");

        _step("[Step 2] Register, activate 2 adapters, then setStrategyOrder([A, B])");
        MockStrategyAdapter_VQ adapterA = new MockStrategyAdapter_VQ(address(usdc), address(vault));
        MockStrategyAdapter_VQ adapterB = new MockStrategyAdapter_VQ(address(usdc), address(vault));

        vm.startPrank(admin);
        controller.registerStrategy(address(adapterA), 5000, 1, false);
        controller.activateStrategy(address(adapterA));
        controller.registerStrategy(address(adapterB), 5000, 2, false);
        controller.activateStrategy(address(adapterB));

        address[] memory orderedAB = new address[](2);
        orderedAB[0] = address(adapterA);
        orderedAB[1] = address(adapterB);
        controller.setStrategyOrder(orderedAB);
        vm.stopPrank();

        uint256 len2 = controller.strategyOrderLength();
        assertEq(len2, 2);
        _step(string.concat("  strategyOrderLength after setStrategyOrder([A,B]): ", vm.toString(len2)));
        _step("  PASS: length == 2");

        _step("[Step 3] Move all active weight to A, then shrink order with setStrategyOrder([A])");
        address[] memory updateAdapters = new address[](2);
        updateAdapters[0] = address(adapterA);
        updateAdapters[1] = address(adapterB);
        uint16[] memory newWeights = new uint16[](2);
        newWeights[0] = 10000;
        newWeights[1] = 0;
        uint16[] memory newPriorities = new uint16[](2);
        newPriorities[0] = 1;
        newPriorities[1] = 2;
        bool[] memory newAsync = new bool[](2);
        newAsync[0] = false;
        newAsync[1] = false;
        address[] memory orderedA = new address[](1);
        orderedA[0] = address(adapterA);

        vm.startPrank(admin);
        controller.updateStrategies(updateAdapters, newWeights, newPriorities, newAsync);
        controller.setStrategyOrder(orderedA);
        vm.stopPrank();

        uint256 len1 = controller.strategyOrderLength();
        assertEq(len1, 1);
        _step(string.concat("  strategyOrderLength after setStrategyOrder([A]): ", vm.toString(len1)));
        _step("  PASS: length == 1 (2 -> 1 transition verified)");

        _logPass();
    }

    // =============================================================
    //  P1 - pendingRedeemRequest tracking
    // =============================================================

    function test_PendingRedeemRequest_Tracking() public {
        _logCase(
            "test_PendingRedeemRequest_Tracking",
            unicode"`pendingRedeemRequest(owner)` 在请求创建和结算后正确反映"
        );

        _step("[Step 1] Initial pendingRedeemRequest(alice) should be 0");
        uint256 pending0 = vault.pendingRedeemRequest(alice);
        assertEq(pending0, 0);
        _step(string.concat("  pendingRedeemRequest(alice): ", vm.toString(pending0)));
        _step("  PASS: initially 0");

        _step("[Step 2] Alice requests async redeem of 1000 shares");
        uint256 redeemShares = 1_000e6;
        vm.prank(alice);
        uint256 requestId = gateway.requestRedeem(redeemShares);
        _step(string.concat("  requestId: ", vm.toString(requestId)));

        uint256 pending1 = vault.pendingRedeemRequest(alice);
        uint256 treasuryShare = (redeemShares * vault.redemptionFeeBps() + 9999) / 10_000;
        uint256 expectedPending = redeemShares - treasuryShare;
        (,, uint256 reqShares, uint256 feeShares, uint256 estimatedAssets,, , IMantleYieldVault.RequestStatus status) =
            vault.requests(requestId);
        assertEq(uint8(status), uint8(IMantleYieldVault.RequestStatus.PENDING), "request should be pending");
        assertEq(reqShares, expectedPending, "stored request shares should equal net shares after fee");
        assertEq(feeShares, treasuryShare, "stored fee shares should match ceil fee formula");
        assertEq(pending1, expectedPending, "pendingRedeemRequest should equal pending net shares");
        _step(string.concat("  pendingRedeemRequest after request: ", vm.toString(pending1)));
        _step(string.concat("  request.shares (netShares): ", vm.toString(reqShares)));
        _step(string.concat("  request.feeShares: ", vm.toString(feeShares)));
        _step(string.concat("  request.estimatedAssets: ", vm.toString(estimatedAssets)));
        _step(string.concat("  expected feeShares (ceil): ", vm.toString(treasuryShare)));
        _step(string.concat("  expected net shares after fee: ", vm.toString(expectedPending)));
        assertEq(estimatedAssets, vault.previewRedeem(redeemShares), "request estimatedAssets should match request-time preview");
        _step("  PASS: pendingRedeemRequest and stored request data match real request semantics");

        _step("[Step 3] Settle the request via processRedeemBatch + finalizeRedeemBatch");
        // PENDING -> PROCESSING via real call chain: bot -> executor -> controller -> vault
        uint256[] memory ids = new uint256[](1);
        ids[0] = requestId;
        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), ids);

        // PROCESSING -> DONE via real call chain
        uint256[] memory settled = new uint256[](1);
        settled[0] = vault.previewRedeem(pending1);
        vm.prank(bot);
        executor.executeFinalizeRedeemBatch(address(controller), ids, settled);

        _step("[Step 4] Verify pendingRedeemRequest(alice) is now 0");
        uint256 pending2 = vault.pendingRedeemRequest(alice);
        assertEq(pending2, 0);
        _step(string.concat("  pendingRedeemRequest after settlement: ", vm.toString(pending2)));
        _step("  PASS: pendingRedeemRequest == 0 after settlement");

        _logPass();
    }

    // =============================================================
    //  P1 - getTokenInfos / totalAssets transparency
    // =============================================================

    function test_GetTokenInfos_TotalAssets_Transparency() public {
        _logCase(
            "test_GetTokenInfos_TotalAssets_Transparency",
            unicode"Gateway `getTokenInfos() / totalAssets()` 透传 Vault"
        );

        _step("[Step 1] Register adapter via controller and invest via rebalance");
        vm.startPrank(admin);
        controller.registerStrategy(address(adapter), 10_000, 1, false);
        controller.activateStrategy(address(adapter));
        address[] memory order = new address[](1);
        order[0] = address(adapter);
        controller.setStrategyOrder(order);
        vm.stopPrank();

        // Trigger rebalance to invest vault cash into adapter (real call chain)
        vm.prank(bot);
        executor.executeRebalance(address(controller));

        _step("[Step 2] Compare gateway.getTokenInfos() with vault.getTokenInfos()");
        IMantleYieldVault.tokenInfo[] memory gwInfos = gateway.getTokenInfos();
        IMantleYieldVault.tokenInfo[] memory vaultInfos = vault.getTokenInfos();
        assertEq(gwInfos.length, vaultInfos.length);
        _step(string.concat("  tokenInfos length: ", vm.toString(gwInfos.length)));
        for (uint256 i = 0; i < gwInfos.length; i++) {
            assertEq(gwInfos[i].token, vaultInfos[i].token);
            assertEq(gwInfos[i].tokenAmount, vaultInfos[i].tokenAmount);
            assertEq(gwInfos[i].usdcAmount, vaultInfos[i].usdcAmount);
        }
        _step("  PASS: gateway.getTokenInfos() matches vault.getTokenInfos()");

        _step("[Step 3] Compare gateway.totalAssets() with vault.totalAssets()");
        uint256 gwTotal = gateway.totalAssets();
        uint256 vaultTotal = vault.totalAssets();
        assertEq(gwTotal, vaultTotal);
        _step(string.concat("  gateway.totalAssets(): ", vm.toString(gwTotal)));
        _step(string.concat("  vault.totalAssets(): ", vm.toString(vaultTotal)));
        _step("  PASS: gateway.totalAssets() matches vault.totalAssets()");

        _logPass();
    }
}
