#!/usr/bin/env bash
# Runs weak reference GC benchmarks across all configured JDK variant images.
#
# Usage:
#   ./scripts/run_benchmark_iterations.sh [OPTIONS] [OUTER_ITERATIONS]
#
# Options:
#   --benchmark multi|single|both    Benchmark suite to run (default: both)
#   --run-id-prefix PREFIX           Prefix for output ID directories (default: timestamp)
#   --output-root DIR                Where to write results (default: <repo>/output)
#   --variant-image-root DIR         Root of variant JDK images (default: build/variant-images)
#   --outer N                        Number of measured iterations (default: 10)
#   --warmup N                       Warmup passes per instance (default: 0)
#   --cooldown N                     Cooldown seconds between variant runs (default: 1)
#   --parallel-instances N           Total parallel instances across all nodes (default: 1)
#   --instance-start N               First instance index for this node (default: 1)
#   --instance-end N                 Last instance index for this node (default: --parallel-instances)
#   --jvm-core-count N               JVM CPU cores per instance
#   --jvm-core-set CPULIST           Explicit JVM CPU set (e.g. 0-9)
#   --aux-core-count N               Auxiliary CPU cores per instance (for monitoring)
#   --aux-core-set CPULIST           Explicit auxiliary CPU set

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${SCRIPT_DIR}/benchmark_runtime_common.sh"

# --- Defaults ---
BENCHMARK_NAME="${BENCHMARK_NAME:-both}"
RUN_ID_PREFIX="${RUN_ID_PREFIX:-$(date +%Y%m%d-%H%M%S)}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${REPO_ROOT}/output}"
VARIANT_IMAGE_ROOT="${VARIANT_IMAGE_ROOT:-${REPO_ROOT}/build/variant-images}"
OUTER_ITERATIONS="${OUTER_ITERATIONS:-10}"
WARMUP_ITERATIONS="${WARMUP_ITERATIONS:-0}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-1}"
PARALLEL_INSTANCES="${PARALLEL_INSTANCES:-1}"
INSTANCE_START_ID="${INSTANCE_START_ID:-1}"
INSTANCE_END_ID="${INSTANCE_END_ID:-}"
export BENCHMARK_JVM_CORE_COUNT="${BENCHMARK_JVM_CORE_COUNT:-4}"
export BENCHMARK_AUX_CORE_COUNT="${BENCHMARK_AUX_CORE_COUNT:-1}"

MULTI_JVM_OPTS="${MULTI_JVM_OPTS:--Xms4g -Xmx4g -XX:+UseZGC -Xlog:gc+stats,gc+ref -XX:InitialTenuringThreshold=1 -XX:MaxTenuringThreshold=1 -XX:-ZProactive -XX:ZCollectionIntervalMajor=315360000 -XX:+ZCollectionIntervalOnly -XX:NativeMemoryTracking=summary}"
SINGLE_JVM_OPTS="${SINGLE_JVM_OPTS:--Xms4g -Xmx4g -XX:+UseZGC -Xlog:gc+stats,gc+ref -XX:InitialTenuringThreshold=1 -XX:MaxTenuringThreshold=1 -XX:-ZProactive -XX:ZCollectionIntervalMajor=315360000 -XX:+ZCollectionIntervalOnly -XX:NativeMemoryTracking=summary}"
MULTI_BENCHMARK_ARGS="${MULTI_BENCHMARK_ARGS:-4000000}"
SINGLE_BENCHMARK_ARGS="${SINGLE_BENCHMARK_ARGS:-30000000}"
ENABLE_WEAK_FIELDS_BENCHMARK="${ENABLE_WEAK_FIELDS_BENCHMARK:-1}"
BENCHMARK_VARIANTS_CSV="${BENCHMARK_VARIANTS:-none,all}"
MONITOR_INTERVAL="${MONITOR_INTERVAL:-0.0001}"
MONITOR_SCRIPT="${MONITOR_SCRIPT:-${SCRIPT_DIR}/monitor_memory.sh}"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

print_header()  {
    echo ""
    echo -e "${BLUE}============================================================${NC}"
    echo -e "${BOLD}${CYAN}  $1${NC}"
    echo -e "${BLUE}============================================================${NC}"
    echo ""
}
print_step()    { echo -e "${YELLOW}▶ $1${NC}"; }
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }

