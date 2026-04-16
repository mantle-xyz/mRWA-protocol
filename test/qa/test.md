## 部署与初始化场景

| 是否自动化 | 测试合约 | 测试结果 | 优先级 | 测试需求描述 | 前置条件 | 测试步骤 | 期望结果 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
|  | VaultFactory、Vault |  | P0 | VaultFactory 使用合法参数部署成功 | 已部署 Vault 实现合约 | 1. 调用 `new VaultFactory(impl, beaconOwner)`<br>2. 读取 `implementation()` | 1. Factory 部署成功<br>2. `implementation()` 返回传入的 `impl` |  |
|  | VaultFactory、Vault |  | P0 | VaultFactory 构造参数为零地址时拒绝部署 | 无 | 1. 使用 `impl = address(0)` 部署<br>2. 使用 `beaconOwner = address(0)` 部署 | 两种情况均回滚，抛出 `Factory__ZeroAddress` |  |
|  | GatewayFactory、Gateway |  | P0 | GatewayFactory 使用合法参数部署成功 | 已部署 Gateway 实现合约 | 1. 调用 `new GatewayFactory(impl, beaconOwner)`<br>2. 读取 `implementation()` | Factory 部署成功，且实现地址正确 |  |
|  | VaultFactory、Vault |  | P0 | `deployAndInitVault` 原子部署并初始化 Vault | 已有合法 `asset / admin / controller / accountant / treasury / gateway` | 1. 组装 `InitParams`<br>2. 调用 `deployAndInitVault(params)`<br>3. 读取关键状态 | 1. Vault 成功部署并初始化<br>2. 关键参数与入参一致<br>3. `nextRequestId = 1`<br>4. `nextInFlightId = 1` |  |
|  | GatewayFactory、Gateway |  | P0 | `deployAndInitGateway` 原子部署并初始化 Gateway | 已有合法 `vault / oracle / sanctionSafe / admin` | 1. 组装 Gateway 初始化参数<br>2. 调用 `deployAndInitGateway(params)`<br>3. 读取关键状态 | Gateway 初始化成功，配置项正确 |  |
|  | VaultFactory、Vault |  | P0 | Vault 初始化拒绝关键零地址 | 已部署未初始化 Vault 代理 | 1. 分别传入 `asset / admin / controller / accountant / treasury / gateway = address(0)` 调用初始化 | 每种情况均回滚，抛出 `Vault__ZeroAddress` |  |
|  | VaultFactory、Vault |  | P0 | Vault 初始化拒绝无效赎回费配置 | 已部署未初始化 Vault 代理 | 1. 传入 `maxRedemptionFeeBps > 10000` 初始化<br>2. 传入 `redemptionFeeBps > maxRedemptionFeeBps` 初始�� | 两种情况均回滚，抛出 `Vault__FeeTooHigh` |  |
|  | GatewayFactory、Gateway |  | P0 | Gateway 初始化拒绝关键零地址 | 已部署未初始化 Gateway 代理 | 1. 分别传入 `vault / oracle / sanctionSafe / admin = address(0)` 调用初始化 | 均回滚，抛出 `Vault__ZeroAddress` |  |
|  | Vault / Gateway / Controller / Accountant |  | P1 | 合约禁止重复初始化 | Vault / Gateway / Controller / Accountant 任一已初始化 | 1. 再次调用 `initialize()` | 回滚，命中 `initializer` 保护 |  |
|  | Accountant |  | P0 | Accountant 初始化拒绝关键零地址与非法初始汇率/费率 | 已部署未初始化 Accountant 代理 | 1. 分别传入 `vault = address(0)` / `admin = address(0)` 调用初始化<br>2. 传入 `initialRate = 0` 调用初始化<br>3. 传入超上限 `managementFeeRate` 调用初始化 | 1. 零地址均回滚 `ZeroAddress()`<br>2. `initialRate = 0` 回滚 `InvalidRate()`<br>3. 超上限费率回滚 `InvalidFeeRate()` |  |
|  | Accountant |  | P0 | `deployAndInitAccountant` 原子部署并初始化成功 | 已有合法 `vault / initialRate / managementFeeRate / admin` | 1. 组装 Accountant 初始化参数<br>2. 调用 `deployAndInitAccountant(params)`<br>3. 读取关键状态 | 1. Accountant 成功部署并初始化<br>2. `lastExchangeRate == initialRate`<br>3. `managementFeeRate` 正确<br>4. admin 获得默认角色 |  |
|  | Accountant |  | P1 | Accountant 初始化后默认参数正确 | Accountant 已初始化 | 1. 读取 `maxAllowedDeviation`<br>2. 读取 `minUpdateInterval`<br>3. 读取 `maxComputeAge`<br>4. 读取三个 timestamp | 1. `maxAllowedDeviation = 100`<br>2. `minUpdateInterval = 20 hours`<br>3. `maxComputeAge = 5 minutes`<br>4. `lastComputeTimestamp / lastUpdateTimestamp / lastFeeSettleTimestamp` 均为初始化时刻 |  |
|  | Accountant |  | P1 | Accountant 初始化后角色授予正确 | Accountant 已初始化 | 1. 检查 admin 是否拥有 `DEFAULT_ADMIN_ROLE`<br>2. 检查 admin 是否拥有 `PAUSER_ROLE`<br>3. 检查 admin 是否拥有 `EXECUTOR_ROLE` | 三个角色均授予 admin |  |
|  | VaultFactory、Vault |  | P1 | `deployAndInitVault` 后关键默认状态正确 | 已有合法初始化参数 | 1. 调用 `deployAndInitVault(params)`<br>2. 读取关键配置和计数器 | 1. `asset / gateway / controller / accountant / treasury` 正确<br>2. `redemptionFeeBps / maxRedemptionFeeBps` 正确<br>3. `nextRequestId = 1`<br>4. `nextInFlightId = 1` |  |
|  | GatewayFactory、Gateway |  | P1 | `deployAndInitGateway` 后关键默认状态正确 | 已有合法初始化参数 | 1. 调用 `deployAndInitGateway(params)`<br>2. 读取关键配置和开关 | 1. `vault / oracle / sanctionSafe` 正确<br>2. `syncRedeemDisabled` 初值正确<br>3. `whitelistEnabled` 初值正确 |  |
|  | Vault / Gateway |  | P1 | 未初始化代理若被抢初始化，控制权落入抢初始化者 | 通过 `deployVault()` / `deployGateway()` 创建未初始化代理 | 1. 非预期账户先调用 `initialize()`<br>2. 读取 admin / 核心配置 | 1. 若实现允许，则代理被成功抢初始化<br>2. 控制权和关键配置归属于抢初始化者<br>3. 该风险应作为部署约束明确记录 |  |
|  | Vault / Gateway |  | P1 | Factory 部署的代理初始化后可立即正常读取关键 view | 已通过 `deployAndInit*` 成功部署 | 1. 调用关键 view，如 Vault 的核心配置、Gateway 的配置、Accountant 的 rate | 1. 关键 view 均可正常读取<br>2. 返回值与初始化参数一致 |  |

## 用户入口与路由场景

| 是否自动化 | 测试合约 | 测试执行结果 | 优先级 | 测试需求描述 | 前置条件 | 测试步骤 | 期望结果 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
|  | Vault |  | P0 | 用户直调 `vault.deposit` 被拒绝 | Vault 已初始化 | 1. 用户直接调用 `vault.deposit(assets, receiver)` | 交易回滚，抛出 `Vault__NotAuthorized` |  |
|  | Vault |  | P0 | 用户直调 `vault.mint` 被拒绝 | Vault 已初始化 | 1. 用户直接调用 `vault.mint(shares, receiver)` | 交易回滚，抛出 `Vault__NotAuthorized` |  |
|  | Vault |  | P0 | 用户直调 `vault.redeem / vault.withdraw` 被拒绝 | Vault 已初始化 | 1. 直接调用 `vault.redeem(...)`<br>2. 直接调用 `vault.withdraw(...)` | 两次调用均回滚，抛出 `Vault__NotAuthorized` |  |
|  | Vault |  | P0 | 用户直调 `vault.requestRedeem` 被拒绝 | Vault 已初始化 | 1. 直接调用 `vault.requestRedeem(shares)` | 回滚，抛出 `Vault__NotAuthorized` |  |
|  | Vault |  | P0 | 非 Gateway 账户直调 `depositFor` 被拒绝 | Vault 已初始化 | 1. 非 Gateway 地址调用 `vault.depositFor(...)` | 回滚，抛出 `Vault__OnlyGateway` |  |
|  | Vault |  | P0 | 非 Gateway 账户直调 `redeemFor` 被拒绝 | Vault 已初始化 | 1. 非 Gateway 地址调用 `vault.redeemFor(...)` | 回滚，抛出 `Vault__OnlyGateway` |  |
|  | Vault |  | P0 | 非 Gateway 账户直调 `requestRedeemFor` 被拒绝 | Vault 已初始化 | 1. 非 Gateway 地址调用 `vault.requestRedeemFor(...)` | 回滚，抛出 `Vault__OnlyGateway` |  |

## Gateway 同步赎回场景

| 是否自动化 | 测试合约 | 测试结果 | 优先级 | 测试需求描述 | 前置条件 | 测试步骤 | 期望结果 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
|  | Gateway |  | P0 | 用户通过 Gateway 正常同步赎回 | 1. `rate = 1e18`，`redemptionFeeBps = 100`（1%）<br>2. `userA` 持有 `1000e18` shares<br>3. `freeCash >= 990e6`<br>4. `syncRedeemDisabled = false` | 1. `userA` 调用 `gateway.redeem(1000e18)` | 1. `grossAssets = 1000e6`，`fee = 1000e6 * 1% = 10e6`<br>2. `userA` 实际收到 `990e6` USDC<br>3. `balanceOf(userA)` 减少 `1000e18` shares |  |
|  | Gateway |  | P0 | `syncRedeemDisabled = true` 时禁止同步赎回 | 已开启 `syncRedeemDisabled` | 1. `userA` 调用 `gateway.redeem(1000e18)` | 回滚，抛出 `Vault__SyncRedeemDisabled` |  |
|  | Gateway |  | P0 | `freeCash` 不足时同步赎回失败 | 1. `userA` 持有 `1000e18` shares<br>2. `getFreeCash()` 仅有 `100e6`<br>3. `previewRedeem(1000e18)` 远超 `100e6` | 1. `userA` 调用 `gateway.redeem(1000e18)` | 回滚：赎回 shares 超过 `maxRedeem(userA)` 时抛出 `ERC4626ExceededMaxRedeem`；若 shares 在 `maxRedeem` 范围内但底层 `_withdraw` 发现 `assets > freeCash`，则抛出 `Vault__InsufficientFreeCash` |  |
|  | gateway / sanction |  | P0 | 被制裁用户同步赎回会将 shares 路由给到 safe 地址 | `userA` 在黑名单中 | 1. `userA` 调用 `gateway.redeem(1000e18)` | 会将 shares 路由给到 safe 地址，并触发对应事件 |  |
|  | gateway / sanction |  | P0 | 白名单开启时，未白名单用户禁止同步赎回 | `whitelistEnabled = true`，`userA` 未被白名单 | 1. `userA` 调用 `gateway.redeem(1000e18)` | 回滚，抛出 `Gateway__NotWhitelisted(userA)` |  |
|  | gateway / sanction |  | P1 | 白名单开启时，已白名单用户正常同步赎回 | `whitelistEnabled = true`，`userA` 已在白名单中，且 `freeCash` 充足 | 1. `userA` 调用 `gateway.redeem(1000e18)` | 赎回成功 |  |
|  | Accountant / Gateway |  | P1 | Accountant 暂停导致同步赎回入口暂停 | Accountant 暂停 | 1. `userA` 调用 `gateway.redeem(1000e18)` | 回滚，抛出 `EnforcedPause()` |  |
|  | Gateway |  | P1 | `fee = 0` 时同步赎回按无手续费结算 | 1. admin 设置 `redemptionFeeBps = 0`<br>2. `rate = 1e18`<br>3. `userA` 持有 `1000e18` shares | 1. `userA` 调用 `gateway.redeem(1000e18)` | 1. `previewRedeem(1000e18)` 返回 `1000e6`（无 fee 扣除）<br>2. `userA` 实际收到 `1000e6` USDC |  |

## Gateway 异步赎回请求场景

| 是否自动化 | 测试合约 | 测试结果 | 优先级 | 测试需求描述 | 前置条件 | 测试步骤 | 期望结果 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
|  | gateway |  | P0 | 用户自己发起异步赎回请求成功 | userA 持有足够 shares，预计资产不低于 `minRedeemAmount` | 1. userA 调用 `gateway.requestRedeem(shares)` | 1. 返回非 0 `requestId`<br>2. Vault 记录新增请求，`owner=userA`，状态为 `PENDING` |  |
|  | gateway / Vault |  | P0 | 最小异步赎回门槛可阻止垃圾小额请求进入队列，避免批处理通道被滥用 | 1. Vault 已设置 `minRedeemAmount`<br>2. 用户可发起 `requestRedeem`<br>3. 用户持有可拆分成多笔极小额的 shares | 1. 构造低于 `minRedeemAmount` 的 shares 数量<br>2. 连续多次调用 `gateway.requestRedeem(tinyShares)`<br>3. 再构造一笔高于门槛的合法请求并调用 `gateway.requestRedeem(validShares)` | 1. 所有低于门槛的请求均被拒绝，不进入 `PENDING` 队列<br>2. 合法金额请求可正常创建并返回非 0 `requestId` |  |
|  | gateway |  | P0 | 0 shares 发起异步赎回请求被拒绝 | 无 | 1. userA 调用 `gateway.requestRedeem(0)` | 回滚，抛出 `Vault__ZeroAmount` |  |
|  | gateway |  | P0 | 预计资产小于最小赎回金额时拒绝创建请求 | `minRedeemAmount` 已设置 | 1. 构造小额 shares<br>2. userA 调用 `gateway.requestRedeem(tinyShares)` | 回滚，抛出 `Vault__BelowMinRedeem` |  |
|  | gateway |  | P0 | 被制裁用户异步赎回时走 shares 路由特殊路径 | userA 已被制裁 | 1. userA 调用 `gateway.requestRedeem(shares)` | 1. 返回 `requestId=0`<br>2. 不创建 request<br>3. shares 通过 `routeSanctionedShares` 转移到 `sanctionSafe` |  |
|  | gateway / controller / vault |  | P0 | `estimatedAssets` 仅为请求创建时的参考值，不构成最终兑付金额的硬承诺 | 1. 用户已成功创建异步赎回请求<br>2. 请求中已记录 `estimatedAssets`<br>3. 后续市场价格 / 执行成本 / 汇率发生变化 | 1. 记录请求创建时的 `estimatedAssets`<br>2. 将请求推进到 `PROCESSING`<br>3. 用与 `estimatedAssets` 不同的 `settledAssets` 完成结算 | 1. 最终 `settledAssets` 可与 `estimatedAssets` 不同<br>2. 若不同，应通过 `RequestSettlementAdjusted` 透明记录<br>3. 系统不会因两者不一致而账本死锁 |  |
|  | Accountant / gateway |  | P1 | Accountant 暂停导致异步赎回入口暂停 | Accountant 已暂停 | 1. userA 调用 `gateway.requestRedeem(shares)` | 回滚，抛出 `EnforcedPause()` |  |
|  | gateway / sanction |  | P0 | `requestRedeem` 白名单开启时未白名单用户被拒绝 | `whitelistEnabled=true`，userA 未被白名单且未被制裁 | 1. userA 调用 `gateway.requestRedeem(shares)` | 回滚，抛出 `Gateway__NotWhitelisted(userA)`（`requestRedeem` 现在也调用 `_requireWhitelisted`） |  |
|  | gateway / sanction |  | P0 | `requestRedeem` 白名单开启时白名单用户可操作 | `whitelistEnabled=true`，userA 已白名单且未被制裁 | 1. userA 调用 `gateway.requestRedeem(shares)` | 调用成功，返回非 0 `requestId` |  |
|  | gateway / sanction |  | P1 | `requestRedeem` 白名单关闭时不检查白名单 | `whitelistEnabled=false`，userA 未白名单且未被制裁 | 1. userA 调用 `gateway.requestRedeem(shares)` | 调用成功（`whitelistEnabled=false` 时 `_requireWhitelisted` 直接通过） |  |

## 异步赎回状态机场景

| 是否自动化 | 测试合约 | 测试结果 | 优先级 | 测试需求描述 | 前置条件 | 测试步骤 | 期望结果 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
|  | gateway / controller / vault / operator |  | P0 | 异步赎回请求创建后 burn shares 并增加锁定份额 | 已成功创建异步赎回请求 | 1. 检查 owner balance<br>2. 检查 `totalLockedShares`<br>3. 检查 `_pendingShares` | 1. owner shares 减少<br>2. `totalLockedShares` 增加<br>3. `_pendingShares[owner]` 增加 |  |
|  | gateway / controller / vault / operator |  | P0 | 单笔请求由 `PENDING` 推进到 `PROCESSING` | 存在 `PENDING` 请求 | 1. Controller 调用 `updateRequestBatch([id], PROCESSING)` | 该请求状态更新为 `PROCESSING` |  |
|  | gateway / controller / vault / operator |  | P0 | 批量请求统一推进到 `PROCESSING` | 存在多笔 `PENDING` 请求 | 1. 调用 `updateRequestBatch(ids, PROCESSING)` | 所有请求状态均更新为 `PROCESSING` |  |
|  | gateway / controller / vault / operator |  | P0 | 不允许直接把请求状态设为 `DONE` | 存在 `PENDING` 或 `PROCESSING` 请求 | 1. 调用 `updateRequestBatch(ids, DONE)` | 回滚，抛出 `Vault__StatusTransitionForbidden` |  |
|  | gateway / controller / vault / operator |  | P0 | 不允许状态倒退 | 某请求已 `PROCESSING` | 1. 调用 `updateRequestBatch([id], PENDING)` | 回滚，抛出 `Vault__InvalidState` |  |
|  | gateway / controller / vault / operator |  | P0 | `markRequestsDone` 只能处理 `PROCESSING` 状态请求 | 请求为 `PENDING` | 1. 调用 `markRequestsDone([id], [settledAssets])` | 回滚，抛出 `Vault__InvalidState` |  |
|  | gateway / controller / vault / operator |  | P0 | `markRequestsDone` 正常完成单笔请求结算 | 请求为 `PROCESSING`，Vault 物理余额足够 | 1. 调用 `markRequestsDone([id], [amount])` | 1. 请求变为 `DONE`<br>2. `settledAssets` 记录正确<br>3. 用户收到资产 |  |
|  | gateway / controller / vault / operator |  | P0 | `markRequestsDone` 正常完成批量请求结算 | 多笔请求为 `PROCESSING`，物理余额足够 | 1. 调用 `markRequestsDone(ids, settledAssets)` | 1. 全部请求置为 `DONE`<br>2. 批量打款成功 |  |
|  | gateway / controller / vault / operator |  | P0 | `markRequestsDone` 时 `settledAssets=0` 被拒绝 | 请求为 `PROCESSING` | 1. 调用 `markRequestsDone([id], [0])` | 回滚，抛出 `Vault__ZeroAmount` |  |
|  | gateway / controller / vault / operator |  | P0 | `markRequestsDone` 数组长度不一致时拒绝 | 请求存在 | 1. 调用 `markRequestsDone([1,2], [amount])` | 回滚，抛出 `Vault__LengthMismatch` |  |
|  | gateway / controller / vault / operator |  | P0 | 物理余额不足时整批结算失败并原子回滚 | 批次总结算金额大于 Vault 当前物理余额 | 1. 调用 `markRequestsDone(ids, settledAssets)` | 1. 回滚，抛出 `Vault__InsufficientPhysicalCash`<br>2. 所有请求状态保持不变 |  |
|  | gateway / controller / vault / operator |  | P1 | `settledAssets` 与 `estimatedAssets` 不一致时记录调整事件 | 1. `rate=1e18`，`redemptionFeeBps=100`<br>2. 已创建赎回请求 `id=1`，`estimatedAssets=990e6`<br>3. 请求已推进到 `PROCESSING` | 1. Controller 调用 `markRequestsDone([1], [900e6])`（`900e6 != 990e6`） | 1. 请求完成，`settledAssets=900e6`<br>2. 触发 `RequestSettlementAdjusted(1, 990e6, 900e6)` |  |
|  | gateway / controller / vault / operator |  | P1 | owner 在结算前被制裁时，资产转入 `sanctionSafe` | 请求创建时 owner 未制裁，结算前被制裁 | 1. 调用 `markRequestsDone([id], [amount])` | 1. 资产转入 `sanctionSafe`<br>2. 触发 `SactionSafeIn` |  |
|  | gateway / controller / vault / operator |  | P1 | 全部结算完成后 `pendingRedeemRequest(owner)` 归零 | owner 所有请求都已完成 | 1. 查询 `pendingRedeemRequest(owner)` | 返回 0 |  |
|  | gateway / controller / vault / operator |  | P1 | 部分请求结算后 `_pendingShares` 正确递减 | owner 有多笔未完成请求 | 1. 仅结算其中一部分 | `_pendingShares` 仅减少已结算部分对应 shares |  |

## FreeCash 与 totalAssets 场景

| 是否自动化 | 测试合约 | 测试结果 | 优先级 | 测试需求描述 | 前置条件 | 测试步骤 | 期望结果 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
|  | Vault |  | P0 | 无 locked shares 时 `freeCash = vault` 底层资产余额 | Vault 有 USDC，`totalLockedShares=0` | 1. 查询 `getFreeCash()` | 返回当前底层资产物理余额 |  |
|  | Vault |  | P0 | 存在 locked shares 时 `freeCash = physicalBalance - previewRedeem(totalLockedShares)` | 1. `rate=1e18`，`redemptionFeeBps=100`（1%）<br>2. Vault 物理余额 `2000e6`<br>3. 已创建异步赎回请求使 `totalLockedShares = 1000e18` | 1. 查询 `getFreeCash()` | `previewRedeem(1000e18)=990e6` → `freeCash = 2000e6 - 990e6 = 1010e6` |  |
|  | Vault |  | P0 | 当 `totalLockedShares` 大于等于物理余额时 `freeCash=0` | `totalLockedShares` 覆盖全部物理余额 | 1. 查询 `getFreeCash()` | 返回 0，不出现负值 |  |
|  | Vault |  | P0 | 存在异步赎回负债时，Vault 必须优先为其预留资金，Controller 不得将该部分资金重新投资 | 1. 已存在异步赎回请求，使 `totalLockedShares > 0`<br>2. Vault 有一定 physical USDC 余额<br>3. Controller 具备再投资能力 | 1. 创建异步赎回请求，提高 `totalLockedShares`<br>2. 查询 `previewRedeem(totalLockedShares)` 与 `getFreeCash()`<br>3. 调用 `rebalance()` 触发投资路径<br>4. 检查实际被投资的资产规模 | 1. `getFreeCash()` 已扣除 `totalLockedShares` 对应资产<br>2. Controller 只能动用扣减后的 `freeCash` 进行投资<br>3. 不得将已预留给异步赎回的资金投入 adapter<br>4. 该行为体现统一资金池下对异步负债的优先保护 |  |
|  | Vault / gateway |  | P0 | 存在异步赎回 `totalLockedShares` 时，同步赎回应受 `freeCash` 限制，不能动用已预留给异步赎回的资金 | 1. 已存在异步赎回请求，`totalLockedShares > 0`<br>2. Vault 物理余额存在，但扣除 `totalLockedShares` 后 `freeCash` 不足<br>3. 用户持有可用于同步赎回的 shares | 1. 查询 `physicalBalance`、`previewRedeem(totalLockedShares)`、`freeCash`<br>2. 用户调用同步赎回 `gateway.redeem(shares)`<br>3. 检查结果 | 1. 即便 Vault 账面物理余额存在，同步赎回仍可能失败<br>2. 失败根因是 `freeCash` 不足，而不是简单“没钱”<br>3. 说明系统优先保护已排队异步赎回资金 |  |
|  | Vault |  | P1 | 修改 redemption fee 会联动影响 `freeCash` | 已存在 locked shares | 1. 记录旧 `freeCash`<br>2. 调整赎回费<br>3. 再查 `freeCash` | `freeCash` 按新的 `previewRedeem(totalLockedShares)` 结果变化 |  |
|  | Vault |  | P0 | `totalAssets` 包含底层余额、策略价值、invest in-flight、redeem in-flight，并扣除 `totalLockedShares` | 1. `rate=1e18`，`redemptionFeeBps=100`<br>2. Vault USDC 余额 `1000e6`<br>3. 1 个 adapter `totalValue()=500e6`<br>4. `totalInvestInFlight=200e6`<br>5. `totalRedeemInFlight=100e6`<br>6. `totalLockedShares=300e18` | 1. 查询 `totalAssets()` | 1. `total = 1000e6 + 500e6 + 200e6 + 100e6 = 1800e6`<br>2. `floatingLocked = previewRedeem(300e18) = 297e6`<br>3. `totalAssets = 1800e6 - 297e6 = 1503e6` |  |
|  | Vault |  | P0 | `totalAssets` 在锁定 shares 大于全部统计资产时返回 0 | `totalLockedShares` 极大 | 1. 查询 `totalAssets()` | 返回 0 |  |
|  | Vault |  | P1 | adapter `totalValue()` 异常会导致 `Vault.totalAssets` 整体失败 | 某 adapter 的 `totalValue()` revert | 1. 查询 `vault.totalAssets()` | 整体回滚 |  |

## Vault 份额转账与合规场景

| 是否自动化 | 测试合约 | 测试结果 | 优先级 | 测试需求描述 | 前置条件 | 测试步骤 | 期望结果 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
|  | Vault |  | P0 | 普通 share transfer 时通过 Gateway 执行 sanctions 校验 | Vault 已配置有效 gateway；<br>userA、userB 均未被制裁；<br>userA 持有足够 shares | 1. userA 调用 `vault.transfer(userB, 100e18)` | 1. 转账成功<br>2. Vault `_update` 进入普通转账分支并调用 `gateway.enforceShareTransfer(userA, userB)`<br>3. userA shares 减少，userB shares 增加 |  |
|  | Vault |  | P0 | from 被制裁时普通 share transfer 被拒绝 | Vault 已配置有效 gateway；<br>userA 已被制裁；<br>userB 未被制裁；<br>userA 持有足够 shares | 1. userA 调用 `vault.transfer(userB, 100e18)` | 1. 交易回滚，抛出 `Vault__Sanctioned(userA)`<br>2. 双方 shares 不变 |  |
|  | Vault |  | P0 | to 被制裁时普通 share transfer 被拒绝 | Vault 已配置有效 gateway；<br>userA 未被制裁；<br>userB 已被制裁；<br>userA 持有足够 shares | 1. userA 调用 `vault.transfer(userB, 100e18)` | 1. 交易回滚，抛出 `Vault__Sanctioned(userB)`<br>2. 双方 shares 不变 |  |
|  | Vault |  | P0 | Vault pause 时普通 share transfer 被拒绝 | userA 持有足够 shares；<br>Vault 已由有权限角色调用 `pause()` 进入暂停态 | 1. userA 调用 `vault.transfer(userB, 100e18)` | 1. 交易回滚，命中 Vault pause 检查（`EnforcedPause`）<br>2. 双方 shares 不变 |  |
|  | Vault |  | P1 | mint / burn 不进入普通 share transfer sanctions 分支 | 已满足对应存款或赎回业务前提；<br>gateway、accountant 等配置正常 | 1. 通过 `gateway.deposit(...)` 触发 mint<br>2. 通过 `gateway.redeem(...)` 或 `gateway.requestRedeem(...)` 触发 burn | 1. mint（`from=0`）和 burn（`to=0`）不会进入 Vault `_update` 中 `from!=0 && to!=0` 的普通转账 sanctions 检查分支<br>2. 是否成功仍取决于各自业务前置条件 |  |
|  | Vault / Gateway |  | P0 | 被制裁 owner 通过 Gateway `requestRedeem` 时触发 `sanctionSafe` 特例路由 | owner 已被制裁；<br>Gateway 已配置非零 `sanctionSafe`；<br>owner 持有足够 shares | 1. owner 调用 `gateway.requestRedeem(shares)` | 1. Gateway 不走普通 `requestRedeemFor`，而是调用 `vault.routeSanctionedShares(owner, owner, shares)`<br>2. shares 从 owner 转入 `sanctionSafe`<br>3. 事件 `SactionSafeIn` emitted<br>4. Gateway 返回 0<br>5. 不创建 redemption request |  |
|  | Gateway / Vault / sanction |  | P1 | `sanctionSafe` 特例路由不走普通 transfer sanctions 拦截 | owner 已被制裁；<br>Gateway 已配置当前 `sanctionSafe`；<br>owner 持有足够 shares | 1. owner 调用 `gateway.requestRedeem(shares)`，触发 `routeSanctionedShares` | 1. Vault `_update` 命中特例分支：`msg.sender == gateway && to == sanctionSafe`<br>2. 不会再调用 `gateway.enforceShareTransfer(from, to)`<br>3. 路由成功完成 |  |
|  | vault |  | P1 | 非 Gateway 调用 `routeSanctionedShares` 被拒绝 | owner 持有足够 shares | 1. 非 gateway 地址直接调用 `vault.routeSanctionedShares(...)` | 交易回滚，抛出 `Vault__OnlyGateway()` |  |

