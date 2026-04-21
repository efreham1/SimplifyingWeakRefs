#!/usr/bin/bash
#SBATCH --job-name=weakref-jmh
#SBATCH --account=uppmax2026-1-109
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=64G
#SBATCH --hint=nomultithread
#SBATCH --time=4:00:00
#SBATCH --output=/dev/shm/weakref-jmh-%j.out
#SBATCH --error=/dev/shm/weakref-jmh-%j.err

set -euo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:${PATH}}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-}"

if [ -z "${REPO_ROOT}" ]; then
    if [ -n "${SLURM_SUBMIT_DIR:-}" ] && [ -f "${SLURM_SUBMIT_DIR}/scripts/run_weakvaluehashmap_jmh.sh" ]; then
        REPO_ROOT="${SLURM_SUBMIT_DIR}"
    else
        REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
    fi
fi

export RUN_ID_PREFIX="${RUN_ID_PREFIX:-slurm-${SLURM_JOB_ID}}"
export FINAL_OUTPUT_ROOT="${FINAL_OUTPUT_ROOT:-${REPO_ROOT}/output}"
export WEAKVALUEHASHMAP_JMH_ARGS="${WEAKVALUEHASHMAP_JMH_ARGS:---live-set 67108864 --time 60 --fork-heap 48g}"
export REPO_ROOT

copy_slurm_logs() {
    local exit_code=$1
    local slurm_output="/dev/shm/weakref-jmh-${SLURM_JOB_ID}.out"
    local slurm_error="/dev/shm/weakref-jmh-${SLURM_JOB_ID}.err"
    local slurm_dest="${FINAL_OUTPUT_ROOT}/slurm"

    mkdir -p "$slurm_dest"

    [ ! -f "$slurm_output" ] || cp -a "$slurm_output" "$slurm_dest/"
    [ ! -f "$slurm_error" ] || cp -a "$slurm_error" "$slurm_dest/"

    return "$exit_code"
}

trap 'exit_code=$?; copy_slurm_logs "$exit_code"; exit "$exit_code"' EXIT

cd "$REPO_ROOT"

WEAKVALUEHASHMAP_JMH_RESULT_ROOT="${FINAL_OUTPUT_ROOT}/id_${RUN_ID_PREFIX}-weakvaluehashmap-jmh"
weakvaluehashmap_jmh_extra_args=()

if [ -n "$WEAKVALUEHASHMAP_JMH_ARGS" ]; then
    read -r -a weakvaluehashmap_jmh_extra_args <<< "$WEAKVALUEHASHMAP_JMH_ARGS"
fi

printf '[benchmark] running weakvaluehashmap JMH into %s\n' "$WEAKVALUEHASHMAP_JMH_RESULT_ROOT"
/usr/bin/bash "${REPO_ROOT}/scripts/run_weakvaluehashmap_jmh.sh" \
    --no-build \
    --result-root "$WEAKVALUEHASHMAP_JMH_RESULT_ROOT" \
    "${weakvaluehashmap_jmh_extra_args[@]}"

if [ -f "${FINAL_OUTPUT_ROOT}/run-metadata.txt" ]; then
    {
        printf 'weakvaluehashmap_jmh_result_root=%s\n' "$WEAKVALUEHASHMAP_JMH_RESULT_ROOT"
        printf 'weakvaluehashmap_jmh_mode=sequential_once\n'
    } >> "${FINAL_OUTPUT_ROOT}/run-metadata.txt"
fi
