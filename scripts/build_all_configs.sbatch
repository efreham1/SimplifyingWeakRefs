#!/usr/bin/bash
#SBATCH --job-name=build-all-configs
#SBATCH --account=uppmax2026-1-109
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=48
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --time=8:00:00
#SBATCH --output=/dev/shm/build-all-configs-%j.out
#SBATCH --error=/dev/shm/build-all-configs-%j.err

set -euo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:${PATH}}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-}"

if [ -z "${REPO_ROOT}" ]; then
    if [ -n "${SLURM_SUBMIT_DIR:-}" ]; then
        REPO_ROOT="${SLURM_SUBMIT_DIR}"
    else
        REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
    fi
fi

FINAL_OUTPUT_ROOT="${FINAL_OUTPUT_ROOT:-${REPO_ROOT}/output}"
CONFIGS=(weak_fields)
BUILD_TYPES=(fastdebug release)

copy_slurm_logs() {
    local exit_code=$1
    local slurm_output="/dev/shm/build-all-configs-${SLURM_JOB_ID}.out"
    local slurm_error="/dev/shm/build-all-configs-${SLURM_JOB_ID}.err"
    local slurm_dest="${FINAL_OUTPUT_ROOT}/slurm"
    mkdir -p "$slurm_dest"
    [ ! -f "$slurm_output" ] || cp -a "$slurm_output" "$slurm_dest/"
    [ ! -f "$slurm_error" ] || cp -a "$slurm_error" "$slurm_dest/"
    return "$exit_code"
}
trap 'exit_code=$?; copy_slurm_logs "$exit_code"; exit "$exit_code"' EXIT

cd "$SNIC_TMP"

# Rsync source to $SNIC_TMP, excluding build and output
rsync -az --delete --exclude 'build/' --exclude 'output/' "$REPO_ROOT/" ./

for config in "${CONFIGS[@]}"; do
  for build_type in "${BUILD_TYPES[@]}"; do
    echo "Building config: $config, type: $build_type"
    bash scripts/build_configs.sh --debug-level "$build_type" "$config"
  done
done

# Rsync build outputs back
for config in "${CONFIGS[@]}"; do
  for build_type in "${BUILD_TYPES[@]}"; do
    REMOTE_BUILD_PATH="$SNIC_TMP/build/${config}-linux-x86_64-server-$build_type/"
    LOCAL_BUILD_PATH="$FINAL_OUTPUT_ROOT/build/${config}-linux-x86_64-server-$build_type/"
    mkdir -p "$LOCAL_BUILD_PATH"
    rsync -az "$REMOTE_BUILD_PATH" "$LOCAL_BUILD_PATH"
  done
done

echo "Build and copy complete."
