// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SubRedManagementAdapter} from "../../src/adapters/digift/SubRedManagementAdapter.sol";
import {ISubRedManagement} from "../../src/interfaces/adapters/digift/ISubRedManagement.sol";
import {IControllerVault} from "../../src/interfaces/vault/IControllerVault.sol";
import {InFlightStatus, RequestStatus} from "../../src/interfaces/vault/types/VaultTypes.sol";
import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";

contract MockUSDCFlow is ERC20 {
    constructor() ERC20("MockUSDC", "mUSDC") {}

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

contract MockVaultFlow is IControllerVault {
    ERC20 public immutable usdc;

    uint256 public lockedTotal;
    uint256 public redeemInFlightTotal;
    uint256 public requestIdCursor;
    uint256 public inFlightIdCursor;

    mapping(uint256 => uint256) public liabilities;
    mapping(uint256 => RequestStatus) public requestStatus;

    struct InFlightData {
        uint256 id;
        address adapter;
        address assetAddr;
        uint256 tokenAmount;
        uint256 usdcAmount;
        uint256 settledAmount;
        bool isInvest;
        uint256 timestamp;
        InFlightStatus status;
    }

    mapping(uint256 => InFlightData) internal inFlights;

    constructor(address asset_) {
        usdc = ERC20(asset_);
    }

    function asset() external view override returns (address) {
        return address(usdc);
    }

    function deposit(uint256 amount) external {
        usdc.transferFrom(msg.sender, address(this), amount);
    }

    function setLiability(uint256 id, uint256 amount) external {
        liabilities[id] = amount;
        if (requestStatus[id] == RequestStatus.NONE) {
            requestStatus[id] = RequestStatus.PENDING;
        }
    }

    function setLockedTotal(uint256 amount) external {
        lockedTotal = amount;
    }

    function totalLockedLiabilities() external view override returns (uint256) {
        return lockedTotal;
    }

    function totalInvestInFlight() external pure override returns (uint256) {
        return 0;
    }

    function totalRedeemInFlight() external view override returns (uint256) {
        return redeemInFlightTotal;
    }

    function approveToAdapter(address adapter, address token, uint256 amount) external override {
        ERC20(token).approve(adapter, amount);
    }

    function updateRequestBatch(uint256[] calldata ids, RequestStatus status) external override {
        for (uint256 i = 0; i < ids.length; i++) {
            requestStatus[ids[i]] = status;
        }
    }

    function markRequestsReady(uint256[] calldata ids, uint256[] calldata settledAssets) external override {
        require(ids.length == settledAssets.length, "LENGTH_MISMATCH");
        for (uint256 i = 0; i < ids.length; i++) {
            liabilities[ids[i]] = settledAssets[i];
            requestStatus[ids[i]] = RequestStatus.READY;
        }
    }

    function createInFlight(address adapter, address assetAddr, uint256 tokenAmount, uint256 usdcAmount, bool isInvest)
        external
        override
        returns (uint256 inFlightId)
    {
        inFlightId = ++inFlightIdCursor;
        inFlights[inFlightId] = InFlightData({
            id: inFlightId,
            adapter: adapter,
            assetAddr: assetAddr,
            tokenAmount: tokenAmount,
            usdcAmount: usdcAmount,
            settledAmount: 0,
            isInvest: isInvest,
            timestamp: block.timestamp,
            status: InFlightStatus.PENDING
        });
        if (!isInvest) {
            redeemInFlightTotal += usdcAmount;
        }
    }

    function confirmInFlight(uint256 inFlightId, uint256 actualAmount) external override {
        InFlightData storage rec = inFlights[inFlightId];
        rec.settledAmount = actualAmount;
        rec.status = InFlightStatus.CONFIRMED;
        if (!rec.isInvest && redeemInFlightTotal >= rec.usdcAmount) {
            redeemInFlightTotal -= rec.usdcAmount;
        }
    }

    function requests(uint256 requestId)
        external
        view
        override
        returns (uint256, address, uint256, uint256, uint256, uint256, RequestStatus)
    {
        uint256 assets = liabilities[requestId];
        RequestStatus status = requestStatus[requestId];
        return (requestId, address(0), 0, assets, status == RequestStatus.READY ? assets : 0, 0, status);
    }

    function inFlightRecords(uint256 inFlightId)
        external
        view
        override
        returns (
            uint256 id,
            address adapter,
            address assetAddr,
            uint256 tokenAmount,
            uint256 usdcAmount,
            uint256 settledAmount,
            bool isInvest,
            uint256 timestamp,
            InFlightStatus status
        )
    {
        InFlightData memory rec = inFlights[inFlightId];
        return (
            rec.id,
            rec.adapter,
            rec.assetAddr,
            rec.tokenAmount,
            rec.usdcAmount,
            rec.settledAmount,
            rec.isInvest,
            rec.timestamp,
            rec.status
        );
    }
}

contract StrategyFlowTest is Test {
    MockUSDCFlow internal usdc;
    MockVaultFlow internal vault;
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
        usdc = new MockUSDCFlow();
        vault = new MockVaultFlow(address(usdc));
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
            address(vault), address(subRedISNR), address(iSNRToken), address(this), address(controller), address(0)
        );
        adapterUMINT = new SubRedManagementAdapter(
            address(vault), address(subRedUMINT), address(uMINTToken), address(this), address(controller), address(0)
        );

        controller.registerStrategy(address(adapterISNR), 5000, 1, true, true, address(adapterISNR));
        controller.registerStrategy(address(adapterUMINT), 5000, 2, true, true, address(adapterUMINT));

        address[] memory ordered = new address[](2);
        ordered[0] = address(adapterISNR);
        ordered[1] = address(adapterUMINT);
        controller.setStrategyOrder(ordered);

        // Simulate user already has USDC and has deposited/staked into vault.
        usdc.mint(user, 1_000e18);
        vm.startPrank(user);
        usdc.approve(address(vault), type(uint256).max);
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
        assertEq(usdc.balanceOf(address(vault)), 0);
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
        controller.processRedeemBatch(ids, 300e18);
        uint256 inFlightAfter = vault.inFlightIdCursor();

        // PROCESSING
        assertEq(uint8(vault.requestStatus(ids[0])), uint8(RequestStatus.PROCESSING));
        assertEq(uint8(vault.requestStatus(ids[1])), uint8(RequestStatus.PROCESSING));
        assertEq(vault.totalRedeemInFlight(), 300e18);

        // Simulate T+N settlement funds returned to vault.
        usdc.mint(address(vault), 300e18);

        uint256 redeemInFlightCount = inFlightAfter - inFlightBefore;
        uint256[] memory inFlightIds = new uint256[](redeemInFlightCount);
        for (uint256 i = 0; i < redeemInFlightCount; i++) {
            inFlightIds[i] = inFlightBefore + i + 1;
        }
        controller.allocateAssetsBatch(ids, inFlightIds);

        // READY
        assertEq(uint8(vault.requestStatus(ids[0])), uint8(RequestStatus.READY));
        assertEq(uint8(vault.requestStatus(ids[1])), uint8(RequestStatus.READY));
        assertEq(vault.totalRedeemInFlight(), 0);
    }
}
