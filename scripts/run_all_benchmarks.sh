#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${SCRIPT_DIR}/benchmark_runtime_common.sh"

export BENCHMARK_JVM_CORE_COUNT="${BENCHMARK_JVM_CORE_COUNT:-10}"
export BENCHMARK_AUX_CORE_COUNT="${BENCHMARK_AUX_CORE_COUNT:-2}"

OUTER_ITERATIONS="${OUTER_ITERATIONS:-100}"
WARMUP_ITERATIONS="${WARMUP_ITERATIONS:-1}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-10}"
PARALLEL_INSTANCES="${PARALLEL_INSTANCES:-8}"
INSTANCE_START_ID="${INSTANCE_START_ID:-1}"
INSTANCE_END_ID="${INSTANCE_END_ID:-}"
ENABLE_ITERATION_BENCHMARKS="${ENABLE_ITERATION_BENCHMARKS:-1}"
ENABLE_WEAKVALUEHASHMAP_JMH="${ENABLE_WEAKVALUEHASHMAP_JMH:-auto}"
WEAKVALUEHASHMAP_JMH_ARGS="${WEAKVALUEHASHMAP_JMH_ARGS:-}"
RUN_ID_PREFIX="${RUN_ID_PREFIX:-$(date +%Y%m%d-%H%M%S)}"
STAGE_ROOT="${STAGE_ROOT:-/dev/shm}"
FINAL_OUTPUT_ROOT="${FINAL_OUTPUT_ROOT:-${REPO_ROOT}/output}"
MULTI_RUN_ID=""
SINGLE_RUN_ID=""
INSTANCE_RANGE_ARGS=()
WEAKVALUEHASHMAP_JMH_RUN_ID=""
EFFECTIVE_PARALLEL_INSTANCES=1
RUN_WEAKVALUEHASHMAP_JMH=0

while [ $# -gt 0 ]; do
    case $1 in
        --outer)
            OUTER_ITERATIONS="$2"
            shift 2
            ;;
        --warmup)
            WARMUP_ITERATIONS="$2"
            shift 2
            ;;
        --cooldown)
            COOLDOWN_SECONDS="$2"
            shift 2
            ;;
        --parallel-instances)
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
        --skip-weakhashmap-jmh)
            ENABLE_WEAKVALUEHASHMAP_JMH=0
            shift
            ;;
        --run-weakhashmap-jmh)
            ENABLE_WEAKVALUEHASHMAP_JMH=1
            shift
            ;;
        --run-id-prefix)
            RUN_ID_PREFIX="$2"
            shift 2
            ;;
        --stage-root)
            STAGE_ROOT="$2"
            shift 2
            ;;
        --final-output-root)
            FINAL_OUTPUT_ROOT="$2"
            shift 2
            ;;
        --variant-image-root)
            export VARIANT_IMAGE_ROOT="$2"
            shift 2
            ;;
        --jvm-core-count)
            export BENCHMARK_JVM_CORE_COUNT="$2"
            shift 2
            ;;
        --aux-core-count)
            export BENCHMARK_AUX_CORE_COUNT="$2"
            shift 2
            ;;
        --jvm-core-set)
            export BENCHMARK_JVM_CORE_SET="$2"
            shift 2
            ;;
        --aux-core-set)
            export BENCHMARK_AUX_CORE_SET="$2"
            shift 2
            ;;
        --multi-run-id)
            MULTI_RUN_ID="$2"
            shift 2
            ;;
        --single-run-id)
            SINGLE_RUN_ID="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

MULTI_RUN_ID="${MULTI_RUN_ID:-${RUN_ID_PREFIX}-multi}"
SINGLE_RUN_ID="${SINGLE_RUN_ID:-${RUN_ID_PREFIX}-single}"
WEAKVALUEHASHMAP_JMH_RUN_ID="${WEAKVALUEHASHMAP_JMH_RUN_ID:-${RUN_ID_PREFIX}-weakvaluehashmap-jmh}"

if ! [[ "$OUTER_ITERATIONS" =~ ^[0-9]+$ ]] || [ "$OUTER_ITERATIONS" -lt 1 ]; then
    echo "OUTER_ITERATIONS must be a positive integer." >&2
    exit 1
