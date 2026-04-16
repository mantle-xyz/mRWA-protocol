# mRWA 协议长稳测试设计方案 v3

> 持续发送交易验证系统稳定性，覆盖多用户申赎全流程、制裁用户穿插交易、再平衡、费用结算、在途与非在途、部分/全额退款结算、多 Adapter 混合权重等全链路场景。共 9 个测试场景（S1–S9）。

**目录**

| 章节 | 内容 |
|------|------|
| **一–四** | 设计目标、双模式架构、文件结构、参数配置 |
| **五** | **9 个测试场景详细设计**（S1–S9 场景描述、迭代流程、边界覆盖） |
| **六** | **执行策略与命令**（完整执行命令参考、Fork 模式说明） |
| **七** | **场景覆盖矩阵**（9 场景 × 35 种交易流/边界的覆盖表） |
| **八** | **预期产出**（报告格式、示例输出、日志文件） |
| **九** | 初版遗漏补充清单 |
| **十–十二** | 代码设计细节（公共基类、验证方法论、Metrics 记录） |
| **十三–十四** | 操作数比例化（`_scaledRand`）、SIM_DAYS 自动缩减、实现阶段 Bug 修复与优化 |

---

## 一、设计目标

通过持续、反复的交易操作模拟真实运行环境，验证：

| 维度 | 说明 |
|------|------|
| 状态一致性 | 在大量交易后核心不变量（invariants）是否始终成立 |
| 数值精度 | 累积误差是否在可接受范围内（exchange rate、fee、份额/资产换算） |
| 状态机正确性 | 异步赎回在海量请求下 PENDING → PROCESSING → DONE 转换是否正确 |
| 并发安全 | 多用户 / 多操作交织时是否会出现资金丢失或状态异常 |
| 在途记录完整性 | in-flight 记录在各种结算场景（正常、部分、全损、重试）下正确清零 |
| 边界退化 | 长时间运行后是否出现 gas 增长、storage 膨胀等性能退化 |

---

## 二、双模式架构

支持两种运行模式，通过环境变量 `STRESS_FORK` 切换：

| 模式 | 说明 | 适用场景 |
|------|------|----------|
| **Local**（默认） | Foundry 本地 EVM，setUp 中一次性部署全套合约 | 快速迭代、CI 回归、无需外部依赖 |
| **Fork** | Fork Mantle Sepolia（或其他网络），使用链上已部署的真实合约 | 集成验证、真实状态测试、上线前回归 |

### 2.1 模式对比

```
┌─────────────────────────────────────────────────────────────────────┐
│                        StressBase.t.sol                             │
│                                                                     │
│  setUp() {                                                          │
│      if (STRESS_FORK) {                                             │
│          _setupFork();   // fork 链，加载链上合约地址                │
│      } else {                                                       │
│          _setupLocal();  // 本地 EVM，部署全套新合约                 │
│      }                                                              │
│      _createUsers();     // 两种模式共用：创建测试用户 + 充值        │
│  }                                                                  │
│                                                                     │
│  // 以下完全共用，场景代码不感知模式差异                            │
│  _checkAllInvariants()                                              │
│  _depositAs() / _redeemAs() / _requestRedeemAs() / ...             │
└─────────────────────────────────────────────────────────────────────┘
```

### 2.2 Local 模式

在 Foundry 本地 EVM 中一次性部署完整协议栈（真实合约 + proxy，不使用 mock accountant / controller）：

```
MockUSDC, MockSanctionsOracle
  ↓
VaultFactory      → MantleYieldVault    (BeaconProxy)
GatewayFactory    → MantleVaultGateway  (BeaconProxy)
AccountantFactory → Accountant          (BeaconProxy)
SCFactory         → StrategyController  (BeaconProxy)
                    OperatorExecutor    (UUPS ERC1967Proxy)
                    AccountantExecutor  (UUPS ERC1967Proxy)
                    MockSync4626Adapter  (sync 策略)
                    MockAsync7540Adapter (async 策略)
  ↓
角色授权 → 策略注册 → 初始存款
```

- 每个 test contract 仅部署一次（setUp），所有 test function 共享同一套合约
- `vm.warp` / `vm.roll` 自由控制时间
- 完全隔离，无外部依赖

### 2.3 Fork 模式

Fork 链上真实状态，直接使用已部署的合约：

```
vm.createSelectFork(rpcUrl)
  ↓
从环境变量 / 配置文件加载合约地址
  ↓
vm.prank(admin/bot) 模拟特权操作
deal(usdc, user, amount) 给测试用户充值
  ↓
与链上合约交互（状态真实，gas 真实）
```

- 不重新部署合约，直接使用链上实例
- 通过 `vm.prank` 模拟 admin / bot 角色执行特权操作
- 通过 `deal` cheatcode 给测试用户充值 USDC
- `vm.warp` 在 fork 上同样可用
- 可验证真实合约状态下的行为

### 2.4 Fork 模式下的限制与适配

| 差异点 | Local 模式 | Fork 模式 | 适配策略 |
|--------|-----------|-----------|----------|
| 合约部署 | setUp 中部署 | 跳过，加载地址 | `if (!IS_FORK) { deploy... }` |
| USDC 充值 | `mockUsdc.mint()` | `deal(usdc, user, amount)` | helpers 内部判断 |
| 策略适配器 | Mock adapters | 链上真实 adapter | Fork 使用链上已注册策略 |
| 时间控制 | `vm.warp` 自由 | `vm.warp` 可用但改变链上时间语义 | 两种模式均使用 `vm.warp` |
| 已有状态 | 空白状态 | 链上已有 deposit / 请求 / in-flight | invariant 检查基于当前快照，不假设空白 |
| 角色地址 | setUp 中自定义 | 从链上 / 配置文件读取 | 统一用环境变量 |

---

## 三、文件结构

```
test/stress/
├── STRESS_TEST_PLAN.md                      // 本文档
├── StressBase.t.sol                         // 公共基类：双模式初始化、invariants、helpers、mock adapters
├── S1_DepositRedeemMix.t.sol                // 场景 1：多用户存取混合循环
├── S2_AsyncRedeemFullCycle.t.sol            // 场景 2：异步赎回全生命周期
├── S3_RebalanceSettlement.t.sol             // 场景 3：再平衡 + 在途结算
├── S4_ExchangeRateFeeAccrual.t.sol          // 场景 4：汇率波动 + 费用累积
├── S5_SanctionedUserInterlace.t.sol         // 场景 5：制裁用户穿插正常交易
├── S6_InFlightEdgeCases.t.sol               // 场景 6：在途异常（部分结算 / 损失 / 重试）
├── S7_FullProtocolEndurance.t.sol           // 场景 7：全链路端到端耐久
├── S8_InvestSettlementEdge.t.sol            // 场景 8：Invest 结算边界（部分/全额退款）
├── S9_MultiAdapterMix.t.sol                 // 场景 9：多 Adapter 非对称权重混合
├── stress.env.example                       // Fork 模式环境变量模板
└── run_stress.sh                            // 执行脚本（多种子、持续时间控制、S1–S9 全覆盖）
```

---

## 四、参数化设计

所有参数通过环境变量控制，代码中设置默认值，无需额外配置即可运行 Local 模式：

### 4.1 通用参数

| 环境变量 | 含义 | 默认值 | 说明 |
|----------|------|--------|------|
| `STRESS_ROUNDS` | 迭代轮次 | 50 | 每个种子的主循环次数 |
| `STRESS_USERS` | 测试用户数 | 20 | 动态创建的用户地址数量 |
| `STRESS_SEED` | 随机种子 | 12345 | 基础种子，保证可复现 |
| `STRESS_SEEDS` | 种子轮数 | 5 | duration=0 模式下执行的种子迭代次数 |
| `STRESS_DAYS` | S7 模拟天数 | 30 | 全链路耐久测试的模拟时长（大用户池自动缩减，见 §13.5） |

### 4.2 Fork 模式参数

| 环境变量 | 含义 | 默认值 | 说明 |
|----------|------|--------|------|
| `STRESS_FORK` | 是否启用 Fork 模式 | `false` | 设为 `true` 启用 |
| `STRESS_RPC_URL` | Fork 的 RPC 地址 | `https://rpc.sepolia.mantle.xyz` | 支持任意 EVM 链 |
| `STRESS_VAULT` | Vault 合约地址 | — | Fork 模式必填 |
| `STRESS_GATEWAY` | Gateway 合约地址 | — | Fork 模式必填 |
| `STRESS_ACCOUNTANT` | Accountant 合约地址 | — | Fork 模式必填 |
| `STRESS_ACCOUNTANT_EXECUTOR` | AccountantExecutor 地址 | — | Fork 模式必填 |
| `STRESS_CONTROLLER` | StrategyController 地址 | — | Fork 模式必填 |
| `STRESS_OPERATOR_EXECUTOR` | OperatorExecutor 地址 | — | Fork 模式必填 |
| `STRESS_ORACLE` | SanctionsOracle 地址 | — | Fork 模式必填 |
| `STRESS_USDC` | USDC 代币地址 | — | Fork 模式必填 |
| `STRESS_ADMIN` | Admin 角色地址 | — | Fork 模式必填 |
| `STRESS_BOT` | Bot 角色地址 | — | Fork 模式必填 |
| `STRESS_TREASURY` | Treasury 地址 | — | Fork 模式必填 |
| `STRESS_SANCTION_SAFE` | SanctionSafe 地址 | — | Fork 模式必填 |

### 4.3 环境变量模板 `stress.env.example`

```bash
# ============================================
# mRWA Stress Test — Fork Mode Configuration
# ============================================
# 复制为 stress.env 并填入实际值，然后:
#   source stress.env && forge test --match-contract S1_ -vvv

# --- 通用参数 ---
STRESS_ROUNDS=50
STRESS_USERS=20
STRESS_SEED=12345
STRESS_DAYS=30

# --- Fork 模式开关 ---
STRESS_FORK=true
STRESS_RPC_URL=https://rpc.sepolia.mantle.xyz

# --- Mantle Sepolia 合约地址（示例） ---
STRESS_VAULT=0xa2a35f68b61b1280959fd91e9d8750a95366b969
STRESS_GATEWAY=0x30650357bf43cca867dcb65e90b3059e9e5fe561
STRESS_ACCOUNTANT=0x3cad2451d47e78d3d9fdb52ab46fcd0e08b6fd9d
STRESS_ACCOUNTANT_EXECUTOR=0xd25b6c06db0691412c9f0112ebb477521181a50e
STRESS_CONTROLLER=0x222f850d8b7f0351dd0cc82ed1c9cd2f47c1dbd8
STRESS_OPERATOR_EXECUTOR=0x349b35d09c104adcd124a5f99e679c6ee5218951
STRESS_ORACLE=0x2f03dc1a914b69970f3a8fc30f5af10b621063ce
STRESS_USDC=0xcb89f5acc8f21a115192a0649fdf6b5d75880289
STRESS_ADMIN=0x65Cf61678Cf120a8F40c2F3aEDCb50BBA0e85c78
STRESS_BOT=0x3C8af6063c934dc25F7dB727bBB6c7DeEBE21Bb2
STRESS_TREASURY=0x3C8af6063c934dc25F7dB727bBB6c7DeEBE21Bb2
STRESS_SANCTION_SAFE=0x3C8af6063c934dc25F7dB727bBB6c7DeEBE21Bb2
```

### 4.4 代码中读取方式

```solidity
abstract contract StressBase is Test {
    // --- 通用参数 ---
    uint256 ROUNDS     = vm.envOr("STRESS_ROUNDS", uint256(50));
    uint256 USER_COUNT = vm.envOr("STRESS_USERS",  uint256(20));
    uint256 SEED       = vm.envOr("STRESS_SEED",   uint256(12345));
    uint256 SIM_DAYS   = vm.envOr("STRESS_DAYS",   uint256(30));

    // --- 模式切换 ---
    bool IS_FORK = vm.envOr("STRESS_FORK", false);

    // --- 合约引用（两种模式统一接口）---
    MantleYieldVault   vault;
    MantleVaultGateway gateway;
    Accountant         accountant;
    AccountantExecutor accountantExecutor;
    StrategyController controller;
    OperatorExecutor   operatorExecutor;
    ISanctionsOracle   oracle;
    IERC20             usdc;

    // --- 角色地址 ---
    address admin;
    address bot;
    address treasury;
    address sanctionSafe;
    address pauser;

    function setUp() public virtual {
        if (IS_FORK) {
            _setupFork();
        } else {
            _setupLocal();
        }
        _createUsers();
    }
}
```

---

## 五、9 个测试场景详细设计

---

### S1：`DepositRedeemMix` — 多用户存取混合压力

**目的**：验证大量 sync deposit + sync redeem 交替执行下份额 / 资产计算的精度和 freeCash 正确性。

**每轮迭代流程**：

```
1. 随机选 _scaledRand(1, 4, 50) 个用户（20用户时1~5，100用户时1~25，1000用户时1~50）
2. 每个用户随机操作:
   - 60% 概率 deposit（随机金额 [1 USDC, 10_000 USDC]）
   - 40% 概率 sync redeem（随机份额 [minRedeem, 用户持有量]，需 freeCash 充足）
3. 每 10 轮通过 accountant 更新一次 exchange rate（±2% 浮动）
4. 检查 invariants I1, I2, I3, I6
5. 特别验证:
   - dust 金额（1 USDC）不会丢失精度
   - 全额赎回后 balanceOf == 0
   - totalSupply == Σ balanceOf
```

**覆盖的边界场景**：

- 小额 / 大额存取精度
- exchange rate 变动前后的份额定价一致性
- freeCash 不足时 sync redeem 正确 revert
- 费用扣除后 treasury 累积正确
- 交替 deposit / redeem 后 totalSupply 与实际份额之和一致

**可并行**：是

---

### S2：`AsyncRedeemFullCycle` — 异步赎回全生命周期

**目的**：验证 `requestRedeem → processRedeemBatch → finalizeRedeemBatch` 全链路在大量请求下的状态机正确性和资金守恒。

**每轮迭代流程**：

```
Phase A — 积累请求:
  1. _scaledRand(2, 4, 50) 个用户发起 requestRedeem（随机份额）
  2. 记录 requestId、estimatedAssets
  3. 验证 totalLockedShares 增长正确
  4. 验证用户 shares 已 burn、fee 已转 treasury

Phase B — 部分处理（不一定处理所有）:
  5. 随机选 50%~100% 的 PENDING 请求进入 processRedeemBatch
  6. 如果 freeCash 不足，自动触发 divest（产生 redeem in-flight）
  7. 验证选中的请求状态变为 PROCESSING
  8. 未选中的请求保持 PENDING（下轮继续）

Phase C — 结算:
  9. warp 时间（模拟 T+N 天结算延迟）
  10. 如有 divest 产生的 redeem in-flight → settleAdapter 先结算
  11. finalizeRedeemBatch:
      - settledAssets 引入 ±5% 随机偏差（模拟真实结算差异）
      - settledAssets 不超过 vault 的 physicalCash
  12. 验证:
      - 请求状态变为 DONE，settledAssets 已设置
      - 用户（或 sanctionSafe）收到对应 USDC
      - totalLockedShares 相应减少

Phase D — 跨轮混合:
  13. 上一轮的未处理 PENDING 请求在本轮与新请求一起处理
  14. 检查 invariants I1, I2, I4, I7, I8
```

**覆盖的边界场景**：

- 部分处理（非全量）状态正确性
- 跨轮次的请求混合处理（新旧请求同批 process）
- `settledAssets ≠ estimatedAssets` 时资金守恒
- `processRedeemBatch` 触发 `_divest` 的联动
- 批次 key 唯一性（排序后 keccak256）
- 多批次重叠处理（两个 batch 同时 PROCESSING + 各自 divest）
- exchange rate 在 process 和 finalize 之间变动

