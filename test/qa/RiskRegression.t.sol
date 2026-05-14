// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategyAdapter} from "../../src/interfaces/adapters/IStrategyAdapter.sol";
import {IStrategyControllerExecutor} from "../../src/interfaces/strategy/IStrategyControllerExecutor.sol";
import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {IMantleVaultGateway} from "../../src/interfaces/vault/IMantleVaultGateway.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {Accountant} from "../../src/accountant/Accountant.sol";
import {SanctionsOracle} from "../../src/compliance/SanctionsOracle.sol";
import {SanctionsOracleFactory} from "../../src/compliance/SanctionsOracleFactory.sol";
import {SubRedManagementAdapter} from "../../src/adapters/digift/SubRedManagementAdapter.sol";
import {MockDFeedPriceOracle} from "../../src/mocks/strategy/MockDFeedPriceOracle.sol";
import {MantleVaultGateway} from "../../src/vault/MantleVaultGateway.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {GatewayFactory} from "../../src/vault/GatewayFactory.sol";
import {VaultFactory} from "../../src/vault/VaultFactory.sol";
import {OperatorExecutor} from "../../src/protocol/OperatorExecutor.sol";
import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test, console2} from "forge-std/Test.sol";

// =============================================================
// Mock contracts (same pattern as StrategyController.t.sol)
// =============================================================

