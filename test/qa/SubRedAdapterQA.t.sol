// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SubRedManagementAdapter} from "../../src/adapters/digift/SubRedManagementAdapterUpgradeable.sol";
import {SubRedManagementAdapterFactory} from "../../src/adapters/digift/SubRedManagementAdapterFactory.sol";
import {BaseAdapterUpgradeable} from "../../src/adapters/base/BaseAdapterUpgradeable.sol";
import {ISubRedManagement} from "../../src/interfaces/adapters/digift/ISubRedManagement.sol";
import {IStrategyControllerExecutor} from "../../src/interfaces/strategy/IStrategyControllerExecutor.sol";
import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {MockDFeedPriceOracle} from "../../src/mocks/strategy/MockDFeedPriceOracle.sol";
import {Accountant} from "../../src/accountant/Accountant.sol";
import {AccountantExecutor} from "../../src/accountant/AccountantExecutor.sol";
import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {OperatorExecutor} from "../../src/protocol/OperatorExecutor.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {MantleVaultGateway} from "../../src/vault/MantleVaultGateway.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {IMantleVaultGateway} from "../../src/interfaces/vault/IMantleVaultGateway.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Test, console2} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";

// ---------------------------------------------------------------------------
// Mock contracts
// ---------------------------------------------------------------------------

interface IMintableERC20_AQ {
    function mint(address to, uint256 amount) external;
}