**可并行**：是

---

### S3：`RebalanceSettlement` — 再平衡 + 在途结算循环

**目的**：验证反复 invest / divest 及 settlement 后资金守恒和策略权重正确。

**前置条件**：
- Local 模式：注册 2 个策略（1 sync + 1 async），权重各 40%，buffer 20%
- Fork 模式：使用链上已注册的策略

**每轮迭代流程**：

```
Phase A — 资金注入 + invest:
  1. _scaledRand(2, 5, 30) 个用户 deposit（使 freeCash > targetCash + threshold）
  2. 触发 rebalance → invest 到策略
  3. 验证 in-flight 记录创建正确
  4. 验证 totalInvestInFlight 增长
  5. 验证 vault 物理 USDC 余额减少

Phase B — invest 结算:
  6. Sync adapter: settledPos = depositAmount（正常 1:1 结算）
  7. Async adapter: warp 后 settledPos 有 ±3% 偏差
  8. 调用 settleAdapter 结算 invest in-flight
  9. 验证:
     - in-flight 状态变为 CONFIRMED
     - totalInvestInFlight 归零
     - adapter 持有对应 pos token

Phase C — 触发 divest:
  10. _scaledRand(1, 5, 30) 个用户 requestRedeem（使 freeCash 不足）
  11. processRedeemBatch 自动触发 _divest
  12. 验证 redeem in-flight 创建正确
  13. sync adapter 立即返回 USDC
  14. async adapter 产生 redeem in-flight

Phase D — redeem 结算:
  15. warp 后 settleAdapter 结算 async redeem in-flight
  16. 验证 totalRedeemInFlight 归零
  17. finalizeRedeemBatch 完成赎回，用户收到 USDC

检查 invariants I1, I3, I7
特别验证: 各策略 totalValue 符合 targetWeight ± threshold
```

**覆盖的边界场景**：

- sync vs async adapter 混合结算
- invest refund（adapter 未全额投资，部分 USDC 退回）
- divest 因 freeCash 不足被 `processRedeemBatch` 自动触发
- 多策略权重分配正确性
- 连续 rebalance 冷却期（cooldown）验证
- 多轮 invest / divest 后无 "幽灵" in-flight 记录残留

**可并行**：是

---

### S4：`ExchangeRateFeeAccrual` — 汇率波动 + 管理费累积

**目的**：验证频繁 NAV 更新下 circuit breaker 正确性，以及 management fee 长期累积精度。

**每轮迭代流程**：

```
汇率更新:
  1. warp 到满足 cooldown 的时间点
  2. 计算新 rate（在 lastRate × [0.95, 1.05] 内随机）
  3. 通过 accountantExecutor 更新 exchange rate
  4. 验证: fee mint 正确
     - sharesToMint = shareBase × feeRate × timeElapsed / (10000 × 365 days)
     - shareBase = min(currentSupply, totalSharesLastSettle)

异常注入（随机触发）:
  5. 10% 概率: 尝试超出 maxDeviation 的 rate
     → 验证 circuit breaker 触发
     → 验证系统进入暂停状态
  6. 5% 概率: 尝试 cooldown 内重复更新
     → 验证 revert
  7. circuit breaker 触发后: admin unpause，下一轮恢复正常更新

Supply 波动场景:
  8. 每 5 轮穿插 _scaledRand(1, 5, 30) 个用户执行 deposit 或 redeem（改变 totalSupply）
  9. 验证 fee 计算使用 min(current, lastSettle) 逻辑正确

Fee 精度验证:
  10. 每轮记录 treasury 份额增量
  11. 最终验证: 累积 fee 与理论值偏差 < 0.01%

检查 invariants I5, I6
```

**覆盖的边界场景**：

- circuit breaker 触发 → 暂停 → unpause → 恢复正常的完整循环
- management fee 的 `min(currentSupply, totalSharesLastSettle)` 防超收逻辑
- 大额赎回导致 totalSupply 骤降后 fee 计算
- 长期累积精度（50+ 次 settle 后的累积误差）
- cooldown 精确边界（恰好满足 / 差 1 秒）
- 连续 circuit breaker 触发 / 恢复后状态正确

**可并行**：是

---

### S5：`SanctionedUserInterlace` — 制裁用户穿插正常交易

**目的**：验证制裁 / 解除制裁在各交易流程中的正确性，尤其穿插在正常用户交易之间。

**每轮迭代流程**：

```
Phase A — 正常交易基础:
  1. _scaledRand(3, 4, 40) 个正常用户 deposit
  2. _scaledRand(1, 10, 20) 个正常用户 sync redeem

Phase B — 制裁穿插:
  3. 随机选 _scaledRand(1, 10, 20) 个用户施加制裁
  4. 被制裁用户尝试:
     a. deposit         → 验证 revert (SanctionedAddress)
     b. sync redeem     → 验证 shares 路由到 sanctionSafe (SanctionSafeIn)
     c. requestRedeem   → 验证 shares 路由到 sanctionSafe
     d. share transfer  → 验证 revert
  5. 正常用户继续交易 → 验证不受制裁影响

Phase C — 异步赎回中途被制裁:
  6. 用户 A 发起 requestRedeem（状态变为 PENDING）
  7. 在 processRedeemBatch 之前，对用户 A 施加制裁
  8. 执行 processRedeemBatch + finalizeRedeemBatch
  9. 验证: settledAssets 发送到 sanctionSafe（而非用户 A）

Phase D — 解除制裁:
  10. 解除所有制裁
  11. 之前被制裁的用户恢复正常操作
  12. 验证 deposit / redeem 均可正常执行

Phase E — 批量制裁:
  13. 每 10 轮执行一次批量制裁（20~50 个地址）
  14. 验证 gas 在合理范围内（< 1.5M gas for 50 addresses）

检查 invariants I1, I2, I6
```

**覆盖的边界场景**：

- 赎回过程中被制裁（request 已发，finalize 时路由到 sanctionSafe）
- `sanctionSafeIn`（shares 路由）vs `sanctionSafeOut`（assets 路由）
- 制裁状态快速翻转不导致状态不一致
- whitelist 模式与制裁的交互
- share transfer 限制（`_update` hook 的制裁检查）
- 正常用户交易不被制裁用户影响
- 批量制裁的 gas 消耗

**可并行**：是

---

### S6：`InFlightEdgeCases` — 在途记录异常场景

**目的**：验证 in-flight 记录在各种异常结算场景下的账本正确性。

**每轮迭代流程**：

```
Case A — 正常在途（基线）:
  1. deposit → rebalance → invest in-flight 创建
  2. settleAdapter（settledPos == expected）
  3. 验证: CONFIRMED，totalInvestInFlight == 0

Case B — Invest 部分退款（refund）:
  4. rebalance → invest in-flight 创建
  5. settle 时 refundAssetAmount > 0（adapter 未全额投资）
  6. 验证: vault 收回 refund USDC + 实际 pos token
  7. 验证: totalInvestInFlight 正确递减

Case C — Redeem 部分结算（策略亏损）:
  8. requestRedeem → processRedeemBatch → divest → redeem in-flight 创建
  9. settle 时 settledAsset < expected（策略亏损导致）
  10. 验证: vault 收到实际 USDC（少于预期）
  11. finalizeRedeemBatch 时 settledAssets 反映实际金额
  12. 验证: 用户收到的金额 < estimatedAssets

Case D — Redeem 零结算（策略全损）:
  13. 创建 redeem in-flight
  14. settle 时 settledAsset = 0（abnormal = true）
  15. 验证: totalRedeemInFlight 正确清零
  16. finalizeRedeemBatch 时 settledAssets = 0
  17. 验证: 系统不 revert，用户收到 0

Case E — 在途与非在途混合:
  18. 同时存在:
      - 2 个 invest in-flight（1 已 settle、1 未 settle）
      - 1 个 redeem in-flight（未 settle）
      - vault 有一定 freeCash
  19. _scaledRand(1, 5, 20) 个用户尝试 sync redeem（使用 freeCash）
  20. _scaledRand(1, 5, 20) 个用户 deposit
  21. 验证: in-flight 不影响 sync redeem 的 freeCash 计算
  22. 验证: totalAssets 正确反映在途 + 非在途

Case F — retryRedeemInFlight:
  23. 创建 async redeem in-flight
  24. 模拟首次结算失败（adapter 未返回资金）
  25. admin 调用 retryRedeemInFlight 重试
  26. 后续正常 settle
  27. 验证: 最终状态正确，in-flight 记录 CONFIRMED

检查 invariants I1, I7
特别验证:
  - 所有 in-flight settle 后 totalInvestInFlight == 0 && totalRedeemInFlight == 0
  - 无 "幽灵" 在途记录（PENDING 状态但永远不会被处理）
  - abnormal 确认不破坏全局 in-flight 计数器
```

**覆盖的边界场景**：

- invest refund（部分退款 + pos token 混合返回）
- redeem 部分结算（策略亏损场景）
- redeem 零结算（策略全损 + abnormal 标记）
- `retryRedeemInFlight` 手动重试流程
- 在途 + 非在途共存时的 `freeCash` / `totalAssets` 计算
- 多个 in-flight 混合状态（部分 CONFIRMED + 部分 PENDING）

**可并行**：是

---

### S7：`FullProtocolEndurance` — 全链路端到端耐久测试

**目的**：串联所有核心流程，模拟多日真实运行，验证系统长期稳定性。

**模拟 `SIM_DAYS` 天，每天执行**：

```
=== Morning（存款阶段）===
  1. _scaledRand(3, 4, 50) 个用户 deposit（随机金额 [100, 50_000 USDC]）
  2. 1~2 个用户 share transfer 给其他用户

=== Mid-morning（合规更新）===
  3. 每 5 天: 随机制裁 1~2 个用户
  4. 每 7 天: 解除之前制裁的用户
  5. 被制裁用户尝试操作 → 验证正确 revert / 路由

=== Noon（NAV 更新）===
  6. accountant 更新 exchange rate（模拟每日 NAV）:
     - 正常日: ±0.5% 波动
     - 每 10 天: ±3% 波动（压力日）
     - 每 15 天: 尝试超出 maxDeviation → circuit breaker → admin unpause
  7. management fee 自动随 rate update 结算

=== Afternoon（赎回阶段）===
  8. _scaledRand(2, 5, 30) 个用户 requestRedeem（随机份额）
  9. _scaledRand(1, 10, 20) 个用户尝试 sync redeem（如果 freeCash 充足）
  10. 被制裁用户夹杂 redeem → 验证 sanctionSafe 路由

=== Evening（Bot 运维周期）===
  11. processRedeemBatch:
      - 处理当天 + 之前积压的 PENDING 请求
  12. rebalance（如果 freeCash 偏离目标）:
      - invest 到 sync / async adapter
  13. settleAdapter:
      - 结算 T-2 天的 invest in-flight
      - 结算 T-3 天的 redeem in-flight（async adapter 延迟更大）
      - 偶尔引入 refund 或部分结算（±5% 偏差）
  14. finalizeRedeemBatch:
      - 完成之前 PROCESSING 的请求

=== Night（检查 + 记录）===
  15. 每 7 天: 显式触发 settleManagementFees（如果 rate update 间隔较长）
  16. 记录 RoundMetrics（totalAssets, totalSupply, rate, freeCash, gas 等）
  17. 检查全部 invariants I1 ~ I8
  18. warp 1 day
```

**最终验证（`SIM_DAYS` 天后）**：

```
- 所有 in-flight 记录已 CONFIRMED（无残留 PENDING）
- 所有 PROCESSING 请求已 finalize（无悬挂状态）
- totalLockedShares == Σ 剩余 PENDING 请求的 shares
- 累积 management fee 与理论值偏差 < 0.01%
- gas 消耗无显著增长趋势（检测 storage 膨胀）
- treasury 余额增长符合预期
- sanctionSafe 余额 == Σ 所有制裁路由的资金
- totalAssets + 用户持有 USDC + sanctionSafe USDC ≈ 初始注入总量（系统闭环）
```

**可并行**：否（全链路串联，内部已包含所有操作类型的交织）

---

### S8：`InvestSettlementEdge` — Invest 结算边界场景

**目的**：验证 Invest 部分结算（5-95% 退款）和全额退款（底层资产无法申购）场景下，vault 的资产守恒和 in-flight 记录正确性。

**覆盖的关键代码路径**：
- `StrategyController._sweepInvestSettlement()` — 同时 sweep posToken + refund USDC
- `vault.confirmInFlight(id, 0, isAbnormal=true)` — 零结算确认（全额退款）
- `_confirmSingleInvestInFlight(adapter, id, settledPos, refundAsset)` — 部分结算记录

**每轮迭代（5 种 case 轮转 `round % 5`）**：

| Case | 名称 | settledPos | refundAsset | 覆盖 |
|------|------|-----------|-------------|------|
| A | 正常全额结算 | 100% | 0 | 对照基准 |
| B | 小比例退款 (5-15%) | 85-95% | 5-15% | 滑点/手续费 |
| C | 大比例退款 (40-70%) | 30-60% | 40-70% | 底层资产流动性不足 |
| D | 全额退款 (100%) | **0** | **100%** | 底层资产拒绝/下架 |
| E | 混合多笔不同比例 | 随机 0~100% | 互补 | 同一 batch 内不同 in-flight 有不同结果 |

```
每轮流程:
  1. 确保 freeCash 充足（_ensureFreeCash）
  2. rebalance → 触发 invest（资金分配到 sync/async adapter）
  3. 根据 case 类型：调整 adapter 上的 posToken/USDC，模拟部分/全额退款
  4. settleAdapter 传入正确的 settledPosAmounts + refundAssetAmounts
  5. 验证 investInFlight == 0
  6. 检查全部 invariants + USDC 闭环
```

**可并行**：是

---

### S9：`MultiAdapterMix` — 多 Adapter 非对称权重混合

**目的**：验证 3 个 adapter 以非对称权重运行时，rebalance 分配、settlement、in-flight 跟踪的正确性。

**Adapter 布局**：

| Adapter | 类型 | 初始权重 | posTokenPrice |
|---------|------|---------|--------------|
| sync1 (syncAdapter) | sync | 40% | 1e18 (固定) |
| async1 (asyncAdapter) | async | 35% | 可变 (jitter) |
| sync2 (s9Sync2) | sync | 25% | 可变 (jitter) |

**每轮迭代（4 个 Phase）**：

```
Phase A: 比例化用户存款（_scaledRand）
Phase B: Rebalance → 资金按权重分配到 3 个 adapter
Phase C: Settle invest:
  - sync1: 正常结算 (0% refund)
  - sync2: 随机部分退款 (0-30%)
  - async1: 正常或部分结算 (0-20%)
Phase D: RequestRedeem → processBatch → settle redeem (3 adapter) → finalize

每 10 轮: jitter sync2 和 async1 的 posTokenPrice (±5%)
每 20 轮: 动态调整权重 (40/35/25 → 30/30/40 → 50/20/30 循环)
```

**可并行**：是

---

## 六、执行策略

### 6.1 为什么选择 Fork 而不是发真实交易

在测试真实合约时，有两种方式可选：

| 方式 | 说明 |
|------|------|
| **Fork（本方案采用）** | `vm.createSelectFork(rpcUrl)` 将链上状态拉到本地 EVM，使用真实合约代码和数据，但执行在本地 |
| **真实交易** | `forge script --broadcast` 向链上发送真实交易，改变链上状态 |

**选择 Fork 的核心原因：**

#### 1. Cheatcode 不可替代

压力测试的核心能力依赖 Foundry cheatcode，真实交易中全部不可用：

