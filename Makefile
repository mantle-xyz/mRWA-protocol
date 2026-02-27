-include .env

.PHONY: all build clean test fmt snapshot gas lint deploy upgrade

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

# ==================== Deploy (Mantle Sepolia) ====================

deploy-sepolia:
	forge script script/Deploy.s.sol:DeployScript \
		--rpc-url mantle_sepolia \
		--broadcast \
		--verify \
		--verifier etherscan \
		-vvvv

# ==================== Deploy (Mainnet) ====================

deploy-mainnet:
	forge script script/Deploy.s.sol:DeployScript \
		--rpc-url mainnet \
		--broadcast \
		--verify \
		--verifier etherscan \
		-vvvv

# ==================== Upgrade ====================

upgrade-sepolia:
	forge script script/Upgrade.s.sol:UpgradeScript \
		--rpc-url mantle_sepolia \
		--broadcast \
		--verify \
		--verifier etherscan \
		-vvvv

# ==================== Utilities ====================

slither:
	slither .

sizes:
	forge build --sizes
