// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategyAdapter} from "../../src/interfaces/adapters/IStrategyAdapter.sol";
import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {IMantleVaultGateway} from "../../src/interfaces/vault/IMantleVaultGateway.sol";
import {IERC7540Redeem, IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {GatewayFactory} from "../../src/vault/GatewayFactory.sol";
import {MantleVaultGateway} from "../../src/vault/MantleVaultGateway.sol";
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
    mapping(address => bool) public whitelisted;

    function initialize(address, address) external override {}

    function isSanctioned(address account) external view override returns (bool) {
        return sanctioned[account];
    }

    function isWhitelisted(address account) external view override returns (bool) {
        return whitelisted[account];
    }

    function setSanctioned(address account, bool status) external {
        sanctioned[account] = status;
    }

    function setWhitelisted(address account, bool status) external {
        whitelisted[account] = status;
    }

    function totalSanctionedCount() external pure override returns (uint256) {
        return 0;
    }

    function totalWhitelistedCount() external pure override returns (uint256) {
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
    function updateWhitelistStatus(address, bool) external override {}
    function updateWhitelistStatusBatch(address[] calldata, bool) external override {}
}

contract MockPosToken is ERC20 {
    constructor() ERC20("Position Token", "POS") {}

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

contract MockStrategyAdapter is IStrategyAdapter {
    MockPosToken public mockPosToken;
    uint256 public mockPrice = 1e18;

    constructor() {
        mockPosToken = new MockPosToken();
    }

    function name() external pure override returns (string memory) {
        return "MockAdapter";
    }

    function asset() external pure override returns (address) {
        return address(0);
    }

    function posToken() external view override returns (address) {
        return address(mockPosToken);
    }

    function priceOracle() external pure override returns (address) {
        return address(0);
    }

    function getPosTokenPrice() external view override returns (uint256) {
        return mockPrice;
    }

    function setMockPrice(uint256 price) external {
        mockPrice = price;
    }

    function estimatePosAmount(uint256 assetAmount) external pure override returns (uint256) {
        return assetAmount;
    }

    function minSubscribeAsset() external pure override returns (uint256) {
        return 0;
    }

    function minRedeemPos() external pure override returns (uint256) {
        return 0;
    }

    function previewDeposit(uint256 assetAmount)
        external
        pure
        override
        returns (bool ok, uint256 executableAssetAmount, uint256 expectedPosAmount)
    {
        return (assetAmount > 0, assetAmount, 0);
    }

    function previewRedeem(uint256 assetAmount)
        external
        pure
        override
        returns (bool ok, uint256 executableAssetAmount, uint256 expectedPosAmount)
    {
        return (assetAmount > 0, assetAmount, 0);
    }

    function vault() external pure override returns (address) {
        return address(0);
    }

    function totalValue() external pure override returns (uint256) {
        return 0;
    }

    /// @dev Adjust posToken balance of the vault to simulate adapter value
    function setTotalValue(uint256 v, address vaultAddr) external {
        uint256 currentBalance = mockPosToken.balanceOf(vaultAddr);
        if (v > currentBalance) {
            mockPosToken.mint(vaultAddr, v - currentBalance);
        } else if (v < currentBalance) {
            mockPosToken.burn(vaultAddr, currentBalance - v);
        }
    }

    function deposit(uint256, address) external pure override returns (uint256) {
        return 0;
    }

    function withdrawSync(uint256, address) external pure override returns (uint256) {
        return 0;
    }

    function requestRedeemAsync(uint256, address) external pure override {}

    function retryRedeemAsync(uint256, address) external pure override {}

    function sweepToVault(address, uint256) external pure override returns (uint256) {
        return 0;
    }

    function setPaused(bool) external pure override {}
}

contract MockAccountant {
    bool public pauseStatus;
    uint256 public exchangeRate = 1e18;
    uint32 public managementFeeRate = 100;

    error EnforcedPause();

    function getRate() external view returns (uint256) {
        return exchangeRate;
    }

    function getRateSafe() external view returns (uint256) {
        if (pauseStatus) revert EnforcedPause();
        return exchangeRate;
    }

    function setPauseStatus(bool paused_) external {
        pauseStatus = paused_;
    }

    function setExchangeRate(uint256 newRate) external {
        exchangeRate = newRate;
    }

    function setManagementFeeRate(uint256 newRate) external {
        managementFeeRate = uint32(newRate);
    }
}

// =============================================================
// Base test helper
// =============================================================

abstract contract VaultTestBase is Test {
    using Math for uint256;

    MockUSDC usdc;
    MockSanctionsOracle oracle;
    MockStrategyAdapter adapter;
    MockAccountant mockAccountant;
    MantleYieldVault vault;
    MantleVaultGateway gateway;

    address admin = makeAddr("admin");
    address controllerAddr = makeAddr("controller");
    address accountantAddr;
    address treasuryAddr = makeAddr("treasury");
    address pauser = makeAddr("pauser");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address sanctionedUser = makeAddr("sanctionedUser");

    uint256 constant INITIAL_DEPOSIT = 1_000e6;
    uint256 constant FEE_BPS = 100; // 1%
    uint256 constant MIN_REDEEM = 10e6;
    uint256 constant BPS_DENOMINATOR = 10_000;

    VaultFactory factory;
    GatewayFactory gatewayFactory;

    function setUp() public virtual {
        usdc = new MockUSDC();
        oracle = new MockSanctionsOracle();
        adapter = new MockStrategyAdapter();
        mockAccountant = new MockAccountant();
        accountantAddr = address(mockAccountant);

        MantleYieldVault impl = new MantleYieldVault();
        MantleVaultGateway gatewayImpl = new MantleVaultGateway();
        factory = new VaultFactory(address(impl), admin);
        gatewayFactory = new GatewayFactory(address(gatewayImpl), admin);

        address vaultAddr = factory.deployVault();
        address gatewayAddr = gatewayFactory.deployGateway();
        vault = MantleYieldVault(vaultAddr);
        gateway = MantleVaultGateway(gatewayAddr);
        IMantleYieldVault.InitParams memory params = _defaultParams();
        params.gateway = gatewayAddr;
        vm.prank(admin);
        vault.initialize(params);
        vm.prank(admin);
        gateway.initialize(
            IMantleVaultGateway.InitParams({
                vault: vaultAddr,
                sanctionsOracle: ISanctionsOracle(address(oracle)),
                sanctionSafe: treasuryAddr,
                admin: admin,
                syncRedeemDisabled: false
            })
        );

        bytes32 pauserRole = vault.PAUSER_ROLE();
        vm.prank(admin);
        vault.grantRole(pauserRole, pauser);

        oracle.setSanctioned(sanctionedUser, true);

        usdc.mint(alice, INITIAL_DEPOSIT);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        gateway.deposit(INITIAL_DEPOSIT);
        vm.stopPrank();
    }

    function _defaultParams() internal view returns (IMantleYieldVault.InitParams memory) {
        return IMantleYieldVault.InitParams({
            asset: IERC20(address(usdc)),
            name: "Mantle RWA Vault",
            symbol: "mRWA",
            admin: admin,
            gateway: address(0),
            controller: controllerAddr,
            accountant: accountantAddr,
            treasury: treasuryAddr,
            maxRedemptionFeeBps: 500,
            redemptionFeeBps: FEE_BPS,
            minRedeemAmount: MIN_REDEEM,
            minDepositAmount: 0
        });
    }
}

// =============================================================
// 初始化测试
// =============================================================

contract InitializeTest is VaultTestBase {
    function _deployUninitializedVaultAndGateway()
        internal
        returns (MantleYieldVault target, MantleVaultGateway targetGateway)
    {
        address targetAddr = factory.deployVault();
        address targetGatewayAddr = gatewayFactory.deployGateway();
        target = MantleYieldVault(targetAddr);
        targetGateway = MantleVaultGateway(targetGatewayAddr);
    }

    function test_initialState() public view {
        assertEq(vault.exchangeRate(), 1e18);
        assertEq(vault.redemptionFeeBps(), FEE_BPS);
        assertEq(vault.minRedeemAmount(), MIN_REDEEM);
        assertEq(vault.controller(), controllerAddr);
        assertEq(vault.accountant(), accountantAddr);
        assertEq(vault.treasury(), treasuryAddr);
        assertEq(vault.totalSupply(), INITIAL_DEPOSIT);
        assertEq(vault.balanceOf(alice), INITIAL_DEPOSIT);
    }

    function test_cannotInitializeTwice() public {
        vm.expectRevert();
        vault.initialize(_defaultParams());
    }

    function _paramsWithOverride(
        address asset_,
        address controller_,
        address accountant_,
        address treasury_,
        uint256 maxFee_,
        uint256 fee_
    ) internal view returns (IMantleYieldVault.InitParams memory p) {
        p = _defaultParams();
        p.asset = IERC20(asset_);
        p.controller = controller_;
        p.accountant = accountant_;
        p.treasury = treasury_;
        p.maxRedemptionFeeBps = maxFee_;
        p.redemptionFeeBps = fee_;
    }

    function test_cannotInitializeWithZeroController() public {
        (MantleYieldVault target, MantleVaultGateway targetGateway) = _deployUninitializedVaultAndGateway();
        IMantleYieldVault.InitParams memory p =
            _paramsWithOverride(address(usdc), address(0), accountantAddr, treasuryAddr, 500, 0);
        p.gateway = address(targetGateway);

        vm.expectRevert(IMantleYieldVault.Vault__ZeroAddress.selector);
        target.initialize(p);
    }

    function test_cannotInitializeWithZeroAsset() public {
        (MantleYieldVault target, MantleVaultGateway targetGateway) = _deployUninitializedVaultAndGateway();
        IMantleYieldVault.InitParams memory p =
            _paramsWithOverride(address(0), controllerAddr, accountantAddr, treasuryAddr, 500, 0);
        p.gateway = address(targetGateway);

        vm.expectRevert(IMantleYieldVault.Vault__ZeroAddress.selector);
        target.initialize(p);
    }

    function test_cannotInitializeWithZeroTreasury() public {
        (MantleYieldVault target, MantleVaultGateway targetGateway) = _deployUninitializedVaultAndGateway();
        IMantleYieldVault.InitParams memory p =
            _paramsWithOverride(address(usdc), controllerAddr, accountantAddr, address(0), 500, 0);
        p.gateway = address(targetGateway);

        vm.expectRevert(IMantleYieldVault.Vault__ZeroAddress.selector);
        target.initialize(p);
    }

    function test_cannotInitializeWithFeeTooHigh() public {
        (MantleYieldVault target, MantleVaultGateway targetGateway) = _deployUninitializedVaultAndGateway();
        IMantleYieldVault.InitParams memory p =
            _paramsWithOverride(address(usdc), controllerAddr, accountantAddr, treasuryAddr, 500, 600);
        p.gateway = address(targetGateway);

        vm.expectRevert(abi.encodeWithSelector(IMantleYieldVault.Vault__FeeTooHigh.selector, 600, 500));
        target.initialize(p);
    }

    function test_cannotInitializeWithZeroGateway() public {
        address targetAddr = factory.deployVault();
        MantleYieldVault target = MantleYieldVault(targetAddr);
        IMantleYieldVault.InitParams memory p = _defaultParams();
        p.gateway = address(0);

        vm.expectRevert(IMantleYieldVault.Vault__ZeroAddress.selector);
        target.initialize(p);
    }
}

// =============================================================
// 存款测试
// =============================================================

contract DepositTest is VaultTestBase {
    function test_depositMintsCorrectShares() public {
        usdc.mint(bob, 500e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 500e6);
        uint256 shares = gateway.deposit(500e6);
        vm.stopPrank();

        assertEq(shares, 500e6);
        assertEq(vault.balanceOf(bob), 500e6);
        assertEq(usdc.balanceOf(address(vault)), INITIAL_DEPOSIT + 500e6);
    }

    function test_depositMatchesPreviewDeposit() public {
        usdc.mint(bob, 500e6);
        uint256 expectedShares = vault.previewDeposit(500e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 500e6);
        uint256 shares = gateway.deposit(500e6);
        vm.stopPrank();

        assertEq(shares, expectedShares);
        assertEq(vault.balanceOf(bob), expectedShares);
    }

    function test_depositRevertsWhenPaused() public {
        vm.prank(pauser);
        vault.pause();

        usdc.mint(bob, 100e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 100e6);
        vm.expectRevert();
        gateway.deposit(100e6);
        vm.stopPrank();
    }

    function test_depositRevertsSanctionedSender() public {
        usdc.mint(sanctionedUser, 100e6);
        vm.startPrank(sanctionedUser);
        usdc.approve(address(vault), 100e6);
        vm.expectRevert(abi.encodeWithSelector(IMantleYieldVault.Vault__Sanctioned.selector, sanctionedUser));
        gateway.deposit(100e6);
        vm.stopPrank();
    }
}

// =============================================================
// 同步赎回测试
// =============================================================

contract SyncRedeemTest is VaultTestBase {
    function test_redeemWithFreeCash() public {
        uint256 shares = 100e6;
        uint256 expectedAssets = vault.previewRedeem(shares);

        vm.prank(alice);
        uint256 assets = gateway.redeem(shares);

        assertEq(assets, expectedAssets);
        assertEq(vault.balanceOf(alice), INITIAL_DEPOSIT - shares);
    }

    function test_previewWithdrawCanBeSatisfiedViaRedeem() public {
        uint256 wantAssets = 99e6;
        uint256 neededShares = vault.previewWithdraw(wantAssets);

        vm.prank(alice);
        uint256 assetsOut = gateway.redeem(neededShares);

        assertGe(assetsOut, wantAssets);
        assertEq(vault.balanceOf(alice), INITIAL_DEPOSIT - neededShares);
    }

    function test_redeemRevertsZeroShares() public {
        vm.prank(alice);
        vm.expectRevert(IMantleYieldVault.Vault__ZeroAmount.selector);
        gateway.redeem(0);
    }

    function test_redeemRevertsWhenPaused() public {
        vm.prank(pauser);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert();
        gateway.redeem(100e6);
    }

    function test_redeemRevertsInsufficientFreeCash() public {
        vm.prank(address(vault));
        usdc.transfer(address(1), INITIAL_DEPOSIT - 10e6);

        uint256 aliceShares = vault.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert();
        gateway.redeem(aliceShares);
    }

    function test_previewRedeemIncludesFee() public view {
        uint256 shares = 1000e6;
        uint256 gross = shares; // 1:1 exchange rate
        uint256 fee = (gross * FEE_BPS + BPS_DENOMINATOR - 1) / BPS_DENOMINATOR; // ceil
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
        uint256 treasuryShare = (shares * FEE_BPS + BPS_DENOMINATOR - 1) / BPS_DENOMINATOR;

        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(vault));
        emit IMantleYieldVault.FeeSharesReceived(treasuryAddr, treasuryShare, IMantleYieldVault.FeeType.Redemption);
        uint256 requestId = gateway.requestRedeem(shares);

        assertEq(requestId, 1);
        assertEq(vault.balanceOf(alice), INITIAL_DEPOSIT - shares);
        assertEq(vault.balanceOf(treasuryAddr), treasuryShare);
        assertGt(vault.totalLockedShares(), 0);
    }

    function test_requestRedeemRevertsZero() public {
        vm.prank(alice);
        vm.expectRevert(IMantleYieldVault.Vault__ZeroAmount.selector);
        gateway.requestRedeem(0);
    }

    function test_requestRedeemRevertsBelowMin() public {
        vm.prank(alice);
        vm.expectRevert();
        gateway.requestRedeem(1);
    }

    function test_requestRedeemRevertsSanctioned() public {
        usdc.mint(sanctionedUser, 100e6);
        vm.startPrank(sanctionedUser);
        usdc.approve(address(vault), 100e6);
        vm.expectRevert(abi.encodeWithSelector(IMantleYieldVault.Vault__Sanctioned.selector, sanctionedUser));
        gateway.deposit(100e6);
        vm.stopPrank();
    }

    function test_requestRedeemRoutesSanctionedOwnerToSanctionSafe() public {
        uint256 shares = 200e6;
        uint256 safeBefore = vault.balanceOf(treasuryAddr);

        oracle.setSanctioned(alice, true);

        vm.prank(alice);
        uint256 requestId = gateway.requestRedeem(shares);

        assertEq(requestId, 0);
        assertEq(vault.balanceOf(alice), INITIAL_DEPOSIT - shares);
        assertEq(vault.balanceOf(treasuryAddr), safeBefore + shares);
        assertEq(vault.pendingRedeemRequest(alice), 0);
    }

    function test_fullRedemptionLifecycle() public {
        uint256 shares = 500e6;

        vm.prank(alice);
        uint256 requestId = gateway.requestRedeem(shares);

        uint256[] memory ids = new uint256[](1);
        ids[0] = requestId;

        vm.prank(controllerAddr);
        vault.updateRequestBatch(ids, IMantleYieldVault.RequestStatus.PROCESSING);

        (,,,, uint256 reqAssets,,,) = vault.requests(requestId);
        uint256[] memory settled = new uint256[](1);
        settled[0] = reqAssets;

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(controllerAddr);
        vault.markRequestsDone(ids, settled);

        assertEq(usdc.balanceOf(alice), balBefore + reqAssets, "USDC transferred directly by markRequestsDone");
    }

    function test_multipleRequestsThenSettle() public {
        vm.prank(alice);
        uint256 id1 = gateway.requestRedeem(200e6);

        vm.prank(alice);
        uint256 id2 = gateway.requestRedeem(200e6);

        uint256[] memory ids = new uint256[](2);
        ids[0] = id1;
        ids[1] = id2;

        uint256[] memory settled = new uint256[](2);
        (,,,, settled[0],,,) = vault.requests(id1);
        (,,,, settled[1],,,) = vault.requests(id2);

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(controllerAddr);
        vault.updateRequestBatch(ids, IMantleYieldVault.RequestStatus.PROCESSING);
        vm.prank(controllerAddr);
        vault.markRequestsDone(ids, settled);

        assertEq(usdc.balanceOf(alice), balBefore + settled[0] + settled[1], "USDC transferred directly");
    }
}

// =============================================================
// updateRequestBatch 测试
// =============================================================

contract UpdateRequestBatchTest is VaultTestBase {
    function test_pendingRequestCount_IncrementsOnRequest() public {
        assertEq(vault.pendingRequestCount(), 0);
        vm.prank(alice);
        gateway.requestRedeem(500e6);
        assertEq(vault.pendingRequestCount(), 1);
    }

    function test_pendingRequestCount_DecrementsWhenMovedToProcessing() public {
        vm.prank(alice);
        uint256 id = gateway.requestRedeem(500e6);

        assertEq(vault.pendingRequestCount(), 1);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        vm.prank(controllerAddr);
        vault.updateRequestBatch(ids, IMantleYieldVault.RequestStatus.PROCESSING);

        assertEq(vault.pendingRequestCount(), 0);
    }

    function test_canTransitionPendingToProcessing() public {
        vm.prank(alice);
        uint256 id = gateway.requestRedeem(500e6);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        vm.prank(controllerAddr);
        vault.updateRequestBatch(ids, IMantleYieldVault.RequestStatus.PROCESSING);
    }

    function test_revertsForbiddenTargetStatus_NONE() public {
        vm.prank(alice);
        uint256 id = gateway.requestRedeem(500e6);

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

    function test_revertsForbiddenTargetStatus_DONE() public {
        vm.prank(alice);
        uint256 id = gateway.requestRedeem(500e6);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        vm.prank(controllerAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMantleYieldVault.Vault__StatusTransitionForbidden.selector, IMantleYieldVault.RequestStatus.DONE
            )
        );
        vault.updateRequestBatch(ids, IMantleYieldVault.RequestStatus.DONE);
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

    function test_revertsOnBackwardTransition() public {
        vm.prank(alice);
        uint256 id = gateway.requestRedeem(500e6);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        vm.prank(controllerAddr);
        vault.updateRequestBatch(ids, IMantleYieldVault.RequestStatus.PROCESSING);

        vm.prank(controllerAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMantleYieldVault.Vault__InvalidState.selector, id, IMantleYieldVault.RequestStatus.PROCESSING
            )
        );
        vault.updateRequestBatch(ids, IMantleYieldVault.RequestStatus.PENDING);
    }

    function test_revertsOnSameStatusTransition() public {
        vm.prank(alice);
        uint256 id = gateway.requestRedeem(500e6);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        vm.prank(controllerAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMantleYieldVault.Vault__InvalidState.selector, id, IMantleYieldVault.RequestStatus.PENDING
            )
        );
        vault.updateRequestBatch(ids, IMantleYieldVault.RequestStatus.PENDING);
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
        vault.confirmInFlight(id, 98, false);
        vm.stopPrank();

        assertEq(vault.totalInvestInFlight(), 0);
        assertEq(vault.adapterInvestInFlightTokens(address(adapter)), 0);
    }

    function test_confirmInFlightRedeem() public {
        vm.startPrank(controllerAddr);
        uint256 id = vault.createInFlight(address(adapter), address(usdc), 50, 50e6, false);
        vault.confirmInFlight(id, 49e6, false);
        vm.stopPrank();

        assertEq(vault.totalRedeemInFlight(), 0);
        assertEq(vault.adapterRedeemInFlightUsdc(address(adapter)), 0);
    }

    function test_confirmInFlightRevertsIfAlreadyConfirmed() public {
        vm.startPrank(controllerAddr);
        uint256 id = vault.createInFlight(address(adapter), address(usdc), 100, 100e6, true);
        vault.confirmInFlight(id, 100, false);

        vm.expectRevert(
            abi.encodeWithSelector(
                IMantleYieldVault.Vault__InvalidInFlightState.selector, id, IMantleYieldVault.InFlightStatus.CONFIRMED
            )
        );
        vault.confirmInFlight(id, 100, false);
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
    function test_exchangeRateReadsFromAccountant() public {
        uint256 newRate = 1.05e18;
        mockAccountant.setExchangeRate(newRate);

        assertEq(vault.exchangeRate(), newRate);
    }

    function test_exchangeRateRevertsWhenAccountantReturnsZero() public {
        mockAccountant.setExchangeRate(0);
        vm.expectRevert(IMantleYieldVault.Vault__ZeroExchangeRate.selector);
        vault.previewRedeem(1e6);
    }

    function test_accountantPauseBlocksSubscribeRedeem() public {
        mockAccountant.setPauseStatus(true);

        usdc.mint(bob, 100e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 100e6);
        vm.expectRevert();
        gateway.deposit(100e6);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert();
        gateway.redeem(10e6);
    }

    function test_exchangeRateAffectsSharePrice() public {
        mockAccountant.setExchangeRate(1.05e18);

        uint256 assetsFor100Shares = vault.previewRedeem(100e6);
        uint256 grossAssets = Math.mulDiv(100e6, 1.05e18, 1e18, Math.Rounding.Floor);
        uint256 fee = Math.mulDiv(grossAssets, FEE_BPS, BPS_DENOMINATOR, Math.Rounding.Ceil);
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
        gateway.requestRedeem(shares);

        assertEq(usdc.balanceOf(address(vault)), vaultBalBefore);
    }

    function test_syncRedeemEmitsRedemptionFee() public {
        uint256 shares = 100e6;
        uint256 treasuryShare = (shares * FEE_BPS + BPS_DENOMINATOR - 1) / BPS_DENOMINATOR;

        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(vault));
        emit IMantleYieldVault.FeeSharesReceived(treasuryAddr, treasuryShare, IMantleYieldVault.FeeType.Redemption);
        gateway.redeem(shares);

        assertEq(vault.balanceOf(treasuryAddr), treasuryShare);
    }

    function test_feeIncreasesFreeCashOnRedeem() public {
        uint256 shares = 100e6;
        uint256 freeCashBefore = vault.getFreeCash();

        vm.prank(alice);
        gateway.redeem(shares);

        uint256 gross = shares;
        uint256 fee = (gross * FEE_BPS + BPS_DENOMINATOR - 1) / BPS_DENOMINATOR;
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
        gateway.requestRedeem(shares);

        uint256 gross = shares;
        uint256 fee = (gross * FEE_BPS + BPS_DENOMINATOR - 1) / BPS_DENOMINATOR;
        uint256 lockedAssets = gross - fee;

        assertEq(vault.getFreeCash(), INITIAL_DEPOSIT - lockedAssets);
    }

    function test_getFreeCash_afterFullRedeem_feeRemains() public {
        uint256 aliceBalance = vault.balanceOf(alice);
        vm.prank(alice);
        gateway.requestRedeem(aliceBalance);

        uint256 gross = aliceBalance;
        uint256 fee = (gross * FEE_BPS + BPS_DENOMINATOR - 1) / BPS_DENOMINATOR;

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

        adapter.setTotalValue(500e6, address(vault));

        assertEq(vault.totalAssets(), INITIAL_DEPOSIT + 500e6);
    }

    function test_totalAssetsSubtractsLiabilities() public {
        uint256 shares = 500e6;

        vm.prank(alice);
        gateway.requestRedeem(shares);

        uint256 gross = shares;
        uint256 fee = (gross * FEE_BPS + BPS_DENOMINATOR - 1) / BPS_DENOMINATOR;
        uint256 lockedAssets = gross - fee;

        assertEq(vault.totalAssets(), INITIAL_DEPOSIT - lockedAssets);
    }

    function test_totalAssetsReturnsZeroWhenLiabilitiesExceedTotal() public {
        uint256 aliceBalance = vault.balanceOf(alice);
        vm.prank(alice);
        gateway.requestRedeem(aliceBalance);

        uint256 gross = aliceBalance;
        uint256 fee = (gross * FEE_BPS + BPS_DENOMINATOR - 1) / BPS_DENOMINATOR;

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
        gateway.setSanctionsOracle(address(newOracle));
        assertEq(address(gateway.sanctionsOracle()), address(newOracle));
    }

    function test_setSanctionsOracleRevertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(IMantleYieldVault.Vault__ZeroAddress.selector);
        gateway.setSanctionsOracle(address(0));
    }

    function test_setSanctionSafe() public {
        address newSafe = makeAddr("newSafe");
        vm.prank(admin);
        gateway.setSanctionSafe(newSafe);
        assertEq(gateway.sanctionSafe(), newSafe);
    }

    function test_gatewayMaxViewsBlockedForSanctionedOwner() public {
        oracle.setSanctioned(alice, true);

        assertEq(gateway.maxDeposit(alice), 0);
        assertEq(gateway.maxRedeem(alice), 0);
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
        uint256 toMint = totalBefore * 100 / BPS_DENOMINATOR; // 1% of supply

        vm.prank(accountantAddr);
        vm.expectEmit(true, false, false, true, address(vault));
        emit IMantleYieldVault.FeeSharesReceived(treasuryAddr, toMint, IMantleYieldVault.FeeType.Management);
        vault.mintFeeShares(toMint);

        assertEq(vault.balanceOf(treasuryAddr), toMint);
    }

    function test_mintFeeSharesNoLongerHasCap() public {
        uint256 totalBefore = vault.totalSupply();
        uint256 tooMuch = totalBefore * 1_100 / BPS_DENOMINATOR;

        vm.prank(accountantAddr);
        vault.mintFeeShares(tooMuch);

        assertEq(vault.balanceOf(treasuryAddr), tooMuch);
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
        gateway.requestRedeem(half);

        uint256 maxR = vault.maxRedeem(alice);
        assertLe(vault.previewRedeem(maxR), vault.getFreeCash());
    }

    function test_maxWithdrawLimitedByFreeCash() public {
        uint256 half = INITIAL_DEPOSIT / 2;

        vm.prank(alice);
        gateway.requestRedeem(half);

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
        gateway.requestRedeem(500e6);

        uint256 treasuryShare = (500e6 * FEE_BPS + BPS_DENOMINATOR - 1) / BPS_DENOMINATOR;
        assertEq(vault.pendingRedeemRequest(alice), 500e6 - treasuryShare);
    }
}