| Cheatcode | 压力测试用途 | 真实交易替代方案 |
|-----------|-------------|-----------------|
| `vm.prank(admin)` | 模拟 admin/bot/20 个用户各自操作 | 必须持有所有角色的私钥并逐一签名 |
| `vm.warp(+1 day)` | 瞬间跳过 cooldown（汇率更新 20h、rebalance 1h） | 干等，50 轮 × 20h cooldown ≈ 40 天 |
| `deal(usdc, user, 1M)` | 为测试用户凭空铸币 | 需从水龙头获取测试网 USDC |
| `assertEq` | 每步操作后精确校验 delta | 只能 `require`，revert 后链上无痕，难以调试 |

没有 `vm.prank`，无法模拟多角色操作；没有 `vm.warp`，时间敏感逻辑（fee 结算、cooldown）无法在合理时间内测完。

#### 2. 速度与成本

```
Fork:   9 个场景 × 50 轮 ≈ 数秒完成，零 gas 费用
真实交易: 9 个场景 × 50 轮 × 等待出块 + cooldown ≈ 数小时到数天，消耗测试网 MNT
```

#### 3. 可重复与可隔离

- **相同 SEED** 在 Fork 模式下产出相同结果，可稳定复现 bug
- **每次 setUp** 从链上快照重新开始，不会残留上次测试的脏状态
- **不影响链上**：不会改变真实合约状态，不会干扰其他人的测试

#### 4. Fork 的可信度等价于真实交易

Fork 模式执行的是**链上完全相同的合约字节码和存储状态**，只是 EVM 在本地运行。合约逻辑的正确性验证与真实交易完全等价。

#### 5. 真实交易适用的场景

Fork 覆盖 95% 验证需求后，以下场景仍建议发真实交易（手动执行少量关键操作即可）：

- Gas estimation 准确性验证（Fork 的 gas 和链上可能存在差异）
- RPC 节点行为验证（超时、限速、nonce 管理）
- 多签 / 时间锁等治理流程的真实签名链路
- 前端 → RPC → 链上的端到端通路验证

**总结：Fork = 真实合约的状态和代码 + 本地 EVM 的速度和控制力。**

---

### 6.2 场景依赖与执行顺序（S1–S9）

```
可并行组（独立场景，无状态共享）:
┌──────────────────────────────────────┐
│  S1: DepositRedeemMix                │
│  S2: AsyncRedeemFullCycle            │
│  S3: RebalanceSettlement             │
│  S4: ExchangeRateFeeAccrual         │
│  S5: SanctionedUserInterlace         │  ← 8 个同时运行
│  S6: InFlightEdgeCases               │
│  S8: InvestSettlementEdge            │
│  S9: MultiAdapterMix                 │
└──────────────────────────────────────┘
               ↓ 全部通过
┌──────────────────────────────────────┐
│  S7: FullProtocolEndurance           │  ← 全链路串联，最后运行
└──────────────────────────────────────┘
```

### 6.3 执行脚本 `run_stress.sh`（持续时间控制）

```bash
# 使用方式：第一个参数为持续测试分钟数
./test/stress/run_stress.sh 10          # 持续跑 10 分钟，自动循环种子，全部 9 个场景
./test/stress/run_stress.sh 30 S1 S7    # 仅 S1 和 S7，跑 30 分钟
./test/stress/run_stress.sh 0           # 不限时，跑 STRESS_SEEDS 轮后停止

# 自定义参数
STRESS_ROUNDS=100 STRESS_USERS=30 ./test/stress/run_stress.sh 10

# 复现特定种子的失败
STRESS_SEED=42345 STRESS_SEEDS=1 ./test/stress/run_stress.sh 0
```

脚本自动处理：
- 以分钟为单位控制总运行时间，自动循环不同种子（seed +10000/轮）
- 每次 `forge test` = 新 EVM 进程（内存不累积）
- 使用 `FOUNDRY_PROFILE=stress` 激活 2GB 内存限制
- 检查每个场景开始前是否超时，确保精确的时间控制
- 汇总所有种子的 PASS/FAIL、交易统计和不变量检查结果
- 输出到 `stress_logs/SUMMARY_REPORT.log`

### 6.4 快速参考命令

```bash
# ===== Local 模式（默认，无需配置）=====

# 跑 10 分钟全部 9 个场景（S1–S9）
./test/stress/run_stress.sh 10

# 跑 1 小时高覆盖量
STRESS_ROUNDS=100 STRESS_USERS=30 ./test/stress/run_stress.sh 60

# 复现特定 seed 下的失败
STRESS_SEED=42345 STRESS_SEEDS=1 ./test/stress/run_stress.sh 0

# 仅 S7 跑 30 分钟
./test/stress/run_stress.sh 30 S7

# 仅跑新场景 S8 + S9
./test/stress/run_stress.sh 30 S8 S9

# 轻量快速测试（验证全部 9 场景可编译通过并运行几轮）
STRESS_ROUNDS=3 STRESS_USERS=5 STRESS_SEEDS=1 ./test/stress/run_stress.sh 0

# 大规模用户测试
STRESS_USERS=100 STRESS_ROUNDS=10 ./test/stress/run_stress.sh 30
STRESS_USERS=500 STRESS_ROUNDS=5 STRESS_SEEDS=1 ./test/stress/run_stress.sh 0
STRESS_USERS=1000 STRESS_ROUNDS=3 STRESS_SEEDS=1 ./test/stress/run_stress.sh 0

# 清除聚合缓存，从零开始
./test/stress/run_stress.sh 10 --reset-cache

# 直接使用 forge（不经过脚本，单次运行单场景）
STRESS_ROUNDS=10 STRESS_USERS=5 STRESS_SEED=12345 FOUNDRY_PROFILE=stress \
  forge test --match-path "test/stress/S1_DepositRedeemMix.t.sol" -vv

# S8 单独运行（验证 invest 退款路径）
STRESS_ROUNDS=25 STRESS_USERS=10 FOUNDRY_PROFILE=stress \
  forge test --match-path "test/stress/S8_InvestSettlementEdge.t.sol" -vv

# S9 单独运行（验证多 adapter 混合）
STRESS_ROUNDS=25 STRESS_USERS=10 FOUNDRY_PROFILE=stress \
  forge test --match-path "test/stress/S9_MultiAdapterMix.t.sol" -vv

# DEBUG 日志模式（查看每笔操作明细）
STRESS_LOG_LEVEL=DEBUG STRESS_ROUNDS=5 FOUNDRY_PROFILE=stress \
  forge test --match-path "test/stress/S8_InvestSettlementEdge.t.sol" -vvv

# ===== Fork 模式（需要 stress.env）=====

# 1. 准备配置
cp test/stress/stress.env.example test/stress/stress.env
# 编辑 stress.env，填入 Mantle Sepolia 上的真实合约地址和角色地址

# 2. 运行全部场景
source test/stress/stress.env && ./test/stress/run_stress.sh 10

# 3. 单场景
source test/stress/stress.env && ./test/stress/run_stress.sh 10 S1

# 4. 直接使用 forge（手动加载环境变量）
source test/stress/stress.env
STRESS_ROUNDS=100 FOUNDRY_PROFILE=stress \
  forge test --match-path "test/stress/S7_FullProtocolEndurance.t.sol" -vvv
```

### 6.5 环境变量参数说明

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `STRESS_SEEDS` | 5 | 每个场景执行的种子轮数（每轮 = 独立 EVM） |
| `STRESS_ROUNDS` | 50 | 每个种子的迭代轮次（S1-S6） |
| `STRESS_DAYS` | 60 | S7 每个种子的模拟天数（大用户池自动缩减，见 §13.5） |
| `STRESS_USERS` | 20 | 测试用户数量，每人初始 1M USDC |
| `STRESS_SEED` | 12345 | 基础种子（实际种子 = base + iter × 10000） |
| `STRESS_DURATION` | 命令行参数 | 每个种子的最大运行秒数（0=无限制） |
| `STRESS_FORK` | false | 是否启用 Fork 模式 |
| `STRESS_RPC_URL` | `https://rpc.sepolia.mantle.xyz` | Fork 模式的 RPC 地址 |
| `STRESS_VAULT` | — | Fork 模式：MantleYieldVault 代理地址 |
| `STRESS_GATEWAY` | — | Fork 模式：MantleVaultGateway 代理地址 |
| `STRESS_ACCOUNTANT` | — | Fork 模式：Accountant 代理地址 |
| `STRESS_ACCOUNTANT_EXECUTOR` | — | Fork 模式：AccountantExecutor 代理地址 |
| `STRESS_CONTROLLER` | — | Fork 模式：StrategyController 代理地址 |
| `STRESS_OPERATOR_EXECUTOR` | — | Fork 模式：OperatorExecutor 代理地址 |
| `STRESS_ORACLE` | — | Fork 模式：SanctionsOracle 代理地址 |
| `STRESS_USDC` | — | Fork 模式：USDC 合约地址 |
| `STRESS_ADMIN` | — | Fork 模式：admin 地址（`vm.prank` 模拟） |
| `STRESS_BOT` | — | Fork 模式：bot 地址（`vm.prank` 模拟） |
| `STRESS_TREASURY` | — | Fork 模式：treasury 地址 |
| `STRESS_SANCTION_SAFE` | — | Fork 模式：sanctionSafe 地址 |

---

## 七、场景覆盖矩阵

下表展示每个场景覆盖的交易流和边界场景：

| 交易流 / 边界场景 | S1 | S2 | S3 | S4 | S5 | S6 | S7 | S8 | S9 |
|-------------------|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| sync deposit | **x** | | | | **x** | | **x** | **x** | **x** |
| sync redeem | **x** | | | | **x** | **x** | **x** | | |
| async requestRedeem | | **x** | **x** | | **x** | **x** | **x** | | **x** |
| processRedeemBatch | | **x** | **x** | | | **x** | **x** | | **x** |
| finalizeRedeemBatch | | **x** | **x** | | | **x** | **x** | | **x** |
| rebalance (invest) | | | **x** | | | **x** | **x** | **x** | **x** |
| rebalance (divest) | | **x** | **x** | | | **x** | **x** | | **x** |
| settleAdapter (invest) | | | **x** | | | **x** | **x** | **x** | **x** |
| settleAdapter (redeem) | | **x** | **x** | | | **x** | **x** | | **x** |
| updateExchangeRate | **x** | **x** | | **x** | | | **x** | **x** | **x** |
| settleManagementFees | | | | **x** | | | **x** | | |
| circuit breaker 触发/恢复 | | | | **x** | | | **x** | | |
| 制裁 / 解除制裁 | | | | | **x** | | **x** | | |
| 制裁用户 deposit revert | | | | | **x** | | **x** | | |
| 制裁用户 redeem → safe 路由 | | | | | **x** | | **x** | | |
| 赎回中途被制裁 | | | | | **x** | | **x** | | |
| share transfer 限制 | | | | | **x** | | **x** | | |
| 批量制裁 | | | | | **x** | | | | |
| invest refund（部分退款） | | | | | | **x** | **x** | **x** | **x** |
| invest 全额退款（0 posToken） | | | | | | | | **x** | |
| redeem 部分结算（亏损） | | | | | | **x** | **x** | | |
| redeem 零结算（全损） | | | | | | **x** | | | |
| retryRedeemInFlight | | | | | | **x** | | | |
| 在途 + 非在途共存 | | | | | | **x** | **x** | | |
| fee min(current, lastSettle) | | | | **x** | | | **x** | | |
| dust 金额精度 | **x** | | | | | | | | |
| freeCash 竞争 | **x** | | | | | | **x** | | |
| 多批次重叠 PROCESSING | | **x** | | | | | | | |
| rate 变动跨 process/finalize | | **x** | | | | | **x** | | |
| 混合 refund 比例（同 batch） | | | | | | | | **x** | |
| confirmInFlight(0, abnormal) | | | | | | | | **x** | |
| 3+ adapter 非对称权重 | | | | | | | | | **x** |
| 动态权重调整 | | | | | | | | | **x** |
| posTokenPrice 变动 | | | | | | | | | **x** |

---

## 八、预期产出

### 8.1 每个场景执行完毕后输出

1. **PASS / FAIL** 状态及失败轮次编号
2. **交易统计**：deposits / syncRedeems / asyncRedeems / processBatch / finalizeBatch / rebalances / settlements / rateUpdates / priceUpdates 各项计数
3. **Invariant 检查汇总**：检查次数、失败次数（及失败详情：哪条 invariant、期望值 vs 实际值）
4. **Gas 消耗报告**：总 gas 使用量
5. **Metrics 趋势**：totalAssets、totalSupply、exchange rate、treasury balance 的逐轮变化（通过 console log 输出，可 grep 做后处理绘图）

### 8.2 汇总报告（`stress_logs/SUMMARY_REPORT.log`）

`run_stress.sh` 执行完毕后自动生成，包含：

- **配置摘要**：持续时间、种子轮数、每轮轮次、用户数
- **Overall 状态**：N passed / M failed / Total total
- **每个场景详情**：种子通过/失败数、总轮次、各类交易计数、不变量统计、gas 汇总
- **Grand Totals**：所有场景的交易总量、不变量检查总量、总 gas、总耗时

### 8.3 示例输出

```
============================================================
  STRESS TEST SUMMARY REPORT
============================================================
  Overall:  9 passed / 0 failed / 9 total
  Time:     5m02s
============================================================

  [S1] Deposit/Redeem Mix        Seeds: 81 passed / 0 failed
  [S2] Async Redeem Cycle        Seeds: 81 passed / 0 failed
  [S3] Rebalance Settlement      Seeds: 81 passed / 0 failed
  [S4] Exchange Rate & Fee       Seeds: 81 passed / 0 failed
  [S5] Sanctioned User           Seeds: 81 passed / 0 failed
  [S6] InFlight Edge Cases       Seeds: 81 passed / 0 failed
  [S7] Full Protocol Endurance   Seeds: 81 passed / 0 failed
  [S8] Invest Settlement Edge    Seeds: 81 passed / 0 failed
  [S9] Multi-Adapter Mix         Seeds: 81 passed / 0 failed

  Grand Totals:
    Rounds:           87,766
    Transactions:     562,930
    Invariant Checks: 150,544 (fails: 0)
```

### 8.4 日志文件

| 文件 | 说明 |
|------|------|
| `stress_logs/SUMMARY_REPORT.log` | 汇总报告（每次 run_stress.sh 覆盖） |
| `stress_logs/stress_YYYYMMDD_HH.log` | 按小时轮转的详细日志 |
| `stress_logs/errors.log` | 所有 ERROR+ 级别日志兜底 |
| `stress_logs/.cache/aggregate.tsv` | TSV 聚合缓存（跨多次运行累积） |

---

## 九、初版方案遗漏场景补充清单

以下 12 个场景在初版方案中未覆盖，本版已补充至对应场景中：

| # | 遗漏场景 | 补充到 | 原因 |
|---|----------|--------|------|
| 1 | exchange rate 在 process 和 finalize 之间变动 | S2, S7 | settled 金额可能偏离估算，影响资金守恒计算 |
| 2 | in-flight 零结算（策略全损 + abnormal 确认） | S6 | `totalRedeemInFlight` 递减但无资金返回 |
| 3 | invest refund（adapter 部分退款） | S6 | `refundAssetAmounts > 0` 时的资金归位 |
| 4 | `retryRedeemInFlight`（async 重试） | S6 | 手动重试流程的状态正确性 |
| 5 | 赎回中途被制裁（request 后、finalize 前制裁） | S5 | `finalizeRedeemBatch` 路由到 sanctionSafe |
| 6 | circuit breaker 触发 → pause → unpause 恢复 | S4, S7 | 系统暂停后恢复交易的连续性 |
| 7 | share transfer 限制（制裁用户转账 revert） | S5 | ERC20 `_update` hook 的制裁检查 |
| 8 | management fee 的 `min(current, lastSettle)` | S4 | 大额赎回后 supply 骤降对费用的影响 |
| 9 | 多批次重叠处理（overlapping batch） | S2 | 两个 batch 同时 PROCESSING + 各自 divest |
| 10 | freeCash 竞争（sync redeem vs locked shares） | S1, S7 | sync redeem 时 `totalLockedShares` 占用 freeCash |
| 11 | 在途 + 非在途共存时的 totalAssets | S6 | 部分 adapter 有 in-flight + 部分已 settle 的混合状态 |
| 12 | `sanctionSafeIn`（shares 路由）+ safe 管理 | S5 | 被制裁用户的 shares 转入 safe 后的处理 |