## Controller 策略配置场景

| 是否自动化 | 测试合约 | 测试结果 | 优先级 | 测试需求描述 | 前置条件 | 测试步骤 | 期望结果 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
|  | StrategyController |  | P0 | StrategyController 初始化成功 | Vault 已部署，且 `vault.asset()` 返回有效资产地址；<br>admin、operatorExecutor、pauser 均为非零地址，且 `operatorExecutor` 为合约地址 | 1. 调用 `initialize(vault, admin, operatorExecutor, pauser, bufferTargetBps, rebalanceThresholdBps, rebalanceCooldown)` | 1. 初始化成功<br>2. `vault`、`asset`、`bufferTargetBps`、`rebalanceThresholdBps`、`rebalanceCooldown` 状态写入正确<br>3. `DEFAULT_ADMIN_ROLE -> admin`，`OPERATOR_EXECUTOR_ROLE -> operatorExecutor`，`PAUSER_ROLE -> pauser` |  |
|  | StrategyController |  | P0 | 初始化拒绝零地址及非法参数 | 未初始化 Controller | 1. 分别传入 `vault/admin/operatorExecutor/pauser = address(0)` 调用 `initialize(...)`<br>2. `operatorExecutor` 传 EOA（无代码）调用 `initialize(...)`<br>3. `bufferTargetBps > 10000` 或 `rebalanceThresholdBps > 10000` 调用 `initialize(...)` | 1. 零地址场景回滚，抛出 `InvalidAddress()`<br>2. EOA executor 场景回滚，抛出 `InvalidExecutorContract(operatorExecutor)`<br>3. 非法 BPS 场景回滚，抛出 `InvalidBps()` |  |
|  | StrategyController |  | P0 | 只有 admin 可以注册策略 | Controller 已初始化 | 1. 非 admin 调用 `registerStrategy(adapter, targetWeightBps, priority, isAsync)`<br>2. admin 调用 `registerStrategy(adapter, targetWeightBps, priority, isAsync)` | 1. 非法调用回滚（`AccessControlUnauthorizedAccount`）<br>2. 合法调用成功，策略默认 `isActive=false` |  |
|  | StrategyController |  | P0 | 注册策略时自动确保 Vault 已注册 adapter | Controller 已初始化；Vault 中当前 `isAdapter(adapter)=false`；adapter 为有效策略合约 | 1. admin 调用 `registerStrategy(adapter, targetWeightBps, priority, isAsync)` | 1. 注册成功，`strategyInfo[adapter].exists=true`，`isActive=false`<br>2. 内部调用 `_ensureVaultAdapterRegistered(adapter)`，自动触发 `vault.registerAdapter(adapter)`<br>3. 最终 `vault.isAdapter(adapter)=true` |  |
|  | StrategyController |  | P0 | 注册重复策略被拒绝 | 某 adapter 已注册（`strategyInfo[adapter].exists == true`） | 1. admin 再次调用 `registerStrategy(adapter, ...)` | 回滚，抛出 `InvalidStrategy(adapter)` |  |
|  | StrategyController |  | P0 | 设置策略顺序时，纳入 order 的 active 策略总权重必须等于 10000 | 已注册并激活多策略；传入 `orderedStrategies` 中各 active 策略的 `targetWeightBps` 总和不为 10000 | 1. admin 调用 `setStrategyOrder(orderedStrategies)` | 回滚，抛出 `WeightsMustBe10000(actualTotalWeight)` |  |
|  | StrategyController |  | P0 | inactive strategy 不能进入 order | 已注册某策略但未调用 `activateStrategy`（`isActive=false`） | 1. admin 调用 `setStrategyOrder([...包含该策略...])` | 回滚，抛出 `StrategyInactive(adapter)` |  |
|  | StrategyController |  | P1 | priority 必须非递减 | 已注册两个 active 策略：A（`priority=10`）、B（`priority=5`） | 1. admin 调用 `setStrategyOrder([B, A])`（priority `5→10`）<br>2. admin 调用 `setStrategyOrder([A, B])`（priority `10→5`） | 1. 步骤 1 成功<br>2. 步骤 2 回滚，抛出 `InvalidPriorityOrder(B)` |  |
|  | StrategyController |  | P1 | `updateStrategiesAndOrder` 可同时更新参数与顺序 | 已注册多个策略，且传入更新参数合法 | 1. admin 调用 `updateStrategiesAndOrder(adapters, targetWeightBpsList, priorities, isAsyncList, orderedStrategies)` | 1. 策略参数更新成功<br>2. `strategyOrder` 更新成功<br>3. 最终状态与输入一致 |  |
|  | StrategyController |  | P0 | 策略完整生命周期：register -> activate -> order -> remove from order -> deactivate | Controller 已初始化；<br>目标 adapter 为有效策略合约；<br>对应 Vault adapter 初始未注册或可注册 | 1. admin 调 `registerStrategy`（默认 inactive）<br>2. admin 调 `activateStrategy`<br>3. admin 调 `setStrategyOrder` 将策略纳入 order<br>4. 通过再次设置 `strategyOrder` 将该策略移出 order<br>5. admin 调 `deactivateStrategy` | 1. 注册后 `isActive=false`，且 Vault 自动注册 adapter<br>2. 激活后 `isActive=true`；内部会再次确保 Vault 已注册该 adapter<br>3. 纳入 order 成功<br>4. 移出 order 成功<br>5. 停用成功，若 `vault.isAdapter(adapter)=true` 则自动调用 `vault.removeAdapter(adapter)` |  |
|  | StrategyController |  | P0 | 有 in-flight 的策略无法停用 | adapter 已注册且激活；存在 pending invest/redeem in-flight（`vault.adapterInvestInFlightTokens(adapter) > 0` 或 `vault.adapterRedeemInFlightUsdc(adapter) > 0`） | 1. admin 调 `deactivateStrategy(adapter)` | 回滚，抛出 `StrategyHasInFlight(adapter, pendingInvest, pendingRedeem)` |  |
|  | StrategyController |  | P0 | 在 order 中的策略无法停用，必须先移出 order | adapter 已注册且激活，且仍在 `strategyOrder` 中 | 1. admin 调 `deactivateStrategy(adapter)` | 回滚，抛出 `StrategyInOrder(adapter)` |  |
|  | StrategyController |  | P1 | `getRebalanceState / previewRebalance` 与实际 `rebalance` 决策一致 | 已配置策略和参数；当前不处于 cooldown；调用 `rebalance()` 的账户拥有 `OPERATOR_EXECUTOR_ROLE` | 1. 调用 `getRebalanceState()` 获取当前状态<br>2. 调用 `previewRebalance()` 获取预期动作<br>3. 实际调用 `rebalance()` | `previewRebalance` 的 `action/amount` 与实际 `rebalance` 的 invest/divest/no-op 决策一致 |  |
|  | StrategyController |  | P1 | `setAdapterPaused` 仅 `PAUSER_ROLE` 可调用 | adapter 已注册为策略（`strategyInfo[adapter].exists=true`） | 1. 非 pauser 调 `setAdapterPaused(adapter, true)`<br>2. pauser 调 `setAdapterPaused(adapter, true)` | 1. 非法调用回滚（`AccessControlUnauthorizedAccount`）<br>2. adapter 暂停成功，并触发 `AdapterPauseUpdated(adapter, true)`；后续该 adapter 的投资/赎回行为是否被阻断，取决于 adapter 自身 pause 逻辑 |  |
|  | StrategyController |  | P1 | 激活已激活的策略被拒绝 | adapter 已注册且 `isActive=true` | 1. admin 调用 `activateStrategy(adapter)` | 回滚，抛出 `StrategyAlreadyActive(adapter)` |  |
|  | StrategyController |  | P1 | 停用已停用的策略被拒绝 | adapter 已注册且 `isActive=false` | 1. admin 调用 `deactivateStrategy(adapter)` | 回滚，抛出 `StrategyAlreadyInactive(adapter)` |  |
|  | StrategyController |  | P1 | `updateStrategies` 输入数组长度不一致被拒绝 | Controller 已初始化；准备不等长的 `adapters / targetWeightBpsList / priorities / isAsyncList` 输入 | 1. admin 调用 `updateStrategies(adapters=[A,B], weights=[5000], priorities=[1,2], isAsync=[false,false])` | 回滚，抛出 `UpdateStrategiesLengthMismatch()` |  |
|  | StrategyController |  | P1 | `updateStrategies` 含重复 adapter 被拒绝 | 已存在策略 A | 1. admin 调用 `updateStrategies(adapters=[A,A], ...)` | 回滚，抛出 `DuplicateStrategyUpdate(A)` |  |
|  | StrategyController |  | P1 | `setAdaptersPaused` 可批量暂停多个 adapter | `adapterA`、`adapterB` 均已注册为策略 | 1. pauser 调用 `setAdaptersPaused([adapterA, adapterB], true)` | 1. 两个 adapter 均暂停成功<br>2. 每个 adapter 各触发一笔 `AdapterPauseUpdated(adapter, true)` |  |
|  | StrategyController |  | P1 | `setAdaptersPaused` 批量暂停中包含未注册 adapter 时整体回滚 | `adapterA` 已注册为策略，`adapterB` 未注册为策略 | 1. pauser 调用 `setAdaptersPaused([adapterA, adapterB], true)` | 整笔交易回滚，抛出 `InvalidStrategy(adapterB)` |  |
|  | StrategyController |  | P1 | `updateStrategies` 更新不存在的策略被拒绝 | `adapterX` 未注册为策略 | 1. admin 调用 `updateStrategies([adapterX], [5000], [1], [false])` | 回滚，抛出 `InvalidStrategy(adapterX)` |  |

## In-Flight 生命周期场景

| 是否自动化 | 测试合约 | 测试结果 | 优先级 | 测试需求描述 | 前置条件 | 测试步骤 | 期望结果 | 测试执行结果 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| ✅ | InFlightLifecycle.t.sol | PASS | P0 | Controller 创建 invest in-flight 记录成功 | adapter 已注册 | 1. 通过 `rebalance()` 触发 `_invest()` → `adapter.deposit()` → `vault.createInFlight(isInvest=true)` | 1. 记录状态为 `PENDING`<br>2. `totalInvestInFlight` 增加<br>3. `adapterInvestInFlightTokens` 增加 | test_CreateInvestInFlight_Success | 真实调用流程 |
| ✅ | InFlightLifecycle.t.sol | PASS | P0 | Controller 创建 redeem in-flight 记录成功 | adapter 已注册，用户有 shares | 1. 用户 `depositFor()` 获得 shares<br>2. 用户 `requestRedeemFor()` 发起赎回<br>3. `processRedeemBatch()` 触发 `_divest()` → `vault.createInFlight(isInvest=false)` | 1. 记录状态为 `PENDING`<br>2. `totalRedeemInFlight` 增加 | test_CreateRedeemInFlight_Success | 真实调用流程 |
| ✅ | InFlightLifecycle.t.sol | PASS | P0 | 未注册 adapter 不能创建 in-flight | adapter 未注册 | 1. 创建 in-flight 后调用 `settleAdapter(...)` | 回滚，抛出 `InvalidStrategy` | test_CreateInFlight_RevertUnregisteredAdapter | 边界测试 |
| ✅ | InFlightLifecycle.t.sol | PASS | P0 | 0 数量不能创建 in-flight | adapter 已注册 | 1. 创建 tokenAmount=0 的 in-flight<br>2. 调用 `settleAdapter(...)` | 回滚，抛出 `InvalidInvestInFlight` | test_CreateInFlight_RevertZeroAmount | 边界测试 |
| ✅ | InFlightLifecycle.t.sol | PASS | P0 | confirm invest in-flight 后状态变为 `CONFIRMED` 且统计减少 | 已存在 invest in-flight | 1. `rebalance()` 创建 invest in-flight<br>2. `settleAdapter()` 确认 | 1. 状态变 `CONFIRMED`<br>2. `settledAmount = tokenAmt`<br>3. 统计值减少至 0 | test_InvestSettlement_FullExecution | 真实调用流程 |
| ✅ | InFlightLifecycle.t.sol | PASS | P0 | confirm redeem in-flight 后状态变为 `CONFIRMED` 且统计减少 | 已存在 redeem in-flight | 1. `processRedeemBatch()` 创建 redeem in-flight<br>2. `settleAdapter()` 确认 | 1. 状态变 `CONFIRMED`<br>2. `settledAmount = usdcAmt`<br>3. 统计值减少至 0 | test_ConfirmRedeemInFlight_Success | 真实调用流程 |
| ✅ | InFlightLifecycle.t.sol | PASS | P1 | 底层回填资金确认时，应允许按真实到账金额确认 in-flight，并将偏差传导到最终结算 | 1. 已存在 invest in-flight<br>2. 实际到账 posToken 数量与预期有偏差 | 1. `rebalance()` 创建 invest in-flight<br>2. `settleAdapter()` 传入实际到账 99% 的 posAmount 和对应 refund | 1. in-flight 状态变为 `CONFIRMED`<br>2. `settledAmount = actualSettled`<br>3. `settledAmount < tokenAmt` | test_ConfirmInFlight_ActualAmountDiffers | 真实调用流程 |
| ✅ | InFlightLifecycle.t.sol | PASS | P1 | 重复 confirm 同一 in-flight 被拒绝 | 某 in-flight 已确认 | 1. `rebalance()` 创建 invest in-flight<br>2. 第一次 `settleAdapter()` 成功<br>3. 第二次 `settleAdapter()` 同一 id | 回滚，抛出 `InvalidInvestInFlight` | test_ConfirmInFlight_RevertDuplicateConfirm | 真实调用流程 |
| ✅ | InFlightLifecycle.t.sol | PASS | P1 | `confirmInFlight` 在异常确认模式下允许 `actualAmount=0` | 1. 已存在一笔 `PENDING` 状态的 invest in-flight<br>2. 调用方为 controller | 1. `rebalance()` 创建 invest in-flight<br>2. `settleAdapter()` 传入 pos=0, refund=full（全额退款场景） | 1. 调用成功<br>2. 该 in-flight 状态变为 `CONFIRMED`<br>3. `settledAmount = 0`<br>4. 统计值减少至 0 | test_ConfirmInFlight_AbnormalAllowsZeroAmount | 真实调用流程，DigiFT 全额退款 |
| ✅ | InFlightLifecycle.t.sol | PASS | P1 | `confirmInFlight` 在非异常确认模式下拒绝 `actualAmount=0` | 1. 存在 usdcAmount=0 的 redeem in-flight（边界情况）<br>2. 调用方为 controller | 1. 直接创建 usdcAmount=0 的 redeem in-flight<br>2. `settleAdapter()` 尝试确认 | 交易回滚，抛出 `InvalidRedeemInFlight`；<br>该 in-flight 状态保持不变 | test_ConfirmInFlight_NonAbnormalRejectsZeroAmount | 边界测试 |

## Adapter 注册与移除场景

| 是否自动化 | 测试合约 | 测试结果 | 优先级 | 测试需求描述 | 前置条件 | 测试步骤 | 期望结果 | 测试执行结果 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
|  | Vault |  | P0 | Controller 正常注册 adapter | Controller / Vault 已初始化 | 1. Controller 调用 `vault.registerAdapter(adapter)` | 1. 注册成功<br>2. `isAdapter[adapter]=true` |  |  |
|  | Vault |  | P0 | 重复注册 adapter 被拒绝 | adapter 已注册 | 1. 再次调用 `registerAdapter(adapter)` | 回滚，抛出 `Vault__AdapterAlreadyRegistered` |  |  |
|  | Vault |  | P0 | 移除不存在的 adapter 被拒绝 | adapter 未注册 | 1. 调用 `removeAdapter(adapter)` | 回滚，抛出 `Vault__AdapterNotRegistered` |  |  |
|  | Vault |  | P0 | adapter 存在 in-flight 时禁止移除 | adapter 已注册且存在 in-flight | 1. 调用 `removeAdapter(adapter)` | 回滚，抛出 `Vault__AdapterHasInFlight` |  |  |
|  | Vault |  | P1 | 无 in-flight 时可移除 adapter | adapter 已注册，无 in-flight | 1. 调用 `removeAdapter(adapter)` | 成功移除，`isAdapter[adapter]=false` |  |  |
|  | Vault |  | P1 | `approveToAdapter` 仅允许已注册 adapter | adapter 未注册（`isAdapter[adapter]=false`） | 1. Controller 调用 `vault.approveToAdapter(adapter, usdc, 1000e6)` | 回滚，抛出 `Vault__AdapterNotRegistered` |  |  |
|  | Vault |  | P1 | `approveToAdapter` 正常设置 allowance | adapter 已注册 | 1. 调用 `approveToAdapter(adapter, token, amount)` | allowance 更新成功 |  |  |

## Redeem Batch 批处理场景

| 是否自动化 | 测试合约 | 测试结果 | 优先级 | 测试需求描述 | 前置条件 | 测试步骤 | 期望结果 | 测试执行结果 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
|  | StrategyController、Vault、OperatorExecutor、Accountant、Adapter |  | P0 | `processRedeemBatch` 正常处理批次 | 存在多个 `PENDING` 请求 | 1. 调用 `processRedeemBatch(ids)` | 1. 批次标记为已处理<br>2. 请求进入 `PROCESSING`<br>3. `batchTotalAsset` 由合约内部通过 `exchangeRate * shares` 链上计算<br>4. emit `RedeemBatchProcessing(count, batchTotalAsset, shortfall)` |  |  |
|  | StrategyController、Vault、OperatorExecutor、Accountant、Adapter |  | P0 | 相同批次不能重复 `processRedeemBatch` | 某批次已处理 | 1. 再次调用 `processRedeemBatch(ids)` | 回滚，抛出 `BatchAlreadyProcessed` |  |  |
|  | StrategyController、Vault、OperatorExecutor、Accountant、Adapter |  | P0 | `finalizeRedeemBatch` 前必须先 process | 某批次尚未处理 | 1. 直接调用 `finalizeRedeemBatch(ids, settledAssets)` | 回滚，抛出 `BatchNotProcessed` |  |  |
|  | StrategyController、Vault、OperatorExecutor、Accountant、Adapter |  | P0 | `finalizeRedeemBatch` 成功完成已 processing 批次 | 1. `ids` 已通过 `processRedeemBatch` 进入 `PROCESSING`<br>2. Vault 物理余额足够覆盖 `settledAssets` 总和 | 1. `operatorExecutor` 调用 `finalizeRedeemBatch(ids, settledAssets)` | 1. `_batchRequiredAssets` 校验 `ids.length == settledAssets.length` 且各请求为 `PROCESSING`<br>2. `readyBatchDone[batchKey]=true`<br>3. 底层调用 `vault.markRequestsDone(ids, settledAssets)` 完成打款<br>4. 每笔请求状态变为 `DONE`，用户收到 USDC<br>5. emit `RedeemBatchReady(count, required)` |  |  |
|  | StrategyController、Vault、OperatorExecutor、Accountant、Adapter |  | P0 | 请求 ID 未排序或有重复时拒绝处理 | `ids` 无序或重复 | 1. 调用 `processRedeemBatch / finalizeRedeemBatch` | 回滚，抛出 `IdsNotSorted` |  |  |
|  | StrategyController、Vault、OperatorExecutor、Accountant、Adapter |  | P0 | 异步赎回最终释放资金时，以 Vault 中真实可点数的 USDC 为准，而不是仅依赖链下结算口径 | 1. 一批请求已进入 `PROCESSING`<br>2. operator 已准备 `settledAssets`<br>3. 初始 Vault 物理余额不足以覆盖该批次总额 | 1. 调用 `finalizeRedeemBatch(ids, settledAssets)`，确认因物理余额不足失败<br>2. 向 Vault 补足 physical USDC 余额<br>3. 再次调用 `finalizeRedeemBatch(ids, settledAssets)` | 1. 物理余额不足时，最终释放失败<br>2. 请求不会被“空头支票式”推进到完成<br>3. 物理余额补足后才能成功完成<br>4. 该场景应被记录为系统的“物理点钞”防线 |  |  |
|  | StrategyController、Vault、OperatorExecutor、Accountant、Adapter |  | P1 | `processRedeemBatch` 在现金不足时触发 `_divest(shortfall)` | `freeCash` 不足以覆盖链上计算的 `batchTotalAsset` | 1. 调用 `processRedeemBatch(ids)` | 1. 合约内部通过 `exchangeRate * shares` 计算 `batchTotalAsset`<br>2. `shortfall = batchTotalAsset - freeCash`<br>3. 同笔交易内执行 `_divest(shortfall)` 流程 |  |  |
|  | StrategyController、Vault、OperatorExecutor、Accountant、Adapter |  | P1 | `finalizeRedeemBatch` 校验物理余额而非 `freeCash` | 1. 存在大量 locked shares 使 `getFreeCash()` 很低<br>2. 但 Vault 物理 USDC 余额（`asset.balanceOf(vault)`）足以覆盖 `settledAssets` 总和 | 1. `operatorExecutor` 调用 `finalizeRedeemBatch(ids, settledAssets)` | 1. finalize 成功（校验的是 `asset.balanceOf(vault) >= sum(settledAssets)`，非 `freeCash`）<br>2. 验证 `freeCash` 和物理余额是两个不同校验口径 |  |  |
|  | StrategyController、Vault、OperatorExecutor、Accountant、Adapter |  | P0 | 相同批次不能重复 `finalizeRedeemBatch` | 某批次已成功 finalize（`readyBatchDone[batchKey] = true`） | 1. 再次调用 `finalizeRedeemBatch(ids, settledAssets)` | 回滚，抛出 `BatchAlreadyReady` |  |  |
|  | StrategyController、Vault、OperatorExecutor、Accountant、Adapter |  | P2 | `processRedeemBatch` 链上计算 `batchTotalAsset` 为 0 的边界行为 | 存在多个 shares 极小的 `PENDING` 请求，`exchangeRate * shares / 1e18` 向下取整后为 0 | 1. 调用 `processRedeemBatch(ids)` | 1. 批次仍标记为已处理（`batchTotalAsset=0`，链上计算结果）<br>2. 不触发 divest（`shortfall=0`）<br>3. 后续 `finalizeRedeemBatch(ids, settledAssets)` 可正常完成 |  |  |
|  | StrategyController、Vault、OperatorExecutor、Accountant、Adapter |  | P0 | `finalizeRedeemBatch` 的 `ids` 与 `settledAssets` 数组长度不一致 | `ids` 已通过 process 进入 `PROCESSING` | 1. 调用 `finalizeRedeemBatch([1,2,3], [100e6, 200e6])`（3 vs 2） | 回滚，抛出 `ClaimInputsLengthMismatch` |  |  |
|  | StrategyController、Vault、OperatorExecutor、Accountant、Adapter |  | P1 | `processRedeemBatch` 的 `batchTotalAsset` 依赖当前 `exchangeRate` | 1. 已有 `PENDING` 请求（`shares=1000e18`）<br>2. 当前 `exchangeRate = 1.1e18` | 1. 调用 `processRedeemBatch(ids)`<br>2. 验证事件中 `batchTotalAsset` | `batchTotalAsset = 1000e18 * 1.1e18 / 1e18 = 1100e6`（向下取整）；<br>若汇率已变化则结果不同于请求创建时的 `estimatedAssets` |  |  |
|  | StrategyController、Vault、OperatorExecutor、Accountant、Adapter |  | P1 | 大量异步赎回请求积压时，运营方可分页处理批次且不破坏整体队列一致性 | 1. 已存在大量 `PENDING` 请求<br>2. 请求数量显著高于单次建议处理规模<br>3. 各请求 `requestId` 已知且可分批挑选 | 1. 先选部分 `requestId` 调用 `processRedeemBatch(ids1)`<br>2. 再对另一部分调用 `processRedeemBatch(ids2)`<br>3. 分别执行 `finalizeRedeemBatch(ids1, settledAssets1)` 与 `finalizeRedeemBatch(ids2, settledAssets2)`<br>4. 检查所有请求状态与账本累计结果 | 1. 系统允许分批推进处理，不要求一次性处理全部请求<br>2. 每批仅影响自身请求集合<br>3. `pendingShares / totalLockedShares / request status` 保持一致<br>4. 系统不会因请求数量多而天然卡死 |  |  |

## Settle Adapter 结算场景

> 业务上下文：`settleAdapter / settleAdapters` 是 `StrategyController` 的统一结算入口，由 `OperatorExecutor` 调用。
>
> **Invest 结算模型**（支持 DigiFT 等 RWA 策略的三种场景）：
> - `InvestSettlementInput` 包含 `inFlightIds`, `settledPosAmounts`, `refundAssetAmounts`
> - **全额成交**：`settledPosAmount > 0, refundAssetAmount = 0`
> - **部分退款**：`settledPosAmount > 0, refundAssetAmount > 0`
> - **全额退款**：`settledPosAmount = 0, refundAssetAmount > 0`（走 abnormal confirm 路径）
>
> 结算流程：先根据本次 `settledAmounts` 汇总值执行 `sweepToVault`（posToken 和 refund asset 分别 sweep），然后在 sweep 实际到账量与应结算总量完全一致时，继续确认对应的 invest / redeem in-flight。若 sweep 数量不足，不会部分成功，而是整笔回滚。

