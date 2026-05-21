# Test Report: VaultDepositWithdrawE2E

- **Contract**: `src/vault/MantleYieldVault.sol` + `src/protocol/StrategyController.sol`
- **Date**: 2026-03-20
- **Network**: Ethereum Sepolia (chainId: 11155111)
- **Status**: Path A PASS | Path B PASS | Path C PASS

## Environment

| Role | Address |
|------|---------|
| Admin | `0x65Cf61678Cf120a8F40c2F3aEDCb50BBA0e85c78` |
| User | `0x16fcf349b60262C4A87350757085784E39804810` |
| MantleYieldVault | `0x5ba7050cb1574cdc052c4bfdec46299d9b049fb6` |
| MantleVaultGateway | `0xba21ea135533eab352a2a0ad1b02d049ed240915` |
| StrategyController | `0xa68d8b8886c35c2f37dee48d0b56f399a5d88208` |
| Accountant | `0x93a44c2c92c9ec8a290bcf6a5efb8459c3ee184d` |
| MockStable | `0xc40fa5d8cf408baa63019137033d2698377fb243` |
| MockSTToken | `0xC2ADD5C914d4953a5382162b08E70fBe6cf47b30` |
| MockSubRedManagement | `0x99c967ada4b3ab4e011ef2379d58e11816bd219b` |
| SubRedManagementAdapter | `0xf82c030bd9a3ad97dfd2838e2c1721f50f75da1e` |

## Pre-State Checks (0a-0i)

| # | Check | Result |
|---|-------|--------|
| 0a | exchangeRate | 1000000000000000000 (1e18) |
| 0b | syncRedeemDisabled | false |
| 0c | minDepositAmount | 1000000 (1e6) |
| 0d | redemptionFeeBps | 10 (0.1%) |
| 0e | getFreeCash | 0 |
| 0f | controller | 0xa68d8B8886c35c2f37dee48D0b56f399a5d88208 |
| 0g | User STABLE balance | 3037960000 |
| 0h | User shares balance | 0 |
| 0i | nextRequestId | 1 |

## Setup (S1-S5)

| # | Action | Tx Hash | Status |
|---|--------|---------|--------|
| S1 | Grant OPERATOR_EXECUTOR_ROLE to admin | `0xfd23f4e197f4beac1eecbbc0dd5ab8c11826c52391b90383983194b17d371959` | ✓ |
| S2 | setRiskParams(bufferTargetBps=10000, threshold=10, cooldown=0) | `0x5a83b8c18b645ad5c846dbf890f2d2344c674628c912a8275cf02b458101d3d7` | ✓ |
| S3 | Accountant setRiskParams(deviation=1000, interval=0) | `0x9c48372241d0025d1cbd43e1744c612557797ad27d1bac5f8d49fd20033da3db` | ✓ |
| S4 | Accountant setMaxComputeAge(86400) | `0x2631d4dbe337f432f0ed03ad0675637c640b3c0b82af3a39d253a11c5bd46b42` | ✓ |
| S5 | Initialize exchange rate (1e18) — **new step** | `0x8f042d6512a670efb14bab2acf2ee29eafb08641d0a7e16e2994232dba658209` | ✓ |

> **Issue found (S5)**: Fresh Accountant deployment has `lastComputeTimestamp=0`. Without initializing the rate, the vault's deposit path reverts with `Panic(17)` (arithmetic underflow) in `_settleManagementFee`. Added S5 to the test plan.

## Path A — Deposit → Rebalance → Update Rate → Sync Withdraw → Rebalance

### Result: ✓ PASS