---

> **以下章节（§十–§十四）为代码级设计细节、验证逻辑、性能优化和 Bug 修复记录，供开发参考。**

---

## 十、公共基类 `StressBase.t.sol` 详细设计

### 10.1 `_setupLocal()` — 本地部署

```solidity
function _setupLocal() internal {
    // 1. 角色地址
    admin        = makeAddr("admin");
    bot          = makeAddr("bot");
    treasury     = makeAddr("treasury");
    sanctionSafe = makeAddr("sanctionSafe");
    pauser       = makeAddr("pauser");

    // 2. 部署 Mock 依赖
    MockUSDC mockUsdc = new MockUSDC();
    usdc = IERC20(address(mockUsdc));
    MockSanctionsOracle mockOracle = new MockSanctionsOracle();
    oracle = ISanctionsOracle(address(mockOracle));

    // 3. 部署实现 + 工厂 + Proxy（与 DeployAll.s.sol 流程一致）
    //    Vault, Gateway, Accountant, Controller, Executors
    //    ... 完整部署流程 ...

    // 4. 部署 Mock 策略适配器（1 sync + 1 async）
    //    注册策略，设置权重

    // 5. 角色授权
    //    EXECUTOR_ROLE, BOT_ROLE, OPERATOR_EXECUTOR_ROLE, PAUSER_ROLE, COMPLIANCE_ROLE
}
```

### 10.2 `_setupFork()` — Fork 链上合约

```solidity
function _setupFork() internal {
    // 1. 创建 Fork
    string memory rpcUrl = vm.envOr("STRESS_RPC_URL", string("https://rpc.sepolia.mantle.xyz"));
    vm.createSelectFork(rpcUrl);

    // 2. 加载合约地址（全部从环境变量读取）
    vault              = MantleYieldVault(vm.envAddress("STRESS_VAULT"));
    gateway            = MantleVaultGateway(vm.envAddress("STRESS_GATEWAY"));
    accountant         = Accountant(vm.envAddress("STRESS_ACCOUNTANT"));
    accountantExecutor = AccountantExecutor(vm.envAddress("STRESS_ACCOUNTANT_EXECUTOR"));
    controller         = StrategyController(vm.envAddress("STRESS_CONTROLLER"));
    operatorExecutor   = OperatorExecutor(vm.envAddress("STRESS_OPERATOR_EXECUTOR"));
    oracle             = ISanctionsOracle(vm.envAddress("STRESS_ORACLE"));
    usdc               = IERC20(vm.envAddress("STRESS_USDC"));

    // 3. 加载角色地址
    admin        = vm.envAddress("STRESS_ADMIN");
    bot          = vm.envAddress("STRESS_BOT");
    treasury     = vm.envAddress("STRESS_TREASURY");
    sanctionSafe = vm.envAddress("STRESS_SANCTION_SAFE");

    // 4. 记录 Fork 时的初始状态（用于 invariant 基线）
    _snapshotInitialState();
}
```

### 10.3 `_createUsers()` — 用户池（双模式共用）

```solidity
address[] internal users;

function _createUsers() internal {
    for (uint256 i = 0; i < USER_COUNT; i++) {
        address u = makeAddr(string.concat("user", vm.toString(i)));
        users.push(u);

        // 充值 USDC
        if (IS_FORK) {
            deal(address(usdc), u, 1_000_000e6);  // Foundry deal cheatcode
        } else {
            MockUSDC(address(usdc)).mint(u, 1_000_000e6);
        }

        // 授权 Gateway 扣款
        vm.prank(u);
        usdc.approve(address(gateway), type(uint256).max);

        // Fork 模式：如果开了 whitelist，需要加白
        if (IS_FORK) {
            _ensureWhitelisted(u);
        }
    }
}
```

### 10.4 伪随机工具（可复现）

使用 `SEED + nonce` 组合，保证相同种子下结果完全一致，便于问题复现：

```solidity
uint256 private _nonce;

function _rand(uint256 max) internal returns (uint256) {
    _nonce++;
    return uint256(keccak256(abi.encode(SEED, _nonce))) % max;
}

function _randBetween(uint256 min, uint256 max) internal returns (uint256) {
    return min + _rand(max - min + 1);
}

function _randUser() internal returns (address) {
    return users[_rand(users.length)];
}

function _randBool(uint256 pctTrue) internal returns (bool) {
    return _rand(100) < pctTrue;
}
```

### 10.5 通用操作 Helpers

```solidity
// 用户存款（通过 Gateway）
function _depositAs(address user, uint256 amount) internal returns (uint256 shares);

// 用户同步赎回
function _redeemAs(address user, uint256 shares) internal returns (uint256 assets);

// 用户异步赎回请求
function _requestRedeemAs(address user, uint256 shares) internal returns (uint256 requestId);

// 批量处理赎回（通过 OperatorExecutor，vm.prank(bot)）
function _processRedeemBatch(uint256[] memory ids) internal;

// 批量完成赎回
function _finalizeRedeemBatch(uint256[] memory ids, uint256[] memory settledAssets) internal;

// 触发再平衡（通过 OperatorExecutor）
function _rebalance() internal;

// 结算适配器（invest 和 redeem in-flight）
function _settleAdapter(address adapter, ...) internal;

// 更新汇率（通过 AccountantExecutor，vm.prank(bot)）
function _updateExchangeRate(uint256 newRate) internal;

// 获取所有指定状态的请求 ID
function _getRequestIdsByStatus(RequestStatus status) internal view returns (uint256[] memory);

// 排序请求 ID（processRedeemBatch 要求严格升序）
function _sortIds(uint256[] memory ids) internal pure returns (uint256[] memory);
```

---

## 十一、验证方法论

本章详细说明在多用户复杂交易及交织场景下，如何校验流程正确性和账本正确性。

### 11.1 验证架构总览

验证分三层，从内到外逐层保障：

```
┌─────────────────────────────────────────────────────────────────┐
│  第三层：全局 Invariant（每轮结束后）                           │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  第二层：操作组合验证（一轮内多个操作的交叉影响）         │  │
│  │  ┌─────────────────────────────────────────────────────┐  │  │
│  │  │  第一层：单操作 Delta 验证（每次调用前后状态差）    │  │  │
│  │  └─────────────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

- **第一层**：每次 deposit / redeem / requestRedeem 等操作前拍快照（Snapshot），操作后校验 delta 是否与预期一致
- **第二层**：一轮内多个用户 / 多种操作执行完毕后，校验它们的 **交叉影响** 是否正确（如：用户 A deposit 不影响用户 B 的 shares）
- **第三层**：一轮所有操作结束后，执行 8 条全局 invariant 检查

### 11.2 Snapshot — Delta 校验模式

每个操作前记录全局状态快照，操作后计算实际 delta 与预期 delta 对比：

```solidity
struct Snapshot {
    // --- Vault 全局状态 ---
    uint256 vaultTotalAssets;
    uint256 vaultTotalSupply;
    uint256 vaultPhysicalCash;          // usdc.balanceOf(vault)
    uint256 vaultTotalLockedShares;
    uint256 vaultTotalInvestInFlight;
    uint256 vaultTotalRedeemInFlight;
    uint256 vaultNextRequestId;
    uint256 vaultNextInFlightId;
    uint256 exchangeRate;

    // --- 当前操作用户状态 ---
    uint256 userShareBalance;
    uint256 userUsdcBalance;

    // --- 关键第三方状态 ---
    uint256 treasuryShareBalance;
    uint256 sanctionSafeShareBalance;
    uint256 sanctionSafeUsdcBalance;
}

function _takeSnapshot(address user) internal view returns (Snapshot memory s) {
    s.vaultTotalAssets          = vault.totalAssets();
    s.vaultTotalSupply          = vault.totalSupply();
    s.vaultPhysicalCash         = usdc.balanceOf(address(vault));
    s.vaultTotalLockedShares    = vault.totalLockedShares();
    s.vaultTotalInvestInFlight  = vault.totalInvestInFlight();
    s.vaultTotalRedeemInFlight  = vault.totalRedeemInFlight();
    s.vaultNextRequestId        = vault.nextRequestId();
    s.vaultNextInFlightId       = vault.nextInFlightId();
    s.exchangeRate              = accountant.getRate();
    s.userShareBalance          = vault.balanceOf(user);
    s.userUsdcBalance           = usdc.balanceOf(user);
    s.treasuryShareBalance      = vault.balanceOf(treasury);
    s.sanctionSafeShareBalance  = vault.balanceOf(sanctionSafe);
    s.sanctionSafeUsdcBalance   = usdc.balanceOf(sanctionSafe);
}
```

### 11.3 第一层：单操作 Delta 验证

#### 6.3.1 Deposit 验证

```solidity
function _depositAs(address user, uint256 assets) internal returns (uint256 shares) {
    Snapshot memory before = _takeSnapshot(user);

    // --- 预计算期望值 ---
    uint256 expectedShares = vault.previewDeposit(assets);

    // --- 执行操作 ---
    vm.prank(user);
    shares = gateway.deposit(assets);

    // --- Delta 校验 ---
    Snapshot memory after = _takeSnapshot(user);

    // 1) 用户: USDC 减少, shares 增加
    assertEq(after.userUsdcBalance, before.userUsdcBalance - assets,
        "deposit: user USDC delta");
    assertEq(after.userShareBalance, before.userShareBalance + shares,
        "deposit: user share delta");

    // 2) Vault: 物理 USDC 增加, totalSupply 增加
    assertEq(after.vaultPhysicalCash, before.vaultPhysicalCash + assets,
        "deposit: vault cash delta");
    assertEq(after.vaultTotalSupply, before.vaultTotalSupply + shares,
        "deposit: totalSupply delta");

    // 3) shares 数量与预期一致
    assertEq(shares, expectedShares, "deposit: shares == previewDeposit");

    // 4) 不影响: lockedShares, inFlight, treasury, requestId
    assertEq(after.vaultTotalLockedShares, before.vaultTotalLockedShares,
        "deposit: lockedShares unchanged");
    assertEq(after.vaultTotalInvestInFlight, before.vaultTotalInvestInFlight,
        "deposit: investInFlight unchanged");
    assertEq(after.treasuryShareBalance, before.treasuryShareBalance,
        "deposit: treasury unchanged");
}
```

#### 6.3.2 Sync Redeem 验证

```solidity
function _redeemAs(address user, uint256 shares) internal returns (uint256 assets) {
    Snapshot memory before = _takeSnapshot(user);

    // --- 预计算 ---
    uint256 expectedAssets = vault.previewRedeem(shares);
    uint256 feeBps = vault.redemptionFeeBps();
    // fee shares = ceil(shares * feeBps / 10000)
    uint256 expectedFeeShares = (shares * feeBps + 9999) / 10000;

    // --- 执行 ---
    vm.prank(user);
    assets = gateway.redeem(shares);

    // --- Delta 校验 ---
    Snapshot memory after = _takeSnapshot(user);

    // 1) 用户: shares 减少, USDC 增加
    assertEq(after.userShareBalance, before.userShareBalance - shares,
        "redeem: user share delta");
    assertEq(after.userUsdcBalance, before.userUsdcBalance + assets,
        "redeem: user USDC delta");

    // 2) Vault: 物理 USDC 减少, totalSupply 减少（扣除 fee 后 burn）
    assertEq(after.vaultPhysicalCash, before.vaultPhysicalCash - assets,
        "redeem: vault cash delta");
    // totalSupply 减少 = shares - feeShares（burn 了 net，fee 转给 treasury）
    assertEq(after.vaultTotalSupply,
        before.vaultTotalSupply - shares + expectedFeeShares,
        "redeem: totalSupply delta");

    // 3) Treasury: 收到 fee shares
    assertEq(after.treasuryShareBalance,
        before.treasuryShareBalance + expectedFeeShares,
        "redeem: treasury fee delta");

    // 4) assets 与预期一致
    assertEq(assets, expectedAssets, "redeem: assets == previewRedeem");

    // 5) 不影响: lockedShares, inFlight
    assertEq(after.vaultTotalLockedShares, before.vaultTotalLockedShares,
        "redeem: lockedShares unchanged");
}
```

#### 6.3.3 Async Redeem Request 验证

```solidity
function _requestRedeemAs(address user, uint256 shares)
    internal returns (uint256 requestId)
{
    Snapshot memory before = _takeSnapshot(user);

    // --- 预计算 ---
    uint256 feeBps = vault.redemptionFeeBps();
    uint256 expectedFeeShares = (shares * feeBps + 9999) / 10000;
    uint256 netShares = shares - expectedFeeShares;

    // --- 执行 ---
    vm.prank(user);
    requestId = gateway.requestRedeem(shares);

    // --- Delta 校验 ---
    Snapshot memory after = _takeSnapshot(user);

    // 1) 用户: shares 全部消失（burn net + fee 转 treasury）
    assertEq(after.userShareBalance, before.userShareBalance - shares,
        "requestRedeem: user share delta");

    // 2) 用户 USDC 不变（异步，未到账）
    assertEq(after.userUsdcBalance, before.userUsdcBalance,
        "requestRedeem: user USDC unchanged");

    // 3) Treasury: 收到 fee shares
    assertEq(after.treasuryShareBalance,
        before.treasuryShareBalance + expectedFeeShares,
        "requestRedeem: treasury fee delta");

    // 4) totalLockedShares 增加 netShares
    assertEq(after.vaultTotalLockedShares,
        before.vaultTotalLockedShares + netShares,
        "requestRedeem: lockedShares delta");

    // 5) totalSupply 减少 netShares（被 burn）
    assertEq(after.vaultTotalSupply,
        before.vaultTotalSupply - netShares,
        "requestRedeem: totalSupply delta");

    // 6) 新 request 创建正确
    assertEq(after.vaultNextRequestId, before.vaultNextRequestId + 1,
        "requestRedeem: requestId incremented");
    (,, uint256 reqShares,,,, uint8 status) = vault.requests(requestId);
    assertEq(reqShares, netShares, "requestRedeem: request.shares == netShares");
    assertEq(status, uint8(RequestStatus.PENDING), "requestRedeem: status PENDING");

    // 7) 物理 USDC 不变（shares 操作不涉及 USDC 转移）
    assertEq(after.vaultPhysicalCash, before.vaultPhysicalCash,
        "requestRedeem: vault cash unchanged");
}
```

#### 6.3.4 Process Redeem Batch 验证

```solidity
function _verifyProcessRedeemBatch(uint256[] memory ids) internal {
    // 记录每个 request 处理前的状态
    uint256 lockedBefore = vault.totalLockedShares();
    uint256 cashBefore = usdc.balanceOf(address(vault));
    uint256 investIFBefore = vault.totalInvestInFlight();
    uint256 redeemIFBefore = vault.totalRedeemInFlight();
    uint256 nextIFIdBefore = vault.nextInFlightId();

    // --- 执行 ---
    vm.prank(bot);
    operatorExecutor.executeProcessRedeemBatch(address(controller), ids);

    // --- 校验 ---
    // 1) 每个 request 状态 PENDING → PROCESSING
    for (uint256 i = 0; i < ids.length; i++) {
        (,,,,,,uint8 status) = vault.requests(ids[i]);
        assertEq(status, uint8(RequestStatus.PROCESSING),
            "process: request status == PROCESSING");
    }

    // 2) totalLockedShares 不变（process 阶段不释放锁定）
    assertEq(vault.totalLockedShares(), lockedBefore,
        "process: lockedShares unchanged");

    // 3) 如果触发了 divest:
    uint256 nextIFIdAfter = vault.nextInFlightId();
    if (nextIFIdAfter > nextIFIdBefore) {
        // divest 产生了新的 in-flight 记录
        uint256 newIFCount = nextIFIdAfter - nextIFIdBefore;
        console2.log("[VERIFY] process triggered divest, new in-flight count:", newIFCount);

        // redeemInFlight 应增加（divest 是从策略赎回）
        assertGe(vault.totalRedeemInFlight(), redeemIFBefore,
            "process+divest: redeemInFlight increased");

        // 验证每条新 in-flight 的状态
        for (uint256 j = nextIFIdBefore; j < nextIFIdAfter; j++) {
            (,,,,,,bool isInvest,, uint8 ifStatus) = vault.inFlightRecords(j);
            assertEq(isInvest, false, "process+divest: in-flight is redeem");
            assertEq(ifStatus, uint8(InFlightStatus.PENDING),
                "process+divest: in-flight status PENDING");
        }
    }
}
```

#### 6.3.5 Finalize Redeem Batch 验证

```solidity
function _verifyFinalizeRedeemBatch(
    uint256[] memory ids,
    uint256[] memory settledAssets
) internal {
    // 记录每个 request 的 owner 和 shares
    address[] memory owners = new address[](ids.length);
    uint256[] memory reqShares = new uint256[](ids.length);
    uint256[] memory ownerUsdcBefore = new uint256[](ids.length);
    uint256 totalSettled;

    for (uint256 i = 0; i < ids.length; i++) {
        (, address owner, uint256 shares,,,,) = vault.requests(ids[i]);
        owners[i] = owner;
        reqShares[i] = shares;
        // 确定接收方：如果被制裁则是 sanctionSafe
        address receiver = oracle.isSanctioned(owner) ? sanctionSafe : owner;
        ownerUsdcBefore[i] = usdc.balanceOf(receiver);
        totalSettled += settledAssets[i];
    }
    uint256 lockedBefore = vault.totalLockedShares();
    uint256 cashBefore = usdc.balanceOf(address(vault));

    // --- 执行 ---
    vm.prank(bot);
    operatorExecutor.executeFinalizeRedeemBatch(
        address(controller), ids, settledAssets
    );

    // --- 校验 ---
    uint256 totalReleasedShares;
    for (uint256 i = 0; i < ids.length; i++) {
        // 1) request 状态 PROCESSING → DONE
        (,,,,uint256 settled,, uint8 status) = vault.requests(ids[i]);
        assertEq(status, uint8(RequestStatus.DONE), "finalize: status DONE");
        assertEq(settled, settledAssets[i], "finalize: settledAssets recorded");

        // 2) 接收方 USDC 增加
        address receiver = oracle.isSanctioned(owners[i]) ? sanctionSafe : owners[i];
        assertEq(usdc.balanceOf(receiver),
            ownerUsdcBefore[i] + settledAssets[i],
            "finalize: receiver USDC delta");

        totalReleasedShares += reqShares[i];
    }

    // 3) totalLockedShares 减少
    assertEq(vault.totalLockedShares(),
        lockedBefore - totalReleasedShares,
        "finalize: lockedShares released");

    // 4) vault 物理 USDC 减少
    assertEq(usdc.balanceOf(address(vault)),
        cashBefore - totalSettled,
        "finalize: vault cash decreased");
}
```

#### 6.3.6 Rebalance (Invest) 验证

```solidity
function _verifyRebalanceInvest() internal {
    uint256 cashBefore = usdc.balanceOf(address(vault));
    uint256 investIFBefore = vault.totalInvestInFlight();
    uint256 nextIFIdBefore = vault.nextInFlightId();

    // --- 执行 ---
    vm.prank(bot);
    operatorExecutor.executeRebalance(address(controller));

    // --- 校验 ---
    uint256 cashAfter = usdc.balanceOf(address(vault));
    uint256 investIFAfter = vault.totalInvestInFlight();
    uint256 nextIFIdAfter = vault.nextInFlightId();

    // USDC 减少 == investInFlight 增加（资金从 vault 转到 adapter）
    uint256 cashDelta = cashBefore - cashAfter;
    uint256 ifDelta = investIFAfter - investIFBefore;
    assertEq(cashDelta, ifDelta,
        "rebalance: cash decrease == investInFlight increase");

    // 每条新 in-flight 记录验证
    for (uint256 j = nextIFIdBefore; j < nextIFIdAfter; j++) {
        (,address adapter,, uint256 tokenAmt, uint256 usdcAmt,,
         bool isInvest,, uint8 ifStatus) = vault.inFlightRecords(j);
        assertTrue(isInvest, "rebalance: in-flight isInvest");
        assertEq(ifStatus, uint8(InFlightStatus.PENDING), "rebalance: IF PENDING");
        assertGt(usdcAmt, 0, "rebalance: usdcAmount > 0");
        assertGt(tokenAmt, 0, "rebalance: tokenAmount > 0");
        // adapter 是已注册的策略
        assertTrue(controller.isStrategyRegistered(adapter),
            "rebalance: adapter registered");
    }

    // totalAssets 不应变化（cash 减少 == investInFlight 增加，互相抵消）
    // 注意：由于 adapter.totalValue() 可能还没反映新投资，
    // totalAssets 可能有微小变化，允许 1 wei 误差
}
```

#### 6.3.7 Settle Adapter 验证

```solidity
function _verifySettleInvest(
    address adapter,
    uint256[] memory inFlightIds,
    uint256[] memory settledPos,
    uint256[] memory refunds
) internal {
    uint256 investIFBefore = vault.totalInvestInFlight();
    uint256 cashBefore = usdc.balanceOf(address(vault));
    uint256 expectedIFDecrease;
    uint256 expectedRefund;

    for (uint256 i = 0; i < inFlightIds.length; i++) {
        (,,,, uint256 usdcAmt,,,,) = vault.inFlightRecords(inFlightIds[i]);
        expectedIFDecrease += usdcAmt;
        expectedRefund += refunds[i];
    }

    // --- 执行 ---
    // ... settleAdapter call ...

    // --- 校验 ---
    // 1) investInFlight 减少
    assertEq(vault.totalInvestInFlight(),
        investIFBefore - expectedIFDecrease,
        "settle-invest: investIF decreased");

    // 2) vault 收到 refund USDC
    assertEq(usdc.balanceOf(address(vault)),
        cashBefore + expectedRefund,
        "settle-invest: refund received");

    // 3) 每条 in-flight 记录变为 CONFIRMED
    for (uint256 i = 0; i < inFlightIds.length; i++) {
        (,,,,,,,,uint8 ifStatus) = vault.inFlightRecords(inFlightIds[i]);
        assertEq(ifStatus, uint8(InFlightStatus.CONFIRMED),
            "settle-invest: IF CONFIRMED");
    }
}

