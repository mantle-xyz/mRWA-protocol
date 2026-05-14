// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Accountant} from "../../src/accountant/Accountant.sol";
import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {IMantleVaultGateway} from "../../src/interfaces/vault/IMantleVaultGateway.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {IStrategyAdapter} from "../../src/interfaces/adapters/IStrategyAdapter.sol";
import {IStrategyControllerExecutor} from "../../src/interfaces/strategy/IStrategyControllerExecutor.sol";
import {MantleVaultGateway} from "../../src/vault/MantleVaultGateway.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {OperatorExecutor} from "../../src/protocol/OperatorExecutor.sol";
import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Test, console2, Vm} from "forge-std/Test.sol";

// ---------------------------------------------------------------------------
// Mock contracts
// ---------------------------------------------------------------------------

contract MockUSDC_MA is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function burn(address from, uint256 amount) external { _burn(from, amount); }
}

contract MockPosToken_MA is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function burn(address from, uint256 amount) external { _burn(from, amount); }
}

contract MockSettlementVenue_MA {
    MockUSDC_MA public immutable ASSET;
    MockPosToken_MA public immutable POS_TOKEN;

    mapping(address => uint256) public pendingInvestAsset;
    mapping(address => uint256) public pendingRedeemPos;

    constructor(address asset_, address posToken_) {
        ASSET = MockUSDC_MA(asset_);
        POS_TOKEN = MockPosToken_MA(posToken_);
    }

    function acceptInvest(address adapter, uint256 assetAmount) external {
        pendingInvestAsset[adapter] += assetAmount;
    }

    function acceptRedeem(address adapter, uint256 posAmount) external {
        pendingRedeemPos[adapter] += posAmount;
    }

    function settleInvest(
        address adapter,
        uint256 investAssetAmount,
        uint256 maxPosAmount,
        uint256 settledPosAmount,
        uint256 refundAssetAmount
    ) external {
        uint256 pendingAsset = pendingInvestAsset[adapter];
        require(investAssetAmount <= pendingAsset, "INVEST_ASSET_EXCEEDS_PENDING");
        require(settledPosAmount <= maxPosAmount, "INVEST_POS_EXCEEDS_EXPECTED");
        require(refundAssetAmount <= investAssetAmount, "INVEST_REFUND_EXCEEDS_ASSET");

        pendingInvestAsset[adapter] = pendingAsset - investAssetAmount;

        uint256 consumedAssetAmount = investAssetAmount - refundAssetAmount;
        if (consumedAssetAmount > 0) {
            ASSET.burn(address(this), consumedAssetAmount);
        }
        if (settledPosAmount > 0) {
            POS_TOKEN.mint(adapter, settledPosAmount);
        }
        if (refundAssetAmount > 0) {
            ASSET.transfer(adapter, refundAssetAmount);
        }
    }

    function settleRedeem(address adapter, uint256 redeemPosAmount, uint256 assetAmount) external {
        uint256 pendingPos = pendingRedeemPos[adapter];
        require(redeemPosAmount <= pendingPos, "REDEEM_POS_EXCEEDS_PENDING");

        pendingRedeemPos[adapter] = pendingPos - redeemPosAmount;

        if (redeemPosAmount > 0) {
            POS_TOKEN.burn(address(this), redeemPosAmount);
        }
        if (assetAmount > 0) {
            ASSET.mint(adapter, assetAmount);
        }
    }
}

contract MockSanctionsOracle_MA is ISanctionsOracle {
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

/// @dev Sync adapter that transfers real tokens.
///      Models a 4626-like adapter: deposit burns USDC and mints posToken,
///      withdrawSync burns posToken and mints USDC. After invest settlement,
///      posToken lives on vault, so totalValue() reads posToken.balanceOf(VAULT).
contract MockSyncAdapter_MA is IStrategyAdapter {
    address public immutable ASSET;
    address public immutable POS_TOKEN;
    address public immutable VAULT;

    constructor(address asset_, address posToken_, address vault_) {
        ASSET = asset_;
        POS_TOKEN = posToken_;
        VAULT = vault_;
    }

    function name() external pure returns (string memory) { return "MockSyncAdapter"; }
    function asset() external view returns (address) { return ASSET; }
    function posToken() external view returns (address) { return POS_TOKEN; }
    function priceOracle() external pure returns (address) { return address(0); }
    function getPosTokenPrice() external pure returns (uint256) { return 1e18; }
    function estimatePosAmount(uint256 assetAmount) external pure returns (uint256) { return assetAmount; }
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
    function vault() external view returns (address) { return VAULT; }

    function totalValue() external view returns (uint256) {
        // After invest settlement, posTokens are swept to vault.
        // Mirrors real adapter: value = posToken held by vault for this strategy.
        return IERC20(POS_TOKEN).balanceOf(VAULT);
    }

    function deposit(uint256 amount, address) external returns (uint256) {
        // Pull USDC from vault
        IERC20(ASSET).transferFrom(VAULT, address(this), amount);
        // Simulate 4626 deposit: consume USDC, produce posToken on adapter
        MockUSDC_MA(ASSET).burn(address(this), amount);
        MockPosToken_MA(POS_TOKEN).mint(address(this), amount);
        // posToken stays on adapter until settle sweeps it to vault
        return amount;
    }

    function withdrawSync(uint256 posAmount, address) external returns (uint256) {
        // Pull posToken from vault (controller pre-approved via vault.approveToAdapter)
        IERC20(POS_TOKEN).transferFrom(VAULT, address(this), posAmount);
        // Simulate 4626 redeem: consume posToken, produce USDC on adapter
        MockPosToken_MA(POS_TOKEN).burn(address(this), posAmount);
        MockUSDC_MA(ASSET).mint(address(this), posAmount);
        // USDC stays on adapter until settle sweeps it to vault
        return posAmount;
    }

    function requestRedeemAsync(uint256, address) external pure {
        revert("Unsupported");
    }

    function sweepToVault(address token, uint256 amount) external returns (uint256) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 actual = amount > bal ? bal : amount;
        if (actual > 0) IERC20(token).transfer(VAULT, actual);
        return actual;
    }

    function setPaused(bool) external {}
    function retryRedeemAsync(uint256, address) external pure {
        revert("Unsupported");
    }
    function minSubscribeAsset() external pure returns (uint256) { return 0; }
    function minRedeemPos() external pure returns (uint256) { return 0; }
}

