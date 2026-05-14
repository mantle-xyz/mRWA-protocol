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
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Test, console2} from "forge-std/Test.sol";

// ---------------------------------------------------------------------------
// Mocks
// ---------------------------------------------------------------------------

contract MockUSDC_NB is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function burn(address from, uint256 amount) external { _burn(from, amount); }
}

contract MockPosToken_NB is ERC20 {
    constructor() ERC20("MockPosToken", "mPOS") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockSanctionsOracle_NB is ISanctionsOracle {
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

contract MockSyncAdapter_NB is IStrategyAdapter {
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
    function estimatePosAmount(uint256 a) external pure returns (uint256) { return a; }
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
    function totalValue() external view returns (uint256) { return IERC20(ASSET).balanceOf(address(this)); }

    function deposit(uint256 amount, address) external returns (uint256) {
        IERC20(ASSET).transferFrom(VAULT, address(this), amount);
        MockPosToken_NB(POS_TOKEN).mint(address(this), amount);
        return amount;
    }

    /// @dev Real sync flow: controller passes posAmount + approves adapter to pull posToken from vault.
    ///      Adapter pulls pos, burns it, USDC stays on adapter (already there from deposit).
    ///      Controller later calls sweepToVault(asset, ...) to move USDC to vault.
    function withdrawSync(uint256 posAmount, address) external returns (uint256) {
        uint256 bal = IERC20(ASSET).balanceOf(address(this));
        uint256 actual = posAmount > bal ? bal : posAmount;
        if (actual > 0) {
            IERC20(POS_TOKEN).transferFrom(VAULT, address(this), actual);
        }
        return actual;
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

// ---------------------------------------------------------------------------
// QA Test: Numerical Boundary & Edge Cases
// ---------------------------------------------------------------------------

contract NumericalBoundaryQATest is Test {
    MockUSDC_NB internal usdc;
    MockPosToken_NB internal posToken;
    MockSanctionsOracle_NB internal oracle;
    MantleYieldVault internal vault;
    MantleVaultGateway internal gateway;
    Accountant internal accountant;
    StrategyController internal controller;
    MockSyncAdapter_NB internal adapter;
    OperatorExecutor internal executor;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal sanctionSafe = makeAddr("sanctionSafe");
    address internal bot = makeAddr("bot");
    address internal user = makeAddr("user");

    string constant MODULE = unicode"数值边界与精度场景";
    string private _buf;

    function _logCase(string memory id, string memory name_) internal {
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

    function setUp() public {
        vm.warp(100_000);

        usdc = new MockUSDC_NB();
        posToken = new MockPosToken_NB();
        oracle = new MockSanctionsOracle_NB();

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
                redemptionFeeBps: 100,
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
                address(vault), admin, address(executor), admin, 1000, 200, 0
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

        adapter = new MockSyncAdapter_NB(address(usdc), address(posToken), address(vault));
        vm.startPrank(admin);
        controller.registerStrategy(address(adapter), 10_000, 1, false);
        controller.activateStrategy(address(adapter));
        address[] memory ordered = new address[](1);
        ordered[0] = address(adapter);
        controller.setStrategyOrder(ordered);
        vm.stopPrank();

        usdc.mint(user, 100_000_000e6);
        vm.prank(user);
        usdc.approve(address(vault), type(uint256).max);
    }

    // =======================================================================
    // 1. 极小金额存款：1 wei USDC 存入时份额行为
    // =======================================================================

    function test_TinyDeposit_OneWei() public {
        _logCase("test_TinyDeposit_OneWei", unicode"1 wei USDC 存入时份额行为（minDeposit=0, rate=1.0）");

        _step("[Step 1] Deposit 1 wei (0.000001 USDC)");
        vm.prank(user);
        gateway.deposit(1);

        uint256 shares = vault.balanceOf(user);
        _step(string.concat("  shares received: ", vm.toString(shares)));
        // At rate 1.0: 1 wei USDC -> 1 share (1 * 1e18 / 1e18 = 1)
        assertEq(shares, 1, "1 wei deposit should yield 1 share at rate 1.0");

        _logPass();
    }

    function test_TinyDeposit_BelowMinDeposit() public {
        _logCase("test_TinyDeposit_BelowMinDeposit", unicode"存款金额低于 `minDepositAmount` 时被拒绝");

        _step("[Step 1] Set minDepositAmount = 1 USDC");
        vm.prank(admin);
        vault.setMinDepositAmount(1e6);

        _step("[Step 2] Deposit 0.5 USDC -> should revert");
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IMantleYieldVault.Vault__BelowMinDeposit.selector, 500000, 1000000));
        gateway.deposit(0.5e6);
        _step("  reverted (below min deposit)");

        _step("[Step 3] Deposit exactly 1 USDC -> should succeed");
        vm.prank(user);
        gateway.deposit(1e6);
        assertGt(vault.balanceOf(user), 0, "deposit at min succeeds");

        _logPass();
    }

    // =======================================================================
    // 2. 极小份额赎回：1 share 赎回时费率舍入行为
    // =======================================================================

    function test_TinyRedeem_FeeRoundingEatsAll() public {
        _logCase("test_TinyRedeem_FeeRoundingEatsAll", unicode"1 share 赎回时 Ceil 舍入导致手续费 >= 净值");

        _step("[Step 1] Deposit small amount to get few shares");
        vm.prank(user);
        gateway.deposit(1); // 1 wei -> 1 share at rate 1.0

        uint256 shares = vault.balanceOf(user);
        assertEq(shares, 1, "1 share");

        _step("[Step 2] Preview redeem of 1 share");
        uint256 preview = vault.previewRedeem(1);
        _step(string.concat("  previewRedeem(1): ", vm.toString(preview)));
        // gross = 1 * 1e18 / 1e18 = 1 wei
        // fee = ceil(1 * 100 / 10000) = ceil(0.01) = 1 wei
        // net = 1 - 1 = 0
        assertEq(preview, 0, "fee rounding eats entire value for 1 share");

        _step("[Step 3] maxRedeem should still report shares (vault lets you try)");
        uint256 maxR = vault.maxRedeem(user);
        _step(string.concat("  maxRedeem: ", vm.toString(maxR)));

        _logPass();
    }

    function test_TinyRedeem_ZeroFeeNoRoundingIssue() public {
        _logCase("test_TinyRedeem_ZeroFeeNoRoundingIssue", unicode"fee=0 时极小份额赎回无舍入问题");

        vm.prank(admin);
        vault.setRedemptionFee(0);

        vm.prank(user);
        gateway.deposit(1); // 1 share

        uint256 preview = vault.previewRedeem(1);
        assertEq(preview, 1, "no fee -> full 1 wei returned");

        vm.prank(user);
        uint256 assets = gateway.redeem(1);
        assertEq(assets, 1, "actually received 1 wei");

        _logPass();
    }

    // =======================================================================
    // 3. setRiskParams 边界：bufferTargetBps = 0 / 10000
    // =======================================================================

    function test_BufferTargetZero_InvestsEverything() public {
        _logCase("test_BufferTargetZero_InvestsEverything", unicode"`bufferTargetBps=0` 时全部资金投入策略");

        vm.prank(user);
        gateway.deposit(10_000e6);

        _step("[Step 1] Set buffer=0, threshold=0 and rebalance");
        vm.prank(admin);
        controller.setRiskParams(0, 0, 0);
        vm.prank(bot);
        executor.executeRebalance(address(controller));

        uint256 fc = vault.getFreeCash();
        uint256 adapterVal = adapter.totalValue();
        _step(string.concat("  freeCash: ", vm.toString(fc)));
        _step(string.concat("  adapter value: ", vm.toString(adapterVal)));

        // targetCash = netAssets * 0 / 10000 = 0 -> invest everything
        assertEq(fc, 0, "freeCash should be 0 (all invested)");
        assertGt(adapterVal, 0, "adapter should hold all funds");

        _logPass();
    }

    function test_BufferTargetMax_InvestsNothing() public {
        _logCase("test_BufferTargetMax_InvestsNothing", unicode"`bufferTargetBps=10000` 时不投资（全部保留为 buffer）");

        vm.prank(user);
        gateway.deposit(10_000e6);

        _step("[Step 1] Set buffer=10000 (100%) and rebalance");
        vm.prank(admin);
        controller.setRiskParams(10_000, 0, 0);
        vm.prank(bot);
        executor.executeRebalance(address(controller));

        uint256 fc = vault.getFreeCash();
        uint256 adapterVal = adapter.totalValue();
        _step(string.concat("  freeCash: ", vm.toString(fc)));
        _step(string.concat("  adapter value: ", vm.toString(adapterVal)));

        // targetCash = netAssets -> freeCash = netAssets -> no excess -> no invest
        assertEq(adapterVal, 0, "adapter should have nothing (all buffer)");
        assertEq(fc, 10_000e6, "all funds stay as freeCash");

        _logPass();
    }

    function test_ThresholdMax_NeverTriggers() public {
        _logCase("test_ThresholdMax_NeverTriggers", unicode"`rebalanceThresholdBps=10000` 时几乎不触发投资或撤资");

        vm.prank(user);
        gateway.deposit(10_000e6);

        _step("[Step 1] Set buffer=50%, threshold=100% and rebalance");
        vm.prank(admin);
        controller.setRiskParams(5000, 10_000, 0);
        vm.prank(bot);
        executor.executeRebalance(address(controller));

        uint256 adapterVal = adapter.totalValue();
        _step(string.concat("  adapter value: ", vm.toString(adapterVal)));

        // targetCash = 5000, threshold = 10000
        // invest requires: freeCash > 5000 + 10000 = 15000 (impossible with 10000 total)
        // divest requires: freeCash + 10000 < 5000 (impossible since freeCash >= 0)
        assertEq(adapterVal, 0, "no invest triggered (threshold too large)");

        _logPass();
    }

    function test_SetRiskParams_RejectsAboveBPS() public {
        _logCase("test_SetRiskParams_RejectsAboveBPS", unicode"`setRiskParams` 拒绝超过 10000 bps 的参数");

        vm.prank(admin);
        vm.expectRevert(StrategyController.Controller__InvalidBps.selector);
        controller.setRiskParams(10_001, 200, 0);
        _step("  bufferTargetBps=10001 reverted");

        vm.prank(admin);
        vm.expectRevert(StrategyController.Controller__InvalidBps.selector);
        controller.setRiskParams(1000, 10_001, 0);
        _step("  rebalanceThresholdBps=10001 reverted");

        // 10000 should be accepted
        vm.prank(admin);
        controller.setRiskParams(10_000, 10_000, 0);
        _step("  10000/10000 accepted");

        _logPass();
    }

    // =======================================================================
    // 4. Accountant setRiskParams 边界
    // =======================================================================

    function test_Accountant_DeviationZero_Rejected() public {
        _logCase("test_Accountant_DeviationZero_Rejected", unicode"Accountant `maxDeviation=0` 被拒绝");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Accountant.Accountant__InvalidDeviation.selector, 0));
        accountant.setRiskParams(0, 20 hours);
        _step("  deviation=0 reverted (InvalidDeviation)");

        _logPass();
    }

    function test_Accountant_DeviationAboveCeiling_Rejected() public {
        _logCase("test_Accountant_DeviationAboveCeiling_Rejected", unicode"Accountant `maxDeviation > 1000` 被拒绝");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Accountant.Accountant__InvalidDeviation.selector, 1001));
        accountant.setRiskParams(1001, 20 hours);
        _step("  deviation=1001 reverted (exceeds MAX_DEVIATION_CEILING=1000)");

        // 1000 should be accepted
        vm.prank(admin);
        accountant.setRiskParams(1000, 20 hours);
        _step("  deviation=1000 accepted");

        _logPass();
    }

    function test_Accountant_MinIntervalZero_Accepted() public {
        _logCase("test_Accountant_MinIntervalZero_Accepted", unicode"Accountant `minInterval=0` 允许每个区块更新汇率");

        vm.prank(admin);
        accountant.setRiskParams(100, 0);

        // With interval=0, consecutive updates should work (no cooldown)
        vm.warp(block.timestamp + 21 hours); // pass initial cooldown

        // Grant executor role to admin for direct testing
        bytes32 execRole = accountant.ACCOUNTANT_EXECUTOR_ROLE();
        vm.prank(admin);
        accountant.grantRole(execRole, admin);

        vm.prank(admin);
        accountant.updateExchangeRate(uint64(1.005e18), uint64(block.timestamp - 1 minutes));

        // Immediate second update (1 second later for fresh compute timestamp)
        vm.warp(block.timestamp + 1);
        vm.prank(admin);
        accountant.updateExchangeRate(uint64(1.006e18), uint64(block.timestamp - 1));

        assertEq(accountant.getRate(), uint256(uint64(1.006e18)), "two rapid updates succeeded");
        _step("  minInterval=0 allows consecutive updates");

        _logPass();
    }

    // =======================================================================
    // 5. 多笔小额赎回 vs 单笔大额赎回的费率累积差异
    // =======================================================================

    function test_FeeRounding_SmallBatchesVsSingleLarge() public {
        _logCase("test_FeeRounding_SmallBatchesVsSingleLarge", unicode"多笔小额赎回 vs 单笔大额赎回的费率累积差异");

        _step("[Step 1] Two users deposit same amount (non-round to trigger Ceil rounding)");
        address userA = makeAddr("userA");
        address userB = makeAddr("userB");
        usdc.mint(userA, 10_000e6);
        usdc.mint(userB, 10_000e6);
        vm.prank(userA);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(userB);
        usdc.approve(address(vault), type(uint256).max);

        // Use 1_000_000_099 instead of 1000e6: shares/10 = 100_000_009 which is NOT
        // divisible by 100, so Ceil(batchAssets * feeBps / 10000) produces real rounding.
        uint256 depositAmt = 1_000_000_099;
        vm.prank(userA);
        gateway.deposit(depositAmt);
        vm.prank(userB);
        gateway.deposit(depositAmt);

        uint256 sharesA = vault.balanceOf(userA);
        uint256 sharesB = vault.balanceOf(userB);
        assertEq(sharesA, sharesB, "same shares");

        _step("[Step 2] userA redeems in 10 small batches");
        uint256 batchSize = sharesA / 10;
        uint256 totalAssetsA = 0;
        for (uint256 i = 0; i < 10; i++) {
            uint256 toRedeem = (i == 9) ? vault.balanceOf(userA) : batchSize;
            if (toRedeem == 0) break;
            vm.prank(userA);
            totalAssetsA += gateway.redeem(toRedeem);
        }
        _step(string.concat("  userA total (10 batches): ", vm.toString(totalAssetsA)));

        _step("[Step 3] userB redeems in 1 large batch");
        vm.prank(userB);
        uint256 totalAssetsB = gateway.redeem(sharesB);
        _step(string.concat("  userB total (1 batch): ", vm.toString(totalAssetsB)));

        _step("[Step 4] Compare: Ceil rounding may cause small batches to pay more fee");
        uint256 diff = totalAssetsB > totalAssetsA ? totalAssetsB - totalAssetsA : totalAssetsA - totalAssetsB;
        _step(string.concat("  difference: ", vm.toString(diff)));

        // Due to Ceil rounding on fee per batch, small batches pay slightly more total fee.
        // With 10 batches each having non-round asset amounts, diff should be ~9 wei.
        assertGe(totalAssetsB, totalAssetsA, "single large redeem gets >= small batches (less rounding loss)");
        assertGt(diff, 0, "rounding should produce a non-zero difference (Ceil activates on each batch)");
        assertLe(diff, 10, "rounding difference should be negligible (<=10 wei)");

        _logPass();
    }
}

