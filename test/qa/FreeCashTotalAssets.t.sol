// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategyAdapter} from "../../src/interfaces/adapters/IStrategyAdapter.sol";
import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {IMantleVaultGateway} from "../../src/interfaces/vault/IMantleVaultGateway.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {MantleVaultGateway} from "../../src/vault/MantleVaultGateway.sol";
import {Accountant} from "../../src/accountant/Accountant.sol";
import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {OperatorExecutor} from "../../src/protocol/OperatorExecutor.sol";
import {IStrategyControllerExecutor} from "../../src/interfaces/strategy/IStrategyControllerExecutor.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Test, console2} from "forge-std/Test.sol";

// ---------------------------------------------------------------------------
// Mocks
// ---------------------------------------------------------------------------

contract MockUSDC is ERC20 {
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

/// @dev A mock pos token that also has 6 decimals to simplify price calculations
contract MockPosToken is ERC20 {
    constructor() ERC20("MockPosToken", "mPOS") {}

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

contract MockSanctionsOracle is ISanctionsOracle {
    mapping(address => bool) private _sanctioned;

    function initialize(address, address) external {}
    function isSanctioned(address account) external view returns (bool) { return _sanctioned[account]; }
    function isWhitelisted(address) external pure returns (bool) { return true; }
    function totalSanctionedCount() external pure returns (uint256) { return 0; }
    function totalWhitelistedCount() external pure returns (uint256) { return 0; }
    function lastUpdateTimestamp() external pure returns (uint256) { return 0; }
    function batchNonce() external pure returns (uint256) { return 0; }
    function MAX_BATCH_SIZE() external pure returns (uint256) { return 200; }
    function updateSanctionStatus(address account, bool sanctioned) external { _sanctioned[account] = sanctioned; }
    function updateSanctionStatusBatch(address[] calldata, bool) external {}
    function updateWhitelistStatus(address, bool) external {}
    function updateWhitelistStatusBatch(address[] calldata, bool) external {}
}

/// @dev Standalone mock price oracle. setPrice() is the external-dependency
///      equivalent of Accountant.setExchangeRate() — acceptable per CLAUDE.md
///      exception. price=0 triggers a realistic "feed unavailable" revert.
contract MockPriceOracle {
    uint256 public price = 1e18;

    error PriceUnavailable();

    function setPrice(uint256 p) external { price = p; }

    function getPrice() external view returns (uint256) {
        if (price == 0) revert PriceUnavailable();
        return price;
    }
}

contract MockSyncSettlementVenue_FTA {
    MockUSDC public immutable ASSET;
    MockPosToken public immutable POS_TOKEN;

    constructor(address asset_, address posToken_) {
        ASSET = MockUSDC(asset_);
        POS_TOKEN = MockPosToken(posToken_);
    }

    function settleDeposit(address adapter, uint256 assetAmount, uint256 posAmount) external {
        if (assetAmount > 0) {
            ASSET.burn(address(this), assetAmount);
        }
        if (posAmount > 0) {
            POS_TOKEN.mint(adapter, posAmount);
        }
    }

    function settleWithdraw(address adapter, uint256 posAmount, uint256 assetAmount) external {
        if (posAmount > 0) {
            POS_TOKEN.burn(address(this), posAmount);
        }
        if (assetAmount > 0) {
            ASSET.mint(adapter, assetAmount);
        }
    }
}

contract MockStrategyAdapter is IStrategyAdapter {
    address public immutable ASSET;
    address public immutable POS_TOKEN;
    MockPriceOracle public immutable ORACLE;
    MockSyncSettlementVenue_FTA public immutable SETTLEMENT_VENUE;
    address public vaultAddr;

    constructor(address asset_, address posToken_, address oracle_, address settlementVenue_) {
        ASSET = asset_;
        POS_TOKEN = posToken_;
        ORACLE = MockPriceOracle(oracle_);
        SETTLEMENT_VENUE = MockSyncSettlementVenue_FTA(settlementVenue_);
    }

    function setVault(address v) external { vaultAddr = v; }

    function name() external pure returns (string memory) { return "MockStrategyAdapter"; }
    function asset() external view returns (address) { return ASSET; }
    function posToken() external view returns (address) { return POS_TOKEN; }
    function priceOracle() external view returns (address) { return address(ORACLE); }
    function vault() external view returns (address) { return vaultAddr; }
    function setPaused(bool) external {}
    function retryRedeemAsync(uint256, address) external {}
    function minSubscribeAsset() external pure returns (uint256) { return 0; }
    function minRedeemPos() external pure returns (uint256) { return 0; }

    function getPosTokenPrice() external view returns (uint256) { return ORACLE.getPrice(); }

    function estimatePosAmount(uint256 assetAmount) external view returns (uint256) {
        uint256 price = ORACLE.getPrice();
        if (price == 0) return assetAmount;
        uint256 assetScale = 10 ** IERC20Metadata(ASSET).decimals();
        uint256 posScale = 10 ** IERC20Metadata(POS_TOKEN).decimals();
        return assetAmount * 1e18 * posScale / (price * assetScale);
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
        uint256 price = ORACLE.getPrice();
        uint256 posBal = IERC20(POS_TOKEN).balanceOf(vaultAddr);
        uint256 assetScale = 10 ** IERC20Metadata(ASSET).decimals();
        uint256 posScale = 10 ** IERC20Metadata(POS_TOKEN).decimals();
        return posBal * price * assetScale / (1e18 * posScale);
    }

    function deposit(uint256 amount, address) external returns (uint256 posAmount) {
        IERC20(ASSET).transferFrom(vaultAddr, address(this), amount);
        IERC20(ASSET).transfer(address(SETTLEMENT_VENUE), amount);

        uint256 price = ORACLE.getPrice();
        uint256 assetScale = 10 ** IERC20Metadata(ASSET).decimals();
        uint256 posScale = 10 ** IERC20Metadata(POS_TOKEN).decimals();
        posAmount = amount * 1e18 * posScale / (price * assetScale);
        SETTLEMENT_VENUE.settleDeposit(address(this), amount, posAmount);
    }

    function withdrawSync(uint256 posAmount, address) external returns (uint256 assetAmount) {
        IERC20(POS_TOKEN).transferFrom(vaultAddr, address(this), posAmount);
        IERC20(POS_TOKEN).transfer(address(SETTLEMENT_VENUE), posAmount);

        uint256 price = ORACLE.getPrice();
        uint256 assetScale = 10 ** IERC20Metadata(ASSET).decimals();
        uint256 posScale = 10 ** IERC20Metadata(POS_TOKEN).decimals();
        assetAmount = posAmount * price * assetScale / (1e18 * posScale);
        SETTLEMENT_VENUE.settleWithdraw(address(this), posAmount, assetAmount);
        return assetAmount;
    }

    function requestRedeemAsync(uint256, address) external {}

    function sweepToVault(address token, uint256 amount) external returns (uint256) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 actual = amount > bal ? bal : amount;
        if (actual > 0) {
            IERC20(token).transfer(vaultAddr, actual);
        }
        return actual;
    }
}

// ---------------------------------------------------------------------------
// Test Contract
// ---------------------------------------------------------------------------

contract FreeCashTotalAssetsQATest is Test {
    MockUSDC internal usdc;
    MockPosToken internal posToken;
    MockSanctionsOracle internal oracle;
    MockPriceOracle internal mockPriceOracle;
    MockSyncSettlementVenue_FTA internal settlementVenue;
    MantleYieldVault internal vault;
    MantleVaultGateway internal gateway;
    Accountant internal accountant;
    StrategyController internal controller;
    MockStrategyAdapter internal adapter;
    OperatorExecutor internal executor;

    address internal admin = makeAddr("admin");
    address internal bot = makeAddr("bot");
    address internal treasury = makeAddr("treasury");
    address internal sanctionSafe = makeAddr("sanctionSafe");
    address internal user1 = makeAddr("user1");
    address internal user2 = makeAddr("user2");

    uint256 constant RATE = 1e18;
    uint256 constant FEE_BPS = 100; // 1%

    function setUp() public {
        usdc = new MockUSDC();
        posToken = new MockPosToken();
        oracle = new MockSanctionsOracle();

        OperatorExecutor execImpl = new OperatorExecutor();
        executor = OperatorExecutor(address(new ERC1967Proxy(
            address(execImpl),
            abi.encodeCall(OperatorExecutor.initialize, (admin, bot))
        )));

        // Deploy implementations
        MantleYieldVault vaultImpl = new MantleYieldVault();
        Accountant acctImpl = new Accountant();
        MantleVaultGateway gwImpl = new MantleVaultGateway();
        StrategyController ctrlImpl = new StrategyController();

        // Initialize vault with admin as controller temporarily
        bytes memory vaultInitData = abi.encodeCall(
            MantleYieldVault.initialize,
            IMantleYieldVault.InitParams({
                asset: IERC20(address(usdc)),
                name: "mRWA Vault",
                symbol: "mRWA",
                admin: admin,
                gateway: address(1), // placeholder
                controller: admin, // placeholder, will update
                accountant: address(1), // placeholder
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

        // Initialize accountant
        bytes memory acctInitData = abi.encodeCall(
            Accountant.initialize,
            (address(vault), uint64(RATE), 0, admin)
        );
        accountant = Accountant(address(new ERC1967Proxy(address(acctImpl), acctInitData)));

        // Initialize controller
        bytes memory ctrlInitData = abi.encodeCall(
            StrategyController.initialize,
            (address(vault), admin, address(executor), admin, 1000, 200, 0)
        );
        controller = StrategyController(address(new ERC1967Proxy(address(ctrlImpl), ctrlInitData)));

        // Initialize gateway
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

        // Set references on vault
        vm.startPrank(admin);
        vault.setAccountant(address(accountant));
        vault.setGateway(address(gateway));
        vault.setController(address(controller));
        vm.stopPrank();

        // Create and register adapter
        mockPriceOracle = new MockPriceOracle();
        settlementVenue = new MockSyncSettlementVenue_FTA(address(usdc), address(posToken));
        adapter = new MockStrategyAdapter(
            address(usdc), address(posToken), address(mockPriceOracle), address(settlementVenue)
        );
        adapter.setVault(address(vault));

        vm.startPrank(admin);
        controller.registerStrategy(address(adapter), 10_000, 1, false);
        controller.activateStrategy(address(adapter));
        address[] memory ordered = new address[](1);
        ordered[0] = address(adapter);
        controller.setStrategyOrder(ordered);
        vm.stopPrank();

        // Fund users
        usdc.mint(user1, 100_000e6);
        usdc.mint(user2, 100_000e6);
        vm.prank(user1);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(user2);
        usdc.approve(address(vault), type(uint256).max);
    }

    // -----------------------------------------------------------------------
    // Logging helpers
    // -----------------------------------------------------------------------

    string constant MODULE = unicode"FreeCash 与 totalAssets 场景";
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

    // -----------------------------------------------------------------------
    // 1. test_FreeCash_NoLockedShares
    // -----------------------------------------------------------------------

    function test_FreeCash_NoLockedShares() public {
        _logCase(
            "test_FreeCash_NoLockedShares",
            unicode"无 locked shares 时 `freeCash = vault` 底层资产余额"
        );

        _step("[Step 1] Deposit 2000 USDC into vault (totalLockedShares=0)");
        _depositViaGateway(user1, 2000e6);
        uint256 physBal = usdc.balanceOf(address(vault));
        _step(string.concat("  vault physical balance = ", vm.toString(physBal)));

        _step("[Step 2] Verify totalLockedShares == 0");
        uint256 locked = vault.totalLockedShares();
        assertEq(locked, 0);
        _step(string.concat("  totalLockedShares = ", vm.toString(locked)));

        _step("[Step 3] Verify freeCash == physical balance");
        uint256 freeCash = vault.getFreeCash();
        _step(string.concat("  freeCash = ", vm.toString(freeCash)));
        assertEq(freeCash, physBal);
        _step("  PASS: freeCash equals physical balance when no locked shares");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 2. test_FreeCash_WithLockedShares
    // -----------------------------------------------------------------------

    function test_FreeCash_WithLockedShares() public {
        _logCase(
            "test_FreeCash_WithLockedShares",
            unicode"存在 locked shares 时 `freeCash = physicalBalance - _convertToAssets(totalLockedShares, Ceil)`"
        );

        _step("[Step 1] Deposit 2000 USDC, create async redeem for 1000 shares worth");
        _depositViaGateway(user1, 2000e6);
        // Deposit another user to have shares to redeem
        uint256 redeemShares = _depositViaGateway(user2, 1000e6);
        _requestRedeemViaGateway(user2, redeemShares);

        uint256 physBal = usdc.balanceOf(address(vault));
        uint256 lockedShares = vault.totalLockedShares();
        _step(string.concat("  physicalBalance = ", vm.toString(physBal)));
        _step(string.concat("  totalLockedShares = ", vm.toString(lockedShares)));

        _step("[Step 2] Compute expected freeCash using formula");
        // freeCash = physicalBalance - _convertToAssets(totalLockedShares, Ceil)
        // _convertToAssets(shares, Ceil) = (shares * rate + 1e18 - 1) / 1e18
        uint256 rate = vault.exchangeRate();
        uint256 floatingLocked = (lockedShares * rate + 1e18 - 1) / 1e18;
        uint256 expectedFreeCash = physBal > floatingLocked ? physBal - floatingLocked : 0;
        uint256 freeCash = vault.getFreeCash();
        _step(string.concat("  rate = ", vm.toString(rate)));
        _step(string.concat("  floatingLocked = ", vm.toString(floatingLocked)));
        _step(string.concat("  expected freeCash = ", vm.toString(expectedFreeCash)));
        _step(string.concat("  actual freeCash = ", vm.toString(freeCash)));

        _step("[Step 3] Verify freeCash matches formula exactly");
        assertEq(freeCash, expectedFreeCash, "freeCash should match formula");
        assertLt(freeCash, physBal, "freeCash should be less than physical balance");
        assertGt(freeCash, 0, "freeCash should be positive (locked does not cover all)");
        _step("  PASS: freeCash = physicalBalance - convertToAssets(totalLockedShares, Ceil)");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 3a. test_FreeCash_ZeroWhenLockedEqualsBalance
    //     Scenario: deposit -> rebalance invest -> requestRedeem -> rate up
    //     Result: physicalBalance == floatingLocked, freeCash == 0
    // -----------------------------------------------------------------------

    function test_FreeCash_ZeroWhenLockedEqualsBalance() public {
        _logCase(
            "test_FreeCash_ZeroWhenLockedEqualsBalance",
            unicode"当 `totalLockedShares` 大于等于物理余额时 `freeCash=0`"
        );

        // Step 1: Deposit
        _step("[Step 1] Deposit 10000 USDC");
        uint256 depositAmount = 10_000e6;
        uint256 shares = _depositViaGateway(user1, depositAmount);
        uint256 physBalAfterDeposit = usdc.balanceOf(address(vault));
        _step(string.concat("  shares minted = ", vm.toString(shares)));
        _step(string.concat("  physicalBalance = ", vm.toString(physBalAfterDeposit)));

        // Step 2: Rebalance to invest excess cash into strategy
        // bufferTargetBps=1000(10%), thresholdBps=200(2%)
        // freeCash=10000, targetCash=1000, invest amount=freeCash-targetCash=9000
        _step("[Step 2] Rebalance: invest excess cash into strategy");
        vm.warp(block.timestamp + 1);
        vm.prank(bot);
        executor.executeRebalance(address(controller));

        uint256 physBalAfterRebalance = usdc.balanceOf(address(vault));
        _step(string.concat("  physicalBalance after rebalance = ", vm.toString(physBalAfterRebalance)));
        assertLt(physBalAfterRebalance, physBalAfterDeposit, "rebalance should reduce vault balance");

        // Step 3: Request redeem for all shares -> creates totalLockedShares
        _step("[Step 3] Request async redeem for all user shares");
        _requestRedeemViaGateway(user1, shares);
        uint256 lockedShares = vault.totalLockedShares();
        _step(string.concat("  totalLockedShares = ", vm.toString(lockedShares)));

        // At rate=1e18, floatingLocked = lockedShares (after fee deduction, locked < physBal)
        uint256 freeCashBeforeRate = vault.getFreeCash();
        _step(string.concat("  freeCash before rate change = ", vm.toString(freeCashBeforeRate)));

        // Step 4: Raise exchange rate so floatingLocked >= physicalBalance
        // floatingLocked = lockedShares * newRate / 1e18 (Ceil)
        // We need: floatingLocked >= physBalAfterRebalance
        // newRate >= physBalAfterRebalance * 1e18 / lockedShares (round up)
        _step("[Step 4] Raise exchange rate so floatingLocked >= physicalBalance");
        uint256 requiredRate = (uint256(physBalAfterRebalance) * 1e18 + lockedShares - 1) / lockedShares;
        // Accountant has 1% max deviation, so check if required rate is within band
        uint256 currentRate = vault.exchangeRate();
        _step(string.concat("  current rate = ", vm.toString(currentRate)));
        _step(string.concat("  required rate = ", vm.toString(requiredRate)));

        if (requiredRate <= currentRate * 101 / 100) {
            // Within 1% band, use normal updateExchangeRate
            vm.warp(block.timestamp + 20 hours + 1);
            vm.prank(admin);
            accountant.updateExchangeRate(uint64(requiredRate), uint64(block.timestamp));
        } else {
            // Exceeds 1% band, use emergencyRateUpdate (admin-only, bypasses circuit breaker)
            vm.prank(admin);
            accountant.emergencyRateUpdate(uint64(requiredRate));
        }
        _step(string.concat("  new rate = ", vm.toString(vault.exchangeRate())));

        // Step 5: Verify freeCash == 0
        _step("[Step 5] Verify freeCash == 0");
        uint256 physBal = usdc.balanceOf(address(vault));
        uint256 floatingLocked = (lockedShares * vault.exchangeRate() + 1e18 - 1) / 1e18;
        uint256 freeCash = vault.getFreeCash();
        _step(string.concat("  physicalBalance = ", vm.toString(physBal)));
        _step(string.concat("  floatingLocked = ", vm.toString(floatingLocked)));
        _step(string.concat("  freeCash = ", vm.toString(freeCash)));
        assertGe(floatingLocked, physBal, "floatingLocked should >= physicalBalance");
        assertEq(freeCash, 0, "freeCash should be 0 when locked covers full balance");
        _step("  PASS: freeCash is 0 when rebalance + rate increase causes locked >= balance");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 3b. test_FreeCash_ZeroWhenLockedExceedsBalance
    //     Scenario: deposit -> rebalance invest -> requestRedeem -> larger rate up
    //     Result: physicalBalance < floatingLocked, freeCash == 0 (no underflow)
    // -----------------------------------------------------------------------

    function test_FreeCash_ZeroWhenLockedExceedsBalance() public {
        _logCase(
            "test_FreeCash_ZeroWhenLockedExceedsBalance",
            unicode"rebalance 投资后请求赎回 + 汇率大幅上升，floatingLocked 严重超过物理余额，freeCash=0 且无下溢"
        );

        // Step 1: Deposit
        _step("[Step 1] Deposit 10000 USDC");
        uint256 depositAmount = 10_000e6;
        uint256 shares = _depositViaGateway(user1, depositAmount);
        _step(string.concat("  shares minted = ", vm.toString(shares)));

        // Step 2: Rebalance to invest most cash into strategy
        _step("[Step 2] Rebalance: invest excess cash into strategy");
        vm.warp(block.timestamp + 1);
        vm.prank(bot);
        executor.executeRebalance(address(controller));

        uint256 physBalAfterRebalance = usdc.balanceOf(address(vault));
        _step(string.concat("  physicalBalance after rebalance = ", vm.toString(physBalAfterRebalance)));

        // Step 3: Request redeem for all shares
        _step("[Step 3] Request async redeem for all user shares");
        _requestRedeemViaGateway(user1, shares);
        uint256 lockedShares = vault.totalLockedShares();
        _step(string.concat("  totalLockedShares = ", vm.toString(lockedShares)));

        // Step 4: Use emergencySetRate to significantly raise the rate
        // This simulates underlying asset appreciation while most funds are deployed
        _step("[Step 4] Emergency rate increase to 1.5x (simulate large asset appreciation)");
        uint64 newRate = uint64(1.5e18);
        vm.prank(admin);
        accountant.emergencyRateUpdate(newRate);
        // emergencyRateUpdate auto-unpauses accountant, no need to call unpause()
        _step(string.concat("  new rate = ", vm.toString(vault.exchangeRate())));

        // Step 5: Verify freeCash == 0 and no underflow
        _step("[Step 5] Verify freeCash == 0 (floatingLocked >> physicalBalance)");
        uint256 physBal = usdc.balanceOf(address(vault));
        uint256 floatingLocked = (lockedShares * vault.exchangeRate() + 1e18 - 1) / 1e18;
        uint256 freeCash = vault.getFreeCash();
        _step(string.concat("  physicalBalance = ", vm.toString(physBal)));
        _step(string.concat("  floatingLocked = ", vm.toString(floatingLocked)));
        _step(string.concat("  gap (locked - balance) = ", vm.toString(floatingLocked - physBal)));
        _step(string.concat("  freeCash = ", vm.toString(freeCash)));
        assertGt(floatingLocked, physBal, "floatingLocked should significantly exceed physicalBalance");
        assertEq(freeCash, 0, "freeCash should be 0, no underflow");
        _step("  PASS: freeCash is 0 with no underflow even when locked >> balance");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 4. test_ControllerCannotInvestLockedFunds
    // -----------------------------------------------------------------------

    function test_ControllerCannotInvestLockedFunds() public {
        _logCase(
            "test_ControllerCannotInvestLockedFunds",
            unicode"存在异步赎回负债时，Vault 必须优先为其预留资金，Controller 不得将该部分资金重新投资"
        );

        _step("[Step 1] Deposit 10000 USDC, request async redeem for half");
        uint256 shares = _depositViaGateway(user1, 10_000e6);
        uint256 redeemShares = shares / 2;
        _requestRedeemViaGateway(user1, redeemShares);

        uint256 freeCashBefore = vault.getFreeCash();
        uint256 physBal = usdc.balanceOf(address(vault));
        uint256 lockedShares = vault.totalLockedShares();
        _step(string.concat("  physicalBalance = ", vm.toString(physBal)));
        _step(string.concat("  totalLockedShares = ", vm.toString(lockedShares)));
        _step(string.concat("  freeCash = ", vm.toString(freeCashBefore)));
        assertGt(freeCashBefore, 0, "should have some freeCash for investment");
        assertLt(freeCashBefore, physBal, "freeCash < physBal due to locked shares");

        _step("[Step 2] Trigger rebalance, verify actual invested amount <= freeCash");
        uint256 vaultUsdcBefore = usdc.balanceOf(address(vault));
        uint256 adapterValBefore = adapter.totalValue();
        vm.prank(bot);
        executor.executeRebalance(address(controller));
        uint256 vaultUsdcAfter = usdc.balanceOf(address(vault));
        uint256 adapterValAfter = adapter.totalValue();
        uint256 actualInvested = vaultUsdcBefore - vaultUsdcAfter;
        _step(string.concat("  vault USDC before rebalance = ", vm.toString(vaultUsdcBefore)));
        _step(string.concat("  vault USDC after rebalance = ", vm.toString(vaultUsdcAfter)));
        _step(string.concat("  actual invested = ", vm.toString(actualInvested)));
        _step(string.concat("  adapter value change = ", vm.toString(adapterValAfter - adapterValBefore)));

        assertLe(actualInvested, freeCashBefore, "invested amount must not exceed freeCash (locked funds protected)");

        _step("[Step 3] Verify vault still has enough to cover locked shares after rebalance");
        uint256 freeCashAfter = vault.getFreeCash();
        uint256 rate = vault.exchangeRate();
        uint256 floatingLocked = (lockedShares * rate + 1e18 - 1) / 1e18;
        _step(string.concat("  freeCash after rebalance = ", vm.toString(freeCashAfter)));
        _step(string.concat("  vault USDC remaining = ", vm.toString(vaultUsdcAfter)));
        _step(string.concat("  floatingLocked = ", vm.toString(floatingLocked)));
        assertGe(vaultUsdcAfter, floatingLocked, "vault must retain enough USDC to cover locked shares");
        _step("  PASS: Controller only invests freeCash, locked funds protected");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 5. test_SyncRedeem_LimitedByFreeCash
    // -----------------------------------------------------------------------

    function test_SyncRedeem_LimitedByFreeCash() public {
        _logCase(
            "test_SyncRedeem_LimitedByFreeCash",
            unicode"存在异步赎回 `totalLockedShares` 时，同步赎回应受 `freeCash` 限制，不能动用已预留给异步赎回的资金"
        );

        _step("[Step 1] Multiple users deposit, rebalance invests into adapter");
        uint256 shares1 = _depositViaGateway(user1, 10_000e6);
        uint256 shares2 = _depositViaGateway(user2, 10_000e6);
        vm.prank(bot);
        executor.executeRebalance(address(controller));
        _step(string.concat("  vault USDC after rebalance: ", vm.toString(usdc.balanceOf(address(vault)))));

        _step("[Step 2] User1 requests async redeem of partial shares, locking some freeCash");
        // Lock only 1/20 of shares so floatingLocked < physicalBalance (buffer),
        // leaving freeCash > 0 but < user2's total shares
        uint256 lockShares = shares1 / 20;
        _requestRedeemViaGateway(user1, lockShares);

        uint256 freeCash = vault.getFreeCash();
        uint256 physBal = usdc.balanceOf(address(vault));
        uint256 lockedShares = vault.totalLockedShares();
        _step(string.concat("  physicalBalance: ", vm.toString(physBal)));
        _step(string.concat("  freeCash after lock: ", vm.toString(freeCash)));
        _step(string.concat("  totalLockedShares: ", vm.toString(lockedShares)));
        assertGt(physBal, freeCash, "physical balance > freeCash (locked funds reserved)");

        _step("[Step 3] User2 maxRedeem is limited by freeCash");
        uint256 maxRedeemUser2 = vault.maxRedeem(user2);
        _step(string.concat("  user2 shares: ", vm.toString(shares2)));
        _step(string.concat("  maxRedeem(user2): ", vm.toString(maxRedeemUser2)));
        assertLt(maxRedeemUser2, shares2, "maxRedeem should be less than full shares (freeCash insufficient)");

        _step("[Step 4] User2 full sync redeem fails, partial succeeds");
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSignature("ERC4626ExceededMaxRedeem(address,uint256,uint256)", user2, shares2, maxRedeemUser2));
        gateway.redeem(shares2);
        _step("  full sync redeem reverted as expected");

        assertGt(maxRedeemUser2, 0, "precondition: user2 should have partial redeemability (freeCash > 0)");
        vm.prank(user2);
        uint256 received = gateway.redeem(maxRedeemUser2);
        assertGt(received, 0, "partial redeem should succeed");
        _step(string.concat("  partial sync redeem succeeded, received: ", vm.toString(received)));

        _step("[Step 5] Verify locked shares unchanged after sync redeem");
        uint256 lockedAfter = vault.totalLockedShares();
        uint256 freeCashAfter = vault.getFreeCash();
        uint256 vaultUsdcAfter = usdc.balanceOf(address(vault));
        _step(string.concat("  vault USDC remaining: ", vm.toString(vaultUsdcAfter)));
        _step(string.concat("  freeCash after: ", vm.toString(freeCashAfter)));
        _step(string.concat("  totalLockedShares after: ", vm.toString(lockedAfter)));
        assertEq(lockedAfter, lockedShares, "totalLockedShares must be unchanged by sync redeem");
        _step("  PASS: sync redeem limited by freeCash, locked funds protected");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 6. test_RedemptionFeeChange_DoesNotAffectFreeCash
    // -----------------------------------------------------------------------

    function test_RedemptionFeeChange_DoesNotAffectFreeCash() public {
        _logCase(
            "test_RedemptionFeeChange_DoesNotAffectFreeCash",
            unicode"修改 redemption fee 不影响 `freeCash`（`getFreeCash` 内部使用 `_convertToAssets(totalLockedShares, Ceil)` 与赎回费无关）"
        );

        _step("[Step 1] Deposit 5000 USDC, create async redeem to generate lockedShares");
        uint256 shares = _depositViaGateway(user1, 5000e6);
        uint256 redeemShares = shares / 2;
        _requestRedeemViaGateway(user1, redeemShares);

        uint256 lockedShares = vault.totalLockedShares();
        assertGt(lockedShares, 0, "should have locked shares");
        _step(string.concat("  totalLockedShares = ", vm.toString(lockedShares)));

        _step("[Step 2] Record freeCash before fee change");
        uint256 freeCashBefore = vault.getFreeCash();
        _step(string.concat("  freeCash before = ", vm.toString(freeCashBefore)));

        _step("[Step 3] Admin changes redemption fee from 100 bps to 500 bps");
        vm.prank(admin);
        vault.setRedemptionFee(500);
        _step("  redemptionFee updated: 100 -> 500 bps");

        _step("[Step 4] Verify freeCash unchanged after fee change");
        uint256 freeCashAfter = vault.getFreeCash();
        _step(string.concat("  freeCash after = ", vm.toString(freeCashAfter)));
        assertEq(freeCashAfter, freeCashBefore, "freeCash must not change when redemption fee changes");

        _step("[Step 5] Verify getFreeCash uses _convertToAssets(Ceil), not previewRedeem");
        // _convertToAssets(totalLockedShares, Ceil) = (lockedShares * rate + 1e18 - 1) / 1e18
        // This does NOT involve redemptionFee at all
        uint256 rate = vault.exchangeRate();
        uint256 floatingLocked = (lockedShares * rate + 1e18 - 1) / 1e18;
        uint256 physBal = usdc.balanceOf(address(vault));
        uint256 expectedFreeCash = physBal > floatingLocked ? physBal - floatingLocked : 0;
        assertEq(freeCashAfter, expectedFreeCash, "freeCash should match _convertToAssets formula (fee-independent)");
        _step(string.concat("  rate = ", vm.toString(rate)));
        _step(string.concat("  floatingLocked (_convertToAssets Ceil) = ", vm.toString(floatingLocked)));
        _step(string.concat("  physicalBalance = ", vm.toString(physBal)));
        _step("  PASS: freeCash is fee-independent, uses _convertToAssets(totalLockedShares, Ceil)");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 6b. test_RedemptionFeeChange_AffectsNetShares
    // -----------------------------------------------------------------------

    function test_RedemptionFeeChange_AffectsNetShares() public {
        _logCase(
            "test_RedemptionFeeChange_AffectsNetShares",
            unicode"修改 redemption fee 后，新创建的赎回请求产生的 netShares 不同"
        );

        _step("[Step 1] Deposit for user1 and user2");
        uint256 shares1 = _depositViaGateway(user1, 3000e6);
        _depositViaGateway(user2, 3000e6);
        uint256 redeemAmount = shares1 / 2;
        _step(string.concat("  each user deposited 3000 USDC, redeemAmount = ", vm.toString(redeemAmount)));

        _step("[Step 2] user1 requestRedeem at original fee (100 bps = 1%)");
        uint256 reqId1 = _requestRedeemViaGateway(user1, redeemAmount);
        (,, uint256 netShares1, uint256 feeShares1,,,,) = vault.requests(reqId1);
        _step(string.concat("  request1 netShares = ", vm.toString(netShares1)));
        _step(string.concat("  request1 feeShares = ", vm.toString(feeShares1)));

        _step("[Step 3] Admin changes redemption fee to 500 bps (5%)");
        vm.prank(admin);
        vault.setRedemptionFee(500);
        _step("  redemptionFee updated: 100 -> 500 bps");

        _step("[Step 4] user2 requestRedeem same gross shares at new fee (500 bps = 5%)");
        uint256 reqId2 = _requestRedeemViaGateway(user2, redeemAmount);
        (,, uint256 netShares2, uint256 feeShares2,,,,) = vault.requests(reqId2);
        _step(string.concat("  request2 netShares = ", vm.toString(netShares2)));
        _step(string.concat("  request2 feeShares = ", vm.toString(feeShares2)));

        _step("[Step 5] Verify: higher fee -> smaller netShares, larger feeShares");
        assertLt(netShares2, netShares1, "higher fee should produce smaller netShares");
        assertGt(feeShares2, feeShares1, "higher fee should produce larger feeShares");
        assertEq(netShares1 + feeShares1, redeemAmount, "request1: netShares + feeShares == gross shares");
        assertEq(netShares2 + feeShares2, redeemAmount, "request2: netShares + feeShares == gross shares");
        _step("  PASS: fee change correctly affects netShares of new requests");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 7. test_TotalAssets_IncludesAllComponents
    //    Business flow: deposit -> rebalance(invest) -> settleAdapter(posToken to vault)
    //    -> deposit again -> rebalance(invest, creates investInFlight)
    //    -> requestRedeem(creates lockedShares)
    //    -> processRedeemBatch(divest sync, creates redeemInFlight)
    //    Result: totalAssets = physBal + posTokenValue + investInFlight + redeemInFlight - floatingLocked
    // -----------------------------------------------------------------------

    function test_TotalAssets_IncludesAllComponents() public {
        _logCase(
            "test_TotalAssets_IncludesAllComponents",
            unicode"`totalAssets` 包含底层余额、策略价值、invest in-flight、redeem in-flight，并扣除 `totalLockedShares`"
        );

        // ---- Round 1: deposit + rebalance + settle → posToken lands on vault ----
        _step("[Step 1] Deposit 10000 USDC, rebalance to invest into adapter");
        _depositViaGateway(user1, 10_000e6);
        vm.warp(block.timestamp + 1);
        vm.prank(bot);
        executor.executeRebalance(address(controller));

        // rebalance created investInFlight, record its ID (starts at 1)
        uint256 investInFlightId1 = vault.nextInFlightId() - 1;
        uint256 investAmount1 = vault.totalInvestInFlight();
        _step(string.concat("  round1 investInFlight = ", vm.toString(investAmount1)));

        // Settle round 1: sweep posToken from adapter to vault, confirm investInFlight
        _step("[Step 2] Settle adapter: posToken swept to vault, investInFlight cleared");
        uint256[] memory ids1 = new uint256[](1);
        ids1[0] = investInFlightId1;
        uint256[] memory settledPos1 = new uint256[](1);
        settledPos1[0] = investAmount1; // 1:1 price, posToken amount == asset amount
        uint256[] memory refunds1 = new uint256[](1);
        refunds1[0] = 0;
        uint256[] memory emptyIds = new uint256[](0);
        uint256[] memory emptyAmounts = new uint256[](0);

        vm.prank(bot);
        executor.executeSettleAdapter(
            address(controller),
            address(adapter),
            IStrategyControllerExecutor.InvestSettlementInput(ids1, settledPos1, refunds1),
            IStrategyControllerExecutor.RedeemSettlementInput(emptyIds, emptyAmounts)
        );

        uint256 posOnVault = posToken.balanceOf(address(vault));
        _step(string.concat("  posToken on vault after settle = ", vm.toString(posOnVault)));
        assertGt(posOnVault, 0, "vault should hold posToken after settlement");
        assertEq(vault.totalInvestInFlight(), 0, "investInFlight should be cleared");

        // ---- Round 2: deposit more + rebalance → new investInFlight ----
        _step("[Step 3] User2 deposits 10000 USDC, rebalance again to create new investInFlight");
        uint256 shares2 = _depositViaGateway(user2, 10_000e6);
        vm.warp(block.timestamp + 1);
        vm.prank(bot);
        executor.executeRebalance(address(controller));

        uint256 investInFlight = vault.totalInvestInFlight();
        _step(string.concat("  investInFlight (round2) = ", vm.toString(investInFlight)));

        // ---- requestRedeem → lockedShares ----
        _step("[Step 4] User2 requests async redeem to create lockedShares");
        _requestRedeemViaGateway(user2, shares2 / 2);
        uint256 lockedShares = vault.totalLockedShares();
        _step(string.concat("  totalLockedShares = ", vm.toString(lockedShares)));

        // ---- processRedeemBatch → divest (sync withdrawSync) → redeemInFlight ----
        _step("[Step 5] processRedeemBatch triggers sync divest, creating redeemInFlight");
        uint256 requestId = vault.nextRequestId() - 1; // the redeem request just created
        uint256[] memory redeemIds = new uint256[](1);
        redeemIds[0] = requestId;
        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), redeemIds);

        uint256 redeemInFlight = vault.totalRedeemInFlight();
        _step(string.concat("  redeemInFlight = ", vm.toString(redeemInFlight)));

        // ---- Verify totalAssets formula ----
        _step("[Step 6] Collect state and verify totalAssets formula");
        uint256 physBal = usdc.balanceOf(address(vault));
        uint256 posValue = posToken.balanceOf(address(vault)); // price=1e18, decimals=6, so value = balance
        uint256 rate = vault.exchangeRate();
        uint256 floatingLocked = (lockedShares * rate + 1e18 - 1) / 1e18;
        investInFlight = vault.totalInvestInFlight();
        redeemInFlight = vault.totalRedeemInFlight();

        uint256 gross = physBal + posValue + investInFlight + redeemInFlight;
        uint256 expectedTotalAssets = gross > floatingLocked ? gross - floatingLocked : 0;

        _step(string.concat("  physBal          = ", vm.toString(physBal)));
        _step(string.concat("  posTokenValue    = ", vm.toString(posValue)));
        _step(string.concat("  investInFlight   = ", vm.toString(investInFlight)));
        _step(string.concat("  redeemInFlight   = ", vm.toString(redeemInFlight)));
        _step(string.concat("  floatingLocked   = ", vm.toString(floatingLocked)));
        _step(string.concat("  gross            = ", vm.toString(gross)));
        _step(string.concat("  expected         = ", vm.toString(expectedTotalAssets)));

        uint256 actualTotalAssets = vault.totalAssets();
        _step(string.concat("  actual           = ", vm.toString(actualTotalAssets)));

        _step("[Step 7] Assert totalAssets matches formula exactly");
        assertEq(actualTotalAssets, expectedTotalAssets, "totalAssets must equal gross - floatingLocked");
        assertGt(actualTotalAssets, 0, "totalAssets should be positive");
        // Verify each component is non-zero (all components contributed)
        assertGt(physBal, 0, "physBal component should be non-zero");
        assertGt(posValue, 0, "posTokenValue component should be non-zero");
        assertGt(investInFlight, 0, "investInFlight component should be non-zero");
        assertGt(redeemInFlight, 0, "redeemInFlight component should be non-zero");
        assertGt(floatingLocked, 0, "floatingLocked component should be non-zero");
        _step("  PASS: totalAssets = physBal + posTokenValue + investInFlight + redeemInFlight - floatingLocked");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 8. test_TotalAssets_ZeroWhenLockedExceedsAll
    //    Business flow: deposit -> rebalance invest (vault USDC drops)
    //    -> requestRedeem all shares (lockedShares created)
    //    -> raise exchange rate (floatingLocked grows beyond total gross)
    //    Result: totalAssets == 0, no underflow
    // -----------------------------------------------------------------------

    function test_TotalAssets_ZeroWhenLockedExceedsAll() public {
        _logCase(
            "test_TotalAssets_ZeroWhenLockedExceedsAll",
            unicode"`totalAssets` 在锁定 shares 大于全部统计资产时返回 0"
        );

        // Step 1: Deposit and rebalance to invest most funds into strategy
        _step("[Step 1] Deposit 10000 USDC, rebalance to invest into adapter");
        uint256 shares = _depositViaGateway(user1, 10_000e6);
        vm.warp(block.timestamp + 1);
        vm.prank(bot);
        executor.executeRebalance(address(controller));

        uint256 physBalAfterRebalance = usdc.balanceOf(address(vault));
        _step(string.concat("  physicalBalance after rebalance = ", vm.toString(physBalAfterRebalance)));

        // Step 2: Settle invest so posToken lands on vault (and investInFlight clears)
        // This way total = physBal + posTokenValue, no inflated inFlight
        _step("[Step 2] Settle adapter: posToken to vault, investInFlight cleared");
        uint256 investId = vault.nextInFlightId() - 1;
        uint256 investedAmount = vault.totalInvestInFlight();

        uint256[] memory ids = new uint256[](1);
        ids[0] = investId;
        uint256[] memory settledPos = new uint256[](1);
        settledPos[0] = investedAmount;
        uint256[] memory refunds = new uint256[](1);
        refunds[0] = 0;
        uint256[] memory emptyIds = new uint256[](0);
        uint256[] memory emptyAmounts = new uint256[](0);

        vm.prank(bot);
        executor.executeSettleAdapter(
            address(controller),
            address(adapter),
            IStrategyControllerExecutor.InvestSettlementInput(ids, settledPos, refunds),
            IStrategyControllerExecutor.RedeemSettlementInput(emptyIds, emptyAmounts)
        );
        assertEq(vault.totalInvestInFlight(), 0, "investInFlight should be cleared");

        // Step 3: Request redeem of ALL shares → creates large lockedShares
        _step("[Step 3] Request async redeem for all user shares");
        _requestRedeemViaGateway(user1, shares);
        uint256 lockedShares = vault.totalLockedShares();
        _step(string.concat("  totalLockedShares = ", vm.toString(lockedShares)));

        // Step 4: Raise exchange rate so floatingLocked exceeds total gross assets
        // total = physBal + posTokenValue (on vault) + 0 + 0
        // floatingLocked = lockedShares * newRate / 1e18 (Ceil)
        // We need floatingLocked > total
        _step("[Step 4] Raise exchange rate so floatingLocked exceeds all gross assets");
        uint256 physBal = usdc.balanceOf(address(vault));
        uint256 posValue = posToken.balanceOf(address(vault)); // price=1e18, decimals match
        uint256 grossTotal = physBal + posValue;
        // requiredRate: lockedShares * rate / 1e18 > grossTotal
        // rate > grossTotal * 1e18 / lockedShares
        uint256 requiredRate = (grossTotal * 1e18 / lockedShares) + 1e18 / 10; // add buffer to ensure >
        _step(string.concat("  grossTotal = ", vm.toString(grossTotal)));
        _step(string.concat("  requiredRate = ", vm.toString(requiredRate)));

        vm.prank(admin);
        accountant.emergencyRateUpdate(uint64(requiredRate));

        // Step 5: Verify totalAssets == 0
        _step("[Step 5] Verify totalAssets == 0 (no underflow)");
        uint256 newRate = vault.exchangeRate();
        uint256 floatingLocked = (lockedShares * newRate + 1e18 - 1) / 1e18;
        _step(string.concat("  new rate         = ", vm.toString(newRate)));
        _step(string.concat("  floatingLocked   = ", vm.toString(floatingLocked)));
        _step(string.concat("  grossTotal       = ", vm.toString(grossTotal)));
        assertGt(floatingLocked, grossTotal, "floatingLocked must exceed gross total");

        uint256 totalAssetsAfter = vault.totalAssets();
        _step(string.concat("  totalAssets      = ", vm.toString(totalAssetsAfter)));
        assertEq(totalAssetsAfter, 0, "totalAssets should be 0 when locked exceeds all");
        _step("  PASS: totalAssets returns 0 (no underflow)");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 9. test_AdapterTotalValue_RevertPropagates
    // -----------------------------------------------------------------------

    function test_AdapterTotalValue_RevertPropagates() public {
        _logCase(
            "test_AdapterTotalValue_RevertPropagates",
            unicode"adapter `totalValue()` 异常会导致 `Vault.totalAssets` 整体失败"
        );

        _step("[Step 1] Deposit some USDC to vault");
        _depositViaGateway(user1, 1000e6);

        _step("[Step 2] Verify totalAssets works normally");
        uint256 ta = vault.totalAssets();
        _step(string.concat("  totalAssets (normal) = ", vm.toString(ta)));
        assertGt(ta, 0);

        _step("[Step 3] Set oracle price to 0 (simulates price feed unavailable), expect totalAssets to revert");
        mockPriceOracle.setPrice(0);

        vm.expectRevert(MockPriceOracle.PriceUnavailable.selector);
        vault.totalAssets();
        _step("  PASS: totalAssets reverts when adapter fails");
        _logPass();
    }
}
