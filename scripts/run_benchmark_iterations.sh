#!/usr/bin/env bash

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${SCRIPT_DIR}/benchmark_runtime_common.sh"

# run_benchmark_iterations.sh
# Runs weak reference benchmarks multiple times and aggregates results.
#
# Usage:
#   ./scripts/run_benchmark_iterations.sh [--benchmark multi|single] [--id RUN_ID] [--cooldown SECONDS] [--warmup N] [OUTER_ITERATIONS]

# Default values
JAVA_BIN="${JAVA_BIN:-${REPO_ROOT}/build/linux-x86_64-server-release/jdk/bin/java}"
JCMD_BIN="${JCMD_BIN:-${REPO_ROOT}/build/linux-x86_64-server-release/jdk/bin/jcmd}"
VARIANT_IMAGE_ROOT="${VARIANT_IMAGE_ROOT:-${REPO_ROOT}/build/variant-images}"
MULTI_JVM_OPTS="${MULTI_JVM_OPTS:--Xms8g -Xmx8g -XX:+UseZGC -Xlog:gc+stats,gc+ref -XX:InitialTenuringThreshold=1 -XX:MaxTenuringThreshold=1 -XX:ZCollectionIntervalMajor=0.5 -XX:+ZCollectionIntervalOnly -XX:NativeMemoryTracking=summary}"
SINGLE_JVM_OPTS="${SINGLE_JVM_OPTS:--Xms7g -Xmx7g -XX:+UseZGC -Xlog:gc+stats,gc+ref -XX:InitialTenuringThreshold=1 -XX:MaxTenuringThreshold=1 -XX:NativeMemoryTracking=summary}"
BENCHMARK_JVM_CORE_COUNT="${BENCHMARK_JVM_CORE_COUNT:-10}"
BENCHMARK_AUX_CORE_COUNT="${BENCHMARK_AUX_CORE_COUNT:-2}"
MULTI_BENCHMARK_ARGS="${MULTI_BENCHMARK_ARGS:-}"
SINGLE_BENCHMARK_ARGS="${SINGLE_BENCHMARK_ARGS:-}"
ENABLE_WEAK_FIELDS_BENCHMARK="${ENABLE_WEAK_FIELDS_BENCHMARK:-1}"
BENCHMARK_VARIANTS_CSV="${BENCHMARK_VARIANTS:-none,clear_path_only,sep_only,dyn_only,clear_path_sep,clear_path_dyn,sep_dyn,all}"
# Available benchmarks:
#   multi   -> WeakRefMultiObjectBenchmark     (many objects, each has its own WeakRef)
#              + WeakFieldMultiObjectBenchmark  (weak_fields variant)
#   single  -> WeakRefSingleObjectBenchmark    (many WeakRefs all pointing at one object)
#              + WeakFieldSingleObjectBenchmark (weak_fields variant)
BENCHMARK_NAME="${BENCHMARK_NAME:-multi}"
OUTER_ITERATIONS=100
MONITOR_INTERVAL="${MONITOR_INTERVAL:-0.0001}"  # 100us interval for monitoring
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-10}"
WARMUP_ITERATIONS="${WARMUP_ITERATIONS:-1}"
PARALLEL_INSTANCES="${PARALLEL_INSTANCES:-8}"
INSTANCE_START_ID="${INSTANCE_START_ID:-1}"
INSTANCE_END_ID="${INSTANCE_END_ID:-}"
MONITOR_SCRIPT="${MONITOR_SCRIPT:-${SCRIPT_DIR}/monitor_memory.sh}"
RUN_ID=1  # Default ID for filenames
OUTPUT_ROOT="${OUTPUT_ROOT:-${REPO_ROOT}/output}"
PRIMARY_BENCHMARK_ARGS=""
WEAK_FIELDS_BENCHMARK_ARGS=""
CURRENT_BENCHMARK_ARGS=""
AFFINITY_OVERVIEW="affinity disabled"
EFFECTIVE_PARALLEL_INSTANCES=1
ACTIVE_PARALLEL_INSTANCES=1

