# Test Plan: VaultDepositWithdrawE2E

- **Contract**: `src/vault/MantleYieldVault.sol` + `src/protocol/StrategyController.sol`
- **Date**: 2026-03-12 (updated: 2026-03-20)
- **Author**: AI Agent
- **Status**: Approved (all paths passed — A, B, C)

## 1. Contract Summary

End-to-end integration test simulating a **real user** performing deposit → withdraw on the deployed MantleYieldVault (Ethereum Sepolia). Covers both sync withdraw (ERC-4626) and async redeem (ERC-7540) paths.

Since **OperatorExecutor's off-chain signing service is not yet developed**, all operator actions (rebalance, processRedeemBatch, finalizeRedeemBatch) are driven via **`cast` commands** directly against StrategyController, after temporarily granting `EXECUTOR_ROLE` to the admin address.

### Architecture Overview

```
User (USER_PRIVATE_KEY)
  │
  ├─ deposit(USDC) ──────────────► MantleYieldVault ◄── controller ── StrategyController
  ├─ withdraw(assets) ────────────►       │                                   │
  ├─ requestRedeem(shares) ───────►       │          EXECUTOR_ROLE            │
  └─ (no claimRedeem — finalizeRedeemBatch transfers directly) ───────►       │     ┌────(bypassed)────► OperatorExecutor
                                          │     │                       (off-chain N/A)
                                          │     │
Admin (ADMIN_PRIVATE_KEY)                 │     │
  │                                       │     │
  ├─ grantRole(EXECUTOR_ROLE) ───► StrategyController
  ├─ processRedeemBatch() ───────► StrategyController ─► vault.updateRequestBatch(PROCESSING)
  └─ finalizeRedeemBatch() ──────► StrategyController ─► vault.markRequestsDone()
```

## 2. Roles & Permissions

| Role | Address | Key |
|------|---------|-----|
| Vault Admin / DEFAULT_ADMIN_ROLE | `0x65Cf61678Cf120a8F40c2F3aEDCb50BBA0e85c78` | `ADMIN_PRIVATE_KEY` |
| Vault Controller | StrategyController proxy (from `plans/addresses.yaml`) | — |
| Vault Accountant | Accountant proxy (from `plans/addresses.yaml`) | — |
| StrategyController EXECUTOR_ROLE | OperatorExecutor (deployed), **+ Admin** (granted for testing) | `ADMIN_PRIVATE_KEY` |
| StrategyController STRATEGY_MANAGER_ROLE | Admin | `ADMIN_PRIVATE_KEY` |
| User (depositor / redeemer) | Derived from `USER_PRIVATE_KEY` | `USER_PRIVATE_KEY` |

## 3. Test Scope

### 3.1 Prerequisites — Environment Setup

```bash
source .env && eval $(yq -r 'to_entries|.[]|.key+"="+.value' plans/addresses.yaml)
RPC="https://eth-sepolia.g.alchemy.com/v2/XMS1J6f654XZolfd7oaMe-kaNPEpWifX"
ADMIN=$(cast wallet address $ADMIN_PRIVATE_KEY)
USER=$(cast wallet address $USER_PRIVATE_KEY)
```

> **Note**: `plans/addresses.yaml` contains duplicate keys from multiple deployments. Ensure the **last** occurrence of each key is the one used (e.g., the latest MantleYieldVault, StrategyController, etc.).

### 3.2 Pre-State Checks (`cast call`)

| # | Command | Purpose |
|---|---------|---------|
| 0a | `cast call $MantleYieldVault "exchangeRate()(uint256)" --rpc-url $RPC` | Confirm rate = 1e18 |
| 0b | `cast call $MantleVaultGateway "syncRedeemDisabled()(bool)" --rpc-url $RPC` | Confirm sync redeem enabled (on Gateway, NOT vault) |
| 0c | `cast call $MantleYieldVault "minDepositAmount()(uint256)" --rpc-url $RPC` | Expect 1e6 (1 USDC) |
| 0d | `cast call $MantleYieldVault "redemptionFeeBps()(uint256)" --rpc-url $RPC` | Expect 10 (0.1%) |
| 0e | `cast call $MantleYieldVault "getFreeCash()(uint256)" --rpc-url $RPC` | Current free cash |
| 0f | `cast call $MantleYieldVault "controller()(address)" --rpc-url $RPC` | Should == $StrategyController |
| 0g | `cast call $MockUSDC "balanceOf(address)(uint256)" $USER --rpc-url $RPC` | User's initial USDC |
| 0h | `cast call $MantleYieldVault "balanceOf(address)(uint256)" $USER --rpc-url $RPC` | User's initial shares |
| 0i | `cast call $MantleYieldVault "nextRequestId()(uint256)" --rpc-url $RPC` | Next request ID (for later) |

