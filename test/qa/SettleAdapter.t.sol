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

contract MockSanctionsOracleSA is ISanctionsOracle {
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

contract MockSettlementVenueSA is ISubRedManagement {
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

    /// @dev NOTE: The accounting `posAmount + refundAssetAmount <= subscribeAsset` is only
    ///      valid when posTokenPrice = 1e18 (1:1). At non-1:1 prices, posAmount would need
    ///      conversion to asset units first. This mock is intentionally simple.
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

contract SettleAdapterQATest is Test {
    MockERC20Mintable internal asset;
    MockERC20Mintable internal posToken1;
    MockERC20Mintable internal posToken2;
    MockERC20Mintable internal posToken3;
    MockSettlementVenueSA internal venue;
    MockDFeedPriceOracle internal priceOracle;
    MockSanctionsOracleSA internal sanctionsOracle;

    MantleYieldVault internal vault;
    MantleVaultGateway internal gateway;
    Accountant internal accountant;
    AccountantExecutor internal accountantExecutor;
    StrategyController internal controller;
    OperatorExecutor internal operatorExecutor;

    SubRedManagementAdapter internal asyncAdapter;
    SubRedManagementAdapter internal asyncAdapter2;

    address internal admin = makeAddr("admin");
    address internal bot = makeAddr("bot");
    address internal acctBot = makeAddr("acctBot");
    address internal treasury = makeAddr("treasury");
    address internal sanctionSafe = makeAddr("sanctionSafe");

    string constant MODULE = unicode"Settle Adapter 结算场景";
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

    function setUp() public {
        vm.warp(100_000);

        asset = new MockERC20Mintable("MockAssetSA", "mASA", 18);
        posToken1 = new MockERC20Mintable("MockPos1", "mPOS1", 18);
        posToken2 = new MockERC20Mintable("MockPos2", "mPOS2", 18);
        posToken3 = new MockERC20Mintable("MockPos3", "mPOS3", 18);
        venue = new MockSettlementVenueSA(admin, address(asset));
        priceOracle = new MockDFeedPriceOracle(1e18, 18);
        sanctionsOracle = new MockSanctionsOracleSA();

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
            abi.encodeCall(Accountant.initialize, (address(vault), 1e18, 0, admin))
        )));

        accountantExecutor = AccountantExecutor(address(new ERC1967Proxy(
            address(accountantExecutorImpl),
            abi.encodeCall(AccountantExecutor.initialize, (admin))
        )));

        operatorExecutor = OperatorExecutor(address(new ERC1967Proxy(
            address(executorImpl),
            abi.encodeCall(OperatorExecutor.initialize, (admin, bot))
        )));

        controller = StrategyController(address(new ERC1967Proxy(
            address(controllerImpl),
            abi.encodeCall(StrategyController.initialize, (
                address(vault),
                admin,
                address(operatorExecutor),
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
            address(posToken1),
            admin,
            address(controller),
            address(accountantExecutor),
            address(priceOracle)
        );
        asyncAdapter2 = new SubRedManagementAdapter(
            address(vault),
            address(venue),
            address(posToken2),
            admin,
            address(controller),
            address(accountantExecutor),
            address(priceOracle)
        );

        vm.startPrank(admin);
        vault.setController(address(controller));
        vault.setAccountant(address(accountant));
        vault.setGateway(address(gateway));
        accountantExecutor.grantRole(accountantExecutor.BOT_ROLE(), acctBot);
        accountant.grantRole(accountant.ACCOUNTANT_EXECUTOR_ROLE(), address(accountantExecutor));
        controller.registerStrategy(address(asyncAdapter), 10_000, 1, true);
        controller.activateStrategy(address(asyncAdapter));
        address[] memory ordered = new address[](1);
        ordered[0] = address(asyncAdapter);
        controller.setStrategyOrder(ordered);
        vm.stopPrank();
    }

    function _adapterPosToken(address adapter) internal view returns (MockERC20Mintable) {
        if (adapter == address(asyncAdapter)) return posToken1;
        if (adapter == address(asyncAdapter2)) return posToken2;
        revert("UNKNOWN_ADAPTER");
    }

    function _registerSecondAdapter() internal {
        vm.startPrank(admin);
        controller.registerStrategy(address(asyncAdapter2), 5000, 2, true);
        controller.activateStrategy(address(asyncAdapter2));

        address[] memory adapters = new address[](2);
        adapters[0] = address(asyncAdapter);
        adapters[1] = address(asyncAdapter2);
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5000;
        weights[1] = 5000;
        uint16[] memory priorities = new uint16[](2);
        priorities[0] = 1;
        priorities[1] = 2;
        bool[] memory asyncFlags = new bool[](2);
        asyncFlags[0] = true;
        asyncFlags[1] = true;
        address[] memory ordered = new address[](2);
        ordered[0] = address(asyncAdapter);
        ordered[1] = address(asyncAdapter2);
        controller.updateStrategiesAndOrder(adapters, weights, priorities, asyncFlags, ordered);
        vm.stopPrank();
    }

    function _focusSingleStrategy(address target) internal {
        if (!vault.isAdapter(address(asyncAdapter2))) {
            vm.startPrank(admin);
            address[] memory orderedSingle = new address[](1);
            orderedSingle[0] = target;
            controller.setStrategyOrder(orderedSingle);
            vm.stopPrank();
            return;
        }

        vm.startPrank(admin);
        address[] memory adapters = new address[](2);
        adapters[0] = address(asyncAdapter);
        adapters[1] = address(asyncAdapter2);
        uint16[] memory weights = new uint16[](2);
        weights[0] = target == address(asyncAdapter) ? 10_000 : 0;
        weights[1] = target == address(asyncAdapter2) ? 10_000 : 0;
        uint16[] memory priorities = new uint16[](2);
        priorities[0] = 1;
        priorities[1] = 2;
        bool[] memory asyncFlags = new bool[](2);
        asyncFlags[0] = true;
        asyncFlags[1] = true;
        address[] memory ordered = new address[](1);
        ordered[0] = target;
        controller.updateStrategiesAndOrder(adapters, weights, priorities, asyncFlags, ordered);
        vm.stopPrank();
    }

    function _depositToVault(address user, uint256 assetAmount) internal returns (uint256 shares) {
        asset.mint(user, assetAmount);
        vm.startPrank(user);
        asset.approve(address(vault), assetAmount);
        shares = gateway.deposit(assetAmount);
        vm.stopPrank();
    }

    function _createInvestInFlightViaRebalance(uint256 investAmount) internal returns (uint256 inFlightId) {
        return _createInvestInFlightViaRebalanceFor(address(asyncAdapter), investAmount);
    }

    function _createInvestInFlightViaRebalanceFor(address adapter, uint256 investAmount)
        internal
        returns (uint256 inFlightId)
    {
        _focusSingleStrategy(adapter);
        address depositor = makeAddr("depositor_invest_sa");
        _depositToVault(depositor, investAmount);

        uint256 nextBefore = vault.nextInFlightId();
        vm.prank(bot);
        operatorExecutor.executeRebalance(address(controller));
        require(vault.nextInFlightId() > nextBefore, "No invest in-flight created");
        inFlightId = vault.nextInFlightId() - 1;
    }

    function _deliverInvestSettlement(uint256 settledPos, uint256 refundAsset) internal {
        _deliverInvestSettlementFor(address(asyncAdapter), settledPos, refundAsset);
    }

    function _deliverInvestSettlementFor(address adapter, uint256 settledPos, uint256 refundAsset) internal {
        vm.prank(admin);
        venue.settleInvest(adapter, address(_adapterPosToken(adapter)), settledPos, refundAsset);
    }

    function _createRedeemRequest(address user, uint256 shares) internal returns (uint256 requestId) {
        vm.prank(user);
        requestId = gateway.requestRedeem(shares);
    }

    function _createRedeemInFlightViaProcessBatch(uint256 assetAmount)
        internal
        returns (uint256 inFlightId, uint256 requestId, uint256 redeemPosAmount, uint256 redeemAssetAmount)
    {
        return _createRedeemInFlightViaProcessBatchFor(address(asyncAdapter), assetAmount);
    }

    function _createRedeemInFlightViaProcessBatchFor(address adapter, uint256 assetAmount)
        internal
        returns (uint256 inFlightId, uint256 requestId, uint256 redeemPosAmount, uint256 redeemAssetAmount)
    {
        _focusSingleStrategy(adapter);
        address user = makeAddr("redeem_user_sa");
        _depositToVault(user, assetAmount);

        uint256 investNextBefore = vault.nextInFlightId();
        vm.prank(bot);
        operatorExecutor.executeRebalance(address(controller));
        require(vault.nextInFlightId() > investNextBefore, "No invest in-flight created");
        uint256 investId = vault.nextInFlightId() - 1;
        (uint256 investTokenAmount,) = _readInvestInFlightAmounts(investId);

        uint256[] memory investIds = new uint256[](1);
        investIds[0] = investId;
        uint256[] memory settledPos = new uint256[](1);
        settledPos[0] = investTokenAmount;
        uint256[] memory refunds = new uint256[](1);
        refunds[0] = 0;
        vm.prank(admin);
        venue.settleInvest(adapter, address(_adapterPosToken(adapter)), investTokenAmount, 0);
        _executeSettleAdapter(
            adapter,
            IStrategyControllerExecutor.InvestSettlementInput(investIds, settledPos, refunds),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );

        uint256 shares = vault.balanceOf(user);
        requestId = _createRedeemRequest(user, shares);

        uint256 redeemNextBefore = vault.nextInFlightId();
        uint256[] memory ids = new uint256[](1);
        ids[0] = requestId;
        vm.prank(bot);
        operatorExecutor.executeProcessRedeemBatch(address(controller), ids);

        require(vault.nextInFlightId() > redeemNextBefore, "No redeem in-flight created");
        inFlightId = vault.nextInFlightId() - 1;
        (,,, redeemPosAmount, redeemAssetAmount,,,,) = vault.inFlightRecords(inFlightId);
    }

    function _deliverRedeemSettlement(uint256 settledAsset) internal {
        _deliverRedeemSettlementFor(address(asyncAdapter), settledAsset);
    }

    function _deliverRedeemSettlementFor(address adapter, uint256 settledAsset) internal {
        asset.mint(address(venue), settledAsset);
        vm.prank(admin);
        venue.settleRedeem(adapter, address(_adapterPosToken(adapter)), settledAsset);
    }

    function _readInvestInFlightAmounts(uint256 inFlightId) internal view returns (uint256 tokenAmount, uint256 usdcAmount) {
        (,,, tokenAmount, usdcAmount,,,,) = vault.inFlightRecords(inFlightId);
    }

    function _executeSettleAdapter(
        address adapter,
        IStrategyControllerExecutor.InvestSettlementInput memory invest,
        IStrategyControllerExecutor.RedeemSettlementInput memory redeem
    ) internal {
        vm.prank(bot);
        operatorExecutor.executeSettleAdapter(address(controller), adapter, invest, redeem);
    }

    function _executeSettleAdapters(
        address[] memory adapters,
        IStrategyControllerExecutor.InvestSettlementInput[] memory investBatch,
        IStrategyControllerExecutor.RedeemSettlementInput[] memory redeemBatch
    ) internal {
        vm.prank(bot);
        operatorExecutor.executeSettleAdapters(address(controller), adapters, investBatch, redeemBatch);
    }

    function _prepareRealRedeemSettlementBalance(address adapter, uint256 assetAmount) internal {
        // When another redeem request is already PROCESSING, the vault keeps floating-locked
        // liability, so depositing only `assetAmount` may still leave freeCash at zero and
        // produce no invest action. Seed enough cash to clear the locked liability and create
        // real sweepable adapter assets for this negative-path settlement test.
        uint256 investId = _createInvestInFlightViaRebalanceFor(adapter, assetAmount * 2);
        (, uint256 investedAssetAmount) = _readInvestInFlightAmounts(investId);
        require(investedAssetAmount >= assetAmount, "Invest too small");

        // This negative redeem-owner test only needs real sweepable asset on the target adapter
        // so settleAdapter can advance past sweep and reach the redeem in-flight ownership check.
        _deliverInvestSettlementFor(adapter, 0, investedAssetAmount);
    }

    function test_SettleAdapter_InvestAndRedeem_Success() public {
        _logCase(
            "test_SettleAdapter_InvestAndRedeem_Success", unicode"settleAdapter 正常结算：同时处理 invest 与 redeem in-flight"
        );

        _step("[Step 1] Create invest in-flight via deposit -> rebalance");
        uint256 investId = _createInvestInFlightViaRebalance(100e18);
        (uint256 investTokenAmount,) = _readInvestInFlightAmounts(investId);
        _step(string.concat("  investId = ", vm.toString(investId)));

        _step("[Step 2] Create redeem in-flight via requestRedeem -> processRedeemBatch");
        (uint256 redeemId,, , uint256 redeemAssetAmount) = _createRedeemInFlightViaProcessBatch(50e18);
        _step(string.concat("  redeemId = ", vm.toString(redeemId)));

        _step("[Step 3] Simulate external venue settlement");
        _deliverInvestSettlement(investTokenAmount, 0);
        _deliverRedeemSettlement(redeemAssetAmount);

        uint256[] memory investIds = new uint256[](1);
        investIds[0] = investId;
        uint256[] memory investAmounts = new uint256[](1);
        investAmounts[0] = investTokenAmount;
        uint256[] memory redeemIds = new uint256[](1);
        redeemIds[0] = redeemId;
        uint256[] memory redeemAmounts = new uint256[](1);
        redeemAmounts[0] = redeemAssetAmount;

        uint256 vaultPosBefore = posToken1.balanceOf(address(vault));
        uint256 vaultAssetBefore = asset.balanceOf(address(vault));

        _step("[Step 4] Call settleAdapter via OperatorExecutor");
        _executeSettleAdapter(
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(investIds, investAmounts, new uint256[](1)),
            IStrategyControllerExecutor.RedeemSettlementInput(redeemIds, redeemAmounts)
        );

        _step("[Step 5] Verify in-flights confirmed and balances swept");
        (,,,,, uint256 settledInvest,,, IMantleYieldVault.InFlightStatus investStatus) = vault.inFlightRecords(investId);
        (,,,,, uint256 settledRedeem,,, IMantleYieldVault.InFlightStatus redeemStatus) = vault.inFlightRecords(redeemId);
        assertEq(settledInvest, investTokenAmount);
        assertEq(settledRedeem, redeemAssetAmount);
        assertEq(uint8(investStatus), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(uint8(redeemStatus), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(posToken1.balanceOf(address(vault)), vaultPosBefore + investTokenAmount);
        assertEq(asset.balanceOf(address(vault)), vaultAssetBefore + redeemAssetAmount);
        assertEq(posToken1.balanceOf(address(asyncAdapter)), 0);
        assertEq(asset.balanceOf(address(asyncAdapter)), 0);
        _logPass();
    }

    function test_SettleAdapter_OnlyRedeem_Success() public {
        _logCase("test_SettleAdapter_OnlyRedeem_Success", unicode"settleAdapter 仅结算 redeem 回款（只处理 asset sweep）");

        (uint256 redeemId,, , uint256 redeemAssetAmount) = _createRedeemInFlightViaProcessBatch(80e18);
        _deliverRedeemSettlement(redeemAssetAmount);

        uint256[] memory emptyIds = new uint256[](0);
        uint256[] memory emptyAmounts = new uint256[](0);
        uint256[] memory redeemIds = new uint256[](1);
        redeemIds[0] = redeemId;
        uint256[] memory redeemAmounts = new uint256[](1);
        redeemAmounts[0] = redeemAssetAmount;
        uint256 vaultAssetBefore = asset.balanceOf(address(vault));
        uint256 vaultPosBefore = posToken1.balanceOf(address(vault));

        _executeSettleAdapter(
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(emptyIds, emptyAmounts, new uint256[](0)),
            IStrategyControllerExecutor.RedeemSettlementInput(redeemIds, redeemAmounts)
        );

        (,,,,,,,, IMantleYieldVault.InFlightStatus status) = vault.inFlightRecords(redeemId);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(asset.balanceOf(address(vault)), vaultAssetBefore + redeemAssetAmount);
        assertEq(posToken1.balanceOf(address(vault)), vaultPosBefore);
        assertEq(asset.balanceOf(address(asyncAdapter)), 0);
        _logPass();
    }

    function test_SettleAdapter_OnlyInvest_Success() public {
        _logCase("test_SettleAdapter_OnlyInvest_Success", unicode"settleAdapter 仅结算 invest 到账（只处理 posToken sweep）");

        uint256 investId = _createInvestInFlightViaRebalance(120e18);
        (uint256 investTokenAmount,) = _readInvestInFlightAmounts(investId);
        _deliverInvestSettlement(investTokenAmount, 0);

        uint256[] memory investIds = new uint256[](1);
        investIds[0] = investId;
        uint256[] memory investAmounts = new uint256[](1);
        investAmounts[0] = investTokenAmount;
        uint256[] memory emptyIds = new uint256[](0);
        uint256[] memory emptyAmounts = new uint256[](0);
        uint256 vaultPosBefore = posToken1.balanceOf(address(vault));
        uint256 vaultAssetBefore = asset.balanceOf(address(vault));

        _executeSettleAdapter(
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(investIds, investAmounts, new uint256[](1)),
            IStrategyControllerExecutor.RedeemSettlementInput(emptyIds, emptyAmounts)
        );

        (,,,,,,,, IMantleYieldVault.InFlightStatus status) = vault.inFlightRecords(investId);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(posToken1.balanceOf(address(vault)), vaultPosBefore + investTokenAmount);
        assertEq(asset.balanceOf(address(vault)), vaultAssetBefore);
        assertEq(posToken1.balanceOf(address(asyncAdapter)), 0);
        _logPass();
    }

    function test_SettleAdapter_RevertInvestLengthMismatch() public {
        _logCase("test_SettleAdapter_RevertInvestLengthMismatch", unicode"invest ids 与 invest settledAmounts 长度不一致时被拒绝");

        uint256[] memory investIds = new uint256[](2);
        investIds[0] = 1;
        investIds[1] = 2;
        uint256[] memory investAmounts = new uint256[](1);
        investAmounts[0] = 100e18;

        vm.expectRevert(StrategyController.Controller__SettleAmountsLengthMismatch.selector);
        _executeSettleAdapter(
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(investIds, investAmounts, new uint256[](2)),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );
        _logPass();
    }

    function test_SettleAdapter_RevertRedeemLengthMismatch() public {
        _logCase("test_SettleAdapter_RevertRedeemLengthMismatch", unicode"redeem ids 与 redeem settledAmounts 长度不一致时被拒绝");

        uint256[] memory redeemIds = new uint256[](2);
        redeemIds[0] = 1;
        redeemIds[1] = 2;
        uint256[] memory redeemAmounts = new uint256[](1);
        redeemAmounts[0] = 50e18;

        vm.expectRevert(StrategyController.Controller__SettleAmountsLengthMismatch.selector);
        _executeSettleAdapter(
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(new uint256[](0), new uint256[](0), new uint256[](0)),
            IStrategyControllerExecutor.RedeemSettlementInput(redeemIds, redeemAmounts)
        );
        _logPass();
    }

    function test_SettleAdapter_RevertInvestSweepMismatch() public {
        _logCase(
            "test_SettleAdapter_RevertInvestSweepMismatch",
            unicode"sweep posToken 数量不足时整笔回滚，不存在按 min(requested,balance) 部分成功"
        );

        uint256 investId = _createInvestInFlightViaRebalance(100e18);
        (uint256 investTokenAmount,) = _readInvestInFlightAmounts(investId);
        uint256 partialSettled = (investTokenAmount * 80) / 100;
        _deliverInvestSettlement(partialSettled, 0);

        uint256[] memory investIds = new uint256[](1);
        investIds[0] = investId;
        uint256[] memory investAmounts = new uint256[](1);
        investAmounts[0] = investTokenAmount;

        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyController.Controller__InvestSweepAmountMismatch.selector,
                address(asyncAdapter),
                investTokenAmount,
                partialSettled
            )
        );
        _executeSettleAdapter(
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(investIds, investAmounts, new uint256[](1)),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );
        _logPass();
    }

    function test_SettleAdapter_RevertRedeemSweepMismatch() public {
        _logCase(
            "test_SettleAdapter_RevertRedeemSweepMismatch",
            unicode"sweep asset 数量不足时整笔回滚，不存在按 min(requested,balance) 部分成功"
        );

        (uint256 redeemId,, , uint256 redeemAssetAmount) = _createRedeemInFlightViaProcessBatch(50e18);
        uint256 partialAsset = (redeemAssetAmount * 60) / 100;
        _deliverRedeemSettlement(partialAsset);

        uint256[] memory redeemIds = new uint256[](1);
        redeemIds[0] = redeemId;
        uint256[] memory redeemAmounts = new uint256[](1);
        redeemAmounts[0] = redeemAssetAmount;

        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyController.Controller__RedeemSweepAmountMismatch.selector,
                address(asyncAdapter),
                redeemAssetAmount,
                partialAsset
            )
        );
        _executeSettleAdapter(
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(new uint256[](0), new uint256[](0), new uint256[](0)),
            IStrategyControllerExecutor.RedeemSettlementInput(redeemIds, redeemAmounts)
        );
        _logPass();
    }

    function test_SettleAdapter_SweepFailPreservesState() public {
        _logCase("test_SettleAdapter_SweepFailPreservesState", unicode"sweep 校验失败时，对应 in-flight 状态和累计值保持不变");

        uint256 investId = _createInvestInFlightViaRebalance(100e18);
        (uint256 investTokenAmount,) = _readInvestInFlightAmounts(investId);
        uint256 partialSettled = (investTokenAmount * 80) / 100;
        (,,,,,,,, IMantleYieldVault.InFlightStatus statusBefore) = vault.inFlightRecords(investId);
        uint256 investInFlightBefore = vault.totalInvestInFlight();
        _deliverInvestSettlement(partialSettled, 0);

        uint256[] memory investIds = new uint256[](1);
        investIds[0] = investId;
        uint256[] memory investAmounts = new uint256[](1);
        investAmounts[0] = investTokenAmount;

        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyController.Controller__InvestSweepAmountMismatch.selector,
                address(asyncAdapter),
                investTokenAmount,
                partialSettled
            )
        );
        _executeSettleAdapter(
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(investIds, investAmounts, new uint256[](1)),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );

        (,,,,,,,, IMantleYieldVault.InFlightStatus statusAfter) = vault.inFlightRecords(investId);
        assertEq(uint8(statusAfter), uint8(statusBefore));
        assertEq(vault.totalInvestInFlight(), investInFlightBefore);
        _logPass();
    }

    function test_SettleAdapter_RedeemZeroAmount_AbnormalPath() public {
        _logCase(
            "test_SettleAdapter_RedeemZeroAmount_AbnormalPath", unicode"redeem settledAmount=0 时走 abnormal confirm 路径"
        );

        (uint256 redeemId,, ,) = _createRedeemInFlightViaProcessBatch(50e18);
        uint256 vaultAssetBefore = asset.balanceOf(address(vault));
        uint256 vaultPosBefore = posToken1.balanceOf(address(vault));

        uint256[] memory redeemIds = new uint256[](1);
        redeemIds[0] = redeemId;
        uint256[] memory redeemAmounts = new uint256[](1);
        redeemAmounts[0] = 0;

        _executeSettleAdapter(
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(new uint256[](0), new uint256[](0), new uint256[](0)),
            IStrategyControllerExecutor.RedeemSettlementInput(redeemIds, redeemAmounts)
        );

        (,,,,, uint256 settledAmount,,, IMantleYieldVault.InFlightStatus status) = vault.inFlightRecords(redeemId);
        assertEq(settledAmount, 0);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(asset.balanceOf(address(vault)), vaultAssetBefore);
        assertEq(posToken1.balanceOf(address(vault)), vaultPosBefore);
        _logPass();
    }

    function test_SettleAdapter_InvestZeroAmount_AbnormalPath() public {
        _logCase(
            "test_SettleAdapter_InvestZeroAmount_AbnormalPath", unicode"invest settledAmount=0 时走 abnormal confirm 路径"
        );

        uint256 investId = _createInvestInFlightViaRebalance(100e18);
        uint256 vaultAssetBefore = asset.balanceOf(address(vault));
        uint256 vaultPosBefore = posToken1.balanceOf(address(vault));

        uint256[] memory investIds = new uint256[](1);
        investIds[0] = investId;
        uint256[] memory investAmounts = new uint256[](1);
        investAmounts[0] = 0;

        _executeSettleAdapter(
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(investIds, investAmounts, new uint256[](1)),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );

        (,,,,, uint256 settledAmount,,, IMantleYieldVault.InFlightStatus status) = vault.inFlightRecords(investId);
        assertEq(settledAmount, 0);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(asset.balanceOf(address(vault)), vaultAssetBefore);
        assertEq(posToken1.balanceOf(address(vault)), vaultPosBefore);
        _logPass();
    }

    function test_SettleAdapter_InvestPartialRefund_Success() public {
        _logCase("test_SettleAdapter_InvestPartialRefund_Success", unicode"invest 结算：部分退款（pos>0, refund>0）");

        uint256 investId = _createInvestInFlightViaRebalance(100e18);
        (uint256 tokenAmount, uint256 usdcAmount) = _readInvestInFlightAmounts(investId);
        uint256 settledPos = (tokenAmount * 70) / 100;
        // Use percentage of original USDC for refund (not usdcAmount - settledPos which mixes units)
        uint256 refundAsset = usdcAmount - (usdcAmount * 70) / 100;
        _deliverInvestSettlement(settledPos, refundAsset);

        uint256[] memory investIds = new uint256[](1);
        investIds[0] = investId;
        uint256[] memory investAmounts = new uint256[](1);
        investAmounts[0] = settledPos;
        uint256[] memory refundAmounts = new uint256[](1);
        refundAmounts[0] = refundAsset;
        uint256 vaultPosBefore = posToken1.balanceOf(address(vault));
        uint256 vaultAssetBefore = asset.balanceOf(address(vault));

        _executeSettleAdapter(
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(investIds, investAmounts, refundAmounts),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );

        (,,,,, uint256 settledAmount,,, IMantleYieldVault.InFlightStatus status) = vault.inFlightRecords(investId);
        assertEq(settledAmount, settledPos);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(posToken1.balanceOf(address(vault)), vaultPosBefore + settledPos);
        assertEq(asset.balanceOf(address(vault)), vaultAssetBefore + refundAsset);
        assertEq(posToken1.balanceOf(address(asyncAdapter)), 0);
        assertEq(asset.balanceOf(address(asyncAdapter)), 0);
        _logPass();
    }

    function test_SettleAdapter_InvestFullRefund_Success() public {
        _logCase("test_SettleAdapter_InvestFullRefund_Success", unicode"invest 结算：全额退款（pos=0, refund>0）");

        uint256 investId = _createInvestInFlightViaRebalance(100e18);
        (, uint256 refundAsset) = _readInvestInFlightAmounts(investId);
        _deliverInvestSettlement(0, refundAsset);

        uint256[] memory investIds = new uint256[](1);
        investIds[0] = investId;
        uint256[] memory investAmounts = new uint256[](1);
        investAmounts[0] = 0;
        uint256[] memory refundAmounts = new uint256[](1);
        refundAmounts[0] = refundAsset;
        uint256 vaultAssetBefore = asset.balanceOf(address(vault));
        uint256 vaultPosBefore = posToken1.balanceOf(address(vault));

        _executeSettleAdapter(
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(investIds, investAmounts, refundAmounts),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );

        (,,,,, uint256 settledAmount,,, IMantleYieldVault.InFlightStatus status) = vault.inFlightRecords(investId);
        assertEq(settledAmount, 0);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(asset.balanceOf(address(vault)), vaultAssetBefore + refundAsset);
        assertEq(posToken1.balanceOf(address(vault)), vaultPosBefore);
        _logPass();
    }

    function test_SettleAdapter_RevertInvestRefundSweepMismatch() public {
        _logCase("test_SettleAdapter_RevertInvestRefundSweepMismatch", unicode"invest 结算：refund sweep 数量不足时整笔回滚");

        uint256 investId = _createInvestInFlightViaRebalance(100e18);
        (uint256 tokenAmount, uint256 usdcAmount) = _readInvestInFlightAmounts(investId);
        uint256 settledPos = (tokenAmount * 70) / 100;
        // Use percentage of original USDC for refund (not usdcAmount - settledPos which mixes units)
        uint256 requestedRefund = usdcAmount - (usdcAmount * 70) / 100;
        uint256 actualRefund = (requestedRefund * 2) / 3;
        _deliverInvestSettlement(settledPos, actualRefund);

        uint256[] memory investIds = new uint256[](1);
        investIds[0] = investId;
        uint256[] memory investAmounts = new uint256[](1);
        investAmounts[0] = settledPos;
        uint256[] memory refundAmounts = new uint256[](1);
        refundAmounts[0] = requestedRefund;

        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyController.Controller__InvestRefundSweepAmountMismatch.selector,
                address(asyncAdapter),
                requestedRefund,
                actualRefund
            )
        );
        _executeSettleAdapter(
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(investIds, investAmounts, refundAmounts),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );

        (,,,,, uint256 settledAmount,,, IMantleYieldVault.InFlightStatus status) = vault.inFlightRecords(investId);
        assertEq(settledAmount, 0);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.PENDING));
        _logPass();
    }

    function test_SettleAdapter_RevertUnregisteredStrategy() public {
        _logCase("test_SettleAdapter_RevertUnregisteredStrategy", unicode"未注册策略的 adapter 无法结算");

        SubRedManagementAdapter unregistered = new SubRedManagementAdapter(
            address(vault),
            address(venue),
            address(posToken3),
            admin,
            address(controller),
            address(accountantExecutor),
            address(priceOracle)
        );

        vm.expectRevert(
            abi.encodeWithSelector(StrategyController.Controller__InvalidStrategy.selector, address(unregistered))
        );
        _executeSettleAdapter(
            address(unregistered),
            IStrategyControllerExecutor.InvestSettlementInput(new uint256[](0), new uint256[](0), new uint256[](0)),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );
        _logPass();
    }

    function test_SettleAdapter_RevertWrongAdapterInFlight() public {
        _logCase("test_SettleAdapter_RevertWrongAdapterInFlight", unicode"invest in-flight 不属于当前 adapter 时被拒绝");

        _registerSecondAdapter();
        uint256 investId = _createInvestInFlightViaRebalanceFor(address(asyncAdapter2), 100e18);
        uint256 sweepableInvestId = _createInvestInFlightViaRebalanceFor(address(asyncAdapter), 100e18);
        (uint256 investTokenAmount,) = _readInvestInFlightAmounts(sweepableInvestId);
        _deliverInvestSettlementFor(address(asyncAdapter), investTokenAmount, 0);

        uint256[] memory investIds = new uint256[](1);
        investIds[0] = investId;
        uint256[] memory investAmounts = new uint256[](1);
        investAmounts[0] = investTokenAmount;

        vm.expectRevert(
            abi.encodeWithSelector(StrategyController.Controller__InvalidInvestInFlight.selector, investId)
        );
        _executeSettleAdapter(
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(investIds, investAmounts, new uint256[](1)),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );
        _logPass();
    }

    function test_SettleAdapter_RevertWrongAdapterRedeemInFlight() public {
        _logCase("test_SettleAdapter_RevertWrongAdapterRedeemInFlight", unicode"redeem in-flight 不属于当前 adapter 时被拒绝");

        _registerSecondAdapter();
        (uint256 redeemId,, , uint256 redeemAssetAmount) = _createRedeemInFlightViaProcessBatchFor(address(asyncAdapter2), 50e18);
        _prepareRealRedeemSettlementBalance(address(asyncAdapter), redeemAssetAmount);

        uint256[] memory redeemIds = new uint256[](1);
        redeemIds[0] = redeemId;
        uint256[] memory redeemAmounts = new uint256[](1);
        redeemAmounts[0] = redeemAssetAmount;

        vm.expectRevert(
            abi.encodeWithSelector(StrategyController.Controller__InvalidRedeemInFlight.selector, redeemId)
        );
        _executeSettleAdapter(
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(new uint256[](0), new uint256[](0), new uint256[](0)),
            IStrategyControllerExecutor.RedeemSettlementInput(redeemIds, redeemAmounts)
        );
        _logPass();
    }

    function test_SettleAdapter_RevertAlreadyConfirmedInFlight() public {
        _logCase("test_SettleAdapter_RevertAlreadyConfirmedInFlight", unicode"已确认的 in-flight 重复结算被拒绝");

        uint256 investId = _createInvestInFlightViaRebalance(100e18);
        (uint256 investTokenAmount,) = _readInvestInFlightAmounts(investId);

        uint256[] memory investIds = new uint256[](1);
        investIds[0] = investId;
        uint256[] memory investAmounts = new uint256[](1);
        investAmounts[0] = investTokenAmount;

        _deliverInvestSettlement(investTokenAmount, 0);
        _executeSettleAdapter(
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(investIds, investAmounts, new uint256[](1)),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );

        // Create a second real invest settlement so the duplicate-settle attempt can pass sweep
        // and reach vault.confirmInFlight on the already CONFIRMED first in-flight.
        uint256 sweepableInvestId = _createInvestInFlightViaRebalance(100e18);
        (uint256 sweepableInvestTokenAmount,) = _readInvestInFlightAmounts(sweepableInvestId);
        _deliverInvestSettlement(sweepableInvestTokenAmount, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                IMantleYieldVault.Vault__InvalidInFlightState.selector,
                investId,
                IMantleYieldVault.InFlightStatus.CONFIRMED
            )
        );
        _executeSettleAdapter(
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(investIds, investAmounts, new uint256[](1)),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );

        (,,,,, uint256 settledAmount,,, IMantleYieldVault.InFlightStatus statusAfter) = vault.inFlightRecords(investId);
        assertEq(uint8(statusAfter), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(settledAmount, investTokenAmount);
        _logPass();
    }

    function test_SettleAdapters_MultiAdapter_Success() public {
        _logCase("test_SettleAdapters_MultiAdapter_Success", unicode"settleAdapters 多 adapter 批量结算 happy path");

        _registerSecondAdapter();
        uint256 investId1 = _createInvestInFlightViaRebalanceFor(address(asyncAdapter), 100e18);
        (uint256 investTokenAmount1,) = _readInvestInFlightAmounts(investId1);
        (uint256 redeemId2,, , uint256 redeemAssetAmount2) = _createRedeemInFlightViaProcessBatchFor(address(asyncAdapter2), 60e18);

        _deliverInvestSettlementFor(address(asyncAdapter), investTokenAmount1, 0);
        _deliverRedeemSettlementFor(address(asyncAdapter2), redeemAssetAmount2);

        address[] memory adapters = new address[](2);
        adapters[0] = address(asyncAdapter);
        adapters[1] = address(asyncAdapter2);
        IStrategyControllerExecutor.InvestSettlementInput[] memory investBatch =
            new IStrategyControllerExecutor.InvestSettlementInput[](2);
        IStrategyControllerExecutor.RedeemSettlementInput[] memory redeemBatch =
            new IStrategyControllerExecutor.RedeemSettlementInput[](2);

        uint256[] memory investIds1 = new uint256[](1);
        investIds1[0] = investId1;
        uint256[] memory investAmounts1 = new uint256[](1);
        investAmounts1[0] = investTokenAmount1;
        investBatch[0] = IStrategyControllerExecutor.InvestSettlementInput(investIds1, investAmounts1, new uint256[](1));
        investBatch[1] = IStrategyControllerExecutor.InvestSettlementInput(new uint256[](0), new uint256[](0), new uint256[](0));

        redeemBatch[0] = IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0));
        uint256[] memory redeemIds2 = new uint256[](1);
        redeemIds2[0] = redeemId2;
        uint256[] memory redeemAmounts2 = new uint256[](1);
        redeemAmounts2[0] = redeemAssetAmount2;
        redeemBatch[1] = IStrategyControllerExecutor.RedeemSettlementInput(redeemIds2, redeemAmounts2);

        uint256 vaultPosBefore = posToken1.balanceOf(address(vault));
        uint256 vaultAssetBefore = asset.balanceOf(address(vault));

        _executeSettleAdapters(adapters, investBatch, redeemBatch);

        (,,,,,,,, IMantleYieldVault.InFlightStatus status1) = vault.inFlightRecords(investId1);
        (,,,,,,,, IMantleYieldVault.InFlightStatus status2) = vault.inFlightRecords(redeemId2);
        assertEq(uint8(status1), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(uint8(status2), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(posToken1.balanceOf(address(vault)), vaultPosBefore + investTokenAmount1);
        assertEq(asset.balanceOf(address(vault)), vaultAssetBefore + redeemAssetAmount2);
        _logPass();
    }

    function test_SettleAdapters_RevertBatchLengthMismatch() public {
        _logCase("test_SettleAdapters_RevertBatchLengthMismatch", unicode"settleAdapters 外层批量数组长度不一致时被拒绝");

        address[] memory adapters = new address[](2);
        adapters[0] = address(asyncAdapter);
        adapters[1] = address(asyncAdapter);
        IStrategyControllerExecutor.InvestSettlementInput[] memory investBatch =
            new IStrategyControllerExecutor.InvestSettlementInput[](1);
        investBatch[0] = IStrategyControllerExecutor.InvestSettlementInput(new uint256[](0), new uint256[](0), new uint256[](0));
        IStrategyControllerExecutor.RedeemSettlementInput[] memory redeemBatch =
            new IStrategyControllerExecutor.RedeemSettlementInput[](2);
        redeemBatch[0] = IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0));
        redeemBatch[1] = IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0));

        vm.expectRevert(StrategyController.Controller__SettleAmountsLengthMismatch.selector);
        _executeSettleAdapters(adapters, investBatch, redeemBatch);
        _logPass();
    }

    function test_SettleAdapters_RevertAnyAdapterFails() public {
        _logCase("test_SettleAdapters_RevertAnyAdapterFails", unicode"settleAdapters 中任一 adapter 结算失败会导致整笔批量结算回滚");

        _registerSecondAdapter();
        uint256 investId1 = _createInvestInFlightViaRebalanceFor(address(asyncAdapter), 100e18);
        (uint256 investTokenAmount1,) = _readInvestInFlightAmounts(investId1);
        (uint256 redeemId2,, , uint256 redeemAssetAmount2) = _createRedeemInFlightViaProcessBatchFor(address(asyncAdapter2), 60e18);
        uint256 partialAsset2 = (redeemAssetAmount2 * 50) / 100;

        _deliverInvestSettlementFor(address(asyncAdapter), investTokenAmount1, 0);
        _deliverRedeemSettlementFor(address(asyncAdapter2), partialAsset2);

        address[] memory adapters = new address[](2);
        adapters[0] = address(asyncAdapter);
        adapters[1] = address(asyncAdapter2);
        IStrategyControllerExecutor.InvestSettlementInput[] memory investBatch =
            new IStrategyControllerExecutor.InvestSettlementInput[](2);
        IStrategyControllerExecutor.RedeemSettlementInput[] memory redeemBatch =
            new IStrategyControllerExecutor.RedeemSettlementInput[](2);

        uint256[] memory investIds1 = new uint256[](1);
        investIds1[0] = investId1;
        uint256[] memory investAmounts1 = new uint256[](1);
        investAmounts1[0] = investTokenAmount1;
        investBatch[0] = IStrategyControllerExecutor.InvestSettlementInput(investIds1, investAmounts1, new uint256[](1));
        investBatch[1] = IStrategyControllerExecutor.InvestSettlementInput(new uint256[](0), new uint256[](0), new uint256[](0));
        redeemBatch[0] = IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0));
        uint256[] memory redeemIds2 = new uint256[](1);
        redeemIds2[0] = redeemId2;
        uint256[] memory redeemAmounts2 = new uint256[](1);
        redeemAmounts2[0] = redeemAssetAmount2;
        redeemBatch[1] = IStrategyControllerExecutor.RedeemSettlementInput(redeemIds2, redeemAmounts2);

        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyController.Controller__RedeemSweepAmountMismatch.selector,
                address(asyncAdapter2),
                redeemAssetAmount2,
                partialAsset2
            )
        );
        _executeSettleAdapters(adapters, investBatch, redeemBatch);

        (,,,,,,,, IMantleYieldVault.InFlightStatus status1) = vault.inFlightRecords(investId1);
        (,,,,,,,, IMantleYieldVault.InFlightStatus status2) = vault.inFlightRecords(redeemId2);
        assertEq(uint8(status1), uint8(IMantleYieldVault.InFlightStatus.PENDING));
        assertEq(uint8(status2), uint8(IMantleYieldVault.InFlightStatus.PENDING));
        _logPass();
    }

    function test_SettleAdapter_SweepMatchGatesConfirmInFlight() public {
        _logCase(
            "test_SettleAdapter_SweepMatchGatesConfirmInFlight",
            unicode"settleAdapter 只有在 sweep 金额完全匹配后才会进入 confirmInFlight"
        );

        uint256 investId = _createInvestInFlightViaRebalance(100e18);
        (uint256 investTokenAmount,) = _readInvestInFlightAmounts(investId);
        _deliverInvestSettlement(investTokenAmount, 0);

        uint256[] memory investIds = new uint256[](1);
        investIds[0] = investId;
        uint256[] memory investAmounts = new uint256[](1);
        investAmounts[0] = investTokenAmount;

        _executeSettleAdapter(
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(investIds, investAmounts, new uint256[](1)),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );

        (,,,,, uint256 settledAmount,,, IMantleYieldVault.InFlightStatus statusOk) = vault.inFlightRecords(investId);
        assertEq(uint8(statusOk), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(settledAmount, investTokenAmount);

        uint256 investId2 = _createInvestInFlightViaRebalance(200e18);
        (uint256 investTokenAmount2,) = _readInvestInFlightAmounts(investId2);
        uint256 partialSettled = (investTokenAmount2 * 75) / 100;
        _deliverInvestSettlement(partialSettled, 0);

        uint256[] memory investIds2 = new uint256[](1);
        investIds2[0] = investId2;
        uint256[] memory investAmounts2 = new uint256[](1);
        investAmounts2[0] = investTokenAmount2;

        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyController.Controller__InvestSweepAmountMismatch.selector,
                address(asyncAdapter),
                investTokenAmount2,
                partialSettled
            )
        );
        _executeSettleAdapter(
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(investIds2, investAmounts2, new uint256[](1)),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );

        (,,,,,,,, IMantleYieldVault.InFlightStatus statusBad) = vault.inFlightRecords(investId2);
        assertEq(uint8(statusBad), uint8(IMantleYieldVault.InFlightStatus.PENDING));
        _logPass();
    }

    // =======================================================================
    // Invest Refund Validation (_validateInvestSettlement) — N-83 ~ N-87
    // =======================================================================

    function test_SettleAdapter_InvestRefund_ExceedsOriginal() public {
        _logCase(
            "test_SettleAdapter_InvestRefund_ExceedsOriginal",
            unicode"`refundAssetAmount > originalAssetAmount` 时 revert `Controller__InvalidInvestRefundAmount`"
        );

        _step("[Step 1] Create invest in-flight via deposit -> rebalance");
        uint256 investId = _createInvestInFlightViaRebalance(1000e18);
        (, uint256 originalAssetAmount) = _readInvestInFlightAmounts(investId);
        _step(string.concat("  investId = ", vm.toString(investId)));
        _step(string.concat("  originalAssetAmount = ", vm.toString(originalAssetAmount)));

        _step("[Step 2] Attempt settle with refundAssetAmount = original + 1");
        uint256 excessRefund = originalAssetAmount + 1;
        uint256[] memory investIds = new uint256[](1);
        investIds[0] = investId;
        uint256[] memory posAmounts = new uint256[](1);
        posAmounts[0] = 0;
        uint256[] memory refundAmounts = new uint256[](1);
        refundAmounts[0] = excessRefund;

        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyController.Controller__InvalidInvestRefundAmount.selector,
                investId,
                excessRefund,
                originalAssetAmount
            )
        );
        _executeSettleAdapter(
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(investIds, posAmounts, refundAmounts),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );

        _step("[Step 3] Verify in-flight status unchanged");
        (,,,,,,,, IMantleYieldVault.InFlightStatus status) = vault.inFlightRecords(investId);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.PENDING));
        _step("  PASS: reverted with Controller__InvalidInvestRefundAmount, status still PENDING");
        _logPass();
    }

    function test_SettleAdapter_InvestRefund_EqualsOriginal() public {
        _logCase(
            "test_SettleAdapter_InvestRefund_EqualsOriginal",
            unicode"`refundAssetAmount == originalAssetAmount` 时成功（全额退款）"
        );

        _step("[Step 1] Create invest in-flight");
        uint256 investId = _createInvestInFlightViaRebalance(1000e18);
        (, uint256 originalAssetAmount) = _readInvestInFlightAmounts(investId);
        _step(string.concat("  investId = ", vm.toString(investId)));
        _step(string.concat("  originalAssetAmount = ", vm.toString(originalAssetAmount)));

        _step("[Step 2] Deliver full refund to adapter (no pos tokens)");
        _deliverInvestSettlement(0, originalAssetAmount);

        _step("[Step 3] Settle with settledPos=0, refund=originalAssetAmount");
        uint256[] memory investIds = new uint256[](1);
        investIds[0] = investId;
        uint256[] memory posAmounts = new uint256[](1);
        posAmounts[0] = 0;
        uint256[] memory refundAmounts = new uint256[](1);
        refundAmounts[0] = originalAssetAmount;

        uint256 vaultAssetBefore = asset.balanceOf(address(vault));
        uint256 vaultPosBefore = posToken1.balanceOf(address(vault));

        _executeSettleAdapter(
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(investIds, posAmounts, refundAmounts),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );

        _step("[Step 4] Verify in-flight CONFIRMED, settledAmount = 0");
        (,,,,, uint256 settledAmount,,, IMantleYieldVault.InFlightStatus status) = vault.inFlightRecords(investId);
        assertEq(settledAmount, 0, "settledAmount should be 0 for full refund");
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(asset.balanceOf(address(vault)), vaultAssetBefore + originalAssetAmount, "refund swept to vault");
        assertEq(posToken1.balanceOf(address(vault)), vaultPosBefore, "no pos tokens for full refund");
        _step("  PASS: full refund accepted, CONFIRMED with settledAmount=0");
        _logPass();
    }

    function test_SettleAdapter_InvestRefund_ZeroRefund() public {
        _logCase(
            "test_SettleAdapter_InvestRefund_ZeroRefund",
            unicode"`refundAssetAmount = 0` 时成功（无退款，全额成交）"
        );

        _step("[Step 1] Create invest in-flight");
        uint256 investId = _createInvestInFlightViaRebalance(1000e18);
        (uint256 investTokenAmount,) = _readInvestInFlightAmounts(investId);
        _step(string.concat("  investId = ", vm.toString(investId)));
        _step(string.concat("  investTokenAmount = ", vm.toString(investTokenAmount)));

        _step("[Step 2] Deliver full pos tokens to adapter");
        _deliverInvestSettlement(investTokenAmount, 0);

        _step("[Step 3] Settle with settledPos=investTokenAmount, refund=0");
        uint256[] memory investIds = new uint256[](1);
        investIds[0] = investId;
        uint256[] memory posAmounts = new uint256[](1);
        posAmounts[0] = investTokenAmount;
        uint256[] memory refundAmounts = new uint256[](1);
        refundAmounts[0] = 0;

        uint256 vaultPosBefore = posToken1.balanceOf(address(vault));
        uint256 vaultAssetBefore = asset.balanceOf(address(vault));

        _executeSettleAdapter(
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(investIds, posAmounts, refundAmounts),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );

        _step("[Step 4] Verify in-flight CONFIRMED, settledAmount = investTokenAmount");
        (,,,,, uint256 settledAmount,,, IMantleYieldVault.InFlightStatus status) = vault.inFlightRecords(investId);
        assertEq(settledAmount, investTokenAmount, "settledAmount should equal pos amount");
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(posToken1.balanceOf(address(vault)), vaultPosBefore + investTokenAmount, "pos tokens swept to vault");
        assertEq(asset.balanceOf(address(vault)), vaultAssetBefore, "no asset refund for zero refund");
        _step("  PASS: zero refund accepted, full settle with pos tokens");
        _logPass();
    }

    function test_SettleAdapter_InvestRefund_WrongAdapter() public {
        _logCase(
            "test_SettleAdapter_InvestRefund_WrongAdapter",
            unicode"invest in-flight 不属于目标 adapter 时 `_validateInvestSettlement` 提前拦截"
        );

        _step("[Step 1] Register second adapter and create invest for adapter2");
        _registerSecondAdapter();
        uint256 investId = _createInvestInFlightViaRebalanceFor(address(asyncAdapter2), 1000e18);
        (uint256 investTokenAmount,) = _readInvestInFlightAmounts(investId);
        _step(string.concat("  investId (adapter2) = ", vm.toString(investId)));

        _step("[Step 2] Try settling investId against adapter1 (wrong adapter)");
        uint256[] memory investIds = new uint256[](1);
        investIds[0] = investId;
        uint256[] memory posAmounts = new uint256[](1);
        posAmounts[0] = investTokenAmount;
        uint256[] memory refundAmounts = new uint256[](1);
        refundAmounts[0] = 0;

        vm.expectRevert(
            abi.encodeWithSelector(StrategyController.Controller__InvalidInvestInFlight.selector, investId)
        );
        _executeSettleAdapter(
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(investIds, posAmounts, refundAmounts),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );

        _step("[Step 3] Verify in-flight still PENDING");
        (,,,,,,,, IMantleYieldVault.InFlightStatus status) = vault.inFlightRecords(investId);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.PENDING));
        _step("  PASS: _validateInvestSettlement caught wrong adapter before sweep");
        _logPass();
    }

    function test_SettleAdapter_InvestRefund_BatchPartialInvalid() public {
        _logCase(
            "test_SettleAdapter_InvestRefund_BatchPartialInvalid",
            unicode"批量 invest 中任一 `refundAssetAmount > originalAssetAmount` 则整批回滚"
        );

        _step("[Step 1] Create two invest in-flights");
        uint256 investId1 = _createInvestInFlightViaRebalance(1000e18);
        (, uint256 origAsset1) = _readInvestInFlightAmounts(investId1);
        uint256 investId2 = _createInvestInFlightViaRebalance(500e18);
        (, uint256 origAsset2) = _readInvestInFlightAmounts(investId2);
        _step(string.concat("  investId1 = ", vm.toString(investId1), ", origAsset1 = ", vm.toString(origAsset1)));
        _step(string.concat("  investId2 = ", vm.toString(investId2), ", origAsset2 = ", vm.toString(origAsset2)));

        _step("[Step 2] Attempt batch settle: id1 valid refund, id2 refund > original");
        uint256 validRefund1 = origAsset1 / 2;
        uint256 invalidRefund2 = origAsset2 + 1;

        uint256[] memory investIds = new uint256[](2);
        investIds[0] = investId1;
        investIds[1] = investId2;
        uint256[] memory posAmounts = new uint256[](2);
        posAmounts[0] = 0;
        posAmounts[1] = 0;
        uint256[] memory refundAmounts = new uint256[](2);
        refundAmounts[0] = validRefund1;
        refundAmounts[1] = invalidRefund2;

        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyController.Controller__InvalidInvestRefundAmount.selector,
                investId2,
                invalidRefund2,
                origAsset2
            )
        );
        _executeSettleAdapter(
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(investIds, posAmounts, refundAmounts),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );

        _step("[Step 3] Verify both in-flights still PENDING (atomic rollback)");
        (,,,,,,,, IMantleYieldVault.InFlightStatus status1) = vault.inFlightRecords(investId1);
        (,,,,,,,, IMantleYieldVault.InFlightStatus status2) = vault.inFlightRecords(investId2);
        assertEq(uint8(status1), uint8(IMantleYieldVault.InFlightStatus.PENDING));
        assertEq(uint8(status2), uint8(IMantleYieldVault.InFlightStatus.PENDING));
        _step("  PASS: entire batch rolled back, both in-flights remain PENDING");
        _logPass();
    }
}