# Ref-proc variants are built into per-variant image snapshots by build_configs.sh.
IFS=',' read -r -a variants <<< "$BENCHMARK_VARIANTS_CSV"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

print_header() {
    echo ""
    echo -e "${BLUE}============================================================${NC}"
    echo -e "${BOLD}${CYAN}  $1${NC}"
    echo -e "${BLUE}============================================================${NC}"
    echo ""
}

print_step() { echo -e "${YELLOW}▶ $1${NC}"; }
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }

build_command_args() {
    local java_opts_string=$1
    local benchmark_args_string=$2
    local -a java_opts=()
    local -a benchmark_args=()

    if [ -n "$java_opts_string" ]; then
        read -r -a java_opts <<< "$java_opts_string"
    fi
    if [ -n "$benchmark_args_string" ]; then
        read -r -a benchmark_args <<< "$benchmark_args_string"
    fi

    COMMAND_ARGS=("$JAVA_BIN")
    COMMAND_ARGS+=("${java_opts[@]}")
    COMMAND_ARGS+=("$BENCHMARK_CLASS")
    COMMAND_ARGS+=("${benchmark_args[@]}")
}

variant_build_dir() {
    local variant=$1
    printf '%s/%s-linux-x86_64-server-release\n' "$VARIANT_IMAGE_ROOT" "$variant"
}

run_output_dir() {
    local run_id=$1
    printf '%s/id_%s\n' "$OUTPUT_ROOT" "$run_id"
}

run_logs_dir() {
    local run_id=$1
    printf '%s/logs\n' "$(run_output_dir "$run_id")"
}

run_memory_dir() {
    local run_id=$1
    printf '%s/memory\n' "$(run_output_dir "$run_id")"
}

ensure_run_output_dirs() {
    local run_id=$1
    mkdir -p "$(run_logs_dir "$run_id")" "$(run_memory_dir "$run_id")"
}

# Parse command line arguments
while [ $# -gt 0 ]; do
    case $1 in
        --id)
            RUN_ID="$2"
            shift 2
            ;;
        --benchmark|-b)
            BENCHMARK_NAME="$2"
            shift 2
            ;;
        --cooldown|-c)
            COOLDOWN_SECONDS="$2"
            shift 2
            ;;
        --warmup|-w)
            WARMUP_ITERATIONS="$2"
            shift 2
            ;;
        --parallel-instances|-p)
            PARALLEL_INSTANCES="$2"
            shift 2
            ;;
        --instance-start)
            INSTANCE_START_ID="$2"
            shift 2
            ;;
        --instance-end)
            INSTANCE_END_ID="$2"
            shift 2
            ;;
        *)
            if [ -z "$OUTER_ITERATIONS" ] || [ "$OUTER_ITERATIONS" = "100" ]; then
                OUTER_ITERATIONS=$1
                shift
            else
                shift
            fi
            ;;
    esac
done

# Resolve benchmark name to class file path
case "$BENCHMARK_NAME" in
    multi)
        BENCHMARK_CLASS="${REPO_ROOT}/test/weakrefs/WeakRefMultiObjectBenchmark.java"
        WEAK_FIELDS_BENCHMARK_CLASS="${REPO_ROOT}/test/weakrefs/WeakFieldMultiObjectBenchmark.java"
        WEAK_FIELDS_BENCHMARK_NAME="field"
        PRIMARY_BENCHMARK_ARGS="$MULTI_BENCHMARK_ARGS"
        WEAK_FIELDS_BENCHMARK_ARGS="${WEAK_FIELDS_MULTI_BENCHMARK_ARGS:-$MULTI_BENCHMARK_ARGS}"
        ;;
    single)
        BENCHMARK_CLASS="${REPO_ROOT}/test/weakrefs/WeakRefSingleObjectBenchmark.java"
        WEAK_FIELDS_BENCHMARK_CLASS="${REPO_ROOT}/test/weakrefs/WeakFieldSingleObjectBenchmark.java"
        WEAK_FIELDS_BENCHMARK_NAME="field-single"
        PRIMARY_BENCHMARK_ARGS="$SINGLE_BENCHMARK_ARGS"
        WEAK_FIELDS_BENCHMARK_ARGS="${WEAK_FIELDS_SINGLE_BENCHMARK_ARGS:-$SINGLE_BENCHMARK_ARGS}"
        ;;
    *)
        echo -e "${RED}Unknown benchmark name: $BENCHMARK_NAME${NC}"
        echo "Supported benchmarks: multi, single"
        exit 1
        ;;