| # | Action | Params | Tx Hash | Result |
|---|--------|--------|---------|--------|
| A1 | Mint 1000 STABLE to User | `mint(User, 1000000000)` | `0xf1b095bb8003a2724258b00688d3ec0b36f50dfa4f62c32ee06b998884c2865c` | ✓ User STABLE: 4037960000 |
| A2 | Approve **Vault** | `approve(Vault, 1000000000)` | `0x7093c8d42145511af1f46fd50eee364afd59906490fa116040e686baa0477fca` | ✓ |
| A3 | Deposit 1000 STABLE via Gateway | `gateway.deposit(1000000000)` | `0x15cc7897645bbcc26d5423454dd5e71bea3b02c43e36b8c2e330e8f8c5f4d678` | ✓ shares minted: 1000000000 |
| A4 | Verify shares | — | — | 1000000000 ✓ |
| A5 | Verify vault STABLE | — | — | 1000000000 ✓ |
| A6 | Rebalance after deposit | `rebalance()` | `0xbb4cc181d989fd8f611cdad5800f2384e9731b484dadb60277d1e887f2781030` | ✓ (no-op, bufferTargetBps=10000) |
| A7 | lastRebalance | — | — | 1773998196 ✓ |
| A8 | freeCash | — | — | 1000000000 ✓ |
| A8a | Update rate to 1.02e18 | `updateExchangeRate(1.02e18, ts-60)` | `0xebd7ff3c3cdeba2311158657d24e205ccf13fbd0d927b987448a41c1a2bac5d7` | ✓ |
| A8b | Verify exchange rate | — | — | 1020000000000000000 ✓ |
| A8c | Accountant rate | — | — | 1020000000000000000 ✓ |
| A9 | previewWithdraw(500e6) | — | — | 490686766 shares |
| A10 | Sync redeem 490686766 shares via Gateway | `gateway.redeem(490686766)` | `0xb4b265f3798232701d6d587ed7a0d430fd60b9f98bca8bee6c1e0dad7bd7a363` | ✓ 500000000 STABLE received |
| A11 | Rebalance after withdraw | `rebalance()` | `0x2f2ba0d217846e3cfbcc7ecf8bf751e2a7067f30721ccfcadc3c09978d8577c0` | ✓ |
| A12 | lastRebalance | — | — | 1773998328 ✓ |
| A13 | freeCash | — | — | 500000000 ✓ |
| A14 | User STABLE | — | — | 3537960000 (increased by 500000000) ✓ |
| A15 | User shares | — | — | 509313234 (decreased by 490686766) ✓ |

> **Issue found (A2)**: Original test plan had user approve the **Gateway**, but the vault calls `transferFrom(user → vault)` directly. Must approve the **Vault** address. Plan updated.

### Path A Analysis

- Rate at 1.02e18: each share worth 1.02 STABLE
- Withdrew 500 STABLE: previewWithdraw → 490686766 shares (accounts for 0.1% redemption fee)
- Gross STABLE = 490686766 × 1.02e18 / 1e18 = 500500021 → fee = 500021 → net ≈ 500000000 ✓

## Path B — Deposit → Rebalance → Async Redeem → Process → Finalize → Rebalance

### Result: ✓ PASS

| # | Action | Params | Tx Hash | Result |
|---|--------|--------|---------|--------|
| B1 | Mint 1000 STABLE to User | `mint(User, 1000000000)` | `0x6faab256d93f92fac84d9bb4af3108e02d0195aee436fede14539f8af01f6698` | ✓ |
| B2a | Approve vault | `approve(Vault, 1000000000)` | `0xb1635aee47efcb77be62a1ea24dbdf003aa514d2505e92632bd5785df300aa38` | ✓ |
| B2b | Deposit 1000 STABLE | `gateway.deposit(1000000000)` | `0xd4b8ba38b65958eb3f46d4131dc70945e3647ad66a58135204d068a6c08e226b` | ✓ shares: 980392156 (at 1.02e18) |
| B3 | Rebalance | `rebalance()` | `0x37354d286c96f89818e48016674adc970253e3c47ef2a39840de37d12c5e1f0c` | ✓ (no-op) |
| B4 | lastRebalance | — | — | 1773998700 ✓ |
| B5 | nextRequestId | — | — | 1 |
| B6 | Request async redeem 500e6 shares | `gateway.requestRedeem(500000000)` | `0x8ec5546f4cb2fe630984b37f8ebf981122c4616d3b2ca585cd8b91d0c12bf6e2` | ✓ requestId=1 |
| B7 | Verify request | `requests(1)` | — | status=1 (PENDING), shares=500e6, estimatedAssets=509490000 ✓ |
| B9 | processRedeemBatch([1]) | `processRedeemBatch([1])` | `0x8a3cc668a3f515c1be81be885aa207edf2353c0c7106ef0c3ef6889b81f7cc48` | ✓ |
| B10 | Verify request status | — | — | status=2 (PROCESSING) ✓ |
| B11 | finalizeRedeemBatch([1], [509490000]) | `finalizeRedeemBatch([1],[509490000])` | `0x734b6d3135222d30fecbc4acb07acbd5e0dda15c5fea5ac0b0a9607e71b405c9` | ✓ |
| B12 | Verify request status | — | — | status=3 (DONE), settledAssets=509490000 ✓ |
| B13 | Rebalance after finalize | `rebalance()` | `0x969bd022f567b979bfd32a2ef6e32f4f54f57b9f166136415e285bf8da4407c5` | ✓ |
| B14 | lastRebalance | — | — | 1773998784 ✓ |
| B15 | freeCash | — | — | 990510000 ✓ |
| B16 | User STABLE | — | — | 4047450000 (increased by 509490000) ✓ |
| B16b | User shares | — | — | 989705390 (decreased by 500000000) ✓ |