contract MockUSDC_AQ is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockUSDC6_AQ is ERC20 {
    constructor() ERC20("Mock USDC6", "USDC6") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockSTToken_AQ is ERC20 {
    constructor() ERC20("Mock ST", "mST") {}

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockSTToken6_AQ is ERC20 {
    constructor() ERC20("Mock ST6", "mST6") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockVault_AQ {
    ERC20 public immutable usdc;

    constructor(address asset_) {
        usdc = ERC20(asset_);
    }

    function asset() external view returns (address) {
        return address(usdc);
    }

    function approveToAdapter(address adapter, uint256 amount) external {
        usdc.approve(adapter, amount);
    }

    function approveTokenToAdapter(address token, address adapter, uint256 amount) external {
        ERC20(token).approve(adapter, amount);
    }
}

contract MockSanctionsOracle_AQ is ISanctionsOracle {
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

contract MockSubRed_AQ is ISubRedManagement {
    struct PendingFlow {
        uint256 subscribeAsset;
        uint256 redeemPos;
    }

    uint256 public subscribeCount;
    uint256 public redeemCount;
    uint256 public redeemNonce;
    address public owner;

    address public lastStToken;
    address public lastCurrencyToken;
    uint256 public lastAmount;
    uint256 public lastDeadline;

    address public lastRedeemStToken;
    address public lastRedeemCurrencyToken;
    uint256 public lastRedeemQuantity;
    uint256 public lastRedeemDeadline;

    bool public rejectSubscribe;
    bool public rejectRedeem;

    mapping(address adapter => mapping(address stToken => PendingFlow)) public pending;

    modifier onlyOwner() {
        require(msg.sender == owner, "ONLY_OWNER");
        _;
    }

    constructor(address owner_) {
        owner = owner_;
    }

    function setRejectSubscribe(bool v) external {
        rejectSubscribe = v;
    }

    function setRejectRedeem(bool v) external {
        rejectRedeem = v;
    }

    function subscribe(address stToken, address currencyToken, uint256 amount, uint256 deadline) external override {
        if (rejectSubscribe) revert("SUBSCRIBE_REJECTED");
        if (deadline <= block.timestamp) revert("SUBSCRIBE_EXPIRED");
        lastStToken = stToken;
        lastCurrencyToken = currencyToken;
        lastAmount = amount;
        lastDeadline = deadline;
        subscribeCount++;
        ERC20(currencyToken).transferFrom(msg.sender, address(this), amount);
        pending[msg.sender][stToken].subscribeAsset += amount;
    }

    function redeem(address stToken, address currencyToken, uint256 quantity, uint256 deadline) external override {
        if (rejectRedeem) revert("REDEEM_REJECTED");
        if (deadline <= block.timestamp) revert("REDEEM_EXPIRED");
        lastRedeemStToken = stToken;
        lastRedeemCurrencyToken = currencyToken;
        lastRedeemQuantity = quantity;
        lastRedeemDeadline = deadline;
        redeemCount++;
        redeemNonce++;
        ERC20(stToken).transferFrom(msg.sender, address(this), quantity);
        pending[msg.sender][stToken].redeemPos += quantity;
    }

    function settleSubscribe(address adapter, address stToken, address receiver, uint256 mintedPos) external onlyOwner {
        PendingFlow storage flow = pending[adapter][stToken];
        require(flow.subscribeAsset > 0, "NO_SUBSCRIBE_PENDING");
        flow.subscribeAsset = 0;
        MockSTToken6_AQ(stToken).mint(receiver, mintedPos);
    }

    function settleRedeem(address adapter, address stToken, address currencyToken, address receiver, uint256 assetsOut)
        external
        onlyOwner
    {
        PendingFlow storage flow = pending[adapter][stToken];
        require(flow.redeemPos > 0, "NO_REDEEM_PENDING");
        flow.redeemPos = 0;
        ERC20(currencyToken).transfer(receiver, assetsOut);
    }
}

// ---------------------------------------------------------------------------
// V2 mock implementations for upgrade tests
// ---------------------------------------------------------------------------

/// @dev V2 implementation — adds version() to verify upgrade took effect
contract SubRedManagementAdapterV2 is SubRedManagementAdapter {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @dev V2 with extra storage — verifies ERC-7201 storage layout compatibility
contract SubRedManagementAdapterV2WithStorage is SubRedManagementAdapter {
    /// @custom:storage-location erc7201:mrwa.storage.SubRedAdapterV2Extra
    struct V2ExtraStorage {
        uint256 extraParam;
    }

    bytes32 private constant V2_EXTRA_LOCATION =
        keccak256(abi.encode(uint256(keccak256("mrwa.storage.SubRedAdapterV2Extra")) - 1)) & ~bytes32(uint256(0xff));

    function _getV2Extra() private pure returns (V2ExtraStorage storage $) {
        bytes32 loc = V2_EXTRA_LOCATION;
        assembly {
            $.slot := loc
        }
    }

    function setExtraParam(uint256 v) external {
        _getV2Extra().extraParam = v;
    }

    function extraParam() external view returns (uint256) {
        return _getV2Extra().extraParam;
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}

// ---------------------------------------------------------------------------
// QA Test
// ---------------------------------------------------------------------------

/**
 * @title  SubRedAdapterQATest
 * @notice QA scenario tests for SubRedManagementAdapter business logic.
 */
contract SubRedAdapterQATest is Test {
    // ── events (re-declared for log verification) ──
    event SubscribeDeadlineWindowUpdated(uint64 newWindow);
    event RedeemDeadlineWindowUpdated(uint64 newWindow);
    event ManualPosTokenPriceUpdated(uint256 oldPriceE18, uint256 newPriceE18, address indexed updater);
    event PriceOracleUpdated(address indexed oldOracle, address indexed newOracle, address indexed updater);
    event AdapterPaused(address indexed adapter, bool paused);
    event AdapterDeposit(
        address indexed adapter, address indexed caller, uint256 amount, address indexed receiver, uint256 sharesOrPos
    );
    event AdapterRedeemRequested(
        address indexed adapter, address indexed caller, uint256 amount, address indexed receiver
    );

    // ── mock tokens (asset 18 decimals, ST 6 decimals — default pair) ──
    MockUSDC_AQ internal usdc;
    MockSTToken6_AQ internal stToken6;
    MantleYieldVault internal vault;
    MantleVaultGateway internal gateway;
    Accountant internal vaultAccountant;
    AccountantExecutor internal accountantExecutor;
    StrategyController internal controllerContract;
    OperatorExecutor internal operatorExecutor;
    MockSanctionsOracle_AQ internal sanctionsOracle;
    MockSubRed_AQ internal subRed;
    MockDFeedPriceOracle internal oracle;

    // ── extra tokens for cross-decimal / sweep tests ──
    MockUSDC6_AQ internal usdc6;
    MockSTToken_AQ internal stToken18;
    MockUSDC_AQ internal dustToken;
    MockVault_AQ internal directVault;

    // ── factory & adapters (deployed via BeaconProxy, matching production) ──
    SubRedManagementAdapterFactory internal factory;
    SubRedManagementAdapter internal adapter; // no oracle, asset=18, st=6
    SubRedManagementAdapter internal adapterWithOracle; // oracle price=2, asset=18, st=6
    SubRedManagementAdapter internal adapterSameDecimals; // no oracle, asset=18, st=18
    SubRedManagementAdapter internal directAdapter; // direct edge-only adapter on mock vault

    // ── actors ──
    address internal admin = makeAddr("admin");
    address internal controller = makeAddr("controller");
    address internal accountant = makeAddr("accountant");
    address internal pauser;
    address internal receiver = makeAddr("receiver");
    address internal other = makeAddr("other");
    address internal funder = makeAddr("funder");
    address internal bot = makeAddr("bot");
    address internal acctBot = makeAddr("acctBot");
    address internal treasury = makeAddr("treasury");
    address internal sanctionSafe = makeAddr("sanctionSafe");

    // ── logging ──
    string constant MODULE = unicode"SubRedAdapter专项场景";
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

    function _fundToken(address token, address to, uint256 amount) internal {
        IMintableERC20_AQ(token).mint(funder, amount);
        vm.prank(funder);
        IERC20(token).transfer(to, amount);
    }

    function _fundVaultAsset(uint256 amount) internal {
        _fundToken(address(usdc), address(vault), amount);
    }

    function _fundVaultSt6(uint256 amount) internal {
        _fundToken(address(stToken6), address(vault), amount);
    }

    function _fundAdapterAsset(address targetAdapter, uint256 amount) internal {
        _fundToken(address(usdc), targetAdapter, amount);
    }

    function _fundAdapterDust(uint256 amount) internal {
        _fundToken(address(dustToken), address(adapter), amount);
    }

    function _fundAdapterSt6(uint256 amount) internal {
        _fundToken(address(stToken6), address(adapter), amount);
    }

    function _depositToVault(address user, uint256 amount) internal returns (uint256 shares) {
        IMintableERC20_AQ(address(usdc)).mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        shares = gateway.deposit(amount);
        vm.stopPrank();
    }

    function _rebalance() internal {
        vm.prank(bot);
        operatorExecutor.executeRebalance(address(controllerContract));
    }

    function _processRedeemBatch(uint256[] memory ids) internal {
        vm.prank(bot);
        operatorExecutor.executeProcessRedeemBatch(address(controllerContract), ids);
    }

    function _settleAdapterInvest(uint256 inFlightId, uint256 settledPosAmount) internal {
        vm.prank(admin);
        subRed.settleSubscribe(address(adapter), address(stToken6), address(adapter), settledPosAmount);

        uint256[] memory ids = new uint256[](1);
        ids[0] = inFlightId;
        uint256[] memory settledPos = new uint256[](1);
        settledPos[0] = settledPosAmount;
        uint256[] memory refundAssets = new uint256[](1);
        refundAssets[0] = 0;

        IStrategyControllerExecutor.InvestSettlementInput memory invest =
            IStrategyControllerExecutor.InvestSettlementInput(ids, settledPos, refundAssets);
        IStrategyControllerExecutor.RedeemSettlementInput memory redeem =
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0));

        vm.prank(bot);
        operatorExecutor.executeSettleAdapter(address(controllerContract), address(adapter), invest, redeem);
    }

    function _seedVaultSt(uint256 assetAmount, address user) internal returns (uint256 shares, uint256 posAmount) {
        shares = _depositToVault(user, assetAmount);
        uint256 inFlightId = vault.nextInFlightId();
        posAmount = adapter.estimatePosAmount(assetAmount);
        _rebalance();
        _settleAdapterInvest(inFlightId, posAmount);
    }

    // ── setUp ──
    function setUp() public {
        // tokens
        usdc = new MockUSDC_AQ();
        stToken6 = new MockSTToken6_AQ();
        stToken18 = new MockSTToken_AQ();
        usdc6 = new MockUSDC6_AQ();
        dustToken = new MockUSDC_AQ();

        // real protocol stack
        sanctionsOracle = new MockSanctionsOracle_AQ();
        subRed = new MockSubRed_AQ(admin);

        // oracle: price = 2 (2e8 in 8-decimal)
        oracle = new MockDFeedPriceOracle(2e8, 8);

        MantleYieldVault vaultImpl = new MantleYieldVault();
        Accountant accountantImpl = new Accountant();
        AccountantExecutor accountantExecutorImpl = new AccountantExecutor();
        StrategyController controllerImpl = new StrategyController();
        OperatorExecutor executorImpl = new OperatorExecutor();
        MantleVaultGateway gatewayImpl = new MantleVaultGateway();

        vault = MantleYieldVault(address(new ERC1967Proxy(
            address(vaultImpl),
            abi.encodeCall(MantleYieldVault.initialize, IMantleYieldVault.InitParams({
                asset: IERC20(address(usdc)),
                name: "mRWA Vault",
                symbol: "mRWA",
                admin: admin,
                gateway: address(1),
                controller: admin,
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

        vaultAccountant = Accountant(address(new ERC1967Proxy(
            address(accountantImpl),
            abi.encodeCall(Accountant.initialize, (address(vault), 1e18, 0, admin))
        )));

        accountantExecutor = AccountantExecutor(address(new ERC1967Proxy(
            address(accountantExecutorImpl),
            abi.encodeCall(AccountantExecutor.initialize, (admin))
        )));

        operatorExecutor = OperatorExecutor(address(new ERC1967Proxy(
            address(executorImpl),
            abi.encodeCall(OperatorExecutor.initialize, (admin, bot))
        )));

        controllerContract = StrategyController(address(new ERC1967Proxy(
            address(controllerImpl),
            abi.encodeCall(StrategyController.initialize, (
                address(vault),
                admin,
                address(operatorExecutor),
                admin,
                0,
                0,
                0
            ))
        )));

        gateway = MantleVaultGateway(address(new ERC1967Proxy(
            address(gatewayImpl),
            abi.encodeCall(MantleVaultGateway.initialize, IMantleVaultGateway.InitParams({
                vault: address(vault),
                sanctionsOracle: ISanctionsOracle(address(sanctionsOracle)),
                sanctionSafe: sanctionSafe,
                admin: admin,
                syncRedeemDisabled: false
            }))
        )));

        // Factory + BeaconProxy deployment (matches production)
        SubRedManagementAdapter adapterImpl = new SubRedManagementAdapter();
        factory = new SubRedManagementAdapterFactory(address(adapterImpl), admin);

        // adapter (no oracle): asset=18, st=6
        adapter = SubRedManagementAdapter(factory.deployAndInitAdapter(
            address(vault), address(subRed), address(stToken6),
            admin, address(controllerContract), address(accountantExecutor), address(0)
        ));

        // adapter with oracle: asset=18, st=6, price=2
        adapterWithOracle = SubRedManagementAdapter(factory.deployAndInitAdapter(
            address(vault), address(subRed), address(stToken6),
            admin, address(controllerContract), address(accountantExecutor), address(oracle)
        ));

        // adapter same decimals: asset=18, st=18
        MockVault_AQ vault18 = new MockVault_AQ(address(usdc));
        adapterSameDecimals = SubRedManagementAdapter(factory.deployAndInitAdapter(
            address(vault18), address(subRed), address(stToken18),
            admin, controller, accountant, address(0)
        ));

        directVault = new MockVault_AQ(address(usdc));
        directAdapter = SubRedManagementAdapter(factory.deployAndInitAdapter(
            address(directVault), address(subRed), address(stToken6),
            admin, controller, accountant, address(0)
        ));

        vm.startPrank(admin);
        vault.setController(address(controllerContract));
        vault.setAccountant(address(vaultAccountant));
        vault.setGateway(address(gateway));
        accountantExecutor.grantRole(accountantExecutor.BOT_ROLE(), acctBot);
        vaultAccountant.grantRole(vaultAccountant.ACCOUNTANT_EXECUTOR_ROLE(), address(accountantExecutor));
        controllerContract.registerStrategy(address(adapter), 10_000, 1, true);
        controllerContract.activateStrategy(address(adapter));
        address[] memory order = new address[](1);
        order[0] = address(adapter);
        controllerContract.setStrategyOrder(order);
        adapter.grantRole(adapter.CONTROLLER_ROLE(), admin);
        adapter.grantRole(adapter.PAUSER_ROLE(), admin);
        adapter.grantRole(adapter.ACCOUNTANT_EXECUTOR_ROLE(), accountant);
        adapterWithOracle.grantRole(adapterWithOracle.CONTROLLER_ROLE(), admin);
        adapterWithOracle.grantRole(adapterWithOracle.PAUSER_ROLE(), admin);
        adapterWithOracle.grantRole(adapterWithOracle.ACCOUNTANT_EXECUTOR_ROLE(), accountant);
        vm.stopPrank();

        // pauser = admin via controllerContract.setAdapterPaused; admin also has direct extra-test role
        pauser = admin;

        // Set manual price = 1e18 (1:1) for adapters without oracle so that
        // estimatePosAmount / deposit / previewDeposit work correctly.
        // (The adapter returns 0 when getPosTokenPrice() == 0.)
        vm.startPrank(accountant);
        adapter.setManualPosTokenPrice(1e18);
        adapterSameDecimals.setManualPosTokenPrice(1e18);
        directAdapter.setManualPosTokenPrice(1e18);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 1 — admin配置setSubscribeDeadlineWindow
    // ═══════════════════════════════════════════════════════════════

    function test_Case01_SetSubscribeDeadlineWindow() public {
        _logCase("Case-01", unicode"admin配置setSubscribeDeadlineWindow");

        uint64 oldWindow = adapter.subscribeDeadlineWindow();
        _step(string.concat("[Step 1] current subscribeDeadlineWindow = ", vm.toString(uint256(oldWindow))));

        _step("[Step 2] admin calls setSubscribeDeadlineWindow(6h)");
        uint64 newWindow = 6 hours;
        vm.recordLogs();
        vm.prank(admin);
        adapter.setSubscribeDeadlineWindow(newWindow);
        {
            VmSafe.Log[] memory logs = vm.getRecordedLogs();
            bool found;
            for (uint256 i; i < logs.length; i++) {
                if (logs[i].topics[0] == keccak256("SubscribeDeadlineWindowUpdated(uint64)")) {
                    assertEq(logs[i].emitter, address(adapter), "wrong emitter");
                    assertEq(abi.decode(logs[i].data, (uint64)), newWindow, "wrong newWindow");
                    found = true;
                    break;
                }
            }
            assertTrue(found, "SubscribeDeadlineWindowUpdated not emitted");
        }
        _step("  SubscribeDeadlineWindowUpdated emitted and verified");

        _step("[Step 3] verify value updated on chain");
        assertEq(adapter.subscribeDeadlineWindow(), newWindow);
        _step(string.concat("  subscribeDeadlineWindow = ", vm.toString(uint256(newWindow))));
        _step(string.concat("  caller = ", vm.toString(admin)));
        _step("  PASS: admin successfully configured subscribeDeadlineWindow");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 2 — admin配置setRedeemDeadlineWindow
    // ═══════════════════════════════════════════════════════════════

    function test_Case02_SetRedeemDeadlineWindow() public {
        _logCase("Case-02", unicode"admin配置setRedeemDeadlineWindow");

        uint64 oldWindow = adapter.redeemDeadlineWindow();
        _step(string.concat("[Step 1] current redeemDeadlineWindow = ", vm.toString(uint256(oldWindow))));

        _step("[Step 2] admin calls setRedeemDeadlineWindow(6h)");
        uint64 newWindow = 6 hours;
        vm.recordLogs();
        vm.prank(admin);
        adapter.setRedeemDeadlineWindow(newWindow);
        {
            VmSafe.Log[] memory logs = vm.getRecordedLogs();
            bool found;
            for (uint256 i; i < logs.length; i++) {
                if (logs[i].topics[0] == keccak256("RedeemDeadlineWindowUpdated(uint64)")) {
                    assertEq(logs[i].emitter, address(adapter), "wrong emitter");
                    assertEq(abi.decode(logs[i].data, (uint64)), newWindow, "wrong newWindow");
                    found = true;
                    break;
                }
            }
            assertTrue(found, "RedeemDeadlineWindowUpdated not emitted");
        }
        _step("  RedeemDeadlineWindowUpdated emitted and verified");

        _step("[Step 3] verify value updated on chain");
        assertEq(adapter.redeemDeadlineWindow(), newWindow);
        _step(string.concat("  redeemDeadlineWindow = ", vm.toString(uint256(newWindow))));
        _step(string.concat("  caller = ", vm.toString(admin)));
        _step("  PASS: admin successfully configured redeemDeadlineWindow");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 3 — admin配置setManualPosTokenPrice为0
    // ═══════════════════════════════════════════════════════════════

    function test_Case03_SetManualPosTokenPriceToZero() public {
        _logCase("Case-03", unicode"admin配置setManualPosTokenPrice为0");

        _step("[Step 1] set manual price to 5e18 first");
        _step(string.concat("  caller = ", vm.toString(accountant)));
        vm.prank(accountant);
        adapter.setManualPosTokenPrice(5e18);
        uint256 priceAfterSet = adapter.getPosTokenPrice();
        assertEq(priceAfterSet, 5e18);
        _step(string.concat("  getPosTokenPrice = ", vm.toString(priceAfterSet)));

        _step("[Step 2] set manual price to 0 (clear override)");
        vm.recordLogs();
        vm.prank(accountant);
        adapter.setManualPosTokenPrice(0);
        {
            VmSafe.Log[] memory logs = vm.getRecordedLogs();
            bool found;
            for (uint256 i; i < logs.length; i++) {
                if (logs[i].topics[0] == keccak256("ManualPosTokenPriceUpdated(uint256,uint256,address)")) {
                    assertEq(logs[i].emitter, address(adapter), "wrong emitter");
                    assertEq(address(uint160(uint256(logs[i].topics[1]))), accountant, "wrong updater");
                    (uint256 oldP, uint256 newP) = abi.decode(logs[i].data, (uint256, uint256));
                    assertEq(oldP, 5e18, "wrong oldPrice");
                    assertEq(newP, 0, "wrong newPrice");
                    found = true;
                    break;
                }
            }
            assertTrue(found, "ManualPosTokenPriceUpdated not emitted");
        }
        _step("  ManualPosTokenPriceUpdated emitted and verified");

        _step("[Step 3] verify falls back to 0 (M-6: no oracle + no manual => 0)");
        uint256 fallbackPrice = adapter.getPosTokenPrice();
        assertEq(fallbackPrice, 0);
        _step(string.concat("  getPosTokenPrice = ", vm.toString(fallbackPrice), " (M-6 fallback)"));
        _step("  PASS: clearing manual price falls back to 0 per M-6");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 4 — 合约暂停解除
    // ═══════════════════════════════════════════════════════════════

    function test_Case04_PauseAndUnpause() public {
        _logCase("Case-04", unicode"合约暂停解除");

        _step("[Prepare] user deposits 1000e18 through gateway");
        _depositToVault(receiver, 1_000e18);
        _step(string.concat("  vault USDC balance = ", vm.toString(usdc.balanceOf(address(vault)))));

        _step("[Step 1] pauser calls controller.setAdapterPaused(adapter, true)");
        _step(string.concat("  pauser = ", vm.toString(pauser)));
        vm.recordLogs();
        vm.prank(pauser);
        controllerContract.setAdapterPaused(address(adapter), true);
        _step(string.concat("  adapter.paused() = ", adapter.paused() ? "true" : "false"));
        assertTrue(adapter.paused());
        {
            VmSafe.Log[] memory logs = vm.getRecordedLogs();
            bool found;
            for (uint256 i; i < logs.length; i++) {
                if (logs[i].topics[0] == keccak256("AdapterPaused(address,bool)")) {
                    assertEq(logs[i].emitter, address(adapter), "wrong emitter");
                    assertEq(address(uint160(uint256(logs[i].topics[1]))), address(adapter), "wrong adapter");
                    assertEq(abi.decode(logs[i].data, (bool)), true, "wrong paused value");
                    found = true;
                    break;
                }
            }
            assertTrue(found, "AdapterPaused(true) not emitted");
        }
        _step("  paused = true, event emitted");

        _step("[Step 2] direct controller-role extra checks still revert when paused");
        vm.prank(admin);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        adapter.deposit(100e18, receiver);

        vm.prank(admin);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        adapter.requestRedeemAsync(100e18, receiver);

        vm.prank(admin);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        adapter.sweepToVault(address(usdc), 100e18);
        _step("  paused guard verified");

        _step("[Step 3] pauser calls controller.setAdapterPaused(adapter, false)");
        vm.recordLogs();
        vm.prank(pauser);
        controllerContract.setAdapterPaused(address(adapter), false);
        _step(string.concat("  adapter.paused() = ", adapter.paused() ? "true" : "false"));
        assertFalse(adapter.paused());
        {
            VmSafe.Log[] memory logs = vm.getRecordedLogs();
            bool found;
            for (uint256 i; i < logs.length; i++) {
                if (logs[i].topics[0] == keccak256("AdapterPaused(address,bool)")) {
                    assertEq(logs[i].emitter, address(adapter), "wrong emitter");
                    assertEq(address(uint160(uint256(logs[i].topics[1]))), address(adapter), "wrong adapter");
                    assertEq(abi.decode(logs[i].data, (bool)), false, "wrong paused value");
                    found = true;
                    break;
                }
            }
            assertTrue(found, "AdapterPaused(false) not emitted");
        }
        _step("  paused = false, event emitted");

        _step("[Step 4] bot calls executeRebalance after unpause");
        uint256 beforeCount = subRed.subscribeCount();
        _rebalance();
        uint256 afterCount = subRed.subscribeCount();
        _step(string.concat("  subscribeCount before = ", vm.toString(beforeCount)));
        _step(string.concat("  subscribeCount after  = ", vm.toString(afterCount)));
        assertEq(afterCount, beforeCount + 1);
        _step("  PASS: pause/unpause cycle works and real rebalance resumes after unpause");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 5 — 合约权限控制
    // ═══════════════════════════════════════════════════════════════

    function test_Case05_AccessControl() public {
        _logCase("Case-05", unicode"合约权限控制");

        _step(string.concat("[Info] unauthorized caller = ", vm.toString(other)));
        _step(string.concat("  admin = ", vm.toString(admin)));
        _step(string.concat("  controller = ", vm.toString(controller)));
        _step(string.concat("  accountant = ", vm.toString(accountant)));
        _step(string.concat("  pauser = ", vm.toString(pauser)));

        // Cache role values to avoid external calls consuming vm.prank
        bytes32 controllerRole = adapter.CONTROLLER_ROLE();
        bytes32 pauserRole = adapter.PAUSER_ROLE();
        bytes32 accountantExecutorRole = adapter.ACCOUNTANT_EXECUTOR_ROLE();
        bytes32 adminRole = 0x00; // DEFAULT_ADMIN_ROLE

        _step("[Step 1] non-Controller calls sweepToVault -> revert");
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, other, controllerRole
        ));
        adapter.sweepToVault(address(usdc), 1e18);
        _step("  reverted (only controller allowed)");

        _step("[Step 2] non-Pauser calls setPaused -> revert");
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, other, pauserRole
        ));
        adapter.setPaused(true);
        _step("  reverted (only pauser allowed)");

        _step("[Step 3] non-Controller calls deposit -> revert");
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, other, controllerRole
        ));
        adapter.deposit(1e18, receiver);
        _step("  reverted (only controller allowed)");

        _step("[Step 4] non-Controller calls requestRedeemAsync -> revert");
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, other, controllerRole
        ));
        adapter.requestRedeemAsync(1e18, receiver);
        _step("  reverted (only controller allowed)");

        _step("[Step 5] non-Admin calls sweep -> revert");
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, other, adminRole
        ));
        adapter.sweep(address(dustToken), receiver);
        _step("  reverted (only admin allowed)");

        _step("[Step 6] non-Admin calls setPriceOracle -> revert");
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, other, adminRole
        ));
        adapter.setPriceOracle(address(oracle));
        _step("  reverted (only admin allowed)");

        _step("[Step 7] non-Accountant calls setManualPosTokenPrice -> revert");
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, other, accountantExecutorRole
        ));
        adapter.setManualPosTokenPrice(1e18);
        _step("  reverted (only accountant allowed)");

        _step("[Step 8] non-Admin calls setSubscribeDeadlineWindow -> revert");
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, other, adminRole
        ));
        adapter.setSubscribeDeadlineWindow(1 hours);
        _step("  reverted (only admin allowed)");
        _step("  PASS: all 8 access control checks verified");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 6 — deposit-从vault取usdc
    // ═══════════════════════════════════════════════════════════════

    function test_Case06_DepositNormal() public {
        _logCase("Case-06", unicode"deposit-从vault取usdc");

        uint256 amount = 100e18;
        uint256 expectedShares = 100e6;
        _step("[Prepare] user deposits 100e18 through gateway");
        _depositToVault(receiver, amount);

        _step("[Step 1] bot calls executeRebalance -> controller -> adapter.deposit");
        _step(string.concat("  caller = ", vm.toString(bot)));
        uint256 vaultBefore = usdc.balanceOf(address(vault));
        _step(string.concat("  vault USDC before = ", vm.toString(vaultBefore)));

        vm.recordLogs();
        _rebalance();
        {
            VmSafe.Log[] memory logs = vm.getRecordedLogs();
            bool found;
            for (uint256 i; i < logs.length; i++) {
                if (
                    logs[i].topics[0]
                        == keccak256("AdapterDeposit(address,address,uint256,address,uint256)")
                ) {
                    assertEq(logs[i].emitter, address(adapter), "wrong emitter");
                    assertEq(address(uint160(uint256(logs[i].topics[1]))), address(adapter), "wrong adapter");
                    assertEq(address(uint160(uint256(logs[i].topics[2]))), address(controllerContract), "wrong caller");
                    assertEq(address(uint160(uint256(logs[i].topics[3]))), address(adapter), "wrong receiver");
                    (uint256 amt, uint256 shares) = abi.decode(logs[i].data, (uint256, uint256));
                    assertEq(amt, amount, "wrong amount");
                    assertEq(shares, expectedShares, "wrong sharesOrPos");
                    found = true;
                    break;
                }
            }
            assertTrue(found, "AdapterDeposit not emitted");
        }
        _step(string.concat("  expected pos = ", vm.toString(expectedShares)));

        _step("[Step 2] verify balances and subRed state");
        uint256 vaultAfter = usdc.balanceOf(address(vault));
        _step(string.concat("  vault USDC after = ", vm.toString(vaultAfter)));
        _step(string.concat("  vault USDC delta = ", vm.toString(vaultBefore - vaultAfter)));
        assertEq(vaultBefore - vaultAfter, amount);
        _step(string.concat("  subRed.subscribeCount = ", vm.toString(subRed.subscribeCount())));
        assertEq(subRed.subscribeCount(), 1);
        _step(string.concat("  subRed.lastAmount = ", vm.toString(subRed.lastAmount())));
        assertEq(subRed.lastAmount(), amount);
        uint256 subRedBal = usdc.balanceOf(address(subRed));
        _step(string.concat("  subRed USDC balance = ", vm.toString(subRedBal)));
        assertEq(subRedBal, amount);
        _step("  PASS: vault balance decreased, subRed received funds, AdapterDeposit event emitted");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 7 — deposit-amount为0
    // ═══════════════════════════════════════════════════════════════

    function test_Case07_DepositZeroAmount() public {
        _logCase("Case-07", unicode"deposit-amount为0");

        _step("[Step 1] admin calls adapter.deposit(0, receiver) as extra controller-role edge test");
        _step(string.concat("  caller = ", vm.toString(admin)));
        _step(string.concat("  receiver = ", vm.toString(receiver)));
        _step("  amount = 0");
        vm.prank(controller);
        vm.expectRevert(BaseAdapterUpgradeable.InvalidAmount.selector);
        directAdapter.deposit(0, receiver);
        _step("  reverted with InvalidAmount");
        _step("  PASS: zero amount deposit is rejected");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 8 — deposit-过期deposit
    // ═══════════════════════════════════════════════════════════════

    function test_Case08_DepositExpired() public {
        _logCase("Case-08", unicode"deposit-过期deposit");

        uint256 amount = 100e18;
        _step("[Prepare] directVault receives funds for adapter-level expiry edge test");
        _fundToken(address(usdc), address(directVault), 500e18);
        directVault.approveToAdapter(address(directAdapter), 500e18);

        _step("[Step 1] admin sets subscribeDeadlineWindow to 0 (immediate expiry)");
        vm.prank(admin);
        directAdapter.setSubscribeDeadlineWindow(0);
        _step(string.concat("  subscribeDeadlineWindow = ", vm.toString(uint256(directAdapter.subscribeDeadlineWindow()))));
        _step(string.concat("  block.timestamp = ", vm.toString(block.timestamp)));
        _step("  deadline will be: block.timestamp + 0 = block.timestamp (expired)");

        _step(string.concat("[Step 2] controller-role holder calls directAdapter.deposit(", vm.toString(amount), ", receiver) directly"));
        vm.prank(controller);
        vm.expectRevert("SUBSCRIBE_EXPIRED");
        directAdapter.deposit(amount, receiver);
        _step("  reverted with SUBSCRIBE_EXPIRED");
        _step("  PASS: expired deadline correctly rejected by SubRed");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 9 — deposit-allowance验证
    // ═══════════════════════════════════════════════════════════════

    function test_Case09_DepositAllowanceResetToZero() public {
        _logCase("Case-09", unicode"deposit-allowance验证");

        uint256 amount = 100e18;
        _step("[Prepare] user deposits 100e18 through gateway");
        _depositToVault(receiver, amount);

        _step("[Step 1] bot calls executeRebalance");
        _rebalance();
        _step("  rebalance succeeded");

        _step("[Step 2] verify adapter -> SubRed USDC allowance is reset to 0");
        uint256 allowance = usdc.allowance(address(adapter), address(subRed));
        _step(string.concat("  adapter->subRed allowance = ", vm.toString(allowance)));
        assertEq(allowance, 0);
        _step("  PASS: allowance correctly reset to 0 after deposit (minimum-privilege pattern)");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 10 — deposit-连续多次deposit
    // ═══════════════════════════════════════════════════════════════

    function test_Case10_MultipleDeposits() public {
        _logCase("Case-10", unicode"deposit-连续多次deposit");

        _step("[Step 1] user deposits 100e18, bot rebalances (1st)");
        _depositToVault(receiver, 100e18);
        _rebalance();
        _step(string.concat("  subscribeCount after 1st = ", vm.toString(subRed.subscribeCount())));

        _step("[Step 2] user deposits 200e18, bot rebalances (2nd)");
        _depositToVault(receiver, 200e18);
        _rebalance();
        _step(string.concat("  subscribeCount after 2nd = ", vm.toString(subRed.subscribeCount())));

        _step("[Step 3] user deposits 300e18, bot rebalances (3rd)");
        _depositToVault(receiver, 300e18);
        _rebalance();
        _step(string.concat("  subscribeCount after 3rd = ", vm.toString(subRed.subscribeCount())));

        _step("[Step 4] verify final state");
        assertEq(subRed.subscribeCount(), 3);
        uint256 totalSubscribed = usdc.balanceOf(address(subRed));
        assertEq(totalSubscribed, 600e18);
        _step(string.concat("  total subscribed to subRed = ", vm.toString(totalSubscribed)));
        uint256 vaultRemaining = usdc.balanceOf(address(vault));
        assertEq(vaultRemaining, 0);
        _step(string.concat("  vault remaining = ", vm.toString(vaultRemaining)));
        _step("  PASS: 3 consecutive deposits all succeeded");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 11 — RequestRedeemAsync-从vault取ST
    // ═══════════════════════════════════════════════════════════════

    function test_Case11_RequestRedeemAsyncNormal() public {
        _logCase("Case-11", unicode"RequestRedeemAsync-从vault取ST");

        uint256 assetAmount = 200e18;
        uint256 posAmount = 200e6;
        _step("[Prepare] user deposit -> bot rebalance -> bot settle invest, forming real vault ST balance");
        (uint256 shares,) = _seedVaultSt(assetAmount, receiver);
        uint256 vaultBefore = stToken6.balanceOf(address(vault));
        _step(string.concat("  vault ST balance = ", vm.toString(vaultBefore)));
        _step(string.concat("  ST decimals = 6, posAmount = ", vm.toString(posAmount)));

        vm.prank(receiver);
        uint256 reqId = gateway.requestRedeem(shares);
        uint256[] memory ids = new uint256[](1);
        ids[0] = reqId;

        _step("[Step 1] bot calls executeProcessRedeemBatch -> controller -> adapter.requestRedeemAsync");
        vm.recordLogs();
        _processRedeemBatch(ids);
        {
            VmSafe.Log[] memory logs = vm.getRecordedLogs();
            bool found;
            for (uint256 i; i < logs.length; i++) {
                if (
                    logs[i].topics[0]
                        == keccak256("AdapterRedeemRequested(address,address,uint256,address)")
                ) {
                    assertEq(logs[i].emitter, address(adapter), "wrong emitter");
                    assertEq(address(uint160(uint256(logs[i].topics[1]))), address(adapter), "wrong adapter");
                    assertEq(address(uint160(uint256(logs[i].topics[2]))), address(controllerContract), "wrong caller");
                    assertEq(address(uint160(uint256(logs[i].topics[3]))), address(adapter), "wrong receiver");
                    assertEq(abi.decode(logs[i].data, (uint256)), posAmount, "wrong amount");
                    found = true;
                    break;
                }
            }
            assertTrue(found, "AdapterRedeemRequested not emitted");
        }

        _step("[Step 2] verify redeemCount, redeemNonce, and real ST flow");
        _step(string.concat("  subRed.redeemCount = ", vm.toString(subRed.redeemCount())));
        assertEq(subRed.redeemCount(), 1);
        _step(string.concat("  subRed.redeemNonce = ", vm.toString(subRed.redeemNonce())));
        assertEq(subRed.redeemNonce(), 1);
        _step(string.concat("  subRed.lastRedeemQuantity = ", vm.toString(subRed.lastRedeemQuantity())));
        assertEq(subRed.lastRedeemQuantity(), posAmount);
        uint256 vaultAfter = stToken6.balanceOf(address(vault));
        _step(string.concat("  vault ST after = ", vm.toString(vaultAfter)));
        assertEq(vaultBefore - vaultAfter, posAmount);
        uint256 adapterST = stToken6.balanceOf(address(adapter));
        _step(string.concat("  adapter ST balance = ", vm.toString(adapterST)));
        assertEq(adapterST, 0);
        uint256 subRedST = stToken6.balanceOf(address(subRed));
        _step(string.concat("  subRed ST balance = ", vm.toString(subRedST)));
        assertEq(subRedST, posAmount);
        _step("  PASS: requestRedeemAsync correctly moved ST vault -> adapter -> subRed and called redeem");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 12 — RequestRedeemAsync-vault未授权ST进行redeem
    // ═══════════════════════════════════════════════════════════════

    function test_Case12_RequestRedeemAsyncNoAllowance() public {
        _logCase("Case-12", unicode"RequestRedeemAsync-vault未授权ST进行redeem");

        _step("[Prepare] fund vault ST directly, do NOT approve adapter (adapter-level edge test)");
        _fundToken(address(stToken6), address(directVault), 100e6);
        _step(string.concat("  vault ST balance = ", vm.toString(stToken6.balanceOf(address(directVault)))));
        uint256 allowance = stToken6.allowance(address(directVault), address(directAdapter));
        _step(string.concat("  vault->adapter ST allowance = ", vm.toString(allowance)));

        _step("[Step 1] controller-role holder calls directAdapter.requestRedeemAsync(100e18, receiver) directly");
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(
            IERC20Errors.ERC20InsufficientAllowance.selector, address(directAdapter), 0, 100e18
        ));
        directAdapter.requestRedeemAsync(100e18, receiver);
        _step("  reverted due to insufficient allowance");
        _step("  PASS: missing allowance correctly prevents redeem");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 13 — RequestRedeemAsync-连续多次调用
    // ═══════════════════════════════════════════════════════════════

    function test_Case13_RequestRedeemAsyncMultiple() public {
        _logCase("Case-13", unicode"RequestRedeemAsync-连续多次调用");

        _step("[Prepare] seed 350e6 ST into vault through real invest path");
        (uint256 shares,) = _seedVaultSt(350e18, receiver);

        _step("[Step 1] user requests 100e18 shares, bot processes batch");
        vm.prank(receiver);
        uint256 reqId1 = gateway.requestRedeem(100e18);
        uint256[] memory ids1 = new uint256[](1);
        ids1[0] = reqId1;
        _processRedeemBatch(ids1);
        _step(string.concat("  redeemCount = ", vm.toString(subRed.redeemCount()), ", nonce = ", vm.toString(subRed.redeemNonce())));

        _step("[Step 2] user requests 200e18 shares, bot processes batch");
        vm.prank(receiver);
        uint256 reqId2 = gateway.requestRedeem(200e18);
        uint256[] memory ids2 = new uint256[](1);
        ids2[0] = reqId2;
        _processRedeemBatch(ids2);
        _step(string.concat("  redeemCount = ", vm.toString(subRed.redeemCount()), ", nonce = ", vm.toString(subRed.redeemNonce())));

        _step("[Step 3] user requests 50e18 shares, bot processes batch");
        vm.prank(receiver);
        uint256 reqId3 = gateway.requestRedeem(shares - 300e18);
        uint256[] memory ids3 = new uint256[](1);
        ids3[0] = reqId3;
        _processRedeemBatch(ids3);
        _step(string.concat("  redeemCount = ", vm.toString(subRed.redeemCount()), ", nonce = ", vm.toString(subRed.redeemNonce())));

        _step("[Step 4] verify final state");
        assertEq(subRed.redeemCount(), 3);
        assertEq(subRed.redeemNonce(), 3);
        _step("  PASS: 3 consecutive redeemAsync calls all succeeded, nonce incremented correctly");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 14 — RequestRedeemAsync-receiver为零地址
    // ═══════════════════════════════════════════════════════════════

    function test_Case14_RequestRedeemAsyncZeroReceiver() public {
        _logCase("Case-14", unicode"RequestRedeemAsync-receiver为零地址");

        _step("[Prepare] fund vault ST directly and approve adapter (adapter-level edge test)");
        _fundToken(address(stToken6), address(directVault), 100e6);
        directVault.approveTokenToAdapter(address(stToken6), address(directAdapter), 100e6);

        _step("[Step 1] controller-role holder calls directAdapter.requestRedeemAsync(100e6, address(0)) directly");
        _step("  receiver = address(0)");
        vm.prank(controller);
        vm.expectRevert(BaseAdapterUpgradeable.InvalidAddress.selector);
        directAdapter.requestRedeemAsync(100e6, address(0));
        _step("  reverted with InvalidAddress");
        _step("  PASS: zero receiver address correctly rejected");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 15 — RequestRedeemAsync-redeem后查看授权allowance
    // ═══════════════════════════════════════════════════════════════

    function test_Case15_RequestRedeemAsyncAllowanceResetToZero() public {
        _logCase("Case-15", unicode"RequestRedeemAsync-redeem后查看授权allowance");

        _step("[Prepare] seed 100e6 ST into vault through real invest path");
        (uint256 shares,) = _seedVaultSt(100e18, receiver);

        vm.prank(receiver);
        uint256 reqId = gateway.requestRedeem(shares);
        uint256[] memory ids = new uint256[](1);
        ids[0] = reqId;

        _step("[Step 1] bot processes redeem batch");
        _processRedeemBatch(ids);
        _step("  requestRedeemAsync succeeded through controller path");

        _step("[Step 2] verify adapter -> SubRed ST allowance is reset to 0");
        uint256 allowance = stToken6.allowance(address(adapter), address(subRed));
        _step(string.concat("  adapter->subRed ST allowance = ", vm.toString(allowance)));
        assertEq(allowance, 0);
        _step("  PASS: ST allowance correctly reset to 0 after redeem (minimum-privilege pattern)");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 16 — RequestRedeemAsync-过期redeem
    // ═══════════════════════════════════════════════════════════════

    function test_Case16_RequestRedeemAsyncExpired() public {
        _logCase("Case-16", unicode"RequestRedeemAsync-过期redeem");

        _step("[Prepare] fund vault ST directly and approve adapter (adapter-level edge test)");
        _fundToken(address(stToken6), address(directVault), 500e6);
        directVault.approveTokenToAdapter(address(stToken6), address(directAdapter), 500e6);

        _step("[Step 1] admin sets directAdapter.redeemDeadlineWindow to 0 (immediate expiry)");
        vm.prank(admin);
        directAdapter.setRedeemDeadlineWindow(0);
        _step(string.concat("  redeemDeadlineWindow = ", vm.toString(uint256(directAdapter.redeemDeadlineWindow()))));
        _step(string.concat("  block.timestamp = ", vm.toString(block.timestamp)));
        _step("  deadline will be: block.timestamp + 0 = block.timestamp (expired)");

        _step("[Step 2] controller-role holder calls directAdapter.requestRedeemAsync(100e6, receiver) directly");
        vm.prank(controller);
        vm.expectRevert("REDEEM_EXPIRED");
        directAdapter.requestRedeemAsync(100e6, receiver);
        _step("  reverted with REDEEM_EXPIRED");
        _step("  PASS: expired deadline correctly rejected by SubRed");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 17 — 价格估算-asset=0
    // ═══════════════════════════════════════════════════════════════

    function test_Case17_EstimatePosAmountZero() public {
        _logCase("Case-17", unicode"价格估算-asset=0");

        _step("[Step 1] call estimatePosAmount(0)");
        uint256 pos = adapter.estimatePosAmount(0);
        _step(string.concat("  result = ", vm.toString(pos)));
        assertEq(pos, 0);
        _step("  PASS: zero asset input returns zero pos");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 18 — 价格估算-asset不为0
    // ═══════════════════════════════════════════════════════════════

    function test_Case18_EstimatePosAmountWithOracle() public {
        _logCase("Case-18", unicode"价格估算-asset不为0");

        _step("[Step 1] parameters: asset=1000e18, oracle price=2, asset_dec=18, st_dec=6");
        _step("  formula: pos = 1000e18 * 1e18 * 1e6 / (2e18 * 1e18) = 500e6");
        uint256 pos = adapterWithOracle.estimatePosAmount(1000e18);
        _step(string.concat("  actual pos = ", vm.toString(pos)));
        assertEq(pos, 500e6);
        _step("  PASS: pos matches expected calculation with oracle price");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 19 — 价格估算-正向除不尽
    // ═══════════════════════════════════════════════════════════════

    function test_Case19_EstimatePosAmountRoundDown() public {
        _logCase("Case-19", unicode"价格估算-正向除不尽");

        _step("[Step 1] set oracle price to 2.1 (210000000 in 8-dec)");
        oracle.setPrice(210_000_000);
        _step("  parameters: asset=1001e18, price=2.1e18, st_dec=6");
        _step("  formula: pos = 1001e18 * 1e18 * 1e6 / (2.1e18 * 1e18) = 476666666.666...");
        _step("  expected: floor(476666666.666...) = 476666666");

        _step("[Step 2] call estimatePosAmount(1001e18)");
        uint256 pos = adapterWithOracle.estimatePosAmount(1001e18);
        _step(string.concat("  actual pos = ", vm.toString(pos)));
        assertEq(pos, 476_666_666);
        _step("  PASS: result is floor-rounded (no rounding up)");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 20 — 价格估算-反向除不尽
    // ═══════════════════════════════════════════════════════════════

    function test_Case20_EstimateAssetAmountRoundDown() public {
        _logCase("Case-20", unicode"价格估算-反向除不尽");

        _step("[Step 1] set oracle price to 2.1 (210000000 in 8-dec)");
        oracle.setPrice(210_000_000);
        _step("  parameters: pos=476666666, price=2.1e18, stDec=6, assetDec=18");
        _step("  formula: asset = 476666666 * 2.1e18 * 1e18 / (1e18 * 1e6)");
        _step("  expected: 1000999998600000000000 (floor)");

        _step("[Step 2] seed 476666666 ST into vault through real invest settlement");
        _seedVaultSt(476_666_666e12, receiver);
        _step(string.concat("  vault ST balance = ", vm.toString(stToken6.balanceOf(address(vault)))));
        uint256 totalVal = adapterWithOracle.totalValue();
        _step(string.concat("  totalValue = ", vm.toString(totalVal)));

        _step("[Step 3] verify floor rounding: 1000e18 < totalValue < 1001e18");
        assertLt(totalVal, 1001e18);
        assertGt(totalVal, 1000e18);
        _step("  PASS: reverse estimation is floor-rounded");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 21 — 价格估算-检查totalValue
    // ═══════════════════════════════════════════════════════════════

    function test_Case21_TotalValueCheck() public {
        _logCase("Case-21", unicode"价格估算-检查totalValue");

        _step("[Step 1] seed 500e6 ST into vault through real invest settlement");
        _seedVaultSt(500e18, receiver);
        _step(string.concat("  vault ST balance = ", vm.toString(stToken6.balanceOf(address(vault)))));
        _step("  oracle price = 2, st_dec = 6, asset_dec = 18");
        _step("  expected totalValue = 500e6 * 2 * 1e12 = 1000e18");

        _step("[Step 2] call totalValue()");
        uint256 value = adapterWithOracle.totalValue();
        _step(string.concat("  totalValue = ", vm.toString(value)));
        assertEq(value, 1000e18);
        _step("  PASS: totalValue matches ST balance * price with decimal scaling");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 22 — 价格估算-oracle为0
    // ═══════════════════════════════════════════════════════════════

    function test_Case22_EstimatePosAmountOracleReturnsZero() public {
        _logCase("Case-22", unicode"价格估算-oracle为0");

        _step("[Step 1] set oracle price to 0");
        oracle.setPrice(0);
        _step("  oracle price = 0 => getPosTokenPrice() returns 0 => estimatePosAmount returns 0");

        _step("[Step 2] call estimatePosAmount(2000e18)");
        uint256 pos = adapterWithOracle.estimatePosAmount(2000e18);
        _step(string.concat("  pos = ", vm.toString(pos)));
        assertEq(pos, 0);
        _step("  PASS: oracle returning 0 means no valid price, estimatePosAmount returns 0");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 23 — 价格估算-同精度换算
    // ═══════════════════════════════════════════════════════════════

    function test_Case23_EstimatePosAmountSameDecimals() public {
        _logCase("Case-23", unicode"价格估算-同精度换算");

        _step("[Step 1] adapterSameDecimals: asset_dec=18, st_dec=18, no oracle, manualPrice=1e18");
        _step("  expected: 500e18 asset -> 500e18 pos (no scaling)");

        _step("[Step 2] call estimatePosAmount(500e18)");
        uint256 pos = adapterSameDecimals.estimatePosAmount(500e18);
        _step(string.concat("  pos = ", vm.toString(pos)));
        assertEq(pos, 500e18);
        _step("  PASS: same-decimal assets map 1:1");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 24 — 价格估算-不同精度换算
    // ═══════════════════════════════════════════════════════════════

    function test_Case24_EstimatePosAmountDifferentDecimals() public {
        _logCase("Case-24", unicode"价格估算-不同精度换算");

        _step("[Step 1] test scale-down: asset_dec=18, st_dec=6, manualPrice=1e18");
        _step("  formula: pos = 1000e18 * 1e18 / (1e18 * 1e12) = 1000e6");
        uint256 pos = adapter.estimatePosAmount(1000e18);
        _step(string.concat("  result: 1000e18 asset -> ", vm.toString(pos), " st (6 decimals)"));
        assertEq(pos, 1000e6);

        _step("[Step 2] test scale-up: asset_dec=6, st_dec=18, manualPrice=1e18");
        MockVault_AQ vault6 = new MockVault_AQ(address(usdc6));
        SubRedManagementAdapter adapterHighSt = SubRedManagementAdapter(factory.deployAndInitAdapter(
            address(vault6), address(subRed), address(stToken18), admin, controller, accountant, address(0)
        ));
        vm.prank(accountant);
        adapterHighSt.setManualPosTokenPrice(1e18);
        _step("  formula: pos = 1000e6 * 1e18 * 1e12 / 1e18 = 1000e18");
        uint256 pos2 = adapterHighSt.estimatePosAmount(1000e6);
        _step(string.concat("  result: 1000e6 asset -> ", vm.toString(pos2), " st (18 decimals)"));
        assertEq(pos2, 1000e18);
        _step("  PASS: both scale-down and scale-up conversions correct");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 25 — 价格估算-adapter有闲置usdc
    // ═══════════════════════════════════════════════════════════════

    function test_Case25_TotalValueExcludesAdapterIdleAsset() public {
        _logCase("Case-25", unicode"价格估算-adapter有闲置usdc");

        _step("[Step 1] seed 500e6 ST into vault through real invest settlement");
        _seedVaultSt(500e18, receiver);
        _step(string.concat("  vault ST balance = ", vm.toString(stToken6.balanceOf(address(vault)))));

        _step("[Step 2] transfer 100e18 idle USDC to adapter");
        _fundAdapterAsset(address(adapterWithOracle), 100e18);
        _step(string.concat("  adapter USDC balance = ", vm.toString(usdc.balanceOf(address(adapterWithOracle)))));

        _step("[Step 3] check totalValue (should only reflect vault ST, not adapter idle USDC)");
        uint256 value = adapterWithOracle.totalValue();
        _step(string.concat("  totalValue = ", vm.toString(value)));
        _step("  expected = 500e6 * 2 * 1e12 = 1000e18 (excludes idle USDC)");
        assertEq(value, 1000e18);
        _step("  PASS: totalValue excludes adapter idle asset by design");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 26 — 价格估算-vault无st余额
    // ═══════════════════════════════════════════════════════════════

    function test_Case26_TotalValueVaultNoST() public {
        _logCase("Case-26", unicode"价格估算-vault无st余额");

        _step("[Step 1] vault has 0 ST");
        _step(string.concat("  vault ST balance = ", vm.toString(stToken6.balanceOf(address(vault)))));

        _step("[Step 2] transfer 50e18 idle USDC to adapter");
        _fundAdapterAsset(address(adapterWithOracle), 50e18);
        _step(string.concat("  adapter USDC balance = ", vm.toString(usdc.balanceOf(address(adapterWithOracle)))));

        _step("[Step 3] check totalValue");
        uint256 value = adapterWithOracle.totalValue();
        _step(string.concat("  totalValue = ", vm.toString(value)));
        assertEq(value, 0);
        _step("  PASS: totalValue = 0 when vault has no ST (idle USDC not counted)");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 27 — 价格估算-有oracle时设置价格
    // ═══════════════════════════════════════════════════════════════

    function test_Case27_SetManualPriceWithOracleReverts() public {
        _logCase("Case-27", unicode"价格估算-有oracle时设置价格");

        _step("[Step 1] verify adapterWithOracle has oracle configured");
        _step(string.concat("  priceOracle = ", vm.toString(adapterWithOracle.priceOracle())));

        _step("[Step 2] accountant calls setManualPosTokenPrice(5e18) -> revert");
        vm.prank(accountant);
        vm.expectRevert(BaseAdapterUpgradeable.Unsupported.selector);
        adapterWithOracle.setManualPosTokenPrice(5e18);
        _step("  reverted with Unsupported");
        _step("  PASS: cannot set manual price when oracle is active");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 28 — 价格估算-禁用oracle设置价格
    // ═══════════════════════════════════════════════════════════════

    function test_Case28_DisableOracleThenSetManualPrice() public {
        _logCase("Case-28", unicode"价格估算-禁用oracle设置价格");

        _step(string.concat("[Step 1] current priceOracle = ", vm.toString(adapterWithOracle.priceOracle())));
        _step("  admin calls setPriceOracle(address(0)) to disable");
        vm.prank(admin);
        adapterWithOracle.setPriceOracle(address(0));
        _step(string.concat("  priceOracle after = ", vm.toString(adapterWithOracle.priceOracle())));
        assertEq(adapterWithOracle.priceOracle(), address(0));

        _step("[Step 2] accountant sets manual price to 4e18");
        vm.prank(accountant);
        adapterWithOracle.setManualPosTokenPrice(4e18);
        _step("  setManualPosTokenPrice(4e18) succeeded");

        _step("[Step 3] verify getPosTokenPrice returns manual price");
        uint256 price = adapterWithOracle.getPosTokenPrice();
        _step(string.concat("  getPosTokenPrice = ", vm.toString(price)));
        assertEq(price, 4e18);
        _step("  PASS: after disabling oracle, manual price takes effect");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 29 — 价格估算-无oracle设置价格
    // ═══════════════════════════════════════════════════════════════

    function test_Case29_NoOracleSetManualPrice() public {
        _logCase("Case-29", unicode"价格估算-无oracle设置价格");

        _step("[Step 1] verify adapter has no oracle configured");
        _step(string.concat("  priceOracle = ", vm.toString(adapter.priceOracle())));
        assertEq(adapter.priceOracle(), address(0));

        _step("[Step 2] accountant sets manual price to 3e18");
        vm.prank(accountant);
        adapter.setManualPosTokenPrice(3e18);
        _step("  setManualPosTokenPrice(3e18) succeeded");

        _step("[Step 3] verify getPosTokenPrice returns manual price");
        uint256 price = adapter.getPosTokenPrice();
        _step(string.concat("  getPosTokenPrice = ", vm.toString(price)));
        assertEq(price, 3e18);
        _step("  PASS: manual price correctly set without oracle");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 30 — 价格估算-无oracle不设置价格
    // ═══════════════════════════════════════════════════════════════

    function test_Case30_NoOracleNoManualPrice() public {
        _logCase("Case-30", unicode"价格估算-无oracle不设置价格");

        _step("[Step 0] clear manual price set in setUp");
        vm.prank(accountant);
        adapter.setManualPosTokenPrice(0);

        _step("[Step 1] verify adapter has no oracle and no manual price");
        _step(string.concat("  priceOracle = ", vm.toString(adapter.priceOracle())));
        assertEq(adapter.priceOracle(), address(0));

        _step("[Step 2] call getPosTokenPrice()");
        uint256 price = adapter.getPosTokenPrice();
        _step(string.concat("  getPosTokenPrice = ", vm.toString(price)));
        assertEq(price, 0);
        _step("  PASS: M-6 fallback price is 0 when no oracle and no manual price");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 31 — 价格估算-有oracle并设置价格
    // ═══════════════════════════════════════════════════════════════

    function test_Case31_OraclePriorityOverManual() public {
        _logCase("Case-31", unicode"价格估算-有oracle并设置价格");

        _step("[Step 1] disable oracle, set manual=9e18, re-enable oracle");
        vm.prank(admin);
        adapterWithOracle.setPriceOracle(address(0));
        _step("  oracle disabled");
        vm.prank(accountant);
        adapterWithOracle.setManualPosTokenPrice(9e18);
        _step("  manual price set to 9e18");
        vm.prank(admin);
        adapterWithOracle.setPriceOracle(address(oracle));
        _step(string.concat("  oracle re-enabled at ", vm.toString(address(oracle))));

        _step("[Step 2] getPosTokenPrice should return oracle value (2e18), not manual (9e18)");
        uint256 price = adapterWithOracle.getPosTokenPrice();
        assertEq(price, 2e18);
        _step(string.concat("  getPosTokenPrice = ", vm.toString(price)));
        _step("  PASS: oracle price (2e18) takes priority over manual price (9e18)");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 32 — 价格估算-事件触发验证
    // ═══════════════════════════════════════════════════════════════

    function test_Case32_PriceEventEmission() public {
        _logCase("Case-32", unicode"价格估算-事件触发验证");

        _step("[Step 1] accountant calls setManualPosTokenPrice(5e18), verify ManualPosTokenPriceUpdated event");
        vm.recordLogs();
        vm.prank(accountant);
        adapter.setManualPosTokenPrice(5e18);
        {
            VmSafe.Log[] memory logs = vm.getRecordedLogs();
            bool found;
            for (uint256 i; i < logs.length; i++) {
                if (logs[i].topics[0] == keccak256("ManualPosTokenPriceUpdated(uint256,uint256,address)")) {
                    assertEq(logs[i].emitter, address(adapter), "wrong emitter");
                    assertEq(address(uint160(uint256(logs[i].topics[1]))), accountant, "wrong updater");
                    (uint256 oldP, uint256 newP) = abi.decode(logs[i].data, (uint256, uint256));
                    assertEq(oldP, 1e18, "wrong oldPrice");
                    assertEq(newP, 5e18, "wrong newPrice");
                    found = true;
                    break;
                }
            }
            assertTrue(found, "ManualPosTokenPriceUpdated not emitted");
        }
        _step("  ManualPosTokenPriceUpdated(oldPrice=1e18, newPrice=5e18, updater=accountant) emitted");

        _step("[Step 2] admin calls setPriceOracle(oracle), verify PriceOracleUpdated event");
        vm.recordLogs();
        vm.prank(admin);
        adapter.setPriceOracle(address(oracle));
        {
            VmSafe.Log[] memory logs = vm.getRecordedLogs();
            bool found;
            for (uint256 i; i < logs.length; i++) {
                if (logs[i].topics[0] == keccak256("PriceOracleUpdated(address,address,address)")) {
                    assertEq(logs[i].emitter, address(adapter), "wrong emitter");
                    assertEq(address(uint160(uint256(logs[i].topics[1]))), address(0), "wrong oldOracle");
                    assertEq(address(uint160(uint256(logs[i].topics[2]))), address(oracle), "wrong newOracle");
                    assertEq(address(uint160(uint256(logs[i].topics[3]))), admin, "wrong updater");
                    found = true;
                    break;
                }
            }
            assertTrue(found, "PriceOracleUpdated not emitted");
        }
        _step("  PriceOracleUpdated(oldOracle=0x0, newOracle=oracle, updater=admin) emitted");
        _step("  PASS: both price-related events correctly emitted");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 33 — SweepToVault-余额150请求100
    // ═══════════════════════════════════════════════════════════════

    function test_Case33_SweepToVaultPartial() public {
        _logCase("Case-33", unicode"SweepToVault-余额150请求100");

        _step("[Step 1] transfer 150e18 USDC to adapter");
        _fundAdapterAsset(address(directAdapter), 150e18);
        _step(string.concat("  adapter USDC balance = ", vm.toString(usdc.balanceOf(address(directAdapter)))));

        _step("[Step 2] controller-role holder calls directAdapter.sweepToVault(usdc, 100e18)");
        vm.prank(controller);
        uint256 claimed = directAdapter.sweepToVault(address(usdc), 100e18);
        _step(string.concat("  claimed = ", vm.toString(claimed)));

        _step("[Step 3] verify balances after partial sweep");
        uint256 vaultBal = usdc.balanceOf(address(directVault));
        uint256 adapterBal = usdc.balanceOf(address(directAdapter));
        _step(string.concat("  vault USDC = ", vm.toString(vaultBal)));
        _step(string.concat("  adapter USDC = ", vm.toString(adapterBal)));
        assertEq(claimed, 100e18);
        assertEq(vaultBal, 100e18);
        assertEq(adapterBal, 50e18);
        _step("  PASS: partial sweep transferred 100, left 50 in adapter");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 34 — SweepToVault-超额
    // ═══════════════════════════════════════════════════════════════

    function test_Case34_SweepToVaultExceedsBalance() public {
        _logCase("Case-34", unicode"SweepToVault-超额");

        _step("[Step 1] transfer 80e18 USDC to adapter");
        _fundAdapterAsset(address(directAdapter), 80e18);
        _step(string.concat("  adapter USDC balance = ", vm.toString(usdc.balanceOf(address(directAdapter)))));

        _step("[Step 2] controller-role holder calls directAdapter.sweepToVault(usdc, 200e18) -> requests more than available");
        vm.prank(controller);
        uint256 claimed = directAdapter.sweepToVault(address(usdc), 200e18);
        _step(string.concat("  claimed = ", vm.toString(claimed), " (capped to balance)"));

        _step("[Step 3] verify balances: claimed = min(200, 80) = 80");
        uint256 vaultBal = usdc.balanceOf(address(directVault));
        uint256 adapterBal = usdc.balanceOf(address(directAdapter));
        _step(string.concat("  vault USDC = ", vm.toString(vaultBal)));
        _step(string.concat("  adapter USDC = ", vm.toString(adapterBal)));
        assertEq(claimed, 80e18);
        assertEq(vaultBal, 80e18);
        assertEq(adapterBal, 0);
        _step("  PASS: sweep capped to available balance");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 35 — SweepToVault-余额为0
    // ═══════════════════════════════════════════════════════════════

    function test_Case35_SweepToVaultZeroBalance() public {
        _logCase("Case-35", unicode"SweepToVault-余额为0");

        _step("[Step 1] verify adapter USDC balance is 0");
        _step(string.concat("  adapter USDC balance = ", vm.toString(usdc.balanceOf(address(directAdapter)))));

        _step("[Step 2] controller-role holder calls directAdapter.sweepToVault(usdc, 100e18)");
        vm.prank(controller);
        uint256 claimed = directAdapter.sweepToVault(address(usdc), 100e18);
        _step(string.concat("  claimed = ", vm.toString(claimed)));

        _step("[Step 3] verify no transfer occurred");
        assertEq(claimed, 0);
        assertEq(usdc.balanceOf(address(directVault)), 0);
        _step("  PASS: zero balance sweep returns 0 without error");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 36 — SweepToVault-token无效
    // ═══════════════════════════════════════════════════════════════

    function test_Case36_SweepToVaultInvalidToken() public {
        _logCase("Case-36", unicode"SweepToVault-token无效");

        _step("[Step 1] controller-role holder calls directAdapter.sweepToVault(address(0), 100e18)");
        _step("  token = address(0)");
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(BaseAdapterUpgradeable.InvalidToken.selector, address(0)));
        directAdapter.sweepToVault(address(0), 100e18);
        _step("  reverted with InvalidToken(address(0))");
        _step("  PASS: zero address token correctly rejected");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 37 — Sweep-非保护代币
    // ═══════════════════════════════════════════════════════════════

    function test_Case37_SweepUnprotectedToken() public {
        _logCase("Case-37", unicode"Sweep-非保护代币");

        _step("[Step 1] transfer 50e18 dustToken to adapter");
        _fundAdapterDust(50e18);
        _step(string.concat("  adapter dustToken balance = ", vm.toString(dustToken.balanceOf(address(adapter)))));

        _step("[Step 2] admin calls sweep(dustToken, receiver)");
        _step(string.concat("  receiver = ", vm.toString(receiver)));
        vm.prank(admin);
        adapter.sweep(address(dustToken), receiver);

        _step("[Step 3] verify all transferred to receiver");
        uint256 receiverBal = dustToken.balanceOf(receiver);
        uint256 adapterBal = dustToken.balanceOf(address(adapter));
        _step(string.concat("  receiver dustToken = ", vm.toString(receiverBal)));
        _step(string.concat("  adapter dustToken = ", vm.toString(adapterBal)));
        assertEq(receiverBal, 50e18);
        assertEq(adapterBal, 0);
        _step("  PASS: unprotected token swept successfully to receiver");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 38 — Sweep-接收者为零地址
    // ═══════════════════════════════════════════════════════════════

    function test_Case38_SweepZeroReceiver() public {
        _logCase("Case-38", unicode"Sweep-接收者为零地址");

        _step("[Step 1] transfer 10e18 dustToken to adapter");
        _fundAdapterDust(10e18);
        _step(string.concat("  adapter dustToken balance = ", vm.toString(dustToken.balanceOf(address(adapter)))));

        _step("[Step 2] admin calls sweep(dustToken, address(0)) -> revert");
        _step("  receiver = address(0)");
        vm.prank(admin);
        vm.expectRevert(BaseAdapterUpgradeable.InvalidAddress.selector);
        adapter.sweep(address(dustToken), address(0));
        _step("  reverted with InvalidAddress");
        _step("  PASS: zero receiver address correctly rejected");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 39 — Sweep-token无效
    // ═══════════════════════════════════════════════════════════════

    function test_Case39_SweepInvalidToken() public {
        _logCase("Case-39", unicode"Sweep-token无效");

        _step("[Step 1] admin calls sweep(address(0), receiver)");
        _step("  token = address(0)");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(BaseAdapterUpgradeable.InvalidToken.selector, address(0)));
        adapter.sweep(address(0), receiver);
        _step("  reverted with InvalidToken(address(0))");
        _step("  PASS: zero address token correctly rejected");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 40 — Sweep-token为ASSET
    // ═══════════════════════════════════════════════════════════════

    function test_Case40_SweepProtectedAsset() public {
        _logCase("Case-40", unicode"Sweep-token为ASSET");

        _step("[Step 1] transfer 10e18 USDC (ASSET) to adapter");
        _fundAdapterAsset(address(adapter), 10e18);
        _step(string.concat("  adapter USDC balance = ", vm.toString(usdc.balanceOf(address(adapter)))));
        _step(string.concat("  ASSET address = ", vm.toString(address(usdc))));

        _step("[Step 2] admin calls sweep(ASSET, receiver) -> revert");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(BaseAdapterUpgradeable.SweepProtectedToken.selector, address(usdc)));
        adapter.sweep(address(usdc), receiver);
        _step("  reverted with SweepProtectedToken(USDC)");
        _step("  PASS: ASSET token is protected and cannot be swept");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 41 — Sweep-token为ST_TOKEN
    // ═══════════════════════════════════════════════════════════════

    function test_Case41_SweepProtectedSTToken() public {
        _logCase("Case-41", unicode"Sweep-token为ST_TOKEN");

        _step("[Step 1] transfer 10e6 stToken6 (ST_TOKEN) to adapter");
        _fundAdapterSt6(10e6);
        _step(string.concat("  adapter stToken6 balance = ", vm.toString(stToken6.balanceOf(address(adapter)))));
        _step(string.concat("  ST_TOKEN address = ", vm.toString(address(stToken6))));

        _step("[Step 2] admin calls sweep(ST_TOKEN, receiver) -> revert");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(BaseAdapterUpgradeable.SweepProtectedToken.selector, address(stToken6)));
        adapter.sweep(address(stToken6), receiver);
        _step("  reverted with SweepProtectedToken(stToken6)");
        _step("  PASS: ST_TOKEN is protected and cannot be swept");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 42 — WithdrawSync-同步提现
    // ═══════════════════════════════════════════════════════════════

    function test_Case42_WithdrawSyncUnsupported() public {
        _logCase("Case-42", unicode"WithdrawSync-同步提现");

        _step("[Step 1] call withdrawSync(100e18, receiver)");
        _step(string.concat("  receiver = ", vm.toString(receiver)));
        _step("  amount = 100e18");
        vm.expectRevert(BaseAdapterUpgradeable.Unsupported.selector);
        adapter.withdrawSync(100e18, receiver);
        _step("  reverted with Unsupported");
        _step("  PASS: withdrawSync is not supported by SubRedManagementAdapter");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 43 — beaconOwner 升级 adapter 实现合约
    // ═══════════════════════════════════════════════════════════════

    function test_Case43_BeaconOwnerUpgrade() public {
        _logCase("Case-43", unicode"beaconOwner 升级 adapter 实现合约");

        UpgradeableBeacon beacon = factory.BEACON();
        address oldImpl = beacon.implementation();
        _step(string.concat("[Step 1] current impl = ", vm.toString(oldImpl)));

        _step("[Step 2] deploy V2 and upgrade");
        SubRedManagementAdapterV2 newImpl = new SubRedManagementAdapterV2();
        vm.prank(admin);
        beacon.upgradeTo(address(newImpl));

        assertEq(beacon.implementation(), address(newImpl), "impl should be newImpl");
        _step(string.concat("  new impl = ", vm.toString(address(newImpl))));
        _step("  PASS: BEACON.implementation() updated to V2");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 44 — 非 beaconOwner 无法升级
    // ═══════════════════════════════════════════════════════════════

    function test_Case44_NonOwnerCannotUpgrade() public {
        _logCase("Case-44", unicode"非 beaconOwner 无法升级");

        UpgradeableBeacon beacon = factory.BEACON();
        SubRedManagementAdapterV2 newImpl = new SubRedManagementAdapterV2();

        _step("[Step 1] non-owner attempts upgrade, expect revert");
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, other));
        beacon.upgradeTo(address(newImpl));
        _step("  PASS: reverted OwnableUnauthorizedAccount");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 45 — 升级为零地址
    // ═══════════════════════════════════════════════════════════════

    function test_Case45_UpgradeToZeroAddress() public {
        _logCase("Case-45", unicode"升级为零地址");

        UpgradeableBeacon beacon = factory.BEACON();

        _step("[Step 1] beaconOwner upgrades to address(0), expect revert");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UpgradeableBeacon.BeaconInvalidImplementation.selector, address(0)));
        beacon.upgradeTo(address(0));
        _step("  PASS: reverted BeaconInvalidImplementation");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 46 — 升级为 EOA
    // ═══════════════════════════════════════════════════════════════

    function test_Case46_UpgradeToEOA() public {
        _logCase("Case-46", unicode"升级为 EOA（无代码）");

        UpgradeableBeacon beacon = factory.BEACON();
        address eoa = makeAddr("eoa");

        _step("[Step 1] beaconOwner upgrades to EOA, expect revert");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UpgradeableBeacon.BeaconInvalidImplementation.selector, eoa));
        beacon.upgradeTo(eoa);
        _step("  PASS: reverted BeaconInvalidImplementation");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 47 — 升级后 ERC-7201 存储布局保持不变
    // ═══════════════════════════════════════════════════════════════

    function test_Case47_StatePreservedAfterUpgrade() public {
        _logCase("Case-47", unicode"升级后 ERC-7201 存储布局保持不变");

        _step("[Step 1] record V1 state");
        uint64 subWindow = adapter.subscribeDeadlineWindow();
        uint64 redWindow = adapter.redeemDeadlineWindow();
        uint256 price = adapter.getPosTokenPrice();
        address st = adapter.stToken();
        address pos = adapter.posToken();
        bool isPaused = adapter.paused();
        _step(string.concat("  subscribeDeadlineWindow = ", vm.toString(uint256(subWindow))));
        _step(string.concat("  redeemDeadlineWindow = ", vm.toString(uint256(redWindow))));
        _step(string.concat("  getPosTokenPrice = ", vm.toString(price)));
        _step(string.concat("  stToken = ", vm.toString(st)));
        _step(string.concat("  posToken = ", vm.toString(pos)));

        _step("[Step 2] upgrade beacon to V2");
        UpgradeableBeacon beacon = factory.BEACON();
        SubRedManagementAdapterV2 newImpl = new SubRedManagementAdapterV2();
        vm.prank(admin);
        beacon.upgradeTo(address(newImpl));

        _step("[Step 3] verify V1 state preserved");
        assertEq(adapter.subscribeDeadlineWindow(), subWindow, "subscribeDeadlineWindow preserved");
        assertEq(adapter.redeemDeadlineWindow(), redWindow, "redeemDeadlineWindow preserved");
        assertEq(adapter.getPosTokenPrice(), price, "getPosTokenPrice preserved");
        assertEq(adapter.stToken(), st, "stToken preserved");
        assertEq(adapter.posToken(), pos, "posToken preserved");
        assertEq(adapter.paused(), isPaused, "paused preserved");
        _step("  PASS: all ERC-7201 state preserved after V2 upgrade");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 48 — 批量升级所有 adapter
    // ═══════════════════════════════════════════════════════════════

    function test_Case48_BatchUpgradeAllAdapters() public {
        _logCase("Case-48", unicode"批量升级所有 adapter");

        _step("[Step 1] deploy 3 extra adapters via factory");
        MockVault_AQ v1 = new MockVault_AQ(address(usdc));
        MockVault_AQ v2 = new MockVault_AQ(address(usdc));
        MockVault_AQ v3 = new MockVault_AQ(address(usdc));
        address a1 = factory.deployAndInitAdapter(
            address(v1), address(subRed), address(stToken6), admin, controller, accountant, address(0)
        );
        address a2 = factory.deployAndInitAdapter(
            address(v2), address(subRed), address(stToken6), admin, controller, accountant, address(0)
        );
        address a3 = factory.deployAndInitAdapter(
            address(v3), address(subRed), address(stToken6), admin, controller, accountant, address(0)
        );

        _step("[Step 2] upgrade beacon once");
        UpgradeableBeacon beacon = factory.BEACON();
        SubRedManagementAdapterV2 newImpl = new SubRedManagementAdapterV2();
        vm.prank(admin);
        beacon.upgradeTo(address(newImpl));

        _step("[Step 3] all 3 adapters use new impl");
        assertEq(SubRedManagementAdapterV2(a1).version(), 2, "a1 should use V2");
        assertEq(SubRedManagementAdapterV2(a2).version(), 2, "a2 should use V2");
        assertEq(SubRedManagementAdapterV2(a3).version(), 2, "a3 should use V2");
        _step("  PASS: all 3 adapters upgraded simultaneously via single beacon upgrade");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 49 — 升级后 adapter 功能正常（deposit 全链路）
    // ═══════════════════════════════════════════════════════════════

    function test_Case49_PostUpgradeDepositFunctionality() public {
        _logCase("Case-49", unicode"升级后 adapter 功能正常（deposit 全链路）");

        _step("[Step 1] deposit before upgrade via full chain");
        uint256 depositAmt = 1000e18;
        _depositToVault(funder, depositAmt);
        uint256 inFlightId = vault.nextInFlightId();
        uint256 posAmt = adapter.estimatePosAmount(depositAmt);
        _rebalance();
        _settleAdapterInvest(inFlightId, posAmt);
        uint256 stBalBefore = stToken6.balanceOf(address(vault));
        _step(string.concat("  vault ST balance after first invest = ", vm.toString(stBalBefore)));
        assertTrue(stBalBefore > 0, "vault should hold ST tokens");

        _step("[Step 2] upgrade beacon to V2");
        UpgradeableBeacon beacon = factory.BEACON();
        SubRedManagementAdapterV2 newImpl = new SubRedManagementAdapterV2();
        vm.prank(admin);
        beacon.upgradeTo(address(newImpl));
        assertEq(SubRedManagementAdapterV2(address(adapter)).version(), 2, "adapter upgraded");

        _step("[Step 3] deposit after upgrade via full chain");
        _depositToVault(receiver, depositAmt);
        uint256 inFlightId2 = vault.nextInFlightId();
        uint256 posAmt2 = adapter.estimatePosAmount(depositAmt);
        _rebalance();
        _settleAdapterInvest(inFlightId2, posAmt2);
        uint256 stBalAfter = stToken6.balanceOf(address(vault));
        _step(string.concat("  vault ST balance after second invest = ", vm.toString(stBalAfter)));
        assertTrue(stBalAfter > stBalBefore, "vault ST balance should increase after second invest");
        _step("  PASS: deposit works correctly after upgrade");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 50 — 升级后新部署的 adapter 使用新实现
    // ═══════════════════════════════════════════════════════════════

    function test_Case50_NewDeployUsesNewImpl() public {
        _logCase("Case-50", unicode"升级后新部署的 adapter 使用新实现");

        _step("[Step 1] upgrade beacon to V2");
        UpgradeableBeacon beacon = factory.BEACON();
        SubRedManagementAdapterV2 newImpl = new SubRedManagementAdapterV2();
        vm.prank(admin);
        beacon.upgradeTo(address(newImpl));

        _step("[Step 2] deploy new adapter after upgrade");
        MockVault_AQ newVault = new MockVault_AQ(address(usdc));
        address newAdapter = factory.deployAndInitAdapter(
            address(newVault), address(subRed), address(stToken6), admin, controller, accountant, address(0)
        );

        assertEq(SubRedManagementAdapterV2(newAdapter).version(), 2, "new adapter should use V2");
        assertEq(factory.implementation(), address(newImpl), "factory.implementation should be V2");
        _step("  PASS: new deployment uses new implementation");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Case 51 — V2 新增 storage 与 V1 存储兼容
    // ═══════════════════════════════════════════════════════════════

    function test_Case51_V2StorageCompatibility() public {
        _logCase("Case-51", unicode"V2 新增 storage 与 V1 存储兼容");

        _step("[Step 1] record V1 state");
        uint64 subWindow = adapter.subscribeDeadlineWindow();
        uint256 price = adapter.getPosTokenPrice();
        address st = adapter.stToken();
        _step(string.concat("  subscribeDeadlineWindow = ", vm.toString(uint256(subWindow))));
        _step(string.concat("  getPosTokenPrice = ", vm.toString(price)));

        _step("[Step 2] upgrade to V2WithStorage");
        UpgradeableBeacon beacon = factory.BEACON();
        SubRedManagementAdapterV2WithStorage newImpl = new SubRedManagementAdapterV2WithStorage();
        vm.prank(admin);
        beacon.upgradeTo(address(newImpl));

        _step("[Step 3] verify V1 state preserved");
        SubRedManagementAdapterV2WithStorage upgraded = SubRedManagementAdapterV2WithStorage(address(adapter));
        assertEq(upgraded.subscribeDeadlineWindow(), subWindow, "subscribeDeadlineWindow preserved");
        assertEq(upgraded.getPosTokenPrice(), price, "getPosTokenPrice preserved");
        assertEq(upgraded.stToken(), st, "stToken preserved");

        _step("[Step 4] V2 new storage works");
        assertEq(upgraded.extraParam(), 0, "extraParam default is 0");
        upgraded.setExtraParam(42);
        assertEq(upgraded.extraParam(), 42, "extraParam set to 42");
        assertEq(upgraded.version(), 2, "version is 2");

        _step("[Step 5] V1 state still intact after V2 storage write");
        assertEq(upgraded.subscribeDeadlineWindow(), subWindow, "subscribeDeadlineWindow still preserved");
        assertEq(upgraded.getPosTokenPrice(), price, "getPosTokenPrice still preserved");
        _step("  PASS: V2 new storage compatible with V1 ERC-7201 layout");

        _logPass();
    }
}
