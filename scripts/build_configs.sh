#!/usr/bin/env bash
set -euo pipefail

# build_configs.sh
# Builds the configured variants prepared by scripts/create_configs.sh.
#
# Ref-proc variants share one configured build per debug level. Each variant
# keeps its own HotSpot artefact cache under build/variant-build-state/ and a
# runnable JDK image snapshot under build/variant-images/.
#
# The weak_fields variant keeps a dedicated configured build because it patches
# files outside HotSpot.
#
# Usage: ./scripts/build_configs.sh --debug-level release|fastdebug [everything|variant|image_name ...]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/variant_common.sh"

MAPPING_FILE="${SCRIPT_DIR}/variants.conf"
LOCK_FILE="${REPO_ROOT}/build/.build_configs.lock"
MAKE_TARGET="exploded-image"
JOBS="${JOBS:-$(nproc)}"
BUILD_RETRY_COUNT="${BUILD_RETRY_COUNT:-2}"
BUILD_RETRY_SLEEP_SECONDS="${BUILD_RETRY_SLEEP_SECONDS:-5}"
DEBUG_LEVEL=""
DEBUG_LEVEL_SET=false
SRC_BACKUP=""
ACTIVE_SHARED_LEVEL=""
SHARED_SOURCE_REFRESH_REQUIRED=false
DEDICATED_SOURCE_REFRESH_REQUIRED=false
SHARED_REUSED_EXACT_CACHE=false
NONE_SIGNATURE=""
KEEP_SHARED_VARIANT_CACHES="${KEEP_SHARED_VARIANT_CACHES:-0}"

mkdir -p "${REPO_ROOT}/build"
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  echo "Another build_configs.sh run is already active." >&2
  exit 1
fi

ensure_patch_layout

requested=()
while [ $# -gt 0 ]; do
  case "$1" in
    --debug-level)
      DEBUG_LEVEL="${2:-}"
      DEBUG_LEVEL_SET=true
      shift 2
      ;;
    everything)
      requested=("everything")
      shift
      ;;
    *)
      requested+=("$1")
      shift
      ;;
  esac
done

if [ "${DEBUG_LEVEL_SET}" = false ]; then
  echo "Missing required option: --debug-level release|fastdebug" >&2
  echo "Usage: ./scripts/build_configs.sh --debug-level release|fastdebug [everything|variant|image_name ...]" >&2
  exit 1
fi

case "${DEBUG_LEVEL}" in
  release|fastdebug)
    ;;
  *)
    echo "Invalid --debug-level value: ${DEBUG_LEVEL}" >&2
    echo "Allowed values: release, fastdebug" >&2
    exit 1
    ;;
esac

refresh_configured_builds() {
  echo "Preparing configured build directories"
  bash "${SCRIPT_DIR}/create_configs.sh"
}

if [ ! -f "${MAPPING_FILE}" ]; then
  refresh_configured_builds
fi

if [ ! -f "${MAPPING_FILE}" ]; then
  echo "Missing mapping file: ${MAPPING_FILE}" >&2
  exit 1
fi

declare -a actual_confs
declare -a variants_arr
declare -a image_names_arr
declare -a modes_arr

while IFS='|' read -r level conf variant image_name mode; do
  case "${level}" in
    \#*|"") continue ;;
  esac

  if [ "${level}" != "${DEBUG_LEVEL}" ]; then
    continue
  fi

  actual_confs+=("${conf}")
  variants_arr+=("${variant}")
  image_names_arr+=("${image_name}")
  modes_arr+=("${mode}")
done < <(grep -vE '^\s*#' "${MAPPING_FILE}")

if [ "${#variants_arr[@]}" -eq 0 ]; then
  echo "No variants configured for debug level ${DEBUG_LEVEL}." >&2
  exit 1
fi

build_indices=()
declare -A seen_images=()

append_build_index() {
  local index="$1"
  local image_name="${image_names_arr[$index]}"

  if [ -z "${seen_images[$image_name]+x}" ]; then
    build_indices+=("${index}")
    seen_images["${image_name}"]=1
  fi
}

conf_failure_log_dir() {
  local conf="$1"

  printf '%s/build/%s/make-support/failure-logs\n' "${REPO_ROOT}" "${conf}"
}

clear_conf_failure_logs() {
  local conf="$1"
  local failure_dir

  failure_dir="$(conf_failure_log_dir "${conf}")"
  rm -rf "${failure_dir}"
}

