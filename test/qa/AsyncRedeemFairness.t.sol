// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {IMantleVaultGateway} from "../../src/interfaces/vault/IMantleVaultGateway.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {GatewayFactory} from "../../src/vault/GatewayFactory.sol";
import {MantleVaultGateway} from "../../src/vault/MantleVaultGateway.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {VaultFactory} from "../../src/vault/VaultFactory.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

// ---------------------------------------------------------------------------
// Mock contracts
// ---------------------------------------------------------------------------

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

    function isWhitelisted(address) external pure override returns (bool) {
        return true;
    }

    function setSanctioned(address account, bool status) external {
        sanctioned[account] = status;
    }

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

// ---------------------------------------------------------------------------
// QA Test: Async Redeem Fairness & Queue Gaming Scenarios
// ---------------------------------------------------------------------------

contract AsyncRedeemFairnessQATest is Test {
    MockUSDC internal usdc;
    MockSanctionsOracle internal oracle;
    MockAccountant internal mockAccountant;
    MantleYieldVault internal vault;
    MantleVaultGateway internal gateway;
    VaultFactory internal factory;
    GatewayFactory internal gatewayFactory;

    address internal admin = makeAddr("admin");
    address internal controllerAddr = makeAddr("controller");
    address internal treasuryAddr = makeAddr("treasury");
    address internal sanctionSafe = makeAddr("sanctionSafe");
    address internal userA = makeAddr("userA");
    address internal userB = makeAddr("userB");
    address internal userC = makeAddr("userC");

    uint256 constant DEPOSIT_AMOUNT = 50_000e6;
    uint256 constant FEE_BPS = 100; // 1%
    uint256 constant FEE_BASIS = 10_000;

    function setUp() public {
        usdc = new MockUSDC();
        oracle = new MockSanctionsOracle();
        mockAccountant = new MockAccountant();

        MantleYieldVault impl = new MantleYieldVault();
        MantleVaultGateway gatewayImpl = new MantleVaultGateway();
        factory = new VaultFactory(address(impl), admin);
        gatewayFactory = new GatewayFactory(address(gatewayImpl), admin);

        address vaultAddr = factory.deployVault();
        address gatewayAddr = gatewayFactory.deployGateway();
        vault = MantleYieldVault(vaultAddr);
        gateway = MantleVaultGateway(gatewayAddr);

        vm.prank(admin);
        vault.initialize(
            IMantleYieldVault.InitParams({
                asset: IERC20(address(usdc)),
                name: "Mantle RWA Vault",
                symbol: "mRWA",
                admin: admin,
                gateway: gatewayAddr,
                controller: controllerAddr,
                accountant: address(mockAccountant),
                treasury: treasuryAddr,
                maxRedemptionFeeBps: 500,
                redemptionFeeBps: FEE_BPS,
                minRedeemAmount: 0,
                minDepositAmount: 0
            })
        );

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

        _depositForUser(userA, DEPOSIT_AMOUNT);
        _depositForUser(userB, DEPOSIT_AMOUNT);
        _depositForUser(userC, DEPOSIT_AMOUNT);
    }

    function _depositForUser(address user, uint256 amount) internal {
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(vault), type(uint256).max);
        gateway.deposit(amount);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // Logging helpers
    // -----------------------------------------------------------------------

    string constant MODULE = unicode"业务博弈、汇率波动、抢赎、排队公平性与极端流动性场景";
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

    function _requestRedeem(address user, uint256 shares) internal returns (uint256 requestId) {
        vm.prank(user);
        requestId = gateway.requestRedeem(shares);
    }

    function _updateBatch(uint256[] memory ids, IMantleYieldVault.RequestStatus status) internal {
        vm.prank(controllerAddr);
        vault.updateRequestBatch(ids, status);
    }

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
    // 1. test_EarlierRequest_HasSmallerRequestId
    // -----------------------------------------------------------------------

    function test_EarlierRequest_HasSmallerRequestId() public {
        _logCase(
            "test_EarlierRequest_HasSmallerRequestId",
            unicode"先创建的异步请求应具有更早的 `requestId`"
        );

        _step("[Step 1] userA creates async redeem request");
        uint256 reqA = _requestRedeem(userA, 1000e6);
        _step(string.concat("  userA requestId = ", vm.toString(reqA)));

        _step("[Step 2] userB creates async redeem request");
        uint256 reqB = _requestRedeem(userB, 1000e6);
        _step(string.concat("  userB requestId = ", vm.toString(reqB)));

        _step("[Step 3] Verify userA.requestId < userB.requestId");
        assertLt(reqA, reqB, "earlier request should have smaller requestId");
        _step("  PASS: userA.requestId < userB.requestId");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 2. test_OperatorCanSkipEarlyRequests_QueueJumping
    // -----------------------------------------------------------------------

    function test_OperatorCanSkipEarlyRequests_QueueJumping() public {
        _logCase(
            "test_OperatorCanSkipEarlyRequests_QueueJumping",
            unicode"运营方可只选择后创建请求进入批次，验证系统是否允许\"插队处理\""
        );

        _step("[Step 1] userA creates early request, userB creates late request");
        uint256 reqEarly = _requestRedeem(userA, 1000e6);
        uint256 reqLate = _requestRedeem(userB, 1000e6);
        _step(string.concat("  early requestId = ", vm.toString(reqEarly)));
        _step(string.concat("  late requestId = ", vm.toString(reqLate)));

        _step("[Step 2] Skip early requestId, only put late requestId into processRedeemBatch");
        _updateBatch(_singleId(reqLate), IMantleYieldVault.RequestStatus.PROCESSING);

        _step("[Step 3] Verify late request is PROCESSING while early remains PENDING");
        (,,,,,,,IMantleYieldVault.RequestStatus statusEarly) = vault.requests(reqEarly);
        (,,,,,,,IMantleYieldVault.RequestStatus statusLate) = vault.requests(reqLate);
        assertEq(uint8(statusEarly), uint8(IMantleYieldVault.RequestStatus.PENDING), "early request should still be PENDING");
        assertEq(uint8(statusLate), uint8(IMantleYieldVault.RequestStatus.PROCESSING), "late request should be PROCESSING");
        _step("  PASS: system allows queue jumping - late request processed first (governance/operational fairness risk noted)");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 3. test_SameBatch_SettledInIdsOrder
    // -----------------------------------------------------------------------

    function test_SameBatch_SettledInIdsOrder() public {
        _logCase(
            "test_SameBatch_SettledInIdsOrder",
            unicode"同一批次内按 `ids` 顺序结算，验证事件和状态顺序"
        );

        _step("[Step 1] Create two requests and move to PROCESSING");
        uint256 req1 = _requestRedeem(userA, 1000e6);
        uint256 req2 = _requestRedeem(userB, 2000e6);

        uint256[] memory ids = new uint256[](2);
        ids[0] = req1;
        ids[1] = req2;
        _updateBatch(ids, IMantleYieldVault.RequestStatus.PROCESSING);

        (,,,,uint256 est1,,,) = vault.requests(req1);
        (,,,,uint256 est2,,,) = vault.requests(req2);
        _step(string.concat("  est1 = ", vm.toString(est1), ", est2 = ", vm.toString(est2)));

        _step("[Step 2] Settle batch in ids order (vault already has USDC from deposits)");

        uint256 balA_before = usdc.balanceOf(userA);
        uint256 balB_before = usdc.balanceOf(userB);

        uint256[] memory settled = new uint256[](2);
        settled[0] = est1;
        settled[1] = est2;

        vm.recordLogs();
        _markDone(ids, settled);

        _step("[Step 3] Verify both DONE with correct settled amounts and user payouts in order");
        (,,,,,uint256 s1,,IMantleYieldVault.RequestStatus st1) = vault.requests(req1);
        (,,,,,uint256 s2,,IMantleYieldVault.RequestStatus st2) = vault.requests(req2);
        assertEq(uint8(st1), uint8(IMantleYieldVault.RequestStatus.DONE));
        assertEq(uint8(st2), uint8(IMantleYieldVault.RequestStatus.DONE));
        assertEq(s1, est1);
        assertEq(s2, est2);
        // Verify users received correct amounts
        assertEq(usdc.balanceOf(userA) - balA_before, est1, "userA should receive est1");
        assertEq(usdc.balanceOf(userB) - balB_before, est2, "userB should receive est2");

        _step("[Step 4] Verify RedemptionDone events emitted in ids order");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 redemptionDoneSig = keccak256("RedemptionDone(address,address,uint256,uint256,uint256)");
        uint256 eventCount;
        address firstEventAccount;
        address secondEventAccount;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == redemptionDoneSig) {
                eventCount++;
                address account = address(uint160(uint256(logs[i].topics[1])));
                if (eventCount == 1) firstEventAccount = account;
                if (eventCount == 2) secondEventAccount = account;
            }
        }
        assertEq(eventCount, 2, "should have 2 RedemptionDone events");
        assertEq(firstEventAccount, userA, "first RedemptionDone should be for userA (ids[0])");
        assertEq(secondEventAccount, userB, "second RedemptionDone should be for userB (ids[1])");
        _step("  PASS: RedemptionDone events emitted in ids order (userA first, userB second)");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 4. test_InsufficientFunds_WholeBatchReverts
    // -----------------------------------------------------------------------

    function test_InsufficientFunds_WholeBatchReverts() public {
        _logCase(
            "test_InsufficientFunds_WholeBatchReverts",
            unicode"批次资金不足时，不允许只结算前半批而静默跳过后半批"
        );

        _step("[Step 1] Create two requests and advance to PROCESSING");
        uint256 req1 = _requestRedeem(userA, 5000e6);
        uint256 req2 = _requestRedeem(userB, 5000e6);

        uint256[] memory ids = new uint256[](2);
        ids[0] = req1;
        ids[1] = req2;
        _updateBatch(ids, IMantleYieldVault.RequestStatus.PROCESSING);

        _step("[Step 2] Settle with total amount exceeding vault physical balance");
        uint256 vaultBal = usdc.balanceOf(address(vault));
        _step(string.concat("  vault physical balance = ", vm.toString(vaultBal)));

        // Each settle amount is slightly more than half the vault balance,
        // so total exceeds physical balance
        uint256 overAmount = vaultBal / 2 + 1;
        uint256[] memory settledAmts = new uint256[](2);
        settledAmts[0] = overAmount;
        settledAmts[1] = overAmount;
        _step(string.concat("  settle total = ", vm.toString(overAmount * 2), " > vault balance"));

        _step("[Step 3] Attempt markRequestsDone, expect revert");
        vm.expectPartialRevert(IMantleYieldVault.Vault__InsufficientPhysicalCash.selector);
        _markDone(ids, settledAmts);

        _step("[Step 4] Verify both requests remain PROCESSING (atomic rollback)");
        (,,,,,,,IMantleYieldVault.RequestStatus st1) = vault.requests(req1);
        (,,,,,,,IMantleYieldVault.RequestStatus st2) = vault.requests(req2);
        assertEq(uint8(st1), uint8(IMantleYieldVault.RequestStatus.PROCESSING));
        assertEq(uint8(st2), uint8(IMantleYieldVault.RequestStatus.PROCESSING));
        _step("  PASS: whole batch reverts atomically, no partial settlement");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 5. test_EarlyAndLateBatch_ExchangeRateDifference
    // -----------------------------------------------------------------------

    function test_EarlyAndLateBatch_ExchangeRateDifference() public {
        _logCase(
            "test_EarlyAndLateBatch_ExchangeRateDifference",
            unicode"早批次和晚批次在汇率变化下的最终到账差异被显式验证"
        );

        _step("[Step 1] userA creates early request at rate=1e18");
        uint256 reqEarly = _requestRedeem(userA, 1000e6);
        (,,,,uint256 estEarly,,,) = vault.requests(reqEarly);
        _step(string.concat("  early estimatedAssets = ", vm.toString(estEarly)));

        _step("[Step 2] Change exchange rate to 1.1e18 (10% appreciation)");
        mockAccountant.setExchangeRate(1.1e18);

        _step("[Step 3] userB creates late request at new rate");
        uint256 reqLate = _requestRedeem(userB, 1000e6);
        (,,,,uint256 estLate,,,) = vault.requests(reqLate);
        _step(string.concat("  late estimatedAssets = ", vm.toString(estLate)));

        _step("[Step 4] Process and settle early batch first (vault has USDC from deposits)");
        _updateBatch(_singleId(reqEarly), IMantleYieldVault.RequestStatus.PROCESSING);
        _markDone(_singleId(reqEarly), _singleAmount(estEarly));

        _step("[Step 5] Process and settle late batch");
        _updateBatch(_singleId(reqLate), IMantleYieldVault.RequestStatus.PROCESSING);
        _markDone(_singleId(reqLate), _singleAmount(estLate));

        _step("[Step 6] Compare settlements - late batch should get more due to rate increase");
        (,,,,,uint256 settledEarly,,) = vault.requests(reqEarly);
        (,,,,,uint256 settledLate,,) = vault.requests(reqLate);
        _step(string.concat("  early settled = ", vm.toString(settledEarly)));
        _step(string.concat("  late settled = ", vm.toString(settledLate)));

        // Same shares amount (1000e6), different rate => different estimatedAssets
        // This is the core of the test: rate change causes settlement difference
        assertTrue(estLate > estEarly, "late estimatedAssets should be higher due to rate change");
        assertTrue(settledLate > settledEarly, "late settled should be higher, reflecting rate difference");
        _step("  PASS: different batches received different settlements reflecting rate change");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 6. test_LongPending_BalanceAndFreeCashStable
    // -----------------------------------------------------------------------

    function test_LongPending_BalanceAndFreeCashStable() public {
        _logCase(
            "test_LongPending_BalanceAndFreeCashStable",
            unicode"请求长期停留在 PENDING 时，对用户余额和自由现金影响稳定"
        );

        _step("[Step 1] Record pre-request state");
        uint256 sharesA = vault.balanceOf(userA);
        uint256 lockedBefore = vault.totalLockedShares();
        uint256 freeCashBefore = vault.getFreeCash();
        uint256 totalAssetsBefore = vault.totalAssets();
        _step(string.concat("  userA shares = ", vm.toString(sharesA)));
        _step(string.concat("  totalLockedShares = ", vm.toString(lockedBefore)));
        _step(string.concat("  freeCash = ", vm.toString(freeCashBefore)));

        _step("[Step 2] userA creates request");
        uint256 reqId = _requestRedeem(userA, 5000e6);
        uint256 sharesAfterReq = vault.balanceOf(userA);
        uint256 lockedAfterReq = vault.totalLockedShares();
        uint256 freeCashAfterReq = vault.getFreeCash();
        uint256 pendingAfterReq = vault.pendingRedeemRequest(userA);
        _step(string.concat("  userA shares after = ", vm.toString(sharesAfterReq)));
        _step(string.concat("  totalLockedShares after = ", vm.toString(lockedAfterReq)));
        _step(string.concat("  freeCash after = ", vm.toString(freeCashAfterReq)));
        _step(string.concat("  pendingShares = ", vm.toString(pendingAfterReq)));

        assertEq(sharesAfterReq, sharesA - 5000e6, "shares should be burned");
        assertGt(lockedAfterReq, lockedBefore, "locked should increase");

        _step("[Step 3] Simulate long time passing without advancing state");
        vm.warp(block.timestamp + 30 days);

        _step("[Step 4] Verify state is unchanged after long delay");
        uint256 sharesLater = vault.balanceOf(userA);
        uint256 lockedLater = vault.totalLockedShares();
        uint256 freeCashLater = vault.getFreeCash();
        uint256 pendingLater = vault.pendingRedeemRequest(userA);
        (,,,,,,,IMantleYieldVault.RequestStatus status) = vault.requests(reqId);

        assertEq(sharesLater, sharesAfterReq, "shares should not drift over time");
        assertEq(lockedLater, lockedAfterReq, "locked should not drift over time");
        assertEq(freeCashLater, freeCashAfterReq, "freeCash should not drift over time");
        assertEq(pendingLater, pendingAfterReq, "pending should not drift over time");
        assertEq(uint8(status), uint8(IMantleYieldVault.RequestStatus.PENDING), "status should remain PENDING");
        _step("  PASS: no state drift after long PENDING period");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 7. test_LongProcessing_SqueezesSyncRedeem
    // -----------------------------------------------------------------------

    function test_LongProcessing_SqueezesSyncRedeem() public {
        _logCase(
            "test_LongProcessing_SqueezesSyncRedeem",
            unicode"请求长期停留在 PROCESSING 时，对后续同步赎回用户构成持续挤压"
        );

        _step("[Step 1] Record userB maxRedeem before any locked liabilities");
        uint256 userBShares = vault.balanceOf(userB);
        uint256 maxRedeemBBefore = vault.maxRedeem(userB);
        uint256 freeCashBefore = vault.getFreeCash();
        _step(string.concat("  userB shares = ", vm.toString(userBShares)));
        _step(string.concat("  maxRedeem before = ", vm.toString(maxRedeemBBefore)));
        _step(string.concat("  freeCash before = ", vm.toString(freeCashBefore)));

        _step("[Step 2] userA and userC redeem ALL their shares to maximize locked liabilities");
        uint256 largeSharesA = vault.balanceOf(userA);
        uint256 largeSharesC = vault.balanceOf(userC);
        _step(string.concat("  userA shares = ", vm.toString(largeSharesA)));
        _step(string.concat("  userC shares = ", vm.toString(largeSharesC)));
        uint256 reqIdA = _requestRedeem(userA, largeSharesA);
        uint256 reqIdC = _requestRedeem(userC, largeSharesC);
        uint256[] memory ids = new uint256[](2);
        ids[0] = reqIdA;
        ids[1] = reqIdC;
        _updateBatch(ids, IMantleYieldVault.RequestStatus.PROCESSING);

        _step("[Step 3] Check userB's sync redeem capacity after locked liabilities created");
        uint256 maxRedeemBAfter = vault.maxRedeem(userB);
        uint256 freeCashAfter = vault.getFreeCash();
        uint256 totalLocked = vault.totalLockedShares();
        _step(string.concat("  maxRedeem after = ", vm.toString(maxRedeemBAfter)));
        _step(string.concat("  freeCash after = ", vm.toString(freeCashAfter)));
        _step(string.concat("  totalLockedShares = ", vm.toString(totalLocked)));

        // freeCash should decrease due to locked liabilities
        assertTrue(freeCashAfter < freeCashBefore, "freeCash should decrease when locked liabilities exist");
        // userB's maxRedeem capacity should decrease (or at least not increase) compared to before
        // because freeCash went down, constraining the available liquidity for sync redemptions
        assertTrue(maxRedeemBAfter <= maxRedeemBBefore, "maxRedeem should not increase when locked liabilities exist");
        _step("  PASS: large PROCESSING request squeezes other users' sync redeem capacity via reduced freeCash");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 8. test_BatchProcessing_PendingAndLockedDecrement
    // -----------------------------------------------------------------------

    function test_BatchProcessing_PendingAndLockedDecrement() public {
        _logCase(
            "test_BatchProcessing_PendingAndLockedDecrement",
            unicode"运营方分批处理请求时，不同批次的 `_pendingShares` 和 `totalLockedShares` 递减正确"
        );

        _step("[Step 1] userA creates two requests");
        uint256 req1 = _requestRedeem(userA, 3000e6);
        uint256 req2 = _requestRedeem(userA, 4000e6);

        uint256 pendingAll = vault.pendingRedeemRequest(userA);
        uint256 lockedAll = vault.totalLockedShares();
        _step(string.concat("  pendingShares = ", vm.toString(pendingAll)));
        _step(string.concat("  totalLockedShares = ", vm.toString(lockedAll)));

        (,,uint256 netShares1,,,,,) = vault.requests(req1);
        (,,uint256 netShares2,,,,,) = vault.requests(req2);
        _step(string.concat("  req1 netShares = ", vm.toString(netShares1)));
        _step(string.concat("  req2 netShares = ", vm.toString(netShares2)));

        _step("[Step 2] Advance both to PROCESSING and settle first request only");
        uint256[] memory allIds = new uint256[](2);
        allIds[0] = req1;
        allIds[1] = req2;
        _updateBatch(allIds, IMantleYieldVault.RequestStatus.PROCESSING);

        (,,,,uint256 est1,,,) = vault.requests(req1);
        _markDone(_singleId(req1), _singleAmount(est1));

        uint256 pendingAfter1 = vault.pendingRedeemRequest(userA);
        uint256 lockedAfter1 = vault.totalLockedShares();
        _step(string.concat("  pendingShares after settle req1 = ", vm.toString(pendingAfter1)));
        _step(string.concat("  totalLockedShares after settle req1 = ", vm.toString(lockedAfter1)));

        assertEq(pendingAfter1, pendingAll - netShares1, "pending should decrease by req1 netShares");
        assertEq(lockedAfter1, lockedAll - netShares1, "locked should decrease by req1 netShares");

        _step("[Step 3] Settle second request");
        (,,,,uint256 est2,,,) = vault.requests(req2);
        _markDone(_singleId(req2), _singleAmount(est2));

        uint256 pendingFinal = vault.pendingRedeemRequest(userA);
        uint256 lockedFinal = vault.totalLockedShares();
        _step(string.concat("  pendingShares final = ", vm.toString(pendingFinal)));
        _step(string.concat("  totalLockedShares final = ", vm.toString(lockedFinal)));

        assertEq(pendingFinal, 0, "pending should be zero after all settled");
        assertEq(lockedFinal, 0, "locked should be zero after all settled");
        _step("  PASS: _pendingShares and totalLockedShares decrement correctly per batch");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 9. test_SameOwner_MultiBatch_TotalSettledCorrect
    // -----------------------------------------------------------------------

    function test_SameOwner_MultiBatch_TotalSettledCorrect() public {
        _logCase(
            "test_SameOwner_MultiBatch_TotalSettledCorrect",
            unicode"同一 owner 多笔请求跨多个批次结算，验证到账合计与每笔 `settledAssets` 之和一致"
        );

        _step("[Step 1] userA creates 3 requests across different times");
        uint256 req1 = _requestRedeem(userA, 2000e6);
        uint256 req2 = _requestRedeem(userA, 3000e6);
        uint256 req3 = _requestRedeem(userA, 4000e6);

        _step("[Step 2] Advance all to PROCESSING");
        uint256[] memory allIds = new uint256[](3);
        allIds[0] = req1;
        allIds[1] = req2;
        allIds[2] = req3;
        _updateBatch(allIds, IMantleYieldVault.RequestStatus.PROCESSING);

        (,,,,uint256 est1,,,) = vault.requests(req1);
        (,,,,uint256 est2,,,) = vault.requests(req2);
        (,,,,uint256 est3,,,) = vault.requests(req3);

        uint256 userABalBefore = usdc.balanceOf(userA);
        _step(string.concat("  userA USDC before = ", vm.toString(userABalBefore)));

        _step("[Step 3] Settle in batch 1: req1 (vault has USDC from deposits)");
        _markDone(_singleId(req1), _singleAmount(est1));

        _step("[Step 4] Settle in batch 2: req2 and req3");
        uint256[] memory batch2Ids = new uint256[](2);
        batch2Ids[0] = req2;
        batch2Ids[1] = req3;
        uint256[] memory batch2Settled = new uint256[](2);
        batch2Settled[0] = est2;
        batch2Settled[1] = est3;
        _markDone(batch2Ids, batch2Settled);

        _step("[Step 5] Verify total USDC received = sum of all settledAssets");
        uint256 userABalAfter = usdc.balanceOf(userA);
        uint256 totalReceived = userABalAfter - userABalBefore;
        uint256 sumSettled = est1 + est2 + est3;
        _step(string.concat("  total received = ", vm.toString(totalReceived)));
        _step(string.concat("  sum of settledAssets = ", vm.toString(sumSettled)));

        assertEq(totalReceived, sumSettled, "total received should equal sum of all settledAssets");

        // Also verify individual settled values recorded correctly
        (,,,,,uint256 s1,,) = vault.requests(req1);
        (,,,,,uint256 s2,,) = vault.requests(req2);
        (,,,,,uint256 s3,,) = vault.requests(req3);
        assertEq(s1 + s2 + s3, totalReceived, "recorded settled sum should match received");
        _step("  PASS: multi-batch settlement total is correct, no duplicate or missing payment");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 10. test_SmallRequestProcessedFirst_LargeStays
    // -----------------------------------------------------------------------

    function test_SmallRequestProcessedFirst_LargeStays() public {
        _logCase(
            "test_SmallRequestProcessedFirst_LargeStays",
            unicode"后来的小额请求被优先处理而早期大额请求滞留，验证系统状态稳定"
        );

        _step("[Step 1] userA creates early LARGE request");
        uint256 reqLarge = _requestRedeem(userA, 30_000e6);
        (,,uint256 largeShares,,uint256 estLarge,,,) = vault.requests(reqLarge);
        _step(string.concat("  large requestId = ", vm.toString(reqLarge)));
        _step(string.concat("  large estimatedAssets = ", vm.toString(estLarge)));

        _step("[Step 2] userB creates later SMALL request");
        uint256 reqSmall = _requestRedeem(userB, 1000e6);
        (,,uint256 smallShares,,uint256 estSmall,,,) = vault.requests(reqSmall);
        _step(string.concat("  small requestId = ", vm.toString(reqSmall)));
        _step(string.concat("  small estimatedAssets = ", vm.toString(estSmall)));

        uint256 lockedBefore = vault.totalLockedShares();
        uint256 pendingABefore = vault.pendingRedeemRequest(userA);
        uint256 pendingBBefore = vault.pendingRedeemRequest(userB);
        _step(string.concat("  totalLockedShares = ", vm.toString(lockedBefore)));
        _step(string.concat("  pendingA = ", vm.toString(pendingABefore)));
        _step(string.concat("  pendingB = ", vm.toString(pendingBBefore)));

        _step("[Step 3] Process only the small request (skip large)");
        _updateBatch(_singleId(reqSmall), IMantleYieldVault.RequestStatus.PROCESSING);
        _markDone(_singleId(reqSmall), _singleAmount(estSmall));

        _step("[Step 4] Verify small request completed, large still PENDING");
        (,,,,,,,IMantleYieldVault.RequestStatus statusLarge) = vault.requests(reqLarge);
        (,,,,,,,IMantleYieldVault.RequestStatus statusSmall) = vault.requests(reqSmall);
        assertEq(uint8(statusSmall), uint8(IMantleYieldVault.RequestStatus.DONE), "small should be DONE");
        assertEq(uint8(statusLarge), uint8(IMantleYieldVault.RequestStatus.PENDING), "large should still be PENDING");

        _step("[Step 5] Verify accounting is still consistent");
        uint256 lockedAfter = vault.totalLockedShares();
        assertEq(lockedAfter, lockedBefore - smallShares, "locked should decrease by small request shares only");
        uint256 pendingAAfter = vault.pendingRedeemRequest(userA);
        assertEq(pendingAAfter, pendingABefore, "userA pending should be unchanged");
        uint256 pendingBAfter = vault.pendingRedeemRequest(userB);
        assertEq(pendingBAfter, 0, "userB pending should be zero");

        // Verify totalAssets and freeCash formula consistency
        // freeCash = physicalBalance - _convertToAssets(totalLockedShares, Ceil)
        // _convertToAssets = shares * rate / 1e18 (no fee deduction, unlike previewRedeem)
        uint256 physicalBalance = usdc.balanceOf(address(vault));
        uint256 totalLocked = vault.totalLockedShares();
        uint256 rate = vault.exchangeRate();
        // _convertToAssets with Ceil: (totalLocked * rate + 1e18 - 1) / 1e18
        uint256 floatingLocked = (totalLocked * rate + 1e18 - 1) / 1e18;
        uint256 expectedFreeCash = physicalBalance > floatingLocked ? physicalBalance - floatingLocked : 0;
        assertEq(vault.getFreeCash(), expectedFreeCash, "freeCash should match formula");
        // totalAssets = physicalBalance - floatingLocked (no adapter/inFlight in this test)
        uint256 expectedTotalAssets = physicalBalance > floatingLocked ? physicalBalance - floatingLocked : 0;
        assertEq(vault.totalAssets(), expectedTotalAssets, "totalAssets should match formula");
        _step(string.concat("  physicalBalance = ", vm.toString(physicalBalance)));
        _step(string.concat("  totalLockedShares = ", vm.toString(totalLocked)));
        _step(string.concat("  floatingLocked = ", vm.toString(floatingLocked)));
        _step(string.concat("  totalAssets = ", vm.toString(vault.totalAssets())));
        _step(string.concat("  freeCash = ", vm.toString(vault.getFreeCash())));
        _step("  PASS: small request completed first, large stays, accounting formula verified");
        _logPass();
    }
}
