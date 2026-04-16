#!/usr/bin/env bash
set -uo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <test_function_name>"
    echo "Example: $0 test_UpdateStrategies_RevertLengthMismatch"
    exit 1
fi

FUNC="$1"
LOG_DIR="logs"
mkdir -p "$LOG_DIR"

TEST_DIR="test/qa"

# Find the test file containing this function
test_file=$(grep -rl "function ${FUNC}" "$TEST_DIR"/*.t.sol 2>/dev/null | head -1)

if [ -z "$test_file" ]; then
    echo "Error: test function '${FUNC}' not found in ${TEST_DIR}/"
    exit 1
fi

filename=$(basename "$test_file" .t.sol)
log_name="${FUNC#test_}"
log_file="$LOG_DIR/${filename}_${log_name}.log"

echo "=========================================="
echo "Running: $filename::$FUNC"
echo "Log:     $log_file"
echo "=========================================="

forge test --match-path "$test_file" --match-test "${FUNC}" -vvvv 2>&1 | tee "$log_file"
forge_exit=${PIPESTATUS[0]}

if [ $forge_exit -eq 0 ]; then
    echo "✅ PASSED: $FUNC"
else
    echo -e "\n----------------------------------------\ntest result: failed" >> "$log_file"
    echo "❌ FAILED: $FUNC (see $log_file)"
fi
