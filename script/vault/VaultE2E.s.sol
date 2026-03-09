// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MantleYieldVault} from "../../src/vault/MantleYieldVault.sol";
import {VaultFactory} from "../../src/vault/VaultFactory.sol";
import {IMantleYieldVault} from "../../src/interfaces/vault/IMantleYieldVault.sol";
import {ISanctionsOracle} from "../../src/interfaces/oracle/ISanctionsOracle.sol";
import {IStrategyAdapter} from "../../src/interfaces/adapters/IStrategyAdapter.sol";

// =============================================================
// Mocks (same as test file, reusable)
// =============================================================

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
    mapping(address => bool) public blacklisted;
    uint256 public totalSanctionedCount;
    uint256 public lastUpdateTimestamp;
    uint256 public batchNonce;
    uint256 public constant MAX_BATCH_SIZE = 200;

    function isSanctioned(address account) external view override returns (bool) {
        return blacklisted[account];
    }

    function setBlacklisted(address account, bool status) public {
        bool prev = blacklisted[account];
        blacklisted[account] = status;
        if (prev != status) {
            if (status) {
                totalSanctionedCount++;
            } else {
                totalSanctionedCount--;
            }
            lastUpdateTimestamp = block.timestamp;
        }
    }

    function updateSanctionStatus(address account, bool sanctioned) external override {
        setBlacklisted(account, sanctioned);
        emit SanctionStatusUpdated(account, sanctioned);
        emit BatchSanctionUpdated(batchNonce++, 1, 1, sanctioned);
    }

    function updateSanctionStatusBatch(address[] calldata accounts, bool sanctioned) external override {
        uint256 changed;
        for (uint256 i = 0; i < accounts.length; i++) {
            bool prev = blacklisted[accounts[i]];
            if (prev != sanctioned) {
                setBlacklisted(accounts[i], sanctioned);
                emit SanctionStatusUpdated(accounts[i], sanctioned);
                changed++;
            }
        }
        emit BatchSanctionUpdated(batchNonce++, accounts.length, changed, sanctioned);
    }
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

    function estimatePosAmount(uint256 assetAmount) external pure override returns (uint256) {
        return assetAmount;
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

    function claimToVault(address, uint256) external pure override returns (uint256) {
        return 0;
    }

    function setPaused(bool) external pure override {}

}

// =============================================================
// E2E Script: exercises every vault flow end-to-end
// =============================================================

