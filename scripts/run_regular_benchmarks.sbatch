#!/usr/bin/bash
#SBATCH --job-name=weakref-bench
#SBATCH --account=uppmax2026-1-109
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=12
#SBATCH --mem=192G
#SBATCH --hint=nomultithread
#SBATCH --time=30:00:00
#SBATCH --output=/dev/shm/weakref-bench-%j.out
#SBATCH --error=/dev/shm/weakref-bench-%j.err

set -euo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:${PATH}}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -n "${SLURM_SUBMIT_DIR:-}" ] && [ -f "${SLURM_SUBMIT_DIR}/scripts/run_benchmark_iterations.sh" ]; then
    REPO_ROOT="${SLURM_SUBMIT_DIR}"
else
    REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi
export REPO_ROOT

export BENCHMARK_JVM_CORE_COUNT="${BENCHMARK_JVM_CORE_COUNT:-10}"
export BENCHMARK_AUX_CORE_COUNT="${BENCHMARK_AUX_CORE_COUNT:-2}"
export BENCHMARK_SELECTION="${BENCHMARK_SELECTION:-both}"
export OUTER_ITERATIONS="${OUTER_ITERATIONS:-1}"
export WARMUP_ITERATIONS="${WARMUP_ITERATIONS:-1}"
export COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-10}"
export PARALLEL_INSTANCES="${PARALLEL_INSTANCES:-1}"
export BENCHMARK_HEAP_SIZE="${BENCHMARK_HEAP_SIZE:-120g}"
export BENCHMARK_MULTI_REFERENCE_COUNT="${BENCHMARK_MULTI_REFERENCE_COUNT:-100000000}"
export BENCHMARK_SINGLE_REFERENCE_COUNT="${BENCHMARK_SINGLE_REFERENCE_COUNT:-1000000000}"
export BENCHMARK_VARIANTS="${BENCHMARK_VARIANTS:-none,clear_path_only,sep_only,dyn_only,clear_path_sep,clear_path_dyn,sep_dyn,all}"
export RUN_ID_PREFIX="${RUN_ID_PREFIX:-slurm-${SLURM_JOB_ID}}"
export FINAL_OUTPUT_ROOT="${FINAL_OUTPUT_ROOT:-${REPO_ROOT}/output}"

copy_slurm_logs() {
    local slurm_output="/dev/shm/weakref-bench-${SLURM_JOB_ID}.out"
    local slurm_error="/dev/shm/weakref-bench-${SLURM_JOB_ID}.err"
    local slurm_dest="${FINAL_OUTPUT_ROOT}/slurm"

    mkdir -p "$slurm_dest"
    [ ! -f "$slurm_output" ] || cp -a "$slurm_output" "$slurm_dest/"
    [ ! -f "$slurm_error"  ] || cp -a "$slurm_error"  "$slurm_dest/"
}

trap 'exit_code=$?; copy_slurm_logs; exit "$exit_code"' EXIT

cd "$REPO_ROOT"

# --- Validate configuration ---
validate_positive_integer() {
    local value=$1 label=$2
    if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 1 ]; then
        printf '[benchmark] error: %s must be a positive integer\n' "$label" >&2
        exit 1
    fi
}

validate_positive_integer "$BENCHMARK_JVM_CORE_COUNT" BENCHMARK_JVM_CORE_COUNT
validate_positive_integer "$BENCHMARK_AUX_CORE_COUNT" BENCHMARK_AUX_CORE_COUNT
validate_positive_integer "$OUTER_ITERATIONS" OUTER_ITERATIONS
validate_positive_integer "$PARALLEL_INSTANCES" PARALLEL_INSTANCES

case "$BENCHMARK_SELECTION" in
    multi|single|both) ;;
    *)
        printf '[benchmark] error: BENCHMARK_SELECTION must be multi, single, or both\n' >&2
        exit 1
        ;;
esac

TOTAL_BENCHMARK_INSTANCES="$PARALLEL_INSTANCES"
[ "$TOTAL_BENCHMARK_INSTANCES" -le "$OUTER_ITERATIONS" ] || TOTAL_BENCHMARK_INSTANCES="$OUTER_ITERATIONS"
export TOTAL_BENCHMARK_INSTANCES

PER_INSTANCE_CORE_COUNT=$((BENCHMARK_JVM_CORE_COUNT + BENCHMARK_AUX_CORE_COUNT))
MAX_INSTANCES_PER_NODE=$((SLURM_CPUS_PER_TASK / PER_INSTANCE_CORE_COUNT))
MAX_TOTAL_INSTANCES=$((MAX_INSTANCES_PER_NODE * SLURM_JOB_NUM_NODES))

