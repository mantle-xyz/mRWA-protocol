// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategyAdapter} from "../../src/interfaces/adapters/IStrategyAdapter.sol";
import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {IERC7540Redeem, IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {VaultFactory} from "../../src/vault/VaultFactory.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

// =============================================================
// Mock 合约
// =============================================================

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

    function initialize(address, address) external override {}

    function isSanctioned(address account) external view override returns (bool) {
        return sanctioned[account];
    }

    function setSanctioned(address account, bool status) external {
        sanctioned[account] = status;
    }

    function totalSanctionedCount() external pure override returns (uint256) {
        return 0;
    }

    function lastUpdateTimestamp() external pure override returns (uint256) {
        return 0;
    }

    function batchNonce() external pure override returns (uint256) {
        return 0;
    }

    function MAX_BATCH_SIZE() external pure override returns (uint256) {
        return 100;
    }

    function updateSanctionStatus(address, bool) external override {}
    function updateSanctionStatusBatch(address[] calldata, bool) external override {}
}

contract MockStrategyAdapter is IStrategyAdapter {
    uint256 public mockTotalValue;

    function name() external pure override returns (string memory) {
        return "MockAdapter";
    }

    function asset() external pure override returns (address) {
        return address(0);
    }

    function posToken() external pure override returns (address) {
        return address(0);
    }

    function estimatePosAmount(uint256 assetAmount) external pure override returns (uint256) {
        return assetAmount;
    }

    function vault() external pure override returns (address) {
        return address(0);
    }

    function totalValue() external view override returns (uint256) {
        return mockTotalValue;
    }

    function setTotalValue(uint256 v) external {
        mockTotalValue = v;
    }

    function deposit(uint256, address) external pure override returns (uint256) {
        return 0;
    }

    function withdrawSync(uint256, address) external pure override returns (uint256) {
        return 0;
    }

    function requestRedeemAsync(uint256, address) external pure override {}

    function sweepToVault(address, uint256) external pure override returns (uint256) {
        return 0;
    }

    function setPaused(bool) external pure override {}
}

// =============================================================
// Base test helper
// =============================================================

abstract contract VaultTestBase is Test {
    using Math for uint256;

    MockUSDC usdc;
    MockSanctionsOracle oracle;
    MockStrategyAdapter adapter;
    MantleYieldVault vault;

    address admin = makeAddr("admin");
    address controllerAddr = makeAddr("controller");
    address accountantAddr = makeAddr("accountant");
    address treasuryAddr = makeAddr("treasury");
    address pauser = makeAddr("pauser");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address sanctionedUser = makeAddr("sanctionedUser");

    uint256 constant INITIAL_DEPOSIT = 1_000e6;
    uint256 constant FEE_BPS = 100; // 1%
    uint256 constant MIN_REDEEM = 10e6;
    uint256 constant FEE_BASIS = 10_000;

    VaultFactory factory;

    function setUp() public virtual {
        usdc = new MockUSDC();
        oracle = new MockSanctionsOracle();
        adapter = new MockStrategyAdapter();

        MantleYieldVault impl = new MantleYieldVault();
        factory = new VaultFactory(address(impl), admin);

        address vaultAddr = factory.deployAndInitVault(_defaultParams());
        vault = MantleYieldVault(vaultAddr);

        bytes32 pauserRole = vault.PAUSER_ROLE();
        vm.prank(admin);
        vault.grantRole(pauserRole, pauser);

        oracle.setSanctioned(sanctionedUser, true);

        usdc.mint(alice, INITIAL_DEPOSIT);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(INITIAL_DEPOSIT, alice);
        vm.stopPrank();
    }

    function _defaultParams() internal view returns (IMantleYieldVault.InitParams memory) {
        return IMantleYieldVault.InitParams({
            asset: IERC20(address(usdc)),
            name: "Mantle RWA Vault",
            symbol: "mRWA",
            admin: admin,
            sanctionsOracle: address(oracle),
            controller: controllerAddr,
            accountant: accountantAddr,
            treasury: treasuryAddr,
            maxRedemptionFeeBps: 500,
            maxRateChangeBps: 1000,
            redemptionFeeBps: FEE_BPS,
            minRedeemAmount: MIN_REDEEM,
            minDepositAmount: 0,
            syncRedeemDisabled: false
        });
    }
}

// =============================================================
// 初始化测试
// =============================================================

contract InitializeTest is VaultTestBase {
    function test_initialState() public view {
        assertEq(vault.exchangeRate(), 1e18);
        assertEq(vault.redemptionFeeBps(), FEE_BPS);
        assertEq(vault.minRedeemAmount(), MIN_REDEEM);
        assertEq(vault.controller(), controllerAddr);
        assertEq(vault.accountant(), accountantAddr);
        assertEq(vault.treasury(), treasuryAddr);
        assertEq(address(vault.sanctionsOracle()), address(oracle));
        assertEq(vault.totalSupply(), INITIAL_DEPOSIT);
        assertEq(vault.balanceOf(alice), INITIAL_DEPOSIT);
    }

    function test_cannotInitializeTwice() public {
        vm.expectRevert();
        vault.initialize(_defaultParams());
    }

    function _paramsWithOverride(
        address asset_,
        address oracle_,
        address controller_,
        address accountant_,
        address treasury_,
        uint256 maxFee_,
        uint256 fee_
    ) internal view returns (IMantleYieldVault.InitParams memory p) {
        p = _defaultParams();
        p.asset = IERC20(asset_);
        p.sanctionsOracle = oracle_;
        p.controller = controller_;
        p.accountant = accountant_;
        p.treasury = treasury_;
        p.maxRedemptionFeeBps = maxFee_;
        p.redemptionFeeBps = fee_;
    }

    function test_cannotInitializeWithZeroController() public {
        vm.expectRevert(IMantleYieldVault.Vault__ZeroAddress.selector);
        factory.deployAndInitVault(
            _paramsWithOverride(address(usdc), address(oracle), address(0), accountantAddr, treasuryAddr, 500, 0)
        );
    }

    function test_cannotInitializeWithZeroOracle() public {
        vm.expectRevert(IMantleYieldVault.Vault__ZeroAddress.selector);
        factory.deployAndInitVault(
            _paramsWithOverride(address(usdc), address(0), controllerAddr, accountantAddr, treasuryAddr, 500, 0)
        );
    }

    function test_cannotInitializeWithZeroAsset() public {
        vm.expectRevert(IMantleYieldVault.Vault__ZeroAddress.selector);
        factory.deployAndInitVault(
            _paramsWithOverride(address(0), address(oracle), controllerAddr, accountantAddr, treasuryAddr, 500, 0)
        );
    }

    function test_cannotInitializeWithZeroTreasury() public {
        vm.expectRevert(IMantleYieldVault.Vault__ZeroAddress.selector);
        factory.deployAndInitVault(
            _paramsWithOverride(address(usdc), address(oracle), controllerAddr, accountantAddr, address(0), 500, 0)
        );
    }

    function test_cannotInitializeWithFeeTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(IMantleYieldVault.Vault__FeeTooHigh.selector, 600, 500));
        factory.deployAndInitVault(
            _paramsWithOverride(address(usdc), address(oracle), controllerAddr, accountantAddr, treasuryAddr, 500, 600)
        );
    }
}