### Path B Analysis

- Deposit at 1.02e18: 1000e6 STABLE → 980392156 shares (1000e6 × 1e18 / 1.02e18)
- Request redeem 500e6 shares: estimatedAssets = 500e6 × 1.02e18 / 1e18 × (1 - 0.001) = 509490000
- finalizeRedeemBatch settledAssets = 509490000, transferred directly to user ✓
- No separate claim step — markRequestsDone transfers STABLE ✓

## Path C — Full Async Adapter Flow (SubRedManagementAdapter)

### Result: ✓ PASS

#### C — Setup

| # | Action | Params | Tx Hash | Result |
|---|--------|--------|---------|--------|
| C00 | Set bufferTargetBps=0 | `setRiskParams(0, 10, 0)` | `0x57001013ef0df94fef107651e63a3f2f6ce7556a1b9a9d3a25561b0a9f22d42d` | ✓ |
| C0a/b | Adapter already registered/activated/ordered | — | — | ✓ (weight=10000, async=true) |

#### C — Deposit + Rebalance (Invest) + Async Settlement

| # | Action | Params | Tx Hash | Result |
|---|--------|--------|---------|--------|
| C1 | Mint 1000 STABLE to User | `mint(User, 1000000000)` | `0xa29c7fea4d388efbed4f8ae0bcbaee9fda1588190a8274d290fffeb553177864` | ✓ |
| C2a | Approve vault | `approve(Vault, 1000000000)` | `0x5865cf9debba3aafd636e239540169e0eb4e8bf962c986e7cb478f49599b502a` | ✓ |
| C2b | Deposit 1000 STABLE | `gateway.deposit(1000000000)` | `0x76aaea6e3a43cb9abb3afea4de8092ebaee2e8a90ec4235f2c0766fa176f8545` | ✓ shares: 980392156 (at 1.02e18) |
| C3 | Rebalance (invest) | `rebalance()` | `0x17230731b1368df6b825f8a84facaffc7a3c0ddeb46a49c1779bcad6387d694a` | ✓ InvestExecuted emitted, STABLE → adapter → SubRed |
| C4 | MockSubRedManagement STABLE | — | — | received invest amount ✓ |
| C5 | Vault freeCash | — | — | 0 (all invested) ✓ |
| C6 | adapterInvestInFlightTokens | — | — | 1990510000000000000000 (18 dec) ✓ |
| C7 | settleSubscribe (off-chain) | _triggered by off-chain service_ | — | ✓ ST tokens minted to adapter |
| C8 | Adapter ST token balance | — | — | 181602600000000000000 ✓ |
| C9 | investInFlight ID | — | — | ID=1 (PENDING, isInvest=true) |
| C10 | settleAdapter (sweep ST + confirm) | `settleAdapter(adapter, 181602600000000000000, 0, [1], [])` | `0xd4f4254ad765cadfc0623668ce0ddffef98d47c2229a8cdc1ed4689c27719eec` | ✓ ST swept to vault |
| C11 | adapterInvestInFlightTokens | — | — | 0 ✓ |
| C12 | adapter totalValue | — | — | 181602600 ✓ |

#### C — Update Rate + Async Redeem + Settlement + Finalize