### 3.2a Prerequisites — Role & Cooldown Setup

> These one-time setup steps apply to **all** paths. Grant `EXECUTOR_ROLE` to admin (bypassing OperatorExecutor) and set `rebalanceCooldown` to 0 so that `rebalance()` can be called immediately after every deposit/withdraw.

| # | Actor | Action | `cast` Command | Verify |
|---|-------|--------|----------------|--------|
| S1 | Admin | Grant OPERATOR_EXECUTOR_ROLE on StrategyController | `cast send $StrategyController "grantRole(bytes32,address)" 0x59be4311d80f86d01d939721887b9fcf8da2080cdaaa31245adf42782da9a3ce $ADMIN --rpc-url $RPC --private-key $ADMIN_PRIVATE_KEY` | admin has OPERATOR_EXECUTOR_ROLE |
| S2 | Admin | Set rebalanceCooldown to 0, **bufferTargetBps=10000** for Paths A/B | `cast send $StrategyController "setRiskParams(uint16,uint16,uint64)" 10000 10 0 --rpc-url $RPC --private-key $ADMIN_PRIVATE_KEY` | `rebalanceCooldown() == 0`, `bufferTargetBps=10000` |
| S3 | Admin | Set Accountant risk params (10% deviation, 0 cooldown) | `cast send $Accountant "setRiskParams(uint32,uint32)" 1000 0 --rpc-url $RPC --private-key $ADMIN_PRIVATE_KEY` | `maxAllowedDeviation()==1000`, `minUpdateInterval()==0` |
| S4 | Admin | Set Accountant maxComputeAge to 1 day | `cast send $Accountant "setMaxComputeAge(uint32)" 86400 --rpc-url $RPC --private-key $ADMIN_PRIVATE_KEY` | `maxComputeAge()==86400` |
| S5 | Admin | **Initialize exchange rate** (required for fresh deployment — `lastComputeTimestamp=0` causes arithmetic underflow in deposit) | `cast send $Accountant "updateExchangeRate(uint64,uint64)" 1000000000000000000 $(($(date +%s)-60)) --rpc-url $RPC --private-key $ADMIN_PRIVATE_KEY` | `lastComputeTimestamp > 0` |

> **CORRECTION (2026-03-18)**: S2 now sets `bufferTargetBps=10000` (100% buffer) for Paths A & B. When an async adapter is registered with 100% weight, `bufferTargetBps=0` causes `rebalance()` to invest all vault USDC into the adapter, leaving no freeCash for sync withdraw in Path A. Setting `bufferTargetBps=10000` makes rebalance a no-op for investing. For Path C, reset to `bufferTargetBps=0` to enable invest behavior.
>
> **Note**: S3–S4 configure the Accountant to allow exchange rate updates up to 10% deviation with no cooldown and a relaxed compute-age window, enabling rate simulation during testing.

### 3.3 Path A — Deposit → Rebalance → Update Exchange Rate → Sync Withdraw → Rebalance