fi

if ! [[ "$PARALLEL_INSTANCES" =~ ^[0-9]+$ ]] || [ "$PARALLEL_INSTANCES" -lt 1 ]; then
    echo "PARALLEL_INSTANCES must be a positive integer." >&2
    exit 1
fi

if ! [[ "$INSTANCE_START_ID" =~ ^[0-9]+$ ]] || [ "$INSTANCE_START_ID" -lt 1 ]; then
    echo "INSTANCE_START_ID must be a positive integer." >&2
    exit 1
fi

EFFECTIVE_PARALLEL_INSTANCES="$PARALLEL_INSTANCES"
if [ "$EFFECTIVE_PARALLEL_INSTANCES" -gt "$OUTER_ITERATIONS" ]; then
    EFFECTIVE_PARALLEL_INSTANCES="$OUTER_ITERATIONS"
fi

INSTANCE_END_ID="${INSTANCE_END_ID:-$EFFECTIVE_PARALLEL_INSTANCES}"

if ! [[ "$INSTANCE_END_ID" =~ ^[0-9]+$ ]] || [ "$INSTANCE_END_ID" -lt 1 ]; then
    echo "INSTANCE_END_ID must be a positive integer." >&2
    exit 1
fi

if [ "$INSTANCE_START_ID" -gt "$EFFECTIVE_PARALLEL_INSTANCES" ]; then
    echo "INSTANCE_START_ID exceeds the effective parallel instance count (${EFFECTIVE_PARALLEL_INSTANCES})." >&2
    exit 1
fi

if [ "$INSTANCE_END_ID" -lt "$INSTANCE_START_ID" ] || [ "$INSTANCE_END_ID" -gt "$EFFECTIVE_PARALLEL_INSTANCES" ]; then
    echo "INSTANCE_END_ID must be between INSTANCE_START_ID and ${EFFECTIVE_PARALLEL_INSTANCES}." >&2
    exit 1
fi

case "$ENABLE_ITERATION_BENCHMARKS" in
    1|true|TRUE|yes|YES)
        ENABLE_ITERATION_BENCHMARKS=1
        ;;
    0|false|FALSE|no|NO)
        ENABLE_ITERATION_BENCHMARKS=0
        ;;
    *)
        echo "ENABLE_ITERATION_BENCHMARKS must be 0 or 1." >&2
        exit 1
        ;;
esac

case "$ENABLE_WEAKVALUEHASHMAP_JMH" in
    auto)
        if [ "$INSTANCE_START_ID" -eq 1 ] && [ "$INSTANCE_END_ID" -eq "$EFFECTIVE_PARALLEL_INSTANCES" ]; then
            RUN_WEAKVALUEHASHMAP_JMH=1
        else
            RUN_WEAKVALUEHASHMAP_JMH=0
        fi
        ;;
    1|true|TRUE|yes|YES)
        RUN_WEAKVALUEHASHMAP_JMH=1
        ;;
    0|false|FALSE|no|NO)
        RUN_WEAKVALUEHASHMAP_JMH=0
        ;;
    *)
        echo "ENABLE_WEAKVALUEHASHMAP_JMH must be 0, 1, or auto." >&2
        exit 1
        ;;
esac

if [ -n "$INSTANCE_END_ID" ] || [ "$INSTANCE_START_ID" != "1" ]; then
    INSTANCE_RANGE_ARGS=(--instance-start "$INSTANCE_START_ID" --instance-end "$INSTANCE_END_ID")
fi

run_weakvaluehashmap_jmh() {
    local result_root="${OUTPUT_ROOT}/id_${WEAKVALUEHASHMAP_JMH_RUN_ID}"
    local -a extra_args=()

    if [ -n "$WEAKVALUEHASHMAP_JMH_ARGS" ]; then
        read -r -a extra_args <<< "$WEAKVALUEHASHMAP_JMH_ARGS"
    fi

    benchmark_note "Running weakvaluehashmap JMH into ${result_root}"
    /usr/bin/bash "${SCRIPT_DIR}/run_weakvaluehashmap_jmh.sh" \
        --no-build \
        --result-root "$result_root" \
        "${extra_args[@]}"
}

