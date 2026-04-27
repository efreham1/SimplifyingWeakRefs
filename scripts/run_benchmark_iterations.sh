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
#   --heap-size SIZE                 Heap size used for both -Xms and -Xmx (default: 4g)
#   --reference-count N              Reference count for both multi and single benchmarks
#   --multi-reference-count N        Reference count for multi benchmarks
#   --single-reference-count N       Reference count for single benchmarks
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

benchmark_fail() {
    printf '[benchmark] error: %s\n' "$*" >&2
    return 1
}

benchmark_with_heap_size() {
    local opts=$1
    local heap_size=$2

    opts="$(printf '%s\n' "$opts" | sed -E 's/(^|[[:space:]])-Xms[^[:space:]]+//g; s/(^|[[:space:]])-Xmx[^[:space:]]+//g; s/[[:space:]]+/ /g; s/^ //; s/ $//')"

    if [ -n "$opts" ]; then
        printf '%s\n' "-Xms${heap_size} -Xmx${heap_size} ${opts}"
    else
        printf '%s\n' "-Xms${heap_size} -Xmx${heap_size}"
    fi
}

benchmark_require_command() {
    local command_name=$1

    command -v "$command_name" >/dev/null 2>&1 || benchmark_fail "required command not found: ${command_name}"
}

benchmark_get_allowed_cpu_list() {
    local cpu_list=""

    if [ -r /proc/self/status ]; then
        cpu_list="$(awk '/^Cpus_allowed_list:/ { print $2 }' /proc/self/status)"
    fi

    if [ -z "$cpu_list" ] && command -v taskset >/dev/null 2>&1; then
        cpu_list="$(taskset -pc $$ 2>/dev/null | awk -F: 'NR == 1 { gsub(/[[:space:]]/, "", $2); print $2 }')"
    fi

    printf '%s\n' "$cpu_list"
}