| 是否自动化 | 测试合约 | 测试结果 | 优先级 | 测试需求描述 | 前置条件 | 测试步骤 | 期望结果 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
|  | StrategyController、Vault、Adapter、OperatorExecutor |  | P0 | `settleAdapter` 正常结算：同时处理 invest 与 redeem in-flight | 1. adapterA 已注册为策略<br>2. 存在 1 笔 pending invest in-flight：`investId=1`<br>3. 存在 1 笔 pending redeem in-flight：`redeemId=2`<br>4. adapter 可足额 sweep 回本次结算需要的 posToken 与 asset | 1. 调用 `settleAdapter(adapterA, [1], [100e18], [2], [500e6])` | 1. Controller 先汇总得到 `investToSweep=100e18`、`redeemToSweep=500e6`<br>2. 执行 `sweepToVault(posToken, 100e18)` 与 `sweepToVault(asset, 500e6)`<br>3. `posClaimed == 100e18`、`assetClaimed == 500e6`<br>4. 触发 `AdapterAssetsSwept`<br>5. invest/redeem in-flight 均确认成功，对应累计值递减 |  |
|  | StrategyController、Vault、Adapter、OperatorExecutor |  | P0 | `settleAdapter` 仅结算 redeem 回款（只处理 asset sweep） | 1. adapterA 已注册<br>2. 仅存在 pending redeem in-flight，无 invest in-flight<br>3. asset 可足额 sweep 回 Vault | 1. 调用 `settleAdapter(adapterA, [], [], [redeemId], [1000e6])` | 1. 不执行 posToken 的 `sweepToVault`<br>2. 执行 `sweepToVault(asset, 1000e6)`<br>3. redeem in-flight 确认成功 |  |
|  | StrategyController、Vault、Adapter、OperatorExecutor |  | P0 | `settleAdapter` 仅结算 invest 到账（只处理 posToken sweep） | 1. adapterA 已注册<br>2. 仅存在 pending invest in-flight，无 redeem in-flight<br>3. posToken 可足额 sweep 回 Vault | 1. 调用 `settleAdapter(adapterA, [investId], [100e18], [], [])` | 1. 执行 `sweepToVault(posToken, 100e18)`<br>2. 不执行 asset 的 `sweepToVault`<br>3. invest in-flight 确认成功 |  |
|  | StrategyController、Vault、Adapter、OperatorExecutor |  | P0 | invest ids 与 invest settledAmounts 长度不一致时被拒绝 | adapterA 已注册 | 1. 调用 `settleAdapter(adapterA, [1,2], [100e18], [], [])` | 回滚，抛出 `SettleAmountsLengthMismatch()` |  |
|  | StrategyController、Vault、Adapter、OperatorExecutor |  | P0 | redeem ids 与 redeem settledAmounts 长度不一致时被拒绝 | adapterA 已注册 | 1. 调用 `settleAdapter(adapterA, [], [], [2,3], [500e6])` | 回滚，抛出 `SettleAmountsLengthMismatch()` |  |
|  | StrategyController、Vault、Adapter、OperatorExecutor |  | P0 | sweep posToken 数量不足时整笔回滚，不存在按 `min(requested,balance)` 部分成功 | 1. adapterA 已注册<br>2. invest `settledAmounts` 求和为 `100e18`<br>3. adapter 实际只能 sweep 出 `80e18` posToken | 1. 调用 `settleAdapter(adapterA, [investId], [100e18], [], [])` | 1. 交易回滚，抛出 `InvestSweepAmountMismatch(adapterA, 100e18, 80e18)`<br>2. 不会继续确认 invest in-flight<br>3. `AdapterAssetsSwept` 事件不会最终落链 |  |
|  | StrategyController、Vault、Adapter、OperatorExecutor |  | P0 | sweep asset 数量不足时整笔回滚，不存在按 `min(requested,balance)` 部分成功 | 1. adapterA 已注册<br>2. redeem `settledAmounts` 求和为 `500e6`<br>3. adapter 实际只能 sweep 出 `300e6` asset | 1. 调用 `settleAdapter(adapterA, [], [], [redeemId], [500e6])` | 1. 交易回滚，抛出 `RedeemSweepAmountMismatch(adapterA, 500e6, 300e6)`<br>2. 不会继续确认 redeem in-flight<br>3. `AdapterAssetsSwept` 事件不会最终落链 |  |
|  | StrategyController、Vault、Adapter、OperatorExecutor |  | P0 | sweep 校验失败时，对应 in-flight 状态和累计值保持不变 | 1. 存在 pending invest 或 redeem in-flight<br>2. sweep 数量故意不足 | 1. 调用 `settleAdapter(...)` 并使其命中 mismatch 回滚<br>2. 查询 in-flight 状态及 Vault 统计值 | 1. 对应 in-flight 仍为 `PENDING`<br>2. `totalInvestInFlight / totalRedeemInFlight` 不变化<br>3. adapter 级累计值不变化 |  |
|  | StrategyController、Vault、Adapter、OperatorExecutor |  | P0 | redeem `settledAmount=0` 时走 abnormal confirm 路径 | 1. adapterA 已注册<br>2. 存在 1 笔 pending redeem in-flight | 1. 调用 `settleAdapter(adapterA, [], [], [redeemId], [0])` | 1. `redeemToSweep = 0`，不执行 asset sweep<br>2. 进入 `confirmInFlight(redeemId, 0, true)` 路径<br>3. redeem in-flight 状态变为 `CONFIRMED`，`settledAmount = 0` |  |
|  | StrategyController、Vault、Adapter、OperatorExecutor |  | P1 | invest `settledAmount=0` 时走 abnormal confirm 路径 | 1. adapterA 已注册<br>2. 存在 1 笔 pending invest in-flight | 1. 调用 `settleAdapter(adapterA, [investId], [0], [], [])` | 1. `investToSweep = 0`，不执行 posToken sweep<br>2. 进入 `confirmInFlight(investId, 0, true)` 路径<br>3. invest in-flight 状态变为 `CONFIRMED`，`settledAmount = 0` |  |
| ✅ | InFlightLifecycle.t.sol | PASS | P0 | invest 结算：全额成交（pos>0, refund=0） | 1. adapterA 已注册<br>2. 存在 1 笔 pending invest in-flight，记录 `tokenAmount=100e18`<br>3. adapter 可足额 sweep 出 posToken | 1. `rebalance()` 创建 invest in-flight<br>2. `settleAdapter(InvestSettlementInput([investId], [tokenAmt], [0]))` | 1. 执行 `sweepToVault(posToken, tokenAmt)`<br>2. 不执行 asset sweep（refund=0）<br>3. invest in-flight 状态变为 `CONFIRMED`，`settledAmount = tokenAmt`<br>4. 统计值减少至 0 | test_InvestSettlement_FullExecution | DigiFT 全额成交场景，真实调用流程 |
| ✅ | InFlightLifecycle.t.sol | PASS | P0 | invest 结算：部分退款（pos>0, refund>0） | 1. adapterA 已注册<br>2. 存在 1 笔 pending invest in-flight<br>3. adapter 可 sweep 出 70% posToken 和 30% asset | 1. `rebalance()` 创建 invest in-flight<br>2. `settleAdapter(InvestSettlementInput([investId], [70%], [30%]))` | 1. 执行 `sweepToVault(posToken, 70%)`<br>2. 执行 `sweepToVault(asset, 30%)`<br>3. invest in-flight 状态变为 `CONFIRMED`，`settledAmount = 70%`<br>4. `claimCount = 2`（两次 sweep） | test_InvestSettlement_PartialRefund | DigiFT 部分退款场景，真实调用流程 |
| ✅ | InFlightLifecycle.t.sol | PASS | P0 | invest 结算：全额退款（pos=0, refund>0） | 1. adapterA 已注册<br>2. 存在 1 笔 pending invest in-flight<br>3. adapter 可 sweep 出全额 asset | 1. `rebalance()` 创建 invest in-flight<br>2. `settleAdapter(InvestSettlementInput([investId], [0], [full]))` | 1. 不执行 posToken sweep（pos=0）<br>2. 执行 `sweepToVault(asset, full)`<br>3. 进入 abnormal confirm 路径<br>4. invest in-flight 状态变为 `CONFIRMED`，`settledAmount = 0`<br>5. `claimCount = 1`（仅 asset） | test_InvestSettlement_FullRefund | DigiFT 全额退款场景，真实调用流程 |
| ✅ | InFlightLifecycle.t.sol | PASS | P1 | invest 结算：refund sweep 数量不足时整笔回滚 | 1. adapterA 已注册<br>2. 存在 pending invest in-flight<br>3. refundAssetAmounts 求和为 30e6<br>4. adapter 实际只能 sweep 出 20e6 asset | 1. `rebalance()` 创建 invest in-flight<br>2. `settleAdapter(InvestSettlementInput([investId], [70%], [30%]))` 但 asset sweep 只返回 2/3 | 1. 交易回滚，抛出 `InvestRefundSweepAmountMismatch(adapterA, requested, actual)`<br>2. in-flight 状态保持 `PENDING` | test_InvestSettlement_RevertRefundSweepMismatch | 真实调用流程 |
|  | StrategyController、Vault、Adapter、OperatorExecutor |  | P1 | 未注册策略的 adapter 无法结算 | `adapterX` 未注册为策略 | 1. 调用 `settleAdapter(adapterX, [], [], [], [])` | 回滚，抛出 `InvalidStrategy(adapterX)` |  |
|  | StrategyController、Vault、Adapter、OperatorExecutor |  | P1 | invest in-flight 不属于当前 adapter 时被拒绝 | 1. `investId` 实际属于 `adapterB`<br>2. 当前结算对象为 `adapterA` | 1. 调用 `settleAdapter(adapterA, [investId], [100e18], [], [])` | 回滚，抛出 `InvalidInvestInFlight(investId)` |  |
|  | StrategyController、Vault、Adapter、OperatorExecutor |  | P1 | redeem in-flight 不属于当前 adapter 时被拒绝 | 1. `redeemId` 实际属于 `adapterB`<br>2. 当前结算对象为 `adapterA` | 1. 调用 `settleAdapter(adapterA, [], [], [redeemId], [500e6])` | 回滚，抛出 `InvalidRedeemInFlight(redeemId)` |  |
|  | StrategyController、Vault、Adapter、OperatorExecutor |  | P1 | 已确认的 in-flight 不能重复结算 | 某 invest 或 redeem in-flight 已不是 `PENDING` | 1. 再次将该 id 传入 `settleAdapter(...)` | 回滚，抛出 `InvalidInvestInFlight(...)` 或 `InvalidRedeemInFlight(...)` |  |
|  | StrategyController、Vault、Adapter、OperatorExecutor |  | P0 | `settleAdapters` 多 adapter 批量结算 happy path | 1. adapterA 有 invest in-flight<br>2. adapterB 有 redeem in-flight<br>3. 两者 sweep 资产均足额 | 1. 调用 `settleAdapters([adapterA, adapterB], [[investIdA], []], [[100e18], []], [[], [redeemIdB]], [[], [500e6]])` | 1. 两个 adapter 分别执行 sweep<br>2. 各自对应的 in-flight 正确确认<br>3. 每个 adapter 各触发一笔 `AdapterAssetsSwept` |  |
|  | StrategyController、Vault、Adapter、OperatorExecutor |  | P1 | `settleAdapters` 外层批量数组长度不一致时被拒绝 | `adapters.length` 与任一 batch 数组长度不一致 | 1. 调用 `settleAdapters([adapterA, adapterB], [[1]], [[100e18]], [[], []], [[], []])` | 回滚，抛出 `SettleAmountsLengthMismatch()` |  |
|  | StrategyController、Vault、Adapter、OperatorExecutor |  | P1 | `settleAdapters` 中任一 adapter 结算失败会导致整笔批量结算回滚 | 1. adapterA 结算正常<br>2. adapterB sweep 数量不足或 in-flight 非法 | 1. 调用 `settleAdapters([...])` | 整笔交易回滚，不会只成功一部分 adapter |  |
|  | StrategyController、Vault、Adapter、OperatorExecutor |  | P1 | `settleAdapter` 只有在 sweep 金额完全匹配后才会进入 `confirmInFlight` | 存在 in-flight；<br>可通过 mock 观察调用顺序 | 1. 构造成功场景调用 `settleAdapter(...)`<br>2. 构造 sweep mismatch 场景再次调用 | 1. 成功场景：先 sweep，再 confirm<br>2. mismatch 场景：不会调用 `confirmInFlight` |  |

## OperatorExecutor 执行场景

| 是否自动化 | 测试合约 | 测试结果 | 优先级 | 测试需求描述 | 前置条件 | 测试步骤 | 期望结果 | 测试执行结果 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
|  | OperatorExecutor、StrategyController |  | P0 | OperatorExecutor 初始化成功并授予初始 bot 权限 | 已部署代理；admin、initialBot 均为非零地址 | 1. 调用 `initialize(admin, initialBot)` | 初始化成功；admin 拥有 `DEFAULT_ADMIN_ROLE`；initialBot 拥有 `BOT_ROLE` |  |  |
|  | OperatorExecutor、StrategyController |  | P0 | 初始化拒绝零地址参数 | 已部署代理 | 1. 调用 `initialize(address(0), initialBot)`<br>2. 调用 `initialize(admin, address(0))` | 两种情况均回滚，抛出 `InvalidAddress()` |  |  |
|  | OperatorExecutor、StrategyController |  | P0 | 只有 admin 可以管理 `BOT_ROLE` | 合约已初始化 | 1. 非 admin 调用 `grantRole(BOT_ROLE, newBot)` 或 `revokeRole(BOT_ROLE, bot)`<br>2. admin 调用 `grantRole/revokeRole` | 1. 非法调用回滚（`AccessControlUnauthorizedAccount`）<br>2. admin 调用成功 |  |  |
|  | OperatorExecutor、StrategyController |  | P1 | 初始 bot 不自动拥有 admin 权限 | 合约已初始化；`admin != initialBot` | 1. 查询 `hasRole(DEFAULT_ADMIN_ROLE, initialBot)` | 返回 false |  |  |
|  | OperatorExecutor、StrategyController |  | P1 | admin 不自动拥有 `BOT_ROLE` | 合约已初始化；`admin != initialBot` | 1. 查询 `hasRole(BOT_ROLE, admin)` | 返回 false |  |  |
|  | OperatorExecutor、StrategyController |  | P0 | 合法 bot 可成功执行 `rebalance` | bot 已拥有 `BOT_ROLE`；`controller_` 为合法 StrategyController 合约地址 | 1. bot 调用 `executeRebalance(controller_)` | 下游 `controller.rebalance()` 被执行；<br>触发 `RebalanceExecuted(bot, controller_)` |  |  |
|  | OperatorExecutor、StrategyController |  | P0 | 非 `BOT_ROLE` 账户不能执行 `rebalance` | caller 无 `BOT_ROLE`；`controller_` 合法 | 1. caller 调用 `executeRebalance(controller_)` | 回滚，抛出 `AccessControlUnauthorizedAccount(caller, BOT_ROLE)` |  |  |
|  | OperatorExecutor、StrategyController |  | P0 | 非法 controller 地址被拒绝（零地址与 EOA 分别校验） | OperatorExecutor 已初始化 | 1. bot 调用 `executeRebalance(address(0))`<br>2. bot 调用 `executeRebalance(eoaAddress)` | 1. 零地址回滚，抛出 `InvalidAddress()`<br>2. EOA 地址回滚，抛出 `InvalidController(eoaAddress)` |  |  |
|  | OperatorExecutor、StrategyController |  | P1 | 下游 Controller 调用失败时整笔交易回滚 | bot 已拥有 `BOT_ROLE`；构造一个会在 `rebalance()` 中回滚的 mock controller | 1. bot 调用 `executeRebalance(controller_)` | 整笔交易回滚；不触发 `RebalanceExecuted` |  |  |
|  | OperatorExecutor、StrategyController |  | P0 | `BOT_ROLE` 可成功执行 `processRedeemBatch` | bot 已拥有 `BOT_ROLE`；`controller_` 合法；已准备 redeem ids | 1. bot 调用 `executeProcessRedeemBatch(controller_, ids)` | 下游 `controller.processRedeemBatch(ids)` 被执行；<br>触发 `ProcessRedeemBatchExecuted(bot, controller_, idsHash)` |  |  |
|  | OperatorExecutor、StrategyController |  | P1 | `processRedeemBatch` 事件中的 `idsHash` 正确 | bot 已拥有 `BOT_ROLE`；`controller_` 合法；ids 已确定 | 1. bot 调用 `executeProcessRedeemBatch(controller_, ids)` | 事件中的 `idsHash == keccak256(abi.encodePacked(ids))` |  |  |
|  | OperatorExecutor、StrategyController |  | P1 | 空 ids 数组是否允许取决于下游 Controller | bot 已拥有 `BOT_ROLE`；`controller_` 合法 | 1. bot 调用 `executeProcessRedeemBatch(controller_, [])` | OperatorExecutor 自身不校验空数组；<br>是否成功取决于下游 controller 逻辑 |  |  |
|  | OperatorExecutor、StrategyController |  | P0 | `BOT_ROLE` 可成功执行 `finalizeRedeemBatch` | bot 已拥有 `BOT_ROLE`；`controller_` 合法；ids 与 `settledAssets` 已准备 | 1. bot 调用 `executeFinalizeRedeemBatch(controller_, ids, settledAssets)` | 下游 `controller.finalizeRedeemBatch(ids, settledAssets)` 被执行；<br>触发 `FinalizeRedeemBatchExecuted(bot, controller_, idsHash, settledAssetsHash)` |  |  |
|  | OperatorExecutor、StrategyController |  | P1 | `finalizeRedeemBatch` 事件中的 `idsHash / settledAssetsHash` 正确 | bot 已拥有 `BOT_ROLE`；`controller_` 合法；输入数组已确定 | 1. bot 调用 `executeFinalizeRedeemBatch(...)` | 事件中的 `idsHash == keccak256(abi.encodePacked(ids))`；`settledAssetsHash == keccak256(abi.encodePacked(settledAssets))` |  |  |
|  | OperatorExecutor、StrategyController |  | P1 | ids 与 `settledAssets` 长度不一致时是否回滚由下游决定 | bot 已拥有 `BOT_ROLE`；`controller_` 合法 | 1. bot 调用 `executeFinalizeRedeemBatch(controller_, [1,2], [100e6])` | OperatorExecutor 不做长度校验；<br>是否回滚取决于下游 controller |  |  |
|  | OperatorExecutor、StrategyController |  | P0 | `BOT_ROLE` 可成功执行单个 adapter 结算 | bot 已拥有 `BOT_ROLE`；`controller_` 合法；adapter 及 invest/redeem in-flight 参数已准备 | 1. bot 调用 `executeSettleAdapter(controller_, adapter, investInFlightIds, investSettledAmounts, redeemInFlightIds, redeemSettledAmounts)` | 下游 `controller.settleAdapter(...)` 被执行；<br>触发 `SettleAdapterExecuted(bot, controller_, adapter)` |  |  |
|  | OperatorExecutor、StrategyController |  | P1 | `executeSettleAdapter` 是否回滚取决于下游参数校验 | bot 已拥有 `BOT_ROLE`；`controller_` 合法；构造长度不一致或非法 settle 参数 | 1. bot 调用 `executeSettleAdapter(...)` | OperatorExecutor 不做数组长度与业务合法性校验；<br>若下游校验失败则整笔回滚 |  |  |
|  | OperatorExecutor、StrategyController |  | P0 | `BOT_ROLE` 可成功执行批量 adapter 结算 | bot 已拥有 `BOT_ROLE`；`controller_` 合法；批量 adapters 与 batch 参数已准备 | 1. bot 调用 `executeSettleAdapters(controller_, adapters, investInFlightIdsBatch, investSettledAmountsBatch, redeemInFlightIdsBatch, redeemSettledAmountsBatch)` | 下游 `controller.settleAdapters(...)` 被执行；<br>触发 `SettleAdaptersExecuted(bot, controller_, adaptersHash)` |  |  |
|  | OperatorExecutor、StrategyController |  | P1 | `executeSettleAdapters` 的批量维度合法性由下游决定 | bot 已拥有 `BOT_ROLE`；`controller_` 合法；故意构造 batch 维度不一致 | 1. bot 调用 `executeSettleAdapters(...)` | OperatorExecutor 不做批量维度校验；<br>若下游校验失败则整笔回滚 |  |  |
|  | OperatorExecutor、StrategyController |  | P1 | `executeSettleAdapters` 事件中的 `adaptersHash` 正确 | bot 已拥有 `BOT_ROLE`；`controller_` 合法；adapters 已确定 | 1. bot 调用 `executeSettleAdapters(...)` | 事件中的 `adaptersHash == keccak256(abi.encodePacked(adapters))` |  |  |
|  | OperatorExecutor、StrategyController |  | P0 | UUPS 升级仅 admin 可执行 | OperatorExecutor 已初始化；已部署兼容的新实现合约 | 1. 非 admin 调用升级入口 → 回滚<br>2. admin 调用升级入口 → 成功 | 1. 非 admin 回滚（`AccessControlUnauthorizedAccount`）<br>2. admin 升级成功 |  |  |
|  | OperatorExecutor、StrategyController |  | P1 | 升级后角色状态保持不变 | 已初始化并已配置 admin、bot；已部署新实现 | 1. 记录升级前角色状态<br>2. 执行升级<br>3. 再次检查角色 | `DEFAULT_ADMIN_ROLE` 与 `BOT_ROLE` 成员保持不变 |  |  |
|  | OperatorExecutor、StrategyController |  | P1 | 升级后执行能力保持正常 | 已升级到新实现；bot 仍有效；controller 合法 | 1. bot 调用任一 `execute*` 方法 | 调用成功；<br>仍可正确路由到下游 controller；<br>事件正常 |  |  |
|  | OperatorExecutor、StrategyController |  | P1 | 撤销 bot 后该地址立即失去执行权限 | bot 原本拥有 `BOT_ROLE` | 1. admin 调用 `revokeRole(BOT_ROLE, bot)`<br>2. bot 再调用任一 `execute*` 方法 | 第 2 步回滚，抛出 `AccessControlUnauthorizedAccount(bot, BOT_ROLE)` |  |  |
|  | OperatorExecutor、StrategyController |  | P1 | 新增 bot 后可立即执行操作 | `newBot` 尚无 `BOT_ROLE` | 1. admin 调用 `grantRole(BOT_ROLE, newBot)`<br>2. `newBot` 调用任一 `execute*` 方法 | `newBot` 可立即成功执行对应操作 |  |  |

## Accountant 汇率与管理费场景

| 是否自动化 | 测试合约 | 测试结果 | 优先级 | 测试需求描述 | 前置条件 | 测试步骤 | 期望结果 | 测试执行结果 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
|  | Accountant、Vault、Gateway、AccountantExecutor |  | P0 | Accountant 初始化成功 | 已部署 Accountant 代理 | 1. 调用 `initialize(address vault_, uint256 initialRate, uint32 managementFeeRate_, address admin)` | 1. 初始化成功<br>2. `lastExchangeRate == initialRate`<br>3. `managementFeeRate == managementFeeRate_`<br>4. `maxAllowedDeviation == 100`（默认 1%）<br>5. `minUpdateInterval == 20 hours`<br>6. `maxComputeAge == 5 minutes`<br>7. admin 获得 `DEFAULT_ADMIN_ROLE + PAUSER_ROLE + EXECUTOR_ROLE` |  |  |
|  | Accountant、Vault、Gateway、AccountantExecutor |  | P0 | 初始化拒绝零地址与非法费率 | 未初始化 Accountant | 1. 传入 `vault=address(0)` 或 `admin=address(0)` → 回滚<br>2. 传入 `feeRate > MAX_FEE` → 回滚 | 零地址抛出地址校验错误；过高费率抛出费率校验错误 |  |  |
|  | Accountant、Vault、Gateway、AccountantExecutor |  | P0 | 正常更新汇率成功 | 偏差、时间戳、冷却期均合法 | 1. 调用 `updateExchangeRate(newRate, computeTimestamp)` | 1. 汇率更新成功<br>2. 更新时间戳更新 |  |  |
|  | Accountant、Vault、Gateway、AccountantExecutor |  | P0 | 新汇率为 0 被拒绝 | Accountant 已初始化，当前 `rate=1e18` | 1. `accountantExecutor` 调用 `updateExchangeRate(0, validTs)` | 回滚，新汇率不能为 0 |  |  |
|  | Accountant、Vault、Gateway、AccountantExecutor |  | P0 | 汇率偏差超过阈值时触发 circuit breaker，而非直接回滚 | 当前 `rate=1e18`，`maxDeviation` 假设为 5% | 1. 调用 `updateExchangeRate(1.1e18, validTs)`（偏差 10% > 5%） | 1. 调用不因偏差超限直接回滚<br>2. Accountant 自动暂停<br>3. emit `CircuitBreakerTriggered`<br>4. `lastExchangeRate` 保持旧值 |  |  |
|  | Accountant、Vault、Gateway、AccountantExecutor |  | P0 | `computeTimestamp` 回退时被拒绝 | 上次 `lastComputeTimestamp = T` | 1. 调用 `updateExchangeRate(newRate, T-1)` | 回滚，新时间戳必须严格大于上次计算时间 |  |  |
|  | Accountant、Vault、Gateway、AccountantExecutor |  | P0 | `computeTimestamp` 在未来时被拒绝 | 当前 `block.timestamp = T` | 1. 调用 `updateExchangeRate(newRate, T+100)` | 回滚，计算时间戳不能超过当前块时间 |  |  |
|  | Accountant、Vault、Gateway、AccountantExecutor |  | P0 | `computeTimestamp` 过旧时被拒绝 | 当前 `block.timestamp = T`，`maxStaleness` 假设为 1 小时 | 1. 调用 `updateExchangeRate(newRate, T - 2 hours)` | 回滚，计算时间戳距当前时间超过允许的最大过期时长 |  |  |
|  | Accountant、Vault、Gateway、AccountantExecutor |  | P0 | 冷却期内再次更新汇率被拒绝 | 刚成功更新过汇率，距上次 < `minUpdateInterval` | 1. 立刻再次调用 `updateExchangeRate(newRate, newTs)` | 回滚，冷却期未满 |  |  |
|  | Accountant、Vault、Gateway、AccountantExecutor |  | P0 | 更新汇率时自动结算管理费并 mint fee shares | 1. `managementFeeRate=100`（1% 年化）<br>2. 距上次更新已过一段时间<br>3. Vault 当前 `totalSupply > 0` | 1. `accountantExecutor` 调用 `updateExchangeRate(newRate, computeTs)` | 1. `_settleManagementFee` 被调用，按时间比例计算应铸 fee shares<br>2. 调用 `vault.mintFeeShares(feeShares)` 铸造给 treasury<br>3. treasury `balanceOf` 增加<br>4. 汇率更新为 `newRate` |  |  |
|  | Accountant、Vault、Gateway、AccountantExecutor |  | P1 | `getRate()` 在暂停时仍可读取最后汇率 | Accountant 已暂停 | 1. 调用 `getRate()` | 返回最后有效汇率 |  |  |
|  | Accountant、Vault、Gateway、AccountantExecutor |  | P1 | `getRateSafe()` 在暂停时会 revert | Accountant 已暂停 | 1. 调用 `getRateSafe()` | 回滚 |  |  |
|  | Accountant、Vault、Gateway、AccountantExecutor |  | P1 | Accountant 暂停后 Gateway 的写入口统一进入暂停语义 | Accountant 已暂停 | 1. 调用 `gateway.deposit(amount)` → 回滚<br>2. 调用 `gateway.redeem(shares)` → 回滚<br>3. 调用 `gateway.requestRedeem(shares)` → 回滚 | 均回滚为 `EnforcedPause()` |  |  |
|  | Accountant、Vault、Gateway、AccountantExecutor |  | P1 | Vault 暂停时，Accountant 自动结费路径会失败 | Vault 已暂停，且本次更新需要铸 fee shares | 1. 调用 `updateExchangeRate(...)` | 因 `vault.mintFeeShares` 受 `whenNotPaused` 限制，整笔更新回滚 |  |  |
|  | Accountant、Vault、Gateway、AccountantExecutor |  | P1 | `setRiskParams` 偏差边界校验 | Accountant 已初始化 | 1. admin 调用 `setRiskParams(0, 20 hours)` → 回滚<br>2. admin 调用 `setRiskParams(1001, 20 hours)`（`> MAX_DEVIATION_CEILING=1000`）→ 回滚<br>3. admin 调用 `setRiskParams(500, 0)` → 成功（`minInterval=0` 允许即时更新） | 1 & 2 均抛出 `InvalidDeviation`<br>3. 成功，后续 `updateExchangeRate` 无冷却期约束 |  |  |
|  | Accountant、Vault、Gateway、AccountantExecutor |  | P1 | `setManagementFeeRate` 边界校验 | Accountant 已初始化 | 1. admin 调用 `setManagementFeeRate(501)`（`> MAX_MANAGEMENT_FEE_BPS=500`）→ 回滚<br>2. admin 调用 `setManagementFeeRate(0)` → 成功 | 1. 抛出 `InvalidFeeRate(501)`<br>2. 成功，后续 `_settleManagementFee` 不再铸 fee shares |  |  |
|  | Accountant、Vault、Gateway、AccountantExecutor |  | P1 | `setMaxComputeAge` 边界校验 | Accountant 已初始化 | 1. admin 调用 `setMaxComputeAge(0)` → 回滚<br>2. admin 调用 `setMaxComputeAge(86401)`（`> MAX_COMPUTE_AGE_CEILING=1 days`）→ 回滚<br>3. admin 调用 `setMaxComputeAge(600)` → 成功 | 1 & 2 均抛出 `InvalidComputeAge`<br>3. 成功，`maxComputeAge` 更新为 600 秒 |  |  |
|  | Accountant、Vault、Gateway、AccountantExecutor |  | P1 | `setVault` 更换关联 Vault | Accountant 已初始化，关联 `vaultA` | 1. admin 调用 `setVault(address(0))` → 回滚<br>2. admin 调用 `setVault(vaultB)` → 成功 | 1. 抛出 `ZeroAddress()`<br>2. `vault()` 返回 `vaultB`，emit `VaultUpdated(vaultA, vaultB)` |  |  |
|  | Accountant、Vault、Gateway、AccountantExecutor |  | P1 | 管理费结算时间差为 0 → 不铸造 shares | 1. Accountant 刚初始化<br>2. `lastFeeSettleTimestamp = block.timestamp`<br>3. 冷却期已过（通过 `setRiskParams` 设置 `minInterval=0`） | 1. 立刻调用 `updateExchangeRate(newRate, validTs)` | 1. `_settleManagementFee` 被调用但 `timeElapsed=0`<br>2. `feeShares=0`，不调用 `mintFeeShares`<br>3. treasury 余额不变 |  |  |
|  | Accountant、Vault、Gateway、AccountantExecutor |  | P0 | circuit breaker 触发后不更新关键状态且不结算管理费 | 1. 当前 `rate = 1e18`<br>2. 距离上次 fee 结算已过去一段时间，且 `managementFeeRate > 0`<br>3. Vault `totalSupply > 0`<br>4. 本次提交的新汇率超出 `maxAllowedDeviation` | 1. 记录 `lastExchangeRate/lastUpdateTimestamp/lastComputeTimestamp/lastFeeSettleTimestamp`<br>2. 调用超限 `updateExchangeRate(...)` | 1. 触发 `CircuitBreakerTriggered`<br>2. Accountant 进入 pause<br>3. `lastExchangeRate / lastUpdateTimestamp / lastComputeTimestamp / lastFeeSettleTimestamp` 都保持不变<br>4. 不调用 `mintFeeShares`<br>5. treasury 余额不变 |  |  |
|  | Accountant、Vault、Gateway、AccountantExecutor |  | P0 | admin 可通过 `emergencyRateUpdate` 绕过偏差与冷却期限制修正汇率 | 1. Accountant 已初始化<br>2. 当前处于 cooldown 内或新汇率偏差远超阈值 | 1. admin 调用 `emergencyRateUpdate(newRate)` | 1. 成功更新汇率<br>2. 不受 `cooldown / deviation` 限制影响<br>3. emit `EmergencyRateUpdated` |  |  |
|  | Accountant、Vault、Gateway、AccountantExecutor |  | P0 | `emergencyRateUpdate` 可在 circuit breaker 后恢复系统可用性 | Accountant 已因超限更新进入 pause | 1. admin 调用 `emergencyRateUpdate(newRate)`<br>2. 再调用 `getRateSafe()` | 1. Accountant 自动解除 pause<br>2. `getRateSafe()` 恢复可用<br>3. 返回修正后的新汇率 |  |  |
|  | Accountant、Vault、Gateway、AccountantExecutor |  | P1 | 非 admin 不可调用 `emergencyRateUpdate` | 调用者无 `DEFAULT_ADMIN_ROLE` | 1. 普通用户调用 `emergencyRateUpdate(newRate)` | 回滚，命中权限校验 |  |  |
|  | Accountant、Vault、Gateway、AccountantExecutor |  | P1 | `emergencyRateUpdate(0)` 被拒绝 | Accountant 已初始化 | 1. admin 调用 `emergencyRateUpdate(0)` | 回滚，抛出 `InvalidRate()` |  |  |