build_has_retryable_resource_failure() {
  local conf="$1"
  local failure_dir

  failure_dir="$(conf_failure_log_dir "${conf}")"
  if [ ! -d "${failure_dir}" ]; then
    return 1
  fi

  find "${failure_dir}" -type f -name '*.log' -print0 | xargs -0 -r grep -Fq 'Resource temporarily unavailable'
}

run_make_target() {
  local conf="$1"
  local attempt=1
  local max_attempts=$((BUILD_RETRY_COUNT + 1))
  local attempt_jobs="$JOBS"
  local make_status=0
  local retryable=false
  local next_jobs=0

  while true; do
    clear_conf_failure_logs "${conf}"

    if [ "${attempt}" -eq 1 ]; then
      echo "Running: make CONF=${conf} ${MAKE_TARGET} JOBS=${attempt_jobs}"
    else
      echo "Running: make CONF=${conf} ${MAKE_TARGET} JOBS=${attempt_jobs} (attempt ${attempt}/${max_attempts})"
    fi

    set +e
    make CONF="${conf}" "${MAKE_TARGET}" JOBS="${attempt_jobs}"
    make_status=$?
    set -e

    if [ "${make_status}" -eq 0 ]; then
      if [ "${attempt_jobs}" -ne "${JOBS}" ]; then
        echo "Build succeeded after retry; continuing with JOBS=${attempt_jobs}"
        JOBS="${attempt_jobs}"
      fi
      return 0
    fi

    retryable=false
    if build_has_retryable_resource_failure "${conf}"; then
      retryable=true
    fi

    if [ "${retryable}" = false ] || [ "${attempt}" -ge "${max_attempts}" ]; then
      return "${make_status}"
    fi

    next_jobs=$((attempt_jobs / 2))
    if [ "${next_jobs}" -lt 1 ]; then
      next_jobs=1
    fi
    if [ "${next_jobs}" -ge "${attempt_jobs}" ] && [ "${attempt_jobs}" -gt 1 ]; then
      next_jobs=$((attempt_jobs - 1))
    fi

    echo "Retrying ${conf} after transient resource failure; sleeping ${BUILD_RETRY_SLEEP_SECONDS}s and reducing JOBS from ${attempt_jobs} to ${next_jobs}"
    sleep "${BUILD_RETRY_SLEEP_SECONDS}"

    attempt=$((attempt + 1))
    attempt_jobs="${next_jobs}"
  done
}

if [ "${#requested[@]}" -eq 0 ] || [ "${requested[0]:-}" = "everything" ]; then
  for i in "${!variants_arr[@]}"; do
    append_build_index "${i}"
  done
else
  for request in "${requested[@]}"; do
    matched=false

    for i in "${!variants_arr[@]}"; do
      if [ "${variants_arr[$i]}" = "${request}" ] || [ "${image_names_arr[$i]}" = "${request}" ]; then
        append_build_index "${i}"
        matched=true
      fi
    done

    if [ "${matched}" = false ]; then
      echo "Warning: requested build '${request}' not found in ${MAPPING_FILE}" >&2
    fi
  done
fi

if [ "${#build_indices[@]}" -eq 0 ]; then
  echo "No configurations to build." >&2
  exit 1
fi

clean_conf_build_output() {
  local conf="$1"
  local spec_file="${REPO_ROOT}/build/${conf}/spec.gmk"

  if [ ! -f "${spec_file}" ]; then
    return 0
  fi

  echo "=== Cleaning: ${conf} ==="
  make CONF="${conf}" clean
}

clean_other_debug_level_builds() {
  local other_level
  local cleaned_any=false
  local other_shared_conf
  local other_weak_fields_conf

  case "${DEBUG_LEVEL}" in
    release)
      other_level="fastdebug"
      ;;
    fastdebug)
      other_level="release"
      ;;
  esac

  other_shared_conf="$(shared_conf_name "${other_level}")"
  other_weak_fields_conf="$(dedicated_conf_name "weak_fields" "${other_level}")"

  for conf in "${other_shared_conf}" "${other_weak_fields_conf}"; do
    if [ ! -f "${REPO_ROOT}/build/${conf}/spec.gmk" ]; then
      continue
    fi

    if [ "${cleaned_any}" = false ]; then
      echo "Cleaning ${other_level} configurations before building ${DEBUG_LEVEL} to avoid filling the disk"
      cleaned_any=true
    fi

    clean_conf_build_output "${conf}"
  done

  rm -rf "${VARIANT_STATE_ROOT}/${other_level}"
  find "${VARIANT_IMAGES_ROOT}" -mindepth 1 -maxdepth 1 -type d -name "*-linux-x86_64-server-${other_level}" -exec rm -rf {} + 2>/dev/null || true
}