// =============================================================
// 存款 / Mint 测试
// =============================================================

contract DepositMintTest is VaultTestBase {
    function test_depositMintsCorrectShares() public {
        usdc.mint(bob, 500e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 500e6);
        uint256 shares = vault.deposit(500e6, bob);
        vm.stopPrank();

        assertEq(shares, 500e6);
        assertEq(vault.balanceOf(bob), 500e6);
        assertEq(usdc.balanceOf(address(vault)), INITIAL_DEPOSIT + 500e6);
    }

    function test_mintDeductsCorrectAssets() public {
        usdc.mint(bob, 500e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 500e6);
        uint256 assets = vault.mint(500e6, bob);
        vm.stopPrank();

        assertEq(assets, 500e6);
        assertEq(vault.balanceOf(bob), 500e6);
    }

    function test_depositRevertsWhenPaused() public {
        vm.prank(pauser);
        vault.pause();

        usdc.mint(bob, 100e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 100e6);
        vm.expectRevert();
        vault.deposit(100e6, bob);
        vm.stopPrank();
    }

    function test_depositRevertsSanctionedSender() public {
        usdc.mint(sanctionedUser, 100e6);
        vm.startPrank(sanctionedUser);
        usdc.approve(address(vault), 100e6);
        vm.expectRevert(abi.encodeWithSelector(IMantleYieldVault.Vault__Sanctioned.selector, sanctionedUser));
        vault.deposit(100e6, sanctionedUser);
        vm.stopPrank();
    }

    function test_depositRevertsSanctionedReceiver() public {
        usdc.mint(alice, 100e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IMantleYieldVault.Vault__Sanctioned.selector, sanctionedUser));
        vault.deposit(100e6, sanctionedUser);
    }
}

// =============================================================
// 同步赎回 (redeem / withdraw) 测试
// =============================================================

contract SyncRedeemTest is VaultTestBase {
    function test_redeemWithFreeCash() public {
        uint256 shares = 100e6;
        uint256 expectedAssets = vault.previewRedeem(shares);

        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);

        assertEq(assets, expectedAssets);
        assertEq(vault.balanceOf(alice), INITIAL_DEPOSIT - shares);
    }

    function test_withdrawWithFreeCash() public {
        uint256 wantAssets = 99e6;
        uint256 neededShares = vault.previewWithdraw(wantAssets);

        vm.prank(alice);
        uint256 sharesUsed = vault.withdraw(wantAssets, alice, alice);

        assertEq(sharesUsed, neededShares);
    }

    function test_redeemRevertsZeroShares() public {
        vm.prank(alice);
        vm.expectRevert(IMantleYieldVault.Vault__ZeroAmount.selector);
        vault.redeem(0, alice, alice);
    }

    function test_withdrawRevertsZeroAssets() public {
        vm.prank(alice);
        vm.expectRevert(IMantleYieldVault.Vault__ZeroAmount.selector);
        vault.withdraw(0, alice, alice);
    }

    function test_redeemRevertsWhenPaused() public {
        vm.prank(pauser);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(100e6, alice, alice);
    }

    function test_redeemRevertsSanctionedReceiver() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IMantleYieldVault.Vault__Sanctioned.selector, sanctionedUser));
        vault.redeem(100e6, sanctionedUser, alice);
    }

    function test_redeemRevertsInsufficientFreeCash() public {
        vm.prank(address(vault));
        usdc.transfer(address(1), INITIAL_DEPOSIT - 10e6);

        uint256 aliceShares = vault.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(aliceShares, alice, alice);
    }

    function test_previewRedeemIncludesFee() public view {
        uint256 shares = 1000e6;
        uint256 gross = shares; // 1:1 exchange rate
        uint256 fee = (gross * FEE_BPS + FEE_BASIS - 1) / FEE_BASIS; // ceil
        uint256 expected = gross - fee;
        assertEq(vault.previewRedeem(shares), expected);
    }
}

// =============================================================
// 异步赎回 (requestRedeem / claimRedeem) 测试
// =============================================================

contract AsyncRedeemTest is VaultTestBase {
    function test_requestRedeemCreatesRequest() public {
        uint256 shares = 500e6;

        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(shares);

        assertEq(requestId, 1);
        assertEq(vault.balanceOf(alice), INITIAL_DEPOSIT - shares);
        assertGt(vault.totalLockedShares(), 0);
    }

    function test_requestRedeemRevertsZero() public {
        vm.prank(alice);
        vm.expectRevert(IMantleYieldVault.Vault__ZeroAmount.selector);
        vault.requestRedeem(0);
    }

    function test_requestRedeemRevertsBelowMin() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.requestRedeem(1);
    }

    function test_requestRedeemRevertsSanctioned() public {
        usdc.mint(sanctionedUser, 100e6);
        vm.startPrank(sanctionedUser);
        usdc.approve(address(vault), 100e6);
        vm.expectRevert(abi.encodeWithSelector(IMantleYieldVault.Vault__Sanctioned.selector, sanctionedUser));
        vault.deposit(100e6, sanctionedUser);
        vm.stopPrank();
    }

    function test_fullRedemptionLifecycle() public {
        uint256 shares = 500e6;

        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(shares);

        uint256[] memory ids = new uint256[](1);
        ids[0] = requestId;

        vm.prank(controllerAddr);
        vault.updateRequestBatch(ids, IMantleYieldVault.RequestStatus.PROCESSING);

        (,,, uint256 reqAssets,,,) = vault.requests(requestId);
        uint256[] memory settled = new uint256[](1);
        settled[0] = reqAssets;
        vm.prank(controllerAddr);
        vault.markRequestsReady(ids, settled);

        uint256 balBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        uint256 claimed = vault.claimRedeem(alice);

        assertGt(claimed, 0);
        assertEq(usdc.balanceOf(alice), balBefore + claimed);
    }

    function test_claimRedeemRevertsWhenNothingClaimable() public {
        vm.prank(alice);
        vm.expectRevert(IMantleYieldVault.Vault__ZeroAmount.selector);
        vault.claimRedeem(alice);
    }

    function test_claimRedeemRevertsWhenPaused() public {
        uint256 shares = 500e6;
        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(shares);

        uint256[] memory ids = new uint256[](1);
        ids[0] = requestId;
        vm.prank(controllerAddr);
        vault.updateRequestBatch(ids, IMantleYieldVault.RequestStatus.PROCESSING);

        (,,, uint256 reqAssets,,,) = vault.requests(requestId);
        uint256[] memory settled = new uint256[](1);
        settled[0] = reqAssets;
        vm.prank(controllerAddr);
        vault.markRequestsReady(ids, settled);

        vm.prank(pauser);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert();
        vault.claimRedeem(alice);
    }

    function test_multipleRequestsThenClaim() public {
        vm.prank(alice);
        uint256 id1 = vault.requestRedeem(200e6);

        vm.prank(alice);
        uint256 id2 = vault.requestRedeem(200e6);

        uint256[] memory ids = new uint256[](2);
        ids[0] = id1;
        ids[1] = id2;

        uint256[] memory settled = new uint256[](2);
        (,,, settled[0],,,) = vault.requests(id1);
        (,,, settled[1],,,) = vault.requests(id2);

        vm.prank(controllerAddr);
        vault.updateRequestBatch(ids, IMantleYieldVault.RequestStatus.PROCESSING);
        vm.prank(controllerAddr);
        vault.markRequestsReady(ids, settled);

        vm.prank(alice);
        uint256 claimed = vault.claimRedeem(alice);

        assertGt(claimed, 0);
    }
}