# --- Argument parsing ---
while [ $# -gt 0 ]; do
    case $1 in
        --benchmark|-b)          BENCHMARK_NAME="$2";                  shift 2 ;;
        --run-id-prefix)         RUN_ID_PREFIX="$2";                   shift 2 ;;
        --output-root)           OUTPUT_ROOT="$2";                     shift 2 ;;
        --variant-image-root)    VARIANT_IMAGE_ROOT="$2";              shift 2 ;;
        --outer)                 OUTER_ITERATIONS="$2";                shift 2 ;;
        --warmup|-w)             WARMUP_ITERATIONS="$2";               shift 2 ;;
        --cooldown|-c)           COOLDOWN_SECONDS="$2";                shift 2 ;;
        --parallel-instances|-p) PARALLEL_INSTANCES="$2";              shift 2 ;;
        --instance-start)        INSTANCE_START_ID="$2";               shift 2 ;;
        --instance-end)          INSTANCE_END_ID="$2";                 shift 2 ;;
        --jvm-core-count)        export BENCHMARK_JVM_CORE_COUNT="$2"; shift 2 ;;
        --jvm-core-set)          export BENCHMARK_JVM_CORE_SET="$2";   shift 2 ;;
        --aux-core-count)        export BENCHMARK_AUX_CORE_COUNT="$2"; shift 2 ;;
        --aux-core-set)          export BENCHMARK_AUX_CORE_SET="$2";   shift 2 ;;
        [0-9]*)                  OUTER_ITERATIONS="$1";                shift   ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# Ref-proc variants (parsed after args so BENCHMARK_VARIANTS env can override)
IFS=',' read -r -a variants <<< "$BENCHMARK_VARIANTS_CSV"

# --- Validation ---
case "$BENCHMARK_NAME" in
    multi|single|both) ;;
    *) echo -e "${RED}Unknown benchmark '$BENCHMARK_NAME'. Use multi, single, or both.${NC}" >&2; exit 1 ;;
esac

[[ "$OUTER_ITERATIONS" =~ ^[0-9]+$ ]] && [ "$OUTER_ITERATIONS" -ge 1 ] || \
    { echo -e "${RED}OUTER_ITERATIONS must be a positive integer.${NC}" >&2; exit 1; }
[[ "$WARMUP_ITERATIONS" =~ ^[0-9]+$ ]] || \
    { echo -e "${RED}WARMUP_ITERATIONS must be a non-negative integer.${NC}" >&2; exit 1; }
[[ "$PARALLEL_INSTANCES" =~ ^[0-9]+$ ]] && [ "$PARALLEL_INSTANCES" -ge 1 ] || \
    { echo -e "${RED}PARALLEL_INSTANCES must be a positive integer.${NC}" >&2; exit 1; }
[[ "$INSTANCE_START_ID" =~ ^[0-9]+$ ]] && [ "$INSTANCE_START_ID" -ge 1 ] || \
    { echo -e "${RED}INSTANCE_START_ID must be a positive integer.${NC}" >&2; exit 1; }

EFFECTIVE_PARALLEL_INSTANCES="$PARALLEL_INSTANCES"
[ "$EFFECTIVE_PARALLEL_INSTANCES" -le "$OUTER_ITERATIONS" ] || EFFECTIVE_PARALLEL_INSTANCES="$OUTER_ITERATIONS"

INSTANCE_END_ID="${INSTANCE_END_ID:-$EFFECTIVE_PARALLEL_INSTANCES}"

[[ "$INSTANCE_END_ID" =~ ^[0-9]+$ ]] && [ "$INSTANCE_END_ID" -ge 1 ] || \
    { echo -e "${RED}INSTANCE_END_ID must be a positive integer.${NC}" >&2; exit 1; }
[ "$INSTANCE_START_ID" -le "$EFFECTIVE_PARALLEL_INSTANCES" ] || \
    { echo -e "${RED}INSTANCE_START_ID (${INSTANCE_START_ID}) exceeds effective instance count (${EFFECTIVE_PARALLEL_INSTANCES}).${NC}" >&2; exit 1; }
[ "$INSTANCE_END_ID" -ge "$INSTANCE_START_ID" ] && [ "$INSTANCE_END_ID" -le "$EFFECTIVE_PARALLEL_INSTANCES" ] || \
    { echo -e "${RED}INSTANCE_END_ID must be between INSTANCE_START_ID and ${EFFECTIVE_PARALLEL_INSTANCES}.${NC}" >&2; exit 1; }

ACTIVE_PARALLEL_INSTANCES=$((INSTANCE_END_ID - INSTANCE_START_ID + 1))

