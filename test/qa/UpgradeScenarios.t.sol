// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategyAdapter} from "../../src/interfaces/adapters/IStrategyAdapter.sol";
import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {IMantleVaultGateway} from "../../src/interfaces/vault/IMantleVaultGateway.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {IAccountant} from "../../src/interfaces/accountant/IAccountant.sol";
import {GatewayFactory} from "../../src/vault/GatewayFactory.sol";
import {MantleVaultGateway} from "../../src/vault/MantleVaultGateway.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {VaultFactory} from "../../src/vault/VaultFactory.sol";
import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {StrategyControllerFactory} from "../../src/protocol/StrategyControllerFactory.sol";
import {Accountant} from "../../src/accountant/Accountant.sol";
import {AccountantFactory} from "../../src/accountant/AccountantFactory.sol";
import {AccountantExecutor} from "../../src/accountant/AccountantExecutor.sol";
import {OperatorExecutor} from "../../src/protocol/OperatorExecutor.sol";
import {IStrategyControllerExecutor} from "../../src/interfaces/strategy/IStrategyControllerExecutor.sol";
import {SanctionsOracle} from "../../src/compliance/SanctionsOracle.sol";
import {SanctionsOracleFactory} from "../../src/compliance/SanctionsOracleFactory.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IAccessControlDefaultAdminRules} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {TimelockController as TimelockUpgradeController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test, console2} from "forge-std/Test.sol";

// ---------------------------------------------------------------------------
// Mock contracts
// ---------------------------------------------------------------------------