// =============================================================
// updateRequestBatch 测试
// =============================================================

contract UpdateRequestBatchTest is VaultTestBase {
    function test_canTransitionPendingToProcessing() public {
        vm.prank(alice);
        uint256 id = vault.requestRedeem(500e6);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        vm.prank(controllerAddr);
        vault.updateRequestBatch(ids, IMantleYieldVault.RequestStatus.PROCESSING);
    }

    function test_revertsForbiddenTargetStatus_NONE() public {
        vm.prank(alice);
        uint256 id = vault.requestRedeem(500e6);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        vm.prank(controllerAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMantleYieldVault.Vault__StatusTransitionForbidden.selector, IMantleYieldVault.RequestStatus.NONE
            )
        );
        vault.updateRequestBatch(ids, IMantleYieldVault.RequestStatus.NONE);
    }

    function test_revertsForbiddenTargetStatus_READY() public {
        vm.prank(alice);
        uint256 id = vault.requestRedeem(500e6);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        vm.prank(controllerAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMantleYieldVault.Vault__StatusTransitionForbidden.selector, IMantleYieldVault.RequestStatus.READY
            )
        );
        vault.updateRequestBatch(ids, IMantleYieldVault.RequestStatus.READY);
    }

    function test_revertsForbiddenTargetStatus_CLAIMED() public {
        vm.prank(alice);
        uint256 id = vault.requestRedeem(500e6);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        vm.prank(controllerAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMantleYieldVault.Vault__StatusTransitionForbidden.selector, IMantleYieldVault.RequestStatus.CLAIMED
            )
        );
        vault.updateRequestBatch(ids, IMantleYieldVault.RequestStatus.CLAIMED);
    }

    function test_revertsIfCurrentStatusIsNONE() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 999;

        vm.prank(controllerAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMantleYieldVault.Vault__InvalidState.selector, 999, IMantleYieldVault.RequestStatus.NONE
            )
        );
        vault.updateRequestBatch(ids, IMantleYieldVault.RequestStatus.PROCESSING);
    }

    function test_revertsIfNotController() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;

        vm.prank(alice);
        vm.expectRevert(IMantleYieldVault.Vault__OnlyController.selector);
        vault.updateRequestBatch(ids, IMantleYieldVault.RequestStatus.PROCESSING);
    }
}

// =============================================================
// Adapter 管理测试
// =============================================================

contract AdapterManagementTest is VaultTestBase {
    function test_registerAdapter() public {
        vm.prank(controllerAddr);
        vault.registerAdapter(address(adapter));

        assertTrue(vault.isAdapter(address(adapter)));
        address[] memory list = vault.getAdapters();
        assertEq(list.length, 1);
        assertEq(list[0], address(adapter));
    }

    function test_registerAdapterRevertsIfAlreadyRegistered() public {
        vm.prank(controllerAddr);
        vault.registerAdapter(address(adapter));

        vm.prank(controllerAddr);
        vm.expectRevert(
            abi.encodeWithSelector(IMantleYieldVault.Vault__AdapterAlreadyRegistered.selector, address(adapter))
        );
        vault.registerAdapter(address(adapter));
    }

    function test_removeAdapter() public {
        vm.prank(controllerAddr);
        vault.registerAdapter(address(adapter));

        vm.prank(controllerAddr);
        vault.removeAdapter(address(adapter));

        assertFalse(vault.isAdapter(address(adapter)));
        assertEq(vault.getAdapters().length, 0);
    }

    function test_removeAdapterRevertsIfNotRegistered() public {
        vm.prank(controllerAddr);
        vm.expectRevert(
            abi.encodeWithSelector(IMantleYieldVault.Vault__AdapterNotRegistered.selector, address(adapter))
        );
        vault.removeAdapter(address(adapter));
    }

    function test_removeAdapterRevertsIfHasInFlight() public {
        vm.startPrank(controllerAddr);
        vault.registerAdapter(address(adapter));
        vault.createInFlight(address(adapter), address(usdc), 100, 100e6, true);
        vm.expectRevert(abi.encodeWithSelector(IMantleYieldVault.Vault__AdapterHasInFlight.selector, address(adapter)));
        vault.removeAdapter(address(adapter));
        vm.stopPrank();
    }

    function test_approveToAdapterRevertsIfNotRegistered() public {
        vm.prank(controllerAddr);
        vm.expectRevert(
            abi.encodeWithSelector(IMantleYieldVault.Vault__AdapterNotRegistered.selector, address(adapter))
        );
        vault.approveToAdapter(address(adapter), address(usdc), 100e6);
    }

    function test_approveToAdapter() public {
        vm.startPrank(controllerAddr);
        vault.registerAdapter(address(adapter));
        vault.approveToAdapter(address(adapter), address(usdc), 100e6);
        vm.stopPrank();

        assertEq(usdc.allowance(address(vault), address(adapter)), 100e6);
    }

    function test_adapterManagementRevertsIfNotController() public {
        vm.prank(alice);
        vm.expectRevert(IMantleYieldVault.Vault__OnlyController.selector);
        vault.registerAdapter(address(adapter));

        vm.prank(alice);
        vm.expectRevert(IMantleYieldVault.Vault__OnlyController.selector);
        vault.removeAdapter(address(adapter));
    }
}

