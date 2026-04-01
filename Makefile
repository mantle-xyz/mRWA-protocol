-include .env

.PHONY: all build clean test fmt snapshot gas lint install-hooks setup

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

# only for this repo, not for submodules, only run once
install-hooks:
	git config core.hooksPath .githooks

setup: install-hooks
	@MIN="1.4.1"; \
	CUR=$$(forge --version 2>/dev/null | head -1 | sed 's/^[^0-9]*//' | cut -d- -f1); \
	if [ -z "$$CUR" ] || [ "$$(printf '%s\n' "$$MIN" "$$CUR" | sort -V | head -1)" != "$$MIN" ]; then \
		echo "forge $$CUR < $$MIN, installing v$$MIN ..."; \
		foundryup -i v$$MIN; \
	else \
		echo "forge $$CUR >= $$MIN, OK"; \
	fi

slither:
	slither .

sizes:
	forge build --sizes
