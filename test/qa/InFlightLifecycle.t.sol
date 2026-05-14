// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SubRedManagementAdapter} from "../../src/adapters/digift/SubRedManagementAdapter.sol";
import {Accountant} from "../../src/accountant/Accountant.sol";
import {AccountantExecutor} from "../../src/accountant/AccountantExecutor.sol";
import {ISubRedManagement} from "../../src/interfaces/adapters/digift/ISubRedManagement.sol";
import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {IStrategyControllerExecutor} from "../../src/interfaces/strategy/IStrategyControllerExecutor.sol";
import {IMantleVaultGateway} from "../../src/interfaces/vault/IMantleVaultGateway.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {MockDFeedPriceOracle} from "../../src/mocks/strategy/MockDFeedPriceOracle.sol";
import {MockERC20Mintable} from "../../src/mocks/token/MockERC20Mintable.sol";
import {OperatorExecutor} from "../../src/protocol/OperatorExecutor.sol";
import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {MantleVaultGateway} from "../../src/vault/MantleVaultGateway.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test, console2} from "forge-std/Test.sol";

// ---------------------------------------------------------------
// Minimal mocks for external dependencies not under test
// ---------------------------------------------------------------

contract MockSanctionsOracleIF is ISanctionsOracle {
    function initialize(address, address) external {}
    function isSanctioned(address) external pure returns (bool) { return false; }
    function isWhitelisted(address) external pure returns (bool) { return true; }
    function totalSanctionedCount() external pure returns (uint256) { return 0; }
    function totalWhitelistedCount() external pure returns (uint256) { return 0; }
    function lastUpdateTimestamp() external pure returns (uint256) { return 0; }
    function batchNonce() external pure returns (uint256) { return 0; }
    function MAX_BATCH_SIZE() external pure returns (uint256) { return 200; }
    function updateSanctionStatus(address, bool) external {}
    function updateSanctionStatusBatch(address[] calldata, bool) external {}
    function updateWhitelistStatus(address, bool) external {}
    function updateWhitelistStatusBatch(address[] calldata, bool) external {}
}

contract MockSettlementVenueIF is ISubRedManagement {
    struct PendingFlow {
        uint256 subscribeAsset;
        uint256 redeemPos;
    }

    MockERC20Mintable public immutable assetToken;
    address public owner;
    mapping(address adapter => mapping(address stToken => PendingFlow)) public pending;

    modifier onlyOwner() {
        require(msg.sender == owner, "ONLY_OWNER");
        _;
    }

    constructor(address owner_, address asset_) {
        owner = owner_;
        assetToken = MockERC20Mintable(asset_);
    }

    function subscribe(address stToken, address currencyToken, uint256 amount, uint256) external override {
        IERC20(currencyToken).transferFrom(msg.sender, address(this), amount);
        pending[msg.sender][stToken].subscribeAsset += amount;
    }

    function redeem(address stToken, address, uint256 quantity, uint256) external override {
        IERC20(stToken).transferFrom(msg.sender, address(this), quantity);
        pending[msg.sender][stToken].redeemPos += quantity;
    }

    function settleInvest(address adapter, address stToken, uint256 posAmount, uint256 refundAssetAmount)
        external
        onlyOwner
    {
        PendingFlow storage flow = pending[adapter][stToken];
        require(posAmount + refundAssetAmount <= flow.subscribeAsset, "INVEST_SETTLE_EXCEEDS_PENDING");
        flow.subscribeAsset -= posAmount + refundAssetAmount;

        if (posAmount > 0) {
            MockERC20Mintable(stToken).mint(adapter, posAmount);
        }
        if (refundAssetAmount > 0) {
            IERC20(address(assetToken)).transfer(adapter, refundAssetAmount);
        }
    }

    function settleRedeem(address adapter, address stToken, uint256 assetAmount) external onlyOwner {
        PendingFlow storage flow = pending[adapter][stToken];
        require(assetAmount <= flow.redeemPos, "REDEEM_SETTLE_EXCEEDS_PENDING");
        flow.redeemPos -= assetAmount;
        IERC20(address(assetToken)).transfer(adapter, assetAmount);
    }
}

// ---------------------------------------------------------------
// Test contract — uses REAL vault, controller, executor, adapter
// ---------------------------------------------------------------

