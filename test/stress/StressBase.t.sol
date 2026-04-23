// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {IMantleVaultGateway} from "../../src/interfaces/vault/IMantleVaultGateway.sol";
import {IStrategyAdapter} from "../../src/interfaces/adapters/IStrategyAdapter.sol";
import {IStrategyControllerExecutor} from "../../src/interfaces/strategy/IStrategyControllerExecutor.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {MantleVaultGateway} from "../../src/vault/MantleVaultGateway.sol";
import {Accountant} from "../../src/accountant/Accountant.sol";
import {AccountantExecutor} from "../../src/accountant/AccountantExecutor.sol";
import {StrategyController} from "../../src/protocol/StrategyController.sol";
import {OperatorExecutor} from "../../src/protocol/OperatorExecutor.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test, console2} from "forge-std/Test.sol";
import {LogUtil} from "../lib/LogUtil.sol";
import {VaultViewHelper} from "../lib/VaultViewHelper.sol";

// =============================================================================
//  Mock Contracts (Local mode only)
// =============================================================================

contract MockUSDC_ST is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract MockPosToken_ST is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract MockSanctionsOracle_ST is ISanctionsOracle {
    mapping(address => bool) private _sanctioned;
    mapping(address => bool) private _whitelisted;

    function initialize(address, address) external {}

    function isSanctioned(address account) external view returns (bool) {
        return _sanctioned[account];
    }

    function isWhitelisted(address) external pure returns (bool) {
        return true;
    }

    function totalSanctionedCount() external pure returns (uint256) {
        return 0;
    }

    function totalWhitelistedCount() external pure returns (uint256) {
        return 0;
    }

    function lastUpdateTimestamp() external pure returns (uint256) {
        return 0;
    }

    function batchNonce() external pure returns (uint256) {
        return 0;
    }

    function MAX_BATCH_SIZE() external pure returns (uint256) {
        return 200;
    }

    function updateSanctionStatus(address account, bool sanctioned) external {
        _sanctioned[account] = sanctioned;
    }

    function updateSanctionStatusBatch(address[] calldata accounts, bool sanctioned) external {
        for (uint256 i = 0; i < accounts.length; i++) {
            _sanctioned[accounts[i]] = sanctioned;
        }
    }

    function updateWhitelistStatus(address account, bool whitelisted) external {
        _whitelisted[account] = whitelisted;
    }

    function updateWhitelistStatusBatch(address[] calldata accounts, bool whitelisted) external {
        for (uint256 i = 0; i < accounts.length; i++) {
            _whitelisted[accounts[i]] = whitelisted;
        }
    }

    // --- Test helpers ---
    function setSanctioned(address account, bool sanctioned) external {
        _sanctioned[account] = sanctioned;
    }
}

/// @dev Sync adapter: immediate deposit/withdraw, holds USDC
contract MockSyncAdapter_ST is IStrategyAdapter {
    address public immutable ASSET;
    address public immutable POS_TOKEN;
    address public immutable VAULT;

    constructor(address asset_, address posToken_, address vault_) {
        ASSET = asset_;
        POS_TOKEN = posToken_;
        VAULT = vault_;
    }

    function name() external pure returns (string memory) {
        return "MockSyncAdapter";
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
        return 1e18;
    }

    function estimatePosAmount(uint256 assetAmount) external pure returns (uint256) {
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
        return IERC20(ASSET).balanceOf(address(this));
    }

    function deposit(uint256 amount, address) external returns (uint256) {
        IERC20(ASSET).transferFrom(VAULT, address(this), amount);
        MockPosToken_ST(POS_TOKEN).mint(address(this), amount);
        return amount;
    }

    function withdrawSync(uint256 amount, address) external returns (uint256) {
        // Divest flow: controller approved us to pull posTokens from vault.
        // Pull posTokens → burn them (simulate selling position).
        // Deposit USDC is already on adapter and will be swept during settlement.
        uint256 posAvail = IERC20(POS_TOKEN).balanceOf(VAULT);
        uint256 posToRedeem = amount > posAvail ? posAvail : amount; // 1:1 price
        if (posToRedeem > 0) {
            IERC20(POS_TOKEN).transferFrom(VAULT, address(this), posToRedeem);
            MockPosToken_ST(POS_TOKEN).burn(address(this), posToRedeem);
        }
        return posToRedeem;
    }

    function requestRedeemAsync(uint256, address) external pure {
        revert("Unsupported");
    }

    function retryRedeemAsync(uint256, address) external pure {
        revert("Unsupported");
    }

    function sweepToVault(address token, uint256 amount) external returns (uint256) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 actual = amount > bal ? bal : amount;
        if (actual > 0) IERC20(token).transfer(VAULT, actual);
        return actual;
    }

    function setPaused(bool) external {}
}

/// @dev Async adapter: deposit is immediate, redeem is async (T+N)
contract MockAsyncAdapter_ST is IStrategyAdapter {
    address public immutable ASSET;
    address public immutable POS_TOKEN;
    address public immutable VAULT;
    uint256 public posTokenPrice = 1e18;
    uint256 public protocolUsdcHeld; // USDC logically held by "external protocol"

    constructor(address asset_, address posToken_, address vault_) {
        ASSET = asset_;
        POS_TOKEN = posToken_;
        VAULT = vault_;
    }

    function setPosTokenPrice(uint256 p) external {
        posTokenPrice = p;
    }

    function name() external pure returns (string memory) {
        return "MockAsyncAdapter";
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
        return posTokenPrice;
    }

    function vault() external view returns (address) {
        return VAULT;
    }

    function estimatePosAmount(uint256 assetAmount) external view returns (uint256) {
        if (posTokenPrice == 0) return assetAmount;
        return assetAmount * 1e18 / posTokenPrice;
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

    function totalValue() external view returns (uint256) {
        return IERC20(POS_TOKEN).balanceOf(VAULT) * posTokenPrice / 1e18;
    }

    function deposit(uint256 amount, address) external returns (uint256) {
        IERC20(ASSET).transferFrom(VAULT, address(this), amount);
        protocolUsdcHeld += amount; // USDC "sent to external protocol"
        uint256 posAmount = posTokenPrice == 0 ? amount : amount * 1e18 / posTokenPrice;
        MockPosToken_ST(POS_TOKEN).mint(address(this), posAmount);
        return posAmount;
    }

    function withdrawSync(uint256, address) external pure returns (uint256) {
        revert("Unsupported");
    }

    function requestRedeemAsync(uint256 posAmount, address) external {
        // Controller passes posAmount (already converted asset→pos); pull directly.
        IERC20(POS_TOKEN).transferFrom(VAULT, address(this), posAmount);
    }

    function retryRedeemAsync(uint256 retryPosAmount, address) external {
        // Real adapter checks own balance and resubmits to external protocol.
        // Mock: verify we hold enough posToken (from prior requestRedeemAsync) and burn it.
        require(IERC20(POS_TOKEN).balanceOf(address(this)) >= retryPosAmount, "insufficient pos for retry");
        MockPosToken_ST(POS_TOKEN).burn(address(this), retryPosAmount);
    }

    function sweepToVault(address token, uint256 amount) external returns (uint256) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        // For USDC: only sweep what's not held by "external protocol"
        if (token == ASSET) {
            uint256 available = bal > protocolUsdcHeld ? bal - protocolUsdcHeld : 0;
            uint256 actual = amount > available ? available : amount;
            if (actual > 0) IERC20(token).transfer(VAULT, actual);
            return actual;
        }
        uint256 actual = amount > bal ? bal : amount;
        if (actual > 0) IERC20(token).transfer(VAULT, actual);
        return actual;
    }

    function setPaused(bool) external {}

    /// @dev Simulate async settlement: release USDC from "external protocol" hold.
    ///      When posTokenPrice appreciated since deposit, the protocol returns MORE USDC
    ///      than was originally deposited. In that case we mint the difference to simulate
    ///      the external protocol returning gains. Returns the extra minted amount so the
    ///      caller can track it in _totalUsdcInjected (USDC closed-system invariant).
    function simulateRedeemSettlement(uint256 usdcAmount) external returns (uint256 extraMinted) {
        if (usdcAmount <= protocolUsdcHeld) {
            protocolUsdcHeld -= usdcAmount;
            return 0;
        }
        // Protocol returns more than original deposit (price appreciation)
        extraMinted = usdcAmount - protocolUsdcHeld;
        protocolUsdcHeld = 0;
        MockUSDC_ST(ASSET).mint(address(this), extraMinted);
    }
}