| # | Actor | Action | `cast` Command | Verify |
|---|-------|--------|----------------|--------|
| A1 | Admin | Mint 1000 USDC to User | `cast send $MockUSDC "mint(address,uint256)" $USER 1000000000 --rpc-url $RPC --private-key $ADMIN_PRIVATE_KEY` | `balanceOf(user) += 1000e6` |
| A2 | User | Approve **vault** (not gateway — vault pulls tokens via `transferFrom`) | `cast send $MockUSDC "approve(address,uint256)" $MantleYieldVault 1000000000 --rpc-url $RPC --private-key $USER_PRIVATE_KEY` | allowance set |
| A3 | User | Deposit 1000 USDC **via Gateway** | `cast send $MantleVaultGateway "deposit(uint256)" 1000000000 --rpc-url $RPC --private-key $USER_PRIVATE_KEY` | shares minted (1000e6 at rate=1e18) |
| A4 | — | Verify deposit | `cast call $MantleYieldVault "balanceOf(address)(uint256)" $USER --rpc-url $RPC` | == 1000e6 (+ any prior balance) |
| A5 | — | Verify vault USDC | `cast call $MockUSDC "balanceOf(address)(uint256)" $MantleYieldVault --rpc-url $RPC` | increased by 1000e6 |
| A6 | Admin | **Rebalance after deposit** | `cast send $StrategyController "rebalance()" --rpc-url $RPC --private-key $ADMIN_PRIVATE_KEY` | tx succeeds, `RebalanceEvaluated` emitted |
| A7 | — | Verify rebalance state | `cast call $StrategyController "lastRebalance()(uint64)" --rpc-url $RPC` | updated to recent timestamp |
| A8 | — | Verify freeCash after rebalance | `cast call $MantleYieldVault "getFreeCash()(uint256)" --rpc-url $RPC` | reflects post-rebalance distribution |
| A8a | Admin | **Update exchange rate to 1.02e18** (simulate 2% yield) | `cast send $Accountant "updateExchangeRate(uint64,uint64)" 1020000000000000000 $(($(date +%s)-60)) --rpc-url $RPC --private-key $ADMIN_PRIVATE_KEY` | tx succeeds, `ExchangeRateUpdated` emitted |
| A8b | — | Verify new exchange rate | `cast call $MantleYieldVault "exchangeRate()(uint256)" --rpc-url $RPC` | == 1020000000000000000 (1.02e18) |
| A8c | — | Verify Accountant rate | `cast call $Accountant "getRate()(uint64)" --rpc-url $RPC` | == 1020000000000000000 |
| A9 | — | Preview withdraw | `cast call $MantleYieldVault "previewWithdraw(uint256)(uint256)" 500000000 --rpc-url $RPC` | shares needed for 500 USDC (fewer than at rate=1e18) |
| A10 | User | Sync redeem via **Gateway** (no `withdraw` on vault) | `SHARES=$(cast call $MantleYieldVault "previewWithdraw(uint256)(uint256)" 500000000 --rpc-url $RPC \| awk '{print $1}') && cast send $MantleVaultGateway "redeem(uint256)" $SHARES --rpc-url $RPC --private-key $USER_PRIVATE_KEY` | USDC received, shares burned |
| A11 | Admin | **Rebalance after withdraw** | `cast send $StrategyController "rebalance()" --rpc-url $RPC --private-key $ADMIN_PRIVATE_KEY` | tx succeeds, `RebalanceEvaluated` emitted |
| A12 | — | Verify rebalance state | `cast call $StrategyController "lastRebalance()(uint64)" --rpc-url $RPC` | updated to recent timestamp |
| A13 | — | Verify freeCash after rebalance | `cast call $MantleYieldVault "getFreeCash()(uint256)" --rpc-url $RPC` | reflects post-withdraw rebalance |
| A14 | — | Verify USDC returned | `cast call $MockUSDC "balanceOf(address)(uint256)" $USER --rpc-url $RPC` | increased by 500e6 |
| A15 | — | Verify shares burned | `cast call $MantleYieldVault "balanceOf(address)(uint256)" $USER --rpc-url $RPC` | decreased |

**Expected**: After updating the exchange rate to 1.02e18 (2% yield), each share is worth 1.02 USDC instead of 1.0 USDC. Withdrawing 500 USDC now burns fewer shares: gross USDC = `500 * 10000 / 9990 ≈ 500.5` (with `redemptionFeeBps=10`), shares burned = `500.5e6 * 1e18 / 1.02e18 ≈ 490,686,274`. The fee stays in the vault. Use `previewWithdraw(500e6)` (step A9) to get the exact shares amount. Each `rebalance()` call emits `RebalanceEvaluated` with the current cash/assets state. If a strategy adapter is already registered and over-allocated (adapter value >> vault USDC), rebalance will be a no-op for investing and only updates `lastRebalance`.

### 3.4 Path B — Deposit → Rebalance → Update Exchange Rate → Async Redeem → Process → Finalize → Rebalance