/// @dev Async adapter with variable posTokenPrice.
contract MockAsyncAdapter_MA is IStrategyAdapter {
    address public immutable ASSET;
    address public immutable POS_TOKEN;
    address public immutable VAULT;
    MockSettlementVenue_MA public immutable SETTLEMENT_VENUE;
    uint256 public posTokenPrice = 1e18;

    constructor(address asset_, address posToken_, address vault_, address settlementVenue_) {
        ASSET = asset_;
        POS_TOKEN = posToken_;
        VAULT = vault_;
        SETTLEMENT_VENUE = MockSettlementVenue_MA(settlementVenue_);
    }

    function setPosTokenPrice(uint256 p) external { posTokenPrice = p; }

    function name() external pure returns (string memory) { return "MockAsyncAdapter"; }
    function asset() external view returns (address) { return ASSET; }
    function posToken() external view returns (address) { return POS_TOKEN; }
    function priceOracle() external pure returns (address) { return address(0); }
    function getPosTokenPrice() external view returns (uint256) { return posTokenPrice; }
    function vault() external view returns (address) { return VAULT; }

    function estimatePosAmount(uint256 assetAmount) external view returns (uint256) {
        if (posTokenPrice == 0) return assetAmount;
        return assetAmount * 1e18 / posTokenPrice;
    }

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

    function totalValue() external view returns (uint256) {
        return IERC20(POS_TOKEN).balanceOf(VAULT) * posTokenPrice / 1e18;
    }

    function deposit(uint256 amount, address) external returns (uint256) {
        IERC20(ASSET).transferFrom(VAULT, address(this), amount);
        IERC20(ASSET).transfer(address(SETTLEMENT_VENUE), amount);
        SETTLEMENT_VENUE.acceptInvest(address(this), amount);
        uint256 posAmount = posTokenPrice == 0 ? amount : amount * 1e18 / posTokenPrice;
        return posAmount;
    }

    function withdrawSync(uint256, address) external pure returns (uint256) {
        revert("async only");
    }

    function requestRedeemAsync(uint256 posAmount, address) external {
        // Real adapter: controller already converted asset→pos and passes posAmount directly.
        IERC20(POS_TOKEN).transferFrom(VAULT, address(this), posAmount);
        IERC20(POS_TOKEN).transfer(address(SETTLEMENT_VENUE), posAmount);
        SETTLEMENT_VENUE.acceptRedeem(address(this), posAmount);
    }

    function sweepToVault(address token, uint256 amount) external returns (uint256) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 actual = amount > bal ? bal : amount;
        if (actual > 0) IERC20(token).transfer(VAULT, actual);
        return actual;
    }

    function setPaused(bool) external {}
    function retryRedeemAsync(uint256, address) external {}
    function minSubscribeAsset() external pure returns (uint256) { return 0; }
    function minRedeemPos() external pure returns (uint256) { return 0; }
}

// ---------------------------------------------------------------------------
// QA Test: Multi-Adapter Strategy Scenarios
// ---------------------------------------------------------------------------