contract MockAsset is ERC20 {
    constructor() ERC20("MockAsset", "mAST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract MockSettlementVenueRR {
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

    function settleInvest(address adapter, uint256 posAmount, uint256 refundAssetAmount) external {
        uint256 pending = pendingInvestAsset[adapter];
        require(posAmount + refundAssetAmount <= pending, "INVEST_SETTLE_EXCEEDS_PENDING");
        pendingInvestAsset[adapter] = pending - posAmount - refundAssetAmount;

        if (posAmount > 0) {
            ASSET.burn(address(this), posAmount);
            POS_TOKEN.mint(adapter, posAmount);
        }
        if (refundAssetAmount > 0) {
            IERC20(address(ASSET)).transfer(adapter, refundAssetAmount);
        }
    }

    function acceptRedeem(address adapter, uint256 posAmount) external {
        pendingRedeemPos[adapter] += posAmount;
    }

    function settleRedeem(address adapter, uint256 assetAmount) external {
        uint256 pending = pendingRedeemPos[adapter];
        pendingRedeemPos[adapter] = 0;

        if (pending > 0) {
            POS_TOKEN.burn(address(this), pending);
        }
        if (assetAmount > 0) {
            ASSET.mint(adapter, assetAmount);
        }
    }
}

contract MockAdapterRR is IStrategyAdapter {
    address public immutable ASSET;
    address public immutable POS_TOKEN;
    address public immutable VAULT;
    MockSettlementVenueRR public immutable SETTLEMENT_VENUE;

    constructor(address asset_, address posToken_, address vault_, address settlementVenue_) {
        ASSET = asset_;
        POS_TOKEN = posToken_;
        VAULT = vault_;
        SETTLEMENT_VENUE = MockSettlementVenueRR(settlementVenue_);
    }

    function name() external pure returns (string memory) { return "MockAdapterRR"; }
    function asset() external view returns (address) { return ASSET; }
    function posToken() external view returns (address) { return POS_TOKEN; }
    function priceOracle() external pure returns (address) { return address(0); }
    function getPosTokenPrice() external pure returns (uint256) { return 1e18; }
    function estimatePosAmount(uint256 assetAmount) external pure returns (uint256 positionAmount) { return assetAmount; }
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

    function vault() external view returns (address) { return VAULT; }

    function totalValue() external view returns (uint256) {
        return IERC20(POS_TOKEN).balanceOf(VAULT);
    }

    function deposit(uint256 amount, address) external returns (uint256 sharesOrPos) {
        IERC20(ASSET).transferFrom(VAULT, address(this), amount);
        IERC20(ASSET).transfer(address(SETTLEMENT_VENUE), amount);
        SETTLEMENT_VENUE.acceptInvest(address(this), amount);
        return amount;
    }

    function withdrawSync(uint256 amount, address) external returns (uint256 actualUSDC) {
        ERC20(POS_TOKEN).transferFrom(VAULT, address(this), amount);
        ERC20(ASSET).transfer(VAULT, amount);
        return amount;
    }

    function requestRedeemAsync(uint256 amount, address) external {
        IERC20(POS_TOKEN).transferFrom(VAULT, address(this), amount);
        IERC20(POS_TOKEN).transfer(address(SETTLEMENT_VENUE), amount);
        SETTLEMENT_VENUE.acceptRedeem(address(this), amount);
    }

    function retryRedeemAsync(uint256, address) external {}

    function sweepToVault(address token, uint256 amount) external returns (uint256 claimed) {
        uint256 balance = ERC20(token).balanceOf(address(this));
        claimed = balance < amount ? balance : amount;
        if (claimed > 0) {
            ERC20(token).transfer(VAULT, claimed);
        }
    }

    function setPaused(bool) external {}
}

contract MockPricedAdapterRR is IStrategyAdapter {
    address public immutable ASSET;
    address public immutable POS_TOKEN;
    address public immutable VAULT;
    MockSettlementVenueRR public immutable SETTLEMENT_VENUE;
    MockDFeedPriceOracle public immutable PRICE_ORACLE;

    constructor(address asset_, address posToken_, address vault_, address settlementVenue_, address priceOracle_) {
        ASSET = asset_;
        POS_TOKEN = posToken_;
        VAULT = vault_;
        SETTLEMENT_VENUE = MockSettlementVenueRR(settlementVenue_);
        PRICE_ORACLE = MockDFeedPriceOracle(priceOracle_);
    }

    function name() external pure returns (string memory) { return "MockPricedAdapterRR"; }
    function asset() external view returns (address) { return ASSET; }
    function posToken() external view returns (address) { return POS_TOKEN; }
    function priceOracle() external view returns (address) { return address(PRICE_ORACLE); }

    function getPosTokenPrice() public view returns (uint256) {
        uint8 oracleDecimals = PRICE_ORACLE.decimals();
        return Math.mulDiv(PRICE_ORACLE.getPrice(), 1e18, 10 ** oracleDecimals, Math.Rounding.Floor);
    }

    function estimatePosAmount(uint256 assetAmount) public view returns (uint256 positionAmount) {
        uint256 priceE18 = getPosTokenPrice();
        if (assetAmount == 0 || priceE18 == 0) {
            return 0;
        }
        return Math.mulDiv(assetAmount, 1e18, priceE18, Math.Rounding.Floor);
    }

    function minSubscribeAsset() external pure returns (uint256) { return 0; }
    function minRedeemPos() external pure returns (uint256) { return 0; }

    function previewDeposit(uint256 assetAmount)
        external
        view
        returns (bool ok, uint256 executableAssetAmount, uint256 expectedPosAmount)
    {
        ok = assetAmount > 0;
        executableAssetAmount = assetAmount;
        expectedPosAmount = estimatePosAmount(assetAmount);
    }

    function previewRedeem(uint256 assetAmount)
        external
        view
        returns (bool ok, uint256 executableAssetAmount, uint256 expectedPosAmount)
    {
        expectedPosAmount = estimatePosAmount(assetAmount);
        ok = assetAmount > 0 && expectedPosAmount > 0;
        executableAssetAmount = ok ? assetAmount : 0;
    }

    function vault() external view returns (address) { return VAULT; }

    function totalValue() external view returns (uint256) {
        uint256 settledVaultPos = IERC20(POS_TOKEN).balanceOf(VAULT);
        uint256 priceE18 = getPosTokenPrice();
        if (settledVaultPos == 0 || priceE18 == 0) {
            return 0;
        }
        return Math.mulDiv(settledVaultPos, priceE18, 1e18, Math.Rounding.Floor);
    }

    function deposit(uint256 amount, address) external returns (uint256 sharesOrPos) {
        IERC20(ASSET).transferFrom(VAULT, address(this), amount);
        IERC20(ASSET).transfer(address(SETTLEMENT_VENUE), amount);
        SETTLEMENT_VENUE.acceptInvest(address(this), amount);
        return estimatePosAmount(amount);
    }

    function withdrawSync(uint256 amount, address) external returns (uint256 actualUSDC) {
        ERC20(POS_TOKEN).transferFrom(VAULT, address(this), amount);
        ERC20(ASSET).transfer(VAULT, amount);
        return amount;
    }

    function requestRedeemAsync(uint256 amount, address) external {
        IERC20(POS_TOKEN).transferFrom(VAULT, address(this), amount);
        IERC20(POS_TOKEN).transfer(address(SETTLEMENT_VENUE), amount);
        SETTLEMENT_VENUE.acceptRedeem(address(this), amount);
    }

    function retryRedeemAsync(uint256, address) external {}

    function sweepToVault(address token, uint256 amount) external returns (uint256 claimed) {
        uint256 balance = ERC20(token).balanceOf(address(this));
        claimed = balance < amount ? balance : amount;
        if (claimed > 0) {
            ERC20(token).transfer(VAULT, claimed);
        }
    }

    function setPaused(bool) external {}
}

contract MockVaultRR {
    ERC20 public immutable token;
    uint256 public mockedExchangeRate = 1e18;

    uint256 public investInFlightTotal;
    uint256 public redeemInFlightTotal;
    uint256 public inFlightIdCursor;
    uint256 public nextRequestId = 1;
    uint256 public pendingRequestCount;
    uint256 public totalLockedSharesValue;
    mapping(address => uint256) public investInFlightByAdapter;
    mapping(address => uint256) public redeemInFlightByAdapter;
    mapping(address => bool) public isAdapterRegistry;
    mapping(address => uint256) public sharesOf;
    address[] public adapterList;

    struct Req {
        address owner;
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

    function asset() external view returns (address) { return address(token); }
    function share() external view returns (address) { return address(this); }
    function totalLockedShares() external view returns (uint256) { return totalLockedSharesValue; }

    function depositFor(address sender, uint256 assets, address receiver) external returns (uint256 shares) {
        shares = (assets * 1e18) / mockedExchangeRate;
        sharesOf[receiver] += shares;
        token.transferFrom(sender, address(this), assets);
    }

    function requestRedeemFor(address, address owner, uint256 shares) external returns (uint256 requestId) {
        require(sharesOf[owner] >= shares, "INSUFFICIENT_SHARES");
        sharesOf[owner] -= shares;
        totalLockedSharesValue += shares;

        requestId = nextRequestId++;
        uint256 estimatedAssets = (shares * mockedExchangeRate) / 1e18;
        reqs[requestId] = Req({
            owner: owner,
            shares: shares,
            estimatedAssets: estimatedAssets,
            settledAssets: 0,
            status: IMantleYieldVault.RequestStatus.PENDING
        });
        pendingRequestCount++;
    }

    function exchangeRate() external view returns (uint256) { return mockedExchangeRate; }

    function totalLockedLiabilities() external view returns (uint256) {
        return (totalLockedSharesValue * mockedExchangeRate) / 1e18;
    }

    function totalAssets() external view returns (uint256) {
        uint256 total = token.balanceOf(address(this)) + investInFlightTotal + redeemInFlightTotal;
        for (uint256 i = 0; i < adapterList.length; i++) {
            address pt = IStrategyAdapter(adapterList[i]).posToken();
            uint256 priceE18 = IStrategyAdapter(adapterList[i]).getPosTokenPrice();
            uint256 ptBal = IERC20(pt).balanceOf(address(this));
            total += (ptBal * priceE18) / 1e18;
        }
        uint256 floatingLocked = (totalLockedSharesValue * mockedExchangeRate) / 1e18;
        return total > floatingLocked ? total - floatingLocked : 0;
    }

    function totalInvestInFlight() external view returns (uint256) { return investInFlightTotal; }
    function totalRedeemInFlight() external view returns (uint256) { return redeemInFlightTotal; }
    function adapterInvestInFlightTokens(address adapter) external view returns (uint256) { return investInFlightByAdapter[adapter]; }
    function adapterRedeemInFlightUsdc(address adapter) external view returns (uint256) { return redeemInFlightByAdapter[adapter]; }

    function getFreeCash() external view returns (uint256) {
        uint256 totalCash = token.balanceOf(address(this));
        uint256 floatingLocked = (totalLockedSharesValue * mockedExchangeRate) / 1e18;
        return totalCash > floatingLocked ? totalCash - floatingLocked : 0;
    }

    function getCashDeficit() external view returns (uint256) {
        uint256 totalCash = token.balanceOf(address(this));
        uint256 floatingLocked = (totalLockedSharesValue * mockedExchangeRate) / 1e18;
        return floatingLocked > totalCash ? floatingLocked - totalCash : 0;
    }

    function approveToAdapter(address adapter, address approveToken, uint256 amount) external {
        ERC20(approveToken).approve(adapter, amount);
    }

    function isAdapter(address adapter) external view returns (bool) { return isAdapterRegistry[adapter]; }

    function registerAdapter(address adapter) external {
        if (!isAdapterRegistry[adapter]) {
            isAdapterRegistry[adapter] = true;
            adapterList.push(adapter);
        }
    }

    function removeAdapter(address adapter) external {
        require(investInFlightByAdapter[adapter] == 0 && redeemInFlightByAdapter[adapter] == 0, "HAS_IN_FLIGHT");
        isAdapterRegistry[adapter] = false;
    }

    function updateRequestBatch(uint256[] calldata ids, IMantleYieldVault.RequestStatus newStatus) external {
        for (uint256 i = 0; i < ids.length; i++) {
            if (
                reqs[ids[i]].status == IMantleYieldVault.RequestStatus.PENDING
                    && newStatus != IMantleYieldVault.RequestStatus.PENDING
                    && pendingRequestCount > 0
            ) {
                pendingRequestCount--;
            }
            reqs[ids[i]].status = newStatus;
        }
    }

    function markRequestsDone(uint256[] calldata ids, uint256[] calldata settledAssets) external {
        uint256 physicalCash = token.balanceOf(address(this));
        uint256 releasedShares;
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            if (reqs[id].status != IMantleYieldVault.RequestStatus.PROCESSING) {
                revert IMantleYieldVault.Vault__InvalidState(id, reqs[id].status);
            }
            uint256 actual = settledAssets[i];
            if (physicalCash < actual) {
                revert IMantleYieldVault.Vault__InsufficientPhysicalCash(ids, settledAssets, token.balanceOf(address(this)));
            }
            reqs[id].settledAssets = actual;
            reqs[id].status = IMantleYieldVault.RequestStatus.DONE;
            physicalCash -= actual;
            releasedShares += reqs[id].shares;
            token.transfer(reqs[id].owner, actual);
        }
        totalLockedSharesValue -= releasedShares;
    }

    function createInFlight(address adapter, address assetAddr, uint256 tokenAmount, uint256 usdcAmount, bool isInvest)
        external
        returns (uint256 inFlightId)
    {
        inFlightId = ++inFlightIdCursor;
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

    error Vault__InvalidInFlightState(uint256 inFlightId, IMantleYieldVault.InFlightStatus currentStatus);

    function confirmInFlight(uint256 inFlightId_, uint256 actualAmount, bool) external {
        InFlight storage f = flights[inFlightId_];
        if (f.status != IMantleYieldVault.InFlightStatus.PENDING) {
            revert Vault__InvalidInFlightState(inFlightId_, f.status);
        }
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
        return (requestId, r.owner, r.shares, 0, r.estimatedAssets, r.settledAssets, 0, r.status);
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

// =============================================================
// Risk Regression Tests - In-flight settlement edge cases
// =============================================================

contract RiskRegressionTest is Test {
    MockAsset internal flowAsset;
    MockAsset internal flowPosToken;
    MockAsset internal flowPosToken2;
    MockSettlementVenueRR internal flowVenue;
    MockSettlementVenueRR internal flowVenue2;
    SanctionsOracle internal flowSanctionsOracle;
    Accountant internal flowAccountant;
    MantleYieldVault internal flowVault;
    MantleVaultGateway internal flowGateway;
    StrategyController internal flowController;
    OperatorExecutor internal flowOperatorExecutor;
    MockAdapterRR internal flowAsyncAdapter;
    MockAdapterRR internal flowAsyncAdapter2;

    address internal admin = makeAddr("admin");
    address internal bot = makeAddr("bot");
    address internal flowUser = makeAddr("flowUser");
    address internal treasury = makeAddr("treasury");
    address internal complianceBot = makeAddr("complianceBot");

    function setUp() public {
        flowAsset = new MockAsset();
        flowPosToken = new MockAsset();
        flowPosToken2 = new MockAsset();
        flowVenue = new MockSettlementVenueRR(address(flowAsset), address(flowPosToken));
        flowVenue2 = new MockSettlementVenueRR(address(flowAsset), address(flowPosToken2));

        SanctionsOracle oracleImpl = new SanctionsOracle();
        SanctionsOracleFactory oracleFactory = new SanctionsOracleFactory(address(oracleImpl), admin);
        vm.prank(admin);
        flowSanctionsOracle = SanctionsOracle(oracleFactory.deployAndInitOracle(admin, complianceBot));

        MantleYieldVault vaultImpl = new MantleYieldVault();
        MantleVaultGateway gatewayImpl = new MantleVaultGateway();
        VaultFactory vaultFactory = new VaultFactory(address(vaultImpl), admin);
        GatewayFactory gatewayFactory = new GatewayFactory(address(gatewayImpl), admin);

        address vaultAddr = vaultFactory.deployVault();
        address gatewayAddr = gatewayFactory.deployGateway();
        flowVault = MantleYieldVault(vaultAddr);
        flowGateway = MantleVaultGateway(gatewayAddr);

        IMantleYieldVault.InitParams memory params = IMantleYieldVault.InitParams({
            asset: IERC20(address(flowAsset)),
            name: "Flow Vault",
            symbol: "fMRA",
            admin: admin,
            gateway: gatewayAddr,
            controller: address(1),
            accountant: address(1),
            treasury: treasury,
            maxRedemptionFeeBps: 500,
            redemptionFeeBps: 0,
            minRedeemAmount: 0,
            minDepositAmount: 0,
            maxSettlementDeviationBps: 0,
            depositDailyRemaining: type(uint256).max,
            redeemDailyRemaining: type(uint256).max
        });
        vm.prank(admin);
        flowVault.initialize(params);

        Accountant accountantImpl = new Accountant();
        flowAccountant = Accountant(address(new ERC1967Proxy(
            address(accountantImpl),
            abi.encodeCall(Accountant.initialize, (address(flowVault), uint64(1e18), 0, admin, admin, admin))
        )));
        vm.prank(admin);
        flowVault.setAccountant(address(flowAccountant));

        OperatorExecutor executorImpl = new OperatorExecutor();
        bytes memory executorInitData = abi.encodeCall(OperatorExecutor.initialize, (admin, bot));
        flowOperatorExecutor = OperatorExecutor(address(new ERC1967Proxy(address(executorImpl), executorInitData)));

        StrategyController flowImplementation = new StrategyController();
        bytes memory flowInitData = abi.encodeCall(
            StrategyController.initialize,
            (vaultAddr, admin, address(flowOperatorExecutor), admin, 0, 0, 0)
        );
        flowController = StrategyController(address(new ERC1967Proxy(address(flowImplementation), flowInitData)));
        vm.prank(admin);
        flowVault.setController(address(flowController));

        vm.prank(admin);
        flowGateway.initialize(
            IMantleVaultGateway.InitParams({
                vault: vaultAddr,
                sanctionsOracle: ISanctionsOracle(address(flowSanctionsOracle)),
                sanctionSafe: treasury,
                admin: admin,
                syncRedeemDisabled: false
            })
        );

        flowAsyncAdapter =
            new MockAdapterRR(address(flowAsset), address(flowPosToken), address(flowVault), address(flowVenue));
        flowAsyncAdapter2 =
            new MockAdapterRR(address(flowAsset), address(flowPosToken2), address(flowVault), address(flowVenue2));

        vm.startPrank(admin);
        flowController.registerStrategy(address(flowAsyncAdapter), 10_000, 1, true);
        flowController.activateStrategy(address(flowAsyncAdapter));
        address[] memory ordered = new address[](1);
        ordered[0] = address(flowAsyncAdapter);
        flowController.setStrategyOrder(ordered);
        vm.stopPrank();
    }

    function _depositToFlowVault(address user, uint256 assetAmount) internal returns (uint256 shares) {
        flowAsset.mint(user, assetAmount);
        vm.startPrank(user);
        flowAsset.approve(address(flowVault), assetAmount);
        shares = flowGateway.deposit(assetAmount);
        vm.stopPrank();
    }

    function _executeFlowRebalance() internal {
        vm.prank(bot);
        flowOperatorExecutor.executeRebalance(address(flowController));
    }

    function _executeFlowRebalanceAndGetInFlightId() internal returns (uint256 inFlightId) {
        uint256 beforeId = flowVault.nextInFlightId();
        _executeFlowRebalance();
        uint256 afterId = flowVault.nextInFlightId();
        require(afterId > beforeId, "No invest in-flight created");
        inFlightId = afterId - 1;
    }

    function _executeFlowSettleAdapter(
        uint256[] memory investIds,
        uint256[] memory investSettledPos,
        uint256[] memory investRefundAssets,
        uint256[] memory redeemIds,
        uint256[] memory redeemSettledAssets
    ) internal {
        vm.prank(bot);
        flowOperatorExecutor.executeSettleAdapter(
            address(flowController),
            address(flowAsyncAdapter),
            IStrategyControllerExecutor.InvestSettlementInput(investIds, investSettledPos, investRefundAssets),
            IStrategyControllerExecutor.RedeemSettlementInput(redeemIds, redeemSettledAssets)
        );
    }

    function _executeFlowProcessRedeemBatch(uint256[] memory ids) internal {
        vm.prank(bot);
        flowOperatorExecutor.executeProcessRedeemBatch(address(flowController), ids);
    }

    function _executeFlowProcessRedeemBatchAndGetInFlightId(uint256[] memory ids) internal returns (uint256 inFlightId) {
        uint256 beforeId = flowVault.nextInFlightId();
        _executeFlowProcessRedeemBatch(ids);
        uint256 afterId = flowVault.nextInFlightId();
        require(afterId > beforeId, "No redeem in-flight created");
        inFlightId = afterId - 1;
    }

    function _executeFlowFinalizeRedeemBatch(uint256[] memory ids, uint256[] memory settledAssets) internal {
        vm.prank(bot);
        flowOperatorExecutor.executeFinalizeRedeemBatch(address(flowController), ids, settledAssets);
    }

    function _createFlowRedeemInFlight(uint256 depositAmount) internal returns (uint256 requestId, uint256 redeemInFlightId) {
        uint256 shares = _depositToFlowVault(flowUser, depositAmount);

        uint256 investInFlightId = _executeFlowRebalanceAndGetInFlightId();

        uint256[] memory investIds = new uint256[](1);
        investIds[0] = investInFlightId;
        uint256[] memory investSettledPos = new uint256[](1);
        investSettledPos[0] = depositAmount;
        uint256[] memory investRefund = new uint256[](1);
        flowVenue.settleInvest(address(flowAsyncAdapter), depositAmount, 0);
        _executeFlowSettleAdapter(investIds, investSettledPos, investRefund, new uint256[](0), new uint256[](0));

        vm.prank(flowUser);
        requestId = flowGateway.requestRedeem(shares);
        uint256[] memory ids = new uint256[](1);
        ids[0] = requestId;
        redeemInFlightId = _executeFlowProcessRedeemBatchAndGetInFlightId(ids);
    }

    /// @dev Settle a specific adapter (not just flowAsyncAdapter) via the real bot → executor chain
    function _executeFlowSettleAdapterFor(
        address adapter,
        uint256[] memory investIds,
        uint256[] memory investSettledPos,
        uint256[] memory investRefundAssets,
        uint256[] memory redeemIds,
        uint256[] memory redeemSettledAssets
    ) internal {
        vm.prank(bot);
        flowOperatorExecutor.executeSettleAdapter(
            address(flowController),
            adapter,
            IStrategyControllerExecutor.InvestSettlementInput(investIds, investSettledPos, investRefundAssets),
            IStrategyControllerExecutor.RedeemSettlementInput(redeemIds, redeemSettledAssets)
        );
    }

    // ==========================================================================
    // Flow tests: duplicate confirm, partial confirm, multi-adapter isolation
    // ==========================================================================

    function test_Flow_DuplicateRedeemConfirm_Reverts() public {
        _logCase(
            "test_Flow_DuplicateRedeemConfirm_Reverts",
            unicode"redeem in-flight 重复 confirm 应被真实 vault 状态保护拒绝"
        );

        _step("[Step 1] Create a redeem in-flight through full flow chain");
        (, uint256 redeemInFlightId) = _createFlowRedeemInFlight(1000e18);
        _step(string.concat("  redeemInFlightId = ", vm.toString(redeemInFlightId)));

        _step("[Step 2] Settle the redeem in-flight (first confirm succeeds)");
        uint256 settledAmount = 900e18;
        flowVenue.settleRedeem(address(flowAsyncAdapter), settledAmount);

        uint256[] memory redeemIds = new uint256[](1);
        redeemIds[0] = redeemInFlightId;
        uint256[] memory redeemAmounts = new uint256[](1);
        redeemAmounts[0] = settledAmount;
        _executeFlowSettleAdapter(new uint256[](0), new uint256[](0), new uint256[](0), redeemIds, redeemAmounts);
        _step("  first settleAdapter succeeded");

        (,,,,,,,, IMantleYieldVault.InFlightStatus status) = flowVault.inFlightRecords(redeemInFlightId);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED), "status should be CONFIRMED");
        _step("  in-flight status = CONFIRMED");

        _step("[Step 3] Attempt duplicate confirm - should revert");
        // Deliver USDC to adapter again so the sweep stage passes; the revert must come from
        // confirmInFlight's status guard, not from an earlier sweep-amount mismatch.
        flowVenue.settleRedeem(address(flowAsyncAdapter), settledAmount);
        vm.expectRevert(abi.encodeWithSelector(
            IMantleYieldVault.Vault__InvalidInFlightState.selector,
            redeemInFlightId,
            IMantleYieldVault.InFlightStatus.CONFIRMED
        ));
        _executeFlowSettleAdapter(new uint256[](0), new uint256[](0), new uint256[](0), redeemIds, redeemAmounts);
        _step("  PASS: duplicate confirm reverted with Vault__InvalidInFlightState");

        _logPass();
    }

    function test_Flow_ReconfirmAlreadyConfirmed_Reverts() public {
        _logCase(
            "test_Flow_ReconfirmAlreadyConfirmed_Reverts",
            unicode"已 CONFIRMED 的 redeem in-flight 无法被再次 settle（状态保护）"
        );

        _step("[Step 1] Create and settle a redeem in-flight");
        (, uint256 redeemInFlightId) = _createFlowRedeemInFlight(500e18);
        flowVenue.settleRedeem(address(flowAsyncAdapter), 500e18);

        uint256[] memory redeemIds = new uint256[](1);
        redeemIds[0] = redeemInFlightId;
        uint256[] memory redeemAmounts = new uint256[](1);
        redeemAmounts[0] = 500e18;
        _executeFlowSettleAdapter(new uint256[](0), new uint256[](0), new uint256[](0), redeemIds, redeemAmounts);

        uint256 redeemTotalAfterFirst = flowVault.totalRedeemInFlight();
        _step(string.concat("  redeemInFlightTotal after confirm = ", vm.toString(redeemTotalAfterFirst)));
        assertEq(redeemTotalAfterFirst, 0, "redeemInFlightTotal should be 0 after confirm");

        _step("[Step 2] Wait some time, then try to re-settle with different amount");
        vm.warp(block.timestamp + 1 hours);
        redeemAmounts[0] = 400e18;
        // Deliver USDC to adapter so sweep passes; the revert must come from confirmInFlight guard.
        flowVenue.settleRedeem(address(flowAsyncAdapter), 400e18);
        vm.expectRevert(abi.encodeWithSelector(
            IMantleYieldVault.Vault__InvalidInFlightState.selector,
            redeemInFlightId,
            IMantleYieldVault.InFlightStatus.CONFIRMED
        ));
        _executeFlowSettleAdapter(new uint256[](0), new uint256[](0), new uint256[](0), redeemIds, redeemAmounts);
        _step("  PASS: re-settle reverted, stats remain unchanged");

        uint256 redeemTotalAfterAttempt = flowVault.totalRedeemInFlight();
        assertEq(redeemTotalAfterAttempt, 0, "redeemInFlightTotal unchanged after failed re-settle");

        _logPass();
    }

    function test_Flow_MultiInFlight_PartialConfirm_StatsCorrect() public {
        _logCase(
            "test_Flow_MultiInFlight_PartialConfirm_StatsCorrect",
            unicode"3 个 redeem in-flight 只 confirm 2 个，统计值仅减去已 confirm 部分"
        );

        _step("[Step 1] Create 3 redeem in-flights via single deposit + 3 separate redeem cycles");
        // Deposit once (6000e18) so all shares are created in one go with no locked-share drag.
        uint256 totalDeposit = 6000e18;
        uint256 allShares = _depositToFlowVault(flowUser, totalDeposit);

        // Settle invest (venue delivers 6000 posTokens to vault via adapter sweep)
        uint256 investInFlightId = _executeFlowRebalanceAndGetInFlightId();
        flowVenue.settleInvest(address(flowAsyncAdapter), totalDeposit, 0);
        {
            uint256[] memory iIds = new uint256[](1);
            iIds[0] = investInFlightId;
            uint256[] memory iPos = new uint256[](1);
            iPos[0] = totalDeposit;
            _executeFlowSettleAdapter(iIds, iPos, new uint256[](1), new uint256[](0), new uint256[](0));
        }

        // 3 separate requestRedeem (2000 shares each) → 3 requests
        uint256 sharesPerReq = allShares / 3;
        vm.startPrank(flowUser);
        uint256 reqId1 = flowGateway.requestRedeem(sharesPerReq);
        uint256 reqId2 = flowGateway.requestRedeem(sharesPerReq);
        uint256 reqId3 = flowGateway.requestRedeem(sharesPerReq);
        vm.stopPrank();

        // 3 separate processRedeemBatch calls → 3 redeem in-flights
        uint256 redeemId1;
        {
            uint256[] memory b1 = new uint256[](1);
            b1[0] = reqId1;
            redeemId1 = _executeFlowProcessRedeemBatchAndGetInFlightId(b1);
        }

        uint256 redeemId2;
        {
            uint256[] memory b2 = new uint256[](1);
            b2[0] = reqId2;
            redeemId2 = _executeFlowProcessRedeemBatchAndGetInFlightId(b2);
        }

        uint256 redeemId3;
        {
            uint256[] memory b3 = new uint256[](1);
            b3[0] = reqId3;
            redeemId3 = _executeFlowProcessRedeemBatchAndGetInFlightId(b3);
        }
        _step(string.concat("  redeemId1 = ", vm.toString(redeemId1)));
        _step(string.concat("  redeemId2 = ", vm.toString(redeemId2)));
        _step(string.concat("  redeemId3 = ", vm.toString(redeemId3)));

        uint256 totalRedeemBefore = flowVault.totalRedeemInFlight();
        _step(string.concat("  redeemInFlightTotal before = ", vm.toString(totalRedeemBefore)));

        // Record per-adapter stats before partial confirm
        uint256 adapterRedeemBefore = flowVault.adapterRedeemInFlightUsdc(address(flowAsyncAdapter));
        _step(string.concat("  adapterRedeemInFlightUsdc before = ", vm.toString(adapterRedeemBefore)));

        _step("[Step 2] Settle only redeemId1 and redeemId2 (leave redeemId3 pending)");
        uint256 settled1 = 900e18;
        uint256 settled2 = 1800e18;
        uint256 totalSettledAsset = settled1 + settled2;
        flowVenue.settleRedeem(address(flowAsyncAdapter), totalSettledAsset);

        uint256[] memory redeemIds = new uint256[](2);
        redeemIds[0] = redeemId1;
        redeemIds[1] = redeemId2;
        uint256[] memory redeemAmounts = new uint256[](2);
        redeemAmounts[0] = settled1;
        redeemAmounts[1] = settled2;
        _executeFlowSettleAdapter(new uint256[](0), new uint256[](0), new uint256[](0), redeemIds, redeemAmounts);
        _step("  settleAdapter for redeemId1 + redeemId2 succeeded");

        _step("[Step 3] Verify stats: only confirmed in-flights' usdcAmount subtracted");
        // Get the original usdcAmount for each in-flight from the records
        (,,,, uint256 usdc1,,,,) = flowVault.inFlightRecords(redeemId1);
        (,,,, uint256 usdc2,,,,) = flowVault.inFlightRecords(redeemId2);
        (,,,, uint256 usdc3,,,,) = flowVault.inFlightRecords(redeemId3);

        uint256 expectedRemaining = totalRedeemBefore - usdc1 - usdc2;
        uint256 actualRemaining = flowVault.totalRedeemInFlight();
        assertEq(actualRemaining, expectedRemaining, "redeemInFlightTotal = original - confirmed1 - confirmed2");
        assertEq(actualRemaining, usdc3, "remaining should equal redeemId3's usdcAmount");
        _step(string.concat("  redeemInFlightTotal after = ", vm.toString(actualRemaining)));
        _step(string.concat("  expected remaining (redeemId3) = ", vm.toString(usdc3)));

        _step("[Step 4] Verify individual statuses");
        (,,,,,,,, IMantleYieldVault.InFlightStatus s1) = flowVault.inFlightRecords(redeemId1);
        (,,,,,,,, IMantleYieldVault.InFlightStatus s2) = flowVault.inFlightRecords(redeemId2);
        (,,,,,,,, IMantleYieldVault.InFlightStatus s3) = flowVault.inFlightRecords(redeemId3);
        assertEq(uint8(s1), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED), "redeemId1 CONFIRMED");
        assertEq(uint8(s2), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED), "redeemId2 CONFIRMED");
        assertEq(uint8(s3), uint8(IMantleYieldVault.InFlightStatus.PENDING), "redeemId3 still PENDING");
        _step("  redeemId1: CONFIRMED, redeemId2: CONFIRMED, redeemId3: PENDING");

        _step("[Step 5] Verify per-adapter stats");
        uint256 adapterRedeemAfter = flowVault.adapterRedeemInFlightUsdc(address(flowAsyncAdapter));
        assertEq(adapterRedeemAfter, adapterRedeemBefore - usdc1 - usdc2, "per-adapter stats correct");
        _step(string.concat("  adapterRedeemInFlightUsdc after = ", vm.toString(adapterRedeemAfter)));

        _logPass();
    }

    function test_Flow_MultiAdapter_ConfirmOneDoesNotAffectOther() public {
        _logCase(
            "test_Flow_MultiAdapter_ConfirmOneDoesNotAffectOther",
            unicode"settle 一个 adapter 的 redeem in-flight 不影响另一个 adapter 的统计"
        );

        _step("[Step 1] Create redeem in-flight for adapter1 (sole strategy at 100%)");
        (, uint256 redeemId1) = _createFlowRedeemInFlight(1000e18);
        _step(string.concat("  adapter1 redeemInFlightId = ", vm.toString(redeemId1)));

        _step("[Step 2] Register adapter2 at 10000 weight, set order = [adapter2]");
        vm.startPrank(admin);
        flowController.registerStrategy(address(flowAsyncAdapter2), 10_000, 2, true);
        flowController.activateStrategy(address(flowAsyncAdapter2));
        address[] memory order2 = new address[](1);
        order2[0] = address(flowAsyncAdapter2);
        flowController.setStrategyOrder(order2);
        vm.stopPrank();

        _step("[Step 3] Create redeem in-flight for adapter2 via full flow chain (inline)");
        // Deposit → rebalance invests into adapter2 (sole order) → settle invest → requestRedeem → processRedeemBatch
        _depositToFlowVault(flowUser, 2000e18);
        uint256 investId2 = _executeFlowRebalanceAndGetInFlightId();
        // freeCash was 1000 (deposit 2000 - locked 1000), so 1000 invested into adapter2
        uint256 investedAmount = 1000e18;
        {
            // Settle adapter2 invest
            flowVenue2.settleInvest(address(flowAsyncAdapter2), investedAmount, 0);
            uint256[] memory iIds = new uint256[](1);
            iIds[0] = investId2;
            uint256[] memory iPos = new uint256[](1);
            iPos[0] = investedAmount;
            _executeFlowSettleAdapterFor(
                address(flowAsyncAdapter2),
                iIds, iPos, new uint256[](1),
                new uint256[](0), new uint256[](0)
            );
        }

        vm.prank(flowUser);
        uint256 reqId2 = flowGateway.requestRedeem(investedAmount);
        // Request only investedAmount worth of shares (1000) — adapter2 has exactly 1000 posTokens
        uint256 redeemId2;
        {
            uint256[] memory reqIds = new uint256[](1);
            reqIds[0] = reqId2;
            uint256 nextId = flowVault.nextInFlightId();
            _executeFlowProcessRedeemBatch(reqIds);
            redeemId2 = nextId;
        }
        _step(string.concat("  adapter2 redeemInFlightId = ", vm.toString(redeemId2)));

        _step("[Step 4] Record stats for both adapters before settling");
        uint256 adapter1RedeemBefore = flowVault.adapterRedeemInFlightUsdc(address(flowAsyncAdapter));
        uint256 adapter2RedeemBefore = flowVault.adapterRedeemInFlightUsdc(address(flowAsyncAdapter2));
        uint256 totalRedeemBefore = flowVault.totalRedeemInFlight();
        assertGt(adapter1RedeemBefore, 0, "adapter1 should have pending redeem in-flight");
        assertGt(adapter2RedeemBefore, 0, "adapter2 should have pending redeem in-flight");
        _step(string.concat("  adapter1 redeemInFlight = ", vm.toString(adapter1RedeemBefore)));
        _step(string.concat("  adapter2 redeemInFlight = ", vm.toString(adapter2RedeemBefore)));

        _step("[Step 5] Settle ONLY adapter1's redeem in-flight");
        (,,,, uint256 usdc1,,,,) = flowVault.inFlightRecords(redeemId1);
        flowVenue.settleRedeem(address(flowAsyncAdapter), usdc1);
        {
            uint256[] memory rIds = new uint256[](1);
            rIds[0] = redeemId1;
            uint256[] memory rAmts = new uint256[](1);
            rAmts[0] = usdc1;
            _executeFlowSettleAdapterFor(
                address(flowAsyncAdapter),
                new uint256[](0), new uint256[](0), new uint256[](0),
                rIds, rAmts
            );
        }
        _step("  adapter1 settleAdapter succeeded");

        _step("[Step 6] Verify adapter2 stats are completely untouched");
        uint256 adapter2RedeemAfter = flowVault.adapterRedeemInFlightUsdc(address(flowAsyncAdapter2));
        assertEq(adapter2RedeemAfter, adapter2RedeemBefore, "adapter2 redeem stats untouched");
        _step(string.concat("  adapter2 redeemInFlight after = ", vm.toString(adapter2RedeemAfter)));
        _step("  PASS: adapter2 stats unchanged");

        _step("[Step 7] Verify adapter1 stats were reduced");
        uint256 adapter1RedeemAfter = flowVault.adapterRedeemInFlightUsdc(address(flowAsyncAdapter));
        assertEq(adapter1RedeemAfter, adapter1RedeemBefore - usdc1, "adapter1 redeem stats reduced");
        _step(string.concat("  adapter1 redeemInFlight after = ", vm.toString(adapter1RedeemAfter)));

        _step("[Step 8] Verify total redeemInFlight only reduced by adapter1's amount");
        uint256 totalRedeemAfter = flowVault.totalRedeemInFlight();
        assertEq(totalRedeemAfter, totalRedeemBefore - usdc1, "total reduced by adapter1 only");
        _step(string.concat("  totalRedeemInFlight after = ", vm.toString(totalRedeemAfter)));

        _step("[Step 9] Verify adapter2's in-flight is still PENDING");
        (,,,,,,,, IMantleYieldVault.InFlightStatus s2) = flowVault.inFlightRecords(redeemId2);
        assertEq(uint8(s2), uint8(IMantleYieldVault.InFlightStatus.PENDING), "adapter2 in-flight still PENDING");
        _step("  adapter2 in-flight status = PENDING");

        _logPass();
    }

    string constant MODULE = unicode"风险回归场景";
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

    // =========================================================================
    // Part A: In-flight settlement regression tests
    // =========================================================================

    // P0: settledAmount records actual Y, not recorded X
    function test_ConfirmInFlight_RecordsActualSettledAmount() public {
        _logCase("test_ConfirmInFlight_RecordsActualSettledAmount", unicode"redeem in-flight 确认时记录实际 settledAmount，而不是强制等于记录值");
        _step("[Step 1] Create a real redeem in-flight via deposit -> rebalance -> settle invest -> requestRedeem -> process");
        (, uint256 inFlightId) = _createFlowRedeemInFlight(100e18);
        _step(string.concat("  redeem inFlightId = ", vm.toString(inFlightId)));

        _step("[Step 2] Set actual settled amount Y = 95e18 (different from recorded X=100e18)");
        uint256 actualY = 95e18;
        flowVenue.settleRedeem(address(flowAsyncAdapter), actualY);
        _step(string.concat("  actualY = ", vm.toString(actualY)));

        _step("[Step 3] Settle adapter through OperatorExecutor");
        uint256[] memory redeemIds = new uint256[](1);
        redeemIds[0] = inFlightId;
        uint256[] memory redeemAmounts = new uint256[](1);
        redeemAmounts[0] = actualY;
        _executeFlowSettleAdapter(new uint256[](0), new uint256[](0), new uint256[](0), redeemIds, redeemAmounts);
        _step("  settleAdapter completed successfully");

        _step("[Step 4] Verify settledAmount == actual Y, not original X");
        (,,,,, uint256 settledAmount,,, IMantleYieldVault.InFlightStatus status) = flowVault.inFlightRecords(inFlightId);
        _step(string.concat("  settledAmount = ", vm.toString(settledAmount)));
        _step(string.concat("  status = ", vm.toString(uint8(status))));
        assertEq(settledAmount, actualY, "settledAmount should be actual Y=95e18, not recorded X=100e18");
        _step("  PASS: settledAmount == actualY (95e18)");
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        _step("  PASS: status == CONFIRMED");
        _logPass();
    }

    // P0: stats decrease by original usdcAmount X, not Y
    function test_ConfirmInFlight_StatsDecreaseByRecordedAmount() public {
        _logCase("test_ConfirmInFlight_StatsDecreaseByRecordedAmount", unicode"redeem in-flight 确认后，统计清账按原记录值 usdcAmount 递减");
        _step("[Step 1] Create a real redeem in-flight with recorded usdcAmount X = 100e18");
        (, uint256 inFlightId) = _createFlowRedeemInFlight(100e18);
        _step(string.concat("  redeem inFlightId = ", vm.toString(inFlightId)));

        _step("[Step 2] Verify initial stats match X = 100e18");
        uint256 redeemTotalBefore = flowVault.totalRedeemInFlight();
        uint256 adapterRedeemBefore = flowVault.adapterRedeemInFlightUsdc(address(flowAsyncAdapter));
        _step(string.concat("  redeemTotalBefore = ", vm.toString(redeemTotalBefore)));
        _step(string.concat("  adapterRedeemBefore = ", vm.toString(adapterRedeemBefore)));
        assertEq(redeemTotalBefore, 100e18);
        assertEq(adapterRedeemBefore, 100e18);
        _step("  PASS: initial stats == 100e18");

        _step("[Step 3] Settle with actual Y = 80e18 (less than X)");
        uint256 actualY = 80e18;
        flowVenue.settleRedeem(address(flowAsyncAdapter), actualY);

        uint256[] memory redeemIds = new uint256[](1);
        redeemIds[0] = inFlightId;
        uint256[] memory redeemAmounts = new uint256[](1);
        redeemAmounts[0] = actualY;
        _executeFlowSettleAdapter(new uint256[](0), new uint256[](0), new uint256[](0), redeemIds, redeemAmounts);
        _step("  settleAdapter completed successfully");

        _step("[Step 4] Verify stats decreased by original X=100e18, not actual Y=80e18");
        _step(string.concat("  redeemInFlightTotal = ", vm.toString(flowVault.totalRedeemInFlight())));
        _step(string.concat("  adapterRedeemInFlight = ", vm.toString(flowVault.adapterRedeemInFlightUsdc(address(flowAsyncAdapter)))));
        assertEq(flowVault.totalRedeemInFlight(), 0, "redeemInFlightTotal should decrease by X=100e18 to 0");
        _step("  PASS: redeemInFlightTotal == 0");
        assertEq(
            flowVault.adapterRedeemInFlightUsdc(address(flowAsyncAdapter)),
            0,
            "adapter redeemInFlight should decrease by X=100e18 to 0"
        );
        _step("  PASS: adapterRedeemInFlight == 0");
        _logPass();
    }

    // P0: Y < X, confirm succeeds, difference exposed in finalize
    function test_ConfirmInFlight_ActualLessThanRecorded_StillSucceeds() public {
        _logCase("test_ConfirmInFlight_ActualLessThanRecorded_StillSucceeds", unicode"实际回款小于记录值时，确认阶段仍可完成，差异在后续结算阶段暴露");
        _step("[Step 1] Create a real redeem in-flight with recorded X = 100e18");
        (, uint256 inFlightId) = _createFlowRedeemInFlight(100e18);
        _step(string.concat("  redeem inFlightId = ", vm.toString(inFlightId)));

        _step("[Step 2] Set actual Y = 60e18 (less than X)");
        uint256 actualY = 60e18;
        flowVenue.settleRedeem(address(flowAsyncAdapter), actualY);
        _step(string.concat("  actualY = ", vm.toString(actualY)));

        uint256[] memory redeemIds = new uint256[](1);
        redeemIds[0] = inFlightId;
        uint256[] memory redeemAmounts = new uint256[](1);
        redeemAmounts[0] = actualY;

        _step("[Step 3] Settle adapter - should NOT revert even though Y < X");
        _executeFlowSettleAdapter(new uint256[](0), new uint256[](0), new uint256[](0), redeemIds, redeemAmounts);
        _step("  PASS: settleAdapter did not revert with Y < X");

        _step("[Step 4] Verify settledAmount == Y and status == CONFIRMED");
        (,,,,, uint256 settledAmount,,, IMantleYieldVault.InFlightStatus status) = flowVault.inFlightRecords(inFlightId);
        _step(string.concat("  settledAmount = ", vm.toString(settledAmount)));
        assertEq(settledAmount, actualY, "settledAmount should record actual Y=60e18");
        _step("  PASS: settledAmount == 60e18");
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        _step("  PASS: status == CONFIRMED");
        _logPass();
    }

    // P0: Y > X, stats still decrease by X
    function test_ConfirmInFlight_ActualMoreThanRecorded_StatsStillByOriginal() public {
        _logCase("test_ConfirmInFlight_ActualMoreThanRecorded_StatsStillByOriginal", unicode"实际回款大于记录值时，确认阶段记录超额实际值，但统计仍按原记录值清账");
        _step("[Step 1] Create a real redeem in-flight with recorded X = 100e18");
        (, uint256 inFlightId) = _createFlowRedeemInFlight(100e18);
        _step(string.concat("  redeem inFlightId = ", vm.toString(inFlightId)));

        _step("[Step 2] Set actual Y = 120e18 (more than X)");
        uint256 actualY = 120e18;
        flowVenue.settleRedeem(address(flowAsyncAdapter), actualY);
        _step(string.concat("  actualY = ", vm.toString(actualY)));

        _step("[Step 3] Settle adapter");
        uint256[] memory redeemIds = new uint256[](1);
        redeemIds[0] = inFlightId;
        uint256[] memory redeemAmounts = new uint256[](1);
        redeemAmounts[0] = actualY;
        _executeFlowSettleAdapter(new uint256[](0), new uint256[](0), new uint256[](0), redeemIds, redeemAmounts);
        _step("  settleAdapter completed successfully");

        _step("[Step 4] Verify stats decrease by original X=100e18, not actual Y=120e18");
        _step(string.concat("  redeemInFlightTotal = ", vm.toString(flowVault.totalRedeemInFlight())));
        _step(string.concat("  adapterRedeemInFlight = ", vm.toString(flowVault.adapterRedeemInFlightUsdc(address(flowAsyncAdapter)))));
        assertEq(flowVault.totalRedeemInFlight(), 0, "redeemInFlightTotal decreases by X=100e18");
        _step("  PASS: redeemInFlightTotal == 0");
        assertEq(flowVault.adapterRedeemInFlightUsdc(address(flowAsyncAdapter)), 0, "adapter redeemInFlight decreases by X");
        _step("  PASS: adapterRedeemInFlight == 0");

        _step("[Step 5] Verify settledAmount records actual Y=120e18");
        (,,,,, uint256 settledAmount,,,) = flowVault.inFlightRecords(inFlightId);
        _step(string.concat("  settledAmount = ", vm.toString(settledAmount)));
        assertEq(settledAmount, actualY, "settledAmount should be actual Y=120e18");
        _step("  PASS: settledAmount == 120e18");
        _logPass();
    }

    // P0: confirm does not fail due to insufficient future payout
    function test_ConfirmInFlight_DoesNotCheckFuturePayment() public {
        _logCase("test_ConfirmInFlight_DoesNotCheckFuturePayment", unicode"confirmInFlight 不直接校验后续批量付款是否充足");
        _step("[Step 1] Create a real redeem in-flight with large recorded X = 1000e18");
        (, uint256 inFlightId) = _createFlowRedeemInFlight(1000e18);
        _step(string.concat("  redeem inFlightId = ", vm.toString(inFlightId)));

        _step("[Step 2] Set actual Y = 1e18 (tiny compared to X=1000e18)");
        uint256 actualY = 1e18;
        flowVenue.settleRedeem(address(flowAsyncAdapter), actualY);
        _step(string.concat("  actualY = ", vm.toString(actualY)));

        _step("[Step 3] Settle adapter - should NOT revert (confirm does not check future payout)");
        uint256[] memory redeemIds = new uint256[](1);
        redeemIds[0] = inFlightId;
        uint256[] memory redeemAmounts = new uint256[](1);
        redeemAmounts[0] = actualY;
        _executeFlowSettleAdapter(new uint256[](0), new uint256[](0), new uint256[](0), redeemIds, redeemAmounts);
        _step("  PASS: settleAdapter did not revert despite Y << X");

        _step("[Step 4] Verify settledAmount and status");
        (,,,,, uint256 settledAmount,,, IMantleYieldVault.InFlightStatus status) = flowVault.inFlightRecords(inFlightId);
        _step(string.concat("  settledAmount = ", vm.toString(settledAmount)));
        _step(string.concat("  status = ", vm.toString(uint8(status))));
        assertEq(settledAmount, actualY);
        _step("  PASS: settledAmount == 1e18");
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        _step("  PASS: status == CONFIRMED");
        _logPass();
    }

    // P0: finalize success depends on physical balance, not settledAmount
    function test_FinalizeRedeemBatch_DependsOnPhysicalBalance() public {
        _logCase("test_FinalizeRedeemBatch_DependsOnPhysicalBalance", unicode"finalizeRedeemBatch 成功与否取决于物理余额，不取决于 redeem in-flight 是否已确认");
        _step("[Step 1] Create a real PROCESSING request and redeem in-flight");
        (uint256 requestId, uint256 inFlightId) = _createFlowRedeemInFlight(100e18);
        uint256[] memory requestIds = new uint256[](1);
        requestIds[0] = requestId;

        uint256[] memory settledAssets = new uint256[](1);
        settledAssets[0] = 100e18;

        _step("[Step 2] Confirm the redeem in-flight with settledAmount=0 (abnormal path)");
        uint256[] memory redeemIds = new uint256[](1);
        redeemIds[0] = inFlightId;
        uint256[] memory redeemAmounts = new uint256[](1);
        redeemAmounts[0] = 0;
        flowVenue.settleRedeem(address(flowAsyncAdapter), 0);
        _executeFlowSettleAdapter(new uint256[](0), new uint256[](0), new uint256[](0), redeemIds, redeemAmounts);

        _step("[Step 3] Attempt finalize with 0 physical balance -> expect revert");
        _step(string.concat("  vault balance = ", vm.toString(flowAsset.balanceOf(address(flowVault)))));
        vm.expectRevert(abi.encodeWithSelector(
            IMantleYieldVault.Vault__InsufficientPhysicalCash.selector, requestIds, settledAssets, 0
        ));
        _executeFlowFinalizeRedeemBatch(requestIds, settledAssets);
        _step("  PASS: reverted as expected (0 balance)");

        _step("[Step 4] New user deposits 50e18 -> still insufficient, expect revert");
        _depositToFlowVault(makeAddr("flowTopUpA"), 50e18);
        _step(string.concat("  vault balance = ", vm.toString(flowAsset.balanceOf(address(flowVault)))));
        vm.expectRevert(abi.encodeWithSelector(
            IMantleYieldVault.Vault__InsufficientPhysicalCash.selector, requestIds, settledAssets, 50e18
        ));
        _executeFlowFinalizeRedeemBatch(requestIds, settledAssets);
        _step("  PASS: reverted as expected (50e18 < 100e18)");

        _step("[Step 5] Another user deposits remaining 50e18 -> now has 100e18 -> finalize succeeds");
        _depositToFlowVault(makeAddr("flowTopUpB"), 50e18);
        _step(string.concat("  vault balance = ", vm.toString(flowAsset.balanceOf(address(flowVault)))));
        uint256 userBefore = flowAsset.balanceOf(flowUser);
        _executeFlowFinalizeRedeemBatch(requestIds, settledAssets);
        _step("  PASS: finalizeRedeemBatch succeeded with sufficient balance");

        _step("[Step 6] Verify request is DONE with correct settledAssets");
        (,,,,,uint256 reqSettled,, IMantleYieldVault.RequestStatus reqStatus) = flowVault.requests(requestId);
        _step(string.concat("  reqSettled = ", vm.toString(reqSettled)));
        _step(string.concat("  reqStatus = ", vm.toString(uint8(reqStatus))));
        assertEq(reqSettled, 100e18, "request settledAssets should match finalize amount");
        _step("  PASS: reqSettled == 100e18");
        assertEq(uint8(reqStatus), uint8(IMantleYieldVault.RequestStatus.DONE));
        _step("  PASS: reqStatus == DONE");
        assertEq(flowAsset.balanceOf(flowUser) - userBefore, 100e18, "owner received finalized assets");
        _step("  PASS: owner actually received 100e18");
        _logPass();
    }

    // P1: confirm does not auto-complete the request; request still needs finalize
    function test_ConfirmInFlight_RequestStillNeedsFinalize() public {
        _logCase("test_ConfirmInFlight_RequestStillNeedsFinalize", unicode"confirmInFlight 后 request 仍需独立 finalize，不会因为 in-flight 已确认而自动完成");
        _step("[Step 1] Create a real PROCESSING request and redeem in-flight");
        (uint256 requestId, uint256 inFlightId) = _createFlowRedeemInFlight(100e18);
        _step(string.concat("  requestId = ", vm.toString(requestId), ", inFlightId = ", vm.toString(inFlightId)));

        uint256[] memory redeemIds = new uint256[](1);
        redeemIds[0] = inFlightId;
        uint256[] memory redeemAmounts = new uint256[](1);
        redeemAmounts[0] = 100e18;

        _step("[Step 2] Settle the redeem in-flight with 100e18");
        flowVenue.settleRedeem(address(flowAsyncAdapter), 100e18);
        _executeFlowSettleAdapter(new uint256[](0), new uint256[](0), new uint256[](0), redeemIds, redeemAmounts);
        _step("  settleAdapter completed successfully");

        _step("[Step 3] Verify in-flight is CONFIRMED");
        (,,,,,,,, IMantleYieldVault.InFlightStatus flightStatus) = flowVault.inFlightRecords(inFlightId);
        assertEq(uint8(flightStatus), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        _step("  PASS: in-flight status == CONFIRMED");

        _step("[Step 4] Verify request is STILL PROCESSING (not auto-completed)");
        (,,,,,,, IMantleYieldVault.RequestStatus reqStatus) = flowVault.requests(requestId);
        _step(string.concat("  reqStatus = ", vm.toString(uint8(reqStatus))));
        assertEq(
            uint8(reqStatus),
            uint8(IMantleYieldVault.RequestStatus.PROCESSING),
            "confirm should not auto-complete the request"
        );
        _step("  PASS: request still PROCESSING after in-flight confirm");

        _step("[Step 5] Finalize the request explicitly");
        uint256[] memory requestIds = new uint256[](1);
        requestIds[0] = requestId;
        uint256[] memory settledAssets = new uint256[](1);
        settledAssets[0] = 100e18;

        _executeFlowFinalizeRedeemBatch(requestIds, settledAssets);
        _step("  finalizeRedeemBatch completed");

        _step("[Step 6] Verify request is now DONE");
        (,,,,,,, IMantleYieldVault.RequestStatus finalStatus) = flowVault.requests(requestId);
        _step(string.concat("  finalStatus = ", vm.toString(uint8(finalStatus))));
        assertEq(uint8(finalStatus), uint8(IMantleYieldVault.RequestStatus.DONE));
        _step("  PASS: request status == DONE after explicit finalize");
        _logPass();
    }

    // P1: in-flight settledAmount != request settledAssets (they are independent concepts)
    function test_SettledAmount_IndependentOfRequestSettledAssets() public {
        _logCase("test_SettledAmount_IndependentOfRequestSettledAssets", unicode"redeem in-flight 确认后，settledAmount 与最终 request settledAssets 不必天然相等");
        _step("[Step 1] Create a real PROCESSING request and redeem in-flight");
        (uint256 requestId, uint256 inFlightId) = _createFlowRedeemInFlight(100e18);
        _step(string.concat("  requestId = ", vm.toString(requestId), ", inFlightId = ", vm.toString(inFlightId)));

        _step("[Step 2] Settle in-flight with actual Y = 90e18");
        flowVenue.settleRedeem(address(flowAsyncAdapter), 90e18);
        uint256[] memory redeemIds = new uint256[](1);
        redeemIds[0] = inFlightId;
        uint256[] memory redeemAmounts = new uint256[](1);
        redeemAmounts[0] = 90e18;

        _executeFlowSettleAdapter(new uint256[](0), new uint256[](0), new uint256[](0), redeemIds, redeemAmounts);
        _step("  settleAdapter completed");

        (,,,,, uint256 flightSettled,,,) = flowVault.inFlightRecords(inFlightId);
        _step(string.concat("  in-flight settledAmount = ", vm.toString(flightSettled)));
        assertEq(flightSettled, 90e18);
        _step("  PASS: in-flight settledAmount == 90e18");

        _step("[Step 3] Request already exists in PROCESSING from the real lifecycle");
        uint256[] memory requestIds = new uint256[](1);
        requestIds[0] = requestId;

        _step("[Step 4] Finalize request with 85e18 (different from in-flight's 90e18)");
        uint256[] memory settledAssets = new uint256[](1);
        settledAssets[0] = 85e18;

        _executeFlowFinalizeRedeemBatch(requestIds, settledAssets);
        _step("  finalizeRedeemBatch completed");

        _step("[Step 5] Verify independence of settledAmount vs settledAssets");
        (,,,,,uint256 reqSettled,,) = flowVault.requests(requestId);
        _step(string.concat("  request settledAssets = ", vm.toString(reqSettled)));
        _step(string.concat("  in-flight settledAmount = ", vm.toString(flightSettled)));
        assertEq(reqSettled, 85e18, "request settledAssets should be 85e18, independent of in-flight settledAmount");
        _step("  PASS: request settledAssets == 85e18");
        assertEq(flightSettled, 90e18, "in-flight settledAmount should be 90e18 (from settleAdapter)");
        assertTrue(flightSettled != reqSettled, "in-flight settledAmount and request settledAssets are independent");
        _step("  PASS: flightSettled (90e18) != reqSettled (85e18) - independent values");
        _logPass();
    }

    // P1: abnormal confirm with 0 amount still clears stats by original X
    function test_AbnormalConfirm_ZeroAmount_StatsClearByOriginal() public {
        _logCase("test_AbnormalConfirm_ZeroAmount_StatsClearByOriginal", unicode"abnormal 路径允许 actualAmount=0，但仍按记录值清理 redeem in-flight 统计");
        _step("[Step 1] Create a real redeem in-flight with recorded usdcAmount X = 200e18");
        (, uint256 inFlightId) = _createFlowRedeemInFlight(200e18);
        _step(string.concat("  inFlightId = ", vm.toString(inFlightId)));
        _step(string.concat("  redeemInFlightTotal = ", vm.toString(flowVault.totalRedeemInFlight())));
        assertEq(flowVault.totalRedeemInFlight(), 200e18);
        assertEq(flowVault.adapterRedeemInFlightUsdc(address(flowAsyncAdapter)), 200e18);
        _step("  PASS: initial stats == 200e18");

        _step("[Step 2] Settle with amount=0 (abnormal case - third party never settled)");
        flowVenue.settleRedeem(address(flowAsyncAdapter), 0);

        uint256[] memory redeemIds = new uint256[](1);
        redeemIds[0] = inFlightId;
        uint256[] memory redeemAmounts = new uint256[](1);
        redeemAmounts[0] = 0;

        _executeFlowSettleAdapter(new uint256[](0), new uint256[](0), new uint256[](0), redeemIds, redeemAmounts);
        _step("  settleAdapter completed with zero amount");

        _step("[Step 3] Verify stats decreased by original X=200e18 (not by 0)");
        _step(string.concat("  redeemInFlightTotal = ", vm.toString(flowVault.totalRedeemInFlight())));
        _step(string.concat("  adapterRedeemInFlight = ", vm.toString(flowVault.adapterRedeemInFlightUsdc(address(flowAsyncAdapter)))));
        assertEq(flowVault.totalRedeemInFlight(), 0, "redeemInFlightTotal should be 0 after abnormal confirm");
        _step("  PASS: redeemInFlightTotal == 0");
        assertEq(
            flowVault.adapterRedeemInFlightUsdc(address(flowAsyncAdapter)),
            0,
            "adapter redeemInFlight should be 0 after abnormal confirm"
        );
        _step("  PASS: adapterRedeemInFlight == 0");

        _step("[Step 4] Verify settledAmount = 0 recorded and status CONFIRMED");
        (,,,,, uint256 settledAmount,,, IMantleYieldVault.InFlightStatus status) = flowVault.inFlightRecords(inFlightId);
        _step(string.concat("  settledAmount = ", vm.toString(settledAmount)));
        _step(string.concat("  status = ", vm.toString(uint8(status))));
        assertEq(settledAmount, 0, "abnormal settle records 0");
        _step("  PASS: settledAmount == 0");
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        _step("  PASS: status == CONFIRMED");
        _logPass();
    }

    // P1: non-abnormal confirm with 0 -> the real vault would revert (ZeroAmount),
    // but this simplified flow vault mock does not enforce that check.
    // However, _confirmRedeemInFlightIds calls confirmInFlight(id, 0, true) when settledAmount==0,
    // so the isAbnormal flag is automatically set. We verify that the controller
    // sets isAbnormal=true (passes settledAmount==0) - the real vault rejects non-abnormal zero.
    function test_NonAbnormal_ZeroAmount_Reverts() public {
        _logCase("test_NonAbnormal_ZeroAmount_Reverts", unicode"非 abnormal 路径下 actualAmount=0 被拒绝");
        _step("[Step 1] Create a real redeem in-flight with usdcAmount = 50e18");
        (, uint256 inFlightId) = _createFlowRedeemInFlight(50e18);
        _step(string.concat("  inFlightId = ", vm.toString(inFlightId)));

        _step("[Step 2] Verify in-flight is PENDING before attempting confirm");
        (,,,,,,,, IMantleYieldVault.InFlightStatus statusBefore) = flowVault.inFlightRecords(inFlightId);
        assertEq(uint8(statusBefore), uint8(IMantleYieldVault.InFlightStatus.PENDING), "should be PENDING");
        _step("  PASS: status == PENDING");

        _step("[Step 3] Call confirmInFlight(inFlightId, 0, false) -> revert Vault__ZeroAmount");
        // Spec: non-abnormal path with actualAmount=0 must be rejected by vault guard.
        // The controller normally auto-sets isAbnormal=true when amount=0, so we test the
        // vault guard directly by pranking as controller with isAbnormal=false.
        vm.prank(address(flowController));
        vm.expectRevert(IMantleYieldVault.Vault__ZeroAmount.selector);
        flowVault.confirmInFlight(inFlightId, 0, false);
        _step("  PASS: reverted with Vault__ZeroAmount");

        _step("[Step 4] Verify in-flight status unchanged (still PENDING)");
        (,,,,,,,, IMantleYieldVault.InFlightStatus statusAfter) = flowVault.inFlightRecords(inFlightId);
        assertEq(uint8(statusAfter), uint8(IMantleYieldVault.InFlightStatus.PENDING), "should still be PENDING");
        _step("  PASS: status still PENDING after revert");
        _logPass();
    }

    // P1: already-confirmed in-flight reverts on duplicate confirm
    function test_DuplicateConfirm_Reverts() public {
        _logCase("test_DuplicateConfirm_Reverts", unicode"重复确认同一 redeem in-flight 被拒绝");
        _step("[Step 1] Create a redeem in-flight through full real flow chain");
        (, uint256 inFlightId) = _createFlowRedeemInFlight(100e18);
        _step(string.concat("  inFlightId = ", vm.toString(inFlightId)));

        uint256[] memory redeemIds = new uint256[](1);
        redeemIds[0] = inFlightId;
        uint256[] memory redeemAmounts = new uint256[](1);
        redeemAmounts[0] = 100e18;

        _step("[Step 2] First settle succeeds");
        flowVenue.settleRedeem(address(flowAsyncAdapter), 100e18);
        _executeFlowSettleAdapter(new uint256[](0), new uint256[](0), new uint256[](0), redeemIds, redeemAmounts);
        _step("  PASS: first settleAdapter completed");

        _step("[Step 3] Verify in-flight is CONFIRMED");
        (,,,,,,,, IMantleYieldVault.InFlightStatus status) = flowVault.inFlightRecords(inFlightId);
        _step(string.concat("  status = ", vm.toString(uint8(status))));
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        _step("  PASS: status == CONFIRMED");

        _step("[Step 4] Second settle of same in-flight -> revert (vault status guard)");
        flowVenue.settleRedeem(address(flowAsyncAdapter), 100e18);
        vm.expectRevert(abi.encodeWithSelector(
            IMantleYieldVault.Vault__InvalidInFlightState.selector,
            inFlightId,
            IMantleYieldVault.InFlightStatus.CONFIRMED
        ));
        _executeFlowSettleAdapter(new uint256[](0), new uint256[](0), new uint256[](0), redeemIds, redeemAmounts);
        _step("  PASS: duplicate confirm reverted with Vault__InvalidInFlightState");
        _logPass();
    }

    // P1: already-confirmed redeem in-flight cannot be re-settled (state guard, not just duplicate)
    function test_InvalidState_RedeemInFlight_CannotResettle() public {
        _logCase("test_InvalidState_RedeemInFlight_CannotResettle", unicode"已确认的 redeem in-flight 重复结算被拒绝");
        _step("[Step 1] Create and settle a redeem in-flight through full real flow chain");
        (, uint256 inFlightId) = _createFlowRedeemInFlight(100e18);
        _step(string.concat("  inFlightId = ", vm.toString(inFlightId)));

        uint256[] memory redeemIds = new uint256[](1);
        redeemIds[0] = inFlightId;
        uint256[] memory redeemAmounts = new uint256[](1);
        redeemAmounts[0] = 100e18;

        _step("[Step 2] Settle (confirm) the redeem in-flight");
        flowVenue.settleRedeem(address(flowAsyncAdapter), 100e18);
        _executeFlowSettleAdapter(new uint256[](0), new uint256[](0), new uint256[](0), redeemIds, redeemAmounts);
        _step("  PASS: first settleAdapter completed");

        _step("[Step 3] Verify in-flight status is CONFIRMED");
        (,,,,,,,, IMantleYieldVault.InFlightStatus status) = flowVault.inFlightRecords(inFlightId);
        _step(string.concat("  status = ", vm.toString(uint8(status))));
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        _step("  PASS: status == CONFIRMED");

        _step("[Step 4] Attempt to re-settle the CONFIRMED in-flight -> revert (vault status guard)");
        flowVenue.settleRedeem(address(flowAsyncAdapter), 100e18);
        vm.expectRevert(abi.encodeWithSelector(
            IMantleYieldVault.Vault__InvalidInFlightState.selector,
            inFlightId,
            IMantleYieldVault.InFlightStatus.CONFIRMED
        ));
        _executeFlowSettleAdapter(new uint256[](0), new uint256[](0), new uint256[](0), redeemIds, redeemAmounts);
        _step("  PASS: re-settle reverted with Vault__InvalidInFlightState");
        _logPass();
    }

    // P1: partial confirm of multi in-flights, adapter stats correct
    function test_MultiInFlight_PartialConfirm_StatsCorrect() public {
        _logCase("test_MultiInFlight_PartialConfirm_StatsCorrect", unicode"多笔 redeem in-flight 部分确认后，adapter 级别的 in-flight 统计累计变化正确");
        _step("[Step 1] Create 3 redeem in-flights through the real flow lifecycle");
        uint256 totalDeposit = 600e18;
        uint256 allShares = _depositToFlowVault(flowUser, totalDeposit);

        uint256 investInFlightId = _executeFlowRebalanceAndGetInFlightId();
        flowVenue.settleInvest(address(flowAsyncAdapter), totalDeposit, 0);
        {
            uint256[] memory investIds = new uint256[](1);
            investIds[0] = investInFlightId;
            uint256[] memory investSettledPos = new uint256[](1);
            investSettledPos[0] = totalDeposit;
            _executeFlowSettleAdapter(investIds, investSettledPos, new uint256[](1), new uint256[](0), new uint256[](0));
        }

        uint256 sharesPerReq = allShares / 3;
        vm.startPrank(flowUser);
        uint256 reqId1 = flowGateway.requestRedeem(sharesPerReq);
        uint256 reqId2 = flowGateway.requestRedeem(sharesPerReq);
        uint256 reqId3 = flowGateway.requestRedeem(sharesPerReq);
        vm.stopPrank();

        uint256 id1;
        {
            uint256[] memory ids1 = new uint256[](1);
            ids1[0] = reqId1;
            id1 = _executeFlowProcessRedeemBatchAndGetInFlightId(ids1);
        }
        uint256 id2;
        {
            uint256[] memory ids2 = new uint256[](1);
            ids2[0] = reqId2;
            id2 = _executeFlowProcessRedeemBatchAndGetInFlightId(ids2);
        }
        uint256 id3;
        {
            uint256[] memory ids3 = new uint256[](1);
            ids3[0] = reqId3;
            id3 = _executeFlowProcessRedeemBatchAndGetInFlightId(ids3);
        }
        _step(string.concat("  id1 = ", vm.toString(id1), ", id2 = ", vm.toString(id2), ", id3 = ", vm.toString(id3)));

        _step(string.concat("  redeemInFlightTotal = ", vm.toString(flowVault.totalRedeemInFlight())));
        uint256 totalRedeemBefore = flowVault.totalRedeemInFlight();
        uint256 adapterRedeemBefore = flowVault.adapterRedeemInFlightUsdc(address(flowAsyncAdapter));
        _step("  PASS: real redeem in-flights created");

        _step("[Step 2] Settle only id1 and id2 (leave id3 pending)");
        uint256[] memory redeemIds = new uint256[](2);
        redeemIds[0] = id1;
        redeemIds[1] = id2;
        uint256[] memory redeemAmounts = new uint256[](2);
        redeemAmounts[0] = 90e18;
        redeemAmounts[1] = 180e18;
        _step("  actuals: id1=90e18, id2=180e18");

        flowVenue.settleRedeem(address(flowAsyncAdapter), 270e18);
        _executeFlowSettleAdapter(new uint256[](0), new uint256[](0), new uint256[](0), redeemIds, redeemAmounts);
        _step("  settleAdapter completed");

        _step("[Step 3] Verify stats only decrease by the original recorded amounts of id1 + id2");
        (,,,, uint256 usdc1,,,,) = flowVault.inFlightRecords(id1);
        (,,,, uint256 usdc2,,,,) = flowVault.inFlightRecords(id2);
        (,,,, uint256 usdc3,,,,) = flowVault.inFlightRecords(id3);
        uint256 expectedRemaining = totalRedeemBefore - usdc1 - usdc2;
        assertEq(flowVault.totalRedeemInFlight(), expectedRemaining, "remaining should equal unconfirmed original amount");
        assertEq(flowVault.totalRedeemInFlight(), usdc3, "remaining should match id3 original usdcAmount");
        assertEq(
            flowVault.adapterRedeemInFlightUsdc(address(flowAsyncAdapter)),
            adapterRedeemBefore - usdc1 - usdc2,
            "adapter stats should only clear confirmed originals"
        );
        _step("  PASS: total + per-adapter stats only cleared confirmed originals");

        _step("[Step 4] Verify statuses: id1=CONFIRMED, id2=CONFIRMED, id3=PENDING");
        (,,,,,,,, IMantleYieldVault.InFlightStatus s1) = flowVault.inFlightRecords(id1);
        (,,,,,,,, IMantleYieldVault.InFlightStatus s2) = flowVault.inFlightRecords(id2);
        (,,,,,,,, IMantleYieldVault.InFlightStatus s3) = flowVault.inFlightRecords(id3);
        assertEq(uint8(s1), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        _step("  PASS: id1 status == CONFIRMED");
        assertEq(uint8(s2), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED));
        _step("  PASS: id2 status == CONFIRMED");
        assertEq(uint8(s3), uint8(IMantleYieldVault.InFlightStatus.PENDING));
        _step("  PASS: id3 status == PENDING");

        _step("[Step 5] Verify settledAmounts recorded correctly");
        (,,,,, uint256 settled1,,,) = flowVault.inFlightRecords(id1);
        (,,,,, uint256 settled2,,,) = flowVault.inFlightRecords(id2);
        _step(string.concat("  settled1 = ", vm.toString(settled1), ", settled2 = ", vm.toString(settled2)));
        assertEq(settled1, 90e18);
        _step("  PASS: settled1 == 90e18");
        assertEq(settled2, 180e18);
        _step("  PASS: settled2 == 180e18");
        _logPass();
    }

    // P1: confirm one adapter's in-flight does not affect another adapter's stats
    function test_MultiAdapter_ConfirmOneDoesNotAffectOther() public {
        _logCase("test_MultiAdapter_ConfirmOneDoesNotAffectOther", unicode"多 adapter 同时存在 redeem in-flight 时，确认一笔不会影响其他 adapter 的累计值");
        _step("[Step 1] Create redeem in-flight for adapter1 through full real flow");
        (, uint256 id1) = _createFlowRedeemInFlight(1000e18);
        _step(string.concat("  adapter1 inFlightId = ", vm.toString(id1)));

        _step("[Step 2] Register adapter2 as the sole strategy and create its redeem in-flight through real flow");
        vm.startPrank(admin);
        flowController.registerStrategy(address(flowAsyncAdapter2), 10_000, 2, true);
        flowController.activateStrategy(address(flowAsyncAdapter2));
        address[] memory order2 = new address[](1);
        order2[0] = address(flowAsyncAdapter2);
        flowController.setStrategyOrder(order2);
        vm.stopPrank();

        _depositToFlowVault(flowUser, 2000e18);
        uint256 investId2 = _executeFlowRebalanceAndGetInFlightId();
        uint256 investedAmount = 1000e18;
        {
            flowVenue2.settleInvest(address(flowAsyncAdapter2), investedAmount, 0);
            uint256[] memory investIds2 = new uint256[](1);
            investIds2[0] = investId2;
            uint256[] memory investSettledPos2 = new uint256[](1);
            investSettledPos2[0] = investedAmount;
            _executeFlowSettleAdapterFor(
                address(flowAsyncAdapter2),
                investIds2,
                investSettledPos2,
                new uint256[](1),
                new uint256[](0),
                new uint256[](0)
            );
        }

        vm.prank(flowUser);
        uint256 reqId2 = flowGateway.requestRedeem(investedAmount);
        uint256 id2;
        {
            uint256[] memory reqIds2 = new uint256[](1);
            reqIds2[0] = reqId2;
            uint256 nextId = flowVault.nextInFlightId();
            _executeFlowProcessRedeemBatch(reqIds2);
            id2 = nextId;
        }
        _step(string.concat("  adapter2 inFlightId = ", vm.toString(id2)));

        _step("[Step 3] Record initial per-adapter stats");
        uint256 adapter1Before = flowVault.adapterRedeemInFlightUsdc(address(flowAsyncAdapter));
        uint256 adapter2Before = flowVault.adapterRedeemInFlightUsdc(address(flowAsyncAdapter2));
        uint256 totalBefore = flowVault.totalRedeemInFlight();
        assertGt(adapter1Before, 0);
        assertGt(adapter2Before, 0);

        _step("[Step 4] Settle only adapter1's in-flight");
        (,,,, uint256 usdc1,,,,) = flowVault.inFlightRecords(id1);
        flowVenue.settleRedeem(address(flowAsyncAdapter), usdc1);
        {
            uint256[] memory redeemIds = new uint256[](1);
            redeemIds[0] = id1;
            uint256[] memory redeemAmounts = new uint256[](1);
            redeemAmounts[0] = usdc1;
            _executeFlowSettleAdapterFor(
                address(flowAsyncAdapter),
                new uint256[](0),
                new uint256[](0),
                new uint256[](0),
                redeemIds,
                redeemAmounts
            );
        }
        _step("  settleAdapter completed for adapter1");

        _step("[Step 5] Verify adapter1 stats cleared, adapter2 untouched");
        assertEq(flowVault.adapterRedeemInFlightUsdc(address(flowAsyncAdapter)), adapter1Before - usdc1);
        _step("  PASS: adapter1 stats reduced only by its own original amount");
        assertEq(flowVault.adapterRedeemInFlightUsdc(address(flowAsyncAdapter2)), adapter2Before);
        _step("  PASS: adapter2 stats untouched");
        assertEq(flowVault.totalRedeemInFlight(), totalBefore - usdc1);
        _step("  PASS: total reduced only by adapter1's original amount");

        _step("[Step 6] Verify adapter2's in-flight still pending");
        (,,,,,,,, IMantleYieldVault.InFlightStatus s2) = flowVault.inFlightRecords(id2);
        _step(string.concat("  adapter2 in-flight status = ", vm.toString(uint8(s2))));
        assertEq(uint8(s2), uint8(IMantleYieldVault.InFlightStatus.PENDING));
        _step("  PASS: adapter2 in-flight still PENDING");
        _logPass();
    }

    // P1: after finalize, user balance, vault balance, request status all consistent
    function test_Finalize_UserReceivesSettledAssets() public {
        _logCase("test_Finalize_UserReceivesSettledAssets", unicode"finalize 后用户到账、Vault 扣减、request 状态三者一致");
        _step("[Step 1] Create a real PROCESSING request and redeem in-flight");
        (uint256 requestId, uint256 inFlightId) = _createFlowRedeemInFlight(100e18);
        uint256[] memory requestIds = new uint256[](1);
        requestIds[0] = requestId;
        _step(string.concat("  requestId = ", vm.toString(requestId), ", inFlightId = ", vm.toString(inFlightId)));

        _step("[Step 2] Settle the redeem in-flight with 100e18 so vault gets real physical cash");
        flowVenue.settleRedeem(address(flowAsyncAdapter), 100e18);
        {
            uint256[] memory redeemIds = new uint256[](1);
            redeemIds[0] = inFlightId;
            uint256[] memory redeemAmounts = new uint256[](1);
            redeemAmounts[0] = 100e18;
            _executeFlowSettleAdapter(new uint256[](0), new uint256[](0), new uint256[](0), redeemIds, redeemAmounts);
        }

        uint256 vaultBalanceBefore = flowAsset.balanceOf(address(flowVault));
        uint256 userBalanceBefore = flowAsset.balanceOf(flowUser);
        _step(string.concat("  vaultBalanceBeforeFinalize = ", vm.toString(vaultBalanceBefore)));
        assertEq(vaultBalanceBefore, 100e18, "vault should hold real settled physical cash before finalize");

        _step("[Step 3] Finalize the redeem batch");
        uint256[] memory settledAssets = new uint256[](1);
        settledAssets[0] = 100e18;
        _executeFlowFinalizeRedeemBatch(requestIds, settledAssets);
        _step("  finalizeRedeemBatch completed");

        _step("[Step 4] Verify request is DONE with correct settledAssets");
        (,,,,, uint256 reqSettled,, IMantleYieldVault.RequestStatus reqStatus) = flowVault.requests(requestId);
        _step(string.concat("  reqSettled = ", vm.toString(reqSettled)));
        _step(string.concat("  reqStatus = ", vm.toString(uint8(reqStatus))));
        assertEq(uint8(reqStatus), uint8(IMantleYieldVault.RequestStatus.DONE), "request should be DONE");
        _step("  PASS: reqStatus == DONE");
        assertEq(reqSettled, 100e18, "request settledAssets should match");
        _step("  PASS: reqSettled == 100e18");

        _step("[Step 5] Verify user received assets and vault physical balance decreased accordingly");
        uint256 vaultBalanceAfter = flowAsset.balanceOf(address(flowVault));
        uint256 userBalanceAfter = flowAsset.balanceOf(flowUser);
        _step(string.concat("  vaultBalanceAfter = ", vm.toString(vaultBalanceAfter)));
        _step(string.concat("  userBalanceDelta = ", vm.toString(userBalanceAfter - userBalanceBefore)));
        assertEq(userBalanceAfter - userBalanceBefore, 100e18, "user should receive finalized assets");
        _step("  PASS: user received 100e18");
        assertEq(vaultBalanceAfter, 0, "vault physical balance should be consumed by payout");
        _step("  PASS: vault balance decreased to 0 after payout");

        _step("[Step 6] Verify replay protection - cannot finalize same batch again");
        vm.expectRevert(abi.encodeWithSelector(
            IMantleYieldVault.Vault__InvalidState.selector, requestId, IMantleYieldVault.RequestStatus.DONE
        ));
        _executeFlowFinalizeRedeemBatch(requestIds, settledAssets);
        _step("  PASS: reverted as expected (replay protection)");
        _logPass();
    }

    // =========================================================================
    // N-13: getPosTokenPrice()=0 -> divest skips adapter (totalValue=0)
    // =========================================================================

    function test_PriceZero_DivestSkipsAdapter() public {
        _logCase(
            "test_PriceZero_DivestSkipsAdapter",
            unicode"当 adapter getPosTokenPrice 返回 0 -> totalValue=0 -> _readDivestCoverage 返回 0 -> 跳过"
        );

        _step("[Step 1] Deploy price-aware adapter whose totalValue comes from real pos balance x oracle price");
        MockAsset priceZeroPosToken = new MockAsset();
        MockSettlementVenueRR priceZeroVenue = new MockSettlementVenueRR(address(flowAsset), address(priceZeroPosToken));
        MockDFeedPriceOracle priceZeroOracle = new MockDFeedPriceOracle(1e8, 8);
        MockPricedAdapterRR priceZeroAdapter = new MockPricedAdapterRR(
            address(flowAsset),
            address(priceZeroPosToken),
            address(flowVault),
            address(priceZeroVenue),
            address(priceZeroOracle)
        );

        vm.startPrank(admin);
        flowController.registerStrategy(address(priceZeroAdapter), 10_000, 2, true);
        flowController.activateStrategy(address(priceZeroAdapter));
        address[] memory ordered = new address[](1);
        ordered[0] = address(priceZeroAdapter);
        flowController.setStrategyOrder(ordered);
        vm.stopPrank();
        _step("  adapter registered as sole strategy");

        _step("[Step 2] User deposits real assets, then bot executes real rebalance invest");
        uint256 depositAmount = 10_000e18;
        _depositToFlowVault(flowUser, depositAmount);
        uint256 investInFlightId = _executeFlowRebalanceAndGetInFlightId();
        _step(string.concat("  investInFlightId = ", vm.toString(investInFlightId)));

        uint256 expectedPosAmount = priceZeroAdapter.estimatePosAmount(depositAmount);
        priceZeroVenue.settleInvest(address(priceZeroAdapter), expectedPosAmount, 0);
        {
            uint256[] memory investIds = new uint256[](1);
            investIds[0] = investInFlightId;
            uint256[] memory investSettledPos = new uint256[](1);
            investSettledPos[0] = expectedPosAmount;
            _executeFlowSettleAdapterFor(
                address(priceZeroAdapter),
                investIds,
                investSettledPos,
                new uint256[](1),
                new uint256[](0),
                new uint256[](0)
            );
        }

        uint256 adapterValueBefore = priceZeroAdapter.totalValue();
        _step(string.concat("  adapter totalValue before price drop = ", vm.toString(adapterValueBefore)));
        assertEq(adapterValueBefore, depositAmount, "totalValue should reflect real settled pos balance at price=1");

        _step("[Step 3] Drop oracle price to 0, so totalValue becomes 0 via real adapter math");
        priceZeroOracle.setPrice(0);
        uint256 adapterValueAfterPriceDrop = priceZeroAdapter.totalValue();
        _step(string.concat("  adapter totalValue after price drop = ", vm.toString(adapterValueAfterPriceDrop)));
        assertEq(adapterValueAfterPriceDrop, 0, "price=0 should drive totalValue to 0");

        _step("[Step 4] Raise buffer to 100% and rebalance through bot -> executor");
        vm.prank(admin);
        flowController.setRiskParams(10_000, 0, 0);

        uint256 redeemIFBefore = flowVault.totalRedeemInFlight();
        uint256 inFlightCursorBefore = flowVault.nextInFlightId();
        _executeFlowRebalance();

        uint256 redeemIFAfter = flowVault.totalRedeemInFlight();
        uint256 inFlightCursorAfter = flowVault.nextInFlightId();
        _step(string.concat("  totalRedeemInFlight: ", vm.toString(redeemIFBefore), " -> ", vm.toString(redeemIFAfter)));
        _step(string.concat("  inFlight cursor: ", vm.toString(inFlightCursorBefore), " -> ", vm.toString(inFlightCursorAfter)));

        _step("[Step 5] Verify controller skipped divest because _readDivestCoverage saw totalValue=0");
        assertEq(redeemIFAfter, redeemIFBefore, "no redeem in-flight should be created when totalValue=0");
        assertEq(inFlightCursorAfter, inFlightCursorBefore, "no new in-flight record should be created");
        assertEq(priceZeroVenue.pendingRedeemPos(address(priceZeroAdapter)), 0, "adapter should not submit redeem to venue");
        _step("  PASS: price=0 led to totalValue=0, adapter was skipped, no divest side effects occurred");
        _logPass();
    }
}

// =============================================================
// Mock contracts for real-vault tests
// =============================================================

contract MockUSDC6 is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockPosToken6 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockSanctionsOracleForRisk is ISanctionsOracle {
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

contract MockSubRedManagementForRisk {
    function subscribe(address, address currencyToken, uint256 amount, uint256) external {
        ERC20(currencyToken).transferFrom(msg.sender, address(this), amount);
    }

    function redeem(address, address, uint256, uint256) external {}
}

contract MockVaultForAdapterSweep {
    ERC20 public immutable usdc;

    constructor(address asset_) {
        usdc = ERC20(asset_);
    }

    function asset() external view returns (address) {
        return address(usdc);
    }
}

// =============================================================
// Part B: getTokenInfos regression tests (using real MantleYieldVault)
// =============================================================

contract RiskRegressionGetTokenInfosTest is Test {
    MockUSDC6 internal usdc;
    MockPosToken6 internal posTokenA;
    MockPosToken6 internal posTokenB;
    SanctionsOracle internal sanctionsOracle;
    Accountant internal accountant;
    StrategyController internal controller;
    OperatorExecutor internal operatorExecutor;

    MantleYieldVault internal vault;
    MantleVaultGateway internal gateway;

    address internal adminAddr = makeAddr("admin");
    address internal botAddr = makeAddr("bot");
    address internal treasuryAddr = makeAddr("treasury");
    address internal depositor = makeAddr("depositor");
    address internal posHolderA = makeAddr("posHolderA");
    address internal posHolderB = makeAddr("posHolderB");
    address internal complianceBot = makeAddr("complianceBot");

    // Mock adapters implementing IStrategyAdapter for vault registration
    MockStrategyAdapterForVault internal adapterA;
    MockStrategyAdapterForVault internal adapterB;

    string constant MODULE = unicode"风险回归场景";
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

    function setUp() public {
        usdc = new MockUSDC6();
        posTokenA = new MockPosToken6("PosTokenA", "PTA");
        posTokenB = new MockPosToken6("PosTokenB", "PTB");
        SanctionsOracle oracleImpl = new SanctionsOracle();
        SanctionsOracleFactory oracleFactory = new SanctionsOracleFactory(address(oracleImpl), adminAddr);
        vm.prank(adminAddr);
        sanctionsOracle = SanctionsOracle(oracleFactory.deployAndInitOracle(adminAddr, complianceBot));

        MantleYieldVault impl = new MantleYieldVault();
        MantleVaultGateway gatewayImpl = new MantleVaultGateway();
        VaultFactory factory = new VaultFactory(address(impl), adminAddr);
        GatewayFactory gatewayFactory = new GatewayFactory(address(gatewayImpl), adminAddr);

        address vaultAddr = factory.deployVault();
        address gatewayAddr = gatewayFactory.deployGateway();
        vault = MantleYieldVault(vaultAddr);
        gateway = MantleVaultGateway(gatewayAddr);

        IMantleYieldVault.InitParams memory params = IMantleYieldVault.InitParams({
            asset: IERC20(address(usdc)),
            name: "Mantle RWA Vault",
            symbol: "mRWA",
            admin: adminAddr,
            gateway: gatewayAddr,
            controller: address(1),
            accountant: address(1), // placeholder, replaced below
            treasury: treasuryAddr,
            maxRedemptionFeeBps: 500,
            redemptionFeeBps: 100,
            minRedeemAmount: 0,
            minDepositAmount: 0,
            maxSettlementDeviationBps: 0,
            depositDailyRemaining: type(uint256).max,
            redeemDailyRemaining: type(uint256).max
        });
        vm.prank(adminAddr);
        vault.initialize(params);

        // Deploy real Accountant
        Accountant acctImpl = new Accountant();
        accountant = Accountant(address(new ERC1967Proxy(
            address(acctImpl),
            abi.encodeCall(Accountant.initialize, (address(vault), uint64(1e18), 0, adminAddr, adminAddr, adminAddr))
        )));
        vm.prank(adminAddr);
        vault.setAccountant(address(accountant));

        OperatorExecutor executorImpl = new OperatorExecutor();
        operatorExecutor = OperatorExecutor(address(new ERC1967Proxy(
            address(executorImpl),
            abi.encodeCall(OperatorExecutor.initialize, (adminAddr, botAddr))
        )));

        StrategyController controllerImpl = new StrategyController();
        controller = StrategyController(address(new ERC1967Proxy(
            address(controllerImpl),
            abi.encodeCall(StrategyController.initialize, (vaultAddr, adminAddr, address(operatorExecutor), adminAddr, 0, 0, 0))
        )));
        vm.prank(adminAddr);
        vault.setController(address(controller));

        vm.prank(adminAddr);
        gateway.initialize(
            IMantleVaultGateway.InitParams({
                vault: vaultAddr,
                sanctionsOracle: ISanctionsOracle(address(sanctionsOracle)),
                sanctionSafe: treasuryAddr,
                admin: adminAddr,
                syncRedeemDisabled: false
            })
        );

        adapterA = new MockStrategyAdapterForVault(address(usdc), address(posTokenA), 1e18);
        adapterB = new MockStrategyAdapterForVault(address(usdc), address(posTokenB), 1e18);
    }

    function _registerAdapter(address adapter, uint16 priority) internal {
        vm.prank(adminAddr);
        controller.registerStrategy(adapter, 0, priority, true);
    }

    function _depositToVault(uint256 assetAmount) internal {
        usdc.mint(depositor, assetAmount);
        vm.startPrank(depositor);
        usdc.approve(address(vault), assetAmount);
        gateway.deposit(assetAmount);
        vm.stopPrank();
    }

    function _transferPosToVault(MockPosToken6 token, address holder, uint256 amount) internal {
        token.mint(holder, amount);
        vm.prank(holder);
        token.transfer(address(vault), amount);
    }

    // P0: getTokenInfos() with 0 adapters returns correct format
    function test_GetTokenInfos_ZeroAdapters() public {
        _logCase(
            "test_GetTokenInfos_ZeroAdapters",
            unicode"`getTokenInfos()` 在 0 个 adapter 时返回格式正确"
        );

        _step("[Step 1] Vault has no adapters registered");

        _step("[Step 2] Call getTokenInfos()");
        IMantleYieldVault.tokenInfo[] memory infos = vault.getTokenInfos();

        _step("[Step 3] Verify array length == 1 (only underlying asset)");
        _step(string.concat("  infos.length = ", vm.toString(infos.length)));
        assertEq(infos.length, 1, "should contain exactly 1 entry (underlying asset)");
        _step("  PASS: infos.length == 1");

        _step("[Step 4] Verify infos[0] is the underlying asset");
        _step(string.concat("  infos[0].token = ", vm.toString(infos[0].token)));
        assertEq(infos[0].token, address(usdc), "infos[0].token should be vault asset");
        _step("  PASS: infos[0].token == asset()");

        _step("[Step 5] Verify tokenAmount and usdcAmount are based on vault balance");
        uint256 expectedBalance = usdc.balanceOf(address(vault));
        _step(string.concat("  infos[0].tokenAmount = ", vm.toString(infos[0].tokenAmount)));
        _step(string.concat("  infos[0].usdcAmount = ", vm.toString(infos[0].usdcAmount)));
        assertEq(infos[0].tokenAmount, expectedBalance, "tokenAmount should equal vault USDC balance");
        _step("  PASS: tokenAmount matches vault balance");
        assertEq(infos[0].usdcAmount, expectedBalance, "usdcAmount should equal vault USDC balance");
        _step("  PASS: usdcAmount matches vault balance");
        _logPass();
    }

    // P0: getTokenInfos() with 1 adapter returns complete and correct info
    function test_GetTokenInfos_OneAdapter() public {
        _logCase(
            "test_GetTokenInfos_OneAdapter",
            unicode"`getTokenInfos()` 在 1 个 adapter 时返回完整且正确"
        );

        _step("[Step 1] Register 1 adapter (adapterA)");
        _registerAdapter(address(adapterA), 1);

        _step("[Step 2] External holder transfers settled posTokenA to vault");
        _transferPosToVault(posTokenA, posHolderA, 500e6);

        _step("[Step 3] Call getTokenInfos()");
        IMantleYieldVault.tokenInfo[] memory infos = vault.getTokenInfos();

        _step("[Step 4] Verify array length == 2");
        _step(string.concat("  infos.length = ", vm.toString(infos.length)));
        assertEq(infos.length, 2, "should be adapters.length + 1 = 2");
        _step("  PASS: infos.length == 2");

        _step("[Step 5] Verify infos[0] is the underlying asset");
        assertEq(infos[0].token, address(usdc), "infos[0].token should be asset");
        _step(string.concat("  infos[0].token = ", vm.toString(infos[0].token)));
        _step("  PASS: infos[0].token == asset()");

        _step("[Step 6] Verify infos[1] is adapterA's posToken info");
        _step(string.concat("  infos[1].token = ", vm.toString(infos[1].token)));
        assertEq(infos[1].token, address(posTokenA), "infos[1].token should be adapterA.posToken()");
        _step("  PASS: infos[1].token == adapterA.posToken()");

        _step("[Step 7] Verify infos[1].tokenAmount includes posToken balance");
        _step(string.concat("  infos[1].tokenAmount = ", vm.toString(infos[1].tokenAmount)));
        assertEq(infos[1].tokenAmount, 500e6, "tokenAmount should reflect posToken balance in vault");
        _step("  PASS: infos[1].tokenAmount == 500e6");

        _step("[Step 8] Verify infos[1].usdcAmount is correctly computed");
        // price=1e18, assetScale=1e6, tokenScale=1e6 => usdcAmount = tokenAmount * price / 1e18 * assetScale / tokenScale
        // = 500e6 * 1e18 / 1e18 * 1e6 / 1e6 = 500e6
        _step(string.concat("  infos[1].usdcAmount = ", vm.toString(infos[1].usdcAmount)));
        assertEq(infos[1].usdcAmount, 500e6, "usdcAmount should match with price=1e18");
        _step("  PASS: infos[1].usdcAmount == 500e6");
        _logPass();
    }

    // P0: getTokenInfos() with 2 adapters all correctly mapped
    function test_GetTokenInfos_TwoAdapters() public {
        _logCase(
            "test_GetTokenInfos_TwoAdapters",
            unicode"`getTokenInfos()` 在 2 个 adapter 时所有 adapter 均正确映射"
        );

        _step("[Step 1] Register 2 adapters (adapterA, adapterB)");
        _registerAdapter(address(adapterA), 1);
        _registerAdapter(address(adapterB), 2);

        _step("[Step 2] Form real vault balances: user deposits USDC, external holders transfer posTokens");
        _depositToVault(100e6);
        _transferPosToVault(posTokenA, posHolderA, 300e6);
        _transferPosToVault(posTokenB, posHolderB, 700e6);

        _step("[Step 3] Call getTokenInfos()");
        IMantleYieldVault.tokenInfo[] memory infos = vault.getTokenInfos();

        _step("[Step 4] Verify array length == 3");
        _step(string.concat("  infos.length = ", vm.toString(infos.length)));
        assertEq(infos.length, 3, "should be adapters.length + 1 = 3");
        _step("  PASS: infos.length == 3");

        _step("[Step 5] Verify infos[0] is underlying asset");
        assertEq(infos[0].token, address(usdc));
        _step(string.concat("  infos[0].token = ", vm.toString(infos[0].token)));
        _step("  PASS: infos[0].token == asset()");

        _step("[Step 6] Verify infos[1] corresponds to adapterA (adapters[0])");
        assertEq(infos[1].token, address(posTokenA), "infos[1] should be adapterA");
        _step(string.concat("  infos[1].token = ", vm.toString(infos[1].token)));
        assertEq(infos[1].tokenAmount, 300e6, "adapterA tokenAmount");
        _step(string.concat("  infos[1].tokenAmount = ", vm.toString(infos[1].tokenAmount)));
        assertEq(infos[1].usdcAmount, 300e6, "adapterA usdcAmount at price=1e18");
        _step(string.concat("  infos[1].usdcAmount = ", vm.toString(infos[1].usdcAmount)));
        _step("  PASS: infos[1] matches adapterA");

        _step("[Step 7] Verify infos[2] corresponds to adapterB (adapters[1])");
        assertEq(infos[2].token, address(posTokenB), "infos[2] should be adapterB");
        _step(string.concat("  infos[2].token = ", vm.toString(infos[2].token)));
        assertEq(infos[2].tokenAmount, 700e6, "adapterB tokenAmount");
        _step(string.concat("  infos[2].tokenAmount = ", vm.toString(infos[2].tokenAmount)));
        assertEq(infos[2].usdcAmount, 700e6, "adapterB usdcAmount at price=1e18");
        _step(string.concat("  infos[2].usdcAmount = ", vm.toString(infos[2].usdcAmount)));
        _step("  PASS: infos[2] matches adapterB");
        _logPass();
    }

    // P0: getTokenInfos() loop index regression test
    function test_GetTokenInfos_LoopIndexRegression() public {
        _logCase(
            "test_GetTokenInfos_LoopIndexRegression",
            unicode"`getTokenInfos()` 循环索引回归测试"
        );

        _step("[Step 1] Register 2 adapters");
        _registerAdapter(address(adapterA), 1);
        _registerAdapter(address(adapterB), 2);

        _step("[Step 2] External holders transfer distinct posToken balances to vault");
        _transferPosToVault(posTokenA, posHolderA, 111e6);
        _transferPosToVault(posTokenB, posHolderB, 222e6);

        _step("[Step 3] Call getTokenInfos()");
        IMantleYieldVault.tokenInfo[] memory infos = vault.getTokenInfos();

        _step("[Step 4] Verify infos[1] is adapters[0]'s info (adapterA)");
        assertEq(infos[1].token, address(posTokenA), "infos[1] must map to adapters[0]");
        assertEq(infos[1].tokenAmount, 111e6, "infos[1].tokenAmount must match adapterA posToken balance");
        _step(string.concat("  infos[1].token = ", vm.toString(infos[1].token)));
        _step(string.concat("  infos[1].tokenAmount = ", vm.toString(infos[1].tokenAmount)));
        _step("  PASS: infos[1] == adapters[0] info");

        _step("[Step 5] Verify infos[2] is adapters[1]'s info (adapterB)");
        assertEq(infos[2].token, address(posTokenB), "infos[2] must map to adapters[1]");
        assertEq(infos[2].tokenAmount, 222e6, "infos[2].tokenAmount must match adapterB posToken balance");
        _step(string.concat("  infos[2].token = ", vm.toString(infos[2].token)));
        _step(string.concat("  infos[2].tokenAmount = ", vm.toString(infos[2].tokenAmount)));
        _step("  PASS: infos[2] == adapters[1] info");

        _step("[Step 6] Verify no empty slots - all entries have non-zero token address");
        for (uint256 i = 0; i < infos.length; i++) {
            assertTrue(infos[i].token != address(0), "no empty slot allowed");
        }
        _step("  PASS: no empty slots detected");
        _logPass();
    }
}

// =============================================================
// Mock adapter implementing IStrategyAdapter for real vault tests
// =============================================================

contract MockStrategyAdapterForVault is IStrategyAdapter {
    address public immutable ASSET;
    address public immutable POS_TOKEN;
    uint256 public mockPrice;

    constructor(address asset_, address posToken_, uint256 price_) {
        ASSET = asset_;
        POS_TOKEN = posToken_;
        mockPrice = price_;
    }

    function name() external pure returns (string memory) {
        return "MockStrategyAdapterForVault";
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

    function getPosTokenPrice() external view returns (uint256) {
        return mockPrice;
    }

    function estimatePosAmount(uint256 assetAmount) external pure returns (uint256) {
        return assetAmount;
    }

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

    function vault() external pure returns (address) {
        return address(0);
    }

    function totalValue() external pure returns (uint256) {
        return 0;
    }

    function deposit(uint256 amount, address) external pure returns (uint256) {
        return amount;
    }

    function withdrawSync(uint256 amount, address) external pure returns (uint256) {
        return amount;
    }

    function requestRedeemAsync(uint256, address) external pure {}

    function retryRedeemAsync(uint256, address) external {}

    function sweepToVault(address, uint256 amount) external pure returns (uint256) {
        return amount;
    }

    function setPaused(bool) external pure {}
}

// =============================================================
// Part C: Adapter getPosTokenPrice fallback chain, setManualPosTokenPrice, sweep protection
// =============================================================

contract RiskRegressionAdapterTest is Test {
    MockUSDC6 internal usdc;
    MockPosToken6 internal stToken;
    MockUSDC6 internal otherToken;
    MockDFeedPriceOracle internal oracle;
    MockSubRedManagementForRisk internal subRed;
    MockVaultForAdapterSweep internal adapterVault;

    SubRedManagementAdapter internal adapterWithOracle;
    SubRedManagementAdapter internal adapterNoOracle;

    address internal adminAddr = makeAddr("adapterAdmin");
    address internal controllerAddr = makeAddr("adapterController");
    address internal accountantExecutorAddr = makeAddr("accountantExecutor");
    address internal receiver = makeAddr("receiver");
    address internal stHolder = makeAddr("stHolder");
    address internal usdcHolder = makeAddr("usdcHolder");
    address internal otherTokenHolder = makeAddr("otherTokenHolder");

    string constant MODULE = unicode"风险回归场景";
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

    function _transferStToVault(address vaultAddr, uint256 amount) internal {
        stToken.mint(stHolder, amount);
        vm.prank(stHolder);
        stToken.transfer(vaultAddr, amount);
    }

    function _transferTokenToAdapter(ERC20 token, address holder, address adapter, uint256 amount) internal {
        if (address(token) == address(usdc)) {
            usdc.mint(holder, amount);
        } else if (address(token) == address(stToken)) {
            stToken.mint(holder, amount);
        } else if (address(token) == address(otherToken)) {
            otherToken.mint(holder, amount);
        }
        vm.prank(holder);
        token.transfer(adapter, amount);
    }

    function setUp() public {
        usdc = new MockUSDC6();
        stToken = new MockPosToken6("SecurityToken", "ST");
        otherToken = new MockUSDC6();
        oracle = new MockDFeedPriceOracle(2e8, 8); // price=2, decimals=8
        subRed = new MockSubRedManagementForRisk();
        adapterVault = new MockVaultForAdapterSweep(address(usdc));

        // Adapter with oracle configured
        adapterWithOracle = new SubRedManagementAdapter(
            address(adapterVault),
            address(subRed),
            address(stToken),
            adminAddr,
            controllerAddr,
            accountantExecutorAddr,
            address(oracle)
        );

        // Adapter without oracle
        adapterNoOracle = new SubRedManagementAdapter(
            address(adapterVault),
            address(subRed),
            address(stToken),
            adminAddr,
            controllerAddr,
            accountantExecutorAddr,
            address(0)
        );
    }

    // P1: getPosTokenPrice() fallback chain verification
    function test_GetPosTokenPrice_FallbackChain() public {
        _logCase(
            "test_GetPosTokenPrice_FallbackChain",
            unicode"Adapter `getPosTokenPrice()` 价格回退链验证"
        );

        _step("[Step 1] Oracle with valid price > 0: should use oracle price");
        // oracle price = 2e8, decimals = 8 => normalized = 2e8 * 1e18 / 10^8 = 2e18
        uint256 price1 = adapterWithOracle.getPosTokenPrice();
        _step(string.concat("  getPosTokenPrice() = ", vm.toString(price1)));
        assertEq(price1, 2e18, "should use oracle price: 2e18");
        _step("  PASS: oracle price used (2e18)");

        _step("[Step 2] Oracle getPrice() returns 0, manualPosTokenPrice > 0: should fallback to manual");
        oracle.setPrice(0);
        // Set manual price on the adapter that has oracle (but oracle returns 0)
        // Since priceOracle != address(0), setManualPosTokenPrice will revert with Unsupported()
        // So we test with adapterNoOracle which has no oracle
        vm.prank(accountantExecutorAddr);
        adapterNoOracle.setManualPosTokenPrice(1.05e18);
        uint256 price2 = adapterNoOracle.getPosTokenPrice();
        _step(string.concat("  getPosTokenPrice() = ", vm.toString(price2)));
        assertEq(price2, 1.05e18, "should use manual price: 1.05e18");
        _step("  PASS: manual price used (1.05e18)");

        _step("[Step 3] No oracle AND manual price = 0: should return 0 (M-6: fallback changed from 1e18 to 0)");
        // Deploy a fresh adapter without oracle and no manual price set
        SubRedManagementAdapter freshAdapter = new SubRedManagementAdapter(
            address(adapterVault),
            address(subRed),
            address(stToken),
            adminAddr,
            controllerAddr,
            accountantExecutorAddr,
            address(0)
        );
        uint256 price3 = freshAdapter.getPosTokenPrice();
        _step(string.concat("  getPosTokenPrice() = ", vm.toString(price3)));
        assertEq(price3, 0, "should fallback to 0 when no oracle and no manual price (M-6)");
        _step("  PASS: fallback returned 0");
        _logPass();
    }

    // P1: setManualPosTokenPrice rejected when oracle is configured
    function test_SetManualPosTokenPrice_RevertWhenOracleConfigured() public {
        _logCase(
            "test_SetManualPosTokenPrice_RevertWhenOracleConfigured",
            unicode"adapter 的 `setManualPosTokenPrice` 仅 `accountantExecutor` 可调用且 oracle 已配置时被拒绝"
        );

        _step("[Step 1] Adapter has priceOracle configured");
        _step(string.concat("  priceOracle = ", vm.toString(adapterWithOracle.priceOracle())));
        assertTrue(adapterWithOracle.priceOracle() != address(0), "oracle should be configured");
        _step("  PASS: priceOracle != address(0)");

        _step("[Step 2] accountantExecutor calls setManualPosTokenPrice(1.05e18) -> expect revert Unsupported()");
        vm.prank(accountantExecutorAddr);
        vm.expectRevert(abi.encodeWithSignature("Adapter__Unsupported()"));
        adapterWithOracle.setManualPosTokenPrice(1.05e18);
        _step("  PASS: reverted with Unsupported() as expected");
        _logPass();
    }

    // P1: Adapter sweep protects asset and posToken
    function test_Sweep_ProtectsAssetAndPosToken() public {
        _logCase(
            "test_Sweep_ProtectsAssetAndPosToken",
            unicode"Adapter sweep 保护底层资产和 `posToken`"
        );

        _step("[Step 1] External holders transfer tokens to adapter");
        _transferTokenToAdapter(usdc, usdcHolder, address(adapterWithOracle), 100e6);
        _transferTokenToAdapter(stToken, stHolder, address(adapterWithOracle), 200e6);
        _transferTokenToAdapter(otherToken, otherTokenHolder, address(adapterWithOracle), 50e6);

        _step("[Step 2] admin calls sweep(asset, receiver) -> expect revert SweepProtectedToken");
        vm.prank(adminAddr);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("Adapter__SweepProtectedToken(address)")), address(usdc)));
        adapterWithOracle.sweep(address(usdc), receiver);
        _step("  PASS: sweep(asset) reverted with SweepProtectedToken");

        _step("[Step 3] admin calls sweep(posToken, receiver) -> expect revert SweepProtectedToken");
        vm.prank(adminAddr);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("Adapter__SweepProtectedToken(address)")), address(stToken)));
        adapterWithOracle.sweep(address(stToken), receiver);
        _step("  PASS: sweep(posToken) reverted with SweepProtectedToken");

        _step("[Step 4] admin calls sweep(otherToken, receiver) -> success");
        vm.prank(adminAddr);
        adapterWithOracle.sweep(address(otherToken), receiver);
        _step(string.concat("  receiver otherToken balance = ", vm.toString(otherToken.balanceOf(receiver))));
        assertEq(otherToken.balanceOf(receiver), 50e6, "otherToken should be swept to receiver");
        _step("  PASS: sweep(otherToken) succeeded");
        assertEq(otherToken.balanceOf(address(adapterWithOracle)), 0, "adapter should have 0 otherToken left");
        _step("  PASS: adapter otherToken balance == 0");
        _logPass();
    }

    // =========================================================================
    // N-12: getPosTokenPrice()=0 fallback behavior in totalValue()
    // =========================================================================

    function test_PriceZero_TotalValueFallback() public {
        _logCase(
            "test_PriceZero_TotalValueFallback",
            unicode"当 adapter 无有效价格源时（getPosTokenPrice 返回 0），totalValue() 返回 0，影响 rebalance 和 totalAssets 计算"
        );

        _step("[Step 1] Deploy fresh adapter without oracle and no manual price");
        SubRedManagementAdapter freshAdapter = new SubRedManagementAdapter(
            address(adapterVault),
            address(subRed),
            address(stToken),
            adminAddr,
            controllerAddr,
            accountantExecutorAddr,
            address(0) // no oracle
        );
        uint256 price = freshAdapter.getPosTokenPrice();
        assertEq(price, 0, "price should be 0 (no oracle, no manual) - M-6 regression");
        _step(string.concat("  getPosTokenPrice() = ", vm.toString(price)));

        _step("[Step 2] External holder transfers posTokens to vault (both USDC and stToken are 6 decimals)");
        _transferStToVault(address(adapterVault), 1000e6);
        uint256 stBalance = stToken.balanceOf(address(adapterVault));
        _step(string.concat("  stToken balance on vault: ", vm.toString(stBalance)));

        _step("[Step 3] Verify totalValue() returns 0 when price=0 (no fallback to raw scaling)");
        // When price=0, _estimateAssetAmount returns 0 immediately (line: if (priceE18 == 0) return 0)
        uint256 tv = freshAdapter.totalValue();
        _step(string.concat("  totalValue() = ", vm.toString(tv)));
        assertEq(tv, 0, "totalValue = 0 when price=0 (no fallback)");
        _step("  PASS: price=0 -> totalValue returns 0");

        _step("[Step 4] With no posTokens on vault, totalValue=0 regardless of price");
        // Deploy another adapter pointing to a vault with no stTokens
        MockVaultForAdapterSweep emptyVault = new MockVaultForAdapterSweep(address(usdc));
        SubRedManagementAdapter emptyAdapter = new SubRedManagementAdapter(
            address(emptyVault),
            address(subRed),
            address(stToken),
            adminAddr,
            controllerAddr,
            accountantExecutorAddr,
            address(0)
        );
        uint256 tvEmpty = emptyAdapter.totalValue();
        assertEq(tvEmpty, 0, "totalValue=0 when no posTokens on vault");
        _step(string.concat("  totalValue() with empty vault = ", vm.toString(tvEmpty)));
        _step("  PASS: no posTokens -> totalValue=0");
        _logPass();
    }
}

