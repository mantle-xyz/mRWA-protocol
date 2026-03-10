# mRWA Protocol

当前 `StrategyController` 采用：

- `TimelockUpgradeController`：治理与延迟执行
- `UpgradeableBeacon`：统一实现地址
- `BeaconProxy`：每个 Vault 一套实例

## 基础要求

- 已安装 Foundry
- 已配置 `.env`（参考 `.env.example`）
- `foundry.toml` 中已配置对应 `rpc_endpoints`

## 常用命令

```bash
make build
make test
```

## 部署流程

### 1) 部署治理与 Beacon

```bash
make deploy-strategy-beacon-timelock VERIFY=false
```

会部署：

- `TimelockUpgradeController`
- `StrategyController` implementation
- `UpgradeableBeacon`

若 `STRATEGY_DEPLOY_FIRST_PROXY=true`，会顺带部署首个 `BeaconProxy`。

### 2) 部署某个 Vault 对应的 Strategy 实例

`.env` 至少需要：

- `STRATEGY_BEACON`
- `STRATEGY_VAULT`
- `STRATEGY_ADMIN`（通常填 Timelock）
- `STRATEGY_OPERATOR`（运营多签/运维地址）
- `STRATEGY_EXECUTOR`（执行器合约或受控地址）

执行：

```bash
make deploy-strategy-beacon-proxy VERIFY=false
```

每换一个 `STRATEGY_VAULT` 再执行一次，即新增一套实例。

## 升级流程（Beacon）

同一个 Beacon 下的所有 Proxy 会一起升级。

### A. Safe 模式（推荐）

```bash
make prepare-strategy-beacon-upgrade-safe
```

脚本会输出 `schedule` / `execute` calldata：

1. 先提交 `schedule(...)`
2. 延迟到期后提交 `execute(...)`

### B. 本地直升（测试用）

```bash
make upgrade-strategy-beacon-local VERIFY=false
```

该模式适合本地/测试快速验证，不建议直接用于生产治理。

## Make 参数

- `NETWORK`：默认 `mantle_sepolia`（需在 `foundry.toml` 存在）
- `VERIFY`：`true/false`，默认 `true`

示例：

```bash
make deploy-strategy-beacon-timelock NETWORK=mantle VERIFY=true
make deploy-strategy-beacon-proxy NETWORK=mantle_sepolia VERIFY=false
```

## 安全提示

- 不要提交 `.env`
- `PRIVATE_KEY` 必须带 `0x` 前缀
- 私钥一旦泄露，立即更换并迁移权限