contract VaultE2E is Script {
    MockUSDC usdc;
    MockSanctionsOracle oracle;
    MockStrategyAdapter adapter;
    MantleYieldVault vault;
    VaultFactory factory;

    address admin;
    address controller;
    address accountant;
    address treasury;
    address pauser;
    address alice;
    address bob;

    uint256 adminKey;
    uint256 controllerKey;
    uint256 accountantKey;
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
        _scenarioExchangeRateUpdate();
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
        accountantKey = 0xA0003;
        pauserKey = 0xA0004;
        aliceKey = 0xA0005;
        bobKey = 0xA0006;

        admin = vm.addr(adminKey);
        controller = vm.addr(controllerKey);
        accountant = vm.addr(accountantKey);
        pauser = vm.addr(pauserKey);
        alice = vm.addr(aliceKey);
        bob = vm.addr(bobKey);
        treasury = vm.addr(0xA0007);
    }

    function _deployInfrastructure() internal {
        vm.startBroadcast(adminKey);
        usdc = new MockUSDC();
        oracle = new MockSanctionsOracle();
        adapter = new MockStrategyAdapter();
        vm.stopBroadcast();

        console.log("[infra] USDC:", address(usdc));
        console.log("[infra] Oracle:", address(oracle));
        console.log("[infra] Adapter:", address(adapter));
    }

    // =============================================================
    // Scenario 1: Beacon Deploy (VaultFactory)
    // =============================================================

    function _scenarioBeaconDeploy() internal {
        console.log("\n--- Scenario: Beacon Deploy ---");

        vm.startBroadcast(adminKey);
        MantleYieldVault impl = new MantleYieldVault();
        factory = new VaultFactory(address(impl), admin);

        address vaultAddr = factory.deployAndInitVault(
            IMantleYieldVault.InitParams({
                asset: IERC20(address(usdc)),
                name: "Mantle RWA Vault",
                symbol: "mRWA",
                admin: admin,
                sanctionsOracle: address(oracle),
                controller: controller,
                accountant: accountant,
                treasury: treasury,
                maxRedemptionFeeBps: 500,
                maxRateChangeBps: 1_000,
                redemptionFeeBps: 100,
                minRedeemAmount: 10e6,
                minDepositAmount: 1e6,
                syncRedeemDisabled: false
            })
        );
        vm.stopBroadcast();

        vault = MantleYieldVault(vaultAddr);
        require(vault.exchangeRate() == 1e18, "exchangeRate != 1e18");
        require(vault.controller() == controller, "controller mismatch");
        require(vault.treasury() == treasury, "treasury mismatch");
        require(factory.vaultCount() == 1, "vault count != 1");
        require(factory.implementation() == address(impl), "impl mismatch");

        bytes32 pauserRole = vault.PAUSER_ROLE();
        vm.broadcast(adminKey);
        vault.grantRole(pauserRole, pauser);

        console.log("[Beacon] Factory:", address(factory));
        console.log("[Beacon] Implementation:", address(impl));
        console.log("[Beacon] Vault:", vaultAddr);

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
        usdc.mint(alice, 10_000e6);

        vm.startBroadcast(aliceKey);
        usdc.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(5_000e6, alice);
        vm.stopBroadcast();

        require(shares == 5_000e6, "shares != 5000e6");
        require(vault.balanceOf(alice) == 5_000e6, "alice balance wrong");
        require(usdc.balanceOf(address(vault)) == 5_000e6, "vault USDC wrong");

        console.log("[deposit] Alice deposited 5000 USDC, got", shares / 1e6, "shares");
        console.log("[deposit] Vault USDC balance:", usdc.balanceOf(address(vault)) / 1e6);
        console.log("[deposit] totalAssets:", vault.totalAssets() / 1e6);
    }

    // =============================================================
    // Scenario 4: Sync Redeem
    // =============================================================

    function _scenarioSyncRedeem() internal {
        console.log("\n--- Scenario: Sync Redeem ---");

        uint256 sharesBefore = vault.balanceOf(alice);
        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.broadcast(aliceKey);
        uint256 assetsOut = vault.redeem(1_000e6, alice, alice);

        uint256 expectedNet = 1_000e6 - (1_000e6 * 100 / 10_000);
        require(assetsOut == expectedNet, "sync redeem net wrong");
        require(vault.balanceOf(alice) == sharesBefore - 1_000e6, "shares not burned");
        require(usdc.balanceOf(alice) == usdcBefore + expectedNet, "usdc not received");

        console.log("[syncRedeem] Redeemed 1000 shares -> received", assetsOut / 1e6, "USDC (1% fee)");
        console.log("[syncRedeem] Fee retained in vault:", (1_000e6 - assetsOut) / 1e6, "USDC");
    }

    // =============================================================
    // Scenario 5: Async Redeem Full Lifecycle
    // =============================================================

    function _scenarioAsyncRedeemFullLifecycle() internal {
        console.log("\n--- Scenario: Async Redeem Lifecycle ---");

        uint256 redeemShares = 1_000e6;

        // Step 1: requestRedeem
        vm.broadcast(aliceKey);
        uint256 reqId = vault.requestRedeem(redeemShares);
        console.log("[async] Step 1 - requestRedeem: id =", reqId);

        (,, uint256 reqShares, uint256 reqAssets, uint256 settled,, IMantleYieldVault.RequestStatus status) = vault.requests(reqId);
        require(status == IMantleYieldVault.RequestStatus.PENDING, "not PENDING");
        require(reqShares == redeemShares, "req shares mismatch");
        require(settled == 0, "settled should be 0");
        console.log("[async]   shares:", reqShares / 1e6, "| expected payout (USDC):", reqAssets / 1e6);

        // Step 2: updateRequestBatch -> PROCESSING
        uint256[] memory ids = new uint256[](1);
        ids[0] = reqId;

        vm.broadcast(controllerKey);
        vault.updateRequestBatch(ids, IMantleYieldVault.RequestStatus.PROCESSING);
        console.log("[async] Step 2 - PROCESSING");

        // Step 3: markRequestsReady (no friction)
        uint256[] memory settledAmounts = new uint256[](1);
        settledAmounts[0] = reqAssets;

        vm.broadcast(controllerKey);
        vault.markRequestsReady(ids, settledAmounts);
        console.log("[async] Step 3 - READY (settled:", reqAssets / 1e6, "USDC)");

        require(vault.claimableReserves() == reqAssets, "claimableReserves wrong");

        // Step 4: claimRedeem
        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.broadcast(aliceKey);
        uint256 claimed = vault.claimRedeem(alice);

        require(claimed == reqAssets, "claimed != reqAssets");
        require(usdc.balanceOf(alice) == usdcBefore + reqAssets, "usdc not received");
        require(vault.claimableReserves() == 0, "claimable not cleared");

        console.log("[async] Step 4 - CLAIMED:", claimed / 1e6, "USDC");
        console.log("[async] totalLockedShares:", vault.totalLockedShares());
        console.log("[async] claimableReserves:", vault.claimableReserves());
    }

    // =============================================================
    // Scenario 6: Async Redeem with Friction
    // =============================================================

    function _scenarioAsyncRedeemWithFriction() internal {
        console.log("\n--- Scenario: Async Redeem with Friction ---");

        uint256 redeemShares = 1_000e6;
        uint256 lockedBefore = vault.totalLockedShares();

        vm.broadcast(aliceKey);
        uint256 reqId = vault.requestRedeem(redeemShares);

        (,,, uint256 estAssets,,, ) = vault.requests(reqId);
        uint256 friction = 5e6;
        uint256 actualSettled = estAssets - friction;

        uint256[] memory ids = new uint256[](1);
        ids[0] = reqId;

        vm.broadcast(controllerKey);
        vault.updateRequestBatch(ids, IMantleYieldVault.RequestStatus.PROCESSING);

        uint256[] memory settledAmounts = new uint256[](1);
        settledAmounts[0] = actualSettled;

        uint256 lockedBeforeReady = vault.totalLockedShares();

        vm.broadcast(controllerKey);
        vault.markRequestsReady(ids, settledAmounts);

        uint256 lockedAfterReady = vault.totalLockedShares();
        require(lockedAfterReady == lockedBeforeReady - redeemShares, "shares not released from locked");

        console.log("[friction] Estimated (USDC):", estAssets / 1e6, "| Settled:", actualSettled / 1e6);
        console.log("[friction] Friction (USDC):", friction / 1e6);
        console.log("[friction] LockedShares after ready:", lockedAfterReady);

        vm.broadcast(aliceKey);
        uint256 claimed = vault.claimRedeem(alice);

        require(claimed == actualSettled, "claimed != actualSettled");
        require(vault.totalLockedShares() == lockedBefore, "lockedShares not back to original");

        (,,, uint256 storedEstAssets, uint256 storedSettled,, ) = vault.requests(reqId);
        require(storedEstAssets == estAssets, "estimatedAssets should be unchanged");
        require(storedSettled == actualSettled, "settledAssets wrong");

        console.log("[friction] Claimed (USDC):", claimed / 1e6);
        console.log("[friction] Audit: est=", storedEstAssets / 1e6, "settled=", storedSettled / 1e6);
    }

    // =============================================================
    // Scenario 7: In-Flight Rebalance
    // =============================================================

    function _scenarioInFlightRebalance() internal {
        console.log("\n--- Scenario: In-Flight Rebalance ---");

        vm.broadcast(controllerKey);
        vault.registerAdapter(address(adapter));

        // Invest in-flight: USDC -> adapter token
        vm.broadcast(controllerKey);
        uint256 investId = vault.createInFlight(address(adapter), address(usdc), 500, 500e6, true);

        require(vault.totalInvestInFlight() == 500e6, "investInFlight wrong");
        console.log("[inflight] Created invest id:", investId, "| 500 USDC -> 500 tokens");
        console.log("[inflight] totalInvestInFlight:", vault.totalInvestInFlight() / 1e6);

        // Confirm invest with slight slippage (got 495 tokens instead of 500)
        vm.broadcast(controllerKey);
        vault.confirmInFlight(investId, 495);

        require(vault.totalInvestInFlight() == 0, "investInFlight not cleared");
        console.log("[inflight] Confirmed invest: actual 495 tokens. InFlight cleared.");

        // Redeem in-flight: adapter token -> USDC
        vm.broadcast(controllerKey);
        uint256 redeemId = vault.createInFlight(address(adapter), address(usdc), 200, 200e6, false);

        require(vault.totalRedeemInFlight() == 200e6, "redeemInFlight wrong");
        console.log("[inflight] Created redeem id:", redeemId, "| 200 tokens -> 200 USDC");

        vm.broadcast(controllerKey);
        vault.confirmInFlight(redeemId, 198e6);

        require(vault.totalRedeemInFlight() == 0, "redeemInFlight not cleared");
        console.log("[inflight] Confirmed redeem: actual 198 USDC. InFlight cleared.");

        // Cleanup
        vm.broadcast(controllerKey);
        vault.removeAdapter(address(adapter));
        console.log("[inflight] Adapter removed.");
    }

    // =============================================================
    // Scenario 8: Exchange Rate Update
    // =============================================================

    function _scenarioExchangeRateUpdate() internal {
        console.log("\n--- Scenario: Exchange Rate Update ---");

        uint256 oldRate = vault.exchangeRate();

        // +5% increase
        uint256 newRate = oldRate * 105 / 100;
        vm.broadcast(accountantKey);
        vault.updateExchangeRate(newRate);

        require(vault.exchangeRate() == newRate, "rate not updated");
        console.log("[rate] Updated:", oldRate, "->", newRate);

        // Verify share pricing changed
        uint256 assetsFor1000Shares = vault.previewRedeem(1_000e6);
        console.log("[rate] 1000 shares now worth", assetsFor1000Shares / 1e6, "USDC (net of fee)");

        // Try exceeding 10% limit
        uint256 tooHigh = newRate * 111 / 100;
        vm.broadcast(accountantKey);
        try vault.updateExchangeRate(tooHigh) {
            revert("should have reverted");
        } catch {
            console.log("[rate] Correctly rejected >10% change");
        }
    }

    // =============================================================
    // Scenario 9: Mint Fee Shares
    // =============================================================

    function _scenarioMintFeeShares() internal {
        console.log("\n--- Scenario: Mint Fee Shares ---");

        uint256 supply = vault.totalSupply();
        uint256 toMint = supply * 100 / 10_000; // 1% of supply

        vm.broadcast(accountantKey);
        vault.mintFeeShares(toMint);

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
        try vault.deposit(100e6, alice) {
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

        vault.setSanctionsOracle(address(newOracle));
        require(address(vault.sanctionsOracle()) == address(newOracle), "oracle not set");
        console.log("[admin] setSanctionsOracle:", address(newOracle));

        vault.setRedemptionFee(200);
        require(vault.redemptionFeeBps() == 200, "fee not set");
        console.log("[admin] setRedemptionFee: 200 bps (2%)");

        vault.setMinRedeemAmount(50e6);
        require(vault.minRedeemAmount() == 50e6, "minRedeem not set");
        console.log("[admin] setMinRedeemAmount: 50 USDC");

        // Restore original values for any subsequent use
        vault.setController(controller);
        vault.setAccountant(accountant);
        vault.setTreasury(treasury);
        vault.setSanctionsOracle(address(oracle));
        vault.setRedemptionFee(100);
        vault.setMinRedeemAmount(10e6);

        vm.stopBroadcast();

        console.log("[admin] All setters verified. Values restored.");
    }
}
