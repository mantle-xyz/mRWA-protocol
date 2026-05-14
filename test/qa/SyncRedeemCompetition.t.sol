// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Accountant} from "../../src/accountant/Accountant.sol";
import {SanctionsOracle} from "../../src/compliance/SanctionsOracle.sol";
import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {IMantleVaultGateway} from "../../src/interfaces/vault/IMantleVaultGateway.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {IStrategyAdapter} from "../../src/interfaces/adapters/IStrategyAdapter.sol";
import {MantleVaultGateway} from "../../src/vault/MantleVaultGateway.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {OperatorExecutor} from "../../src/protocol/OperatorExecutor.sol";
import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Test, console2} from "forge-std/Test.sol";

// ---------------------------------------------------------------------------
// Mock contracts
// ---------------------------------------------------------------------------

contract MockUSDC_SRC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockPosToken_SRC is ERC20 {
    constructor() ERC20("MockPosToken", "mPOS") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Mock adapter that transfers real tokens.
///      - deposit(): pulls USDC from vault, mints posTokens (simulates external protocol).
///      - sweepToVault(): transfers any token from adapter to vault.
///      - totalValue(): returns real USDC balance held by this adapter.
///      - withdrawSync(): reports available USDC (already held from prior deposit).
contract MockStrategyAdapter_SRC is IStrategyAdapter {
    address public immutable ASSET;
    address public immutable POS_TOKEN;
    address public immutable VAULT;

    constructor(address asset_, address posToken_, address vault_) {
        ASSET = asset_;
        POS_TOKEN = posToken_;
        VAULT = vault_;
    }

    function name() external pure returns (string memory) { return "MockStrategyAdapter"; }
    function asset() external view returns (address) { return ASSET; }
    function posToken() external view returns (address) { return POS_TOKEN; }
    function priceOracle() external pure returns (address) { return address(0); }
    function getPosTokenPrice() external pure returns (uint256) { return 1e18; }
    function estimatePosAmount(uint256 assetAmount) external pure returns (uint256) { return assetAmount; }
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
    function vault() external view returns (address) { return VAULT; }

    function totalValue() external view returns (uint256) {
        return IERC20(ASSET).balanceOf(address(this));
    }

    function deposit(uint256 amount, address) external returns (uint256) {
        IERC20(ASSET).transferFrom(VAULT, address(this), amount);
        MockPosToken_SRC(POS_TOKEN).mint(address(this), amount);
        return amount;
    }

    function withdrawSync(uint256 amount, address) external returns (uint256) {
        uint256 bal = IERC20(ASSET).balanceOf(address(this));
        return amount > bal ? bal : amount;
    }

    function requestRedeemAsync(uint256, address) external {}

    function sweepToVault(address token, uint256 amount) external returns (uint256) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 actual = amount > bal ? bal : amount;
        if (actual > 0) IERC20(token).transfer(VAULT, actual);
        return actual;
    }

    function setPaused(bool) external {}
    function retryRedeemAsync(uint256, address) external {}
}

// ---------------------------------------------------------------------------
// QA Test: Sync Redeem Competition Scenarios
// ---------------------------------------------------------------------------