# --- Path helpers ---
variant_build_dir() { printf '%s/%s-linux-x86_64-server-release\n' "$VARIANT_IMAGE_ROOT" "$1"; }
run_output_dir()    { printf '%s/id_%s\n'   "$OUTPUT_ROOT" "$1"; }
run_logs_dir()      { printf '%s/logs\n'    "$(run_output_dir "$1")"; }
run_memory_dir()    { printf '%s/memory\n'  "$(run_output_dir "$1")"; }

# --- Core benchmark functions ---

cooldown_system() {
    echo "  Cooldown (${COOLDOWN_SECONDS}s)..."
    sleep "$COOLDOWN_SECONDS"
    print_success "Cooldown complete"
}

cleanup_old_results() {
    local logs_dir memory_dir
    logs_dir="$(run_logs_dir "$RUN_ID")"
    memory_dir="$(run_memory_dir "$RUN_ID")"
    mkdir -p "$logs_dir" "$memory_dir"
    rm -f "${logs_dir}/run_*_${RUN_ID}.log"
    rm -f "${memory_dir}/monitor_*_${RUN_ID}.csv"
}

run_single() {
    local label=$1 outer_run=$2 total_runs=$3
    local stage_kind=${4:-measured} stage_index=${5:-0}
    local instance_id=${6:-1} total_instances=${7:-1}
    local log_dir memory_dir log_file monitor_log display_context log_title phase_label
    local parallel_mode=false java_opts exit_code=0 java_pid monitor_pid=""
    local -a cmd _opts _args

    log_dir="$(run_logs_dir "$RUN_ID")"
    memory_dir="$(run_memory_dir "$RUN_ID")"
    mkdir -p "$log_dir" "$memory_dir"

    if [ "$stage_kind" = "warmup" ]; then
        log_file="${log_dir}/run_${BENCHMARK_NAME}_warmup_${label}_instance${instance_id}_pass${stage_index}_${RUN_ID}.log"
        monitor_log="${memory_dir}/monitor_${BENCHMARK_NAME}_warmup_${label}_instance${instance_id}_pass${stage_index}_${RUN_ID}.csv"
        display_context="Instance ${instance_id}/${total_instances}, warm-up ${stage_index}/${WARMUP_ITERATIONS}"
    else
        log_file="${log_dir}/run_${BENCHMARK_NAME}_${label}_run${outer_run}_${RUN_ID}.log"
        monitor_log="${memory_dir}/monitor_${BENCHMARK_NAME}_${label}_run${outer_run}_${RUN_ID}.csv"
        display_context="Instance ${instance_id}/${total_instances}, outer iteration ${outer_run}/${total_runs}"
    fi
    log_title="=== ${display_context} (Variant ${label}) ==="

    [ "$ACTIVE_PARALLEL_INSTANCES" -gt 1 ] && parallel_mode=true

    echo "  ${display_context} - Variant ${label}"
    echo "    Log: $log_file"
    echo "    Args: ${CURRENT_BENCHMARK_ARGS:-<none>}"

    if [ "$BENCHMARK_NAME" = "single" ] || [ "$BENCHMARK_NAME" = "field-single" ]; then
        java_opts="$SINGLE_JVM_OPTS"
    else
        java_opts="$MULTI_JVM_OPTS"
    fi

    cmd=("$JAVA_BIN")
    read -r -a _opts <<< "$java_opts"
    cmd+=("${_opts[@]}")
    cmd+=("$BENCHMARK_CLASS")
    if [ -n "$CURRENT_BENCHMARK_ARGS" ]; then
        read -r -a _args <<< "$CURRENT_BENCHMARK_ARGS"
        cmd+=("${_args[@]}")
    fi

    {
        echo ""
        echo "$log_title"
        echo ""
        echo "Affinity: $(benchmark_affinity_summary)"
        echo "Args: ${CURRENT_BENCHMARK_ARGS:-<none>}"
        echo "Command: ${cmd[*]}"
        echo ""
    } >> "$log_file"

    if [ -n "${BENCHMARK_JVM_CORE_SET:-}" ]; then
        taskset --cpu-list "$BENCHMARK_JVM_CORE_SET" "${cmd[@]}" >> "$log_file" 2>&1 &
    else
        "${cmd[@]}" >> "$log_file" 2>&1 &
    fi
    java_pid=$!

    sleep 1

    if kill -0 $java_pid 2>/dev/null; then
        if [ -n "${BENCHMARK_AUX_CORE_SET:-}" ]; then
            taskset --cpu-list "$BENCHMARK_AUX_CORE_SET" \
                "$MONITOR_SCRIPT" "$java_pid" "$monitor_log" "$MONITOR_INTERVAL" "$JCMD_BIN" "$log_file" &
        else
            "$MONITOR_SCRIPT" "$java_pid" "$monitor_log" "$MONITOR_INTERVAL" "$JCMD_BIN" "$log_file" &
        fi
        monitor_pid=$!
        [ "$parallel_mode" = false ] && sleep 0.5
    fi

    if [ "$parallel_mode" = false ]; then
        while kill -0 $java_pid 2>/dev/null; do
            if [ -f "$log_file" ]; then
                phase_label=$(grep -oP 'Phase\s+\d+(?:[.-]\d+)?' "$log_file" | tail -1)
                [ -n "$phase_label" ] && printf "${CYAN}▶${NC} %s (Variant %s) - Phase %s    \r" \
                    "$display_context" "$label" "${phase_label#Phase }"
            fi
            sleep 0.5
        done
    fi

    wait $java_pid || exit_code=$?

    if [ -n "$monitor_pid" ]; then
        sleep 1
        kill $monitor_pid 2>/dev/null || true
    fi

    if [ $exit_code -eq 0 ]; then
        printf "${GREEN}✓${NC} %s (Variant %s) - Done!          \n" "$display_context" "$label"
        echo ""
    else
        printf "${RED}✗${NC} %s (Variant %s) - Failed (exit code %d)\n" "$display_context" "$label" "$exit_code"
        echo ""
        return $exit_code
    fi
}