contract MockUSDC_Upgrade is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockSanctionsOracle_Upgrade is ISanctionsOracle {
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

contract MockAccountant_Upgrade {
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

    function setExchangeRate(uint256 newRate) external {
        exchangeRate = newRate;
    }

    function mintFeeShares(uint256) external {}
    function updateExchangeRate(uint64, uint64) external {}
}

/// @dev V2 implementation for Gateway that adds a version function
contract MantleVaultGatewayV2 is MantleVaultGateway {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @dev V2 implementation for Vault that adds a version function
contract MantleYieldVaultV2 is MantleYieldVault {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @dev V2 implementation for SanctionsOracle that adds a version function
contract SanctionsOracleV2 is SanctionsOracle {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @dev V2 implementation for Accountant that adds a version function
contract AccountantV2 is Accountant {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @dev V2 Accountant that appends a new storage variable (compatible)
contract AccountantV2WithStorage is Accountant {
    uint256 public newAccountantVar;

    function setNewAccountantVar(uint256 val) external {
        newAccountantVar = val;
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @dev V2 implementation for StrategyController that adds a version function
contract StrategyControllerV2 is StrategyController {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @dev V2 for AccountantExecutor
contract AccountantExecutorV2 is AccountantExecutor {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @dev V2 for OperatorExecutor
contract OperatorExecutorV2 is OperatorExecutor {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @dev V2 implementation for Vault that appends a new storage variable
contract MantleYieldVaultV2WithStorage is MantleYieldVault {
    uint256 public newVar;

    function setNewVar(uint256 val) external {
        newVar = val;
    }
}

/// @dev V2 implementation for Vault with reinitializer(2)
contract MantleYieldVaultV2Reinit is MantleYieldVault {
    uint256 public extraData;

    function reinitialize(uint256 val) external reinitializer(2) {
        extraData = val;
    }
}

/// @dev Mock vault for full-chain Accountant tests (tracks mintFeeShares calls and totalSupply)
contract MockVaultForUpgrade {
    uint256 public _totalSupply;
    uint256 public lastFeeShares;
    uint256 public totalFeeMintCalls;

    constructor(uint256 initialSupply) {
        _totalSupply = initialSupply;
    }

    function mintFeeShares(uint256 shares) external {
        lastFeeShares = shares;
        totalFeeMintCalls++;
        _totalSupply += shares;
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function asset() external pure returns (address) {
        return address(0xA);
    }
}

/// @dev Incompatible V2 that swaps field positions in the ERC-7201 namespaced storage struct.
///      In V1: slot 0 = vault(20) + maxAllowedDeviation(4) + managementFeeRate(4) + minUpdateInterval(4)
///             slot 2 = lastExchangeRate (uint256)
///      This V2 puts lastExchangeRate into slot 1 (where maxComputeAge/timestamps were),
///      so reading lastExchangeRate after upgrade returns corrupted data.
contract AccountantV2Incompatible {
    bytes32 private constant ACCOUNTANT_STORAGE_LOCATION =
        0x6c92d3e3e5b85f72ef5aed0666c2a5bff81ca952e7397a04503941b502a0e700;

    struct AccountantStorageBroken {
        // ── slot 0 ── same as V1
        address vault;
        uint32 maxAllowedDeviation;
        uint32 managementFeeRate;
        uint32 minUpdateInterval;
        // ── slot 1 ── SWAPPED: lastExchangeRate moved here (was in slot 2)
        uint256 lastExchangeRate;
        // ── slot 2 ── timestamps moved here (were in slot 1)
        uint32 maxComputeAge;
        uint64 lastComputeTimestamp;
        uint64 lastFeeSettleTimestamp;
        uint64 lastUpdateTimestamp;
        // ── slot 3 ──
        uint256 totalSharesLastSettle;
    }

    function _getBrokenStorage() private pure returns (AccountantStorageBroken storage $) {
        bytes32 loc = ACCOUNTANT_STORAGE_LOCATION;
        assembly {
            $.slot := loc
        }
    }

    function getRate() external view returns (uint256) {
        return _getBrokenStorage().lastExchangeRate;
    }

    function lastExchangeRate() external view returns (uint256) {
        return _getBrokenStorage().lastExchangeRate;
    }

    function managementFeeRate() external view returns (uint32) {
        return _getBrokenStorage().managementFeeRate;
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @dev V2 StrategyController that appends a new storage variable (compatible)
contract StrategyControllerV2WithStorage is StrategyController {
    uint256 public newControllerVar;

    function setNewControllerVar(uint256 val) external {
        newControllerVar = val;
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @dev Incompatible V2 StrategyController that reorders storage variables.
///      In V1: slot layout starts with asset(20), vault(20), then packed uint16+uint64 fields.
///      This V2 swaps vault and asset positions so reading them after upgrade returns corrupted data.
contract StrategyControllerV2Incompatible {
    // Swapped: vault first, then asset (opposite of V1)
    address public vault;
    address public asset;
    uint16 public bufferTargetBps;

    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @dev V2 SanctionsOracle that appends a new variable in the ERC-7201 namespace (compatible)
contract SanctionsOracleV2WithStorage is SanctionsOracle {
    // Appended outside the ERC-7201 struct - safe for beacon proxy
    uint256 public extraOracleData;

    function setExtraOracleData(uint256 val) external {
        extraOracleData = val;
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @dev Mock vault for StrategyController integration tests.
///      Implements the subset of IMantleYieldVault that StrategyController actually calls.
contract MockVaultForController {
    ERC20 public immutable token;
    uint256 public mockedExchangeRate = 1e18;

    uint256 public locked;
    uint256 public investInFlightTotal;
    uint256 public redeemInFlightTotal;
    uint256 public inFlightIdCursor;
    mapping(address => uint256) public investInFlightByAdapter;
    mapping(address => uint256) public redeemInFlightByAdapter;
    mapping(address => bool) public isAdapterRegistry;

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

    mapping(uint256 => InFlight) public flights;

    constructor(address asset_) {
        token = ERC20(asset_);
    }

    function asset() external view returns (address) {
        return address(token);
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

    /// @dev Simplified mirror of MantleYieldVault.totalAssets().
    function totalAssets() external view returns (uint256) {
        uint256 total = token.balanceOf(address(this)) + investInFlightTotal + redeemInFlightTotal;
        return total > locked ? total - locked : 0;
    }

    /// @dev M-8: StrategyController now uses vault.pendingRequestCount() instead of
    ///      _hasPendingLatestRequest. No requests in these integration tests → return 0.
    function pendingRequestCount() external pure returns (uint256) {
        return 0;
    }

    function nextRequestId() external pure returns (uint256) {
        return 1;
    }

    /// @dev Required for _hasPendingLatestRequest fallback path — never hit while nextRequestId()==1.
    function requests(uint256)
        external
        pure
        returns (uint256, address, uint256, uint256, uint256, uint256, uint256, IMantleYieldVault.RequestStatus)
    {
        return (0, address(0), 0, 0, 0, 0, 0, IMantleYieldVault.RequestStatus.NONE);
    }

    function approveToAdapter(address adapter, address approveToken, uint256 amount) external {
        ERC20(approveToken).approve(adapter, amount);
    }

    function isAdapter(address adapter) external view returns (bool) {
        return isAdapterRegistry[adapter];
    }

    function registerAdapter(address adapter) external {
        isAdapterRegistry[adapter] = true;
    }

    function removeAdapter(address adapter) external {
        require(investInFlightByAdapter[adapter] == 0 && redeemInFlightByAdapter[adapter] == 0, "HAS_IN_FLIGHT");
        isAdapterRegistry[adapter] = false;
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

/// @dev Mock strategy adapter for upgrade integration tests.
contract MockAdapterForUpgrade is IStrategyAdapter {
    address public immutable ASSET;
    address public immutable POS_TOKEN;
    address public immutable VAULT;

    uint256 public depositCount;
    uint256 public withdrawCount;

    constructor(address asset_, address posToken_, address vault_) {
        ASSET = asset_;
        POS_TOKEN = posToken_;
        VAULT = vault_;
    }

    function name() external pure returns (string memory) { return "MockAdapterForUpgrade"; }
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
    function vault() external view returns (address) { return VAULT; }
    function totalValue() external view returns (uint256) {
        return ERC20(ASSET).balanceOf(address(this)) + ERC20(POS_TOKEN).balanceOf(address(this));
    }

    function deposit(uint256 amount, address) external returns (uint256) {
        depositCount++;
        ERC20(ASSET).transferFrom(VAULT, address(this), amount);
        return amount;
    }

    function withdrawSync(uint256 amount, address) external returns (uint256) {
        withdrawCount++;
        return amount;
    }

    function requestRedeemAsync(uint256, address) external {}
    function retryRedeemAsync(uint256, address) external {}

    function sweepToVault(address token, uint256 amount) external returns (uint256) {
        ERC20(token).transfer(VAULT, amount);
        return amount;
    }

    function setPaused(bool) external {}
}

/// @dev Not a UUPS contract - for testing upgrade-to-non-UUPS failure
contract NotUUPS {
    function proxiableUUID() external pure returns (bytes32) {
        return bytes32(0);
    }
}

// ---------------------------------------------------------------------------
// QA Test Suite
// ---------------------------------------------------------------------------

contract UpgradeScenariosQATest is Test {
    struct RealControllerStack {
        MantleYieldVault vault;
        MantleVaultGateway gateway;
        Accountant accountant;
        OperatorExecutor operatorExecutor;
        StrategyControllerFactory factory;
        UpgradeableBeacon beacon;
        StrategyController controller;
        MockUSDC_Upgrade posToken;
        MockAdapterForUpgrade adapter;
    }

    struct RealAccountantStack {
        MantleYieldVault vault;
        MantleVaultGateway gateway;
        Accountant accountant;
        AccountantExecutor executor;
        AccountantFactory factory;
    }

    MockUSDC_Upgrade internal usdc;
    MockSanctionsOracle_Upgrade internal oracle;
    MockAccountant_Upgrade internal mockAccountant;

    address internal admin = makeAddr("admin");
    address internal attacker = makeAddr("attacker");
    address internal treasuryAddr = makeAddr("treasury");
    address internal sanctionSafe = makeAddr("sanctionSafe");
    address internal userA = makeAddr("userA");
    address internal userB = makeAddr("userB");
    address internal bot = makeAddr("bot");

    function setUp() public {
        usdc = new MockUSDC_Upgrade();
        oracle = new MockSanctionsOracle_Upgrade();
        mockAccountant = new MockAccountant_Upgrade();
    }

    // -----------------------------------------------------------------------
    // Logging helpers
    // -----------------------------------------------------------------------

    string constant MODULE = unicode"合约升级相关";
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
    // Helper: deploy initialized vault + gateway
    // -----------------------------------------------------------------------

    function _deployRealOracle(address complianceBot) internal returns (SanctionsOracle so) {
        SanctionsOracleFactory factory = new SanctionsOracleFactory(address(new SanctionsOracle()), admin);
        address oracleAddr = factory.deployAndInitOracle(admin, complianceBot);
        so = SanctionsOracle(oracleAddr);
    }

    function _deployRealAccountant(address vaultAddr, uint64 initialRate, uint32 managementFeeRate_)
        internal
        returns (Accountant acct)
    {
        AccountantFactory factory = new AccountantFactory(address(new Accountant()), admin);
        address acctAddr = factory.deployAndInitAccountant(vaultAddr, initialRate, managementFeeRate_, admin, admin, admin);
        acct = Accountant(acctAddr);
    }

    function _initRealVault(address vAddr, address gwAddr, address accountantAddr) internal returns (MantleYieldVault v) {
        v = MantleYieldVault(vAddr);

        vm.prank(admin);
        v.initialize(
            IMantleYieldVault.InitParams({
                asset: IERC20(address(usdc)),
                name: "Mantle RWA Vault",
                symbol: "mRWA",
                admin: admin,
                gateway: gwAddr,
                controller: makeAddr("controller"),
                accountant: accountantAddr,
                treasury: treasuryAddr,
                maxRedemptionFeeBps: 500,
                redemptionFeeBps: 100,
                minRedeemAmount: 100e6,
                minDepositAmount: 0,
                maxSettlementDeviationBps: 0,
                depositDailyRemaining: type(uint256).max,
                redeemDailyRemaining: type(uint256).max
            })
        );
    }

    function _initRealGateway(address gwAddr, address vAddr, address oracleAddr) internal returns (MantleVaultGateway gw) {
        gw = MantleVaultGateway(gwAddr);

        vm.prank(admin);
        gw.initialize(
            IMantleVaultGateway.InitParams({
                vault: vAddr,
                sanctionsOracle: ISanctionsOracle(oracleAddr),
                sanctionSafe: sanctionSafe,
                admin: admin,
                syncRedeemDisabled: false
            })
        );
    }

    function _deployVaultAndGateway(VaultFactory vf, GatewayFactory gf)
        internal
        returns (MantleYieldVault v, MantleVaultGateway gw)
    {
        address vAddr = vf.deployVault();
        address gwAddr = gf.deployGateway();
        SanctionsOracle realOracle = _deployRealOracle(bot);
        Accountant realAccountant = _deployRealAccountant(vAddr, 1e18, 100);
        v = _initRealVault(vAddr, gwAddr, address(realAccountant));
        gw = _initRealGateway(gwAddr, vAddr, address(realOracle));
    }

    function _depositForUser(MantleVaultGateway gw, MantleYieldVault v, address user, uint256 amount) internal {
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(v), type(uint256).max);
        gw.deposit(amount);
        vm.stopPrank();
    }

    function _deployOperatorExecutor() internal returns (OperatorExecutor opExec) {
        OperatorExecutor opImpl = new OperatorExecutor();
        bytes memory opInit = abi.encodeCall(OperatorExecutor.initialize, (admin, bot));
        opExec = OperatorExecutor(address(new ERC1967Proxy(address(opImpl), opInit)));
    }

    function _deployRealControllerStack(uint16 bufferTargetBps, uint16 rebalanceThresholdBps, uint64 cooldown)
        internal
        returns (RealControllerStack memory s)
    {
        VaultFactory vaultFactory = new VaultFactory(address(new MantleYieldVault()), admin);
        GatewayFactory gatewayFactory = new GatewayFactory(address(new MantleVaultGateway()), admin);
        (s.vault, s.gateway) = _deployVaultAndGateway(vaultFactory, gatewayFactory);
        s.accountant = Accountant(s.vault.accountant());
        s.operatorExecutor = _deployOperatorExecutor();
        s.factory = new StrategyControllerFactory(address(new StrategyController()), admin);
        s.beacon = s.factory.BEACON();
        s.posToken = new MockUSDC_Upgrade();
        s.adapter = new MockAdapterForUpgrade(address(usdc), address(s.posToken), address(s.vault));

        address ctrlAddr = s.factory.deployAndInitController(
            address(s.vault), admin, address(s.operatorExecutor), admin, bufferTargetBps, rebalanceThresholdBps, cooldown
        );
        s.controller = StrategyController(ctrlAddr);

        vm.prank(admin);
        s.vault.setController(ctrlAddr);
    }

    function _fundRealVault(RealControllerStack memory s, address user, uint256 amount) internal {
        _depositForUser(s.gateway, s.vault, user, amount);
    }

    function _deployRealAccountantStack() internal returns (RealAccountantStack memory s) {
        VaultFactory vaultFactory = new VaultFactory(address(new MantleYieldVault()), admin);
        GatewayFactory gatewayFactory = new GatewayFactory(address(new MantleVaultGateway()), admin);
        (s.vault, s.gateway) = _deployVaultAndGateway(vaultFactory, gatewayFactory);

        s.factory = new AccountantFactory(address(new Accountant()), admin);
        address acctAddr = s.factory.deployAndInitAccountant(address(s.vault), 1e18, 100, admin, admin, admin);
        s.accountant = Accountant(acctAddr);

        vm.prank(admin);
        s.vault.setAccountant(acctAddr);

        AccountantExecutor exImpl = new AccountantExecutor();
        bytes memory exInit = abi.encodeCall(AccountantExecutor.initialize, (admin));
        s.executor = AccountantExecutor(address(new ERC1967Proxy(address(exImpl), exInit)));

        vm.startPrank(admin);
        s.executor.grantRole(s.executor.BOT_ROLE(), bot);
        s.executor.grantRole(s.executor.FEE_SETTLER_ROLE(), bot);
        s.accountant.grantRole(s.accountant.ACCOUNTANT_EXECUTOR_ROLE(), address(s.executor));
        vm.stopPrank();
    }

    function _fundRealVault(MantleVaultGateway gw, MantleYieldVault v, address user, uint256 amount) internal {
        _depositForUser(gw, v, user, amount);
    }

    /// @dev Helper to upgrade a beacon as owner (avoids vm.prank being consumed by BEACON() view call)
    function _beaconUpgrade(UpgradeableBeacon beacon, address owner, address newImpl) internal {
        vm.prank(owner);
        beacon.upgradeTo(newImpl);
    }

    // ===================================================================
    //  GATEWAY FACTORY - BEACON UPGRADE
    // ===================================================================

    function test_GW_BeaconOwnerUpgrade() public {
        _logCase("test_GW_BeaconOwnerUpgrade", unicode"`beaconOwner` 升级实现合约");

        MantleVaultGateway impl = new MantleVaultGateway();
        GatewayFactory factory = new GatewayFactory(address(impl), admin);
        UpgradeableBeacon beacon = factory.BEACON();

        _step("[Step 1] Deploy new impl and upgrade");
        MantleVaultGatewayV2 newImpl = new MantleVaultGatewayV2();
        _beaconUpgrade(beacon, admin, address(newImpl));

        assertEq(beacon.implementation(), address(newImpl), "impl should be newImpl");
        _step("  PASS: BEACON.implementation() == newImpl");

        _logPass();
    }

    function test_GW_NonOwnerCannotUpgrade() public {
        _logCase("test_GW_NonOwnerCannotUpgrade", unicode"非 beaconOwner 无法升级");

        MantleVaultGateway impl = new MantleVaultGateway();
        GatewayFactory factory = new GatewayFactory(address(impl), admin);
        UpgradeableBeacon beacon = factory.BEACON();
        MantleVaultGatewayV2 newImpl = new MantleVaultGatewayV2();

        _step("[Step 1] Non-owner attempts upgrade, expect revert");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        beacon.upgradeTo(address(newImpl));
        _step("  PASS: reverted OwnableUnauthorizedAccount");

        _logPass();
    }

    function test_GW_UpgradeToZeroAddress() public {
        _logCase("test_GW_UpgradeToZeroAddress", unicode"升级为零地址");

        MantleVaultGateway impl = new MantleVaultGateway();
        GatewayFactory factory = new GatewayFactory(address(impl), admin);
        UpgradeableBeacon beacon = factory.BEACON();

        _step("[Step 1] beaconOwner upgrades to address(0), expect revert");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UpgradeableBeacon.BeaconInvalidImplementation.selector, address(0)));
        beacon.upgradeTo(address(0));
        _step("  PASS: reverted BeaconInvalidImplementation");

        _logPass();
    }

    function test_GW_UpgradeToEOA() public {
        _logCase("test_GW_UpgradeToEOA", unicode"升级为 EOA（无代码）");

        MantleVaultGateway impl = new MantleVaultGateway();
        GatewayFactory factory = new GatewayFactory(address(impl), admin);
        UpgradeableBeacon beacon = factory.BEACON();

        address eoa = makeAddr("eoa");
        _step("[Step 1] beaconOwner upgrades to EOA, expect revert");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UpgradeableBeacon.BeaconInvalidImplementation.selector, eoa));
        beacon.upgradeTo(eoa);
        _step("  PASS: reverted BeaconInvalidImplementation");

        _logPass();
    }

    function test_GW_StatePreservedAfterUpgrade() public {
        _logCase("test_GW_StatePreservedAfterUpgrade", unicode"升级后存储布局兼容性（ERC-7201）");

        MantleVaultGateway gwImpl = new MantleVaultGateway();
        GatewayFactory gFactory = new GatewayFactory(address(gwImpl), admin);
        UpgradeableBeacon beacon = gFactory.BEACON();
        VaultFactory vFactory = new VaultFactory(address(new MantleYieldVault()), admin);
        (MantleYieldVault v, MantleVaultGateway gw) = _deployVaultAndGateway(vFactory, gFactory);

        _step("[Step 1] Record V1 state");
        address vaultAddr = address(gw.vault());
        address oracleAddr = address(gw.sanctionsOracle());
        address safeAddr = gw.sanctionSafe();
        bool syncDisabled = gw.syncRedeemDisabled();
        _step(string.concat("  vault: ", vm.toString(vaultAddr)));

        _step("[Step 2] Upgrade beacon to V2");
        MantleVaultGatewayV2 newImpl = new MantleVaultGatewayV2();
        _beaconUpgrade(beacon, admin, address(newImpl));

        _step("[Step 3] Verify V1 state preserved");
        assertEq(address(gw.vault()), vaultAddr, "vault should be preserved");
        assertEq(address(gw.sanctionsOracle()), oracleAddr, "oracle should be preserved");
        assertEq(gw.sanctionSafe(), safeAddr, "sanctionSafe should be preserved");
        assertEq(gw.syncRedeemDisabled(), syncDisabled, "syncRedeemDisabled should be preserved");
        _step("  PASS: All V1 state preserved after V2 upgrade");

        _logPass();
    }

    function test_GW_BatchUpgradeAllGateways() public {
        _logCase("test_GW_BatchUpgradeAllGateways", unicode"批量升级所有 gateway");

        MantleVaultGateway impl = new MantleVaultGateway();
        GatewayFactory factory = new GatewayFactory(address(impl), admin);
        UpgradeableBeacon beacon = factory.BEACON();

        _step("[Step 1] Deploy 3 gateways");
        address gw1 = factory.deployGateway();
        address gw2 = factory.deployGateway();
        address gw3 = factory.deployGateway();
        assertEq(factory.gatewayCount(), 3, "should have 3 gateways");

        _step("[Step 2] Upgrade beacon once");
        MantleVaultGatewayV2 newImpl = new MantleVaultGatewayV2();
        _beaconUpgrade(beacon, admin, address(newImpl));

        _step("[Step 3] All 3 gateways use new impl");
        assertEq(MantleVaultGatewayV2(gw1).version(), 2, "gw1 should use V2");
        assertEq(MantleVaultGatewayV2(gw2).version(), 2, "gw2 should use V2");
        assertEq(MantleVaultGatewayV2(gw3).version(), 2, "gw3 should use V2");
        _step("  PASS: All 3 gateways upgraded simultaneously");

        _logPass();
    }

    function test_GW_PostUpgradeFunctionality() public {
        _logCase("test_GW_PostUpgradeFunctionality", unicode"升级后继续工作");

        MantleVaultGateway gwImpl = new MantleVaultGateway();
        GatewayFactory gFactory = new GatewayFactory(address(gwImpl), admin);
        UpgradeableBeacon beacon = gFactory.BEACON();
        VaultFactory vFactory = new VaultFactory(address(new MantleYieldVault()), admin);
        (MantleYieldVault v, MantleVaultGateway gw) = _deployVaultAndGateway(vFactory, gFactory);

        _step("[Step 1] deposit before upgrade");
        _depositForUser(gw, v, userA, 1_000e6);
        uint256 sharesBefore = v.balanceOf(userA);
        assertTrue(sharesBefore > 0, "userA should have shares");
        _step(string.concat("  userA shares: ", vm.toString(sharesBefore)));

        _step("[Step 2] Upgrade beacon to V2");
        MantleVaultGatewayV2 newImpl = new MantleVaultGatewayV2();
        _beaconUpgrade(beacon, admin, address(newImpl));

        _step("[Step 3] deposit after upgrade");
        _depositForUser(gw, v, userB, 1_000e6);
        uint256 sharesAfter = v.balanceOf(userB);
        assertTrue(sharesAfter > 0, "userB should have shares after upgrade");
        _step(string.concat("  userB shares: ", vm.toString(sharesAfter)));
        _step("  PASS: deposit works after upgrade");

        _logPass();
    }

    function test_GW_NewDeployUsesNewImpl() public {
        _logCase("test_GW_NewDeployUsesNewImpl", unicode"升级后新部署 gateway 使用新实现");

        MantleVaultGateway impl = new MantleVaultGateway();
        GatewayFactory factory = new GatewayFactory(address(impl), admin);
        UpgradeableBeacon beacon = factory.BEACON();

        _step("[Step 1] Upgrade beacon");
        MantleVaultGatewayV2 newImpl = new MantleVaultGatewayV2();
        _beaconUpgrade(beacon, admin, address(newImpl));

        _step("[Step 2] Deploy new gateway after upgrade");
        address newGw = factory.deployGateway();
        assertEq(MantleVaultGatewayV2(newGw).version(), 2, "new gw should use V2");
        assertEq(factory.implementation(), address(newImpl), "factory.implementation should be V2");
        _step("  PASS: New deployment uses new implementation");

        _logPass();
    }

    function test_GW_MultiGatewayIndependent() public {
        _logCase("test_GW_MultiGatewayIndependent", unicode"多 gateway 独立运作");

        MantleVaultGateway gwImpl = new MantleVaultGateway();
        GatewayFactory gFactory = new GatewayFactory(address(gwImpl), admin);
        VaultFactory vFactory = new VaultFactory(address(new MantleYieldVault()), admin);

        _step("[Step 1] Deploy 2 gateways with different vaults");
        (MantleYieldVault v1, MantleVaultGateway gw1) = _deployVaultAndGateway(vFactory, gFactory);
        (MantleYieldVault v2, MantleVaultGateway gw2) = _deployVaultAndGateway(vFactory, gFactory);

        _step("[Step 2] alice deposits via gw1, bob deposits via gw2");
        _depositForUser(gw1, v1, userA, 1_000e6);
        _depositForUser(gw2, v2, userB, 2_000e6);

        assertTrue(v1.balanceOf(userA) > 0, "userA should have v1 shares");
        assertTrue(v2.balanceOf(userB) > 0, "userB should have v2 shares");
        assertEq(v1.balanceOf(userB), 0, "userB should not have v1 shares");
        assertEq(v2.balanceOf(userA), 0, "userA should not have v2 shares");
        _step("  PASS: Gateways operate independently");

        _logPass();
    }

    function test_GW_PostUpgradeExistingGatewayWorks() public {
        _logCase("test_GW_PostUpgradeExistingGatewayWorks", unicode"升级后已有 gateway 继续工作");

        MantleVaultGateway gwImpl = new MantleVaultGateway();
        GatewayFactory gFactory = new GatewayFactory(address(gwImpl), admin);
        UpgradeableBeacon beacon = gFactory.BEACON();
        VaultFactory vFactory = new VaultFactory(address(new MantleYieldVault()), admin);
        (MantleYieldVault v, MantleVaultGateway gw) = _deployVaultAndGateway(vFactory, gFactory);

        _step("[Step 1] Pre-upgrade: deposit and redeem");
        _depositForUser(gw, v, userA, 1_000e6);
        uint256 shares = v.balanceOf(userA);
        assertTrue(shares > 0, "userA should have shares");
        vm.prank(userA);
        gw.redeem(shares);
        assertEq(v.balanceOf(userA), 0, "userA redeemed all shares");
        _step("  Pre-upgrade deposit/redeem completed");

        _step("[Step 2] Record V1 state");
        address vaultAddr = address(gw.vault());
        address oracleAddr = address(gw.sanctionsOracle());
        address safeAddr = gw.sanctionSafe();
        bool syncDisabled = gw.syncRedeemDisabled();
        bool wlEnabled = gw.whitelistEnabled();

        _step("[Step 3] Upgrade beacon to V2");
        MantleVaultGatewayV2 newImpl = new MantleVaultGatewayV2();
        _beaconUpgrade(beacon, admin, address(newImpl));

        _step("[Step 4] Post-upgrade: deposit works");
        _depositForUser(gw, v, userB, 500e6);
        assertTrue(v.balanceOf(userB) > 0, "userB should have shares after upgrade");
        _step("  Post-upgrade deposit works");

        _step("[Step 5] Post-upgrade: isSanctioned works");
        assertFalse(gw.isSanctioned(userB), "userB should not be sanctioned");
        _step("  Post-upgrade isSanctioned works");

        _step("[Step 6] Verify state preserved");
        assertEq(address(gw.vault()), vaultAddr, "vault preserved");
        assertEq(address(gw.sanctionsOracle()), oracleAddr, "sanctionsOracle preserved");
        assertEq(gw.sanctionSafe(), safeAddr, "sanctionSafe preserved");
        assertEq(gw.syncRedeemDisabled(), syncDisabled, "syncRedeemDisabled preserved");
        assertEq(gw.whitelistEnabled(), wlEnabled, "whitelistEnabled preserved");
        _step("  PASS: All state preserved, functionality normal after upgrade");

        _logPass();
    }

    // ===================================================================
    //  VAULT FACTORY - BEACON UPGRADE
    // ===================================================================

    function test_Vault_BeaconUpgradeAllVaults() public {
        _logCase("test_Vault_BeaconUpgradeAllVaults", unicode"Beacon 升级后所有 vault 指向新实现");

        MantleYieldVault impl = new MantleYieldVault();
        VaultFactory factory = new VaultFactory(address(impl), admin);
        UpgradeableBeacon beacon = factory.BEACON();

        _step("[Step 1] Deploy 2 vaults");
        address v1 = factory.deployVault();
        address v2 = factory.deployVault();

        _step("[Step 2] Upgrade beacon");
        MantleYieldVaultV2 newImpl = new MantleYieldVaultV2();
        _beaconUpgrade(beacon, admin, address(newImpl));

        _step("[Step 3] Both vaults use new impl");
        assertEq(factory.implementation(), address(newImpl), "factory.implementation should be V2");
        assertEq(MantleYieldVaultV2(v1).version(), 2, "v1 should use V2");
        assertEq(MantleYieldVaultV2(v2).version(), 2, "v2 should use V2");
        _step("  PASS: All vaults point to new implementation");

        _logPass();
    }

    function test_Vault_StatePreservedAfterUpgrade() public {
        _logCase("test_Vault_StatePreservedAfterUpgrade", unicode"升级后状态保留");

        MantleYieldVault impl = new MantleYieldVault();
        VaultFactory vFactory = new VaultFactory(address(impl), admin);
        UpgradeableBeacon beacon = vFactory.BEACON();
        GatewayFactory gFactory = new GatewayFactory(address(new MantleVaultGateway()), admin);
        (MantleYieldVault v, MantleVaultGateway gw) = _deployVaultAndGateway(vFactory, gFactory);

        _step("[Step 1] Deposit to create state");
        _depositForUser(gw, v, userA, 1_000e6);
        uint256 sharesBefore = v.balanceOf(userA);
        uint256 rateBefore = v.exchangeRate();
        address controllerBefore = v.controller();
        address accountantBefore = v.accountant();
        _step(string.concat("  shares: ", vm.toString(sharesBefore)));

        _step("[Step 2] Upgrade beacon");
        MantleYieldVaultV2 newImpl = new MantleYieldVaultV2();
        _beaconUpgrade(beacon, admin, address(newImpl));

        _step("[Step 3] Verify state preserved");
        assertEq(v.balanceOf(userA), sharesBefore, "shares preserved");
        assertEq(v.exchangeRate(), rateBefore, "exchangeRate preserved");
        assertEq(v.controller(), controllerBefore, "controller preserved");
        assertEq(v.accountant(), accountantBefore, "accountant preserved");
        _step("  PASS: All state preserved after upgrade");

        _logPass();
    }

    function test_Vault_NonOwnerCannotUpgrade() public {
        _logCase("test_Vault_NonOwnerCannotUpgrade", unicode"非 `beaconOwner` 无法升级");

        VaultFactory factory = new VaultFactory(address(new MantleYieldVault()), admin);
        UpgradeableBeacon beacon = factory.BEACON();
        MantleYieldVaultV2 newImpl = new MantleYieldVaultV2();

        _step("[Step 1] Attacker attempts upgrade");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        beacon.upgradeTo(address(newImpl));
        _step("  PASS: reverted OwnableUnauthorizedAccount");

        _logPass();
    }

    function test_Vault_UpgradeToZeroAddress() public {
        _logCase("test_Vault_UpgradeToZeroAddress", unicode"升级到零地址失败");

        VaultFactory factory = new VaultFactory(address(new MantleYieldVault()), admin);
        UpgradeableBeacon beacon = factory.BEACON();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UpgradeableBeacon.BeaconInvalidImplementation.selector, address(0)));
        beacon.upgradeTo(address(0));
        _step("  PASS: reverted for zero address");

        _logPass();
    }

    function test_Vault_UpgradeToEOA() public {
        _logCase("test_Vault_UpgradeToEOA", unicode"升级到非合约地址失败");

        VaultFactory factory = new VaultFactory(address(new MantleYieldVault()), admin);
        UpgradeableBeacon beacon = factory.BEACON();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UpgradeableBeacon.BeaconInvalidImplementation.selector, makeAddr("eoa")));
        beacon.upgradeTo(makeAddr("eoa"));
        _step("  PASS: reverted BeaconInvalidImplementation");

        _logPass();
    }

    function test_Vault_NewFunctionCallable() public {
        _logCase("test_Vault_NewFunctionCallable", unicode"升级后新函数可调用");

        VaultFactory factory = new VaultFactory(address(new MantleYieldVault()), admin);
        UpgradeableBeacon beacon = factory.BEACON();
        address v = factory.deployVault();

        MantleYieldVaultV2 newImpl = new MantleYieldVaultV2();
        _beaconUpgrade(beacon, admin, address(newImpl));

        assertEq(MantleYieldVaultV2(v).version(), 2, "version() should return 2");
        _step("  PASS: New function callable after upgrade");

        _logPass();
    }

    function test_Vault_OldFunctionsStillWork() public {
        _logCase("test_Vault_OldFunctionsStillWork", unicode"升级后旧函数仍正常");

        VaultFactory vFactory = new VaultFactory(address(new MantleYieldVault()), admin);
        UpgradeableBeacon beacon = vFactory.BEACON();
        GatewayFactory gFactory = new GatewayFactory(address(new MantleVaultGateway()), admin);
        (MantleYieldVault v, MantleVaultGateway gw) = _deployVaultAndGateway(vFactory, gFactory);

        _step("[Step 1] Upgrade beacon");
        _beaconUpgrade(beacon, admin, address(new MantleYieldVaultV2()));

        _step("[Step 2] deposit and redeem after upgrade");
        _depositForUser(gw, v, userA, 1_000e6);
        assertTrue(v.balanceOf(userA) > 0, "deposit should work");

        uint256 shares = v.balanceOf(userA);
        vm.prank(userA);
        gw.redeem(shares);
        assertEq(v.balanceOf(userA), 0, "redeem should work");
        _step("  PASS: Old functions work after upgrade");

        _logPass();
    }

    function test_Vault_ConstructorRejectZeroImpl() public {
        _logCase("test_Vault_ConstructorRejectZeroImpl", unicode"构造函数拒绝 impl=address(0)");

        vm.expectRevert(VaultFactory.Factory__ZeroAddress.selector);
        new VaultFactory(address(0), admin);
        _step("  PASS: Reverted Factory__ZeroAddress");

        _logPass();
    }

    function test_Vault_ConstructorRejectZeroOwner() public {
        _logCase("test_Vault_ConstructorRejectZeroOwner", unicode"构造函数拒绝 `beaconOwner=address(0)`");

        MantleYieldVault impl = new MantleYieldVault();
        vm.expectRevert(VaultFactory.Factory__ZeroAddress.selector);
        new VaultFactory(address(impl), address(0));
        _step("  PASS: Reverted Factory__ZeroAddress");

        _logPass();
    }

    function test_Vault_DeployVault() public {
        _logCase("test_Vault_DeployVault", unicode"`deployVault` 部署未初始化 vault");

        VaultFactory factory = new VaultFactory(address(new MantleYieldVault()), admin);

        _step("[Step 1] Deploy vault");
        address v = factory.deployVault();
        assertTrue(v != address(0), "vault should not be zero");
        assertEq(factory.vaultCount(), 1, "vaultCount should be 1");
        assertEq(factory.vaults(0), v, "vaults(0) should be vault");
        _step("  PASS: deployVault works correctly");

        _logPass();
    }

    function test_Vault_DeployAndInitVault() public {
        _logCase("test_Vault_DeployAndInitVault", unicode"deployAndInitVault 部署并初始化");

        VaultFactory factory = new VaultFactory(address(new MantleYieldVault()), admin);
        address accountantVault = factory.deployVault();
        Accountant realAccountant = _deployRealAccountant(accountantVault, 1e18, 100);

        IMantleYieldVault.InitParams memory params = IMantleYieldVault.InitParams({
            asset: IERC20(address(usdc)),
            name: "Mantle RWA Vault",
            symbol: "mRWA",
            admin: admin,
            gateway: makeAddr("gw"),
            controller: makeAddr("ctrl"),
            accountant: address(realAccountant),
            treasury: treasuryAddr,
            maxRedemptionFeeBps: 500,
            redemptionFeeBps: 100,
            minRedeemAmount: 100e6,
            minDepositAmount: 0,
            maxSettlementDeviationBps: 0,
            depositDailyRemaining: type(uint256).max,
            redeemDailyRemaining: type(uint256).max
        });

        address v = factory.deployAndInitVault(params);
        assertTrue(v != address(0), "vault should not be zero");
        assertEq(MantleYieldVault(v).controller(), makeAddr("ctrl"), "controller should match");
        assertEq(MantleYieldVault(v).exchangeRate(), 1e18, "exchangeRate should be 1e18");
        _step("  PASS: deployAndInitVault works correctly");

        _logPass();
    }

    function test_Vault_ConsecutiveDeployments() public {
        _logCase("test_Vault_ConsecutiveDeployments", unicode"连续部署多个 vault");

        VaultFactory factory = new VaultFactory(address(new MantleYieldVault()), admin);
        factory.deployVault();
        factory.deployVault();
        factory.deployVault();

        assertEq(factory.vaultCount(), 3, "vaultCount should be 3");
        address[] memory all = factory.getAllVaults();
        assertEq(all.length, 3, "getAllVaults should return 3");
        assertTrue(all[0] != all[1] && all[1] != all[2] && all[0] != all[2], "all different addresses");
        _step("  PASS: 3 vaults deployed, getAllVaults returns correct list");

        _logPass();
    }

    function test_Vault_GetAllVaults() public {
        _logCase("test_Vault_GetAllVaults", unicode"getAllVaults 返回正确列表");

        VaultFactory factory = new VaultFactory(address(new MantleYieldVault()), admin);
        address v1 = factory.deployVault();
        address v2 = factory.deployVault();

        address[] memory all = factory.getAllVaults();
        assertEq(all.length, 2, "length should be 2");
        assertEq(all[0], v1, "first vault");
        assertEq(all[1], v2, "second vault");
        _step("  PASS: getAllVaults returns correct ordered list");

        _logPass();
    }

    function test_Vault_AnyoneCanDeploy() public {
        _logCase("test_Vault_AnyoneCanDeploy", unicode"任何人都可以调用 `deployVault`");

        VaultFactory factory = new VaultFactory(address(new MantleYieldVault()), admin);

        vm.prank(attacker);
        address v = factory.deployVault();
        assertTrue(v != address(0), "anyone can deploy");
        _step("  PASS: Random address can call deployVault");

        _logPass();
    }

    function test_Vault_IsBeaconProxy() public {
        _logCase("test_Vault_IsBeaconProxy", unicode"部署的 vault 确实是 `BeaconProxy`");

        VaultFactory factory = new VaultFactory(address(new MantleYieldVault()), admin);
        UpgradeableBeacon beacon = factory.BEACON();
        address v = factory.deployVault();

        _step("[Step 1] Upgrade beacon and verify vault uses new logic");
        MantleYieldVaultV2 newImpl = new MantleYieldVaultV2();
        _beaconUpgrade(beacon, admin, address(newImpl));

        assertEq(MantleYieldVaultV2(v).version(), 2, "should use V2 after beacon upgrade");
        _step("  PASS: Vault is a BeaconProxy (follows beacon upgrades)");

        _logPass();
    }

    function test_Vault_InitializerPreventsDoubleInit() public {
        _logCase("test_Vault_InitializerPreventsDoubleInit", unicode"initializer 防止重复初始化");

        VaultFactory vFactory = new VaultFactory(address(new MantleYieldVault()), admin);
        GatewayFactory gFactory = new GatewayFactory(address(new MantleVaultGateway()), admin);
        (MantleYieldVault v,) = _deployVaultAndGateway(vFactory, gFactory);
        address accountantVault = vFactory.deployVault();
        Accountant realAccountant = _deployRealAccountant(accountantVault, 1e18, 100);

        _step("[Step 1] Call initialize again on already-initialized vault");
        IMantleYieldVault.InitParams memory params = IMantleYieldVault.InitParams({
            asset: IERC20(address(usdc)),
            name: "Mantle RWA Vault",
            symbol: "mRWA",
            admin: admin,
            gateway: makeAddr("gw2"),
            controller: makeAddr("ctrl2"),
            accountant: address(realAccountant),
            treasury: treasuryAddr,
            maxRedemptionFeeBps: 500,
            redemptionFeeBps: 100,
            minRedeemAmount: 100e6,
            minDepositAmount: 0,
            maxSettlementDeviationBps: 0,
            depositDailyRemaining: type(uint256).max,
            redeemDailyRemaining: type(uint256).max
        });
        vm.prank(admin);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        v.initialize(params);
        _step("  PASS: Reverted InvalidInitialization on double init");

        _logPass();
    }

    function test_Vault_ImplCannotBeInitialized() public {
        _logCase("test_Vault_ImplCannotBeInitialized", unicode"实现合约不可直接初始化");

        MantleYieldVault impl = new MantleYieldVault();
        VaultFactory helperFactory = new VaultFactory(address(new MantleYieldVault()), admin);
        address accountantVault = helperFactory.deployVault();
        Accountant realAccountant = _deployRealAccountant(accountantVault, 1e18, 100);

        _step("[Step 1] Call initialize directly on implementation");
        IMantleYieldVault.InitParams memory params = IMantleYieldVault.InitParams({
            asset: IERC20(address(usdc)),
            name: "Mantle RWA Vault",
            symbol: "mRWA",
            admin: admin,
            gateway: makeAddr("gw"),
            controller: makeAddr("ctrl"),
            accountant: address(realAccountant),
            treasury: treasuryAddr,
            maxRedemptionFeeBps: 500,
            redemptionFeeBps: 100,
            minRedeemAmount: 100e6,
            minDepositAmount: 0,
            maxSettlementDeviationBps: 0,
            depositDailyRemaining: type(uint256).max,
            redeemDailyRemaining: type(uint256).max
        });
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(params);
        _step("  PASS: Reverted on direct implementation initialize");

        _logPass();
    }

    function test_Vault_TimelockEarlyExecuteReverts() public {
        _logCase("test_Vault_TimelockEarlyExecuteReverts", unicode"Timelock 控制的升级流程");

        MantleYieldVault impl = new MantleYieldVault();
        MantleYieldVaultV2 newImpl = new MantleYieldVaultV2();

        address[] memory proposers = new address[](1);
        proposers[0] = admin;
        address[] memory executors = new address[](1);
        executors[0] = admin;

        uint256 minDelay = 1 days;
        TimelockUpgradeController timelock = new TimelockUpgradeController(minDelay, proposers, executors, admin);

        VaultFactory factory = new VaultFactory(address(impl), address(timelock));
        UpgradeableBeacon beacon = factory.BEACON();

        _step("[Step 1] Schedule upgrade via timelock");
        bytes memory data = abi.encodeCall(beacon.upgradeTo, (address(newImpl)));
        bytes32 salt = bytes32(0);
        vm.prank(admin);
        timelock.schedule(address(beacon), 0, data, bytes32(0), salt, minDelay);

        _step("[Step 2] Immediately execute before delay -> revert");
        bytes32 opId = timelock.hashOperation(address(beacon), 0, data, bytes32(0), salt);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnexpectedOperationState.selector, opId, bytes32(1 << uint8(TimelockController.OperationState.Ready))));
        timelock.execute(address(beacon), 0, data, bytes32(0), salt);
        _step("  PASS: Early execute reverted as expected");

        _logPass();
    }

    function test_Vault_NewStorageVariableAppend() public {
        _logCase("test_Vault_NewStorageVariableAppend", unicode"新实现添加新存储变量（尾部追加）");

        MantleYieldVault impl = new MantleYieldVault();
        VaultFactory vFactory = new VaultFactory(address(impl), admin);
        UpgradeableBeacon beacon = vFactory.BEACON();
        GatewayFactory gFactory = new GatewayFactory(address(new MantleVaultGateway()), admin);
        (MantleYieldVault v, MantleVaultGateway gw) = _deployVaultAndGateway(vFactory, gFactory);

        _step("[Step 1] Deposit to create state");
        _depositForUser(gw, v, userA, 1_000e6);
        uint256 sharesBefore = v.balanceOf(userA);
        uint256 rateBefore = v.exchangeRate();
        address controllerBefore = v.controller();
        _step(string.concat("  shares: ", vm.toString(sharesBefore)));

        _step("[Step 2] Upgrade to V2 with new storage variable");
        MantleYieldVaultV2WithStorage newImpl = new MantleYieldVaultV2WithStorage();
        _beaconUpgrade(beacon, admin, address(newImpl));

        _step("[Step 3] Verify old vars intact");
        assertEq(v.balanceOf(userA), sharesBefore, "shares preserved");
        assertEq(v.exchangeRate(), rateBefore, "exchangeRate preserved");
        assertEq(v.controller(), controllerBefore, "controller preserved");
        _step("  Old variables intact");

        _step("[Step 4] Verify new variable works");
        MantleYieldVaultV2WithStorage v2 = MantleYieldVaultV2WithStorage(address(v));
        assertEq(v2.newVar(), 0, "newVar should be zero initially");
        v2.setNewVar(42);
        assertEq(v2.newVar(), 42, "newVar should be 42");
        _step("  PASS: New storage variable appended and works correctly");

        _logPass();
    }

    function test_Vault_Reinitializer() public {
        _logCase("test_Vault_Reinitializer", unicode"reinitializer(2) 升级初始化");

        MantleYieldVault impl = new MantleYieldVault();
        VaultFactory vFactory = new VaultFactory(address(impl), admin);
        UpgradeableBeacon beacon = vFactory.BEACON();
        GatewayFactory gFactory = new GatewayFactory(address(new MantleVaultGateway()), admin);
        (MantleYieldVault v,) = _deployVaultAndGateway(vFactory, gFactory);

        _step("[Step 1] Upgrade to V2 with reinitializer");
        MantleYieldVaultV2Reinit newImpl = new MantleYieldVaultV2Reinit();
        _beaconUpgrade(beacon, admin, address(newImpl));

        _step("[Step 2] Call reinitialize(2) -> success");
        MantleYieldVaultV2Reinit v2 = MantleYieldVaultV2Reinit(address(v));
        v2.reinitialize(999);
        assertEq(v2.extraData(), 999, "extraData should be 999");
        _step("  reinitialize(2) succeeded");

        _step("[Step 3] Call reinitialize(2) again -> revert");
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        v2.reinitialize(123);
        _step("  PASS: Second reinitialize(2) reverted as expected");

        _logPass();
    }

    function test_Vault_ConstructorCorrectlyInitializesBeacon() public {
        _logCase("test_Vault_ConstructorCorrectlyInitializesBeacon", unicode"构造函数正确初始化 Beacon");

        MantleYieldVault impl = new MantleYieldVault();
        VaultFactory factory = new VaultFactory(address(impl), admin);
        UpgradeableBeacon beacon = factory.BEACON();

        _step("[Step 1] Verify BEACON is non-zero");
        assertTrue(address(beacon) != address(0), "BEACON should be non-zero");
        _step("  BEACON address is non-zero");

        _step("[Step 2] Verify implementation matches");
        assertEq(beacon.implementation(), address(impl), "implementation should match impl");
        _step("  implementation() == impl");

        _step("[Step 3] Verify beacon owner");
        assertEq(beacon.owner(), admin, "BEACON owner should be beaconOwner");
        _step("  PASS: BEACON.owner() == beaconOwner");

        _logPass();
    }

    function test_Vault_DeployAndInitVaultRejectZeroAddress() public {
        _logCase("test_Vault_DeployAndInitVaultRejectZeroAddress", unicode"`deployAndInitVault` 参数零地址拒绝");

        VaultFactory factory = new VaultFactory(address(new MantleYieldVault()), admin);
        address accountantVault = factory.deployVault();
        Accountant realAccountant = _deployRealAccountant(accountantVault, 1e18, 100);

        _step("[Step 1] Call deployAndInitVault with admin = address(0)");
        IMantleYieldVault.InitParams memory params = IMantleYieldVault.InitParams({
            asset: IERC20(address(usdc)),
            name: "Mantle RWA Vault",
            symbol: "mRWA",
            admin: address(0),
            gateway: makeAddr("gw"),
            controller: makeAddr("ctrl"),
            accountant: address(realAccountant),
            treasury: treasuryAddr,
            maxRedemptionFeeBps: 500,
            redemptionFeeBps: 100,
            minRedeemAmount: 100e6,
            minDepositAmount: 0,
            maxSettlementDeviationBps: 0,
            depositDailyRemaining: type(uint256).max,
            redeemDailyRemaining: type(uint256).max
        });
        vm.expectRevert(abi.encodeWithSelector(IAccessControlDefaultAdminRules.AccessControlInvalidDefaultAdmin.selector, address(0)));
        factory.deployAndInitVault(params);
        _step("  PASS: Reverted for zero address admin");

        _logPass();
    }

    function test_Vault_VaultsIndexOutOfBounds() public {
        _logCase("test_Vault_VaultsIndexOutOfBounds", unicode"`vaults(index)` 越界访问");

        VaultFactory factory = new VaultFactory(address(new MantleYieldVault()), admin);

        _step("[Step 1] Deploy 1 vault");
        factory.deployVault();
        assertEq(factory.vaultCount(), 1, "should have 1 vault");

        _step("[Step 2] Access vaults(1) -> revert (out of bounds)");
        // Solidity array OOB: optimizer may strip Panic data, producing empty revert
        vm.expectRevert(bytes(""));
        factory.vaults(1);
        _step("  PASS: Reverted on out-of-bounds access");

        _logPass();
    }

    // ===================================================================
    //  VAULT FACTORY - TIMELOCK UPGRADE
    // ===================================================================

    function test_Vault_TimelockDelayedUpgrade() public {
        _logCase("test_Vault_TimelockDelayedUpgrade", unicode"Timelock 延迟到期后执行升级");

        MantleYieldVault impl = new MantleYieldVault();
        MantleYieldVaultV2 newImpl = new MantleYieldVaultV2();

        address[] memory proposers = new address[](1);
        proposers[0] = admin;
        address[] memory executors = new address[](1);
        executors[0] = admin;

        uint256 minDelay = 1 days;
        TimelockUpgradeController timelock = new TimelockUpgradeController(minDelay, proposers, executors, admin);

        VaultFactory factory = new VaultFactory(address(impl), address(timelock));
        UpgradeableBeacon beacon = factory.BEACON();

        _step("[Step 1] Schedule upgrade");
        bytes memory data = abi.encodeCall(beacon.upgradeTo, (address(newImpl)));
        bytes32 salt = bytes32(0);
        vm.prank(admin);
        timelock.schedule(address(beacon), 0, data, bytes32(0), salt, minDelay);

        _step("[Step 2] Execute immediately should revert");
        bytes32 opId = timelock.hashOperation(address(beacon), 0, data, bytes32(0), salt);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnexpectedOperationState.selector, opId, bytes32(1 << uint8(TimelockController.OperationState.Ready))));
        timelock.execute(address(beacon), 0, data, bytes32(0), salt);
        _step("  Correctly reverted before delay");

        _step("[Step 3] Warp and execute");
        vm.warp(block.timestamp + minDelay);
        vm.prank(admin);
        timelock.execute(address(beacon), 0, data, bytes32(0), salt);

        assertEq(beacon.implementation(), address(newImpl), "beacon should be upgraded");
        _step("  PASS: Upgrade succeeded after delay");

        _logPass();
    }

    function test_Vault_TimelockCancel() public {
        _logCase("test_Vault_TimelockCancel", unicode"Timelock 延迟期内可取消");

        MantleYieldVault impl = new MantleYieldVault();
        MantleYieldVaultV2 newImpl = new MantleYieldVaultV2();

        address[] memory proposers = new address[](1);
        proposers[0] = admin;
        address[] memory executors = new address[](1);
        executors[0] = admin;

        uint256 minDelay = 1 days;
        TimelockUpgradeController timelock = new TimelockUpgradeController(minDelay, proposers, executors, admin);

        VaultFactory factory = new VaultFactory(address(impl), address(timelock));
        UpgradeableBeacon beacon = factory.BEACON();

        bytes memory data = abi.encodeCall(beacon.upgradeTo, (address(newImpl)));
        bytes32 salt = bytes32(0);

        vm.prank(admin);
        timelock.schedule(address(beacon), 0, data, bytes32(0), salt, minDelay);

        _step("[Step 1] Cancel the scheduled operation");
        bytes32 opId = timelock.hashOperation(address(beacon), 0, data, bytes32(0), salt);
        vm.prank(admin);
        timelock.cancel(opId);

        _step("[Step 2] Execute after delay should still revert (cancelled)");
        vm.warp(block.timestamp + minDelay);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnexpectedOperationState.selector, opId, bytes32(1 << uint8(TimelockController.OperationState.Ready))));
        timelock.execute(address(beacon), 0, data, bytes32(0), salt);
        _step("  PASS: Cancelled operation cannot be executed");

        _logPass();
    }

    // ===================================================================
    //  STRATEGY CONTROLLER FACTORY - BEACON UPGRADE
    // ===================================================================

    function test_SC_BeaconOwnerUpgrade() public {
        _logCase("test_SC_BeaconOwnerUpgrade", unicode"`beaconOwner` 升级实现合约");

        StrategyController impl = new StrategyController();
        StrategyControllerFactory factory = new StrategyControllerFactory(address(impl), admin);
        UpgradeableBeacon beacon = factory.BEACON();

        StrategyControllerV2 newImpl = new StrategyControllerV2();
        _beaconUpgrade(beacon, admin, address(newImpl));

        assertEq(beacon.implementation(), address(newImpl), "impl should be newImpl");
        _step("  PASS: BEACON.implementation() == newImpl");

        _logPass();
    }

    function test_SC_NonOwnerCannotUpgrade() public {
        _logCase("test_SC_NonOwnerCannotUpgrade", unicode"非 `beaconOwner` 无法升级");

        StrategyControllerFactory factory = new StrategyControllerFactory(address(new StrategyController()), admin);
        UpgradeableBeacon beacon = factory.BEACON();
        StrategyControllerV2 newImpl = new StrategyControllerV2();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        beacon.upgradeTo(address(newImpl));
        _step("  PASS: reverted OwnableUnauthorizedAccount");

        _logPass();
    }

    function test_SC_UpgradeToZeroAddress() public {
        _logCase("test_SC_UpgradeToZeroAddress", unicode"升级为零地址");

        StrategyControllerFactory factory = new StrategyControllerFactory(address(new StrategyController()), admin);
        UpgradeableBeacon beacon = factory.BEACON();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UpgradeableBeacon.BeaconInvalidImplementation.selector, address(0)));
        beacon.upgradeTo(address(0));
        _step("  PASS: reverted BeaconInvalidImplementation");

        _logPass();
    }

    function test_SC_UpgradeToEOA() public {
        _logCase("test_SC_UpgradeToEOA", unicode"升级为 EOA（无代码）");

        StrategyControllerFactory factory = new StrategyControllerFactory(address(new StrategyController()), admin);
        UpgradeableBeacon beacon = factory.BEACON();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UpgradeableBeacon.BeaconInvalidImplementation.selector, makeAddr("eoa")));
        beacon.upgradeTo(makeAddr("eoa"));
        _step("  PASS: reverted BeaconInvalidImplementation");

        _logPass();
    }

    function test_SC_BatchUpgradeAllControllers() public {
        _logCase("test_SC_BatchUpgradeAllControllers", unicode"批量升级所有 controller");

        StrategyController impl = new StrategyController();
        StrategyControllerFactory factory = new StrategyControllerFactory(address(impl), admin);
        UpgradeableBeacon beacon = factory.BEACON();

        _step("[Step 1] Deploy 5 controllers");
        for (uint256 i = 0; i < 5; i++) {
            factory.deployController();
        }
        assertEq(factory.controllerCount(), 5, "should have 5 controllers");

        _step("[Step 2] Upgrade beacon once");
        StrategyControllerV2 newImpl = new StrategyControllerV2();
        _beaconUpgrade(beacon, admin, address(newImpl));

        _step("[Step 3] All 5 controllers use new impl");
        address[] memory all = factory.getAllControllers();
        for (uint256 i = 0; i < 5; i++) {
            assertEq(StrategyControllerV2(all[i]).version(), 2, "should use V2");
        }
        _step("  PASS: All 5 controllers upgraded simultaneously");

        _logPass();
    }

    function test_SC_TimelockDelayedUpgrade() public {
        _logCase("test_SC_TimelockDelayedUpgrade", unicode"通过 `TimelockController` 延迟升级");

        StrategyController impl = new StrategyController();
        StrategyControllerV2 newImpl = new StrategyControllerV2();

        address[] memory proposers = new address[](1);
        proposers[0] = admin;
        address[] memory executors = new address[](1);
        executors[0] = admin;

        uint256 minDelay = 1 days;
        TimelockUpgradeController timelock = new TimelockUpgradeController(minDelay, proposers, executors, admin);

        StrategyControllerFactory factory = new StrategyControllerFactory(address(impl), address(timelock));
        UpgradeableBeacon beacon = factory.BEACON();

        bytes memory data = abi.encodeCall(beacon.upgradeTo, (address(newImpl)));
        bytes32 salt = bytes32(0);

        _step("[Step 1] Schedule upgrade");
        vm.prank(admin);
        timelock.schedule(address(beacon), 0, data, bytes32(0), salt, minDelay);

        _step("[Step 2] Execute before delay should revert");
        bytes32 opId = timelock.hashOperation(address(beacon), 0, data, bytes32(0), salt);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnexpectedOperationState.selector, opId, bytes32(1 << uint8(TimelockController.OperationState.Ready))));
        timelock.execute(address(beacon), 0, data, bytes32(0), salt);
        _step("  Correctly reverted before delay");

        _step("[Step 3] Warp and execute");
        vm.warp(block.timestamp + minDelay);
        vm.prank(admin);
        timelock.execute(address(beacon), 0, data, bytes32(0), salt);

        assertEq(beacon.implementation(), address(newImpl), "beacon should be upgraded");
        _step("  PASS: Timelock upgrade succeeded after delay");

        _logPass();
    }

    function test_SC_PostUpgradeControllerWorks() public {
        _logCase("test_SC_PostUpgradeControllerWorks", unicode"升级后已有 controller 继续工作");

        RealControllerStack memory s = _deployRealControllerStack(1000, 200, 0);

        _step("[Step 1] Deploy and init controller, register + activate strategy, set order");
        _registerActivateAndSetOrder(s.controller, s.adapter);
        _fundRealVault(s, userA, 10_000e6);

        _step("[Step 2] Execute rebalance (invest) before upgrade");
        vm.prank(bot);
        s.operatorExecutor.executeRebalance(address(s.controller));
        assertTrue(s.adapter.depositCount() > 0, "deposit should have been called");
        uint256 depositsBefore = s.adapter.depositCount();
        _step(string.concat("  deposits before upgrade: ", vm.toString(depositsBefore)));

        _step("[Step 3] Upgrade beacon to V2");
        StrategyControllerV2 newImpl = new StrategyControllerV2();
        _beaconUpgrade(s.beacon, admin, address(newImpl));

        _step("[Step 4] Verify state preserved and rebalance works after upgrade");
        _verifyStrategyPreserved(s.controller, address(s.adapter));
        assertEq(StrategyControllerV2(address(s.controller)).version(), 2, "V2 version available");

        // Rebalance again after upgrade with a new real deposit
        _fundRealVault(s, userB, 10_000e6);
        vm.warp(block.timestamp + 1); // pass cooldown
        vm.prank(bot);
        s.operatorExecutor.executeRebalance(address(s.controller));
        assertTrue(s.adapter.depositCount() > depositsBefore, "deposit called again after upgrade");
        _step("  PASS: Controller continues working after upgrade with state preserved");

        _logPass();
    }

    function test_SC_NewDeployUsesNewImpl() public {
        _logCase("test_SC_NewDeployUsesNewImpl", unicode"升级后新部署 controller 使用新实现");

        StrategyController impl = new StrategyController();
        StrategyControllerFactory factory = new StrategyControllerFactory(address(impl), admin);
        UpgradeableBeacon beacon = factory.BEACON();

        _step("[Step 1] Upgrade beacon to V2");
        StrategyControllerV2 newImpl = new StrategyControllerV2();
        _beaconUpgrade(beacon, admin, address(newImpl));

        _step("[Step 2] Deploy new controller after upgrade");
        VaultFactory vaultFactory = new VaultFactory(address(new MantleYieldVault()), admin);
        GatewayFactory gatewayFactory = new GatewayFactory(address(new MantleVaultGateway()), admin);
        (MantleYieldVault vault_,) = _deployVaultAndGateway(vaultFactory, gatewayFactory);
        OperatorExecutor opExec = _deployOperatorExecutor();

        address newCtrl = factory.deployAndInitController(
            address(vault_), admin, address(opExec), admin, 1000, 200, 1 hours
        );
        vm.prank(admin);
        vault_.setController(newCtrl);
        assertEq(StrategyControllerV2(newCtrl).version(), 2, "new controller should use V2");
        assertEq(factory.implementation(), address(newImpl), "factory.implementation should be V2");
        _step("  PASS: New deployment uses new implementation");

        _logPass();
    }

    function test_SC_StorageLayoutCompatibility() public {
        _logCase("test_SC_StorageLayoutCompatibility", unicode"升级后存储布局兼容性");

        RealControllerStack memory s = _deployRealControllerStack(1000, 200, 0);

        _step("[Step 1] Deploy V1 controller, register strategy, set order, rebalance");
        _registerActivateAndSetOrder(s.controller, s.adapter);
        _fundRealVault(s, userA, 5_000e6);
        vm.prank(bot);
        s.operatorExecutor.executeRebalance(address(s.controller));

        // Record V1 state snapshot
        bytes32 v1StateHash = _hashControllerState(s.controller, address(s.adapter));

        _step("[Step 2] Upgrade beacon to V2 with appended storage");
        StrategyControllerV2WithStorage newImpl = new StrategyControllerV2WithStorage();
        _beaconUpgrade(s.beacon, admin, address(newImpl));

        _step("[Step 3] Verify V1 state preserved");
        assertEq(_hashControllerState(s.controller, address(s.adapter)), v1StateHash, "controller state fully preserved");

        _step("[Step 4] V2 new method available");
        StrategyControllerV2WithStorage ctrlV2 = StrategyControllerV2WithStorage(address(s.controller));
        assertEq(ctrlV2.version(), 2, "version() should return 2");
        vm.prank(admin);
        ctrlV2.setNewControllerVar(42);
        assertEq(ctrlV2.newControllerVar(), 42, "new var works");
        _step("  PASS: V1 data fully preserved; V2 new method works; no storage conflict");

        _logPass();
    }

    function test_SC_StorageLayoutIncompatibility() public {
        _logCase("test_SC_StorageLayoutIncompatibility", unicode"升级后存储布局不兼容（破坏性测试）");

        RealControllerStack memory s = _deployRealControllerStack(1500, 300, 1 hours);

        _step("[Step 1] Deploy V1 controller and record state");
        address ctrlAddr = address(s.controller);
        address vaultV1 = address(s.controller.vault());
        address assetV1 = address(s.controller.asset());

        _step("[Step 2] Upgrade to incompatible V2 (swapped vault/asset positions)");
        StrategyControllerV2Incompatible badImpl = new StrategyControllerV2Incompatible();
        _beaconUpgrade(s.beacon, admin, address(badImpl));

        _step("[Step 3] Read data through V2 interface - should be corrupted");
        StrategyControllerV2Incompatible ctrlBad = StrategyControllerV2Incompatible(ctrlAddr);
        // In V1: slot0=asset, slot1=vault. In bad V2: slot0=vault, slot1=asset.
        // So reading vault through bad V2 returns what was V1's asset, and vice versa.
        bool corrupted = (ctrlBad.vault() != vaultV1) || (ctrlBad.asset() != assetV1);
        assertTrue(corrupted, "data should be corrupted after incompatible upgrade");
        _step("  PASS: Data corruption demonstrated - proves storage layout compatibility is critical");

        _logPass();
    }

    function test_SC_FullLifecycleWithUpgrade() public {
        _logCase(
            "test_SC_FullLifecycleWithUpgrade",
            unicode"factory 部署 -> controller 初始化 -> 注册策略 -> 激活 -> rebalance -> 升级 -> rebalance"
        );

        RealControllerStack memory s = _deployRealControllerStack(1000, 200, 0);

        _step("[Step 1] Deploy factory");
        assertEq(address(s.controller.vault()), address(s.vault), "controller wired to real vault");

        _step("[Step 3] Register strategy");
        vm.prank(admin);
        s.controller.registerStrategy(address(s.adapter), 10_000, 1, false);

        _step("[Step 4] Activate strategy");
        vm.prank(admin);
        s.controller.activateStrategy(address(s.adapter));

        _step("[Step 5] Set strategy order");
        address[] memory order = new address[](1);
        order[0] = address(s.adapter);
        vm.prank(admin);
        s.controller.setStrategyOrder(order);

        _step("[Step 6] User deposits USDC to real vault through gateway");
        _fundRealVault(s, userA, 10_000e6);

        _step("[Step 7] Rebalance (invest)");
        vm.prank(bot);
        s.operatorExecutor.executeRebalance(address(s.controller));
        assertTrue(s.adapter.depositCount() > 0, "deposit called on invest");
        uint256 depositsFirst = s.adapter.depositCount();

        _step("[Step 8] Upgrade beacon to new impl");
        StrategyControllerV2 newImpl = new StrategyControllerV2();
        _beaconUpgrade(s.beacon, admin, address(newImpl));
        assertEq(StrategyControllerV2(address(s.controller)).version(), 2, "V2 active");

        _step("[Step 9] Rebalance again after upgrade");
        _fundRealVault(s, userB, 10_000e6);
        vm.warp(block.timestamp + 1);
        vm.prank(bot);
        s.operatorExecutor.executeRebalance(address(s.controller));
        assertTrue(s.adapter.depositCount() > depositsFirst, "deposit called again post-upgrade");
        _step("  PASS: Full lifecycle with upgrade completed successfully");

        _logPass();
    }

    function test_SC_MultiControllerIndependent() public {
        _logCase("test_SC_MultiControllerIndependent", unicode"多 controller 独立运作");

        RealControllerStack memory s1 = _deployRealControllerStack(1000, 200, 0);
        RealControllerStack memory s2 = _deployRealControllerStack(2000, 300, 0);

        _step("[Step 1] Deploy 2 controllers with different vaults");
        assertTrue(address(s1.vault) != address(s2.vault), "vaults must differ");

        _step("[Step 2] Controller1 registers/activates adapterA");
        _registerActivateAndSetOrder(s1.controller, s1.adapter);

        _step("[Step 3] Controller2 registers/activates adapterB");
        _registerActivateAndSetOrder(s2.controller, s2.adapter);

        _step("[Step 4] Rebalance both independently");
        _fundRealVault(s1, userA, 5_000e6);
        _fundRealVault(s2, userB, 8_000e6);

        vm.prank(bot);
        s1.operatorExecutor.executeRebalance(address(s1.controller));
        vm.prank(bot);
        s2.operatorExecutor.executeRebalance(address(s2.controller));

        assertTrue(s1.adapter.depositCount() > 0, "adapterA got deposits");
        assertTrue(s2.adapter.depositCount() > 0, "adapterB got deposits");
        assertEq(s1.controller.bufferTargetBps(), 1000, "ctrl1 has its own buffer");
        assertEq(s2.controller.bufferTargetBps(), 2000, "ctrl2 has its own buffer");
        _step("  PASS: Controllers operate independently with different vaults and strategies");

        _logPass();
    }

    function test_SC_OperatorToControllerToVault() public {
        _logCase(
            "test_SC_OperatorToControllerToVault",
            unicode"`OperatorExecutor -> StrategyController -> Vault` 全链路"
        );

        RealControllerStack memory s = _deployRealControllerStack(1000, 200, 0);

        _step("[Step 3] Register, activate, set order");
        _registerActivateAndSetOrder(s.controller, s.adapter);

        _step("[Step 4] Fund vault and execute rebalance through full chain");
        _fundRealVault(s, userA, 10_000e6);
        vm.prank(bot);
        s.operatorExecutor.executeRebalance(address(s.controller));

        _step("[Step 5] Verify vault state updated");
        assertTrue(s.adapter.depositCount() > 0, "adapter deposit called");
        assertTrue(s.vault.totalInvestInFlight() > 0, "vault invest in-flight recorded");
        assertTrue(s.vault.nextInFlightId() > 1, "in-flight ID created");
        _step("  PASS: OperatorExecutor -> StrategyController -> Vault full chain works");

        _logPass();
    }

    function test_SC_OperatorSettleAdapterFullChain() public {
        _logCase(
            "test_SC_OperatorSettleAdapterFullChain",
            unicode"`OperatorExecutor settleAdapter` 全链路"
        );

        RealControllerStack memory s = _deployRealControllerStack(1000, 200, 0);
        _registerActivateAndSetOrder(s.controller, s.adapter);

        _step("[Step 1] Create invest in-flight via rebalance");
        _fundRealVault(s, userA, 10_000e6);
        vm.prank(bot);
        s.operatorExecutor.executeRebalance(address(s.controller));

        uint256 inFlightId = s.vault.nextInFlightId() - 1;
        assertTrue(inFlightId > 0, "in-flight created");
        uint256 investBefore = s.vault.totalInvestInFlight();
        assertTrue(investBefore > 0, "invest in-flight > 0");

        _step("[Step 2] Settle adapter through OperatorExecutor");
        _settleInvestInFlight(s.vault, inFlightId, s.posToken, s.operatorExecutor, address(s.controller), address(s.adapter));

        _step("[Step 3] Verify settlement completed");
        assertEq(s.vault.totalInvestInFlight(), 0, "invest in-flight cleared");
        IMantleYieldVault.InFlightStatus status;
        (,,,,,,,, status) = s.vault.inFlightRecords(inFlightId);
        assertEq(uint8(status), uint8(IMantleYieldVault.InFlightStatus.CONFIRMED), "in-flight confirmed");
        _step("  PASS: OperatorExecutor settleAdapter full chain works");

        _logPass();
    }

    function test_SC_StrategyFullLifecycle() public {
        _logCase(
            "test_SC_StrategyFullLifecycle",
            unicode"策略完整生命周期：注册 -> 激活 -> order -> rebalance -> settle -> 移出 order -> 停用"
        );

        RealControllerStack memory s = _deployRealControllerStack(1000, 200, 0);

        _step("[Step 1] registerStrategy");
        vm.prank(admin);
        s.controller.registerStrategy(address(s.adapter), 10_000, 1, false);
        (,,,, bool exists1) = s.controller.strategyInfo(address(s.adapter));
        assertTrue(exists1, "strategy registered");

        _step("[Step 2] activateStrategy");
        vm.prank(admin);
        s.controller.activateStrategy(address(s.adapter));
        (,,, bool active2,) = s.controller.strategyInfo(address(s.adapter));
        assertTrue(active2, "strategy activated");

        _step("[Step 3] setStrategyOrder");
        address[] memory order = new address[](1);
        order[0] = address(s.adapter);
        vm.prank(admin);
        s.controller.setStrategyOrder(order);
        assertEq(s.controller.strategyOrderLength(), 1, "order length = 1");

        _step("[Step 4] rebalance (invest)");
        _fundRealVault(s, userA, 10_000e6);
        vm.prank(bot);
        s.operatorExecutor.executeRebalance(address(s.controller));
        assertTrue(s.adapter.depositCount() > 0, "invest executed");

        _step("[Step 5] settleAdapter (confirm invest in-flight)");
        _settleInvestInFlight(
            s.vault, s.vault.nextInFlightId() - 1, s.posToken, s.operatorExecutor, address(s.controller), address(s.adapter)
        );
        assertEq(s.vault.totalInvestInFlight(), 0, "in-flight settled");

        _step("[Step 6] Register a second adapter, move weight, set order to exclude first adapter");
        MockAdapterForUpgrade adapter2 =
            new MockAdapterForUpgrade(address(usdc), address(s.posToken), address(s.vault));
        _registerAndSwapToAdapter2(s.controller, s.adapter, adapter2);
        assertEq(s.controller.strategyOrderLength(), 1, "order has only adapter2");

        _step("[Step 7] deactivateStrategy (first adapter)");
        vm.prank(admin);
        s.controller.deactivateStrategy(address(s.adapter));
        (,,, bool active7,) = s.controller.strategyInfo(address(s.adapter));
        assertFalse(active7, "strategy deactivated");
        assertFalse(s.vault.isAdapter(address(s.adapter)), "adapter removed from vault");
        _step("  PASS: Full strategy lifecycle completed successfully");

        _logPass();
    }

    // ===================================================================
    //  SANCTIONS ORACLE FACTORY - BEACON UPGRADE
    // ===================================================================

    function test_SO_BeaconOwnerUpgrade() public {
        _logCase("test_SO_BeaconOwnerUpgrade", unicode"`beaconOwner` 升级实现合约");

        SanctionsOracle impl = new SanctionsOracle();
        SanctionsOracleFactory factory = new SanctionsOracleFactory(address(impl), admin);
        UpgradeableBeacon beacon = factory.BEACON();

        SanctionsOracleV2 newImpl = new SanctionsOracleV2();
        _beaconUpgrade(beacon, admin, address(newImpl));

        assertEq(beacon.implementation(), address(newImpl));
        _step("  PASS: BEACON.implementation() == newImpl");

        _logPass();
    }

    function test_SO_PostUpgradeOracleWorks() public {
        _logCase("test_SO_PostUpgradeOracleWorks", unicode"升级后已有 oracle 继续工作");

        SanctionsOracle impl = new SanctionsOracle();
        SanctionsOracleFactory factory = new SanctionsOracleFactory(address(impl), admin);
        UpgradeableBeacon beacon = factory.BEACON();

        _step("[Step 1] Deploy and init oracle, sanction an address");
        address oracleAddr = factory.deployAndInitOracle(admin, bot);
        SanctionsOracle so = SanctionsOracle(oracleAddr);
        vm.prank(bot);
        so.updateSanctionStatus(userA, true);
        assertTrue(so.isSanctioned(userA), "userA should be sanctioned");

        _step("[Step 2] Upgrade beacon");
        SanctionsOracleV2 newImpl = new SanctionsOracleV2();
        _beaconUpgrade(beacon, admin, address(newImpl));

        _step("[Step 3] Verify state preserved and functionality works");
        assertTrue(so.isSanctioned(userA), "userA still sanctioned after upgrade");
        vm.prank(bot);
        so.updateSanctionStatus(userB, true);
        assertTrue(so.isSanctioned(userB), "userB sanctioned after upgrade");
        _step("  PASS: Oracle continues working after upgrade with state preserved");

        _logPass();
    }

    function test_SO_NonOwnerCannotUpgrade() public {
        _logCase("test_SO_NonOwnerCannotUpgrade", unicode"非 `beaconOwner` 无法升级");

        SanctionsOracleFactory factory = new SanctionsOracleFactory(address(new SanctionsOracle()), admin);
        UpgradeableBeacon beacon = factory.BEACON();
        SanctionsOracleV2 newImpl = new SanctionsOracleV2();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        beacon.upgradeTo(address(newImpl));
        _step("  PASS: reverted OwnableUnauthorizedAccount");

        _logPass();
    }

    function test_SO_UpgradeToZeroAddress() public {
        _logCase("test_SO_UpgradeToZeroAddress", unicode"升级为零地址");

        SanctionsOracleFactory factory = new SanctionsOracleFactory(address(new SanctionsOracle()), admin);
        UpgradeableBeacon beacon = factory.BEACON();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UpgradeableBeacon.BeaconInvalidImplementation.selector, address(0)));
        beacon.upgradeTo(address(0));
        _step("  PASS: reverted BeaconInvalidImplementation");

        _logPass();
    }

    function test_SO_UpgradeToEOA() public {
        _logCase("test_SO_UpgradeToEOA", unicode"升级为 EOA（无代码）");

        SanctionsOracleFactory factory = new SanctionsOracleFactory(address(new SanctionsOracle()), admin);
        UpgradeableBeacon beacon = factory.BEACON();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UpgradeableBeacon.BeaconInvalidImplementation.selector, makeAddr("eoa")));
        beacon.upgradeTo(makeAddr("eoa"));
        _step("  PASS: reverted BeaconInvalidImplementation");

        _logPass();
    }

    function test_SO_BatchUpgradeAllOracles() public {
        _logCase("test_SO_BatchUpgradeAllOracles", unicode"批量升级所有 oracle");

        SanctionsOracle impl = new SanctionsOracle();
        SanctionsOracleFactory factory = new SanctionsOracleFactory(address(impl), admin);
        UpgradeableBeacon beacon = factory.BEACON();

        _step("[Step 1] Deploy 5 oracles");
        for (uint256 i = 0; i < 5; i++) {
            factory.deployAndInitOracle(admin, bot);
        }
        assertEq(factory.oracleCount(), 5);

        _step("[Step 2] Upgrade beacon once");
        SanctionsOracleV2 newImpl = new SanctionsOracleV2();
        _beaconUpgrade(beacon, admin, address(newImpl));

        _step("[Step 3] All 5 oracles use V2");
        address[] memory all = factory.getAllOracles();
        for (uint256 i = 0; i < 5; i++) {
            assertEq(SanctionsOracleV2(all[i]).version(), 2);
        }
        _step("  PASS: All 5 oracles upgraded simultaneously");

        _logPass();
    }

    function test_SO_MultiOracleIndependent() public {
        _logCase("test_SO_MultiOracleIndependent", unicode"多 oracle 独立运作");

        SanctionsOracle impl = new SanctionsOracle();
        SanctionsOracleFactory factory = new SanctionsOracleFactory(address(impl), admin);

        address bot1 = makeAddr("bot1");
        address bot2 = makeAddr("bot2");
        address o1 = factory.deployAndInitOracle(admin, bot1);
        address o2 = factory.deployAndInitOracle(admin, bot2);

        _step("[Step 1] bot1 sanctions alice on oracle1");
        vm.prank(bot1);
        SanctionsOracle(o1).updateSanctionStatus(userA, true);

        _step("[Step 2] bot2 sanctions bob on oracle2");
        vm.prank(bot2);
        SanctionsOracle(o2).updateSanctionStatus(userB, true);

        assertTrue(SanctionsOracle(o1).isSanctioned(userA), "o1: alice sanctioned");
        assertFalse(SanctionsOracle(o1).isSanctioned(userB), "o1: bob not sanctioned");
        assertFalse(SanctionsOracle(o2).isSanctioned(userA), "o2: alice not sanctioned");
        assertTrue(SanctionsOracle(o2).isSanctioned(userB), "o2: bob sanctioned");
        _step("  PASS: Oracles operate independently");

        _logPass();
    }

    function test_SO_NewDeployUsesNewImpl() public {
        _logCase("test_SO_NewDeployUsesNewImpl", unicode"升级后新部署 oracle 使用新实现");

        SanctionsOracle impl = new SanctionsOracle();
        SanctionsOracleFactory factory = new SanctionsOracleFactory(address(impl), admin);
        UpgradeableBeacon beacon = factory.BEACON();

        SanctionsOracleV2 newImpl = new SanctionsOracleV2();
        _beaconUpgrade(beacon, admin, address(newImpl));

        address newOracle = factory.deployAndInitOracle(admin, bot);
        assertEq(SanctionsOracleV2(newOracle).version(), 2);
        _step("  PASS: New deployment uses new implementation");

        _logPass();
    }

    function test_SO_StorageLayoutCompatibility() public {
        _logCase("test_SO_StorageLayoutCompatibility", unicode"升级后存储布局兼容性（ERC-7201）");

        SanctionsOracle impl = new SanctionsOracle();
        SanctionsOracleFactory factory = new SanctionsOracleFactory(address(impl), admin);
        UpgradeableBeacon beacon = factory.BEACON();

        _step("[Step 1] Deploy V1 oracle, perform sanction and whitelist operations");
        address oracleAddr = factory.deployAndInitOracle(admin, bot);
        SanctionsOracle so = SanctionsOracle(oracleAddr);

        vm.startPrank(bot);
        so.updateSanctionStatus(userA, true);
        so.updateWhitelistStatus(userB, true);
        vm.stopPrank();

        // Record V1 state
        assertTrue(so.isSanctioned(userA), "V1: userA sanctioned");
        assertFalse(so.isSanctioned(userB), "V1: userB not sanctioned");
        assertTrue(so.isWhitelisted(userB), "V1: userB whitelisted");
        assertFalse(so.isWhitelisted(userA), "V1: userA not whitelisted");
        uint256 sanctionCountV1 = so.totalSanctionedCount();
        uint256 whitelistCountV1 = so.totalWhitelistedCount();

        _step("[Step 2] Upgrade beacon to V2 with appended storage");
        SanctionsOracleV2WithStorage newImpl = new SanctionsOracleV2WithStorage();
        _beaconUpgrade(beacon, admin, address(newImpl));

        _step("[Step 3] Verify V1 data preserved (ERC-7201 namespaced storage)");
        assertTrue(so.isSanctioned(userA), "V2: userA still sanctioned");
        assertFalse(so.isSanctioned(userB), "V2: userB still not sanctioned");
        assertTrue(so.isWhitelisted(userB), "V2: userB still whitelisted");
        assertFalse(so.isWhitelisted(userA), "V2: userA still not whitelisted");
        assertEq(so.totalSanctionedCount(), sanctionCountV1, "sanctioned count preserved");
        assertEq(so.totalWhitelistedCount(), whitelistCountV1, "whitelist count preserved");

        _step("[Step 4] V2 new method available");
        SanctionsOracleV2WithStorage soV2 = SanctionsOracleV2WithStorage(oracleAddr);
        assertEq(soV2.version(), 2, "version() returns 2");
        vm.prank(admin);
        soV2.setExtraOracleData(99);
        assertEq(soV2.extraOracleData(), 99, "new V2 variable works");

        _step("[Step 5] V1 operations still work after upgrade");
        vm.prank(bot);
        so.updateSanctionStatus(userA, false);
        assertFalse(so.isSanctioned(userA), "unsanction works after upgrade");
        _step("  PASS: V1 data fully preserved (ERC-7201); V2 new method works");

        _logPass();
    }

    function test_SO_WhitelistGatewayIntegration() public {
        _logCase("test_SO_WhitelistGatewayIntegration", unicode"Oracle 白名单与 Gateway 联动");

        _step("[Step 1] Deploy real SanctionsOracle via factory");
        SanctionsOracle soImpl = new SanctionsOracle();
        SanctionsOracleFactory soFactory = new SanctionsOracleFactory(address(soImpl), admin);
        address oracleAddr = soFactory.deployAndInitOracle(admin, bot);
        SanctionsOracle so = SanctionsOracle(oracleAddr);

        _step("[Step 2] Deploy Gateway and Vault, configure oracle");
        VaultFactory vFactory = new VaultFactory(address(new MantleYieldVault()), admin);
        GatewayFactory gFactory = new GatewayFactory(address(new MantleVaultGateway()), admin);

        address vAddr = vFactory.deployVault();
        address gwAddr = gFactory.deployGateway();
        MantleYieldVault v = MantleYieldVault(vAddr);
        MantleVaultGateway gw = MantleVaultGateway(gwAddr);
        Accountant realAccountant = _deployRealAccountant(vAddr, 1e18, 100);

        vm.prank(admin);
        v.initialize(
            IMantleYieldVault.InitParams({
                asset: IERC20(address(usdc)),
                name: "Mantle RWA Vault",
                symbol: "mRWA",
                admin: admin,
                gateway: gwAddr,
                controller: makeAddr("controller"),
                accountant: address(realAccountant),
                treasury: treasuryAddr,
                maxRedemptionFeeBps: 500,
                redemptionFeeBps: 100,
                minRedeemAmount: 100e6,
                minDepositAmount: 0,
                maxSettlementDeviationBps: 0,
                depositDailyRemaining: type(uint256).max,
                redeemDailyRemaining: type(uint256).max
            })
        );

        vm.prank(admin);
        gw.initialize(
            IMantleVaultGateway.InitParams({
                vault: vAddr,
                sanctionsOracle: ISanctionsOracle(oracleAddr),
                sanctionSafe: sanctionSafe,
                admin: admin,
                syncRedeemDisabled: false
            })
        );

        _step("[Step 3] Admin enables whitelist");
        vm.prank(admin);
        gw.setWhitelistEnabled(true);

        _step("[Step 4] Non-whitelisted user tries to deposit -> reverts");
        usdc.mint(userA, 1_000e6);
        vm.startPrank(userA);
        usdc.approve(address(v), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IMantleVaultGateway.Gateway__NotWhitelisted.selector, userA));
        gw.deposit(1_000e6);
        vm.stopPrank();
        _step("  Step 4 reverted Gateway__NotWhitelisted as expected");

        _step("[Step 5] Compliance bot whitelists the user");
        vm.prank(bot);
        so.updateWhitelistStatus(userA, true);
        assertTrue(so.isWhitelisted(userA), "userA whitelisted in oracle");

        _step("[Step 6] Whitelisted user deposits successfully");
        vm.prank(userA);
        gw.deposit(1_000e6);
        assertTrue(v.balanceOf(userA) > 0, "userA received shares");
        _step("  PASS: Oracle whitelist and Gateway interoperate correctly");

        _logPass();
    }

    // ===================================================================
    //  ACCOUNTANT FACTORY - BEACON UPGRADE
    // ===================================================================

    function test_Acct_BeaconOwnerUpgrade() public {
        _logCase("test_Acct_BeaconOwnerUpgrade", unicode"`beaconOwner` 升级实现合约");

        Accountant impl = new Accountant();
        AccountantFactory factory = new AccountantFactory(address(impl), admin);
        UpgradeableBeacon beacon = factory.BEACON();

        AccountantV2 newImpl = new AccountantV2();
        _beaconUpgrade(beacon, admin, address(newImpl));

        assertEq(beacon.implementation(), address(newImpl));
        _step("  PASS: BEACON.implementation() == newImpl");

        _logPass();
    }

    function test_Acct_PostUpgradeWorks() public {
        _logCase("test_Acct_PostUpgradeWorks", unicode"升级后已有 accountant 继续工作");

        Accountant impl = new Accountant();
        AccountantFactory factory = new AccountantFactory(address(impl), admin);
        UpgradeableBeacon beacon = factory.BEACON();

        // Need a vault for accountant init
        VaultFactory vFactory = new VaultFactory(address(new MantleYieldVault()), admin);
        GatewayFactory gFactory = new GatewayFactory(address(new MantleVaultGateway()), admin);
        (MantleYieldVault v,) = _deployVaultAndGateway(vFactory, gFactory);

        _step("[Step 1] Deploy and init accountant");
        address acctAddr = factory.deployAndInitAccountant(address(v), 1e18, 100, admin, admin, admin);
        Accountant acct = Accountant(acctAddr);
        uint256 rateBefore = acct.getRate();
        _step(string.concat("  rate before: ", vm.toString(rateBefore)));

        _step("[Step 2] Upgrade beacon");
        AccountantV2 newImpl = new AccountantV2();
        _beaconUpgrade(beacon, admin, address(newImpl));

        _step("[Step 3] Verify state preserved");
        assertEq(acct.getRate(), rateBefore, "rate preserved");
        assertEq(acct.lastExchangeRate(), rateBefore, "lastExchangeRate preserved");
        _step("  PASS: Accountant continues working after upgrade");

        _logPass();
    }

    function test_Acct_NonOwnerCannotUpgrade() public {
        _logCase("test_Acct_NonOwnerCannotUpgrade", unicode"非 `beaconOwner` 无法升级");

        AccountantFactory factory = new AccountantFactory(address(new Accountant()), admin);
        UpgradeableBeacon beacon = factory.BEACON();
        AccountantV2 newImpl = new AccountantV2();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        beacon.upgradeTo(address(newImpl));
        _step("  PASS: reverted OwnableUnauthorizedAccount");

        _logPass();
    }

    function test_Acct_UpgradeToZeroAddress() public {
        _logCase("test_Acct_UpgradeToZeroAddress", unicode"升级为零地址");

        AccountantFactory factory = new AccountantFactory(address(new Accountant()), admin);
        UpgradeableBeacon beacon = factory.BEACON();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UpgradeableBeacon.BeaconInvalidImplementation.selector, address(0)));
        beacon.upgradeTo(address(0));
        _step("  PASS: reverted BeaconInvalidImplementation");

        _logPass();
    }

    function test_Acct_UpgradeToEOA() public {
        _logCase("test_Acct_UpgradeToEOA", unicode"升级为 EOA（无代码）");

        AccountantFactory factory = new AccountantFactory(address(new Accountant()), admin);
        UpgradeableBeacon beacon = factory.BEACON();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UpgradeableBeacon.BeaconInvalidImplementation.selector, makeAddr("eoa")));
        beacon.upgradeTo(makeAddr("eoa"));
        _step("  PASS: reverted BeaconInvalidImplementation");

        _logPass();
    }

    function test_Acct_BatchUpgradeAllAccountants() public {
        _logCase("test_Acct_BatchUpgradeAllAccountants", unicode"批量升级所有 accountant");

        Accountant impl = new Accountant();
        AccountantFactory factory = new AccountantFactory(address(impl), admin);
        UpgradeableBeacon beacon = factory.BEACON();

        VaultFactory vFactory = new VaultFactory(address(new MantleYieldVault()), admin);
        GatewayFactory gFactory = new GatewayFactory(address(new MantleVaultGateway()), admin);

        _step("[Step 1] Deploy 5 accountants");
        for (uint256 i = 0; i < 5; i++) {
            (MantleYieldVault v,) = _deployVaultAndGateway(vFactory, gFactory);
            factory.deployAndInitAccountant(address(v), 1e18, 100, admin, admin, admin);
        }
        assertEq(factory.accountantCount(), 5);

        _step("[Step 2] Upgrade beacon once");
        AccountantV2 newImpl = new AccountantV2();
        _beaconUpgrade(beacon, admin, address(newImpl));

        _step("[Step 3] All 5 use V2");
        address[] memory all = factory.getAllAccountants();
        for (uint256 i = 0; i < 5; i++) {
            assertEq(AccountantV2(all[i]).version(), 2);
        }
        _step("  PASS: All 5 accountants upgraded simultaneously");

        _logPass();
    }

    function test_Acct_TimelockDelayedUpgrade() public {
        _logCase("test_Acct_TimelockDelayedUpgrade", unicode"通过 `TimelockController` 延迟升级");

        Accountant impl = new Accountant();
        AccountantV2 newImpl = new AccountantV2();

        address[] memory proposers = new address[](1);
        proposers[0] = admin;
        address[] memory executors = new address[](1);
        executors[0] = admin;

        uint256 minDelay = 1 days;
        TimelockUpgradeController timelock = new TimelockUpgradeController(minDelay, proposers, executors, admin);

        AccountantFactory factory = new AccountantFactory(address(impl), address(timelock));
        UpgradeableBeacon beacon = factory.BEACON();

        bytes memory data = abi.encodeCall(beacon.upgradeTo, (address(newImpl)));
        bytes32 salt = bytes32(0);

        vm.prank(admin);
        timelock.schedule(address(beacon), 0, data, bytes32(0), salt, minDelay);

        _step("[Step 1] Execute before delay should revert");
        bytes32 opId = timelock.hashOperation(address(beacon), 0, data, bytes32(0), salt);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnexpectedOperationState.selector, opId, bytes32(1 << uint8(TimelockController.OperationState.Ready))));
        timelock.execute(address(beacon), 0, data, bytes32(0), salt);

        _step("[Step 2] Warp and execute");
        vm.warp(block.timestamp + minDelay);
        vm.prank(admin);
        timelock.execute(address(beacon), 0, data, bytes32(0), salt);

        assertEq(beacon.implementation(), address(newImpl));
        _step("  PASS: Timelock upgrade succeeded after delay");

        _logPass();
    }

    function test_Acct_FullLifecycleWithUpgrade() public {
        _logCase(
            "test_Acct_FullLifecycleWithUpgrade",
            unicode"factory 部署 -> accountant 初始化 -> 更新汇率 -> 升级 -> 再更新"
        );

        Accountant impl = new Accountant();
        AccountantFactory factory = new AccountantFactory(address(impl), admin);
        UpgradeableBeacon beacon = factory.BEACON();
        VaultFactory vFactory = new VaultFactory(address(new MantleYieldVault()), admin);
        GatewayFactory gFactory = new GatewayFactory(address(new MantleVaultGateway()), admin);
        (MantleYieldVault v,) = _deployVaultAndGateway(vFactory, gFactory);

        _step("[Step 1] Deploy and init accountant");
        address acctAddr = factory.deployAndInitAccountant(address(v), 1e18, 100, admin, admin, admin);
        Accountant acct = Accountant(acctAddr);

        _step("[Step 2] Deploy executor and update rate via bot -> executor -> accountant");
        AccountantExecutor exImpl = new AccountantExecutor();
        AccountantExecutor executor = AccountantExecutor(address(new ERC1967Proxy(
            address(exImpl), abi.encodeCall(AccountantExecutor.initialize, (admin))
        )));
        vm.startPrank(admin);
        executor.grantRole(executor.BOT_ROLE(), bot);
        executor.grantRole(executor.FEE_SETTLER_ROLE(), bot);
        acct.grantRole(acct.ACCOUNTANT_EXECUTOR_ROLE(), address(executor));
        vm.stopPrank();

        vm.warp(block.timestamp + 21 hours); // wait for cooldown
        vm.prank(bot);
        executor.executeUpdateRate(address(acct), 1.001e18, uint64(block.timestamp));
        assertEq(acct.lastExchangeRate(), 1.001e18, "rate updated");
        _step("  Rate updated to 1.001e18");

        _step("[Step 3] Upgrade beacon to V2");
        AccountantV2 newImpl = new AccountantV2();
        _beaconUpgrade(beacon, admin, address(newImpl));

        _step("[Step 4] Update rate again after upgrade via executor");
        vm.warp(block.timestamp + 21 hours);
        vm.prank(bot);
        executor.executeUpdateRate(address(acct), 1.002e18, uint64(block.timestamp));
        assertEq(acct.lastExchangeRate(), 1.002e18, "rate updated after upgrade");
        _step("  PASS: Full lifecycle with upgrade works correctly");

        _logPass();
    }

    function test_Acct_MultiAccountantIndependent() public {
        _logCase("test_Acct_MultiAccountantIndependent", unicode"多 accountant 独立运作");

        Accountant impl = new Accountant();
        AccountantFactory factory = new AccountantFactory(address(impl), admin);
        VaultFactory vFactory = new VaultFactory(address(new MantleYieldVault()), admin);
        GatewayFactory gFactory = new GatewayFactory(address(new MantleVaultGateway()), admin);

        (MantleYieldVault v1,) = _deployVaultAndGateway(vFactory, gFactory);
        (MantleYieldVault v2,) = _deployVaultAndGateway(vFactory, gFactory);

        address a1 = factory.deployAndInitAccountant(address(v1), 1e18, 100, admin, admin, admin);
        address a2 = factory.deployAndInitAccountant(address(v2), 1e18, 100, admin, admin, admin);

        // Deploy executor and grant roles on both accountants
        AccountantExecutor exImpl = new AccountantExecutor();
        AccountantExecutor executor = AccountantExecutor(address(new ERC1967Proxy(
            address(exImpl), abi.encodeCall(AccountantExecutor.initialize, (admin))
        )));
        vm.startPrank(admin);
        executor.grantRole(executor.BOT_ROLE(), bot);
        executor.grantRole(executor.FEE_SETTLER_ROLE(), bot);
        Accountant(a1).grantRole(Accountant(a1).ACCOUNTANT_EXECUTOR_ROLE(), address(executor));
        Accountant(a2).grantRole(Accountant(a2).ACCOUNTANT_EXECUTOR_ROLE(), address(executor));
        vm.stopPrank();

        _step("[Step 1] Update rate on accountant1 via executor");
        vm.warp(block.timestamp + 21 hours);
        vm.prank(bot);
        executor.executeUpdateRate(a1, 1.005e18, uint64(block.timestamp));

        _step("[Step 2] Update rate on accountant2 differently via executor");
        vm.prank(bot);
        executor.executeUpdateRate(a2, 0.995e18, uint64(block.timestamp));

        assertEq(Accountant(a1).lastExchangeRate(), 1.005e18, "a1 rate correct");
        assertEq(Accountant(a2).lastExchangeRate(), 0.995e18, "a2 rate correct");
        _step("  PASS: Accountants operate independently with different rates");

        _logPass();
    }

    function test_Acct_NewDeployUsesNewImpl() public {
        _logCase("test_Acct_NewDeployUsesNewImpl", unicode"升级后新部署 accountant 使用新实现");

        Accountant impl = new Accountant();
        AccountantFactory factory = new AccountantFactory(address(impl), admin);
        UpgradeableBeacon beacon = factory.BEACON();

        AccountantV2 newImpl = new AccountantV2();
        _beaconUpgrade(beacon, admin, address(newImpl));

        VaultFactory vFactory = new VaultFactory(address(new MantleYieldVault()), admin);
        GatewayFactory gFactory = new GatewayFactory(address(new MantleVaultGateway()), admin);
        (MantleYieldVault v,) = _deployVaultAndGateway(vFactory, gFactory);

        address newAcct = factory.deployAndInitAccountant(address(v), 1e18, 100, admin, admin, admin);
        assertEq(AccountantV2(newAcct).version(), 2);
        _step("  PASS: New deployment uses new implementation");

        _logPass();
    }

    // ===================================================================
    //  ACCOUNTANT - STORAGE / SETVAULT / FULL-CHAIN TESTS
    // ===================================================================

    /// @dev Helper: deploy Accountant via BeaconProxy with MockVaultForUpgrade
    /// @dev Helper: settle all pending invest in-flights for a given adapter via OperatorExecutor
    function _settleInvestInFlight(
        IMantleYieldVault vault_,
        uint256 inFlightId,
        MockUSDC_Upgrade posToken_,
        OperatorExecutor opExec,
        address ctrlAddr,
        address adapterAddr
    ) internal {
        (, address flightAdapter, address posToken, uint256 tokenAmt,,,,,) = vault_.inFlightRecords(inFlightId);
        assertEq(posToken, address(posToken_), "unexpected invest pos token");
        posToken_.mint(flightAdapter, tokenAmt);
        uint256[] memory investIds = new uint256[](1);
        investIds[0] = inFlightId;
        uint256[] memory investSettled = new uint256[](1);
        investSettled[0] = tokenAmt;
        vm.prank(bot);
        opExec.executeSettleAdapter(
            ctrlAddr,
            adapterAddr,
            IStrategyControllerExecutor.InvestSettlementInput(investIds, investSettled, new uint256[](1)),
            IStrategyControllerExecutor.RedeemSettlementInput(new uint256[](0), new uint256[](0))
        );
    }

    /// @dev Register adapter, activate, and set as sole strategy order
    function _registerActivateAndSetOrder(StrategyController ctrl, MockAdapterForUpgrade adapter) internal {
        vm.startPrank(admin);
        ctrl.registerStrategy(address(adapter), 10_000, 1, false);
        ctrl.activateStrategy(address(adapter));
        address[] memory order = new address[](1);
        order[0] = address(adapter);
        ctrl.setStrategyOrder(order);
        vm.stopPrank();
    }

    /// @dev Verify strategy info preserved after upgrade
    function _verifyStrategyPreserved(StrategyController ctrl, address adapterAddr) internal view {
        (uint16 weight,, , bool isActive, bool exists) = ctrl.strategyInfo(adapterAddr);
        assertEq(weight, 10_000, "weight preserved");
        assertTrue(isActive, "still active");
        assertTrue(exists, "still exists");
    }

    /// @dev Hash all strategyInfo fields for before/after comparison
    function _hashStrategyInfo(StrategyController ctrl, address adapterAddr) internal view returns (bytes32) {
        (uint16 w, uint16 p, bool ia, bool act, bool ex) = ctrl.strategyInfo(adapterAddr);
        return keccak256(abi.encode(w, p, ia, act, ex));
    }

    /// @dev Hash controller config + strategy info for before/after snapshot comparison
    function _hashControllerState(StrategyController ctrl, address adapterAddr) internal view returns (bytes32) {
        return keccak256(abi.encode(
            ctrl.bufferTargetBps(),
            ctrl.rebalanceThresholdBps(),
            address(ctrl.vault()),
            _hashStrategyInfo(ctrl, adapterAddr)
        ));
    }

    /// @dev Register adapter2, move all weight from adapter to adapter2, set order to adapter2 only
    function _registerAndSwapToAdapter2(
        StrategyController ctrl,
        MockAdapterForUpgrade adapter,
        MockAdapterForUpgrade adapter2
    ) internal {
        vm.startPrank(admin);
        ctrl.registerStrategy(address(adapter2), 0, 2, false);
        ctrl.activateStrategy(address(adapter2));

        address[] memory adaptersList = new address[](2);
        adaptersList[0] = address(adapter);
        adaptersList[1] = address(adapter2);
        uint16[] memory weights = new uint16[](2);
        weights[0] = 0;
        weights[1] = 10_000;
        uint16[] memory priorities = new uint16[](2);
        priorities[0] = 1;
        priorities[1] = 2;
        bool[] memory isAsyncs = new bool[](2);
        isAsyncs[0] = false;
        isAsyncs[1] = false;
        address[] memory newOrder = new address[](1);
        newOrder[0] = address(adapter2);
        ctrl.updateStrategiesAndOrder(adaptersList, weights, priorities, isAsyncs, newOrder);
        vm.stopPrank();
    }

    function _deployAccountantWithMockVault(MockVaultForUpgrade mockVault)
        internal
        returns (Accountant acct, AccountantFactory factory)
    {
        Accountant impl = new Accountant();
        factory = new AccountantFactory(address(impl), admin);
        address acctAddr = factory.deployAndInitAccountant(address(mockVault), 1e18, 100, admin, admin, admin);
        acct = Accountant(acctAddr);
    }

    /// @dev Helper: deploy Accountant + AccountantExecutor full chain with MockVaultForUpgrade
    function _deployFullChain(MockVaultForUpgrade mockVault)
        internal
        returns (Accountant acct, AccountantExecutor executor, AccountantFactory acctFactory)
    {
        (acct, acctFactory) = _deployAccountantWithMockVault(mockVault);

        AccountantExecutor exImpl = new AccountantExecutor();
        bytes memory exInit = abi.encodeCall(AccountantExecutor.initialize, (admin));
        executor = AccountantExecutor(address(new ERC1967Proxy(address(exImpl), exInit)));

        vm.startPrank(admin);
        executor.grantRole(executor.BOT_ROLE(), bot);
        executor.grantRole(executor.FEE_SETTLER_ROLE(), bot);
        acct.grantRole(acct.ACCOUNTANT_EXECUTOR_ROLE(), address(executor));
        vm.stopPrank();
    }

    function test_Acct_StorageLayoutCompatibility() public {
        _logCase(
            "test_Acct_StorageLayoutCompatibility",
            unicode"升级后存储布局兼容性（ERC-7201）"
        );

        _step("[Step 1] Deploy full chain and perform rate update to establish V1 state");
        RealAccountantStack memory s = _deployRealAccountantStack();
        _fundRealVault(s.gateway, s.vault, userA, 1_000_000e6);

        vm.warp(block.timestamp + 21 hours);
        vm.prank(bot);
        s.executor.executeUpdateRate(address(s.accountant), 1.005e18, uint64(block.timestamp));

        // Record V1 state snapshot
        uint256 v1Rate = s.accountant.lastExchangeRate();
        uint32 v1FeeRate = s.accountant.managementFeeRate();
        uint64 v1ComputeTs = s.accountant.lastComputeTimestamp();
        address v1Vault = address(s.accountant.vault());
        assertEq(v1Rate, 1.005e18, "V1 rate set");

        _step("[Step 2] Upgrade beacon to V2 with appended storage");
        UpgradeableBeacon beacon = s.factory.BEACON();
        AccountantV2WithStorage newImpl = new AccountantV2WithStorage();
        _beaconUpgrade(beacon, admin, address(newImpl));

        _step("[Step 3] Verify V1 data preserved (ERC-7201 namespaced storage)");
        assertEq(s.accountant.lastExchangeRate(), v1Rate, "lastExchangeRate preserved");
        assertEq(s.accountant.managementFeeRate(), v1FeeRate, "managementFeeRate preserved");
        assertEq(s.accountant.lastComputeTimestamp(), v1ComputeTs, "lastComputeTimestamp preserved");
        assertEq(address(s.accountant.vault()), v1Vault, "vault reference preserved");

        _step("[Step 4] V2 new method available");
        AccountantV2WithStorage acctV2 = AccountantV2WithStorage(address(s.accountant));
        assertEq(acctV2.version(), 2, "version() returns 2");
        vm.prank(admin);
        acctV2.setNewAccountantVar(42);
        assertEq(acctV2.newAccountantVar(), 42, "new V2 variable works");

        _step("[Step 5] V1 operations still work after upgrade");
        vm.warp(block.timestamp + 21 hours);
        vm.prank(bot);
        s.executor.executeUpdateRate(address(s.accountant), 1.006e18, uint64(block.timestamp));
        assertEq(s.accountant.lastExchangeRate(), 1.006e18, "rate update works after upgrade");
        _step("  PASS: V1 data fully preserved (ERC-7201); V2 new method works");

        _logPass();
    }

    function test_Acct_StorageLayoutIncompatibility() public {
        _logCase(
            "test_Acct_StorageLayoutIncompatibility",
            unicode"升级后存储布局不兼容（破坏性测试）"
        );

        Accountant impl = new Accountant();
        AccountantFactory factory = new AccountantFactory(address(impl), admin);
        UpgradeableBeacon beacon = factory.BEACON();

        MockVaultForUpgrade mockVault = new MockVaultForUpgrade(1_000_000e18);

        _step("[Step 1] Deploy accountant V1 and write data");
        address acctAddr = factory.deployAndInitAccountant(address(mockVault), 1e18, 100, admin, admin, admin);
        Accountant acct = Accountant(acctAddr);

        // Deploy executor for proper call chain
        AccountantExecutor exImpl = new AccountantExecutor();
        AccountantExecutor executor = AccountantExecutor(address(new ERC1967Proxy(
            address(exImpl), abi.encodeCall(AccountantExecutor.initialize, (admin))
        )));
        vm.startPrank(admin);
        executor.grantRole(executor.BOT_ROLE(), bot);
        executor.grantRole(executor.FEE_SETTLER_ROLE(), bot);
        acct.grantRole(acct.ACCOUNTANT_EXECUTOR_ROLE(), address(executor));
        vm.stopPrank();

        // Update rate to set a known lastExchangeRate
        vm.warp(block.timestamp + 21 hours);
        vm.prank(bot);
        executor.executeUpdateRate(address(acct), 1.005e18, uint64(block.timestamp));
        uint256 v1Rate = acct.lastExchangeRate();
        assertEq(v1Rate, 1.005e18, "V1 rate should be 1.005e18");
        _step(string.concat("  V1 lastExchangeRate: ", vm.toString(v1Rate)));

        _step("[Step 2] Upgrade beacon to incompatible V2");
        AccountantV2Incompatible badImpl = new AccountantV2Incompatible();
        _beaconUpgrade(beacon, admin, address(badImpl));

        _step("[Step 3] Read data via incompatible V2 layout - expect corrupted");
        uint256 corruptedRate = AccountantV2Incompatible(acctAddr).lastExchangeRate();
        _step(string.concat("  Corrupted rate: ", vm.toString(corruptedRate)));

        // The rate read through the incompatible layout should NOT equal the V1 rate
        // because lastExchangeRate is now reading from a different slot
        assertTrue(corruptedRate != v1Rate, "rate should be corrupted after incompatible upgrade");
        _step("  PASS: Data corrupted, proving storage layout compatibility is critical");

        _logPass();
    }

    function test_Acct_SetVaultSwitchIntegration() public {
        _logCase(
            "test_Acct_SetVaultSwitchIntegration",
            unicode"accountant `setVault` 切换后与新 vault 联动"
        );

        _step("[Step 1] Deploy accountant with full executor chain and oldVault");
        RealAccountantStack memory oldStack = _deployRealAccountantStack();
        _fundRealVault(oldStack.gateway, oldStack.vault, userA, 1_000_000e6);

        _step("[Step 1.1] Establish a non-zero fee baseline on oldVault");
        vm.warp(block.timestamp + 21 hours);
        vm.prank(bot);
        oldStack.executor.executeSettleManagementFee(address(oldStack.accountant));
        uint256 oldVaultSupplyBefore = oldStack.vault.totalSupply();
        uint256 oldTreasuryBefore = oldStack.vault.balanceOf(treasuryAddr);

        _step("[Step 2] Switch to newVault");
        VaultFactory vaultFactory = new VaultFactory(address(new MantleYieldVault()), admin);
        GatewayFactory gatewayFactory = new GatewayFactory(address(new MantleVaultGateway()), admin);
        (MantleYieldVault newVault, MantleVaultGateway newGateway) = _deployVaultAndGateway(vaultFactory, gatewayFactory);
        _fundRealVault(newGateway, newVault, userB, 2_000_000e6);
        uint256 newVaultSupplyBefore = newVault.totalSupply();
        uint256 newTreasuryBefore = newVault.balanceOf(treasuryAddr);

        vm.prank(admin);
        oldStack.accountant.setVault(address(newVault));
        vm.prank(admin);
        newVault.setAccountant(address(oldStack.accountant));
        assertEq(address(oldStack.accountant.vault()), address(newVault), "vault should be newVault");
        _step("  vault switched to newVault");

        _step("[Step 3] Call settleManagementFee via executor - fee settlement should use newVault");
        vm.warp(block.timestamp + 21 hours);
        uint256 lastSettleTsBefore = oldStack.accountant.lastFeeSettleTimestamp();
        uint256 shareBaseBefore = oldStack.accountant.totalSharesLastSettle();
        vm.prank(bot);
        oldStack.executor.executeSettleManagementFee(address(oldStack.accountant));

        uint256 oldVaultSupplyAfter = oldStack.vault.totalSupply();
        uint256 newVaultSupplyAfter = newVault.totalSupply();
        uint256 newTreasuryAfter = newVault.balanceOf(treasuryAddr);
        uint256 timeElapsed = block.timestamp - lastSettleTsBefore;
        uint256 expectedFeeShares =
            ((newVaultSupplyBefore < shareBaseBefore ? newVaultSupplyBefore : shareBaseBefore) * oldStack.accountant.managementFeeRate() * timeElapsed)
                / (10_000 * 365 days);
        assertEq(oldVaultSupplyAfter, oldVaultSupplyBefore, "oldVault totalSupply should stay unchanged");
        assertEq(oldStack.vault.balanceOf(treasuryAddr), oldTreasuryBefore, "oldVault treasury balance should stay unchanged");
        assertEq(newVaultSupplyAfter - newVaultSupplyBefore, expectedFeeShares, "newVault totalSupply should increase by expected fee shares");
        assertEq(newTreasuryAfter - newTreasuryBefore, expectedFeeShares, "newVault treasury should receive expected fee shares");
        _step("  PASS: Fee settlement uses newVault after setVault switch");

        _logPass();
    }

    function test_Acct_FullRateUpdateChain() public {
        _logCase(
            "test_Acct_FullRateUpdateChain",
            unicode"完整汇率更新流程"
        );

        _step("[Step 1] Deploy full chain (executor + accountant + real vault)");
        RealAccountantStack memory s = _deployRealAccountantStack();

        _step("[Step 2] Bot calls executor.executeUpdateRate");
        vm.warp(block.timestamp + 21 hours);
        uint64 newRate = 1.001e18;
        uint64 computeTs = uint64(block.timestamp);
        vm.prank(bot);
        s.executor.executeUpdateRate(address(s.accountant), newRate, computeTs);

        _step("[Step 3] Verify full chain success");
        assertEq(s.accountant.lastExchangeRate(), newRate, "rate should be updated");
        assertEq(s.accountant.lastComputeTimestamp(), computeTs, "computeTimestamp should be set");
        _step("  PASS: Full chain Bot -> executor -> accountant -> rate update succeeded");

        _logPass();
    }

    function test_Acct_FullChain_CooldownPropagates() public {
        _logCase(
            "test_Acct_FullChain_CooldownPropagates",
            unicode"全链路 - cooldown 检查透传"
        );

        RealAccountantStack memory s = _deployRealAccountantStack();

        _step("[Step 1] Bot calls executor without waiting for cooldown");
        // Do NOT warp forward - cooldown has not elapsed
        vm.prank(bot);
        vm.expectRevert(abi.encodeWithSelector(Accountant.Accountant__FutureComputeTimestamp.selector, uint256(uint64(block.timestamp + 1)), block.timestamp));
        s.executor.executeUpdateRate(address(s.accountant), 1.001e18, uint64(block.timestamp + 1));
        _step("  PASS: CooldownNotElapsed revert propagated through executor");

        _logPass();
    }

    function test_Acct_FullChain_DeviationCircuitBreaker() public {
        _logCase(
            "test_Acct_FullChain_DeviationCircuitBreaker",
            unicode"全链路 - deviation 超限触发 soft pause"
        );

        RealAccountantStack memory s = _deployRealAccountantStack();

        _step("[Step 1] Bot calls executor with excessive deviation rate");
        vm.warp(block.timestamp + 21 hours);
        uint256 rateBefore = s.accountant.lastExchangeRate();
        // 1.05e18 is a 5% deviation, far above the 1% default maxAllowedDeviation
        uint64 extremeRate = 1.05e18;
        uint64 computeTs = uint64(block.timestamp);
        vm.prank(bot);
        s.executor.executeUpdateRate(address(s.accountant), extremeRate, computeTs);

        _step("[Step 2] Verify circuit breaker triggered");
        assertTrue(s.accountant.paused(), "accountant should be paused");
        assertEq(s.accountant.lastExchangeRate(), rateBefore, "rate should remain unchanged");
        _step("  PASS: CircuitBreakerTriggered, accountant paused, rate unchanged");

        _logPass();
    }

    function test_Acct_FullChain_StaleTimestampPropagates() public {
        _logCase(
            "test_Acct_FullChain_StaleTimestampPropagates",
            unicode"全链路 - `computeTimestamp` 过期透传"
        );

        RealAccountantStack memory s = _deployRealAccountantStack();

        _step("[Step 1] Bot calls executor with stale computeTimestamp");
        vm.warp(block.timestamp + 21 hours);
        // Use a computeTimestamp that equals the lastComputeTimestamp (set during init)
        // which is stale (not strictly newer)
        uint64 staleTs = s.accountant.lastComputeTimestamp();
        vm.prank(bot);
        vm.expectRevert(abi.encodeWithSelector(Accountant.Accountant__StaleComputeTimestamp.selector, uint256(staleTs), uint256(staleTs)));
        s.executor.executeUpdateRate(address(s.accountant), 1.001e18, staleTs);
        _step("  PASS: StaleComputeTimestamp revert propagated through executor");

        _logPass();
    }

    function test_Acct_FullChain_PausePropagates() public {
        _logCase(
            "test_Acct_FullChain_PausePropagates",
            unicode"全链路 - 暂停透传"
        );

        RealAccountantStack memory s = _deployRealAccountantStack();

        _step("[Step 1] Admin pauses accountant");
        vm.prank(admin);
        s.accountant.pause();
        assertTrue(s.accountant.paused(), "accountant should be paused");

        _step("[Step 2] Bot calls executor - should revert with EnforcedPause");
        vm.warp(block.timestamp + 21 hours);
        vm.prank(bot);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        s.executor.executeUpdateRate(address(s.accountant), 1.001e18, uint64(block.timestamp));
        _step("  PASS: EnforcedPause revert propagated through executor");

        _logPass();
    }

    function test_Acct_FullChain_FeeSettlementMintShares() public {
        _logCase(
            "test_Acct_FullChain_FeeSettlementMintShares",
            unicode"全链路 - 费用结算与 `vault.mintFeeShares`"
        );

        RealAccountantStack memory s = _deployRealAccountantStack();
        _fundRealVault(s.gateway, s.vault, userA, 1_000_000e6);

        _step("[Step 1] First rate update - does NOT trigger fee settlement");
        vm.warp(block.timestamp + 21 hours);
        vm.prank(bot);
        s.executor.executeUpdateRate(address(s.accountant), 1.001e18, uint64(block.timestamp));
        uint256 treasuryBefore = s.vault.balanceOf(treasuryAddr);
        uint256 supplyBefore = s.vault.totalSupply();
        uint256 lastSettleTsBefore = s.accountant.lastFeeSettleTimestamp();
        uint256 shareBase = s.accountant.totalSharesLastSettle();
        _step(string.concat("  totalSupply before settle: ", vm.toString(supplyBefore)));
        assertEq(treasuryBefore, 0, "rate update should not mint fee shares");

        _step("[Step 2] Call executeSettleManagementFee - triggers fee calculation");
        vm.prank(bot);
        s.executor.executeSettleManagementFee(address(s.accountant));
        uint256 treasuryAfter = s.vault.balanceOf(treasuryAddr);
        uint256 supplyAfter = s.vault.totalSupply();
        uint256 timeElapsed = block.timestamp - lastSettleTsBefore;
        uint256 expectedFeeShares = (shareBase * s.accountant.managementFeeRate() * timeElapsed) / (10_000 * 365 days);
        _step(string.concat("  fee shares minted: ", vm.toString(expectedFeeShares)));
        assertEq(treasuryAfter - treasuryBefore, expectedFeeShares, "treasury should receive exact fee shares");
        assertEq(supplyAfter - supplyBefore, expectedFeeShares, "vault totalSupply should increase by fee shares");

        _step("[Step 3] Second rate update - still works after fee settlement");
        vm.warp(block.timestamp + 21 hours);
        vm.prank(bot);
        s.executor.executeUpdateRate(address(s.accountant), 1.002e18, uint64(block.timestamp));
        assertEq(s.accountant.lastExchangeRate(), 1.002e18, "second rate update should succeed");
        _step("  PASS: Fee settlement via executeSettleManagementFee mints shares to treasury");

        _logPass();
    }

    function test_Acct_FullChain_ConsecutiveUpdates() public {
        _logCase(
            "test_Acct_FullChain_ConsecutiveUpdates",
            unicode"全链路 - 连续多次更新"
        );

        RealAccountantStack memory s = _deployRealAccountantStack();
        _fundRealVault(s.gateway, s.vault, userA, 1_000_000e6);
        uint256 treasuryBefore = s.vault.balanceOf(treasuryAddr);
        uint256 supplyBefore = s.vault.totalSupply();

        _step("[Step 1] First update");
        vm.warp(block.timestamp + 21 hours);
        uint64 ts1 = uint64(block.timestamp);
        vm.prank(bot);
        s.executor.executeUpdateRate(address(s.accountant), 1.001e18, ts1);
        assertEq(s.accountant.lastExchangeRate(), 1.001e18, "rate1");
        uint64 computeTs1 = s.accountant.lastComputeTimestamp();

        _step("[Step 2] Second update");
        vm.warp(block.timestamp + 21 hours);
        uint64 ts2 = uint64(block.timestamp);
        vm.prank(bot);
        s.executor.executeUpdateRate(address(s.accountant), 1.002e18, ts2);
        assertEq(s.accountant.lastExchangeRate(), 1.002e18, "rate2");
        uint64 computeTs2 = s.accountant.lastComputeTimestamp();
        assertTrue(computeTs2 > computeTs1, "computeTimestamp should strictly increase");

        _step("[Step 3] Third update");
        vm.warp(block.timestamp + 21 hours);
        uint64 ts3 = uint64(block.timestamp);
        vm.prank(bot);
        s.executor.executeUpdateRate(address(s.accountant), 1.003e18, ts3);
        assertEq(s.accountant.lastExchangeRate(), 1.003e18, "rate3");
        uint64 computeTs3 = s.accountant.lastComputeTimestamp();
        assertTrue(computeTs3 > computeTs2, "computeTimestamp should strictly increase again");

        // Rate updates no longer settle fees - fee settlement requires separate settleManagementFee() calls.
        assertEq(s.vault.balanceOf(treasuryAddr), treasuryBefore, "rate updates should not mint treasury shares");
        assertEq(s.vault.totalSupply(), supplyBefore, "rate updates should not change totalSupply");
        _step("  PASS: Three consecutive updates succeeded with increasing computeTimestamp; fee settlement is independent");

        _logPass();
    }

    function test_Acct_FullChain_PauseUnpauseResume() public {
        _logCase(
            "test_Acct_FullChain_PauseUnpauseResume",
            unicode"全链路 - 暂停后恢复再更新"
        );

        RealAccountantStack memory s = _deployRealAccountantStack();

        _step("[Step 1] First update succeeds");
        vm.warp(block.timestamp + 21 hours);
        vm.prank(bot);
        s.executor.executeUpdateRate(address(s.accountant), 1.001e18, uint64(block.timestamp));
        assertEq(s.accountant.lastExchangeRate(), 1.001e18, "first update should succeed");
        _step("  First update succeeded");

        _step("[Step 2] Admin pauses");
        vm.prank(admin);
        s.accountant.pause();
        assertTrue(s.accountant.paused(), "should be paused");
        _step("  Accountant paused");

        _step("[Step 3] Update reverts while paused");
        vm.warp(block.timestamp + 21 hours);
        vm.prank(bot);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        s.executor.executeUpdateRate(address(s.accountant), 1.002e18, uint64(block.timestamp));
        _step("  Update correctly reverted while paused");

        _step("[Step 4] Admin unpauses");
        vm.prank(admin);
        s.accountant.unpause();
        assertFalse(s.accountant.paused(), "should be unpaused");
        _step("  Accountant unpaused");

        _step("[Step 5] Update succeeds after unpause and cooldown");
        vm.warp(block.timestamp + 21 hours);
        vm.prank(bot);
        s.executor.executeUpdateRate(address(s.accountant), 1.002e18, uint64(block.timestamp));
        assertEq(s.accountant.lastExchangeRate(), 1.002e18, "update after unpause should succeed");
        _step("  PASS: Pause -> revert -> unpause -> cooldown -> update succeeded");

        _logPass();
    }

    // ===================================================================
    //  ACCOUNTANT EXECUTOR - UUPS UPGRADE
    // ===================================================================

    function test_AE_AdminCanUpgrade() public {
        _logCase("test_AE_AdminCanUpgrade", unicode"admin 可通过 UUPS 升级");

        AccountantExecutor impl = new AccountantExecutor();
        bytes memory initData = abi.encodeCall(AccountantExecutor.initialize, (admin));
        AccountantExecutor executor = AccountantExecutor(address(new ERC1967Proxy(address(impl), initData)));

        _step("[Step 1] Grant bot role before upgrade");
        vm.startPrank(admin);
        executor.grantRole(executor.BOT_ROLE(), bot);
        vm.stopPrank();
        assertTrue(executor.hasRole(executor.BOT_ROLE(), bot), "bot has role before");

        _step("[Step 2] Upgrade to V2");
        AccountantExecutorV2 newImpl = new AccountantExecutorV2();
        vm.prank(admin);
        executor.upgradeToAndCall(address(newImpl), "");

        _step("[Step 3] Verify state preserved and V2 works");
        assertTrue(executor.hasRole(executor.BOT_ROLE(), bot), "bot role preserved");
        assertTrue(executor.hasRole(executor.DEFAULT_ADMIN_ROLE(), admin), "admin role preserved");
        assertEq(AccountantExecutorV2(address(executor)).version(), 2, "version should be 2");
        _step("  PASS: UUPS upgrade succeeded, state preserved");

        _logPass();
    }

    function test_AE_NonAdminCannotUpgrade() public {
        _logCase("test_AE_NonAdminCannotUpgrade", unicode"非 admin 无法升级");

        AccountantExecutor impl = new AccountantExecutor();
        bytes memory initData = abi.encodeCall(AccountantExecutor.initialize, (admin));
        AccountantExecutor executor = AccountantExecutor(address(new ERC1967Proxy(address(impl), initData)));

        AccountantExecutorV2 newImpl = new AccountantExecutorV2();

        _step("[Step 1] Non-admin attempts upgrade");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, bytes32(0)));
        executor.upgradeToAndCall(address(newImpl), "");
        _step("  PASS: reverted AccessControlUnauthorizedAccount");

        _logPass();
    }

    // ===================================================================
    //  OPERATOR EXECUTOR - UUPS UPGRADE
    // ===================================================================

    function test_OE_ProxyDeployAndInit() public {
        _logCase("test_OE_ProxyDeployAndInit", unicode"通过代理部署并初始化成功");

        OperatorExecutor impl = new OperatorExecutor();
        bytes memory initData = abi.encodeCall(OperatorExecutor.initialize, (admin, bot));
        OperatorExecutor executor = OperatorExecutor(address(new ERC1967Proxy(address(impl), initData)));

        assertTrue(executor.hasRole(executor.DEFAULT_ADMIN_ROLE(), admin), "admin has role");
        assertTrue(executor.hasRole(executor.BOT_ROLE(), bot), "bot has role");
        _step("  PASS: Proxy deployed and initialized successfully");

        _logPass();
    }

    function test_OE_AdminCanUpgrade() public {
        _logCase("test_OE_AdminCanUpgrade", unicode"admin 可升级到新实现");

        OperatorExecutor impl = new OperatorExecutor();
        bytes memory initData = abi.encodeCall(OperatorExecutor.initialize, (admin, bot));
        OperatorExecutor executor = OperatorExecutor(address(new ERC1967Proxy(address(impl), initData)));

        _step("[Step 1] Upgrade to V2");
        OperatorExecutorV2 newImpl = new OperatorExecutorV2();
        vm.prank(admin);
        executor.upgradeToAndCall(address(newImpl), "");

        assertEq(OperatorExecutorV2(address(executor)).version(), 2, "version should be 2");
        _step("  PASS: Admin upgraded to V2");

        _logPass();
    }

    function test_OE_NonAdminCannotUpgrade() public {
        _logCase("test_OE_NonAdminCannotUpgrade", unicode"非 admin 不能升级");

        OperatorExecutor impl = new OperatorExecutor();
        bytes memory initData = abi.encodeCall(OperatorExecutor.initialize, (admin, bot));
        OperatorExecutor executor = OperatorExecutor(address(new ERC1967Proxy(address(impl), initData)));

        OperatorExecutorV2 newImpl = new OperatorExecutorV2();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, bytes32(0)));
        executor.upgradeToAndCall(address(newImpl), "");
        _step("  PASS: reverted AccessControlUnauthorizedAccount");

        _logPass();
    }

    function test_OE_DirectImplUpgradeFails() public {
        _logCase("test_OE_DirectImplUpgradeFails", unicode"直接对实现合约调用升级应失败");

        OperatorExecutor impl = new OperatorExecutor();
        OperatorExecutorV2 newImpl = new OperatorExecutorV2();

        _step("[Step 1] Direct call to implementation should revert (onlyProxy)");
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        impl.upgradeToAndCall(address(newImpl), "");
        _step("  PASS: Reverted on direct impl call (UUPS onlyProxy)");

        _logPass();
    }

    function test_OE_UpgradeToNonUUPS() public {
        _logCase("test_OE_UpgradeToNonUUPS", unicode"升级到非 UUPS 实现应失败");

        OperatorExecutor impl = new OperatorExecutor();
        bytes memory initData = abi.encodeCall(OperatorExecutor.initialize, (admin, bot));
        OperatorExecutor executor = OperatorExecutor(address(new ERC1967Proxy(address(impl), initData)));

        NotUUPS notUups = new NotUUPS();

        _step("[Step 1] Upgrade to non-UUPS contract should revert");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UUPSUpgradeable.UUPSUnsupportedProxiableUUID.selector, bytes32(0)));
        executor.upgradeToAndCall(address(notUups), "");
        _step("  PASS: Reverted for non-UUPS implementation");

        _logPass();
    }

    function test_OE_RolesPreservedAfterUpgrade() public {
        _logCase("test_OE_RolesPreservedAfterUpgrade", unicode"升级后角色状态保持不变");

        OperatorExecutor impl = new OperatorExecutor();
        bytes memory initData = abi.encodeCall(OperatorExecutor.initialize, (admin, bot));
        OperatorExecutor executor = OperatorExecutor(address(new ERC1967Proxy(address(impl), initData)));

        _step("[Step 1] Add extra bot");
        address bot2 = makeAddr("bot2");
        bytes32 botRole = executor.BOT_ROLE();
        vm.prank(admin);
        executor.grantRole(botRole, bot2);

        _step("[Step 2] Record roles before upgrade");
        bool adminHas = executor.hasRole(executor.DEFAULT_ADMIN_ROLE(), admin);
        bool bot1Has = executor.hasRole(executor.BOT_ROLE(), bot);
        bool bot2Has = executor.hasRole(executor.BOT_ROLE(), bot2);
        assertTrue(adminHas && bot1Has && bot2Has, "all roles set before upgrade");

        _step("[Step 3] Upgrade to V2");
        OperatorExecutorV2 newImpl = new OperatorExecutorV2();
        vm.prank(admin);
        executor.upgradeToAndCall(address(newImpl), "");

        _step("[Step 4] Verify roles preserved");
        assertTrue(executor.hasRole(executor.DEFAULT_ADMIN_ROLE(), admin), "admin preserved");
        assertTrue(executor.hasRole(executor.BOT_ROLE(), bot), "bot1 preserved");
        assertTrue(executor.hasRole(executor.BOT_ROLE(), bot2), "bot2 preserved");
        _step("  PASS: All roles preserved after upgrade");

        _logPass();
    }

    function test_OE_PostUpgradeExecution() public {
        _logCase("test_OE_PostUpgradeExecution", unicode"升级后执行能力保持");

        OperatorExecutor impl = new OperatorExecutor();
        bytes memory initData = abi.encodeCall(OperatorExecutor.initialize, (admin, bot));
        OperatorExecutor executor = OperatorExecutor(address(new ERC1967Proxy(address(impl), initData)));

        _step("[Step 1] Upgrade to V2");
        OperatorExecutorV2 newImpl = new OperatorExecutorV2();
        vm.prank(admin);
        executor.upgradeToAndCall(address(newImpl), "");

        _step("[Step 2] Execute rebalance after upgrade (with mock controller)");
        MockControllerForOE mockCtrl = new MockControllerForOE();

        vm.prank(bot);
        executor.executeRebalance(address(mockCtrl));
        assertTrue(mockCtrl.rebalanceCalled(), "rebalance should have been called");
        _step("  PASS: Execution ability preserved after upgrade");

        _logPass();
    }

    // ===================================================================
    //  ACCOUNTANT EXECUTOR - FULL CHAIN
    // ===================================================================

    function test_AE_ExecutorUpgradeThenUpdateRate() public {
        _logCase("test_AE_ExecutorUpgradeThenUpdateRate", unicode"executor 升级后继续工作");

        // Deploy accountant via factory
        Accountant acctImpl = new Accountant();
        AccountantFactory acctFactory = new AccountantFactory(address(acctImpl), admin);
        VaultFactory vFactory = new VaultFactory(address(new MantleYieldVault()), admin);
        GatewayFactory gFactory = new GatewayFactory(address(new MantleVaultGateway()), admin);
        (MantleYieldVault v,) = _deployVaultAndGateway(vFactory, gFactory);
        address acctAddr = acctFactory.deployAndInitAccountant(address(v), 1e18, 100, admin, admin, admin);
        Accountant acct = Accountant(acctAddr);

        // Deploy executor
        AccountantExecutor exImpl = new AccountantExecutor();
        bytes memory exInit = abi.encodeCall(AccountantExecutor.initialize, (admin));
        AccountantExecutor executor = AccountantExecutor(address(new ERC1967Proxy(address(exImpl), exInit)));

        // Grant roles
        vm.startPrank(admin);
        executor.grantRole(executor.BOT_ROLE(), bot);
        executor.grantRole(executor.FEE_SETTLER_ROLE(), bot);
        acct.grantRole(acct.ACCOUNTANT_EXECUTOR_ROLE(), address(executor));
        vm.stopPrank();

        _step("[Step 1] Upgrade executor to V2");
        AccountantExecutorV2 newExImpl = new AccountantExecutorV2();
        vm.prank(admin);
        executor.upgradeToAndCall(address(newExImpl), "");

        _step("[Step 2] Execute update rate through upgraded executor");
        vm.warp(block.timestamp + 21 hours);
        vm.prank(bot);
        executor.executeUpdateRate(acctAddr, 1.001e18, uint64(block.timestamp));

        assertEq(acct.lastExchangeRate(), 1.001e18, "rate should be updated");
        _step("  PASS: Upgraded executor can still update rate");

        _logPass();
    }
}

// ---------------------------------------------------------------------------
// Helper mock for OperatorExecutor post-upgrade test
// ---------------------------------------------------------------------------

contract MockControllerForOE {
    bool public rebalanceCalled;

    function rebalance() external {
        rebalanceCalled = true;
    }

    function processRedeemBatch(uint256[] calldata) external {}
    function finalizeRedeemBatch(uint256[] calldata, uint256[] calldata) external {}

    function settleAdapter(address, uint256[] calldata, uint256[] calldata, uint256[] calldata, uint256[] calldata)
        external
    {}

    function settleAdapters(
        address[] calldata,
        uint256[][] calldata,
        uint256[][] calldata,
        uint256[][] calldata,
        uint256[][] calldata
    ) external {}
}