benchmark_expand_cpu_list() {
    local cpu_list=$1
    local chunk
    local start
    local end
    local cpu

    [ -n "$cpu_list" ] || return 0

    IFS=',' read -r -a chunks <<< "$cpu_list"
    for chunk in "${chunks[@]}"; do
        chunk=${chunk//[[:space:]]/}
        [ -n "$chunk" ] || continue

        if [[ "$chunk" == *-* ]]; then
            start=${chunk%-*}
            end=${chunk#*-}

            if ! [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ ]]; then
                benchmark_fail "invalid CPU range: ${chunk}"
                return 1
            fi

            if [ "$start" -gt "$end" ]; then
                benchmark_fail "CPU range start is greater than end: ${chunk}"
                return 1
            fi

            for ((cpu = start; cpu <= end; cpu++)); do
                printf '%s\n' "$cpu"
            done
        else
            if ! [[ "$chunk" =~ ^[0-9]+$ ]]; then
                benchmark_fail "invalid CPU index: ${chunk}"
                return 1
            fi
            printf '%s\n' "$chunk"
        fi
    done
}

benchmark_normalise_cpu_list() {
    local cpu_list=$1
    local -a cpus=()

    mapfile -t cpus < <(benchmark_expand_cpu_list "$cpu_list") || return 1
    if [ "${#cpus[@]}" -eq 0 ]; then
        benchmark_fail "CPU list resolves to zero CPUs"
        return 1
    fi

    (IFS=,; printf '%s\n' "${cpus[*]}")
}

benchmark_cpu_count() {
    local cpu_list=$1
    local -a cpus=()

    mapfile -t cpus < <(benchmark_expand_cpu_list "$cpu_list") || return 1
    printf '%s\n' "${#cpus[@]}"
}

benchmark_validate_cpu_subset() {
    local subset_list=$1
    local allowed_list=$2
    local -A allowed_map=()
    local cpu

    while IFS= read -r cpu; do
        allowed_map["$cpu"]=1
    done < <(benchmark_expand_cpu_list "$allowed_list")

    while IFS= read -r cpu; do
        if [ -z "${allowed_map[$cpu]:-}" ]; then
            benchmark_fail "CPU ${cpu} is outside the allowed CPU set ${allowed_list}"
            return 1
        fi
    done < <(benchmark_expand_cpu_list "$subset_list")
}

benchmark_validate_disjoint_cpu_lists() {
    local left_list=$1
    local right_list=$2
    local -A left_map=()
    local cpu

    while IFS= read -r cpu; do
        left_map["$cpu"]=1
    done < <(benchmark_expand_cpu_list "$left_list")

    while IFS= read -r cpu; do
        if [ -n "${left_map[$cpu]:-}" ]; then
            benchmark_fail "CPU ${cpu} appears in both CPU sets"
            return 1
        fi
    done < <(benchmark_expand_cpu_list "$right_list")
}

benchmark_has_affinity_configuration() {
    [ -n "${BENCHMARK_JVM_CORE_SET:-}" ] || [ -n "${BENCHMARK_AUX_CORE_SET:-}" ] || \
        [ -n "${BENCHMARK_JVM_CORE_COUNT:-}" ] || [ -n "${BENCHMARK_AUX_CORE_COUNT:-}" ]
}

benchmark_ensure_allowed_core_set() {
    local allowed_list="${BENCHMARK_ALLOWED_CORE_SET:-}"

    if [ -z "$allowed_list" ]; then
        allowed_list="$(benchmark_get_allowed_cpu_list)"
    fi
    if [ -z "$allowed_list" ]; then
        benchmark_fail "unable to determine allowed CPU list"
        return 1
    fi

    allowed_list="$(benchmark_normalise_cpu_list "$allowed_list")" || return 1
    export BENCHMARK_ALLOWED_CORE_SET="$allowed_list"
}

benchmark_requested_affinity_summary() {
    local allowed_set="${BENCHMARK_ALLOWED_CORE_SET:-unset}"

    if [ -n "${BENCHMARK_JVM_CORE_SET:-}" ] || [ -n "${BENCHMARK_AUX_CORE_SET:-}" ]; then
        printf 'requested jvm=%s aux=%s allowed=%s\n' \
            "${BENCHMARK_JVM_CORE_SET:-unset}" \
            "${BENCHMARK_AUX_CORE_SET:-unset}" \
            "$allowed_set"
    elif [ -n "${BENCHMARK_JVM_CORE_COUNT:-}" ] || [ -n "${BENCHMARK_AUX_CORE_COUNT:-}" ]; then
        printf 'requested per-instance jvm-count=%s aux-count=%s allowed=%s\n' \
            "${BENCHMARK_JVM_CORE_COUNT:-unset}" \
            "${BENCHMARK_AUX_CORE_COUNT:-unset}" \
            "$allowed_set"
    else
        printf 'affinity disabled\n'
    fi
}

benchmark_resolve_core_sets() {
    local allowed_list
    local allowed_count
    local jvm_core_count
    local aux_core_count
    local aux_start
    local -a allowed_cpus=()
    local -a jvm_cpus=()
    local -a aux_cpus=()

    benchmark_ensure_allowed_core_set || return 1
    allowed_list="${BENCHMARK_ALLOWED_CORE_SET}"
    allowed_count="$(benchmark_cpu_count "$allowed_list")" || return 1

    if [ -n "${BENCHMARK_JVM_CORE_SET:-}" ] || [ -n "${BENCHMARK_AUX_CORE_SET:-}" ]; then
        if [ -z "${BENCHMARK_JVM_CORE_SET:-}" ] || [ -z "${BENCHMARK_AUX_CORE_SET:-}" ]; then
            benchmark_fail "both BENCHMARK_JVM_CORE_SET and BENCHMARK_AUX_CORE_SET must be set together"
            return 1
        fi

        BENCHMARK_JVM_CORE_SET="$(benchmark_normalise_cpu_list "$BENCHMARK_JVM_CORE_SET")" || return 1
        BENCHMARK_AUX_CORE_SET="$(benchmark_normalise_cpu_list "$BENCHMARK_AUX_CORE_SET")" || return 1

        benchmark_validate_cpu_subset "$BENCHMARK_JVM_CORE_SET" "$allowed_list" || return 1
        benchmark_validate_cpu_subset "$BENCHMARK_AUX_CORE_SET" "$allowed_list" || return 1
        benchmark_validate_disjoint_cpu_lists "$BENCHMARK_JVM_CORE_SET" "$BENCHMARK_AUX_CORE_SET" || return 1
    else
        jvm_core_count=${BENCHMARK_JVM_CORE_COUNT:-}
        aux_core_count=${BENCHMARK_AUX_CORE_COUNT:-}

        if [ -z "$jvm_core_count" ] || [ -z "$aux_core_count" ]; then
            benchmark_fail "set BENCHMARK_JVM_CORE_COUNT and BENCHMARK_AUX_CORE_COUNT, or provide explicit CPU sets"
            return 1
        fi

        if ! [[ "$jvm_core_count" =~ ^[0-9]+$ && "$aux_core_count" =~ ^[0-9]+$ ]]; then
            benchmark_fail "CPU counts must be positive integers"
            return 1
        fi

        if [ "$jvm_core_count" -lt 1 ] || [ "$aux_core_count" -lt 1 ]; then
            benchmark_fail "CPU counts must be at least 1"
            return 1
        fi

        if [ $((jvm_core_count + aux_core_count)) -gt "$allowed_count" ]; then
            benchmark_fail "requested ${jvm_core_count} JVM CPUs and ${aux_core_count} auxiliary CPUs, but only ${allowed_count} CPUs are available (${allowed_list})"
            return 1
        fi

        mapfile -t allowed_cpus < <(benchmark_expand_cpu_list "$allowed_list")
        jvm_cpus=("${allowed_cpus[@]:0:jvm_core_count}")
        aux_start=$((allowed_count - aux_core_count))
        aux_cpus=("${allowed_cpus[@]:aux_start:aux_core_count}")

        BENCHMARK_JVM_CORE_SET="$(IFS=,; printf '%s' "${jvm_cpus[*]}")"
        BENCHMARK_AUX_CORE_SET="$(IFS=,; printf '%s' "${aux_cpus[*]}")"
    fi

    unset BENCHMARK_INSTANCE_ALLOWED_CORE_SET
    export BENCHMARK_ALLOWED_CORE_SET="$allowed_list"
    export BENCHMARK_JVM_CORE_SET
    export BENCHMARK_AUX_CORE_SET
}

benchmark_resolve_parallel_slot_core_sets() {
    local slot_index=$1
    local slot_count=$2
    local allowed_count
    local jvm_core_count
    local aux_core_count
    local per_slot_core_count
    local slot_start
    local -a allowed_cpus=()
    local -a slot_cpus=()
    local -a jvm_cpus=()
    local -a aux_cpus=()

    if [ "$slot_count" -lt 1 ] || [ "$slot_index" -lt 1 ] || [ "$slot_index" -gt "$slot_count" ]; then
        benchmark_fail "invalid parallel slot assignment ${slot_index}/${slot_count}"
        return 1
    fi

    benchmark_ensure_allowed_core_set || return 1
    allowed_count="$(benchmark_cpu_count "$BENCHMARK_ALLOWED_CORE_SET")" || return 1

    if [ -n "${BENCHMARK_JVM_CORE_SET:-}" ] || [ -n "${BENCHMARK_AUX_CORE_SET:-}" ]; then
        benchmark_fail "parallel benchmark instances require BENCHMARK_JVM_CORE_COUNT and BENCHMARK_AUX_CORE_COUNT instead of explicit CPU sets"
        return 1
    fi

    jvm_core_count=${BENCHMARK_JVM_CORE_COUNT:-}
    aux_core_count=${BENCHMARK_AUX_CORE_COUNT:-}
    if [ -z "$jvm_core_count" ] || [ -z "$aux_core_count" ]; then
        benchmark_fail "parallel benchmark instances require BENCHMARK_JVM_CORE_COUNT and BENCHMARK_AUX_CORE_COUNT"
        return 1
    fi
    if ! [[ "$jvm_core_count" =~ ^[0-9]+$ && "$aux_core_count" =~ ^[0-9]+$ ]]; then
        benchmark_fail "CPU counts must be positive integers"
        return 1
    fi
    if [ "$jvm_core_count" -lt 1 ] || [ "$aux_core_count" -lt 1 ]; then
        benchmark_fail "CPU counts must be at least 1"
        return 1
    fi

    per_slot_core_count=$((jvm_core_count + aux_core_count))
    if [ $((slot_count * per_slot_core_count)) -gt "$allowed_count" ]; then
        benchmark_fail "requested ${slot_count} parallel instances with ${jvm_core_count} JVM CPUs and ${aux_core_count} auxiliary CPUs each, but only ${allowed_count} CPUs are available (${BENCHMARK_ALLOWED_CORE_SET})"
        return 1
    fi

    mapfile -t allowed_cpus < <(benchmark_expand_cpu_list "$BENCHMARK_ALLOWED_CORE_SET")
    slot_start=$(((slot_index - 1) * per_slot_core_count))
    slot_cpus=("${allowed_cpus[@]:slot_start:per_slot_core_count}")
    jvm_cpus=("${slot_cpus[@]:0:jvm_core_count}")
    aux_cpus=("${slot_cpus[@]:jvm_core_count:aux_core_count}")

    BENCHMARK_INSTANCE_ALLOWED_CORE_SET="$(IFS=,; printf '%s' "${slot_cpus[*]}")"
    BENCHMARK_JVM_CORE_SET="$(IFS=,; printf '%s' "${jvm_cpus[*]}")"
    BENCHMARK_AUX_CORE_SET="$(IFS=,; printf '%s' "${aux_cpus[*]}")"

    export BENCHMARK_INSTANCE_ALLOWED_CORE_SET
    export BENCHMARK_JVM_CORE_SET
    export BENCHMARK_AUX_CORE_SET
}

benchmark_affinity_summary() {
    local allowed_set="${BENCHMARK_INSTANCE_ALLOWED_CORE_SET:-${BENCHMARK_ALLOWED_CORE_SET:-unknown}}"

    if benchmark_has_affinity_configuration; then
        printf 'allowed=%s jvm=%s aux=%s\n' \
            "$allowed_set" \
            "${BENCHMARK_JVM_CORE_SET:-unset}" \
            "${BENCHMARK_AUX_CORE_SET:-unset}"
    else
        printf 'affinity disabled\n'
    fi
}

# --- Defaults ---
BENCHMARK_NAME="${BENCHMARK_NAME:-both}"
RUN_ID_PREFIX="${RUN_ID_PREFIX:-$(date +%Y%m%d-%H%M%S)}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${REPO_ROOT}/output}"
VARIANT_IMAGE_ROOT="${VARIANT_IMAGE_ROOT:-${REPO_ROOT}/build/variant-images}"
OUTER_ITERATIONS="${OUTER_ITERATIONS:-1}"
WARMUP_ITERATIONS="${WARMUP_ITERATIONS:-0}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-1}"
PARALLEL_INSTANCES="${PARALLEL_INSTANCES:-1}"
INSTANCE_START_ID="${INSTANCE_START_ID:-1}"
INSTANCE_END_ID="${INSTANCE_END_ID:-}"
BENCHMARK_HEAP_SIZE="${BENCHMARK_HEAP_SIZE:-4g}"
export BENCHMARK_JVM_CORE_COUNT="${BENCHMARK_JVM_CORE_COUNT:-4}"
export BENCHMARK_AUX_CORE_COUNT="${BENCHMARK_AUX_CORE_COUNT:-1}"

MULTI_JVM_OPTS="${MULTI_JVM_OPTS:--Xms${BENCHMARK_HEAP_SIZE} -Xmx${BENCHMARK_HEAP_SIZE} -XX:+UseZGC -Xlog:gc+stats,gc+ref -XX:InitialTenuringThreshold=1 -XX:MaxTenuringThreshold=1 -XX:-ZProactive -XX:ZCollectionIntervalMajor=315360000 -XX:+ZCollectionIntervalOnly -XX:NativeMemoryTracking=summary}"
SINGLE_JVM_OPTS="${SINGLE_JVM_OPTS:--Xms${BENCHMARK_HEAP_SIZE} -Xmx${BENCHMARK_HEAP_SIZE} -XX:+UseZGC -Xlog:gc+stats,gc+ref -XX:InitialTenuringThreshold=1 -XX:MaxTenuringThreshold=1 -XX:-ZProactive -XX:ZCollectionIntervalMajor=315360000 -XX:+ZCollectionIntervalOnly -XX:NativeMemoryTracking=summary}"
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

BENCHMARK_ABORT_REQUESTED=0
declare -a BENCHMARK_WORKER_PIDS=()

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

benchmark_unregister_worker_pid() {
    local finished_pid=$1
    local -a remaining=()
    local pid

    for pid in "${BENCHMARK_WORKER_PIDS[@]}"; do
        [ "$pid" = "$finished_pid" ] || remaining+=("$pid")
    done
    BENCHMARK_WORKER_PIDS=("${remaining[@]}")
}

benchmark_terminate_workers() {
    local pid

    for pid in "${BENCHMARK_WORKER_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
}

benchmark_handle_interrupt() {
    local signal_name=$1

    if [ "$BENCHMARK_ABORT_REQUESTED" -eq 1 ]; then
        return 0
    fi

    BENCHMARK_ABORT_REQUESTED=1
    echo ""
    print_warning "Received ${signal_name}; stopping benchmark workers"
    benchmark_terminate_workers
}

trap 'benchmark_handle_interrupt INT' INT
trap 'benchmark_handle_interrupt TERM' TERM

# --- Argument parsing ---
while [ $# -gt 0 ]; do
    case $1 in
        --benchmark|-b)          BENCHMARK_NAME="$2";                  shift 2 ;;
        --run-id-prefix)         RUN_ID_PREFIX="$2";                   shift 2 ;;
        --output-root)           OUTPUT_ROOT="$2";                     shift 2 ;;
        --variant-image-root)    VARIANT_IMAGE_ROOT="$2";              shift 2 ;;
        --heap-size)             BENCHMARK_HEAP_SIZE="$2";             shift 2 ;;
        --reference-count)       MULTI_BENCHMARK_ARGS="$2"; SINGLE_BENCHMARK_ARGS="$2"; shift 2 ;;
        --multi-reference-count) MULTI_BENCHMARK_ARGS="$2";            shift 2 ;;
        --single-reference-count) SINGLE_BENCHMARK_ARGS="$2";          shift 2 ;;
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