esac

PRIMARY_BENCHMARK_CLASS="$BENCHMARK_CLASS"
PRIMARY_BENCHMARK_NAME="$BENCHMARK_NAME"
CURRENT_BENCHMARK_ARGS="$PRIMARY_BENCHMARK_ARGS"

if ! [[ "$OUTER_ITERATIONS" =~ ^[0-9]+$ ]] || [ "$OUTER_ITERATIONS" -lt 1 ]; then
    echo -e "${RED}OUTER_ITERATIONS must be a positive integer.${NC}"
    exit 1
fi

if ! [[ "$WARMUP_ITERATIONS" =~ ^[0-9]+$ ]] || [ "$WARMUP_ITERATIONS" -lt 0 ]; then
    echo -e "${RED}WARMUP_ITERATIONS must be a non-negative integer.${NC}"
    exit 1
fi

if ! [[ "$PARALLEL_INSTANCES" =~ ^[0-9]+$ ]] || [ "$PARALLEL_INSTANCES" -lt 1 ]; then
    echo -e "${RED}PARALLEL_INSTANCES must be a positive integer.${NC}"
    exit 1
fi

EFFECTIVE_PARALLEL_INSTANCES="$PARALLEL_INSTANCES"
if [ "$EFFECTIVE_PARALLEL_INSTANCES" -gt "$OUTER_ITERATIONS" ]; then
    EFFECTIVE_PARALLEL_INSTANCES="$OUTER_ITERATIONS"
fi

if ! [[ "$INSTANCE_START_ID" =~ ^[0-9]+$ ]] || [ "$INSTANCE_START_ID" -lt 1 ]; then
    echo -e "${RED}INSTANCE_START_ID must be a positive integer.${NC}"
    exit 1
fi

if [ -n "$INSTANCE_END_ID" ] && { ! [[ "$INSTANCE_END_ID" =~ ^[0-9]+$ ]] || [ "$INSTANCE_END_ID" -lt 1 ]; }; then
    echo -e "${RED}INSTANCE_END_ID must be a positive integer.${NC}"
    exit 1
fi

INSTANCE_END_ID="${INSTANCE_END_ID:-$EFFECTIVE_PARALLEL_INSTANCES}"

if [ "$INSTANCE_START_ID" -gt "$EFFECTIVE_PARALLEL_INSTANCES" ]; then
    echo -e "${RED}INSTANCE_START_ID exceeds the effective parallel instance count (${EFFECTIVE_PARALLEL_INSTANCES}).${NC}"
    exit 1
fi

if [ "$INSTANCE_END_ID" -lt "$INSTANCE_START_ID" ] || [ "$INSTANCE_END_ID" -gt "$EFFECTIVE_PARALLEL_INSTANCES" ]; then
    echo -e "${RED}INSTANCE_END_ID must be between INSTANCE_START_ID and ${EFFECTIVE_PARALLEL_INSTANCES}.${NC}"
    exit 1
fi

ACTIVE_PARALLEL_INSTANCES=$((INSTANCE_END_ID - INSTANCE_START_ID + 1))

if benchmark_has_affinity_configuration; then
    benchmark_require_command taskset

    if [ "$ACTIVE_PARALLEL_INSTANCES" -gt 1 ]; then
        benchmark_ensure_allowed_core_set
        if ! (benchmark_resolve_parallel_slot_core_sets 1 "$ACTIVE_PARALLEL_INSTANCES" >/dev/null); then
            exit 1
        fi
        AFFINITY_OVERVIEW="$(benchmark_requested_affinity_summary)"
    else
        benchmark_resolve_core_sets
        AFFINITY_OVERVIEW="$(benchmark_affinity_summary)"
    fi