if [ "$MAX_INSTANCES_PER_NODE" -lt 1 ]; then
    printf '[benchmark] error: node has %s CPUs per task, insufficient for one instance requiring %s CPUs\n' \
        "$SLURM_CPUS_PER_TASK" "$PER_INSTANCE_CORE_COUNT" >&2
    exit 1
fi

if [ "$TOTAL_BENCHMARK_INSTANCES" -gt "$MAX_TOTAL_INSTANCES" ]; then
    printf '[benchmark] error: requested %s instances but %s nodes with %s CPUs support only %s instances at %s CPUs each\n' \
        "$TOTAL_BENCHMARK_INSTANCES" "$SLURM_JOB_NUM_NODES" "$SLURM_CPUS_PER_TASK" \
        "$MAX_TOTAL_INSTANCES" "$PER_INSTANCE_CORE_COUNT" >&2
    exit 1
fi

printf '[benchmark] Running %s instance(s) across %s node(s), %s CPUs per instance\n' \
    "$TOTAL_BENCHMARK_INSTANCES" "$SLURM_JOB_NUM_NODES" "$PER_INSTANCE_CORE_COUNT"

# Each node runs this script: copies variant images to its own /dev/shm, creates a
# stage dir, runs the benchmark, and copies results to the shared output root.
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
    instance_start=$((extra_instances * (base_instances + 1) + (node_rank - extra_instances) * base_instances + 1))
fi

if [ "$local_instance_count" -lt 1 ]; then
    printf '[benchmark] node %s/%s has no assigned instances; skipping\n' "$((node_rank + 1))" "$node_count"
    exit 0
fi

instance_end=$((instance_start + local_instance_count - 1))
printf '[benchmark] node %s/%s: instances %s-%s\n' \
    "$((node_rank + 1))" "$node_count" "$instance_start" "$instance_end"

# Copy all release variant images to this node's /dev/shm
VARIANT_RAM_DIR="/dev/shm/variant-images-${SLURM_JOB_ID}"
mkdir -p "$VARIANT_RAM_DIR"
for src_dir in "${REPO_ROOT}/build/variant-images/"*-linux-x86_64-server-release; do
    [ -d "$src_dir" ] || continue
    variant_name="$(basename "$src_dir")"
    if [ ! -d "${VARIANT_RAM_DIR}/${variant_name}" ]; then
        printf '[benchmark] Copying %s to RAM...\n' "$variant_name"
        cp -a "$src_dir" "${VARIANT_RAM_DIR}/"
    fi
done
printf '[benchmark] All variant images in RAM at %s\n' "$VARIANT_RAM_DIR"

# Create a stage directory in /dev/shm for benchmark output
STAGE_DIR=""
VARIANT_RAM_DIR_CREATED="$VARIANT_RAM_DIR"

cleanup_node() {
    if [ -n "${STAGE_DIR:-}" ] && [ -d "$STAGE_DIR" ]; then
        printf '[benchmark] Copying output from %s to %s\n' "$STAGE_DIR" "$FINAL_OUTPUT_ROOT"
        mkdir -p "$FINAL_OUTPUT_ROOT"
        cp -a "$STAGE_DIR/." "$FINAL_OUTPUT_ROOT/" 2>/dev/null || true
        rm -rf "$STAGE_DIR"
    fi
    rm -rf "${VARIANT_RAM_DIR_CREATED:-}"
}
trap cleanup_node EXIT

STAGE_DIR="$(mktemp -d "/dev/shm/weakref-bench-${SLURM_JOB_ID}-XXXXXX")"

/usr/bin/bash "${REPO_ROOT}/scripts/run_benchmark_iterations.sh" \
    --benchmark "$BENCHMARK_SELECTION" \
    --run-id-prefix "$RUN_ID_PREFIX" \
    --output-root "$STAGE_DIR" \
    --variant-image-root "$VARIANT_RAM_DIR" \
    --heap-size "$BENCHMARK_HEAP_SIZE" \
    --multi-reference-count "$BENCHMARK_MULTI_REFERENCE_COUNT" \
    --single-reference-count "$BENCHMARK_SINGLE_REFERENCE_COUNT" \
    --outer "$OUTER_ITERATIONS" \
    --warmup "$WARMUP_ITERATIONS" \
    --cooldown "$COOLDOWN_SECONDS" \
    --parallel-instances "$total_instances" \
    --instance-start "$instance_start" \
    --instance-end "$instance_end" \
    --jvm-core-count "$BENCHMARK_JVM_CORE_COUNT" \
    --aux-core-count "$BENCHMARK_AUX_CORE_COUNT"
EOF