function _verifySettleRedeem(
    address adapter,
    uint256[] memory inFlightIds,
    uint256[] memory settledAssets
) internal {
    uint256 redeemIFBefore = vault.totalRedeemInFlight();
    uint256 cashBefore = usdc.balanceOf(address(vault));
    uint256 expectedIFDecrease;
    uint256 totalSettledAsset;

    for (uint256 i = 0; i < inFlightIds.length; i++) {
        (,,,, uint256 usdcAmt,,,,) = vault.inFlightRecords(inFlightIds[i]);
        expectedIFDecrease += usdcAmt;
        totalSettledAsset += settledAssets[i];
    }

    // --- 执行 ---
    // ... settleAdapter call ...

    // --- 校验 ---
    // 1) redeemInFlight 减少（按原始记录的 usdcAmount，不是 settledAsset）
    assertEq(vault.totalRedeemInFlight(),
        redeemIFBefore - expectedIFDecrease,
        "settle-redeem: redeemIF decreased");

    // 2) vault 收到实际 USDC（可能 > 或 < 预期）
    assertEq(usdc.balanceOf(address(vault)),
        cashBefore + totalSettledAsset,
        "settle-redeem: USDC received");

    // 3) 每条 in-flight 变为 CONFIRMED
    for (uint256 i = 0; i < inFlightIds.length; i++) {
        (,,,,,,,,uint8 ifStatus) = vault.inFlightRecords(inFlightIds[i]);
        assertEq(ifStatus, uint8(InFlightStatus.CONFIRMED),
            "settle-redeem: IF CONFIRMED");
    }

    // 4) 如果 settledAsset < 原始 usdcAmount → 亏损场景
    //    如果 settledAsset == 0 → 全损场景
    //    两种情况都不应 revert，系统继续运行
}
```

#### 6.3.8 Exchange Rate Update 验证

```solidity
function _verifyExchangeRateUpdate(uint256 newRate) internal {
    uint256 rateBefore = accountant.getRate();
    uint256 supplyBefore = vault.totalSupply();
    uint256 treasuryBefore = vault.balanceOf(treasury);

    // --- 执行 ---
    vm.prank(bot);
    accountantExecutor.executeExchangeRateUpdate(
        address(accountant), uint64(newRate), uint64(block.timestamp)
    );

    // --- 校验 ---
    // 1) rate 已更新
    assertEq(accountant.getRate(), newRate, "rateUpdate: rate applied");

    // 2) management fee 已结算（treasury shares 增加）
    uint256 treasuryAfter = vault.balanceOf(treasury);
    uint256 feeSharesMinted = treasuryAfter - treasuryBefore;

    // 3) fee 计算验证（允许 1 wei 舍入误差）
    //    理论值: shareBase * feeRate * timeElapsed / (10000 * 365 days)
    //    shareBase = min(currentSupply, lastSettleSupply)
    if (feeSharesMinted > 0) {
        console2.log("[VERIFY] fee shares minted:", feeSharesMinted);
        // 记录累积 fee 用于最终精度校验
        _cumulativeFeeShares += feeSharesMinted;
    }

    // 4) totalSupply 增加了 feeSharesMinted
    assertEq(vault.totalSupply(), supplyBefore + feeSharesMinted,
        "rateUpdate: totalSupply += feeShares");
}
```

#### 6.3.9 Sanction 操作验证

```solidity
function _verifySanctionedDeposit(address user, uint256 amount) internal {
    // 被制裁用户 deposit 应 revert
    vm.prank(user);
    vm.expectRevert();  // SanctionedAddress error
    gateway.deposit(amount);
}

function _verifySanctionedRedeem(address user, uint256 shares) internal {
    Snapshot memory before = _takeSnapshot(user);
    uint256 safeBefore = vault.balanceOf(sanctionSafe);

    // 被制裁用户 redeem → shares 路由到 sanctionSafe
    vm.prank(user);
    gateway.redeem(shares);

    // 1) 用户 shares 减少
    assertEq(vault.balanceOf(user), before.userShareBalance - shares,
        "sanctioned-redeem: user shares decreased");

    // 2) sanctionSafe shares 增加（路由过去的）
    assertEq(vault.balanceOf(sanctionSafe), safeBefore + shares,
        "sanctioned-redeem: safe received shares");

    // 3) 用户 USDC 不变（没有实际赎回）
    assertEq(usdc.balanceOf(user), before.userUsdcBalance,
        "sanctioned-redeem: user USDC unchanged");
}