else
    AFFINITY_OVERVIEW="$(benchmark_affinity_summary)"
fi

print_header "WEAKREF GC BENCHMARK"
echo -e "${BOLD}Running:${NC} $OUTER_ITERATIONS outer iteration(s)"
echo -e "${BOLD}Warm-up:${NC} $WARMUP_ITERATIONS iteration(s) per instance"
echo -e "${BOLD}Parallel instances:${NC} $EFFECTIVE_PARALLEL_INSTANCES"
echo -e "${BOLD}Active range:${NC} instances ${INSTANCE_START_ID}-${INSTANCE_END_ID} on this node"
echo -e "${BOLD}Benchmark:${NC} $BENCHMARK_CLASS"
echo -e "${BOLD}Run ID:${NC} $RUN_ID"
echo -e "${BOLD}Cooldown:${NC} ${COOLDOWN_SECONDS}s between variant runs"
echo -e "${BOLD}Multi JVM opts:${NC} $MULTI_JVM_OPTS"
echo -e "${BOLD}Single JVM opts:${NC} $SINGLE_JVM_OPTS"
echo -e "${BOLD}Output root:${NC} $OUTPUT_ROOT"
echo -e "${BOLD}Affinity:${NC} ${AFFINITY_OVERVIEW}"
echo ""

cooldown_system() {
    echo "  Cooldown period (${COOLDOWN_SECONDS}s)..."
    sleep "$COOLDOWN_SECONDS"

    print_success "Cooled down system for next run"
}

cleanup_old_results() {
    print_step "Cleaning up existing CSV and log files for Run ID $RUN_ID..."

    ensure_run_output_dirs "$RUN_ID"

    rm -f "$(run_logs_dir "$RUN_ID")"/run_*_"${RUN_ID}".log
    rm -f "$(run_memory_dir "$RUN_ID")"/monitor_*_"${RUN_ID}".csv

    print_success "Existing results cleaned up for Run ID $RUN_ID"
}

