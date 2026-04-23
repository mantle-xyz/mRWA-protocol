-include .env

.PHONY: all build clean test fmt snapshot gas lint install-hooks setup \
        coverage coverage-html coverage-open coverage-clean

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

# ==================== Coverage ====================
# 只统计 test/qa 和 test/stress 两个目录的用例。
# 详见 COVERAGE.md。
#
# 已知问题：forge coverage 强制使用 --ir-minimum（最小优化），
# 本仓库的 StrategyController.sol 在该优化级别下会 stack too deep
# （Foundry issue #3357）。暂时的变通：跳过 Deploy 脚本 + 接受该限制，
# 详细绕过方案见 COVERAGE.md 第 5 节。

COVERAGE_DIR       ?= coverage
COVERAGE_LCOV      := $(COVERAGE_DIR)/lcov.info
COVERAGE_FILTERED  := $(COVERAGE_DIR)/lcov.filtered.info
COVERAGE_HTML_DIR  := $(COVERAGE_DIR)/html
COVERAGE_MATCH     ?= test/{qa,stress}/**/*.sol
# 跳过 Deploy 脚本编译，降低 --ir-minimum 的 stack 压力
COVERAGE_SKIP      ?= --skip DeployAll.s.sol --skip DeployInit.s.sol

# 生成原始 lcov tracefile（只跑 test/qa + test/stress）
# 使用 stress profile 拿到 2GB memory_limit；日志落到 tmp/coverage.log
coverage:
	@mkdir -p $(COVERAGE_DIR) tmp
	FOUNDRY_PROFILE=stress forge coverage \
	    --ir-minimum \
	    $(COVERAGE_SKIP) \
	    --report lcov \
	    --report-file $(COVERAGE_LCOV) \
	    --match-path "$(COVERAGE_MATCH)" \
	    > tmp/coverage.log 2>&1 || \
	    (echo "forge coverage failed; see tmp/coverage.log (likely stack too deep, see COVERAGE.md §5)"; exit 1)
	@echo "lcov saved: $(COVERAGE_LCOV) ($$(wc -l < $(COVERAGE_LCOV)) lines)"
	@echo "log:        tmp/coverage.log"

# 过滤 lib/ test/ script/ 后生成 HTML
coverage-html: coverage
	@mkdir -p tmp
	lcov --remove $(COVERAGE_LCOV) \
	    'lib/*' 'test/*' 'script/*' 'scripts/*' \
	    --output-file $(COVERAGE_FILTERED) \
	    --rc derive_function_end_line=0 \
	    --ignore-errors unused,inconsistent \
	    > tmp/lcov_filter.log 2>&1
	genhtml $(COVERAGE_FILTERED) \
	    --output-directory $(COVERAGE_HTML_DIR) \
	    --title "mRWA-protocol coverage (qa+stress)" \
	    --branch-coverage \
	    --rc derive_function_end_line=0 \
	    --ignore-errors inconsistent,corrupt \
	    > tmp/genhtml.log 2>&1
	@echo "HTML report: $(COVERAGE_HTML_DIR)/index.html"

coverage-open: coverage-html
	@open $(COVERAGE_HTML_DIR)/index.html

coverage-clean:
	rm -rf $(COVERAGE_DIR) tmp/coverage.log tmp/lcov_filter.log tmp/genhtml.log
