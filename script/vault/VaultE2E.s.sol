// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategyAdapter} from "../../src/interfaces/adapters/IStrategyAdapter.sol";
import {ISanctionsOracle} from "../../src/interfaces/compliance/ISanctionsOracle.sol";
import {IMantleVaultGateway} from "../../src/interfaces/vault/IMantleVaultGateway.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {GatewayFactory} from "../../src/vault/GatewayFactory.sol";
import {MantleVaultGateway} from "../../src/vault/MantleVaultGateway.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {VaultFactory} from "../../src/vault/VaultFactory.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Script, console} from "forge-std/Script.sol";

// =============================================================
// Mocks (same as test file, reusable)
// =============================================================

contract MockStable is ERC20 {
    constructor() ERC20("Stable Coin", "STABLE") {}

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

contract MockStrategyAdapter is IStrategyAdapter {
    uint256 public mockTotalValue;

    function name() external pure override returns (string memory) {
        return "MockAdapter";
    }

    function asset() external pure override returns (address) {
        return address(0);
    }

    function posToken() external pure override returns (address) {
        return address(0);
    }

    function priceOracle() external pure override returns (address) {
        return address(0);
    }

    function getPosTokenPrice() external pure override returns (uint256) {
        return 1e18;
    }

    function estimatePosAmount(uint256 assetAmount) external pure override returns (uint256) {
        return assetAmount;
    }

    function previewDeposit(uint256 assetAmount)
        external
        pure
        override
        returns (bool ok, uint256 executableAssetAmount, uint256 expectedPosAmount)
    {
        return (assetAmount > 0, assetAmount, 0);
    }

    function previewRedeem(uint256 assetAmount)
        external
        pure
        override
        returns (bool ok, uint256 executableAssetAmount, uint256 expectedPosAmount)
    {
        return (assetAmount > 0, assetAmount, 0);
    }

    function vault() external pure override returns (address) {
        return address(0);
    }

    function totalValue() external view override returns (uint256) {
        return mockTotalValue;
    }

    function setTotalValue(uint256 v) external {
        mockTotalValue = v;
    }

    function deposit(uint256, address) external pure override returns (uint256) {
        return 0;
    }

    function withdrawSync(uint256, address) external pure override returns (uint256) {
        return 0;
    }

    function requestRedeemAsync(uint256, address) external pure override {}

    function retryRedeemAsync(uint256, address) external pure override {}

    function sweepToVault(address, uint256) external pure override returns (uint256) {
        return 0;
    }

    function setPaused(bool) external pure override {}
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

    function mintFeeSharesOnVault(address vault, uint256 shares) external {
        IMantleYieldVault(vault).mintFeeShares(shares);
    }
}

// =============================================================
// E2E Script: exercises every vault flow end-to-end
// =============================================================

contract VaultE2E is Script {
    MockStable stable;
    MockSanctionsOracle oracle;
    MockStrategyAdapter adapter;
    MockAccountant accountantMock;
    MantleYieldVault vault;
    MantleVaultGateway gateway;
    VaultFactory factory;
    GatewayFactory gatewayFactory;

    address admin;
    address controller;
    address accountant;
    address treasury;
    address pauser;
    address alice;
    address bob;

    uint256 adminKey;
    uint256 controllerKey;
    uint256 pauserKey;
    uint256 aliceKey;
    uint256 bobKey;

    function run() external {
        _setupAccounts();
        _deployInfrastructure();

        _scenarioBeaconDeploy();

        _scenarioDeposit();
        _scenarioSyncRedeem();
        _scenarioAsyncRedeemFullLifecycle();
        _scenarioAsyncRedeemWithFriction();
        _scenarioInFlightRebalance();
        _scenarioExchangeRateRead();
        _scenarioMintFeeShares();
        _scenarioPauseUnpause();
        _scenarioAdminSetters();

        console.log("========================================");
        console.log("  ALL E2E SCENARIOS PASSED");
        console.log("========================================");
    }

    // =============================================================
    // Setup
    // =============================================================

    function _setupAccounts() internal {
        adminKey = 0xA0001;
        controllerKey = 0xA0002;
        pauserKey = 0xA0004;
        aliceKey = 0xA0005;
        bobKey = 0xA0006;

        admin = vm.addr(adminKey);
        controller = vm.addr(controllerKey);
        pauser = vm.addr(pauserKey);
        alice = vm.addr(aliceKey);
        bob = vm.addr(bobKey);
        treasury = vm.addr(0xA0007);
    }

    function _deployInfrastructure() internal {
        vm.startBroadcast(adminKey);
        stable = new MockStable();
        oracle = new MockSanctionsOracle();
        adapter = new MockStrategyAdapter();
        accountantMock = new MockAccountant();
        vm.stopBroadcast();

        accountant = address(accountantMock);

        console.log("[infra] STABLE:", address(stable));
        console.log("[infra] Oracle:", address(oracle));
        console.log("[infra] Adapter:", address(adapter));
        console.log("[infra] Accountant:", accountant);
    }

    // =============================================================
    // Scenario 1: Beacon Deploy (VaultFactory)
    // =============================================================

    function _scenarioBeaconDeploy() internal {
        console.log("\n--- Scenario: Beacon Deploy ---");

        vm.startBroadcast(adminKey);
        MantleYieldVault impl = new MantleYieldVault();
        MantleVaultGateway gatewayImpl = new MantleVaultGateway();
        factory = new VaultFactory(address(impl), admin);
        gatewayFactory = new GatewayFactory(address(gatewayImpl), admin);

        address vaultAddr = factory.deployVault();
        address gatewayAddr = gatewayFactory.deployGateway();
        vault = MantleYieldVault(vaultAddr);
        gateway = MantleVaultGateway(gatewayAddr);
        vault.initialize(
            IMantleYieldVault.InitParams({
                asset: IERC20(address(stable)),
                name: "Mantle RWA Vault",
                symbol: "mRWA",
                admin: admin,
                gateway: gatewayAddr,
                controller: controller,
                accountant: accountant,
                treasury: treasury,
                maxRedemptionFeeBps: 500,
                redemptionFeeBps: 100,
                minRedeemAmount: 10e6,
                minDepositAmount: 1e6,
                maxSettlementDeviationBps: 1000,
                depositDailyRemaining: type(uint256).max,
                redeemDailyRemaining: type(uint256).max
            })
        );
        gateway.initialize(
            IMantleVaultGateway.InitParams({
                vault: vaultAddr,
                sanctionsOracle: ISanctionsOracle(address(oracle)),
                sanctionSafe: treasury,
                admin: admin,
                syncRedeemDisabled: false,
                whitelistEnabled: false
            })
        );
        vm.stopBroadcast();

        require(vault.exchangeRate() == 1e18, "exchangeRate != 1e18");
        require(vault.controller() == controller, "controller mismatch");
        require(vault.treasury() == treasury, "treasury mismatch");
        require(vault.gateway() == address(gateway), "gateway mismatch");
        require(factory.vaultCount() == 1, "vault count != 1");
        require(factory.implementation() == address(impl), "impl mismatch");

        bytes32 pauserRole = vault.PAUSER_ROLE();
        vm.broadcast(adminKey);
        vault.grantRole(pauserRole, pauser);

        console.log("[Beacon] Factory:", address(factory));
        console.log("[Beacon] Implementation:", address(impl));
        console.log("[Beacon] Vault:", vaultAddr);
        console.log("[Beacon] Gateway:", address(gateway));

        // Also test uninitialized deployment
        vm.startBroadcast(adminKey);
        address uninitVault = factory.deployVault();
        vm.stopBroadcast();

        require(factory.vaultCount() == 2, "vault count != 2");
        console.log("[Beacon] Uninitialized Vault:", uninitVault);
    }

    // =============================================================
    // Scenario 3: Deposit
    // =============================================================

    function _scenarioDeposit() internal {
        console.log("\n--- Scenario: Deposit ---");

        vm.broadcast(adminKey);
        stable.mint(alice, 10_000e6);

        vm.startBroadcast(aliceKey);
        stable.approve(address(vault), type(uint256).max);
        uint256 shares = gateway.deposit(5_000e6);
        vm.stopBroadcast();

        require(shares == 5_000e6, "shares != 5000e6");
        require(vault.balanceOf(alice) == 5_000e6, "alice balance wrong");
        require(stable.balanceOf(address(vault)) == 5_000e6, "vault STABLE wrong");

        console.log("[deposit] Alice deposited 5000 STABLE, got", shares / 1e6, "shares");
        console.log("[deposit] Vault STABLE balance:", stable.balanceOf(address(vault)) / 1e6);
        console.log("[deposit] totalAssets:", vault.totalAssets() / 1e6);
    }

    // =============================================================
    // Scenario 4: Sync Redeem
    // =============================================================

    function _scenarioSyncRedeem() internal {
        console.log("\n--- Scenario: Sync Redeem ---");

        uint256 sharesBefore = vault.balanceOf(alice);
        uint256 stableBefore = stable.balanceOf(alice);

        vm.broadcast(aliceKey);
        uint256 assetsOut = gateway.redeem(1_000e6);

        uint256 expectedNet = 1_000e6 - (1_000e6 * 100 / 10_000);
        require(assetsOut == expectedNet, "sync redeem net wrong");
        require(vault.balanceOf(alice) == sharesBefore - 1_000e6, "shares not burned");
        require(stable.balanceOf(alice) == stableBefore + expectedNet, "stable not received");

        console.log("[syncRedeem] Redeemed 1000 shares -> received", assetsOut / 1e6, "STABLE (1% fee)");
        console.log("[syncRedeem] Fee retained in vault:", (1_000e6 - assetsOut) / 1e6, "STABLE");
    }

    // =============================================================
    // Scenario 5: Async Redeem Full Lifecycle
    // =============================================================

    function _scenarioAsyncRedeemFullLifecycle() internal {
        console.log("\n--- Scenario: Async Redeem Lifecycle ---");

        uint256 redeemShares = 1_000e6;

        // Step 1: requestRedeem
        vm.broadcast(aliceKey);
        uint256 reqId = gateway.requestRedeem(redeemShares);
        console.log("[async] Step 1 - requestRedeem: id =", reqId);

        (,, uint256 reqShares,, uint256 reqAssets, uint256 settled,, IMantleYieldVault.RequestStatus status) =
            vault.requests(reqId);
        require(status == IMantleYieldVault.RequestStatus.PENDING, "not PENDING");
        require(reqShares == redeemShares, "req shares mismatch");
        require(settled == 0, "settled should be 0");
        console.log("[async]   shares:", reqShares / 1e6, "| expected payout (STABLE):", reqAssets / 1e6);

        // Step 2: updateRequestBatch -> PROCESSING
        uint256[] memory ids = new uint256[](1);
        ids[0] = reqId;

        vm.broadcast(controllerKey);
        vault.updateRequestBatch(ids, IMantleYieldVault.RequestStatus.PROCESSING);
        console.log("[async] Step 2 - PROCESSING");

        // Step 3: markRequestsDone - directly transfers STABLE to user (no separate claim)
        uint256[] memory settledAmounts = new uint256[](1);
        settledAmounts[0] = reqAssets;

        uint256 stableBefore = stable.balanceOf(alice);

        vm.broadcast(controllerKey);
        vault.markRequestsDone(ids, settledAmounts);
        console.log("[async] Step 3 - DONE (settled:", reqAssets / 1e6, "STABLE, transferred directly)");

        require(stable.balanceOf(alice) == stableBefore + reqAssets, "stable not received");
        console.log("[async] totalLockedShares:", vault.totalLockedShares());
    }

    // =============================================================
    // Scenario 6: Async Redeem with Friction
    // =============================================================

    function _scenarioAsyncRedeemWithFriction() internal {
        console.log("\n--- Scenario: Async Redeem with Friction ---");

        uint256 redeemShares = 1_000e6;
        uint256 lockedBefore = vault.totalLockedShares();

        vm.broadcast(aliceKey);
        uint256 reqId = gateway.requestRedeem(redeemShares);

        (,,,, uint256 estAssets,,,) = vault.requests(reqId);
        uint256 friction = 5e6;
        uint256 actualSettled = estAssets - friction;

        uint256[] memory ids = new uint256[](1);
        ids[0] = reqId;

        vm.broadcast(controllerKey);
        vault.updateRequestBatch(ids, IMantleYieldVault.RequestStatus.PROCESSING);

        uint256[] memory settledAmounts = new uint256[](1);
        settledAmounts[0] = actualSettled;

        uint256 stableBefore = stable.balanceOf(alice);

        vm.broadcast(controllerKey);
        vault.markRequestsDone(ids, settledAmounts);

        require(stable.balanceOf(alice) == stableBefore + actualSettled, "stable not received");
        require(vault.totalLockedShares() == lockedBefore, "lockedShares not back to original");

        (,,,, uint256 storedEstAssets, uint256 storedSettled,,) = vault.requests(reqId);
        require(storedEstAssets == estAssets, "estimatedAssets should be unchanged");
        require(storedSettled == actualSettled, "settledAssets wrong");

        console.log("[friction] Estimated (STABLE):", estAssets / 1e6, "| Settled:", actualSettled / 1e6);
        console.log("[friction] Friction (STABLE):", friction / 1e6);
        console.log("[friction] STABLE received directly:", actualSettled / 1e6);
        console.log("[friction] Audit: est=", storedEstAssets / 1e6, "settled=", storedSettled / 1e6);
    }

    // =============================================================
    // Scenario 7: In-Flight Rebalance
    // =============================================================

    function _scenarioInFlightRebalance() internal {
        console.log("\n--- Scenario: In-Flight Rebalance ---");

        vm.broadcast(controllerKey);
        vault.registerAdapter(address(adapter));

        // Invest in-flight: STABLE -> adapter token
        vm.broadcast(controllerKey);
        uint256 investId = vault.createInFlight(address(adapter), address(stable), 500, 500e6, true);

        require(vault.totalInvestInFlight() == 500e6, "investInFlight wrong");
        console.log("[inflight] Created invest id:", investId, "| 500 STABLE -> 500 tokens");
        console.log("[inflight] totalInvestInFlight:", vault.totalInvestInFlight() / 1e6);

        // Confirm invest with slight slippage (got 495 tokens instead of 500)
        vm.broadcast(controllerKey);
        vault.confirmInFlight(investId, 495, false);

        require(vault.totalInvestInFlight() == 0, "investInFlight not cleared");
        console.log("[inflight] Confirmed invest: actual 495 tokens. InFlight cleared.");

        // Redeem in-flight: adapter token -> STABLE
        vm.broadcast(controllerKey);
        uint256 redeemId = vault.createInFlight(address(adapter), address(stable), 200, 200e6, false);

        require(vault.totalRedeemInFlight() == 200e6, "redeemInFlight wrong");
        console.log("[inflight] Created redeem id:", redeemId, "| 200 tokens -> 200 STABLE");

        vm.broadcast(controllerKey);
        vault.confirmInFlight(redeemId, 198e6, false);

        require(vault.totalRedeemInFlight() == 0, "redeemInFlight not cleared");
        console.log("[inflight] Confirmed redeem: actual 198 STABLE. InFlight cleared.");

        // Cleanup
        vm.broadcast(controllerKey);
        vault.removeAdapter(address(adapter));
        console.log("[inflight] Adapter removed.");
    }

    // =============================================================
    // Scenario 8: Exchange Rate Read
    // =============================================================

    function _scenarioExchangeRateRead() internal view {
        console.log("\n--- Scenario: Exchange Rate Read ---");
        uint256 rate = vault.exchangeRate();
        require(rate > 0, "rate must be positive");
        console.log("[rate] Current rate:", rate);
        console.log("[rate] 1000 shares worth", vault.previewRedeem(1_000e6) / 1e6, "STABLE (net of fee)");
    }

    // =============================================================
    // Scenario 9: Mint Fee Shares
    // =============================================================

    function _scenarioMintFeeShares() internal {
        console.log("\n--- Scenario: Mint Fee Shares ---");

        uint256 supply = vault.totalSupply();
        uint256 toMint = supply * 100 / 10_000; // 1% of supply

        vm.broadcast(adminKey);
        accountantMock.mintFeeSharesOnVault(address(vault), toMint);

        require(vault.balanceOf(treasury) == toMint, "treasury balance wrong");
        console.log("[fees] Minted", toMint / 1e6, "fee shares to treasury");
        console.log("[fees] Treasury balance:", vault.balanceOf(treasury) / 1e6, "shares");
        console.log("[fees] New totalSupply:", vault.totalSupply() / 1e6);
    }

    // =============================================================
    // Scenario 10: Pause / Unpause
    // =============================================================

    function _scenarioPauseUnpause() internal {
        console.log("\n--- Scenario: Pause / Unpause ---");

        vm.broadcast(pauserKey);
        vault.pause();

        require(vault.paused(), "not paused");
        require(vault.maxDeposit(alice) == 0, "maxDeposit should be 0");
        require(vault.maxRedeem(alice) == 0, "maxRedeem should be 0");
        console.log("[pause] Paused. maxDeposit=0, maxRedeem=0");

        // Transfer should revert when paused
        vm.broadcast(aliceKey);
        try vault.transfer(bob, 1) {
            revert("transfer should revert when paused");
        } catch {
            console.log("[pause] Transfer correctly blocked");
        }

        // Deposit should revert when paused
        vm.broadcast(aliceKey);
        try gateway.deposit(100e6) {
            revert("deposit should revert when paused");
        } catch {
            console.log("[pause] Deposit correctly blocked");
        }

        vm.broadcast(adminKey);
        vault.unpause();

        require(!vault.paused(), "still paused");
        console.log("[pause] Unpaused. Operations resumed.");
    }

    // =============================================================
    // Scenario 11: Admin Setters
    // =============================================================

    function _scenarioAdminSetters() internal {
        console.log("\n--- Scenario: Admin Setters ---");

        address newController = vm.addr(0xB0001);
        address newAccountant = vm.addr(0xB0002);
        address newTreasury = vm.addr(0xB0003);
        address newSanctionSafe = vm.addr(0xB0004);
        MockSanctionsOracle newOracle = new MockSanctionsOracle();

        vm.startBroadcast(adminKey);

        vault.setController(newController);
        require(vault.controller() == newController, "controller not set");
        console.log("[admin] setController:", newController);

        vault.setAccountant(newAccountant);
        require(vault.accountant() == newAccountant, "accountant not set");
        console.log("[admin] setAccountant:", newAccountant);

        vault.setTreasury(newTreasury);
        require(vault.treasury() == newTreasury, "treasury not set");
        console.log("[admin] setTreasury:", newTreasury);

        gateway.setSanctionsOracle(address(newOracle));
        require(address(gateway.sanctionsOracle()) == address(newOracle), "oracle not set");
        console.log("[admin] gateway.setSanctionsOracle:", address(newOracle));

        gateway.setSanctionSafe(newSanctionSafe);
        require(gateway.sanctionSafe() == newSanctionSafe, "sanctionSafe not set");
        console.log("[admin] gateway.setSanctionSafe:", newSanctionSafe);

        gateway.setSyncRedeemDisabled(true);
        require(gateway.syncRedeemDisabled(), "sync disable not set");
        console.log("[admin] gateway.setSyncRedeemDisabled: true");

        vault.setRedemptionFee(200);
        require(vault.redemptionFeeBps() == 200, "fee not set");
        console.log("[admin] setRedemptionFee: 200 bps (2%)");

        vault.setMinRedeemAmount(50e6);
        require(vault.minRedeemAmount() == 50e6, "minRedeem not set");
        console.log("[admin] setMinRedeemAmount: 50 STABLE");

        // Restore original values for any subsequent use
        vault.setController(controller);
        vault.setAccountant(accountant);
        vault.setTreasury(treasury);
        gateway.setSanctionsOracle(address(oracle));
        gateway.setSanctionSafe(treasury);
        gateway.setSyncRedeemDisabled(false);
        vault.setRedemptionFee(100);
        vault.setMinRedeemAmount(10e6);

        vm.stopBroadcast();

        console.log("[admin] All setters verified. Values restored.");
    }
}