// =============================================================
// Part D: SanctionSafeIn event tests (shares routing + sanctions payout)
// =============================================================

contract RiskRegressionSanctionSafeInTest is Test {
    MockUSDC6 internal usdc;
    SanctionsOracle internal sanctionsOracle;
    Accountant internal accountant;
    StrategyController internal controller;
    OperatorExecutor internal operatorExecutor;

    MantleYieldVault internal vault;
    MantleVaultGateway internal gateway;

    address internal adminAddr = makeAddr("admin");
    address internal complianceBot = makeAddr("complianceBot");
    address internal bot = makeAddr("bot");
    address internal controllerAddr = makeAddr("controller");
    address internal treasuryAddr = makeAddr("treasury");
    address internal sanctionSafeAddr = makeAddr("sanctionSafe");
    address internal sanctionedUser = makeAddr("sanctionedUser");
    address internal normalUser = makeAddr("normalUser");

    string constant MODULE = unicode"风险回归场景";
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

    function _setSanctioned(address account, bool status) internal {
        vm.prank(complianceBot);
        sanctionsOracle.updateSanctionStatus(account, status);
    }

    function _processRedeemBatch(uint256[] memory ids) internal {
        vm.prank(bot);
        operatorExecutor.executeProcessRedeemBatch(address(controller), ids);
    }

    function _finalizeRedeemBatch(uint256[] memory ids, uint256[] memory settledAssets) internal {
        vm.prank(bot);
        operatorExecutor.executeFinalizeRedeemBatch(address(controller), ids, settledAssets);
    }

    function setUp() public {
        usdc = new MockUSDC6();
        SanctionsOracle oracleImpl = new SanctionsOracle();
        SanctionsOracleFactory oracleFactory = new SanctionsOracleFactory(address(oracleImpl), adminAddr);
        vm.prank(adminAddr);
        sanctionsOracle = SanctionsOracle(oracleFactory.deployAndInitOracle(adminAddr, complianceBot));

        MantleYieldVault impl = new MantleYieldVault();
        MantleVaultGateway gatewayImpl = new MantleVaultGateway();
        VaultFactory factory = new VaultFactory(address(impl), adminAddr);
        GatewayFactory gatewayFactory = new GatewayFactory(address(gatewayImpl), adminAddr);

        address vaultAddr = factory.deployVault();
        address gatewayAddr = gatewayFactory.deployGateway();
        vault = MantleYieldVault(vaultAddr);
        gateway = MantleVaultGateway(gatewayAddr);

        IMantleYieldVault.InitParams memory params = IMantleYieldVault.InitParams({
            asset: IERC20(address(usdc)),
            name: "Mantle RWA Vault",
            symbol: "mRWA",
            admin: adminAddr,
            gateway: gatewayAddr,
            controller: controllerAddr,
            accountant: address(1), // placeholder, replaced below
            treasury: treasuryAddr,
            maxRedemptionFeeBps: 500,
            redemptionFeeBps: 0, // No fee for simpler math
            minRedeemAmount: 0,
            minDepositAmount: 0,
            maxSettlementDeviationBps: 0,
            depositDailyRemaining: type(uint256).max,
            redeemDailyRemaining: type(uint256).max
        });
        vm.prank(adminAddr);
        vault.initialize(params);

        // Deploy real Accountant
        Accountant acctImpl = new Accountant();
        accountant = Accountant(address(new ERC1967Proxy(
            address(acctImpl),
            abi.encodeCall(Accountant.initialize, (address(vault), uint64(1e18), 0, adminAddr, adminAddr, adminAddr))
        )));
        vm.prank(adminAddr);
        vault.setAccountant(address(accountant));

        OperatorExecutor executorImpl = new OperatorExecutor();
        operatorExecutor = OperatorExecutor(address(new ERC1967Proxy(
            address(executorImpl),
            abi.encodeCall(OperatorExecutor.initialize, (adminAddr, bot))
        )));

        StrategyController controllerImpl = new StrategyController();
        controller = StrategyController(address(new ERC1967Proxy(
            address(controllerImpl),
            abi.encodeCall(StrategyController.initialize, (vaultAddr, adminAddr, address(operatorExecutor), adminAddr, 0, 0, 0))
        )));
        vm.prank(adminAddr);
        vault.setController(address(controller));

        vm.prank(adminAddr);
        gateway.initialize(
            IMantleVaultGateway.InitParams({
                vault: vaultAddr,
                sanctionsOracle: ISanctionsOracle(address(sanctionsOracle)),
                sanctionSafe: sanctionSafeAddr,
                admin: adminAddr,
                syncRedeemDisabled: false
            })
        );

        // Deposit some USDC for normalUser and sanctionedUser
        usdc.mint(normalUser, 10_000e6);
        vm.startPrank(normalUser);
        usdc.approve(address(vault), type(uint256).max);
        gateway.deposit(10_000e6);
        vm.stopPrank();

        // Transfer some shares to sanctionedUser
        vm.prank(normalUser);
        vault.transfer(sanctionedUser, 1000e6);
    }

    // P1: SanctionSafeIn event on both shares routing and sanctions payout paths
    function test_SanctionSafeIn_BothPaths() public {
        _logCase(
            "test_SanctionSafeIn_BothPaths",
            unicode"SanctionSafeIn 事件在 shares 路由与 sanctions payout 两种路径下均按当前实现正确记录"
        );

        // ---- Path 1: Sanctioned user calls gateway.requestRedeem -> shares routed to sanctionSafe ----
        _step("[Step 1] Path 1: Sanctioned user calls gateway.requestRedeem, triggering shares routing");
        _setSanctioned(sanctionedUser, true);

        uint256 sharesToRedeem = 500e6;
        uint256 sanctionSafeSharesBefore = vault.balanceOf(sanctionSafeAddr);
        _step(string.concat("  sanctionedUser shares = ", vm.toString(vault.balanceOf(sanctionedUser))));
        _step(string.concat("  sanctionSafe shares before = ", vm.toString(sanctionSafeSharesBefore)));

        vm.prank(sanctionedUser);
        vm.expectEmit(true, true, false, true, address(vault));
        emit IMantleYieldVault.SanctionSafeIn(sanctionedUser, address(vault), sharesToRedeem);
        uint256 requestId = gateway.requestRedeem(sharesToRedeem);
        _step(string.concat("  requestId = ", vm.toString(requestId)));
        assertEq(requestId, 0, "should return 0 for sanctioned user (no real request created)");
        _step("  PASS: requestId == 0 (sanctioned path)");

        uint256 sanctionSafeSharesAfter = vault.balanceOf(sanctionSafeAddr);
        _step(string.concat("  sanctionSafe shares after = ", vm.toString(sanctionSafeSharesAfter)));
        assertEq(
            sanctionSafeSharesAfter,
            sanctionSafeSharesBefore + sharesToRedeem,
            "sanctionSafe should receive the shares"
        );
        _step("  PASS: SanctionSafeIn emitted for shares routing path");

        // ---- Path 2: Normal user creates request, then gets sanctioned, then settlement pays to sanctionSafe ----
        _step("[Step 2] Path 2: Normal user requests redeem, then gets sanctioned before settlement");

        // normalUser requests redeem
        uint256 normalShares = 1000e6;
        vm.prank(normalUser);
        uint256 reqId = gateway.requestRedeem(normalShares);
        _step(string.concat("  normalUser requestId = ", vm.toString(reqId)));
        assertTrue(reqId > 0, "should create a valid request");
        _step("  PASS: request created successfully");

        // Process the request through the real bot -> operator -> controller chain
        uint256[] memory reqIds = new uint256[](1);
        reqIds[0] = reqId;
        _processRedeemBatch(reqIds);
        _step("  request moved to PROCESSING");

        // Now sanction the normal user
        _setSanctioned(normalUser, true);
        _step("  normalUser is now sanctioned");

        // Finalize - should pay to sanctionSafe and emit SanctionSafeIn
        // Vault already has real physical USDC from the shared pool deposit in setUp
        (,,,, uint256 estimatedAssets,,,) = vault.requests(reqId);
        _step(string.concat("  estimatedAssets = ", vm.toString(estimatedAssets)));

        uint256[] memory settledAssets = new uint256[](1);
        settledAssets[0] = estimatedAssets;

        _step("[Step 3] Finalize redeem batch -> expect SanctionSafeIn event for sanctions payout path");
        vm.expectEmit(true, true, false, true, address(vault));
        emit IMantleYieldVault.SanctionSafeIn(normalUser, address(usdc), estimatedAssets);
        _finalizeRedeemBatch(reqIds, settledAssets);
        _step("  PASS: SanctionSafeIn emitted for sanctions payout path");

        _step("[Step 4] Verify sanctionSafe received the USDC payout");
        uint256 safeUsdcBalance = usdc.balanceOf(sanctionSafeAddr);
        _step(string.concat("  sanctionSafe USDC balance = ", vm.toString(safeUsdcBalance)));
        assertEq(safeUsdcBalance, estimatedAssets, "sanctionSafe should receive the settled assets");
        _step("  PASS: sanctionSafe received USDC payout");
        _logPass();
    }
}