## SanctionsOracle 场景

| 是否自动化 | 测试合约 | 测试结果 | 优先级 | 测试需求描述 | 前置条件 | 测试步骤 | 期望结果 | 测试执行结果 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
|  | sanctions |  | P0 | 单地址加入制裁名单成功 | Oracle 已初始化 | 1. `complianceBot` 调用 `updateSanctionStatus(account, true)` | 1. `isSanctioned(account)=true`<br>2. 总数增加 |  |  |
|  | sanctions |  | P0 | 单地址移出制裁名单成功 | 地址已被制裁 | 1. `complianceBot` 调用 `updateSanctionStatus(account, false)` | 1. `isSanctioned(account)=false`<br>2. 总数减少 |  |  |
|  | sanctions |  | P0 | 非 compliance 角色无法更新制裁状态 | Oracle 已初始化 | 1. 非 `complianceBot` 调用更新函数 | 回滚 |  |  |
|  | sanctions |  | P1 | 批量更新制裁状态成功 | 已初始化 | 1. 调用 `updateSanctionStatusBatch(accounts, true)` | 批量生效，事件正确 |  |  |
|  | sanctions |  | P1 | 空数组批量更新被拒绝 | 已初始化 | 1. 调用 `updateSanctionStatusBatch([], true)` | 回滚，抛出 `Oracle__EmptyArray` |  |  |
|  | sanctions |  | P1 | 超过最大批量数被拒绝 | 构造超限数组 | 1. 调用批量更新 | 回滚，抛出 `Oracle__BatchTooLarge` |  |  |
|  | sanctions |  | P1 | 重复设置相同状态时保持幂等 | 某地址已为 `sanctioned=true` | 1. 再次设置为 `true` | 业务结果不变，计数不重复增加 |  |  |
|  | sanctions |  | P1 | `totalSanctionedCount` 正确反映增减 | Oracle 已初始化，初始 `count=0` | 1. `updateSanctionStatus(alice, true)` → `count=1`<br>2. `updateSanctionStatus(bob, true)` → `count=2`<br>3. `updateSanctionStatus(alice, false)` → `count=1` | `totalSanctionedCount()` 在每步后返回正确值 |  |  |
|  | sanctions |  | P1 | `batchNonce` 每次批量操作后递增 | Oracle 已初始化，初始 `batchNonce=0` | 1. 调用 `updateSanctionStatusBatch([alice, bob], true)` → `batchNonce=1`<br>2. 调用 `updateSanctionStatusBatch([charlie], false)` → `batchNonce=2` | `batchNonce()` 在每次 batch 后严格 +1 |  |  |
|  | sanctions |  | P1 | 批量操作含零地址时被拒绝 | Oracle 已初始化 | 1. 调用 `updateSanctionStatusBatch([alice, address(0), bob], true)` | 回滚，抛出 `Oracle__ZeroAddress` |  |  |

## 查询与报价场景

| 是否自动化 | 测试合约 | 测试结果 | 优先级 | 测试需求描述 | 前置条件 | 测试步骤 | 期望结果 | 测试执行结果 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
|  | gateway |  | P0 | `gateway.maxDeposit` 对被制裁用户返回 0 | 1. userA 已被制裁<br>2. Vault / Gateway / Accountant 正常运行 | 1. 调用 `gateway.maxDeposit(userA)` | 返回 0 |  |  |
|  | gateway |  | P0 | `gateway.maxRedeem` 对被制裁用户返回 0 | 1. userA 已被制裁且持有 shares | 1. 调用 `gateway.maxRedeem(userA)` | 返回 0 |  |  |
|  | gateway |  | P0 | Accountant 暂停时 Gateway 的 `maxDeposit/maxRedeem` 返回 0 | 1. Accountant 已暂停<br>2. userA 持有 shares 且未被制裁 | 1. 分别调用 `gateway.maxDeposit(userA)` 和 `gateway.maxRedeem(userA)` | 全部返回 0（因 `_isSubscribeRedeemPaused()` 为 true） |  |  |
|  | gateway |  | P1 | `syncRedeemDisabled` 当前不影响 `gateway.maxRedeem` 的展示值 | 已开启 `syncRedeemDisabled`，owner 未制裁，Accountant 正常 | 1. 查询 `gateway.maxRedeem(userA)`<br>2. 再调用真实 `gateway.redeem(...)` | 1. `maxRedeem` 仍可能非 0<br>2. 真实 redeem 被 `Vault__SyncRedeemDisabled` 拒绝 |  |  |
|  | gateway / vault |  | P1 | Gateway `previewRedeem/previewDeposit` 与 Vault 一致 | 1. `rate=1.1e18`，`redemptionFeeBps=100` | 1. 查询 `gateway.previewRedeem(shares)` 与 `vault.previewRedeem(shares)` 比较<br>2. 查询 `gateway.previewDeposit(assets)` 与 `vault.previewDeposit(assets)` 比较 | 两对返回值分别相等 |  |  |
|  | vault / accountant |  | P1 | `exchangeRate()` 与 Accountant 当前值一致 | Accountant 已设置汇率 | 1. 查询 `vault.exchangeRate()` | 返回 Accountant 当前 rate |  |  |
|  | vault |  | P1 | `share()` 返回 Vault 自身地址 | Vault 已初始化 | 1. 调用 `share()` | 返回 Vault 地址 |  |  |
|  | gateway / vault |  | P1 | Gateway 新增 `getFreeCash()` 转调 Vault 结果一致 | Vault 有 USDC 余额和 locked shares | 1. 查询 `gateway.getFreeCash()`<br>2. 查询 `vault.getFreeCash()` | 两者返回值相等 |  |  |
|  | controller |  | P1 | `strategyOrderLength()` 与实际 order 一致 | 1. Controller 初始化，order 为空<br>2. 注册并激活 2 个策略，设置 order | 1. 初始查询 `strategyOrderLength()` → 0<br>2. `setStrategyOrder([A, B])` 后查询 → 2<br>3. `setStrategyOrder([A])` 后查询 → 1 | 每步返回值与 `strategyOrder` 数组长度一致 |  |  |
|  | vault |  | P1 | `pendingRedeemRequest(owner)` 在请求创建和结算后正确反映 | 1. userA 初始无异步请求 | 1. 查询 `vault.pendingRedeemRequest(userA)` → 0<br>2. userA 发起异步赎回 1000 shares<br>3. 查询 → 1000 shares 对应的 estimated assets<br>4. 结算完成（`markRequestsDone`）<br>5. 查询 → 0 | 各步骤返回值正确反映当前 pending 状态 |  |  |
|  | gateway / vault |  | P1 | Gateway `getTokenInfos() / totalAssets()` 透传 Vault | Vault 已注册 1 个 adapter 且有余额 | 1. 比较 `gateway.getTokenInfos()` 与 `vault.getTokenInfos()`<br>2. 比较 `gateway.totalAssets()` 与 `vault.totalAssets()` | 两对返回值分别相等 |  |  |

## 风险回归场景

| 是否自动化 | 测试合约 | 测试结果 | 优先级 | 测试需求描述 | 前置条件 | 测试步骤 | 期望结果 | 测试执行结果 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
|  | adapter |  | P0 | `getTokenInfos()` 在 0 个 adapter 时返回格式正确 | Vault 无 adapter | 1. 调用 `getTokenInfos()` | 返回数组至少包含底层资产信息 |  |  |
|  | adapter |  | P0 | `getTokenInfos()` 在 1 个 adapter 时返回完整且正确 | 已注册 1 个 adapter（adapterA） | 1. 调用 `getTokenInfos()`<br>2. 断言返回数组长度 = 2<br>3. 断言 `infos[0]` 为底层资产信息<br>4. 断言 `infos[1]` 为 adapterA 信息（`posToken/tokenAmount/usdcAmount` 均正确） | 1. 数组长度 = `adapters.length + 1`<br>2. `infos[0].token == asset()`<br>3. `infos[1].token == adapterA.posToken()`<br>4. 不存在空槽位或错位 |  |  |
|  | adapter |  | P0 | `getTokenInfos()` 在 2 个 adapter 时所有 adapter 均正确映射 | 已注册 2 个 adapter（adapterA, adapterB） | 1. 调用 `getTokenInfos()`<br>2. 断言返回数组长度 = 3<br>3. 逐项验证 `infos[1]` 对应 adapterA，`infos[2]` 对应 adapterB | 1. 每个 adapter 的 `posToken`、`tokenAmount`（含 in-flight）、`usdcAmount` 均正确<br>2. 顺序与 `adapters` 数组一致 |  |  |
|  | adapter |  | P0 | `getTokenInfos()` 循环索引回归测试 | 已注册 2 个 adapter | 1. 调用 `getTokenInfos()`<br>2. 验证 `infos[1]` 是 `adapters[0]` 的信息<br>3. 验证 `infos[2]` 是 `adapters[1]` 的信息<br>4. 验证无空槽位 | 1. 循环 `for(i=0; i<len; i++)` 正确遍历所有 adapter<br>2. 写入 `infos[i+1]` 无偏移错误 |  |  |
|  | adapter |  | P1 | Adapter `getPosTokenPrice()` 价格回退链验证 | 已部署 adapter，`priceOracle` 可配置 | 1. 设置有效 `priceOracle` 且 `getPrice()>0` → 验证使用 oracle 价格<br>2. `oracle getPrice()=0` 且 `manualPosTokenPrice>0` → 验证 fallback 到 manual<br>3. 无 oracle 且 `manual=0` → 验证 fallback 到 `1e18` 默认值 | 三层回退链均返回正确价格，影响 `totalValue()` 和 `totalAssets()` 计算 |  |  |
|  | adapter |  | P1 | adapter 的 `setManualPosTokenPrice` 仅 `accountantExecutor` 可调用且 oracle 已配置时被拒绝 | adapter 已配置 `priceOracle` | 1. `accountantExecutor` 调 `setManualPosTokenPrice(1.05e18)` | 回滚，抛出 `Unsupported()`（oracle 存在时不允许手动覆盖） |  |  |
|  | adapter |  | P1 | Adapter sweep 保护底层资产和 `posToken` | adapter 持有多种 token | 1. admin 调 `sweep(asset, receiver)` → 回滚 `SweepProtectedToken`<br>2. admin 调 `sweep(posToken, receiver)` → 回滚 `SweepProtectedToken`<br>3. admin 调 `sweep(otherToken, receiver)` → 成功转出 | 仅允许 sweep 非核心资产 |  |  |
|  | gateway / sanctions / vault |  | P1 | `SactionSafeIn` 事件在 shares 路由与 sanctions payout 两种路径下均按当前实现正确记录 | 1. 已支持被制裁用户 shares 路由到 `sanctionSafe`<br>2. 已支持结算时将资产打给 `sanctionSafe` | 1. 构造被制裁用户调用 `gateway.requestRedeem(shares)` / `gateway.redeem(shares)`，触发 shares 路由<br>2. 构造请求创建后用户被制裁，再执行结算，触发 sanctions payout<br>3. 分别检查两条路径发出的 `SactionSafeIn` 事件字段 | 1. 两种路径均发出 `SactionSafeIn`<br>2. 事件参数与各自代码路径中的实际 emit 值一致 |  |  |
|  | controller / vault |  | P0 | redeem in-flight 确认时记录实际 `settledAmount`，而不是强制等于记录值 | 已存在一笔 redeem in-flight，记录 `usdcAmount = X` | 1. 调用 `confirmInFlight(inFlightId, Y, false)`，其中 `Y != X`<br>2. 查询 `inFlightRecord` | `r.settledAmount = Y`；<br>`r.status = CONFIRMED`；<br>说明确认阶段记录的是实际值 |  |  |
|  | controller / vault |  | P0 | redeem in-flight 确认后，统计清账按原记录值 `usdcAmount` 递减 | 已存在一笔 redeem in-flight，记录 `usdcAmount = X` | 1. 调用 `confirmInFlight(inFlightId, Y, false)`<br>2. 查询 `totalRedeemInFlight` 与 `adapterRedeemInFlightUsdc[adapter]` | 两个统计值均按原记录值 `X` 递减，而不是按 `Y` 递减 |  |  |
|  | controller / vault |  | P0 | 实际回款小于记录值时，确认阶段仍可完成，差异在后续结算阶段暴露 | 已存在 redeem in-flight，`usdcAmount = X`；<br>实际回款 `Y < X`；<br>后续 batch 需要支付金额较高 | 1. 调用 `confirmInFlight(inFlightId, Y, false)`<br>2. 执行 `finalizeRedeemBatch(ids, settledAssets)` | 1. confirm 阶段成功并记录 `settledAmount=Y`<br>2. in-flight 统计已按 `X` 清账<br>3. 若 Vault 物理余额不足，则在 `finalizeRedeemBatch / markRequestsDone` 阶段暴露问题 |  |  |
|  | controller / vault |  | P0 | 实际回款大于记录值时，确认阶段记录超额实际值，但统计仍按原记录值清账 | 已存在 redeem in-flight，`usdcAmount = X`；<br>实际回款 `Y > X` | 1. 调用 `confirmInFlight(inFlightId, Y, false)`<br>2. 查询 record 与统计值 | 1. `settledAmount=Y`<br>2. `totalRedeemInFlight` 与 `adapterRedeemInFlightUsdc` 仍按 `X` 递减<br>3. 不因 `Y > X` 自动扩张 in-flight 统计 |  |  |
|  | controller / vault |  | P0 | `confirmInFlight` 不直接校验后续批量付款是否充足 | 已存在 redeem in-flight；<br>Vault 当前真实物理余额不足覆盖后续 `settledAssets` 总和 | 1. 先执行 `confirmInFlight(...)`<br>2. 再执行 `finalizeRedeemBatch(...)` | 1. confirm 阶段本身不因 future payout 不足而失败<br>2. 资金不足在后续 `finalize / markRequestsDone` 时暴露 |  |  |
|  | controller / vault |  | P0 | `finalizeRedeemBatch` 成功与否取决于物理余额，不取决于 redeem in-flight 是否已确认 | 已存在已确认 redeem in-flight；<br>Vault 有 / 无足够物理余额两组场景 | 1. 分别在“物理余额足够”和“物理余额不足”场景下调用 `finalizeRedeemBatch(ids, settledAssets)` | 1. 物理余额足够时 finalize 成功<br>2. 物理余额不足时失败；说明最终付款约束在 `finalize/markRequestsDone` 阶段 |  |  |
|  | controller / vault |  | P1 | `confirmInFlight` 后 request 仍需独立 finalize，不会因为 in-flight 已确认而自动完成 | 已存在 PROCESSING 请求，对应 redeem in-flight 已确认 | 1. 调用 `confirmInFlight(...)`<br>2. 检查 request 状态<br>3. 再调用 `finalizeRedeemBatch(...)` | 1. confirm 后 request 不会自动变 DONE<br>2. 仍需显式执行 `finalize / markRequestsDone` |  |  |
|  | controller / vault |  | P1 | redeem in-flight 确认后，`settledAmount` 与最终 request `settledAssets` 不必天然相等 | 已存在一组请求和对应 redeem in-flight；开发 / 运营可传入 finalize 的 `settledAssets` | 1. 先 `confirmInFlight(inFlightId, Y, false)`<br>2. 再 `finalizeRedeemBatch(ids, settledAssets)`，令某笔 `settledAssets != Y` 对应口径 | 1. in-flight record 中保存的是本次 in-flight 实际值<br>2. request 的最终 `settledAssets` 以 finalize 路径传入值为准<br>3. 两者不是同一个字段，不应混淆 |  |  |
|  | controller / vault |  | P1 | abnormal 路径允许 `actualAmount=0`，但仍按记录值清理 redeem in-flight 统计 | 已存在 pending redeem in-flight，记录 `usdcAmount = X` | 1. 调用 `confirmInFlight(inFlightId, 0, true)` | 1. 调用成功<br>2. `settledAmount = 0`<br>3. `status = CONFIRMED`<br>4. `totalRedeemInFlight` 与 `adapterRedeemInFlightUsdc` 仍按 `X` 递减 |  |  |
|  | controller / vault |  | P1 | 非 abnormal 路径下 `actualAmount=0` 被拒绝 | 已存在 pending redeem in-flight | 1. 调用 `confirmInFlight(inFlightId, 0, false)` | 回滚，抛出 `Vault__ZeroAmount()` |  |  |
|  | controller / vault |  | P1 | 重复确认同一 redeem in-flight 被拒绝 | 某 redeem in-flight 已被确认 | 1. 再次调用 `confirmInFlight(inFlightId, amount, false)` | 回滚，抛出 `Vault__InvalidInFlightState(inFlightId, status)` |  |  |
|  | controller / vault |  | P1 | 未确认或状态非法的 redeem in-flight 不能进入重复结算 | 存在状态不是 PENDING 的 in-flight | 1. 调用 `confirmInFlight(...)` | 回滚，状态机保护生效 |  |  |
|  | controller / vault |  | P1 | 多笔 redeem in-flight 部分确认后，adapter 级别的 in-flight 统计累计变化正确 | 同一 adapter 下存在多笔 redeem in-flight | 1. 依次确认其中部分记录<br>2. 查询 `adapterRedeemInFlightUsdc[adapter]` | adapter 级累计值按每笔记录的 `usdcAmount` 逐笔扣减，剩余值正确 |  |  |
|  | controller / vault |  | P1 | 多 adapter 同时存在 redeem in-flight 时，确认一笔不会影响其他 adapter 的累计值 | adapterA、adapterB 均有 redeem in-flight | 1. 仅确认 adapterA 的某笔 in-flight<br>2. 查询两个 adapter 的统计值 | 只有 adapterA 的累计值减少；adapterB 不受影响 |  |  |
|  | controller / vault |  | P1 | finalize 后用户到账、Vault 扣减、request 状态三者一致 | 已存在 PROCESSING 请求；物理余额足够；<br>redeem in-flight 已确认 | 1. 执行 `finalizeRedeemBatch(ids, settledAssets)` | 1. request 状态变为 DONE<br>2. 用户实际到账等于对应 `settledAssets`<br>3. Vault 物理余额按支付金额扣减 |  |  |

## 业务博弈、汇率波动、抢赎、排队公平性与极端流动性场景

### 汇率波动与用户抢跑场景