| # | Actor | Action | `cast` Command | Verify |
|---|-------|--------|----------------|--------|
| B1 | Admin | Mint 1000 USDC to User | `cast send $MockUSDC "mint(address,uint256)" $USER 1000000000 --rpc-url $RPC --private-key $ADMIN_PRIVATE_KEY` | balance += 1000e6 |
| B2 | User | Approve + Deposit 1000 USDC via **Gateway** | (same as A2+A3, using gateway) | shares minted |
| B3 | Admin | **Rebalance after deposit** | `cast send $StrategyController "rebalance()" --rpc-url $RPC --private-key $ADMIN_PRIVATE_KEY` | tx succeeds, `RebalanceEvaluated` emitted |
| B4 | — | Verify rebalance state | `cast call $StrategyController "lastRebalance()(uint64)" --rpc-url $RPC` | updated to recent timestamp |
| B4a | Admin | **Update exchange rate to 1.02e18** (simulate 2% yield; skip if rate already 1.02e18 from Path A) | `cast send $Accountant "updateExchangeRate(uint64,uint64)" 1020000000000000000 $(($(date +%s)-60)) --rpc-url $RPC --private-key $ADMIN_PRIVATE_KEY` | tx succeeds, `ExchangeRateUpdated` emitted |
| B4b | — | Verify new exchange rate | `cast call $MantleYieldVault "exchangeRate()(uint256)" --rpc-url $RPC` | == 1020000000000000000 (1.02e18) |
| B5 | — | Record `nextRequestId` | `cast call $MantleYieldVault "nextRequestId()(uint256)" --rpc-url $RPC` | save as `$REQ_ID` |
| B6 | User | Request async redeem (500 shares) via **Gateway** | `cast send $MantleVaultGateway "requestRedeem(uint256)" 500000000 --rpc-url $RPC --private-key $USER_PRIVATE_KEY` | request created with status=PENDING |
| B7 | — | Verify request | `cast call $MantleYieldVault "requests(uint256)(uint256,address,uint256,uint256,uint256,uint256,uint8)" $REQ_ID --rpc-url $RPC` | status=1 (PENDING), shares=500e6 |
| B8 | — | Compute estimatedAssets | 500e6 shares × 1.02e18 / 1e18 = 510e6 gross; fee = 510e6 × 10 / 10000 = 510000; net = 509490000 | ~509.49 USDC |
| B9 | Admin | processRedeemBatch | `cast send $StrategyController "processRedeemBatch(uint256[])" "[$REQ_ID]" --rpc-url $RPC --private-key $ADMIN_PRIVATE_KEY` | request → PROCESSING |
| B10 | — | Verify request status | `cast call $MantleYieldVault "requests(uint256)(uint256,address,uint256,uint256,uint256,uint256,uint8)" $REQ_ID --rpc-url $RPC` | status=2 (PROCESSING) |
| B11 | Admin | finalizeRedeemBatch (calls `markRequestsDone` — transfers USDC directly to user, no separate claim step) | `cast send $StrategyController "finalizeRedeemBatch(uint256[],uint256[])" "[$REQ_ID]" "[509490000]" --rpc-url $RPC --private-key $ADMIN_PRIVATE_KEY` | request → DONE, settledAssets set, USDC transferred |
| B12 | — | Verify request status | same as B10 | status=3 (DONE), settledAssets ≈ 509490000 |
| B13 | Admin | **Rebalance after finalize** | `cast send $StrategyController "rebalance()" --rpc-url $RPC --private-key $ADMIN_PRIVATE_KEY` | tx succeeds, `RebalanceEvaluated` emitted |
| B14 | — | Verify rebalance state | `cast call $StrategyController "lastRebalance()(uint64)" --rpc-url $RPC` | updated to recent timestamp |
| B15 | — | Verify freeCash after rebalance | `cast call $MantleYieldVault "getFreeCash()(uint256)" --rpc-url $RPC` | reflects post-finalize rebalance |
| B16 | — | Verify USDC received | `cast call $MockUSDC "balanceOf(address)(uint256)" $USER --rpc-url $RPC` | increased by ~509.49 USDC |

### 3.5 Path C — Full Async Adapter Flow (SubRedManagementAdapter + MockSubRedManagement)

> **Prerequisite**: Deploy `SubRedManagementAdapter` + `MockSubRedManagement` + `MockERC20Mintable` (ST token). Register adapter on StrategyController. Add addresses to `plans/addresses.yaml`: `$SubRedAdapter`, `$MockSubRedManagement`, `$MockSTToken`.

```
Deposit → Rebalance (invest) → settleSubscribe (off-chain settlement)
→ settleAdapter (sweep ST token to vault) → Update Exchange Rate
→ Async Redeem → processRedeemBatch → finalizeRedeemBatch
→ Claim → Rebalance
```

#### Architecture — Async Adapter Settle Flow

