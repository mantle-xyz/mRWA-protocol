// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {IMantleVaultGateway} from "../../src/interfaces/vault/IMantleVaultGateway.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {MantleVaultGateway} from "../../src/vault/MantleVaultGateway.sol";
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

    function setSanctioned(address account, bool sanctioned) external {
        _sanctioned[account] = sanctioned;
    }
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

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal controllerAddr;
    address internal sanctionSafe = makeAddr("sanctionSafe");
    address internal user1 = makeAddr("user1");
    address internal user2 = makeAddr("user2");

    uint256 constant RATE = 1e18; // 1:1 exchange rate
    uint256 constant FEE_BPS = 100; // 1% redemption fee

    function setUp() public {
        usdc = new MockUSDC();
        oracle = new MockSanctionsOracle();

        // Deploy Accountant
        Accountant acctImpl = new Accountant();

        // Deploy Vault (we need a temporary controller; we'll use admin as controller)
        MantleYieldVault vaultImpl = new MantleYieldVault();

        // Deploy Gateway
        MantleVaultGateway gwImpl = new MantleVaultGateway();

        // We use admin as controller for these tests (controller calls updateRequestBatch/markRequestsDone)
        controllerAddr = admin;

        // Initialize vault behind proxy
        bytes memory vaultInitData = abi.encodeCall(
            MantleYieldVault.initialize,
            IMantleYieldVault.InitParams({
                asset: IERC20(address(usdc)),
                name: "mRWA Vault",
                symbol: "mRWA",
                admin: admin,
                gateway: address(1), // placeholder, will update
                controller: controllerAddr,
                accountant: address(1), // placeholder, will update
                treasury: treasury,
                maxRedemptionFeeBps: 500,
                redemptionFeeBps: FEE_BPS,
                minRedeemAmount: 0,
                minDepositAmount: 0
            })
        );
        vault = MantleYieldVault(address(new ERC1967Proxy(address(vaultImpl), vaultInitData)));

        // Initialize accountant
        bytes memory acctInitData = abi.encodeCall(
            Accountant.initialize,
            (address(vault), uint64(RATE), 0, admin)
        );
        accountant = Accountant(address(new ERC1967Proxy(address(acctImpl), acctInitData)));

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

        // Set accountant and gateway on vault
        vm.startPrank(admin);
        vault.setAccountant(address(accountant));
        vault.setGateway(address(gateway));
        vm.stopPrank();

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

    /// @dev Controller calls updateRequestBatch
    function _updateBatch(uint256[] memory ids, IMantleYieldVault.RequestStatus status) internal {
        vm.prank(controllerAddr);
        vault.updateRequestBatch(ids, status);
    }

    /// @dev Controller calls markRequestsDone
    function _markDone(uint256[] memory ids, uint256[] memory settled) internal {
        vm.prank(controllerAddr);
        vault.markRequestsDone(ids, settled);
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

        _step("[Step 2] Controller calls updateRequestBatch([id], PROCESSING)");
        _updateBatch(_singleId(reqId), IMantleYieldVault.RequestStatus.PROCESSING);

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

        _step("[Step 2] Controller calls updateRequestBatch(ids, PROCESSING)");
        uint256[] memory ids = new uint256[](2);
        ids[0] = reqId1;
        ids[1] = reqId2;
        _updateBatch(ids, IMantleYieldVault.RequestStatus.PROCESSING);

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

        _step("[Step 1] Deposit and create redeem request");
        uint256 shares = _depositViaGateway(user1, 1000e6);
        uint256 reqId = _requestRedeemViaGateway(user1, shares);

        _step("[Step 2] Attempt updateRequestBatch with DONE status, expect revert");
        vm.expectRevert(
            abi.encodeWithSelector(
                IMantleYieldVault.Vault__StatusTransitionForbidden.selector,
                IMantleYieldVault.RequestStatus.DONE
            )
        );
        _updateBatch(_singleId(reqId), IMantleYieldVault.RequestStatus.DONE);
        _step("  PASS: reverted with Vault__StatusTransitionForbidden");
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
        _updateBatch(_singleId(reqId), IMantleYieldVault.RequestStatus.PROCESSING);

        _step("[Step 2] Attempt to regress to PENDING, expect revert");
        vm.expectRevert(
            abi.encodeWithSelector(
                IMantleYieldVault.Vault__InvalidState.selector,
                reqId,
                IMantleYieldVault.RequestStatus.PROCESSING
            )
        );
        _updateBatch(_singleId(reqId), IMantleYieldVault.RequestStatus.PENDING);
        _step("  PASS: reverted with Vault__InvalidState");
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

        _step("[Step 2] Attempt markRequestsDone on PENDING request, expect revert");
        vm.expectRevert(
            abi.encodeWithSelector(
                IMantleYieldVault.Vault__InvalidState.selector,
                reqId,
                IMantleYieldVault.RequestStatus.PENDING
            )
        );
        _markDone(_singleId(reqId), _singleAmount(990e6));
        _step("  PASS: reverted with Vault__InvalidState");
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

        _step("[Step 2] Advance to PROCESSING");
        _updateBatch(_singleId(reqId), IMantleYieldVault.RequestStatus.PROCESSING);

        // Get estimated assets from request
        (,,,,uint256 estimatedAssets,,,) = vault.requests(reqId);
        _step(string.concat("  estimatedAssets = ", vm.toString(estimatedAssets)));

        _step("[Step 3] Vault already has USDC from deposit, verify sufficient");
        uint256 vaultBal = usdc.balanceOf(address(vault));
        _step(string.concat("  vault USDC = ", vm.toString(vaultBal)));
        assertGe(vaultBal, estimatedAssets, "vault should have enough USDC from deposit");

        uint256 user1BalBefore = usdc.balanceOf(user1);
        _step(string.concat("  user1 USDC before = ", vm.toString(user1BalBefore)));

        _step("[Step 4] markRequestsDone");
        _markDone(_singleId(reqId), _singleAmount(estimatedAssets));

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

        _step("[Step 2] Advance both to PROCESSING");
        uint256[] memory ids = new uint256[](2);
        ids[0] = reqId1;
        ids[1] = reqId2;
        _updateBatch(ids, IMantleYieldVault.RequestStatus.PROCESSING);

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
        _markDone(ids, settled);

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

        _step("[Step 1] Deposit, request, advance to PROCESSING");
        uint256 shares = _depositViaGateway(user1, 1000e6);
        uint256 reqId = _requestRedeemViaGateway(user1, shares);
        _updateBatch(_singleId(reqId), IMantleYieldVault.RequestStatus.PROCESSING);

        _step("[Step 2] Attempt markRequestsDone with settledAssets=0, expect revert");
        vm.expectRevert(IMantleYieldVault.Vault__ZeroAmount.selector);
        _markDone(_singleId(reqId), _singleAmount(0));
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

        _step("[Step 1] Create two real requests");
        uint256 shares1 = _depositViaGateway(user1, 1000e6);
        uint256 shares2 = _depositViaGateway(user2, 1000e6);
        uint256 reqId1 = _requestRedeemViaGateway(user1, shares1);
        uint256 reqId2 = _requestRedeemViaGateway(user2, shares2);

        uint256[] memory allIds = new uint256[](2);
        allIds[0] = reqId1;
        allIds[1] = reqId2;
        _updateBatch(allIds, IMantleYieldVault.RequestStatus.PROCESSING);

        _step("[Step 2] Prepare mismatched arrays: 2 ids, 1 amount");
        uint256[] memory ids = new uint256[](2);
        ids[0] = reqId1;
        ids[1] = reqId2;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e6;

        _step("[Step 2] Attempt markRequestsDone, expect revert");
        vm.expectRevert(
            abi.encodeWithSelector(IMantleYieldVault.Vault__LengthMismatch.selector, 2, 1)
        );
        _markDone(ids, amounts);
        _step("  PASS: reverted with Vault__LengthMismatch");
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

        _step("[Step 2] Advance to PROCESSING");
        _updateBatch(_singleId(reqId), IMantleYieldVault.RequestStatus.PROCESSING);

        uint256 vaultBal = usdc.balanceOf(address(vault));
        _step(string.concat("  vault USDC = ", vm.toString(vaultBal)));

        _step("[Step 3] Attempt to settle with amount exceeding vault physical balance");
        // Vault has 1000e6 from deposit; settle with vaultBal + 1 to exceed physical balance
        // This simulates a scenario where rate changed and settlement requires more than available
        uint256 overAmount = vaultBal + 1;
        _step(string.concat("  settle amount = ", vm.toString(overAmount)));

        vm.expectPartialRevert(IMantleYieldVault.Vault__InsufficientPhysicalCash.selector);
        _markDone(_singleId(reqId), _singleAmount(overAmount));

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

        _step("[Step 2] Advance to PROCESSING");
        _updateBatch(_singleId(reqId), IMantleYieldVault.RequestStatus.PROCESSING);

        (,,,,uint256 estimatedAssets,,,) = vault.requests(reqId);
        _step(string.concat("  estimatedAssets = ", vm.toString(estimatedAssets)));
        // estimatedAssets should be 990e6 (1000 - 1% fee)

        _step("[Step 3] Settle with 900e6 (different from estimatedAssets), expect adjustment event");
        uint256 settleAmount = 900e6;
        // vault already has 1000e6 from deposit, sufficient for 900e6 settlement

        vm.expectEmit(true, false, false, true, address(vault));
        emit IMantleYieldVault.RequestSettlementAdjusted(reqId, estimatedAssets, settleAmount);

        _markDone(_singleId(reqId), _singleAmount(settleAmount));

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

        _step("[Step 2] Advance to PROCESSING");
        _updateBatch(_singleId(reqId), IMantleYieldVault.RequestStatus.PROCESSING);

        (,,,,uint256 estimatedAssets,,,) = vault.requests(reqId);
        // vault already has 1000e6 from deposit, sufficient for ~990e6 settlement

        _step("[Step 3] Sanction user1 before settlement");
        oracle.setSanctioned(user1, true);
        assertTrue(oracle.isSanctioned(user1));

        uint256 safeBefore = usdc.balanceOf(sanctionSafe);
        uint256 user1Before = usdc.balanceOf(user1);

        _step("[Step 4] markRequestsDone - assets should go to sanctionSafe");
        vm.expectEmit(true, true, false, true, address(vault));
        emit IMantleYieldVault.SanctionSafeIn(user1, address(usdc), estimatedAssets);
        _markDone(_singleId(reqId), _singleAmount(estimatedAssets));

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

        _step("[Step 2] Advance both to PROCESSING and settle");
        uint256[] memory ids = new uint256[](2);
        ids[0] = reqId1;
        ids[1] = reqId2;
        _updateBatch(ids, IMantleYieldVault.RequestStatus.PROCESSING);

        (,,,,uint256 est1,,,) = vault.requests(reqId1);
        (,,,,uint256 est2,,,) = vault.requests(reqId2);
        // vault already has 2000e6 from deposit, sufficient for settlement

        uint256[] memory settled = new uint256[](2);
        settled[0] = est1;
        settled[1] = est2;
        _markDone(ids, settled);

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

        _step("[Step 2] Advance both to PROCESSING, settle only first");
        uint256[] memory allIds = new uint256[](2);
        allIds[0] = reqId1;
        allIds[1] = reqId2;
        _updateBatch(allIds, IMantleYieldVault.RequestStatus.PROCESSING);

        (,,,,uint256 est1,,,) = vault.requests(reqId1);
        // vault already has 2000e6 from deposit, sufficient for settlement
        _markDone(_singleId(reqId1), _singleAmount(est1));

        _step("[Step 3] Verify pendingShares decreased by only settled portion");
        uint256 pendingAfterPartial = vault.pendingRedeemRequest(user1);
        _step(string.concat("  pendingShares after partial settle = ", vm.toString(pendingAfterPartial)));
        assertEq(pendingAfterPartial, pendingAll - req1Shares);
        assertGt(pendingAfterPartial, 0, "should still have pending shares");
        _step("  PASS: pendingShares correctly decremented");
        _logPass();
    }
}