run_variant_set() {
    local outer_run=$1 total_runs=$2 stage_kind=$3
    local stage_index=${4:-0} instance_id=${5:-1} total_instances=${6:-1}
    local variant variant_dir

    for variant in "${variants[@]}"; do
        variant_dir="$(variant_build_dir "$variant")"
        JAVA_BIN="${variant_dir}/jdk/bin/java"
        JCMD_BIN="${variant_dir}/jdk/bin/jcmd"

        if [ ! -x "$JAVA_BIN" ]; then
            print_warning "Variant '$variant' not found at $JAVA_BIN; skipping"
            continue
        fi

        BENCHMARK_CLASS="$PRIMARY_BENCHMARK_CLASS"
        BENCHMARK_NAME="$PRIMARY_BENCHMARK_NAME"
        CURRENT_BENCHMARK_ARGS="$PRIMARY_BENCHMARK_ARGS"

        if [ "$stage_kind" = "warmup" ]; then
            print_step "Instance $instance_id/$total_instances - Warm-up $stage_index/$WARMUP_ITERATIONS - Variant $variant"
        else
            print_step "Instance $instance_id/$total_instances - Outer iteration $outer_run/$total_runs - Variant $variant"
        fi
        cooldown_system

        if ! run_single "$variant" "$outer_run" "$total_runs" "$stage_kind" "$stage_index" "$instance_id" "$total_instances"; then
            if [ "$stage_kind" = "warmup" ]; then
                print_warning "Warm-up failed for instance $instance_id variant '$variant' (continuing)"
            else
                return 1
            fi
        fi
    done

    if [ "$ENABLE_WEAK_FIELDS_BENCHMARK" != "1" ] || [ -z "${WEAK_FIELDS_BENCHMARK_CLASS:-}" ]; then
        return 0
    fi

    variant="weak_fields"
    variant_dir="$(variant_build_dir "$variant")"
    JAVA_BIN="${variant_dir}/jdk/bin/java"
    JCMD_BIN="${variant_dir}/jdk/bin/jcmd"

    if [ ! -x "$JAVA_BIN" ]; then
        print_warning "Variant 'weak_fields' not found at $JAVA_BIN; skipping"
        return 0
    fi

    BENCHMARK_CLASS="$WEAK_FIELDS_BENCHMARK_CLASS"
    BENCHMARK_NAME="$WEAK_FIELDS_BENCHMARK_NAME"
    CURRENT_BENCHMARK_ARGS="$WEAK_FIELDS_BENCHMARK_ARGS"

    if [ "$stage_kind" = "warmup" ]; then
        print_step "Instance $instance_id/$total_instances - Warm-up $stage_index/$WARMUP_ITERATIONS - Variant weak_fields"
    else
        print_step "Instance $instance_id/$total_instances - Outer iteration $outer_run/$total_runs - Variant weak_fields"
    fi
    cooldown_system

    if ! run_single "weak_fields" "$outer_run" "$total_runs" "$stage_kind" "$stage_index" "$instance_id" "$total_instances"; then
        if [ "$stage_kind" = "warmup" ]; then
            print_warning "Warm-up failed for instance $instance_id variant 'weak_fields' (continuing)"
        else
            return 1
        fi
    fi

    BENCHMARK_CLASS="$PRIMARY_BENCHMARK_CLASS"
    BENCHMARK_NAME="$PRIMARY_BENCHMARK_NAME"
    CURRENT_BENCHMARK_ARGS="$PRIMARY_BENCHMARK_ARGS"
}

