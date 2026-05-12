// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Accountant} from "../../src/accountant/Accountant.sol";
import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {IStrategyAdapter} from "../../src/interfaces/adapters/IStrategyAdapter.sol";
import {IStrategyControllerExecutor} from "../../src/interfaces/strategy/IStrategyControllerExecutor.sol";
import {IMantleVaultGateway} from "../../src/interfaces/vault/IMantleVaultGateway.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {OperatorExecutor} from "../../src/protocol/OperatorExecutor.sol";
import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {GatewayFactory} from "../../src/vault/GatewayFactory.sol";
import {MantleVaultGateway} from "../../src/vault/MantleVaultGateway.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {VaultFactory} from "../../src/vault/VaultFactory.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test, console2} from "forge-std/Test.sol";
import {VaultViewHelper} from "../lib/VaultViewHelper.sol";

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

    function isWhitelisted(address) external pure override returns (bool) {
        return true;
    }

    function setSanctioned(address account, bool status) external {
        sanctioned[account] = status;
    }

    function totalSanctionedCount() external pure override returns (uint256) { return 0; }
    function totalWhitelistedCount() external pure override returns (uint256) { return 0; }
    function lastUpdateTimestamp() external pure override returns (uint256) { return 0; }
    function batchNonce() external pure override returns (uint256) { return 0; }
    function MAX_BATCH_SIZE() external pure override returns (uint256) { return 100; }
    function updateSanctionStatus(address, bool) external override {}
    function updateSanctionStatusBatch(address[] calldata, bool) external override {}
    function updateWhitelistStatus(address, bool) external override {}
    function updateWhitelistStatusBatch(address[] calldata, bool) external override {}
}

/// @dev Minimal adapter mock for StrategyController registration.
///      deposit() transfers real funds from vault; totalValue() returns real balance.
contract MockAdapterFee is IStrategyAdapter {
    address public immutable ASSET;
    address public immutable POS_TOKEN;
    address public vaultAddress;

    constructor(address asset_, address posToken_) {
        ASSET = asset_;
        POS_TOKEN = posToken_;
    }

    function setVault(address v) external { vaultAddress = v; }
    function name() external pure returns (string memory) { return "MockAdapterFee"; }
    function asset() external view returns (address) { return ASSET; }
    function posToken() external view returns (address) { return POS_TOKEN; }
    function priceOracle() external pure returns (address) { return address(0); }
    function getPosTokenPrice() external pure returns (uint256) { return 0; }
    function estimatePosAmount(uint256 a) external pure returns (uint256) { return a; }
    function minSubscribeAsset() external pure returns (uint256) { return 0; }
    function minRedeemPos() external pure returns (uint256) { return 0; }
    function previewDeposit(uint256 assetAmount)
        external
        pure
        returns (bool ok, uint256 executableAssetAmount, uint256 expectedPosAmount)
    {
        ok = assetAmount > 0;
        executableAssetAmount = assetAmount;
        expectedPosAmount = 0;
    }
    function previewRedeem(uint256 assetAmount)
        external
        pure
        returns (bool ok, uint256 executableAssetAmount, uint256 expectedPosAmount)
    {
        ok = assetAmount > 0;
        executableAssetAmount = assetAmount;
        expectedPosAmount = 0;
    }
    function vault() external view returns (address) { return vaultAddress; }
    function totalValue() external view returns (uint256) { return ERC20(ASSET).balanceOf(address(this)); }
    function deposit(uint256 amount, address) external returns (uint256) {
        ERC20(ASSET).transferFrom(vaultAddress, address(this), amount);
        return amount;
    }
    function withdrawSync(uint256, address) external pure returns (uint256) {
        revert("Unsupported");
    }
    function requestRedeemAsync(uint256, address) external {}
    function sweepToVault(address token, uint256 amount) external returns (uint256 claimed) {
        uint256 bal = ERC20(token).balanceOf(address(this));
        claimed = amount > bal ? bal : amount;
        if (claimed > 0) {
            ERC20(token).transfer(vaultAddress, claimed);
        }
    }
    function setPaused(bool) external {}
    function retryRedeemAsync(uint256, address) external {}
    function paused() external pure returns (bool) { return false; }
}

// ---------------------------------------------------------------------------
// QA Test: Redemption Fee Impact on Queued & New Users
// ---------------------------------------------------------------------------