contract SyncRedeemCompetitionQATest is Test {
    MockUSDC_SRC internal usdc;
    MockPosToken_SRC internal posToken;
    SanctionsOracle internal oracle;
    MantleYieldVault internal vault;
    MantleVaultGateway internal gateway;
    Accountant internal accountant;
    StrategyController internal controller;
    MockStrategyAdapter_SRC internal adapter;
    OperatorExecutor internal executor;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal sanctionSafe = makeAddr("sanctionSafe");
    address internal bot = makeAddr("bot");
    address internal userA = makeAddr("userA");
    address internal userB = makeAddr("userB");
    address internal whale = makeAddr("whale");
    address internal retail = makeAddr("retail");
    address internal user1 = makeAddr("user1");
    address internal user2 = makeAddr("user2");
    address internal user3 = makeAddr("user3");

    uint256 constant FEE_BPS = 100; // 1%
    uint256 constant BPS = 10_000;

    /// @dev ERC4626 standard error emitted by vault when shares > maxRedeem.
    bytes4 private constant ERC4626_EXCEEDED_MAX_REDEEM =
        bytes4(keccak256("ERC4626ExceededMaxRedeem(address,uint256,uint256)"));

    // -----------------------------------------------------------------------
    // Logging helpers
    // -----------------------------------------------------------------------

    string constant MODULE =
        unicode"业务博弈、汇率波动、抢赎、排队公平性与极端流动性场景";
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
    // setUp
    // -----------------------------------------------------------------------

    function setUp() public {
        vm.warp(1000);

        usdc = new MockUSDC_SRC();
        posToken = new MockPosToken_SRC();
        SanctionsOracle oracleImpl = new SanctionsOracle();
        oracle = SanctionsOracle(address(new ERC1967Proxy(
            address(oracleImpl),
            abi.encodeCall(SanctionsOracle.initialize, (admin, admin))
        )));

        MantleYieldVault vaultImpl = new MantleYieldVault();
        Accountant acctImpl = new Accountant();
        MantleVaultGateway gwImpl = new MantleVaultGateway();
        StrategyController ctrlImpl = new StrategyController();
        OperatorExecutor execImpl = new OperatorExecutor();

        // Vault (placeholders wired below)
        bytes memory vaultInitData = abi.encodeCall(
            MantleYieldVault.initialize,
            IMantleYieldVault.InitParams({
                asset: IERC20(address(usdc)),
                name: "mRWA Vault",
                symbol: "mRWA",
                admin: admin,
                gateway: address(1),
                controller: admin,
                accountant: address(1),
                treasury: treasury,
                maxRedemptionFeeBps: 500,
                redemptionFeeBps: FEE_BPS,
                minRedeemAmount: 0,
                minDepositAmount: 0,
                maxSettlementDeviationBps: 0,
                depositDailyRemaining: type(uint256).max,
                redeemDailyRemaining: type(uint256).max
            })
        );
        vault = MantleYieldVault(address(new ERC1967Proxy(address(vaultImpl), vaultInitData)));

        // Accountant (0 management fee for simpler math)
        bytes memory acctInitData =
            abi.encodeCall(Accountant.initialize, (address(vault), 1e18, 0, admin, admin, admin));
        accountant = Accountant(address(new ERC1967Proxy(address(acctImpl), acctInitData)));

        // OperatorExecutor (real contract with bot role)
        bytes memory execInitData =
            abi.encodeCall(OperatorExecutor.initialize, (admin, bot));
        executor = OperatorExecutor(address(new ERC1967Proxy(address(execImpl), execInitData)));

        // Controller (points to real executor)
        bytes memory ctrlInitData = abi.encodeCall(
            StrategyController.initialize,
            (address(vault), admin, address(executor), admin, 1000, 200, 0)
        );
        controller = StrategyController(address(new ERC1967Proxy(address(ctrlImpl), ctrlInitData)));

        // Gateway
        bytes memory gwInitData = abi.encodeCall(
            MantleVaultGateway.initialize,
            IMantleVaultGateway.InitParams({
                vault: address(vault),
                sanctionsOracle: ISanctionsOracle(address(oracle)),
                sanctionSafe: sanctionSafe,
                admin: admin,
                syncRedeemDisabled: false
            })
        );
        gateway = MantleVaultGateway(address(new ERC1967Proxy(address(gwImpl), gwInitData)));

        // Wire up vault
        vm.startPrank(admin);
        vault.setAccountant(address(accountant));
        vault.setGateway(address(gateway));
        vault.setController(address(controller));
        vm.stopPrank();

        // Register adapter (real tokens, vault-aware)
        adapter = new MockStrategyAdapter_SRC(address(usdc), address(posToken), address(vault));
        vm.startPrank(admin);
        controller.registerStrategy(address(adapter), 10_000, 1, false);
        controller.activateStrategy(address(adapter));
        address[] memory ordered = new address[](1);
        ordered[0] = address(adapter);
        controller.setStrategyOrder(ordered);
        vm.stopPrank();

        // Fund users
        address[7] memory users = [userA, userB, whale, retail, user1, user2, user3];
        for (uint256 i = 0; i < users.length; i++) {
            usdc.mint(users[i], 1_000_000e6);
            vm.prank(users[i]);
            usdc.approve(address(vault), type(uint256).max);
        }
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    function _depositForUser(address user, uint256 amount) internal {
        vm.prank(user);
        gateway.deposit(amount);
    }

    /// @dev Reduce freeCash by investing excess into adapter via real rebalance.
    ///      Sets bufferTargetBps so that targetCash ~ targetFreeCash, then executes
    ///      bot -> executor -> controller.rebalance().
    function _investViaRebalance(uint256 targetFreeCash) internal {
        uint256 total = usdc.balanceOf(address(vault));
        require(total > 0, "vault has no USDC");
        require(targetFreeCash <= total, "targetFreeCash exceeds vault balance");
        uint16 bufferBps = uint16((targetFreeCash * BPS) / total);
        if (uint256(bufferBps) * total / BPS < targetFreeCash) bufferBps += 1;

        vm.prank(admin);
        controller.setRiskParams(bufferBps, 0, 0);

        vm.prank(bot);
        executor.executeRebalance(address(controller));
    }

    // =======================================================================
    // 1. 两个用户同时同步赎回, freeCash仅够一人
    // =======================================================================

    function test_TwoUsersSyncRedeem_FreeCashForOne() public {
        _logCase(
            "test_TwoUsersSyncRedeem_FreeCashForOne",
            unicode"两个用户同时同步赎回，freeCash 仅够一人，验证先来先得"
        );

        _step("[Step 1] Both users deposit 1000 USDC each");
        _depositForUser(userA, 1000e6);
        _depositForUser(userB, 1000e6);
        uint256 sharesA = vault.balanceOf(userA);
        uint256 sharesB = vault.balanceOf(userB);
        assertEq(sharesA, sharesB, "equal shares");
        _step(string.concat("  each has shares: ", vm.toString(sharesA)));

        _step("[Step 2] Invest to leave freeCash ~ 1000 (enough for one, not two)");
        _investViaRebalance(1000e6);
        uint256 fc = vault.getFreeCash();
        _step(string.concat("  freeCash: ", vm.toString(fc)));

        _step("[Step 3] userA redeems first - should succeed");
        vm.prank(userA);
        uint256 assetsA = gateway.redeem(sharesA);
        assertGt(assetsA, 0, "userA should succeed");
        _step(string.concat("  userA received: ", vm.toString(assetsA)));

        _step("[Step 4] userB tries to redeem - should fail");
        uint256 maxRedeemB = vault.maxRedeem(userB);
        _step(string.concat("  maxRedeem(userB): ", vm.toString(maxRedeemB)));
        assertLt(maxRedeemB, sharesB, "maxRedeem should be less than total shares");

        vm.prank(userB);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626_EXCEEDED_MAX_REDEEM, userB, sharesB, maxRedeemB)
        );
        gateway.redeem(sharesB);
        _step("  userB full redeem: reverted (insufficient freeCash)");

        _logPass();
    }

    // =======================================================================
    // 2. 大户先赎导致小户后续同步赎回失败
    // =======================================================================

    function test_WhaleRedeemBlocksRetail() public {
        _logCase(
            "test_WhaleRedeemBlocksRetail",
            unicode"大户先赎导致小户后续同步赎回失败"
        );

        _step("[Step 1] Whale deposits 5000 USDC, retail deposits 500 USDC");
        _depositForUser(whale, 5000e6);
        _depositForUser(retail, 500e6);

        _step("[Step 2] Invest to leave freeCash ~ 5100 (covers whale, not both)");
        _investViaRebalance(5100e6);
        uint256 fc = vault.getFreeCash();
        _step(string.concat("  freeCash: ", vm.toString(fc)));

        _step("[Step 3] Whale redeems first");
        uint256 whaleShares = vault.balanceOf(whale);
        vm.prank(whale);
        uint256 whaleAssets = gateway.redeem(whaleShares);
        _step(string.concat("  whale received: ", vm.toString(whaleAssets)));

        _step("[Step 4] Retail tries to redeem - should fail");
        uint256 retailShares = vault.balanceOf(retail);
        uint256 fcAfter = vault.getFreeCash();
        uint256 maxRedeemRetail = vault.maxRedeem(retail);
        _step(string.concat("  freeCash after whale: ", vm.toString(fcAfter)));
        _step(string.concat("  maxRedeem(retail): ", vm.toString(maxRedeemRetail)));
        assertLt(maxRedeemRetail, retailShares, "retail cannot fully redeem");

        vm.prank(retail);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626_EXCEEDED_MAX_REDEEM, retail, retailShares, maxRedeemRetail)
        );
        gateway.redeem(retailShares);
        _step("  retail full redeem: reverted");

        _logPass();
    }

    // =======================================================================
    // 3. 小户先赎、大户后赎时的freeCash分布
    // =======================================================================

    function test_RetailFirstThenWhale() public {
        _logCase(
            "test_RetailFirstThenWhale",
            unicode"小户先赎、大户后赎时，验证剩余 freeCash 分布结果"
        );

        _step("[Step 1] Retail deposits 500, whale deposits 5000");
        _depositForUser(retail, 500e6);
        _depositForUser(whale, 5000e6);

        _step("[Step 2] Invest to leave freeCash ~ 3000");
        _investViaRebalance(3000e6);
        uint256 fc0 = vault.getFreeCash();
        _step(string.concat("  freeCash: ", vm.toString(fc0)));

        _step("[Step 3] Retail redeems first - succeeds");
        uint256 retailShares = vault.balanceOf(retail);
        uint256 retailPreview = vault.previewRedeem(retailShares);
        vm.prank(retail);
        uint256 retailAssets = gateway.redeem(retailShares);
        assertGt(retailAssets, 0, "retail should succeed");
        assertEq(retailAssets, retailPreview, "retail gets exact previewRedeem amount");
        _step(string.concat("  retail received: ", vm.toString(retailAssets)));

        uint256 fcAfter = vault.getFreeCash();
        _step(string.concat("  freeCash after retail: ", vm.toString(fcAfter)));
        assertEq(fcAfter, fc0 - retailAssets, "freeCash decreased by exact redeem amount");

        _step("[Step 4] Whale tries full redeem - should fail");
        uint256 whaleShares = vault.balanceOf(whale);
        uint256 maxRedeemWhale = vault.maxRedeem(whale);
        _step(string.concat("  whale shares: ", vm.toString(whaleShares)));
        _step(string.concat("  maxRedeem(whale): ", vm.toString(maxRedeemWhale)));
        assertLt(maxRedeemWhale, whaleShares, "whale cannot fully redeem");

        vm.prank(whale);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626_EXCEEDED_MAX_REDEEM, whale, whaleShares, maxRedeemWhale)
        );
        gateway.redeem(whaleShares);
        _step("  whale full redeem: reverted (insufficient freeCash)");

        _step("[Step 5] Whale can partially redeem up to maxRedeem");
        uint256 whaleBalBefore = usdc.balanceOf(whale);
        vm.prank(whale);
        uint256 partialAssets = gateway.redeem(maxRedeemWhale);
        assertGt(partialAssets, 0, "whale partial redeem should succeed");
        assertEq(usdc.balanceOf(whale) - whaleBalBefore, partialAssets, "whale received exact amount");
        _step(string.concat("  whale partial redeemed: ", vm.toString(maxRedeemWhale), " shares -> ", vm.toString(partialAssets), " assets"));

        uint256 fcFinal = vault.getFreeCash();
        _step(string.concat("  freeCash final: ", vm.toString(fcFinal)));
        _step("  [Finding] Small user redeems first, large user can only partially redeem remaining freeCash");

        _logPass();
    }

    // =======================================================================
    // 4. 连续同步赎回逐步压缩 maxRedeem/maxWithdraw
    // =======================================================================

    function test_SequentialRedeemCompressesMaxRedeem() public {
        _logCase(
            "test_SequentialRedeemCompressesMaxRedeem",
            unicode"连续同步赎回会逐步压缩 maxRedeem/maxWithdraw"
        );

        _step("[Step 1] Three users deposit");
        _depositForUser(user1, 1000e6);
        _depositForUser(user2, 1000e6);
        _depositForUser(user3, 1000e6);

        _step("[Step 2] Invest to leave freeCash ~ 2500");
        _investViaRebalance(2500e6);
        _step(string.concat("  freeCash: ", vm.toString(vault.getFreeCash())));

        _step("[Step 3] Record initial maxRedeem/maxWithdraw for each user");
        uint256 mr1 = vault.maxRedeem(user1);
        uint256 mw1 = vault.maxWithdraw(user1);
        _step(string.concat("  maxRedeem(user1): ", vm.toString(mr1)));
        _step(string.concat("  maxWithdraw(user1): ", vm.toString(mw1)));

        _step("[Step 4] user1 redeems");
        vm.prank(user1);
        gateway.redeem(mr1);
        _step(string.concat("  freeCash after user1: ", vm.toString(vault.getFreeCash())));

        uint256 mr2 = vault.maxRedeem(user2);
        uint256 mw2 = vault.maxWithdraw(user2);
        _step(string.concat("  maxRedeem(user2) after user1 redeem: ", vm.toString(mr2)));
        _step(string.concat("  maxWithdraw(user2) after user1 redeem: ", vm.toString(mw2)));
        assertLe(mr2, mr1, "maxRedeem should decrease or stay same");

        _step("[Step 5] user2 redeems");
        vm.prank(user2);
        gateway.redeem(mr2);
        _step(string.concat("  freeCash after user2: ", vm.toString(vault.getFreeCash())));

        uint256 mr3 = vault.maxRedeem(user3);
        uint256 mw3 = vault.maxWithdraw(user3);
        _step(string.concat("  maxRedeem(user3) after user1+user2 redeem: ", vm.toString(mr3)));
        _step(string.concat("  maxWithdraw(user3) after user1+user2 redeem: ", vm.toString(mw3)));
        assertLe(mr3, mr2, "maxRedeem continues to decrease");

        _step("  [Finding] Each successive sync redeem reduces available quota for remaining users");

        _logPass();
    }

    // =======================================================================
    // 5. 前序同步赎回抽干freeCash后后续用户只能转异步
    // =======================================================================

    function test_FreeCashExhaustedFallbackToAsync() public {
        _logCase(
            "test_FreeCashExhaustedFallbackToAsync",
            unicode"前序同步赎回抽干 freeCash 后，后续用户只能转异步赎回"
        );

        _step("[Step 1] Users deposit");
        _depositForUser(user1, 1000e6);
        _depositForUser(user2, 1000e6);
        _depositForUser(user3, 1000e6);

        _step("[Step 2] Invest to leave tight freeCash (enough for ~1 user)");
        _investViaRebalance(1000e6);
        _step(string.concat("  freeCash: ", vm.toString(vault.getFreeCash())));

        _step("[Step 3] user1 sync redeems successfully");
        uint256 maxR1 = vault.maxRedeem(user1);
        vm.prank(user1);
        gateway.redeem(maxR1);
        _step(string.concat("  user1 redeemed. freeCash: ", vm.toString(vault.getFreeCash())));

        _step("[Step 4] user2 tries sync redeem - fails");
        uint256 shares2 = vault.balanceOf(user2);
        uint256 maxR2 = vault.maxRedeem(user2);
        _step(string.concat("  maxRedeem(user2): ", vm.toString(maxR2)));
        // user2 should not be able to fully sync redeem (freeCash exhausted by user1)
        assertTrue(maxR2 < shares2, "precondition: maxRedeem(user2) < shares2 (freeCash exhausted)");

        if (maxR2 == 0) {
            _step("  user2 cannot sync redeem at all (maxRedeem = 0)");
        } else if (maxR2 < shares2) {
            vm.prank(user2);
            vm.expectRevert(
                abi.encodeWithSelector(ERC4626_EXCEEDED_MAX_REDEEM, user2, shares2, maxR2)
            );
            gateway.redeem(shares2);
            _step("  user2 full sync redeem: reverted");
        }

        _step("[Step 5] user2 and user3 fall back to async redeem - succeeds");
        vm.prank(user2);
        uint256 reqId2 = gateway.requestRedeem(shares2);
        assertGt(reqId2, 0, "async request should succeed for user2");
        _step(string.concat("  user2 async reqId: ", vm.toString(reqId2)));

        uint256 shares3 = vault.balanceOf(user3);
        vm.prank(user3);
        uint256 reqId3 = gateway.requestRedeem(shares3);
        assertGt(reqId3, 0, "async request should succeed for user3");
        _step(string.concat("  user3 async reqId: ", vm.toString(reqId3)));

        _logPass();
    }

    // =======================================================================
    // 6. 多用户同时同步+异步赎回，系统账本保持一致
    // =======================================================================

    function test_MixedSyncAsyncBookConsistency() public {
        _logCase(
            "test_MixedSyncAsyncBookConsistency",
            unicode"多用户在同一轮市场恐慌中同时发起同步赎回与异步赎回，系统账本保持一致"
        );

        _step("[Step 1] Users deposit");
        _depositForUser(user1, 2000e6);
        _depositForUser(user2, 2000e6);
        _depositForUser(user3, 2000e6);

        uint256 totalSupplyBefore = vault.totalSupply();
        _step(string.concat("  totalSupply: ", vm.toString(totalSupplyBefore)));

        _step("[Step 2] Invest to leave limited freeCash for partial sync coverage");
        _investViaRebalance(2500e6);
        _step(string.concat("  freeCash: ", vm.toString(vault.getFreeCash())));

        _step("[Step 3] user1 does sync redeem");
        uint256 maxR1 = vault.maxRedeem(user1);
        vm.prank(user1);
        uint256 assets1 = gateway.redeem(maxR1);
        _step(string.concat("  user1 sync redeemed shares: ", vm.toString(maxR1), ", assets: ", vm.toString(assets1)));

        _step("[Step 4] user2 does async redeem");
        uint256 shares2 = vault.balanceOf(user2);
        vm.prank(user2);
        uint256 reqId2 = gateway.requestRedeem(shares2);
        _step(string.concat("  user2 async request, reqId: ", vm.toString(reqId2)));

        _step("[Step 5] user3 does partial sync + async");
        uint256 maxR3 = vault.maxRedeem(user3);
        if (maxR3 > 0) {
            vm.prank(user3);
            gateway.redeem(maxR3);
            _step(string.concat("  user3 sync redeemed: ", vm.toString(maxR3)));
        }
        uint256 remaining3 = vault.balanceOf(user3);
        if (remaining3 > 0) {
            vm.prank(user3);
            gateway.requestRedeem(remaining3);
            _step(string.concat("  user3 async for remaining: ", vm.toString(remaining3)));
        }

        _step("[Step 6] Check account book consistency");
        uint256 totalSupplyAfter = vault.totalSupply();
        uint256 totalLocked = vault.totalLockedShares();
        uint256 physicalBal = usdc.balanceOf(address(vault));
        uint256 freeCash = vault.getFreeCash();

        _step(string.concat("  totalSupply: ", vm.toString(totalSupplyAfter)));
        _step(string.concat("  totalLockedShares: ", vm.toString(totalLocked)));
        _step(string.concat("  physicalBalance: ", vm.toString(physicalBal)));
        _step(string.concat("  freeCash: ", vm.toString(freeCash)));

        uint256 freeSharesUser1 = vault.balanceOf(user1);
        uint256 freeSharesUser2 = vault.balanceOf(user2);
        uint256 freeSharesUser3 = vault.balanceOf(user3);
        uint256 freeSharesTreasury = vault.balanceOf(treasury);
        uint256 sumBalances = freeSharesUser1 + freeSharesUser2 + freeSharesUser3 + freeSharesTreasury;
        assertEq(totalSupplyAfter, sumBalances, "totalSupply = sum of all balances");
        assertGt(totalLocked, 0, "should have locked shares from async redeems");

        // freeCash invariant: freeCash = physicalBalance - ceil(totalLockedShares * rate / 1e18)
        uint256 rate = vault.exchangeRate();
        uint256 lockedAssetsCeil = (totalLocked * rate + 1e18 - 1) / 1e18;
        uint256 expectedFreeCash = physicalBal > lockedAssetsCeil ? physicalBal - lockedAssetsCeil : 0;
        assertEq(freeCash, expectedFreeCash, "freeCash = physicalBalance - lockedAssetsValue");

        // physicalBalance must cover locked obligations
        assertGe(physicalBal, freeCash, "physicalBalance >= freeCash");

        _step("  Account book self-consistent: no duplicate deductions");

        _logPass();
    }

    // =======================================================================
    // 7. 同一用户先同步赎回部分再异步赎回剩余
    // =======================================================================

    function test_SameUserPartialSyncThenAsync() public {
        _logCase(
            "test_SameUserPartialSyncThenAsync",
            unicode"同一用户先同步赎回部分份额，再异步赎回剩余份额，验证口径一致"
        );

        _step("[Step 1] userA deposits 5000 USDC");
        _depositForUser(userA, 5000e6);
        uint256 totalShares = vault.balanceOf(userA);
        _step(string.concat("  userA shares: ", vm.toString(totalShares)));

        _step("[Step 2] Invest to leave freeCash ~ 2000");
        _investViaRebalance(2000e6);
        _step(string.concat("  freeCash: ", vm.toString(vault.getFreeCash())));

        _step("[Step 3] userA sync redeems what's available");
        uint256 maxR = vault.maxRedeem(userA);
        _step(string.concat("  maxRedeem(userA): ", vm.toString(maxR)));
        assertGt(maxR, 0, "should be able to redeem something");
        assertLt(maxR, totalShares, "cannot redeem all");

        vm.prank(userA);
        uint256 syncAssets = gateway.redeem(maxR);
        _step(string.concat("  sync redeemed shares: ", vm.toString(maxR), ", assets: ", vm.toString(syncAssets)));

        _step("[Step 4] userA async redeems remaining");
        uint256 remaining = vault.balanceOf(userA);
        _step(string.concat("  remaining shares: ", vm.toString(remaining)));
        assertGt(remaining, 0, "should have remaining shares");

        vm.prank(userA);
        uint256 reqId = gateway.requestRedeem(remaining);
        _step(string.concat("  async reqId: ", vm.toString(reqId)));

        _step("[Step 5] Verify shares and locked state");
        assertEq(vault.balanceOf(userA), 0, "userA should have 0 free shares");
        uint256 pending = vault.pendingRedeemRequest(userA);
        _step(string.concat("  pendingRedeemRequest(userA): ", vm.toString(pending)));
        assertGt(pending, 0, "should have pending shares locked");

        uint256 totalNow = vault.totalSupply();
        uint256 locked = vault.totalLockedShares();
        _step(string.concat("  totalSupply: ", vm.toString(totalNow)));
        _step(string.concat("  totalLockedShares: ", vm.toString(locked)));
        _step("  Both sync and async paths correctly deducted shares");

        _logPass();
    }

    // =======================================================================
    // 8. 大户连续多笔小额同步赎回分批抽干freeCash
    // =======================================================================

    function test_WhaleSmallBatchDrainFreeCash() public {
        _logCase(
            "test_WhaleSmallBatchDrainFreeCash",
            unicode"大户连续多笔小额同步赎回是否能分批抽干 freeCash"
        );

        _step("[Step 1] Whale deposits 10000 USDC, retail deposits 1000 USDC");
        _depositForUser(whale, 10_000e6);
        _depositForUser(retail, 1000e6);

        _step("[Step 2] Invest to leave freeCash ~ 5000");
        _investViaRebalance(5000e6);
        uint256 fc0 = vault.getFreeCash();
        _step(string.concat("  initial freeCash: ", vm.toString(fc0)));

        _step("[Step 3] Whale does multiple small redeems");
        uint256 batchSize = 500e6;
        uint256 redeemCount = 0;
        uint256 totalWhaleAssets = 0;

        for (uint256 i = 0; i < 20; i++) {
            uint256 whaleShares = vault.balanceOf(whale);
            if (whaleShares < batchSize) break;

            uint256 maxR = vault.maxRedeem(whale);
            if (maxR == 0) break;

            uint256 toRedeem = maxR < batchSize ? maxR : batchSize;
            vm.prank(whale);
            uint256 assets = gateway.redeem(toRedeem);
            totalWhaleAssets += assets;
            redeemCount++;

            uint256 fcNow = vault.getFreeCash();
            _step(
                string.concat(
                    "  batch ", vm.toString(redeemCount),
                    ": redeemed ", vm.toString(toRedeem),
                    " shares, freeCash: ", vm.toString(fcNow)
                )
            );

            if (fcNow == 0) break;
        }

        _step(string.concat("  total batches: ", vm.toString(redeemCount)));
        _step(string.concat("  total whale assets: ", vm.toString(totalWhaleAssets)));

        _step("[Step 4] Check retail user's remaining capacity");
        uint256 maxRedeemRetail = vault.maxRedeem(retail);
        uint256 maxWithdrawRetail = vault.maxWithdraw(retail);
        _step(string.concat("  maxRedeem(retail): ", vm.toString(maxRedeemRetail)));
        _step(string.concat("  maxWithdraw(retail): ", vm.toString(maxWithdrawRetail)));
        _step(string.concat("  freeCash: ", vm.toString(vault.getFreeCash())));

        assertLt(maxRedeemRetail, vault.balanceOf(retail), "retail maxRedeem should be reduced");
        _step("  [Finding] Multiple small redeems can progressively drain freeCash, squeezing other users");

        _logPass();
    }
}