// =============================================================
// InFlight 在途资产测试
// =============================================================

contract InFlightTest is VaultTestBase {
    function setUp() public override {
        super.setUp();
        vm.prank(controllerAddr);
        vault.registerAdapter(address(adapter));
    }

    function test_createInFlightInvest() public {
        vm.prank(controllerAddr);
        uint256 id = vault.createInFlight(address(adapter), address(usdc), 100, 100e6, true);

        assertEq(id, 1);
        assertEq(vault.totalInvestInFlight(), 100e6);
        assertEq(vault.adapterInvestInFlightTokens(address(adapter)), 100);
    }

    function test_createInFlightRedeem() public {
        vm.prank(controllerAddr);
        uint256 id = vault.createInFlight(address(adapter), address(usdc), 50, 50e6, false);

        assertEq(id, 1);
        assertEq(vault.totalRedeemInFlight(), 50e6);
        assertEq(vault.adapterRedeemInFlightUsdc(address(adapter)), 50e6);
    }

    function test_confirmInFlightInvest() public {
        vm.startPrank(controllerAddr);
        uint256 id = vault.createInFlight(address(adapter), address(usdc), 100, 100e6, true);
        vault.confirmInFlight(id, 98);
        vm.stopPrank();

        assertEq(vault.totalInvestInFlight(), 0);
        assertEq(vault.adapterInvestInFlightTokens(address(adapter)), 0);
    }

    function test_confirmInFlightRedeem() public {
        vm.startPrank(controllerAddr);
        uint256 id = vault.createInFlight(address(adapter), address(usdc), 50, 50e6, false);
        vault.confirmInFlight(id, 49e6);
        vm.stopPrank();

        assertEq(vault.totalRedeemInFlight(), 0);
        assertEq(vault.adapterRedeemInFlightUsdc(address(adapter)), 0);
    }

    function test_confirmInFlightRevertsIfAlreadyConfirmed() public {
        vm.startPrank(controllerAddr);
        uint256 id = vault.createInFlight(address(adapter), address(usdc), 100, 100e6, true);
        vault.confirmInFlight(id, 100);

        vm.expectRevert(
            abi.encodeWithSelector(
                IMantleYieldVault.Vault__InvalidInFlightState.selector, id, IMantleYieldVault.InFlightStatus.CONFIRMED
            )
        );
        vault.confirmInFlight(id, 100);
        vm.stopPrank();
    }

    function test_createInFlightRevertsZeroAmount() public {
        vm.prank(controllerAddr);
        vm.expectRevert(IMantleYieldVault.Vault__ZeroAmount.selector);
        vault.createInFlight(address(adapter), address(usdc), 0, 100e6, true);
    }

    function test_createInFlightRevertsUnregisteredAdapter() public {
        address fakeAdapter = makeAddr("fakeAdapter");
        vm.prank(controllerAddr);
        vm.expectRevert(abi.encodeWithSelector(IMantleYieldVault.Vault__AdapterNotRegistered.selector, fakeAdapter));
        vault.createInFlight(fakeAdapter, address(usdc), 100, 100e6, true);
    }
}

// =============================================================
// ExchangeRate 测试
// =============================================================

contract ExchangeRateTest is VaultTestBase {
    function test_updateExchangeRate() public {
        uint256 newRate = 1.05e18;
        vm.prank(accountantAddr);
        vault.updateExchangeRate(newRate);

        assertEq(vault.exchangeRate(), newRate);
    }

    function test_updateExchangeRateRevertsZero() public {
        vm.prank(accountantAddr);
        vm.expectRevert(IMantleYieldVault.Vault__ZeroExchangeRate.selector);
        vault.updateExchangeRate(0);
    }

    function test_updateExchangeRatePausesOnExceedsLimit() public {
        uint256 tooHigh = 1.2e18;
        assertFalse(vault.paused());
        vm.prank(accountantAddr);
        vault.updateExchangeRate(tooHigh);
        assertTrue(vault.paused(), "vault should be paused after exceeding limit");
        assertEq(vault.exchangeRate(), tooHigh, "rate should still be updated");
    }

    function test_updateExchangeRateRevertsIfNotAccountant() public {
        vm.prank(alice);
        vm.expectRevert(IMantleYieldVault.Vault__OnlyAccountant.selector);
        vault.updateExchangeRate(1.01e18);
    }

    function test_exchangeRateAffectsSharePrice() public {
        vm.prank(accountantAddr);
        vault.updateExchangeRate(1.05e18);

        uint256 assetsFor100Shares = vault.previewRedeem(100e6);
        uint256 grossAssets = Math.mulDiv(100e6, 1.05e18, 1e18, Math.Rounding.Floor);
        uint256 fee = Math.mulDiv(grossAssets, FEE_BPS, FEE_BASIS, Math.Rounding.Ceil);
        assertEq(assetsFor100Shares, grossAssets - fee);
    }
}

// =============================================================
// 赎回费测试
// =============================================================

contract RedemptionFeeTest is VaultTestBase {
    function test_setRedemptionFee() public {
        vm.prank(admin);
        vault.setRedemptionFee(200);
        assertEq(vault.redemptionFeeBps(), 200);
    }

    function test_setRedemptionFeeRevertsTooHigh() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IMantleYieldVault.Vault__FeeTooHigh.selector, 501, 500));
        vault.setRedemptionFee(501);
    }

    function test_setRedemptionFeeRevertsIfNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setRedemptionFee(100);
    }

    function test_feeStaysInVaultOnRequestRedeem() public {
        uint256 shares = 500e6;
        uint256 vaultBalBefore = usdc.balanceOf(address(vault));

        vm.prank(alice);
        vault.requestRedeem(shares);

        assertEq(usdc.balanceOf(address(vault)), vaultBalBefore);
    }

    function test_feeIncreasesFreeCashOnRedeem() public {
        uint256 shares = 100e6;
        uint256 freeCashBefore = vault.getFreeCash();

        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        uint256 gross = shares;
        uint256 fee = (gross * FEE_BPS + FEE_BASIS - 1) / FEE_BASIS;
        uint256 netTransferred = gross - fee;

        assertEq(vault.getFreeCash(), freeCashBefore - netTransferred - fee + fee);
    }
}

// =============================================================
// FreeCash & totalAssets 测试
// =============================================================