```
Admin (rebalance)
  │
  ├─ rebalance() ──────────────► StrategyController
  │                                   │  _invest() ──► adapter.deposit(amount, adapter)
  │                                   │                    │  ASSET.transferFrom(vault → adapter)
  │                                   │                    │  _subscribe(amount, deadline)
  │                                   │                    │     └─ SubRed.subscribe(stToken, USDC, amount, deadline)
  │                                   │                    │        └─ USDC transferred: adapter → MockSubRedManagement
  │                                   │  _recordInvestInFlight(adapter, usdcAmt, posAmt)
  │                                   │     └─ vault.recordInFlight(adapter, posAmt, usdcAmt, true)
  │
  │  ─── T+N settlement delay (simulated) ───
  │
  ├─ settleSubscribe() ───────► MockSubRedManagement
  │    (off-chain / admin)          │  mint ST token → adapter (receiver)
  │                                 │  emit SubscribeSettled
  │
  ├─ settleAdapter() ─────────► StrategyController
  │    (via OperatorExecutor        │  _sweepAdapterAssetsToVaultInternal(adapter, posAmount, 0)
  │     or admin w/ EXECUTOR_ROLE)  │     └─ adapter.sweepToVault(posToken, posAmount)
  │                                 │        └─ ST token: adapter → vault (if any residual on adapter)
  │                                 │  _confirmInvestInFlightIds(adapter, investInFlightIds)
  │                                 │     └─ vault.confirmInFlight(id, posAmount, true)
  │                                 │        └─ clears adapterInvestInFlightTokens
  │
  └─ (now vault holds ST tokens, freeCash available for withdraw)
```

#### C — Setup Steps

> **CORRECTION (2026-03-18)**: Before Path C, reset `bufferTargetBps` to 0 so rebalance invests into the adapter.

| # | Actor | Action | Command | Verify |
|---|-------|--------|---------|--------|
| C00 | Admin | **Set bufferTargetBps=0** (enable invest) | `cast send $StrategyController "setRiskParams(uint16,uint16,uint64)" 0 10 0 --rpc-url $RPC --private-key $ADMIN_PRIVATE_KEY` | `bufferTargetBps()==0` |
| C0a | Admin | Register adapter on StrategyController (100% weight, async=true). **NOTE**: `registerStrategy` has 4 params (not 5); it auto-calls `vault.registerAdapter()`. Use `activateStrategy` separately. | `cast send $StrategyController "registerStrategy(address,uint16,uint16,bool)" $SubRedAdapter 10000 0 true --rpc-url $RPC --private-key $ADMIN_PRIVATE_KEY && cast send $StrategyController "activateStrategy(address)" $SubRedAdapter --rpc-url $RPC --private-key $ADMIN_PRIVATE_KEY` | adapter registered + activated, `isAsync=true`, `vault.isAdapter(adapter)==true` |
| C0b | Admin | Set strategy order | `cast send $StrategyController "setStrategyOrder(address[])" "[$SubRedAdapter]" --rpc-url $RPC --private-key $ADMIN_PRIVATE_KEY` | order set |

#### C — Deposit + Rebalance (Invest) + Async Settlement

| # | Actor | Action | `cast` Command | Verify |
|---|-------|--------|----------------|--------|
| C1 | Admin | Mint 1000 USDC to User | `cast send $MockUSDC "mint(address,uint256)" $USER 1000000000 --rpc-url $RPC --private-key $ADMIN_PRIVATE_KEY` | `balanceOf(user) += 1000e6` |
| C2 | User | Approve + Deposit 1000 USDC | (same as A2+A3) | shares minted |
| C3 | Admin | **Rebalance (triggers invest → adapter.deposit → subscribe)** | `cast send $StrategyController "rebalance()" --rpc-url $RPC --private-key $ADMIN_PRIVATE_KEY` | tx succeeds, `RebalanceEvaluated` + `InvestExecuted` emitted |
| C4 | — | Verify USDC moved to MockSubRedManagement | `cast call $MockUSDC "balanceOf(address)(uint256)" $MockSubRedManagement --rpc-url $RPC` | received invest amount |
| C5 | — | Verify vault freeCash reduced | `cast call $MantleYieldVault "getFreeCash()(uint256)" --rpc-url $RPC` | reduced (USDC sent to adapter → SubRed) |
| C6 | — | Verify investInFlight recorded | `cast call $MantleYieldVault "adapterInvestInFlightTokens(address)(uint256)" $SubRedAdapter --rpc-url $RPC` | > 0 (pending ST tokens) |
| C7 | Off-chain | **settleSubscribe — BLOCKED** (requires off-chain settlement service; `SubRedManagement.settleSubscribe` cannot be called directly via `cast` — the deployed contract interface differs from source and/or has access control requiring the off-chain service). **Test pauses here until off-chain settlement completes.** | _off-chain service triggers settlement_ | ST token minted to adapter |
| C8 | — | Verify adapter received ST token | `cast call $MockSTToken "balanceOf(address)(uint256)" $SubRedAdapter --rpc-url $RPC` | == minted amount |
| C9 | — | Read investInFlight ID | `cast call $MantleYieldVault "nextInFlightId()(uint256)" --rpc-url $RPC` | save `$IN_FLIGHT_ID = nextInFlightId - 1` |
| C10 | Admin | **settleAdapter — sweep ST tokens to vault + confirm investInFlight** (combined in one tx; guard requires investInFlightIds when posAmount > 0 and in-flights exist) | `cast send $StrategyController "settleAdapter(address,uint256,uint256,uint256[],uint256[])" $SubRedAdapter $ST_AMOUNT 0 "[$IN_FLIGHT_ID]" "[]" --rpc-url $RPC --private-key $ADMIN_PRIVATE_KEY` | ST tokens swept to vault, investInFlight confirmed |
| C11 | — | Verify investInFlight cleared | `cast call $MantleYieldVault "adapterInvestInFlightTokens(address)(uint256)" $SubRedAdapter --rpc-url $RPC` | == 0 |
| C12 | — | Verify adapter totalValue | `cast call $SubRedAdapter "totalValue()(uint256)" --rpc-url $RPC` | > 0 (ST token value in vault) |