remove_obsolete_per_variant_build_dirs() {
  local level
  local variant
  local obsolete_dir
  local removed_any=false

  for level in release fastdebug; do
    for variant in "${VARIANT_LIST[@]}"; do
      if [ "${variant}" = "weak_fields" ]; then
        continue
      fi

      obsolete_dir="${REPO_ROOT}/build/$(variant_image_name "${variant}" "${level}")"
      if [ ! -f "${obsolete_dir}/spec.gmk" ]; then
        continue
      fi

      if [ "${removed_any}" = false ]; then
        echo "Removing obsolete per-variant build directories from the previous layout"
        removed_any=true
      fi

      echo "  ${obsolete_dir#${REPO_ROOT}/}"
      rm -rf "${obsolete_dir}"
    done
  done
}

prune_shared_variant_caches() {
  local level_dir="${VARIANT_STATE_ROOT}/${DEBUG_LEVEL}"
  local variant
  local variant_cache_dir_path
  local pruned_any=false

  if [ "${KEEP_SHARED_VARIANT_CACHES}" = "1" ] || [ ! -d "${level_dir}" ]; then
    return 0
  fi

  for variant in "${VARIANT_LIST[@]}"; do
    if [ "${variant}" = "none" ] || [ "${variant}" = "weak_fields" ]; then
      continue
    fi

    variant_cache_dir_path="$(variant_cache_dir "${variant}" "${DEBUG_LEVEL}")"
    if [ ! -d "${variant_cache_dir_path}" ]; then
      continue
    fi

    if [ "${pruned_any}" = false ]; then
      echo "Pruning shared HotSpot caches for ${DEBUG_LEVEL}; keeping only the none seed cache"
      pruned_any=true
    fi

    echo "  ${variant_cache_dir_path#${REPO_ROOT}/}"
    rm -rf "${variant_cache_dir_path}"
  done
}

ensure_configured_confs_exist() {
  local conf
  local missing_conf=false
  local refresh_attempted=false
  declare -A seen_confs=()

  while true; do
    missing_conf=false

    for conf in "${actual_confs[@]}"; do
      if [ -n "${seen_confs[$conf]+x}" ]; then
        continue
      fi

      if [ ! -f "${REPO_ROOT}/build/${conf}/spec.gmk" ]; then
        echo "Missing configured build directory: build/${conf}" >&2
        missing_conf=true
        break
      fi

      seen_confs["${conf}"]=1
    done

    if [ "${missing_conf}" = false ]; then
      return 0
    fi

    if [ "${refresh_attempted}" = true ]; then
      echo "Failed to prepare the configured build directories." >&2
      exit 1
    fi

    refresh_configured_builds
    refresh_attempted=true
    seen_confs=()
  done
}

cleanup() {
  local exit_status=$?
  local restore_status=0

  if [ -n "${ACTIVE_SHARED_LEVEL}" ]; then
    rm -rf "$(shared_hotspot_dir "${ACTIVE_SHARED_LEVEL}")"
  fi

  if [ -n "${SRC_BACKUP}" ] && [ -d "${SRC_BACKUP}" ]; then
    restore_src_from_backup "${SRC_BACKUP}" || restore_status=$?
    if [ "${restore_status}" -eq 0 ]; then
      rm -rf "${SRC_BACKUP}"
    else
      echo "Warning: failed to restore src/ from ${SRC_BACKUP}; backup left in place." >&2
    fi
  fi

  trap - EXIT
  exit "${exit_status}"
}
trap cleanup EXIT

recover_shared_hotspot() {
  local level="$1"
  local shared_hotspot
  local work_state_dir
  local reason=""

  shared_hotspot="$(shared_hotspot_dir "${level}")"
  work_state_dir="$(shared_work_state_dir "${level}")"

  if [ -f "${work_state_dir}/in_progress" ]; then
    reason="previous attempt did not complete cleanly"
  elif [ -d "${shared_hotspot}" ] || [ -d "${work_state_dir}" ]; then
    reason="stale shared HotSpot workspace detected"
  fi

  if [ -n "${reason}" ]; then
    echo "Resetting shared HotSpot workspace for ${level}: ${reason}"
    rm -rf "${shared_hotspot}" "${work_state_dir}"
  fi
}