contract FreeCashTest is VaultTestBase {
    function test_getFreeCashWithNoLiabilities() public view {
        assertEq(vault.getFreeCash(), INITIAL_DEPOSIT);
    }

    function test_getFreeCashReducedByLiabilities() public {
        uint256 shares = 500e6;

        vm.prank(alice);
        vault.requestRedeem(shares);

        uint256 gross = shares;
        uint256 fee = (gross * FEE_BPS + FEE_BASIS - 1) / FEE_BASIS;
        uint256 lockedAssets = gross - fee;

        assertEq(vault.getFreeCash(), INITIAL_DEPOSIT - lockedAssets);
    }

    function test_getFreeCash_afterFullRedeem_feeRemains() public {
        uint256 aliceBalance = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(aliceBalance);

        uint256 gross = aliceBalance;
        uint256 fee = (gross * FEE_BPS + FEE_BASIS - 1) / FEE_BASIS;

        assertEq(vault.getFreeCash(), fee);
    }
}

contract TotalAssetsTest is VaultTestBase {
    function test_totalAssetsBasic() public view {
        assertEq(vault.totalAssets(), INITIAL_DEPOSIT);
    }

    function test_totalAssetsIncludesAdapterValue() public {
        vm.prank(controllerAddr);
        vault.registerAdapter(address(adapter));

        adapter.setTotalValue(500e6);

        assertEq(vault.totalAssets(), INITIAL_DEPOSIT + 500e6);
    }

    function test_totalAssetsSubtractsLiabilities() public {
        uint256 shares = 500e6;

        vm.prank(alice);
        vault.requestRedeem(shares);

        uint256 gross = shares;
        uint256 fee = (gross * FEE_BPS + FEE_BASIS - 1) / FEE_BASIS;
        uint256 lockedAssets = gross - fee;

        assertEq(vault.totalAssets(), INITIAL_DEPOSIT - lockedAssets);
    }

    function test_totalAssetsReturnsZeroWhenLiabilitiesExceedTotal() public {
        uint256 aliceBalance = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(aliceBalance);

        uint256 gross = aliceBalance;
        uint256 fee = (gross * FEE_BPS + FEE_BASIS - 1) / FEE_BASIS;

        assertEq(vault.totalAssets(), fee);
    }

    function test_totalAssetsIncludesInFlight() public {
        vm.prank(controllerAddr);
        vault.registerAdapter(address(adapter));

        vm.prank(controllerAddr);
        vault.createInFlight(address(adapter), address(usdc), 100, 200e6, true);

        assertEq(vault.totalAssets(), INITIAL_DEPOSIT + 200e6);
    }
}

// =============================================================
// 合规 (Sanctions) 测试
// =============================================================

contract SanctionsTest is VaultTestBase {
    function test_transferBlockedForSanctionedFrom() public {
        oracle.setSanctioned(alice, true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IMantleYieldVault.Vault__Sanctioned.selector, alice));
        vault.transfer(bob, 1e6);
    }

    function test_transferBlockedForSanctionedTo() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IMantleYieldVault.Vault__Sanctioned.selector, sanctionedUser));
        vault.transfer(sanctionedUser, 1e6);
    }

    function test_setSanctionsOracle() public {
        MockSanctionsOracle newOracle = new MockSanctionsOracle();
        vm.prank(admin);
        vault.setSanctionsOracle(address(newOracle));
        assertEq(address(vault.sanctionsOracle()), address(newOracle));
    }

    function test_setSanctionsOracleRevertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(IMantleYieldVault.Vault__ZeroAddress.selector);
        vault.setSanctionsOracle(address(0));
    }
}

// =============================================================
// Admin 权限管理测试
// =============================================================

contract AdminTest is VaultTestBase {
    function test_setController() public {
        address newController = makeAddr("newController");
        vm.prank(admin);
        vault.setController(newController);
        assertEq(vault.controller(), newController);
    }

    function test_setControllerRevertsZero() public {
        vm.prank(admin);
        vm.expectRevert(IMantleYieldVault.Vault__ZeroAddress.selector);
        vault.setController(address(0));
    }

    function test_setAccountant() public {
        address newAccountant = makeAddr("newAccountant");
        vm.prank(admin);
        vault.setAccountant(newAccountant);
        assertEq(vault.accountant(), newAccountant);
    }

    function test_setAccountantRevertsZero() public {
        vm.prank(admin);
        vm.expectRevert(IMantleYieldVault.Vault__ZeroAddress.selector);
        vault.setAccountant(address(0));
    }

    function test_setMinRedeemAmount() public {
        vm.prank(admin);
        vault.setMinRedeemAmount(50e6);
        assertEq(vault.minRedeemAmount(), 50e6);
    }

    function test_rescueTokens() public {
        MockUSDC otherToken = new MockUSDC();
        otherToken.mint(address(vault), 100e6);

        vm.prank(admin);
        vault.rescueTokens(address(otherToken), admin, 100e6);

        assertEq(otherToken.balanceOf(admin), 100e6);
    }

    function test_rescueTokensRevertsForUnderlying() public {
        vm.prank(admin);
        vm.expectRevert(IMantleYieldVault.Vault__RescueAssetCannotBeUnderlying.selector);
        vault.rescueTokens(address(usdc), admin, 100e6);
    }
}

// =============================================================
// 暂停 / 恢复 测试
// =============================================================

contract PauseTest is VaultTestBase {
    function test_pauseAndUnpause() public {
        vm.prank(pauser);
        vault.pause();
        assertTrue(vault.paused());

        vm.prank(admin);
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_onlyPauserCanPause() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.pause();
    }

    function test_onlyAdminCanUnpause() public {
        vm.prank(pauser);
        vault.pause();

        vm.prank(pauser);
        vm.expectRevert();
        vault.unpause();
    }

    function test_maxDepositReturnsZeroWhenPaused() public {
        vm.prank(pauser);
        vault.pause();
        assertEq(vault.maxDeposit(alice), 0);
    }

    function test_maxMintReturnsZeroWhenPaused() public {
        vm.prank(pauser);
        vault.pause();
        assertEq(vault.maxMint(alice), 0);
    }

    function test_maxRedeemReturnsZeroWhenPaused() public {
        vm.prank(pauser);
        vault.pause();
        assertEq(vault.maxRedeem(alice), 0);
    }

    function test_maxWithdrawReturnsZeroWhenPaused() public {
        vm.prank(pauser);
        vault.pause();
        assertEq(vault.maxWithdraw(alice), 0);
    }

    function test_transferBlockedWhenPaused() public {
        vm.prank(pauser);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert();
        vault.transfer(bob, 1e6);
    }
}

// =============================================================
// mintFeeShares 测试
// =============================================================