| 是否自动化 | 测试合约 | 测试结果 | 优先级 | 测试需求描述 | 前置条件 | 测试步骤 | 期望结果 | 测试执行结果 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
|  | Accountant |  | P0 | 汇率上调前用户抢先存款，验证旧低汇率下获得更多 shares | 1. 当前 `rate = 1.0e18`<br>2. 下一次 Accountant 更新将把汇率上调到 `1.1e18`<br>3. userA、userB 均持有相同数量 USDC | 1. userA 在汇率上调前调用 `gateway.deposit(1100e6)`<br>2. BOT 更新汇率到 `1.1e18`<br>3. userB 在汇率上调后调用 `gateway.deposit(1100e6)`<br>4. 对比双方获得的 shares | 1. userA 因按旧低汇率入场，获得的 shares 多于 userB<br>2. 差值完全符合当前汇率换算逻辑<br>3. 该结果应被记录为系统天然存在的时间窗口特征 |  |  |
|  | Accountant |  | P0 | 汇率下调前用户抢先同步赎回，验证是否把损失留给剩余持有人 | 1. userA、userB 持有相同 shares<br>2. 当前 `rate = 1.1e18`<br>3. 下一次更新将下调到 `1.0e18`<br>4. Vault `freeCash` 足够支持 userA 先同步赎回 | 1. userA 在汇率下调前执行 `gateway.redeem(...)`<br>2. BOT 更新汇率到 `1.0e18`<br>3. 观察 userB 剩余 shares 对应价值 | 1. userA 按旧高汇率拿到更多资产<br>2. userB 持有份额在新汇率下对应价值下降 |  |  |
|  | Accountant |  | P0 | 汇率上调前用户提前同步赎回，验证其是否拿到比更新后更少的资产 | 1. 当前 `rate = 1.0e18`<br>2. 下一次更新将上调到 `1.1e18`<br>3. `freeCash` 充足 | 1. userA 在更新前同步赎回<br>2. 另一用户在更新后按同份额赎回<br>3. 比较到账资产 | 1. 更新前赎回用户到账资产更少<br>2. 差值与汇率变动一致 |  |  |
|  | Accountant |  | P0 | 汇率下调前用户抢先发起异步赎回请求，验证 `estimatedAssets` 与后续 `settledAssets` 关系 | 1. 当前 `rate = 1.1e18`<br>2. 下一次更新将下调到 `1.0e18`<br>3. userA 持有足够 shares | 1. userA 在旧高汇率下调用 `gateway.requestRedeem(...)`<br>2. `processRedeemBatch(ids)` —— 此时 `batchTotalAsset` 按当前（新低）汇率链上计算<br>3. BOT 下调汇率（若在 process 之前则 process 用新汇率；若在之后则 process 已用旧汇率）<br>4. Operator 调用 `finalizeRedeemBatch(ids, settledAssets)` 传入实际结算金额 | 1. 请求创建时 `estimatedAssets` 按旧高汇率计算<br>2. `settledAssets` 由 Operator 显式传入（可等于、小于或大于 `estimatedAssets`）<br>3. 若 `settledAssets < estimatedAssets`：触发 `RequestSettlementAdjusted(id, estimatedAssets, settledAssets)`<br>4. 若 `settledAssets == estimatedAssets`：不触发调整事件<br>5. 测试应分别验证 Operator 传入不同 `settledAssets` 的行为差异 |  |  |
|  | Accountant |  | P0 | 汇率上调前用户发起异步赎回请求，验证 `settledAssets` 与 `estimatedAssets` 关系 | 1. 当前 `rate = 1.0e18`<br>2. 下一次更新将上调到 `1.1e18` | 1. userA 发起异步赎回<br>2. `processRedeemBatch(ids)` 进入处理中<br>3. BOT 上调汇率<br>4. Operator 调用 `finalizeRedeemBatch(ids, settledAssets)` 传入实际结算金额 | 1. `estimatedAssets` 按旧汇率记录<br>2. `settledAssets` 由 Operator 显式传入（可等于、大于或小于 `estimatedAssets`）<br>3. 若 `settledAssets > estimatedAssets`：触发 `RequestSettlementAdjusted(id, estimatedAssets, settledAssets)`<br>4. 若 `settledAssets == estimatedAssets`：不触发调整事件<br>5. 测试应分别验证 Operator 传入不同 `settledAssets` 的行为差异 |  |  |
|  | Accountant |  | P0 | `deposit -> updateExchangeRate` 与 `updateExchangeRate -> deposit` 顺序颠倒时结果不同 | 1. 两名用户持有相同 USDC<br>2. 存在一次明确汇率更新 | 1. 场景 A：userA 先存款，再更新汇率<br>2. 场景 B：先更新汇率，userB 再存款<br>3. 对比两人获得 shares | 1. 两名用户获得的 shares 不同<br>2. 差值与顺序和汇率变化严格一致 |  |  |
|  | Accountant |  | P0 | `redeem -> updateExchangeRate` 与 `updateExchangeRate -> redeem` 顺序颠倒时结果不同 | 1. 两名用户持有相同 shares<br>2. 存在一次汇率更新 | 1. 场景 A：userA 先赎回，再更新汇率<br>2. 场景 B：先更新汇率，userB 再赎回<br>3. 对比到账资产 | 1. 两名用户到账资产不同<br>2. 差值符合新旧汇率差异 |  |  |
|  | Accountant |  | P1 | Accountant 长时间未更新汇率时，用户按 stale rate 连续存款的风险暴露 | 1. Accountant 长时间未更新<br>2. 实际市场价格已显著变化，但链上 rate 仍旧值 | 1. 多个用户按旧汇率连续存款<br>2. 随后一次性更新汇率 | 1. 存量用户和后续用户份额价值出现明显差异<br>2. 测试记录 stale rate 带来的公平性风险 |  |  |
|  | Accountant |  | P1 | Accountant 长时间未更新汇率时，用户按 stale rate 连续赎回的风险暴露 | 1. Accountant 长时间未更新<br>2. 实际市场价格已显著变化 | 1. 多个用户按旧汇率连续同步或异步赎回<br>2. 随后更新汇率 | 1. 先操作用户可能占优或吃亏<br>2. 需验证系统不会破坏账本一致性 |  |  |
|  | Accountant |  | P1 | 管理费结算与汇率更新同笔发生时，对前后用户的份额价值影响 | 1. 存在待结管理费<br>2. 将触发一次 `updateExchangeRate` | 1. userA 在更新前存 / 赎<br>2. 调用 `updateExchangeRate()` 完成结费与更新汇率<br>3. userB 在更新后存 / 赎 | 1. 前后用户结果不同<br>2. 差异同时包含汇率变化和 fee shares 稀释效应 |  |  |
|  | Accountant |  | P1 | 汇率上调前抢存后立即异步赎回，验证短周期套利闭环 | 1. 当前 `rate = 1.0e18`<br>2. 即将上调到 `1.1e18`<br>3. 存款和请求赎回都允许 | 1. userA 在旧汇率下存款<br>2. 汇率上调<br>3. userA 立即发起异步赎回<br>4. 后续结算 | 1. userA 因抢在低汇率下拿到更多 shares，后续可能兑现更高资产<br>2. 应明确记录是否存在显著短周期套利空间 |  |  |
|  | Accountant |  | P1 | 汇率下调前抢赎失败改走异步赎回，比较同步失败与异步排队后的经济结果 | 1. 当前 `rate` 偏高<br>2. `freeCash` 不足以让后手同步退出 | 1. userA 先同步赎回成功<br>2. userB 同步赎回失败<br>3. userB 改走异步赎回<br>4. 之后汇率下调并结算 | 1. userB 的异步结算结果可能显著劣于 userA<br>2. 体现先来先得与价格时序双重影响 |  |  |
|  | Accountant |  | P1 | 超限汇率更新触发 circuit breaker 后，用户写入口统一被阻断 | 1. 当前汇率存在一次超限更新提案<br>2. Gateway / Accountant / Vault 已联通 | 1. BOT 提交一次超出 `maxAllowedDeviation` 的 `updateExchangeRate(...)`<br>2. 用户分别调用 `gateway.deposit(...)`、`gateway.redeem(...)`、`gateway.requestRedeem(...)` | 1. Accountant 进入 pause 并保持旧汇率<br>2. 三个 Gateway 写入口均进入暂停语义并回滚 |  |  |
|  | Accountant |  | P1 | circuit breaker 触发后 admin 用 `emergencyRateUpdate` 修正汇率并恢复业务 | 1. Accountant 已因超限更新进入 pause<br>2. admin 拥有修正权限 | 1. admin 调用 `emergencyRateUpdate(correctedRate)`<br>2. 用户再次尝试 `gateway.deposit(...)` 或 `gateway.redeem(...)` | 1. Accountant 成功更新为修正汇率并解除 pause<br>2. Gateway 写入口恢复可用 |  |  |
|  | Accountant |  | P1 | 运营 BOT 发起超限更新时，`RateUpdateExecuted` 与实际未更新汇率并存 | 1. 真实 AccountantExecutor -> Accountant 链路已接通<br>2. 偏差超限 | 1. BOT 调用 `executeUpdateRate(accountant, badRate, computeTs)`<br>2. 检查事件与 Accountant 状态 | 1. Executor 侧可 emit `RateUpdateExecuted`<br>2. Accountant 侧 emit `CircuitBreakerTriggered`<br>3. `lastExchangeRate` 仍为旧值，避免把 relay 成功误判为汇率已更新 |  |  |

### 同步赎回抢兑与先来先得场景

| 是否自动化 | 测试合约 | 测试结果 | 优先级 | 测试需求描述 | 前置条件 | 测试步骤 | 期望结果 | 测试执行结果 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
|  | gateway / vault |  | P0 | 两个用户同时同步赎回，`freeCash` 仅够一人，验证先来先得 | 1. userA、userB 持有相同 shares<br>2. `freeCash` 仅够一人全额赎回 | 1. userA 先调用 `gateway.redeem(...)`<br>2. userB 再调用 `gateway.redeem(...)` | 1. userA 成功<br>2. userB 失败，命中 `maxRedeem/freeCash` 限制 |  |  |
|  | gateway / vault |  | P0 | 大户先赎导致小户后续同步赎回失败 | 1. whale 与 retail 均持有 shares<br>2. `freeCash` 总量有限 | 1. whale 先赎回大额 shares<br>2. retail 再赎回小额 shares | 1. whale 成功抽走大部分 `freeCash`<br>2. retail 即使金额较小也可能失败 |  |  |
|  | gateway / vault |  | P1 | 小户先赎、大户后赎时，验证剩余 `freeCash` 分布结果 | 1. `freeCash` 有限<br>2. retail 金额小于 whale | 1. retail 先赎回<br>2. whale 后赎回 | 1. retail 成功<br>2. whale 可能部分不可赎或全部失败 |  |  |
|  | gateway / vault |  | P0 | 连续同步赎回会逐步压缩 `maxRedeem/maxWithdraw` | 多个用户持有 shares 且 `freeCash` 有限 | 1. 用户逐个执行同步赎回<br>2. 每次后查询下一用户的 `maxRedeem/maxWithdraw` | 每次成功赎回后，后续用户可同步退出额度下降 |  |  |
|  | gateway / vault |  | P0 | 前序同步赎回抽干 `freeCash` 后，后续用户只能转异步赎回 | 1. 多个用户持有 shares<br>2. `freeCash` 会被前序交易耗尽 | 1. 前几名用户同步赎回成功<br>2. 后续用户尝试同步赎回失败<br>3. 后续用户改发异步赎回请求 | 1. 同步赎回失败<br>2. 异步赎回请求仍可创建 |  |  |
|  | gateway / vault |  | P1 | 多用户在同一轮市场恐慌中同时发起同步赎回与异步赎回，系统账本保持一致 | 1. 部分用户将走同步，部分走异步 | 1. 混合执行多个同步赎回和异步请求<br>2. 检查 `totalSupply`、`totalLockedShares`、`physicalBalance`、`pendingShares` | 所有账本字段保持自洽，无重复扣减或重复支付 |  |  |
|  | gateway / vault |  | P1 | 同一用户先同步赎回部分份额，再异步赎回剩余份额，验证口径一致 | 同一用户持有足够 shares，`freeCash` 仅覆盖部分份额 | 1. 先同步赎回一部分<br>2. 再对剩余 shares 发起异步赎回 | 1. 两条路径均成功<br>2. 用户总 shares 扣减正确<br>3. locked 和实际到账金额均正确 |  |  |
|  | gateway / vault |  | P1 | 大户连续多笔小额同步赎回是否能分批抽干 `freeCash` | whale 持有大额 shares，`freeCash` 有限 | 1. whale 连续发起多笔小额同步赎回<br>2. 观察后续用户可赎额度 | 1. 多笔交易累积后可逐渐耗尽 `freeCash`<br>2. 后续用户 `maxRedeem/maxWithdraw` 持续下降 |  |  |

### 异步赎回排队、公平性与选择性处理场景

| 是否自动化 | 测试合约 | 测试结果 | 优先级 | 测试需求描述 | 前置条件 | 测试步骤 | 期望结果 | 测试执行结果 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
|  | gateway / controller |  | P0 | 先创建的异步请求应具有更早的 `requestId` | 多个用户依次创建异步请求 | 1. userA 创建请求<br>2. userB 创建请求<br>3. 比较 `requestId` | `userA.requestId < userB.requestId` |  |  |
|  | gateway / controller |  | P0 | 运营方可只选择后创建请求进入批次，验证系统是否允许“插队处理” | 存在早晚两批 PENDING 请求 | 1. 跳过早期 `requestId`<br>2. 仅将后期 `requestId` 放入 `processRedeemBatch` | 当前实现若允许，则后创建请求可先进入 PROCESSING；该结果需记录为治理 / 运营公平性风险 |  |  |
|  | gateway / controller / vault |  | P0 | 同一批次内按 `ids` 顺序结算，验证事件和状态顺序 | 一批 requests 均已进入 PROCESSING | 1. 调用 `markRequestsDone(ids, settledAssets)` | 1. 状态更新与事件顺序与 `ids` 顺序一致<br>2. 账本更新正确 |  |  |
|  | gateway / controller / vault |  | P0 | 批次资金不足时，不允许只结算前半批而静默跳过后半批 | 1. 一批 requests 已 PROCESSING<br>2. 物理余额不足以覆盖整批 | 1. 调用 `markRequestsDone(ids, settledAssets)` | 1. 整批回滚<br>2. 不应出现部分成功、部分失败的静默结算 |  |  |
|  | gateway / controller / vault |  | P1 | 早批次和晚批次在汇率变化下的最终到账差异被显式验证 | 1. 两批请求分时创建<br>2. 中间发生汇率变化 | 1. 先结算早批次<br>2. 后结算晚批次<br>3. 比较同等 shares 的到账结果 | 1. 不同批次可能因市场变化而得到不同 `settledAssets`<br>2. 差异应可解释且被记录 |  |  |
|  | gateway / controller / vault |  | P1 | 请求长期停留在 PENDING 时，对用户余额和自由现金影响稳定 | 创建请求后长期不处理 | 1. 创建请求<br>2. 长时间不推进状态<br>3. 观察 shares、locked、`freeCash`、`totalAssets` | 1. 用户 shares 已烧毁<br>2. locked 负债持续存在<br>3. 系统不应出现状态漂移 |  |  |
|  | gateway / controller / vault |  | P1 | 请求长期停留在 PROCESSING 时，对后续同步赎回用户构成持续挤压 | 某大额请求已进入 PROCESSING 但尚未结算 | 1. 将请求推进到 PROCESSING<br>2. 其他用户尝试同步赎回 | 因 locked 负债存在，其他用户可同步退出额度下降 |  |  |
|  | gateway / controller / vault |  | P1 | 运营方分批处理请求时，不同批次的 `_pendingShares` 和 `totalLockedShares` 递减正确 | owner 存在多笔请求分批结算 | 1. 仅结算部分请求<br>2. 再结算剩余请求 | 每次仅减少对应部分，最终全部结清后归零 |  |  |
|  | gateway / controller / vault |  | P1 | 同一 owner 多笔请求跨多个批次结算，验证到账合计与每笔 `settledAssets` 之和一致 | owner 多笔请求分散在不同批次 | 1. 创建多笔请求<br>2. 分多批次结算 | 1. owner 累计到账 = 各 request `settledAssets` 之和<br>2. 不应重复或漏付 |  |  |
|  | gateway / controller / vault |  | P1 | 后来的小额请求被优先处理而早期大额请求滞留，验证系统状态稳定 | 早期存在大额请求，后续存在小额请求 | 1. 先处理后来的小额请求<br>2. 保留早期大额请求未处理 | 1. 小额请求可先完成<br>2. 大额请求继续停留<br>3. 总账本依然自洽 |  |  |

### 赎回费率调整对排队用户和新老用户的影响场景

| 是否自动化 | 测试合约 | 测试结果 | 优先级 | 测试需求描述 | 前置条件 | 测试步骤 | 期望结果 | 测试执行结果 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
|  | gateway / vault |  | P0 | 用户提交异步赎回请求后，管理员上调 redemption fee，验证老请求估算值冻结且不会自动按新 fee 重算 | 1. 用户已创建异步请求<br>2. 请求创建时已记录 `estimatedAssets`<br>3. 当前存在 locked shares | 1. 记录请求创建时的 `estimatedAssets`<br>2. admin 上调 `redemptionFeeBps`<br>3. 再读取该请求数据<br>4. 推进该请求后续结算 | 1. 已创建请求的 `estimatedAssets` 保持不变<br>2. 老请求不会仅因 fee 上调而自动按新 fee 重算<br>3. 最终 `settledAssets` 是否偏离原估算，取决于后续 `finalize /` 结算传入值，而不是 fee 自动重算 |  |  |
|  | gateway / vault |  | P0 | 用户提交异步赎回请求后，管理员下调 redemption fee，验证老请求不会自动按新 fee 提高估算值 | 1. 用户已创建异步请求<br>2. 请求创建时已按旧 fee 记录 `estimatedAssets` | 1. 记录原 `estimatedAssets`<br>2. admin 下调 `redemptionFeeBps`<br>3. 再读取请求数据并结算 | 1. 已记录的 `estimatedAssets` 不变<br>2. 老请求不会仅因 fee 下调而自动提高 `settledAssets` 或 `estimatedAssets`<br>3. 新 fee 只影响后续新口径，不自动回写老请求 |  |  |
|  | gateway / vault |  | P1 | 同一时刻新老请求在 fee 变更前后创建，验证两批用户估算值差异 | 1. 老请求在旧 fee 下创建<br>2. 管理员修改 fee<br>3. 新请求在新 fee 下创建 | 1. 创建老请求<br>2. 修改 fee<br>3. 创建新请求<br>4. 比较两笔请求的 `estimatedAssets` | 1. 两批请求的 `estimatedAssets` 不同<br>2. 差异符合 fee 变化后的新旧计价口径 |  |  |
|  | gateway / vault |  | P1 | fee 变更后，同步赎回、老异步请求与新异步请求三种路径结果口径不同 | 1. 同时存在已排队老请求与待操作用户<br>2. admin 修改 fee | 1. 记录老请求 `estimatedAssets`<br>2. admin 调整 fee<br>3. 一名用户执行同步赎回<br>4. 另一名用户新建异步请求<br>5. 对比三种路径的结果 | 1. 同步赎回与新异步请求按当前 fee 计算<br>2. 老异步请求保留创建时的 `estimatedAssets`<br>3. 三种路径的结果差异应可解释，且符合各自口径 |  |  |
|  | gateway / vault |  | P1 | `maxRedemptionFeeBps` 下调导致当前 fee 自动收敛时，验证新口径变化但老请求不自动重算 | 1. 当前 fee 高于新 max<br>2. 存在 pending / processing 请求 | 1. admin 调 `setMaxRedemptionFee(newMax)`<br>2. 检查当前 fee 是否自动收敛<br>3. 查询新请求和老请求口径 | 1. 当前 fee 自动收敛到新 max<br>2. 新请求 / 新同步赎回按新 fee 口径计算<br>3. 已创建请求的 `estimatedAssets` 不自动重算 |  |  |
|  | gateway / vault |  | P0 | 同步赎回 / 异步赎回产生的 redemption fee 直接转给 treasury，而不是留在 Vault 内部 | 1. treasury 已配置<br>2. 用户持有可同步赎回的 shares<br>3. 当前 `redemptionFeeBps > 0` | 1. 记录赎回前 Vault 资产余额、treasury 资产余额、用户资产余额<br>2. 用户执行同步赎回 / 异步赎回<br>3. 比较赎回后的三方余额变化 | 1. 用户实际到账为扣费后的净额<br>2. fee 对应资产直接转入 treasury，并有对应事件<br>3. fee 不应以“留存在 Vault 中”的方式体现 |  |  |
|  | gateway / vault |  | P1 | fee 上调后，相关 view 的变化应与“新 fee 口径 + fee 转 treasury”的真实资产流动一致 | 1. 已存在 locked shares<br>2. 当前 fee 可调整 | 1. admin 上调 fee<br>2. 查询 `previewRedeem(totalLockedShares)`、`getFreeCash()`、`maxRedeem()`、`maxWithdraw()`<br>3. 如有赎回，再观察 treasury / Vault 余额变化 | 1. `previewRedeem(totalLockedShares)` 按新 fee 口径变化<br>2. `getFreeCash/maxRedeem/maxWithdraw` 的变化应与当前公式和实际资产流向一致<br>3. 不应再简单假设“fee 上调必然让 Vault 更宽松”，而应以新逻辑实际结果为准 |  |  |
|  | gateway / vault |  | P1 | fee 下调后，相关 view 的变化应与“新 fee 口径 + fee 转 treasury”的真实资产流动一致 | 1. 已存在 locked shares<br>2. 当前 fee 可调整 | 1. admin 下调 fee<br>2. 查询 `previewRedeem(totalLockedShares)`、`getFreeCash()`、`maxRedeem()`、`maxWithdraw()` | 1. `previewRedeem(totalLockedShares)` 按新 fee 口径变化<br>2. `getFreeCash/maxRedeem/maxWithdraw` 的变化应与当前公式和真实资金流一致<br>3. 不应只用“locked liabilities 变化”单独解释全部结果 |  |  |
|  | gateway / vault |  | P1 | fee 为 0 时，异步 / 同步赎回不再产生 treasury 收费 | 1. 当前 `redemptionFeeBps > 0`<br>2. 用户持有可赎回 shares | 1. admin 调 `setRedemptionFee(0)`<br>2. 记录赎回前 treasury 余额<br>3. 用户执行异步 / 同步赎回 | 1. 用户按无 fee 口径到账<br>2. treasury 余额不因该次赎回增加 |  |  |
|  | gateway / vault |  | P1 | fee 上调不会改变已锁定 shares 数量，只改变其对应的预估资产口径 | 1. 已存在异步赎回请求<br>2. `totalLockedShares > 0` | 1. 记录 fee 调整前 `totalLockedShares` 与 `previewRedeem(totalLockedShares)`<br>2. admin 上调 fee<br>3. 再次读取同两项 | 1. `totalLockedShares` 本身不变<br>2. 变化的是 `previewRedeem(totalLockedShares)` 对应的资产口径 |  |  |
|  | gateway / vault |  | P1 | fee 下调不会改变已锁定 shares 数量，只改变其对应的预估资产口径 | 1. 已存在异步赎回请求<br>2. `totalLockedShares > 0` | 1. 记录 fee 调整前 `totalLockedShares` 与 `previewRedeem(totalLockedShares)`<br>2. admin 下调 fee<br>3. 再次读取同两项 | 1. `totalLockedShares` 本身不变<br>2. 变化的是 `previewRedeem(totalLockedShares)` 对应的资产口径 |  |  |
|  | gateway / vault |  | P1 | 老请求在 fee 变更后结算时，若 `settledAssets != estimatedAssets`，差异应通过结算机制透明体现 | 1. 已存在老异步请求<br>2. 中间发生 fee 变更<br>3. 后续实际结算值与旧估算存在差异 | 1. 记录老请求 `estimatedAssets`<br>2. 修改 fee<br>3. `finalize /` 结算时传入不同的 `settledAssets` | 1. 老请求不会自动重算 `estimatedAssets`<br>2. 差异应通过既有结算机制和事件透明体现<br>3. 系统不应因 fee 变更 + 结算差异而死锁 |  |  |

### 会计更新、用户操作与结费交错场景

| 是否自动化 | 测试合约 | 测试结果 | 优先级 | 测试需求描述 | 前置条件 | 测试步骤 | 期望结果 | 测试执行结果 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
|  | accountant / gateway |  | P0 | `deposit -> updateExchangeRate -> redeem` 与 `updateExchangeRate -> deposit -> redeem` 的最终赎回结果不同 | 存在一次明确汇率变化 | 1. 场景 A 按顺序执行<br>2. 场景 B 按反向顺序执行<br>3. 比较同等初始资金的最终资产 | 1. 两种顺序下用户获得的 shares 不同<br>2. 最终赎回拿回的资产不同<br>3. 差异与汇率变化时点一致 |  |  |
|  | accountant / gateway |  | P0 | `requestRedeem -> updateExchangeRate -> finalize` 与 `updateExchangeRate -> requestRedeem -> finalize` 对异步赎回估值口径的影响不同 | 存在一次汇率变化 | 1. 场景 A 先请求后更新<br>2. 场景 B 先更新后请求<br>3. 最终分别结算 | 1. 两种顺序下 `estimatedAssets` 不同，因为其在 request 创建时按当时汇率记录<br>2. `settledAssets` 由 finalize 显式传入，不会仅因汇率变化自动重算<br>3. 若两场景最终 `settledAssets` 不同，应能用各自 finalize 传入值与处理时点解释 |  |  |
|  | accountant / gateway |  | P1 | 自动管理费结算先于汇率写入，验证用户在更新前后操作的差异 | 将触发 fee settle | 1. 用户在更新前操作<br>2. `updateExchangeRate()` 自动结费<br>3. 用户在更新后操作 | 结果差异应包含 fee shares 铸造带来的稀释效应 |  |  |
|  | accountant / gateway |  | P1 | `processRedeemBatch` 前后插入一次 `rebalance`，验证筹资路径差异 | 1. 存在待处理 batch<br>2. 策略仓位可调度 | 1. 场景 A 先 `rebalance` 再 `processRedeemBatch`<br>2. 场景 B 直接 `processRedeemBatch` | 不同顺序下 divest 路径、in-flight 数量、剩余 `freeCash` 可能不同 |  |  |
|  | accountant / gateway |  | P1 | 汇率更新未成功生效时，用户不应读到半完成状态 | 分别构造一次 revert 型更新失败与一次 circuit breaker 触发 | 1. 构造 `cooldown / timestamp` 非法导致 `updateExchangeRate()` revert<br>2. 构造偏差超限导致触发 circuit breaker<br>3. 分别检查用户查询与 Gateway 写入口 | 1. revert 型失败下，rate / fee settle / 时间戳均保持不变<br>2. circuit breaker 下，旧 rate 保持不变，但 Accountant 进入 pause<br>3. 用户不会读到“部分写入的新汇率状态” |  |  |
|  | accountant / gateway / controller |  | P1 | 更新汇率前后分别 `processRedeemBatch`，比较链上计算的 `batchTotalAsset` 差异 | 有两批待处理请求，中间插入一次汇率变化 | 1. `processRedeemBatch(ids1)` 处理第一批（按旧汇率计算 `batchTotalAsset`）<br>2. 更新汇率<br>3. `processRedeemBatch(ids2)` 处理第二批（按新汇率计算 `batchTotalAsset`） | 1. 两批事件中的 `batchTotalAsset` 不同（因链上使用当前 `exchangeRate` 计算）<br>2. 体现汇率变化对赎回资产筹措压力的影响<br>3. 后续 `finalizeRedeemBatch` 时 Operator 可分别传入不同 `settledAssets` |  |  |
|  | accountant |  | P1 | 自动结费导致 treasury 获得新 shares 后，再次赎回会改变剩余用户占比 | treasury 在更新后持有新增 shares | 1. 触发一次结费<br>2. 由 treasury 或其他用户赎回<br>3. 比较结费前后占比 | 1. share 分布变化正确<br>2. 不破坏整体账本一致性 |  |  |
|  | accountant / gateway |  | P1 | `circuit breaker -> emergencyRateUpdate -> 用户恢复操作` 的顺序链路正确 | 1. 先发生一次超限汇率更新<br>2. Accountant 已进入 pause | 1. BOT 提交超限更新触发 circuit breaker<br>2. 用户尝试 Gateway 写操作并失败<br>3. admin 调用 `emergencyRateUpdate(newRate)`<br>4. 用户再次操作 | 1. circuit breaker 后旧汇率保持不变，Gateway 写入口暂停<br>2. `emergencyRateUpdate` 成功更新汇率并解除 Accountant pause<br>3. 用户写入口恢复可用 |  |  |

### 极端流动性压力与挤兑场景

