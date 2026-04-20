#!/usr/bin/bash
#SBATCH --job-name=weakref-bench
#SBATCH --account=uppmax2026-1-109
#SBATCH --nodes=2
#SBATCH --ntasks=2
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=48
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --hint=nomultithread
#SBATCH --time=30:00:00
#SBATCH --output=/dev/shm/weakref-bench-%j.out
#SBATCH --error=/dev/shm/weakref-bench-%j.err

set -euo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:${PATH}}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-}"

if [ -z "${REPO_ROOT}" ]; then
    if [ -n "${SLURM_SUBMIT_DIR:-}" ] && [ -f "${SLURM_SUBMIT_DIR}/scripts/run_all_benchmarks.sh" ]; then
        REPO_ROOT="${SLURM_SUBMIT_DIR}"
    else
        REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
    fi
fi

export BENCHMARK_JVM_CORE_COUNT="${BENCHMARK_JVM_CORE_COUNT:-10}"
export BENCHMARK_AUX_CORE_COUNT="${BENCHMARK_AUX_CORE_COUNT:-2}"
export OUTER_ITERATIONS="${OUTER_ITERATIONS:-100}"
export WARMUP_ITERATIONS="${WARMUP_ITERATIONS:-1}"
export COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-10}"
export PARALLEL_INSTANCES="${PARALLEL_INSTANCES:-8}"
export RUN_ID_PREFIX="${RUN_ID_PREFIX:-slurm-${SLURM_JOB_ID}}"
export STAGE_ROOT="${STAGE_ROOT:-/dev/shm}"
export FINAL_OUTPUT_ROOT="${FINAL_OUTPUT_ROOT:-${REPO_ROOT}/output}"
export REPO_ROOT

copy_slurm_logs() {
    local exit_code=$1
    local slurm_output="/dev/shm/weakref-bench-${SLURM_JOB_ID}.out"
    local slurm_error="/dev/shm/weakref-bench-${SLURM_JOB_ID}.err"
    local slurm_dest="${FINAL_OUTPUT_ROOT}/slurm"

    mkdir -p "$slurm_dest"

    [ ! -f "$slurm_output" ] || cp -a "$slurm_output" "$slurm_dest/"
    [ ! -f "$slurm_error" ] || cp -a "$slurm_error" "$slurm_dest/"

    return "$exit_code"
}

trap 'exit_code=$?; copy_slurm_logs "$exit_code"; exit "$exit_code"' EXIT

cd "$REPO_ROOT"

validate_positive_integer() {
    local value=$1
    local label=$2

    if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 1 ]; then
        printf '[benchmark] error: %s must be a positive integer\n' "$label" >&2
        exit 1
    fi
}

validate_positive_integer "$BENCHMARK_JVM_CORE_COUNT" BENCHMARK_JVM_CORE_COUNT
validate_positive_integer "$BENCHMARK_AUX_CORE_COUNT" BENCHMARK_AUX_CORE_COUNT
validate_positive_integer "$OUTER_ITERATIONS" OUTER_ITERATIONS
validate_positive_integer "$PARALLEL_INSTANCES" PARALLEL_INSTANCES

TOTAL_BENCHMARK_INSTANCES="$PARALLEL_INSTANCES"
if [ "$TOTAL_BENCHMARK_INSTANCES" -gt "$OUTER_ITERATIONS" ]; then
    TOTAL_BENCHMARK_INSTANCES="$OUTER_ITERATIONS"
fi

PER_INSTANCE_CORE_COUNT=$((BENCHMARK_JVM_CORE_COUNT + BENCHMARK_AUX_CORE_COUNT))
MAX_INSTANCES_PER_NODE=$((SLURM_CPUS_PER_TASK / PER_INSTANCE_CORE_COUNT))
MAX_TOTAL_INSTANCES=$((MAX_INSTANCES_PER_NODE * SLURM_JOB_NUM_NODES))

if [ "$MAX_INSTANCES_PER_NODE" -lt 1 ]; then
    printf '[benchmark] error: each node only has %s CPUs per task, which is insufficient for one benchmark instance requiring %s CPUs\n' \
        "$SLURM_CPUS_PER_TASK" "$PER_INSTANCE_CORE_COUNT" >&2
    exit 1
fi

if [ "$TOTAL_BENCHMARK_INSTANCES" -gt "$MAX_TOTAL_INSTANCES" ]; then
    printf '[benchmark] error: requested %s effective instances but two nodes with %s CPUs per task only support %s instances at %s CPUs each\n' \
        "$TOTAL_BENCHMARK_INSTANCES" "$SLURM_CPUS_PER_TASK" "$MAX_TOTAL_INSTANCES" "$PER_INSTANCE_CORE_COUNT" >&2
    exit 1
fi

export TOTAL_BENCHMARK_INSTANCES

srun \
    --nodes "$SLURM_JOB_NUM_NODES" \
    --ntasks "$SLURM_JOB_NUM_NODES" \
    --ntasks-per-node 1 \
    --cpus-per-task "$SLURM_CPUS_PER_TASK" \
    --cpu-bind=none \
    --label \
    /usr/bin/env bash -s <<'EOF'
set -euo pipefail

node_count="${SLURM_STEP_NUM_NODES:-${SLURM_JOB_NUM_NODES:-1}}"
node_rank="${SLURM_PROCID:-0}"
total_instances="${TOTAL_BENCHMARK_INSTANCES}"
base_instances=$((total_instances / node_count))
extra_instances=$((total_instances % node_count))

if [ "$node_rank" -lt "$extra_instances" ]; then
    local_instance_count=$((base_instances + 1))
    instance_start=$(((node_rank * (base_instances + 1)) + 1))
else
    local_instance_count=$base_instances
    instance_start=$((((extra_instances * (base_instances + 1)) + ((node_rank - extra_instances) * base_instances)) + 1))
fi

if [ "$local_instance_count" -lt 1 ]; then
    printf '[benchmark] node %s/%s has no assigned instances; skipping\n' "$((node_rank + 1))" "$node_count"
    exit 0
fi

instance_end=$((instance_start + local_instance_count - 1))

printf '[benchmark] node %s/%s running global instances %s-%s\n' \
    "$((node_rank + 1))" "$node_count" "$instance_start" "$instance_end"

/usr/bin/bash "${REPO_ROOT}/scripts/run_all_benchmarks.sh" \
    --outer "$OUTER_ITERATIONS" \
    --warmup "$WARMUP_ITERATIONS" \
    --cooldown "$COOLDOWN_SECONDS" \
    --parallel-instances "$total_instances" \
    --instance-start "$instance_start" \
    --instance-end "$instance_end" \
    --run-id-prefix "$RUN_ID_PREFIX" \
    --stage-root "$STAGE_ROOT" \
    --final-output-root "$FINAL_OUTPUT_ROOT" \
    --jvm-core-count "$BENCHMARK_JVM_CORE_COUNT" \
    --aux-core-count "$BENCHMARK_AUX_CORE_COUNT"
EOF