contract InFlightLifecycleTest is Test {
    MockERC20Mintable internal asset;
    MockERC20Mintable internal posToken;
    MockSettlementVenueIF internal venue;
    MockDFeedPriceOracle internal priceOracle;
    MockSanctionsOracleIF internal sanctionsOracle;

    MantleYieldVault internal vault;
    MantleVaultGateway internal gateway;
    Accountant internal accountant;
    AccountantExecutor internal accountantExecutor;
    StrategyController internal controller;
    OperatorExecutor internal executor;

    SubRedManagementAdapter internal asyncAdapter;

    address internal admin = makeAddr("admin");
    address internal bot = makeAddr("bot");
    address internal treasury = makeAddr("treasury");
    address internal sanctionSafe = makeAddr("sanctionSafe");

    function setUp() public {
        vm.warp(100_000);

        asset = new MockERC20Mintable("MockAssetIF", "mASIF", 18);
        posToken = new MockERC20Mintable("MockPosIF", "mPIF", 18);
        venue = new MockSettlementVenueIF(admin, address(asset));
        priceOracle = new MockDFeedPriceOracle(1e18, 18);
        sanctionsOracle = new MockSanctionsOracleIF();

        MantleYieldVault vaultImpl = new MantleYieldVault();
        Accountant accountantImpl = new Accountant();
        AccountantExecutor accountantExecutorImpl = new AccountantExecutor();
        StrategyController controllerImpl = new StrategyController();
        OperatorExecutor executorImpl = new OperatorExecutor();
        MantleVaultGateway gatewayImpl = new MantleVaultGateway();

        vault = MantleYieldVault(address(new ERC1967Proxy(
            address(vaultImpl),
            abi.encodeCall(MantleYieldVault.initialize, IMantleYieldVault.InitParams({
                asset: IERC20(address(asset)),
                name: "mRWA Vault",
                symbol: "mRWA",
                admin: admin,
                gateway: address(1),
                controller: admin,
                accountant: address(1),
                treasury: treasury,
                maxRedemptionFeeBps: 500,
                redemptionFeeBps: 0,
                minRedeemAmount: 0,
                minDepositAmount: 0,
                maxSettlementDeviationBps: 0,
                depositDailyRemaining: type(uint256).max,
                redeemDailyRemaining: type(uint256).max
            }))
        )));

        accountant = Accountant(address(new ERC1967Proxy(
            address(accountantImpl),
            abi.encodeCall(Accountant.initialize, (address(vault), 1e18, 0, admin, admin, admin))
        )));

        accountantExecutor = AccountantExecutor(address(new ERC1967Proxy(
            address(accountantExecutorImpl),
            abi.encodeCall(AccountantExecutor.initialize, (admin))
        )));

        executor = OperatorExecutor(address(new ERC1967Proxy(
            address(executorImpl),
            abi.encodeCall(OperatorExecutor.initialize, (admin, bot))
        )));

        controller = StrategyController(address(new ERC1967Proxy(
            address(controllerImpl),
            abi.encodeCall(StrategyController.initialize, (
                address(vault),
                admin,
                address(executor),
                admin,
                0,
                0,
                0
            ))
        )));

        gateway = MantleVaultGateway(address(new ERC1967Proxy(
            address(gatewayImpl),
            abi.encodeCall(MantleVaultGateway.initialize, IMantleVaultGateway.InitParams({
                vault: address(vault),
                sanctionsOracle: sanctionsOracle,
                sanctionSafe: sanctionSafe,
                admin: admin,
                syncRedeemDisabled: false
            }))
        )));

        asyncAdapter = new SubRedManagementAdapter(
            address(vault),
            address(venue),
            address(posToken),
            admin,
            address(controller),
            address(accountantExecutor),
            address(priceOracle)
        );

        vm.startPrank(admin);
        vault.setController(address(controller));
        vault.setAccountant(address(accountant));
        vault.setGateway(address(gateway));
        accountant.grantRole(accountant.ACCOUNTANT_EXECUTOR_ROLE(), address(accountantExecutor));
        controller.registerStrategy(address(asyncAdapter), 10_000, 1, true);
        controller.activateStrategy(address(asyncAdapter));
        address[] memory ordered = new address[](1);
        ordered[0] = address(asyncAdapter);
        controller.setStrategyOrder(ordered);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    function _depositToVault(address user, uint256 assetAmount) internal returns (uint256 shares) {
        asset.mint(user, assetAmount);
        vm.startPrank(user);
        asset.approve(address(vault), assetAmount);
        shares = gateway.deposit(assetAmount);
        vm.stopPrank();
    }

    function _createRedeemRequest(address user, uint256 shares) internal returns (uint256 requestId) {
        vm.prank(user);
        requestId = gateway.requestRedeem(shares);
    }

    function _createInvestInFlightViaRebalance(uint256 investAmount) internal returns (uint256 inFlightId) {
        address depositor = makeAddr("depositor_invest");
        _depositToVault(depositor, investAmount);

        uint256 idBefore = vault.nextInFlightId();
        vm.prank(bot);
        executor.executeRebalance(address(controller));
        require(vault.nextInFlightId() > idBefore, "No invest in-flight created");
        inFlightId = vault.nextInFlightId() - 1;
    }

    function _createRedeemInFlightViaProcessBatch(address user, uint256 assetAmount)
        internal
        returns (uint256 inFlightId, uint256 requestId)
    {
        // 1. Deposit for user
        _depositToVault(user, assetAmount);

        // 2. Rebalance to invest USDC to adapter
        uint256 investIdBefore = vault.nextInFlightId();
        vm.prank(bot);
        executor.executeRebalance(address(controller));
        require(vault.nextInFlightId() > investIdBefore, "No invest in-flight created");
        uint256 investId = vault.nextInFlightId() - 1;

        // 3. Settle the invest (sweep posToken from adapter to vault)
        (,,, uint256 tokenAmt,,,,,) = vault.inFlightRecords(investId);
        _deliverInvestSettlement(tokenAmt, 0);
        _executeSettleAdapter(
            IStrategyControllerExecutor.InvestSettlementInput(
                _u256Array(investId), _u256Array(tokenAmt), _u256Array(uint256(0))
            ),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );
        // Now: vault has posToken, vault has 0 USDC (freeCash = 0)

        // 4. User requests redeem
        uint256 shares = vault.balanceOf(user);
        requestId = _createRedeemRequest(user, shares);

        // 5. processRedeemBatch — freeCash=0 < batchTotalAsset → triggers divest
        uint256 redeemIdBefore = vault.nextInFlightId();
        uint256[] memory ids = new uint256[](1);
        ids[0] = requestId;
        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), ids);
        require(vault.nextInFlightId() > redeemIdBefore, "No redeem in-flight created");
        inFlightId = vault.nextInFlightId() - 1;
    }

    function _deliverInvestSettlement(uint256 settledPos, uint256 refundAsset) internal {
        vm.prank(admin);
        venue.settleInvest(address(asyncAdapter), address(posToken), settledPos, refundAsset);
    }

    function _deliverRedeemSettlement(uint256 settledAsset) internal {
        asset.mint(address(venue), settledAsset);
        vm.prank(admin);
        venue.settleRedeem(address(asyncAdapter), address(posToken), settledAsset);
    }

    function _executeSettleAdapter(
        IStrategyControllerExecutor.InvestSettlementInput memory invest,
        IStrategyControllerExecutor.RedeemSettlementInput memory redeem
    ) internal {
        vm.prank(bot);
        executor.executeSettleAdapter(address(controller), address(asyncAdapter), invest, redeem);
    }

    function _u256Array(uint256 v) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = v;
    }

    // ---------------------------------------------------------------
    // Logging helpers
    // ---------------------------------------------------------------

    string constant MODULE = unicode"In-Flight 生命周期场景";
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

    // ================================================================
    // Test 1 - P0: Create invest in-flight succeeds
    // ================================================================
    function test_CreateInvestInFlight_Success() public {
        _logCase("test_CreateInvestInFlight_Success", unicode"Controller 创建 invest in-flight 记录成功");

        _step("[Step 1] Snapshot invest in-flight totals before creation");
        uint256 investBefore = vault.totalInvestInFlight();
        uint256 adapterBefore = vault.adapterInvestInFlightTokens(address(asyncAdapter));
        _step(string.concat("  investInFlightTotal before = ", vm.toString(investBefore)));
        _step(string.concat("  adapterInvestInFlightTokens before = ", vm.toString(adapterBefore)));

        _step(unicode"[Step 2] Create invest in-flight via rebalance (真实调用流程)");
        uint256 investAmount = 100e18;
        uint256 id = _createInvestInFlightViaRebalance(investAmount);
        _step(string.concat("  investAmount = ", vm.toString(investAmount)));
        _step(string.concat("  inFlightId = ", vm.toString(id)));

        assertGe(id, 1, "id should be >= 1");
        _step(string.concat("  PASS: id = ", vm.toString(id)));

        _step("[Step 3] Verify in-flight record stored correctly");
        (
            uint256 recId,
            address recAdapter,
            address recToken,
            uint256 recTokenAmt,
            uint256 recUsdcAmt,
            uint256 recSettled,
            bool recIsInvest,
            ,
            IMantleYieldVault.InFlightStatus recStatus
        ) = vault.inFlightRecords(id);

        _step(string.concat("  recId = ", vm.toString(recId)));
        _step(string.concat("  recAdapter = ", vm.toString(recAdapter)));
        _step(string.concat("  recToken = ", vm.toString(recToken)));
        _step(string.concat("  recTokenAmt = ", vm.toString(recTokenAmt)));
        _step(string.concat("  recUsdcAmt = ", vm.toString(recUsdcAmt)));
        _step(string.concat("  recSettled = ", vm.toString(recSettled)));
        _step(string.concat("  recIsInvest = ", vm.toString(recIsInvest)));
        _step(string.concat("  recStatus = ", vm.toString(uint8(recStatus))));

        assertEq(recId, id);
        assertEq(recAdapter, address(asyncAdapter));
        assertEq(recToken, address(posToken));
        assertEq(recUsdcAmt, investAmount, "usdcAmt should equal deposited amount (0% buffer)");
        assertEq(recTokenAmt, investAmount, "tokenAmt should equal usdcAmt at 1:1 price");
        assertEq(recSettled, 0);
        assertTrue(recIsInvest);
        assertEq(uint8(recStatus), uint8(IMantleYieldVault.InFlightStatus.PENDING));
        _step("  PASS: all record fields match expected values");

        _step("[Step 4] Verify invest in-flight totals increased");
        assertEq(vault.totalInvestInFlight(), investBefore + recUsdcAmt, "investInFlightTotal increased by usdcAmt");
        assertEq(
            vault.adapterInvestInFlightTokens(address(asyncAdapter)),
            adapterBefore + recTokenAmt,
            "adapterInvestInFlightTokens increased by tokenAmt"
        );
        _step("  PASS: totals increased by exact amounts");
        _logPass();
    }

    // ================================================================
    // Test 2 - P0: Create redeem in-flight succeeds
    // ================================================================
    function test_CreateRedeemInFlight_Success() public {
        _logCase("test_CreateRedeemInFlight_Success", unicode"Controller 创建 redeem in-flight 记录成功");

        _step("[Step 1] Snapshot redeem in-flight totals before creation");
        uint256 redeemBefore = vault.totalRedeemInFlight();
        uint256 adapterBefore = vault.adapterRedeemInFlightUsdc(address(asyncAdapter));
        _step(string.concat("  redeemInFlightTotal before = ", vm.toString(redeemBefore)));
        _step(string.concat("  adapterRedeemInFlightUsdc before = ", vm.toString(adapterBefore)));

        _step(unicode"[Step 2] Create redeem in-flight via processRedeemBatch (真实调用流程)");
        address user = makeAddr("redeemUser");
        uint256 redeemAmount = 50e18;
        (uint256 id, uint256 requestId) = _createRedeemInFlightViaProcessBatch(user, redeemAmount);
        _step(string.concat("  user = ", vm.toString(user)));
        _step(string.concat("  redeemAmount = ", vm.toString(redeemAmount)));
        _step(string.concat("  requestId = ", vm.toString(requestId)));
        _step(string.concat("  inFlightId = ", vm.toString(id)));

        assertGe(id, 1, "id should be >= 1");
        _step(string.concat("  PASS: id = ", vm.toString(id)));

        _step("[Step 3] Verify in-flight record stored correctly");
        (
            uint256 recId,
            address recAdapter,
            ,
            uint256 recTokenAmt,
            uint256 recUsdcAmt,
            uint256 recSettled,
            bool recIsInvest,
            ,
            IMantleYieldVault.InFlightStatus recStatus
        ) = vault.inFlightRecords(id);

        _step(string.concat("  recId = ", vm.toString(recId)));
        _step(string.concat("  recAdapter = ", vm.toString(recAdapter)));
        _step(string.concat("  recTokenAmt = ", vm.toString(recTokenAmt)));
        _step(string.concat("  recUsdcAmt = ", vm.toString(recUsdcAmt)));
        _step(string.concat("  recSettled = ", vm.toString(recSettled)));
        _step(string.concat("  recIsInvest = ", vm.toString(recIsInvest)));
        _step(string.concat("  recStatus = ", vm.toString(uint8(recStatus))));

        assertEq(recId, id);
        assertEq(recAdapter, address(asyncAdapter));
        assertGt(recTokenAmt, 0, "tokenAmt should be > 0");
        assertGt(recUsdcAmt, 0, "usdcAmt should be > 0");
        assertEq(recSettled, 0);
        assertFalse(recIsInvest);
        assertEq(uint8(recStatus), uint8(IMantleYieldVault.InFlightStatus.PENDING));
        _step("  PASS: all record fields match expected values");

        _step("[Step 4] Verify redeem in-flight totals increased");
        assertEq(vault.totalRedeemInFlight(), redeemBefore + recUsdcAmt, "redeemInFlightTotal increased by usdcAmt");
        assertEq(
            vault.adapterRedeemInFlightUsdc(address(asyncAdapter)),
            adapterBefore + recUsdcAmt,
            "adapterRedeemInFlightUsdc increased by usdcAmt"
        );
        _step("  PASS: totals increased by exact amounts");
        _logPass();
    }

    // ================================================================
    // Test 3 - P0: Settle rejects unregistered adapter
    // ================================================================
    function test_CreateInFlight_RevertUnregisteredAdapter() public {
        _logCase("test_CreateInFlight_RevertUnregisteredAdapter", unicode"未注册 adapter 不能创建 in-flight");

        _step("[Step 1] Deploy an unregistered adapter");
        SubRedManagementAdapter unregisteredAdapter = new SubRedManagementAdapter(
            address(vault),
            address(venue),
            address(posToken),
            admin,
            address(controller),
            address(accountantExecutor),
            address(priceOracle)
        );
        _step(string.concat("  unregisteredAdapter = ", vm.toString(address(unregisteredAdapter))));

        _step("[Step 2] Attempt settleAdapter with unregistered adapter");
        _step(string.concat("  caller = bot via executor = ", vm.toString(address(executor))));

        _step("[Step 3] Expect revert with InvalidStrategy for unregistered adapter");
        vm.prank(bot);
        vm.expectRevert(
            abi.encodeWithSelector(StrategyController.Controller__InvalidStrategy.selector, address(unregisteredAdapter))
        );
        executor.executeSettleAdapter(
            address(controller),
            address(unregisteredAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(new uint256[](0), new uint256[](0), new uint256[](0)),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );
        _step("  PASS: reverted as expected with InvalidStrategy");
        _logPass();
    }

    // ================================================================
    // Test 4 - P0: Settle with zero settled amount walks abnormal confirm path
    // ================================================================
    function test_SettleInvestInFlight_ZeroAmountAbnormalConfirm() public {
        _logCase("test_SettleInvestInFlight_ZeroAmountAbnormalConfirm", unicode"0 数量 settle 走异常确认路径，调用成功");

        _step(unicode"[Step 1] Create invest in-flight via rebalance (真实调用流程)");
        uint256 investAmount = 100e18;
        uint256 id = _createInvestInFlightViaRebalance(investAmount);
        (,,, uint256 tokenAmt, uint256 usdcAmt,,,,) = vault.inFlightRecords(id);
        _step(string.concat("  inFlightId = ", vm.toString(id)));
        _step(string.concat("  tokenAmt = ", vm.toString(tokenAmt)));
        _step(string.concat("  usdcAmt = ", vm.toString(usdcAmt)));

        _step("[Step 2] Settle with settledPos=0, refund=0 (zero quantity settle)");
        // Sweep phase: totalPos=0 totalRefund=0 -> no sweep -> passes
        // Confirm phase: settledPosAmount==0 -> abnormal=true -> vault.confirmInFlight succeeds
        vm.prank(bot);
        executor.executeSettleAdapter(
            address(controller),
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(_u256Array(id), _u256Array(uint256(0)), _u256Array(uint256(0))),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );
        _step("  settleAdapter executed successfully (abnormal confirm path)");

        _step("[Step 3] Verify in-flight record is CONFIRMED with settledAmount = 0");
        (,,,,, uint256 settledAmount, bool isInvest,, IMantleYieldVault.InFlightStatus status) =
            vault.inFlightRecords(id);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertTrue(isInvest);
        assertEq(settledAmount, 0);
        _step(string.concat("  status = ", vm.toString(uint8(status))));
        _step(string.concat("  settledAmount = ", vm.toString(settledAmount)));
        _step("  PASS: zero-amount settle confirmed via abnormal path");
        _logPass();
    }

    // ================================================================
    // Test 5 - P0: Invest settlement full execution (pos>0, refund=0)
    // ================================================================
    function test_InvestSettlement_FullExecution() public {
        _logCase("test_InvestSettlement_FullExecution", unicode"confirm invest in-flight 后状态变为 `CONFIRMED` 且统计减少");

        _step(unicode"[Step 1] Create invest in-flight via rebalance (真实调用流程)");
        uint256 investAmount = 100e18;
        uint256 id = _createInvestInFlightViaRebalance(investAmount);
        (,,, uint256 tokenAmt, uint256 usdcAmt,, bool isInvest,,) = vault.inFlightRecords(id);
        _step(string.concat("  inFlightId = ", vm.toString(id)));
        _step(string.concat("  tokenAmt = ", vm.toString(tokenAmt)));
        _step(string.concat("  usdcAmt = ", vm.toString(usdcAmt)));
        assertTrue(isInvest, "Should be invest in-flight");

        _step("[Step 2] Settlement venue delivers full posToken settlement to adapter");
        _deliverInvestSettlement(tokenAmt, 0);
        _step(string.concat("  adapter posToken balance = ", vm.toString(posToken.balanceOf(address(asyncAdapter)))));

        _step(unicode"[Step 3] Call settleAdapter with InvestSettlementInput (真实调用流程)");
        uint256 vaultPosBefore = posToken.balanceOf(address(vault));
        _executeSettleAdapter(
            IStrategyControllerExecutor.InvestSettlementInput(_u256Array(id), _u256Array(tokenAmt), _u256Array(uint256(0))),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );
        uint256 vaultPosAfter = posToken.balanceOf(address(vault));
        assertEq(vaultPosAfter - vaultPosBefore, tokenAmt, "vault should receive posToken from invest settle");
        _step("  settleAdapter executed successfully");

        _step("[Step 4] Verify in-flight record is CONFIRMED with settledAmount = tokenAmt");
        (,,,,, uint256 settledAmount, bool recIsInvest,, IMantleYieldVault.InFlightStatus status) =
            vault.inFlightRecords(id);
        assertTrue(recIsInvest);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(settledAmount, tokenAmt);
        _step("  PASS: status is CONFIRMED and settledAmount matches full pos amount");

        _step("[Step 5] Verify invest in-flight totals decreased to zero");
        assertEq(vault.totalInvestInFlight(), 0);
        assertEq(vault.adapterInvestInFlightTokens(address(asyncAdapter)), 0);
        _step("  PASS: totals decreased to zero (full execution, no refund)");
        _logPass();
    }

    // ================================================================
    // Test 6 - P0: Confirm redeem in-flight via settleAdapter
    // ================================================================
    function test_ConfirmRedeemInFlight_Success() public {
        _logCase("test_ConfirmRedeemInFlight_Success", unicode"confirm redeem in-flight 后状态变为 `CONFIRMED` 且统计减少");

        _step(unicode"[Step 1] Create redeem in-flight via processRedeemBatch (真实调用流程)");
        address user = makeAddr("redeemUser6");
        uint256 redeemAmount = 80e18;
        (uint256 id, uint256 requestId) = _createRedeemInFlightViaProcessBatch(user, redeemAmount);
        _step(string.concat("  user = ", vm.toString(user)));
        _step(string.concat("  redeemAmount = ", vm.toString(redeemAmount)));
        _step(string.concat("  requestId = ", vm.toString(requestId)));
        _step(string.concat("  inFlightId = ", vm.toString(id)));

        (,,,, uint256 usdcAmt,,,,) = vault.inFlightRecords(id);

        _step("[Step 2] Settlement venue delivers USDC to adapter");
        _deliverRedeemSettlement(usdcAmt);
        _step(string.concat("  venue delivered ", vm.toString(usdcAmt), " to adapter"));

        _step("[Step 3] Call settleAdapter to confirm redeem in-flight");
        uint256 vaultUsdcBefore = asset.balanceOf(address(vault));
        _executeSettleAdapter(
            IStrategyControllerExecutor.InvestSettlementInput(new uint256[](0), new uint256[](0), new uint256[](0)),
            IStrategyControllerExecutor.RedeemSettlementInput(_u256Array(id), _u256Array(usdcAmt))
        );
        uint256 vaultUsdcAfter = asset.balanceOf(address(vault));
        assertEq(vaultUsdcAfter - vaultUsdcBefore, usdcAmt, "vault should receive USDC from redeem settle");
        _step("  settleAdapter executed successfully");

        _step("[Step 4] Verify in-flight record is CONFIRMED");
        (,,,,, uint256 settledAmount, bool isInvest,, IMantleYieldVault.InFlightStatus status) =
            vault.inFlightRecords(id);
        assertFalse(isInvest);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(settledAmount, usdcAmt);
        _step("  PASS: status is CONFIRMED and settledAmount matches");

        _step("[Step 5] Verify redeem in-flight totals decreased to zero");
        assertEq(vault.totalRedeemInFlight(), 0);
        assertEq(vault.adapterRedeemInFlightUsdc(address(asyncAdapter)), 0);
        _step("  PASS: totals decreased to zero");
        _logPass();
    }

    // ================================================================
    // Test 7 - P1: Confirm in-flight records actual (differing) amount
    // ================================================================
    function test_ConfirmInFlight_ActualAmountDiffers() public {
        _logCase("test_ConfirmInFlight_ActualAmountDiffers", unicode"底层回填资金确认时，应允许按真实到账金额确认 in-flight，并将偏差传导到最终结算");

        _step(unicode"[Step 1] Create invest in-flight via rebalance (真实调用流程)");
        uint256 investAmount = 100e18;
        uint256 id = _createInvestInFlightViaRebalance(investAmount);

        (,,, uint256 tokenAmt, uint256 usdcAmt,,,,) = vault.inFlightRecords(id);
        uint256 actualSettled = tokenAmt * 99 / 100; // 99% delivered
        _step(string.concat("  inFlightId = ", vm.toString(id)));
        _step(string.concat("  original tokenAmt = ", vm.toString(tokenAmt)));
        _step(string.concat("  actualSettled (differs) = ", vm.toString(actualSettled)));

        _step("[Step 2] Settlement venue delivers partial posToken and refund asset");
        uint256 refundAmount = usdcAmt - ((usdcAmt * actualSettled) / tokenAmt);
        _deliverInvestSettlement(actualSettled, refundAmount);

        _executeSettleAdapter(
            IStrategyControllerExecutor.InvestSettlementInput(
                _u256Array(id), _u256Array(actualSettled), _u256Array(refundAmount)
            ),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );
        _step("  settleAdapter executed successfully");

        _step("[Step 3] Verify record is CONFIRMED with actual (differing) amount");
        (,,,,, uint256 settledAmount, bool isInvest2,, IMantleYieldVault.InFlightStatus status) =
            vault.inFlightRecords(id);
        assertTrue(isInvest2);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(settledAmount, actualSettled);
        assertTrue(settledAmount < tokenAmt);
        _step(string.concat("  PASS: settledAmount (", vm.toString(settledAmount), ") < original tokenAmt (", vm.toString(tokenAmt), ")"));
        _logPass();
    }

    // ================================================================
    // Test 8 - P1: Duplicate confirm is rejected
    // ================================================================
    function test_ConfirmInFlight_RevertDuplicateConfirm() public {
        _logCase("test_ConfirmInFlight_RevertDuplicateConfirm", unicode"重复 confirm 同一 in-flight 被拒绝");

        _step(unicode"[Step 1] Create invest in-flight via rebalance");
        uint256 investAmount = 50e18;
        uint256 id = _createInvestInFlightViaRebalance(investAmount);
        _step(string.concat("  inFlightId = ", vm.toString(id)));

        (,,, uint256 tokenAmt,,,,,) = vault.inFlightRecords(id);

        _step("[Step 2] Settlement venue delivers posToken for the first settle");
        _deliverInvestSettlement(tokenAmt, 0);
        _executeSettleAdapter(
            IStrategyControllerExecutor.InvestSettlementInput(_u256Array(id), _u256Array(tokenAmt), _u256Array(uint256(0))),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );
        _step("  first settleAdapter executed successfully");

        _step("[Step 3] Verify in-flight is now CONFIRMED");
        (,,,,,,,, IMantleYieldVault.InFlightStatus status) = vault.inFlightRecords(id);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        _step("  PASS: status is CONFIRMED after first settle");

        _step("[Step 4] Create a second real invest in-flight so adapter again has sweepable posToken");
        uint256 secondId = _createInvestInFlightViaRebalance(investAmount);
        (,,, uint256 secondTokenAmt,,,,,) = vault.inFlightRecords(secondId);
        _deliverInvestSettlement(secondTokenAmt, 0);
        _step(string.concat("  secondInFlightId = ", vm.toString(secondId)));
        _step(string.concat("  secondTokenAmt = ", vm.toString(secondTokenAmt)));

        _step("[Step 5] Second settleAdapter reuses first id (already CONFIRMED) => revert");
        vm.expectRevert(
            abi.encodeWithSelector(
                IMantleYieldVault.Vault__InvalidInFlightState.selector,
                id,
                IMantleYieldVault.InFlightStatus.CONFIRMED
            )
        );
        vm.prank(bot);
        executor.executeSettleAdapter(
            address(controller),
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(
                _u256Array(id), _u256Array(secondTokenAmt), _u256Array(uint256(0))
            ),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );
        _step("  PASS: duplicate confirm reverted with Vault__InvalidInFlightState");

        _step("[Step 6] Verify original in-flight record unchanged");
        (,,,,, uint256 settledAmount,,, IMantleYieldVault.InFlightStatus finalStatus) = vault.inFlightRecords(id);
        assertEq(uint8(finalStatus), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(settledAmount, tokenAmt, "settledAmount unchanged from first settle");
        _step("  PASS: original record not overwritten");
        _logPass();
    }

    // ================================================================
    // Test 9 - P1: Abnormal confirm allows zero settled amount (full refund)
    // ================================================================
    function test_ConfirmInFlight_AbnormalAllowsZeroAmount() public {
        _logCase("test_ConfirmInFlight_AbnormalAllowsZeroAmount", unicode"`confirmInFlight` 在异常确认模式下允许 `actualAmount=0`");

        _step(unicode"[Step 1] Create invest in-flight via rebalance (真实调用流程)");
        uint256 investAmount = 100e18;
        uint256 id = _createInvestInFlightViaRebalance(investAmount);

        (,,, uint256 tokenAmt, uint256 usdcAmt,,,,) = vault.inFlightRecords(id);
        _step(string.concat("  inFlightId = ", vm.toString(id)));
        _step(string.concat("  tokenAmt = ", vm.toString(tokenAmt)));
        _step(string.concat("  usdcAmt = ", vm.toString(usdcAmt)));

        _step("[Step 2] Settlement venue delivers a full refund and no posToken");
        uint256 settledPos = 0;
        uint256 refundAsset = usdcAmt;
        _deliverInvestSettlement(settledPos, refundAsset);
        _step(string.concat("  settledPos = ", vm.toString(settledPos)));
        _step(string.concat("  refundAsset = ", vm.toString(refundAsset)));
        _step("  (triggers abnormal confirm path)");

        _executeSettleAdapter(
            IStrategyControllerExecutor.InvestSettlementInput(
                _u256Array(id), _u256Array(settledPos), _u256Array(refundAsset)
            ),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );
        _step("  settleAdapter executed successfully (no revert)");

        _step("[Step 3] Verify record is CONFIRMED with settledAmount = 0");
        (,,,,, uint256 settledAmount, bool isInvest,, IMantleYieldVault.InFlightStatus status) =
            vault.inFlightRecords(id);
        assertTrue(isInvest);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(settledAmount, 0);
        _step("  PASS: abnormal confirm accepted with zero settled amount (full refund)");
        _logPass();
    }

    // ================================================================
    // Test 10 - P1: Redeem settle with zero settled amount walks abnormal path
    // ================================================================
    function test_SettleRedeemInFlight_ZeroAmountAbnormalConfirm() public {
        _logCase("test_SettleRedeemInFlight_ZeroAmountAbnormalConfirm", unicode"`confirmInFlight` 在非异常确认模式下允许 `actualAmount=0`（走异常路径）");

        _step(unicode"[Step 1] Create redeem in-flight via processRedeemBatch (真实调用流程)");
        address user = makeAddr("redeemUser10");
        uint256 redeemAmount = 50e18;
        (uint256 id, uint256 requestId) = _createRedeemInFlightViaProcessBatch(user, redeemAmount);
        _step(string.concat("  inFlightId = ", vm.toString(id)));
        _step(string.concat("  requestId = ", vm.toString(requestId)));

        (,,,, uint256 usdcAmt,,,,) = vault.inFlightRecords(id);
        _step(string.concat("  usdcAmt = ", vm.toString(usdcAmt)));

        _step("[Step 2] Settle with settledAmount=0 (triggers abnormal confirm path)");
        // settledAmount=0 -> abnormal=true in controller._confirmSingleRedeemInFlight
        _executeSettleAdapter(
            IStrategyControllerExecutor.InvestSettlementInput(new uint256[](0), new uint256[](0), new uint256[](0)),
            IStrategyControllerExecutor.RedeemSettlementInput(_u256Array(id), _u256Array(uint256(0)))
        );
        _step("  settleAdapter executed successfully (abnormal confirm path)");

        _step("[Step 3] Verify in-flight record is CONFIRMED with settledAmount = 0");
        (,,,,, uint256 settledAmount, bool isInvest,, IMantleYieldVault.InFlightStatus status) =
            vault.inFlightRecords(id);
        assertFalse(isInvest);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(settledAmount, 0);
        _step(string.concat("  status = ", vm.toString(uint8(status))));
        _step(string.concat("  settledAmount = ", vm.toString(settledAmount)));
        _step("  PASS: redeem in-flight confirmed via abnormal path with settledAmount=0");
        _logPass();
    }

    // ================================================================
    // Test 11 - P0: Invest settlement with partial refund (pos>0, refund>0)
    // ================================================================
    function test_InvestSettlement_PartialRefund() public {
        _logCase("test_InvestSettlement_PartialRefund", unicode"invest 结算：部分退款（pos>0, refund>0）");

        _step(unicode"[Step 1] Create invest in-flight via rebalance (真实调用流程)");
        uint256 investAmount = 100e18;
        uint256 id = _createInvestInFlightViaRebalance(investAmount);

        (,,, uint256 tokenAmt, uint256 usdcAmt,,,,) = vault.inFlightRecords(id);
        _step(string.concat("  inFlightId = ", vm.toString(id)));
        _step(string.concat("  tokenAmt = ", vm.toString(tokenAmt)));
        _step(string.concat("  usdcAmt = ", vm.toString(usdcAmt)));

        _step("[Step 2] Settlement venue delivers 70% posToken and 30% refund");
        uint256 settledPos = tokenAmt * 70 / 100;
        uint256 refundAsset = usdcAmt - ((usdcAmt * settledPos) / tokenAmt);
        _deliverInvestSettlement(settledPos, refundAsset);
        _step(string.concat("  settledPos = ", vm.toString(settledPos)));
        _step(string.concat("  refundAsset = ", vm.toString(refundAsset)));

        _step("[Step 3] Call settleAdapter with InvestSettlementInput");
        uint256 vaultPosBefore = posToken.balanceOf(address(vault));
        uint256 vaultAssetBefore = asset.balanceOf(address(vault));
        _executeSettleAdapter(
            IStrategyControllerExecutor.InvestSettlementInput(
                _u256Array(id), _u256Array(settledPos), _u256Array(refundAsset)
            ),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );
        _step("  settleAdapter executed successfully");

        _step("[Step 4] Verify vault received both posToken and refund asset");
        assertEq(posToken.balanceOf(address(vault)) - vaultPosBefore, settledPos, "vault received posToken");
        assertEq(asset.balanceOf(address(vault)) - vaultAssetBefore, refundAsset, "vault received refund asset");
        _step("  PASS: vault received correct amounts of posToken and asset");

        _step("[Step 5] Verify in-flight record is CONFIRMED with settledAmount = settledPos");
        (,,,,, uint256 settledAmount, bool isInvest,, IMantleYieldVault.InFlightStatus status) =
            vault.inFlightRecords(id);
        assertTrue(isInvest);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(settledAmount, settledPos);
        _step("  PASS: status is CONFIRMED, settledAmount reflects partial pos");

        _step("[Step 6] Verify invest in-flight totals decreased");
        assertEq(vault.totalInvestInFlight(), 0);
        assertEq(vault.adapterInvestInFlightTokens(address(asyncAdapter)), 0);
        _step("  PASS: totals decreased to zero after partial refund settlement");
        _logPass();
    }

    // ================================================================
    // Test 12 - P0: Invest settlement with full refund (pos=0, refund>0)
    // ================================================================
    function test_InvestSettlement_FullRefund() public {
        _logCase("test_InvestSettlement_FullRefund", unicode"invest 结算：全额退款（pos=0, refund>0）");

        _step(unicode"[Step 1] Create invest in-flight via rebalance (真实调用流程)");
        uint256 investAmount = 100e18;
        uint256 id = _createInvestInFlightViaRebalance(investAmount);

        (,,, uint256 tokenAmt, uint256 usdcAmt,,,,) = vault.inFlightRecords(id);
        _step(string.concat("  inFlightId = ", vm.toString(id)));
        _step(string.concat("  tokenAmt = ", vm.toString(tokenAmt)));
        _step(string.concat("  usdcAmt = ", vm.toString(usdcAmt)));

        _step("[Step 2] Settlement venue delivers a full refund with no posToken");
        uint256 settledPos = 0;
        uint256 refundAsset = usdcAmt;
        _deliverInvestSettlement(settledPos, refundAsset);

        _step("[Step 3] Call settleAdapter with pos=0, refund=full");
        uint256 vaultPosBefore = posToken.balanceOf(address(vault));
        uint256 vaultAssetBefore = asset.balanceOf(address(vault));
        _executeSettleAdapter(
            IStrategyControllerExecutor.InvestSettlementInput(
                _u256Array(id), _u256Array(settledPos), _u256Array(refundAsset)
            ),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );
        _step("  settleAdapter executed successfully (abnormal confirm path)");

        _step("[Step 4] Verify only asset was swept (no posToken for pos=0)");
        assertEq(posToken.balanceOf(address(vault)) - vaultPosBefore, 0, "no posToken swept");
        assertEq(asset.balanceOf(address(vault)) - vaultAssetBefore, refundAsset, "vault received full refund");
        _step("  PASS: vault received only asset refund, no posToken");

        _step("[Step 5] Verify in-flight record is CONFIRMED with settledAmount = 0 (abnormal)");
        (,,,,, uint256 settledAmount, bool isInvest,, IMantleYieldVault.InFlightStatus status) =
            vault.inFlightRecords(id);
        assertTrue(isInvest);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(settledAmount, 0);
        _step("  PASS: abnormal confirm succeeded, settledAmount = 0 (full refund)");

        _step("[Step 6] Verify invest in-flight totals decreased");
        assertEq(vault.totalInvestInFlight(), 0);
        assertEq(vault.adapterInvestInFlightTokens(address(asyncAdapter)), 0);
        _step("  PASS: totals decreased to zero after full refund");
        _logPass();
    }

    // ================================================================
    // Test 13 - P1: Invest settlement reverts on pos sweep mismatch
    // ================================================================
    function test_InvestSettlement_RevertPosSweepMismatch() public {
        _logCase("test_InvestSettlement_RevertPosSweepMismatch", unicode"invest 结算：pos sweep 数量不足时整笔回滚");

        _step(unicode"[Step 1] Create invest in-flight via rebalance (真实调用流程)");
        uint256 investAmount = 100e18;
        uint256 id = _createInvestInFlightViaRebalance(investAmount);

        (,,, uint256 tokenAmt,,,,,) = vault.inFlightRecords(id);
        _step(string.concat("  inFlightId = ", vm.toString(id)));
        _step(string.concat("  tokenAmt = ", vm.toString(tokenAmt)));

        _step("[Step 2] Settlement venue delivers only 90% of the requested posToken");
        uint256 requestedPos = tokenAmt;
        uint256 actualPos = tokenAmt * 90 / 100;
        _deliverInvestSettlement(actualPos, 0);
        _step(string.concat("  requestedPos = ", vm.toString(requestedPos)));
        _step(string.concat("  actualPos (adapter balance) = ", vm.toString(actualPos)));

        _step("[Step 3] Expect revert with InvestSweepAmountMismatch");
        vm.prank(bot);
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyController.Controller__InvestSweepAmountMismatch.selector,
                address(asyncAdapter),
                requestedPos,
                actualPos
            )
        );
        executor.executeSettleAdapter(
            address(controller),
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(
                _u256Array(id), _u256Array(requestedPos), _u256Array(uint256(0))
            ),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );
        _step("  PASS: reverted as expected with InvestSweepAmountMismatch");

        _step("[Step 4] Verify in-flight remains PENDING");
        (,,,,,,,, IMantleYieldVault.InFlightStatus status) = vault.inFlightRecords(id);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.PENDING));
        _step("  PASS: in-flight status still PENDING (rollback succeeded)");
        _logPass();
    }

    // ================================================================
    // Test 14 - P1: Invest settlement reverts on refund sweep mismatch
    // ================================================================
    function test_InvestSettlement_RevertRefundSweepMismatch() public {
        _logCase("test_InvestSettlement_RevertRefundSweepMismatch", unicode"invest 结算：refund sweep 数量不足时整笔回滚");

        _step(unicode"[Step 1] Create invest in-flight via rebalance (真实调用流程)");
        uint256 investAmount = 100e18;
        uint256 id = _createInvestInFlightViaRebalance(investAmount);

        (,,, uint256 tokenAmt, uint256 usdcAmt,,,,) = vault.inFlightRecords(id);
        _step(string.concat("  inFlightId = ", vm.toString(id)));
        _step(string.concat("  tokenAmt = ", vm.toString(tokenAmt)));

        _step("[Step 2] Settlement venue delivers 70% posToken, but refund is short");
        uint256 settledPos = tokenAmt * 70 / 100;
        uint256 requestedRefund = usdcAmt - ((usdcAmt * settledPos) / tokenAmt);
        uint256 actualRefund = requestedRefund * 2 / 3;
        _deliverInvestSettlement(settledPos, actualRefund);
        _step(string.concat("  settledPos = ", vm.toString(settledPos)));
        _step(string.concat("  requestedRefund = ", vm.toString(requestedRefund)));
        _step(string.concat("  actualRefund (adapter balance) = ", vm.toString(actualRefund)));

        _step("[Step 3] Expect revert with InvestRefundSweepAmountMismatch");
        vm.prank(bot);
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyController.Controller__InvestRefundSweepAmountMismatch.selector,
                address(asyncAdapter),
                requestedRefund,
                actualRefund
            )
        );
        executor.executeSettleAdapter(
            address(controller),
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(
                _u256Array(id), _u256Array(settledPos), _u256Array(requestedRefund)
            ),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );
        _step("  PASS: reverted as expected with InvestRefundSweepAmountMismatch");

        _step("[Step 4] Verify in-flight remains PENDING");
        (,,,,,,,, IMantleYieldVault.InFlightStatus status) = vault.inFlightRecords(id);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.PENDING));
        _step("  PASS: in-flight status still PENDING (rollback succeeded)");
        _logPass();
    }
}