| 是否自动化 | 测试合约 | 测试结果 | 优先级 | 测试需求描述 | 前置条件 | 测试步骤 | 期望结果 | 测试执行结果 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
|  | Vault |  | P0 | 全部 `freeCash` 被 locked shares 吃满时，所有同步赎回都应失败 | 1. Vault `physicalBalance > 0`<br>2. `previewRedeem(totalLockedShares) >= physicalBalance` | 1. 多名用户尝试同步赎回 | 全部失败，`getFreeCash() = 0` |  |  |
|  | Vault / gateway |  | P0 | `freeCash` 为 0 时，异步赎回仍可继续排队 | `getFreeCash() = 0` | 1. 用户调用 `gateway.requestRedeem(...)` | 请求仍可创建，进入异步队列 |  |  |
|  | controller / vault |  | P0 | 异步策略回款延迟导致 batch 长时间无法 finalize | 1. 请求已 PROCESSING<br>2. redeem in-flight 未完成 | 1. 尝试 `finalizeRedeemBatch(ids, settledAssets)` | 若 `asset.balanceOf(vault) < sum(settledAssets)`，则 revert `InsufficientCashForReady`；请求继续停留在处理中 |  |  |
|  | controller / vault |  | P0 | 新用户在旧请求积压期间继续存款，验证其资金是否被旧赎回优先消耗 | 1. 存在大量 locked requests<br>2. 新用户仍可存款 | 1. 新用户存款<br>2. 推进旧请求 finalize | 新存入资金会进入 Vault 物理余额，并可能被旧请求结算优先消耗 |  |  |
|  | controller / vault |  | P1 | redeem in-flight 确认阶段记录本次 settle 传入的实际值，并按原记录值清理 in-flight 统计；最终付款能力在 finalize 阶段校验 | 1. 已存在一笔 pending redeem in-flight，记录 `usdcAmount = X`<br>2. 本次 `settleAdapter` 传入对应 `redeemSettledAmounts = [Y]`<br>3. sweep 实际到账量与 Y 一致，因此 settle 可成功继续<br>4. Vault 后续用于支付 request 的物理余额可能不足 | 1. 执行 `settleAdapter(adapter, [], [], [redeemId], [Y])`<br>2. 检查该笔 in-flight 的 `settledAmount`、`totalRedeemInFlight`、`adapterRedeemInFlightUsdc` 变化<br>3. 再执行 `finalizeRedeemBatch(ids, settledAssets)` | 1. `confirmInFlight` 后，该笔 in-flight 的 `settledAmount = Y`，即记录的是本次 settle 传入值<br>2. `totalRedeemInFlight` 与 `adapterRedeemInFlightUsdc` 按原 in-flight 记录值 X 递减，而不是按 Y 递减<br>3. redeem in-flight 确认成功并不等于 request 已可付款<br>4. 若 Vault 真实物理余额不足覆盖 `settledAssets`，问题会在 `finalizeRedeemBatch / markRequestsDone` 阶段暴露 |  |  |
|  | vault / gateway |  | P1 | 多重压力同时发生时，核心 view 结果仍应可解释且不出现脏状态 | 1. Vault 持有一定物理 USDC<br>2. 已配置多个 adapter<br>3. 已存在部分 locked shares 与 redeem in-flight | 1. 同时下调多个 adapter 的 `totalValue()`<br>2. 通过新增异步赎回请求提高 `totalLockedShares`<br>3. 保留或新增 redeem in-flight，提高 `totalRedeemInFlight`<br>4. 查询 `totalAssets()`、`getFreeCash()`、`maxRedeem()`、`maxWithdraw()` | 1. 各 view 返回值应与当前资产、`totalLockedShares` 和 in-flight 口径一致<br>2. `totalAssets()` 因策略估值下降而下降，必要时返回 0<br>3. `getFreeCash()` 因 `totalLockedShares` 上升而下降，必要时返回 0<br>4. `maxRedeem/maxWithdraw` 随 `freeCash` 压缩而下降<br>5. 不出现 underflow、异常大值或前后不一致的脏状态 |  |  |
|  | vault / gateway |  | P1 | 多用户挤兑下，系统总支付不超过物理余额与结算口径上限 | 多用户同步 / 异步混合退出 | 1. 执行一系列退出<br>2. 汇总所有实际支付额与剩余余额 | 不发生超付，不出现负债账本异常 |  |  |
|  | vault |  | P1 | USDC 物理余额极低但 `totalRedeemInFlight` 很高时，验证 `totalAssets` 与实际可支付能力分离 | 1. physical USDC 很低<br>2. redeem in-flight 账面值很高 | 1. 查询 `totalAssets`、`getFreeCash`、`maxRedeem`<br>2. 尝试真实赎回 | 1. `totalAssets` 可能仍较高<br>2. 但同步赎回能力依然很弱，体现账面资产与即时流动性分离 |  |  |
|  | gateway / vault / adapter / controller |  | P1 | 多个 async adapter 同时未回款时，批量请求积压不应破坏后续存款流程 | 多个 adapter 上存在 redeem in-flight | 1. 用户继续存款<br>2. 查询关键账本<br>3. 再尝试 finalize | 1. 存款仍可按当前规则执行<br>2. 请求积压不应导致账本错乱 |  |  |
|  | gateway / vault / controller |  | P1 | 统一资金池模式下，新进入 Vault 的资金可优先用于履约旧的异步赎回请求 | 1. 存在一批待结算异步赎回请求<br>2. Vault 当前物理余额不足<br>3. 新用户仍可继续存款 | 1. 保持旧请求处于 PROCESSING<br>2. 新用户向 Vault 存入资金<br>3. 推进旧请求 `finalizeRedeemBatch(...)`<br>4. 观察新资金去向 | 1. 新进入统一资金池的 USDC 可被旧请求优先消耗<br>2. 该行为应被记录为统一资金池 / 母基金模式的设计结果<br>3. 不应误判为资金错配 bug |  |  |
|  | gateway / vault / controller |  | P1 | 异步赎回队列长时间处于 PENDING / PROCESSING 时，系统应保持账本稳定并在流动性恢复后继续推进 | 1. 存在多笔 PENDING / PROCESSING 请求<br>2. 底层回款存在较长等待周期<br>3. 期间系统仍可能有新存款、新汇率更新 | 1. 创建并积压多笔请求<br>2. 在等待期间反复查询 `totalLockedShares / totalRedeemInFlight / pendingShares / totalAssets / getFreeCash`<br>3. 流动性恢复后重新 process / finalize | 1. 长时间等待本身不破坏账本一致性<br>2. 关键账本字段保持自洽<br>3. 资金恢复后系统可继续推进，不会进入永久死锁 |  |  |

### 黑名单与市场事件交错场景

| 是否自动化 | 测试合约 | 测试结果 | 优先级 | 测试需求描述 | 前置条件 | 测试步骤 | 期望结果 | 测试执行结果 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
|  | gateway / sanctions |  | P0 | 用户在被拉黑前同步赎回成功，被拉黑后再操作失败 | 1. 用户初始未被制裁<br>2. 后续会被拉黑 | 1. 先同步赎回一次<br>2. 更新 sanctions<br>3. 再次尝试 `deposit/redeem/requestRedeem` | 1. 拉黑前操作成功<br>2. 拉黑后被 Gateway 拦截，异步 / 同步赎回会触发路由场景 |  |  |
|  | gateway / sanctions / controller |  | P0 | 用户在被拉黑前创建异步请求，结算时已被拉黑，最终打到 `sanctionSafe` | 1. 创建请求时未被制裁<br>2. finalize 前被制裁 | 1. 创建异步请求<br>2. 推进到 PROCESSING<br>3. 拉黑 owner<br>4. finalize | 结算资产打到 `sanctionSafe` |  |  |
|  | gateway / sanctions / controller |  | P1 | 同一批次中部分用户正常结算、部分用户因结算前被拉黑而打到 `sanctionSafe` | 一批 requests 中多个 owner 状态不同 | 1. 创建多笔请求<br>2. 部分 owner 拉黑<br>3. 批量结算 | 同批次内按每个 owner 的当前 sanctions 状态分别处理 |  |  |
|  | gateway / sanctions / controller |  | P1 | 大额市场波动期间，sanctions 更新与用户退出操作交错，系统状态保持一致 | 存在市场波动和大额退出 | 1. 用户存 / 赎 / 排队<br>2. 中间更新 sanctions<br>3. 再执行结算 | 账本、事件、接收地址均与当时 sanctions 状态一致 |  |  |
|  | gateway / sanctions / controller |  | P1 | 被拉黑用户的 shares 被路由到 `sanctionSafe` 后，`sanctionSafe` 再参与后续赎回流程的行为正确 | `sanctionSafe` 已收到 shares | 1. `sanctionSafe` 对收到的 shares 再执行同步或异步赎回 | 1. `sanctionSafe` 作为普通持有人路径可继续操作（若未被制裁）<br>2. 账本更新正确 |  |  |
|  | gateway / sanctions |  | P1 | 白名单 + 制裁双重检查的优先级验证 | 1. `whitelistEnabled=true`<br>2. userA 同时被制裁且不在白名单中 | 1. userA 调用 `gateway.deposit(1000e6)` | 1. 制裁检查先于白名单检查（代码中 `_requireNotSanctioned` 在 `_requireWhitelisted` 之前）<br>2. 回滚，抛出 `Vault__Sanctioned(userA)` 而非 `Gateway__NotWhitelisted` |  |  |
|  | gateway / sanctions |  | P1 | 白名单开启时被制裁用户发起 `requestRedeem` 仍走路由路径 | 1. `whitelistEnabled=true`<br>2. userA 被制裁但不在白名单中 | 1. userA 调用 `gateway.requestRedeem(shares)` | 1. 制裁路由分支先于白名单检查执行（`isSanctioned` 判断在 `_requireWhitelisted` 之前）<br>2. 被制裁分支生效，shares 转入 `sanctionSafe`，返回 `requestId=0`（不触发白名单 revert） |  |  |
|  | gateway / sanctions |  | P1 | 正常用户、请求前已被制裁用户、请求后被制裁用户在赎回流程中应走不同路径 | 1. 准备 3 类用户：正常 / 请求前已制裁 / 请求后被制裁<br>2. `sanctionSafe` 已配置可用 | 1. 正常用户发起并完成赎回<br>2. 已制裁用户发起 `requestRedeem`<br>3. 第三类用户先创建请求，再在 finalize 前被制裁<br>4. 比较三类路径的资产与 shares 流向 | 1. 正常用户走正常结算路径<br>2. 请求前已制裁用户走 shares 路由到 `sanctionSafe`<br>3. 请求后被制裁用户走 USDC 打款到 `sanctionSafe`<br>4. 三条路径应在业务文档中被清晰区分 |  |  |

### 运营选择性执行与治理风险场景

| 是否自动化 | 测试合约 | 测试结果 | 优先级 | 测试需求描述 | 前置条件 | 测试步骤 | 期望结果 | 测试执行结果 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
|  | Operator / gateway |  | P0 | Operator 只处理部分用户请求，验证系统是否允许选择性推进 | 1. userA、userB、userC 已分别创建异步赎回请求<br>2. 三笔请求状态均为 PENDING<br>3. 三笔请求的 `requestId` 已知，且按创建顺序递增 | 1. 记录三笔请求的 `requestId` 与初始状态<br>2. Operator 仅选择其中一部分 `requestId`（例如 userB、userC）调用 `processRedeemBatch(ids)`<br>3. 查询所有请求状态 | 1. 被选中的请求进入 PROCESSING<br>2. 未被选中的请求仍保持 PENDING<br>3. 系统允许“只推进部分请求”这一行为<br>4. 该结果应被记录为运营侧存在选择性处理空间的治理 / 公平性风险 |  |  |
|  | Operator / gateway |  | P1 | 先处理后创建的 batch，再处理早期 batch，验证系统账本是否仍一致 | 1. 先由 userA、userB 创建第一批异步赎回请求（早批次）<br>2. 再由 userC、userD 创建第二批异步赎回请求（晚批次）<br>3. 两批请求均处于 PENDING | 1. 记录两批请求的 `requestId`、owner、shares、`estimatedAssets`<br>2. 先对晚批次调用 `processRedeemBatch(lateIds)`<br>3. 再对早批次调用 `processRedeemBatch(earlyIds)`<br>4. 按两批次分别 finalize / 结算<br>5. 检查每笔请求最终状态、到账金额与全局账本 | 1. 晚批次可以先于早批次进入处理和结算流程（若当前实现允许）<br>2. 所有请求最终均只被结算一次，不发生重复结算<br>3. `_pendingShares`、`totalLockedShares`、各请求状态变化保持一致<br>4. 虽公平性存疑，但系统账本必须保持自洽 |  |  |
|  | Operator / gateway / controller |  | P1 | Admin 在用户集中退出期间修改策略权重，验证后续 divest 路径变化 | 1. 系统中已存在多策略，且已配置 `strategyOrder` 与 target weight<br>2. 多个用户已发起异步赎回请求，形成待处理批次<br>3. 当前 `freeCash` 不足，需要通过 divest 或 `rebalance` 筹资 | 1. 记录修改前的策略权重、顺序、各策略仓位与待处理请求情况<br>2. 调用 `processRedeemBatch(ids)`，观察当前批次所需资金规模<br>3. admin 修改策略权重或 `strategyOrder`<br>4. 继续执行后续 `rebalance / settleAdapter / finalizeRedeemBatch` 流程<br>5. 对比修改前后实际 divest 路径、被动用的策略、in-flight 变化 | 1. 策略权重 / 顺序变更后，后续筹资路径可能发生变化<br>2. 已存在的 request 状态机不应被破坏，不能回退、丢失或重复结算<br>3. 账本字段（`totalLockedShares`、`pendingShares`、`totalRedeemInFlight` 等）保持一致<br>4. 该场景应明确体现“运营配置变化会影响后续筹资路径，但不应破坏既有请求” |  |  |
|  | Vault、Gateway、Accountant、Controller |  | P1 | Admin 更换 `accountant/gateway/controller` 后，新旧地址切换语义正确 | 1. Vault、Gateway、Accountant、Controller 已正常运行<br>2. 已准备好新的 `newAccountant / newGateway / newController` 实例<br>3. 用户与运营流程均可正常调用旧地址 | 1. 记录切换前核心地址配置与相关功能表现<br>2. admin 调用对应 setter 完成地址切换<br>3. 用户通过新 Gateway 执行 `deposit/redeem/requestRedeem` 或查询操作<br>4. 运营侧通过新 Controller / 新 Accountant 执行对应操作<br>5. 分别尝试让旧地址继续调用原本的受控能力 | 1. 切换后对外行为按新依赖实现执行<br>2. 旧地址不应继续保有已切换走的受控能力（例如旧 Gateway / 旧 Accountant / 旧 Controller 的关键受控调用应失败或失效）<br>3. 新地址对应功能可正常工作<br>4. 切换后的 view 与状态读取口径应与新依赖一致 |  |  |
|  | Operator / gateway / controller |  | P1 | 运营方长期不处理某些请求，但持续处理其他请求，验证系统不会出现余额穿透或重复占用 | 1. 系统中存在多批异步赎回请求<br>2. 其中一部分请求长期保持 PENDING 或 PROCESSING 未完成<br>3. 另一部分请求被持续推进并结算 | 1. 创建多批请求并记录每批 `requestId`、shares、owner、状态<br>2. 仅对部分批次持续执行 `processRedeemBatch` 与 `finalizeRedeemBatch`<br>3. 保留另一部分批次长期不处理<br>4. 周期性检查 `totalLockedShares`、`_pendingShares`、`totalAssets`、`getFreeCash()`、各 request 状态<br>5. 对比已处理批次和未处理批次对系统账本的影响 | 1. 未处理请求应持续占用其对应的 locked liabilities / pending 口径<br>2. 已处理请求结算后应正常释放对应占用<br>3. 不应出现同一份 shares 或负债被重复释放 / 重复计算<br>4. `totalAssets`、`getFreeCash()`、请求状态与 pending / locked 账本应保持一致，不出现余额穿透或脏状态 |  |  |

## 合约升级相关

### GatewayFactory - Beacon 升级流程

| 是否自动化 | 测试合约 | 测试结果 | 测试需求描述 | 前置条件 | 测试步骤 | 期望结果 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- |
|  | GatewayFactory / gateway |  | `beaconOwner` 升级实现合约 | `beaconOwner` 拥有 BEACON；<br>新 `MantleVaultGateway` impl 已部署 | 1. `beaconOwner` 调用 `BEACON.upgradeTo(newImpl)` | `BEACON.implementation() == newImpl`；<br>所有已部署 gateway 代理自动指向新实现 |  |
|  | GatewayFactory / gateway |  | 升级后已有 gateway 继续工作 | 已有 gateway 完成过 `deposit/redeem` 操作 | 1. 升级 BEACON<br>2. 对已有 gateway 调用 `deposit`、`isSanctioned` 等 | 状态保留（`vault`、`sanctionsOracle`、`sanctionSafe`、`syncRedeemDisabled`、`whitelistEnabled` 不变）；<br>功能正常 |  |
|  | GatewayFactory / gateway |  | 升级后新部署 gateway 使用新实现 | BEACON 已升级 | 1. 升级后调用 `factory.deployAndInitGateway(params)`<br>2. 调用 `implementation()` | 新 gateway 使用新实现 |  |
|  | GatewayFactory / gateway |  | 非 `beaconOwner` 无法升级 | 调用者非 `beaconOwner` | 1. 非 owner 调用 `BEACON.upgradeTo(newImpl)` | revert `OwnableUnauthorizedAccount(caller)` |  |
|  | GatewayFactory / gateway |  | 升级为零地址 | `beaconOwner` 身份 | 1. `beaconOwner` 调用 `BEACON.upgradeTo(address(0))` | revert `BeaconInvalidImplementation(address(0))` |  |
|  | GatewayFactory / gateway |  | 升级为 EOA（无代码） | `beaconOwner` 身份 | 1. `beaconOwner` 调用 `BEACON.upgradeTo(eoa)` | revert `BeaconInvalidImplementation(eoa)` |  |
|  | GatewayFactory / gateway |  | 升级后存储布局兼容性（ERC-7201） | V1 gateway 已有 `vault/oracle/whitelistEnabled` 数据 | 1. V1 执行多次操作<br>2. 升级到 V2<br>3. 读取 V1 数据 | V1 状态完整保留 |  |
|  | GatewayFactory / gateway |  | 批量升级所有 gateway | factory 部署了 3 个 gateway | 1. `beaconOwner` 调用一次 `BEACON.upgradeTo(newImpl)` | 所有 3 个 gateway 同时升级；各自状态保留 |  |
|  | GatewayFactory / gateway |  | 多 gateway 独立运作 | factory 部署 2 个 gateway，各自关联不同 vault | 1. alice 通过 `gateway1.deposit` → `vault1`<br>2. bob 通过 `gateway2.deposit` → `vault2` | 互不干扰；<br>各 vault 独立接收资金 |  |
|  | GatewayFactory / gateway |  | 升级后继续工作 | gateway 已运行；有存量用户 | 1. 多次 `deposit/redeem`<br>2. beacon 升级到 V2<br>3. 继续 `deposit/redeem` | 升级前后状态连续；功能正常 |  |

### Vault 升级相关

| 是否自动化 | 测试合约 | 测试结果 | 测试需求描述 | 前置条件 | 测试步骤 | 期望结果 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- |
|  | VaultFactory / vault |  | Beacon 升级后所有 vault 指向新实现 | Factory 部署了 2 个 vault 实例；`beaconOwner = admin` | 1. 部署新 `MantleYieldVaultV2` 实现<br>2. admin 调用 `BEACON.upgradeTo(newImplAddress)`<br>3. 检查 `factory.implementation()` | `factory.implementation()` 返回 `newImplAddress`；<br>两个 vault proxy 都执行新实现的逻辑 |  |
|  | VaultFactory / vault |  | 升级后状态保留 | Vault 已有 alice 持仓 `1000e18 shares`、`exchangeRate=1.05e18`、有 PENDING 请求、`controller/accountant/treasury` 已设置 | 1. 升级 Beacon<br>2. 检查所有状态变量 | `balanceOf(alice)=1000e18`、`exchangeRate=1.05e18`、`controller/accountant/treasury` 不变；<br>PENDING 请求状态不变、`totalAssets()` 不变 |  |
|  | VaultFactory / vault |  | 非 `beaconOwner` 无法升级 | `attacker ≠ beaconOwner` | `attacker` 调用 `BEACON.upgradeTo(evilImpl)` | revert `OwnableUnauthorizedAccount` |  |
|  | VaultFactory / vault |  | 升级到零地址失败 | `beaconOwner = admin` | admin 调用 `BEACON.upgradeTo(address(0))` | revert（`UpgradeableBeacon` 拒绝零地址实现） |  |
|  | VaultFactory / vault |  | 升级到非合约地址失败 | `beaconOwner = admin` | admin 调用 `BEACON.upgradeTo(EOA地址)` | revert `BeaconInvalidImplementation`（要求 implementation 是合约） |  |
|  | VaultFactory / vault |  | 升级后新函数可调用 | 新实现添加了 `function newFunction() returns (uint256)` | 1. 升级 Beacon<br>2. 通过 proxy 调用 `newFunction()` | 返回预期值 |  |
|  | VaultFactory / vault |  | 升级后旧函数仍正常 | 升级到包含所有旧函数的新实现 | 1. 升级<br>2. 调用 `deposit`、`redeem`、`requestRedeem`、`updateExchangeRate` 等 | 全部正常工作，无 revert |  |
|  | VaultFactory / vault |  | `initializer` 防止重复初始化 | Vault 已 initialize 过 | 调用 `vault.initialize(params)` | revert `InvalidInitialization`（`Initializable` 防护） |  |
|  | VaultFactory / vault |  | 实现合约不可直接初始化 | 直接在 implementation 合约上操作（非通过 proxy） | 调用 `impl.initialize(params)` | revert `InvalidInitialization`（constructor 中调了 `_disableInitializers()`） |  |
|  | VaultFactory / vault |  | Timelock 控制的升级流程 | `beaconOwner = TimelockUpgradeController`；`proposer/executor` 已配置 | 1. proposer 调用 `timelock.schedule(beacon, 0, upgradeTo(newImpl), ...)`<br>2. 立即执行 `timelock.execute(...)` | revert `TimelockUnexpectedOperationState`（延迟未到） |  |
|  | VaultFactory / vault |  | Timelock 延迟到期后执行升级 | `beaconOwner = TimelockUpgradeController`；`proposer/executor` 已配置 | 1. `schedule`<br>2. `vm.warp(block.timestamp + minDelay)`<br>3. executor 调用 `timelock.execute(...)` | 升级成功，`BEACON.implementation() = newImpl` |  |
|  | VaultFactory / vault |  | Timelock 延迟期内可取消 | `beaconOwner = TimelockUpgradeController`；`proposer/executor` 已配置，已 `schedule` | `canceller` 调用 `timelock.cancel(opId)` | 操作取消，延迟到期后 `execute` 也会 revert |  |
|  | VaultFactory / vault |  | 新实现添加新存储变量（尾部追加） | V2 在 V1 存储末尾追加 `uint256 newVar` | 1. 升级<br>2. 读旧变量<br>3. 写 / 读 `newVar` | 旧变量不受影响；`newVar` 可正常读写 |  |
|  | VaultFactory / vault |  | `reinitializer(2)` 升级初始化 | V2 有 `reinitialize(uint64 version)` 函数 | 1. 升级 Beacon<br>2. 通过 proxy 调用 `reinitialize(2)`<br>3. 再次调用 `reinitialize(2)` | 第一次调用 `reinitialize` 成功；<br>第二次 `reinitialize` revert（版本已用过） |  |
|  | VaultFactory / vault |  | 构造函数正确初始化 Beacon | 有效 `impl` 和 `beaconOwner` | 部署 `VaultFactory(impl, beaconOwner)` | 1. `factory.BEACON()` 非零地址<br>2. `factory.implementation() = impl`<br>3. `BEACON.owner() = beaconOwner` |  |
|  | VaultFactory / vault |  | 构造函数拒绝 `impl=address(0)` | — | 部署 `VaultFactory(address(0), beaconOwner)` | revert `Factory__ZeroAddress()` |  |
|  | VaultFactory / vault |  | 构造函数拒绝 `beaconOwner=address(0)` | — | 部署 `VaultFactory(impl, address(0))` | revert `Factory__ZeroAddress()` |  |
|  | VaultFactory / vault |  | `deployVault` 部署未初始化 vault | Factory 已部署 | 调用 `factory.deployVault()` | 1. 返回非零地址<br>2. `vaultCount()=1`<br>3. `vaults(0)` = 返回地址<br>4. emit `VaultDeployed(addr, 0, false)` |  |
|  | VaultFactory / vault |  | `deployAndInitVault` 部署并初始化 | Factory 已部署；准备好 `InitParams` | 调用 `factory.deployAndInitVault(params)` | 1. 返回非零地址<br>2. `vault.controller() = params.controller`<br>3. `vault.exchangeRate() = 1e18`<br>4. emit `VaultDeployed(addr, 0, true)` |  |
|  | VaultFactory / vault |  | `deployAndInitVault` 参数零地址拒绝 | `params.admin = address(0)` | 调用 `factory.deployAndInitVault(badParams)` | revert（来自 vault 的 `initialize` 校验） |  |
|  | VaultFactory / vault |  | 连续部署多个 vault | — | 连续调用 3 次 `deployAndInitVault` | `vaultCount()=3`；`getAllVaults()` 返回 3 个不同地址 |  |
|  | VaultFactory / vault |  | `getAllVaults` 返回正确列表 | 已部署 2 个 vault | 调用 `getAllVaults()` | 返回长度为 2 的数组，顺序正确 |  |
|  | VaultFactory / vault |  | `vaults(index)` 越界访问 | 只部署了 1 个 vault | 调用 `factory.vaults(1)` | revert（数组越界） |  |
|  | VaultFactory / vault |  | 任何人都可以调用 `deployVault` | `caller =` 随机地址 | 随机地址调用 `factory.deployVault()` | 成功（Factory 没有权限限制） |  |
|  | VaultFactory / vault |  | 部署的 vault 确实是 `BeaconProxy` | 调用 `deployAndInitVault` | 1. 升级 Beacon 到新实现<br>2. 检查已部署 vault 是否使用新逻辑 | 是（确认它是 `BeaconProxy` 而非独立合约） |  |

### StrategyControllerFactory - Beacon 升级流程

| 测试编号 | 测试合约 | 测试结果 | 测试需求描述 | 前置条件 | 测试步骤 | 期望结果 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- |
|  | controllerFactory / controller |  | `beaconOwner` 升级实现合约 | `beaconOwner` 拥有 BEACON；新 impl 已部署 | 1. `beaconOwner` 调用 `BEACON.upgradeTo(newImpl)` | `BEACON.implementation() == newImpl`；<br>所有已部署 controller 代理自动指向新实现 |  |
|  | controllerFactory / controller |  | 升级后已有 controller 继续工作 | 已有 controller 注册了策略并执行过 `rebalance` | 1. `beaconOwner` 升级 BEACON<br>2. 对已有 controller 调用 `rebalance`<br>3. 检查 `strategyInfo / strategyOrder` | 所有状态保留；<br>新功能可用；<br>旧数据不变 |  |
|  | controllerFactory / controller |  | 升级后新部署 controller 使用新实现 | BEACON 已升级 | 1. 升级后调用 `factory.deployAndInitController`<br>2. 调用 `implementation()` | 新 controller 使用新实现；<br>`implementation()` 返回新地址 |  |
|  | controllerFactory / controller |  | 非 `beaconOwner` 无法升级 | 调用者非 `beaconOwner` | 1. 非 owner 调用 `BEACON.upgradeTo(newImpl)` | revert (`OwnableUnauthorizedAccount`) |  |
|  | controllerFactory / controller |  | 升级为零地址 | `beaconOwner` 身份 | 1. `beaconOwner` 调用 `BEACON.upgradeTo(address(0))` | revert (`BeaconInvalidImplementation`) |  |
|  | controllerFactory / controller |  | 升级为 EOA（无代码） | `beaconOwner` 身份 | 1. `beaconOwner` 调用 `BEACON.upgradeTo(eoa)` | revert (`BeaconInvalidImplementation`)，OZ 要求实现必须是合约 |  |
|  | controllerFactory / controller |  | 升级后存储布局兼容性 | V1 controller 有策略数据；V2 只追加新状态变量 | 1. V1 注册策略、设置 order、执行 `rebalance`<br>2. 升级到 V2<br>3. 读取 V1 的策略数据<br>4. 调用 V2 新增方法 | V1 数据完整保留；<br>V2 新方法可用；<br>无存储冲突 |  |
|  | controllerFactory / controller |  | 升级后存储布局不兼容（破坏性测试） | V2 修改了已有变量的位置 | 1. V1 写入数据<br>2. 升级到不兼容 V2<br>3. 读取数据 | 数据被损坏，证明存储布局兼容性的重要性 |  |
|  | controllerFactory / controller |  | 通过 `TimelockUpgradeController` 延迟升级 | `BEACON.owner()` 设为 `TimelockUpgradeController` | 1. proposer 调用 `timelock.schedule(BEACON.upgradeTo(newImpl), delay)`<br>2. 在 delay 之前调用 `execute` -> revert<br>3. warp delay<br>4. executor 调用 `execute` | 步骤 2 revert；<br>步骤 4 成功，BEACON 实现已更新 |  |
|  | controllerFactory / controller |  | 批量升级所有 controller | factory 部署了 5 个 controller | 1. `beaconOwner` 调用一次 `BEACON.upgradeTo(newImpl)` | 所有 5 个 controller 同时升级；<br>分别验证每个 controller 的 implementation 指向新合约 |  |
|  | controllerFactory / controller |  | factory 部署 -> controller 初始化 -> 注册策略 -> 激活 -> rebalance -> 升级 -> rebalance | 全新环境 | 1. 部署 factory<br>2. `deployAndInitController`<br>3. 注册策略<br>4. 激活策略（`activateStrategy`）<br>5. 设置 order<br>6. mint USDC 到 vault<br>7. `rebalance`（invest）<br>8. 升级 beacon 到新 impl<br>9. 再次 `rebalance` | 所有步骤成功；升级后状态保持；新 `rebalance` 正常工作 |  |
|  | controllerFactory / controller |  | 多 controller 独立运作 | factory 部署 2 个 controller，分别管理不同 vault | 1. `controller1` 注册 / 激活策略 A<br>2. `controller2` 注册 / 激活策略 B<br>3. 分别 `rebalance` | 互不干扰；<br>各自策略独立执行 |  |
|  | controller / OperatorExecutor / vault |  | `OperatorExecutor -> StrategyController -> Vault` 全链路 | `OperatorExecutor` 已初始化，持有 controller `OPERATOR_EXECUTOR_ROLE` | 1. signer 签名 `rebalance`<br>2. relayer 调用 `OperatorExecutor.executeRebalance`<br>3. `OperatorExecutor -> controller.rebalance`<br>4. `controller -> vault.approveToAdapter / createInFlight` | 签名验证通过；<br>nonce 递增；<br>controller 和 vault 状态正确更新 |  |
|  | controller / OperatorExecutor |  | `OperatorExecutor settleAdapter` 全链路 | 有 pending invest + redeem in-flight | 1. signer 签名 `settleAdapter` 命令<br>2. relayer 调用 `OperatorExecutor.executeSettleAdapter`<br>3. `controller.settleAdapter -> adapter.sweepToVault + confirmInFlight` | sweep 完成；<br>in-flight 确认；<br>vault 统计正确更新 |  |
|  | controller / OperatorExecutor / vault |  | 策略完整生命周期：注册 -> 激活 -> order -> rebalance -> settle -> 移出 order -> 停用 | 全新 controller | 1. `registerStrategy`<br>2. `activateStrategy`<br>3. `setStrategyOrder`<br>4. `rebalance(invest)`<br>5. `settleAdapter(confirm invest in-flight)`<br>6. `setStrategyOrder`（移除该策略）<br>7. `deactivateStrategy` | 全部成功；<br>最终策略 inactive；<br>adapter 从 vault 移除 |  |

