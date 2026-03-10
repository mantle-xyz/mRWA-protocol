# StrategyController: Beacon + Timelock

## 1) Deploy timelock + strategy beacon (optional first proxy)

```bash
export DEPLOYER_PRIVATE_KEY=0x...
export TIMELOCK_MIN_DELAY=86400
export TIMELOCK_PROPOSER=0xSAFE
export TIMELOCK_EXECUTOR=0xSAFE
export TIMELOCK_ADMIN=0xDEPLOYER
export TIMELOCK_RENOUNCE_ADMIN=true

export STRATEGY_DEPLOY_FIRST_PROXY=true
export STRATEGY_VAULT=0x...
export STRATEGY_ADMIN=0xTIMELOCK_OR_SAFE
export STRATEGY_OPERATOR=0xOPS_SAFE
export STRATEGY_EXECUTOR=0x...
export STRATEGY_BUFFER_TARGET_BPS=500
export STRATEGY_REBALANCE_THRESHOLD_BPS=100
export STRATEGY_REBALANCE_COOLDOWN=3600

forge script script/DeployStrategyBeaconWithTimelock.s.sol:DeployStrategyBeaconWithTimelockScript \
  --rpc-url mantle_sepolia --broadcast
```

## 2) Deploy additional strategy instances from the same beacon

```bash
export DEPLOYER_PRIVATE_KEY=0x...
export STRATEGY_BEACON=0x...
export STRATEGY_VAULT=0x...
export STRATEGY_ADMIN=0x...
export STRATEGY_OPERATOR=0x...
export STRATEGY_EXECUTOR=0x...
export STRATEGY_BUFFER_TARGET_BPS=500
export STRATEGY_REBALANCE_THRESHOLD_BPS=100
export STRATEGY_REBALANCE_COOLDOWN=3600

forge script script/DeployStrategyBeaconProxy.s.sol:DeployStrategyBeaconProxyScript \
  --rpc-url mantle_sepolia --broadcast
```

## 3) Prepare Safe calldata for beacon upgrade

```bash
export TIMELOCK_ADDRESS=0x...
export STRATEGY_BEACON=0x...
export NEW_IMPLEMENTATION=0x...
export DEPLOY_NEW_IMPLEMENTATION=false
export UPGRADE_EXECUTE_ONCHAIN=false
export UPGRADE_CALLER_PRIVATE_KEY=0x...
export UPGRADE_PREDECESSOR=0x0000000000000000000000000000000000000000000000000000000000000000
export UPGRADE_SALT=0x1111111111111111111111111111111111111111111111111111111111111111
export UPGRADE_DELAY=86400

forge script script/PrepareStrategyBeaconUpgradeForSafe.s.sol:PrepareStrategyBeaconUpgradeForSafeScript \
  --rpc-url mantle_sepolia
```

Use output as two Safe tx:
1. `target = TIMELOCK_ADDRESS`, `data = schedule(...)`
2. after delay: `target = TIMELOCK_ADDRESS`, `data = execute(...)`

For local direct upgrade (single run), set:
- `UPGRADE_EXECUTE_ONCHAIN=true`
- `UPGRADE_DELAY=0`

Then run with `--broadcast` to send tx onchain.