contract RedemptionFeeImpactQATest is Test {
    using VaultViewHelper for MantleYieldVault;
    MockUSDC internal usdc;
    MockUSDC internal posToken;
    MockSanctionsOracle internal oracle;
    Accountant internal accountant;
    MantleYieldVault internal vault;
    MantleVaultGateway internal gateway;
    OperatorExecutor internal executor;
    StrategyController internal controller;
    MockAdapterFee internal adapter;
    VaultFactory internal factory;
    GatewayFactory internal gatewayFactory;

    address internal admin = makeAddr("admin");
    address internal bot = makeAddr("bot");
    address internal manager = makeAddr("manager");
    address internal treasuryAddr = makeAddr("treasury");
    address internal sanctionSafe = makeAddr("sanctionSafe");
    address internal userA = makeAddr("userA");
    address internal userB = makeAddr("userB");
    address internal userC = makeAddr("userC");

    uint256 constant DEPOSIT_AMOUNT = 50_000e6;
    uint256 constant INITIAL_FEE_BPS = 100; // 1%
    uint256 constant FEE_BASIS = 10_000;

    function setUp() public {
        usdc = new MockUSDC();
        posToken = new MockUSDC();
        oracle = new MockSanctionsOracle();

        // 1. Deploy vault + gateway via factory
        MantleYieldVault impl = new MantleYieldVault();
        MantleVaultGateway gatewayImpl = new MantleVaultGateway();
        factory = new VaultFactory(address(impl), admin);
        gatewayFactory = new GatewayFactory(address(gatewayImpl), admin);

        address vaultAddr = factory.deployVault();
        address gatewayAddr = gatewayFactory.deployGateway();
        vault = MantleYieldVault(vaultAddr);
        gateway = MantleVaultGateway(gatewayAddr);

        // 2. Deploy real OperatorExecutor
        OperatorExecutor executorImpl = new OperatorExecutor();
        bytes memory executorInitData = abi.encodeCall(OperatorExecutor.initialize, (admin, bot));
        executor = OperatorExecutor(address(new ERC1967Proxy(address(executorImpl), executorInitData)));

        // 3. Initialize vault with placeholder controller (will update after controller deploy)
        vm.prank(admin);
        vault.initialize(
            IMantleYieldVault.InitParams({
                asset: IERC20(address(usdc)),
                name: "Mantle RWA Vault",
                symbol: "mRWA",
                admin: admin,
                gateway: gatewayAddr,
                controller: address(executor), // placeholder, updated below
                accountant: address(1), // placeholder, replaced below
                treasury: treasuryAddr,
                maxRedemptionFeeBps: 500,
                redemptionFeeBps: INITIAL_FEE_BPS,
                minRedeemAmount: 0,
                minDepositAmount: 0,
                maxSettlementDeviationBps: 0,
                depositDailyRemaining: type(uint256).max,
                redeemDailyRemaining: type(uint256).max
            })
        );

        // Deploy real Accountant
        Accountant acctImpl = new Accountant();
        accountant = Accountant(address(new ERC1967Proxy(
            address(acctImpl),
            abi.encodeCall(Accountant.initialize, (vaultAddr, uint64(1e18), 0, admin))
        )));
        vm.prank(admin);
        vault.setAccountant(address(accountant));

        // 4. Deploy real StrategyController
        StrategyController controllerImpl = new StrategyController();
        bytes memory controllerInitData = abi.encodeCall(
            StrategyController.initialize,
            (vaultAddr, manager, address(executor), manager, 1000, 200, 1 hours)
        );
        controller = StrategyController(address(new ERC1967Proxy(address(controllerImpl), controllerInitData)));

        // 5. Update vault's controller to the real StrategyController
        vm.prank(admin);
        vault.setController(address(controller));

        // 6. Deploy and register adapter
        adapter = new MockAdapterFee(address(usdc), address(posToken));
        adapter.setVault(vaultAddr);
        vm.startPrank(manager);
        controller.registerStrategy(address(adapter), 10_000, 1, true);
        controller.activateStrategy(address(adapter));
        address[] memory ordered = new address[](1);
        ordered[0] = address(adapter);
        controller.setStrategyOrder(ordered);
        vm.stopPrank();

        // 7. Initialize gateway
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

        // 8. Seed users with deposits
        _depositForUser(userA, DEPOSIT_AMOUNT);
        _depositForUser(userB, DEPOSIT_AMOUNT);
        _depositForUser(userC, DEPOSIT_AMOUNT);
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

    function _requestRedeem(address user, uint256 shares) internal returns (uint256 requestId) {
        vm.prank(user);
        requestId = gateway.requestRedeem(shares);
    }

    function _syncRedeem(address user, uint256 shares) internal returns (uint256 assets) {
        vm.prank(user);
        assets = gateway.redeem(shares);
    }

    /// @dev Bot -> OperatorExecutor -> StrategyController -> vault.updateRequestBatch (real chain)
    function _processRedeemBatch(uint256[] memory ids) internal {
        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), ids);
    }

    /// @dev Bot -> OperatorExecutor -> StrategyController -> vault.markRequestsDone (real chain)
    function _finalizeRedeemBatch(uint256[] memory ids, uint256[] memory settled) internal {
        vm.prank(bot);
        executor.executeFinalizeRedeemBatch(address(controller), ids, settled);
    }

    function _singleId(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function _singleAmount(uint256 amt) internal pure returns (uint256[] memory amts) {
        amts = new uint256[](1);
        amts[0] = amt;
    }

    /// @dev Ceiling division matching Solidity Math.Rounding.Ceil
    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    // -----------------------------------------------------------------------
    // 1. test_FeeIncrease_OldRequestEstimatedFrozen
    // -----------------------------------------------------------------------

    function test_FeeIncrease_OldRequestEstimatedFrozen() public {
        _logCase(
            "test_FeeIncrease_OldRequestEstimatedFrozen",
            unicode"用户提交异步赎回请求后，管理员上调 redemption fee，验证老请求估算值冻结且不会自动按新 fee 重算"
        );

        uint256 redeemShares = 5000e6;
        uint256 rate = accountant.getRate();

        _step("[Step 1] userA creates async redeem request at fee=1%");
        uint256 treasurySharesBefore = vault.balanceOf(treasuryAddr);
        uint256 reqId = _requestRedeem(userA, redeemShares);
        (uint256 netShares, uint256 feeShares, uint256 estBefore,,) = vault.reqCore(reqId);

        // Verify estimatedAssets matches formula: grossAssets - fee
        uint256 grossAssets = (redeemShares * rate) / 1e18;
        uint256 expectedFee = _ceilDiv(grossAssets * INITIAL_FEE_BPS, FEE_BASIS);
        uint256 expectedEst = grossAssets - expectedFee;
        uint256 expectedTreasuryShares = _ceilDiv(redeemShares * INITIAL_FEE_BPS, FEE_BASIS);
        assertEq(estBefore, expectedEst, "estimatedAssets should match formula: grossAssets - fee");
        assertEq(feeShares, expectedTreasuryShares, "feeShares should match formula: shares * fee / basis (ceil)");
        _step(string.concat("  grossAssets = ", vm.toString(grossAssets)));
        _step(string.concat("  fee (1%) = ", vm.toString(expectedFee)));
        _step(string.concat("  estimatedAssets = ", vm.toString(estBefore)));

        // Verify treasury received fee shares
        uint256 treasurySharesAfter = vault.balanceOf(treasuryAddr);
        assertEq(treasurySharesAfter - treasurySharesBefore, expectedTreasuryShares, "treasury should receive feeShares");
        _step(string.concat("  treasury feeShares = ", vm.toString(treasurySharesAfter - treasurySharesBefore)));

        _step("[Step 2] Admin increases redemption fee to 3%");
        vm.prank(admin);
        vault.setRedemptionFee(300);
        assertEq(vault.redemptionFeeBps(), 300, "fee should be 300 bps");

        _step("[Step 3] Re-read the old request data");
        uint256 estAfter = vault.reqEstimate(reqId);
        assertEq(estAfter, estBefore, "estimatedAssets should NOT change after fee increase");

        _step("[Step 4] Process and finalize via real chain: Bot -> OperatorExecutor -> Controller -> Vault");
        uint256 userUsdcBefore = usdc.balanceOf(userA);
        _processRedeemBatch(_singleId(reqId));
        _finalizeRedeemBatch(_singleId(reqId), _singleAmount(estBefore));

        (,,, uint256 settled, IMantleYieldVault.RequestStatus status) = vault.reqCore(reqId);
        assertEq(uint8(status), uint8(IMantleYieldVault.RequestStatus.DONE));
        assertEq(settled, estBefore, "settled should match original estimate, not auto-recalculated");

        // Verify user actually received the settled USDC
        uint256 userUsdcAfter = usdc.balanceOf(userA);
        assertEq(userUsdcAfter - userUsdcBefore, estBefore, "user should receive exact settled amount");
        _step(string.concat("  user USDC received = ", vm.toString(userUsdcAfter - userUsdcBefore)));
        _step("  PASS: old request estimatedAssets frozen, not auto-recalculated on fee increase");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 2. test_FeeDecrease_OldRequestEstimatedUnchanged
    // -----------------------------------------------------------------------

    function test_FeeDecrease_OldRequestEstimatedUnchanged() public {
        _logCase(
            "test_FeeDecrease_OldRequestEstimatedUnchanged",
            unicode"用户提交异步赎回请求后，管理员下调 redemption fee，验证老请求不会自动按新 fee 提高估算值"
        );

        uint256 redeemShares = 5000e6;
        uint256 rate = accountant.getRate();

        _step("[Step 1] userA creates async redeem request at fee=1%");
        uint256 treasurySharesBefore = vault.balanceOf(treasuryAddr);
        uint256 reqId = _requestRedeem(userA, redeemShares);
        (, uint256 feeShares, uint256 estBefore,,) = vault.reqCore(reqId);

        // Verify against formula
        uint256 grossAssets = (redeemShares * rate) / 1e18;
        uint256 expectedFee = _ceilDiv(grossAssets * INITIAL_FEE_BPS, FEE_BASIS);
        uint256 expectedEst = grossAssets - expectedFee;
        assertEq(estBefore, expectedEst, "estimatedAssets should match formula");
        _step(string.concat("  estimatedAssets = ", vm.toString(estBefore), " (grossAssets=", vm.toString(grossAssets), " - fee=", vm.toString(expectedFee), ")"));

        // Verify treasury
        uint256 expectedTreasuryShares = _ceilDiv(redeemShares * INITIAL_FEE_BPS, FEE_BASIS);
        assertEq(vault.balanceOf(treasuryAddr) - treasurySharesBefore, expectedTreasuryShares, "treasury should receive fee shares");

        _step("[Step 2] Admin decreases redemption fee to 0.5%");
        vm.prank(admin);
        vault.setRedemptionFee(50);
        assertEq(vault.redemptionFeeBps(), 50, "fee should be 50 bps");

        _step("[Step 3] Re-read request data - estimatedAssets should be frozen");
        uint256 estAfter = vault.reqEstimate(reqId);
        assertEq(estAfter, estBefore, "estimatedAssets should NOT change after fee decrease");

        _step("[Step 4] Process and finalize via real chain, verify user receives USDC");
        uint256 userUsdcBefore = usdc.balanceOf(userA);
        _processRedeemBatch(_singleId(reqId));
        _finalizeRedeemBatch(_singleId(reqId), _singleAmount(estBefore));

        uint256 settled = vault.reqSettled(reqId);
        assertEq(settled, estBefore, "settled should match original estimate");
        assertEq(usdc.balanceOf(userA) - userUsdcBefore, estBefore, "user should receive exact settled USDC");
        _step("  PASS: old request estimatedAssets unchanged after fee decrease");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 3. test_OldAndNewRequests_DifferentEstimatedAssets
    // -----------------------------------------------------------------------

    function test_OldAndNewRequests_DifferentEstimatedAssets() public {
        _logCase(
            "test_OldAndNewRequests_DifferentEstimatedAssets",
            unicode"同一时刻新老请求在 fee 变更前后创建，验证两批用户估算值差异"
        );

        uint256 redeemShares = 5000e6;
        uint256 rate = accountant.getRate();
        uint256 grossAssets = (redeemShares * rate) / 1e18;

        _step("[Step 1] userA creates old request at fee=1%");
        uint256 treasuryBefore = vault.balanceOf(treasuryAddr);
        uint256 reqOld = _requestRedeem(userA, redeemShares);
        uint256 estOld = vault.reqEstimate(reqOld);
        uint256 expectedOldFee = _ceilDiv(grossAssets * 100, FEE_BASIS);
        uint256 expectedEstOld = grossAssets - expectedOldFee;
        assertEq(estOld, expectedEstOld, "old estimatedAssets should match 1% fee formula");
        // Treasury received old fee shares
        uint256 expectedOldTreasury = _ceilDiv(redeemShares * 100, FEE_BASIS);
        assertEq(vault.balanceOf(treasuryAddr) - treasuryBefore, expectedOldTreasury, "treasury should receive 1% feeShares");
        _step(string.concat("  old estimatedAssets = ", vm.toString(estOld), " (fee=", vm.toString(expectedOldFee), ")"));

        _step("[Step 2] Admin changes fee to 3%");
        vm.prank(admin);
        vault.setRedemptionFee(300);

        _step("[Step 3] userB creates new request at fee=3%");
        (uint256 estNew, uint256 expectedNewFee) = _createAndVerifyNewRequest(redeemShares, grossAssets, 300);

        _step("[Step 4] Verify the difference matches fee delta");
        assertTrue(estOld > estNew, "old request (1% fee) should have higher estimatedAssets than new (3% fee)");
        uint256 expectedDiff = expectedNewFee - expectedOldFee;
        assertEq(estOld - estNew, expectedDiff, "difference should equal fee delta");
        _step(string.concat("  difference = ", vm.toString(estOld - estNew), " = newFee - oldFee = ", vm.toString(expectedDiff)));
        _step("  PASS: old and new requests differ exactly by fee change amount");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 4. test_FeeChange_ThreePathsDifferentResults
    // -----------------------------------------------------------------------

    function test_FeeChange_ThreePathsDifferentResults() public {
        _logCase(
            "test_FeeChange_ThreePathsDifferentResults",
            unicode"fee 变更后，同步赎回、老异步请求与新异步请求三种路径结果口径不同"
        );

        uint256 redeemShares = 5000e6;
        uint256 rate = accountant.getRate();
        uint256 grossAssets = (redeemShares * rate) / 1e18;

        _step("[Step 1] userA creates old async request at fee=1%");
        uint256 treasuryBefore1 = vault.balanceOf(treasuryAddr);
        uint256 reqOld = _requestRedeem(userA, redeemShares);
        uint256 estOld = vault.reqEstimate(reqOld);
        uint256 expectedOldFee = _ceilDiv(grossAssets * 100, FEE_BASIS);
        assertEq(estOld, grossAssets - expectedOldFee, "old async should use 1% fee formula");
        _step(string.concat("  old async estimatedAssets = ", vm.toString(estOld)));

        _step("[Step 2] Admin changes fee to 3%");
        vm.prank(admin);
        vault.setRedemptionFee(300);

        _step("[Step 3] userC performs sync redeem at new fee=3%");
        uint256 userCUsdcBefore = usdc.balanceOf(userC);
        uint256 treasuryBeforeSync = vault.balanceOf(treasuryAddr);
        uint256 syncAssets = _syncRedeem(userC, redeemShares);
        uint256 expectedNewFee = _ceilDiv(grossAssets * 300, FEE_BASIS);
        assertEq(syncAssets, grossAssets - expectedNewFee, "sync redeem should use 3% fee formula");
        // Verify treasury received fee shares from sync
        assertTrue(vault.balanceOf(treasuryAddr) > treasuryBeforeSync, "treasury should receive fee from sync redeem");
        // Verify user received exact sync amount
        assertEq(usdc.balanceOf(userC) - userCUsdcBefore, syncAssets, "userC should receive sync redeem USDC");
        _step(string.concat("  sync redeem assets = ", vm.toString(syncAssets)));

        _step("[Step 4] userB creates new async request at new fee=3%");
        uint256 reqNew = _requestRedeem(userB, redeemShares);
        uint256 estNew = vault.reqEstimate(reqNew);
        assertEq(estNew, grossAssets - expectedNewFee, "new async should use 3% fee formula");
        _step(string.concat("  new async estimatedAssets = ", vm.toString(estNew)));

        _step("[Step 5] Verify three paths: old(1%) > sync(3%) == newAsync(3%)");
        assertTrue(estOld > syncAssets, "old async(1%) > sync redeem(3%)");
        assertEq(estNew, syncAssets, "new async and sync redeem match (both 3% fee, same formula)");
        _step("  PASS: three paths produce explainable results matching respective fee formulas");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 5. test_MaxFeeLowered_CurrentFeeConverges
    // -----------------------------------------------------------------------

    function test_MaxFeeLowered_CurrentFeeConverges() public {
        _logCase(
            "test_MaxFeeLowered_CurrentFeeConverges",
            unicode"`maxRedemptionFeeBps` 下调导致当前 fee 自动收敛时，验证新口径变化但老请求不自动重算"
        );

        _step("[Step 1] Current fee=1% (100 bps), max=5% (500 bps)");
        assertEq(vault.redemptionFeeBps(), 100);
        assertEq(vault.maxRedemptionFeeBps(), 500);

        // First raise fee to 3% so we can test convergence
        vm.prank(admin);
        vault.setRedemptionFee(300);
        _step("  Raised fee to 3% (300 bps)");

        uint256 redeemShares = 5000e6;
        uint256 rate = accountant.getRate();
        uint256 grossAssets = (redeemShares * rate) / 1e18;

        _step("[Step 2] userA creates request at fee=3%");
        uint256 treasuryBefore = vault.balanceOf(treasuryAddr);
        uint256 reqId = _requestRedeem(userA, redeemShares);
        uint256 estBefore = vault.reqEstimate(reqId);
        uint256 expectedFee3pct = _ceilDiv(grossAssets * 300, FEE_BASIS);
        assertEq(estBefore, grossAssets - expectedFee3pct, "estimatedAssets should match 3% fee formula");
        _step(string.concat("  estimatedAssets = ", vm.toString(estBefore), " (fee=3%)"));

        // Verify treasury received 3% fee shares
        uint256 expectedTreasury3pct = _ceilDiv(redeemShares * 300, FEE_BASIS);
        assertEq(vault.balanceOf(treasuryAddr) - treasuryBefore, expectedTreasury3pct, "treasury should receive 3% feeShares");

        _step("[Step 3] Admin lowers maxRedemptionFeeBps to 200 (2%), which is below current 300");
        vm.prank(admin);
        vault.setMaxRedemptionFee(200);

        _step("[Step 4] Verify current fee auto-converged to new max");
        assertEq(vault.redemptionFeeBps(), 200, "fee should converge to new max (200 bps)");
        assertEq(vault.maxRedemptionFeeBps(), 200, "max should be updated");

        _step("[Step 5] Old request estimatedAssets should NOT be recalculated");
        uint256 estAfter = vault.reqEstimate(reqId);
        assertEq(estAfter, estBefore, "old request estimatedAssets should remain frozen");

        _step("[Step 6] New request should use the converged fee (2%)");
        uint256 treasuryBeforeNew = vault.balanceOf(treasuryAddr);
        uint256 reqNew = _requestRedeem(userB, redeemShares);
        uint256 estNew = vault.reqEstimate(reqNew);
        uint256 expectedFee2pct = _ceilDiv(grossAssets * 200, FEE_BASIS);
        assertEq(estNew, grossAssets - expectedFee2pct, "new estimatedAssets should match 2% fee formula");
        assertTrue(estNew > estBefore, "new request at 2% fee should estimate more than old at 3%");

        // Verify treasury received 2% fee shares for new request
        uint256 expectedTreasury2pct = _ceilDiv(redeemShares * 200, FEE_BASIS);
        assertEq(vault.balanceOf(treasuryAddr) - treasuryBeforeNew, expectedTreasury2pct, "treasury should receive 2% feeShares");
        _step(string.concat("  new estimatedAssets = ", vm.toString(estNew), " (fee=2%)"));
        _step("  PASS: fee converged, new requests use new fee, old requests frozen");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 6. test_RedemptionFee_GoesToTreasury
    // -----------------------------------------------------------------------

    function test_RedemptionFee_GoesToTreasury() public {
        _logCase(
            "test_RedemptionFee_GoesToTreasury",
            unicode"同步赎回 / 异步赎回产生的 redemption fee 直接转给 treasury，而不是留在 Vault 内部"
        );

        uint256 redeemShares = 5000e6;
        uint256 rate = accountant.getRate();
        uint256 grossAssets = (redeemShares * rate) / 1e18;
        uint256 expectedTreasuryShares = _ceilDiv(redeemShares * INITIAL_FEE_BPS, FEE_BASIS);
        uint256 expectedFee = _ceilDiv(grossAssets * INITIAL_FEE_BPS, FEE_BASIS);
        uint256 expectedNetAssets = grossAssets - expectedFee;

        _step("[Step 1] Record pre-redeem balances");
        uint256 treasurySharesBefore = vault.balanceOf(treasuryAddr);
        uint256 userAUsdcBefore = usdc.balanceOf(userA);
        _step(string.concat("  treasury shares before = ", vm.toString(treasurySharesBefore)));
        _step(string.concat("  expected fee per redeem: treasuryShares=", vm.toString(expectedTreasuryShares), " assetFee=", vm.toString(expectedFee)));

        _step("[Step 2] userA performs sync redeem");
        uint256 syncAssets = _syncRedeem(userA, redeemShares);

        // Verify user received exact net amount
        assertEq(syncAssets, expectedNetAssets, "sync redeem should return grossAssets - fee");
        assertEq(usdc.balanceOf(userA) - userAUsdcBefore, expectedNetAssets, "userA USDC delta should match formula");
        _step(string.concat("  sync redeem assets = ", vm.toString(syncAssets), " (expected ", vm.toString(expectedNetAssets), ")"));

        // Verify treasury received exact fee shares
        uint256 treasurySharesAfterSync = vault.balanceOf(treasuryAddr);
        uint256 feeSharesSync = treasurySharesAfterSync - treasurySharesBefore;
        assertEq(feeSharesSync, expectedTreasuryShares, "treasury should receive exact feeShares from sync redeem");
        _step(string.concat("  treasury feeShares (sync) = ", vm.toString(feeSharesSync)));

        _step("[Step 3] userB creates async redeem request");
        uint256 treasurySharesBeforeAsync = vault.balanceOf(treasuryAddr);
        uint256 reqId = _requestRedeem(userB, redeemShares);
        uint256 reqFeeShares = vault.reqFeeShares(reqId);
        uint256 feeSharesAsync = vault.balanceOf(treasuryAddr) - treasurySharesBeforeAsync;
        assertEq(feeSharesAsync, expectedTreasuryShares, "treasury should receive exact feeShares from async request");
        assertEq(reqFeeShares, expectedTreasuryShares, "request.feeShares should match formula");
        _step(string.concat("  treasury feeShares (async) = ", vm.toString(feeSharesAsync)));

        _step("[Step 4] Verify total treasury accumulation");
        uint256 totalTreasuryGain = vault.balanceOf(treasuryAddr) - treasurySharesBefore;
        assertEq(totalTreasuryGain, expectedTreasuryShares * 2, "treasury should receive feeShares from both operations");
        _step(string.concat("  total treasury gain = ", vm.toString(totalTreasuryGain)));
        _step("  PASS: redemption fee shares transferred to treasury with exact formula amounts");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 7. test_FeeIncrease_ViewsConsistent
    // -----------------------------------------------------------------------

    function test_FeeIncrease_ViewsConsistent() public {
        _logCase(
            "test_FeeIncrease_ViewsConsistent",
            unicode"fee 上调后，相关 view 的变化应与\"新 fee 口径 + fee 转 treasury\"的真实资产流动一致"
        );

        _step("[Step 1] Create async request to establish locked shares");
        uint256 reqId = _requestRedeem(userA, 10_000e6);
        uint256 totalLocked = vault.totalLockedShares();
        _step(string.concat("  totalLockedShares = ", vm.toString(totalLocked)));

        uint256 previewBefore = vault.previewRedeem(totalLocked);
        uint256 freeCashBefore = vault.getFreeCash();
        uint256 maxRedeemB = vault.maxRedeem(userB);
        uint256 maxWithdrawB = vault.maxWithdraw(userB);
        _step(string.concat("  previewRedeem(locked) before = ", vm.toString(previewBefore)));
        _step(string.concat("  freeCash before = ", vm.toString(freeCashBefore)));
        _step(string.concat("  maxRedeem(userB) before = ", vm.toString(maxRedeemB)));
        _step(string.concat("  maxWithdraw(userB) before = ", vm.toString(maxWithdrawB)));

        _step("[Step 2] Admin increases fee from 1% to 4%");
        vm.prank(admin);
        vault.setRedemptionFee(400);

        _step("[Step 3] Re-query views after fee increase");
        uint256 previewAfter = vault.previewRedeem(totalLocked);
        uint256 freeCashAfter = vault.getFreeCash();
        uint256 maxRedeemBAfter = vault.maxRedeem(userB);
        uint256 maxWithdrawBAfter = vault.maxWithdraw(userB);
        _step(string.concat("  previewRedeem(locked) after = ", vm.toString(previewAfter)));
        _step(string.concat("  freeCash after = ", vm.toString(freeCashAfter)));
        _step(string.concat("  maxRedeem(userB) after = ", vm.toString(maxRedeemBAfter)));
        _step(string.concat("  maxWithdraw(userB) after = ", vm.toString(maxWithdrawBAfter)));

        _step("[Step 4] Verify previewRedeem decreased (higher fee = less assets per share)");
        assertTrue(previewAfter < previewBefore, "previewRedeem should decrease with higher fee");

        _step("[Step 5] Verify freeCash unchanged (fee does not affect freeCash)");
        // getFreeCash = physicalBalance - convertToAssets(totalLockedShares, Ceil)
        // totalLockedShares records net shares (set at request time), not affected by fee changes
        // So freeCash should NOT change when fee is adjusted
        assertEq(freeCashAfter, freeCashBefore, "freeCash should NOT change when fee changes (totalLockedShares is net shares)");

        _step("[Step 6] Verify maxRedeem increased (higher fee = less asset per share = more shares redeemable within freeCash)");
        _step(string.concat("  maxRedeem(userB) before = ", vm.toString(maxRedeemB)));
        _step(string.concat("  maxRedeem(userB) after  = ", vm.toString(maxRedeemBAfter)));
        assertTrue(maxRedeemBAfter >= maxRedeemB, "maxRedeem should not decrease when fee increases");

        _step("[Step 7] Verify maxWithdraw decreased (higher fee = less asset per share for user)");
        _step(string.concat("  maxWithdraw(userB) before = ", vm.toString(maxWithdrawB)));
        _step(string.concat("  maxWithdraw(userB) after  = ", vm.toString(maxWithdrawBAfter)));
        assertTrue(maxWithdrawBAfter < maxWithdrawB, "maxWithdraw should decrease when fee increases (less asset per share)");
        _step("  PASS: views changed consistently with fee increase");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 8. test_FeeDecrease_ViewsConsistent
    // -----------------------------------------------------------------------

    function test_FeeDecrease_ViewsConsistent() public {
        _logCase(
            "test_FeeDecrease_ViewsConsistent",
            unicode"fee 下调后，相关 view 的变化应与\"新 fee 口径 + fee 转 treasury\"的真实资产流动一致"
        );

        // Start with higher fee to have room to decrease
        vm.prank(admin);
        vault.setRedemptionFee(400);

        _step("[Step 1] Create async request to establish locked shares at 4% fee");
        uint256 reqId = _requestRedeem(userA, 10_000e6);
        uint256 totalLocked = vault.totalLockedShares();
        _step(string.concat("  totalLockedShares = ", vm.toString(totalLocked)));

        uint256 previewBefore = vault.previewRedeem(totalLocked);
        uint256 freeCashBefore = vault.getFreeCash();
        uint256 maxRedeemB = vault.maxRedeem(userB);
        uint256 maxWithdrawB = vault.maxWithdraw(userB);
        _step(string.concat("  previewRedeem(locked) before = ", vm.toString(previewBefore)));
        _step(string.concat("  freeCash before = ", vm.toString(freeCashBefore)));
        _step(string.concat("  maxRedeem(userB) before = ", vm.toString(maxRedeemB)));
        _step(string.concat("  maxWithdraw(userB) before = ", vm.toString(maxWithdrawB)));

        _step("[Step 2] Admin decreases fee from 4% to 1%");
        vm.prank(admin);
        vault.setRedemptionFee(100);

        _step("[Step 3] Re-query views after fee decrease");
        uint256 previewAfter = vault.previewRedeem(totalLocked);
        uint256 freeCashAfter = vault.getFreeCash();
        uint256 maxRedeemBAfter = vault.maxRedeem(userB);
        uint256 maxWithdrawBAfter = vault.maxWithdraw(userB);
        _step(string.concat("  previewRedeem(locked) after = ", vm.toString(previewAfter)));
        _step(string.concat("  freeCash after = ", vm.toString(freeCashAfter)));
        _step(string.concat("  maxRedeem(userB) after = ", vm.toString(maxRedeemBAfter)));
        _step(string.concat("  maxWithdraw(userB) after = ", vm.toString(maxWithdrawBAfter)));

        _step("[Step 4] Verify previewRedeem increased (lower fee = more assets per share)");
        assertTrue(previewAfter > previewBefore, "previewRedeem should increase with lower fee");

        _step("[Step 5] Verify freeCash unchanged (fee does not affect freeCash)");
        // getFreeCash = physicalBalance - convertToAssets(totalLockedShares, Ceil)
        // totalLockedShares records net shares, not affected by fee changes
        assertEq(freeCashAfter, freeCashBefore, "freeCash should NOT change when fee changes (totalLockedShares is net shares)");

        _step("[Step 6] Verify maxRedeem decreased (lower fee = more asset per share = fewer shares redeemable within freeCash)");
        _step(string.concat("  maxRedeem(userB) before = ", vm.toString(maxRedeemB)));
        _step(string.concat("  maxRedeem(userB) after  = ", vm.toString(maxRedeemBAfter)));
        assertTrue(maxRedeemBAfter <= maxRedeemB, "maxRedeem should not increase when fee decreases");

        _step("[Step 7] Verify maxWithdraw increased (lower fee = more asset per share for user)");
        _step(string.concat("  maxWithdraw(userB) before = ", vm.toString(maxWithdrawB)));
        _step(string.concat("  maxWithdraw(userB) after  = ", vm.toString(maxWithdrawBAfter)));
        assertTrue(maxWithdrawBAfter > maxWithdrawB, "maxWithdraw should increase when fee decreases (more asset per share)");
        _step("  PASS: views changed consistently with fee decrease");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 9. test_ZeroFee_NoTreasuryCharge
    // -----------------------------------------------------------------------

    function test_ZeroFee_NoTreasuryCharge() public {
        _logCase(
            "test_ZeroFee_NoTreasuryCharge",
            unicode"fee 为 0 时，异步 / 同步赎回不再产生 treasury 收费"
        );

        _step("[Step 1] Admin sets fee to 0");
        vm.prank(admin);
        vault.setRedemptionFee(0);
        assertEq(vault.redemptionFeeBps(), 0, "fee should be 0");

        uint256 treasurySharesBefore = vault.balanceOf(treasuryAddr);
        _step(string.concat("  treasury shares before = ", vm.toString(treasurySharesBefore)));

        _step("[Step 2] userA performs sync redeem with fee=0");
        uint256 redeemShares = 5000e6;
        uint256 rate = accountant.getRate();
        uint256 grossAssets = (redeemShares * rate) / 1e18;

        uint256 userAUsdcBefore = usdc.balanceOf(userA);
        uint256 syncAssets = _syncRedeem(userA, redeemShares);

        // Verify user receives FULL grossAssets (no fee deducted)
        assertEq(syncAssets, grossAssets, "sync redeem at 0% fee should return full grossAssets");
        assertEq(usdc.balanceOf(userA) - userAUsdcBefore, grossAssets, "userA should receive full amount");
        _step(string.concat("  sync redeem assets = ", vm.toString(syncAssets), " == grossAssets = ", vm.toString(grossAssets)));

        // Verify treasury unchanged
        uint256 treasurySharesAfterSync = vault.balanceOf(treasuryAddr);
        assertEq(treasurySharesAfterSync, treasurySharesBefore, "no fee shares for sync redeem at 0% fee");

        _step("[Step 3] userB creates async redeem request with fee=0");
        uint256 reqId = _requestRedeem(userB, redeemShares);
        uint256 treasurySharesAfterAsync = vault.balanceOf(treasuryAddr);
        assertEq(treasurySharesAfterAsync, treasurySharesBefore, "no fee shares for async request at 0% fee");

        // Verify request: feeShares=0, estimatedAssets=grossAssets
        (, uint256 feeShares, uint256 estAssets,,) = vault.reqCore(reqId);
        assertEq(feeShares, 0, "feeShares should be 0 when fee is 0");
        assertEq(estAssets, grossAssets, "estimatedAssets should equal grossAssets at 0% fee");
        _step(string.concat("  async estimatedAssets = ", vm.toString(estAssets), " == grossAssets"));
        _step("  PASS: zero fee means no treasury charge, user gets full amount");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 10. test_FeeIncrease_LockedSharesUnchanged
    // -----------------------------------------------------------------------

    function test_FeeIncrease_LockedSharesUnchanged() public {
        _logCase(
            "test_FeeIncrease_LockedSharesUnchanged",
            unicode"fee 上调不会改变已锁定 shares 数量，只改变其对应的预估资产口径"
        );

        _step("[Step 1] Create async request to establish locked shares");
        _requestRedeem(userA, 10_000e6);
        uint256 lockedBefore = vault.totalLockedShares();
        uint256 previewBefore = vault.previewRedeem(lockedBefore);
        _step(string.concat("  totalLockedShares before = ", vm.toString(lockedBefore)));
        _step(string.concat("  previewRedeem(locked) before = ", vm.toString(previewBefore)));

        _step("[Step 2] Admin increases fee from 1% to 4%");
        vm.prank(admin);
        vault.setRedemptionFee(400);

        _step("[Step 3] Verify totalLockedShares unchanged but previewRedeem changed");
        uint256 lockedAfter = vault.totalLockedShares();
        uint256 previewAfter = vault.previewRedeem(lockedAfter);
        _step(string.concat("  totalLockedShares after = ", vm.toString(lockedAfter)));
        _step(string.concat("  previewRedeem(locked) after = ", vm.toString(previewAfter)));

        assertEq(lockedAfter, lockedBefore, "totalLockedShares must NOT change on fee adjustment");
        assertTrue(previewAfter < previewBefore, "previewRedeem should decrease with higher fee");
        _step("  PASS: locked shares unchanged, only asset valuation changed");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 11. test_FeeDecrease_LockedSharesUnchanged
    // -----------------------------------------------------------------------

    function test_FeeDecrease_LockedSharesUnchanged() public {
        _logCase(
            "test_FeeDecrease_LockedSharesUnchanged",
            unicode"fee 下调不会改变已锁定 shares 数量，只改变其对应的预估资产口径"
        );

        _step("[Step 1] Create async request to establish locked shares");
        _requestRedeem(userA, 10_000e6);
        uint256 lockedBefore = vault.totalLockedShares();
        uint256 previewBefore = vault.previewRedeem(lockedBefore);
        _step(string.concat("  totalLockedShares before = ", vm.toString(lockedBefore)));
        _step(string.concat("  previewRedeem(locked) before = ", vm.toString(previewBefore)));

        _step("[Step 2] Admin decreases fee from 1% to 0.5%");
        vm.prank(admin);
        vault.setRedemptionFee(50);

        _step("[Step 3] Verify totalLockedShares unchanged but previewRedeem changed");
        uint256 lockedAfter = vault.totalLockedShares();
        uint256 previewAfter = vault.previewRedeem(lockedAfter);
        _step(string.concat("  totalLockedShares after = ", vm.toString(lockedAfter)));
        _step(string.concat("  previewRedeem(locked) after = ", vm.toString(previewAfter)));

        assertEq(lockedAfter, lockedBefore, "totalLockedShares must NOT change on fee adjustment");
        assertTrue(previewAfter > previewBefore, "previewRedeem should increase with lower fee");
        _step("  PASS: locked shares unchanged, only asset valuation changed");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 12. test_OldRequest_SettlementDifference_Transparent
    // -----------------------------------------------------------------------

    function test_OldRequest_SettlementDifference_Transparent() public {
        _logCase(
            "test_OldRequest_SettlementDifference_Transparent",
            unicode"老请求在 fee 变更后结算时，若 `settledAssets != estimatedAssets`，差异应通过结算机制透明体现"
        );

        uint256 redeemShares = 5000e6;
        uint256 originalRate = accountant.getRate(); // 1e18

        _step("[Step 1] userA creates request at rate=1e18, fee=1%");
        uint256 reqId = _requestRedeem(userA, redeemShares);
        (uint256 netShares,, uint256 estOriginal,,) = vault.reqCore(reqId);
        uint256 grossAtOriginalRate = (redeemShares * originalRate) / 1e18;
        uint256 feeAtOriginalRate = _ceilDiv(grossAtOriginalRate * INITIAL_FEE_BPS, FEE_BASIS);
        assertEq(estOriginal, grossAtOriginalRate - feeAtOriginalRate, "estimatedAssets should match formula at original rate");
        _step(string.concat("  estimatedAssets = ", vm.toString(estOriginal), " (rate=1e18, fee=1%)"));

        _step("[Step 2] Admin changes fee to 3%");
        vm.prank(admin);
        vault.setRedemptionFee(300);

        _step("[Step 3] Verify old request estimatedAssets not auto-recalculated");
        uint256 estAfterFeeChange = vault.reqEstimate(reqId);
        assertEq(estAfterFeeChange, estOriginal, "estimatedAssets should not auto-recalculate");

        _step("[Step 4] Exchange rate drops slightly (e.g. strategy incurred small loss)");
        // Accountant updates rate from 1e18 to 0.99e18 (1% NAV decline)
        uint256 newRate = 0.99e18;
        vm.prank(admin);
        accountant.emergencyRateUpdate(uint64(newRate));
        _step(string.concat("  new exchangeRate = ", vm.toString(newRate)));

        _step("[Step 5] Process via real chain");
        _processRedeemBatch(_singleId(reqId));

        _step("[Step 6] Operator settles at actual value based on new rate");
        // Real business: operator calculates actual settlement = netShares * newRate / 1e18
        uint256 actualSettled = (netShares * newRate) / 1e18;
        _step(string.concat("  estOriginal (old rate) = ", vm.toString(estOriginal)));
        _step(string.concat("  actualSettled (new rate) = ", vm.toString(actualSettled)));
        assertLt(actualSettled, estOriginal, "settlement at lower rate (0.99) should be less than original estimate (1.0)");

        // Expect adjustment event since settledAssets != estimatedAssets
        uint256 userUsdcBefore = usdc.balanceOf(userA);
        vm.expectEmit(true, false, false, true, address(vault));
        emit IMantleYieldVault.RequestSettlementAdjusted(reqId, estOriginal, actualSettled);

        _finalizeRedeemBatch(_singleId(reqId), _singleAmount(actualSettled));

        _step("[Step 7] Verify settlement recorded correctly");
        (,, uint256 estFinal, uint256 settled, IMantleYieldVault.RequestStatus status) = vault.reqCore(reqId);
        assertEq(uint8(status), uint8(IMantleYieldVault.RequestStatus.DONE));
        assertEq(estFinal, estOriginal, "estimatedAssets should remain as originally recorded (frozen)");
        assertEq(settled, actualSettled, "settledAssets should reflect actual rate-based settlement");

        // Verify user received EXACT settled amount
        uint256 userUsdcDelta = usdc.balanceOf(userA) - userUsdcBefore;
        assertEq(userUsdcDelta, actualSettled, "user should receive exact settled amount");
        _step(string.concat("  user USDC received = ", vm.toString(userUsdcDelta)));
        _step("  PASS: rate change + fee change -> settlement difference transparent via event, no deadlock");
        _logPass();
    }

    /// @dev Create a new request for userB at the given fee, verify estimatedAssets and treasury
    function _createAndVerifyNewRequest(uint256 redeemShares, uint256 grossAssets, uint256 feeBps)
        internal
        returns (uint256 estNew, uint256 expectedNewFee)
    {
        uint256 treasuryBeforeNew = vault.balanceOf(treasuryAddr);
        uint256 reqNew = _requestRedeem(userB, redeemShares);
        estNew = vault.reqEstimate(reqNew);
        expectedNewFee = _ceilDiv(grossAssets * feeBps, FEE_BASIS);
        uint256 expectedEstNew = grossAssets - expectedNewFee;
        assertEq(estNew, expectedEstNew, "new estimatedAssets should match fee formula");
        uint256 expectedNewTreasury = _ceilDiv(redeemShares * feeBps, FEE_BASIS);
        assertEq(vault.balanceOf(treasuryAddr) - treasuryBeforeNew, expectedNewTreasury, "treasury should receive feeShares");
        _step(string.concat("  new estimatedAssets = ", vm.toString(estNew), " (fee=", vm.toString(expectedNewFee), ")"));
    }
}