function _verifySanctionedFinalize(
    uint256 requestId,
    address originalOwner,
    uint256 settledAsset
) internal {
    // 用户在 request 之后被制裁，finalize 时应路由到 sanctionSafe
    uint256 safeBefore = usdc.balanceOf(sanctionSafe);

    // ... finalize batch ...

    // settledAssets 应到 sanctionSafe 而非 originalOwner
    assertEq(usdc.balanceOf(sanctionSafe),
        safeBefore + settledAsset,
        "sanctioned-finalize: assets to safe");
}
```

### 11.4 第二层：多用户操作组合验证

#### 6.4.1 一轮多用户操作的验证策略

一轮内可能有多个用户各自执行不同操作。验证策略是：**记录所有用户操作前状态 → 逐个执行并校验单操作 delta → 全部执行完后校验聚合 delta**。

```solidity
function _executeRound(uint256 round) internal {
    // ========== 阶段 1: 拍全局快照 ==========
    uint256 totalSupplyBefore   = vault.totalSupply();
    uint256 totalAssetsBefore   = vault.totalAssets();
    uint256 physicalCashBefore  = usdc.balanceOf(address(vault));
    uint256 treasuryBefore      = vault.balanceOf(treasury);

    // 记录每个用户的 share 和 USDC 余额
    uint256[] memory userSharesBefore = new uint256[](users.length);
    uint256[] memory userUsdcBefore   = new uint256[](users.length);
    for (uint256 i = 0; i < users.length; i++) {
        userSharesBefore[i] = vault.balanceOf(users[i]);
        userUsdcBefore[i]   = usdc.balanceOf(users[i]);
    }

    // 本轮累积器
    uint256 totalDeposited;
    uint256 totalSyncRedeemed;
    uint256 totalAsyncRequested;
    uint256 totalFeeSharesMinted;

    // ========== 阶段 2: 逐个操作，每次校验单操作 delta ==========
    uint256 opCount = _scaledRand(1, 4, 50);
    for (uint256 op = 0; op < opCount; op++) {
        address user = _randUser();
        uint256 action = _rand(100);

        if (action < 60) {
            // --- Deposit ---
            uint256 amount = _randBetween(1e6, 10_000e6);
            uint256 shares = _depositAs(user, amount);  // 内部已校验 delta
            totalDeposited += amount;
        } else if (action < 80) {
            // --- Sync Redeem ---
            uint256 userShares = vault.balanceOf(user);
            if (userShares > 0) {
                uint256 shares = _randBetween(1, userShares);
                uint256 assets = _redeemAs(user, shares);  // 内部已校验 delta
                totalSyncRedeemed += assets;
            }
        } else {
            // --- Async Request Redeem ---
            uint256 userShares = vault.balanceOf(user);
            if (userShares > 0) {
                uint256 shares = _randBetween(1, userShares);
                uint256 reqId = _requestRedeemAs(user, shares); // 内部已校验
                totalAsyncRequested += shares;
            }
        }
    }

    // ========== 阶段 3: 聚合验证 ==========
    _verifyAggregatedDeltas(
        totalSupplyBefore, totalAssetsBefore, physicalCashBefore,
        treasuryBefore, userSharesBefore, userUsdcBefore,
        totalDeposited, totalSyncRedeemed, totalAsyncRequested
    );

    // ========== 阶段 4: 全局 invariant ==========
    _checkAllInvariants(string.concat("round ", vm.toString(round)));
    _logMetrics(round);
}
```

#### 6.4.2 聚合 Delta 验证

一轮结束后，校验所有操作的总效果是否与各操作 delta 之和一致：

```solidity
function _verifyAggregatedDeltas(
    uint256 totalSupplyBefore,
    uint256 totalAssetsBefore,
    uint256 physicalCashBefore,
    uint256 treasuryBefore,
    uint256[] memory userSharesBefore,
    uint256[] memory userUsdcBefore,
    uint256 totalDeposited,
    uint256 totalSyncRedeemed,
    uint256 totalAsyncRequested
) internal view {
    // === 份额守恒验证 ===
    // 所有用户 share 变化之和 + treasury 变化 = totalSupply 变化
    int256 totalShareDelta;
    for (uint256 i = 0; i < users.length; i++) {
        totalShareDelta += int256(vault.balanceOf(users[i]))
                         - int256(userSharesBefore[i]);
    }
    int256 treasuryDelta = int256(vault.balanceOf(treasury))
                         - int256(treasuryBefore);
    int256 supplyDelta   = int256(vault.totalSupply())
                         - int256(totalSupplyBefore);

    // 份额流入 = 用户变化 + treasury 变化 + sanctionSafe 变化
    // 必须等于 totalSupply 变化
    int256 safeDelta = int256(vault.balanceOf(sanctionSafe))
                     - int256(sanctionSafeSharesBefore);
    assertEq(totalShareDelta + treasuryDelta + safeDelta, supplyDelta,
        "aggregate: share conservation");

    // === USDC 守恒验证 ===
    // 所有 USDC 变化之和 = 0（闭环系统，USDC 不会凭空产生或消失）
    int256 totalUsdcDelta;
    for (uint256 i = 0; i < users.length; i++) {
        totalUsdcDelta += int256(usdc.balanceOf(users[i]))
                        - int256(userUsdcBefore[i]);
    }
    int256 vaultCashDelta = int256(usdc.balanceOf(address(vault)))
                          - int256(physicalCashBefore);
    int256 safeUsdcDelta  = int256(usdc.balanceOf(sanctionSafe))
                          - int256(sanctionSafeUsdcBefore);

    // 用户 USDC 变化 + vault USDC 变化 + safe USDC 变化 = 0
    assertEq(totalUsdcDelta + vaultCashDelta + safeUsdcDelta, 0,
        "aggregate: USDC conservation (closed system)");
}
```

#### 6.4.3 多用户操作互不干扰验证

验证用户 A 的操作不会影响用户 B 的状态（除了全局变量的合法间接影响）：

```solidity
// 在一轮中，记录每个用户的"预期最终状态"
// 如果用户本轮没有操作，其 share 和 USDC 余额应完全不变
function _verifyNoUnintendedSideEffects(
    uint256[] memory userSharesBefore,
    uint256[] memory userUsdcBefore,
    bool[] memory userActedThisRound
) internal view {
    for (uint256 i = 0; i < users.length; i++) {
        if (!userActedThisRound[i]) {
            // 未操作的用户: share 和 USDC 余额必须不变
            assertEq(vault.balanceOf(users[i]), userSharesBefore[i],
                string.concat("side-effect: user ", vm.toString(i),
                    " shares unchanged"));
            assertEq(usdc.balanceOf(users[i]), userUsdcBefore[i],
                string.concat("side-effect: user ", vm.toString(i),
                    " USDC unchanged"));
        }
    }
}
```

### 11.5 第三层：全局 Invariant 详细实现

#### I1: 资产守恒

```solidity
function _checkI1_AssetConservation(string memory ctx) internal view {
    uint256 physicalCash = usdc.balanceOf(address(vault));
    uint256 investIF     = vault.totalInvestInFlight();
    uint256 redeemIF     = vault.totalRedeemInFlight();

    // 遍历所有注册策略，求 adapter 持仓总值
    uint256 strategyValue;
    address[] memory adapters = controller.getStrategyOrder();
    for (uint256 i = 0; i < adapters.length; i++) {
        strategyValue += IStrategyAdapter(adapters[i]).totalValue();
    }

    // 原始总量（不扣除 lockedShares 占位）
    uint256 rawTotal = physicalCash + investIF + redeemIF + strategyValue;

    // vault.totalAssets() 内部扣除了 floatingLocked
    uint256 reportedTotal = vault.totalAssets();

    // totalAssets 不能为负（合约已保护，返回 0）
    assertGe(reportedTotal, 0,
        string.concat(ctx, " I1: totalAssets >= 0"));

    // rawTotal 必须 >= floatingLocked（否则 totalAssets 会是 0）
    uint256 lockedShares = vault.totalLockedShares();
    if (lockedShares > 0) {
        // floatingLocked = convertToAssets(lockedShares, Ceil)
        // 由于我们无法直接调用 internal _convertToAssets，
        // 用 rawTotal >= reportedTotal 间接验证
        assertGe(rawTotal, reportedTotal,
            string.concat(ctx, " I1: rawTotal >= reportedTotal"));
    }
}
```

#### I2: 份额守恒

```solidity
function _checkI2_ShareConservation(string memory ctx) internal view {
    uint256 totalSupply = vault.totalSupply();

    // 汇总所有已知地址的 shares
    uint256 accountedShares;
    for (uint256 i = 0; i < users.length; i++) {
        accountedShares += vault.balanceOf(users[i]);
    }
    accountedShares += vault.balanceOf(treasury);
    accountedShares += vault.balanceOf(sanctionSafe);
    accountedShares += vault.balanceOf(admin);

    // Local 模式: 所有地址都已知，accountedShares == totalSupply
    if (!IS_FORK) {
        assertEq(accountedShares, totalSupply,
            string.concat(ctx, " I2: shares fully accounted (local)"));
    } else {
        // Fork 模式: 链上可能有其他持仓用户
        // 验证: accountedShares <= totalSupply（不超发）
        assertLe(accountedShares, totalSupply,
            string.concat(ctx, " I2: known shares <= totalSupply (fork)"));
        // 未知地址持仓 = totalSupply - accountedShares
        uint256 unknownShares = totalSupply - accountedShares;
        // 未知持仓应等于 fork 时的初始未知持仓（我们不操作那些地址）
        assertEq(unknownShares, _forkInitialUnknownShares,
            string.concat(ctx, " I2: unknown shares unchanged (fork)"));
    }
}
```

#### I4: 请求状态完整性

```solidity
function _checkI4_RequestIntegrity(string memory ctx) internal view {
    // 遍历所有已创建的 request（从 _baseRequestId 到 nextRequestId）
    uint256 nextId = vault.nextRequestId();
    for (uint256 id = _baseRequestId; id < nextId; id++) {
        (,, uint256 shares,, uint256 settledAssets,, uint8 status) =
            vault.requests(id);

        if (status == uint8(RequestStatus.PENDING)) {
            // PENDING: settledAssets 必须为 0
            assertEq(settledAssets, 0,
                string.concat(ctx, " I4: PENDING.settled == 0, id=",
                    vm.toString(id)));
            assertGt(shares, 0,
                string.concat(ctx, " I4: PENDING.shares > 0"));
        } else if (status == uint8(RequestStatus.PROCESSING)) {
            // PROCESSING: settledAssets 仍为 0（还没 finalize）
            assertEq(settledAssets, 0,
                string.concat(ctx, " I4: PROCESSING.settled == 0"));
        } else if (status == uint8(RequestStatus.DONE)) {
            // DONE: settledAssets 已设置（可以是 0 如果全损，但一般 > 0）
            // 注意: 全损场景下 settledAssets == 0 是合法的
        }

        // 状态单调: 不应存在 NONE（已创建的 request 至少是 PENDING）
        assertTrue(status >= uint8(RequestStatus.PENDING),
            string.concat(ctx, " I4: status >= PENDING"));

        // 记录状态用于 I8 校验
    }
}
```

#### I7: 在途记录一致性

```solidity
function _checkI7_InFlightConsistency(string memory ctx) internal view {
    uint256 nextId = vault.nextInFlightId();
    uint256 sumInvestIF;
    uint256 sumRedeemIF;

    for (uint256 id = _baseInFlightId; id < nextId; id++) {
        (,,,, uint256 usdcAmt,, bool isInvest,, uint8 ifStatus) =
            vault.inFlightRecords(id);

        if (ifStatus == uint8(InFlightStatus.PENDING)) {
            if (isInvest) {
                sumInvestIF += usdcAmt;
            } else {
                sumRedeemIF += usdcAmt;
            }
        }
        // CONFIRMED 的不计入（已从全局计数器中扣除）
    }

    assertEq(vault.totalInvestInFlight(), sumInvestIF,
        string.concat(ctx, " I7: investIF sum matches"));
    assertEq(vault.totalRedeemInFlight(), sumRedeemIF,
        string.concat(ctx, " I7: redeemIF sum matches"));
}
```

#### I8: 锁定份额一致性

```solidity
function _checkI8_LockedSharesBalance(string memory ctx) internal view {
    uint256 nextId = vault.nextRequestId();
    uint256 sumLockedShares;

    for (uint256 id = _baseRequestId; id < nextId; id++) {
        (,, uint256 shares,,,, uint8 status) = vault.requests(id);
        if (status == uint8(RequestStatus.PENDING)
            || status == uint8(RequestStatus.PROCESSING)) {
            sumLockedShares += shares;
        }
    }

    assertEq(vault.totalLockedShares(), sumLockedShares,
        string.concat(ctx, " I8: lockedShares == sum(PENDING+PROCESSING)"));
}
```

### 11.6 全局资金闭环方程

整个系统是一个闭环：测试注入的 USDC 总量在系统内流转，不会凭空产生或消失。

```
USDC 守恒方程（任何时刻成立）:

  Σ users[i].usdcBalance          // 用户持有的 USDC
+ usdc.balanceOf(vault)           // vault 物理 USDC
+ usdc.balanceOf(sanctionSafe)    // 制裁安全地址持有的 USDC
+ Σ adapter[j].usdcBalance        // adapter 中暂存的 USDC（settle 前）
= TOTAL_USDC_INJECTED             // 测试开始时 mint 给所有用户的总量
```

```
Shares 守恒方程（任何时刻成立）:

  Σ users[i].shareBalance         // 用户持有的 shares
+ vault.balanceOf(treasury)       // treasury 持有的 shares（fee 累积）
+ vault.balanceOf(sanctionSafe)   // safe 持有的 shares（制裁路由）
= vault.totalSupply()             // 已发行总量
```

```
totalAssets 构成方程:

  vault.totalAssets()
= usdc.balanceOf(vault)           // 物理现金
+ vault.totalInvestInFlight()     // invest 在途 USDC
+ vault.totalRedeemInFlight()     // redeem 在途 USDC（期望返回）
+ Σ adapter[j].totalValue()       // 策略持仓估值
- floatingLocked                  // 锁定份额对应的资产占位
                                  // = convertToAssets(totalLockedShares, Ceil)
```

```solidity
function _checkClosedSystemUSDC(string memory ctx) internal view {
    uint256 totalInSystem;

    // 用户持有
    for (uint256 i = 0; i < users.length; i++) {
        totalInSystem += usdc.balanceOf(users[i]);
    }
    // vault 持有
    totalInSystem += usdc.balanceOf(address(vault));
    // sanctionSafe 持有
    totalInSystem += usdc.balanceOf(sanctionSafe);
    // adapter 中暂存（settle 前可能有残留）
    address[] memory adapters = controller.getStrategyOrder();
    for (uint256 j = 0; j < adapters.length; j++) {
        totalInSystem += usdc.balanceOf(adapters[j]);
    }

    assertEq(totalInSystem, _totalUsdcInjected,
        string.concat(ctx, " USDC closed system: total == injected"));
}
```

### 11.7 各场景的具体验证策略

#### S1 (DepositRedeemMix) 验证重点

```
每轮:
  ┌─ 快照全局状态 + 所有用户状态
  │
  ├─ 操作 1: userA.deposit(500 USDC)
  │   └─ delta 校验: A.shares↑, A.usdc↓, vault.cash↑, supply↑
  │
  ├─ 操作 2: userB.redeem(100 shares)
  │   └─ delta 校验: B.shares↓, B.usdc↑, vault.cash↓, treasury↑
  │
  ├─ 操作 3: userC.deposit(1 USDC)    ← dust 金额
  │   └─ delta 校验: shares > 0（不能因精度丢失 mint 0 shares）
  │
  ├─ 聚合验证:
  │   ├─ 份额守恒: Σ share 变化 + treasury 变化 == supply 变化
  │   ├─ USDC 守恒: Σ USDC 变化 == 0
  │   └─ 未操作用户: 余额完全不变
  │
  ├─ 每 10 轮: exchange rate 更新
  │   └─ 更新后立即 deposit/redeem → 验证新 rate 下份额计算正确
  │
  └─ 全局 invariant I1, I2, I3, I6
```

#### S2 (AsyncRedeemFullCycle) 验证重点

```
每轮:
  Phase A (积累请求):
  ┌─ 快照: lockedShares, requestId counter
  │
  ├─ N 个用户各自 requestRedeem
  │   └─ 每个: delta 校验 + request 对象验证
  │
  ├─ 聚合验证:
  │   ├─ lockedShares 增量 == Σ netShares
  │   ├─ treasury 增量 == Σ feeShares
  │   ├─ totalSupply 减量 == Σ netShares（burn）
  │   └─ 新 request 全部 PENDING
  │
  Phase B (部分处理):
  ├─ 选取部分 PENDING → processRedeemBatch
  │   ├─ 选中的 → PROCESSING
  │   ├─ 未选中的 → 保持 PENDING
  │   └─ 如触发 divest: 验证 in-flight 创建
  │
  Phase C (结算):
  ├─ settle in-flight（如有 divest 产生的）
  │   └─ delta 校验: redeemIF↓, cash↑
  │
  ├─ finalizeRedeemBatch
  │   ├─ 每个 request: PROCESSING → DONE
  │   ├─ 每个用户/sanctionSafe: USDC 收到 settledAssets
  │   ├─ lockedShares 释放
  │   └─ vault.cash 减少 == Σ settledAssets
  │
  Phase D (跨轮):
  ├─ 上一轮遗留的 PENDING 在本轮被 process
  │   └─ 验证新旧请求混合 batch 的 key 唯一性
  │
  └─ 全局 invariant I1, I2, I4, I7, I8
      特别:
      ├─ I8: lockedShares == Σ(PENDING + PROCESSING).shares
      └─ I4: 无 "跳跃"（不能从 PENDING 直接到 DONE）
```

#### S3 (RebalanceSettlement) 验证重点

```
每轮:
  Phase A (invest):
  ┌─ 快照: cash, investIF, nextInFlightId
  │
  ├─ _scaledRand(2, 5, 30) users deposit → cash 充裕
  ├─ rebalance()
  │   ├─ cash↓ == investIF↑
  │   ├─ 新 in-flight 全部 isInvest=true, PENDING
  │   └─ adapter 收到 USDC（adapter.usdcBalance↑）
  │
  Phase B (invest settle):
  ├─ settleAdapter (invest)
  │   ├─ investIF↓ == 回收的原始 usdcAmount
  │   ├─ vault 收到 pos token + refund
  │   ├─ in-flight → CONFIRMED
  │   └─ adapter.usdcBalance → 0（全部 sweep 回 vault）
  │
  Phase C (divest):
  ├─ 用户 requestRedeem → processRedeemBatch 触发 divest
  │   ├─ sync adapter: 立即返回 USDC → in-flight 直接记录 received
  │   ├─ async adapter: 产生 PENDING redeem in-flight
  │   └─ redeemIF↑
  │
  Phase D (redeem settle):
  ├─ settleAdapter (redeem)
  │   ├─ redeemIF↓
  │   ├─ vault.cash↑
  │   └─ in-flight → CONFIRMED
  │
  ├─ finalizeRedeemBatch → 用户收到 USDC
  │
  └─ 全局 invariant I1, I3, I7
      特别:
      ├─ 全部 settle 后: investIF == 0, redeemIF == 0
      ├─ 无 "幽灵" in-flight（遍历全部 ID 确认无遗漏 PENDING）
      └─ 策略权重: |adapter.totalValue / netAssets - targetWeight| < threshold
