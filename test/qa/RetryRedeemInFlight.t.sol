// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategyAdapter} from "../../src/interfaces/adapters/IStrategyAdapter.sol";
import {IStrategyControllerExecutor} from "../../src/interfaces/strategy/IStrategyControllerExecutor.sol";
import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {IMantleVaultGateway} from "../../src/interfaces/vault/IMantleVaultGateway.sol";
import {OperatorExecutor} from "../../src/protocol/OperatorExecutor.sol";
import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {MantleVaultGateway} from "../../src/vault/MantleVaultGateway.sol";
import {VaultFactory} from "../../src/vault/VaultFactory.sol";
import {GatewayFactory} from "../../src/vault/GatewayFactory.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test, console2} from "forge-std/Test.sol";

// ============================================================
// Mock Contracts
// ============================================================

contract MockUSDC_RT is ERC20 {
    constructor() ERC20("MockUSDC", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockSanctionsOracle_RT is ISanctionsOracle {
    function initialize(address, address) external override {}
    function isSanctioned(address) external pure override returns (bool) { return false; }
    function isWhitelisted(address) external pure override returns (bool) { return true; }
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

contract MockAccountant_RT {
    uint256 public exchangeRate = 1e18;
    function getRate() external view returns (uint256) { return exchangeRate; }
    function getRateSafe() external view returns (uint256) { return exchangeRate; }
}

/// @dev Async adapter that tracks retryRedeemAsync calls for test verification.
///      deposit() pulls USDC from vault, mints posToken to self.
///      requestRedeemAsync() pulls posToken from vault (initial divest request).
///      retryRedeemAsync() uses posToken already on adapter (retry after DiGiFT rejection).
///      sweepToVault() transfers actual token balance to vault.
///      totalValue() returns posToken balance on vault (new settled-only semantics).
contract MockAsyncAdapter_RT is IStrategyAdapter {
    address public immutable ASSET;
    address public immutable POS_TOKEN;
    address public vaultAddress;

    // Tracking for test assertions
    uint256 public lastRetryPosAmount;
    uint256 public retryCallCount;

    constructor(address asset_, address posToken_) {
        ASSET = asset_;
        POS_TOKEN = posToken_;
    }

    function setVault(address v) external { vaultAddress = v; }
    function name() external pure returns (string memory) { return "MockAsyncAdapter_RT"; }
    function asset() external view returns (address) { return ASSET; }
    function posToken() external view returns (address) { return POS_TOKEN; }
    function priceOracle() external pure returns (address) { return address(0); }
    function getPosTokenPrice() external pure returns (uint256) { return 1e18; }
    function estimatePosAmount(uint256 assetAmount) external pure returns (uint256) { return assetAmount; }
    function vault() external view returns (address) { return vaultAddress; }

    /// @dev New semantics: only settled posToken on vault, not adapter local balance.
    function totalValue() external view returns (uint256) {
        return IERC20(POS_TOKEN).balanceOf(vaultAddress);
    }

    function deposit(uint256 amount, address) external returns (uint256) {
        IERC20(ASSET).transferFrom(vaultAddress, address(this), amount);
        MockUSDC_RT(POS_TOKEN).mint(address(this), amount);
        return amount;
    }

    function withdrawSync(uint256, address) external pure returns (uint256) {
        revert("async only");
    }

    /// @dev Initial async redeem: controller approves posToken, adapter pulls from vault.
    function requestRedeemAsync(uint256 amount, address) external {
        IERC20(POS_TOKEN).transferFrom(vaultAddress, address(this), amount);
    }

    /// @dev Retry: uses posToken already sitting on adapter (returned by DiGiFT after rejection).
    ///      Simulates sending posToken to external protocol by burning it.
    function retryRedeemAsync(uint256 retryPosAmount, address) external {
        lastRetryPosAmount = retryPosAmount;
        retryCallCount++;
        // Simulate sending posToken to external protocol (burn from adapter)
        // In real adapter, _redeem sends posToken to SubRedManagement contract
        ERC20(POS_TOKEN).transfer(address(0xdead), retryPosAmount);
    }

    function sweepToVault(address token, uint256 amount) external returns (uint256 claimed) {
        if (amount == 0) return 0;
        uint256 bal = IERC20(token).balanceOf(address(this));
        claimed = bal < amount ? bal : amount;
        if (claimed > 0) IERC20(token).transfer(vaultAddress, claimed);
        return claimed;
    }

    function setPaused(bool) external {}
}

/// @dev Sync adapter for testing retry-on-sync-strategy revert.
contract MockSyncAdapter_RT is IStrategyAdapter {
    address public immutable ASSET;
    address public immutable POS_TOKEN;
    address public vaultAddress;

    constructor(address asset_, address posToken_) {
        ASSET = asset_;
        POS_TOKEN = posToken_;
    }

    function setVault(address v) external { vaultAddress = v; }
    function name() external pure returns (string memory) { return "MockSyncAdapter_RT"; }
    function asset() external view returns (address) { return ASSET; }
    function posToken() external view returns (address) { return POS_TOKEN; }
    function priceOracle() external pure returns (address) { return address(0); }
    function getPosTokenPrice() external pure returns (uint256) { return 1e18; }
    function estimatePosAmount(uint256 assetAmount) external pure returns (uint256) { return assetAmount; }
    function vault() external view returns (address) { return vaultAddress; }
    function totalValue() external view returns (uint256) { return IERC20(ASSET).balanceOf(address(this)); }

    function deposit(uint256 amount, address) external returns (uint256) {
        IERC20(ASSET).transferFrom(vaultAddress, address(this), amount);
        return amount;
    }
    function withdrawSync(uint256 amount, address) external returns (uint256) {
        uint256 bal = IERC20(ASSET).balanceOf(address(this));
        return amount > bal ? bal : amount;
    }
    function requestRedeemAsync(uint256, address) external {}
    function retryRedeemAsync(uint256, address) external {}
    function sweepToVault(address token, uint256 amount) external returns (uint256) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 actual = amount > bal ? bal : amount;
        if (actual > 0) IERC20(token).transfer(vaultAddress, actual);
        return actual;
    }
    function setPaused(bool) external {}
}

// ============================================================
// QA Test: Retry Redeem In-Flight
// ============================================================

contract RetryRedeemInFlightQATest is Test {
    MockUSDC_RT internal usdc;
    MockUSDC_RT internal posToken;
    MockUSDC_RT internal posTokenSync;
    MockSanctionsOracle_RT internal oracle;
    MockAccountant_RT internal accountant;

    MantleYieldVault internal vault;
    MantleVaultGateway internal gateway;
    OperatorExecutor internal executor;
    StrategyController internal controller;
    MockAsyncAdapter_RT internal asyncAdapter;
    MockSyncAdapter_RT internal syncAdapter;

    address internal admin = makeAddr("admin");
    address internal bot = makeAddr("bot");
    address internal manager = makeAddr("manager");
    address internal treasury = makeAddr("treasury");
    address internal userA = makeAddr("userA");

    function setUp() public {
        usdc = new MockUSDC_RT();
        posToken = new MockUSDC_RT();
        posTokenSync = new MockUSDC_RT();
        oracle = new MockSanctionsOracle_RT();
        accountant = new MockAccountant_RT();

        // Deploy vault + gateway via factory
        MantleYieldVault vImpl = new MantleYieldVault();
        MantleVaultGateway gImpl = new MantleVaultGateway();
        VaultFactory vf = new VaultFactory(address(vImpl), admin);
        GatewayFactory gf = new GatewayFactory(address(gImpl), admin);
        address vaultAddr = vf.deployVault();
        address gatewayAddr = gf.deployGateway();
        vault = MantleYieldVault(vaultAddr);
        gateway = MantleVaultGateway(gatewayAddr);

        // Deploy real OperatorExecutor
        OperatorExecutor eImpl = new OperatorExecutor();
        executor = OperatorExecutor(address(new ERC1967Proxy(
            address(eImpl),
            abi.encodeCall(OperatorExecutor.initialize, (admin, bot))
        )));

        // Init vault
        vm.prank(admin);
        vault.initialize(IMantleYieldVault.InitParams({
            asset: IERC20(address(usdc)),
            name: "mRWA",
            symbol: "mRWA",
            admin: admin,
            gateway: gatewayAddr,
            controller: address(executor),
            accountant: address(accountant),
            treasury: treasury,
            maxRedemptionFeeBps: 500,
            redemptionFeeBps: 0,
            minRedeemAmount: 0,
            minDepositAmount: 0
        }));

        // Deploy real StrategyController (manager = DEFAULT_ADMIN_ROLE)
        StrategyController cImpl = new StrategyController();
        controller = StrategyController(address(new ERC1967Proxy(
            address(cImpl),
            abi.encodeCall(StrategyController.initialize, (
                vaultAddr, manager, address(executor), manager, 1000, 200, 1 hours
            ))
        )));
        vm.prank(admin);
        vault.setController(address(controller));

        // Init gateway
        vm.prank(admin);
        gateway.initialize(IMantleVaultGateway.InitParams({
            vault: vaultAddr,
            sanctionsOracle: ISanctionsOracle(address(oracle)),
            sanctionSafe: treasury,
            admin: admin,
            syncRedeemDisabled: false
        }));

        // Deploy + register async adapter
        asyncAdapter = new MockAsyncAdapter_RT(address(usdc), address(posToken));
        asyncAdapter.setVault(vaultAddr);
        vm.startPrank(manager);
        controller.registerStrategy(address(asyncAdapter), 10_000, 1, true);
        controller.activateStrategy(address(asyncAdapter));
        address[] memory o = new address[](1);
        o[0] = address(asyncAdapter);
        controller.setStrategyOrder(o);
        vm.stopPrank();

        // Deploy sync adapter (not registered by default)
        syncAdapter = new MockSyncAdapter_RT(address(usdc), address(posTokenSync));
        syncAdapter.setVault(vaultAddr);
    }

    // ----------------------------------------------------------
    // Helpers
    // ----------------------------------------------------------

    function _deposit(address user, uint256 amount) internal {
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(vault), type(uint256).max);
        gateway.deposit(amount);
        vm.stopPrank();
    }

    function _investViaRebalance() internal {
        vm.warp(block.timestamp + 2 hours);
        vm.prank(bot);
        executor.executeRebalance(address(controller));
    }

    function _lastInFlightId() internal view returns (uint256) {
        return vault.nextInFlightId() - 1;
    }

    /// @dev Create a PENDING redeem in-flight via real flow:
    ///      deposit -> rebalance invest -> settle invest -> requestRedeem -> processRedeemBatch (triggers divest)
    function _createRedeemInFlight(uint256 depositAmount)
        internal
        returns (uint256 redeemInFlightId, uint256 reqId)
    {
        // Step 1: deposit and invest
        _deposit(userA, depositAmount);
        _deposit(makeAddr("buffer"), depositAmount); // buffer keeps freeCash > 0 for future ops
        _investViaRebalance();
        uint256 investId = _lastInFlightId();

        // Step 2: settle the invest (posToken arrives at adapter, sweep to vault)
        (,,, uint256 investTokenAmt,,,,, ) = vault.inFlightRecords(investId);
        posToken.mint(address(asyncAdapter), investTokenAmt);
        _settleInvest(_arr(investId), _arr(investTokenAmt), _arr(0));

        // Step 3: user redeems and process batch (triggers divest -> creates redeem in-flight)
        uint256 shares = vault.balanceOf(userA);
        vm.prank(userA);
        reqId = gateway.requestRedeem(shares);

        vm.warp(block.timestamp + 2 hours);
        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), _arr(reqId));
        redeemInFlightId = _lastInFlightId();
    }

    /// @dev Create an invest in-flight via deposit -> rebalance
    function _createInvestInFlight(uint256 depositAmount) internal returns (uint256 investId) {
        _deposit(userA, depositAmount);
        _investViaRebalance();
        investId = _lastInFlightId();
    }

    function _settleInvest(uint256[] memory ids, uint256[] memory posAmts, uint256[] memory refunds) internal {
        vm.prank(bot);
        executor.executeSettleAdapter(
            address(controller),
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(ids, posAmts, refunds),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );
    }

    function _settleRedeem(uint256[] memory ids, uint256[] memory amts) internal {
        vm.prank(bot);
        executor.executeSettleAdapter(
            address(controller),
            address(asyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(new uint256[](0), new uint256[](0), new uint256[](0)),
            IStrategyControllerExecutor.RedeemSettlementInput(ids, amts)
        );
    }

    function _arr(uint256 v) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = v;
    }

    // ----------------------------------------------------------
    // Logging helpers
    // ----------------------------------------------------------

    string constant MODULE = unicode"Retry Redeem In-Flight 场景";
    function _logCase(string memory id, string memory name_) internal pure {
        console2.log(string.concat("testcase module: ", MODULE));
        console2.log(string.concat("testcase id: ", id));
        console2.log(string.concat("testcase name: ", name_));
        console2.log("----------------------------------------");
    }
    function _step(string memory msg_) internal pure { console2.log(msg_); }
    function _logPass() internal pure {
        console2.log("----------------------------------------");
        console2.log("test result: passed");
    }

    // ============================================================
    // P0: Partial amount retry succeeds
    // ============================================================
    function test_RetryRedeemInFlight_PartialAmount_Success() public {
        _logCase(
            "test_RetryRedeemInFlight_PartialAmount_Success",
            unicode"admin 对 PENDING 状态的 async redeem in-flight 发起部分数量 retry 成功"
        );

        _step("[Step 1] Create PENDING redeem in-flight via real flow");
        (uint256 redeemId, ) = _createRedeemInFlight(1000e6);
        (,, address token, uint256 tokenAmount,,,,, IMantleYieldVault.InFlightStatus statusBefore) =
            vault.inFlightRecords(redeemId);
        assertEq(uint8(statusBefore), uint8(IMantleYieldVault.InFlightStatus.PENDING));
        _step(string.concat("  redeemId=", vm.toString(redeemId), " tokenAmount=", vm.toString(tokenAmount)));

        _step("[Step 2] Simulate DiGiFT rejection: posToken returned to adapter");
        uint256 retryAmount = tokenAmount * 60 / 100;
        posToken.mint(address(asyncAdapter), retryAmount);

        _step("[Step 3] Admin calls retryRedeemInFlight with partial amount");
        vm.expectEmit(true, true, false, true, address(controller));
        emit StrategyController.RedeemInFlightRetryRequested(address(asyncAdapter), redeemId, retryAmount);

        vm.prank(manager);
        controller.retryRedeemInFlight(address(asyncAdapter), redeemId, retryAmount);

        _step("[Step 4] Verify: in-flight unchanged (same ID, still PENDING), adapter called");
        (,,,,,,,, IMantleYieldVault.InFlightStatus statusAfter) = vault.inFlightRecords(redeemId);
        assertEq(uint8(statusAfter), uint8(IMantleYieldVault.InFlightStatus.PENDING), "status should remain PENDING");
        assertEq(asyncAdapter.retryCallCount(), 1, "adapter.retryRedeemAsync should be called once");
        assertEq(asyncAdapter.lastRetryPosAmount(), retryAmount, "adapter should receive correct retryPosAmount");

        _step("  PASS: partial retry succeeded, in-flight status unchanged, event emitted");
        _logPass();
    }

    // ============================================================
    // P0: Full amount retry succeeds
    // ============================================================
    function test_RetryRedeemInFlight_FullAmount_Success() public {
        _logCase(
            "test_RetryRedeemInFlight_FullAmount_Success",
            unicode"admin 对 PENDING 状态的 async redeem in-flight 发起全额 retry 成功"
        );

        _step("[Step 1] Create PENDING redeem in-flight");
        (uint256 redeemId, ) = _createRedeemInFlight(1000e6);
        (,,, uint256 tokenAmount,,,,, ) = vault.inFlightRecords(redeemId);

        _step("[Step 2] Simulate full DiGiFT rejection: all posToken returned to adapter");
        posToken.mint(address(asyncAdapter), tokenAmount);

        _step("[Step 3] Admin calls retryRedeemInFlight with full original amount");
        vm.expectEmit(true, true, false, true, address(controller));
        emit StrategyController.RedeemInFlightRetryRequested(address(asyncAdapter), redeemId, tokenAmount);

        vm.prank(manager);
        controller.retryRedeemInFlight(address(asyncAdapter), redeemId, tokenAmount);

        _step("[Step 4] Verify");
        (,,,,,,,, IMantleYieldVault.InFlightStatus statusAfter) = vault.inFlightRecords(redeemId);
        assertEq(uint8(statusAfter), uint8(IMantleYieldVault.InFlightStatus.PENDING), "status should remain PENDING");
        assertEq(asyncAdapter.retryCallCount(), 1);
        assertEq(asyncAdapter.lastRetryPosAmount(), tokenAmount);

        _step("  PASS: full retry succeeded");
        _logPass();
    }

    // ============================================================
    // P0: Revert - non-admin caller
    // ============================================================
    function test_RetryRedeemInFlight_RevertNonAdmin() public {
        _logCase(
            "test_RetryRedeemInFlight_RevertNonAdmin",
            unicode"非 admin 调用 retryRedeemInFlight 应 revert"
        );

        _step("[Step 1] Create PENDING redeem in-flight");
        (uint256 redeemId, ) = _createRedeemInFlight(1000e6);
        (,,, uint256 tokenAmount,,,,, ) = vault.inFlightRecords(redeemId);
        posToken.mint(address(asyncAdapter), tokenAmount);

        _step("[Step 2] Bot (non-admin) attempts retry");
        vm.expectRevert(abi.encodeWithSelector(
            bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
            bot,
            bytes32(0) // DEFAULT_ADMIN_ROLE
        ));
        vm.prank(bot);
        controller.retryRedeemInFlight(address(asyncAdapter), redeemId, tokenAmount);

        _step("  PASS: non-admin caller reverted");
        _logPass();
    }

    // ============================================================
    // P0: Revert - sync strategy
    // ============================================================
    function test_RetryRedeemInFlight_RevertSyncStrategy() public {
        _logCase(
            "test_RetryRedeemInFlight_RevertSyncStrategy",
            unicode"对 sync strategy 调用 retryRedeemInFlight 应 revert RetryOnlyAsyncStrategy"
        );

        _step("[Step 1] Register sync adapter");
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 5000, 2, false);
        controller.activateStrategy(address(syncAdapter));
        vm.stopPrank();

        _step("[Step 2] Create a redeem in-flight via async adapter for use as valid ID");
        (uint256 redeemId, ) = _createRedeemInFlight(1000e6);

        _step("[Step 3] Admin attempts retry targeting sync adapter");
        vm.expectRevert(abi.encodeWithSelector(StrategyController.RetryOnlyAsyncStrategy.selector, address(syncAdapter)));
        vm.prank(manager);
        controller.retryRedeemInFlight(address(syncAdapter), redeemId, 100e6);

        _step("  PASS: sync strategy reverted with RetryOnlyAsyncStrategy");
        _logPass();
    }

    // ============================================================
    // P0: Revert - in-flight already CONFIRMED (non-PENDING)
    // ============================================================
    function test_RetryRedeemInFlight_RevertNonPending() public {
        _logCase(
            "test_RetryRedeemInFlight_RevertNonPending",
            unicode"对已 CONFIRMED 的 in-flight 调用 retryRedeemInFlight 应 revert InvalidRedeemInFlight"
        );

        _step("[Step 1] Create and settle redeem in-flight to CONFIRMED");
        (uint256 redeemId, ) = _createRedeemInFlight(1000e6);
        (,,,, uint256 usdcAmount,,,, ) = vault.inFlightRecords(redeemId);
        usdc.mint(address(asyncAdapter), usdcAmount);
        _settleRedeem(_arr(redeemId), _arr(usdcAmount));

        (,,,,,,,, IMantleYieldVault.InFlightStatus status) = vault.inFlightRecords(redeemId);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED), "should be CONFIRMED after settle");

        _step("[Step 2] Admin attempts retry on CONFIRMED in-flight");
        vm.expectRevert(abi.encodeWithSelector(StrategyController.InvalidRedeemInFlight.selector, redeemId));
        vm.prank(manager);
        controller.retryRedeemInFlight(address(asyncAdapter), redeemId, 100e6);

        _step("  PASS: CONFIRMED in-flight reverted with InvalidRedeemInFlight");
        _logPass();
    }

    // ============================================================
    // P0: Revert - adapter mismatch
    // ============================================================
    function test_RetryRedeemInFlight_RevertAdapterMismatch() public {
        _logCase(
            "test_RetryRedeemInFlight_RevertAdapterMismatch",
            unicode"传入的 adapter 与 in-flight 记录的 adapter 不匹配时应 revert InvalidRedeemInFlight"
        );

        _step("[Step 1] Create redeem in-flight on asyncAdapter");
        (uint256 redeemId, ) = _createRedeemInFlight(1000e6);

        _step("[Step 2] Register a second async adapter");
        MockAsyncAdapter_RT asyncAdapter2 = new MockAsyncAdapter_RT(address(usdc), address(posToken));
        asyncAdapter2.setVault(address(vault));
        vm.startPrank(manager);
        controller.registerStrategy(address(asyncAdapter2), 5000, 2, true);
        controller.activateStrategy(address(asyncAdapter2));
        vm.stopPrank();

        _step("[Step 3] Admin attempts retry with wrong adapter");
        vm.expectRevert(abi.encodeWithSelector(StrategyController.InvalidRedeemInFlight.selector, redeemId));
        vm.prank(manager);
        controller.retryRedeemInFlight(address(asyncAdapter2), redeemId, 100e6);

        _step("  PASS: adapter mismatch reverted with InvalidRedeemInFlight");
        _logPass();
    }

    // ============================================================
    // P0: Revert - retryPosAmount exceeds original tokenAmount
    // ============================================================
    function test_RetryRedeemInFlight_RevertExceedsOriginal() public {
        _logCase(
            "test_RetryRedeemInFlight_RevertExceedsOriginal",
            unicode"retryPosAmount 超过原始 in-flight tokenAmount 时应 revert InvalidRetryAmount"
        );

        _step("[Step 1] Create PENDING redeem in-flight");
        (uint256 redeemId, ) = _createRedeemInFlight(1000e6);
        (,,, uint256 tokenAmount,,,,, ) = vault.inFlightRecords(redeemId);

        _step("[Step 2] Admin attempts retry with amount > original");
        uint256 excessAmount = tokenAmount + 1;
        vm.expectRevert(StrategyController.InvalidRetryAmount.selector);
        vm.prank(manager);
        controller.retryRedeemInFlight(address(asyncAdapter), redeemId, excessAmount);

        _step("  PASS: excess amount reverted with InvalidRetryAmount");
        _logPass();
    }

    // ============================================================
    // P0: Revert - invest in-flight ID (not redeem)
    // ============================================================
    function test_RetryRedeemInFlight_RevertInvestInFlight() public {
        _logCase(
            "test_RetryRedeemInFlight_RevertInvestInFlight",
            unicode"对 invest 类型的 in-flight 调用 retryRedeemInFlight 应 revert InvalidRedeemInFlight"
        );

        _step("[Step 1] Create invest in-flight");
        uint256 investId = _createInvestInFlight(1000e6);
        (,,,,,, bool isInvest,, IMantleYieldVault.InFlightStatus status) = vault.inFlightRecords(investId);
        assertTrue(isInvest, "should be invest in-flight");
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.PENDING));

        _step("[Step 2] Admin attempts retry on invest in-flight");
        vm.expectRevert(abi.encodeWithSelector(StrategyController.InvalidRedeemInFlight.selector, investId));
        vm.prank(manager);
        controller.retryRedeemInFlight(address(asyncAdapter), investId, 100e6);

        _step("  PASS: invest in-flight reverted with InvalidRedeemInFlight");
        _logPass();
    }

    // ============================================================
    // P0: Revert - zero retryPosAmount
    // ============================================================
    function test_RetryRedeemInFlight_RevertZeroAmount() public {
        _logCase(
            "test_RetryRedeemInFlight_RevertZeroAmount",
            unicode"retryPosAmount = 0 时应 revert InvalidRetryAmount"
        );

        (uint256 redeemId, ) = _createRedeemInFlight(1000e6);

        vm.expectRevert(StrategyController.InvalidRetryAmount.selector);
        vm.prank(manager);
        controller.retryRedeemInFlight(address(asyncAdapter), redeemId, 0);

        _step("  PASS: zero amount reverted with InvalidRetryAmount");
        _logPass();
    }

    // ============================================================
    // P1: End-to-end: retry then settle successfully
    // ============================================================
    function test_RetryRedeemInFlight_ThenSettle_Success() public {
        _logCase(
            "test_RetryRedeemInFlight_ThenSettle_Success",
            unicode"retry 后正常 settle：retry -> DiGiFT 处理 -> settleAdapter sweep -> in-flight CONFIRMED"
        );

        _step("[Step 1] Create PENDING redeem in-flight");
        (uint256 redeemId, uint256 reqId) = _createRedeemInFlight(1000e6);
        (,,,uint256 tokenAmount, uint256 usdcAmount,,,, ) = vault.inFlightRecords(redeemId);
        _step(string.concat("  redeemId=", vm.toString(redeemId),
            " tokenAmount=", vm.toString(tokenAmount),
            " usdcAmount=", vm.toString(usdcAmount)));

        _step("[Step 2] Simulate DiGiFT rejection: posToken returned to adapter, then retry");
        posToken.mint(address(asyncAdapter), tokenAmount);
        vm.prank(manager);
        controller.retryRedeemInFlight(address(asyncAdapter), redeemId, tokenAmount);
        assertEq(asyncAdapter.retryCallCount(), 1);

        _step("[Step 3] Simulate DiGiFT processes retry: USDC arrives at adapter");
        usdc.mint(address(asyncAdapter), usdcAmount);

        _step("[Step 4] Settle redeem: sweep USDC from adapter to vault, confirm in-flight");
        uint256 redeemInFlightBefore = vault.totalRedeemInFlight();
        uint256 vaultUsdcBefore = usdc.balanceOf(address(vault));

        _settleRedeem(_arr(redeemId), _arr(usdcAmount));

        _step("[Step 5] Verify: in-flight CONFIRMED, USDC swept to vault, stats cleared");
        (,,,,, uint256 settledAmount,,, IMantleYieldVault.InFlightStatus statusFinal) =
            vault.inFlightRecords(redeemId);
        assertEq(uint8(statusFinal), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED), "should be CONFIRMED");
        assertEq(settledAmount, usdcAmount, "settledAmount should match sweep amount");
        assertEq(vault.totalRedeemInFlight(), redeemInFlightBefore - usdcAmount, "totalRedeemInFlight decreased");
        assertGt(usdc.balanceOf(address(vault)), vaultUsdcBefore, "vault USDC should increase from sweep");

        _step("[Step 6] Finalize redeem batch: user receives USDC");
        uint256 userUsdcBefore = usdc.balanceOf(userA);

        // Compute settled assets from shares and exchange rate
        (,, uint256 netShares,, uint256 estAssets,,, ) = vault.requests(reqId);
        vm.warp(block.timestamp + 2 hours);
        vm.prank(bot);
        executor.executeFinalizeRedeemBatch(address(controller), _arr(reqId), _arr(estAssets));

        uint256 userUsdcAfter = usdc.balanceOf(userA);
        assertGt(userUsdcAfter, userUsdcBefore, "user should receive USDC after finalize");

        (,,,,,,,IMantleYieldVault.RequestStatus reqStatus) = vault.requests(reqId);
        assertEq(uint8(reqStatus), uint8(IMantleYieldVault.RequestStatus.DONE), "request should be DONE");

        _step("  PASS: full retry -> settle -> finalize flow completed, user received USDC");
        _logPass();
    }

    // ============================================================
    // P0: Revert - unregistered strategy
    // ============================================================
    function test_RetryRedeemInFlight_RevertUnregisteredStrategy() public {
        _logCase(
            "test_RetryRedeemInFlight_RevertUnregisteredStrategy",
            unicode"传入未注册的 adapter 地址应 revert InvalidStrategy"
        );

        _step("[Step 1] Create PENDING redeem in-flight on registered adapter");
        (uint256 redeemId, ) = _createRedeemInFlight(1000e6);

        _step("[Step 2] Admin attempts retry with unregistered adapter address");
        address fakeAdapter = makeAddr("unregistered");
        vm.expectRevert(abi.encodeWithSelector(StrategyController.InvalidStrategy.selector, fakeAdapter));
        vm.prank(manager);
        controller.retryRedeemInFlight(fakeAdapter, redeemId, 100e6);

        _step("  PASS: unregistered adapter reverted with InvalidStrategy");
        _logPass();
    }

    // ============================================================
    // P0: Revert - non-existent inFlightId
    // ============================================================
    function test_RetryRedeemInFlight_RevertNonExistentId() public {
        _logCase(
            "test_RetryRedeemInFlight_RevertNonExistentId",
            unicode"传入不存在的 inFlightId 应 revert InvalidRedeemInFlight"
        );

        _step("[Step 1] Use an ID that was never created");
        uint256 fakeId = 999;

        _step("[Step 2] Admin attempts retry with non-existent ID");
        // vault.inFlightRecords(999) returns defaults: adapter=address(0), status=NONE
        // recordAdapter(0x0) != asyncAdapter -> revert InvalidRedeemInFlight
        vm.expectRevert(abi.encodeWithSelector(StrategyController.InvalidRedeemInFlight.selector, fakeId));
        vm.prank(manager);
        controller.retryRedeemInFlight(address(asyncAdapter), fakeId, 100e6);

        _step("  PASS: non-existent ID reverted with InvalidRedeemInFlight");
        _logPass();
    }

    // ============================================================
    // P1: Multiple retries on same in-flight
    // ============================================================
    function test_RetryRedeemInFlight_MultipleRetries_Success() public {
        _logCase(
            "test_RetryRedeemInFlight_MultipleRetries_Success",
            unicode"DiGiFT 多次拒绝后 admin 可多次 retry 同一 in-flight"
        );

        _step("[Step 1] Create PENDING redeem in-flight");
        (uint256 redeemId, ) = _createRedeemInFlight(1000e6);
        (,,, uint256 tokenAmount,,,,, ) = vault.inFlightRecords(redeemId);

        _step("[Step 2] First retry: DiGiFT rejects, posToken returned, admin retries");
        posToken.mint(address(asyncAdapter), tokenAmount);
        vm.prank(manager);
        controller.retryRedeemInFlight(address(asyncAdapter), redeemId, tokenAmount);
        assertEq(asyncAdapter.retryCallCount(), 1, "first retry call");

        _step("[Step 3] Second retry: DiGiFT rejects again, posToken returned again, admin retries again");
        posToken.mint(address(asyncAdapter), tokenAmount);
        vm.prank(manager);
        controller.retryRedeemInFlight(address(asyncAdapter), redeemId, tokenAmount);
        assertEq(asyncAdapter.retryCallCount(), 2, "second retry call");

        _step("[Step 4] Verify in-flight still PENDING after two retries");
        (,,,,,,,, IMantleYieldVault.InFlightStatus status) = vault.inFlightRecords(redeemId);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.PENDING), "still PENDING after 2 retries");

        _step("  PASS: multiple retries on same in-flight all succeeded");
        _logPass();
    }

    // ============================================================
    // P1: Retry does not create new in-flight, original fields unchanged
    // ============================================================
    function test_RetryRedeemInFlight_InFlightFieldsUnchanged() public {
        _logCase(
            "test_RetryRedeemInFlight_InFlightFieldsUnchanged",
            unicode"retry 不创建新 in-flight，原始记录的所有字段保持不变"
        );

        _step("[Step 1] Create PENDING redeem in-flight and snapshot all fields");
        (uint256 redeemId, ) = _createRedeemInFlight(1000e6);
        uint256 nextIdBefore = vault.nextInFlightId();
        (
            uint256 idBefore, address adapterBefore, address tokenBefore,
            uint256 tokenAmountBefore, uint256 usdcAmountBefore, uint256 settledBefore,
            bool isInvestBefore, uint256 timestampBefore, IMantleYieldVault.InFlightStatus statusBefore
        ) = vault.inFlightRecords(redeemId);

        _step("[Step 2] Retry");
        posToken.mint(address(asyncAdapter), tokenAmountBefore);
        vm.prank(manager);
        controller.retryRedeemInFlight(address(asyncAdapter), redeemId, tokenAmountBefore);

        _step("[Step 3] Verify nextInFlightId unchanged (no new in-flight created)");
        assertEq(vault.nextInFlightId(), nextIdBefore, "nextInFlightId should not change");

        _step("[Step 4] Verify all original fields preserved");
        (
            uint256 idAfter, address adapterAfter, address tokenAfter,
            uint256 tokenAmountAfter, uint256 usdcAmountAfter, uint256 settledAfter,
            bool isInvestAfter, uint256 timestampAfter, IMantleYieldVault.InFlightStatus statusAfter
        ) = vault.inFlightRecords(redeemId);

        assertEq(idAfter, idBefore, "id unchanged");
        assertEq(adapterAfter, adapterBefore, "adapter unchanged");
        assertEq(tokenAfter, tokenBefore, "token unchanged");
        assertEq(tokenAmountAfter, tokenAmountBefore, "tokenAmount unchanged");
        assertEq(usdcAmountAfter, usdcAmountBefore, "usdcAmount unchanged");
        assertEq(settledAfter, settledBefore, "settledAmount unchanged");
        assertEq(isInvestAfter, isInvestBefore, "isInvest unchanged");
        assertEq(timestampAfter, timestampBefore, "timestamp unchanged");
        assertEq(uint8(statusAfter), uint8(statusBefore), "status unchanged (PENDING)");

        _step("  PASS: retry does not mutate in-flight record, no new in-flight created");
        _logPass();
    }

    // ============================================================
    // P1: Deactivated strategy can still retry (in-flight already exists)
    // ============================================================
    function test_RetryRedeemInFlight_DeactivatedStrategy_Success() public {
        _logCase(
            "test_RetryRedeemInFlight_DeactivatedStrategy_Success",
            unicode"策略被停用后仍可 retry 已有的 in-flight（合约不检查 isActive）"
        );

        _step("[Step 1] Create PENDING redeem in-flight while strategy is active");
        (uint256 redeemId, ) = _createRedeemInFlight(1000e6);
        (,,, uint256 tokenAmount,,,,, ) = vault.inFlightRecords(redeemId);

        _step("[Step 2] Force-deactivate strategy via vm.store");
        // Precondition: strategy is active
        // strategyInfo returns (targetWeightBps, priority, isAsync, isActive, exists)
        (,, bool isAsyncBefore, bool isActiveBefore,) = controller.strategyInfo(address(asyncAdapter));
        assertTrue(isAsyncBefore, "precondition: strategy isAsync");
        assertTrue(isActiveBefore, "precondition: strategy isActive");

        // strategyInfo mapping is at slot 3.
        // StrategyInfo packs (from low byte): targetWeightBps(2), priority(2), isAsync(1), isActive(1), exists(1)
        // isActive is at byte offset 5 (bit 40). Flip it to 0.
        bytes32 infoSlot = keccak256(abi.encode(address(asyncAdapter), uint256(3)));
        bytes32 currentVal = vm.load(address(controller), infoSlot);
        // Clear byte 5 (isActive) by masking out bits 47:40
        bytes32 mask = ~bytes32(uint256(0xff) << 40);
        bytes32 newVal = currentVal & mask;
        vm.store(address(controller), infoSlot, newVal);

        // Verify deactivated
        (,,, bool isActiveAfter,) = controller.strategyInfo(address(asyncAdapter));
        assertFalse(isActiveAfter, "strategy should be deactivated");
        _step("  Strategy force-deactivated via vm.store");

        _step("[Step 3] Retry on deactivated strategy - should succeed");
        posToken.mint(address(asyncAdapter), tokenAmount);
        vm.prank(manager);
        controller.retryRedeemInFlight(address(asyncAdapter), redeemId, tokenAmount);

        (,,,,,,,, IMantleYieldVault.InFlightStatus status) = vault.inFlightRecords(redeemId);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.PENDING));
        assertEq(asyncAdapter.retryCallCount(), 1);
        _step("  PASS: retry succeeded on deactivated strategy (contract only checks exists+isAsync)");
        _logPass();
    }

    // ============================================================
    // P1: Partial retry then settle with partial amount
    // ============================================================
    function test_RetryRedeemInFlight_PartialRetry_ThenPartialSettle() public {
        _logCase(
            "test_RetryRedeemInFlight_PartialRetry_ThenPartialSettle",
            unicode"部分 retry 后 DiGiFT 只处理了 retry 数量对应的资产，settle 使用部分金额"
        );

        _step("[Step 1] Create PENDING redeem in-flight");
        (uint256 redeemId, uint256 reqId) = _createRedeemInFlight(1000e6);
        (,,, uint256 tokenAmount, uint256 originalUsdcAmount,,,, ) = vault.inFlightRecords(redeemId);
        _step(string.concat("  original tokenAmount=", vm.toString(tokenAmount),
            " usdcAmount=", vm.toString(originalUsdcAmount)));

        _step("[Step 2] Partial retry: 60% of original posToken");
        uint256 retryAmount = tokenAmount * 60 / 100;
        posToken.mint(address(asyncAdapter), retryAmount);
        vm.prank(manager);
        controller.retryRedeemInFlight(address(asyncAdapter), redeemId, retryAmount);

        _step("[Step 3] DiGiFT processes only the retry portion, returns proportional USDC");
        // retryAmount is 60% of tokenAmount, so USDC returned is ~60% of original
        uint256 partialUsdc = originalUsdcAmount * 60 / 100;
        usdc.mint(address(asyncAdapter), partialUsdc);

        _step("[Step 4] Settle with partial USDC amount");
        uint256 redeemIFBefore = vault.totalRedeemInFlight();
        _settleRedeem(_arr(redeemId), _arr(partialUsdc));

        _step("[Step 5] Verify in-flight CONFIRMED with partial settledAmount");
        (,,,,, uint256 settledAmount,,, IMantleYieldVault.InFlightStatus finalStatus) =
            vault.inFlightRecords(redeemId);
        assertEq(uint8(finalStatus), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(settledAmount, partialUsdc, "settledAmount should be partial USDC");
        // totalRedeemInFlight decreases by original usdcAmount (not settledAmount)
        assertEq(vault.totalRedeemInFlight(), redeemIFBefore - originalUsdcAmount,
            "totalRedeemInFlight decreases by original usdcAmount, not settled");

        _step(string.concat("  settled: ", vm.toString(partialUsdc),
            " (vs original: ", vm.toString(originalUsdcAmount), ")"));
        _step("  PASS: partial retry -> partial settle -> CONFIRMED, stats cleared by original amount");
        _logPass();
    }

    // ============================================================
    // P1: Retry then abnormal settle (settledAmount=0)
    // ============================================================
    function test_RetryRedeemInFlight_ThenAbnormalSettle() public {
        _logCase(
            "test_RetryRedeemInFlight_ThenAbnormalSettle",
            unicode"retry 后 DiGiFT 仍无法处理，通过 abnormal 路径 settle（settledAmount=0）"
        );

        _step("[Step 1] Create PENDING redeem in-flight");
        (uint256 redeemId, ) = _createRedeemInFlight(1000e6);
        (,,, uint256 tokenAmount, uint256 usdcAmount,,,, ) = vault.inFlightRecords(redeemId);

        _step("[Step 2] Retry");
        posToken.mint(address(asyncAdapter), tokenAmount);
        vm.prank(manager);
        controller.retryRedeemInFlight(address(asyncAdapter), redeemId, tokenAmount);

        _step("[Step 3] DiGiFT still fails - settle with amount=0 via abnormal path");
        // settleAdapter with redeemSettledAmount=0 triggers abnormal confirm in controller
        // The controller calls vault.confirmInFlight(redeemId, 0, true) for abnormal
        uint256 redeemIFBefore = vault.totalRedeemInFlight();

        // Settle redeem with 0 amount (abnormal - no USDC returned)
        _settleRedeem(_arr(redeemId), _arr(0));

        _step("[Step 4] Verify in-flight CONFIRMED with settledAmount=0 (abnormal)");
        (,,,,, uint256 settledAmount,,, IMantleYieldVault.InFlightStatus status) =
            vault.inFlightRecords(redeemId);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        assertEq(settledAmount, 0, "settledAmount should be 0 in abnormal path");
        assertEq(vault.totalRedeemInFlight(), redeemIFBefore - usdcAmount,
            "totalRedeemInFlight still decreases by original usdcAmount");

        _step("  PASS: abnormal settle after retry - CONFIRMED with 0 settled, stats cleared");
        _logPass();
    }
}