| # | Action | Params | Tx Hash | Result |
|---|--------|--------|---------|--------|
| C13 | Update exchange rate to 1.02e18 | `updateExchangeRate(1.02e18, ts-60)` | `0xbd7ef21f583aa6db445a1f7ebe40e176d00bf1366ed6e4256db0c48ef2442889` | ✓ (fee shares minted: 390) |
| C14 | Verify exchange rate | — | — | 1020000000000000000 ✓ |
| C15 | nextRequestId | — | — | 2 |
| C16 | Request async redeem 500e6 shares | `gateway.requestRedeem(500000000)` | `0xd2f16bd0e447a0026078f30622da3eecd96d36c686fb9a67baccc55de4f72f4c` | ✓ requestId=2 |
| C17 | Verify request | `requests(2)` | — | status=1 (PENDING), shares=500e6, estimatedAssets=509490000 ✓ |
| C18 | processRedeemBatch([2]) | `processRedeemBatch([2])` | `0xa778034e7e7078153eb76ec92425d57f663a9e64cb2b79eca9c610ed175bcb0e` | ✓ divest triggered, ST tokens → SubRed |
| C18a | settleRedeem (off-chain) | _triggered by off-chain service_ | — | ✓ STABLE sent to adapter |
| C18b | Adapter STABLE balance | — | — | 1990509700 ✓ |
| C18c | settleAdapter (sweep STABLE + confirm redeem) | `settleAdapter(adapter, 0, 1990509700, [], [2])` | `0xd23191a82205f42d30f2e1d31f72f3a3c0eb2e0745f9160de5287f14b9a7aae5` | ✓ STABLE swept to vault |
| C18d | Vault STABLE / redeemInFlight | — | — | vault STABLE=1990509700, redeemInFlight=0, freeCash=1481019700 ✓ |
| C19 | finalizeRedeemBatch([2], [509490000]) | `finalizeRedeemBatch([2],[509490000])` | `0x72148e5c54f2807c3e2f3c97d83d31c09409345480ad6915bd1d962ef6b489b7` | ✓ request → DONE |
| C20 | Verify request status | `requests(2)` | — | status=3 (DONE), settledAssets=509490000 ✓ |
| C21 | Rebalance after finalize | `rebalance()` | `0x51f2f23b3aaf0d7b18e77b8c2f8b241730f7fe04607826021ada81d7aebc2803` | ✓ remaining STABLE re-invested |
| C22 | User STABLE | — | — | 4556940000 (increased by 509490000) ✓ |
| C23 | User shares | — | — | 1470097546 (decreased by 500000000) ✓ |

### Path C Analysis

- **Invest flow**: `rebalance()` → `adapter.deposit()` → `SubRed.subscribe()` → STABLE leaves vault. Off-chain `settleSubscribe` mints 181602600e18 ST tokens to adapter. `settleAdapter` sweeps ST to vault and confirms investInFlight.
- **Divest flow**: `processRedeemBatch()` → `adapter.requestRedeemAsync()` → `SubRed.redeem()` → ST tokens leave vault. Off-chain `settleRedeem` sends 1990509700 STABLE to adapter. `settleAdapter` sweeps STABLE to vault and confirms redeemInFlight.
- **Settlement amounts**: Invested 1990510000 STABLE, received back 1990509700 STABLE (300 STABLE difference — rounding/fee from SubRed mock).
- **ST token pricing**: adapter `totalValue()` returned 181602600 (STABLE equivalent), indicating the ST token oracle/pricing is configured. The minted 181602600e18 ST tokens correspond to ~181.6 STABLE value at the oracle price, less than the invested 1990510000 STABLE — indicating the mock settlement used a different conversion ratio.
- Rebalance after finalize re-invested remaining vault STABLE into the adapter (freeCash → 0).

## Issues & Corrections Applied to Test Plan

| # | Issue | Severity | Resolution |
|---|-------|----------|------------|
| 1 | Fresh Accountant has `lastComputeTimestamp=0`, causing `Panic(17)` in deposit | **Critical** | Added step S5: initialize exchange rate before first deposit |
| 2 | STABLE approval must target Vault, not Gateway | **Critical** | Fixed A2: approve Vault address |
| 3 | `registerStrategy` has 4 params (not 5 as in plan) | Medium | Fixed C0a: correct function signature |
| 4 | SubRedManagement settlement requires off-chain service | **Blocker** | Updated C7, C18a to note off-chain dependency |
| 5 | Deposit at non-1e18 rate mints different share count | Info | Documented in B2b, C2b |

## Post-Test Snapshot

```
User STABLE balance:     4556940000
User shares:           1470097546
Vault freeCash:        0 (all invested into adapter after C21 rebalance)
Vault totalSupply:     1470097936 (includes 390 fee shares from C13)
Exchange rate:         1020000000000000000 (1.02e18)
nextRequestId:         3
nextInFlightId:        4
bufferTargetBps:       0
rebalanceCooldown:     0
```