run_single() {
    local label=$1
    local outer_run=$2
    local total_runs=$3
    local stage_kind=${4:-measured}
    local stage_index=${5:-0}
    local instance_id=${6:-1}
    local total_instances=${7:-1}
    local log_dir
    local memory_dir
    local log_file
    local monitor_log
    local display_context
    local log_title
    local phase_label
    local parallel_mode=false

    log_dir="$(run_logs_dir "$RUN_ID")"
    memory_dir="$(run_memory_dir "$RUN_ID")"
    mkdir -p "$log_dir" "$memory_dir"

    if [ "$stage_kind" = "warmup" ]; then
        log_file="${log_dir}/run_${BENCHMARK_NAME}_warmup_${label}_instance${instance_id}_pass${stage_index}_${RUN_ID}.log"
        monitor_log="${memory_dir}/monitor_${BENCHMARK_NAME}_warmup_${label}_instance${instance_id}_pass${stage_index}_${RUN_ID}.csv"
        display_context="Instance ${instance_id}/${total_instances}, warm-up ${stage_index}/${WARMUP_ITERATIONS}"
        log_title="=== ${display_context} (Variant ${label}) ==="
    else
        log_file="${log_dir}/run_${BENCHMARK_NAME}_${label}_run${outer_run}_${RUN_ID}.log"
        monitor_log="${memory_dir}/monitor_${BENCHMARK_NAME}_${label}_run${outer_run}_${RUN_ID}.csv"
        display_context="Instance ${instance_id}/${total_instances}, outer iteration ${outer_run}/${total_runs}"
        log_title="=== ${display_context} (Variant ${label}) ==="
    fi

    if [ "$ACTIVE_PARALLEL_INSTANCES" -gt 1 ]; then
        parallel_mode=true
    fi

    echo "  ${display_context} - Variant ${label}"
    echo "    Logging to: $log_file"
    echo "    Memory monitoring to: $monitor_log"
    echo "    Benchmark args: ${CURRENT_BENCHMARK_ARGS:-<none>}"
    
    if [ "$BENCHMARK_NAME" = "single" ]; then
        JAVA_OPTS="$SINGLE_JVM_OPTS"
    else
        JAVA_OPTS="$MULTI_JVM_OPTS"
    fi

    build_command_args "$JAVA_OPTS" "$CURRENT_BENCHMARK_ARGS"

    {
        echo ""
        echo "$log_title"
        echo ""
        echo "Affinity: $(benchmark_affinity_summary)"
        echo "Benchmark args: ${CURRENT_BENCHMARK_ARGS:-<none>}"
        echo "Command: ${COMMAND_ARGS[*]}"
        echo ""
    } >> "$log_file"

    if [ -n "${BENCHMARK_JVM_CORE_SET:-}" ]; then
        taskset --cpu-list "$BENCHMARK_JVM_CORE_SET" "${COMMAND_ARGS[@]}" >> "$log_file" 2>&1 &
    else
        "${COMMAND_ARGS[@]}" >> "$log_file" 2>&1 &
    fi

    local wrapper_pid=$!
    
    # Wait a moment for Java to start.
    sleep 1
    local java_pid=$wrapper_pid
    
    # Start memory monitor on if we got the PID
    local monitor_pid=""
    if [ -n "$java_pid" ] && kill -0 $java_pid 2>/dev/null; then
        if [ -n "${BENCHMARK_AUX_CORE_SET:-}" ]; then
            taskset --cpu-list "$BENCHMARK_AUX_CORE_SET" \
                "$MONITOR_SCRIPT" "$java_pid" "$monitor_log" "$MONITOR_INTERVAL" "$JCMD_BIN" "$log_file" &
        else
            "$MONITOR_SCRIPT" "$java_pid" "$monitor_log" "$MONITOR_INTERVAL" "$JCMD_BIN" "$log_file" &
        fi
        monitor_pid=$!
        if [ "$parallel_mode" = false ]; then
            printf "${CYAN}▶${NC} %s (Variant %s) - Memory monitor started (PID: %s -> %s)\r" \
                "$display_context" "$label" "$java_pid" "$monitor_pid"
            sleep 0.5
        fi
    fi
    
    local last_phase=""
    if [ "$parallel_mode" = false ]; then
        while kill -0 $java_pid 2>/dev/null; do
            if [ -f "$log_file" ]; then
                phase_label=$(grep -oP 'Phase\s+\d+(?:[.-]\d+)?' "$log_file" | tail -1)
                last_phase=${phase_label#Phase }
            fi

            if [ -n "$last_phase" ]; then
                printf "${CYAN}▶${NC} %s (Variant %s) - Phase %s    \r" \
                    "$display_context" "$label" "$last_phase"
            fi

            sleep 0.5
        done
    fi
    
    local exit_code=0
    wait $java_pid || exit_code=$?
    
    if [ -n "$monitor_pid" ]; then
        sleep 1
        kill $monitor_pid 2>/dev/null || true
    fi
    
    if [ $exit_code -eq 0 ]; then
        printf "${GREEN}✓${NC} %s (Variant %s) - Completed successfully!          \n" \
            "$display_context" "$label"
        echo ""
    else
        printf "${RED}✗${NC} %s (Variant %s) - Failed with exit code %d\n" \
            "$display_context" "$label" "$exit_code"
        echo ""
        return $exit_code
    fi

    return 0
}

run_variant_set() {
    local outer_run=$1
    local total_runs=$2
    local stage_kind=$3
    local stage_index=${4:-0}
    local instance_id=${5:-1}
    local total_instances=${6:-1}
    local variant
    local variant_build_dir_path
    local variant_java
    local variant_jcmd

    for variant in "${variants[@]}"; do
        variant_build_dir_path="$(variant_build_dir "$variant")"
        variant_java="$variant_build_dir_path/jdk/bin/java"
        variant_jcmd="$variant_build_dir_path/jdk/bin/jcmd"

        if [ ! -x "$variant_java" ]; then
            print_warning "Build for variant '$variant' not found at $variant_java; skipping"
            continue
        fi

        JAVA_BIN="$variant_java"
        JCMD_BIN="$variant_jcmd"
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

    if [ "$ENABLE_WEAK_FIELDS_BENCHMARK" != "1" ] || [ -z "$WEAK_FIELDS_BENCHMARK_CLASS" ]; then
        return 0
    fi

    variant="weak_fields"
    variant_build_dir_path="$(variant_build_dir "$variant")"
    variant_java="$variant_build_dir_path/jdk/bin/java"
    variant_jcmd="$variant_build_dir_path/jdk/bin/jcmd"

    if [ ! -x "$variant_java" ]; then
        print_warning "Build for weak_fields configuration not found at $variant_java; skipping"
        return 0
    fi

    JAVA_BIN="$variant_java"
    JCMD_BIN="$variant_jcmd"
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

    return 0
}

discard_warmup_results() {
    local instance_id=$1

    rm -f "$(run_logs_dir "$RUN_ID")"/run_*_warmup_*_instance${instance_id}_*_${RUN_ID}.log
    rm -f "$(run_memory_dir "$RUN_ID")"/monitor_*_warmup_*_instance${instance_id}_*_${RUN_ID}.csv
}

compute_instance_run_range() {
    local instance_id=$1
    local instance_count=$2
    local total_runs=$3
    local base_runs=$((total_runs / instance_count))
    local extra_runs=$((total_runs % instance_count))

    if [ "$instance_id" -le "$extra_runs" ]; then
        INSTANCE_RUN_COUNT=$((base_runs + 1))
        INSTANCE_RUN_START=$(((((instance_id - 1) * (base_runs + 1))) + 1))
    else
        INSTANCE_RUN_COUNT=$base_runs
        INSTANCE_RUN_START=$((((extra_runs * (base_runs + 1)) + ((instance_id - extra_runs - 1) * base_runs)) + 1))
    fi

    INSTANCE_RUN_END=$((INSTANCE_RUN_START + INSTANCE_RUN_COUNT - 1))
}

run_instance_worker() {
    local instance_id=$1
    local instance_count=$2
    local total_runs=$3
    local local_slot_index=$4
    local local_slot_count=$5
    local outer_run

    if benchmark_has_affinity_configuration; then
        if [ "$local_slot_count" -gt 1 ]; then
            benchmark_resolve_parallel_slot_core_sets "$local_slot_index" "$local_slot_count" || return 1
        else
            benchmark_resolve_core_sets || return 1
        fi
    fi

    compute_instance_run_range "$instance_id" "$instance_count" "$total_runs"

    print_step "Starting instance $instance_id/$instance_count for outer iterations ${INSTANCE_RUN_START}-${INSTANCE_RUN_END}"
    echo "  Affinity: $(benchmark_affinity_summary)"

    if [ "$WARMUP_ITERATIONS" -gt 0 ]; then
        local warmup
        for ((warmup=1; warmup<=WARMUP_ITERATIONS; warmup++)); do
            if ! run_variant_set 0 "$total_runs" warmup "$warmup" "$instance_id" "$instance_count"; then
                return 1
            fi
        done
        discard_warmup_results "$instance_id"
        print_success "Warm-up complete for instance $instance_id/$instance_count"
    fi

    for ((outer_run=INSTANCE_RUN_START; outer_run<=INSTANCE_RUN_END; outer_run++)); do
        if ! run_variant_set "$outer_run" "$total_runs" measured 0 "$instance_id" "$instance_count"; then
            return 1
        fi
    done

    return 0
}

count_measured_runs() {
    local logs_dir

    logs_dir="$(run_logs_dir "$RUN_ID")"
    find "$logs_dir" -maxdepth 1 -type f -name "run_*_run*_${RUN_ID}.log" ! -name "run_*_warmup_*" | wc -l | tr -d '[:space:]'
}

wait_for_next_instance() {
    local finished_pid=""
    local status=0

    if ! wait -n -p finished_pid; then
        status=$?
    fi

    if [ -z "$finished_pid" ]; then
        print_warning "Failed to identify the finished benchmark instance"
        return 1
    fi

    unset 'INSTANCE_SLOT_BY_PID[$finished_pid]'

    if [ $status -ne 0 ]; then
        return $status
    fi

    return 0
}

cleanup_old_results

print_header "STARTING BENCHMARK SUITE"
print_step "Running $OUTER_ITERATIONS outer iteration(s) split across $EFFECTIVE_PARALLEL_INSTANCES instance(s); this node handles instances ${INSTANCE_START_ID}-${INSTANCE_END_ID}"
echo ""

declare -A INSTANCE_SLOT_BY_PID=()

overall_status=0
local_slot_index=0
for ((instance_id=INSTANCE_START_ID; instance_id<=INSTANCE_END_ID; instance_id++)); do
    local_slot_index=$((local_slot_index + 1))
    (
        run_instance_worker "$instance_id" "$EFFECTIVE_PARALLEL_INSTANCES" "$OUTER_ITERATIONS" "$local_slot_index" "$ACTIVE_PARALLEL_INSTANCES"
    ) &
    INSTANCE_SLOT_BY_PID[$!]="$instance_id"
done

while [ "${#INSTANCE_SLOT_BY_PID[@]}" -gt 0 ]; do
    if ! wait_for_next_instance; then
        overall_status=1
        break
    fi
done

if [ $overall_status -ne 0 ]; then
    for pid in "${!INSTANCE_SLOT_BY_PID[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    wait || true

    print_header "BENCHMARK FAILED"
    echo -e "${RED}One or more runs failed. Check the log files for details.${NC}"
    exit 1
fi

measured_runs="$(count_measured_runs)"
if [ "$measured_runs" -eq 0 ]; then
    print_header "BENCHMARK FAILED"
    echo -e "${RED}No benchmark runs were executed. Check VARIANT_IMAGE_ROOT and the enabled variant list.${NC}"
    exit 1
fi

print_header "BENCHMARK COMPLETE"
echo -e "${BOLD}All benchmark runs completed successfully!${NC}"
echo ""
echo -e "${GREEN}Output Summary:${NC}"
RUN_OUTPUT_DIR="$(run_output_dir "$RUN_ID")"
echo "  • Run directory:      ${RUN_OUTPUT_DIR}"
echo "  • Benchmark logs:     ${RUN_OUTPUT_DIR}/logs/run_${BENCHMARK_NAME}_<variant>_run*_${RUN_ID}.log"
echo "  • Memory monitoring:  ${RUN_OUTPUT_DIR}/memory/monitor_${BENCHMARK_NAME}_<variant>_run*_${RUN_ID}.csv"
echo "  • Variant images:     ${VARIANT_IMAGE_ROOT}/<variant>-linux-x86_64-server-release"
if [ "$ENABLE_WEAK_FIELDS_BENCHMARK" = "1" ] && [ -n "$WEAK_FIELDS_BENCHMARK_NAME" ]; then
    echo "  • Weak-fields config: ${RUN_OUTPUT_DIR}/logs/run_${WEAK_FIELDS_BENCHMARK_NAME}_weak_fields_run*_${RUN_ID}.log"
    echo "                        ${RUN_OUTPUT_DIR}/memory/monitor_${WEAK_FIELDS_BENCHMARK_NAME}_weak_fields_run*_${RUN_ID}.csv"
fi
echo ""
echo -e "${CYAN}Next Steps:${NC}"
echo "  To analyze and compare results, run:"
echo -e "  ${YELLOW}python3 scripts/parse_gc_stats.py${NC}"
echo ""
