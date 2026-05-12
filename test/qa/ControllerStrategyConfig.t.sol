// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {IStrategyAdapter} from "../../src/interfaces/adapters/IStrategyAdapter.sol";
import {IStrategyControllerExecutor} from "../../src/interfaces/strategy/IStrategyControllerExecutor.sol";
import {IMantleVaultGateway} from "../../src/interfaces/vault/IMantleVaultGateway.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {OperatorExecutor} from "../../src/protocol/OperatorExecutor.sol";
import {MantleVaultGateway} from "../../src/vault/MantleVaultGateway.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Test, console2} from "forge-std/Test.sol";

// ---------------------------------------------------------------------------
// Mock contracts
// ---------------------------------------------------------------------------

contract MockAsset is ERC20 {
    constructor() ERC20("MockAsset", "mAST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract MockStrategyAdapter is IStrategyAdapter {
    address public immutable ASSET;
    address public immutable POS_TOKEN;
    address public VAULT;

    bool public paused;

    constructor(address asset_, address posToken_) {
        ASSET = asset_;
        POS_TOKEN = posToken_;
    }

    function setVault(address v) external {
        VAULT = v;
    }

    function name() external pure returns (string memory) {
        return "MockStrategyAdapter";
    }

    function asset() external view returns (address) {
        return ASSET;
    }

    function posToken() external view returns (address) {
        return POS_TOKEN;
    }

    function priceOracle() external pure returns (address) {
        return address(0);
    }

    function getPosTokenPrice() external pure returns (uint256) {
        return 0;
    }

    function estimatePosAmount(uint256 assetAmount) external pure returns (uint256 positionAmount) {
        return assetAmount;
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

    function vault() external view returns (address) {
        return VAULT;
    }

    function totalValue() external view returns (uint256) {
        return IERC20(POS_TOKEN).balanceOf(address(this));
    }

    function deposit(uint256 amount, address) external returns (uint256 sharesOrPos) {
        IERC20(ASSET).transferFrom(VAULT, address(this), amount);
        // USDC leaves adapter to SubRed (burn to simulate)
        MockAsset(ASSET).burn(address(this), amount);
        // DiGiFT fulfillment: posToken arrives at adapter
        MockAsset(POS_TOKEN).mint(address(this), amount);
        return amount;
    }

    function withdrawSync(uint256 amount, address) external returns (uint256 actualUSDC) {
        IERC20(ASSET).transfer(VAULT, amount);
        return amount;
    }

    function requestRedeemAsync(uint256 amount, address) external {
        IERC20(POS_TOKEN).transferFrom(VAULT, address(this), amount);
    }

    function sweepToVault(address token, uint256 amount) external returns (uint256 claimed) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        claimed = amount > bal ? bal : amount;
        if (claimed > 0) {
            IERC20(token).transfer(VAULT, claimed);
        }
    }

    function setPaused(bool p) external {
        paused = p;
    }
    function retryRedeemAsync(uint256, address) external {}
    function minSubscribeAsset() external pure returns (uint256) { return 0; }
    function minRedeemPos() external pure returns (uint256) { return 0; }
}

contract MockControllerVault {
    ERC20 public immutable token;
    uint256 public mockedExchangeRate = 1e18;

    uint256 public locked;
    uint256 public investInFlightTotal;
    uint256 public redeemInFlightTotal;
    uint256 public nextInFlightId = 1;
    uint256 public nextReqId = 1;
    uint256 public pendingRequestCount;
    mapping(address => uint256) public investInFlightByAdapter;
    mapping(address => uint256) public redeemInFlightByAdapter;
    mapping(address => bool) public isAdapterRegistry;
    address[] public adapterList;

    struct Req {
        uint256 shares;
        uint256 estimatedAssets;
        uint256 settledAssets;
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

    function asset() external view returns (address) {
        return address(token);
    }

    function setExchangeRate(uint256 rate) external {
        mockedExchangeRate = rate;
    }

    function exchangeRate() external view returns (uint256) {
        return mockedExchangeRate;
    }

    function totalLockedLiabilities() external view returns (uint256) {
        return locked;
    }

    function totalInvestInFlight() external view returns (uint256) {
        return investInFlightTotal;
    }

    function totalRedeemInFlight() external view returns (uint256) {
        return redeemInFlightTotal;
    }

    function adapterInvestInFlightTokens(address adapter) external view returns (uint256) {
        return investInFlightByAdapter[adapter];
    }

    function adapterRedeemInFlightUsdc(address adapter) external view returns (uint256) {
        return redeemInFlightByAdapter[adapter];
    }

    function getFreeCash() external view returns (uint256) {
        uint256 totalCash = token.balanceOf(address(this));
        return totalCash > locked ? totalCash - locked : 0;
    }

    function getCashDeficit() external view returns (uint256) {
        uint256 totalCash = token.balanceOf(address(this));
        return locked > totalCash ? locked - totalCash : 0;
    }

    function totalAssets() external view returns (uint256) {
        uint256 total = token.balanceOf(address(this)) + investInFlightTotal;
        for (uint256 i = 0; i < adapterList.length; i++) {
            total += IStrategyAdapter(adapterList[i]).totalValue();
        }
        // Mirror real vault: deduct floating locked liabilities
        if (total <= locked) return 0;
        return total - locked;
    }

    function nextRequestId() external view returns (uint256) {
        return nextReqId;
    }

    function createMockRequest(uint256 shares, uint256 estimatedAssets, IMantleYieldVault.RequestStatus status)
        external
    {
        uint256 id = nextReqId++;
        reqs[id] = Req(shares, estimatedAssets, 0, status);
        // Simulate real vault: only active requests (PENDING/PROCESSING) lock liabilities
        if (status == IMantleYieldVault.RequestStatus.PENDING || status == IMantleYieldVault.RequestStatus.PROCESSING) {
            locked += estimatedAssets;
        }
        // Track pending count for StrategyController._readRebalanceState()
        if (status == IMantleYieldVault.RequestStatus.PENDING) {
            pendingRequestCount++;
        }
    }

    function approveToAdapter(address adapter, address approveToken, uint256 amount) external {
        ERC20(approveToken).approve(adapter, amount);
    }

    function isAdapter(address adapter) external view returns (bool) {
        return isAdapterRegistry[adapter];
    }

    function registerAdapter(address adapter) external {
        isAdapterRegistry[adapter] = true;
        adapterList.push(adapter);
    }

    function removeAdapter(address adapter) external {
        require(investInFlightByAdapter[adapter] == 0 && redeemInFlightByAdapter[adapter] == 0, "HAS_IN_FLIGHT");
        isAdapterRegistry[adapter] = false;
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
        return (requestId, address(0), r.shares, 0, r.estimatedAssets, r.settledAssets, 0, r.status);
    }

    function inFlightRecords(uint256 inFlightId)
        external
        view
        returns (
            uint256 id,
            address adapter,
            address assetAddr,
            uint256 tokenAmount,
            uint256 usdcAmount,
            uint256 settledAmount,
            bool isInvest,
            uint256 timestamp,
            IMantleYieldVault.InFlightStatus status
        )
    {
        InFlight memory f = flights[inFlightId];
        return (f.id, f.adapter, f.assetAddr, f.tokenAmount, f.usdcAmount, f.settledAmount, f.isInvest, f.timestamp, f.status);
    }
}

contract MockSanctionsOracle_CSC is ISanctionsOracle {
    function initialize(address, address) external {}
    function isSanctioned(address) external pure returns (bool) { return false; }
    function isWhitelisted(address) external pure returns (bool) { return true; }
    function totalSanctionedCount() external pure returns (uint256) { return 0; }
    function totalWhitelistedCount() external pure returns (uint256) { return 0; }
    function lastUpdateTimestamp() external pure returns (uint256) { return 0; }
    function batchNonce() external pure returns (uint256) { return 0; }
    function MAX_BATCH_SIZE() external pure returns (uint256) { return 200; }
    function updateSanctionStatus(address, bool) external {}
    function updateSanctionStatusBatch(address[] calldata, bool) external {}
    function updateWhitelistStatus(address, bool) external {}
    function updateWhitelistStatusBatch(address[] calldata, bool) external {}
}

contract MockAccountant_CSC {
    uint256 public rate = 1e18;

    function getRate() external view returns (uint256) { return rate; }
    function getRateSafe() external view returns (uint256) { return rate; }
    function setExchangeRate(uint256 newRate) external { rate = newRate; }
}

contract MockSettlementVenue_CSC {
    MockAsset public immutable ASSET;
    MockAsset public immutable POS_TOKEN;

    mapping(address => uint256) public pendingInvestAsset;
    mapping(address => uint256) public pendingRedeemPos;

    constructor(address asset_, address posToken_) {
        ASSET = MockAsset(asset_);
        POS_TOKEN = MockAsset(posToken_);
    }

    function acceptInvest(address adapter, uint256 assetAmount) external {
        pendingInvestAsset[adapter] += assetAmount;
    }

    function acceptRedeem(address adapter, uint256 posAmount) external {
        pendingRedeemPos[adapter] += posAmount;
    }

    function settleInvest(
        address adapter,
        uint256 investAssetAmount,
        uint256 maxPosAmount,
        uint256 settledPosAmount,
        uint256 refundAssetAmount
    ) external {
        uint256 pendingAsset = pendingInvestAsset[adapter];
        require(investAssetAmount <= pendingAsset, "INVEST_ASSET_EXCEEDS_PENDING");
        require(settledPosAmount <= maxPosAmount, "INVEST_POS_EXCEEDS_EXPECTED");
        require(refundAssetAmount <= investAssetAmount, "INVEST_REFUND_EXCEEDS_ASSET");

        pendingInvestAsset[adapter] = pendingAsset - investAssetAmount;

        uint256 consumedAssetAmount = investAssetAmount - refundAssetAmount;
        if (consumedAssetAmount > 0) {
            ASSET.burn(address(this), consumedAssetAmount);
        }
        if (settledPosAmount > 0) {
            POS_TOKEN.mint(adapter, settledPosAmount);
        }
        if (refundAssetAmount > 0) {
            ASSET.transfer(adapter, refundAssetAmount);
        }
    }

    function settleRedeem(address adapter, uint256 redeemPosAmount, uint256 assetAmount) external {
        uint256 pendingPos = pendingRedeemPos[adapter];
        require(redeemPosAmount <= pendingPos, "REDEEM_POS_EXCEEDS_PENDING");

        pendingRedeemPos[adapter] = pendingPos - redeemPosAmount;

        if (redeemPosAmount > 0) {
            POS_TOKEN.burn(address(this), redeemPosAmount);
        }
        if (assetAmount > 0) {
            ASSET.mint(adapter, assetAmount);
        }
    }
}

contract MockAsyncAdapter_CSC is IStrategyAdapter {
    address public immutable ASSET;
    address public immutable POS_TOKEN;
    address public immutable VAULT;
    MockSettlementVenue_CSC public immutable SETTLEMENT_VENUE;

    constructor(address asset_, address posToken_, address vault_, address settlementVenue_) {
        ASSET = asset_;
        POS_TOKEN = posToken_;
        VAULT = vault_;
        SETTLEMENT_VENUE = MockSettlementVenue_CSC(settlementVenue_);
    }

    function name() external pure returns (string memory) { return "MockAsyncAdapterCSC"; }
    function asset() external view returns (address) { return ASSET; }
    function posToken() external view returns (address) { return POS_TOKEN; }
    function priceOracle() external pure returns (address) { return address(0); }
    function getPosTokenPrice() external pure returns (uint256) { return 1e18; }
    function estimatePosAmount(uint256 assetAmount) external pure returns (uint256 positionAmount) {
        return assetAmount;
    }

    function previewDeposit(uint256 assetAmount)
        external
        pure
        returns (bool ok, uint256 executableAssetAmount, uint256 expectedPosAmount)
    {
        ok = assetAmount > 0;
        executableAssetAmount = assetAmount;
        expectedPosAmount = assetAmount;
    }

    function previewRedeem(uint256 assetAmount)
        external
        pure
        returns (bool ok, uint256 executableAssetAmount, uint256 expectedPosAmount)
    {
        ok = assetAmount > 0;
        executableAssetAmount = assetAmount;
        expectedPosAmount = assetAmount;
    }

    function vault() external view returns (address) { return VAULT; }
    function totalValue() external view returns (uint256) { return IERC20(POS_TOKEN).balanceOf(VAULT); }

    function deposit(uint256 amount, address) external returns (uint256 sharesOrPos) {
        IERC20(ASSET).transferFrom(VAULT, address(this), amount);
        IERC20(ASSET).transfer(address(SETTLEMENT_VENUE), amount);
        SETTLEMENT_VENUE.acceptInvest(address(this), amount);
        return amount;
    }

    function withdrawSync(uint256, address) external pure returns (uint256) {
        revert("Unsupported");
    }

    function requestRedeemAsync(uint256 amount, address) external {
        IERC20(POS_TOKEN).transferFrom(VAULT, address(this), amount);
        IERC20(POS_TOKEN).transfer(address(SETTLEMENT_VENUE), amount);
        SETTLEMENT_VENUE.acceptRedeem(address(this), amount);
    }

    function sweepToVault(address token, uint256 amount) external returns (uint256 claimed) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        claimed = amount > bal ? bal : amount;
        if (claimed > 0) {
            IERC20(token).transfer(VAULT, claimed);
        }
    }

    function setPaused(bool) external {}
    function retryRedeemAsync(uint256, address) external {}
    function minSubscribeAsset() external pure returns (uint256) { return 0; }
    function minRedeemPos() external pure returns (uint256) { return 0; }
}

// ---------------------------------------------------------------------------
// QA Test: Controller Strategy Config Scenarios
// ---------------------------------------------------------------------------

contract ControllerStrategyConfigTest is Test {
    struct RealRebalanceStack {
        MockAsset asset_;
        MockAsset posToken_;
        MockSanctionsOracle_CSC oracle_;
        MockAccountant_CSC accountant_;
        MantleYieldVault vault_;
        MantleVaultGateway gateway_;
        StrategyController controller_;
        OperatorExecutor executor_;
        MockSettlementVenue_CSC venue_;
        MockAsyncAdapter_CSC adapter_;
    }

    MockAsset internal asset;
    MockAsset internal posToken;
    MockControllerVault internal vault;
    StrategyController internal controller;
    OperatorExecutor internal executor;

    MockStrategyAdapter internal syncAdapter;
    MockStrategyAdapter internal asyncAdapter;

    address internal manager = makeAddr("manager");
    address internal bot = makeAddr("bot");
    address internal nonAdmin = makeAddr("nonAdmin");

    function setUp() public {
        asset = new MockAsset();
        posToken = new MockAsset();
        vault = new MockControllerVault(address(asset));

        OperatorExecutor execImpl = new OperatorExecutor();
        executor = OperatorExecutor(address(new ERC1967Proxy(
            address(execImpl),
            abi.encodeCall(OperatorExecutor.initialize, (manager, bot))
        )));

        StrategyController implementation = new StrategyController();
        bytes memory initData = abi.encodeCall(
            StrategyController.initialize,
            (address(vault), manager, address(executor), manager, 1000, 200, 1 hours)
        );
        controller = StrategyController(address(new ERC1967Proxy(address(implementation), initData)));

        syncAdapter = new MockStrategyAdapter(address(asset), address(posToken));
        asyncAdapter = new MockStrategyAdapter(address(asset), address(posToken));

        syncAdapter.setVault(address(vault));
        asyncAdapter.setVault(address(vault));
    }

    // -----------------------------------------------------------------------
    // Logging helpers
    // -----------------------------------------------------------------------

    string constant MODULE = unicode"Controller 策略配置场景";
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
    // Helpers
    // -----------------------------------------------------------------------

    function _registerAndActivateTwoStrategies() internal {
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 5000, 1, false);
        controller.activateStrategy(address(syncAdapter));
        controller.registerStrategy(address(asyncAdapter), 5000, 2, true);
        controller.activateStrategy(address(asyncAdapter));
        address[] memory ordered = new address[](2);
        ordered[0] = address(syncAdapter);
        ordered[1] = address(asyncAdapter);
        controller.setStrategyOrder(ordered);
        vm.stopPrank();
    }

    function _deployRealRebalanceStack() internal returns (RealRebalanceStack memory s) {
        address treasury = makeAddr("treasury_real_rebalance");
        address sanctionSafe = makeAddr("sanction_safe_real_rebalance");

        s.asset_ = new MockAsset();
        s.posToken_ = new MockAsset();
        s.oracle_ = new MockSanctionsOracle_CSC();
        s.accountant_ = new MockAccountant_CSC();

        MantleYieldVault vaultImpl = new MantleYieldVault();
        MantleVaultGateway gatewayImpl = new MantleVaultGateway();
        StrategyController controllerImpl = new StrategyController();
        OperatorExecutor executorImpl = new OperatorExecutor();

        s.vault_ = MantleYieldVault(address(new ERC1967Proxy(
            address(vaultImpl),
            abi.encodeCall(MantleYieldVault.initialize, IMantleYieldVault.InitParams({
                asset: IERC20(address(s.asset_)),
                name: "mRWA Vault",
                symbol: "mRWA",
                admin: manager,
                gateway: address(1),
                controller: manager,
                accountant: address(1),
                treasury: treasury,
                maxRedemptionFeeBps: 500,
                redemptionFeeBps: 0,
                minRedeemAmount: 0,
                minDepositAmount: 0,
                maxSettlementDeviationBps: 0,
                depositDailyRemaining: type(uint256).max,
                redeemDailyRemaining: type(uint256).max
            }))
        )));

        s.executor_ = OperatorExecutor(address(new ERC1967Proxy(
            address(executorImpl),
            abi.encodeCall(OperatorExecutor.initialize, (manager, bot))
        )));

        s.controller_ = StrategyController(address(new ERC1967Proxy(
            address(controllerImpl),
            abi.encodeCall(StrategyController.initialize, (
                address(s.vault_), manager, address(s.executor_), manager, 1000, 200, 0
            ))
        )));

        s.gateway_ = MantleVaultGateway(address(new ERC1967Proxy(
            address(gatewayImpl),
            abi.encodeCall(MantleVaultGateway.initialize, IMantleVaultGateway.InitParams({
                vault: address(s.vault_),
                sanctionsOracle: ISanctionsOracle(address(s.oracle_)),
                sanctionSafe: sanctionSafe,
                admin: manager,
                syncRedeemDisabled: false
            }))
        )));

        vm.startPrank(manager);
        s.vault_.setAccountant(address(s.accountant_));
        s.vault_.setGateway(address(s.gateway_));
        s.vault_.setController(address(s.controller_));
        vm.stopPrank();

        s.venue_ = new MockSettlementVenue_CSC(address(s.asset_), address(s.posToken_));
        s.adapter_ = new MockAsyncAdapter_CSC(
            address(s.asset_), address(s.posToken_), address(s.vault_), address(s.venue_)
        );

        vm.startPrank(manager);
        s.controller_.registerStrategy(address(s.adapter_), 10_000, 1, true);
        s.controller_.activateStrategy(address(s.adapter_));
        address[] memory ordered = new address[](1);
        ordered[0] = address(s.adapter_);
        s.controller_.setStrategyOrder(ordered);
        vm.stopPrank();
    }

    function _settleRealInvest(RealRebalanceStack memory s, uint256 inFlightId, uint256 posAmount, uint256 refundAsset)
        internal
    {
        (,,, uint256 expectedPos, uint256 investAsset,, bool isInvest,,) = s.vault_.inFlightRecords(inFlightId);
        assertTrue(isInvest, "expected invest in-flight");

        s.venue_.settleInvest(address(s.adapter_), investAsset, expectedPos, posAmount, refundAsset);

        uint256[] memory ids = new uint256[](1);
        ids[0] = inFlightId;
        uint256[] memory settledPos = new uint256[](1);
        settledPos[0] = posAmount;
        uint256[] memory refunds = new uint256[](1);
        refunds[0] = refundAsset;

        vm.prank(bot);
        s.executor_.executeSettleAdapter(
            address(s.controller_),
            address(s.adapter_),
            IStrategyControllerExecutor.InvestSettlementInput(ids, settledPos, refunds),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );
    }

    function _movePrimaryRealAdapterOutOfOrder(RealRebalanceStack memory s) internal returns (address standbyAdapter) {
        MockAsset standbyPosToken = new MockAsset();
        MockSettlementVenue_CSC standbyVenue =
            new MockSettlementVenue_CSC(address(s.asset_), address(standbyPosToken));
        MockAsyncAdapter_CSC standby = new MockAsyncAdapter_CSC(
            address(s.asset_), address(standbyPosToken), address(s.vault_), address(standbyVenue)
        );

        vm.startPrank(manager);
        s.controller_.registerStrategy(address(standby), 10_000, 2, true);
        s.controller_.activateStrategy(address(standby));

        address[] memory adapters = new address[](2);
        adapters[0] = address(s.adapter_);
        adapters[1] = address(standby);
        uint16[] memory weights = new uint16[](2);
        weights[0] = 0;
        weights[1] = 10_000;
        uint16[] memory priorities = new uint16[](2);
        priorities[0] = 1;
        priorities[1] = 2;
        bool[] memory isAsyncFlags = new bool[](2);
        isAsyncFlags[0] = true;
        isAsyncFlags[1] = true;
        address[] memory newOrder = new address[](1);
        newOrder[0] = address(standby);

        s.controller_.updateStrategiesAndOrder(adapters, weights, priorities, isAsyncFlags, newOrder);
        vm.stopPrank();

        standbyAdapter = address(standby);
    }

    // -----------------------------------------------------------------------
    // 1. test_Initialize_Success (P0)
    // -----------------------------------------------------------------------

    function test_Initialize_Success() public {
        _logCase("test_Initialize_Success", unicode"StrategyController 初始化成功");

        _step("[Step 1] Verify vault and asset addresses");
        _step(string.concat("  controller.vault() = ", vm.toString(address(controller.vault()))));
        assertEq(address(controller.vault()), address(vault));
        _step("  PASS: vault address matches");
        _step(string.concat("  controller.asset() = ", vm.toString(address(controller.asset()))));
        assertEq(address(controller.asset()), address(asset));
        _step("  PASS: asset address matches");

        _step("[Step 2] Verify role assignments");
        bool hasAdmin = controller.hasRole(controller.DEFAULT_ADMIN_ROLE(), manager);
        _step(string.concat("  manager has DEFAULT_ADMIN_ROLE = ", vm.toString(hasAdmin)));
        assertTrue(hasAdmin);
        _step("  PASS: admin role assigned");
        bool hasOperator = controller.hasRole(controller.OPERATOR_EXECUTOR_ROLE(), address(executor));
        _step(string.concat("  executor has OPERATOR_EXECUTOR_ROLE = ", vm.toString(hasOperator)));
        assertTrue(hasOperator);
        _step("  PASS: operator executor role assigned");
        bool hasPauser = controller.hasRole(controller.PAUSER_ROLE(), manager);
        _step(string.concat("  manager has PAUSER_ROLE = ", vm.toString(hasPauser)));
        assertTrue(hasPauser);
        _step("  PASS: pauser role assigned");

        _step("[Step 3] Verify risk parameters");
        uint256 bufBps = controller.bufferTargetBps();
        uint256 rebalBps = controller.rebalanceThresholdBps();
        uint256 cooldown = controller.rebalanceCooldown();
        _step(string.concat("  bufferTargetBps = ", vm.toString(bufBps)));
        _step(string.concat("  rebalanceThresholdBps = ", vm.toString(rebalBps)));
        _step(string.concat("  rebalanceCooldown = ", vm.toString(cooldown)));
        assertEq(bufBps, 1000);
        assertEq(rebalBps, 200);
        assertEq(cooldown, 1 hours);
        _step("  PASS: risk params match expected values");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 2. test_Initialize_RevertInvalidParams (P0)
    // -----------------------------------------------------------------------

    function test_Initialize_RevertInvalidParams() public {
        _logCase("test_Initialize_RevertInvalidParams", unicode"初始化拒绝零地址及非法参数");
        StrategyController impl = new StrategyController();

        _step("[Step 1] Attempt initialize with zero vault address");
        bytes memory initData = abi.encodeCall(
            StrategyController.initialize,
            (address(0), manager, address(executor), manager, 1000, 200, 1 hours)
        );
        vm.expectRevert(StrategyController.Controller__InvalidAddress.selector);
        new ERC1967Proxy(address(impl), initData);
        _step("  PASS: reverted as expected (InvalidAddress)");

        _step("[Step 2] Attempt initialize with zero admin address");
        initData = abi.encodeCall(
            StrategyController.initialize,
            (address(vault), address(0), address(executor), manager, 1000, 200, 1 hours)
        );
        vm.expectRevert(StrategyController.Controller__InvalidAddress.selector);
        new ERC1967Proxy(address(impl), initData);
        _step("  PASS: reverted as expected (InvalidAddress)");

        _step("[Step 3] Attempt initialize with zero operator executor address");
        initData = abi.encodeCall(
            StrategyController.initialize,
            (address(vault), manager, address(0), manager, 1000, 200, 1 hours)
        );
        vm.expectRevert(StrategyController.Controller__InvalidAddress.selector);
        new ERC1967Proxy(address(impl), initData);
        _step("  PASS: reverted as expected (InvalidAddress)");

        _step("[Step 4] Attempt initialize with zero pauser address");
        initData = abi.encodeCall(
            StrategyController.initialize,
            (address(vault), manager, address(executor), address(0), 1000, 200, 1 hours)
        );
        vm.expectRevert(StrategyController.Controller__InvalidAddress.selector);
        new ERC1967Proxy(address(impl), initData);
        _step("  PASS: reverted as expected (InvalidAddress)");

        _step("[Step 5] Attempt initialize with EOA executor");
        address eoaExecutor = makeAddr("eoaExecutor");
        initData = abi.encodeCall(
            StrategyController.initialize,
            (address(vault), manager, eoaExecutor, manager, 1000, 200, 1 hours)
        );
        vm.expectRevert(abi.encodeWithSelector(StrategyController.Controller__InvalidExecutorContract.selector, eoaExecutor));
        new ERC1967Proxy(address(impl), initData);
        _step("  PASS: reverted as expected (InvalidExecutorContract)");

        _step("[Step 6] Attempt initialize with bufferTargetBps = 10001 (> 10000)");
        initData = abi.encodeCall(
            StrategyController.initialize,
            (address(vault), manager, address(executor), manager, 10001, 200, 1 hours)
        );
        vm.expectRevert(StrategyController.Controller__InvalidBps.selector);
        new ERC1967Proxy(address(impl), initData);
        _step("  PASS: reverted as expected (InvalidBps)");

        _step("[Step 7] Attempt initialize with rebalanceThresholdBps = 10001 (> 10000)");
        initData = abi.encodeCall(
            StrategyController.initialize,
            (address(vault), manager, address(executor), manager, 1000, 10001, 1 hours)
        );
        vm.expectRevert(StrategyController.Controller__InvalidBps.selector);
        new ERC1967Proxy(address(impl), initData);
        _step("  PASS: reverted as expected (InvalidBps)");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 5. test_RegisterStrategy_OnlyAdmin (P0)
    // -----------------------------------------------------------------------

    function test_RegisterStrategy_OnlyAdmin() public {
        _logCase("test_RegisterStrategy_OnlyAdmin", unicode"只有 admin 可以注册策略");

        _step("[Step 1] Non-admin attempts to register strategy");
        _step(string.concat("  nonAdmin = ", vm.toString(nonAdmin)));
        bytes32 adminRole = controller.DEFAULT_ADMIN_ROLE();
        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nonAdmin, adminRole));
        controller.registerStrategy(address(syncAdapter), 5000, 1, false);
        _step("  PASS: reverted as expected (access control)");

        _step("[Step 2] Admin registers strategy");
        _step(string.concat("  manager = ", vm.toString(manager)));
        vm.prank(manager);
        controller.registerStrategy(address(syncAdapter), 5000, 1, false);
        _step("  registerStrategy called successfully");

        _step("[Step 3] Verify strategy registered with isActive = false");
        (, , , bool isActive, bool exists) = controller.strategyInfo(address(syncAdapter));
        _step(string.concat("  exists = ", vm.toString(exists)));
        _step(string.concat("  isActive = ", vm.toString(isActive)));
        assertTrue(exists);
        _step("  PASS: strategy exists");
        assertFalse(isActive);
        _step("  PASS: strategy starts inactive");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 6. test_RegisterStrategy_AutoRegistersVaultAdapter (P0)
    // -----------------------------------------------------------------------

    function test_RegisterStrategy_AutoRegistersVaultAdapter() public {
        _logCase("test_RegisterStrategy_AutoRegistersVaultAdapter", unicode"注册策略时自动确保 Vault 已注册 adapter");

        _step("[Step 1] Check adapter not registered in vault before");
        bool before = vault.isAdapterRegistry(address(syncAdapter));
        _step(string.concat("  vault.isAdapter(syncAdapter) = ", vm.toString(before)));
        assertFalse(before);
        _step("  PASS: adapter not registered yet");

        _step("[Step 2] Admin registers strategy");
        vm.prank(manager);
        controller.registerStrategy(address(syncAdapter), 5000, 1, false);
        _step("  registerStrategy called successfully");

        _step("[Step 3] Verify vault auto-registered adapter");
        bool after_ = vault.isAdapterRegistry(address(syncAdapter));
        _step(string.concat("  vault.isAdapter(syncAdapter) = ", vm.toString(after_)));
        assertTrue(after_);
        _step("  PASS: adapter auto-registered in vault");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 7. test_RegisterStrategy_RevertDuplicate (P0)
    // -----------------------------------------------------------------------

    function test_RegisterStrategy_RevertDuplicate() public {
        _logCase("test_RegisterStrategy_RevertDuplicate", unicode"注册重复策略被拒绝");

        _step("[Step 1] Register strategy for the first time");
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 5000, 1, false);
        _step(string.concat("  registered syncAdapter = ", vm.toString(address(syncAdapter))));

        _step("[Step 2] Attempt to register the same strategy again");
        vm.expectRevert(abi.encodeWithSelector(StrategyController.Controller__InvalidStrategy.selector, address(syncAdapter)));
        controller.registerStrategy(address(syncAdapter), 5000, 1, false);
        _step("  PASS: reverted as expected (InvalidStrategy - duplicate)");
        vm.stopPrank();
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 8. test_SetStrategyOrder_RevertWeightsNot10000 (P0)
    // -----------------------------------------------------------------------

    function test_SetStrategyOrder_RevertWeightsNot10000() public {
        _logCase("test_SetStrategyOrder_RevertWeightsNot10000", unicode"设置策略顺序时，纳入 order 的 active 策略总权重必须等于 10000");

        _step("[Step 1] Register strategy with weight 7000 (not 10000)");
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 7000, 1, false);
        controller.activateStrategy(address(syncAdapter));
        _step(string.concat("  syncAdapter weight = ", vm.toString(uint256(7000))));

        _step("[Step 2] Attempt setStrategyOrder with total weight != 10000");
        address[] memory ordered = new address[](1);
        ordered[0] = address(syncAdapter);

        vm.expectRevert(abi.encodeWithSelector(StrategyController.Controller__WeightsMustBe10000.selector, 7000));
        controller.setStrategyOrder(ordered);
        _step("  PASS: reverted as expected (WeightsMustBe10000)");
        vm.stopPrank();
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 9. test_SetStrategyOrder_RevertInactiveStrategy (P0)
    // -----------------------------------------------------------------------

    function test_SetStrategyOrder_RevertInactiveStrategy() public {
        _logCase("test_SetStrategyOrder_RevertInactiveStrategy", unicode"inactive strategy 不能进入 order");

        _step("[Step 1] Register strategy but do NOT activate");
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 10000, 1, false);
        _step(string.concat("  syncAdapter = ", vm.toString(address(syncAdapter))));

        _step("[Step 2] Attempt setStrategyOrder with inactive strategy");
        address[] memory ordered = new address[](1);
        ordered[0] = address(syncAdapter);

        vm.expectRevert(abi.encodeWithSelector(StrategyController.Controller__StrategyInactive.selector, address(syncAdapter)));
        controller.setStrategyOrder(ordered);
        _step("  PASS: reverted as expected (StrategyInactive)");
        vm.stopPrank();
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 10. test_SetStrategyOrder_PriorityOrder (P1)
    // -----------------------------------------------------------------------

    function test_SetStrategyOrder_PriorityOrder() public {
        _logCase("test_SetStrategyOrder_PriorityOrder", unicode"priority 必须非递减");

        _step("[Step 1] Register syncAdapter with priority=1, asyncAdapter with priority=2");
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 5000, 1, false);
        controller.activateStrategy(address(syncAdapter));
        controller.registerStrategy(address(asyncAdapter), 5000, 2, true);
        controller.activateStrategy(address(asyncAdapter));
        _step(string.concat("  syncAdapter priority = ", vm.toString(uint256(1))));
        _step(string.concat("  asyncAdapter priority = ", vm.toString(uint256(2))));

        _step("[Step 2] setStrategyOrder with ascending priority (1 -> 2) succeeds");
        address[] memory ordered = new address[](2);
        ordered[0] = address(syncAdapter);  // priority 1
        ordered[1] = address(asyncAdapter); // priority 2 >= 1 -> valid
        controller.setStrategyOrder(ordered);
        _step("  setStrategyOrder succeeded");

        uint256 orderLen = controller.strategyOrderLength();
        assertEq(orderLen, 2);
        assertEq(controller.strategyOrder(0), address(syncAdapter));
        assertEq(controller.strategyOrder(1), address(asyncAdapter));
        _step("  PASS: ascending priority order accepted");

        _step("[Step 3] Attempt setStrategyOrder with descending priority (2 -> 1) reverts");
        address[] memory badOrder = new address[](2);
        badOrder[0] = address(asyncAdapter); // priority 2
        badOrder[1] = address(syncAdapter);  // priority 1 < 2 -> invalid

        vm.expectRevert(
            abi.encodeWithSelector(StrategyController.Controller__InvalidPriorityOrder.selector, address(syncAdapter))
        );
        controller.setStrategyOrder(badOrder);
        _step("  PASS: descending priority (2 -> 1) reverted as expected (InvalidPriorityOrder)");
        vm.stopPrank();
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 11. test_UpdateStrategiesAndOrder_Success (P1)
    // -----------------------------------------------------------------------

    function test_UpdateStrategiesAndOrder_Success() public {
        _logCase("test_UpdateStrategiesAndOrder_Success", unicode"updateStrategiesAndOrder 可同时更新参数与顺序");

        _step("[Step 1] Register and activate both strategies with initial weights 5000/5000");
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 5000, 1, false);
        controller.activateStrategy(address(syncAdapter));
        controller.registerStrategy(address(asyncAdapter), 5000, 2, true);
        controller.activateStrategy(address(asyncAdapter));
        _step(string.concat("  syncAdapter = ", vm.toString(address(syncAdapter))));
        _step(string.concat("  asyncAdapter = ", vm.toString(address(asyncAdapter))));

        _step("[Step 2] Set initial strategy order");
        address[] memory ordered = new address[](2);
        ordered[0] = address(syncAdapter);
        ordered[1] = address(asyncAdapter);
        controller.setStrategyOrder(ordered);
        _step("  initial order set successfully");

        _step("[Step 3] Update strategies and order: change weights to 6000/4000");
        address[] memory adapters = new address[](2);
        adapters[0] = address(syncAdapter);
        adapters[1] = address(asyncAdapter);
        uint16[] memory weights = new uint16[](2);
        weights[0] = 6000;
        weights[1] = 4000;
        uint16[] memory priorities = new uint16[](2);
        priorities[0] = 1;
        priorities[1] = 2;
        bool[] memory isAsyncFlags = new bool[](2);
        isAsyncFlags[0] = false;
        isAsyncFlags[1] = true;

        address[] memory newOrder = new address[](2);
        newOrder[0] = address(syncAdapter);
        newOrder[1] = address(asyncAdapter);

        controller.updateStrategiesAndOrder(adapters, weights, priorities, isAsyncFlags, newOrder);
        _step("  updateStrategiesAndOrder called successfully");

        _step("[Step 4] Verify updated weights and order length");
        (uint16 w1, , , ,) = controller.strategyInfo(address(syncAdapter));
        (uint16 w2, , , ,) = controller.strategyInfo(address(asyncAdapter));
        _step(string.concat("  syncAdapter weight = ", vm.toString(uint256(w1))));
        _step(string.concat("  asyncAdapter weight = ", vm.toString(uint256(w2))));
        assertEq(w1, 6000);
        _step("  PASS: syncAdapter weight updated to 6000");
        assertEq(w2, 4000);
        _step("  PASS: asyncAdapter weight updated to 4000");
        uint256 orderLen = controller.strategyOrderLength();
        _step(string.concat("  strategyOrderLength = ", vm.toString(orderLen)));
        assertEq(orderLen, 2);
        _step("  PASS: order length is 2");
        vm.stopPrank();
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 12. test_StrategyLifecycle_FullCycle (P0)
    // -----------------------------------------------------------------------

    function test_StrategyLifecycle_FullCycle() public {
        _logCase("test_StrategyLifecycle_FullCycle", unicode"策略完整生命周期：register -> activate -> order -> remove from order -> deactivate");
        vm.startPrank(manager);

        _step("[Step 1] Register syncAdapter");
        controller.registerStrategy(address(syncAdapter), 10000, 1, false);
        (, , , bool isActive, bool exists) = controller.strategyInfo(address(syncAdapter));
        _step(string.concat("  exists = ", vm.toString(exists), ", isActive = ", vm.toString(isActive)));
        assertTrue(exists);
        assertFalse(isActive);
        _step("  PASS: registered but inactive");

        _step("[Step 2] Activate syncAdapter");
        controller.activateStrategy(address(syncAdapter));
        (, , , isActive,) = controller.strategyInfo(address(syncAdapter));
        _step(string.concat("  isActive = ", vm.toString(isActive)));
        assertTrue(isActive);
        _step("  PASS: strategy is now active");

        _step("[Step 3] Set strategy order with syncAdapter");
        address[] memory ordered = new address[](1);
        ordered[0] = address(syncAdapter);
        controller.setStrategyOrder(ordered);
        uint256 orderLen = controller.strategyOrderLength();
        _step(string.concat("  strategyOrderLength = ", vm.toString(orderLen)));
        assertEq(orderLen, 1);
        _step("  PASS: order set with 1 strategy");

        _step("[Step 4] Replace syncAdapter in order with asyncAdapter");
        controller.registerStrategy(address(asyncAdapter), 10000, 2, true);
        controller.activateStrategy(address(asyncAdapter));

        address[] memory adapters = new address[](2);
        adapters[0] = address(syncAdapter);
        adapters[1] = address(asyncAdapter);
        uint16[] memory weights = new uint16[](2);
        weights[0] = 0;
        weights[1] = 10000;
        uint16[] memory priorities = new uint16[](2);
        priorities[0] = 1;
        priorities[1] = 2;
        bool[] memory isAsyncFlags = new bool[](2);
        isAsyncFlags[0] = false;
        isAsyncFlags[1] = true;

        address[] memory newOrder = new address[](1);
        newOrder[0] = address(asyncAdapter);
        controller.updateStrategiesAndOrder(adapters, weights, priorities, isAsyncFlags, newOrder);

        orderLen = controller.strategyOrderLength();
        _step(string.concat("  strategyOrderLength = ", vm.toString(orderLen)));
        assertEq(orderLen, 1);
        _step("  PASS: syncAdapter removed from order");

        _step("[Step 5] Deactivate syncAdapter (no longer in order, no in-flight)");
        controller.deactivateStrategy(address(syncAdapter));
        (, , , isActive,) = controller.strategyInfo(address(syncAdapter));
        _step(string.concat("  isActive = ", vm.toString(isActive)));
        assertFalse(isActive);
        _step("  PASS: syncAdapter deactivated successfully");

        vm.stopPrank();
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 13. test_DeactivateStrategy_RevertHasInFlight (P0)
    // -----------------------------------------------------------------------

    function test_DeactivateStrategy_RevertHasInFlight() public {
        _logCase("test_DeactivateStrategy_RevertHasInFlight", unicode"有 in-flight 的策略无法停用");

        RealRebalanceStack memory investStack = _deployRealRebalanceStack();
        address investUser = makeAddr("deactivate_invest_user");
        uint256 investDeposit = 10_000e18;

        investStack.asset_.mint(investUser, investDeposit);
        vm.prank(investUser);
        investStack.asset_.approve(address(investStack.vault_), type(uint256).max);

        _step("[Step 1] Create real invest in-flight via deposit -> rebalance");
        vm.prank(investUser);
        investStack.gateway_.deposit(investDeposit);
        vm.prank(bot);
        investStack.executor_.executeRebalance(address(investStack.controller_));

        uint256 pendingInvest = investStack.vault_.adapterInvestInFlightTokens(address(investStack.adapter_));
        assertGt(pendingInvest, 0, "real invest in-flight must exist");
        _movePrimaryRealAdapterOutOfOrder(investStack);
        _step(string.concat("  investInFlight = ", vm.toString(pendingInvest)));

        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyController.Controller__StrategyHasInFlight.selector, address(investStack.adapter_), pendingInvest, 0
            )
        );
        investStack.controller_.deactivateStrategy(address(investStack.adapter_));
        _step("  PASS: reverted as expected (real invest in-flight blocks deactivate)");

        _step("[Step 2] Create real redeem in-flight via settle invest -> requestRedeem -> processRedeemBatch");
        RealRebalanceStack memory redeemStack = _deployRealRebalanceStack();
        address redeemUser = makeAddr("deactivate_redeem_user");
        uint256 redeemDeposit = 20_000e18;
        uint256 redeemRequestShares = 5_000e18;

        redeemStack.asset_.mint(redeemUser, redeemDeposit);
        vm.prank(redeemUser);
        redeemStack.asset_.approve(address(redeemStack.vault_), type(uint256).max);

        vm.prank(redeemUser);
        redeemStack.gateway_.deposit(redeemDeposit);
        vm.prank(bot);
        redeemStack.executor_.executeRebalance(address(redeemStack.controller_));

        uint256 investInFlightId = redeemStack.vault_.nextInFlightId() - 1;
        (,,, uint256 expectedPos,,,,,) = redeemStack.vault_.inFlightRecords(investInFlightId);
        _settleRealInvest(redeemStack, investInFlightId, expectedPos, 0);

        vm.prank(redeemUser);
        uint256 requestId = redeemStack.gateway_.requestRedeem(redeemRequestShares);
        uint256[] memory ids = new uint256[](1);
        ids[0] = requestId;
        vm.prank(bot);
        redeemStack.executor_.executeProcessRedeemBatch(address(redeemStack.controller_), ids);

        uint256 pendingRedeem = redeemStack.vault_.adapterRedeemInFlightUsdc(address(redeemStack.adapter_));
        assertGt(pendingRedeem, 0, "real redeem in-flight must exist");
        _movePrimaryRealAdapterOutOfOrder(redeemStack);
        _step(string.concat("  redeemInFlight = ", vm.toString(pendingRedeem)));

        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyController.Controller__StrategyHasInFlight.selector, address(redeemStack.adapter_), 0, pendingRedeem
            )
        );
        redeemStack.controller_.deactivateStrategy(address(redeemStack.adapter_));
        _step("  PASS: reverted as expected (real redeem in-flight blocks deactivate)");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 14. test_DeactivateStrategy_RevertStillInOrder (P0)
    // -----------------------------------------------------------------------

    function test_DeactivateStrategy_RevertStillInOrder() public {
        _logCase("test_DeactivateStrategy_RevertStillInOrder", unicode"在 order 中的策略无法停用，必须先移出 order");

        _step("[Step 1] Register, activate, and add syncAdapter to order");
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 10000, 1, false);
        controller.activateStrategy(address(syncAdapter));
        address[] memory ordered = new address[](1);
        ordered[0] = address(syncAdapter);
        controller.setStrategyOrder(ordered);
        _step(string.concat("  syncAdapter = ", vm.toString(address(syncAdapter))));
        _step(string.concat("  strategyOrderLength = ", vm.toString(controller.strategyOrderLength())));

        _step("[Step 2] Attempt to deactivate while still in order");
        vm.expectRevert(abi.encodeWithSelector(StrategyController.Controller__StrategyInOrder.selector, address(syncAdapter)));
        controller.deactivateStrategy(address(syncAdapter));
        _step("  PASS: reverted as expected (StrategyInOrder)");
        vm.stopPrank();
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 15. test_ActivateStrategy_RevertAlreadyActive (P1)
    // -----------------------------------------------------------------------

    function test_ActivateStrategy_RevertAlreadyActive() public {
        _logCase("test_ActivateStrategy_RevertAlreadyActive", unicode"激活已激活的策略被拒绝");

        _step("[Step 1] Register and activate syncAdapter");
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 5000, 1, false);
        controller.activateStrategy(address(syncAdapter));
        _step(string.concat("  syncAdapter = ", vm.toString(address(syncAdapter))));

        _step("[Step 2] Attempt to activate again");
        vm.expectRevert(
            abi.encodeWithSelector(StrategyController.Controller__StrategyAlreadyActive.selector, address(syncAdapter))
        );
        controller.activateStrategy(address(syncAdapter));
        _step("  PASS: reverted as expected (StrategyAlreadyActive)");
        vm.stopPrank();
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 16. test_DeactivateStrategy_RevertAlreadyInactive (P1)
    // -----------------------------------------------------------------------

    function test_DeactivateStrategy_RevertAlreadyInactive() public {
        _logCase("test_DeactivateStrategy_RevertAlreadyInactive", unicode"停用已停用的策略被拒绝");

        _step("[Step 1] Register syncAdapter (starts inactive by default)");
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 5000, 1, false);
        (, , , bool isActive,) = controller.strategyInfo(address(syncAdapter));
        _step(string.concat("  isActive = ", vm.toString(isActive)));

        _step("[Step 2] Attempt to deactivate an already inactive strategy");
        vm.expectRevert(
            abi.encodeWithSelector(StrategyController.Controller__StrategyAlreadyInactive.selector, address(syncAdapter))
        );
        controller.deactivateStrategy(address(syncAdapter));
        _step("  PASS: reverted as expected (StrategyAlreadyInactive)");
        vm.stopPrank();
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 17. test_UpdateStrategies_RevertLengthMismatch (P1)
    // -----------------------------------------------------------------------

    function test_UpdateStrategies_RevertLengthMismatch() public {
        _logCase("test_UpdateStrategies_RevertLengthMismatch", unicode"updateStrategies 输入数组长度不一致被拒绝");

        _step("[Step 1] Register syncAdapter");
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 5000, 1, false);
        _step(string.concat("  syncAdapter = ", vm.toString(address(syncAdapter))));

        _step("[Step 2] Prepare mismatched arrays (adapters.length=1, weights.length=2)");
        address[] memory adapters = new address[](1);
        adapters[0] = address(syncAdapter);

        uint16[] memory weights = new uint16[](2); // Mismatched length
        weights[0] = 5000;
        weights[1] = 5000;

        uint16[] memory priorities = new uint16[](1);
        priorities[0] = 1;

        bool[] memory isAsyncFlags = new bool[](1);
        isAsyncFlags[0] = false;
        _step(string.concat("  adapters.length = ", vm.toString(uint256(1))));
        _step(string.concat("  weights.length = ", vm.toString(uint256(2))));

        _step("[Step 3] Attempt updateStrategies with mismatched lengths");
        vm.expectRevert(StrategyController.Controller__UpdateStrategiesLengthMismatch.selector);
        controller.updateStrategies(adapters, weights, priorities, isAsyncFlags);
        _step("  PASS: reverted as expected (UpdateStrategiesLengthMismatch)");
        vm.stopPrank();
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 18. test_UpdateStrategies_RevertDuplicate (P1)
    // -----------------------------------------------------------------------

    function test_UpdateStrategies_RevertDuplicate() public {
        _logCase("test_UpdateStrategies_RevertDuplicate", unicode"updateStrategies 含重复 adapter 被拒绝");

        _step("[Step 1] Register syncAdapter");
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 5000, 1, false);
        _step(string.concat("  syncAdapter = ", vm.toString(address(syncAdapter))));

        _step("[Step 2] Prepare arrays with duplicate adapter entries");
        address[] memory adapters = new address[](2);
        adapters[0] = address(syncAdapter);
        adapters[1] = address(syncAdapter); // Duplicate
        _step(string.concat("  adapters[0] = adapters[1] = ", vm.toString(address(syncAdapter))));

        uint16[] memory weights = new uint16[](2);
        weights[0] = 5000;
        weights[1] = 5000;

        uint16[] memory priorities = new uint16[](2);
        priorities[0] = 1;
        priorities[1] = 1;

        bool[] memory isAsyncFlags = new bool[](2);
        isAsyncFlags[0] = false;
        isAsyncFlags[1] = false;

        _step("[Step 3] Attempt updateStrategies with duplicate adapter");
        vm.expectRevert(
            abi.encodeWithSelector(StrategyController.Controller__DuplicateStrategyUpdate.selector, address(syncAdapter))
        );
        controller.updateStrategies(adapters, weights, priorities, isAsyncFlags);
        _step("  PASS: reverted as expected (DuplicateStrategyUpdate)");
        vm.stopPrank();
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 19. test_SetAdapterPaused_OnlyPauser (P1)
    // -----------------------------------------------------------------------

    function test_SetAdapterPaused_OnlyPauser() public {
        _logCase("test_SetAdapterPaused_OnlyPauser", unicode"setAdapterPaused 仅 PAUSER_ROLE 可调用");

        _step("[Step 1] Register syncAdapter");
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 5000, 1, false);
        vm.stopPrank();
        _step(string.concat("  syncAdapter = ", vm.toString(address(syncAdapter))));

        _step("[Step 2] Non-pauser attempts to pause adapter");
        _step(string.concat("  nonAdmin = ", vm.toString(nonAdmin)));
        bytes32 pauserRole = controller.PAUSER_ROLE();
        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nonAdmin, pauserRole));
        controller.setAdapterPaused(address(syncAdapter), true);
        _step("  PASS: reverted as expected (access control)");

        _step("[Step 3] Pauser (manager) pauses adapter");
        vm.prank(manager);
        controller.setAdapterPaused(address(syncAdapter), true);
        bool pausedState = syncAdapter.paused();
        _step(string.concat("  syncAdapter.paused() = ", vm.toString(pausedState)));
        assertTrue(pausedState);
        _step("  PASS: adapter is paused");

        _step("[Step 4] Pauser unpauses adapter");
        vm.prank(manager);
        controller.setAdapterPaused(address(syncAdapter), false);
        pausedState = syncAdapter.paused();
        _step(string.concat("  syncAdapter.paused() = ", vm.toString(pausedState)));
        assertFalse(pausedState);
        _step("  PASS: adapter is unpaused");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 20. test_SetAdaptersPaused_BatchSuccess (P1)
    // -----------------------------------------------------------------------

    function test_SetAdaptersPaused_BatchSuccess() public {
        _logCase("test_SetAdaptersPaused_BatchSuccess", unicode"setAdaptersPaused 可批量暂停多个 adapter");

        _step("[Step 1] Register both adapters");
        vm.startPrank(manager);
        controller.registerStrategy(address(syncAdapter), 5000, 1, false);
        controller.registerStrategy(address(asyncAdapter), 5000, 2, true);
        vm.stopPrank();
        _step(string.concat("  syncAdapter = ", vm.toString(address(syncAdapter))));
        _step(string.concat("  asyncAdapter = ", vm.toString(address(asyncAdapter))));

        address[] memory adapters = new address[](2);
        adapters[0] = address(syncAdapter);
        adapters[1] = address(asyncAdapter);

        _step("[Step 2] Batch pause both adapters");
        vm.prank(manager);
        controller.setAdaptersPaused(adapters, true);
        _step(string.concat("  syncAdapter.paused() = ", vm.toString(syncAdapter.paused())));
        _step(string.concat("  asyncAdapter.paused() = ", vm.toString(asyncAdapter.paused())));
        assertTrue(syncAdapter.paused());
        assertTrue(asyncAdapter.paused());
        _step("  PASS: both adapters paused");

        _step("[Step 3] Batch unpause both adapters");
        vm.prank(manager);
        controller.setAdaptersPaused(adapters, false);
        _step(string.concat("  syncAdapter.paused() = ", vm.toString(syncAdapter.paused())));
        _step(string.concat("  asyncAdapter.paused() = ", vm.toString(asyncAdapter.paused())));
        assertFalse(syncAdapter.paused());
        assertFalse(asyncAdapter.paused());
        _step("  PASS: both adapters unpaused");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 21. test_SetAdaptersPaused_RevertUnregistered (P1)
    // -----------------------------------------------------------------------

    function test_SetAdaptersPaused_RevertUnregistered() public {
        _logCase("test_SetAdaptersPaused_RevertUnregistered", unicode"setAdaptersPaused 批量暂停中包含未注册 adapter 时整体回滚");

        _step("[Step 1] Attempt batch pause with unregistered adapter");
        _step(string.concat("  syncAdapter (unregistered) = ", vm.toString(address(syncAdapter))));
        address[] memory adapters = new address[](1);
        adapters[0] = address(syncAdapter);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(StrategyController.Controller__InvalidStrategy.selector, address(syncAdapter)));
        controller.setAdaptersPaused(adapters, true);
        _step("  PASS: reverted as expected (InvalidStrategy)");

        _step("[Step 2] Attempt single pause with unregistered adapter");
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(StrategyController.Controller__InvalidStrategy.selector, address(syncAdapter)));
        controller.setAdapterPaused(address(syncAdapter), true);
        _step("  PASS: reverted as expected (InvalidStrategy)");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 22. test_UpdateStrategies_RevertNotExists (P1)
    // -----------------------------------------------------------------------

    function test_UpdateStrategies_RevertNotExists() public {
        _logCase("test_UpdateStrategies_RevertNotExists", unicode"updateStrategies 更新不存在的策略被拒绝");

        _step("[Step 1] Prepare update for unregistered syncAdapter");
        _step(string.concat("  syncAdapter (unregistered) = ", vm.toString(address(syncAdapter))));
        address[] memory adapters = new address[](1);
        adapters[0] = address(syncAdapter);

        uint16[] memory weights = new uint16[](1);
        weights[0] = 10000;

        uint16[] memory priorities = new uint16[](1);
        priorities[0] = 1;

        bool[] memory isAsyncFlags = new bool[](1);
        isAsyncFlags[0] = false;

        _step("[Step 2] Attempt updateStrategies for non-existent strategy");
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(StrategyController.Controller__InvalidStrategy.selector, address(syncAdapter)));
        controller.updateStrategies(adapters, weights, priorities, isAsyncFlags);
        _step("  PASS: reverted as expected (InvalidStrategy)");
        _logPass();
    }

    // -----------------------------------------------------------------------
    // 23. test_PreviewRebalance_MatchesActualRebalance (P1)
    // -----------------------------------------------------------------------

    function test_PreviewRebalance_MatchesActualRebalance() public {
        _logCase("test_PreviewRebalance_MatchesActualRebalance", unicode"getRebalanceState / previewRebalance 与实际 rebalance 决策一致");

        RealRebalanceStack memory s = _deployRealRebalanceStack();
        address userA = makeAddr("preview_user_a");
        uint256 depositAmount = 100_000e18;

        s.asset_.mint(userA, depositAmount);
        vm.prank(userA);
        s.asset_.approve(address(s.vault_), type(uint256).max);

        _step("[Setup] Use real gateway deposit so vault cash comes from actual user flow");
        vm.prank(userA);
        s.gateway_.deposit(depositAmount);
        _step(string.concat("  userA deposited = ", vm.toString(depositAmount)));

        _step("[Step 1] Call getRebalanceState() to inspect current state");
        (
            uint256 totalCash,
            uint256 freeCash,
            uint256 idealCash,
            uint256 netAssets,
            uint256 targetCash,
            uint256 threshold,
            bool hasPendingRequest
        ) = s.controller_.getRebalanceState();
        // Derive `locked` for log compatibility (locked = totalCash - freeCash).
        uint256 locked = totalCash - freeCash;
        _step(string.concat("  totalCash   = ", vm.toString(totalCash)));
        _step(string.concat("  locked      = ", vm.toString(locked)));
        _step(string.concat("  freeCash    = ", vm.toString(freeCash)));
        _step(string.concat("  idealCash   = ", vm.toString(idealCash)));
        _step(string.concat("  netAssets   = ", vm.toString(netAssets)));
        _step(string.concat("  targetCash  = ", vm.toString(targetCash)));
        _step(string.concat("  threshold   = ", vm.toString(threshold)));
        _step(string.concat("  hasPending  = ", vm.toString(hasPendingRequest)));

        _step("[Step 2] Call previewRebalance() to get expected action");
        (bool shouldRebalance, uint8 action, uint256 amount) = s.controller_.previewRebalance();
        _step(string.concat("  shouldRebalance = ", vm.toString(shouldRebalance)));
        _step(string.concat("  action          = ", vm.toString(uint256(action))));
        _step(string.concat("  amount          = ", vm.toString(amount)));

        // With bufferTargetBps=1000 (10%) and rebalanceThresholdBps=200 (2%):
        // targetCash = netAssets * 10% ; threshold = netAssets * 2%
        // idealCash == freeCash == totalCash (locked=0, redeemInFlight=0) which is far above targetCash + threshold => INVEST
        assertTrue(shouldRebalance, "shouldRebalance must be true");
        assertEq(action, s.controller_.REBALANCE_ACTION_INVEST(), "action must be INVEST");
        assertGt(amount, 0, "invest amount must be > 0");
        _step("  PASS: previewRebalance indicates INVEST with amount > 0");

        // Manually compute expected values to cross-check
        uint256 expectedAction;
        uint256 expectedAmount;
        if (idealCash > targetCash + threshold) {
            expectedAction = 1; // INVEST
            uint256 surplus = idealCash - targetCash;
            expectedAmount = surplus > freeCash ? freeCash : surplus;
        } else if (idealCash + threshold < targetCash && !hasPendingRequest) {
            expectedAction = 2; // DIVEST
            expectedAmount = targetCash - idealCash;
        }
        assertEq(action, expectedAction, "action must match manual computation");
        assertEq(amount, expectedAmount, "amount must match manual computation");
        _step("  PASS: preview values match manual computation from getRebalanceState");

        _step("[Step 3] Execute rebalance() and verify it matches preview");
        // Record vault balance before rebalance to verify actual invest/divest via real state
        uint256 vaultBalBefore = s.asset_.balanceOf(address(s.vault_));

        vm.prank(bot);
        s.executor_.executeRebalance(address(s.controller_));
        _step("  rebalance() executed successfully");

        uint256 vaultBalAfter = s.asset_.balanceOf(address(s.vault_));

        if (action == s.controller_.REBALANCE_ACTION_INVEST()) {
            // Vault USDC must decrease (funds moved to adapters)
            assertLt(vaultBalAfter, vaultBalBefore, "vault balance must decrease for INVEST");
            _step(string.concat("  vault balance decreased: ", vm.toString(vaultBalBefore), " -> ", vm.toString(vaultBalAfter)));
            assertGt(s.vault_.totalInvestInFlight(), 0, "real invest should create invest in-flight");
            _step("  PASS: rebalance performed INVEST as predicted by previewRebalance");
        } else if (action == s.controller_.REBALANCE_ACTION_DIVEST()) {
            // Vault USDC must increase (funds returned from adapters)
            assertGt(vaultBalAfter, vaultBalBefore, "vault balance must increase for DIVEST");
            _step(string.concat("  vault balance increased: ", vm.toString(vaultBalBefore), " -> ", vm.toString(vaultBalAfter)));
            _step("  PASS: rebalance performed DIVEST as predicted by previewRebalance");
        } else {
            // No-op: vault balance should remain unchanged
            assertEq(vaultBalAfter, vaultBalBefore, "vault balance must not change for no-op");
            _step("  PASS: rebalance performed NO-OP as predicted by previewRebalance");
        }

        _logPass();
    }

    // -----------------------------------------------------------------------
    // 24. test_GetRebalanceState_FieldsComputedCorrectly (P0, N-19)
    // -----------------------------------------------------------------------

    function test_GetRebalanceState_FieldsComputedCorrectly() public {
        _logCase(
            "test_GetRebalanceState_FieldsComputedCorrectly",
            unicode"getRebalanceState() 返回的每个字段均按新公式计算正确"
        );

        RealRebalanceStack memory s = _deployRealRebalanceStack();
        address userA = makeAddr("state_user_a");
        address userB = makeAddr("state_user_b");

        uint256 initialDeposit = 100_000e18;
        uint256 secondDeposit = 30_000e18;
        uint256 firstRedeemShares = 15_000e18;
        uint256 secondRedeemShares = 5_000e18;

        s.asset_.mint(userA, initialDeposit);
        s.asset_.mint(userB, secondDeposit);

        vm.prank(userA);
        s.asset_.approve(address(s.vault_), type(uint256).max);
        vm.prank(userB);
        s.asset_.approve(address(s.vault_), type(uint256).max);

        _step("[Step 1] Build rebalance state via real deposit -> invest -> settle -> request -> process flow");

        vm.prank(userA);
        s.gateway_.deposit(initialDeposit);
        _step(string.concat("  userA deposited = ", vm.toString(initialDeposit)));

        vm.prank(bot);
        s.executor_.executeRebalance(address(s.controller_));
        uint256 settledInvestId = s.vault_.nextInFlightId() - 1;
        (,,, uint256 settledExpectedPos,,,,,) = s.vault_.inFlightRecords(settledInvestId);
        _settleRealInvest(s, settledInvestId, settledExpectedPos, 0);
        _step(string.concat("  first invest settled pos = ", vm.toString(settledExpectedPos)));

        vm.prank(userB);
        s.gateway_.deposit(secondDeposit);
        _step(string.concat("  userB deposited = ", vm.toString(secondDeposit)));

        vm.prank(bot);
        s.executor_.executeRebalance(address(s.controller_));
        uint256 pendingInvestId = s.vault_.nextInFlightId() - 1;
        _step(string.concat("  pending invest inFlightId = ", vm.toString(pendingInvestId)));

        vm.prank(userA);
        uint256 requestId1 = s.gateway_.requestRedeem(firstRedeemShares);
        vm.prank(userB);
        uint256 requestId2 = s.gateway_.requestRedeem(secondRedeemShares);
        _step(string.concat("  requestId1 (to process) = ", vm.toString(requestId1)));
        _step(string.concat("  requestId2 (kept pending) = ", vm.toString(requestId2)));

        uint256[] memory ids = new uint256[](1);
        ids[0] = requestId1;
        vm.prank(bot);
        s.executor_.executeProcessRedeemBatch(address(s.controller_), ids);
        _step("  processed requestId1 to create redeem in-flight");

        uint256 adapterValue = s.adapter_.totalValue();
        uint256 investInFlight = s.vault_.totalInvestInFlight();
        uint256 redeemInFlight = s.vault_.totalRedeemInFlight();
        uint256 pendingCount = s.vault_.pendingRequestCount();
        _step(string.concat("  adapter totalValue settled on vault = ", vm.toString(adapterValue)));
        _step(string.concat("  totalInvestInFlight = ", vm.toString(investInFlight)));
        _step(string.concat("  totalRedeemInFlight = ", vm.toString(redeemInFlight)));
        _step(string.concat("  pendingRequestCount = ", vm.toString(pendingCount)));

        assertGt(adapterValue, 0, "adapter value must come from settled invest");
        assertGt(investInFlight, 0, "invest in-flight must come from real rebalance");
        assertGt(redeemInFlight, 0, "redeem in-flight must come from real processRedeemBatch");
        assertGt(pendingCount, 0, "one request should remain pending");

        _step("[Step 2] Query real vault state directly for expected values");
        uint256 expectedTotalCash = s.asset_.balanceOf(address(s.vault_));
        uint256 expectedFreeCash = s.vault_.getFreeCash();
        uint256 expectedRedeemInFlight = s.vault_.totalRedeemInFlight();
        uint256 expectedIdealCash = expectedFreeCash + expectedRedeemInFlight;
        uint256 expectedNetAssets = s.vault_.totalAssets();
        uint256 expectedCashDeficit = s.vault_.getCashDeficit();
        uint256 bufBps = s.controller_.bufferTargetBps();
        uint256 rebalBps = s.controller_.rebalanceThresholdBps();
        uint256 expectedTargetCash = (expectedNetAssets * bufBps) / 10000 + expectedCashDeficit;
        uint256 expectedThreshold = (expectedNetAssets * rebalBps) / 10000;
        _step(string.concat("  expectedTotalCash  = ", vm.toString(expectedTotalCash)));
        _step(string.concat("  expectedFreeCash   = ", vm.toString(expectedFreeCash)));
        _step(string.concat("  expectedIdealCash  = ", vm.toString(expectedIdealCash)));
        _step(string.concat("  expectedNetAssets  = ", vm.toString(expectedNetAssets)));
        _step(string.concat("  expectedTargetCash = ", vm.toString(expectedTargetCash)));
        _step(string.concat("  expectedThreshold  = ", vm.toString(expectedThreshold)));
        _step(string.concat("  expectedCashDeficit = ", vm.toString(expectedCashDeficit)));

        _step("[Step 3] Call controller.getRebalanceState() and verify all 7 fields");
        (
            uint256 totalCash,
            uint256 freeCash,
            uint256 idealCash,
            uint256 netAssets,
            uint256 targetCash,
            uint256 threshold,
            bool hasPendingRequest
        ) = s.controller_.getRebalanceState();

        _step(string.concat("  [1] totalCash     = ", vm.toString(totalCash)));
        assertEq(totalCash, expectedTotalCash, "totalCash = asset.balanceOf(real vault)");
        _step("    PASS: totalCash = asset.balanceOf(real vault)");

        _step(string.concat("  [2] freeCash      = ", vm.toString(freeCash)));
        assertEq(freeCash, expectedFreeCash, "freeCash = vault.getFreeCash()");
        _step("    PASS: freeCash = real vault.getFreeCash()");

        _step(string.concat("  [3] idealCash     = ", vm.toString(idealCash)));
        assertEq(idealCash, expectedIdealCash, "idealCash = freeCash + totalRedeemInFlight");
        _step("    PASS: idealCash = freeCash + real vault.totalRedeemInFlight()");

        _step(string.concat("  [4] netAssets     = ", vm.toString(netAssets)));
        assertEq(netAssets, expectedNetAssets, "netAssets = vault.totalAssets()");
        _step("    PASS: netAssets = real vault.totalAssets()");

        _step(string.concat("  [5] targetCash    = ", vm.toString(targetCash)));
        assertEq(targetCash, expectedTargetCash, "targetCash = netAssets * bufferBps / 10000 + cashDeficit");
        _step("    PASS: targetCash = (netAssets * bufferTargetBps / 10000) + real vault.getCashDeficit()");

        _step(string.concat("  [6] threshold     = ", vm.toString(threshold)));
        assertEq(threshold, expectedThreshold, "threshold = netAssets * rebalanceBps / 10000");
        _step("    PASS: threshold = netAssets * rebalanceThresholdBps / 10000");

        _step(string.concat("  [7] hasPending    = ", vm.toString(hasPendingRequest)));
        assertTrue(hasPendingRequest, "hasPendingRequest must be true when pendingRequestCount > 0");
        _step("    PASS: hasPendingRequest = true (one real request remains PENDING)");

        _logPass();
    }
}