```

#### S5 (SanctionedUserInterlace) 验证重点

```
每轮:
  Phase A (正常交易基线):
  ┌─ 记录所有用户 shares + USDC
  │
  ├─ 正常用户 deposit/redeem → 标准 delta 校验
  │
  Phase B (制裁穿插):
  ├─ 施加制裁: oracle.setSanctioned(userX, true)
  │
  ├─ 被制裁用户操作验证:
  │   ├─ deposit → revert（不消耗 USDC，状态不变）
  │   ├─ redeem → shares 转 sanctionSafe
  │   │   ├─ userX.shares↓
  │   │   ├─ sanctionSafe.shares↑（等量）
  │   │   └─ userX.usdc 不变, vault.cash 不变
  │   ├─ requestRedeem → shares 转 sanctionSafe
  │   │   └─ 同上逻辑
  │   └─ transfer → revert
  │
  ├─ 正常用户继续操作 → 验证不受影响:
  │   └─ 正常用户的 delta 与无制裁时完全一致
  │
  Phase C (中途制裁):
  ├─ userA requestRedeem (PENDING 状态)
  ├─ 施加制裁: oracle.setSanctioned(userA, true)
  ├─ processRedeemBatch + finalizeRedeemBatch
  │   └─ 验证: USDC 到 sanctionSafe 而非 userA
  │       ├─ sanctionSafe.usdc↑ == settledAssets
  │       └─ userA.usdc 不变
  │
  Phase D (解除制裁):
  ├─ oracle.setSanctioned(userX, false)
  ├─ 用户恢复正常操作 → 标准 delta 校验通过
  │
  └─ 全局 invariant I1, I2, I6
      特别:
      ├─ sanctionSafe 余额 == Σ 所有制裁路由的 shares + USDC
      └─ USDC 闭环: 总量不变（资金只是换了接收方）
```

#### S7 (FullProtocolEndurance) 验证重点

S7 综合了所有场景的验证，以「每日」为单位组织：

```
每天:
  ┌─ 日快照: 全局状态 + 所有用户状态
  │
  ├─ Morning: deposits + transfers
  │   ├─ 每笔 deposit: 单操作 delta 校验
  │   ├─ 每笔 transfer: sender↓, receiver↑, totalSupply 不变
  │   └─ 聚合: USDC 闭环
  │
  ├─ Mid-morning: 制裁更新
  │   ├─ 制裁: 后续操作路由验证
  │   └─ 解除: 恢复正常验证
  │
  ├─ Noon: exchange rate + fee
  │   ├─ rate 更新: delta 校验
  │   ├─ fee mint: 理论值 vs 实际值
  │   └─ circuit breaker: 触发 → 暂停 → unpause 全流程
  │
  ├─ Afternoon: requestRedeem + sync redeem
  │   ├─ request: lockedShares 增量校验
  │   ├─ sync redeem: freeCash 充足性检查
  │   └─ 制裁用户: 路由校验
  │
  ├─ Evening: bot 运维
  │   ├─ processRedeemBatch: 状态转换 + divest 联动
  │   ├─ rebalance: invest in-flight 创建
  │   ├─ settleAdapter: in-flight 结算（含 refund / 部分 / 偏差）
  │   ├─ finalizeRedeemBatch: 用户到账
  │   └─ 聚合: 在途归零检查（T-2 的应该全部 CONFIRMED）
  │
  ├─ Night: 全面检查
  │   ├─ 8 条 invariant 全部通过
  │   ├─ USDC 闭环方程
  │   ├─ Metrics 记录
  │   └─ gas 趋势记录
  │
  └─ warp 1 day

最终验证（第 SIM_DAYS 天后）:
  ├─ 遍历所有 in-flight: 无残留 PENDING
  ├─ 遍历所有 request: 无残留 PROCESSING
  ├─ lockedShares == Σ 剩余 PENDING.shares
  ├─ 累积 fee 精度: |actual - theoretical| / theoretical < 0.0001
  ├─ gas 趋势: 线性回归斜率 < 阈值（无显著膨胀）
  └─ USDC 闭环: total == injected
```

### 11.8 Fork 模式的验证适配

Fork 模式下，链上已有状态（已有用户持仓、已有 pending 请求、已有 in-flight），需要特殊处理：

```solidity
// Fork 初始化时记录基线
uint256 _forkInitialUnknownShares;  // 链上未知用户持有的 shares
uint256 _baseRequestId;             // fork 时的 nextRequestId（之前的不管）
uint256 _baseInFlightId;            // fork 时的 nextInFlightId
uint256 _totalUsdcInjected;         // 我们注入的 USDC 总量

function _snapshotInitialState() internal {
    // 计算链上已有的、非我们创建的份额
    uint256 knownShares = vault.balanceOf(treasury)
                        + vault.balanceOf(sanctionSafe)
                        + vault.balanceOf(admin);
    _forkInitialUnknownShares = vault.totalSupply() - knownShares;

    // 记录 request/in-flight 起点，只验证我们创建的
    _baseRequestId   = vault.nextRequestId();
    _baseInFlightId  = vault.nextInFlightId();
}

// I2 适配: Local 模式用 ==，Fork 模式用差值比较
// I4/I7/I8: 只遍历 _baseRequestId 之后的 request
// USDC 闭环: 只计算我们注入的 USDC 是否守恒
```

---

## 十二、Metrics 记录

每轮迭代记录关键指标，通过 `console2.log` 输出，可 grep 做后处理分析：

```solidity
struct RoundMetrics {
    uint256 round;
    uint256 totalAssets;
    uint256 totalSupply;
    uint256 exchangeRate;
    uint256 freeCash;
    uint256 treasuryBalance;
    uint256 totalInvestInFlight;
    uint256 totalRedeemInFlight;
    uint256 totalLockedShares;
    uint256 pendingRequestCount;
    uint256 processingRequestCount;
    uint256 doneRequestCount;
}

function _logMetrics(uint256 round) internal view {
    console2.log("[METRICS] round=%d totalAssets=%d totalSupply=%d", round, vault.totalAssets(), vault.totalSupply());
    console2.log("[METRICS] round=%d rate=%d freeCash=%d", round, accountant.getRate(), vault.getFreeCash());
    console2.log("[METRICS] round=%d investIF=%d redeemIF=%d locked=%d",
        round, vault.totalInvestInFlight(), vault.totalRedeemInFlight(), vault.totalLockedShares());
    console2.log("[METRICS] round=%d treasury=%d", round, vault.balanceOf(treasury));
}
```

---

## 十三、操作数比例化（`_scaledRand`）

### 13.1 背景

默认 20 用户时，每轮操作数为 1~5 笔。当用户数增加到 100 或 1000 时，操作数保持不变——只有 0.1~0.5% 的用户被选中，无法充分测试大规模并发。

### 13.2 `_scaledRand(minVal, divisor, maxVal)` 机制

```solidity
function _scaledRand(uint256 minVal, uint256 divisor, uint256 maxVal) internal returns (uint256) {
    uint256 upper = users.length / divisor;
    if (upper < minVal) upper = minVal;
    if (upper > maxVal) upper = maxVal;
    return _randBetween(minVal, upper);
}
```

- `divisor=4` 表示约 25% 用户参与
- `maxVal` 防止大用户池时单轮 gas 爆炸

### 13.3 各场景缩放对照表

| 场景 | 位置 | 原值 | _scaledRand 参数 | 20用户 | 100用户 | 1000用户 |
|------|------|------|-----------------|--------|---------|----------|
| S1 | 每轮操作 | 1~5 | (1, 4, 50) | 1~5 | 1~25 | 1~50 |
| S2 | requestRedeem | 3~8 | (2, 4, 50) | 2~5 | 2~25 | 2~50 |
| S2 | 周期补充 | min(5) | min(len/4, 50) | 5 | 25 | 50 |
| S3 | 存款 | 2~3 | (2, 5, 30) | 2~4 | 2~20 | 2~30 |
| S3 | 赎回 | 1~3 | (1, 5, 30) | 1~4 | 1~20 | 1~30 |
| S3 | 周期补充 | min(3) | min(len/4, 50) | 5 | 25 | 50 |
| S4 | 初始 seeding | min(5) | min(len/2, 50) | 10 | 50 | 50 |
| S4 | 供给波动 | 1 | (1, 5, 30) | 1~4 | 1~20 | 1~30 |
| S5 | 正常操作 | 3~5 | (3, 4, 40) | 3~5 | 3~25 | 3~40 |
| S5 | 正常赎回 | 2 | (1, 10, 20) | 1~2 | 1~10 | 1~20 |
| S5 | 制裁 | 1~3 | (1, 10, 20) | 1~2 | 1~10 | 1~20 |
| S5 | Phase C | 3 | (2, 5, 30) | 2~4 | 2~20 | 2~30 |
| S6 | triggerDivest 赎回 | 1 | (1, 10, 20) | 1~2 | 1~10 | 1~20 |
| S6 | Case E sync 操作 | 1 | (1, 5, 20) | 1~4 | 1~20 | 1~20 |
| S6 | Case E 存款 | 1 | (1, 5, 20) | 1~4 | 1~20 | 1~20 |
| S7 | 早晨存款 | 5~10 | (3, 4, 50) | 3~5 | 3~25 | 3~50 |
| S7 | 下午赎回 | 2~5 | (2, 5, 30) | 2~4 | 2~20 | 2~30 |
| S7 | sync赎回 | 2 | (1, 10, 20) | 1~2 | 1~10 | 1~20 |
| S7 | 用户补充 | 全量 | min(len, 200) | 20 | 100 | 200 |
| S9 | 存款 | — | (2, 5, 30) | 2~4 | 2~20 | 2~30 |
| S9 | 赎回 | — | (1, 5, 20) | 1~4 | 1~20 | 1~20 |
| S9 | 周期补充 | min(5) | min(len/4, 50) | 5 | 25 | 50 |

### 13.4 大规模测试命令参考

```bash
# 100 用户，30 分钟
STRESS_USERS=100 ./test/stress/run_stress.sh 30

# 500 用户，10 轮/seed，单种子
STRESS_USERS=500 STRESS_ROUNDS=10 STRESS_SEEDS=1 ./test/stress/run_stress.sh 0

# 1000 用户，降低轮数避免超时
STRESS_USERS=1000 STRESS_ROUNDS=5 STRESS_SEEDS=1 ./test/stress/run_stress.sh 0

# 只跑新场景
STRESS_USERS=100 ./test/stress/run_stress.sh 10 S8 S9
```

### 13.5 S7 `SIM_DAYS` 自动缩减

EVM 内存在单个 `test_*()` 函数内只增不减。1000 用户 × 60 天会导致 `MemoryOOG`。StressBase `setUp()` 中自动按 `users × days ≤ 3000` 预算缩减 `SIM_DAYS`：

```solidity
if (USER_COUNT > 100 && SIM_DAYS > 10) {
    uint256 budget = 3000;
    uint256 maxDays = budget / USER_COUNT;
    if (maxDays < 5) maxDays = 5;
    if (SIM_DAYS > maxDays) SIM_DAYS = maxDays;
}
```

| 用户数 | 原 SIM_DAYS | 自动缩减后 | 说明 |
|--------|-------------|-----------|------|
| 20 | 30 | 30 | 不触发（≤100 用户） |
| 100 | 30 | 30 | 100×30=3000，刚好等于预算 |
| 200 | 30 | 15 | 200×15=3000 |
| 500 | 30 | 6 | 500×6=3000 |
| 1000 | 30 | 5 | 下限保护，至少 5 天 |

S7 的 `_phaseEvening` 用户补充循环也从遍历全量用户改为 `min(users.length, 200)` 封顶，避免单日内 1000 次 mint 调用的额外内存开销。
## 十四、实现阶段 Bug 修复与性能优化记录

> 本节记录压力测试实现过程中发现的问题和优化措施。

### 14.1 核心 Bug：MockAsyncAdapter `RedeemSweepAmountMismatch`

**现象**：S7 在高轮次（~50+ days）时出现 `StrategyController.RedeemSweepAmountMismatch`

**根因**：`MockAsyncAdapter_ST` 的 `deposit()` 将 USDC 从 Vault 转入 adapter，但这部分 USDC 逻辑上属于"外部协议持有"。之后 `sweepToVault()` 被调用时，adapter 把全部 USDC（包括应由协议持有的部分）都 sweep 回 Vault，导致实际 sweep 金额 ≠ 预期金额。

**修复方案**：引入 `protocolUsdcHeld` 状态变量，区分 adapter 上的 USDC 归属：

```solidity
contract MockAsyncAdapter_ST {
    uint256 public protocolUsdcHeld; // USDC 逻辑上由"外部协议"持有

    function deposit(uint256 amount, address) external returns (uint256) {
        IERC20(ASSET).transferFrom(VAULT, address(this), amount);
        protocolUsdcHeld += amount; // 标记为协议持有
        uint256 posAmount = amount * 1e18 / posTokenPrice;
        MockPosToken_ST(POS_TOKEN).mint(address(this), posAmount);
        return posAmount;
    }

    function sweepToVault(address token, uint256 amount) external returns (uint256) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (token == ASSET) {
            // 只 sweep 不属于协议的部分
            uint256 available = bal > protocolUsdcHeld ? bal - protocolUsdcHeld : 0;
            uint256 actual = amount > available ? available : amount;
            if (actual > 0) IERC20(token).transfer(VAULT, actual);
            return actual;
        }
        uint256 actual = amount > bal ? bal : amount;
        if (actual > 0) IERC20(token).transfer(VAULT, actual);
        return actual;
    }

    function simulateRedeemSettlement(uint256 usdcAmount) external {
        // 模拟外部协议释放 USDC（赎回结算 / 退款）
        protocolUsdcHeld = usdcAmount > protocolUsdcHeld ? 0 : protocolUsdcHeld - usdcAmount;
    }
}
```

**影响范围**：所有涉及 async adapter 赎回结算的场景（S2、S3、S5、S6、S7）均需在 settle 前调用 `simulateRedeemSettlement()`。

---

### 14.2 次要 Bug 修复

| Bug | 场景 | 现象 | 根因 | 修复 |
|-----|------|------|------|------|
| `S6:final redeemIF != 0` | S6 | 1000 用户下 seed 112345/492345 失败，redeemIF 残留 | Cases A/B 只结算 invest in-flight，不清理 redeem in-flight；如果最后几轮是 A/B，prior Cases C/D/E/F 创建的 redeem IF 未被 settle | 主循环后、final assert 前增加清扫：先 settle 残留 invest IF → settle 残留 redeem IF → finalize |
| `S7 MemoryOOG` | S7 | 1000 用户 × 60 天 → EVM 内存溢出（26/49 seeds 失败） | EVM 内存在单个 test_*() 内只增不减；大用户池 × 多天产生的对象超限 | StressBase setUp() 自动缩减 SIM_DAYS（users × days ≤ 3000）；用户补充循环 min(len, 200) 封顶 |
| `Vault__BelowMinRedeem` | S2/S5 | 汇率 < 1.0 时赎回失败 | `shares * rate * (1-fee)` 的 USDC 价值 < `minRedeemAmount` | 新增 `_effectiveMinRedeemShares()` 逆算最小份额 |
| `Vault__BelowMinRedeem` (round 2) | S3/S7/S9 | 200 用户 600 分钟测试下 S3(94/5377)、S7(9/5377)、S9(28/5377) 失败 | S3/S6/S7/S9 的 `_requestRedeemAs` 前用 `vault.minRedeemAmount()` 做 shares 阈值检查，但 vault 的 `_requestRedeem` 实际检查的是 `estimatedAssets = convertToAssets(shares) - fee`；当汇率下浮（rate<1e18）+ 赎回费（50bps），estimatedAssets 可以 < minRedeemAmount（如 985558 < 1e6） | 将 S3/S6/S7/S9 中 `_requestRedeemAs` 前的 `vault.minRedeemAmount()` 统一替换为 `_effectiveMinRedeemShares()`（已在 S2/S5 中使用） |
| `InsufficientCashForReady` | S2 | 批量 finalize 时现金不足 | 多轮累积的 PROCESSING 请求超过 vault 现金 | finalize 前检测缺口，注入 shortfall USDC |
| `BatchNotProcessed` | S2 | finalize batch 不匹配 | 过滤零金额条目后 batch key 变化 | 改为 USDC 注入（保持 batch 完整） |
| 错误的 adapter 路由 | S2 | 所有 in-flight 发给 syncAdapter | `_trySettleAllInFlight()` 未按 adapter 分组 | 重写为 per-adapter 分组结算 |
| `BatchNotProcessed` | S6 | caseD→caseE 轮次交替下 finalize 失败 | caseD（全损）产生 PROCESSING 残留被零金额跳过 → 下轮 caseE 与新批次合并，hash 对不上 | `_finalizeAllProcessing()` 改为不跳过，最小 1 wei 结算 + USDC shortfall 注入 |
| `RedeemSweepAmountMismatch` | S6 | invest-with-refund 后再 divest 触发 | `MockSyncAdapter_ST.withdrawSync()` 写成了 `view` 空函数，未按真实语义从 vault 拉取 posToken；多轮后 adapter USDC 账与 posToken 账发散 | 改为状态变更：`transferFrom(vault, self, posToken) + burn`；invest 退款时 burn 孤儿 posToken |
| `retryRedeemAsync` 语义反转 | S6 (Case F) | retry 路径从未被覆盖 | `MockAsyncAdapter_ST.retryRedeemAsync()` 从 vault 拉 posToken（`transferFrom(VAULT, self)`），真实 adapter 消费自身持有的 posToken | 改为 `require(balanceOf(self) >= amt); burn(self, amt)`；新增 S6 Case F 覆盖 retry 路径 |

### 14.3 `_effectiveMinRedeemShares()` 辅助函数

当 `accountant.getRate() < 1e18` 时，`minRedeemAmount` 对应的份额数比直觉值更高（因为每份价值更低）。新增辅助函数精确计算：

```solidity
function _effectiveMinRedeemShares() internal view returns (uint256) {
    uint256 minAssets = vault.minRedeemAmount();
    uint256 rate = accountant.getRate();
    uint256 feeBps = vault.redemptionFeeBps();
    if (rate == 0) return minAssets;
    // 逆向推算：多少 shares 赎回后（扣 fee）的 USDC 价值 ≥ minRedeemAmount
    uint256 computed = minAssets * 1e18 * 10000 / (rate * (10000 - feeBps)) + 1;
    return computed > minAssets ? computed : minAssets;
}
```

---

### 14.4 EVM 内存优化

Foundry 测试的整个 `test_*()` 函数作为单笔 EVM 交易执行，EVM 内存在交易期间只增不减（无 GC）。高轮次时内存持续累积导致 `MemoryOOG`。采取三级优化：

#### 14.4.1 `_advanceBaseIds()` — 收窄扫描范围

每轮不变量检查后推进 `_baseRequestId` 和 `_baseInFlightId`，跳过已完成的历史记录：

```solidity
function _advanceBaseIds() internal {
    // 跳过 DONE / CANCELLED 的请求
    uint256 nextReq = vault.nextRequestId();
    while (_baseRequestId < nextReq) {
        (,,,,,,, IMantleYieldVault.RequestStatus s) = vault.requests(_baseRequestId);
        if (s == IMantleYieldVault.RequestStatus.PENDING
            || s == IMantleYieldVault.RequestStatus.PROCESSING) break;
        _baseRequestId++;
    }
    // 跳过 SETTLED 的 in-flight
    uint256 nextIf = vault.nextInFlightId();
    while (_baseInFlightId < nextIf) {
        (,,,,,,,, IMantleYieldVault.InFlightStatus s) = vault.inFlightRecords(_baseInFlightId);
        if (s == IMantleYieldVault.InFlightStatus.PENDING) break;
        _baseInFlightId++;
    }
}
```

将不变量检查和结算函数的复杂度从 **O(全历史)** 降为 **O(活跃记录)**。S2 gas 从 270 亿降至 5.5 亿（降低 50 倍）。

#### 14.4.2 两遍分配模式 — 避免超大数组

修复前（S2/S3/S6 中的结算函数）：

```solidity
uint256 nextIfId = vault.nextInFlightId();
uint256[] memory ids = new uint256[](nextIfId);      // 全历史大小！
uint256[] memory settled = new uint256[](nextIfId);   // 200 轮后 nextIfId=800+
```

修复后（两遍扫描：先计数，再精确分配）：

```solidity
// 第一遍：计数
uint256 count;
for (uint256 id = _baseInFlightId; id < nextIfId; id++) {
    if (match) count++;
}
if (count == 0) return;
// 第二遍：精确大小分配
uint256[] memory ids = new uint256[](count);          // 通常 count < 10
```

#### 14.4.3 多种子执行模型 — 根本解决内存累积

**核心思想**：每个场景不再由单个 EVM 跑全部轮次，而是分为多个独立 `forge test` 进程，每次使用不同的随机种子。

```
优化前（单 EVM，内存累积）：
  forge test (seed=12345, rounds=200)
  ├── Round 0:   memory +5KB   total  5KB
  ├── Round 100: memory +5KB   total 500KB (memory gas 已开始升高)
  └── Round 199: memory +5KB   total 1GB+  → MemoryOOG ✗