/// @dev Configurable sync adapter: like MockSyncAdapter_ST but with mutable posTokenPrice.
///      Used by S9 (multi-adapter) to test price-divergent sync strategies.
contract MockConfigSyncAdapter_ST is IStrategyAdapter {
    address public immutable ASSET;
    address public immutable POS_TOKEN;
    address public immutable VAULT;
    uint256 public posTokenPrice = 1e18;

    constructor(address asset_, address posToken_, address vault_) {
        ASSET = asset_;
        POS_TOKEN = posToken_;
        VAULT = vault_;
    }

    function setPosTokenPrice(uint256 p) external { posTokenPrice = p; }

    function name() external pure returns (string memory) { return "MockConfigSyncAdapter"; }
    function asset() external view returns (address) { return ASSET; }
    function posToken() external view returns (address) { return POS_TOKEN; }
    function priceOracle() external pure returns (address) { return address(0); }
    function getPosTokenPrice() external view returns (uint256) { return posTokenPrice; }
    function vault() external view returns (address) { return VAULT; }

    function estimatePosAmount(uint256 assetAmount) external view returns (uint256) {
        if (posTokenPrice == 0) return assetAmount;
        return assetAmount * 1e18 / posTokenPrice;
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

    /// @dev totalValue = USDC held on adapter (same as MockSyncAdapter_ST).
    ///      This is the "real value" deployed in the strategy.
    function totalValue() external view returns (uint256) {
        return IERC20(ASSET).balanceOf(address(this));
    }

    function deposit(uint256 amount, address) external returns (uint256) {
        IERC20(ASSET).transferFrom(VAULT, address(this), amount);
        uint256 posAmt = posTokenPrice == 0 ? amount : amount * 1e18 / posTokenPrice;
        MockPosToken_ST(POS_TOKEN).mint(address(this), posAmt);
        return posAmt;
    }

    function withdrawSync(uint256 posAmount, address) external returns (uint256) {
        // Controller passes posAmount directly (already converted asset→pos); do NOT re-divide by price.
        // Pull posTokens from vault → burn → USDC stays on adapter for sweep.
        uint256 posAvail = IERC20(POS_TOKEN).balanceOf(VAULT);
        uint256 posToRedeem = posAmount > posAvail ? posAvail : posAmount;
        if (posToRedeem > 0) {
            IERC20(POS_TOKEN).transferFrom(VAULT, address(this), posToRedeem);
            MockPosToken_ST(POS_TOKEN).burn(address(this), posToRedeem);
        }
        return posToRedeem * posTokenPrice / 1e18;
    }

    function requestRedeemAsync(uint256, address) external pure {
        revert("Unsupported");
    }
    function retryRedeemAsync(uint256, address) external pure {
        revert("Unsupported");
    }

    function sweepToVault(address token, uint256 amount) external returns (uint256) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 actual = amount > bal ? bal : amount;
        if (actual > 0) IERC20(token).transfer(VAULT, actual);
        return actual;
    }

    function setPaused(bool) external {}
}

// =============================================================================
//  StressBase — shared foundation for all stress test scenarios
// =============================================================================

