-include .env

# Single signing key for deployment/upgrade scripts.
NETWORK ?= mantle_sepolia
VERIFY ?= true

VERIFY_FLAGS :=
ifeq ($(VERIFY),true)
VERIFY_FLAGS += --verify --verifier etherscan
endif

.PHONY: all build clean test fmt snapshot gas lint \
	deploy-strategy-beacon-timelock deploy-strategy-beacon-proxy \
	prepare-strategy-beacon-upgrade-safe upgrade-strategy-beacon-local

all: clean install build

# ==================== Setup ====================

install:
	forge install

update:
	forge update

# ==================== Build ====================

build:
	forge build

clean:
	forge clean

# ==================== Test ====================

test:
	forge test -vvv

test-gas:
	forge test -vvv --gas-report

snapshot:
	forge snapshot

# ==================== Lint & Format ====================

fmt:
	forge fmt

fmt-check:
	forge fmt --check

lint:
	forge fmt --check && forge build

# ==================== Timelock + Beacon (StrategyController) ====================

deploy-strategy-beacon-timelock:
	@forge script script/DeployStrategyBeaconWithTimelock.s.sol:DeployStrategyBeaconWithTimelockScript \
		--rpc-url $(NETWORK) \
		--broadcast \
		$(VERIFY_FLAGS) \
		-vvvv

deploy-strategy-beacon-proxy:
	@forge script script/DeployStrategyBeaconProxy.s.sol:DeployStrategyBeaconProxyScript \
		--rpc-url $(NETWORK) \
		--broadcast \
		$(VERIFY_FLAGS) \
		-vvvv

prepare-strategy-beacon-upgrade-safe:
	@UPGRADE_EXECUTE_ONCHAIN=false \
	forge script script/PrepareStrategyBeaconUpgradeForSafe.s.sol:PrepareStrategyBeaconUpgradeForSafeScript \
		--rpc-url $(NETWORK) \
		-vvvv

upgrade-strategy-beacon-local:
	@UPGRADE_EXECUTE_ONCHAIN=true \
	forge script script/PrepareStrategyBeaconUpgradeForSafe.s.sol:PrepareStrategyBeaconUpgradeForSafeScript \
		--rpc-url $(NETWORK) \
		--broadcast \
		$(VERIFY_FLAGS) \
		-vvvv

# ==================== Utilities ====================

slither:
	slither .

sizes:
	forge build --sizes