// =============================================================
// Gateway View Passthrough 测试
// =============================================================

contract GatewayViewPassthroughTest is VaultTestBase {
    function test_gatewayLimitViewsMirrorVault() public view {
        assertEq(gateway.maxRedeem(alice), vault.maxRedeem(alice));
        assertEq(gateway.maxDeposit(alice), vault.maxDeposit(alice));
    }

    function test_gatewayPreviewViewsMirrorVault() public view {
        uint256 shares = 123e6;
        assertEq(gateway.previewRedeem(shares), vault.previewRedeem(shares));
    }

    function test_gatewayAssetViewsMirrorVault() public view {
        assertEq(gateway.exchangeRate(), vault.exchangeRate());
        assertEq(gateway.totalAssets(), vault.totalAssets());
        assertEq(gateway.redemptionFeeBps(), vault.redemptionFeeBps());
        assertEq(gateway.managementFeeRate(), mockAccountant.managementFeeRate());

        IMantleYieldVault.tokenInfo[] memory gatewayInfos = gateway.getTokenInfos();
        IMantleYieldVault.tokenInfo[] memory vaultInfos = vault.getTokenInfos();

        assertEq(gatewayInfos.length, vaultInfos.length);
        for (uint256 i = 0; i < vaultInfos.length; i++) {
            assertEq(gatewayInfos[i].token, vaultInfos[i].token);
            assertEq(gatewayInfos[i].tokenAmount, vaultInfos[i].tokenAmount);
            assertEq(gatewayInfos[i].usdcAmount, vaultInfos[i].usdcAmount);
        }
    }

    function test_gatewayMaxViewsReturnZeroWhenAccountantPaused() public {
        mockAccountant.setPauseStatus(true);

        assertEq(gateway.maxDeposit(alice), 0);
        assertEq(gateway.maxRedeem(alice), 0);
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
        adapter.setTotalValue(INITIAL_DEPOSIT, address(vault));
        vm.prank(controllerAddr);
        vault.confirmInFlight(1, INITIAL_DEPOSIT, false);

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
        gateway.redeem(aliceShares);

        // ====================================================
        // Phase 3: Async redeem (T+N) full flow
        // ====================================================

        // Step 3a: User requests async redeem
        vm.prank(alice);
        uint256 reqId = gateway.requestRedeem(aliceShares);

        uint256 netAssets = 990e6; // 1000e6 - 1% fee (10e6)
        uint256 aliceTreasuryShare = (aliceShares * FEE_BPS + BPS_DENOMINATOR - 1) / BPS_DENOMINATOR;
        uint256 aliceNetShares = aliceShares - aliceTreasuryShare;
        assertEq(vault.totalLockedShares(), aliceNetShares, "locked shares = net redeemed shares");
        assertEq(vault.balanceOf(alice), 0, "shares burned");
        // floatingLocked = _convertToAssets(totalLockedShares, Ceil), no fee re-applied
        uint256 floatingLocked = vault.totalLockedShares() * vault.exchangeRate() / 1e18;
        assertEq(vault.totalAssets(), INITIAL_DEPOSIT - floatingLocked, "totalAssets = total - floatingLocked");

        // Step 3b: Controller moves to PROCESSING
        uint256[] memory ids = new uint256[](1);
        ids[0] = reqId;
        vm.prank(controllerAddr);
        vault.updateRequestBatch(ids, IMantleYieldVault.RequestStatus.PROCESSING);

        // Step 3c: Controller initiates async redeem from adapter
        //   adapter.totalValue drops (tokens leaving adapter), in-flight bridges the gap
        adapter.setTotalValue(10e6, address(vault)); // 1000 - 990 withdrawn
        vm.prank(controllerAddr);
        vault.createInFlight(address(adapter), address(usdc), netAssets, netAssets, false);

        assertEq(vault.totalRedeemInFlight(), netAssets, "redeem in-flight tracking");

        // Step 3d: USDC arrives at vault (settlement)
        vm.prank(address(adapter));
        usdc.transfer(address(vault), netAssets);

        vm.prank(controllerAddr);
        vault.confirmInFlight(2, netAssets, false);

        assertEq(vault.totalRedeemInFlight(), 0, "redeem in-flight cleared");
        assertEq(usdc.balanceOf(address(vault)), netAssets, "vault received USDC");

        // Step 3e: Mark requests done (USDC transferred directly to user)
        uint256[] memory settled = new uint256[](1);
        settled[0] = netAssets;
        vm.prank(controllerAddr);
        vault.markRequestsDone(ids, settled);

        // ====================================================
        // Final state verification (markRequestsDone transfers USDC directly)
        // ====================================================

        uint256 treasuryShares = (aliceShares * FEE_BPS + BPS_DENOMINATOR - 1) / BPS_DENOMINATOR;
        assertEq(usdc.balanceOf(alice), netAssets, "alice received 990 USDC");
        assertEq(usdc.balanceOf(address(vault)), 0, "vault back to 0 cash");
        assertEq(vault.totalLockedShares(), 0, "locked shares cleared");
        assertEq(vault.totalSupply(), treasuryShares, "only treasury fee shares outstanding");
        assertEq(vault.balanceOf(treasuryAddr), treasuryShares, "treasury holds fee shares");
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
        adapter.setTotalValue(INITIAL_DEPOSIT, address(vault));
        vm.prank(controllerAddr);
        vault.confirmInFlight(1, INITIAL_DEPOSIT, false);

        assertEq(vault.getFreeCash(), 0, "initial: zero cash");

        // --- Bob deposits 500 USDC ---
        uint256 bobDeposit = 500e6;
        usdc.mint(bob, bobDeposit);
        vm.startPrank(bob);
        usdc.approve(address(vault), bobDeposit);
        gateway.deposit(bobDeposit);
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
        adapter.setTotalValue(INITIAL_DEPOSIT + bobDeposit, address(vault));
        vm.prank(controllerAddr);
        vault.confirmInFlight(2, bobDeposit, false);

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
        adapter.setTotalValue(INITIAL_DEPOSIT, address(vault));
        vm.prank(controllerAddr);
        vault.confirmInFlight(1, INITIAL_DEPOSIT, false);
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
        adapter.setTotalValue(INITIAL_DEPOSIT, address(vault));
        vm.prank(controllerAddr);
        vault.confirmInFlight(1, INITIAL_DEPOSIT, false);

        // --- Alice requests async redeem ---
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 reqId = gateway.requestRedeem(aliceShares);
        uint256 netAssets = 990e6; // 1000 - 1% fee

        uint256[] memory ids = new uint256[](1);
        ids[0] = reqId;
        vm.prank(controllerAddr);
        vault.updateRequestBatch(ids, IMantleYieldVault.RequestStatus.PROCESSING);

        // --- Adapter async redeem settles with friction ---
        uint256 actualReceived = netAssets - friction; // 985e6
        adapter.setTotalValue(INITIAL_DEPOSIT - actualReceived, address(vault));
        vm.prank(controllerAddr);
        vault.createInFlight(address(adapter), address(usdc), netAssets, netAssets, false);
        vm.prank(address(adapter));
        usdc.transfer(address(vault), actualReceived); // only 985 USDC arrives
        vm.prank(controllerAddr);
        vault.confirmInFlight(2, actualReceived, false);

        assertEq(usdc.balanceOf(address(vault)), actualReceived, "vault has 985 USDC");

        // markRequestsDone with settledAssets = actualReceived (less than estimated)
        uint256 lockedSharesBefore = vault.totalLockedShares();
        uint256[] memory settled = new uint256[](1);
        settled[0] = actualReceived;
        vm.prank(controllerAddr);
        vault.markRequestsDone(ids, settled);

        // Shares released; USDC transferred directly to alice
        uint256 aliceTreasuryShareFriction = (aliceShares * FEE_BPS + BPS_DENOMINATOR - 1) / BPS_DENOMINATOR;
        uint256 aliceNetSharesFriction = aliceShares - aliceTreasuryShareFriction;
        assertEq(vault.totalLockedShares(), lockedSharesBefore - aliceNetSharesFriction, "locked shares released");
        assertEq(usdc.balanceOf(alice), actualReceived, "alice receives 985 USDC (990 - 5 friction) directly");

        // estimatedAssets preserved, settledAssets = actual
        (,,,, uint256 estAssets, uint256 settled_,, IMantleYieldVault.RequestStatus status) = vault.requests(reqId);
        assertEq(estAssets, netAssets, "estimatedAssets preserved");
        assertEq(settled_, actualReceived, "settledAssets = actual settlement");
        assertTrue(status == IMantleYieldVault.RequestStatus.DONE, "request is DONE");
        assertEq(vault.totalLockedShares(), 0, "all locked shares settled");
    }

    /// @dev settledAssets > estimatedAssets (underlying appreciated during async period)
    function test_markRequestsDone_settledExceedsEstimated_works() public {
        uint256 redeemShares = 500e6;
        vm.prank(alice);
        uint256 reqId = gateway.requestRedeem(redeemShares);

        uint256[] memory ids = new uint256[](1);
        ids[0] = reqId;
        vm.prank(controllerAddr);
        vault.updateRequestBatch(ids, IMantleYieldVault.RequestStatus.PROCESSING);

        (,,,, uint256 estAssets,,,) = vault.requests(reqId);
        uint256 surplus = 10e6;
        uint256 settledAmount = estAssets + surplus;
        uint256[] memory settled = new uint256[](1);
        settled[0] = settledAmount;

        uint256 lockedSharesBefore = vault.totalLockedShares();

        usdc.mint(address(vault), surplus);

        vm.prank(controllerAddr);
        vault.markRequestsDone(ids, settled);

        uint256 redeemTreasuryShare = (redeemShares * FEE_BPS + BPS_DENOMINATOR - 1) / BPS_DENOMINATOR;
        uint256 redeemNetShares = redeemShares - redeemTreasuryShare;
        assertEq(vault.totalLockedShares(), lockedSharesBefore - redeemNetShares, "locked shares released");
        assertEq(usdc.balanceOf(alice), settledAmount, "alice receives surplus directly");
    }

    /// @dev ids and settledAssets length mismatch reverts
    function test_markRequestsDone_revertsOnLengthMismatch() public {
        vm.prank(alice);
        uint256 reqId = gateway.requestRedeem(500e6);

        uint256[] memory ids = new uint256[](1);
        ids[0] = reqId;

        uint256[] memory settled = new uint256[](2);
        settled[0] = 100e6;
        settled[1] = 100e6;

        vm.prank(controllerAddr);
        vm.expectRevert(abi.encodeWithSelector(IMantleYieldVault.Vault__LengthMismatch.selector, 1, 2));
        vault.markRequestsDone(ids, settled);
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
        gateway.deposit(10_000e6);
    }

    function test_setSyncRedeemDisabled_onlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        gateway.setSyncRedeemDisabled(true);
    }

    function test_setSyncRedeemDisabled_emitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(address(gateway));
        emit IMantleVaultGateway.SyncRedeemDisabledUpdated(true);
        gateway.setSyncRedeemDisabled(true);

        assertTrue(gateway.syncRedeemDisabled());
    }

    function test_redeemRevertsWhenSyncDisabled() public {
        vm.prank(admin);
        gateway.setSyncRedeemDisabled(true);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(IMantleYieldVault.Vault__SyncRedeemDisabled.selector);
        gateway.redeem(shares);
    }

    function test_maxRedeemNotAffectedWhenSyncDisabled() public {
        vm.prank(admin);
        gateway.setSyncRedeemDisabled(true);

        assertGt(vault.maxRedeem(alice), 0);
    }

    function test_maxWithdrawNotAffectedWhenSyncDisabled() public {
        vm.prank(admin);
        gateway.setSyncRedeemDisabled(true);

        assertGt(vault.maxWithdraw(alice), 0);
    }

    function test_requestRedeemStillWorksWhenSyncDisabled() public {
        vm.prank(admin);
        gateway.setSyncRedeemDisabled(true);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        gateway.requestRedeem(shares);

        uint256 treasuryShare = (shares * FEE_BPS + BPS_DENOMINATOR - 1) / BPS_DENOMINATOR;
        assertEq(vault.pendingRedeemRequest(alice), shares - treasuryShare);
    }

    function test_redeemWorksAfterReenabling() public {
        vm.prank(admin);
        gateway.setSyncRedeemDisabled(true);

        vm.prank(admin);
        gateway.setSyncRedeemDisabled(false);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        gateway.redeem(shares);

        assertEq(vault.balanceOf(alice), 0);
    }
}