contract MultiAdapterStrategyQATest is Test {
    MockUSDC_MA internal usdc;
    MockSanctionsOracle_MA internal oracle;
    MantleYieldVault internal vault;
    MantleVaultGateway internal gateway;
    Accountant internal accountant;
    StrategyController internal controller;
    OperatorExecutor internal executor;
    mapping(address => address) internal settlementVenueByAdapter;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal sanctionSafe = makeAddr("sanctionSafe");
    address internal bot = makeAddr("bot");
    address internal depositor = makeAddr("depositor");

    uint256 constant BPS = 10_000;

    // -----------------------------------------------------------------------
    // Logging helpers
    // -----------------------------------------------------------------------

    string constant MODULE = unicode"多 Adapter 投资/赎回场景";
    string private _caseId;
    string private _caseName;
    string private _buf;

    function _logCase(string memory id, string memory name_) internal {
        _caseId = id;
        _caseName = name_;
        _buf = "";
        _step(string.concat("testcase module: ", MODULE));
        _step(string.concat("testcase id: ", id));
        _step(string.concat("testcase name: ", name_));
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
    // setUp: bare vault + controller, no default adapter
    // -----------------------------------------------------------------------

    function setUp() public {
        vm.warp(1000);

        usdc = new MockUSDC_MA();
        oracle = new MockSanctionsOracle_MA();

        MantleYieldVault vaultImpl = new MantleYieldVault();
        Accountant acctImpl = new Accountant();
        MantleVaultGateway gwImpl = new MantleVaultGateway();
        StrategyController ctrlImpl = new StrategyController();
        OperatorExecutor execImpl = new OperatorExecutor();

        vault = MantleYieldVault(address(new ERC1967Proxy(
            address(vaultImpl),
            abi.encodeCall(MantleYieldVault.initialize, IMantleYieldVault.InitParams({
                asset: IERC20(address(usdc)),
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
            address(acctImpl),
            abi.encodeCall(Accountant.initialize, (address(vault), 1e18, 0, admin, admin, admin))
        )));

        executor = OperatorExecutor(address(new ERC1967Proxy(
            address(execImpl),
            abi.encodeCall(OperatorExecutor.initialize, (admin, bot))
        )));

        controller = StrategyController(address(new ERC1967Proxy(
            address(ctrlImpl),
            abi.encodeCall(StrategyController.initialize, (
                address(vault), admin, address(executor), admin, 1000, 0, 0
            ))
        )));

        gateway = MantleVaultGateway(address(new ERC1967Proxy(
            address(gwImpl),
            abi.encodeCall(MantleVaultGateway.initialize, IMantleVaultGateway.InitParams({
                vault: address(vault),
                sanctionsOracle: ISanctionsOracle(address(oracle)),
                sanctionSafe: sanctionSafe,
                admin: admin,
                syncRedeemDisabled: false
            }))
        )));

        vm.startPrank(admin);
        vault.setAccountant(address(accountant));
        vault.setGateway(address(gateway));
        vault.setController(address(controller));
        vm.stopPrank();

        // Fund depositor
        usdc.mint(depositor, 100_000_000e6);
        vm.prank(depositor);
        usdc.approve(address(vault), type(uint256).max);
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    function _deposit(uint256 amount) internal {
        vm.prank(depositor);
        gateway.deposit(amount);
    }

    function _rebalance() internal {
        vm.warp(block.timestamp + 1);
        vm.prank(bot);
        executor.executeRebalance(address(controller));
    }

    function _rebalanceWithParams(uint16 bufferBps, uint16 thresholdBps, uint64 cooldown) internal {
        vm.prank(admin);
        controller.setRiskParams(bufferBps, thresholdBps, cooldown);
        vm.warp(block.timestamp + 1);
        vm.prank(bot);
        executor.executeRebalance(address(controller));
    }

    function _setStrategyOrder(address[] memory order) internal {
        vm.prank(admin);
        controller.setStrategyOrder(order);
    }

    function _registerAndActivate(address adpt, uint16 weight, uint16 priority, bool isAsync) internal {
        vm.startPrank(admin);
        controller.registerStrategy(adpt, weight, priority, isAsync);
        controller.activateStrategy(adpt);
        vm.stopPrank();
    }

    function _deployAsyncAdapter(string memory posName, string memory posSymbol)
        internal
        returns (MockPosToken_MA posToken, MockAsyncAdapter_MA adapter)
    {
        posToken = new MockPosToken_MA(posName, posSymbol);
        MockSettlementVenue_MA venue = new MockSettlementVenue_MA(address(usdc), address(posToken));
        adapter = new MockAsyncAdapter_MA(address(usdc), address(posToken), address(vault), address(venue));
        settlementVenueByAdapter[address(adapter)] = address(venue);
    }

    function _inFlightTokenAmount(uint256 inFlightId) internal view returns (uint256 tokenAmount) {
        (,,, tokenAmount,,,,,) = vault.inFlightRecords(inFlightId);
    }

    function _deliverAsyncInvestSettlement(address adpt, uint256 inFlightId, uint256 posAmount, uint256 refundAsset) internal {
        address venue = settlementVenueByAdapter[adpt];
        if (venue == address(0)) return;

        (,,, uint256 expectedPos, uint256 investAsset,, bool isInvest,,) = vault.inFlightRecords(inFlightId);
        assertTrue(isInvest, "expected invest in-flight");
        MockSettlementVenue_MA(venue).settleInvest(adpt, investAsset, expectedPos, posAmount, refundAsset);
    }

    function _deliverAsyncRedeemSettlement(address adpt, uint256 inFlightId, uint256 assetAmount) internal {
        address venue = settlementVenueByAdapter[adpt];
        if (venue == address(0)) return;

        (,,, uint256 redeemPos,,, bool isInvest,,) = vault.inFlightRecords(inFlightId);
        assertFalse(isInvest, "expected redeem in-flight");
        MockSettlementVenue_MA(venue).settleRedeem(adpt, redeemPos, assetAmount);
    }

    function _settleAsyncInvest(address adpt, uint256 inFlightId, uint256 posAmount) internal {
        _deliverAsyncInvestSettlement(adpt, inFlightId, posAmount, 0);
        uint256[] memory ids = new uint256[](1);
        ids[0] = inFlightId;
        uint256[] memory settledPos = new uint256[](1);
        settledPos[0] = posAmount;
        uint256[] memory refunds = new uint256[](1);
        refunds[0] = 0;
        IStrategyControllerExecutor.InvestSettlementInput memory investInput = IStrategyControllerExecutor
            .InvestSettlementInput({inFlightIds: ids, settledPosAmounts: settledPos, refundAssetAmounts: refunds});
        IStrategyControllerExecutor.RedeemSettlementInput memory redeemInput =
            IStrategyControllerExecutor.RedeemSettlementInput({inFlightIds: new uint256[](0), settledAssetAmounts: new uint256[](0)});
        vm.prank(bot);
        executor.executeSettleAdapter(address(controller), adpt, investInput, redeemInput);
    }

    function _settleAsyncRedeem(address adpt, uint256 inFlightId, uint256 assetAmount) internal {
        _deliverAsyncRedeemSettlement(adpt, inFlightId, assetAmount);
        uint256[] memory ids = new uint256[](1);
        ids[0] = inFlightId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = assetAmount;
        IStrategyControllerExecutor.InvestSettlementInput memory investInput = IStrategyControllerExecutor
            .InvestSettlementInput({inFlightIds: new uint256[](0), settledPosAmounts: new uint256[](0), refundAssetAmounts: new uint256[](0)});
        IStrategyControllerExecutor.RedeemSettlementInput memory redeemInput =
            IStrategyControllerExecutor.RedeemSettlementInput({inFlightIds: ids, settledAssetAmounts: amounts});
        vm.prank(bot);
        executor.executeSettleAdapter(address(controller), adpt, investInput, redeemInput);
    }

    function _lastInFlightId() internal view returns (uint256) {
        return vault.nextInFlightId() - 1;
    }

    // =======================================================================
    // 1. Asymmetric weight 30%/70% invest
    // =======================================================================

    function test_AsymmetricWeight_Invest() public {
        _logCase(
            "test_AsymmetricWeight_Invest",
            unicode"不对称权重 30%/70% -- invest 按 targetWeightBps 比例分配"
        );

        _step("[Step 1] Deploy sync adapterA(30%) and sync adapterB(70%)");
        MockPosToken_MA posA = new MockPosToken_MA("PosA", "PA");
        MockPosToken_MA posB = new MockPosToken_MA("PosB", "PB");
        MockSyncAdapter_MA adapterA = new MockSyncAdapter_MA(address(usdc), address(posA), address(vault));
        MockSyncAdapter_MA adapterB = new MockSyncAdapter_MA(address(usdc), address(posB), address(vault));

        _registerAndActivate(address(adapterA), 3000, 1, false);
        _registerAndActivate(address(adapterB), 7000, 2, false);
        address[] memory order = new address[](2);
        order[0] = address(adapterA);
        order[1] = address(adapterB);
        _setStrategyOrder(order);

        _step("[Step 2] Deposit 10000 USDC and rebalance (buffer=10%, threshold=0)");
        _deposit(10_000e6);
        uint256 ifIdStart = vault.nextInFlightId();
        _rebalance();

        // Settle sync invest in-flights (sync adapters also create PENDING in-flight records)
        _settleAsyncInvest(address(adapterA), ifIdStart, _inFlightTokenAmount(ifIdStart));
        _settleAsyncInvest(address(adapterB), ifIdStart + 1, _inFlightTokenAmount(ifIdStart + 1));

        // _invest uses totalAssets (snapshot) to compute per-adapter targetBalance.
        // totalAssets = vault.bal + strategyValue + investIF + redeemIF
        // At rebalance time: all in vault, nothing deployed yet.
        uint256 totalAssets = 10_000e6;
        // _readRebalanceState: freeCash = physicalBal - lockedValue = 10000 - 0 = 10000
        // targetCash = netAssets * bufferBps / 10000 + cashDeficit = 10000*1000/10000 + 0 = 1000
        // invest amount = freeCash - targetCash = 9000
        uint256 targetCash = totalAssets * 1000 / BPS;
        uint256 investAmount = totalAssets - targetCash; // freeCash(10000) - targetCash(1000) = 9000

        uint256 valueA = adapterA.totalValue();
        uint256 valueB = adapterB.totalValue();
        _step(string.concat("  adapterA totalValue: ", vm.toString(valueA)));
        _step(string.concat("  adapterB totalValue: ", vm.toString(valueB)));

        // Inside _invest(9000), per-adapter allocation follows contract formula:
        //   targetBalance = totalAssets * weightBps / 10000
        //   shortfall = targetBalance - currentBalance (currentBalance=0 for fresh adapters)
        //   alloc = min(shortfall, remaining)
        uint256 targetA = totalAssets * 3000 / BPS; // 3000
        uint256 targetB = totalAssets * 7000 / BPS; // 7000
        uint256 remaining = investAmount;
        uint256 expectedAllocA = targetA < remaining ? targetA : remaining; // min(3000, 9000) = 3000
        remaining -= expectedAllocA;
        uint256 expectedAllocB = targetB < remaining ? targetB : remaining; // min(7000, 6000) = 6000

        assertEq(valueA, expectedAllocA, "adapterA alloc = min(targetA, remaining)");
        assertEq(valueB, expectedAllocB, "adapterB alloc = min(targetB, remaining)");
        assertEq(valueA + valueB, investAmount, "total invested = investAmount");
        assertEq(usdc.balanceOf(address(vault)), targetCash, "vault USDC = buffer");

        _logPass();
    }

    // =======================================================================
    // 2. Asymmetric weight divest waterfall
    // =======================================================================

    function test_AsymmetricWeight_DivestWaterfall() public {
        _logCase(
            "test_AsymmetricWeight_DivestWaterfall",
            unicode"不对称权重 divest -- 瀑布式按 strategyOrder 顺序逐个回收（不看权重）"
        );

        _step("[Step 1] Setup 30%/70%, invest, and settle in-flights");
        MockPosToken_MA posA = new MockPosToken_MA("PosA", "PA");
        MockPosToken_MA posB = new MockPosToken_MA("PosB", "PB");
        MockSyncAdapter_MA adapterA = new MockSyncAdapter_MA(address(usdc), address(posA), address(vault));
        MockSyncAdapter_MA adapterB = new MockSyncAdapter_MA(address(usdc), address(posB), address(vault));

        _registerAndActivate(address(adapterA), 3000, 1, false);
        _registerAndActivate(address(adapterB), 7000, 2, false);
        address[] memory order = new address[](2);
        order[0] = address(adapterA);
        order[1] = address(adapterB);
        _setStrategyOrder(order);

        _deposit(10_000e6);
        uint256 ifIdStart = vault.nextInFlightId();
        _rebalance();

        // Settle invest in-flights so netAssets is not double-counted
        _settleAsyncInvest(address(adapterA), ifIdStart, _inFlightTokenAmount(ifIdStart));
        _settleAsyncInvest(address(adapterB), ifIdStart + 1, _inFlightTokenAmount(ifIdStart + 1));

        uint256 valueABefore = adapterA.totalValue();
        uint256 valueBBefore = adapterB.totalValue();
        _step(string.concat("  adapterA after invest: ", vm.toString(valueABefore)));
        _step(string.concat("  adapterB after invest: ", vm.toString(valueBBefore)));

        _step("[Step 2] Set buffer=80% -> divest");
        // _readRebalanceState:
        //   netAssets = vault.bal(1000) + strategyValue(3000+6000) + investIF(0) + redeemIF(0) = 10000
        //   targetCash = 10000 * 8000 / 10000 + cashDeficit(0) = 8000
        //   freeCash = vault.getFreeCash() = 1000 (no lockedShares)
        //   freeCash(1000) + threshold(0) < targetCash(8000) -> DIVEST
        //   divestAmount = targetCash - freeCash = 7000
        //
        // _divest(7000) waterfall (no weight, just strategyOrder):
        //   adapterA: _readDivestCoverage(remaining=7000)
        //     settledValue=totalValue()=3000, pendingRedeem=0, totalCover=3000
        //     toWithdraw=min(7000,3000)=3000, coveredByPending=0, requestAsset=3000
        //     withdrawSync(3000) -> received=3000, remaining=_remainingAfterClear(7000, 3000)=4000
        //   adapterB: _readDivestCoverage(remaining=4000)
        //     settledValue=6000, totalCover=6000
        //     toWithdraw=min(4000,6000)=4000, requestAsset=4000
        //     withdrawSync(4000) -> received=4000, remaining=0
        uint256 bufferAfterRebalance = usdc.balanceOf(address(vault));
        uint256 netAssetsDivest = bufferAfterRebalance + valueABefore + valueBBefore;
        uint16 newBufferBps = 8000;
        uint256 targetCashDivest = netAssetsDivest * newBufferBps / BPS;
        uint256 divestAmount = targetCashDivest > bufferAfterRebalance ? targetCashDivest - bufferAfterRebalance : 0;
        uint256 redeemIfStart = vault.nextInFlightId();
        _rebalanceWithParams(8000, 0, 0);

        uint256 valueAAfter = adapterA.totalValue();
        uint256 valueBAfter = adapterB.totalValue();
        _step(string.concat("  adapterA after divest: ", vm.toString(valueAAfter)));
        _step(string.concat("  adapterB after divest: ", vm.toString(valueBAfter)));

        // adapterA: withdrew all 3000 -> 0
        // adapterB: withdrew 4000 of 6000 -> 2000
        uint256 withdrawnFromA = valueABefore; // min(3000, 7000) = 3000
        uint256 withdrawnFromB = divestAmount - withdrawnFromA; // 7000 - 3000 = 4000
        assertEq(valueAAfter, 0, "adapterA fully drained");
        assertEq(valueBAfter, valueBBefore - withdrawnFromB, "adapterB partially drained");

        // Real protocol: withdrawSync sends USDC to adapter (not vault).
        // USDC stays on adapter until settle sweeps it to vault.
        assertEq(usdc.balanceOf(address(vault)), bufferAfterRebalance, "vault USDC unchanged before settle");
        assertEq(vault.totalRedeemInFlight(), withdrawnFromA + withdrawnFromB, "sync redeem in-flights pending");

        _step("[Step 3] Settle sync redeem in-flights (sweep USDC from adapters to vault)");
        _settleAsyncRedeem(address(adapterA), redeemIfStart, withdrawnFromA);
        _settleAsyncRedeem(address(adapterB), redeemIfStart + 1, withdrawnFromB);

        uint256 vaultBal = usdc.balanceOf(address(vault));
        _step(string.concat("  vault USDC after settle: ", vm.toString(vaultBal)));
        assertEq(vaultBal, bufferAfterRebalance + withdrawnFromA + withdrawnFromB, "vault = buffer + divested");
        assertEq(vault.totalRedeemInFlight(), 0, "all redeem in-flights cleared");

        _logPass();
    }

    // =======================================================================
    // 3. Dual async adapter divest -- both create redeem in-flight
    // =======================================================================

    function test_DualAsync_DivestWaterfall() public {
        _logCase(
            "test_DualAsync_DivestWaterfall",
            unicode"双 async adapter 瀑布 divest -- 两个 adapter 都走 requestRedeemAsync 路径"
        );

        _step("[Step 1] Deploy 2 async adapters with 50%/50% weight");
        (MockPosToken_MA posA, MockAsyncAdapter_MA adapterA) = _deployAsyncAdapter("PosA", "PA");
        (MockPosToken_MA posB, MockAsyncAdapter_MA adapterB) = _deployAsyncAdapter("PosB", "PB");

        _registerAndActivate(address(adapterA), 5000, 1, true);
        _registerAndActivate(address(adapterB), 5000, 2, true);
        address[] memory order = new address[](2);
        order[0] = address(adapterA);
        order[1] = address(adapterB);
        _setStrategyOrder(order);

        _step("[Step 2] Deposit 10000 and rebalance invest");
        _deposit(10_000e6);
        uint256 ifIdBefore = vault.nextInFlightId();
        _rebalance();

        // Settle both async invest in-flights
        _step("[Step 3] Settle both invest in-flights");
        uint256 investIdA = ifIdBefore;
        uint256 investIdB = ifIdBefore + 1;
        _settleAsyncInvest(address(adapterA), investIdA, _inFlightTokenAmount(investIdA));
        _settleAsyncInvest(address(adapterB), investIdB, _inFlightTokenAmount(investIdB));

        uint256 valueA = adapterA.totalValue();
        uint256 valueB = adapterB.totalValue();
        _step(string.concat("  adapterA totalValue: ", vm.toString(valueA)));
        _step(string.concat("  adapterB totalValue: ", vm.toString(valueB)));

        _step("[Step 4] Set buffer=80% -> large divest spanning both adapters");
        // _readRebalanceState:
        //   netAssets = 1000 + valueA + valueB + 0 + 0
        //   targetCash = netAssets * 8000/10000 = 8000
        //   freeCash = 1000, divestAmount = 8000 - 1000 = 7000
        //
        // _divest(7000) waterfall (async -> requestRedeemAsync):
        //   adapterA: coverage=valueA, toWithdraw=min(7000, valueA)=valueA, requestAsset=valueA
        //   remaining = 7000 - valueA
        //   adapterB: coverage=valueB, toWithdraw=min(remaining, valueB)=remaining, requestAsset=remaining
        uint256 vaultCashBefore = usdc.balanceOf(address(vault)); // 1000
        uint256 netAssets = vaultCashBefore + valueA + valueB;
        uint256 divestAmount = (netAssets * 8000 / BPS) - vaultCashBefore; // 7000
        uint256 expectedRedeemA = valueA < divestAmount ? valueA : divestAmount;
        uint256 expectedRedeemB = (divestAmount - expectedRedeemA) < valueB
            ? (divestAmount - expectedRedeemA) : valueB;

        _rebalanceWithParams(8000, 0, 0);

        uint256 redeemIFAfterA = vault.adapterRedeemInFlightUsdc(address(adapterA));
        uint256 redeemIFAfterB = vault.adapterRedeemInFlightUsdc(address(adapterB));
        _step(string.concat("  adapterA redeemInFlight: ", vm.toString(redeemIFAfterA)));
        _step(string.concat("  adapterB redeemInFlight: ", vm.toString(redeemIFAfterB)));

        assertEq(redeemIFAfterA, expectedRedeemA, "adapterA redeemInFlight = full drain");
        assertEq(redeemIFAfterB, expectedRedeemB, "adapterB redeemInFlight = remaining");

        uint256 totalRedeemIF = vault.totalRedeemInFlight();
        assertEq(totalRedeemIF, expectedRedeemA + expectedRedeemB, "totalRedeemInFlight = divestAmount");
        _step(string.concat("  totalRedeemInFlight: ", vm.toString(totalRedeemIF)));

        // posTokens should have been pulled from vault by adapters
        uint256 posAOnVault = posA.balanceOf(address(vault));
        uint256 posBOnVault = posB.balanceOf(address(vault));
        _step(string.concat("  posA on vault: ", vm.toString(posAOnVault)));
        _step(string.concat("  posB on vault: ", vm.toString(posBOnVault)));

        _logPass();
    }

    // =======================================================================
    // 4. Interleaved settle/rebalance cycle
    // =======================================================================

    function test_InterleavedSettleRebalance() public {
        _logCase(
            "test_InterleavedSettleRebalance",
            unicode"交错 settle/rebalance 周期 -- settle adapterA 后再 rebalance 再 settle adapterB"
        );

        _step("[Step 1] Deploy 2 async adapters 50%/50%, invest and settle");
        (, MockAsyncAdapter_MA adapterA) = _deployAsyncAdapter("PosA", "PA");
        (, MockAsyncAdapter_MA adapterB) = _deployAsyncAdapter("PosB", "PB");

        _registerAndActivate(address(adapterA), 5000, 1, true);
        _registerAndActivate(address(adapterB), 5000, 2, true);
        address[] memory order = new address[](2);
        order[0] = address(adapterA);
        order[1] = address(adapterB);
        _setStrategyOrder(order);

        _deposit(10_000e6);
        uint256 ifIdStart = vault.nextInFlightId();
        _rebalance();

        // Settle invest in-flights
        uint256 investIdA = ifIdStart;
        uint256 investIdB = ifIdStart + 1;
        _settleAsyncInvest(address(adapterA), investIdA, _inFlightTokenAmount(investIdA));
        _settleAsyncInvest(address(adapterB), investIdB, _inFlightTokenAmount(investIdB));

        uint256 totalAssetsBefore = usdc.balanceOf(address(vault)) + adapterA.totalValue() + adapterB.totalValue();
        _step(string.concat("  totalAssets after invest: ", vm.toString(totalAssetsBefore)));

        _step("[Step 2] Trigger large divest (buffer=80%) -> 2 redeem in-flights");
        _rebalanceWithParams(8000, 0, 0);

        uint256 redeemIdA = vault.nextInFlightId() - 2;
        uint256 redeemIdB = vault.nextInFlightId() - 1;
        uint256 redeemAmtA = vault.adapterRedeemInFlightUsdc(address(adapterA));
        uint256 redeemAmtB = vault.adapterRedeemInFlightUsdc(address(adapterB));
        _step(string.concat("  adapterA redeemInFlight: ", vm.toString(redeemAmtA)));
        _step(string.concat("  adapterB redeemInFlight: ", vm.toString(redeemAmtB)));

        _step("[Step 3] Settle adapterA redeem only -> venue delivers USDC back to adapter, then sweep to vault");
        _settleAsyncRedeem(address(adapterA), redeemIdA, redeemAmtA);

        assertEq(vault.adapterRedeemInFlightUsdc(address(adapterA)), 0, "adapterA redeemInFlight cleared");
        assertEq(vault.adapterRedeemInFlightUsdc(address(adapterB)), redeemAmtB, "adapterB redeemInFlight unchanged");
        _step("  adapterA redeemInFlight cleared, adapterB unchanged");

        _step("[Step 4] Rebalance again -> should not double-invest");
        uint256 investIFBefore = vault.totalInvestInFlight();
        // buffer is still 80%, freeCash should now be higher, no invest expected
        _rebalance();
        uint256 investIFAfter = vault.totalInvestInFlight();
        _step(string.concat("  investInFlight: ", vm.toString(investIFBefore), " -> ", vm.toString(investIFAfter)));

        _step("[Step 5] Settle adapterB redeem");
        _settleAsyncRedeem(address(adapterB), redeemIdB, redeemAmtB);

        assertEq(vault.adapterRedeemInFlightUsdc(address(adapterB)), 0, "adapterB redeemInFlight cleared");
        assertEq(vault.totalRedeemInFlight(), 0, "totalRedeemInFlight = 0");
        _step("  all redeem in-flights cleared");

        _step("[Step 6] Final rebalance to equilibrium");
        _rebalanceWithParams(1000, 0, 0);
        uint256 totalAssetsAfter = usdc.balanceOf(address(vault)) + adapterA.totalValue() + adapterB.totalValue()
            + vault.totalInvestInFlight() + vault.totalRedeemInFlight();
        _step(string.concat("  totalAssets final: ", vm.toString(totalAssetsAfter)));
        // No USDC minted or burned -- totalAssets must be exactly conserved
        assertEq(totalAssetsAfter, totalAssetsBefore, "totalAssets must be conserved");

        _logPass();
    }

    // =======================================================================
    // 5. 3 adapter invest waterfall
    // =======================================================================

    function test_ThreeAdapter_InvestWaterfall() public {
        _logCase(
            "test_ThreeAdapter_InvestWaterfall",
            unicode"3 adapter 瀑布 invest -- 第三个 adapter 获得 excessCash 的剩余"
        );

        _step("[Step 1] Deploy 3 sync adapters: A=20%, B=30%, C=50%");
        MockPosToken_MA posA = new MockPosToken_MA("PosA", "PA");
        MockPosToken_MA posB = new MockPosToken_MA("PosB", "PB");
        MockPosToken_MA posC = new MockPosToken_MA("PosC", "PC");
        MockSyncAdapter_MA adapterA = new MockSyncAdapter_MA(address(usdc), address(posA), address(vault));
        MockSyncAdapter_MA adapterB = new MockSyncAdapter_MA(address(usdc), address(posB), address(vault));
        MockSyncAdapter_MA adapterC = new MockSyncAdapter_MA(address(usdc), address(posC), address(vault));

        _registerAndActivate(address(adapterA), 2000, 1, false);
        _registerAndActivate(address(adapterB), 3000, 2, false);
        _registerAndActivate(address(adapterC), 5000, 3, false);
        address[] memory order = new address[](3);
        order[0] = address(adapterA);
        order[1] = address(adapterB);
        order[2] = address(adapterC);
        _setStrategyOrder(order);

        _step("[Step 2] Deposit 10000 USDC and rebalance (buffer=10%)");
        _deposit(10_000e6);
        uint256 ifId3 = vault.nextInFlightId();
        _rebalance();

        // Settle invest in-flights (sync adapters also create PENDING records)
        _settleAsyncInvest(address(adapterA), ifId3, _inFlightTokenAmount(ifId3));
        _settleAsyncInvest(address(adapterB), ifId3 + 1, _inFlightTokenAmount(ifId3 + 1));
        _settleAsyncInvest(address(adapterC), ifId3 + 2, _inFlightTokenAmount(ifId3 + 2));

        // Contract formula trace:
        // totalAssets = vault.bal(10000) + strategyValue(0) + investIF(0) + redeemIF(0) = 10000
        // targetCash = 10000 * 1000/10000 + cashDeficit(0) = 1000
        // investAmount = freeCash(10000) - targetCash(1000) = 9000
        uint256 totalAssets_ = 10_000e6;
        uint256 investAmount = totalAssets_ - (totalAssets_ * 1000 / BPS); // 9000

        uint256 valueA = adapterA.totalValue();
        uint256 valueB = adapterB.totalValue();
        uint256 valueC = adapterC.totalValue();
        uint256 vaultBal = usdc.balanceOf(address(vault));
        _step(string.concat("  adapterA: ", vm.toString(valueA)));
        _step(string.concat("  adapterB: ", vm.toString(valueB)));
        _step(string.concat("  adapterC: ", vm.toString(valueC)));
        _step(string.concat("  vault USDC: ", vm.toString(vaultBal)));

        // Inside _invest(9000), per-adapter: alloc = min(targetBalance - currentBalance, remaining)
        uint256 targetA = totalAssets_ * 2000 / BPS; // 2000
        uint256 targetB = totalAssets_ * 3000 / BPS; // 3000
        uint256 targetC = totalAssets_ * 5000 / BPS; // 5000
        uint256 remaining = investAmount;
        uint256 expectedA = targetA < remaining ? targetA : remaining; // min(2000, 9000) = 2000
        remaining -= expectedA;
        uint256 expectedB = targetB < remaining ? targetB : remaining; // min(3000, 7000) = 3000
        remaining -= expectedB;
        uint256 expectedC = targetC < remaining ? targetC : remaining; // min(5000, 4000) = 4000

        assertEq(valueA, expectedA, "adapterA alloc = min(targetA, remaining)");
        assertEq(valueB, expectedB, "adapterB alloc = min(targetB, remaining)");
        assertEq(valueC, expectedC, "adapterC alloc = min(targetC, remaining) -- capped by remaining");
        assertEq(valueA + valueB + valueC, investAmount, "total invested = investAmount");
        assertEq(vaultBal, totalAssets_ * 1000 / BPS, "vault = buffer");

        _logPass();
    }

    // =======================================================================
    // 6. 3 adapter divest waterfall -- partial drain
    // =======================================================================

    function test_ThreeAdapter_DivestWaterfall() public {
        _logCase(
            "test_ThreeAdapter_DivestWaterfall",
            unicode"3 adapter 瀑布 divest -- 部分 adapter 清空后 remaining 传递给下一个"
        );

        _step("[Step 1] Setup 3 sync adapters A=20%, B=30%, C=50%, invest, and settle");
        MockPosToken_MA posA = new MockPosToken_MA("PosA", "PA");
        MockPosToken_MA posB = new MockPosToken_MA("PosB", "PB");
        MockPosToken_MA posC = new MockPosToken_MA("PosC", "PC");
        MockSyncAdapter_MA adapterA = new MockSyncAdapter_MA(address(usdc), address(posA), address(vault));
        MockSyncAdapter_MA adapterB = new MockSyncAdapter_MA(address(usdc), address(posB), address(vault));
        MockSyncAdapter_MA adapterC = new MockSyncAdapter_MA(address(usdc), address(posC), address(vault));

        _registerAndActivate(address(adapterA), 2000, 1, false);
        _registerAndActivate(address(adapterB), 3000, 2, false);
        _registerAndActivate(address(adapterC), 5000, 3, false);
        address[] memory order = new address[](3);
        order[0] = address(adapterA);
        order[1] = address(adapterB);
        order[2] = address(adapterC);
        _setStrategyOrder(order);

        _deposit(10_000e6);
        uint256 ifId3 = vault.nextInFlightId();
        _rebalance();

        // Settle invest in-flights so netAssets is not double-counted
        _settleAsyncInvest(address(adapterA), ifId3, _inFlightTokenAmount(ifId3));
        _settleAsyncInvest(address(adapterB), ifId3 + 1, _inFlightTokenAmount(ifId3 + 1));
        _settleAsyncInvest(address(adapterC), ifId3 + 2, _inFlightTokenAmount(ifId3 + 2));

        uint256 valueAInit = adapterA.totalValue(); // 2000
        uint256 valueBInit = adapterB.totalValue(); // 3000
        uint256 valueCInit = adapterC.totalValue(); // 4000
        _step(string.concat("  after invest: A=", vm.toString(valueAInit), " B=", vm.toString(valueBInit), " C=", vm.toString(valueCInit)));

        _step("[Step 2] Set buffer=90% -> divest");
        // _readRebalanceState:
        //   netAssets = 1000 + (2000+3000+4000) + 0 + 0 = 10000
        //   targetCash = 10000 * 9000/10000 + 0 = 9000
        //   freeCash = 1000, divestAmount = 9000 - 1000 = 8000
        //
        // _divest(8000) waterfall:
        //   A: coverage=totalValue()=2000, toWithdraw=min(8000,2000)=2000, withdrawSync(2000)=2000, remaining=6000
        //   B: coverage=3000, toWithdraw=min(6000,3000)=3000, withdrawSync(3000)=3000, remaining=3000
        //   C: coverage=4000, toWithdraw=min(3000,4000)=3000, withdrawSync(3000)=3000, remaining=0
        uint256 bufferAfterRebalance = usdc.balanceOf(address(vault));
        uint256 netAssetsDivest = bufferAfterRebalance + valueAInit + valueBInit + valueCInit;
        uint16 newBufferBps = 9000;
        uint256 targetCashDivest = netAssetsDivest * newBufferBps / BPS;
        uint256 divestAmount = targetCashDivest > bufferAfterRebalance ? targetCashDivest - bufferAfterRebalance : 0;
        uint256 redeemIfStart = vault.nextInFlightId();
        _rebalanceWithParams(9000, 0, 0);

        uint256 valueA = adapterA.totalValue();
        uint256 valueB = adapterB.totalValue();
        uint256 valueC = adapterC.totalValue();
        _step(string.concat("  adapterA: ", vm.toString(valueA)));
        _step(string.concat("  adapterB: ", vm.toString(valueB)));
        _step(string.concat("  adapterC: ", vm.toString(valueC)));

        // Waterfall: A drained(2000), B drained(3000), C partial(3000 of 4000)
        uint256 withdrawnA = valueAInit; // 2000
        uint256 remainAfterA = divestAmount - withdrawnA; // 6000
        uint256 withdrawnB = valueBInit; // 3000
        uint256 remainAfterB = remainAfterA - withdrawnB; // 3000
        uint256 withdrawnC = remainAfterB; // 3000 (< valueCInit=4000)

        assertEq(valueA, 0, "adapterA fully drained");
        assertEq(valueB, 0, "adapterB fully drained");
        assertEq(valueC, valueCInit - withdrawnC, "adapterC: 4000 - 3000 = 1000 remaining");

        // Real protocol: withdrawSync sends USDC to adapter (not vault).
        assertEq(usdc.balanceOf(address(vault)), bufferAfterRebalance, "vault USDC unchanged before settle");
        assertEq(vault.totalRedeemInFlight(), withdrawnA + withdrawnB + withdrawnC, "sync redeem in-flights pending");

        _step("[Step 3] Settle sync redeem in-flights (sweep USDC from adapters to vault)");
        _settleAsyncRedeem(address(adapterA), redeemIfStart, withdrawnA);
        _settleAsyncRedeem(address(adapterB), redeemIfStart + 1, withdrawnB);
        _settleAsyncRedeem(address(adapterC), redeemIfStart + 2, withdrawnC);

        uint256 vaultBal = usdc.balanceOf(address(vault));
        _step(string.concat("  vault USDC after settle: ", vm.toString(vaultBal)));
        assertEq(vaultBal, bufferAfterRebalance + withdrawnA + withdrawnB + withdrawnC, "vault = buffer + divested");
        assertEq(vault.totalRedeemInFlight(), 0, "all redeem in-flights cleared");

        _logPass();
    }

    // =======================================================================
    // 7. settleAdapters batch settle for 2 adapters
    // =======================================================================

    function test_SettleAdapters_BatchRedeem() public {
        _logCase(
            "test_SettleAdapters_BatchRedeem",
            unicode"settleAdapters 批量结算 -- 多 adapter 同时 settle invest + redeem"
        );

        _step("[Step 1] Deploy 2 async adapters 50%/50%, invest and settle");
        (, MockAsyncAdapter_MA adapterA) = _deployAsyncAdapter("PosA", "PA");
        (, MockAsyncAdapter_MA adapterB) = _deployAsyncAdapter("PosB", "PB");

        _registerAndActivate(address(adapterA), 5000, 1, true);
        _registerAndActivate(address(adapterB), 5000, 2, true);
        address[] memory order = new address[](2);
        order[0] = address(adapterA);
        order[1] = address(adapterB);
        _setStrategyOrder(order);

        _deposit(10_000e6);
        uint256 ifIdStart = vault.nextInFlightId();
        _rebalance();

        // Settle invest in-flights
        _settleAsyncInvest(address(adapterA), ifIdStart, _inFlightTokenAmount(ifIdStart));
        _settleAsyncInvest(address(adapterB), ifIdStart + 1, _inFlightTokenAmount(ifIdStart + 1));
        _step("  invest in-flights settled");

        _step("[Step 2] Trigger divest -> 2 redeem in-flights");
        _rebalanceWithParams(8000, 0, 0);

        uint256 redeemIdA = vault.nextInFlightId() - 2;
        uint256 redeemIdB = vault.nextInFlightId() - 1;
        uint256 redeemAmtA = vault.adapterRedeemInFlightUsdc(address(adapterA));
        uint256 redeemAmtB = vault.adapterRedeemInFlightUsdc(address(adapterB));
        _step(string.concat("  redeemInFlight A=", vm.toString(redeemAmtA), " B=", vm.toString(redeemAmtB)));

        assertGt(redeemAmtA, 0, "adapterA has redeem in-flight");
        assertGt(redeemAmtB, 0, "adapterB has redeem in-flight");

        _step("[Step 3] External venue delivers redeem USDC to both adapters");
        _deliverAsyncRedeemSettlement(address(adapterA), redeemIdA, redeemAmtA);
        _deliverAsyncRedeemSettlement(address(adapterB), redeemIdB, redeemAmtB);

        _step("[Step 4] Batch settle both adapters via executeSettleAdapters");
        address[] memory adapters = new address[](2);
        adapters[0] = address(adapterA);
        adapters[1] = address(adapterB);

        // Build invest input (empty for both -- no invest to settle)
        IStrategyControllerExecutor.InvestSettlementInput[] memory investBatch =
            new IStrategyControllerExecutor.InvestSettlementInput[](2);
        investBatch[0] = IStrategyControllerExecutor.InvestSettlementInput({
            inFlightIds: new uint256[](0),
            settledPosAmounts: new uint256[](0),
            refundAssetAmounts: new uint256[](0)
        });
        investBatch[1] = IStrategyControllerExecutor.InvestSettlementInput({
            inFlightIds: new uint256[](0),
            settledPosAmounts: new uint256[](0),
            refundAssetAmounts: new uint256[](0)
        });

        // Build redeem input
        IStrategyControllerExecutor.RedeemSettlementInput[] memory redeemBatch =
            new IStrategyControllerExecutor.RedeemSettlementInput[](2);

        uint256[] memory idsA = new uint256[](1);
        idsA[0] = redeemIdA;
        uint256[] memory amtsA = new uint256[](1);
        amtsA[0] = redeemAmtA;
        redeemBatch[0] = IStrategyControllerExecutor.RedeemSettlementInput({
            inFlightIds: idsA,
            settledAssetAmounts: amtsA
        });

        uint256[] memory idsB = new uint256[](1);
        idsB[0] = redeemIdB;
        uint256[] memory amtsB = new uint256[](1);
        amtsB[0] = redeemAmtB;
        redeemBatch[1] = IStrategyControllerExecutor.RedeemSettlementInput({
            inFlightIds: idsB,
            settledAssetAmounts: amtsB
        });

        vm.prank(bot);
        executor.executeSettleAdapters(address(controller), adapters, investBatch, redeemBatch);

        _step("[Step 5] Verify both redeem in-flights CONFIRMED");
        (,,,,,,,, IMantleYieldVault.InFlightStatus statusA) = vault.inFlightRecords(redeemIdA);
        (,,,,,,,, IMantleYieldVault.InFlightStatus statusB) = vault.inFlightRecords(redeemIdB);
        assertEq(uint8(statusA), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED), "adapterA redeem CONFIRMED");
        assertEq(uint8(statusB), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED), "adapterB redeem CONFIRMED");

        assertEq(vault.adapterRedeemInFlightUsdc(address(adapterA)), 0, "adapterA redeemInFlight cleared");
        assertEq(vault.adapterRedeemInFlightUsdc(address(adapterB)), 0, "adapterB redeemInFlight cleared");
        assertEq(vault.totalRedeemInFlight(), 0, "totalRedeemInFlight = 0");
        _step("  PASS: batch settle cleared both redeem in-flights");

        _logPass();
    }

    // =======================================================================
    // 8. Mixed sync/async adapter waterfall divest
    // =======================================================================

    function test_MixedSyncAsyncDivest() public {
        _logCase(
            "test_MixedSyncAsyncDivest",
            unicode"混合 sync/async adapter 瀑布 divest -- sync adapter 走 withdrawSync，async adapter 走 requestRedeemAsync"
        );

        _step("[Step 1] Deploy 1 sync adapter (50%) + 1 async adapter (50%)");
        MockPosToken_MA posA = new MockPosToken_MA("PosA", "PA");
        MockSyncAdapter_MA syncAdapterA = new MockSyncAdapter_MA(address(usdc), address(posA), address(vault));

        (, MockAsyncAdapter_MA asyncAdapterB) = _deployAsyncAdapter("PosB", "PB");

        _registerAndActivate(address(syncAdapterA), 5000, 1, false);
        _registerAndActivate(address(asyncAdapterB), 5000, 2, true);
        address[] memory order = new address[](2);
        order[0] = address(syncAdapterA);
        order[1] = address(asyncAdapterB);
        _setStrategyOrder(order);

        _step("[Step 2] Deposit 10000 USDC and rebalance invest");
        _deposit(10_000e6);
        uint256 ifIdStart = vault.nextInFlightId();
        _rebalance();

        _step("[Step 3] Settle both invest in-flights");
        uint256 investIdA = ifIdStart;
        uint256 investIdB = ifIdStart + 1;
        // Sync adapter: _deliverAsyncInvestSettlement is a no-op (no venue), settle sweeps posToken from adapter to vault
        _settleAsyncInvest(address(syncAdapterA), investIdA, _inFlightTokenAmount(investIdA));
        // Async adapter: venue delivers posToken, then settle sweeps to vault
        _settleAsyncInvest(address(asyncAdapterB), investIdB, _inFlightTokenAmount(investIdB));

        uint256 valueA = syncAdapterA.totalValue();
        uint256 valueB = asyncAdapterB.totalValue();
        _step(string.concat("  syncAdapterA totalValue: ", vm.toString(valueA)));
        _step(string.concat("  asyncAdapterB totalValue: ", vm.toString(valueB)));
        assertGt(valueA, 0, "syncAdapterA should have value");
        assertGt(valueB, 0, "asyncAdapterB should have value");

        _step("[Step 4] Set buffer=80% -> divest spanning both adapters");
        // _readRebalanceState:
        //   netAssets = vaultCash + valueA + valueB
        //   targetCash = netAssets * 8000/10000 = 8000
        //   freeCash = vaultCash (1000), divestAmount = 8000 - 1000 = 7000
        //
        // _divest(7000) waterfall:
        //   syncAdapterA: coverage=valueA, toWithdraw=min(7000, valueA)=valueA
        //     withdrawSync(valueA) -> remaining = 7000 - valueA
        //   asyncAdapterB: coverage=valueB, toWithdraw=min(remaining, valueB)=remaining
        //     requestRedeemAsync(remaining) -> remaining = 0
        uint256 vaultCashBefore = usdc.balanceOf(address(vault));
        uint256 netAssets = vaultCashBefore + valueA + valueB;
        uint256 targetCashDivest = netAssets * 8000 / BPS;
        uint256 divestAmount = targetCashDivest - vaultCashBefore;
        uint256 expectedSyncWithdraw = valueA < divestAmount ? valueA : divestAmount;
        uint256 expectedAsyncRedeem = divestAmount - expectedSyncWithdraw;

        uint256 redeemIfStart = vault.nextInFlightId();
        _rebalanceWithParams(8000, 0, 0);

        _step("[Step 5] Verify sync adapter: withdrawSync path (full drain)");
        uint256 valueAAfter = syncAdapterA.totalValue();
        assertEq(valueAAfter, 0, "syncAdapterA fully drained by withdrawSync");
        _step(string.concat("  syncAdapterA totalValue after divest: ", vm.toString(valueAAfter)));

        _step("[Step 6] Verify async adapter: requestRedeemAsync path (partial redeem)");
        uint256 redeemIFB = vault.adapterRedeemInFlightUsdc(address(asyncAdapterB));
        assertEq(redeemIFB, expectedAsyncRedeem, "asyncAdapterB redeemInFlight = remaining from waterfall");
        _step(string.concat("  asyncAdapterB redeemInFlight: ", vm.toString(redeemIFB)));

        // posTokens should have been pulled from vault by async adapter
        uint256 valueBAfter = asyncAdapterB.totalValue();
        uint256 expectedValueBAfter = valueB - expectedAsyncRedeem;
        assertEq(valueBAfter, expectedValueBAfter, "asyncAdapterB value reduced by redeemed amount");
        _step(string.concat("  asyncAdapterB totalValue after divest: ", vm.toString(valueBAfter)));

        _step("[Step 7] Verify remaining correctly propagated: syncWithdraw + asyncRedeem = divestAmount");
        uint256 totalRedeemIF = vault.totalRedeemInFlight();
        assertEq(totalRedeemIF, expectedSyncWithdraw + expectedAsyncRedeem, "totalRedeemInFlight = divestAmount");
        _step(string.concat("  totalRedeemInFlight: ", vm.toString(totalRedeemIF)));
        _step(string.concat("  syncWithdraw(", vm.toString(expectedSyncWithdraw),
            ") + asyncRedeem(", vm.toString(expectedAsyncRedeem), ") = ", vm.toString(divestAmount)));

        _step("[Step 8] Settle both redeem in-flights and verify vault USDC = targetCash");
        // Sync adapter: USDC already on adapter from withdrawSync, sweep to vault
        _settleAsyncRedeem(address(syncAdapterA), redeemIfStart, expectedSyncWithdraw);
        // Async adapter: venue delivers USDC to adapter, then sweep to vault
        _settleAsyncRedeem(address(asyncAdapterB), redeemIfStart + 1, expectedAsyncRedeem);

        uint256 vaultCashFinal = usdc.balanceOf(address(vault));
        _step(string.concat("  vault USDC after settle: ", vm.toString(vaultCashFinal)));
        assertEq(vaultCashFinal, vaultCashBefore + divestAmount, "vault USDC = initial buffer + divested");
        assertEq(vault.totalRedeemInFlight(), 0, "all redeem in-flights cleared");
        _step("  PASS: sync path withdrew immediately, async path created redeem in-flight, remaining correctly propagated");

        _logPass();
    }
}
