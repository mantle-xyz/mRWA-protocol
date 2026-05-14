#!/usr/bin/env bash
set -o pipefail

# =============================================================================
#  mRWA Stress Test Runner — Multi-Seed, Duration-Based
# =============================================================================
#  持续测试指定分钟数，自动循环不同种子。每次 forge test = 独立 EVM，内存不累积。
#  聚合数据通过 stress_logs/.cache/aggregate.tsv (由 Solidity 端每 seed-run 追加) 计算。
#
#  Usage:
#    ./test/stress/run_stress.sh 10          # 持续跑 10 分钟
#    ./test/stress/run_stress.sh 30 S1 S7    # 仅 S1 和 S7，跑 30 分钟
#    ./test/stress/run_stress.sh 0           # 不限时，跑 STRESS_SEEDS 轮后停止
#
#  Env overrides:
#    STRESS_ROUNDS=100 STRESS_USERS=30 ./test/stress/run_stress.sh 10
#    STRESS_SEED=99999 STRESS_SEEDS=1  ./test/stress/run_stress.sh 0   # 单种子复现
#    STRESS_LOG_LEVEL=DEBUG ./test/stress/run_stress.sh 10   # 日志等级：DEBUG/INFO/WARN/ERROR/CRIT
#
#  Flags:
#    --reset-cache   清除 .cache/aggregate.tsv，从零开始聚合
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPORT_DIR="$PROJ_DIR/stress_logs"
TSV_FILE="$REPORT_DIR/.cache/aggregate.tsv"

