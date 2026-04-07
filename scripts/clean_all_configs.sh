#!/usr/bin/env bash
set -euo pipefail

# clean_all_configs.sh
# Cleans the configured build directories used by the variant workflow and
# removes variant image snapshots plus cached HotSpot artefacts.
#
# Usage:
#   ./scripts/clean_all_configs.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/variant_common.sh"

clean_conf_build_output() {
  local conf="$1"
  local spec_file="${REPO_ROOT}/build/${conf}/spec.gmk"

  if [ ! -f "${spec_file}" ]; then
    return 0
  fi

  echo "=== Cleaning: ${conf} ==="
  make CONF="${conf}" clean
}

remove_obsolete_per_variant_build_dirs() {
  local level
  local variant
  local obsolete_dir

  for level in release fastdebug; do
    for variant in "${VARIANT_LIST[@]}"; do
      if [ "${variant}" = "weak_fields" ]; then
        continue
      fi

      obsolete_dir="${REPO_ROOT}/build/$(variant_image_name "${variant}" "${level}")"
      if [ ! -f "${obsolete_dir}/spec.gmk" ]; then
        continue
      fi

      echo "Removing obsolete build directory: ${obsolete_dir#${REPO_ROOT}/}"
      rm -rf "${obsolete_dir}"
    done
  done
}

cd "${REPO_ROOT}"

clean_conf_build_output "$(shared_conf_name "release")"
clean_conf_build_output "$(shared_conf_name "fastdebug")"
clean_conf_build_output "$(dedicated_conf_name "weak_fields" "release")"
clean_conf_build_output "$(dedicated_conf_name "weak_fields" "fastdebug")"

rm -rf "${VARIANT_IMAGES_ROOT}"
rm -rf "${VARIANT_STATE_ROOT}"
rm -rf "$(shared_work_state_dir "release")"
rm -rf "$(shared_work_state_dir "fastdebug")"

remove_obsolete_per_variant_build_dirs

echo "All variant build outputs cleaned."