#### C — Update Rate + Async Redeem (with redeem settlement)

| # | Actor | Action | `cast` Command | Verify |
|---|-------|--------|----------------|--------|
| C13 | Admin | **Update exchange rate to 1.02e18** (simulate 2% yield) | `cast send $Accountant "updateExchangeRate(uint64,uint64)" 1020000000000000000 $(($(date +%s)-60)) --rpc-url $RPC --private-key $ADMIN_PRIVATE_KEY` | `ExchangeRateUpdated` emitted |
| C14 | — | Verify new exchange rate | `cast call $MantleYieldVault "exchangeRate()(uint256)" --rpc-url $RPC` | == 1020000000000000000 |
| C15 | — | Record `nextRequestId` | `cast call $MantleYieldVault "nextRequestId()(uint256)" --rpc-url $RPC` | save as `$REQ_ID` |
| C16 | User | Request async redeem (500 shares) via Gateway | `cast send $MantleVaultGateway "requestRedeem(uint256)" 500000000 --rpc-url $RPC --private-key $USER_PRIVATE_KEY` | request created with status=PENDING |
| C17 | — | Verify request | `cast call $MantleYieldVault "requests(uint256)(uint256,address,uint256,uint256,uint256,uint256,uint8)" $REQ_ID --rpc-url $RPC` | status=1 (PENDING), shares=500e6 |
| C18 | Admin | **processRedeemBatch** (triggers divest → `adapter.requestRedeemAsync` → `SubRed.redeem`) | `cast send $StrategyController "processRedeemBatch(uint256[])" "[$REQ_ID]" --rpc-url $RPC --private-key $ADMIN_PRIVATE_KEY` | request → PROCESSING, `AsyncRedeemRequested` emitted, redeemInFlight created |
| C18a | Off-chain | **settleRedeem — BLOCKED** (requires off-chain settlement service; same limitation as C7) | _off-chain service triggers settlement_ | USDC sent to adapter |
| C18b | — | Verify adapter received USDC | `cast call $MockUSDC "balanceOf(address)(uint256)" $SubRedAdapter --rpc-url $RPC` | == 509490000 |
| C18c | Admin | **settleAdapter** (sweep USDC from adapter to vault + confirm redeemInFlight) | `cast send $StrategyController "settleAdapter(address,uint256,uint256,uint256[],uint256[])" $SubRedAdapter 0 509490000 "[]" "[$REDEEM_INFLIGHT_ID]" --rpc-url $RPC --private-key $ADMIN_PRIVATE_KEY` | USDC swept to vault, redeemInFlight cleared |
| C18d | — | Verify vault has enough USDC | `cast call $MockUSDC "balanceOf(address)(uint256)" $MantleYieldVault --rpc-url $RPC` | >= 509490000 |
| C19 | Admin | **finalizeRedeemBatch** (vault must have sufficient USDC) | `cast send $StrategyController "finalizeRedeemBatch(uint256[],uint256[])" "[$REQ_ID]" "[509490000]" --rpc-url $RPC --private-key $ADMIN_PRIVATE_KEY` | request → DONE, USDC transferred to user via `markRequestsDone` |
| C20 | — | Verify request status | `cast call $MantleYieldVault "requests(uint256)(uint256,address,uint256,uint256,uint256,uint256,uint8)" $REQ_ID --rpc-url $RPC` | status=3 (DONE), settledAssets = 509490000 |
| C21 | Admin | **Rebalance after finalize** | `cast send $StrategyController "rebalance()" --rpc-url $RPC --private-key $ADMIN_PRIVATE_KEY` | tx succeeds |
| C22 | — | Verify USDC received | `cast call $MockUSDC "balanceOf(address)(uint256)" $USER --rpc-url $RPC` | increased by ~509.49 USDC |
| C23 | — | Verify shares burned | `cast call $MantleYieldVault "balanceOf(address)(uint256)" $USER --rpc-url $RPC` | decreased by 500e6 |

