#!/usr/bin/bash
#SBATCH --job-name=weakref-jmh
#SBATCH --account=uppmax2026-1-109
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=48
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --hint=nomultithread
#SBATCH --time=10:00:00
#SBATCH --output=/dev/shm/weakref-jmh-%j.out
#SBATCH --error=/dev/shm/weakref-jmh-%j.err

set -euo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:${PATH}}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -n "${SLURM_SUBMIT_DIR:-}" ] && [ -f "${SLURM_SUBMIT_DIR}/scripts/run_weakvaluehashmap_jmh.sh" ]; then
    REPO_ROOT="${SLURM_SUBMIT_DIR}"
else
    REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi
export REPO_ROOT

FINAL_OUTPUT_ROOT="${FINAL_OUTPUT_ROOT:-${REPO_ROOT}/output}"
RUN_ID="${RUN_ID:-jmh-${SLURM_JOB_ID}}"

copy_slurm_logs() {
    local slurm_output="/dev/shm/weakref-jmh-${SLURM_JOB_ID}.out"
    local slurm_error="/dev/shm/weakref-jmh-${SLURM_JOB_ID}.err"
    local slurm_dest="${FINAL_OUTPUT_ROOT}/slurm"

    mkdir -p "$slurm_dest"
    [ ! -f "$slurm_output" ] || cp -a "$slurm_output" "$slurm_dest/"
    [ ! -f "$slurm_error"  ] || cp -a "$slurm_error"  "$slurm_dest/"
}

trap 'exit_code=$?; copy_slurm_logs; exit "$exit_code"' EXIT

cd "$REPO_ROOT"

# Copy the JMH variant images (none, all, weak_fields) to this node's /dev/shm
VARIANT_RAM_DIR="/dev/shm/variant-images-${SLURM_JOB_ID}"
mkdir -p "$VARIANT_RAM_DIR"

for variant in none all weak_fields; do
    src_dir="${REPO_ROOT}/build/variant-images/${variant}-linux-x86_64-server-release"
    if [ -d "$src_dir" ]; then
        printf '[jmh] Copying %s to RAM...\n' "$variant"
        cp -a "$src_dir" "${VARIANT_RAM_DIR}/"
    else
        printf '[jmh] Warning: variant image not found: %s\n' "$src_dir" >&2
    fi
done
printf '[jmh] Variant images ready at %s\n' "$VARIANT_RAM_DIR"

# Create a stage directory in /dev/shm for benchmark output
STAGE_DIR=""
VARIANT_RAM_DIR_CREATED="$VARIANT_RAM_DIR"

cleanup() {
    if [ -n "${STAGE_DIR:-}" ] && [ -d "$STAGE_DIR" ]; then
        printf '[jmh] Copying output from %s to %s\n' "$STAGE_DIR" "$FINAL_OUTPUT_ROOT"
        mkdir -p "$FINAL_OUTPUT_ROOT"
        cp -a "$STAGE_DIR/." "$FINAL_OUTPUT_ROOT/" 2>/dev/null || true
        rm -rf "$STAGE_DIR"
    fi
    rm -rf "${VARIANT_RAM_DIR_CREATED:-}"
}
trap cleanup EXIT

STAGE_DIR="$(mktemp -d "/dev/shm/weakref-jmh-${SLURM_JOB_ID}-XXXXXX")"

/usr/bin/bash "${REPO_ROOT}/scripts/run_weakvaluehashmap_jmh.sh" \
    --no-build \
    --variant-image-root "$VARIANT_RAM_DIR" \
    --result-root "${STAGE_DIR}/id_${RUN_ID}"
