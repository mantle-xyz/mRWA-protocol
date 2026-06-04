// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SubRedManagementAdapter} from "../../src/adapters/digift/SubRedManagementAdapter.sol";
import {ISubRedManagement} from "../../src/interfaces/adapters/digift/ISubRedManagement.sol";
import {IStrategyControllerExecutor} from "../../src/interfaces/strategy/IStrategyControllerExecutor.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";

contract MockStableFlow is ERC20 {
    constructor() ERC20("MockStable", "mStable") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockSTTokenFlow is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockAccountantFlow {
    bool public paused;

    function setPaused(bool paused_) external {
        paused = paused_;
    }
}

contract MockSubRedManagementFlow is ISubRedManagement {
    address public lastStToken;
    uint256 public lastAmount;
    uint256 public subscribeCount;

    function subscribe(address stToken, address currencyToken, uint256 amount, uint256) external override {
        lastStToken = stToken;
        lastAmount = amount;
        subscribeCount++;
        ERC20(currencyToken).transferFrom(msg.sender, address(this), amount);
    }

    function redeem(address, address, uint256, uint256) external override {}
}

contract MockVaultFlow {
    ERC20 public immutable stable;
    address public accountant;
    uint256 public mockedExchangeRate = 1e18;

    uint256 public lockedTotal;
    uint256 public investInFlightTotal;
    uint256 public redeemInFlightTotal;
    uint256 public requestIdCursor;
    uint256 public inFlightIdCursor;
    uint256 public pendingRequestCount;
    mapping(address => uint256) public investInFlightByAdapter;
    mapping(address => uint256) public redeemInFlightByAdapter;
    mapping(address => bool) public isAdapterRegistry;
    address[] public adapterList;

    mapping(uint256 => uint256) public liabilities;
    mapping(uint256 => IMantleYieldVault.RequestStatus) public requestStatus;

    struct InFlightData {
        uint256 id;
        address adapter;
        address assetAddr;
        uint256 tokenAmount;
        uint256 stableAmount;
        uint256 settledAmount;
        bool isInvest;
        uint256 timestamp;
        IMantleYieldVault.InFlightStatus status;
    }

    mapping(uint256 => InFlightData) internal inFlights;

    constructor(address asset_) {
        stable = ERC20(asset_);
    }

    function asset() external view returns (address) {
        return address(stable);
    }

    function setAccountant(address accountant_) external {
        accountant = accountant_;
    }

    function deposit(uint256 amount) external {
        stable.transferFrom(msg.sender, address(this), amount);
    }

    function setLiability(uint256 id, uint256 amount) external {
        liabilities[id] = amount;
        if (requestStatus[id] == IMantleYieldVault.RequestStatus.NONE) {
            requestStatus[id] = IMantleYieldVault.RequestStatus.PENDING;
            pendingRequestCount++;
            if (id >= requestIdCursor) {
                requestIdCursor = id + 1;
            }
        }
    }

    function setLockedTotal(uint256 amount) external {
        lockedTotal = amount;
    }

    function totalLockedLiabilities() external view returns (uint256) {
        return lockedTotal;
    }

    function exchangeRate() external view returns (uint256) {
        return mockedExchangeRate;
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

    function adapterRedeemInFlightStable(address adapter) external view returns (uint256) {
        return redeemInFlightByAdapter[adapter];
    }

    function getFreeCash() external view returns (uint256) {
        uint256 totalCash = stable.balanceOf(address(this));
        return totalCash > lockedTotal ? totalCash - lockedTotal : 0;
    }

    function getCashDeficit() external view returns (uint256) {
        uint256 totalCash = stable.balanceOf(address(this));
        return lockedTotal > totalCash ? lockedTotal - totalCash : 0;
    }

    uint256 public mockedTotalAssets;

    function setMockedTotalAssets(uint256 v) external {
        mockedTotalAssets = v;
    }

    function totalAssets() external view returns (uint256) {
        if (mockedTotalAssets > 0) return mockedTotalAssets;
        uint256 total = stable.balanceOf(address(this)) + investInFlightTotal + redeemInFlightTotal;
        return total > lockedTotal ? total - lockedTotal : 0;
    }

    function approveToAdapter(address adapter, address token, uint256 amount) external {
        ERC20(token).approve(adapter, amount);
    }

    function isAdapter(address adapter) external view returns (bool) {
        return isAdapterRegistry[adapter];
    }

    function getAdapters() external view returns (address[] memory) {
        return adapterList;
    }

    function registerAdapter(address adapter) external {
        adapterList.push(adapter);
        isAdapterRegistry[adapter] = true;
    }

    function removeAdapter(address adapter) external {
        require(investInFlightByAdapter[adapter] == 0 && redeemInFlightByAdapter[adapter] == 0, "HAS_IN_FLIGHT");
        isAdapterRegistry[adapter] = false;
        uint256 len = adapterList.length;
        for (uint256 i = 0; i < len; i++) {
            if (adapterList[i] == adapter) {
                adapterList[i] = adapterList[len - 1];
                adapterList.pop();
                break;
            }
        }
    }

    function updateRequestBatch(uint256[] calldata ids, IMantleYieldVault.RequestStatus status) external {
        for (uint256 i = 0; i < ids.length; i++) {
            if (
                requestStatus[ids[i]] == IMantleYieldVault.RequestStatus.PENDING
                    && status != IMantleYieldVault.RequestStatus.PENDING
            ) {
                pendingRequestCount--;
            } else if (
                requestStatus[ids[i]] != IMantleYieldVault.RequestStatus.PENDING
                    && status == IMantleYieldVault.RequestStatus.PENDING
            ) {
                pendingRequestCount++;
            }
            requestStatus[ids[i]] = status;
        }
    }

    function markRequestsDone(uint256[] calldata ids, uint256[] calldata settledAssets) external {
        require(ids.length == settledAssets.length, "LENGTH_MISMATCH");
        for (uint256 i = 0; i < ids.length; i++) {
            liabilities[ids[i]] = settledAssets[i];
            requestStatus[ids[i]] = IMantleYieldVault.RequestStatus.DONE;
        }
    }

    function createInFlight(
        address adapter,
        address assetAddr,
        uint256 tokenAmount,
        uint256 stableAmount,
        bool isInvest
    ) external returns (uint256 inFlightId) {
        inFlightId = ++inFlightIdCursor;
        inFlights[inFlightId] = InFlightData({
            id: inFlightId,
            adapter: adapter,
            assetAddr: assetAddr,
            tokenAmount: tokenAmount,
            stableAmount: stableAmount,
            settledAmount: 0,
            isInvest: isInvest,
            timestamp: block.timestamp,
            status: IMantleYieldVault.InFlightStatus.PENDING
        });
        if (isInvest) {
            investInFlightTotal += stableAmount;
            investInFlightByAdapter[adapter] += tokenAmount;
        } else {
            redeemInFlightTotal += stableAmount;
            redeemInFlightByAdapter[adapter] += stableAmount;
        }
    }

    function confirmInFlight(uint256 inFlightId, uint256 actualAmount, bool) external {
        InFlightData storage rec = inFlights[inFlightId];
        rec.settledAmount = actualAmount;
        rec.status = IMantleYieldVault.InFlightStatus.CONFIRMED;
        if (rec.isInvest && investInFlightTotal >= rec.stableAmount) {
            investInFlightTotal -= rec.stableAmount;
            if (investInFlightByAdapter[rec.adapter] >= rec.tokenAmount) {
                investInFlightByAdapter[rec.adapter] -= rec.tokenAmount;
            }
        }
        if (!rec.isInvest && redeemInFlightTotal >= rec.stableAmount) {
            redeemInFlightTotal -= rec.stableAmount;
            if (redeemInFlightByAdapter[rec.adapter] >= rec.stableAmount) {
                redeemInFlightByAdapter[rec.adapter] -= rec.stableAmount;
            }
        }
    }

    function requests(uint256 requestId)
        external
        view
        returns (uint256, address, uint256, uint256, uint256, uint256, uint256, IMantleYieldVault.RequestStatus)
    {
        uint256 assets = liabilities[requestId];
        IMantleYieldVault.RequestStatus status = requestStatus[requestId];
        return (
            requestId,
            address(0),
            assets,
            0, // feeShares
            assets,
            status == IMantleYieldVault.RequestStatus.DONE ? assets : 0,
            0,
            status
        );
    }

    function nextRequestId() external view returns (uint256) {
        return requestIdCursor == 0 ? 1 : requestIdCursor;
    }

    function inFlightRecords(uint256 inFlightId)
        external
        view
        returns (
            uint256 id,
            address adapter,
            address assetAddr,
            uint256 tokenAmount,
            uint256 stableAmount,
            uint256 settledAmount,
            bool isInvest,
            uint256 timestamp,
            IMantleYieldVault.InFlightStatus status
        )
    {
        InFlightData memory rec = inFlights[inFlightId];
        return (
            rec.id,
            rec.adapter,
            rec.assetAddr,
            rec.tokenAmount,
            rec.stableAmount,
            rec.settledAmount,
            rec.isInvest,
            rec.timestamp,
            rec.status
        );
    }
}

contract StrategyFlowTest is Test {
    MockStableFlow internal stable;
    MockVaultFlow internal vault;
    MockAccountantFlow internal accountant;
    StrategyController internal controller;
    MockSubRedManagementFlow internal subRedISNR;
    MockSubRedManagementFlow internal subRedUMINT;
    MockSTTokenFlow internal iSNRToken;
    MockSTTokenFlow internal uMINTToken;
    SubRedManagementAdapter internal adapterISNR;
    SubRedManagementAdapter internal adapterUMINT;

    address internal user = makeAddr("user");
    address internal operator = makeAddr("operator");

    function setUp() public {
        stable = new MockStableFlow();
        vault = new MockVaultFlow(address(stable));
        accountant = new MockAccountantFlow();
        vault.setAccountant(address(accountant));
        StrategyController implementation = new StrategyController();
        bytes memory initData = abi.encodeCall(
            StrategyController.initialize, (address(vault), address(this), address(this), address(this), 0, 0, 0)
        );
        controller = StrategyController(address(new ERC1967Proxy(address(implementation), initData)));

        subRedISNR = new MockSubRedManagementFlow();
        subRedUMINT = new MockSubRedManagementFlow();
        iSNRToken = new MockSTTokenFlow("iSNR", "iSNR");
        uMINTToken = new MockSTTokenFlow("uMINT", "uMINT");

        adapterISNR = new SubRedManagementAdapter(
            address(vault),
            address(subRedISNR),
            address(iSNRToken),
            address(this),
            address(controller),
            address(this),
            address(0)
        );
        adapterUMINT = new SubRedManagementAdapter(
            address(vault),
            address(subRedUMINT),
            address(uMINTToken),
            address(this),
            address(controller),
            address(this),
            address(0)
        );
        adapterISNR.setManualPosTokenPrice(1e18);
        adapterUMINT.setManualPosTokenPrice(1e18);

        controller.registerStrategy(address(adapterISNR), 5000, 1, true);
        controller.registerStrategy(address(adapterUMINT), 5000, 2, true);
        controller.activateStrategy(address(adapterISNR));
        controller.activateStrategy(address(adapterUMINT));

        address[] memory ordered = new address[](2);
        ordered[0] = address(adapterISNR);
        ordered[1] = address(adapterUMINT);
        controller.setStrategyOrder(ordered);

        // Simulate user already has STABLE and has deposited/staked into vault.
        stable.mint(user, 1_000e18);
        vm.startPrank(user);
        stable.approve(address(vault), type(uint256).max);
        vault.deposit(1_000e18);
        vm.stopPrank();
    }

    function test_RebalanceInvestsBy50_50Weights() public {
        controller.rebalance();

        assertEq(subRedISNR.subscribeCount(), 1);
        assertEq(subRedUMINT.subscribeCount(), 1);
        assertEq(subRedISNR.lastStToken(), address(iSNRToken));
        assertEq(subRedUMINT.lastStToken(), address(uMINTToken));
        assertEq(subRedISNR.lastAmount(), 500e18);
        assertEq(subRedUMINT.lastAmount(), 500e18);
        assertEq(stable.balanceOf(address(vault)), 0);
    }

    function test_AsyncProcessBatchAddsInFlightAndMovesReady() public {
        controller.rebalance();
        // Simulate settled position tokens held by vault.
        iSNRToken.mint(address(vault), 500e18);
        uMINTToken.mint(address(vault), 500e18);

        uint256[] memory ids = new uint256[](2);
        ids[0] = 101;
        ids[1] = 102;
        vault.setLiability(ids[0], 150e18);
        vault.setLiability(ids[1], 150e18);
        vault.setLockedTotal(300e18);

        uint256 inFlightBefore = vault.inFlightIdCursor();
        controller.processRedeemBatch(ids);
        uint256 inFlightAfter = vault.inFlightIdCursor();

        // PROCESSING
        assertEq(uint8(vault.requestStatus(ids[0])), uint8(IMantleYieldVault.RequestStatus.PROCESSING));
        assertEq(uint8(vault.requestStatus(ids[1])), uint8(IMantleYieldVault.RequestStatus.PROCESSING));
        assertEq(vault.totalRedeemInFlight(), 300e18);

        uint256 redeemInFlightCount = inFlightAfter - inFlightBefore;
        uint256[] memory inFlightIds = new uint256[](redeemInFlightCount);
        for (uint256 i = 0; i < redeemInFlightCount; i++) {
            inFlightIds[i] = inFlightBefore + i + 1;
        }

        address[] memory adapters = new address[](2);
        adapters[0] = address(adapterISNR);
        adapters[1] = address(adapterUMINT);
        IStrategyControllerExecutor.InvestSettlementInput[] memory investBatch =
            new IStrategyControllerExecutor.InvestSettlementInput[](2);
        investBatch[0] =
            IStrategyControllerExecutor.InvestSettlementInput(new uint256[](0), new uint256[](0), new uint256[](0));
        investBatch[1] =
            IStrategyControllerExecutor.InvestSettlementInput(new uint256[](0), new uint256[](0), new uint256[](0));
        uint256[] memory redeemCountByAdapter = new uint256[](2);
        for (uint256 i = 0; i < redeemInFlightCount; i++) {
            (, address adapter,,,,,,,) = vault.inFlightRecords(inFlightIds[i]);
            if (adapter == adapters[0]) redeemCountByAdapter[0]++;
            else if (adapter == adapters[1]) redeemCountByAdapter[1]++;
            else revert("UNEXPECTED_ADAPTER");
        }

        IStrategyControllerExecutor.RedeemSettlementInput[] memory redeemBatch =
            new IStrategyControllerExecutor.RedeemSettlementInput[](2);
        redeemBatch[0] = IStrategyControllerExecutor.RedeemSettlementInput(
            new uint256[](redeemCountByAdapter[0]), new uint256[](redeemCountByAdapter[0])
        );
        redeemBatch[1] = IStrategyControllerExecutor.RedeemSettlementInput(
            new uint256[](redeemCountByAdapter[1]), new uint256[](redeemCountByAdapter[1])
        );

        uint256[] memory writeIdx = new uint256[](2);
        for (uint256 i = 0; i < redeemInFlightCount; i++) {
            uint256 inFlightId = inFlightIds[i];
            (, address adapter,,, uint256 stableAmount,,,,) = vault.inFlightRecords(inFlightId);
            if (adapter == adapters[0]) {
                uint256 idx = writeIdx[0];
                redeemBatch[0].inFlightIds[idx] = inFlightId;
                redeemBatch[0].settledAssetAmounts[idx] = stableAmount;
                writeIdx[0] = idx + 1;
                stable.mint(adapters[0], stableAmount);
            } else if (adapter == adapters[1]) {
                uint256 idx = writeIdx[1];
                redeemBatch[1].inFlightIds[idx] = inFlightId;
                redeemBatch[1].settledAssetAmounts[idx] = stableAmount;
                writeIdx[1] = idx + 1;
                stable.mint(adapters[1], stableAmount);
            } else {
                revert("UNEXPECTED_ADAPTER");
            }
        }
        uint256[] memory settledAssets = new uint256[](2);
        settledAssets[0] = 150e18;
        settledAssets[1] = 150e18;
        controller.settleAdapters(adapters, investBatch, redeemBatch);
        controller.finalizeRedeemBatch(ids, settledAssets);

        // DONE
        assertEq(uint8(vault.requestStatus(ids[0])), uint8(IMantleYieldVault.RequestStatus.DONE));
        assertEq(uint8(vault.requestStatus(ids[1])), uint8(IMantleYieldVault.RequestStatus.DONE));
        assertEq(vault.totalRedeemInFlight(), 0);
    }
}
