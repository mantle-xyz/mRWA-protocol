# mRWA Protocol

## Prerequisites

- Foundry is installed
- `task` and `yq` are installed
- `.env` is configured (see `.env.example`)
- `rpc_endpoints` are configured in `foundry.toml`
- `deploy-config/<network>/<profile>.yaml` is prepared

## Common Commands

```bash
make build
make test
```

**Pre-commit auto-formatting (repo only):** run `make install-hooks` once at the repository root. After that, every `git commit` will run `forge fmt` and re-stage modified `.sol` files automatically.

## Deployment and Upgrades

All deployment and upgrade operations are executed through `Taskfile.yaml`.

Common commands:

```bash
NETWORK=mantle-sepolia task DeployAll
NETWORK=mantle-sepolia task RegisterStrategy
NETWORK=mantle-sepolia task UpgradeAll
```

Upgrade individual modules:

```bash
NETWORK=mantle-sepolia task UpgradeSanctionsOracle
NETWORK=mantle-sepolia task UpgradeAccountant
NETWORK=mantle-sepolia task UpgradeStrategyController
NETWORK=mantle-sepolia task UpgradeGateway
NETWORK=mantle-sepolia task UpgradeVault
NETWORK=mantle-sepolia task UpgradeOperatorExecutor
NETWORK=mantle-sepolia task UpgradeAccountantExecutor
```

You can also pass through Foundry arguments:

```bash
NETWORK=mantle-sepolia task DeployAll -- --broadcast -vvvv
NETWORK=mantle-sepolia task UpgradeVault -- --broadcast
```

## Task Parameters

- `NETWORK`: maps to `deploy-config/<network>/`
- `PROFILE`: defaults to `default`
- `CLI_ARGS`: passed through to `forge script`

## Security Notes

- Do not commit `.env`
- `F_PRIVATE_KEY` must include the `0x` prefix
- If a private key is exposed, rotate it immediately and migrate permissions