> **CRITICAL**: Steps C18a–C18d are required for async adapters. `processRedeemBatch` triggers `requestRedeemAsync` on the adapter which calls `SubRed.redeem()` — this only submits a redeem request. The actual USDC doesn't return until `settleRedeem` (off-chain settlement) and `settleAdapter` (sweep to vault). `finalizeRedeemBatch` will **revert with `InsufficientCashForReady`** if the vault doesn't hold enough USDC. There is no separate "claim" step — `finalizeRedeemBatch` calls `markRequestsDone` which transfers USDC directly to the user.

**Expected**: The key difference from Paths A/B is that **both invest and divest are asynchronous**:

- **Invest flow**: `rebalance()` → `adapter.deposit()` → `SubRed.subscribe()` — USDC leaves vault → adapter → SubRed. After T+N settlement, `settleSubscribe()` mints ST tokens to adapter. Then `settleAdapter()` sweeps ST tokens from adapter to vault and confirms investInFlight.
- **Divest flow**: `processRedeemBatch()` → `adapter.requestRedeemAsync()` → `SubRed.redeem()` — ST tokens leave vault → adapter → SubRed. After T+N settlement, `settleRedeem()` sends USDC to adapter. Then `settleAdapter()` sweeps USDC to vault and confirms redeemInFlight. Only then can `finalizeRedeemBatch()` succeed.

### 3.6 `cast` Verification Commands (Post-Test Snapshot)

```bash
source .env && eval $(yq -r 'to_entries|.[]|.key+"="+.value' plans/addresses.yaml)
RPC="https://eth-sepolia.g.alchemy.com/v2/XMS1J6f654XZolfd7oaMe-kaNPEpWifX"
USER=$(cast wallet address $USER_PRIVATE_KEY)

# Vault state
cast call $MantleYieldVault "totalSupply()(uint256)" --rpc-url $RPC
cast call $MantleYieldVault "totalAssets()(uint256)" --rpc-url $RPC
cast call $MantleYieldVault "getFreeCash()(uint256)" --rpc-url $RPC
cast call $MantleYieldVault "exchangeRate()(uint256)" --rpc-url $RPC
cast call $MantleYieldVault "totalLockedShares()(uint256)" --rpc-url $RPC
# NOTE: claimableReserves() does not exist on vault
cast call $MantleYieldVault "nextRequestId()(uint256)" --rpc-url $RPC

# User balances
cast call $MockUSDC "balanceOf(address)(uint256)" $USER --rpc-url $RPC
cast call $MantleYieldVault "balanceOf(address)(uint256)" $USER --rpc-url $RPC

# Controller state
cast call $StrategyController "lastRebalance()(uint64)" --rpc-url $RPC
cast call $StrategyController "bufferTargetBps()(uint16)" --rpc-url $RPC
cast call $StrategyController "rebalanceCooldown()(uint64)" --rpc-url $RPC
```

## 4. Mocks Required

Paths A & B run against deployed contracts with no additional mocks. Path C additionally requires:

| Contract | Address Source | Notes |
|----------|---------------|-------|
| MockERC20Mintable (MockUSDC) | `plans/addresses.yaml` | Vault underlying asset |
| MockERC20Mintable (MockSTToken) | `plans/addresses.yaml` | ST token (position token for adapter) |
| MockSubRedManagement | `plans/addresses.yaml` | Simulates Digift SubRed subscribe/redeem + settlement |
| SubRedManagementAdapter | `plans/addresses.yaml` | Async adapter wired to MockSubRedManagement |
| SanctionsOracle | `plans/addresses.yaml` | — |
| MantleYieldVault | `plans/addresses.yaml` | — |
| StrategyController | `plans/addresses.yaml` | — |

## 5. Dependencies & Preconditions

| Item | Requirement |
|------|-------------|
| `.env` | Must contain `ADMIN_PRIVATE_KEY` and `USER_PRIVATE_KEY` |
| `plans/addresses.yaml` | Must have correct deployed proxy addresses |
| `yq` | Installed (for YAML → env var export) |
| `cast` (Foundry) | Installed |
| User not sanctioned | SanctionsOracle must return `false` for User address |
| Vault not paused | `vault.paused() == false` |
| `syncRedeemDisabled == false` | Required for Path A |
| FreeCash ≥ withdrawal amount | Required for Path A sync withdraw |
| Path C only | Deployed SubRedManagementAdapter + MockSubRedManagement + MockSTToken |