### SanctionsOracleFactory - Beacon 升级流程

| 测试编号 | 测试合约 | 测试结果 | 测试需求描述 | 前置条件 | 测试步骤 | 期望结果 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- |
|  | SanctionsOracleFactory / Sanctions |  | `beaconOwner` 升级实现合约 | `beaconOwner` 拥有 BEACON；新 `SanctionsOracle` impl 已部署 | 1. `beaconOwner` 调用 `BEACON.upgradeTo(newImpl)` | `BEACON.implementation() == newImpl`；<br>所有已部署 oracle 代理自动指向新实现 |  |
|  | SanctionsOracleFactory / Sanctions |  | 升级后已有 oracle 继续工作 | 已有 oracle 做过制裁操作 | 1. 升级 BEACON<br>2. 对已有 oracle 调用 `isSanctioned / updateSanctionStatus` | 状态保留；<br>功能正常 |  |
|  | SanctionsOracleFactory / Sanctions |  | 升级后新部署 oracle 使用新实现 | BEACON 已升级 | 1. 升级后调用 `factory.deployAndInitOracle`<br>2. 调用 `implementation()` | 新 oracle 使用新实现 |  |
|  | SanctionsOracleFactory / Sanctions |  | 非 `beaconOwner` 无法升级 | 调用者非 `beaconOwner` | 1. 非 owner 调用 `BEACON.upgradeTo(newImpl)` | revert `OwnableUnauthorizedAccount(caller)` |  |
|  | SanctionsOracleFactory / Sanctions |  | 升级为零地址 | `beaconOwner` 身份 | 1. `beaconOwner` 调用 `BEACON.upgradeTo(address(0))` | revert `BeaconInvalidImplementation(address(0))` |  |
|  | SanctionsOracleFactory / Sanctions |  | 升级为 EOA（无代码） | `beaconOwner` 身份 | 1. `beaconOwner` 调用 `BEACON.upgradeTo(eoa)` | revert `BeaconInvalidImplementation(eoa)` |  |
|  | SanctionsOracleFactory / Sanctions |  | 升级后存储布局兼容性（ERC-7201） | V1 oracle 已有制裁和白名单数据；V2 只追加新变量 | 1. V1 执行多次制裁 / 白名单操作<br>2. 升级到 V2<br>3. 读取 V1 数据<br>4. 调用 V2 新方法 | V1 数据完整保留（ERC-7201 命名空间存储）；V2 新方法可用 |  |
|  | SanctionsOracleFactory / Sanctions |  | 批量升级所有 oracle | factory 部署了 5 个 oracle | 1. `beaconOwner` 调用一次 `BEACON.upgradeTo(newImpl)` | 所有 5 个 oracle 同时升级；各自状态保留 |  |
|  | SanctionsOracleFactory / Sanctions |  | 多 oracle 独立运作 | factory 部署 2 个 oracle，分别由不同 `complianceBot` 管理 | 1. `oracle1.bot1` 制裁 alice<br>2. `oracle2.bot2` 制裁 bob | `oracle1: isSanctioned(alice)==true, isSanctioned(bob)==false`；<br>`oracle2: isSanctioned(alice)==false, isSanctioned(bob)==true`；<br>互不干扰 |  |
|  | gateway / Sanctions |  | Oracle 白名单与 Gateway 联动 | `Gateway whitelistEnabled=true`；使用此 Oracle | 1. 部署 oracle 并初始化<br>2. Gateway 配置 oracle<br>3. admin 开启 `whitelistEnabled`<br>4. 未白名单用户尝试 `gateway.deposit()` → 回滚<br>5. `complianceBot` 白名单该用户<br>6. 用户再次 `gateway.deposit()` | 步骤 4 回滚 `Gateway__NotWhitelisted`；<br>步骤 6 成功 |  |

### AccountantFactory - Beacon 升级流程-汇率更新全流程

| 测试编号 | 测试合约 | 测试结果 | 测试需求描述 | 前置条件 | 测试步骤 | 期望结果 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- |
|  | AccountantFactory / accountant |  | `beaconOwner` 升级实现合约 | `beaconOwner` 拥有 BEACON；<br>新 Accountant impl 已部署 | 1. `beaconOwner` 调用 `BEACON.upgradeTo(newImpl)` | `BEACON.implementation() == newImpl`；<br>所有已部署 accountant 代理自动指向新实现 |  |
|  | AccountantFactory / accountant |  | 升级后已有 accountant 继续工作 | 已有 accountant 执行过 `updateExchangeRate` | 1. 升级 BEACON<br>2. 对已有 accountant 调用 `getRate / updateExchangeRate` | 状态保留；<br>`lastExchangeRate` 不变；<br>角色不变；<br>功能正常 |  |
|  | AccountantFactory / accountant |  | 升级后新部署 accountant 使用新实现 | BEACON 已升级 | 1. 升级后调用 `factory.deployAndInitAccountant`<br>2. 调用 `implementation()` | 新 accountant 使用新实现 |  |
|  | AccountantFactory / accountant |  | 非 `beaconOwner` 无法升级 | 调用者非 `beaconOwner` | 1. 非 owner 调用 `BEACON.upgradeTo(newImpl)` | revert `OwnableUnauthorizedAccount(caller)` |  |
|  | AccountantFactory / accountant |  | 升级为零地址 | `beaconOwner` 身份 | 1. `beaconOwner` 调用 `BEACON.upgradeTo(address(0))` | revert `BeaconInvalidImplementation(address(0))` |  |
|  | AccountantFactory / accountant |  | 升级为 EOA（无代码） | `beaconOwner` 身份 | 1. `beaconOwner` 调用 `BEACON.upgradeTo(eoa)` | revert `BeaconInvalidImplementation(eoa)` |  |
|  | AccountantFactory / accountant |  | 升级后存储布局兼容性（ERC-7201） | V1 accountant 已有汇率和费用数据；V2 只追加新变量 | 1. V1 执行多次 `updateExchangeRate`<br>2. 升级到 V2<br>3. 读取 V1 数据<br>4. 调用 V2 新方法 | V1 数据完整保留（ERC-7201 命名空间存储）；<br>V2 新方法可用；<br>无存储冲突 |  |
|  | AccountantFactory / accountant |  | 升级后存储布局不兼容（破坏性测试） | V2 修改了 `AccountantStorage` 中已有字段的位置 | 1. V1 写入数据<br>2. 升级到不兼容 V2<br>3. 读取数据 | 数据损坏，证明 ERC-7201 布局兼容性的重要性 |  |
|  | AccountantFactory / accountant |  | 通过 `TimelockUpgradeController` 延迟升级 | `BEACON.owner()` 设为 `TimelockUpgradeController` | 1. proposer `schedule(BEACON.upgradeTo(newImpl), delay)`<br>2. 在 delay 前 `execute` -> revert<br>3. warp delay<br>4. executor `execute` | 步骤 2 revert；<br>步骤 4 成功；<br>BEACON 实现已更新 |  |
|  | AccountantFactory / accountant |  | 批量升级所有 accountant | factory 部署了 5 个 accountant | 1. `beaconOwner` 调用一次 `BEACON.upgradeTo(newImpl)` | 所有 5 个 accountant 同时升级 |  |
|  | AccountantFactory / accountant |  | factory 部署 -> accountant 初始化 -> 更新汇率 -> 升级 -> 再更新 | 全新环境 | 1. 部署 `AccountantFactory`<br>2. `deployAndInitAccountant`<br>3. 授予 executor `EXECUTOR_ROLE`<br>4. cooldown 后 `updateExchangeRate`<br>5. 升级 beacon 到新 impl<br>6. cooldown 后再次 `updateExchangeRate` | 所有步骤成功；<br>升级后状态保持；<br>新 `updateExchangeRate` 正常 |  |
|  | AccountantFactory / accountant |  | 多 accountant 独立运作 | factory 部署 2 个 accountant，分别管理不同 vault | 1. `accountant1.updateExchangeRate` 到 `1.005e18`<br>2. `accountant2.updateExchangeRate` 到 `0.995e18` | 互不干扰；<br>各自汇率独立 |  |
|  | vault / accountant |  | accountant `setVault` 切换后与新 vault 联动 | 已初始化；部署新 vault | 1. admin `setVault(newVault)`<br>2. `updateExchangeRate` | 费用结算使用 `newVault.totalSupply()` 和 `newVault.mintFeeShares()` |  |
|  | AccountantExecutor / accountant |  | executor 升级后继续工作 | `AccountantExecutor` 通过 UUPS 升级 | 1. 部署新 `AccountantExecutor` impl<br>2. admin 调用 `executor.upgradeToAndCall(newImpl, "")`<br>3. bot 调用 `executeUpdateRate(accountant, newRate, computeTs)` | 成功；角色保留 |  |
|  | AccountantExecutor / accountant |  | 完整汇率更新流程 | `AccountantExecutor` 已初始化；<br>`Accountant` 已初始化；<br>executor 持有 Accountant `EXECUTOR_ROLE`；<br>bot 持有 executor `BOT_ROLE` | 1. bot 调用 `executor.executeUpdateRate(accountant, newRate, computeTs)`<br>2. executor 调用 `accountant.updateExchangeRate`<br>3. accountant 结算管理费<br>4. accountant 更新汇率 | 全链路成功；<br>`accountant.lastExchangeRate == newRate`；<br>vault 收到 fee shares |  |
|  | AccountantExecutor / accountant |  | 全链路 - cooldown 检查透传 | cooldown 未过 | 1. bot 调用 `executor.executeUpdateRate(accountant, newRate, computeTs)` | revert 来自 Accountant 的 `CooldownNotElapsed`，透传到 executor 调用者 |  |
|  | AccountantExecutor / accountant |  | 全链路 - deviation 超限触发 soft pause | 偏差超限 | 1. bot 调用 `executor.executeUpdateRate(accountant, 1.05e18, ...)` | executor 触发 `RateUpdateExecuted`；<br>Accountant 触发 `CircuitBreakerTriggered`；<br>Accountant 进入 paused；<br>`lastExchangeRate` 保持旧值 |  |
|  | AccountantExecutor / accountant |  | 全链路 - `computeTimestamp` 过期透传 | 传入过期的 `computeTimestamp` | 1. bot 调用 `executor.executeUpdateRate(accountant, rate, staleTs)` | revert 来自 Accountant 的 `StaleComputeTimestamp` |  |
|  | AccountantExecutor / accountant |  | 全链路 - 暂停透传 | Accountant 已 pause | 1. bot 调用 `executor.executeUpdateRate(accountant, rate, ts)` | revert (`EnforcedPause`)，通过 executor 传播 |  |
|  | AccountantExecutor / accountant / vault |  | 全链路 - 费用结算与 `vault.mintFeeShares` | vault 有 `totalSupply`；<br>`feeRate > 0` | 1. 第一次 `executeUpdateRate(accountant, rate1, ts1)` primes snapshot<br>2. 第二次 `executeUpdateRate(accountant, rate2, ts2)` | `vault.mintFeeShares` 被调用；<br>treasury 收到 fee shares |  |
|  | AccountantExecutor / accountant |  | 全链路 - 连续多次更新 | 已成功更新过 | 1. 第一次更新<br>2. cooldown 后第二次更新<br>3. cooldown 后第三次更新 | 每次 `lastExchangeRate` 更新；<br>每次费用正确结算；<br>`lastComputeTimestamp` 严格递增 |  |
|  | AccountantExecutor / accountant |  | 全链路 - 暂停后恢复再更新 | 中途 admin pause | 1. 更新成功<br>2. admin pause<br>3. 更新 revert<br>4. admin unpause<br>5. cooldown 后再次更新 | 步骤 3 revert；<br>步骤 5 成功 |  |

### AccountantExecutor UUPS 升级

| 测试编号 | 测试合约 | 测试结果 | 测试需求描述 | 前置条件 | 测试步骤 | 期望结果 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- |
|  | AccountantExecutor |  | admin 可通过 UUPS 升级 | admin 拥有 `DEFAULT_ADMIN_ROLE` | 1. 部署新 `AccountantExecutor` 实现<br>2. admin 调用 `executor.upgradeToAndCall(newImpl, "")` | executor 指向新实现；<br>状态保留；<br>角色不变；<br>升级后 `executeUpdateRate(accountant, newRate, computeTs)` 仍可正常工作 |  |
|  | AccountantExecutor |  | 非 admin 无法升级 | user 无 `DEFAULT_ADMIN_ROLE` | 1. user 调用 `executor.upgradeToAndCall(newImpl, "")` | revert `AccessControlUnauthorizedAccount(user, DEFAULT_ADMIN_ROLE)` |  |

### OperatorExecutor UUPS

| 测试编号 | 测试合约 | 测试结果 | 测试需求描述 | 前置条件 | 测试步骤 | 期望结果 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- |
|  | OperatorExecutor |  | 通过代理部署并初始化成功 | 已部署实现合约 | 1. 部署代理<br>2. 调用 `initialize(admin, initialBot)` | 代理初始化成功；后续通过代理地址执行业务 |  |
|  | OperatorExecutor |  | admin 可升级到新实现 | `proxy=V1`；已部署兼容 UUPS 的 `implV2`；`caller=admin` | 通过代理调用升级入口升级到 `implV2` | 升级成功；实现地址切换到 `implV2` |  |
|  | OperatorExecutor |  | 非 admin 不能升级 | `proxy=V1`；caller 无 `DEFAULT_ADMIN_ROLE` | 通过代理调用升级入口 | revert `AccessControlUnauthorizedAccount(caller, DEFAULT_ADMIN_ROLE)` |  |
|  | OperatorExecutor |  | 直接对实现合约调用升级应失败 | 已部署 implementation 和 `implV2` | 直接对 implementation 调用升级入口 | revert（命中 UUPS `onlyProxy` 保护） |  |
|  | OperatorExecutor |  | 升级到非 UUPS 实现应失败 | `proxy=V1`；`NotUUPS` 合约不满足 UUPS 要求；`caller=admin` | 通过代理调用升级入口 | revert（无效实现） |  |
|  | OperatorExecutor |  | 升级后角色状态保持不变 | V1 已配置 admin、多个 bot；已部署 `implV2` | 1. 记录升级前角色状态<br>2. 执行升级<br>3. 再次检查 | `DEFAULT_ADMIN_ROLE`、`BOT_ROLE` 成员保持不变 |  |
|  | OperatorExecutor |  | 升级后执行能力保持 | proxy 已升级到 V2；bot 仍有效 | 调用任一 `execute*` | 成功路由到下游 controller；事件正常 |  |

## Gateway 管理配置场景

| 是否自动化 | 测试合约 | 测试结果 | 优先级 | 测试需求描述 | 前置条件 | 测试步骤 | 期望结果 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Y | GatewayAdminConfig.t.sol | PASS | P0 | admin 开启/关闭同步赎回开关，验证 redeem 行为变化 | Gateway 已初始化，用户已存款 | 1. 默认 `syncRedeemDisabled=false`，用户同步赎回成功<br>2. admin 调用 `setSyncRedeemDisabled(true)`<br>3. 用户同步赎回<br>4. 用户异步赎回<br>5. admin 调用 `setSyncRedeemDisabled(false)` | 1. 默认同步赎回正常<br>2. 开启后同步赎回 revert `Vault__SyncRedeemDisabled`<br>3. 异步赎回不受影响<br>4. 关闭后同步赎回恢复 |  |
| Y | GatewayAdminConfig.t.sol | PASS | P0 | 非 admin 不能修改 `syncRedeemDisabled` | Gateway 已初始化 | 非 admin 调用 `setSyncRedeemDisabled(true)` | revert，命中角色检查 |  |
| Y | GatewayAdminConfig.t.sol | PASS | P0 | admin 更换制裁预言机地址，新预言机立即生效 | Gateway 已初始化 | 1. admin 调用 `setSanctionsOracle(newOracle)`<br>2. 通过新预言机标记用户为制裁<br>3. 查询 `gateway.isSanctioned(user)` | 1. 预言机地址更新<br>2. 新预言机制裁状态立即生效 |  |
| Y | GatewayAdminConfig.t.sol | PASS | P0 | `setSanctionsOracle` 拒绝零地址 | Gateway 已初始化 | admin 调用 `setSanctionsOracle(address(0))` | revert `Vault__ZeroAddress` |  |
| Y | GatewayAdminConfig.t.sol | PASS | P0 | 非 admin 不能更换制裁预言机 | Gateway 已初始化 | 非 admin 调用 `setSanctionsOracle(addr)` | revert，命中角色检查 |  |
| Y | GatewayAdminConfig.t.sol | PASS | P0 | admin 更换制裁安全地址 | Gateway 已初始化 | admin 调用 `setSanctionSafe(newSafe)` | `sanctionSafe` 更新为新地址 |  |
| Y | GatewayAdminConfig.t.sol | PASS | P0 | `setSanctionSafe` 拒绝零地址 | Gateway 已初始化 | admin 调用 `setSanctionSafe(address(0))` | revert `Vault__ZeroAddress` |  |
| Y | GatewayAdminConfig.t.sol | PASS | P0 | admin 开启白名单后，未白名单用户被拒绝，白名单用户正常操作 | Gateway 已初始化，用户已有余额 | 1. 白名单关闭时用户正常存款<br>2. admin 调用 `setWhitelistEnabled(true)`<br>3. 未白名单用户存款<br>4. 白名单用户存款<br>5. admin 调用 `setWhitelistEnabled(false)`<br>6. 之前被拒用户再存款 | 1. 白名单开启后非白名单用户 revert<br>2. 白名单用户正常<br>3. 关闭后所有用户恢复正常 |  |
| Y | GatewayAdminConfig.t.sol | PASS | P0 | 非 admin 不能修改 `whitelistEnabled` | Gateway 已初始化 | 非 admin 调用 `setWhitelistEnabled(true)` | revert，命中角色检查 |  |

## Vault 管理配置场景

| 是否自动化 | 测试合约 | 测试结果 | 优先级 | 测试需求描述 | 前置条件 | 测试步骤 | 期望结果 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Y | VaultAdminConfig.t.sol | PASS | P0 | admin 更换 Accountant 地址，新 Accountant 立即生效 | Vault 已初始化，初始汇率 1.0 | 1. 部署新 Accountant（汇率 1.05）<br>2. admin 调用 `vault.setAccountant(newAcct)` | `vault.exchangeRate()` 返回新 Accountant 的汇率 |  |
| Y | VaultAdminConfig.t.sol | PASS | P0 | `setAccountant` 拒绝零地址 | Vault 已初始化 | admin 调用 `vault.setAccountant(address(0))` | revert `Vault__ZeroAddress` |  |
| Y | VaultAdminConfig.t.sol | PASS | P0 | 非 admin 不能更换 Accountant | Vault 已初始化 | 非 admin 调用 `vault.setAccountant(addr)` | revert，命中角色检查 |  |
| Y | VaultAdminConfig.t.sol | PASS | P0 | admin 更换 Controller 地址 | Vault 已初始化 | admin 调用 `vault.setController(newCtrl)` | Controller 更新成功 |  |
| Y | VaultAdminConfig.t.sol | PASS | P0 | `setController` 拒绝零地址 | Vault 已初始化 | admin 调用 `vault.setController(address(0))` | revert `Vault__ZeroAddress` |  |
| Y | VaultAdminConfig.t.sol | PASS | P0 | admin 更换 Gateway 后，旧 Gateway 无法操作 | Vault 已初始化，用户通过旧 Gateway 存过款 | 1. admin 调用 `vault.setGateway(newGw)`<br>2. 通过旧 Gateway 存款 | 旧 Gateway 操作 revert |  |
| Y | VaultAdminConfig.t.sol | PASS | P0 | `setGateway` 拒绝零地址 | Vault 已初始化 | admin 调用 `vault.setGateway(address(0))` | revert `Vault__ZeroAddress` |  |
| Y | VaultAdminConfig.t.sol | PASS | P0 | admin 更换 Treasury 后，赎回费用流向新 Treasury | Vault 已初始化，用户有存款 | 1. admin 调用 `vault.setTreasury(newTreasury)`<br>2. 用户赎回 | 费用份额流向新 Treasury，旧 Treasury 不再收到 |  |
| Y | VaultAdminConfig.t.sol | PASS | P0 | `setTreasury` 拒绝零地址 | Vault 已初始化 | admin 调用 `vault.setTreasury(address(0))` | revert `Vault__ZeroAddress` |  |
| Y | VaultAdminConfig.t.sol | PASS | P0 | admin 调整赎回费率上限（上调） | 初始 `maxRedemptionFeeBps=500` | 1. admin 调用 `vault.setMaxRedemptionFee(1000)`<br>2. 再设 `redemptionFeeBps=800` | 上调成功，可设置更高费率 |  |
| Y | VaultAdminConfig.t.sol | PASS | P0 | 降低 max 时自动收敛当前 fee | 初始 `maxRedemptionFeeBps=500`, `redemptionFeeBps=100` | admin 调用 `vault.setMaxRedemptionFee(50)` | `redemptionFeeBps` 自动收敛到 50 |  |
| Y | VaultAdminConfig.t.sol | PASS | P0 | `setMaxRedemptionFee` 拒绝超过 10000 bps | Vault 已初始化 | admin 调用 `vault.setMaxRedemptionFee(10001)` | revert `Vault__FeeTooHigh` |  |
| Y | VaultAdminConfig.t.sol | PASS | P1 | admin 回收误入 Vault 的非底层代币 | Vault 中有非底层 ERC20 代币 | admin 调用 `vault.rescueTokens(randomToken, recipient, amount)` | 代币成功转给 recipient |  |
| Y | VaultAdminConfig.t.sol | PASS | P1 | `rescueTokens` 拒绝回收底层资产 (USDC) | Vault 中有 USDC 余额 | admin 调用 `vault.rescueTokens(usdc, admin, amount)` | revert `Vault__RescueAssetCannotBeUnderlying` |  |
| Y | VaultAdminConfig.t.sol | PASS | P1 | 非 admin 不能调用 `rescueTokens` | Vault 已初始化 | 非 admin 调用 `vault.rescueTokens(...)` | revert，命中角色检查 |  |

## Rebalance 投资与撤资场景