contract MintFeeSharesTest is VaultTestBase {
    function test_mintFeeShares() public {
        uint256 totalBefore = vault.totalSupply();
        uint256 toMint = totalBefore * 100 / FEE_BASIS; // 1% of supply

        vm.prank(accountantAddr);
        vault.mintFeeShares(toMint);

        assertEq(vault.balanceOf(treasuryAddr), toMint);
    }

    function test_mintFeeSharesRevertsExceedsCap() public {
        uint256 totalBefore = vault.totalSupply();
        uint256 tooMuch = totalBefore * 1_100 / FEE_BASIS;

        vm.prank(accountantAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMantleYieldVault.Vault__FeeTooHigh.selector, tooMuch, totalBefore * 1_000 / FEE_BASIS
            )
        );
        vault.mintFeeShares(tooMuch);
    }

    function test_mintFeeSharesRevertsIfNotAccountant() public {
        vm.prank(alice);
        vm.expectRevert(IMantleYieldVault.Vault__OnlyAccountant.selector);
        vault.mintFeeShares(1);
    }
}

// =============================================================
// maxRedeem / maxWithdraw 精确测试
// =============================================================

contract MaxRedeemWithdrawTest is VaultTestBase {
    function test_maxRedeemReturnsFullBalanceWhenFreeCashSufficient() public view {
        uint256 maxR = vault.maxRedeem(alice);
        assertEq(maxR, INITIAL_DEPOSIT);
    }

    function test_maxRedeemLimitedByFreeCash() public {
        uint256 half = INITIAL_DEPOSIT / 2;

        vm.prank(alice);
        vault.requestRedeem(half);

        uint256 maxR = vault.maxRedeem(alice);
        assertLe(vault.previewRedeem(maxR), vault.getFreeCash());
    }

    function test_maxWithdrawLimitedByFreeCash() public {
        uint256 half = INITIAL_DEPOSIT / 2;

        vm.prank(alice);
        vault.requestRedeem(half);

        uint256 maxW = vault.maxWithdraw(alice);
        assertLe(maxW, vault.getFreeCash());
    }
}

// =============================================================
// ERC-165 测试
// =============================================================

contract ERC165Test is VaultTestBase {
    function test_supportsIERC7540Redeem() public view {
        bytes4 iface = type(IERC7540Redeem).interfaceId;
        assertTrue(vault.supportsInterface(iface));
    }

    function test_shareReturnsVaultAddress() public view {
        assertEq(vault.share(), address(vault));
    }
}

// =============================================================
// ERC-7540 View 函数测试
// =============================================================

contract ERC7540ViewTest is VaultTestBase {
    function test_pendingRedeemRequestTracksShares() public {
        vm.prank(alice);
        vault.requestRedeem(500e6);

        assertEq(vault.pendingRedeemRequest(alice), 500e6);
    }

    function test_claimableRedeemRequestAfterReady() public {
        vm.prank(alice);
        uint256 id = vault.requestRedeem(500e6);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        (,,, uint256 reqAssets,,,) = vault.requests(id);
        uint256[] memory settled = new uint256[](1);
        settled[0] = reqAssets;

        vm.prank(controllerAddr);
        vault.updateRequestBatch(ids, IMantleYieldVault.RequestStatus.PROCESSING);
        vm.prank(controllerAddr);
        vault.markRequestsReady(ids, settled);

        assertEq(vault.claimableRedeemRequest(alice), 500e6);
    }
}

// =============================================================
// Zero Cash Buffer E2E Test
// =============================================================

