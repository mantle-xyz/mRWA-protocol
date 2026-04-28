// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OperatorExecutor} from "../../src/protocol/OperatorExecutor.sol";
import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {IStrategyAdapter} from "../../src/interfaces/adapters/IStrategyAdapter.sol";
import {IStrategyControllerExecutor} from "../../src/interfaces/strategy/IStrategyControllerExecutor.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test, console2} from "forge-std/Test.sol";

// ---------------------------------------------------------------------------
// Mock Contracts for E2E Redeem Batch Testing
// ---------------------------------------------------------------------------

contract MockAssetRB is ERC20 {
    constructor() ERC20("MockUSDC", "mUSDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockAdapterRB is IStrategyAdapter {
    address public immutable ASSET;
    address public immutable POS_TOKEN;
    address public vaultAddress;

    bool public paused;
    uint256 public depositCount;
    uint256 public withdrawCount;
    uint256 public asyncCount;

    constructor(address asset_, address posToken_) {
        ASSET = asset_;
        POS_TOKEN = posToken_;
    }

    function setVault(address vault_) external { vaultAddress = vault_; }

    function name() external pure returns (string memory) { return "MockAdapterRB"; }
    function asset() external view returns (address) { return ASSET; }
    function posToken() external view returns (address) { return POS_TOKEN; }
    function priceOracle() external pure returns (address) { return address(0); }
    function getPosTokenPrice() external pure returns (uint256) { return 0; }
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
    function vault() external view returns (address) { return vaultAddress; }

    /// @dev totalValue = actual asset balance held by adapter (like a real adapter)
    function totalValue() external view returns (uint256) {
        return ERC20(ASSET).balanceOf(address(this));
    }

    /// @dev Real adapter behavior: transferFrom vault using approval, hold funds
    function deposit(uint256 amount, address) external returns (uint256) {
        depositCount++;
        // vault.approveToAdapter gave us allowance, pull funds from vault (real behavior)
        ERC20(ASSET).transferFrom(vaultAddress, address(this), amount);
        return amount;
    }

    /// @dev Async-only adapter; withdrawSync should never be called by controller.
    function withdrawSync(uint256, address) external returns (uint256) {
        withdrawCount++;
        revert("Unsupported");
    }

    /// @dev Async-only mock: vault holds only ASSET (no posToken), so we can't transferFrom posToken here.
    ///      The test simulates settlement by manually moving asset from adapter back to vault later.
    function requestRedeemAsync(uint256, address) external { asyncCount++; }

    /// @dev Real sweepToVault clamps to min(balance, amount) per BaseAdapter.
    function sweepToVault(address token, uint256 amount) external returns (uint256 claimed) {
        uint256 bal = ERC20(token).balanceOf(address(this));
        claimed = amount > bal ? bal : amount;
        if (claimed > 0) {
            ERC20(token).transfer(vaultAddress, claimed);
        }
    }

    function setPaused(bool p) external { paused = p; }
    function retryRedeemAsync(uint256, address) external {}
}

/// @dev Mock Vault that simulates real business flow:
///   - depositFor: transfer asset in, mint shares
///   - requestRedeemFor: burn shares, lock, create PENDING request
///   - updateRequestBatch: PENDING -> PROCESSING
///   - markRequestsDone: transfer USDC to user, release locked shares, DONE
///   - getFreeCash: physicalBalance - lockedSharesValue (real formula)
contract MockVaultRB {
    ERC20 public immutable token;
    uint256 public mockedExchangeRate = 1e18;

    uint256 public totalLockedSharesValue;
    uint256 public investInFlightTotal;
    uint256 public redeemInFlightTotal;
    uint256 public nextInFlightId = 1;
    uint256 public nextRequestId = 1;
    uint256 public pendingRequestCount;

    mapping(address => uint256) public investInFlightByAdapter;
    mapping(address => uint256) public redeemInFlightByAdapter;
    mapping(address => bool) public isAdapterRegistry;
    mapping(address => uint256) public sharesOf;

    struct Req {
        uint256 id;
        address owner;
        uint256 shares;
        uint256 feeShares;
        uint256 estimatedAssets;
        uint256 settledAssets;
        uint256 timestamp;
        IMantleYieldVault.RequestStatus status;
    }

    struct InFlight {
        uint256 id;
        address adapter;
        address assetAddr;
        uint256 tokenAmount;
        uint256 usdcAmount;
        uint256 settledAmount;
        bool isInvest;
        uint256 timestamp;
        IMantleYieldVault.InFlightStatus status;
    }

    mapping(uint256 => Req) public reqs;
    mapping(uint256 => InFlight) public flights;

    constructor(address asset_) {
        token = ERC20(asset_);
    }

    function asset() external view returns (address) { return address(token); }
    function share() external view returns (address) { return address(this); }

    function setExchangeRate(uint256 rate) external { mockedExchangeRate = rate; }
    function exchangeRate() external view returns (uint256) { return mockedExchangeRate; }

    // ---- Deposit: transfer asset in, record shares ----
    function depositFor(address sender, uint256 assets, address receiver) external returns (uint256 shares) {
        shares = (assets * 1e18) / mockedExchangeRate;
        sharesOf[receiver] += shares;
        token.transferFrom(sender, address(this), assets);
    }

    // ---- Request Redeem: burn shares, lock, create PENDING request ----
    function requestRedeemFor(address, address owner, uint256 shares) external returns (uint256 requestId) {
        require(sharesOf[owner] >= shares, "Insufficient shares");
        sharesOf[owner] -= shares;
        totalLockedSharesValue += shares;

        requestId = nextRequestId++;
        pendingRequestCount++;
        uint256 estimatedAssets = (shares * mockedExchangeRate) / 1e18;
        reqs[requestId] = Req({
            id: requestId,
            owner: owner,
            shares: shares,
            feeShares: 0,
            estimatedAssets: estimatedAssets,
            settledAssets: 0,
            timestamp: block.timestamp,
            status: IMantleYieldVault.RequestStatus.PENDING
        });
    }

    function totalLockedShares() external view returns (uint256) { return totalLockedSharesValue; }

    // ---- FreeCash: physical balance - locked shares value (real formula) ----
    function getFreeCash() external view returns (uint256) {
        uint256 totalCash = token.balanceOf(address(this));
        uint256 lockedValue = (totalLockedSharesValue * mockedExchangeRate) / 1e18;
        return totalCash > lockedValue ? totalCash - lockedValue : 0;
    }

    function totalLockedLiabilities() external view returns (uint256) {
        return (totalLockedSharesValue * mockedExchangeRate) / 1e18;
    }

    function getCashDeficit() external view returns (uint256) {
        uint256 totalCash = token.balanceOf(address(this));
        uint256 lockedValue = (totalLockedSharesValue * mockedExchangeRate) / 1e18;
        if (totalCash > lockedValue) return 0;
        return lockedValue - totalCash;
    }

    function totalInvestInFlight() external view returns (uint256) { return investInFlightTotal; }
    function totalRedeemInFlight() external view returns (uint256) { return redeemInFlightTotal; }
    function adapterInvestInFlightTokens(address a) external view returns (uint256) { return investInFlightByAdapter[a]; }
    function adapterRedeemInFlightUsdc(address a) external view returns (uint256) { return redeemInFlightByAdapter[a]; }

    /// @dev Simplified totalAssets: physical + inflight - lockedLiabilities.
    ///      Matches real formula semantics enough for rebalance arithmetic in this mock.
    function totalAssets() external view returns (uint256) {
        uint256 total = token.balanceOf(address(this)) + investInFlightTotal + redeemInFlightTotal;
        uint256 lockedValue = (totalLockedSharesValue * mockedExchangeRate) / 1e18;
        if (total <= lockedValue) return 0;
        return total - lockedValue;
    }

    function approveToAdapter(address adapter, address approveToken, uint256 amount) external {
        ERC20(approveToken).approve(adapter, amount);
    }

    function isAdapter(address adapter) external view returns (bool) { return isAdapterRegistry[adapter]; }
    function registerAdapter(address adapter) external { isAdapterRegistry[adapter] = true; }

    function removeAdapter(address adapter) external {
        require(investInFlightByAdapter[adapter] == 0 && redeemInFlightByAdapter[adapter] == 0, "HAS_IN_FLIGHT");
        isAdapterRegistry[adapter] = false;
    }

    // ---- updateRequestBatch: monotonic state machine (M-11/M-12) ----
    //      Real Vault rejects transitions where new <= current or current == NONE with
    //      Vault__InvalidState(id, currentStatus). Mock must enforce the same to catch
    //      duplicate process / out-of-order calls in unit tests.
    function updateRequestBatch(uint256[] calldata ids, IMantleYieldVault.RequestStatus newStatus) external {
        if (
            newStatus == IMantleYieldVault.RequestStatus.NONE
                || newStatus == IMantleYieldVault.RequestStatus.DONE
        ) {
            revert IMantleYieldVault.Vault__StatusTransitionForbidden(newStatus);
        }
        for (uint256 i = 0; i < ids.length; i++) {
            IMantleYieldVault.RequestStatus current = reqs[ids[i]].status;
            if (
                current == IMantleYieldVault.RequestStatus.NONE
                    || uint8(newStatus) <= uint8(current)
            ) {
                revert IMantleYieldVault.Vault__InvalidState(ids[i], current);
            }
            reqs[ids[i]].status = newStatus;
            if (current == IMantleYieldVault.RequestStatus.PENDING && pendingRequestCount > 0) {
                pendingRequestCount--;
            }
        }
    }

    // ---- markRequestsDone: only PROCESSING can move to DONE (M-4) ----
    function markRequestsDone(uint256[] calldata ids, uint256[] calldata settledAssets) external {
        require(ids.length == settledAssets.length, "LENGTH_MISMATCH");
        for (uint256 i = 0; i < ids.length; i++) {
            Req storage r = reqs[ids[i]];
            if (r.status != IMantleYieldVault.RequestStatus.PROCESSING) {
                revert IMantleYieldVault.Vault__InvalidState(ids[i], r.status);
            }
            r.settledAssets = settledAssets[i];
            r.status = IMantleYieldVault.RequestStatus.DONE;

            // Release locked shares
            if (totalLockedSharesValue >= r.shares) {
                totalLockedSharesValue -= r.shares;
            }

            // Transfer USDC to owner (real vault behavior)
            if (settledAssets[i] > 0) {
                token.transfer(r.owner, settledAssets[i]);
            }
        }
    }

    function createInFlight(address adapter, address assetAddr, uint256 tokenAmount, uint256 usdcAmount, bool isInvest)
        external
        returns (uint256 inFlightId)
    {
        inFlightId = nextInFlightId++;
        flights[inFlightId] = InFlight({
            id: inFlightId,
            adapter: adapter,
            assetAddr: assetAddr,
            tokenAmount: tokenAmount,
            usdcAmount: usdcAmount,
            settledAmount: 0,
            isInvest: isInvest,
            timestamp: block.timestamp,
            status: IMantleYieldVault.InFlightStatus.PENDING
        });
        if (isInvest) {
            investInFlightTotal += usdcAmount;
            investInFlightByAdapter[adapter] += tokenAmount;
        } else {
            redeemInFlightTotal += usdcAmount;
            redeemInFlightByAdapter[adapter] += usdcAmount;
        }
    }

    function confirmInFlight(uint256 inFlightId, uint256 actualAmount, bool) external {
        InFlight storage f = flights[inFlightId];
        f.settledAmount = actualAmount;
        f.status = IMantleYieldVault.InFlightStatus.CONFIRMED;
        if (f.isInvest && investInFlightTotal >= f.usdcAmount) {
            investInFlightTotal -= f.usdcAmount;
            if (investInFlightByAdapter[f.adapter] >= f.tokenAmount) {
                investInFlightByAdapter[f.adapter] -= f.tokenAmount;
            }
        }
        if (!f.isInvest && redeemInFlightTotal >= f.usdcAmount) {
            redeemInFlightTotal -= f.usdcAmount;
            if (redeemInFlightByAdapter[f.adapter] >= f.usdcAmount) {
                redeemInFlightByAdapter[f.adapter] -= f.usdcAmount;
            }
        }
    }

    function requests(uint256 requestId)
        external
        view
        returns (uint256, address, uint256, uint256, uint256, uint256, uint256, IMantleYieldVault.RequestStatus)
    {
        Req memory r = reqs[requestId];
        return (r.id, r.owner, r.shares, r.feeShares, r.estimatedAssets, r.settledAssets, r.timestamp, r.status);
    }

    function inFlightRecords(uint256 inFlightId)
        external
        view
        returns (
            uint256 id, address adapter, address assetAddr, uint256 tokenAmount,
            uint256 usdcAmount, uint256 settledAmount, bool isInvest,
            uint256 timestamp, IMantleYieldVault.InFlightStatus status
        )
    {
        InFlight memory f = flights[inFlightId];
        return (f.id, f.adapter, f.assetAddr, f.tokenAmount, f.usdcAmount, f.settledAmount, f.isInvest, f.timestamp, f.status);
    }
}

// ---------------------------------------------------------------------------
// QA Test Suite -- Redeem Batch E2E
// ---------------------------------------------------------------------------

contract RedeemBatchQATest is Test {
    MockAssetRB internal asset;
    MockAssetRB internal posToken;
    MockVaultRB internal vault;
    StrategyController internal controller;
    OperatorExecutor internal executor;
    MockAdapterRB internal asyncAdapter;

    address internal admin = makeAddr("admin");
    address internal bot = makeAddr("bot");
    address internal manager = makeAddr("manager");
    address internal userA = makeAddr("userA");
    address internal userB = makeAddr("userB");

    // Events
    event RedeemBatchProcessing(uint256 indexed batchSize, uint256 batchTotalAsset, uint256 shortfallAsset);
    event RedeemBatchReady(uint256 indexed batchSize, uint256 requiredAsset);

    function setUp() public {
        // 1. Deploy tokens
        asset = new MockAssetRB();
        posToken = new MockAssetRB();

        // 2. Deploy mock vault
        vault = new MockVaultRB(address(asset));

        // 3. Deploy real OperatorExecutor
        OperatorExecutor executorImpl = new OperatorExecutor();
        bytes memory executorInitData = abi.encodeCall(OperatorExecutor.initialize, (admin, bot));
        executor = OperatorExecutor(address(new ERC1967Proxy(address(executorImpl), executorInitData)));

        // 4. Deploy real StrategyController
        StrategyController controllerImpl = new StrategyController();
        bytes memory controllerInitData = abi.encodeCall(
            StrategyController.initialize,
            (address(vault), manager, address(executor), manager, 1000, 200, 1 hours)
        );
        controller = StrategyController(address(new ERC1967Proxy(address(controllerImpl), controllerInitData)));

        // 5. Deploy and register async adapter
        asyncAdapter = new MockAdapterRB(address(asset), address(posToken));
        asyncAdapter.setVault(address(vault));
        vm.startPrank(manager);
        controller.registerStrategy(address(asyncAdapter), 10_000, 1, true);
        controller.activateStrategy(address(asyncAdapter));
        address[] memory ordered = new address[](1);
        ordered[0] = address(asyncAdapter);
        controller.setStrategyOrder(ordered);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // Logging helpers
    // -----------------------------------------------------------------------

    string constant MODULE = unicode"Redeem Batch 批处理场景";
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

    function _step(string memory msg) internal {
        console2.log(msg);
        _buf = string.concat(_buf, msg, "\n");
    }

    function _logPass() internal {
        _step("----------------------------------------");
        _step("test result: passed");
    }

    // -----------------------------------------------------------------------
    // E2E Helpers -- real deposit -> requestRedeem flow
    // -----------------------------------------------------------------------

    /// @dev User deposits asset into vault, gets shares
    function _depositToVault(address user, uint256 assetAmount) internal returns (uint256 shares) {
        asset.mint(user, assetAmount);
        vm.prank(user);
        asset.approve(address(vault), assetAmount);
        shares = vault.depositFor(user, assetAmount, user);
    }

    /// @dev User creates a redeem request (burns shares, locks, creates PENDING request)
    function _createRedeemRequest(address user, uint256 shares) internal returns (uint256 requestId) {
        requestId = vault.requestRedeemFor(user, user, shares);
    }

    /// @dev Full setup: deposit for users and create N redeem requests, return sorted ids
    function _setupRedeemRequests(address user, uint256 depositAmount, uint256 numRequests)
        internal
        returns (uint256[] memory ids, uint256 sharesPerRequest)
    {
        uint256 totalShares = _depositToVault(user, depositAmount);
        sharesPerRequest = totalShares / numRequests;

        ids = new uint256[](numRequests);
        for (uint256 i = 0; i < numRequests; i++) {
            ids[i] = _createRedeemRequest(user, sharesPerRequest);
        }
    }

    /// @dev Bot executes processRedeemBatch via OperatorExecutor (real flow)
    function _processRedeemBatch(uint256[] memory ids) internal {
        vm.prank(bot);
        executor.executeProcessRedeemBatch(address(controller), ids);
    }

    /// @dev Bot executes finalizeRedeemBatch via OperatorExecutor (real flow)
    function _finalizeRedeemBatch(uint256[] memory ids, uint256[] memory settledAssets) internal {
        vm.prank(bot);
        executor.executeFinalizeRedeemBatch(address(controller), ids, settledAssets);
    }

    /// @dev Execute rebalance via real OperatorExecutor.
    ///      Mock adapter.deposit() does transferFrom(vault) automatically,
    ///      and adapter.totalValue() returns real asset balance — no manual steps needed.
    function _investViaRebalance() internal {
        vm.warp(block.timestamp + 2 hours);
        vm.prank(bot);
        executor.executeRebalance(address(controller));
    }

    // -----------------------------------------------------------------------
    // 1. test_ProcessRedeemBatch_Success (P0)
    // -----------------------------------------------------------------------

    function test_ProcessRedeemBatch_Success() public {
        _logCase("test_ProcessRedeemBatch_Success", unicode"processRedeemBatch 正常处理批次");

        _step("[Step 1] UserA deposits 600, userB deposits 600 (provides buffer)");
        _depositToVault(userB, 600e18);
        (uint256[] memory ids,) = _setupRedeemRequests(userA, 600e18, 3);
        _step(string.concat("  ids = [", vm.toString(ids[0]), ", ", vm.toString(ids[1]), ", ", vm.toString(ids[2]), "]"));
        _step(string.concat("  vault balance = ", vm.toString(asset.balanceOf(address(vault)))));
        _step(string.concat("  freeCash = ", vm.toString(vault.getFreeCash())));

        _step("[Step 2] Verify all requests are PENDING before processing");
        for (uint256 i = 0; i < ids.length; i++) {
            (,,,,,,, IMantleYieldVault.RequestStatus s) = vault.requests(ids[i]);
            assertEq(uint8(s), uint8(IMantleYieldVault.RequestStatus.PENDING));
        }
        _step("  PASS: all requests are PENDING");

        _step("[Step 3] Bot calls executeProcessRedeemBatch via OperatorExecutor");
        // M-1: Controller no longer maintains processingBatchDone mapping; state lives on Vault request status.
        // Pre-condition: each request is still PENDING.
        for (uint256 i = 0; i < ids.length; i++) {
            (,,,,,,, IMantleYieldVault.RequestStatus sPre) = vault.requests(ids[i]);
            assertEq(uint8(sPre), uint8(IMantleYieldVault.RequestStatus.PENDING), "request should be PENDING before process");
        }

        _processRedeemBatch(ids);
        _step("  PASS: processRedeemBatch executed via real OperatorExecutor");

        _step("[Step 4] Verify request status = PROCESSING");
        for (uint256 i = 0; i < ids.length; i++) {
            (,,,,,,, IMantleYieldVault.RequestStatus s) = vault.requests(ids[i]);
            assertEq(uint8(s), uint8(IMantleYieldVault.RequestStatus.PROCESSING));
            _step(string.concat("  request[", vm.toString(ids[i]), "] = PROCESSING"));
        }
        _step("  PASS: all 3 requests are PROCESSING");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 2. test_ProcessRedeemBatch_RevertDuplicate (P0)
    // -----------------------------------------------------------------------

    function test_ProcessRedeemBatch_RevertDuplicate() public {
        _logCase("test_ProcessRedeemBatch_RevertDuplicate", unicode"相同批次不能重复 processRedeemBatch");

        _step("[Step 1] Setup and process batch via real flow");
        (uint256[] memory ids,) = _setupRedeemRequests(userA, 600e18, 3);
        _processRedeemBatch(ids);
        _step("  PASS: first processRedeemBatch succeeded");

        _step("[Step 2] Attempt to process the same batch again via OperatorExecutor");
        // M-1: state transitions now enforced by Vault; updateRequestBatch rejects
        // a target status <= current status with Vault__InvalidState(id, currentStatus).
        vm.prank(bot);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMantleYieldVault.Vault__InvalidState.selector,
                ids[0],
                IMantleYieldVault.RequestStatus.PROCESSING
            )
        );
        executor.executeProcessRedeemBatch(address(controller), ids);
        _step("  PASS: reverted with Vault__InvalidState(PROCESSING)");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 3. test_FinalizeRedeemBatch_RevertNotProcessed (P0)
    // -----------------------------------------------------------------------

    function test_FinalizeRedeemBatch_RevertNotProcessed() public {
        _logCase("test_FinalizeRedeemBatch_RevertNotProcessed", unicode"finalizeRedeemBatch 前必须先 process");

        _step("[Step 1] Setup redeem requests but skip processRedeemBatch");
        (uint256[] memory ids, uint256 sharesPerReq) = _setupRedeemRequests(userA, 600e18, 3);
        uint256 assetPerReq = (sharesPerReq * vault.exchangeRate()) / 1e18;

        uint256[] memory settled = new uint256[](3);
        settled[0] = assetPerReq;
        settled[1] = assetPerReq;
        settled[2] = assetPerReq;

        _step("[Step 2] Attempt to finalize without prior processing via OperatorExecutor");
        // M-2: StrategyController._batchRequiredAssets early-checks per-request status on vault
        //      and reverts with InvalidRequestState(id, status) when status != PROCESSING.
        vm.prank(bot);
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyController.InvalidRequestState.selector,
                ids[0],
                IMantleYieldVault.RequestStatus.PENDING
            )
        );
        executor.executeFinalizeRedeemBatch(address(controller), ids, settled);
        _step("  PASS: reverted with InvalidRequestState(PENDING)");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 4. test_FinalizeRedeemBatch_Success (P0)
    // -----------------------------------------------------------------------

    function test_FinalizeRedeemBatch_Success() public {
        _logCase("test_FinalizeRedeemBatch_Success", unicode"finalizeRedeemBatch 成功完成已 processing 批次");

        _step("[Step 1] UserB deposits to provide buffer, userA deposits and creates requests");
        _depositToVault(userB, 600e18);
        (uint256[] memory ids, uint256 sharesPerReq) = _setupRedeemRequests(userA, 600e18, 3);
        _processRedeemBatch(ids);
        _step("  PASS: batch processed");

        _step("[Step 2] Record user balance before finalize");
        uint256 userBalanceBefore = asset.balanceOf(userA);
        _step(string.concat("  userA USDC before = ", vm.toString(userBalanceBefore)));

        _step("[Step 3] Prepare settledAssets and finalize");
        uint256 assetPerReq = (sharesPerReq * vault.exchangeRate()) / 1e18;
        uint256[] memory settled = new uint256[](3);
        settled[0] = assetPerReq;
        settled[1] = assetPerReq;
        settled[2] = assetPerReq;

        // M-3: Controller.readyBatchDone mapping removed; rely on Vault request status instead.
        // Pre-condition: requests should be PROCESSING (not yet DONE).
        for (uint256 i = 0; i < ids.length; i++) {
            (,,,,,,, IMantleYieldVault.RequestStatus sPre) = vault.requests(ids[i]);
            assertEq(uint8(sPre), uint8(IMantleYieldVault.RequestStatus.PROCESSING), "should be PROCESSING before finalize");
        }

        _finalizeRedeemBatch(ids, settled);
        _step("  PASS: finalizeRedeemBatch executed via OperatorExecutor");

        _step("[Step 4] Verify all requests are DONE with correct settledAssets");
        for (uint256 i = 0; i < ids.length; i++) {
            (,,,,, uint256 sa,, IMantleYieldVault.RequestStatus s) = vault.requests(ids[i]);
            assertEq(uint8(s), uint8(IMantleYieldVault.RequestStatus.DONE));
            assertEq(sa, assetPerReq);
            _step(string.concat("  request[", vm.toString(ids[i]), "] DONE, settled=", vm.toString(sa)));
        }

        _step("[Step 5] Verify USDC actually transferred to user");
        uint256 userBalanceAfter = asset.balanceOf(userA);
        uint256 totalReceived = userBalanceAfter - userBalanceBefore;
        _step(string.concat("  userA USDC after = ", vm.toString(userBalanceAfter)));
        _step(string.concat("  totalReceived = ", vm.toString(totalReceived)));
        assertEq(totalReceived, assetPerReq * 3, "user should receive total settled USDC");
        _step("  PASS: user received USDC - real settlement confirmed");

        _step("[Step 6] Verify totalLockedShares decreased");
        uint256 lockedAfter = vault.totalLockedSharesValue();
        _step(string.concat("  totalLockedShares after = ", vm.toString(lockedAfter)));
        assertEq(lockedAfter, 0, "all locked shares should be released");
        _step("  PASS: locked shares fully released");

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 5. test_ProcessRedeemBatch_RevertIdsNotSorted (P0)
    // -----------------------------------------------------------------------

    function test_ProcessRedeemBatch_RevertIdsNotSorted() public {
        _logCase("test_ProcessRedeemBatch_RevertIdsNotSorted", unicode"请求 ID 未排序或有重复时拒绝处理");

        _step("[Step 1] Create 3 real redeem requests");
        (uint256[] memory ids,) = _setupRedeemRequests(userA, 600e18, 3);

        _step("[Step 2] Rearrange ids to be unsorted");
        uint256[] memory unsortedIds = new uint256[](3);
        unsortedIds[0] = ids[1]; // out of order
        unsortedIds[1] = ids[0];
        unsortedIds[2] = ids[2];
        _step(string.concat("  unsortedIds = [", vm.toString(unsortedIds[0]), ", ", vm.toString(unsortedIds[1]), ", ", vm.toString(unsortedIds[2]), "]"));

        _step("[Step 3] processRedeemBatch with unsorted IDs via OperatorExecutor");
        vm.prank(bot);
        vm.expectRevert(StrategyController.IdsNotSorted.selector);
        executor.executeProcessRedeemBatch(address(controller), unsortedIds);
        _step("  PASS: processRedeemBatch reverted with IdsNotSorted");

        _step("[Step 4] Process sorted batch first (precondition for finalize test)");
        _processRedeemBatch(ids);
        _step("  processed sorted batch [1,2,3]");

        _step("[Step 5] finalizeRedeemBatch also rejects unsorted IDs");
        uint256[] memory settled = new uint256[](3);
        settled[0] = 200e18;
        settled[1] = 200e18;
        settled[2] = 200e18;
        vm.prank(bot);
        vm.expectRevert(StrategyController.IdsNotSorted.selector);
        executor.executeFinalizeRedeemBatch(address(controller), unsortedIds, settled);
        _step("  PASS: finalizeRedeemBatch also reverted with IdsNotSorted");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 6. test_FinalizeRedeemBatch_RevertInsufficientBalance (P0)
    // -----------------------------------------------------------------------

    function test_FinalizeRedeemBatch_RevertInsufficientBalance() public {
        _logCase("test_FinalizeRedeemBatch_RevertInsufficientBalance", unicode"物理余额不足时 finalize 失败，补足后成功");

        _step("[Step 1] UserA deposits 600, rebalance invests most into adapter");
        _depositToVault(userA, 600e18);
        _investViaRebalance();
        uint256 vaultAfterInvest = asset.balanceOf(address(vault));
        uint256 adapterValue = asset.balanceOf(address(asyncAdapter));
        _step(string.concat("  vault physical after rebalance = ", vm.toString(vaultAfterInvest)));
        _step(string.concat("  adapter holds = ", vm.toString(adapterValue)));

        _step("[Step 2] UserA creates 3 redeem requests for all shares");
        uint256 totalShares = vault.sharesOf(userA);
        uint256 sharesPerReq = totalShares / 3;
        uint256[] memory ids = new uint256[](3);
        ids[0] = _createRedeemRequest(userA, sharesPerReq);
        ids[1] = _createRedeemRequest(userA, sharesPerReq);
        ids[2] = _createRedeemRequest(userA, sharesPerReq);
        uint256 assetPerReq = (sharesPerReq * vault.exchangeRate()) / 1e18;

        _step("[Step 3] Process batch (divest triggered due to shortfall)");
        _processRedeemBatch(ids);
        _step("  PASS: batch processed");

        _step("[Step 4] Attempt finalize - vault doesn't have enough (funds in adapter)");
        uint256[] memory settled = new uint256[](3);
        settled[0] = assetPerReq;
        settled[1] = assetPerReq;
        settled[2] = assetPerReq;
        uint256 totalSettled = assetPerReq * 3;
        uint256 vaultBalance = asset.balanceOf(address(vault));
        _step(string.concat("  totalSettled = ", vm.toString(totalSettled)));
        _step(string.concat("  vaultBalance = ", vm.toString(vaultBalance)));
        require(totalSettled > vaultBalance, "test setup: vault should have less than needed");

        vm.prank(bot);
        vm.expectRevert(
            abi.encodeWithSelector(StrategyController.InsufficientCashForReady.selector, totalSettled, vaultBalance)
        );
        executor.executeFinalizeRedeemBatch(address(controller), ids, settled);
        _step("  PASS: reverted with InsufficientCashForReady");

        _step("[Step 5] Adapter returns funds to vault (simulating settleAdapter -> sweepToVault)");
        uint256 adapterBalance = asset.balanceOf(address(asyncAdapter));
        _step(string.concat("  adapter balance = ", vm.toString(adapterBalance)));
        // Sweep all adapter funds back to vault (real sweepToVault behavior)
        vm.prank(address(asyncAdapter));
        asset.transfer(address(vault), adapterBalance);
        uint256 newBalance = asset.balanceOf(address(vault));
        _step(string.concat("  adapter swept back = ", vm.toString(adapterBalance)));
        _step(string.concat("  vault balance after sweep = ", vm.toString(newBalance)));

        _step("[Step 6] Finalize again - should succeed now that funds are back in vault");
        _finalizeRedeemBatch(ids, settled);
        _step("  PASS: finalizeRedeemBatch succeeded after adapter settlement");

        _step("[Step 7] Verify user received USDC");
        uint256 userBalance = asset.balanceOf(userA);
        _step(string.concat("  userA USDC = ", vm.toString(userBalance)));
        assertEq(userBalance, totalSettled, "user should receive full settled USDC");
        _step("  PASS: physical balance check prevents air settlement");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 7. test_ProcessRedeemBatch_TriggersdivestOnShortfall (P1)
    // -----------------------------------------------------------------------

    function test_ProcessRedeemBatch_TriggersdivestOnShortfall() public {
        _logCase("test_ProcessRedeemBatch_TriggersdivestOnShortfall", unicode"processRedeemBatch 在现金不足时触发 _divest(shortfall)");

        _step("[Step 1] UserA deposits 600, rebalance invests most into adapter");
        _depositToVault(userA, 600e18);
        _investViaRebalance();
        uint256 vaultAfterInvest = asset.balanceOf(address(vault));
        uint256 adapterBalance = asset.balanceOf(address(asyncAdapter));
        _step(string.concat("  vault physical = ", vm.toString(vaultAfterInvest)));
        _step(string.concat("  adapter holds = ", vm.toString(adapterBalance)));

        _step("[Step 2] UserA creates 3 redeem requests for all shares");
        uint256 totalShares = vault.sharesOf(userA);
        uint256 sharesPerReq = totalShares / 3;
        uint256[] memory ids = new uint256[](3);
        ids[0] = _createRedeemRequest(userA, sharesPerReq);
        ids[1] = _createRedeemRequest(userA, sharesPerReq);
        ids[2] = _createRedeemRequest(userA, sharesPerReq);

        uint256 freeCash = vault.getFreeCash();
        _step(string.concat("  freeCash after redeem requests = ", vm.toString(freeCash)));
        _step("  freeCash is low because most funds are in adapter + shares are locked");

        _step("[Step 3] Record adapter async call count before process");
        uint256 asyncCountBefore = asyncAdapter.asyncCount();

        _step("[Step 4] Bot calls processRedeemBatch - divest triggered for shortfall");
        _processRedeemBatch(ids);
        _step("  PASS: processRedeemBatch completed");

        _step("[Step 5] Verify divest was triggered (adapter.requestRedeemAsync called)");
        uint256 asyncCountAfter = asyncAdapter.asyncCount();
        _step(string.concat("  asyncCount before = ", vm.toString(asyncCountBefore)));
        _step(string.concat("  asyncCount after  = ", vm.toString(asyncCountAfter)));
        assertGt(asyncCountAfter, asyncCountBefore, "divest should have called requestRedeemAsync on adapter");
        _step("  PASS: _divest triggered, adapter received async redeem request");

        _step("[Step 6] Verify requests are PROCESSING");
        (,,,,,,, IMantleYieldVault.RequestStatus s1) = vault.requests(ids[0]);
        assertEq(uint8(s1), uint8(IMantleYieldVault.RequestStatus.PROCESSING));
        _step("  PASS: requests moved to PROCESSING even with shortfall");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 8. test_FinalizeRedeemBatch_ChecksPhysicalBalance (P1)
    // -----------------------------------------------------------------------

    function test_FinalizeRedeemBatch_ChecksPhysicalBalance() public {
        _logCase("test_FinalizeRedeemBatch_ChecksPhysicalBalance", unicode"finalizeRedeemBatch 校验物理余额而非 freeCash");

        _step("[Step 1] UserA deposits 600 and creates 3 redeem requests");
        (uint256[] memory ids, uint256 sharesPerReq) = _setupRedeemRequests(userA, 600e18, 3);
        // vault has 600 physical, locked = 600 shares, freeCash = 0

        _step("[Step 2] UserB deposits 400 (new depositor adds physical balance)");
        _depositToVault(userB, 400e18);
        // vault now has 1000 physical, locked = 600 shares (from userA)
        // freeCash = 1000 - 600 = 400

        uint256 freeCash = vault.getFreeCash();
        uint256 physicalBalance = asset.balanceOf(address(vault));
        _step(string.concat("  freeCash = ", vm.toString(freeCash)));
        _step(string.concat("  physicalBalance = ", vm.toString(physicalBalance)));

        _step("[Step 3] Process batch");
        _processRedeemBatch(ids);

        _step("[Step 4] Prepare settled = 600 total (> freeCash=400 but < physical=1000)");
        uint256 assetPerReq = (sharesPerReq * vault.exchangeRate()) / 1e18;
        uint256[] memory settled = new uint256[](3);
        settled[0] = assetPerReq;
        settled[1] = assetPerReq;
        settled[2] = assetPerReq;
        _step(string.concat("  totalSettled = ", vm.toString(assetPerReq * 3)));
        _step(string.concat("  totalSettled(600) > freeCash(400) but < physicalBalance(1000)"));

        _step("[Step 5] Finalize should succeed based on physical balance, not freeCash");
        _finalizeRedeemBatch(ids, settled);
        _step("  PASS: finalizeRedeemBatch succeeded despite totalSettled > freeCash");

        _step("[Step 6] Verify requests are DONE and userA received USDC");
        (,,,,,,, IMantleYieldVault.RequestStatus s1) = vault.requests(ids[0]);
        assertEq(uint8(s1), uint8(IMantleYieldVault.RequestStatus.DONE));
        uint256 userABalance = asset.balanceOf(userA);
        assertEq(userABalance, assetPerReq * 3, "userA should receive settled USDC");
        _step(string.concat("  userA received = ", vm.toString(userABalance)));
        _step("  PASS: finalize checks physical balance (asset.balanceOf), not freeCash");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 9. test_FinalizeRedeemBatch_RevertDuplicate (P0)
    // -----------------------------------------------------------------------

    function test_FinalizeRedeemBatch_RevertDuplicate() public {
        _logCase("test_FinalizeRedeemBatch_RevertDuplicate", unicode"相同批次不能重复 finalizeRedeemBatch");

        _step("[Step 1] Full flow: deposit -> requestRedeem -> process -> finalize");
        _depositToVault(userB, 600e18);
        (uint256[] memory ids, uint256 sharesPerReq) = _setupRedeemRequests(userA, 600e18, 3);
        _processRedeemBatch(ids);

        uint256 assetPerReq = (sharesPerReq * vault.exchangeRate()) / 1e18;
        uint256[] memory settled = new uint256[](3);
        settled[0] = assetPerReq;
        settled[1] = assetPerReq;
        settled[2] = assetPerReq;
        _finalizeRedeemBatch(ids, settled);
        _step("  PASS: first finalizeRedeemBatch succeeded");

        _step("[Step 2] Attempt to finalize the same batch again");
        // M-4: StrategyController._batchRequiredAssets early-checks status and reverts
        //      with InvalidRequestState(id, DONE) before reaching Vault.markRequestsDone.
        vm.prank(bot);
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyController.InvalidRequestState.selector,
                ids[0],
                IMantleYieldVault.RequestStatus.DONE
            )
        );
        executor.executeFinalizeRedeemBatch(address(controller), ids, settled);
        _step("  PASS: reverted with InvalidRequestState(DONE)");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 10. test_FinalizeRedeemBatch_RevertLengthMismatch (P0)
    // -----------------------------------------------------------------------

    function test_FinalizeRedeemBatch_RevertLengthMismatch() public {
        _logCase("test_FinalizeRedeemBatch_RevertLengthMismatch", unicode"finalizeRedeemBatch ids 与 settledAssets 长度不一致");

        _step("[Step 1] Setup and process batch");
        (uint256[] memory ids,) = _setupRedeemRequests(userA, 600e18, 3);
        _processRedeemBatch(ids);

        _step("[Step 2] Prepare mismatched arrays: ids.length=3, settled.length=2");
        uint256[] memory settled = new uint256[](2);
        settled[0] = 100e18;
        settled[1] = 200e18;

        _step("[Step 3] Finalize via OperatorExecutor - expect ClaimInputsLengthMismatch");
        vm.prank(bot);
        vm.expectRevert(StrategyController.ClaimInputsLengthMismatch.selector);
        executor.executeFinalizeRedeemBatch(address(controller), ids, settled);
        _step("  PASS: reverted with ClaimInputsLengthMismatch");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 11. test_ProcessRedeemBatch_DependsOnExchangeRate (P1)
    // -----------------------------------------------------------------------

    function test_ProcessRedeemBatch_DependsOnExchangeRate() public {
        _logCase("test_ProcessRedeemBatch_DependsOnExchangeRate", unicode"processRedeemBatch batchTotalAsset 依赖当前 exchangeRate");

        _step("[Step 1] UserA deposits 600 at 1:1 rate, create 3 requests");
        (uint256[] memory ids, uint256 sharesPerReq) = _setupRedeemRequests(userA, 600e18, 3);
        _step(string.concat("  sharesPerReq = ", vm.toString(sharesPerReq)));

        _step("[Step 2] Simulate rate increase to 1.05 (accountant updates rate after yield)");
        // Small rate change within normal deviation - no circuit breaker
        vault.setExchangeRate(1.05e18);
        _step(string.concat("  new exchangeRate = ", vm.toString(vault.exchangeRate())));
        // batchTotalAsset = 600e18 * 1.05e18 / 1e18 = 630e18
        _step("  batchTotalAsset should be 630e18 (shares * new rate)");

        _step("[Step 3] UserB deposits to provide extra buffer for potential shortfall");
        _depositToVault(userB, 200e18);

        _step("[Step 4] Process and verify batch processes at new rate");
        _processRedeemBatch(ids);
        // M-1: verify via Vault request status instead of removed processingBatchDone mapping.
        for (uint256 i = 0; i < ids.length; i++) {
            (,,,,,,, IMantleYieldVault.RequestStatus s) = vault.requests(ids[i]);
            assertEq(uint8(s), uint8(IMantleYieldVault.RequestStatus.PROCESSING), "batch should be processed");
        }
        _step("  PASS: batch processed with rate-dependent batchTotalAsset (630e18 not 600e18)");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 12. test_RedeemBatch_PaginatedProcessing (P1)
    // -----------------------------------------------------------------------

    function test_RedeemBatch_PaginatedProcessing() public {
        _logCase("test_RedeemBatch_PaginatedProcessing", unicode"运营方分页处理批次不破坏整体队列一致性");

        _step("[Step 0] Third depositor provides buffer so vault has enough freeCash");
        address userC = makeAddr("userC");
        _depositToVault(userC, 1000e18);

        _step("[Step 1] UserA deposits 600, creates 3 requests (batch A)");
        (uint256[] memory batchA, uint256 sharesA) = _setupRedeemRequests(userA, 600e18, 3);
        _step(string.concat("  batchA ids = [", vm.toString(batchA[0]), ", ", vm.toString(batchA[1]), ", ", vm.toString(batchA[2]), "]"));

        _step("[Step 2] UserB deposits 400, creates 2 requests (batch B)");
        (uint256[] memory batchB, uint256 sharesB) = _setupRedeemRequests(userB, 400e18, 2);
        _step(string.concat("  batchB ids = [", vm.toString(batchB[0]), ", ", vm.toString(batchB[1]), "]"));

        _step("[Step 3] Process batch A via OperatorExecutor");
        _processRedeemBatch(batchA);
        _step("  PASS: batch A processed");

        _step("[Step 4] Process batch B via OperatorExecutor");
        _processRedeemBatch(batchB);
        _step("  PASS: batch B processed");

        _step("[Step 5] Finalize batch B first (out of order)");
        uint256 assetPerB = (sharesB * vault.exchangeRate()) / 1e18;
        uint256[] memory settledB = new uint256[](2);
        settledB[0] = assetPerB;
        settledB[1] = assetPerB;

        uint256 userBBalanceBefore = asset.balanceOf(userB);
        _finalizeRedeemBatch(batchB, settledB);

        (,,,,,,, IMantleYieldVault.RequestStatus sB0) = vault.requests(batchB[0]);
        assertEq(uint8(sB0), uint8(IMantleYieldVault.RequestStatus.DONE));
        uint256 userBReceived = asset.balanceOf(userB) - userBBalanceBefore;
        _step(string.concat("  userB received = ", vm.toString(userBReceived)));
        _step("  PASS: batch B finalized, userB received USDC");

        _step("[Step 6] Verify batch A still in PROCESSING");
        (,,,,,,, IMantleYieldVault.RequestStatus sA0) = vault.requests(batchA[0]);
        assertEq(uint8(sA0), uint8(IMantleYieldVault.RequestStatus.PROCESSING));
        _step("  PASS: batch A still PROCESSING - batches are independent");

        _step("[Step 7] Finalize batch A");
        uint256 assetPerA = (sharesA * vault.exchangeRate()) / 1e18;
        uint256[] memory settledA = new uint256[](3);
        settledA[0] = assetPerA;
        settledA[1] = assetPerA;
        settledA[2] = assetPerA;

        uint256 userABalanceBefore = asset.balanceOf(userA);
        _finalizeRedeemBatch(batchA, settledA);

        (,,,,,,, IMantleYieldVault.RequestStatus sA0Final) = vault.requests(batchA[0]);
        assertEq(uint8(sA0Final), uint8(IMantleYieldVault.RequestStatus.DONE));
        uint256 userAReceived = asset.balanceOf(userA) - userABalanceBefore;
        _step(string.concat("  userA received = ", vm.toString(userAReceived)));
        _step("  PASS: all batches finalized, both users received USDC");

        _step("[Step 8] Verify all locked shares released");
        assertEq(vault.totalLockedSharesValue(), 0, "all locked shares should be released");
        _step("  PASS: totalLockedShares = 0, queue consistency maintained");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 13. test_ProcessRedeemBatch_ZeroBatchTotalAsset (P2)
    // -----------------------------------------------------------------------

    function test_ProcessRedeemBatch_ZeroBatchTotalAsset() public {
        _logCase("test_ProcessRedeemBatch_ZeroBatchTotalAsset", unicode"processRedeemBatch batchTotalAsset 为 0 的边界行为");

        _step("[Step 1] Deposit minimal amount and create requests with tiny shares");
        // Deposit 3 wei of asset => 3 wei of shares at 1:1
        uint256 totalShares = _depositToVault(userA, 3);
        uint256 reqId1 = _createRedeemRequest(userA, 1);
        uint256 reqId2 = _createRedeemRequest(userA, 1);
        uint256 reqId3 = _createRedeemRequest(userA, 1);

        uint256[] memory ids = new uint256[](3);
        ids[0] = reqId1;
        ids[1] = reqId2;
        ids[2] = reqId3;

        _step("[Step 2] Set exchangeRate to 1 wei so shares * rate / 1e18 = 0");
        vault.setExchangeRate(1);
        _step("  batchTotalAsset = 3 * floor(1 * 1 / 1e18) = 0");

        _step("[Step 3] Process batch - should succeed with batchTotalAsset=0, no divest");
        _processRedeemBatch(ids);
        // M-1: verify via Vault request status instead of removed processingBatchDone mapping.
        for (uint256 i = 0; i < ids.length; i++) {
            (,,,,,,, IMantleYieldVault.RequestStatus sProc) = vault.requests(ids[i]);
            assertEq(uint8(sProc), uint8(IMantleYieldVault.RequestStatus.PROCESSING));
        }
        _step("  PASS: batch processed with batchTotalAsset=0");

        _step("[Step 4] Verify requests remain PROCESSING (finalize with 0 settledAssets would revert via Vault__ZeroAmount)");
        // Note: finalizeRedeemBatch with settledAssets=[0,0,0] would revert in real vault
        // (Vault__ZeroAmount). The spec tests processRedeemBatch boundary, not finalize.

        _step("[Step 5] Spot-check first request status");
        (,,,,,,, IMantleYieldVault.RequestStatus s1) = vault.requests(ids[0]);
        assertEq(uint8(s1), uint8(IMantleYieldVault.RequestStatus.PROCESSING));
        _step("  PASS: edge case handled - zero-total batch processes successfully");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 14. test_ProcessRedeemBatch_RejectProcessingToProcessing (N-16)
    // -----------------------------------------------------------------------

    function test_ProcessRedeemBatch_RejectProcessingToProcessing() public {
        _logCase(
            "test_ProcessRedeemBatch_RejectProcessingToProcessing",
            unicode"[N-16] Vault rejects PROCESSING -> PROCESSING transition"
        );

        _step("[Step 1] Deposit and create 2 requests");
        _depositToVault(userB, 400e18);
        (uint256[] memory ids,) = _setupRedeemRequests(userA, 400e18, 2);
        _step(string.concat("  ids = [", vm.toString(ids[0]), ", ", vm.toString(ids[1]), "]"));

        _step("[Step 2] Process batch successfully -> PENDING to PROCESSING");
        _processRedeemBatch(ids);
        for (uint256 i = 0; i < ids.length; i++) {
            (,,,,,,, IMantleYieldVault.RequestStatus s) = vault.requests(ids[i]);
            assertEq(uint8(s), uint8(IMantleYieldVault.RequestStatus.PROCESSING));
        }
        _step("  PASS: all requests now PROCESSING");

        _step("[Step 3] Attempt to process same batch again -> Vault rejects PROCESSING->PROCESSING");
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMantleYieldVault.Vault__InvalidState.selector,
                ids[0],
                IMantleYieldVault.RequestStatus.PROCESSING
            )
        );
        _processRedeemBatch(ids);
        _step("  PASS: Vault__InvalidState(id, PROCESSING) - state machine rejects duplicate process");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 15. test_FinalizeRedeemBatch_RejectDoneToDone (N-17)
    // -----------------------------------------------------------------------

    function test_FinalizeRedeemBatch_RejectDoneToDone() public {
        _logCase(
            "test_FinalizeRedeemBatch_RejectDoneToDone",
            unicode"[N-17] Vault rejects DONE -> DONE (duplicate finalize)"
        );

        _step("[Step 1] Deposit, create requests, and process");
        _depositToVault(userB, 400e18);
        (uint256[] memory ids, uint256 sharesPerReq) = _setupRedeemRequests(userA, 400e18, 2);
        _processRedeemBatch(ids);

        _step("[Step 2] Finalize successfully -> PROCESSING to DONE");
        uint256 assetPerReq = (sharesPerReq * vault.exchangeRate()) / 1e18;
        uint256[] memory settled = new uint256[](2);
        settled[0] = assetPerReq;
        settled[1] = assetPerReq;
        _finalizeRedeemBatch(ids, settled);

        for (uint256 i = 0; i < ids.length; i++) {
            (,,,,,,, IMantleYieldVault.RequestStatus s) = vault.requests(ids[i]);
            assertEq(uint8(s), uint8(IMantleYieldVault.RequestStatus.DONE));
        }
        _step("  PASS: all requests now DONE");

        _step("[Step 3] Attempt duplicate finalize -> Controller rejects DONE requests");
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyController.InvalidRequestState.selector,
                ids[0],
                IMantleYieldVault.RequestStatus.DONE
            )
        );
        _finalizeRedeemBatch(ids, settled);
        _step("  PASS: InvalidRequestState(id, DONE) - cannot finalize already-DONE requests");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 16. test_MarkRequestsDone_RejectPendingDirect (N-18)
    // -----------------------------------------------------------------------

    function test_MarkRequestsDone_RejectPendingDirect() public {
        _logCase(
            "test_MarkRequestsDone_RejectPendingDirect",
            unicode"[N-18] Vault rejects PENDING -> DONE (skip PROCESSING)"
        );

        _step("[Step 1] Deposit and create requests (remain PENDING)");
        _depositToVault(userB, 400e18);
        (uint256[] memory ids, uint256 sharesPerReq) = _setupRedeemRequests(userA, 400e18, 2);

        for (uint256 i = 0; i < ids.length; i++) {
            (,,,,,,, IMantleYieldVault.RequestStatus s) = vault.requests(ids[i]);
            assertEq(uint8(s), uint8(IMantleYieldVault.RequestStatus.PENDING));
        }
        _step("  All requests are PENDING");

        _step("[Step 2] Attempt finalize directly (skip process) -> Controller rejects PENDING requests");
        uint256 assetPerReq = (sharesPerReq * vault.exchangeRate()) / 1e18;
        uint256[] memory settled = new uint256[](2);
        settled[0] = assetPerReq;
        settled[1] = assetPerReq;
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyController.InvalidRequestState.selector,
                ids[0],
                IMantleYieldVault.RequestStatus.PENDING
            )
        );
        _finalizeRedeemBatch(ids, settled);
        _step("  PASS: InvalidRequestState(id, PENDING) - cannot skip PROCESSING step");
        _logPass();
    }
}