if benchmark_has_affinity_configuration; then
    benchmark_ensure_allowed_core_set
fi

STAGE_DIR="$(benchmark_prepare_stage_dir "$STAGE_ROOT" "weakref-bench-${RUN_ID_PREFIX}")"
export OUTPUT_ROOT="$STAGE_DIR"

cleanup() {
    local exit_code=$1

    if [ -d "$STAGE_DIR" ]; then
        benchmark_note "Copying staged output from ${STAGE_DIR} to ${FINAL_OUTPUT_ROOT}"
        if benchmark_copy_stage_to_final "$STAGE_DIR" "$FINAL_OUTPUT_ROOT"; then
            rm -rf "$STAGE_DIR"
        else
            benchmark_warn "failed to copy staged output; leaving ${STAGE_DIR} in place"
        fi
    fi

    return "$exit_code"
}

trap 'exit_code=$?; cleanup "$exit_code"; exit "$exit_code"' EXIT

cd "$REPO_ROOT"

cat > "${STAGE_DIR}/run-metadata.txt" <<EOF
run_id_prefix=${RUN_ID_PREFIX}
multi_run_id=${MULTI_RUN_ID}
single_run_id=${SINGLE_RUN_ID}
weakvaluehashmap_jmh_run_id=${WEAKVALUEHASHMAP_JMH_RUN_ID}
outer_iterations=${OUTER_ITERATIONS}
warmup_iterations=${WARMUP_ITERATIONS}
cooldown_seconds=${COOLDOWN_SECONDS}
parallel_instances=${PARALLEL_INSTANCES}
effective_parallel_instances=${EFFECTIVE_PARALLEL_INSTANCES}
active_instance_range=${INSTANCE_START_ID}-${INSTANCE_END_ID}
iteration_benchmarks_enabled=${ENABLE_ITERATION_BENCHMARKS}
weakvaluehashmap_jmh_enabled=${RUN_WEAKVALUEHASHMAP_JMH}
affinity=$(benchmark_requested_affinity_summary)
variant_image_root=${VARIANT_IMAGE_ROOT:-${REPO_ROOT}/build/variant-images}
final_output_root=${FINAL_OUTPUT_ROOT}
stage_dir=${STAGE_DIR}
EOF

benchmark_note "Using stage directory ${STAGE_DIR}"
benchmark_note "Parallel instances: ${PARALLEL_INSTANCES}"
if [ "${#INSTANCE_RANGE_ARGS[@]}" -gt 0 ]; then
    benchmark_note "Active instance range: ${INSTANCE_START_ID}-${INSTANCE_END_ID}"
fi
benchmark_note "Affinity: $(benchmark_requested_affinity_summary)"

if [ "$ENABLE_ITERATION_BENCHMARKS" = "1" ]; then
    bash "${SCRIPT_DIR}/run_benchmark_iterations.sh" \
        --benchmark multi \
        --id "$MULTI_RUN_ID" \
        --cooldown "$COOLDOWN_SECONDS" \
        --parallel-instances "$PARALLEL_INSTANCES" \
        --warmup "$WARMUP_ITERATIONS" \
        "${INSTANCE_RANGE_ARGS[@]}" \
        "$OUTER_ITERATIONS"

    bash "${SCRIPT_DIR}/run_benchmark_iterations.sh" \
        --benchmark single \
        --id "$SINGLE_RUN_ID" \
        --cooldown "$COOLDOWN_SECONDS" \
        --parallel-instances "$PARALLEL_INSTANCES" \
        --warmup "$WARMUP_ITERATIONS" \
        "${INSTANCE_RANGE_ARGS[@]}" \
        "$OUTER_ITERATIONS"
else
    benchmark_note "Skipping iteration benchmarks"
fi

if [ "$RUN_WEAKVALUEHASHMAP_JMH" = "1" ]; then
    run_weakvaluehashmap_jmh
else
    benchmark_note "Skipping weakvaluehashmap JMH for this invocation"
fi