| 是否自动化 | 测试合约 | 测试结果 | 优先级 | 测试需求描述 | 前置条件 | 测试步骤 | 期望结果 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Y | RebalanceInvestDivest.t.sol | PASS | P0 | `freeCash > targetCash + threshold` 时触发投资 | `bufferTargetBps=1000`, `rebalanceThresholdBps=200`, `freeCash=10000e6` | bot 通过 OperatorExecutor 调用 `rebalance()` | 1. 触发 invest，金额 = freeCash - targetCash<br>2. `lastRebalance` 更新<br>3. adapter `totalValue` 增加 |  |
| Y | RebalanceInvestDivest.t.sol | PASS | P0 | `freeCash + threshold < targetCash` 时触发撤资 | 先投资使 `freeCash=700e6`，再恢复 buffer=10% | bot 调用 `rebalance()` | 1. 触发 divest<br>2. `totalRedeemInFlight` 增加<br>3. `lastRebalance` 更新 |  |
| Y | RebalanceInvestDivest.t.sol | PASS | P0 | 落在阈值区间内时不做投资也不做撤资 | 构造 `freeCash=1100e6`（在 [800, 1200] 区间内） | bot 调用 `rebalance()` | 1. adapter `totalValue` 不变<br>2. `lastRebalance` 仍更新 |  |
| Y | RebalanceInvestDivest.t.sol | PASS | P0 | 冷却期内禁止再次 rebalance | 距离上次 rebalance 不足 cooldown | bot 调用 `rebalance()` | revert `CooldownNotElapsed`<br>cooldown 过后调用成功 |  |
| Y | RebalanceInvestDivest.t.sol | PASS | P1 | 投资时按 `strategyOrder` 顺序填补缺口 | `strategyOrder=[adapterA, adapterB]`，权重各 50% | bot 调用 `rebalance()` 触发 invest | 1. adapterA 先填补 = totalAssets*50%<br>2. adapterB 收到剩余<br>3. 总投资 = excessCash |  |
| Y | RebalanceInvestDivest.t.sol | PASS | P1 | 撤资时按 `strategyOrder` 顺序，`isAsync` 决定 sync/async 路径 | `[adapterA(sync), adapterB(async)]`，两者均有仓位 | bot 调用 `rebalance()` 触发 divest | 1. adapterA 走 `withdrawSync` 路径<br>2. adapterB 走 `requestRedeemAsync` 路径<br>3. 各自 `adapterRedeemInFlightUsdc` 增加 |  |
| Y | RebalanceInvestDivest.t.sol | PASS | P1 | 异步投资/异步赎回会创建 in-flight 记录 | 命中 async adapter | bot 调用 `rebalance()` | `totalInvestInFlight` 和 `totalRedeemInFlight` 分别增加 |  |
| Y | RebalanceInvestDivest.t.sol | PASS | P1 | 外部 adapter 调用失败时记录 skipped 而不是整体中断 | adapterA `deposit()` 会 revert | bot 调用 `rebalance()` | 1. badAdapter 被跳过（`InvestSkipped` 事件）<br>2. goodAdapter 正常投资<br>3. rebalance 不回滚 |  |
| Y | RebalanceInvestDivest.t.sol | PASS | P1 | 所有策略合计流动性仍不足时记录 `DivestIncomplete` | trappedAdapter `withdrawSync` 会 revert | bot 调用 `rebalance()` | 1. `DivestIncomplete(remaining)` 事件<br>2. rebalance 不回滚 |  |
| Y | RebalanceInvestDivest.t.sol | PASS | P1 | 首次 rebalance 不受冷却期限制 | `lastRebalance=0`, `cooldown=1h` | bot 调用 `rebalance()` | 调用成功，`lastRebalance` 更新 |  |
| Y | RebalanceInvestDivest.t.sol | PASS | P1 | 投资时扣除 pending invest in-flight，避免重复投资 | adapter 已有 pending invest in-flight | 再次 `rebalance()` | 第二次投资金额 < 第一次（pending 已扣减） |  |
| Y | RebalanceInvestDivest.t.sol | PASS | P1 | 同步撤资（`withdrawSync`）自动创建 redeem in-flight 记录 | 存在同步策略且 `freeCash` 不足 | bot 调用 `rebalance()` 触发 divest | `totalRedeemInFlight` 和 `adapterRedeemInFlightUsdc` 增加 |  |
| Y | RebalanceInvestDivest.t.sol | PASS | P1 | 投资后清除 adapter allowance | adapter 已注册且投资成功 | bot 调用 `rebalance()` 后检查 allowance | `usdc.allowance(vault, adapter) == 0` |  |
| Y | RebalanceInvestDivest.t.sol | PASS | P1 | `strategyOrder` 为空时 rebalance 为 no-op | Controller 已初始化但无策略注册 | bot 调用 `rebalance()` | 1. `freeCash` 无变化<br>2. `lastRebalance` 更新 |  |
| Y | RebalanceInvestDivest.t.sol | PASS | P1 | adapter `totalValue()` 异常时 rebalance 不中断 | adapter 的 `totalValue()` 会 revert | bot 调用 `rebalance()` | 1. 异常 adapter 价值视为 0<br>2. 正常 adapter 正常投资<br>3. rebalance 不回滚 |  |
| Y | RebalanceInvestDivest.t.sol |  | P1 | vault 存在 cashDeficit 时 targetCash 增大，触发更大金额的 divest | vault 物理余额不足覆盖 totalLockedShares（大量 redeem 请求 + 大部分 USDC 已投出） | 1. deposit -> invest 大部分 USDC<br>2. requestRedeem 80% shares（产生 cashDeficit > 0）<br>3. bot 调用 `rebalance()` | 1. `targetCash = netAssets * bufferBps / 10000 + cashDeficit`<br>2. divest 金额 >= cashDeficit<br>3. `totalRedeemInFlight` 增加 |  |
| Y | RebalanceInvestDivest.t.sol |  | P1 | freeCash 充足覆盖 locked shares 时 cashDeficit=0，rebalance 行为不变（回归验证） | deposit 后无 redeem 请求，freeCash 充裕 | 1. deposit -> invest<br>2. 查询 `getCashDeficit()`<br>3. 查询 `getRebalanceState()` | 1. `cashDeficit = 0`<br>2. `targetCash = netAssets * bufferBps / 10000`（无额外加值） |  |
| Y | RebalanceInvestDivest.t.sol |  | P1 | adapter 已有 pending redeem in-flight 时，divest 不再发起重复的 redeem 请求 | async adapter 已注册；前一轮 divest 留下 pending redeem in-flight | 1. 第一轮 divest 产生 pending redeem<br>2. 第二轮 divest（更大 buffer） | `_readDivestCoverage` 返回 `coveredByPending > 0`，新请求金额小于全额 shortfall；不重复请求已 pending 的部分 |  |
| Y | RebalanceInvestDivest.t.sol |  | P1 | divest 同时考虑 adapter settled value 和 pending redeem coverage，只对 settled 部分发起新请求 | async adapter 有 settled value > 0 且 pending redeem > 0 | 1. 第一轮 divest 产生部分 pending<br>2. 第二轮大额 divest | 新增 redeem in-flight <= settled value；pending 部分不重复计入 |  |
| Y | RebalanceInvestDivest.t.sol |  | P1 | pending redeem 完全覆盖 divest 需求时，不发起任何新的 redeem 请求 | async adapter 已有大额 pending redeem in-flight | 1. 第一轮大额 divest 产生大 pending<br>2. 第二轮小额 divest（shortfall < pendingRedeem） | `adapterRedeemInFlightUsdc` 不增加（无新请求）；`_readDivestCoverage` 返回 `requestAsset=0` |  |
| Y | RebalanceInvestDivest.t.sol |  | P1 | getCashDeficit 数值公式验证：floatingLocked - physicalBalance (when freeCash=0) | vault 物理余额不足覆盖 totalLockedShares | 1. deposit -> invest 大部分<br>2. requestRedeem 90% shares<br>3. 验证 `getCashDeficit()` 计算<br>4. 验证 `getRebalanceState().targetCash` 包含 deficit | 1. 无 locked 时 deficit=0<br>2. freeCash=0 时 deficit=floatingLocked-physicalBalance<br>3. targetCash = netAssets*bufferBps/10000 + deficit |  |
| Y | RebalanceInvestDivest.t.sol |  | P1 | processRedeemBatch 触发 _divest 时，pending redeem coverage 逻辑也生效 | async adapter 已有 pending redeem；freeCash < batchTotalAsset | 1. rebalance divest 产生 pending<br>2. 用户 requestRedeem<br>3. processRedeemBatch 触发 _divest | 新请求 <= adapter settled value（pending coverage 被尊重）；不重复请求已 pending 的部分 |  |
| Y | RebalanceInvestDivest.t.sol | PASS | P1 | posToken 升值后 adapter.totalValue 增大，rebalance invest 分配减少 | async adapter 已注册，posTokenPrice=1e18，deposit 10000 USDC 并 rebalance 投资 | 1. setPosTokenPrice(2e18)（posToken 升值 2x）<br>2. 再存入 5000 USDC 并 rebalance<br>3. 比较第二次投资金额 vs 第一次 | 1. adapter.totalValue() 因价格上涨而翻倍<br>2. adapter 已超配，第二次 invest 分配 < 第一次<br>3. 验证 totalValue 使用 price 换算而非 1:1 | test_Invest_PosTokenPriceAboveOne_ReducesAllocation |
| Y | RebalanceInvestDivest.t.sol | PASS | P1 | posToken 贬值后 adapter.totalValue 缩水，divest 可用额度相应减少 | async adapter 已注册，deposit 10000 USDC 并 rebalance 投资，settle 完成 | 1. setPosTokenPrice(0.5e18)（posToken 贬值 50%）<br>2. setRiskParams 提高 buffer 到 100% 触发全额 divest<br>3. 验证 divest 金额 | 1. adapter.totalValue() 因价格下跌减半<br>2. divest 请求金额 = 缩水后的 settledValue（非原始投入额）<br>3. adapterRedeemInFlightUsdc <= 缩水后 totalValue | test_Divest_PosTokenPriceBelowOne_SettledValueReduced |

## Retry Redeem In-Flight 场景

| 是否自动化 | 测试合约 | 测试结果 | 优先级 | 测试需求描述 | 前置条件 | 测试步骤 | 期望结果 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Y | RetryRedeemInFlight.t.sol |  | P0 | admin 对 PENDING 状态的 async redeem in-flight 发起部分数量 retry 成功 | 已存在 PENDING redeem in-flight（tokenAmount=X），DiGiFT 退回部分 posToken 到 adapter | 1. admin 调用 `retryRedeemInFlight(adapter, inFlightId, X*60%)` | 1. `RedeemInFlightRetryRequested` 事件<br>2. adapter.retryRedeemAsync 被调用<br>3. in-flight 状态仍为 PENDING<br>4. in-flight ID 不变 |  |
| Y | RetryRedeemInFlight.t.sol |  | P0 | admin 对 PENDING 状态的 async redeem in-flight 发起全额 retry 成功 | 同上，retryPosAmount = 原始 tokenAmount | 1. admin 调用 `retryRedeemInFlight(adapter, inFlightId, tokenAmount)` | 同上 |  |
| Y | RetryRedeemInFlight.t.sol |  | P0 | 非 admin 调用 retryRedeemInFlight 应 revert | 同上 | 1. bot 调用 `retryRedeemInFlight(...)` | revert（AccessControl 检查失败） |  |
| Y | RetryRedeemInFlight.t.sol |  | P0 | 对 sync strategy 调用 retryRedeemInFlight 应 revert RetryOnlyAsyncStrategy | sync adapter 已注册 | 1. admin 调用 `retryRedeemInFlight(syncAdapter, ...)` | revert `RetryOnlyAsyncStrategy(syncAdapter)` |  |
| Y | RetryRedeemInFlight.t.sol |  | P0 | 对已 CONFIRMED 的 in-flight 调用 retryRedeemInFlight 应 revert InvalidRedeemInFlight | redeem in-flight 已通过 settleAdapter 确认为 CONFIRMED | 1. admin 调用 `retryRedeemInFlight(adapter, confirmedId, ...)` | revert `InvalidRedeemInFlight(confirmedId)` |  |
| Y | RetryRedeemInFlight.t.sol |  | P0 | 传入的 adapter 与 in-flight 记录的 adapter 不匹配时应 revert InvalidRedeemInFlight | in-flight 归属 adapterA，传入 adapterB | 1. admin 调用 `retryRedeemInFlight(adapterB, inFlightId, ...)` | revert `InvalidRedeemInFlight(inFlightId)` |  |
| Y | RetryRedeemInFlight.t.sol |  | P0 | retryPosAmount 超过原始 in-flight tokenAmount 时应 revert InvalidRetryAmount | tokenAmount = X | 1. admin 调用 `retryRedeemInFlight(adapter, inFlightId, X+1)` | revert `InvalidRetryAmount()` |  |
| Y | RetryRedeemInFlight.t.sol |  | P0 | 对 invest 类型的 in-flight 调用 retryRedeemInFlight 应 revert InvalidRedeemInFlight | 存在 invest 类型的 PENDING in-flight | 1. admin 调用 `retryRedeemInFlight(adapter, investInFlightId, ...)` | revert `InvalidRedeemInFlight(investInFlightId)` |  |
| Y | RetryRedeemInFlight.t.sol |  | P0 | retryPosAmount = 0 时应 revert InvalidRetryAmount | 存在 PENDING redeem in-flight | 1. admin 调用 `retryRedeemInFlight(adapter, inFlightId, 0)` | revert `InvalidRetryAmount()` |  |
| Y | RetryRedeemInFlight.t.sol |  | P0 | 传入未注册的 adapter 地址应 revert InvalidStrategy | adapter 地址不在 strategyInfo 中 | 1. admin 调用 `retryRedeemInFlight(fakeAddr, inFlightId, amount)` | revert `InvalidStrategy(fakeAddr)` |  |
| Y | RetryRedeemInFlight.t.sol |  | P0 | 传入不存在的 inFlightId 应 revert InvalidRedeemInFlight | inFlightId 从未被创建（vault 返回默认值 adapter=0x0, status=NONE） | 1. admin 调用 `retryRedeemInFlight(adapter, 999, amount)` | revert `InvalidRedeemInFlight(999)` |  |
| Y | RetryRedeemInFlight.t.sol |  | P1 | retry 后正常 settle：retry -> DiGiFT 处理 -> settleAdapter sweep -> in-flight CONFIRMED -> finalize -> 用户收到 USDC | 已 retry 的 PENDING redeem in-flight | 1. retry<br>2. mock DiGiFT 返回 USDC 到 adapter<br>3. settleAdapter sweep<br>4. finalizeRedeemBatch | 1. in-flight CONFIRMED<br>2. vault USDC 增加<br>3. request 状态 DONE<br>4. 用户收到 USDC |  |
| Y | RetryRedeemInFlight.t.sol |  | P1 | DiGiFT 多次拒绝后 admin 可多次 retry 同一 in-flight | PENDING redeem in-flight | 1. retry 第一次<br>2. retry 第二次（posToken 再次返回 adapter） | 1. 两次 retry 均成功<br>2. retryCallCount=2<br>3. in-flight 仍为 PENDING |  |
| Y | RetryRedeemInFlight.t.sol |  | P1 | retry 不创建新 in-flight，原始记录的所有字段保持不变 | PENDING redeem in-flight | 1. 记录 retry 前所有字段<br>2. retry<br>3. 比较所有字段 | nextInFlightId 不变；id/adapter/token/tokenAmount/usdcAmount/settledAmount/isInvest/timestamp/status 全部不变 |  |
| Y | RetryRedeemInFlight.t.sol |  | P1 | 策略被停用后仍可 retry 已有的 in-flight（合约不检查 isActive） | 已注册 async strategy（exists=true, isAsync=true） | 1. 创建 in-flight<br>2. retry | retry 成功，验证合约只检查 exists+isAsync，不检查 isActive |  |
| Y | RetryRedeemInFlight.t.sol |  | P1 | 部分 retry 后 DiGiFT 只处理了 retry 数量对应的资产，settle 使用部分金额 | retry 60% posToken | 1. retry 60%<br>2. DiGiFT 返回 60% 对应 USDC<br>3. settleRedeem with partial amount | 1. CONFIRMED<br>2. settledAmount = partial USDC<br>3. totalRedeemInFlight 按原始 usdcAmount 扣减（不按 settled） |  |
| Y | RetryRedeemInFlight.t.sol |  | P1 | retry 后 DiGiFT 仍无法处理，通过 abnormal 路径 settle（settledAmount=0） | retry 后 DiGiFT 仍失败 | 1. retry<br>2. settleRedeem with amount=0（abnormal） | 1. CONFIRMED<br>2. settledAmount=0<br>3. totalRedeemInFlight 仍按原始 usdcAmount 扣减 |  |

## 白名单管理场景

| 是否自动化 | 测试合约 | 测试结果 | 优先级 | 测试需求描述 | 前置条件 | 测试步骤 | 期望结果 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Y | WhitelistManagement.t.sol | PASS | P0 | compliance 角色添加/移除白名单，计数正确 | SanctionsOracle 已初始化 | 1. 添加 user1<br>2. 添加 user2<br>3. 移除 user1<br>4. 重复添加 user2 | 1. 每步后 `totalWhitelistedCount` 正确<br>2. 重复操作不重复计数 |  |
| Y | WhitelistManagement.t.sol | PASS | P0 | `updateWhitelistStatus` 拒绝零地址 | SanctionsOracle 已初始化 | compliance 调用 `updateWhitelistStatus(address(0), true)` | revert `Oracle__ZeroAddress` |  |
| Y | WhitelistManagement.t.sol | PASS | P0 | 非 compliance 角色不能修改白名单 | SanctionsOracle 已初始化 | 非 compliance 调用 `updateWhitelistStatus` | revert，命中角色检查 |  |
| Y | WhitelistManagement.t.sol | PASS | P0 | 批量添加白名单，计数正确 | SanctionsOracle 已初始化 | 1. 批量添加 3 个用户<br>2. 批量移除 2 个用户 | 1. `totalWhitelistedCount` 从 0→3→1<br>2. 各用户 `isWhitelisted` 状态正确 |  |
| Y | WhitelistManagement.t.sol | PASS | P0 | 批量白名单拒绝空数组 | SanctionsOracle 已初始化 | compliance 调用 `updateWhitelistStatusBatch([], true)` | revert `Oracle__EmptyArray` |  |
| Y | WhitelistManagement.t.sol | PASS | P0 | 批量白名单拒绝超过 MAX_BATCH_SIZE | SanctionsOracle 已初始化 | compliance 调用 batch 长度 201 | revert `Oracle__BatchTooLarge(201, 200)` |  |
| Y | WhitelistManagement.t.sol | PASS | P1 | `totalWhitelistedCount` 在增删后精确追踪 | SanctionsOracle 已初始化 | 多次添加/移除/重复操作 | 1. 增加时 +1，移除时 -1<br>2. 重复移除不双重递减<br>3. 全部移除后归零 |  |

## AccountantExecutor 执行与 Accountant 暂停恢复场景

| 是否自动化 | 测试合约 | 测试结果 | 优先级 | 测试需求描述 | 前置条件 | 测试步骤 | 期望结果 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Y | AccountantExecutorQA.t.sol | PASS | P0 | bot 通过 AccountantExecutor 成功更新汇率 | AccountantExecutor 已部署，bot 有 BOT_ROLE，executor 有 EXECUTOR_ROLE | 1. 等待 cooldown<br>2. acctBot 调用 `executeUpdateRate(accountant, newRate, computeTs)` | 1. `accountant.getRate() == newRate`<br>2. `vault.exchangeRate() == newRate` |  |
| Y | AccountantExecutorQA.t.sol | PASS | P0 | 非 bot 不能调用 `executeUpdateRate` | AccountantExecutor 已部署 | 非 bot 调用 `executeUpdateRate` | revert，命中角色检查 |  |
| Y | AccountantExecutorQA.t.sol | PASS | P0 | 汇率偏差超限触发断路器暂停 | 初始汇率 1.0，maxDeviation=1% | bot 更新汇率为 1.05（5% 偏差） | 1. 汇率不更新（断路器拦截）<br>2. Accountant 进入暂停状态<br>3. `getRateSafe()` revert |  |
| Y | AccountantExecutorQA.t.sol | PASS | P0 | 汇率更新冷却期内再次更新被拒绝 | 刚成功更新过汇率，cooldown=20h | 1. 立即再次更新<br>2. 等待 20h 后更新 | 1. 立即更新 revert（CooldownNotElapsed）<br>2. 等待后更新成功 |  |
| Y | AccountantExecutorQA.t.sol | PASS | P1 | admin 暂停后恢复 Accountant，`getRateSafe` 恢复可用 | Accountant 已初始化 | 1. admin 暂停<br>2. `getRateSafe()` revert<br>3. `getRate()` 仍可用<br>4. admin unpause<br>5. `getRateSafe()` 恢复 | 暂停只影响 `getRateSafe`，不影响 `getRate` |  |
| Y | AccountantExecutorQA.t.sol | PASS | P1 | 非 admin 不能 unpause Accountant | Accountant 已暂停 | 非 admin 调用 `unpause()` | revert，命中角色检查 |  |

## Adapter 配置管理场景

| 是否自动化 | 测试合约 | 测试结果 | 优先级 | 测试需求描述 | 前置条件 | 测试步骤 | 期望结果 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Y | AdapterConfigQA.t.sol | PASS | P1 | admin 更换价格预言机地址 | SubRedManagementAdapter 已部署，初始有 priceOracle | admin 调用 `setPriceOracle(newOracle)` | `priceOracle()` 返回新地址 |  |
| Y | AdapterConfigQA.t.sol | PASS | P1 | `setPriceOracle` 可设为零地址（回退到手动价格） | Adapter 已部署 | admin 调用 `setPriceOracle(address(0))` | `priceOracle()` 返回 address(0) |  |
| Y | AdapterConfigQA.t.sol | PASS | P1 | 非 admin 不能更换价格预言机 | Adapter 已部署 | 非 admin 调用 `setPriceOracle` | revert，命中角色检查 |  |
| Y | AdapterConfigQA.t.sol | PASS | P1 | admin 修改申购截止窗口 | 默认 `subscribeDeadlineWindow=6h` | 1. 验证默认值<br>2. admin 设为 12h<br>3. admin 设为 0 | 各步骤值正确更新 |  |
| Y | AdapterConfigQA.t.sol | PASS | P1 | 非 admin 不能修改申购截止窗口 | Adapter 已部署 | 非 admin 调用 `setSubscribeDeadlineWindow` | revert，命中角色检查 |  |
| Y | AdapterConfigQA.t.sol | PASS | P1 | admin 修改赎回截止窗口 | 默认 `redeemDeadlineWindow=6h` | admin 设为 24h | 值正确更新 |  |
| Y | AdapterConfigQA.t.sol | PASS | P1 | 非 admin 不能修改赎回截止窗口 | Adapter 已部署 | 非 admin 调用 `setRedeemDeadlineWindow` | revert，命中角色检查 |  |

## 数值边界与精度场景

| 是否自动化 | 测试合约 | 测试结果 | 优先级 | 测试需求描述 | 前置条件 | 测试步骤 | 期望结果 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Y | NumericalBoundary.t.sol | PASS | P2 | 1 wei USDC 存入时份额行为（minDeposit=0, rate=1.0） | Vault 已初始化，`minDepositAmount=0` | 存入 1 wei USDC | 获得 1 share（1 * 1e18 / 1e18 = 1） |  |
| Y | NumericalBoundary.t.sol | PASS | P2 | 存款金额低于 `minDepositAmount` 时被拒绝 | `minDepositAmount=1e6` | 1. 存入 0.5e6 -> revert<br>2. 存入 1e6 -> 成功 | 低于最小值被拒绝，等于时通过 |  |
| Y | NumericalBoundary.t.sol | PASS | P2 | 1 share 赎回时 Ceil 舍入导致手续费 >= 净值 | 存入 1 wei 获得 1 share，`fee=1%` | `previewRedeem(1)` | fee=ceil(1*100/10000)=1，net=1-1=0，手续费吞掉全部价值 |  |
| Y | NumericalBoundary.t.sol | PASS | P2 | fee=0 时极小份额赎回无舍入问题 | `redemptionFeeBps=0`，1 share | `redeem(1)` | 净得 1 wei，无舍入损失 |  |
| Y | NumericalBoundary.t.sol | PASS | P2 | `bufferTargetBps=0` 时全部资金投入策略 | 用户已存款 10000e6 | `setRiskParams(0,0,0)` + `rebalance()` | `freeCash=0`，adapter 持有全部资金 |  |
| Y | NumericalBoundary.t.sol | PASS | P2 | `bufferTargetBps=10000` 时不投资（全部保留为 buffer） | 用户已存款 10000e6 | `setRiskParams(10000,0,0)` + `rebalance()` | adapter 无资金，`freeCash=10000e6` |  |
| Y | NumericalBoundary.t.sol | PASS | P2 | `rebalanceThresholdBps=10000` 时几乎不触发投资或撤资 | 用户已存款 10000e6，buffer=50% | `setRiskParams(5000,10000,0)` + `rebalance()` | 投资条件 freeCash>15000 不可能满足，adapter 为 0 |  |
| Y | NumericalBoundary.t.sol | PASS | P2 | `setRiskParams` 拒绝超过 10000 bps 的参数 | Controller 已初始化 | 1. `setRiskParams(10001,200,0)` -> revert<br>2. `setRiskParams(1000,10001,0)` -> revert<br>3. `setRiskParams(10000,10000,0)` -> 成功 | 10001 被拒绝 (`InvalidBps`)，10000 接受 |  |
| Y | NumericalBoundary.t.sol | PASS | P2 | Accountant `maxDeviation=0` 被拒绝 | Accountant 已初始化 | `setRiskParams(0, 20h)` | revert `InvalidDeviation` |  |
| Y | NumericalBoundary.t.sol | PASS | P2 | Accountant `maxDeviation > 1000` 被拒绝 | Accountant 已初始化 | 1. `setRiskParams(1001, 20h)` -> revert<br>2. `setRiskParams(1000, 20h)` -> 成功 | 1001 被拒绝，1000 接受（`MAX_DEVIATION_CEILING=1000`） |  |
| Y | NumericalBoundary.t.sol | PASS | P2 | Accountant `minInterval=0` 允许每个区块更新汇率 | Accountant 已初始化 | 1. `setRiskParams(100, 0)`<br>2. 连续两次 `updateExchangeRate`（间隔 1s） | 两次更新均成功，无冷却限制 |  |
| Y | NumericalBoundary.t.sol | PASS | P2 | 多笔小额赎回 vs 单笔大额赎回的费率累积差异 | 两用户各存 1000e6，fee=1% | 1. userA 分 10 笔赎回<br>2. userB 1 笔赎回 | 1. 单笔 >= 多笔（Ceil 舍入累积）<br>2. 差异 <= 10 wei（可忽略） |  |
| Y | NumericalBoundary.t.sol | PASS | P2 | exchangeRate = 3（不整除）shares<->USDC 往返舍入验证 | Vault 已初始化，MockAccountant rate=3 | 1. 存入 10 wei USDC<br>2. 计算 shares = floor(10 * 1e18 / 3)<br>3. previewRedeem(shares) | 1. shares = 3333333333333333333<br>2. previewRedeem = 9（往返损失恰好 1 wei）<br>3. 损失由两次 Floor 整除导致 | test_Precision_IndivisibleExchangeRate_ShareConversion |
| Y | NumericalBoundary.t.sol | PASS | P2 | exchangeRate = 1e18+1（最小增量）share 转换精度 | Vault 已初始化，MockAccountant rate=1e18+1 | 1. 存入 1000 USDC<br>2. previewRedeem(shares) | 1. 往返损失 <= 1 wei<br>2. previewRedeem 与 `shares * rate / 1e18` 公式一致 | test_Precision_NearUnityRate_MinimalIncrement |
| Y | NumericalBoundary.t.sol | PASS | P2 | posTokenPrice = 7e17（质数级价格）USDC(6dec)->ST(18dec) 跨精度换算 | adapter posTokenPrice=7e17，USDC 6 decimals，posToken 18 decimals | 1. 存入 1000 USDC 并 rebalance + settle<br>2. 验证 posToken 数量 = `mulDiv(amount, 1e18*stScale, price*assetScale, Floor)`<br>3. 验证 adapter.totalValue() 反向换算<br>4. 验证往返损失 | 1. posToken 数量与公式一致<br>2. totalValue 与反向公式一致<br>3. USDC->posToken->USDC 往返损失 <= 1 wei | test_Precision_PrimePrice_CrossDecimalConversion |
| Y | NumericalBoundary.t.sol | PASS | P2 | totalAssets 两步 Floor vs adapter 一步 Floor 差值验证 | adapter posTokenPrice=3e17（0.3 USDC/ST），6/18 decimal 差异 | 1. 存入 777 USDC 并 rebalance + settle<br>2. 手动计算 vault 两步 Floor 和 adapter 一步 Floor<br>3. 对比 vault.totalAssets() | 1. 两步 vs 一步差值 <= 1 wei<br>2. vault.totalAssets() 等于两步 Floor 计算值<br>3. 与原始存款差值 <= 1 wei | test_Precision_TotalAssets_TwoStepVsOneStep_Floor |
| Y | NumericalBoundary.t.sol | PASS | P2 | exchangeRate=1e18+3 + posTokenPrice=3e17 组合全链路精度 | MockAccountant rate=1e18+3，adapter price=3e17 | 1. 存入 5000 USDC<br>2. rebalance + settle<br>3. 验证 totalAssets 与存款差值<br>4. 验证 previewRedeem 与公式一致 | 1. shares 与 `mulDiv(assets, 1e18, rate, Floor)` 一致<br>2. totalAssets 与存款差值 <= 2 wei<br>3. share->USDC 往返损失 <= 1 wei | test_Precision_UglyRate_UglyPrice_FullChain |
| Y | NumericalBoundary.t.sol | PASS | P2 | posTokenPrice = 1e30（天价 token）无溢出验证 | adapter posTokenPrice=1e30（1 ST = 1e12 USDC） | 1. 存入 10000 USDC 并 rebalance + settle<br>2. 验证 totalValue 往返<br>3. 验证 totalAssets 无溢出 | 1. posToken 数量与公式一致<br>2. 往返损失 <= 1 wei<br>3. totalAssets 无溢出，差值 <= 2 wei | test_Precision_LargePosTokenPrice_NoOverflow |
| Y | NumericalBoundary.t.sol | PASS | P2 | posTokenPrice = 1（1e-18 USDC/ST）极大 posToken 数量验证 | adapter posTokenPrice=1，1 USDC 产生 1e36 posToken-wei | 1. 存入 1 USDC 并 rebalance + settle<br>2. 验证 posToken 数量 = 1e36<br>3. 验证 totalValue 和 totalAssets | 1. posToken 数量 = 1e36（精确）<br>2. totalValue = 1e6（精确往返）<br>3. totalAssets = 1e6（与存款一致） | test_Precision_TinyPosTokenPrice_MassiveTokenAmount |