prepare_shared_variant_workspace() {
  local variant="$1"
  local signature="$2"
  local shared_hotspot
  local cache_hotspot
  local cache_signature_file
  local cached_signature=""
  local none_cache_hotspot
  local none_signature_file
  local none_cached_signature=""

  SHARED_SOURCE_REFRESH_REQUIRED=false
  SHARED_REUSED_EXACT_CACHE=false
  recover_shared_hotspot "${DEBUG_LEVEL}"

  shared_hotspot="$(shared_hotspot_dir "${DEBUG_LEVEL}")"
  cache_hotspot="$(variant_cache_hotspot_dir "${variant}" "${DEBUG_LEVEL}")"
  cache_signature_file="$(variant_cache_signature_file "${variant}" "${DEBUG_LEVEL}")"

  if [ -f "${cache_signature_file}" ] && [ -d "${cache_hotspot}" ]; then
    cached_signature="$(cat "${cache_signature_file}")"
  fi

  if [ "${cached_signature}" = "${signature}" ]; then
    echo "Reusing exact HotSpot cache for ${variant}"
    mkdir -p "$(dirname "${shared_hotspot}")"
    mv "${cache_hotspot}" "${shared_hotspot}"
    SHARED_REUSED_EXACT_CACHE=true
    return 0
  fi

  rm -rf "${cache_hotspot}"
  rm -f "${cache_signature_file}"

  if [ "${variant}" != "none" ]; then
    none_cache_hotspot="$(variant_cache_hotspot_dir "none" "${DEBUG_LEVEL}")"
    none_signature_file="$(variant_cache_signature_file "none" "${DEBUG_LEVEL}")"

    if [ -f "${none_signature_file}" ] && [ -d "${none_cache_hotspot}" ]; then
      none_cached_signature="$(cat "${none_signature_file}")"
    fi

    if [ "${none_cached_signature}" = "${NONE_SIGNATURE}" ]; then
      echo "Seeding ${variant} HotSpot cache from none"
      copy_tree_contents "${none_cache_hotspot}" "${shared_hotspot}"
    else
      echo "No exact HotSpot cache for ${variant}; compiling in the shared workspace"
      rm -rf "${shared_hotspot}"
    fi

    SHARED_SOURCE_REFRESH_REQUIRED=true
  else
    echo "No exact HotSpot cache for ${variant}; compiling in the shared workspace"
    rm -rf "${shared_hotspot}"
  fi
}

begin_shared_variant_build() {
  local variant="$1"
  local signature="$2"
  local work_state_dir

  work_state_dir="$(shared_work_state_dir "${DEBUG_LEVEL}")"
  mkdir -p "${work_state_dir}"
  printf '%s\n' "${variant}" > "${work_state_dir}/variant"
  printf '%s\n' "${signature}" > "${work_state_dir}/signature"
  : > "${work_state_dir}/in_progress"
}

store_shared_variant_cache() {
  local variant="$1"
  local signature="$2"
  local shared_hotspot
  local cache_dir
  local cache_hotspot
  local cache_signature_file
  local work_state_dir

  shared_hotspot="$(shared_hotspot_dir "${DEBUG_LEVEL}")"
  cache_dir="$(variant_cache_dir "${variant}" "${DEBUG_LEVEL}")"
  cache_hotspot="$(variant_cache_hotspot_dir "${variant}" "${DEBUG_LEVEL}")"
  cache_signature_file="$(variant_cache_signature_file "${variant}" "${DEBUG_LEVEL}")"
  work_state_dir="$(shared_work_state_dir "${DEBUG_LEVEL}")"

  if [ "${variant}" = "none" ] || [ "${KEEP_SHARED_VARIANT_CACHES}" = "1" ]; then
    rm -rf "${cache_hotspot}"
    mkdir -p "$(dirname "${cache_hotspot}")"
    mv "${shared_hotspot}" "${cache_hotspot}"
    printf '%s\n' "${signature}" > "${cache_signature_file}"
  else
    rm -rf "${shared_hotspot}" "${cache_hotspot}"
    rm -f "${cache_signature_file}"
  fi

  rm -rf "${work_state_dir}"
}