discard_warmup_results() {
    rm -f "$(run_logs_dir "$RUN_ID")"/run_*_warmup_*_instance${1}_*_${RUN_ID}.log
    rm -f "$(run_memory_dir "$RUN_ID")"/monitor_*_warmup_*_instance${1}_*_${RUN_ID}.csv
}

compute_instance_run_range() {
    local instance_id=$1 instance_count=$2 total_runs=$3
    local base_runs=$((total_runs / instance_count))
    local extra_runs=$((total_runs % instance_count))

    if [ "$instance_id" -le "$extra_runs" ]; then
        INSTANCE_RUN_COUNT=$((base_runs + 1))
        INSTANCE_RUN_START=$(((instance_id - 1) * (base_runs + 1) + 1))
    else
        INSTANCE_RUN_COUNT=$base_runs
        INSTANCE_RUN_START=$((extra_runs * (base_runs + 1) + (instance_id - extra_runs - 1) * base_runs + 1))
    fi
    INSTANCE_RUN_END=$((INSTANCE_RUN_START + INSTANCE_RUN_COUNT - 1))
}

run_instance_worker() {
    local instance_id=$1 instance_count=$2 total_runs=$3
    local local_slot_index=$4 local_slot_count=$5

    if benchmark_has_affinity_configuration; then
        if [ "$local_slot_count" -gt 1 ]; then
            benchmark_resolve_parallel_slot_core_sets "$local_slot_index" "$local_slot_count" || return 1
        else
            benchmark_resolve_core_sets || return 1
        fi
    fi

    compute_instance_run_range "$instance_id" "$instance_count" "$total_runs"
    print_step "Starting instance $instance_id/$instance_count (outer iterations ${INSTANCE_RUN_START}-${INSTANCE_RUN_END})"
    echo "  Affinity: $(benchmark_affinity_summary)"

    if [ "$WARMUP_ITERATIONS" -gt 0 ]; then
        local warmup
        for ((warmup = 1; warmup <= WARMUP_ITERATIONS; warmup++)); do
            run_variant_set 0 "$total_runs" warmup "$warmup" "$instance_id" "$instance_count" || return 1
        done
        discard_warmup_results "$instance_id"
        print_success "Warm-up complete for instance $instance_id/$instance_count"
    fi

    local outer_run
    for ((outer_run = INSTANCE_RUN_START; outer_run <= INSTANCE_RUN_END; outer_run++)); do
        run_variant_set "$outer_run" "$total_runs" measured 0 "$instance_id" "$instance_count" || return 1
    done
}

count_measured_runs() {
    find "$(run_logs_dir "$RUN_ID")" -maxdepth 1 -type f \
        -name "run_*_run*_${RUN_ID}.log" ! -name "run_*_warmup_*" | wc -l | tr -d '[:space:]'
}

wait_for_next_instance() {
    local finished_pid="" status=0
    wait -n -p finished_pid || status=$?
    if [ -z "$finished_pid" ]; then
        print_warning "Failed to identify the finished benchmark instance"
        return 1
    fi
    unset 'INSTANCE_SLOT_BY_PID[$finished_pid]'
    return $status
}

# --- Run a complete benchmark suite (multi or single) ---

