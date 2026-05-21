// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SubRedManagementAdapter} from "../../src/adapters/digift/SubRedManagementAdapter.sol";
import {ISubRedManagement} from "../../src/interfaces/adapters/digift/ISubRedManagement.sol";
import {MockDFeedPriceOracle} from "../../src/mocks/strategy/MockDFeedPriceOracle.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

contract MockStable is ERC20 {
    constructor() ERC20("MockStable", "mStable") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockSTToken is ERC20 {
    constructor() ERC20("MockST", "mST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockSTToken6 is ERC20 {
    constructor() ERC20("MockST6", "mST6") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract MockVaultForAdapter {
    ERC20 public immutable stable;

    constructor(address asset_) {
        stable = ERC20(asset_);
    }

    function asset() external view returns (address) {
        return address(stable);
    }

    function approveToAdapter(address adapter, uint256 amount) external {
        stable.approve(adapter, amount);
    }

    function approveTokenToAdapter(address token, address adapter, uint256 amount) external {
        ERC20(token).approve(adapter, amount);
    }
}

contract MockSubRedManagement is ISubRedManagement {
    address public lastStToken;
    address public lastCurrencyToken;
    uint256 public lastAmount;
    uint256 public lastDeadline;
    uint256 public subscribeCount;
    uint256 public redeemCount;
    address public lastRedeemStToken;
    address public lastRedeemCurrencyToken;
    uint256 public lastRedeemQuantity;
    uint256 public lastRedeemDeadline;

    function subscribe(address stToken, address currencyToken, uint256 amount, uint256 deadline) external override {
        lastStToken = stToken;
        lastCurrencyToken = currencyToken;
        lastAmount = amount;
        lastDeadline = deadline;
        subscribeCount++;

        ERC20(currencyToken).transferFrom(msg.sender, address(this), amount);
    }

    function redeem(address stToken, address currencyToken, uint256 quantity, uint256 deadline) external override {
        lastRedeemStToken = stToken;
        lastRedeemCurrencyToken = currencyToken;
        lastRedeemQuantity = quantity;
        lastRedeemDeadline = deadline;
        redeemCount++;
    }
}

contract SubRedManagementAdapterTest is Test {
    error EnforcedPause();

    event Paused(address account);
    event Unpaused(address account);
    event AdapterRedeemRequested(
        address indexed adapter, address indexed caller, uint256 amount, address indexed receiver
    );

    MockStable internal stable;
    MockStable internal dustToken;
    MockVaultForAdapter internal vault;
    MockSubRedManagement internal subRed;
    MockSTToken internal stToken;
    MockSTToken6 internal stToken6;
    SubRedManagementAdapter internal adapter;
    SubRedManagementAdapter internal adapterWithOracle;
    MockDFeedPriceOracle internal oracle;

    address internal operator = makeAddr("operator");
    address internal receiver = makeAddr("receiver");
    address internal other = makeAddr("other");

    uint256 internal constant SUBSCRIBE_STEP_ASSET = 1e16; // 0.01 with 18-dec asset
    uint256 internal constant REDEEM_STEP_POS_18 = 1e18; // 1 whole token
    uint256 internal constant REDEEM_STEP_POS_6 = 1e6; // 1 whole token

    function setUp() public {
        stable = new MockStable();
        dustToken = new MockStable();
        vault = new MockVaultForAdapter(address(stable));
        subRed = new MockSubRedManagement();
        stToken = new MockSTToken();
        stToken6 = new MockSTToken6();
        oracle = new MockDFeedPriceOracle(2 * 10 ** 8, 8);

        adapter = new SubRedManagementAdapter(
            address(vault), address(subRed), address(stToken), address(this), address(this), address(this), address(0)
        );
        adapter.setManualPosTokenPrice(1e18);
        adapterWithOracle = new SubRedManagementAdapter(
            address(vault),
            address(subRed),
            address(stToken6),
            address(this),
            address(this),
            address(this),
            address(oracle)
        );
    }

    function test_DepositPullsFromVaultAndSubscribes() public {
        stable.mint(address(vault), 1_000e18);
        vault.approveToAdapter(address(adapter), 500e18);

        uint256 subscribed = adapter.deposit(100e18, address(0));
        assertEq(subscribed, 100e18);
        assertEq(subRed.subscribeCount(), 1);
        assertEq(subRed.lastStToken(), address(stToken));
        assertEq(subRed.lastCurrencyToken(), address(stable));
        assertEq(subRed.lastAmount(), 100e18);
        assertEq(stable.balanceOf(address(subRed)), 100e18);
    }

    function test_RequestRedeemAsyncPullsPosTokenFromVault() public {
        stToken.mint(address(vault), 300e18);
        vault.approveTokenToAdapter(address(stToken), address(adapter), 300e18);

        adapter.requestRedeemAsync(200e18, receiver);
        assertEq(subRed.redeemCount(), 1);
        assertEq(subRed.lastRedeemStToken(), address(stToken));
        assertEq(subRed.lastRedeemCurrencyToken(), address(stable));
        assertEq(subRed.lastRedeemQuantity(), 200e18);
        assertEq(stToken.balanceOf(address(adapter)), 200e18);
    }

    function test_RequestRedeemAsync_EmitsRequestEventWithoutSyntheticRequestId() public {
        stToken.mint(address(vault), 300e18);
        vault.approveTokenToAdapter(address(stToken), address(adapter), 300e18);

        vm.expectEmit(true, true, true, true, address(adapter));
        emit AdapterRedeemRequested(address(adapter), address(this), 200e18, receiver);

        adapter.requestRedeemAsync(200e18, receiver);
    }

    function test_RetryRedeemAsync_UsesAdapterLocalPosBalance() public {
        stToken.mint(address(adapter), 300e18);

        adapter.retryRedeemAsync(120e18, receiver);
        assertEq(subRed.redeemCount(), 1);
        assertEq(subRed.lastRedeemStToken(), address(stToken));
        assertEq(subRed.lastRedeemCurrencyToken(), address(stable));
        assertEq(subRed.lastRedeemQuantity(), 120e18);
    }

    function test_RetryRedeemAsync_EmitsRequestEventEstimatedFromRetryPosAmount() public {
        stToken.mint(address(adapter), 300e18);

        vm.expectEmit(true, true, true, true, address(adapter));
        emit AdapterRedeemRequested(address(adapter), address(this), 120e18, receiver);

        adapter.retryRedeemAsync(120e18, receiver);
    }

    function test_RetryRedeemAsync_OracleAdapterEmitsPosAmountNotAssetAmount() public {
        stToken6.mint(address(adapterWithOracle), 300e6);

        vm.expectEmit(true, true, true, true, address(adapterWithOracle));
        emit AdapterRedeemRequested(address(adapterWithOracle), address(this), 120e6, receiver);

        adapterWithOracle.retryRedeemAsync(120e6, receiver);
    }

    function test_RetryRedeemAsync_DoesNotEmitCustomRetryEvent() public {
        stToken.mint(address(adapter), 300e18);

        vm.recordLogs();
        adapter.retryRedeemAsync(120e18, receiver);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 retryTopic = keccak256("AdapterRedeemRetried(address,address,uint256,uint256,address)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertFalse(
                logs[i].emitter == address(adapter) && logs[i].topics.length > 0 && logs[i].topics[0] == retryTopic
            );
        }
    }

    function test_RevertWhen_RetryRedeemAsyncWithoutEnoughAdapterPosBalance() public {
        stToken.mint(address(adapter), 80e18);

        vm.expectRevert();
        adapter.retryRedeemAsync(120e18, receiver);
    }

    function test_RevertWhen_RetryRedeemAsyncCalledByNonController() public {
        stToken.mint(address(adapter), 300e18);

        vm.prank(other);
        vm.expectRevert();
        adapter.retryRedeemAsync(120e18, receiver);
    }

    function test_SweepToVault_ReturnsTokenBalance() public {
        stable.mint(address(adapter), 150e18);
        uint256 claimed = adapter.sweepToVault(address(stable), 100e18);
        assertEq(claimed, 100e18);
        assertEq(stable.balanceOf(address(vault)), 100e18);
        assertEq(stable.balanceOf(address(adapter)), 50e18);
    }

    function test_RevertWhen_SweepToVaultCalledByNonController() public {
        vm.prank(other);
        vm.expectRevert();
        adapter.sweepToVault(address(stable), 1e18);
    }

    function test_RevertWhen_RequestRedeemWithoutVaultPosAllowance() public {
        stToken.mint(address(vault), 100e18);
        vm.expectRevert();
        adapter.requestRedeemAsync(100e18, receiver);
    }

    function test_RevertWhen_SetPausedByUnauthorized() public {
        vm.prank(other);
        vm.expectRevert();
        adapter.setPaused(true);
    }

    function test_SetPaused_EmitsOZPausableEventsAndRemainsIdempotent() public {
        vm.expectEmit(false, false, false, true, address(adapter));
        emit Paused(address(this));
        adapter.setPaused(true);
        assertTrue(adapter.paused());

        adapter.setPaused(true);
        assertTrue(adapter.paused());

        vm.expectEmit(false, false, false, true, address(adapter));
        emit Unpaused(address(this));
        adapter.setPaused(false);
        assertFalse(adapter.paused());

        adapter.setPaused(false);
        assertFalse(adapter.paused());
    }

    function test_RevertWhen_DepositPaused_UsesOZPausableError() public {
        stable.mint(address(vault), 1_000e18);
        vault.approveToAdapter(address(adapter), 500e18);
        adapter.setPaused(true);

        vm.expectRevert(EnforcedPause.selector);
        adapter.deposit(100e18, address(0));
    }

    function test_SweepDustToken_Success() public {
        dustToken.mint(address(adapter), 15e18);
        adapter.sweep(address(dustToken), receiver);
        assertEq(dustToken.balanceOf(receiver), 15e18);
        assertEq(dustToken.balanceOf(address(adapter)), 0);
    }

    function test_RevertWhen_SweepWithZeroReceiver() public {
        dustToken.mint(address(adapter), 1e18);
        vm.expectRevert();
        adapter.sweep(address(dustToken), address(0));
    }

    function test_RevertWhen_SweepWithZeroToken() public {
        vm.expectRevert();
        adapter.sweep(address(0), receiver);
    }

    function test_EstimatePosAmount_UsesOraclePrice() public view {
        // asset decimals = 18, st decimals = 6, price decimals = 8, price = 2
        // position = amountAsset * 1e8 * 1e6 / (2e8 * 1e18) = amountAsset / (2 * 1e12)
        uint256 amountAsset = 1000e18;
        uint256 pos = adapterWithOracle.estimatePosAmount(amountAsset);
        assertEq(pos, 500_000_000); // 500 * 1e6
    }

    function test_TotalValue_UsesOraclePrice() public {
        // stToken6 has 6 decimals; mint 500 tokens => 500e6 raw.
        // with price=2 and oracle decimals 8, asset value should be 1000e18.
        stToken6.mint(address(vault), 500e6);
        uint256 value = adapterWithOracle.totalValue();
        assertEq(value, 1000e18);
    }

    function test_TotalValue_IgnoresAdapterLocalAssetPendingSettlement() public {
        stToken6.mint(address(vault), 500e6);
        stable.mint(address(adapterWithOracle), 100e18);

        uint256 value = adapterWithOracle.totalValue();
        assertEq(value, 1000e18);
    }

    function test_EstimatePosAmount_ReturnsZeroWhenOraclePriceZero() public {
        oracle.setPrice(0);

        uint256 amountAsset = 2000e18;
        uint256 pos = adapterWithOracle.estimatePosAmount(amountAsset);
        assertEq(pos, 0);

        stToken6.mint(address(vault), 500e6);
        assertEq(adapterWithOracle.totalValue(), 0);
    }

    function test_GetPosTokenPrice_DoesNotFallbackToManualWhenOracleConfigured() public {
        adapter.setManualPosTokenPrice(4e18);
        adapter.setPriceOracle(address(oracle));
        oracle.setPrice(0);

        assertEq(adapter.getPosTokenPrice(), 0);
    }

    function test_GetPosTokenPrice_ReturnsZeroWhenOracleNormalizesToZero() public {
        adapter.setManualPosTokenPrice(4e18);
        oracle.setDecimals(20);
        oracle.setPrice(1);
        adapter.setPriceOracle(address(oracle));

        assertEq(adapter.getPosTokenPrice(), 0);

        stToken.mint(address(vault), 500e18);
        assertEq(adapter.totalValue(), 0);
    }

    function test_RevertWhen_SetManualPosTokenPrice_WithOracleConfigured() public {
        vm.expectRevert();
        adapterWithOracle.setManualPosTokenPrice(5e18);
    }

    function test_SetManualPosTokenPrice_AfterDisablingOracle() public {
        adapterWithOracle.setPriceOracle(address(0));
        adapterWithOracle.setManualPosTokenPrice(4e18);
        assertEq(adapterWithOracle.getPosTokenPrice(), 4e18);
    }

    function test_GetPosTokenPrice_UsesManualWhenNoOracleConfigured() public {
        adapter.setManualPosTokenPrice(4e18);
        assertEq(adapter.getPosTokenPrice(), 4e18);
    }

    function test_PreviewDeposit_FloorsToIncrement() public {
        adapter.setExecutionConstraints(0, SUBSCRIBE_STEP_ASSET, 0, REDEEM_STEP_POS_18);

        uint256 rawAmount = 20_001e18 + 9e15; // 20,001.009
        (bool ok, uint256 executableAssetAmount, uint256 expectedPosAmount) = adapter.previewDeposit(rawAmount);

        assertTrue(ok);
        assertEq(executableAssetAmount, 20_001e18);
        assertEq(expectedPosAmount, 20_001e18);
    }

    function test_PreviewDeposit_ReturnsFlooredAmountWithoutMinimumConstraint() public {
        adapter.setExecutionConstraints(0, SUBSCRIBE_STEP_ASSET, 0, REDEEM_STEP_POS_18);

        uint256 rawAmount = 19_999e18 + 999e15; // 19,999.999
        (bool ok, uint256 executableAssetAmount, uint256 expectedPosAmount) = adapter.previewDeposit(rawAmount);

        assertTrue(ok);
        assertEq(executableAssetAmount, 19_999e18 + 99e16);
        assertEq(expectedPosAmount, 19_999e18 + 99e16);
    }

    function test_PreviewDeposit_ReturnsFalseWhenExpectedPosUnavailable() public {
        oracle.setPrice(0);

        (bool ok, uint256 executableAssetAmount, uint256 expectedPosAmount) = adapterWithOracle.previewDeposit(100e18);

        assertFalse(ok);
        assertEq(executableAssetAmount, 0);
        assertEq(expectedPosAmount, 0);
    }

    function test_PreviewRedeem_FloorsQuantityAndReturnsExecutableAsset() public {
        adapterWithOracle.setExecutionConstraints(0, SUBSCRIBE_STEP_ASSET, 0, REDEEM_STEP_POS_6);

        uint256 rawAmount = 3_003e18 + 8e17; // 3003.8 => 1501.9 pos at price 2
        (bool ok, uint256 executableAssetAmount, uint256 expectedPosAmount) = adapterWithOracle.previewRedeem(rawAmount);

        assertTrue(ok);
        assertEq(executableAssetAmount, 3_002e18);
        assertEq(expectedPosAmount, 1_501e6);
    }

    function test_PreviewRedeem_ReturnsFlooredQuantityWithoutMinimumConstraint() public {
        adapterWithOracle.setExecutionConstraints(0, SUBSCRIBE_STEP_ASSET, 0, REDEEM_STEP_POS_6);

        uint256 rawAmount = 2_999e18 + 8e17; // 2999.8 => 1499.9 pos at price 2
        (bool ok, uint256 executableAssetAmount, uint256 expectedPosAmount) = adapterWithOracle.previewRedeem(rawAmount);

        assertTrue(ok);
        assertEq(executableAssetAmount, 2_998e18);
        assertEq(expectedPosAmount, 1_499e6);
    }

    function test_RevertWhen_RequestRedeemAmountIsNotNormalizedToPreviewResult() public {
        adapterWithOracle.setExecutionConstraints(0, SUBSCRIBE_STEP_ASSET, 0, REDEEM_STEP_POS_6);
        stToken6.mint(address(vault), 5_000e6);
        vault.approveTokenToAdapter(address(stToken6), address(adapterWithOracle), 5_000e6);

        vm.expectRevert();
        adapterWithOracle.requestRedeemAsync(3_003e18 + 8e17, receiver);
    }
}