prepare_dedicated_variant_build() {
  local conf="$1"
  local signature="$2"
  local state_dir="${REPO_ROOT}/build/${conf}/.variant_overlay_state"
  local signature_file="${state_dir}/signature"
  local in_progress_file="${state_dir}/in_progress"
  local previous_signature=""

  DEDICATED_SOURCE_REFRESH_REQUIRED=false
  mkdir -p "${state_dir}"

  if [ -f "${in_progress_file}" ]; then
    echo "Cleaning ${conf}: previous attempt did not complete cleanly"
    make CONF="${conf}" clean
  fi

  if [ -f "${signature_file}" ]; then
    previous_signature="$(cat "${signature_file}")"
  fi

  if [ "${previous_signature}" != "${signature}" ]; then
    DEDICATED_SOURCE_REFRESH_REQUIRED=true
  fi

  : > "${in_progress_file}"
}

mark_dedicated_variant_success() {
  local conf="$1"
  local signature="$2"
  local state_dir="${REPO_ROOT}/build/${conf}/.variant_overlay_state"

  printf '%s\n' "${signature}" > "${state_dir}/signature"
  rm -f "${state_dir}/in_progress"
}

build_shared_variant() {
  local conf="$1"
  local variant="$2"
  local image_name="$3"
  local signature="$4"

  prepare_shared_variant_workspace "${variant}" "${signature}"
  begin_shared_variant_build "${variant}" "${signature}"
  ACTIVE_SHARED_LEVEL="${DEBUG_LEVEL}"

  if [ "${SHARED_SOURCE_REFRESH_REQUIRED}" = true ]; then
    echo "Refreshing patched source timestamps for ${variant}"
    touch_variant_sources "${variant}"
  fi

  run_make_target "${conf}"

  if [ "${SHARED_REUSED_EXACT_CACHE}" = true ] && [ -d "$(variant_image_dir_by_name "${image_name}")" ]; then
    echo "Reusing existing image snapshot for ${variant}"
  else
    snapshot_variant_image "${image_name}" "${REPO_ROOT}/build/${conf}" "${variant}" "shared-hotspot"
  fi
  store_shared_variant_cache "${variant}" "${signature}"
  ACTIVE_SHARED_LEVEL=""

  echo "Finished build: build/variant-images/${image_name}"
}

build_dedicated_variant() {
  local conf="$1"
  local variant="$2"
  local image_name="$3"
  local signature="$4"

  prepare_dedicated_variant_build "${conf}" "${signature}"

  if [ "${DEDICATED_SOURCE_REFRESH_REQUIRED}" = true ]; then
    echo "Refreshing patched source timestamps for ${variant}"
    touch_variant_sources "${variant}"
  fi

  run_make_target "${conf}"

  mark_dedicated_variant_success "${conf}" "${signature}"
  snapshot_variant_image "${image_name}" "${REPO_ROOT}/build/${conf}" "${variant}" "dedicated"

  echo "Finished build: build/variant-images/${image_name}"
}

cd "${REPO_ROOT}"
clean_other_debug_level_builds
remove_obsolete_per_variant_build_dirs
ensure_configured_confs_exist
recover_shared_hotspot "${DEBUG_LEVEL}"
prune_shared_variant_caches

SRC_BACKUP="$(mktemp -d "${REPO_ROOT}/.src_backup.XXXXXX")"
requested_backup_variants=()
for index in "${build_indices[@]}"; do
  variant="${variants_arr[$index]}"
  requested_backup_variants+=("${variant}")
done

backup_variant_sources "${SRC_BACKUP}" "${requested_backup_variants[@]}" >/dev/null
echo "Backing up $(count_src_backup_paths "${SRC_BACKUP}") affected src file(s) to ${SRC_BACKUP}"

NONE_SIGNATURE="$(compute_variant_signature "none")"

for index in "${build_indices[@]}"; do
  conf="${actual_confs[$index]}"
  variant="${variants_arr[$index]}"
  image_name="${image_names_arr[$index]}"
  mode="${modes_arr[$index]}"
  variant_signature="$(compute_variant_signature "${variant}")"

  echo
  echo "=== Building: ${image_name} (variant: ${variant}, mode: ${mode}) ==="

  restore_src_from_backup "${SRC_BACKUP}"
  echo "Installing variant files: ${variant}"
  install_variant_files "${variant}"

  case "${mode}" in
    shared-hotspot)
      build_shared_variant "${conf}" "${variant}" "${image_name}" "${variant_signature}"
      ;;
    dedicated)
      build_dedicated_variant "${conf}" "${variant}" "${image_name}" "${variant_signature}"
      ;;
    *)
      echo "Error: unknown build mode '${mode}' for variant '${variant}'" >&2
      exit 1
      ;;
  esac
done

echo "All requested builds complete."