## 6. Risks & Notes

1. **Duplicate keys in `addresses.yaml`**: The file contains two sets of deployed addresses (old and new). When loading with `yq`, the **last** occurrence wins. Verify the loaded addresses match the intended deployment.

2. **OperatorExecutor bypass**: We grant `EXECUTOR_ROLE` directly to admin on StrategyController, bypassing OperatorExecutor's EIP-712 signature verification. This is a **testing shortcut only** — production must use OperatorExecutor with proper signatures.

3. **Request ID tracking**: `requestRedeem` returns the request ID. When using `cast send`, extract it from `nextRequestId()` **before** calling `requestRedeem`, since `cast send` doesn't directly return Solidity return values.

4. **Array encoding in `cast`**: `cast send` encodes Solidity arrays as `"[1]"` or `"[1,2,3]"`. If encoding fails, use explicit ABI encoding: `cast abi-encode "f(uint256[])" "[1]"`.

5. **Rebalance cooldown**: Default `rebalanceCooldown = 3600` (1 hour). Step S2 sets it to **0** for testing, so `rebalance()` can be called immediately after every deposit/withdraw without `CooldownNotElapsed` reverts. In production, check `lastRebalance` before calling.

6. **Redemption fee**: `redemptionFeeBps = 10` (0.1%). Both sync and async redemptions deduct this fee. The `estimatedAssets` in a request already has the fee deducted.

7. **Path C adapter deployment**: Requires SubRedManagementAdapter + MockSubRedManagement + MockSTToken deployed on Ethereum Sepolia. The `settleSubscribe` receiver should be the **adapter** address (ST tokens are minted to adapter, then swept to vault by `settleAdapter`). The `settleAdapter` call sweeps ST tokens from adapter to vault and confirms `investInFlightIds`.

8. **Async settle ordering**: After `rebalance()` invests into the adapter, the flow **must** wait for `settleSubscribe` (off-chain/mock settlement) and then `settleAdapter` (confirm in-flight) before proceeding to withdraw. Withdrawing before settlement will fail or produce incorrect accounting because `adapterInvestInFlightTokens` is still non-zero.

9. **CRITICAL — Gateway-only user interactions**: `deposit()`, `withdraw()`, `redeem()`, and `requestRedeem()` on `MantleYieldVault` are all `pure` functions that revert with `Vault__NotAuthorized`. ALL user interactions must go through `MantleVaultGateway`. There is no `withdraw()` on the gateway — use `gateway.redeem(shares, receiver, owner)` for sync redemptions (by shares, not by assets).

10. **No `claimRedeem` step**: The `finalizeRedeemBatch` function calls `vault.markRequestsDone()` which directly transfers USDC to the user. There is no separate claim step. The request status enum is: `NONE(0) → PENDING(1) → PROCESSING(2) → DONE(3)`. There are no `READY` or `CLAIMED` statuses.

11. **`updateExchangeRate` timestamp**: Using `$(date +%s)` for the compute timestamp can cause `FutureComputeTimestamp` errors if the local clock is ahead of the block timestamp. Use `$(($(date +%s)-60))` to ensure the timestamp is safely in the past.

12. **CRITICAL — Fresh deployment requires exchange rate initialization**: On a freshly deployed Accountant, `lastComputeTimestamp = 0`. The vault's `_settleManagementFee` computes `block.timestamp - lastComputeTimestamp` which can cause arithmetic overflow in the ERC4626 deposit path. **Always call `updateExchangeRate` before the first deposit** (added as step S5).

13. **CRITICAL — USDC approval must target Vault, not Gateway**: The Gateway calls `vault.depositFor(caller, assets, receiver)`, and the Vault executes `IERC20.transferFrom(caller, vault, assets)`. Therefore, the user must approve the **Vault** address, not the Gateway. Approving the Gateway will cause an arithmetic underflow revert in `transferFrom`.

14. **Path C — SubRedManagement settlement is off-chain only**: The `SubRedManagement` contract's `settleSubscribe` and `settleRedeem` functions are triggered by an external off-chain service. They cannot be called directly via `cast send` in E2E testing. Path C tests must pause after `rebalance()` (invest) at step C7 and after `processRedeemBatch()` (divest) at step C18a, waiting for the off-chain settlement service to complete before proceeding with `settleAdapter` and `finalizeRedeemBatch`.