rm -rf $REPORT_DIR/*

# --- Parse flags ---
RESET_CACHE=false
POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        --reset-cache) RESET_CACHE=true ;;
        *) POSITIONAL+=("$arg") ;;
    esac
done
set -- "${POSITIONAL[@]}"

# --- Parse duration (first arg, required) ---
if [[ $# -lt 1 ]]; then
    cat <<'USAGE'
Usage: run_stress.sh <duration_minutes> [S1] [S2] ... [S14] [--reset-cache]

  duration_minutes: total wall-clock time to keep testing (0 = run STRESS_SEEDS rounds then stop)
  --reset-cache:    clear the TSV aggregate cache before starting

Examples:
  ./run_stress.sh 10              # all cases, run for 10 minutes
  ./run_stress.sh 30 S1 S7       # S1 and S7 only, run for 30 minutes
  ./run_stress.sh 0              # all cases, run STRESS_SEEDS rounds (default 5)

Env overrides:
  STRESS_SEEDS=10                 # max seed rounds when duration=0 (default 5)
  STRESS_ROUNDS=100               # rounds per seed-run (default 50)
  STRESS_DAYS=30                  # simulated days for S7 per seed-run (default 60, auto-reduced for large user pools)
  STRESS_USERS=30                 # number of test users (default 20)
  STRESS_SEED=99999               # base seed (default 12345)
  STRESS_SEEDS=1                  # single seed = reproduce a specific run
  STRESS_LOG_LEVEL=DEBUG          # log level: DEBUG/INFO/WARN/ERROR/CRIT (default INFO)
USAGE
    exit 1
fi

DURATION_MIN="$1"
DURATION_SEC=$((DURATION_MIN * 60))
shift

# Remaining args are scenario filters
SELECTED=("$@")

# --- Config ---
BASE_SEED="${STRESS_SEED:-12345}"
MAX_SEEDS="${STRESS_SEEDS:-5}"          # only used when duration=0
ROUNDS_PER_SEED="${STRESS_ROUNDS:-50}"
DAYS_PER_SEED="${STRESS_DAYS:-60}"
USER_COUNT="${STRESS_USERS:-20}"

export STRESS_USERS="$USER_COUNT"
export STRESS_ROUNDS="$ROUNDS_PER_SEED"
export STRESS_DAYS="$DAYS_PER_SEED"
export STRESS_DURATION="0"              # per-seed: no time limit (use ROUNDS)

# --- Scenario definitions ---
KEYS=(       S1                        S2                          S3                        S4                            S5                              S6                        S7                          S8                              S9                       S10                              S11                          S12                            S13                        S14                              )
CONTRACTS=(  S1_DepositRedeemMix       S2_AsyncRedeemFullCycle     S3_RebalanceSettlement    S4_ExchangeRateFeeAccrual     S5_SanctionedUserInterlace      S6_InFlightEdgeCases      S7_FullProtocolEndurance     S8_InvestSettlementEdge          S9_MultiAdapterMix       S10_InterleavedOperations         S11_AdapterPauseRecovery     S12_CircuitBreakerRecovery     S13_DailyCapExhaustion     S14_ConcurrentBatchProcessing    )
FUNCS=(      test_depositRedeemMix     test_asyncRedeemFullCycle   test_rebalanceSettlementCycle test_exchangeRateFeeAccrual test_sanctionedUserInterlace  test_inFlightEdgeCases    test_fullProtocolEndurance   test_investSettlementEdge        test_multiAdapterMix     test_interleavedOperations        test_adapterPauseRecovery    test_circuitBreakerRecovery    test_dailyCapExhaustion    test_concurrentBatchProcessing   )
NAMES=(      "Deposit/Redeem Mix"      "Async Redeem Cycle"        "Rebalance Settlement"    "Exchange Rate & Fee"         "Sanctioned User"               "InFlight Edge Cases"     "Full Protocol Endurance"    "Invest Settlement Edge"         "Multi-Adapter Mix"      "Interleaved Operations"          "Adapter Pause Recovery"     "Circuit Breaker Recovery"     "Daily Cap Exhaustion"     "Concurrent Batch Processing"    )

# Scenario descriptions (from STRESS_TEST_PLAN.md §八)
DESCS=(
    "验证大量 sync deposit + sync redeem 交替执行下份额/资产计算的精度和 freeCash 正确性"
    "验证 requestRedeem -> processRedeemBatch -> finalizeRedeemBatch 全链路在大量请求下的状态机正确性和资金守恒"
    "验证反复 invest/divest 及 settlement 后资金守恒和策略权重正确"
    "验证频繁 NAV 更新下 circuit breaker 正确性，以及 management fee 长期累积精度"
    "验证制裁/解除制裁在各交易流程中的正确性，尤其穿插在正常用户交易之间"
    "验证 in-flight 记录在各种异常结算场景下的账本正确性（退款/部分结算/零结算/重试）"
    "串联所有核心流程，模拟多日真实运行，验证系统长期稳定性"
    "验证Invest部分结算(5-95%退款)和全额退款(底层资产无法申购)场景下vault资产守恒和in-flight记录正确性"
    "验证3个adapter非对称权重(40/35/25)下rebalance分配、混合结算、权重动态调整的正确性"
    "验证操作交错场景：双IF共存、rate变化在process↔finalize间、重叠PROCESSING批次+乱序finalize、PROCESSING期间deposit/syncRedeem、PENDING时rebalance"
    "验证adapter暂停/恢复期间rebalance跳过暂停adapter、用户操作不受影响、unpause后恢复正常"
    "验证汇率偏离触发熔断→accountant暂停→deposit/redeem阻断→admin通过emergencyRateUpdate恢复→操作恢复"
    "验证每日存取限额耗尽后交易被拒绝、限额重置后恢复正常"
    "验证多个PROCESSING批次同时存在时的交错结算和最终化，in-flight记账正确性"
)

# Test method per round (from STRESS_TEST_PLAN.md §八)
METHODS=(
    "随机选用户 -> 60%概率deposit / 40%概率syncRedeem -> 每笔delta校验 -> 每轮检查I1,I2,I3,I6不变量"
    "积累requestRedeem -> processBatch(触发divest) -> inject shortfall -> finalizeBatch -> 验证请求状态PENDING->PROCESSING->DONE"
    "deposit积累 -> rebalance(invest到adapter) -> settle invest -> requestRedeem(触发divest) -> settle redeem -> finalize -> 验证in-flight清零"
    "每轮jitter exchangeRate ±2%(clamp到maxDeviation) -> 穿插deposit/redeem -> 验证rate单调性和treasury fee增长"
    "随机制裁/解除用户 -> 被制裁用户尝试操作(验证revert/路由sanctionSafe) -> 正常用户交易不受影响"
    "6种case轮转: A=正常invest结算, B=invest退款, C=部分redeem结算(30-80%), D=零结算(全损), E=混合并发, F=retryRedeemInFlight"
    "模拟N天: 早=deposit, 午=NAV更新+fee, 下午=requestRedeem+syncRedeem, 晚=processBatch+rebalance+settle+finalize+全量不变量检查"
    "5种case轮转: A=正常全额结算, B=小比例退款(5-15%), C=大比例退款(40-70%), D=全额退款(0+100%), E=混合多笔不同比例"
    "每轮: 比例化存款→rebalance验证3-adapter分配→settle(sync1正常/sync2部分退款/async1随机)→divest+finalize; 每10轮jitter价格, 每20轮调权重"
    "7种case轮转: A=双IF共存, B=rate变化+finalize, C=重叠批次+乱序finalize, D=PROCESSING期间deposit, E=PROCESSING期间syncRedeem, F=PENDING时rebalance, G=全组合kitchen-sink; 每step间检查不变量"
    "每3轮: pause sync adapter -> rebalance(跳过) -> 用户deposit/redeem -> unpause -> 验证不变量"
    "每4轮: 正常deposit -> 触发极端rate跳变→熔断暂停 -> emergencyRateUpdate恢复 -> 恢复正常操作"
    "每轮: N个用户尝试deposit(耗尽cap) -> N个用户尝试redeem(耗尽cap) -> 每5轮重置限额"
    "每轮: 两波requestRedeem -> 分别processBatch(两批同时PROCESSING) -> settle -> finalize -> 验证无残留PROCESSING"
)

should_run() {
    local key="$1"
    if [[ ${#SELECTED[@]} -eq 0 ]]; then return 0; fi
    for s in "${SELECTED[@]}"; do
        if [[ "$s" == "$key" ]]; then return 0; fi
    done
    return 1
}

# Build list of active scenario indices
ACTIVE_INDICES=()
for i in "${!KEYS[@]}"; do
    if should_run "${KEYS[$i]}"; then
        ACTIVE_INDICES+=("$i")
    fi
done

# --- Prepare ---
mkdir -p "$REPORT_DIR/.cache"

# Reset cache if requested
if $RESET_CACHE; then
    rm -f "$TSV_FILE"
    echo "  [reset] Cleared $TSV_FILE"
fi

# Clean up legacy per-round log files (no longer generated, but clear residuals)
rm -f "$REPORT_DIR"/*_round_*.log

GLOBAL_REPORT="$REPORT_DIR/SUMMARY_REPORT.log"

# Per-case tracking (parallel arrays)
declare -a CASE_PASS CASE_FAIL CASE_FAIL_SEEDS CASE_SEEDS_RUN
for i in "${ACTIVE_INDICES[@]}"; do
    CASE_PASS[$i]=0
    CASE_FAIL[$i]=0
    CASE_FAIL_SEEDS[$i]=""
    CASE_SEEDS_RUN[$i]=0
done

TOTAL_START=$(date +%s)
TOTAL_SEED_ROUNDS=0

# --- Helper: check if time is up ---
time_up() {
    if [[ "$DURATION_SEC" -eq 0 ]]; then return 1; fi  # duration=0 → never time-up
    local elapsed=$(( $(date +%s) - TOTAL_START ))
    [[ $elapsed -ge $DURATION_SEC ]]
}

# --- Helper: format elapsed time ---
fmt_elapsed() {
    local sec="$1"
    if [[ $sec -ge 60 ]]; then
        printf "%dm%02ds" $((sec / 60)) $((sec % 60))
    else
        printf "%ds" "$sec"
    fi
}

# --- Helper: aggregate a field from TSV for a given contract ---
# Usage: tsv_sum <contract> <column_name>
# Returns: sum of that column for all rows matching the contract
tsv_sum() {
    local contract="$1" col_name="$2"
    if [[ ! -f "$TSV_FILE" ]]; then echo "0"; return; fi
    awk -F'\t' -v c="$contract" -v col="$col_name" '
    NR==1 {
        for (i=1; i<=NF; i++) if ($i == col) { ci=i; break }
        next
    }
    $2 == c && ci > 0 { s += $ci }
    END { print s+0 }
    ' "$TSV_FILE"
}

# --- Helper: aggregate a field from TSV across ALL active contracts ---
# Usage: tsv_grand_sum <column_name> <contract1> <contract2> ...
tsv_grand_sum() {
    local col_name="$1"; shift
    local contracts=("$@")
    if [[ ! -f "$TSV_FILE" ]]; then echo "0"; return; fi
    # Build a pattern for awk
    local pattern=""
    for c in "${contracts[@]}"; do
        pattern="${pattern:+$pattern|}$c"
    done
    awk -F'\t' -v pat="$pattern" -v col="$col_name" '
    NR==1 {
        for (i=1; i<=NF; i++) if ($i == col) { ci=i; break }
        next
    }
    ci > 0 && $2 ~ ("^(" pat ")$") { s += $ci }
    END { print s+0 }
    ' "$TSV_FILE"
}

# --- Print header ---
if [[ "$DURATION_SEC" -gt 0 ]]; then
    echo "============================================================"
    echo "  mRWA Stress Test Suite"
    echo "============================================================"
    echo "  Duration:    ${DURATION_MIN} minutes"
    echo "  Rounds/seed: $ROUNDS_PER_SEED"
    echo "  Days/seed:   $DAYS_PER_SEED (S7)"
    echo "  Users:       $USER_COUNT"
    echo "  Base seed:   $BASE_SEED"
    scenario_list=""
    for i in "${ACTIVE_INDICES[@]}"; do
        scenario_list="${scenario_list:+$scenario_list,}${KEYS[$i]}"
    done
    echo "  Scenarios:   $scenario_list"
    echo "============================================================"
    echo ""
else
    echo "============================================================"
    echo "  mRWA Stress Test Suite"
    echo "============================================================"
    echo "  Mode:        Fixed ${MAX_SEEDS} seed rounds"
    echo "  Rounds/seed: $ROUNDS_PER_SEED"
    echo "  Days/seed:   $DAYS_PER_SEED (S7)"
    echo "  Users:       $USER_COUNT"
    echo "  Base seed:   $BASE_SEED"
    scenario_list=""
    for i in "${ACTIVE_INDICES[@]}"; do
        scenario_list="${scenario_list:+$scenario_list,}${KEYS[$i]}"
    done
    echo "  Scenarios:   $scenario_list"
    echo "============================================================"
    echo ""
fi

# --- Main loop: cycle through scenarios with different seeds ---
seed_iter=0
stop=false

while ! $stop; do
    current_seed=$((BASE_SEED + seed_iter * 10000))
    TOTAL_SEED_ROUNDS=$((TOTAL_SEED_ROUNDS + 1))

    elapsed=$(( $(date +%s) - TOTAL_START ))
    if [[ "$DURATION_SEC" -gt 0 ]]; then
        remaining=$((DURATION_SEC - elapsed))
        echo "──── Seed round $((seed_iter + 1)) (seed=$current_seed, elapsed=$(fmt_elapsed $elapsed), remaining=$(fmt_elapsed $remaining)) ────"
    else
        echo "──── Seed round $((seed_iter + 1))/${MAX_SEEDS} (seed=$current_seed) ────"
    fi

    for i in "${ACTIVE_INDICES[@]}"; do
        # Check time before each case
        if time_up; then
            stop=true
            break
        fi

        key="${KEYS[$i]}"
        contract="${CONTRACTS[$i]}"
        func="${FUNCS[$i]}"

        tmplog=$(mktemp)
        STRESS_SEED=$current_seed FOUNDRY_PROFILE=stress forge test \
            --match-path "test/stress/${contract}.t.sol" \
            --match-test "$func" \
            -vv 2>&1 > "$tmplog"
        exit_code=$?
        tail -3 "$tmplog"

        CASE_SEEDS_RUN[$i]=$(( ${CASE_SEEDS_RUN[$i]} + 1 ))

        if [[ $exit_code -eq 0 ]]; then
            CASE_PASS[$i]=$(( ${CASE_PASS[$i]} + 1 ))
            printf "  %-25s PASS  (seed=%s)\n" "[$key]" "$current_seed"
        else
            CASE_FAIL[$i]=$(( ${CASE_FAIL[$i]} + 1 ))
            CASE_FAIL_SEEDS[$i]="${CASE_FAIL_SEEDS[$i]} $current_seed"
            printf "  %-25s FAIL  (seed=%s)\n" "[$key]" "$current_seed"
            # Save full forge output for failed seeds
            {
                echo "==== FAIL: ${key} seed=${current_seed} $(date '+%Y-%m-%d %H:%M:%S') ===="
                cat "$tmplog"
                echo ""
            } >> "$REPORT_DIR/failed_seeds.log"
        fi
        rm -f "$tmplog"
    done

    seed_iter=$((seed_iter + 1))
    echo ""

    # duration=0 mode: stop after MAX_SEEDS rounds
    if [[ "$DURATION_SEC" -eq 0 && $seed_iter -ge $MAX_SEEDS ]]; then
        stop=true
    fi
done

TOTAL_END=$(date +%s)
TOTAL_ELAPSED=$((TOTAL_END - TOTAL_START))

# --- Count passed/failed cases ---
PASSED=0
FAILED=0
PASSED_KEYS=""
FAILED_KEYS=""

for i in "${ACTIVE_INDICES[@]}"; do
    key="${KEYS[$i]}"
    if [[ ${CASE_FAIL[$i]} -eq 0 ]]; then
        PASSED=$((PASSED + 1))
        PASSED_KEYS="$PASSED_KEYS $key"
    else
        FAILED=$((FAILED + 1))
        FAILED_KEYS="$FAILED_KEYS $key"
    fi
done

# --- Collect active contract names for grand totals ---
ACTIVE_CONTRACTS=()
for i in "${ACTIVE_INDICES[@]}"; do
    ACTIVE_CONTRACTS+=("${CONTRACTS[$i]}")
done

# --- Generate summary report (using TSV-based aggregation) ---
{
    echo "============================================================"
    echo "  STRESS TEST SUMMARY REPORT"
    echo "  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "============================================================"
    echo ""
    echo "Configuration:"
    if [[ "$DURATION_SEC" -gt 0 ]]; then
        echo "  Duration:        ${DURATION_MIN} minutes"
    else
        echo "  Duration:        unlimited (${MAX_SEEDS} seed rounds)"
    fi
    echo "  Seed rounds:     $seed_iter (base=$BASE_SEED)"
    echo "  Rounds/seed:     $ROUNDS_PER_SEED"
    echo "  Days/seed (S7):  $DAYS_PER_SEED"
    echo "  Users:           $USER_COUNT"
    echo ""
    echo "  Note: Each 'seed' is an independent test run with a unique random seed."
    echo "        'Rounds' = sum of inner loop iterations across all seed runs."
    echo "        Each seed-run deploys a fresh protocol stack (not cumulative)."
    echo ""
    echo "============================================================"
    echo "  Overall:  $PASSED passed / $FAILED failed / $((PASSED + FAILED)) total"
    echo "  Time:     $(fmt_elapsed $TOTAL_ELAPSED)"
    echo "============================================================"
    echo ""

    # Per-case detail (aggregated from TSV)
    for i in "${ACTIVE_INDICES[@]}"; do
        key="${KEYS[$i]}"
        contract="${CONTRACTS[$i]}"
        name="${NAMES[$i]}"
        desc="${DESCS[$i]}"
        method="${METHODS[$i]}"
        seeds_run=${CASE_SEEDS_RUN[$i]}

        echo "------------------------------------------------------------"
        echo "  [$key] $name"
        echo "------------------------------------------------------------"
        echo "  Scenario: $desc"
        echo "  Method:   $method"
        echo ""

        printf "  Seeds:            %s passed / %s failed  (%s runs)\n" \
            "${CASE_PASS[$i]}" "${CASE_FAIL[$i]}" "$seeds_run"

        if [[ ${CASE_FAIL[$i]} -gt 0 ]]; then
            printf "  Failed seeds:    %s\n" "${CASE_FAIL_SEEDS[$i]}"
            # Extract error summary from failed_seeds.log
            if [[ -f "$REPORT_DIR/failed_seeds.log" ]]; then
                echo "  Error summary:"
                grep -A1 "FAIL: ${key} seed=" "$REPORT_DIR/failed_seeds.log" \
                    | grep "\[FAIL:" | sed 's/^/    /' | head -10
            fi
        fi

        printf "  Total Rounds:     %s\n" "$(tsv_sum "$contract" "actualRounds")"
        printf "  Transactions:     %s total\n" "$(tsv_sum "$contract" "totalTx")"
        printf "    deposits:       %s\n" "$(tsv_sum "$contract" "deposits")"
        printf "    syncRedeems:    %s\n" "$(tsv_sum "$contract" "syncRedeems")"
        printf "    asyncRedeems:   %s\n" "$(tsv_sum "$contract" "asyncRedeems")"
        printf "    processBatch:   %s\n" "$(tsv_sum "$contract" "processBatch")"
        printf "    finalizeBatch:  %s\n" "$(tsv_sum "$contract" "finalizeBatch")"
        printf "    rebalances:     %s\n" "$(tsv_sum "$contract" "rebalances")"
        printf "    settlements:    %s\n" "$(tsv_sum "$contract" "settlements")"
        printf "    rateUpdates:    %s\n" "$(tsv_sum "$contract" "rateUpdates")"
        printf "    priceUpdates:   %s\n" "$(tsv_sum "$contract" "priceUpdates")"
        printf "  Invariants:       %s checks, %s fails\n" \
            "$(tsv_sum "$contract" "invariantChecks")" "$(tsv_sum "$contract" "invariantFails")"
        printf "  Gas Used:         %s\n" "$(tsv_sum "$contract" "totalGasUsed")"
        echo ""
    done

    # Grand totals (single awk pass per field across all active contracts)
    echo "============================================================"
    echo "  Grand Totals"
    echo "============================================================"

    printf "  Rounds:              %s\n" "$(tsv_grand_sum "actualRounds" "${ACTIVE_CONTRACTS[@]}")"
    printf "  Transactions:        %s\n" "$(tsv_grand_sum "totalTx" "${ACTIVE_CONTRACTS[@]}")"
    printf "    deposits:          %s\n" "$(tsv_grand_sum "deposits" "${ACTIVE_CONTRACTS[@]}")"
    printf "    syncRedeems:       %s\n" "$(tsv_grand_sum "syncRedeems" "${ACTIVE_CONTRACTS[@]}")"
    printf "    asyncRedeems:      %s\n" "$(tsv_grand_sum "asyncRedeems" "${ACTIVE_CONTRACTS[@]}")"
    printf "    processBatch:      %s\n" "$(tsv_grand_sum "processBatch" "${ACTIVE_CONTRACTS[@]}")"
    printf "    finalizeBatch:     %s\n" "$(tsv_grand_sum "finalizeBatch" "${ACTIVE_CONTRACTS[@]}")"
    printf "    rebalances:        %s\n" "$(tsv_grand_sum "rebalances" "${ACTIVE_CONTRACTS[@]}")"
    printf "    settlements:       %s\n" "$(tsv_grand_sum "settlements" "${ACTIVE_CONTRACTS[@]}")"
    printf "    rateUpdates:       %s\n" "$(tsv_grand_sum "rateUpdates" "${ACTIVE_CONTRACTS[@]}")"
    printf "    priceUpdates:      %s\n" "$(tsv_grand_sum "priceUpdates" "${ACTIVE_CONTRACTS[@]}")"
    printf "  Invariant Checks:    %s (fails: %s)\n" \
        "$(tsv_grand_sum "invariantChecks" "${ACTIVE_CONTRACTS[@]}")" \
        "$(tsv_grand_sum "invariantFails" "${ACTIVE_CONTRACTS[@]}")"
    printf "  Gas Used:            %s\n" "$(tsv_grand_sum "totalGasUsed" "${ACTIVE_CONTRACTS[@]}")"
    printf "  Wall Time:           %s\n" "$(fmt_elapsed $TOTAL_ELAPSED)"
    echo ""

    if [[ $FAILED -gt 0 ]]; then
        echo "  FAILED CASES:$FAILED_KEYS"
        echo "  Full error logs: $REPORT_DIR/failed_seeds.log"
    fi
    echo "============================================================"

} | tee "$GLOBAL_REPORT"

echo ""
echo "Report: $GLOBAL_REPORT"

exit $FAILED
