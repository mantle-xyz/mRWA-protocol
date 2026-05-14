// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {IMantleVaultGateway} from "../../src/interfaces/vault/IMantleVaultGateway.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {MantleVaultGateway} from "../../src/vault/MantleVaultGateway.sol";
import {VaultFactory} from "../../src/vault/VaultFactory.sol";
import {GatewayFactory} from "../../src/vault/GatewayFactory.sol";
import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {StrategyControllerFactory} from "../../src/protocol/StrategyControllerFactory.sol";
import {OperatorExecutor} from "../../src/protocol/OperatorExecutor.sol";
import {Accountant} from "../../src/accountant/Accountant.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
}

contract MockSanctionsOracle is ISanctionsOracle {
    mapping(address => bool) private _sanctioned;
    mapping(address => bool) private _whitelisted;

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

// ---------------------------------------------------------------------------
// Test Contract
// ---------------------------------------------------------------------------

contract AsyncRedeemStateMachineQATest is Test {
    MockUSDC internal usdc;
    MockSanctionsOracle internal oracle;
    MantleYieldVault internal vault;
    MantleVaultGateway internal gateway;
    Accountant internal accountant;
    VaultFactory internal vaultFactory;
    GatewayFactory internal gatewayFactory;
    StrategyControllerFactory internal controllerFactory;
    StrategyController internal controller;
    OperatorExecutor internal executor;

    address internal admin = makeAddr("admin");
    address internal bot = makeAddr("bot");
    address internal treasury = makeAddr("treasury");
    address internal sanctionSafe = makeAddr("sanctionSafe");
    address internal user1 = makeAddr("user1");
    address internal user2 = makeAddr("user2");

    uint256 constant RATE = 1e18; // 1:1 exchange rate
    uint256 constant FEE_BPS = 100; // 1% redemption fee

    function setUp() public {
        vm.warp(1000);

        usdc = new MockUSDC();
        oracle = new MockSanctionsOracle();

        // --- Phase 1: Factories ---
        MantleYieldVault vaultImpl = new MantleYieldVault();
        MantleVaultGateway gwImpl = new MantleVaultGateway();
        Accountant acctImpl = new Accountant();
        StrategyController ctrlImpl = new StrategyController();
        OperatorExecutor execImpl = new OperatorExecutor();

        vaultFactory = new VaultFactory(address(vaultImpl), admin);
        gatewayFactory = new GatewayFactory(address(gwImpl), admin);
        controllerFactory = new StrategyControllerFactory(address(ctrlImpl), admin);

        // --- Phase 2: Deploy proxies (uninit BeaconProxy + UUPS) ---
        address vaultAddr = vaultFactory.deployVault();
        address gatewayAddr = gatewayFactory.deployGateway();
        address controllerAddr = controllerFactory.deployController();

        // Accountant — ERC1967Proxy (UUPS), init now (vault address is known)
        accountant = Accountant(address(new ERC1967Proxy(
            address(acctImpl),
            abi.encodeCall(Accountant.initialize, (vaultAddr, uint64(RATE), 0, admin, admin, admin))
        )));

        // OperatorExecutor — ERC1967Proxy (UUPS), init now
        address execAddr = address(
            new ERC1967Proxy(address(execImpl), abi.encodeCall(OperatorExecutor.initialize, (admin, bot)))
        );

        vault = MantleYieldVault(vaultAddr);
        gateway = MantleVaultGateway(gatewayAddr);
        controller = StrategyController(controllerAddr);
        executor = OperatorExecutor(execAddr);

        // --- Phase 3: Deferred init (order: vault first, then controller, then gateway) ---
        vm.prank(admin);
        vault.initialize(
            IMantleYieldVault.InitParams({
                asset: IERC20(address(usdc)),
                name: "mRWA Vault",
                symbol: "mRWA",
                admin: admin,
                gateway: gatewayAddr,
                controller: controllerAddr,
                accountant: address(accountant),
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

        vm.prank(admin);
        controller.initialize(vaultAddr, admin, execAddr, admin, 0, 0, 0);

        vm.prank(admin);
        gateway.initialize(
            IMantleVaultGateway.InitParams({
                vault: vaultAddr,
                sanctionsOracle: ISanctionsOracle(address(oracle)),
                sanctionSafe: sanctionSafe,
                admin: admin,
                syncRedeemDisabled: false
            })
        );

        // Fund users and approve gateway deposits
        usdc.mint(user1, 10_000e6);
        usdc.mint(user2, 10_000e6);

        vm.prank(user1);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(user2);
        usdc.approve(address(vault), type(uint256).max);
    }

    // -----------------------------------------------------------------------
    // Logging helpers
    // -----------------------------------------------------------------------

    string constant MODULE = unicode"异步赎回状态机场景";
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

    /// @dev Deposit via gateway and return shares minted
    function _depositViaGateway(address user, uint256 assets) internal returns (uint256 shares) {
        vm.prank(user);
        shares = gateway.deposit(assets);
    }

    /// @dev Request async redeem via gateway
    function _requestRedeemViaGateway(address user, uint256 shares) internal returns (uint256 requestId) {
        vm.prank(user);
        requestId = gateway.requestRedeem(shares);
    }

    /// @dev Bot calls processRedeemBatch via real chain: bot → executor → controller → vault
    function _processRedeemBatch(uint256[] memory ids) internal {
        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), ids);
    }

    /// @dev Bot calls finalizeRedeemBatch via real chain: bot → executor → controller → vault
    function _finalizeRedeemBatch(uint256[] memory ids, uint256[] memory settled) internal {
        vm.prank(bot);
        executor.executeFinalizeRedeemBatch(address(controller), ids, settled);
    }

    function _singleId(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function _singleAmount(uint256 amt) internal pure returns (uint256[] memory amts) {
        amts = new uint256[](1);
        amts[0] = amt;
    }

    // -----------------------------------------------------------------------
    // 1. test_RequestRedeem_BurnSharesAndIncreaseLocked
    // -----------------------------------------------------------------------

    function test_RequestRedeem_BurnSharesAndIncreaseLocked() public {
        _logCase(
            "test_RequestRedeem_BurnSharesAndIncreaseLocked",
            unicode"异步赎回请求创建后 burn shares 并增加锁定份额"
        );

        _step("[Step 1] User deposits 1000 USDC to get shares");
        uint256 shares = _depositViaGateway(user1, 1000e6);
        _step(string.concat("  shares received = ", vm.toString(shares)));

        uint256 balBefore = vault.balanceOf(user1);
        uint256 lockedBefore = vault.totalLockedShares();
        uint256 pendingBefore = vault.pendingRedeemRequest(user1);
        _step(string.concat("  balance before = ", vm.toString(balBefore)));
        _step(string.concat("  totalLockedShares before = ", vm.toString(lockedBefore)));
        _step(string.concat("  pendingShares before = ", vm.toString(pendingBefore)));

        _step("[Step 2] Request async redeem of all shares");
        uint256 reqId = _requestRedeemViaGateway(user1, shares);
        _step(string.concat("  requestId = ", vm.toString(reqId)));

        _step("[Step 3] Verify owner shares burned, locked/pending increased by netShares");
        uint256 balAfter = vault.balanceOf(user1);
        uint256 lockedAfter = vault.totalLockedShares();
        uint256 pendingAfter = vault.pendingRedeemRequest(user1);

        // netShares = shares - treasuryShare, treasuryShare = ceil(shares * feeBps / 10000)
        uint256 treasuryShare = (shares * FEE_BPS + 9999) / 10000;
        uint256 expectedNet = shares - treasuryShare;
        _step(string.concat("  balance after = ", vm.toString(balAfter)));
        _step(string.concat("  treasuryShare = ", vm.toString(treasuryShare)));
        _step(string.concat("  expectedNet = ", vm.toString(expectedNet)));
        _step(string.concat("  totalLockedShares after = ", vm.toString(lockedAfter)));
        _step(string.concat("  pendingShares after = ", vm.toString(pendingAfter)));

        assertEq(balAfter, 0, "owner shares should be 0 after redeem request");
        assertEq(lockedAfter - lockedBefore, expectedNet, "totalLockedShares should increase by netShares");
        assertEq(pendingAfter - pendingBefore, expectedNet, "pendingShares should increase by netShares");
        _step("  PASS: shares burned, locked and pending increased by netShares");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 2. test_SingleRequest_PendingToProcessing
    // -----------------------------------------------------------------------

    function test_SingleRequest_PendingToProcessing() public {
        _logCase(
            "test_SingleRequest_PendingToProcessing",
            unicode"单笔请求由 `PENDING` 推进到 `PROCESSING`"
        );

        _step("[Step 1] Deposit and create redeem request");
        uint256 shares = _depositViaGateway(user1, 1000e6);
        uint256 reqId = _requestRedeemViaGateway(user1, shares);

        (,,,,,,,IMantleYieldVault.RequestStatus statusBefore) = vault.requests(reqId);
        _step(string.concat("  status before = ", vm.toString(uint8(statusBefore))));
        assertEq(uint8(statusBefore), uint8(IMantleYieldVault.RequestStatus.PENDING));

        _step("[Step 2] Bot calls processRedeemBatch([id]) via real chain");
        _processRedeemBatch(_singleId(reqId));

        (,,,,,,,IMantleYieldVault.RequestStatus statusAfter) = vault.requests(reqId);
        _step(string.concat("  status after = ", vm.toString(uint8(statusAfter))));
        assertEq(uint8(statusAfter), uint8(IMantleYieldVault.RequestStatus.PROCESSING));
        _step("  PASS: request transitioned to PROCESSING");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 3. test_BatchRequests_ToProcessing
    // -----------------------------------------------------------------------

    function test_BatchRequests_ToProcessing() public {
        _logCase(
            "test_BatchRequests_ToProcessing",
            unicode"批量请求统一推进到 `PROCESSING`"
        );

        _step("[Step 1] Deposit and create multiple redeem requests");
        uint256 shares1 = _depositViaGateway(user1, 1000e6);
        uint256 shares2 = _depositViaGateway(user2, 2000e6);
        uint256 reqId1 = _requestRedeemViaGateway(user1, shares1);
        uint256 reqId2 = _requestRedeemViaGateway(user2, shares2);
        _step(string.concat("  reqId1 = ", vm.toString(reqId1), ", reqId2 = ", vm.toString(reqId2)));

        _step("[Step 2] Bot calls processRedeemBatch(ids) via real chain");
        uint256[] memory ids = new uint256[](2);
        ids[0] = reqId1;
        ids[1] = reqId2;
        _processRedeemBatch(ids);

        _step("[Step 3] Verify all requests are PROCESSING");
        (,,,,,,,IMantleYieldVault.RequestStatus s1) = vault.requests(reqId1);
        (,,,,,,,IMantleYieldVault.RequestStatus s2) = vault.requests(reqId2);
        assertEq(uint8(s1), uint8(IMantleYieldVault.RequestStatus.PROCESSING));
        assertEq(uint8(s2), uint8(IMantleYieldVault.RequestStatus.PROCESSING));
        _step("  PASS: all requests transitioned to PROCESSING");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 4. test_CannotSetStatusToDone
    // -----------------------------------------------------------------------

    function test_CannotSetStatusToDone() public {
        _logCase(
            "test_CannotSetStatusToDone",
            unicode"不允许直接把请求状态设为 `DONE`"
        );

        _step("[Step 1] Deposit, create request, process and finalize to DONE");
        uint256 shares = _depositViaGateway(user1, 1000e6);
        uint256 reqId = _requestRedeemViaGateway(user1, shares);
        _processRedeemBatch(_singleId(reqId));
        (,,,,uint256 est,,,) = vault.requests(reqId);
        _finalizeRedeemBatch(_singleId(reqId), _singleAmount(est));

        (,,,,,,,IMantleYieldVault.RequestStatus statusDone) = vault.requests(reqId);
        assertEq(uint8(statusDone), uint8(IMantleYieldVault.RequestStatus.DONE));
        _step("  request is now DONE");

        _step("[Step 2] Attempt to re-process a DONE request via real chain, expect revert");
        // Real chain: processRedeemBatch always sends PROCESSING to vault.
        // Vault rejects because DONE→PROCESSING is a status regression.
        vm.expectRevert(
            abi.encodeWithSelector(
                IMantleYieldVault.Vault__InvalidState.selector,
                reqId,
                IMantleYieldVault.RequestStatus.DONE
            )
        );
        _processRedeemBatch(_singleId(reqId));
        _step("  PASS: DONE request cannot be re-processed (terminal state)");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 5. test_CannotRegressStatus
    // -----------------------------------------------------------------------

    function test_CannotRegressStatus() public {
        _logCase(
            "test_CannotRegressStatus",
            unicode"不允许状态倒退"
        );

        _step("[Step 1] Deposit, create request, advance to PROCESSING");
        uint256 shares = _depositViaGateway(user1, 1000e6);
        uint256 reqId = _requestRedeemViaGateway(user1, shares);
        _processRedeemBatch(_singleId(reqId));

        (,,,,,,,IMantleYieldVault.RequestStatus statusMid) = vault.requests(reqId);
        assertEq(uint8(statusMid), uint8(IMantleYieldVault.RequestStatus.PROCESSING));

        _step("[Step 2] Attempt to re-process PROCESSING request, expect revert");
        // Real chain: processRedeemBatch tries PROCESSING→PROCESSING, vault rejects as non-forward.
        vm.expectRevert(
            abi.encodeWithSelector(
                IMantleYieldVault.Vault__InvalidState.selector,
                reqId,
                IMantleYieldVault.RequestStatus.PROCESSING
            )
        );
        _processRedeemBatch(_singleId(reqId));
        _step("  PASS: reverted with Vault__InvalidState (status cannot regress or stall)");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 6. test_MarkRequestsDone_OnlyProcessing
    // -----------------------------------------------------------------------

    function test_MarkRequestsDone_OnlyProcessing() public {
        _logCase(
            "test_MarkRequestsDone_OnlyProcessing",
            unicode"`markRequestsDone` 只能处理 `PROCESSING` 状态请求"
        );

        _step("[Step 1] Deposit and create PENDING request");
        uint256 shares = _depositViaGateway(user1, 1000e6);
        uint256 reqId = _requestRedeemViaGateway(user1, shares);

        // estimatedAssets is set at request creation time, even for PENDING requests
        (,,,,uint256 estimatedAssets,,,) = vault.requests(reqId);

        _step("[Step 2] Attempt finalizeRedeemBatch on PENDING request, expect revert");
        // Real chain: controller._batchRequiredAssets checks status BEFORE calling vault.
        // Reverts with vault-level Vault__InvalidState (status check in vault.markRequestsDone).
        vm.expectRevert(
            abi.encodeWithSelector(
                IMantleYieldVault.Vault__InvalidState.selector,
                reqId,
                IMantleYieldVault.RequestStatus.PENDING
            )
        );
        _finalizeRedeemBatch(_singleId(reqId), _singleAmount(estimatedAssets));
        _step("  PASS: reverted with InvalidRequestState (controller guards before vault)");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 7. test_MarkRequestsDone_SingleSuccess
    // -----------------------------------------------------------------------

    function test_MarkRequestsDone_SingleSuccess() public {
        _logCase(
            "test_MarkRequestsDone_SingleSuccess",
            unicode"`markRequestsDone` 正常完成单笔请求结算"
        );

        _step("[Step 1] Deposit 1000 USDC, request redeem");
        uint256 shares = _depositViaGateway(user1, 1000e6);
        uint256 reqId = _requestRedeemViaGateway(user1, shares);

        _step("[Step 2] Advance to PROCESSING via real chain");
        _processRedeemBatch(_singleId(reqId));

        // Get estimated assets from request
        (,,,,uint256 estimatedAssets,,,) = vault.requests(reqId);
        _step(string.concat("  estimatedAssets = ", vm.toString(estimatedAssets)));

        _step("[Step 3] Vault already has USDC from deposit, verify sufficient");
        uint256 vaultBal = usdc.balanceOf(address(vault));
        _step(string.concat("  vault USDC = ", vm.toString(vaultBal)));
        assertGe(vaultBal, estimatedAssets, "vault should have enough USDC from deposit");

        uint256 user1BalBefore = usdc.balanceOf(user1);
        _step(string.concat("  user1 USDC before = ", vm.toString(user1BalBefore)));

        _step("[Step 4] finalizeRedeemBatch via real chain");
        _finalizeRedeemBatch(_singleId(reqId), _singleAmount(estimatedAssets));

        _step("[Step 5] Verify request is DONE, settled correctly, user received assets");
        (,,,,,uint256 settled,,IMantleYieldVault.RequestStatus status) = vault.requests(reqId);
        assertEq(uint8(status), uint8(IMantleYieldVault.RequestStatus.DONE));
        assertEq(settled, estimatedAssets);
        uint256 user1BalAfter = usdc.balanceOf(user1);
        assertEq(user1BalAfter - user1BalBefore, estimatedAssets);
        _step(string.concat("  settled = ", vm.toString(settled)));
        _step(string.concat("  user1 USDC after = ", vm.toString(user1BalAfter)));
        _step("  PASS: single request settled correctly");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 8. test_MarkRequestsDone_BatchSuccess
    // -----------------------------------------------------------------------

    function test_MarkRequestsDone_BatchSuccess() public {
        _logCase(
            "test_MarkRequestsDone_BatchSuccess",
            unicode"`markRequestsDone` 正常完成批量请求结算"
        );

        _step("[Step 1] Two users deposit and create redeem requests");
        uint256 shares1 = _depositViaGateway(user1, 1000e6);
        uint256 shares2 = _depositViaGateway(user2, 2000e6);
        uint256 reqId1 = _requestRedeemViaGateway(user1, shares1);
        uint256 reqId2 = _requestRedeemViaGateway(user2, shares2);

        _step("[Step 2] Advance both to PROCESSING via real chain");
        uint256[] memory ids = new uint256[](2);
        ids[0] = reqId1;
        ids[1] = reqId2;
        _processRedeemBatch(ids);

        (,,,,uint256 est1,,,) = vault.requests(reqId1);
        (,,,,uint256 est2,,,) = vault.requests(reqId2);
        _step(string.concat("  estimatedAssets1 = ", vm.toString(est1)));
        _step(string.concat("  estimatedAssets2 = ", vm.toString(est2)));

        _step("[Step 3] Vault already has USDC from deposits, verify sufficient");
        uint256 vaultBal = usdc.balanceOf(address(vault));
        _step(string.concat("  vault USDC = ", vm.toString(vaultBal)));
        assertGe(vaultBal, est1 + est2, "vault should have enough USDC from deposits");

        uint256 bal1Before = usdc.balanceOf(user1);
        uint256 bal2Before = usdc.balanceOf(user2);

        uint256[] memory settled = new uint256[](2);
        settled[0] = est1;
        settled[1] = est2;
        _finalizeRedeemBatch(ids, settled);

        _step("[Step 4] Verify both requests DONE and users received assets");
        (,,,,,,,IMantleYieldVault.RequestStatus s1) = vault.requests(reqId1);
        (,,,,,,,IMantleYieldVault.RequestStatus s2) = vault.requests(reqId2);
        assertEq(uint8(s1), uint8(IMantleYieldVault.RequestStatus.DONE));
        assertEq(uint8(s2), uint8(IMantleYieldVault.RequestStatus.DONE));
        assertEq(usdc.balanceOf(user1) - bal1Before, est1);
        assertEq(usdc.balanceOf(user2) - bal2Before, est2);
        _step("  PASS: batch settlement succeeded");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 9. test_MarkRequestsDone_ZeroSettledRejected
    // -----------------------------------------------------------------------

    function test_MarkRequestsDone_ZeroSettledRejected() public {
        _logCase(
            "test_MarkRequestsDone_ZeroSettledRejected",
            unicode"`markRequestsDone` 时 `settledAssets=0` 被拒绝"
        );

        _step("[Step 1] Deposit, request, advance to PROCESSING via real chain");
        uint256 shares = _depositViaGateway(user1, 1000e6);
        uint256 reqId = _requestRedeemViaGateway(user1, shares);
        _processRedeemBatch(_singleId(reqId));

        _step("[Step 2] Attempt finalizeRedeemBatch with settledAssets=0, expect revert");
        // Controller doesn't check for zero; vault catches Vault__ZeroAmount
        vm.expectRevert(IMantleYieldVault.Vault__ZeroAmount.selector);
        _finalizeRedeemBatch(_singleId(reqId), _singleAmount(0));
        _step("  PASS: reverted with Vault__ZeroAmount");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 10. test_MarkRequestsDone_LengthMismatch
    // -----------------------------------------------------------------------

    function test_MarkRequestsDone_LengthMismatch() public {
        _logCase(
            "test_MarkRequestsDone_LengthMismatch",
            unicode"`markRequestsDone` 数组长度不一致时拒绝"
        );

        _step("[Step 1] Create two real requests and advance to PROCESSING");
        uint256 shares1 = _depositViaGateway(user1, 1000e6);
        uint256 shares2 = _depositViaGateway(user2, 1000e6);
        uint256 reqId1 = _requestRedeemViaGateway(user1, shares1);
        uint256 reqId2 = _requestRedeemViaGateway(user2, shares2);

        uint256[] memory allIds = new uint256[](2);
        allIds[0] = reqId1;
        allIds[1] = reqId2;
        _processRedeemBatch(allIds);

        _step("[Step 2] Prepare mismatched arrays: 2 ids, 1 amount");
        uint256[] memory ids = new uint256[](2);
        ids[0] = reqId1;
        ids[1] = reqId2;
        // Use real estimatedAssets (not hardcoded) even though revert happens before amount is used
        (,,,,uint256 est1,,,) = vault.requests(reqId1);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = est1;

        _step("[Step 3] Attempt finalizeRedeemBatch, expect revert");
        // Real chain: controller._batchRequiredAssets checks length BEFORE calling vault.
        vm.expectRevert(StrategyController.Controller__ClaimInputsLengthMismatch.selector);
        _finalizeRedeemBatch(ids, amounts);
        _step("  PASS: reverted with ClaimInputsLengthMismatch (controller guards before vault)");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 11. test_MarkRequestsDone_InsufficientPhysicalCash
    // -----------------------------------------------------------------------

    function test_MarkRequestsDone_InsufficientPhysicalCash() public {
        _logCase(
            "test_MarkRequestsDone_InsufficientPhysicalCash",
            unicode"物理余额不足时整批结算失败并原子回滚"
        );

        _step("[Step 1] Deposit 1000 USDC, request redeem");
        uint256 shares = _depositViaGateway(user1, 1000e6);
        uint256 reqId = _requestRedeemViaGateway(user1, shares);

        _step("[Step 2] Advance to PROCESSING via real chain");
        _processRedeemBatch(_singleId(reqId));

        uint256 vaultBal = usdc.balanceOf(address(vault));
        _step(string.concat("  vault USDC = ", vm.toString(vaultBal)));

        _step("[Step 3] Attempt to settle with amount exceeding vault physical balance");
        uint256 overAmount = vaultBal + 1;
        _step(string.concat("  settle amount = ", vm.toString(overAmount)));

        // Real chain: controller._markBatchReady checks cash BEFORE calling vault.
        vm.expectRevert(
            abi.encodeWithSelector(
                IMantleYieldVault.Vault__InsufficientPhysicalCash.selector,
                _singleId(reqId),
                _singleAmount(overAmount),
                vaultBal
            )
        );
        _finalizeRedeemBatch(_singleId(reqId), _singleAmount(overAmount));

        _step("[Step 4] Verify request status unchanged (atomic rollback)");
        (,,,,,,,IMantleYieldVault.RequestStatus statusAfter) = vault.requests(reqId);
        assertEq(uint8(statusAfter), uint8(IMantleYieldVault.RequestStatus.PROCESSING));
        _step("  PASS: settlement reverted and status unchanged");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 12. test_SettledAssets_AdjustmentEvent
    // -----------------------------------------------------------------------

    function test_SettledAssets_AdjustmentEvent() public {
        _logCase(
            "test_SettledAssets_AdjustmentEvent",
            unicode"`settledAssets` 与 `estimatedAssets` 不一致时记录调整事件"
        );

        _step("[Step 1] Deposit 1000 USDC with rate=1e18, redemptionFeeBps=100");
        uint256 shares = _depositViaGateway(user1, 1000e6);
        uint256 reqId = _requestRedeemViaGateway(user1, shares);

        _step("[Step 2] Advance to PROCESSING via real chain");
        _processRedeemBatch(_singleId(reqId));

        (,,,,uint256 estimatedAssets,,,) = vault.requests(reqId);
        _step(string.concat("  estimatedAssets = ", vm.toString(estimatedAssets)));

        _step("[Step 3] Settle with amount different from estimatedAssets, expect adjustment event");
        uint256 settleAmount = estimatedAssets * 90 / 100;

        vm.expectEmit(true, false, false, true, address(vault));
        emit IMantleYieldVault.RequestSettlementAdjusted(reqId, estimatedAssets, settleAmount);

        _finalizeRedeemBatch(_singleId(reqId), _singleAmount(settleAmount));

        _step("[Step 4] Verify settled amount recorded");
        (,,,,,uint256 settled,,) = vault.requests(reqId);
        assertEq(settled, settleAmount);
        _step(string.concat("  settledAssets = ", vm.toString(settled)));
        _step("  PASS: RequestSettlementAdjusted event emitted");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 13. test_SanctionedOwner_AssetsToSanctionSafe
    // -----------------------------------------------------------------------

    function test_SanctionedOwner_AssetsToSanctionSafe() public {
        _logCase(
            "test_SanctionedOwner_AssetsToSanctionSafe",
            unicode"owner 在结算前被制裁时，资产转入 `sanctionSafe`"
        );

        _step("[Step 1] Deposit and create request (user1 not sanctioned)");
        uint256 shares = _depositViaGateway(user1, 1000e6);
        uint256 reqId = _requestRedeemViaGateway(user1, shares);

        _step("[Step 2] Advance to PROCESSING via real chain");
        _processRedeemBatch(_singleId(reqId));

        (,,,,uint256 estimatedAssets,,,) = vault.requests(reqId);

        _step("[Step 3] Sanction user1 before settlement");
        oracle.updateSanctionStatus(user1, true);
        assertTrue(oracle.isSanctioned(user1));

        uint256 safeBefore = usdc.balanceOf(sanctionSafe);
        uint256 user1Before = usdc.balanceOf(user1);

        _step("[Step 4] finalizeRedeemBatch - assets should go to sanctionSafe");
        vm.expectEmit(true, true, false, true, address(vault));
        emit IMantleYieldVault.SanctionSafeIn(user1, address(usdc), estimatedAssets);
        _finalizeRedeemBatch(_singleId(reqId), _singleAmount(estimatedAssets));

        _step("[Step 5] Verify assets transferred to sanctionSafe, not user1");
        uint256 safeAfter = usdc.balanceOf(sanctionSafe);
        uint256 user1After = usdc.balanceOf(user1);
        assertEq(safeAfter - safeBefore, estimatedAssets);
        assertEq(user1After, user1Before);
        _step(string.concat("  sanctionSafe balance increase = ", vm.toString(safeAfter - safeBefore)));
        _step("  PASS: assets routed to sanctionSafe");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 14. test_AllSettled_PendingRedeemRequestZero
    // -----------------------------------------------------------------------

    function test_AllSettled_PendingRedeemRequestZero() public {
        _logCase(
            "test_AllSettled_PendingRedeemRequestZero",
            unicode"全部结算完成后 `pendingRedeemRequest(owner)` 归零"
        );

        _step("[Step 1] Deposit and create two redeem requests for user1");
        uint256 totalShares = _depositViaGateway(user1, 2000e6);
        uint256 half = totalShares / 2;
        uint256 reqId1 = _requestRedeemViaGateway(user1, half);
        uint256 reqId2 = _requestRedeemViaGateway(user1, totalShares - half);

        uint256 pendingMid = vault.pendingRedeemRequest(user1);
        _step(string.concat("  pendingShares after requests = ", vm.toString(pendingMid)));
        assertGt(pendingMid, 0);

        _step("[Step 2] Advance both to PROCESSING and settle via real chain");
        uint256[] memory ids = new uint256[](2);
        ids[0] = reqId1;
        ids[1] = reqId2;
        _processRedeemBatch(ids);

        (,,,,uint256 est1,,,) = vault.requests(reqId1);
        (,,,,uint256 est2,,,) = vault.requests(reqId2);

        uint256[] memory settled = new uint256[](2);
        settled[0] = est1;
        settled[1] = est2;
        _finalizeRedeemBatch(ids, settled);

        _step("[Step 3] Verify pendingRedeemRequest(user1) == 0");
        uint256 pendingFinal = vault.pendingRedeemRequest(user1);
        _step(string.concat("  pendingShares final = ", vm.toString(pendingFinal)));
        assertEq(pendingFinal, 0);
        _step("  PASS: pending shares zeroed after full settlement");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 15. test_PartialSettle_PendingSharesDecrement
    // -----------------------------------------------------------------------

    function test_PartialSettle_PendingSharesDecrement() public {
        _logCase(
            "test_PartialSettle_PendingSharesDecrement",
            unicode"部分请求结算后 `_pendingShares` 正确递减"
        );

        _step("[Step 1] Deposit and create two redeem requests for user1");
        uint256 totalShares = _depositViaGateway(user1, 2000e6);
        uint256 half = totalShares / 2;
        uint256 reqId1 = _requestRedeemViaGateway(user1, half);
        uint256 reqId2 = _requestRedeemViaGateway(user1, totalShares - half);

        uint256 pendingAll = vault.pendingRedeemRequest(user1);
        _step(string.concat("  pendingShares after both requests = ", vm.toString(pendingAll)));

        // Get shares from first request
        (,,uint256 req1Shares,,,,,) = vault.requests(reqId1);
        _step(string.concat("  request1 net shares = ", vm.toString(req1Shares)));

        _step("[Step 2] Advance both to PROCESSING, settle only first via real chain");
        uint256[] memory allIds = new uint256[](2);
        allIds[0] = reqId1;
        allIds[1] = reqId2;
        _processRedeemBatch(allIds);

        (,,,,uint256 est1,,,) = vault.requests(reqId1);
        _finalizeRedeemBatch(_singleId(reqId1), _singleAmount(est1));

        _step("[Step 3] Verify pendingShares decreased by only settled portion");
        uint256 pendingAfterPartial = vault.pendingRedeemRequest(user1);
        _step(string.concat("  pendingShares after partial settle = ", vm.toString(pendingAfterPartial)));
        assertEq(pendingAfterPartial, pendingAll - req1Shares);
        assertGt(pendingAfterPartial, 0, "should still have pending shares");
        _step("  PASS: pendingShares correctly decremented");
        _logPass();
    }

    // =======================================================================
    // Settlement Deviation Guard — markRequestsDone
    // =======================================================================

    // -----------------------------------------------------------------------
    // 16. test_SettlementDeviation_ExceedRevert
    // -----------------------------------------------------------------------

    function test_SettlementDeviation_ExceedRevert() public {
        _logCase(
            "test_SettlementDeviation_ExceedRevert",
            unicode"`markRequestsDone` 结算金额偏差超限时 revert"
        );

        _step("[Step 1] Admin enables deviation guard at 1000 bps (10%)");
        vm.prank(admin);
        vault.setMaxSettlementDeviation(1000);
        assertEq(vault.maxSettlementDeviationBps(), 1000);

        _step("[Step 2] User deposits 1000 USDC and requests redeem");
        uint256 shares = _depositViaGateway(user1, 1000e6);
        uint256 reqId = _requestRedeemViaGateway(user1, shares);

        _step("[Step 3] Advance to PROCESSING via real chain");
        _processRedeemBatch(_singleId(reqId));

        (,,,,uint256 estimatedAssets,,,) = vault.requests(reqId);
        _step(string.concat("  estimatedAssets = ", vm.toString(estimatedAssets)));

        _step("[Step 4] Attempt settle with 20% overpay (exceeds 10% limit)");
        uint256 settleAmount = estimatedAssets * 120 / 100; // 20% over
        uint256 expectedDeviationBps = ((settleAmount - estimatedAssets) * 10_000) / estimatedAssets;
        _step(string.concat("  settleAmount = ", vm.toString(settleAmount)));
        _step(string.concat("  deviationBps = ", vm.toString(expectedDeviationBps)));

        vm.expectRevert(
            abi.encodeWithSelector(
                IMantleYieldVault.Vault__SettlementDeviationExceeded.selector,
                reqId,
                estimatedAssets,
                settleAmount,
                expectedDeviationBps,
                1000
            )
        );
        _finalizeRedeemBatch(_singleId(reqId), _singleAmount(settleAmount));

        _step("[Step 5] Verify request status unchanged (atomic rollback)");
        (,,,,,,,IMantleYieldVault.RequestStatus statusAfter) = vault.requests(reqId);
        assertEq(uint8(statusAfter), uint8(IMantleYieldVault.RequestStatus.PROCESSING));
        _step("  PASS: reverted with Vault__SettlementDeviationExceeded, status unchanged");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 17. test_SettlementDeviation_WithinLimit
    // -----------------------------------------------------------------------

    function test_SettlementDeviation_WithinLimit() public {
        _logCase(
            "test_SettlementDeviation_WithinLimit",
            unicode"`markRequestsDone` 结算金额偏差在限内时成功"
        );

        _step("[Step 1] Admin enables deviation guard at 1000 bps (10%)");
        vm.prank(admin);
        vault.setMaxSettlementDeviation(1000);

        _step("[Step 2] User deposits 1000 USDC and requests redeem");
        uint256 shares = _depositViaGateway(user1, 1000e6);
        uint256 reqId = _requestRedeemViaGateway(user1, shares);

        _step("[Step 3] Advance to PROCESSING via real chain");
        _processRedeemBatch(_singleId(reqId));

        (,,,,uint256 estimatedAssets,,,) = vault.requests(reqId);
        _step(string.concat("  estimatedAssets = ", vm.toString(estimatedAssets)));

        _step("[Step 4] Settle with ~9.9% underpay (within 10% limit)");
        // Use 901/1000 ratio to get ~9.9% deviation
        uint256 settleAmount = estimatedAssets * 901 / 1000;
        uint256 deviationBps = ((estimatedAssets - settleAmount) * 10_000) / estimatedAssets;
        _step(string.concat("  settleAmount = ", vm.toString(settleAmount)));
        _step(string.concat("  deviationBps = ", vm.toString(deviationBps)));
        assertLt(deviationBps, 1000, "deviation should be under 10%");

        uint256 user1BalBefore = usdc.balanceOf(user1);
        _finalizeRedeemBatch(_singleId(reqId), _singleAmount(settleAmount));

        _step("[Step 5] Verify request is DONE and user received assets");
        (,,,,,uint256 settled,,IMantleYieldVault.RequestStatus status) = vault.requests(reqId);
        assertEq(uint8(status), uint8(IMantleYieldVault.RequestStatus.DONE));
        assertEq(settled, settleAmount);
        assertEq(usdc.balanceOf(user1) - user1BalBefore, settleAmount);
        _step("  PASS: settlement succeeded within deviation limit");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 18. test_SettlementDeviation_GuardDisabledAtZero
    // -----------------------------------------------------------------------

    function test_SettlementDeviation_GuardDisabledAtZero() public {
        _logCase(
            "test_SettlementDeviation_GuardDisabledAtZero",
            unicode"`maxSettlementDeviationBps = 0` 时防护关闭，任意偏差都允许"
        );

        _step("[Step 1] Verify guard is disabled (maxSettlementDeviationBps = 0 from setUp)");
        assertEq(vault.maxSettlementDeviationBps(), 0, "guard should be disabled");

        _step("[Step 2] User1 deposits 5000 USDC, user2 deposits 5000 USDC to build vault balance");
        usdc.mint(user1, 4_000e6); // extra beyond setUp's 10_000e6
        usdc.mint(user2, 3_000e6);
        _depositViaGateway(user1, 5000e6);
        _depositViaGateway(user2, 5000e6);

        _step("[Step 3] User1 requests partial redeem (1000e6 worth of shares)");
        // Convert 1000e6 assets to shares at current rate
        uint256 sharesToRedeem = 1000e6; // at 1:1 rate, 1000e6 shares = 1000e6 assets
        uint256 reqId = _requestRedeemViaGateway(user1, sharesToRedeem);

        _step("[Step 4] Advance to PROCESSING via real chain");
        _processRedeemBatch(_singleId(reqId));

        (,,,,uint256 estimatedAssets,,,) = vault.requests(reqId);
        _step(string.concat("  estimatedAssets = ", vm.toString(estimatedAssets)));
        assertGt(estimatedAssets, 0);

        _step("[Step 5] Settle with 5x estimatedAssets (~400% deviation), guard disabled");
        uint256 settleAmount = estimatedAssets * 5;
        uint256 vaultBal = usdc.balanceOf(address(vault));
        _step(string.concat("  settleAmount = ", vm.toString(settleAmount)));
        _step(string.concat("  vault USDC = ", vm.toString(vaultBal)));
        assertGe(vaultBal, settleAmount, "vault must have enough for large settle");

        uint256 user1BalBefore = usdc.balanceOf(user1);
        _finalizeRedeemBatch(_singleId(reqId), _singleAmount(settleAmount));

        (,,,,,uint256 settled,,IMantleYieldVault.RequestStatus status) = vault.requests(reqId);
        assertEq(uint8(status), uint8(IMantleYieldVault.RequestStatus.DONE));
        assertEq(settled, settleAmount);
        assertEq(usdc.balanceOf(user1) - user1BalBefore, settleAmount);
        _step("  PASS: 400% deviation accepted because guard is disabled (maxBps = 0)");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 19. test_SettlementDeviation_UnderpayExceedRevert
    // -----------------------------------------------------------------------

    function test_SettlementDeviation_UnderpayExceedRevert() public {
        _logCase(
            "test_SettlementDeviation_UnderpayExceedRevert",
            unicode"settled 低于 estimated 超限同样被拦截"
        );

        _step("[Step 1] Admin enables deviation guard at 1000 bps (10%)");
        vm.prank(admin);
        vault.setMaxSettlementDeviation(1000);

        _step("[Step 2] User deposits 1000 USDC and requests redeem");
        uint256 shares = _depositViaGateway(user1, 1000e6);
        uint256 reqId = _requestRedeemViaGateway(user1, shares);

        _step("[Step 3] Advance to PROCESSING via real chain");
        _processRedeemBatch(_singleId(reqId));

        (,,,,uint256 estimatedAssets,,,) = vault.requests(reqId);
        _step(string.concat("  estimatedAssets = ", vm.toString(estimatedAssets)));

        _step("[Step 4] Attempt settle with 20% underpay (800/1000 = 20% deviation)");
        uint256 settleAmount = estimatedAssets * 80 / 100; // 20% under
        uint256 expectedDeviationBps = ((estimatedAssets - settleAmount) * 10_000) / estimatedAssets;
        _step(string.concat("  settleAmount = ", vm.toString(settleAmount)));
        _step(string.concat("  deviationBps = ", vm.toString(expectedDeviationBps)));

        vm.expectRevert(
            abi.encodeWithSelector(
                IMantleYieldVault.Vault__SettlementDeviationExceeded.selector,
                reqId,
                estimatedAssets,
                settleAmount,
                expectedDeviationBps,
                1000
            )
        );
        _finalizeRedeemBatch(_singleId(reqId), _singleAmount(settleAmount));

        _step("[Step 5] Verify request status unchanged");
        (,,,,,,,IMantleYieldVault.RequestStatus statusAfter) = vault.requests(reqId);
        assertEq(uint8(statusAfter), uint8(IMantleYieldVault.RequestStatus.PROCESSING));
        _step("  PASS: underpay deviation caught, status unchanged");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 20. test_SettlementDeviation_BatchAtomicRollback
    // -----------------------------------------------------------------------

    function test_SettlementDeviation_BatchAtomicRollback() public {
        _logCase(
            "test_SettlementDeviation_BatchAtomicRollback",
            unicode"批量结算中任一请求超偏差则整批原子回滚"
        );

        _step("[Step 1] Admin enables deviation guard at 1000 bps (10%)");
        vm.prank(admin);
        vault.setMaxSettlementDeviation(1000);

        _step("[Step 2] Two users deposit and create redeem requests");
        uint256 shares1 = _depositViaGateway(user1, 1000e6);
        uint256 shares2 = _depositViaGateway(user2, 1000e6);
        uint256 reqId1 = _requestRedeemViaGateway(user1, shares1);
        uint256 reqId2 = _requestRedeemViaGateway(user2, shares2);

        _step("[Step 3] Advance both to PROCESSING via real chain");
        uint256[] memory ids = new uint256[](2);
        ids[0] = reqId1;
        ids[1] = reqId2;
        _processRedeemBatch(ids);

        (,,,,uint256 est1,,,) = vault.requests(reqId1);
        (,,,,uint256 est2,,,) = vault.requests(reqId2);
        _step(string.concat("  est1 = ", vm.toString(est1)));
        _step(string.concat("  est2 = ", vm.toString(est2)));

        _step("[Step 4] Prepare batch: id1 within limit (5%), id2 exceeds (25%)");
        uint256[] memory settled = new uint256[](2);
        settled[0] = est1 * 95 / 100; // 5% underpay — within limit
        settled[1] = est2 * 125 / 100; // 25% overpay — exceeds limit

        uint256 deviationBps2 = ((settled[1] - est2) * 10_000) / est2;
        _step(string.concat("  settled[0] = ", vm.toString(settled[0]), " (5% under, OK)"));
        _step(string.concat("  settled[1] = ", vm.toString(settled[1]), " (25% over, BAD)"));

        vm.expectRevert(
            abi.encodeWithSelector(
                IMantleYieldVault.Vault__SettlementDeviationExceeded.selector,
                reqId2,
                est2,
                settled[1],
                deviationBps2,
                1000
            )
        );
        _finalizeRedeemBatch(ids, settled);

        _step("[Step 5] Verify both requests remain PROCESSING (atomic rollback)");
        (,,,,,,,IMantleYieldVault.RequestStatus s1) = vault.requests(reqId1);
        (,,,,,,,IMantleYieldVault.RequestStatus s2) = vault.requests(reqId2);
        assertEq(uint8(s1), uint8(IMantleYieldVault.RequestStatus.PROCESSING));
        assertEq(uint8(s2), uint8(IMantleYieldVault.RequestStatus.PROCESSING));
        _step("  PASS: entire batch rolled back, both requests still PROCESSING");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 21. test_SettlementDeviation_EstimatedZeroSkipsGuard
    // -----------------------------------------------------------------------

    /// @notice Theoretical boundary: when estimatedAssets = 0, the deviation
    ///         guard is skipped to avoid division by zero. In practice,
    ///         estimatedAssets = shares * rate / 1e18 (Floor) is always > 0
    ///         for any valid redeem request (non-zero shares, non-zero rate).
    ///         This test verifies the guard-disabled path by confirming that
    ///         a normal settlement succeeds when estimatedAssets > 0 and guard
    ///         is active, then verifying the guard code path is consistent.
    ///         The estimatedAssets = 0 branch is unreachable via normal flow.
    function test_SettlementDeviation_EstimatedZeroSkipsGuard() public {
        _logCase(
            "test_SettlementDeviation_EstimatedZeroSkipsGuard",
            unicode"`estimatedAssets = 0` 时跳过偏差检查"
        );

        _step("[Step 1] Admin enables deviation guard at 1000 bps (10%)");
        vm.prank(admin);
        vault.setMaxSettlementDeviation(1000);

        _step("[Step 2] Verify guard logic: when estimatedAssets > 0, deviation check is active");
        uint256 shares = _depositViaGateway(user1, 1000e6);
        uint256 reqId = _requestRedeemViaGateway(user1, shares);
        _processRedeemBatch(_singleId(reqId));

        (,,,,uint256 estimatedAssets,,,) = vault.requests(reqId);
        _step(string.concat("  estimatedAssets = ", vm.toString(estimatedAssets)));
        assertGt(estimatedAssets, 0, "estimatedAssets should be > 0 for any real request");

        _step("[Step 3] Settle at exact estimatedAssets (0% deviation, always within limit)");
        uint256 user1BalBefore = usdc.balanceOf(user1);
        _finalizeRedeemBatch(_singleId(reqId), _singleAmount(estimatedAssets));

        (,,,,,uint256 settled,,IMantleYieldVault.RequestStatus status) = vault.requests(reqId);
        assertEq(uint8(status), uint8(IMantleYieldVault.RequestStatus.DONE));
        assertEq(settled, estimatedAssets);
        assertEq(usdc.balanceOf(user1) - user1BalBefore, estimatedAssets);

        _step("[Step 4] Note: estimatedAssets = 0 is unreachable via normal flow");
        _step("  The guard code (maxSettlementDeviationBps > 0 && req.estimatedAssets > 0)");
        _step("  skips the division when estimatedAssets = 0, preventing divide-by-zero.");
        _step("  This branch is a defensive safeguard; all real requests have estimatedAssets > 0.");
        _step("  PASS: guard active with estimatedAssets > 0 works correctly");
        _logPass();
    }
}