run_benchmark_suite() {
    local bench_type=$1

    case "$bench_type" in
        multi)
            RUN_ID="${RUN_ID_PREFIX}-multi"
            PRIMARY_BENCHMARK_CLASS="${REPO_ROOT}/test/weakrefs/WeakRefMultiObjectBenchmark.java"
            WEAK_FIELDS_BENCHMARK_CLASS="${REPO_ROOT}/test/weakrefs/WeakFieldMultiObjectBenchmark.java"
            WEAK_FIELDS_BENCHMARK_NAME="field"
            PRIMARY_BENCHMARK_ARGS="$MULTI_BENCHMARK_ARGS"
            WEAK_FIELDS_BENCHMARK_ARGS="${WEAK_FIELDS_MULTI_BENCHMARK_ARGS:-$MULTI_BENCHMARK_ARGS}"
            ;;
        single)
            RUN_ID="${RUN_ID_PREFIX}-single"
            PRIMARY_BENCHMARK_CLASS="${REPO_ROOT}/test/weakrefs/WeakRefSingleObjectBenchmark.java"
            WEAK_FIELDS_BENCHMARK_CLASS="${REPO_ROOT}/test/weakrefs/WeakFieldSingleObjectBenchmark.java"
            WEAK_FIELDS_BENCHMARK_NAME="field-single"
            PRIMARY_BENCHMARK_ARGS="$SINGLE_BENCHMARK_ARGS"
            WEAK_FIELDS_BENCHMARK_ARGS="${WEAK_FIELDS_SINGLE_BENCHMARK_ARGS:-$SINGLE_BENCHMARK_ARGS}"
            ;;
    esac

    PRIMARY_BENCHMARK_NAME="$bench_type"
    BENCHMARK_NAME="$bench_type"
    CURRENT_BENCHMARK_ARGS="$PRIMARY_BENCHMARK_ARGS"

    cleanup_old_results

    print_header "${bench_type^^} BENCHMARK"
    echo -e "${BOLD}Outer iterations:${NC}   $OUTER_ITERATIONS"
    echo -e "${BOLD}Warm-up:${NC}            $WARMUP_ITERATIONS pass(es)"
    echo -e "${BOLD}Parallel instances:${NC} $EFFECTIVE_PARALLEL_INSTANCES total (this node: ${INSTANCE_START_ID}-${INSTANCE_END_ID})"
    echo -e "${BOLD}Variant image root:${NC} $VARIANT_IMAGE_ROOT"
    echo -e "${BOLD}Output root:${NC}        $OUTPUT_ROOT  (run ID: $RUN_ID)"
    echo -e "${BOLD}Affinity:${NC}           $(benchmark_requested_affinity_summary)"
    echo ""

    declare -A INSTANCE_SLOT_BY_PID=()
    local overall_status=0 local_slot_index=0 instance_id

    for ((instance_id = INSTANCE_START_ID; instance_id <= INSTANCE_END_ID; instance_id++)); do
        local_slot_index=$((local_slot_index + 1))
        (
            run_instance_worker "$instance_id" "$EFFECTIVE_PARALLEL_INSTANCES" "$OUTER_ITERATIONS" \
                "$local_slot_index" "$ACTIVE_PARALLEL_INSTANCES"
        ) &
        INSTANCE_SLOT_BY_PID[$!]="$instance_id"
    done

    while [ "${#INSTANCE_SLOT_BY_PID[@]}" -gt 0 ]; do
        wait_for_next_instance || { overall_status=1; break; }
    done

    if [ $overall_status -ne 0 ]; then
        local pid
        for pid in "${!INSTANCE_SLOT_BY_PID[@]}"; do
            kill "$pid" 2>/dev/null || true
        done
        wait || true
        echo -e "${RED}One or more benchmark instances failed. Check the log files.${NC}" >&2
        return 1
    fi

    local measured_runs
    measured_runs="$(count_measured_runs)"
    if [ "$measured_runs" -eq 0 ]; then
        echo -e "${RED}No benchmark runs completed. Check VARIANT_IMAGE_ROOT (${VARIANT_IMAGE_ROOT}) and variant list.${NC}" >&2
        return 1
    fi

    print_header "${bench_type^^} BENCHMARK COMPLETE"
    echo -e "${BOLD}Completed $measured_runs run(s) successfully.${NC}"
    echo "  Output: $(run_output_dir "$RUN_ID")"
    echo ""
}

# --- Main ---

if benchmark_has_affinity_configuration; then
    benchmark_require_command taskset
    benchmark_ensure_allowed_core_set
fi

# Save before run_benchmark_suite overwrites the global.
BENCHMARK_SELECTION="$BENCHMARK_NAME"

case "$BENCHMARK_SELECTION" in
    multi|both) run_benchmark_suite multi ;;
esac

case "$BENCHMARK_SELECTION" in
    single|both) run_benchmark_suite single ;;
esac