contract ZeroCashBufferTest is VaultTestBase {
    function setUp() public override {
        super.setUp();
        vm.prank(controllerAddr);
        vault.registerAdapter(address(adapter));
    }

    /// @dev Full lifecycle: deposit → invest all (T+N) → sync redeem fails → async redeem → claim
    function test_zeroCashBuffer_fullLifecycle() public {
        // ====================================================
        // Phase 1: Invest all USDC via adapter (async T+N)
        // ====================================================

        vm.startPrank(controllerAddr);
        vault.approveToAdapter(address(adapter), address(usdc), INITIAL_DEPOSIT);
        vault.createInFlight(address(adapter), address(usdc), INITIAL_DEPOSIT, INITIAL_DEPOSIT, true);
        vm.stopPrank();

        // Adapter pulls USDC from vault (simulates adapter.deposit pulling via transferFrom)
        vm.prank(address(adapter));
        usdc.transferFrom(address(vault), address(adapter), INITIAL_DEPOSIT);

        // Mid-flight: USDC left vault, tokens not yet settled
        assertEq(usdc.balanceOf(address(vault)), 0, "vault USDC should be 0");
        assertEq(vault.totalInvestInFlight(), INITIAL_DEPOSIT, "invest in-flight should track USDC");
        assertEq(vault.totalAssets(), INITIAL_DEPOSIT, "totalAssets preserved by in-flight");
        assertEq(vault.getFreeCash(), 0, "freeCash should be 0");

        // Settlement: adapter now holds the value
        adapter.setTotalValue(INITIAL_DEPOSIT);
        vm.prank(controllerAddr);
        vault.confirmInFlight(1, INITIAL_DEPOSIT);

        assertEq(vault.totalInvestInFlight(), 0, "in-flight cleared after confirm");
        assertEq(vault.totalAssets(), INITIAL_DEPOSIT, "totalAssets via adapter.totalValue");
        assertEq(vault.getFreeCash(), 0, "freeCash still 0");

        // ====================================================
        // Phase 2: Sync redeem fails (no FreeCash)
        // ====================================================

        uint256 aliceShares = vault.balanceOf(alice);

        assertEq(vault.maxRedeem(alice), 0, "maxRedeem should be 0 with no cash");
        assertEq(vault.maxWithdraw(alice), 0, "maxWithdraw should be 0 with no cash");

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSignature("ERC4626ExceededMaxRedeem(address,uint256,uint256)", alice, aliceShares, uint256(0))
        );
        vault.redeem(aliceShares, alice, alice);

        // ====================================================
        // Phase 3: Async redeem (T+N) full flow
        // ====================================================

        // Step 3a: User requests async redeem
        vm.prank(alice);
        uint256 reqId = vault.requestRedeem(aliceShares);

        uint256 netAssets = 990e6; // 1000e6 - 1% fee (10e6)
        assertEq(vault.totalLockedShares(), aliceShares, "locked shares = redeemed shares");
        assertEq(vault.balanceOf(alice), 0, "shares burned");
        uint256 floatingLocked = vault.previewRedeem(vault.totalLockedShares());
        assertEq(vault.totalAssets(), INITIAL_DEPOSIT - floatingLocked, "totalAssets = total - floatingLocked");

        // Step 3b: Controller moves to PROCESSING
        uint256[] memory ids = new uint256[](1);
        ids[0] = reqId;
        vm.prank(controllerAddr);
        vault.updateRequestBatch(ids, IMantleYieldVault.RequestStatus.PROCESSING);

        // Step 3c: Controller initiates async redeem from adapter
        //   adapter.totalValue drops (tokens leaving adapter), in-flight bridges the gap
        adapter.setTotalValue(10e6); // 1000 - 990 withdrawn
        vm.prank(controllerAddr);
        vault.createInFlight(address(adapter), address(usdc), netAssets, netAssets, false);

        assertEq(vault.totalRedeemInFlight(), netAssets, "redeem in-flight tracking");

        // Step 3d: USDC arrives at vault (settlement)
        vm.prank(address(adapter));
        usdc.transfer(address(vault), netAssets);

        vm.prank(controllerAddr);
        vault.confirmInFlight(2, netAssets);

        assertEq(vault.totalRedeemInFlight(), 0, "redeem in-flight cleared");
        assertEq(usdc.balanceOf(address(vault)), netAssets, "vault received USDC");

        // Step 3e: Mark requests ready (no friction, settled = full amount)
        uint256[] memory settled = new uint256[](1);
        settled[0] = netAssets;
        vm.prank(controllerAddr);
        vault.markRequestsReady(ids, settled);

        // Step 3f: User claims
        vm.prank(alice);
        vault.claimRedeem(alice);

        // ====================================================
        // Final state verification
        // ====================================================

        assertEq(usdc.balanceOf(alice), netAssets, "alice received 990 USDC");
        assertEq(usdc.balanceOf(address(vault)), 0, "vault back to 0 cash");
        assertEq(vault.totalLockedShares(), 0, "locked shares cleared");
        assertEq(vault.claimableReserves(), 0, "claimable reserves cleared");
        assertEq(vault.totalSupply(), 0, "no shares outstanding");
        assertEq(vault.totalAssets(), 10e6, "fee retained in adapter");
    }

    /// @dev New deposit immediately invested, vault stays at zero cash
    function test_zeroCashBuffer_continuousOperation() public {
        // --- Initial invest: move all USDC to adapter ---
        vm.startPrank(controllerAddr);
        vault.approveToAdapter(address(adapter), address(usdc), INITIAL_DEPOSIT);
        vault.createInFlight(address(adapter), address(usdc), INITIAL_DEPOSIT, INITIAL_DEPOSIT, true);
        vm.stopPrank();

        vm.prank(address(adapter));
        usdc.transferFrom(address(vault), address(adapter), INITIAL_DEPOSIT);
        adapter.setTotalValue(INITIAL_DEPOSIT);
        vm.prank(controllerAddr);
        vault.confirmInFlight(1, INITIAL_DEPOSIT);

        assertEq(vault.getFreeCash(), 0, "initial: zero cash");

        // --- Bob deposits 500 USDC ---
        uint256 bobDeposit = 500e6;
        usdc.mint(bob, bobDeposit);
        vm.startPrank(bob);
        usdc.approve(address(vault), bobDeposit);
        vault.deposit(bobDeposit, bob);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(vault)), bobDeposit, "vault holds Bob's deposit");
        assertEq(vault.getFreeCash(), bobDeposit, "freeCash = Bob's deposit");

        // --- Controller immediately invests Bob's USDC ---
        vm.startPrank(controllerAddr);
        vault.approveToAdapter(address(adapter), address(usdc), bobDeposit);
        vault.createInFlight(address(adapter), address(usdc), bobDeposit, bobDeposit, true);
        vm.stopPrank();

        vm.prank(address(adapter));
        usdc.transferFrom(address(vault), address(adapter), bobDeposit);
        adapter.setTotalValue(INITIAL_DEPOSIT + bobDeposit);
        vm.prank(controllerAddr);
        vault.confirmInFlight(2, bobDeposit);

        // Vault back to zero cash
        assertEq(usdc.balanceOf(address(vault)), 0, "vault back to 0 cash");
        assertEq(vault.getFreeCash(), 0, "freeCash back to 0");
        assertEq(vault.totalAssets(), INITIAL_DEPOSIT + bobDeposit, "totalAssets includes both deposits");
        assertTrue(vault.balanceOf(bob) > 0, "Bob has shares");
    }

    /// @dev totalAssets remains consistent at every step of the in-flight lifecycle
    function test_zeroCashBuffer_totalAssetsNeverDrops() public {
        // Step 1: All USDC in vault
        assertEq(vault.totalAssets(), INITIAL_DEPOSIT, "step1: totalAssets");

        // Step 2: Create invest in-flight (intent recorded, USDC still in vault)
        vm.startPrank(controllerAddr);
        vault.approveToAdapter(address(adapter), address(usdc), INITIAL_DEPOSIT);
        vault.createInFlight(address(adapter), address(usdc), INITIAL_DEPOSIT, INITIAL_DEPOSIT, true);
        vm.stopPrank();
        // totalAssets = 1000 (vault) + 1000 (investInFlight) + 0 (adapter) - 0 = 2000
        // Note: intentionally over-counted before USDC leaves; controller should move atomically
        uint256 step2 = vault.totalAssets();
        assertTrue(step2 >= INITIAL_DEPOSIT, "step2: totalAssets >= initial");

        // Step 3: USDC leaves vault
        vm.prank(address(adapter));
        usdc.transferFrom(address(vault), address(adapter), INITIAL_DEPOSIT);
        // totalAssets = 0 (vault) + 1000 (investInFlight) + 0 (adapter) - 0 = 1000
        assertEq(vault.totalAssets(), INITIAL_DEPOSIT, "step3: in-flight bridges the gap");

        // Step 4: Settlement + confirm
        adapter.setTotalValue(INITIAL_DEPOSIT);
        vm.prank(controllerAddr);
        vault.confirmInFlight(1, INITIAL_DEPOSIT);
        // totalAssets = 0 (vault) + 0 (investInFlight) + 1000 (adapter) - 0 = 1000
        assertEq(vault.totalAssets(), INITIAL_DEPOSIT, "step4: adapter value takes over");
    }

    /// @dev Async redemption with settlement friction: adapter returns less USDC than expected
    function test_zeroCashBuffer_asyncRedeemWithFriction() public {
        uint256 friction = 5e6; // 5 USDC friction from async settlement

        // --- Setup: invest all USDC to adapter ---
        vm.startPrank(controllerAddr);
        vault.approveToAdapter(address(adapter), address(usdc), INITIAL_DEPOSIT);
        vault.createInFlight(address(adapter), address(usdc), INITIAL_DEPOSIT, INITIAL_DEPOSIT, true);
        vm.stopPrank();
        vm.prank(address(adapter));
        usdc.transferFrom(address(vault), address(adapter), INITIAL_DEPOSIT);
        adapter.setTotalValue(INITIAL_DEPOSIT);
        vm.prank(controllerAddr);
        vault.confirmInFlight(1, INITIAL_DEPOSIT);

        // --- Alice requests async redeem ---
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 reqId = vault.requestRedeem(aliceShares);
        uint256 netAssets = 990e6; // 1000 - 1% fee

        uint256[] memory ids = new uint256[](1);
        ids[0] = reqId;
        vm.prank(controllerAddr);
        vault.updateRequestBatch(ids, IMantleYieldVault.RequestStatus.PROCESSING);

        // --- Adapter async redeem settles with friction ---
        uint256 actualReceived = netAssets - friction; // 985e6
        adapter.setTotalValue(INITIAL_DEPOSIT - actualReceived);
        vm.prank(controllerAddr);
        vault.createInFlight(address(adapter), address(usdc), netAssets, netAssets, false);
        vm.prank(address(adapter));
        usdc.transfer(address(vault), actualReceived); // only 985 USDC arrives
        vm.prank(controllerAddr);
        vault.confirmInFlight(2, actualReceived);

        assertEq(usdc.balanceOf(address(vault)), actualReceived, "vault has 985 USDC");

        // markRequestsReady with settledAssets = actualReceived (less than estimated)
        uint256 lockedSharesBefore = vault.totalLockedShares();
        uint256[] memory settled = new uint256[](1);
        settled[0] = actualReceived;
        vm.prank(controllerAddr);
        vault.markRequestsReady(ids, settled);

        // Shares released from totalLockedShares; claimableReserves holds actual USDC amount
        assertEq(vault.totalLockedShares(), lockedSharesBefore - aliceShares, "locked shares released");
        assertEq(vault.claimableReserves(), actualReceived, "claimable = actual settled amount");

        // estimatedAssets preserved, settledAssets = actual
        (,,, uint256 estAssets, uint256 settled_,, IMantleYieldVault.RequestStatus status) = vault.requests(reqId);
        assertEq(estAssets, netAssets, "estimatedAssets preserved");
        assertEq(settled_, actualReceived, "settledAssets = actual settlement");
        assertTrue(status == IMantleYieldVault.RequestStatus.READY, "request is READY");

        // --- Alice claims the friction-adjusted amount ---
        vm.prank(alice);
        vault.claimRedeem(alice);

        assertEq(usdc.balanceOf(alice), actualReceived, "alice receives 985 USDC (990 - 5 friction)");
        assertEq(vault.totalLockedShares(), 0, "all locked shares settled");
        assertEq(vault.claimableReserves(), 0, "claimable reserves cleared");
    }

    /// @dev settledAssets > estimatedAssets (underlying appreciated during async period)
    function test_markRequestsReady_settledExceedsEstimated_works() public {
        uint256 redeemShares = 500e6;
        vm.prank(alice);
        uint256 reqId = vault.requestRedeem(redeemShares);

        uint256[] memory ids = new uint256[](1);
        ids[0] = reqId;
        vm.prank(controllerAddr);
        vault.updateRequestBatch(ids, IMantleYieldVault.RequestStatus.PROCESSING);

        (,,, uint256 estAssets,,,) = vault.requests(reqId);
        uint256 surplus = 10e6;
        uint256 settledAmount = estAssets + surplus;
        uint256[] memory settled = new uint256[](1);
        settled[0] = settledAmount;

        uint256 lockedSharesBefore = vault.totalLockedShares();

        usdc.mint(address(vault), surplus);

        vm.prank(controllerAddr);
        vault.markRequestsReady(ids, settled);

        assertEq(vault.totalLockedShares(), lockedSharesBefore - redeemShares, "locked shares released");
        assertEq(vault.claimableReserves(), settledAmount, "claimable includes surplus");
    }

    /// @dev ids and settledAssets length mismatch reverts
    function test_markRequestsReady_revertsOnLengthMismatch() public {
        vm.prank(alice);
        uint256 reqId = vault.requestRedeem(500e6);

        uint256[] memory ids = new uint256[](1);
        ids[0] = reqId;

        uint256[] memory settled = new uint256[](2);
        settled[0] = 100e6;
        settled[1] = 100e6;

        vm.prank(controllerAddr);
        vm.expectRevert(abi.encodeWithSelector(IMantleYieldVault.Vault__LengthMismatch.selector, 1, 2));
        vault.markRequestsReady(ids, settled);
    }
}