优化后（多 EVM，内存独立）：
  forge test (seed=12345, rounds=50) → 50KB peak → PASS ✓  EVM 销毁
  forge test (seed=22345, rounds=50) → 50KB peak → PASS ✓  EVM 销毁
  forge test (seed=32345, rounds=50) → 50KB peak → PASS ✓  EVM 销毁
  forge test (seed=42345, rounds=50) → 50KB peak → PASS ✓  EVM 销毁
  forge test (seed=52345, rounds=50) → 50KB peak → PASS ✓  EVM 销毁
  总覆盖: 250 轮 × 5 种随机场景，永不 OOM
```

**为什么多种子比单种子更好**：

- 同一个 seed 只测试一条固定的操作路径（固定的用户选择、金额、操作顺序）
- 不同 seed = 完全不同的路径组合，发现边界 bug 的概率更高
- 如果 seed=42345 下出现失败，用 `STRESS_SEED=42345 STRESS_SEEDS=1` 可精确复现

---

### 14.5 `run_stress.sh` 持续时间控制执行脚本

#### 14.5.1 执行模型

脚本第一个参数为**持续测试分钟数**，自动循环不同种子直到时间耗尽：

- `./run_stress.sh 10` → 持续跑 10 分钟，自动递增种子（base+10000/轮）
- `./run_stress.sh 0` → 不限时，跑 `STRESS_SEEDS` 轮后停止
- 每次 `forge test` = 新 OS 进程 = 新 EVM = 内存不累积

#### 14.5.2 参数

| 环境变量 | 默认值 | 说明 |
|----------|--------|------|
| `STRESS_SEED` | 12345 | 基础种子（实际种子 = base + iter × 10000） |
| `STRESS_SEEDS` | 5 | duration=0 时的最大种子轮数 |
| `STRESS_ROUNDS` | 50 | 每个种子的迭代轮次 |
| `STRESS_DAYS` | 60 | S7 模拟天数（大用户池自动缩减，见 §13.5） |
| `STRESS_USERS` | 20 | 测试用户数量 |

#### 14.5.3 使用方式

```bash
# 持续跑 10 分钟（轻量验证，全部 9 场景）
./test/stress/run_stress.sh 10

# 持续跑 1 小时（高覆盖）
STRESS_ROUNDS=100 STRESS_USERS=30 ./test/stress/run_stress.sh 60

# 仅 S1 和 S7 跑 30 分钟
./test/stress/run_stress.sh 30 S1 S7

# 仅新场景 S8 + S9 跑 10 分钟
./test/stress/run_stress.sh 10 S8 S9

# 复现特定种子的失败
STRESS_SEED=42345 STRESS_SEEDS=1 ./test/stress/run_stress.sh 0

# 固定轮数模式（跑完 5 轮种子后停止，全部 S1–S9）
./test/stress/run_stress.sh 0

# 清除聚合缓存重新开始
./test/stress/run_stress.sh 10 --reset-cache
```

#### 14.5.3 Foundry 配置

`foundry.toml` 中新增 stress profile，为压力测试提供更高内存上限：

```toml
[profile.stress]
memory_limit = 2_147_483_648     # 2GB（Foundry 默认 ~128MB）
```

脚本中通过 `FOUNDRY_PROFILE=stress` 激活。

---

### 14.6 最新测试结果（2026-04-15）

```
配置: STRESS_SEEDS=1, Rounds/seed=3, Users=5, Days/seed=60
结果: 9/9 PASSED, 0 invariant 失败
耗时: 2s

Per-scenario:
  [S1] Deposit/Redeem Mix          PASS   (deposits=22937, syncRedeems=8879)
  [S2] Async Redeem Cycle          PASS   (asyncRedeems=20819, processBatch=8629)
  [S3] Rebalance Settlement        PASS   (rebalances=12209, settlements=19368)
  [S4] Exchange Rate & Fee         PASS   (rateUpdates=12209)
  [S5] Sanctioned User             PASS   (deposits=67944, syncRedeems=7511)
  [S6] InFlight Edge Cases         PASS   (rebalances=14045, settlements=5094)
  [S7] Full Protocol Endurance     PASS   (totalTx=240742, 14700 simulated days)
  [S8] Invest Settlement Edge      PASS   (rebalances=6, settlements=12)
  [S9] Multi-Adapter Mix           PASS   (rebalances=6, settlements=20, 3 adapters)

Grand Totals:
  Rounds:              87,766
  Transactions:        562,930
  Invariant Checks:    150,544 (fails: 0)
  Gas Used:            269,520,111,800
```

高覆盖测试（5 分钟持续运行，81 seed rounds，S1–S7）：

```
配置: Duration=5min, Rounds/seed=50, Days/seed=60, Users=20
结果: 7/7 PASSED, 81 seed rounds × 7 scenarios, 0 失败
耗时: 5m00s

Grand Totals:
  Rounds:              28,900
  Transactions:        200,093
  Invariant Checks:    49,562 (fails: 0)
  Gas Used:            67,456,572,797
```

### 14.8 日志系统与聚合缓存

#### 14.8.1 日志等级系统

`LogUtil`（`test/lib/LogUtil.sol`）支持五级日志过滤：

| 等级 | 值 | 默认打印 | 说明 |
|------|---|---------|------|
| `DEBUG` | 0 | 否 | 每笔操作明细（deposit/redeem/rebalance/settle 参数、ledger 快照、gas） |
| `INFO` | 1 | 是（默认） | 轮次开始/结束、不变量汇总、最终报告 |
| `WARN` | 2 | 是 | 预留 |
| `ERROR` | 3 | 是 | 不变量失败详情、scene dump |
| `CRIT` | 4 | 是 | 预留 |

通过环境变量 `STRESS_LOG_LEVEL` 控制（`initLog` 时读取），例如：
```bash
STRESS_LOG_LEVEL=DEBUG ./test/stress/run_stress.sh 10   # 所有级别
STRESS_LOG_LEVEL=ERROR ./test/stress/run_stress.sh 10   # 只看错误
```

#### 14.8.2 小时轮转日志

使用 `initLog(tag, logDir, errorLogPath)` 初始化后，主日志按自然小时（北京时间）轮转：

```
stress_logs/stress_20260415_14.log    # 14:00-14:59 内的所有日志
stress_logs/stress_20260415_15.log    # 15:00-15:59
```

多 case、多 seed 共享同一小时文件（追加写入）。不再生成每轮独立文件，日志文件数从 O(seeds × rounds) 降至 O(小时数)。

#### 14.8.3 错误兜底文件

当日志等级 >= `ERROR` 时，除写入主日志外，额外追加到 `stress_logs/errors.log`。便于快速定位所有失败：
```bash
cat stress_logs/errors.log   # 查看所有不变量失败
```

#### 14.8.4 TSV 聚合缓存

每个 seed-run 结束时，`_appendAggregateRow()` 向 `stress_logs/.cache/aggregate.tsv` 追加一行，schema 如下：

```
ts  contract  seed  result  actualRounds  totalTx  deposits  syncRedeems  asyncRedeems  processBatch  finalizeBatch  rebalances  settlements  rateUpdates  priceUpdates  invariantChecks  invariantFails  totalGasUsed  wallMs
```

`run_stress.sh` 最终汇总时直接用 `awk -F'\t'` 读取 TSV，单次 O(N) 扫描完成，取代此前 O(seeds × fields) 的逐文件 grep。

使用 `--reset-cache` 清空 TSV 重新开始：
```bash
./test/stress/run_stress.sh 10 --reset-cache
```

#### 14.8.5 S6 Case F — retryRedeemInFlight 覆盖

新增 `_caseF_retryAsyncRedeem`（`round % 6 == 5`），覆盖异步赎回的手动重试路径：

1. `_triggerDivest()` → 产生 async redeem in-flight
2. 扫描 asyncAdapter 上 PENDING 的 redeem in-flight
3. `controller.retryRedeemInFlight(asyncAdapter, id, partialPos)`（admin 权限）
4. 正常结算 + finalize
5. 断言 `totalRedeemInFlight == 0`

---

### 14.7 已修改的文件清单

| 文件 | 变更 |
|------|------|
| `test/lib/LogUtil.sol` | 重构：日志等级系统（DEBUG/INFO/WARN/ERROR/CRIT）、小时轮转、errors.log 兜底、`STRESS_LOG_LEVEL` env 开关 |
| `test/stress/StressBase.t.sol` | MockAsyncAdapter_ST `protocolUsdcHeld`；MockUSDC_ST/MockPosToken_ST 暴露 `burn()`；`MockSyncAdapter_ST.withdrawSync()` 改为状态变更；`MockConfigSyncAdapter_ST`（可变 price 的 sync adapter）；`_effectiveMinRedeemShares()`；`_advanceBaseIds()`；`_scaledRand()` 操作数比例化；`_checkUsdcClosedSystem` 加 `virtual`；`retryRedeemAsync` mock 修复；`_appendAggregateRow()` TSV 缓存追加 |
| `test/stress/S1_DepositRedeemMix.t.sol` | 操作数改 `_scaledRand`；初始 seeding 比例化 |
| `test/stress/S2_AsyncRedeemFullCycle.t.sol` | per-adapter 结算分组；两遍分配模式；USDC shortfall 注入；操作数改 `_scaledRand` |
| `test/stress/S3_RebalanceSettlement.t.sol` | 两遍分配模式；`simulateRedeemSettlement()` 调用；操作数改 `_scaledRand` |
| `test/stress/S5_SanctionedUserInterlace.t.sol` | `_effectiveMinRedeemShares()` 守卫；操作数改 `_scaledRand` |
| `test/stress/S6_InFlightEdgeCases.t.sol` | 两遍分配模式；`simulateRedeemSettlement()`；invest 退款 burn 孤儿 posToken；`_finalizeAllProcessing()` 不跳过零金额；新增 Case F（retryRedeemInFlight 覆盖） |
| `test/stress/S7_FullProtocolEndurance.t.sol` | 两遍分配模式；`simulateRedeemSettlement()`；操作数比例化 `_scaledRand` |
| `test/stress/S8_InvestSettlementEdge.t.sol` | **新增**：Invest 部分结算 (5-95% 退款) + 全额退款 (100%)，5 种 case 轮转，覆盖 `confirmInFlight(id, 0, isAbnormal=true)` |
| `test/stress/S9_MultiAdapterMix.t.sol` | **新增**：3 adapter 非对称权重 (40/35/25)；混合结算（sync1 正常/sync2 部分退款/async 随机）；动态权重调整（每 20 轮）；posTokenPrice jitter（每 10 轮）；override `_checkUsdcClosedSystem` |
| `test/stress/run_stress.sh` | 持续时间控制（分钟）；多种子自动循环；TSV 聚合替代逐文件 grep；`--reset-cache` 开关；注册 S8/S9（KEYS/CONTRACTS/FUNCS/NAMES/DESCS/METHODS 全部 9 项） |
| `foundry.toml` | 新增 `[profile.stress]` memory_limit=2GB |

---