// ===========================================================================
// Precision Mocks (variable exchangeRate + variable posTokenPrice + 18-dec ST)
// ===========================================================================

/// @dev Mock accountant with directly settable rate (bypasses cooldown/deviation).
contract MockAccountant_NB2 {
    uint256 public exchangeRate;
    constructor(uint256 initRate) { exchangeRate = initRate; }
    function getRate() external view returns (uint256) { return exchangeRate; }
    function getRateSafe() external view returns (uint256) { return exchangeRate; }
    function setExchangeRate(uint256 r) external { exchangeRate = r; }
}

/// @dev 18-decimal position token (matches real DiGiFT ST token).
contract MockPosToken18_NB is ERC20 {
    constructor() ERC20("ST Token 18", "ST18") {}
    function decimals() public pure override returns (uint8) { return 18; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function burn(address from, uint256 amount) external { _burn(from, amount); }
}

contract MockSettlementVenue_NB {
    MockUSDC_NB public immutable ASSET;
    MockPosToken18_NB public immutable POS_TOKEN;

    mapping(address => uint256) public pendingInvestAsset;
    mapping(address => uint256) public pendingRedeemPos;

    constructor(address asset_, address posToken_) {
        ASSET = MockUSDC_NB(asset_);
        POS_TOKEN = MockPosToken18_NB(posToken_);
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

/// @dev Async adapter with variable posTokenPrice, matching real SubRedManagementAdapter formulas.
///      posToken sits on vault (not adapter) after settlement.
contract MockPricedAdapter_NB is IStrategyAdapter {
    address public immutable ASSET;
    address public immutable POS_TOKEN;
    address public immutable VAULT;
    MockSettlementVenue_NB public immutable SETTLEMENT_VENUE;
    uint256 public posTokenPrice = 1e18;

    constructor(address asset_, address posToken_, address vault_, address settlementVenue_) {
        ASSET = asset_;
        POS_TOKEN = posToken_;
        VAULT = vault_;
        SETTLEMENT_VENUE = MockSettlementVenue_NB(settlementVenue_);
    }

    function name() external pure returns (string memory) { return "MockPricedAdapter"; }
    function asset() external view returns (address) { return ASSET; }
    function posToken() external view returns (address) { return POS_TOKEN; }
    function priceOracle() external pure returns (address) { return address(0); }
    function vault() external view returns (address) { return VAULT; }
    function setPaused(bool) external {}
    function retryRedeemAsync(uint256, address) external {}
    function minSubscribeAsset() external pure returns (uint256) { return 0; }
    function minRedeemPos() external pure returns (uint256) { return 0; }

    /// @dev Real async adapter: controller passes posAmount (already asset→pos), vault pre-approves
    ///      adapter to pull posToken. Mock mirrors this so posToken actually leaves vault for adapter,
    ///      then moves onward to an external settlement venue.
    function requestRedeemAsync(uint256 posAmount, address) external {
        if (posAmount > 0) {
            IERC20(POS_TOKEN).transferFrom(VAULT, address(this), posAmount);
            IERC20(POS_TOKEN).transfer(address(SETTLEMENT_VENUE), posAmount);
            SETTLEMENT_VENUE.acceptRedeem(address(this), posAmount);
        }
    }

    function withdrawSync(uint256, address) external pure returns (uint256) { revert("Unsupported"); }

    function setPosTokenPrice(uint256 p) external { posTokenPrice = p; }
    function getPosTokenPrice() external view returns (uint256) { return posTokenPrice; }

    /// @dev Matches SubRedManagementAdapter._estimatePosAmountInternal
    function estimatePosAmount(uint256 amountAsset) external view returns (uint256) {
        if (amountAsset == 0 || posTokenPrice == 0) return amountAsset;
        uint256 stScale = 10 ** IERC20Metadata(POS_TOKEN).decimals();
        uint256 assetScale = 10 ** IERC20Metadata(ASSET).decimals();
        return Math.mulDiv(amountAsset, 1e18 * stScale, posTokenPrice * assetScale, Math.Rounding.Floor);
    }

    /// @dev Exposes _estimatePosAmount with explicit decimal params (split formula, matches real adapter)
    function estimatePosAmountWithDecimals(uint256 amountAsset, uint8 assetDecimals, uint8 stDecimals)
        external view returns (uint256)
    {
        if (amountAsset == 0 || posTokenPrice == 0) return 0;
        if (stDecimals >= assetDecimals) {
            return Math.mulDiv(amountAsset, 1e18 * (10 ** (stDecimals - assetDecimals)), posTokenPrice, Math.Rounding.Floor);
        }
        return Math.mulDiv(amountAsset, 1e18, posTokenPrice * (10 ** (assetDecimals - stDecimals)), Math.Rounding.Floor);
    }

    /// @dev Exposes _estimateAssetAmount with explicit decimal params and rounding (matches real adapter)
    function estimateAssetAmountWithDecimals(uint256 amountPosRaw, uint8 assetDecimals, uint8 stDecimals, Math.Rounding rounding)
        external view returns (uint256)
    {
        if (amountPosRaw == 0 || posTokenPrice == 0) return 0;
        if (assetDecimals >= stDecimals) {
            return Math.mulDiv(amountPosRaw, posTokenPrice * (10 ** (assetDecimals - stDecimals)), 1e18, rounding);
        }
        return Math.mulDiv(amountPosRaw, posTokenPrice, 1e18 * (10 ** (stDecimals - assetDecimals)), rounding);
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

    /// @dev Matches SubRedManagementAdapter.totalValue: posToken on VAULT * price
    function totalValue() external view returns (uint256) {
        uint256 bal = IERC20(POS_TOKEN).balanceOf(VAULT);
        if (bal == 0) return 0;
        uint256 stScale = 10 ** IERC20Metadata(POS_TOKEN).decimals();
        uint256 assetScale = 10 ** IERC20Metadata(ASSET).decimals();
        return Math.mulDiv(bal, posTokenPrice * assetScale, 1e18 * stScale, Math.Rounding.Floor);
    }

    /// @dev deposit: pull USDC from vault, then forward it to the external settlement venue.
    function deposit(uint256 amountAsset, address) external returns (uint256 posAmount) {
        IERC20(ASSET).transferFrom(VAULT, address(this), amountAsset);
        IERC20(ASSET).transfer(address(SETTLEMENT_VENUE), amountAsset);
        SETTLEMENT_VENUE.acceptInvest(address(this), amountAsset);
        uint256 stScale = 10 ** IERC20Metadata(POS_TOKEN).decimals();
        uint256 assetScale = 10 ** IERC20Metadata(ASSET).decimals();
        posAmount = Math.mulDiv(amountAsset, 1e18 * stScale, posTokenPrice * assetScale, Math.Rounding.Floor);
    }

    function sweepToVault(address token, uint256 amount) external returns (uint256) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 actual = amount > bal ? bal : amount;
        if (actual > 0) IERC20(token).transfer(VAULT, actual);
        return actual;
    }
}

// ===========================================================================
// QA Test: Precision with tricky exchange rates and posToken prices
// ===========================================================================

contract NumericalPrecisionQATest is Test {
    MockUSDC_NB internal usdc;
    MockPosToken18_NB internal posToken18;
    MockSanctionsOracle_NB internal oracle;
    MockAccountant_NB2 internal mockAccountant;
    MantleYieldVault internal vault;
    MantleVaultGateway internal gateway;
    StrategyController internal controller;
    MockSettlementVenue_NB internal settlementVenue;
    MockPricedAdapter_NB internal adapter;
    OperatorExecutor internal executor;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal sanctionSafe = makeAddr("sanctionSafe");
    address internal bot = makeAddr("bot");
    address internal user = makeAddr("user");

    string constant MODULE = unicode"汇率与价格换算精度场景";
    string private _buf;

    function _logCase(string memory id, string memory name_) internal {
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

    function setUp() public {
        vm.warp(100_000);

        usdc = new MockUSDC_NB();
        posToken18 = new MockPosToken18_NB();
        oracle = new MockSanctionsOracle_NB();
        mockAccountant = new MockAccountant_NB2(1e18);

        MantleYieldVault vaultImpl = new MantleYieldVault();
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
                redemptionFeeBps: 0, // zero fee to isolate precision effects
                minRedeemAmount: 0,
                minDepositAmount: 0,
                maxSettlementDeviationBps: 0,
                depositDailyRemaining: type(uint256).max,
                redeemDailyRemaining: type(uint256).max
            }))
        )));

        executor = OperatorExecutor(address(new ERC1967Proxy(
            address(execImpl),
            abi.encodeCall(OperatorExecutor.initialize, (admin, bot))
        )));

        controller = StrategyController(address(new ERC1967Proxy(
            address(ctrlImpl),
            abi.encodeCall(StrategyController.initialize, (
                address(vault), admin, address(executor), admin, 0, 0, 0
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
        vault.setAccountant(address(mockAccountant));
        vault.setGateway(address(gateway));
        vault.setController(address(controller));
        vm.stopPrank();

        settlementVenue = new MockSettlementVenue_NB(address(usdc), address(posToken18));
        adapter = new MockPricedAdapter_NB(address(usdc), address(posToken18), address(vault), address(settlementVenue));
        vm.startPrank(admin);
        controller.registerStrategy(address(adapter), 10_000, 1, true);
        controller.activateStrategy(address(adapter));
        address[] memory ordered = new address[](1);
        ordered[0] = address(adapter);
        controller.setStrategyOrder(ordered);
        vm.stopPrank();

        usdc.mint(user, 100_000_000e6);
        vm.prank(user);
        usdc.approve(address(vault), type(uint256).max);
    }

    // =======================================================================
    // Helper: deposit, rebalance into adapter, and settle (full flow)
    // =======================================================================
    function _depositAndInvestAndSettle(uint256 usdcAmount) internal {
        vm.prank(user);
        gateway.deposit(usdcAmount);

        // Rebalance: USDC -> adapter -> venue, investInFlight recorded
        vm.prank(bot);
        executor.executeRebalance(address(controller));

        uint256 inFlightId = vault.nextInFlightId() - 1;
        (,,, uint256 expectedPos,,,,,) = vault.inFlightRecords(inFlightId);
        _settleInvest(inFlightId, expectedPos, 0);
    }

    function _deliverInvestSettlement(uint256 inFlightId, uint256 posAmount, uint256 refundAsset) internal {
        (,,, uint256 expectedPos, uint256 investAsset,, bool isInvest,,) = vault.inFlightRecords(inFlightId);
        assertTrue(isInvest, "expected invest in-flight");
        settlementVenue.settleInvest(address(adapter), investAsset, expectedPos, posAmount, refundAsset);
    }

    function _settleInvest(uint256 inFlightId, uint256 posAmount, uint256 refundAsset) internal {
        _deliverInvestSettlement(inFlightId, posAmount, refundAsset);
        uint256[] memory ids = new uint256[](1);
        ids[0] = inFlightId;
        uint256[] memory settledPos = new uint256[](1);
        settledPos[0] = posAmount;
        uint256[] memory refunds = new uint256[](1);
        refunds[0] = refundAsset;

        IStrategyControllerExecutor.InvestSettlementInput memory investInput =
            IStrategyControllerExecutor.InvestSettlementInput(ids, settledPos, refunds);
        IStrategyControllerExecutor.RedeemSettlementInput memory redeemInput =
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0));

        vm.prank(bot);
        executor.executeSettleAdapter(address(controller), address(adapter), investInput, redeemInput);
    }

    // =======================================================================
    // 1. Indivisible exchangeRate: shares <-> USDC rounding
    // =======================================================================

    function test_Precision_IndivisibleExchangeRate_ShareConversion() public {
        _logCase(
            "test_Precision_IndivisibleExchangeRate_ShareConversion",
            unicode"exchangeRate = 3（不整除）shares<->USDC 往返舍入验证"
        );

        // rate = 3 means 1 share = 3 wei USDC
        mockAccountant.setExchangeRate(3);

        _step("[Step 1] Deposit 10 wei USDC at rate=3");
        vm.prank(user);
        gateway.deposit(10);

        // shares = assets * 1e18 / rate = 10 * 1e18 / 3 = 3333333333333333333 (Floor)
        uint256 shares = vault.balanceOf(user);
        uint256 expectedShares = Math.mulDiv(10, 1e18, 3, Math.Rounding.Floor);
        _step(string.concat("  shares: ", vm.toString(shares)));
        _step(string.concat("  expected: ", vm.toString(expectedShares)));
        assertEq(shares, expectedShares, "shares = floor(10 * 1e18 / 3)");

        _step("[Step 2] Preview redeem all shares");
        uint256 preview = vault.previewRedeem(shares);
        // assets = shares * rate / 1e18 = 3333333333333333333 * 3 / 1e18 = 9 (Floor)
        uint256 expectedAssets = Math.mulDiv(shares, 3, 1e18, Math.Rounding.Floor);
        _step(string.concat("  previewRedeem: ", vm.toString(preview)));
        _step(string.concat("  expected: ", vm.toString(expectedAssets)));
        assertEq(preview, expectedAssets, "roundtrip loses 1 wei (10 -> 9)");

        _step("[Step 3] Verify roundtrip loss is exactly 1 wei");
        uint256 loss = 10 - preview;
        _step(string.concat("  roundtrip loss: ", vm.toString(loss)));
        assertEq(loss, 1, "indivisible rate causes exactly 1 wei loss");

        _logPass();
    }

    // =======================================================================
    // 2. Near-unity rate: rate = 1e18 + 1 (smallest increment above 1.0)
    // =======================================================================

    function test_Precision_NearUnityRate_MinimalIncrement() public {
        _logCase(
            "test_Precision_NearUnityRate_MinimalIncrement",
            unicode"exchangeRate = 1e18+1（最小增量）share 转换精度"
        );

        uint256 rate = 1e18 + 1;
        mockAccountant.setExchangeRate(rate);

        _step("[Step 1] Deposit 1000 USDC at rate = 1e18 + 1");
        vm.prank(user);
        gateway.deposit(1000e6);

        uint256 shares = vault.balanceOf(user);
        uint256 expectedShares = Math.mulDiv(1000e6, 1e18, rate, Math.Rounding.Floor);
        _step(string.concat("  shares: ", vm.toString(shares)));
        assertEq(shares, expectedShares, "shares correct at near-unity rate");

        _step("[Step 2] Redeem and verify loss <= 1 wei");
        uint256 preview = vault.previewRedeem(shares);
        uint256 expectedAssets = Math.mulDiv(shares, rate, 1e18, Math.Rounding.Floor);
        assertEq(preview, expectedAssets, "preview matches formula");

        uint256 loss = 1000e6 - preview;
        _step(string.concat("  deposit: 1000000000, redeem preview: ", vm.toString(preview)));
        _step(string.concat("  roundtrip loss: ", vm.toString(loss)));
        assertLe(loss, 1, "loss <= 1 wei at near-unity rate");

        _logPass();
    }

    // =======================================================================
    // 3. Prime-number price + cross-decimal: USDC(6) -> ST(18) conversion
    // =======================================================================

    function test_Precision_PrimePrice_CrossDecimalConversion() public {
        _logCase(
            "test_Precision_PrimePrice_CrossDecimalConversion",
            unicode"posTokenPrice = 7e17（质数级价格）USDC(6dec)->ST(18dec) 跨精度换算"
        );

        // price = 0.7e18 means 1 ST = 0.7 USDC
        uint256 price = 7e17;
        adapter.setPosTokenPrice(price);

        uint256 depositAmount = 1000e6; // 1000 USDC

        _step("[Step 1] Deposit 1000 USDC and rebalance");
        _depositAndInvestAndSettle(depositAmount);

        _step("[Step 2] Verify posToken amount on vault");
        uint256 posBalance = posToken18.balanceOf(address(vault));
        // expected: 1000e6 * 1e18 * 1e18 / (7e17 * 1e6) = 1000e6 * 1e36 / 7e23
        uint256 expectedPos = Math.mulDiv(depositAmount, 1e18 * 1e18, price * 1e6, Math.Rounding.Floor);
        _step(string.concat("  posToken balance: ", vm.toString(posBalance)));
        _step(string.concat("  expected:         ", vm.toString(expectedPos)));
        assertEq(posBalance, expectedPos, "posAmount matches estimatePosAmount formula");

        _step("[Step 3] Verify adapter.totalValue() -> USDC conversion");
        uint256 adpValue = adapter.totalValue();
        // reverse: posBalance * price * 1e6 / (1e18 * 1e18)
        uint256 expectedValue = Math.mulDiv(posBalance, price * 1e6, 1e18 * 1e18, Math.Rounding.Floor);
        _step(string.concat("  adapter.totalValue(): ", vm.toString(adpValue)));
        _step(string.concat("  expected:             ", vm.toString(expectedValue)));
        assertEq(adpValue, expectedValue, "totalValue matches reverse formula");

        _step("[Step 4] Verify roundtrip loss (USDC -> pos -> USDC)");
        uint256 roundtripLoss = depositAmount - adpValue;
        _step(string.concat("  roundtrip loss: ", vm.toString(roundtripLoss)));
        // With prime-number price and cross-decimal, loss should be <= 1 wei
        assertLe(roundtripLoss, 1, "roundtrip loss <= 1 wei");

        _logPass();
    }

    // =======================================================================
    // 4. Vault totalAssets two-step Floor vs adapter one-step Floor: diff <= 1
    // =======================================================================

    function test_Precision_TotalAssets_TwoStepVsOneStep_Floor() public {
        _logCase(
            "test_Precision_TotalAssets_TwoStepVsOneStep_Floor",
            unicode"totalAssets 两步 Floor vs adapter 一步 Floor 差值验证"
        );

        // Use a price that causes non-exact division: 100 USDC / 0.3 = 333.33... posTokens
        // (777 / 0.3 = 2590 exact, which hides all rounding — avoid that)
        uint256 price = 3e17;
        adapter.setPosTokenPrice(price);

        uint256 depositAmt = 100e6;
        _step("[Step 1] Deposit 100 USDC (100/0.3 = 333.33... non-exact) and rebalance");
        _depositAndInvestAndSettle(depositAmt);

        uint256 posBalance = posToken18.balanceOf(address(vault));
        _step(string.concat("  posToken on vault: ", vm.toString(posBalance)));
        // posBalance should NOT be exact: 100e6 * 1e36 / (3e17 * 1e6) = 333_333...333 (repeating)
        assertGt(posBalance, 0, "posToken balance must be non-zero");

        _step("[Step 2] Compare vault.totalAssets() vs adapter.totalValue()");
        // vault does: posBalance * price / 1e18 (Floor) * 1e6 / 1e18 (Floor) -- two steps
        uint256 step1 = Math.mulDiv(posBalance, price, 1e18, Math.Rounding.Floor);
        uint256 vaultCalc = Math.mulDiv(step1, 1e6, 1e18, Math.Rounding.Floor);

        // adapter does: posBalance * price * 1e6 / (1e18 * 1e18) (Floor) -- one step
        uint256 adapterCalc = Math.mulDiv(posBalance, price * 1e6, 1e18 * 1e18, Math.Rounding.Floor);

        _step(string.concat("  vault two-step:   ", vm.toString(vaultCalc)));
        _step(string.concat("  adapter one-step: ", vm.toString(adapterCalc)));

        uint256 diff = vaultCalc > adapterCalc ? vaultCalc - adapterCalc : adapterCalc - vaultCalc;
        _step(string.concat("  difference: ", vm.toString(diff)));
        // Note: For the specific formula structure (two Floor divs where second divisor * remainder < first divisor),
        // the two-step and one-step results are mathematically equal for all inputs.
        // We verify this invariant holds and bound it to at most 1 wei for safety.
        assertLe(diff, 1, "two-step vs one-step Floor differs by at most 1 wei");

        _step("[Step 3] Verify vault.totalAssets() equals two-step calc");
        uint256 totalAssets = vault.totalAssets();
        // After settle: physical USDC = 0, investInFlight = 0, totalAssets = vaultCalc (posToken value)
        _step(string.concat("  vault.totalAssets(): ", vm.toString(totalAssets)));
        assertEq(totalAssets, vaultCalc, "totalAssets uses two-step Floor calc");

        _step("[Step 4] Verify roundtrip precision loss from original deposit");
        uint256 gap = depositAmt > totalAssets ? depositAmt - totalAssets : totalAssets - depositAmt;
        _step(string.concat("  gap from original deposit: ", vm.toString(gap)));
        // With non-exact division (100/0.3), truncation causes real precision loss (gap > 0)
        assertGt(gap, 0, "non-exact price division should produce measurable precision loss");
        assertLe(gap, 1, "totalAssets within 1 wei of original deposit");

        _logPass();
    }

    // =======================================================================
    // 5. Combined: ugly exchangeRate + ugly posTokenPrice
    // =======================================================================

    function test_Precision_UglyRate_UglyPrice_FullChain() public {
        _logCase(
            "test_Precision_UglyRate_UglyPrice_FullChain",
            unicode"exchangeRate=1e18+3 + posTokenPrice=3e17 组合全链路精度"
        );

        uint256 rate = 1e18 + 3; // 1.000000000000000003
        uint256 price = 3e17;    // 0.3 USDC per ST
        mockAccountant.setExchangeRate(rate);
        adapter.setPosTokenPrice(price);

        _step("[Step 1] Deposit 5000 USDC at ugly rate");
        vm.prank(user);
        gateway.deposit(5000e6);

        uint256 shares = vault.balanceOf(user);
        uint256 expectedShares = Math.mulDiv(5000e6, 1e18, rate, Math.Rounding.Floor);
        _step(string.concat("  shares: ", vm.toString(shares)));
        assertEq(shares, expectedShares, "shares correct with ugly rate");

        _step("[Step 2] Rebalance and settle with ugly price");
        vm.prank(bot);
        executor.executeRebalance(address(controller));

        uint256 inFlightId = vault.nextInFlightId() - 1;
        (,,, uint256 expectedPos,,,,,) = vault.inFlightRecords(inFlightId);
        _settleInvest(inFlightId, expectedPos, 0);

        uint256 posBalance = posToken18.balanceOf(address(vault));
        _step(string.concat("  posToken balance: ", vm.toString(posBalance)));

        _step("[Step 3] Verify totalAssets consistency");
        uint256 totalAssets = vault.totalAssets();
        _step(string.concat("  totalAssets: ", vm.toString(totalAssets)));
        // totalAssets should be very close to 5000e6
        // Two rounding steps: USDC->posToken (Floor) then posToken->USDC valuation (two Floor divs)
        uint256 gap = 5000e6 > totalAssets ? 5000e6 - totalAssets : totalAssets - 5000e6;
        _step(string.concat("  gap from deposit: ", vm.toString(gap)));
        assertLe(gap, 2, "totalAssets within 2 wei of deposit (two rounding steps)");

        _step("[Step 4] Verify share -> USDC conversion is consistent");
        uint256 redeemPreview = vault.previewRedeem(shares);
        uint256 expectedRedeem = Math.mulDiv(shares, rate, 1e18, Math.Rounding.Floor);
        assertEq(redeemPreview, expectedRedeem, "previewRedeem matches formula");

        uint256 redeemLoss = 5000e6 - redeemPreview;
        _step(string.concat("  redeem preview: ", vm.toString(redeemPreview)));
        _step(string.concat("  deposit-to-redeem loss: ", vm.toString(redeemLoss)));
        assertLe(redeemLoss, 1, "share conversion roundtrip loss <= 1 wei");

        _logPass();
    }

    // =======================================================================
    // 6. Large posTokenPrice: price close to overflow boundary
    // =======================================================================

    function test_Precision_LargePosTokenPrice_NoOverflow() public {
        _logCase(
            "test_Precision_LargePosTokenPrice_NoOverflow",
            unicode"posTokenPrice = 1e30（天价 token）无溢出验证"
        );

        // 1 posToken = 1e30 / 1e18 = 1e12 USDC (1 trillion USDC per token)
        uint256 price = 1e30;
        adapter.setPosTokenPrice(price);

        _step("[Step 1] Deposit 10,000 USDC and rebalance");
        _depositAndInvestAndSettle(10_000e6);

        uint256 posBalance = posToken18.balanceOf(address(vault));
        // posAmount = 10_000e6 * 1e18 * 1e18 / (1e30 * 1e6) = 10_000e6 * 1e36 / 1e36 = 10_000e6
        // = 10_000_000_000 (10 billion pos-token-wei for 10k USDC, since price is huge)
        uint256 expectedPos = Math.mulDiv(10_000e6, 1e18 * 1e18, price * 1e6, Math.Rounding.Floor);
        _step(string.concat("  posBalance: ", vm.toString(posBalance)));
        _step(string.concat("  expected:   ", vm.toString(expectedPos)));
        assertEq(posBalance, expectedPos, "posAmount correct with large price");

        _step("[Step 2] Verify totalValue roundtrip");
        uint256 adpValue = adapter.totalValue();
        _step(string.concat("  adapter.totalValue(): ", vm.toString(adpValue)));
        uint256 roundtripLoss = 10_000e6 - adpValue;
        _step(string.concat("  roundtrip loss: ", vm.toString(roundtripLoss)));
        assertLe(roundtripLoss, 1, "no overflow, roundtrip loss <= 1 wei");

        _step("[Step 3] Verify totalAssets no overflow");
        uint256 ta = vault.totalAssets();
        _step(string.concat("  totalAssets: ", vm.toString(ta)));
        uint256 gap = 10_000e6 > ta ? 10_000e6 - ta : ta - 10_000e6;
        assertLe(gap, 2, "totalAssets within 2 wei");

        _logPass();
    }

    // =======================================================================
    // 7. Tiny posTokenPrice: 1 wei price (1 ST = 1e-18 USDC)
    // =======================================================================

    function test_Precision_TinyPosTokenPrice_MassiveTokenAmount() public {
        _logCase(
            "test_Precision_TinyPosTokenPrice_MassiveTokenAmount",
            unicode"posTokenPrice = 1（1e-18 USDC/ST）极大 posToken 数量验证"
        );

        // price = 1 means 1 ST = 1e-18 USDC = essentially worthless per unit
        // 1 USDC = 1e6 wei, so pos amount = 1e6 * 1e18 * 1e18 / (1 * 1e6) = 1e36
        uint256 price = 1;
        adapter.setPosTokenPrice(price);

        _step("[Step 1] Deposit 1 USDC and rebalance");
        _depositAndInvestAndSettle(1e6);

        uint256 posBalance = posToken18.balanceOf(address(vault));
        uint256 expectedPos = Math.mulDiv(1e6, 1e18 * 1e18, price * 1e6, Math.Rounding.Floor);
        _step(string.concat("  posBalance: ", vm.toString(posBalance)));
        _step(string.concat("  expected:   ", vm.toString(expectedPos)));
        assertEq(posBalance, expectedPos, "massive posToken amount correct");

        _step("[Step 2] Verify totalValue roundtrip (no precision loss at tiny price)");
        uint256 adpValue = adapter.totalValue();
        _step(string.concat("  adapter.totalValue(): ", vm.toString(adpValue)));
        // At price=1: totalValue = posBalance * 1 * 1e6 / (1e18 * 1e18)
        // = 1e36 * 1e6 / 1e36 = 1e6 exactly
        assertEq(adpValue, 1e6, "roundtrip exact at price=1");

        _step("[Step 3] totalAssets consistent");
        uint256 ta = vault.totalAssets();
        _step(string.concat("  totalAssets: ", vm.toString(ta)));
        assertEq(ta, 1e6, "totalAssets equals deposit");

        _logPass();
    }

    // =======================================================================
    // 8. N-33: High-decimal stToken (18) + low-decimal asset (6): _estimatePosAmount no overflow
    // =======================================================================

    function test_Precision_HighStDecimals_LowAssetDecimals_NoPosOverflow() public {
        _logCase(
            "test_Precision_HighStDecimals_LowAssetDecimals_NoPosOverflow",
            unicode"高精度 stToken（stDecimals=18）与低精度 asset（assetDecimals=6）时 `_estimatePosAmountInternal` 不溢出"
        );

        // Setup: posTokenPrice=2e18 (1 ST = 2 USDC)
        uint256 price = 2e18;
        adapter.setPosTokenPrice(price);

        _step("[Step 1] Call estimatePosAmountWithDecimals(1e12, 6, 18) -- stDecimals >= assetDecimals branch");
        // Real adapter formula (split): Math.mulDiv(1e12, 1e18 * 10^(18-6), 2e18)
        //   = Math.mulDiv(1e12, 1e18 * 1e12, 2e18) = Math.mulDiv(1e12, 1e30, 2e18) = 5e23
        uint256 posAmount = adapter.estimatePosAmountWithDecimals(1e12, 6, 18);
        uint256 expected = Math.mulDiv(1e12, 1e18 * (10 ** 12), price, Math.Rounding.Floor);
        _step(string.concat("  posAmount: ", vm.toString(posAmount)));
        _step(string.concat("  expected:  ", vm.toString(expected)));
        assertEq(posAmount, expected, "split formula result matches");
        assertEq(posAmount, 5e23, "= 500000e18 posToken (5e23)");

        _step("[Step 2] Verify same result via full-chain deposit (existing USDC(6)->ST(18) setup)");
        _depositAndInvestAndSettle(1e12); // 1,000,000 USDC
        uint256 posBalance = posToken18.balanceOf(address(vault));
        _step(string.concat("  posBalance on vault: ", vm.toString(posBalance)));
        assertEq(posBalance, expected, "full-chain deposit matches formula");

        _step("[Step 3] Verify old formula (combined) gives same result (Math.mulDiv handles large intermediates)");
        // Old formula: Math.mulDiv(1e12, 1e18 * 1e18, 2e18 * 1e6) = Math.mulDiv(1e12, 1e36, 2e24)
        uint256 oldResult = Math.mulDiv(1e12, 1e18 * 1e18, price * 1e6, Math.Rounding.Floor);
        assertEq(oldResult, posAmount, "old and new formulas agree");
        _step("  PASS: no overflow, split formula produces correct 5e23");

        _logPass();
    }

    // =======================================================================
    // 9. N-34: Low-decimal stToken (6) + high-decimal asset (18): _estimateAssetAmount no overflow
    // =======================================================================

    function test_Precision_LowStDecimals_HighAssetDecimals_NoAssetOverflow() public {
        _logCase(
            "test_Precision_LowStDecimals_HighAssetDecimals_NoAssetOverflow",
            unicode"低精度 stToken（stDecimals=6）与高精度 asset（assetDecimals=18）时 `_estimateAssetAmount` 不溢出"
        );

        // Setup: posTokenPrice=2e18 (1 ST = 2 asset-units)
        uint256 price = 2e18;
        adapter.setPosTokenPrice(price);

        _step("[Step 1] Call estimateAssetAmountWithDecimals(1e12, 18, 6, Floor) -- assetDecimals >= stDecimals branch");
        // Real adapter formula (split): Math.mulDiv(1e12, 2e18 * 10^(18-6), 1e18)
        //   = Math.mulDiv(1e12, 2e18 * 1e12, 1e18) = Math.mulDiv(1e12, 2e30, 1e18) = 2e24
        uint256 assetAmount = adapter.estimateAssetAmountWithDecimals(1e12, 18, 6, Math.Rounding.Floor);
        uint256 expected = Math.mulDiv(1e12, price * (10 ** 12), 1e18, Math.Rounding.Floor);
        _step(string.concat("  assetAmount: ", vm.toString(assetAmount)));
        _step(string.concat("  expected:    ", vm.toString(expected)));
        assertEq(assetAmount, expected, "split formula result matches");
        assertEq(assetAmount, 2e24, "= 2e24 (correct reverse conversion)");

        _step("[Step 2] Verify roundtrip: pos->asset->pos preserves direction");
        // Convert back: assetAmount -> posAmount with (assetDec=18, stDec=6)
        uint256 roundtripPos = adapter.estimatePosAmountWithDecimals(assetAmount, 18, 6);
        // Expected: Math.mulDiv(2e24, 1e18, 2e18 * 1e12) = Math.mulDiv(2e24, 1e18, 2e30) = 1e12
        _step(string.concat("  roundtrip posAmount: ", vm.toString(roundtripPos)));
        assertEq(roundtripPos, 1e12, "roundtrip pos->asset->pos is lossless");
        _step("  PASS: no overflow, split formula produces correct 2e24");

        _logPass();
    }

    // =======================================================================
    // 10. N-35: _estimateAssetAmount Ceil rounding support
    // =======================================================================

    function test_Precision_EstimateAssetAmount_CeilRounding() public {
        _logCase(
            "test_Precision_EstimateAssetAmount_CeilRounding",
            unicode"`_estimateAssetAmount` 新增 Rounding 参数支持 Ceil rounding"
        );

        // Use a price that causes indivisible conversion: price=3e18 (1 ST = 3 asset-units)
        // With assetDecimals=6, stDecimals=18:
        //   assetAmount = posAmount * 3e18 / (1e18 * 1e12) -- stDecimals > assetDecimals branch
        // Choose posAmount that doesn't divide evenly
        uint256 price = 3e18;
        adapter.setPosTokenPrice(price);

        // posAmount = 1e18 + 1 (one extra wei to force non-exact division)
        uint256 posAmount = 1e18 + 1;

        _step("[Step 1] Compare Floor vs Ceil rounding for estimateAssetAmount");
        // Using existing setup decimals: assetDecimals=6, stDecimals=18
        uint256 floorResult = adapter.estimateAssetAmountWithDecimals(posAmount, 6, 18, Math.Rounding.Floor);
        uint256 ceilResult = adapter.estimateAssetAmountWithDecimals(posAmount, 6, 18, Math.Rounding.Ceil);
        _step(string.concat("  posAmount:    ", vm.toString(posAmount)));
        _step(string.concat("  Floor result: ", vm.toString(floorResult)));
        _step(string.concat("  Ceil result:  ", vm.toString(ceilResult)));

        assertGe(ceilResult, floorResult, "Ceil >= Floor always");

        _step("[Step 2] Verify Ceil result differs from Floor (non-exact division)");
        // stDecimals(18) > assetDecimals(6) branch: mulDiv(posAmount, price, 1e18 * 1e12)
        // = mulDiv(1e18+1, 3e18, 1e30)
        // Floor: (1e18+1) * 3e18 / 1e30 = (3e36 + 3e18) / 1e30 = 3e6 + 3e-12 -> Floor = 3e6
        // Ceil: rounds up -> 3e6 + 1
        uint256 expectedFloor = Math.mulDiv(posAmount, price, 1e18 * 1e12, Math.Rounding.Floor);
        uint256 expectedCeil = Math.mulDiv(posAmount, price, 1e18 * 1e12, Math.Rounding.Ceil);
        assertEq(floorResult, expectedFloor, "Floor matches manual calc");
        assertEq(ceilResult, expectedCeil, "Ceil matches manual calc");
        assertGt(ceilResult, floorResult, "Ceil > Floor for non-exact division");
        _step(string.concat("  difference: ", vm.toString(ceilResult - floorResult)));

        _step("[Step 3] Verify Ceil ensures direction safety: ceilAsset * 1e18 / price covers posAmount");
        // The Ceil guarantee: using ceilResult as executableAssetAmount, converting back to pos
        // should be >= posAmount (ensures the adapter receives enough asset)
        // backPos = ceilResult * 1e18 * 1e12 / price (Floor)
        uint256 backPos = Math.mulDiv(ceilResult, 1e18 * 1e12, price, Math.Rounding.Floor);
        _step(string.concat("  backPos from Ceil: ", vm.toString(backPos)));
        assertGe(backPos, posAmount, "Ceil ensures sufficient asset coverage");

        // Floor does NOT guarantee this
        uint256 backPosFloor = Math.mulDiv(floorResult, 1e18 * 1e12, price, Math.Rounding.Floor);
        _step(string.concat("  backPos from Floor: ", vm.toString(backPosFloor)));
        assertLt(backPosFloor, posAmount, "Floor under-covers posAmount (expected)");
        _step("  PASS: Ceil rounding ensures executableAssetAmount covers posAmount");

        _logPass();
    }
}