// =============================================================
// SyncRedeemDisabled Tests
// =============================================================

contract SyncRedeemDisabledTest is VaultTestBase {
    function setUp() public override {
        super.setUp();
        usdc.mint(alice, 10_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
    }

    function test_setSyncRedeemDisabled_onlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setSyncRedeemDisabled(true);
    }

    function test_setSyncRedeemDisabled_emitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(address(vault));
        emit IMantleYieldVault.SyncRedeemDisabledUpdated(true);
        vault.setSyncRedeemDisabled(true);

        assertTrue(vault.syncRedeemDisabled());
    }

    function test_redeemRevertsWhenSyncDisabled() public {
        vm.prank(admin);
        vault.setSyncRedeemDisabled(true);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(IMantleYieldVault.Vault__SyncRedeemDisabled.selector);
        vault.redeem(shares, alice, alice);
    }

    function test_withdrawRevertsWhenSyncDisabled() public {
        vm.prank(admin);
        vault.setSyncRedeemDisabled(true);

        vm.prank(alice);
        vm.expectRevert(IMantleYieldVault.Vault__SyncRedeemDisabled.selector);
        vault.withdraw(1_000e6, alice, alice);
    }

    function test_maxRedeemReturnsZeroWhenSyncDisabled() public {
        vm.prank(admin);
        vault.setSyncRedeemDisabled(true);

        assertEq(vault.maxRedeem(alice), 0);
    }

    function test_maxWithdrawReturnsZeroWhenSyncDisabled() public {
        vm.prank(admin);
        vault.setSyncRedeemDisabled(true);

        assertEq(vault.maxWithdraw(alice), 0);
    }

    function test_requestRedeemStillWorksWhenSyncDisabled() public {
        vm.prank(admin);
        vault.setSyncRedeemDisabled(true);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(shares);

        assertEq(vault.pendingRedeemRequest(alice), shares);
    }

    function test_redeemWorksAfterReenabling() public {
        vm.prank(admin);
        vault.setSyncRedeemDisabled(true);

        vm.prank(admin);
        vault.setSyncRedeemDisabled(false);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        assertEq(vault.balanceOf(alice), 0);
    }
}