[ -n "$BENCHMARK_HEAP_SIZE" ] || { echo -e "${RED}BENCHMARK_HEAP_SIZE must not be empty.${NC}" >&2; exit 1; }
MULTI_JVM_OPTS="$(benchmark_with_heap_size "$MULTI_JVM_OPTS" "$BENCHMARK_HEAP_SIZE")"
SINGLE_JVM_OPTS="$(benchmark_with_heap_size "$SINGLE_JVM_OPTS" "$BENCHMARK_HEAP_SIZE")"
[[ "$MULTI_BENCHMARK_ARGS" =~ ^[0-9]+$ ]] && [ "$MULTI_BENCHMARK_ARGS" -ge 1 ] || \
    { echo -e "${RED}MULTI reference count must be a positive integer.${NC}" >&2; exit 1; }
[[ "$SINGLE_BENCHMARK_ARGS" =~ ^[0-9]+$ ]] && [ "$SINGLE_BENCHMARK_ARGS" -ge 1 ] || \
    { echo -e "${RED}SINGLE reference count must be a positive integer.${NC}" >&2; exit 1; }

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
    local parallel_mode=false java_opts exit_code=0 java_pid monitor_pid="" interrupted=0
    local -a cmd _opts _args

    log_dir="$(run_logs_dir "$RUN_ID")"
    memory_dir="$(run_memory_dir "$RUN_ID")"
    mkdir -p "$log_dir" "$memory_dir"

    trap 'interrupted=1; [ -n "${monitor_pid:-}" ] && kill "$monitor_pid" 2>/dev/null || true; [ -n "${java_pid:-}" ] && kill "$java_pid" 2>/dev/null || true' INT TERM

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

    trap - INT TERM

    if [ "$interrupted" -eq 1 ] || [ "$BENCHMARK_ABORT_REQUESTED" -eq 1 ]; then
        return 130
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

    if [ "$BENCHMARK_ABORT_REQUESTED" -eq 1 ]; then
        return 130
    fi

    wait -n -p finished_pid || status=$?
    if [ -z "$finished_pid" ]; then
        print_warning "Failed to identify the finished benchmark instance"
        return 1
    fi
    unset 'INSTANCE_SLOT_BY_PID[$finished_pid]'
    benchmark_unregister_worker_pid "$finished_pid"
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
        BENCHMARK_WORKER_PIDS+=("$!")
    done

    while [ "${#INSTANCE_SLOT_BY_PID[@]}" -gt 0 ]; do
        wait_for_next_instance || { overall_status=1; break; }
    done

    if [ $overall_status -ne 0 ]; then
        benchmark_terminate_workers
        wait || true
        BENCHMARK_WORKER_PIDS=()
        echo -e "${RED}One or more benchmark instances failed. Check the log files.${NC}" >&2
        return 1
    fi

    BENCHMARK_WORKER_PIDS=()

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