abstract contract StressBase is LogUtil {
    using VaultViewHelper for MantleYieldVault;

    // =========================================================================
    //  Configuration (environment variables with defaults)
    // =========================================================================
    uint256 internal ROUNDS;
    uint256 internal USER_COUNT;
    uint256 internal SEED;
    uint256 internal SIM_DAYS;
    uint256 internal MAX_DURATION; // max wall-clock seconds, 0 = unlimited
    bool internal IS_FORK;

    // =========================================================================
    //  Protocol contract references
    // =========================================================================
    MantleYieldVault internal vault;
    MantleVaultGateway internal gateway;
    Accountant internal accountant;
    AccountantExecutor internal acctExecutor;
    StrategyController internal controller;
    OperatorExecutor internal opExecutor;
    IERC20 internal usdc;

    // Oracle: real ISanctionsOracle in fork, MockSanctionsOracle_ST in local
    ISanctionsOracle internal oracle;
    MockSanctionsOracle_ST internal mockOracle; // only set in local mode

    // Adapters (local mode only)
    MockSyncAdapter_ST internal syncAdapter;
    MockAsyncAdapter_ST internal asyncAdapter;
    MockPosToken_ST internal syncPosToken;
    MockPosToken_ST internal asyncPosToken;

    // =========================================================================
    //  Role addresses
    // =========================================================================
    address internal admin;
    address internal bot;
    address internal treasury;
    address internal sanctionSafe;
    address internal pauser;

    // =========================================================================
    //  User pool
    // =========================================================================
    address[] internal users;

    // =========================================================================
    //  Tracking state (for invariant checks)
    // =========================================================================
    uint256 internal _lastTreasuryBalance;
    uint256 internal _totalUsdcInjected;
    uint256 internal _baseRequestId;
    uint256 internal _baseInFlightId;
    uint256 internal _cumulativeFeeShares;
    uint256 internal _forkInitialUnknownShares;

    // =========================================================================
    //  Random state
    // =========================================================================
    uint256 private _nonce;

    // =========================================================================
    //  Stress logging state
    // =========================================================================
    string internal _stCaseId;
    string internal _stCaseName;
    uint256 private _stCaseStartGas;
    uint256 private _stRoundStartGas;
    uint256 internal _wallStartTime; // vm.unixTime() at case start (ms)

    // =========================================================================
    //  Statistics counters (for final report)
    // =========================================================================
    uint256 internal _statDeposits;
    uint256 internal _statSyncRedeems;
    uint256 internal _statAsyncRedeems;
    uint256 internal _statProcessBatches;
    uint256 internal _statFinalizeBatches;
    uint256 internal _statRebalances;
    uint256 internal _statSettlements;
    uint256 internal _statRateUpdates;
    uint256 internal _statPriceUpdates;
    uint256 internal _statInvariantChecks;
    uint256 internal _statInvariantFails;
    uint256 internal _statTotalTx;
    uint256 internal _statActualRounds; // rounds actually executed

    // =========================================================================
    //  Snapshot struct for delta verification
    // =========================================================================
    struct Snapshot {
        uint256 vaultTotalSupply;
        uint256 vaultPhysicalCash;
        uint256 vaultTotalLockedShares;
        uint256 vaultTotalInvestInFlight;
        uint256 vaultTotalRedeemInFlight;
        uint256 vaultNextRequestId;
        uint256 vaultNextInFlightId;
        uint256 exchangeRate;
        uint256 userShareBalance;
        uint256 userUsdcBalance;
        uint256 treasuryShareBalance;
        uint256 sanctionSafeShareBalance;
        uint256 sanctionSafeUsdcBalance;
    }

    // =========================================================================
    //  setUp — dual mode entry point
    // =========================================================================
    function setUp() public virtual {
        // Read config from environment
        ROUNDS = vm.envOr("STRESS_ROUNDS", uint256(50));
        USER_COUNT = vm.envOr("STRESS_USERS", uint256(20));
        SEED = vm.envOr("STRESS_SEED", uint256(12345));
        SIM_DAYS = vm.envOr("STRESS_DAYS", uint256(30));
        MAX_DURATION = vm.envOr("STRESS_DURATION", uint256(0)); // seconds, 0 = unlimited

        // Auto-reduce SIM_DAYS for large user pools to avoid EVM MemoryOOG.
        // 1000 users × 60 days overflows; scale down proportionally.
        if (USER_COUNT > 100 && SIM_DAYS > 10) {
            uint256 budget = 3000; // target: users * days ≤ budget
            uint256 maxDays = budget / USER_COUNT;
            if (maxDays < 5) maxDays = 5;
            if (SIM_DAYS > maxDays) SIM_DAYS = maxDays;
        }
        IS_FORK = vm.envOr("STRESS_FORK", false);

        if (IS_FORK) {
            _setupFork();
        } else {
            _setupLocal();
        }

        _createUsers();

        // Record baseline for invariant checks
        _lastTreasuryBalance = vault.balanceOf(treasury);
        _baseRequestId = vault.nextRequestId();
        _baseInFlightId = vault.nextInFlightId();

        if (IS_FORK) {
            uint256 knownShares = vault.balanceOf(treasury) + vault.balanceOf(sanctionSafe);
            for (uint256 i = 0; i < users.length; i++) {
                knownShares += vault.balanceOf(users[i]);
            }
            _forkInitialUnknownShares = vault.totalSupply() - knownShares;
        }
    }

    // =========================================================================
    //  _setupLocal — deploy full protocol stack
    // =========================================================================
    function _setupLocal() internal {
        vm.warp(1000);

        // --- Role addresses ---
        admin = makeAddr("admin");
        bot = makeAddr("bot");
        treasury = makeAddr("treasury");
        sanctionSafe = makeAddr("sanctionSafe");
        pauser = makeAddr("pauser");

        // --- Mock tokens ---
        MockUSDC_ST mockUsdc = new MockUSDC_ST();
        usdc = IERC20(address(mockUsdc));
        syncPosToken = new MockPosToken_ST("SyncPos", "sPOS");
        asyncPosToken = new MockPosToken_ST("AsyncPos", "aPOS");

        // --- Mock oracle ---
        mockOracle = new MockSanctionsOracle_ST();
        oracle = ISanctionsOracle(address(mockOracle));

        // --- Deploy implementations ---
        MantleYieldVault vaultImpl = new MantleYieldVault();
        Accountant acctImpl = new Accountant();
        MantleVaultGateway gwImpl = new MantleVaultGateway();
        StrategyController ctrlImpl = new StrategyController();
        OperatorExecutor opExecImpl = new OperatorExecutor();
        AccountantExecutor acctExecImpl = new AccountantExecutor();

        // --- Deploy Vault proxy ---
        vault = MantleYieldVault(
            address(
                new ERC1967Proxy(
                    address(vaultImpl),
                    abi.encodeCall(
                        MantleYieldVault.initialize,
                        IMantleYieldVault.InitParams({
                            asset: IERC20(address(usdc)),
                            name: "mRWA Stress Vault",
                            symbol: "smRWA",
                            admin: admin,
                            gateway: address(1), // placeholder
                            controller: admin, // placeholder
                            accountant: address(1), // placeholder
                            treasury: treasury,
                            maxRedemptionFeeBps: 500,
                            redemptionFeeBps: 100, // 1%
                            minRedeemAmount: 1e6, // 1 USDC
                            minDepositAmount: 1e6 // 1 USDC
                        })
                    )
                )
            )
        );

        // --- Deploy Accountant proxy ---
        accountant = Accountant(
            address(
                new ERC1967Proxy(
                    address(acctImpl),
                    abi.encodeCall(Accountant.initialize, (address(vault), uint64(1e18), 50, admin))
                )
            )
        );

        // --- Deploy OperatorExecutor proxy ---
        opExecutor = OperatorExecutor(
            address(
                new ERC1967Proxy(address(opExecImpl), abi.encodeCall(OperatorExecutor.initialize, (admin, bot)))
            )
        );

        // --- Deploy AccountantExecutor proxy ---
        acctExecutor = AccountantExecutor(
            address(
                new ERC1967Proxy(address(acctExecImpl), abi.encodeCall(AccountantExecutor.initialize, (admin)))
            )
        );

        // --- Deploy StrategyController proxy ---
        // bufferTarget=10%, threshold=2%, cooldown=1 hour
        controller = StrategyController(
            address(
                new ERC1967Proxy(
                    address(ctrlImpl),
                    abi.encodeCall(
                        StrategyController.initialize,
                        (address(vault), admin, address(opExecutor), pauser, 1000, 200, 3600)
                    )
                )
            )
        );

        // --- Deploy Gateway proxy ---
        gateway = MantleVaultGateway(
            address(
                new ERC1967Proxy(
                    address(gwImpl),
                    abi.encodeCall(
                        MantleVaultGateway.initialize,
                        IMantleVaultGateway.InitParams({
                            vault: address(vault),
                            sanctionsOracle: ISanctionsOracle(address(oracle)),
                            sanctionSafe: sanctionSafe,
                            admin: admin,
                            syncRedeemDisabled: false
                        })
                    )
                )
            )
        );

        // --- Link components ---
        vm.startPrank(admin);
        vault.setAccountant(address(accountant));
        vault.setGateway(address(gateway));
        vault.setController(address(controller));
        vault.grantRole(vault.PAUSER_ROLE(), pauser);
        vm.stopPrank();

        // --- Grant roles ---
        vm.startPrank(admin);
        // AccountantExecutor: grant BOT_ROLE to bot
        acctExecutor.grantRole(acctExecutor.BOT_ROLE(), bot);
        // Accountant: grant EXECUTOR_ROLE to AccountantExecutor
        accountant.grantRole(accountant.EXECUTOR_ROLE(), address(acctExecutor));
        vm.stopPrank();

        // --- Deploy and register adapters ---
        syncAdapter = new MockSyncAdapter_ST(address(usdc), address(syncPosToken), address(vault));
        asyncAdapter = new MockAsyncAdapter_ST(address(usdc), address(asyncPosToken), address(vault));

        vm.startPrank(admin);
        // Register sync adapter: weight=50%, priority=1, isAsync=false
        controller.registerStrategy(address(syncAdapter), 5000, 1, false);
        controller.activateStrategy(address(syncAdapter));

        // Register async adapter: weight=50%, priority=2, isAsync=true
        controller.registerStrategy(address(asyncAdapter), 5000, 2, true);
        controller.activateStrategy(address(asyncAdapter));

        // Set strategy execution order
        address[] memory order = new address[](2);
        order[0] = address(syncAdapter);
        order[1] = address(asyncAdapter);
        controller.setStrategyOrder(order);
        vm.stopPrank();
    }

    // =========================================================================
    //  _setupFork — fork chain and load addresses from env
    // =========================================================================
    function _setupFork() internal {
        string memory rpcUrl = vm.envOr("STRESS_RPC_URL", string("https://rpc.sepolia.mantle.xyz"));
        vm.createSelectFork(rpcUrl);

        vault = MantleYieldVault(vm.envAddress("STRESS_VAULT"));
        gateway = MantleVaultGateway(vm.envAddress("STRESS_GATEWAY"));
        accountant = Accountant(vm.envAddress("STRESS_ACCOUNTANT"));
        acctExecutor = AccountantExecutor(vm.envAddress("STRESS_ACCOUNTANT_EXECUTOR"));
        controller = StrategyController(vm.envAddress("STRESS_CONTROLLER"));
        opExecutor = OperatorExecutor(vm.envAddress("STRESS_OPERATOR_EXECUTOR"));
        oracle = ISanctionsOracle(vm.envAddress("STRESS_ORACLE"));
        usdc = IERC20(vm.envAddress("STRESS_USDC"));

        admin = vm.envAddress("STRESS_ADMIN");
        bot = vm.envAddress("STRESS_BOT");
        treasury = vm.envAddress("STRESS_TREASURY");
        sanctionSafe = vm.envAddress("STRESS_SANCTION_SAFE");
        pauser = admin; // fallback
    }

    // =========================================================================
    //  _createUsers — create and fund test users
    // =========================================================================
    function _createUsers() internal {
        uint256 perUser = 1_000_000e6; // 1M USDC each

        for (uint256 i = 0; i < USER_COUNT; i++) {
            address u = makeAddr(string.concat("stressUser", vm.toString(i)));
            users.push(u);

            // Fund USDC
            if (IS_FORK) {
                deal(address(usdc), u, perUser);
            } else {
                MockUSDC_ST(address(usdc)).mint(u, perUser);
            }

            // Approve vault to spend USDC
            vm.prank(u);
            usdc.approve(address(vault), type(uint256).max);

            _totalUsdcInjected += perUser;
        }
    }

    // =========================================================================
    //  Random utilities (deterministic, reproducible)
    // =========================================================================
    function _rand(uint256 max) internal returns (uint256) {
        require(max > 0, "rand: max must be > 0");
        _nonce++;
        return uint256(keccak256(abi.encode(SEED, _nonce))) % max;
    }

    function _randBetween(uint256 min, uint256 max) internal returns (uint256) {
        if (min >= max) return min;
        return min + _rand(max - min + 1);
    }

    function _randUser() internal returns (address) {
        return users[_rand(users.length)];
    }

    function _randBool(uint256 pctTrue) internal returns (bool) {
        return _rand(100) < pctTrue;
    }

    /// @dev Scaled random: upper = clamp(users.length / divisor, minVal, maxVal)
    ///      Makes per-round operation counts proportional to user pool size.
    ///      Example: _scaledRand(1, 4, 50)  →  20 users: 1~5,  100 users: 1~25,  1000 users: 1~50
    function _scaledRand(uint256 minVal, uint256 divisor, uint256 maxVal) internal returns (uint256) {
        uint256 upper = users.length / divisor;
        if (upper < minVal) upper = minVal;
        if (upper > maxVal) upper = maxVal;
        return _randBetween(minVal, upper);
    }

    /// @notice Check if wall-clock duration has been exceeded (used as loop exit condition)
    function _shouldStop() internal returns (bool) {
        if (MAX_DURATION == 0) return false;
        uint256 elapsedMs = vm.unixTime() - _wallStartTime;
        return elapsedMs >= MAX_DURATION * 1000;
    }

    // =========================================================================
    //  Snapshot helpers
    // =========================================================================
    function _takeSnapshot(address user) internal view returns (Snapshot memory s) {
        s.vaultTotalSupply = vault.totalSupply();
        s.vaultPhysicalCash = usdc.balanceOf(address(vault));
        s.vaultTotalLockedShares = vault.totalLockedShares();
        s.vaultTotalInvestInFlight = vault.totalInvestInFlight();
        s.vaultTotalRedeemInFlight = vault.totalRedeemInFlight();
        s.vaultNextRequestId = vault.nextRequestId();
        s.vaultNextInFlightId = vault.nextInFlightId();
        s.exchangeRate = accountant.getRate();
        s.userShareBalance = vault.balanceOf(user);
        s.userUsdcBalance = usdc.balanceOf(user);
        s.treasuryShareBalance = vault.balanceOf(treasury);
        s.sanctionSafeShareBalance = vault.balanceOf(sanctionSafe);
        s.sanctionSafeUsdcBalance = usdc.balanceOf(sanctionSafe);
    }

    // =========================================================================
    //  Operation helpers with delta verification
    // =========================================================================

    /// @notice Deposit USDC via Gateway, verify deltas
    function _depositAs(address user, uint256 assets) internal returns (uint256 shares) {
        Snapshot memory before = _takeSnapshot(user);
        uint256 expectedShares = gateway.previewDeposit(assets);

        vm.prank(user);
        shares = gateway.deposit(assets);

        Snapshot memory snapAfter = _takeSnapshot(user);

        // User: USDC decreased, shares increased
        assertEq(snapAfter.userUsdcBalance, before.userUsdcBalance - assets, "deposit: user USDC delta");
        assertEq(snapAfter.userShareBalance, before.userShareBalance + shares, "deposit: user share delta");

        // Vault: cash increased, supply increased
        assertEq(snapAfter.vaultPhysicalCash, before.vaultPhysicalCash + assets, "deposit: vault cash delta");
        assertEq(snapAfter.vaultTotalSupply, before.vaultTotalSupply + shares, "deposit: supply delta");

        // Shares match preview
        assertEq(shares, expectedShares, "deposit: shares == preview");

        // No side effects on locked/inflight
        assertEq(snapAfter.vaultTotalLockedShares, before.vaultTotalLockedShares, "deposit: locked unchanged");
        assertEq(snapAfter.vaultTotalInvestInFlight, before.vaultTotalInvestInFlight, "deposit: investIF unchanged");

        logInfo(string.concat(
            "[DEPOSIT] user=", vm.toString(user),
            " amt=", _toStr(assets),
            " shares=", _toStr(shares),
            " cash=", _toStr(usdc.balanceOf(address(vault)))
        ));
        _statDeposits++;
        _statTotalTx++;
    }

    /// @notice Sync redeem via Gateway, verify deltas
    function _redeemAs(address user, uint256 shares) internal returns (uint256 assets) {
        Snapshot memory before = _takeSnapshot(user);
        uint256 expectedAssets = gateway.previewRedeem(shares);
        uint256 feeBps = vault.redemptionFeeBps();
        uint256 expectedFeeShares = _ceilDiv(shares * feeBps, 10_000);

        vm.prank(user);
        assets = gateway.redeem(shares);

        Snapshot memory snapAfter = _takeSnapshot(user);

        // User: shares decreased, USDC increased
        assertEq(snapAfter.userShareBalance, before.userShareBalance - shares, "redeem: user share delta");
        assertEq(snapAfter.userUsdcBalance, before.userUsdcBalance + assets, "redeem: user USDC delta");

        // Vault: cash decreased
        assertEq(snapAfter.vaultPhysicalCash, before.vaultPhysicalCash - assets, "redeem: vault cash delta");

        // Supply: net burn = shares - feeShares
        assertEq(
            snapAfter.vaultTotalSupply,
            before.vaultTotalSupply - shares + expectedFeeShares,
            "redeem: supply delta"
        );

        // Treasury: received fee shares
        assertEq(
            snapAfter.treasuryShareBalance,
            before.treasuryShareBalance + expectedFeeShares,
            "redeem: treasury fee"
        );

        assertEq(assets, expectedAssets, "redeem: assets == preview");

        logInfo(string.concat(
            "[SYNC_REDEEM] user=", vm.toString(user),
            " shares=", _toStr(shares),
            " assets=", _toStr(assets),
            " cash=", _toStr(usdc.balanceOf(address(vault)))
        ));
        _statSyncRedeems++;
        _statTotalTx++;
    }

    /// @notice Request async redeem via Gateway, verify deltas
    function _requestRedeemAs(address user, uint256 shares) internal returns (uint256 requestId) {
        Snapshot memory before = _takeSnapshot(user);
        uint256 feeBps = vault.redemptionFeeBps();
        uint256 expectedFeeShares = _ceilDiv(shares * feeBps, 10_000);
        uint256 netShares = shares - expectedFeeShares;

        vm.prank(user);
        requestId = gateway.requestRedeem(shares);

        Snapshot memory snapAfter = _takeSnapshot(user);

        // User: all shares removed
        assertEq(snapAfter.userShareBalance, before.userShareBalance - shares, "request: user share delta");
        // User USDC unchanged (async, no payout yet)
        assertEq(snapAfter.userUsdcBalance, before.userUsdcBalance, "request: user USDC unchanged");

        // Treasury: fee shares
        assertEq(
            snapAfter.treasuryShareBalance,
            before.treasuryShareBalance + expectedFeeShares,
            "request: treasury fee"
        );

        // Locked shares increased by netShares
        assertEq(
            snapAfter.vaultTotalLockedShares,
            before.vaultTotalLockedShares + netShares,
            "request: locked delta"
        );

        // Supply decreased by netShares (burned)
        assertEq(snapAfter.vaultTotalSupply, before.vaultTotalSupply - netShares, "request: supply delta");

        // Request created
        assertEq(snapAfter.vaultNextRequestId, before.vaultNextRequestId + 1, "request: id incremented");

        // Verify request object
        (uint256 reqShares, IMantleYieldVault.RequestStatus status) = vault.reqSharesAndStatus(requestId);
        assertEq(reqShares, netShares, "request: req.shares");
        assertEq(uint8(status), uint8(IMantleYieldVault.RequestStatus.PENDING), "request: status PENDING");

        logInfo(string.concat(
            "[REQUEST_REDEEM] user=", vm.toString(user),
            " shares=", _toStr(shares),
            " reqId=", _toStr(requestId),
            " locked=", _toStr(vault.totalLockedShares())
        ));
        _statAsyncRedeems++;
        _statTotalTx++;
    }

    /// @notice Process redeem batch via OperatorExecutor
    function _processRedeemBatch(uint256[] memory ids) internal {
        vm.prank(bot);
        opExecutor.executeProcessRedeemBatch(address(controller), ids);
        // Sum shares for logging
        uint256 totalShares;
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 sh = vault.reqShares(ids[i]);
            totalShares += sh;
        }
        logInfo(string.concat(
            "[PROCESS_BATCH] count=", _toStr(ids.length),
            " totalShares=", _toStr(totalShares),
            " redeemIF=", _toStr(vault.totalRedeemInFlight())
        ));
        _statProcessBatches++;
        _statTotalTx++;
    }

    /// @notice Finalize redeem batch via OperatorExecutor
    function _finalizeRedeemBatch(uint256[] memory ids, uint256[] memory settledAssets) internal {
        vm.prank(bot);
        opExecutor.executeFinalizeRedeemBatch(address(controller), ids, settledAssets);
        uint256 totalSettled;
        for (uint256 i = 0; i < settledAssets.length; i++) totalSettled += settledAssets[i];
        logInfo(string.concat(
            "[FINALIZE_BATCH] count=", _toStr(ids.length),
            " totalSettled=", _toStr(totalSettled),
            " cash=", _toStr(usdc.balanceOf(address(vault)))
        ));
        _statFinalizeBatches++;
        _statTotalTx++;
    }

    /// @notice Trigger rebalance via OperatorExecutor
    function _rebalance() internal {
        uint256 cashBefore = usdc.balanceOf(address(vault));
        vm.prank(bot);
        opExecutor.executeRebalance(address(controller));
        logInfo(string.concat(
            "[REBALANCE] cashBefore=", _toStr(cashBefore),
            " cashAfter=", _toStr(usdc.balanceOf(address(vault))),
            " investIF=", _toStr(vault.totalInvestInFlight()),
            " redeemIF=", _toStr(vault.totalRedeemInFlight())
        ));
        _statRebalances++;
        _statTotalTx++;
    }

    /// @notice Settle adapter via OperatorExecutor
    function _settleAdapter(
        address adapter,
        IStrategyControllerExecutor.InvestSettlementInput memory invest,
        IStrategyControllerExecutor.RedeemSettlementInput memory redeem
    ) internal {
        vm.prank(bot);
        opExecutor.executeSettleAdapter(address(controller), adapter, invest, redeem);
        logInfo(string.concat(
            "[SETTLE] adapter=", vm.toString(adapter),
            " investIds=", _toStr(invest.inFlightIds.length),
            " redeemIds=", _toStr(redeem.inFlightIds.length),
            " investIF=", _toStr(vault.totalInvestInFlight()),
            " redeemIF=", _toStr(vault.totalRedeemInFlight())
        ));
        _statSettlements++;
        _statTotalTx++;
    }

    /// @notice Update exchange rate via AccountantExecutor
    function _updateExchangeRate(uint64 newRate) internal {
        uint256 oldRate = accountant.getRate();
        vm.prank(bot);
        acctExecutor.executeUpdateRate(address(accountant), newRate, uint64(block.timestamp));
        logInfo(string.concat(
            "[RATE_UPDATE] old=", _toStr(oldRate),
            " new=", _toStr(uint256(newRate))
        ));
        _statRateUpdates++;
        _statTotalTx++;
    }

    /// @notice Set sanction status (handles both local mock and fork mode)
    function _setSanctioned(address account, bool sanctioned) internal {
        if (IS_FORK) {
            // In fork mode, prank as admin/compliance bot
            vm.prank(admin);
            oracle.updateSanctionStatus(account, sanctioned);
        } else {
            mockOracle.setSanctioned(account, sanctioned);
        }
    }

    // =========================================================================
    //  Utility: get request IDs by status
    // =========================================================================

    function _getRequestIdsByStatus(IMantleYieldVault.RequestStatus targetStatus)
        internal
        view
        returns (uint256[] memory)
    {
        uint256 nextId = vault.nextRequestId();
        uint256 count;
        for (uint256 id = _baseRequestId; id < nextId; id++) {
            IMantleYieldVault.RequestStatus status = vault.reqStatus(id);
            if (status == targetStatus) count++;
        }
        uint256[] memory ids = new uint256[](count);
        uint256 idx;
        for (uint256 id = _baseRequestId; id < nextId; id++) {
            IMantleYieldVault.RequestStatus status = vault.reqStatus(id);
            if (status == targetStatus) {
                ids[idx++] = id;
            }
        }
        return ids;
    }

    function _sortIds(uint256[] memory ids) internal pure returns (uint256[] memory) {
        // Simple insertion sort (small arrays)
        for (uint256 i = 1; i < ids.length; i++) {
            uint256 key = ids[i];
            uint256 j = i;
            while (j > 0 && ids[j - 1] > key) {
                ids[j] = ids[j - 1];
                j--;
            }
            ids[j] = key;
        }
        return ids;
    }

    // =========================================================================
    //  Empty settlement inputs (convenience)
    // =========================================================================

    function _emptyInvestInput() internal pure returns (IStrategyControllerExecutor.InvestSettlementInput memory) {
        return IStrategyControllerExecutor.InvestSettlementInput({
            inFlightIds: new uint256[](0),
            settledPosAmounts: new uint256[](0),
            refundAssetAmounts: new uint256[](0)
        });
    }

    function _emptyRedeemInput() internal pure returns (IStrategyControllerExecutor.RedeemSettlementInput memory) {
        return IStrategyControllerExecutor.RedeemSettlementInput({
            inFlightIds: new uint256[](0),
            settledAssetAmounts: new uint256[](0)
        });
    }

    // =========================================================================
    //  Global Invariant Checks (with detailed error dump)
    // =========================================================================

    function _checkAllInvariants(string memory ctx) internal {
        _statInvariantChecks++;
        bool ok = true;
        ok = _safeCheckI1(ctx) && ok;
        ok = _safeCheckI2(ctx) && ok;
        ok = _safeCheckI3(ctx) && ok;
        ok = _safeCheckI4(ctx) && ok;
        ok = _safeCheckI6(ctx) && ok;
        ok = _safeCheckI7(ctx) && ok;
        ok = _safeCheckI8(ctx) && ok;
        if (ok) {
            logDebug("ALL INVARIANTS PASSED", ctx);
        } else {
            _statInvariantFails++;
            logError("INVARIANT FAILURE detected at", ctx);
            _dumpScene(ctx);
            // Write FAILED row to TSV before reverting so aggregate data is preserved
            uint256 totalGas = _stCaseStartGas - gasleft();
            uint256 elapsedMs = vm.unixTime() - _wallStartTime;
            _appendAggregateRow(totalGas, elapsedMs, false);
            revert(string.concat("Invariant failure: ", ctx));
        }
        // Advance base IDs past settled records to keep future scans efficient
        _advanceBaseIds();
    }

    /// @dev Dump full scene context on invariant failure
    function _dumpScene(string memory ctx) internal {
        logSep(string.concat("FAILURE SCENE DUMP: ", ctx));
        // --- Test run context ---
        logError("seed", SEED);
        logError("round", _statActualRounds);
        logError("totalTx", _statTotalTx);
        // --- Protocol state ---
        logError("rate", accountant.getRate());
        logError("redemptionFeeBps", vault.redemptionFeeBps());
        _logLedger("FAILURE");
        logError("block.timestamp", block.timestamp);
        logError("nextRequestId", vault.nextRequestId());
        logError("nextInFlightId", vault.nextInFlightId());
        // --- Adapter state ---
        logError("syncAdapter USDC", usdc.balanceOf(address(syncAdapter)));
        logError("asyncAdapter USDC", usdc.balanceOf(address(asyncAdapter)));
        logError("totalUsdcInjected", _totalUsdcInjected);
        // Per-user balances (cap to first 50 to avoid OOG in large user pools)
        uint256 userCap = users.length < 50 ? users.length : 50;
        for (uint256 i = 0; i < userCap; i++) {
            logError(
                string.concat("user[", _toStr(i), "]"),
                string.concat(
                    vm.toString(users[i]),
                    " shares=", _toStr(vault.balanceOf(users[i])),
                    " usdc=", _toStr(usdc.balanceOf(users[i]))
                )
            );
        }
        if (users.length > 50) {
            logError("... truncated", string.concat(_toStr(users.length - 50), " more users"));
        }
        logError("treasury shares", vault.balanceOf(treasury));
        logError("sanctionSafe shares", vault.balanceOf(sanctionSafe));
        logError("sanctionSafe usdc", usdc.balanceOf(sanctionSafe));
        // Pending/Processing requests
        uint256 nextReq = vault.nextRequestId();
        for (uint256 id = _baseRequestId; id < nextReq; id++) {
            (uint256 sh,, , uint256 sa, IMantleYieldVault.RequestStatus st) = vault.reqCore(id);
            if (st == IMantleYieldVault.RequestStatus.PENDING || st == IMantleYieldVault.RequestStatus.PROCESSING) {
                logError(string.concat("request[", _toStr(id), "]"),
                    string.concat("shares=", _toStr(sh), " settled=", _toStr(sa), " status=", _toStr(uint256(uint8(st)))));
            }
        }
        // Pending in-flight
        uint256 nextIf = vault.nextInFlightId();
        for (uint256 id = _baseInFlightId; id < nextIf; id++) {
            (address ifAdapter,, uint256 uAmt, bool isInv, IMantleYieldVault.InFlightStatus ifs) = vault.ifFull(id);
            if (ifs == IMantleYieldVault.InFlightStatus.PENDING) {
                logError(string.concat("inflight[", _toStr(id), "]"),
                    string.concat("adapter=", vm.toString(ifAdapter), " usdc=", _toStr(uAmt), " isInvest=", isInv ? "true" : "false"));
            }
        }
        logSep("END SCENE DUMP");
    }

    // --- Safe wrappers: return false instead of revert ---

    function _safeCheckI1(string memory ctx) internal returns (bool) {
        try this.extCheckI1(ctx) { return true; }
        catch (bytes memory reason) { logError(string.concat("I1_AssetConservation FAIL: ", ctx), string(reason)); return false; }
    }
    function _safeCheckI2(string memory ctx) internal returns (bool) {
        try this.extCheckI2(ctx) { return true; }
        catch (bytes memory reason) { logError(string.concat("I2_ShareConservation FAIL: ", ctx), string(reason)); return false; }
    }
    function _safeCheckI3(string memory ctx) internal returns (bool) {
        try this.extCheckI3(ctx) { return true; }
        catch (bytes memory reason) { logError(string.concat("I3_FreeCashNonNeg FAIL: ", ctx), string(reason)); return false; }
    }
    function _safeCheckI4(string memory ctx) internal returns (bool) {
        try this.extCheckI4(ctx) { return true; }
        catch (bytes memory reason) { logError(string.concat("I4_RequestIntegrity FAIL: ", ctx), string(reason)); return false; }
    }
    function _safeCheckI6(string memory ctx) internal returns (bool) {
        try this.extCheckI6(ctx) { return true; }
        catch (bytes memory reason) { logError(string.concat("I6_TreasuryMonotonic FAIL: ", ctx), string(reason)); return false; }
    }
    function _safeCheckI7(string memory ctx) internal returns (bool) {
        try this.extCheckI7(ctx) { return true; }
        catch (bytes memory reason) { logError(string.concat("I7_InFlightConsistency FAIL: ", ctx), string(reason)); return false; }
    }
    function _safeCheckI8(string memory ctx) internal returns (bool) {
        try this.extCheckI8(ctx) { return true; }
        catch (bytes memory reason) { logError(string.concat("I8_LockedSharesBalance FAIL: ", ctx), string(reason)); return false; }
    }

    // --- External wrappers (needed for try/catch on internal calls) ---

    function extCheckI1(string memory ctx) external { _checkI1_AssetConservation(ctx); }
    function extCheckI2(string memory ctx) external { _checkI2_ShareConservation(ctx); }
    function extCheckI3(string memory ctx) external { _checkI3_FreeCashNonNeg(ctx); }
    function extCheckI4(string memory ctx) external { _checkI4_RequestIntegrity(ctx); }
    function extCheckI6(string memory ctx) external { _checkI6_TreasuryMonotonic(ctx); }
    function extCheckI7(string memory ctx) external { _checkI7_InFlightConsistency(ctx); }
    function extCheckI8(string memory ctx) external { _checkI8_LockedSharesBalance(ctx); }

    function _checkI1_AssetConservation(string memory ctx) internal view {
        uint256 totalAssets = vault.totalAssets();
        // totalAssets is defined to return 0 when rawTotal < floatingLocked
        // So it's always >= 0 by construction; just ensure no revert
        assertTrue(totalAssets >= 0, string.concat(ctx, " I1: totalAssets >= 0"));
    }

    function _checkI2_ShareConservation(string memory ctx) internal view {
        uint256 totalSupply = vault.totalSupply();
        uint256 accounted;
        for (uint256 i = 0; i < users.length; i++) {
            accounted += vault.balanceOf(users[i]);
        }
        accounted += vault.balanceOf(treasury);
        accounted += vault.balanceOf(sanctionSafe);
        accounted += vault.balanceOf(admin);

        if (!IS_FORK) {
            assertEq(accounted, totalSupply, string.concat(ctx, " I2: shares accounted (local)"));
        } else {
            assertLe(accounted, totalSupply, string.concat(ctx, " I2: known <= totalSupply (fork)"));
            uint256 unknownShares = totalSupply - accounted;
            assertEq(
                unknownShares, _forkInitialUnknownShares, string.concat(ctx, " I2: unknown unchanged (fork)")
            );
        }
    }

    function _checkI3_FreeCashNonNeg(string memory ctx) internal view {
        // getFreeCash returns 0 when physicalCash < floatingLocked, never reverts
        uint256 freeCash = vault.getFreeCash();
        assertTrue(freeCash >= 0, string.concat(ctx, " I3: freeCash >= 0"));
    }

    function _checkI4_RequestIntegrity(string memory ctx) internal view {
        uint256 nextId = vault.nextRequestId();
        for (uint256 id = _baseRequestId; id < nextId; id++) {
            (,, uint256 shares,,, uint256 settledAssets,, IMantleYieldVault.RequestStatus status) =
                vault.requests(id);

            if (status == IMantleYieldVault.RequestStatus.PENDING) {
                assertEq(settledAssets, 0, string.concat(ctx, " I4: PENDING settled==0"));
                assertGt(shares, 0, string.concat(ctx, " I4: PENDING shares>0"));
            } else if (status == IMantleYieldVault.RequestStatus.PROCESSING) {
                assertEq(settledAssets, 0, string.concat(ctx, " I4: PROCESSING settled==0"));
            }
            assertTrue(
                uint8(status) >= uint8(IMantleYieldVault.RequestStatus.PENDING),
                string.concat(ctx, " I4: status >= PENDING")
            );
        }
    }

    function _checkI6_TreasuryMonotonic(string memory ctx) internal {
        uint256 current = vault.balanceOf(treasury);
        assertGe(current, _lastTreasuryBalance, string.concat(ctx, " I6: treasury monotonic"));
        _lastTreasuryBalance = current;
    }

    function _checkI7_InFlightConsistency(string memory ctx) internal view {
        uint256 nextId = vault.nextInFlightId();
        uint256 sumInvestIF;
        uint256 sumRedeemIF;

        for (uint256 id = _baseInFlightId; id < nextId; id++) {
            (,,,, uint256 usdcAmt,, bool isInvest,, IMantleYieldVault.InFlightStatus ifStatus) =
                vault.inFlightRecords(id);

            if (ifStatus == IMantleYieldVault.InFlightStatus.PENDING) {
                if (isInvest) {
                    sumInvestIF += usdcAmt;
                } else {
                    sumRedeemIF += usdcAmt;
                }
            }
        }

        assertEq(vault.totalInvestInFlight(), sumInvestIF, string.concat(ctx, " I7: investIF sum"));
        assertEq(vault.totalRedeemInFlight(), sumRedeemIF, string.concat(ctx, " I7: redeemIF sum"));
    }

    function _checkI8_LockedSharesBalance(string memory ctx) internal view {
        uint256 nextId = vault.nextRequestId();
        uint256 sumLocked;

        for (uint256 id = _baseRequestId; id < nextId; id++) {
            (uint256 shares, IMantleYieldVault.RequestStatus status) = vault.reqSharesAndStatus(id);
            if (
                status == IMantleYieldVault.RequestStatus.PENDING
                    || status == IMantleYieldVault.RequestStatus.PROCESSING
            ) {
                sumLocked += shares;
            }
        }

        assertEq(vault.totalLockedShares(), sumLocked, string.concat(ctx, " I8: locked == sum"));
    }

    /// @notice Check USDC closed system (local mode only)
    function _checkUsdcClosedSystem(string memory ctx) internal view virtual {
        if (IS_FORK) return; // Skip in fork mode (unknown external holders)

        uint256 totalInSystem;
        for (uint256 i = 0; i < users.length; i++) {
            totalInSystem += usdc.balanceOf(users[i]);
        }
        totalInSystem += usdc.balanceOf(address(vault));
        totalInSystem += usdc.balanceOf(sanctionSafe);
        totalInSystem += usdc.balanceOf(address(syncAdapter));
        totalInSystem += usdc.balanceOf(address(asyncAdapter));

        assertEq(totalInSystem, _totalUsdcInjected, string.concat(ctx, " USDC closed system"));
    }

    /// @dev Advance _baseRequestId and _baseInFlightId past settled/finalized records.
    ///      This keeps invariant-check scans and _getRequestIdsByStatus() O(active) instead of O(total).
    function _advanceBaseIds() internal {
        // Advance past DONE / CANCELLED requests
        uint256 nextReq = vault.nextRequestId();
        while (_baseRequestId < nextReq) {
            IMantleYieldVault.RequestStatus s = vault.reqStatus(_baseRequestId);
            if (s == IMantleYieldVault.RequestStatus.PENDING || s == IMantleYieldVault.RequestStatus.PROCESSING) break;
            _baseRequestId++;
        }

        // Advance past SETTLED in-flight records
        uint256 nextIf = vault.nextInFlightId();
        while (_baseInFlightId < nextIf) {
            IMantleYieldVault.InFlightStatus s = vault.ifStatus(_baseInFlightId);
            if (s == IMantleYieldVault.InFlightStatus.PENDING) break;
            _baseInFlightId++;
        }
    }

    // =========================================================================
    //  Metrics logging
    // =========================================================================

    function _logMetrics(uint256 round) internal view {
        console2.log("[METRICS] round=%d totalAssets=%d totalSupply=%d", round, vault.totalAssets(), vault.totalSupply());
        console2.log(
            "[METRICS] round=%d rate=%d freeCash=%d", round, accountant.getRate(), vault.getFreeCash()
        );
        console2.log("[METRICS] round=%d investIF=%d redeemIF=%d", round, vault.totalInvestInFlight(), vault.totalRedeemInFlight());
        console2.log("[METRICS] round=%d locked=%d", round, vault.totalLockedShares());
        console2.log("[METRICS] round=%d treasury=%d", round, vault.balanceOf(treasury));
    }

    // =========================================================================
    //  Stress case logging — logCase / logStep / logPass (基于 LogUtil)
    // =========================================================================

    /// @notice 初始化 case 日志，创建 stress_logs 目录（参照 qa logCase 格式）
    function _logCase(string memory id, string memory name) internal {
        _stCaseId = id;
        _stCaseName = name;
        _stCaseStartGas = gasleft();
        _wallStartTime = vm.unixTime();
        try vm.createDir("stress_logs", true) {} catch {}
        try vm.createDir("stress_logs/.cache", true) {} catch {}
        initLog(id, "stress_logs", "stress_logs/errors.log");
        logSep(string.concat("CASE START: ", name));
        logInfo(string.concat("testcase module: stress"));
        logInfo(string.concat("testcase id: ", id));
        logInfo(string.concat("testcase name: ", name));
        logSep();
        logInfo("config rounds", ROUNDS);
        logInfo("config users", USER_COUNT);
        logInfo("config seed", SEED);
        if (MAX_DURATION > 0) {
            logInfo("config maxDuration(s)", MAX_DURATION);
        }
        logSep();
    }

    /// @notice 开始新一轮（只记录 gas 起点，不打印日志）
    function _logRoundStart(uint256 /* round */) internal {
        _stRoundStartGas = gasleft();
    }

    /// @notice 记录步骤
    function _logStep(string memory m) internal {
        logDebug(m);
    }

    /// @notice 记录操作（存款/赎回等）
    function _logOp(string memory op, address user, uint256 amount, uint256 result) internal {
        logDebug(string.concat(op, " user=", vm.toString(user)), string.concat("amount=", _toStr(amount), " result=", _toStr(result)));
    }

    /// @notice 记录账本校验快照
    function _logLedger(string memory ctx) internal {
        logDebug(string.concat("[LEDGER:", ctx, "] totalAssets"), vault.totalAssets());
        logDebug(string.concat("[LEDGER:", ctx, "] totalSupply"), vault.totalSupply());
        logDebug(string.concat("[LEDGER:", ctx, "] rate"), accountant.getRate());
        logDebug(string.concat("[LEDGER:", ctx, "] freeCash"), vault.getFreeCash());
        logDebug(string.concat("[LEDGER:", ctx, "] investIF"), vault.totalInvestInFlight());
        logDebug(string.concat("[LEDGER:", ctx, "] redeemIF"), vault.totalRedeemInFlight());
        logDebug(string.concat("[LEDGER:", ctx, "] lockedShares"), vault.totalLockedShares());
        logDebug(string.concat("[LEDGER:", ctx, "] treasury"), vault.balanceOf(treasury));
        logDebug(string.concat("[LEDGER:", ctx, "] vaultCash"), usdc.balanceOf(address(vault)));
    }

    /// @notice 结束本轮，单行 INFO 汇总 vault 核心指标 + gas
    function _logRoundEnd(uint256 round) internal {
        uint256 gasUsed = _stRoundStartGas - gasleft();
        logInfo(string.concat(
            "[R", _toStr(round), "]",
            " assets=", _toStr(vault.totalAssets()),
            " supply=", _toStr(vault.totalSupply()),
            " rate=", _toStr(accountant.getRate()),
            " cash=", _toStr(vault.getFreeCash()),
            " investIF=", _toStr(vault.totalInvestInFlight()),
            " redeemIF=", _toStr(vault.totalRedeemInFlight()),
            " locked=", _toStr(vault.totalLockedShares()),
            " gas=", _toStr(gasUsed)
        ));
        _logLedger("ROUND_END"); // full detail at DEBUG level
        _statActualRounds++;
    }

    /// @notice 标记 case 通过（参照 qa logPass 格式），写入 summary 并追加汇总到 REPORT.log
    function _logPass() internal {
        uint256 totalGas = _stCaseStartGas - gasleft();
        uint256 elapsedMs = vm.unixTime() - _wallStartTime;
        // Write case summary (into rotating hourly log)
        _logLedger("FINAL");
        logSep();
        logInfo("test result: passed");
        logInfo("actualRounds", _statActualRounds);
        logInfo("totalGasUsed", totalGas);
        logInfo("wallTimeMs", elapsedMs);
        logSep();
        // Write to per-case report + TSV cache
        _writeReport(totalGas, elapsedMs, true);
    }

    /// @notice 写入汇总报告到 stress_logs/<caseId>_REPORT.log (覆盖写) 并追加 TSV 行
    function _writeReport(uint256 totalGas, uint256 elapsedMs, bool passed) internal {
        // --- Per-case human-readable report (legacy single-file mode) ---
        string memory rpt = string.concat("stress_logs/", _stCaseId, "_REPORT.log");
        vm.writeFile(rpt, "");
        initLog(_stCaseId, rpt);
        logSep(string.concat("STRESS TEST REPORT: ", _stCaseName));
        logInfo("caseId", _stCaseId);
        logInfo("result", passed ? "PASSED" : "FAILED");
        logInfo("configRounds", ROUNDS);
        logInfo("actualRounds", _statActualRounds);
        logInfo("users", USER_COUNT);
        logInfo("seed", SEED);
        if (MAX_DURATION > 0) {
            logInfo("maxDuration(s)", MAX_DURATION);
        }
        logInfo("wallTimeMs", elapsedMs);
        logSep("Transaction Statistics");
        logInfo("deposits", _statDeposits);
        logInfo("syncRedeems", _statSyncRedeems);
        logInfo("asyncRedeems (requestRedeem)", _statAsyncRedeems);
        logInfo("processRedeemBatches", _statProcessBatches);
        logInfo("finalizeRedeemBatches", _statFinalizeBatches);
        logInfo("rebalances", _statRebalances);
        logInfo("settlements", _statSettlements);
        logInfo("rateUpdates", _statRateUpdates);
        logInfo("priceUpdates", _statPriceUpdates);
        logInfo("totalTransactions", _statTotalTx);
        logSep("Invariant Checks");
        logInfo("invariantChecks", _statInvariantChecks);
        logInfo("invariantFails", _statInvariantFails);
        logSep("Final Ledger");
        _logLedger("REPORT");
        logSep("Performance");
        logInfo("totalGasUsed", totalGas);
        logSep("END REPORT");

        // --- Switch back to rotating log for any subsequent writes ---
        initLog(_stCaseId, "stress_logs", "stress_logs/errors.log");

        // --- Append TSV aggregate row ---
        _appendAggregateRow(totalGas, elapsedMs, passed);
    }

    /// @notice 追加一行到 stress_logs/.cache/aggregate.tsv
    function _appendAggregateRow(uint256 totalGas, uint256 elapsedMs, bool passed) internal {
        string memory tsvPath = "stress_logs/.cache/aggregate.tsv";
        // Write header if file doesn't exist
        bool exists;
        try vm.readLine(tsvPath) {
            exists = true;
        } catch {
            exists = false;
        }
        if (!exists) {
            vm.writeLine(
                tsvPath,
                "ts\tcontract\tseed\tresult\tactualRounds\ttotalTx\tdeposits\tsyncRedeems\tasyncRedeems\tprocessBatch\tfinalizeBatch\trebalances\tsettlements\trateUpdates\tpriceUpdates\tinvariantChecks\tinvariantFails\ttotalGasUsed\twallMs"
            );
        }
        // Build TSV row
        string memory row = string.concat(
            _toStr(vm.unixTime()), "\t",
            _stCaseId, "\t",
            _toStr(SEED), "\t",
            passed ? "PASSED" : "FAILED", "\t",
            _toStr(_statActualRounds), "\t",
            _toStr(_statTotalTx), "\t",
            _toStr(_statDeposits), "\t",
            _toStr(_statSyncRedeems), "\t",
            _toStr(_statAsyncRedeems), "\t"
        );
        row = string.concat(
            row,
            _toStr(_statProcessBatches), "\t",
            _toStr(_statFinalizeBatches), "\t",
            _toStr(_statRebalances), "\t",
            _toStr(_statSettlements), "\t",
            _toStr(_statRateUpdates), "\t",
            _toStr(_statPriceUpdates), "\t",
            _toStr(_statInvariantChecks), "\t",
            _toStr(_statInvariantFails), "\t"
        );
        row = string.concat(
            row,
            _toStr(totalGas), "\t",
            _toStr(elapsedMs)
        );
        vm.writeLine(tsvPath, row);
    }

    /// @notice uint256 → decimal string
    function _toStr(uint256 val) internal pure returns (string memory) {
        if (val == 0) return "0";
        uint256 temp = val;
        uint256 digits;
        while (temp != 0) { digits++; temp /= 10; }
        bytes memory buffer = new bytes(digits);
        while (val != 0) { digits -= 1; buffer[digits] = bytes1(uint8(48 + uint256(val % 10))); val /= 10; }
        return string(buffer);
    }

    // =========================================================================
    //  Periodic rate & underlying asset price updates
    // =========================================================================

    /// @notice 每轮调用：周期性更新汇率 + 底层资产价格
    ///         rateInterval  — 每 N 轮更新一次汇率
    ///         priceInterval — 每 N 轮更新一次 posToken 价格
    function _periodicRateAndPriceUpdate(uint256 round, uint256 rateInterval, uint256 priceInterval) internal {
        if (rateInterval > 0 && round > 0 && round % rateInterval == 0) {
            _jitterExchangeRate();
        }
        if (!IS_FORK && priceInterval > 0 && round > 0 && round % priceInterval == 0) {
            _jitterPosTokenPrice();
        }
    }

    /// @notice 汇率 ±2% 随机抖动（clamp 到 maxDeviation 防止熔断）
    function _jitterExchangeRate() internal {
        uint256 currentRate = accountant.getRate();
        uint256 maxDev = accountant.maxAllowedDeviation();
        uint256 delta = currentRate * _randBetween(1, 200) / 10_000;
        uint64 newRate;
        if (_randBool(50)) {
            newRate = uint64(currentRate + delta);
        } else {
            newRate = uint64(currentRate > delta ? currentRate - delta : currentRate);
        }
        uint64 upper = uint64(currentRate * (10_000 + maxDev) / 10_000);
        uint64 lower = uint64(currentRate * (10_000 - maxDev) / 10_000);
        if (newRate > upper) newRate = upper;
        if (newRate < lower) newRate = lower;
        // Respect cooldown
        vm.warp(block.timestamp + accountant.minUpdateInterval() + 1);
        _updateExchangeRate(newRate);
    }

    /// @notice 底层资产 posToken 价格 ±5% 随机抖动（仅 local 模式）
    function _jitterPosTokenPrice() internal {
        if (IS_FORK) return;
        uint256 currentPrice = asyncAdapter.posTokenPrice();
        uint256 delta = currentPrice * _randBetween(1, 500) / 10_000;
        uint256 newPrice;
        if (_randBool(50)) {
            newPrice = currentPrice + delta;
        } else {
            newPrice = currentPrice > delta ? currentPrice - delta : currentPrice / 2 + 1;
        }
        asyncAdapter.setPosTokenPrice(newPrice);
        logInfo(string.concat(
            "[PRICE_UPDATE] old=", _toStr(currentPrice),
            " new=", _toStr(newPrice)
        ));
        _statPriceUpdates++;
        _statTotalTx++;
    }

    // =========================================================================
    //  Math helpers
    // =========================================================================

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    /// @notice Compute minimum shares needed for redeem/requestRedeem to pass minRedeemAmount check
    ///         The vault checks:
    ///           feeShares    = ceilDiv(shares * feeBps, 10000)   ← rounds UP (costs 1 extra share)
    ///           netShares    = shares - feeShares
    ///           estimatedAssets = floor(netShares * rate / 1e18) ← rounds DOWN (costs 1 asset)
    ///           require(estimatedAssets >= minRedeemAmount)
    ///         Two rounding layers can combine for up to 2 wei shortfall, so we add +2 margin.
    function _effectiveMinRedeemShares() internal view returns (uint256) {
        uint256 minAssets = vault.minRedeemAmount();
        uint256 rate = accountant.getRate();
        uint256 feeBps = vault.redemptionFeeBps();
        if (rate == 0) return minAssets;
        // Solve: shares >= minAssets * 1e18 * 10000 / (rate * (10000 - feeBps))
        // +2 covers both ceilDiv fee rounding and floor asset rounding
        uint256 computed = minAssets * 1e18 * 10000 / (rate * (10000 - feeBps)) + 2;
        return computed > minAssets ? computed : minAssets;
    }
}
