#!/usr/bin/env bash
set -uo pipefail

LOG_DIR="logs"
mkdir -p "$LOG_DIR"

rm -rf "$LOG_DIR"/*

TEST_DIR="test/qa"
PASSED=0
FAILED=0
FAILED_LIST=()

START_TIME=$(date +%s)

for test_file in "$TEST_DIR"/*.t.sol; do
    filename=$(basename "$test_file" .t.sol)

    # Extract test function names
    test_functions=$(grep -o 'function test[A-Za-z0-9_]*' "$test_file" | sed 's/function //')

    for func in $test_functions; do
        log_name="${func#test_}"
        log_file="$LOG_DIR/${filename}_${log_name}.log"

        echo "=========================================="
        echo "Running: $filename::$func"
        echo "Log:     $log_file"
        echo "=========================================="

        forge test --match-path "test/qa/${filename}.t.sol" --match-test "${func}" -vvvv 2>&1 | tee "$log_file"
        forge_exit=${PIPESTATUS[0]}

        if [ $forge_exit -eq 0 ]; then
            echo "✅ PASSED: $func"
            ((PASSED++))
        else
            echo -e "\n----------------------------------------\ntest result: failed" >> "$log_file"
            echo "❌ FAILED: $func (see $log_file)"
            ((FAILED++))
            FAILED_LIST+=("$filename::$func")
        fi
        echo ""
    done
done

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
MINUTES=$((ELAPSED / 60))
SECONDS=$((ELAPSED % 60))

echo "=========================================="
echo "Summary: $PASSED passed, $FAILED failed"
if [ ${#FAILED_LIST[@]} -gt 0 ]; then
    echo "Failed tests:"
    for f in "${FAILED_LIST[@]}"; do
        echo "  - $f"
    done
fi
echo "Total time: ${MINUTES}m ${SECONDS}s"
echo "=========================================="
