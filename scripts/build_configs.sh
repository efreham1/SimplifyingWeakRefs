#!/usr/bin/env bash
set -euo pipefail

# build_configs.sh
# Builds configurations created by scripts/create_configs.sh.
# patches/base/src/ contains common ref-proc patches applied to all ref-proc variants except dyn_only.
# patches/<variant>/src/ contains variant-specific ref-proc files.
# patches/weak_fields/src/ contains the weak field annotation/processing patches (standalone).
#
# Usage: ./scripts/build_configs.sh --debug-level release|fastdebug [everything|variant|conf_name ...]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MAPPING_FILE="${SCRIPT_DIR}/variants.conf"
PATCHES_DIR="${REPO_ROOT}/patches"
MAKE_TARGET="exploded-image"
JOBS="$(nproc)"
DEBUG_LEVEL=""
DEBUG_LEVEL_SET=false

if [ ! -f "${MAPPING_FILE}" ]; then
  echo "Missing mapping file: ${MAPPING_FILE}" 1>&2
  echo "Run scripts/create_configs.sh first." 1>&2
  exit 1
fi

# Read mapping into arrays: conf_name|variant
declare -a confs
declare -a variants_arr
while IFS='|' read -r conf variant; do
  case "$conf" in
    \#*|"") continue ;;
  esac
  confs+=("$conf")
  variants_arr+=("$variant")
done < <(grep -vE '^\s*#' "${MAPPING_FILE}")

# Parse args
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
  echo "Missing required option: --debug-level release|fastdebug" 1>&2
  echo "Usage: ./scripts/build_configs.sh --debug-level release|fastdebug [everything|variant|conf_name ...]" 1>&2
  exit 1
fi

case "${DEBUG_LEVEL}" in
  release|fastdebug)
    ;;
  *)
    echo "Invalid --debug-level value: ${DEBUG_LEVEL}" 1>&2
    echo "Allowed values: release, fastdebug" 1>&2
    exit 1
    ;;
esac

build_list=()
declare -A seen

append_if_allowed() {
  local conf="$1"
  if [ "${DEBUG_LEVEL}" = "release" ] && [[ "${conf}" != *"-release" ]]; then
    return
  fi
  if [ "${DEBUG_LEVEL}" = "fastdebug" ] && [[ "${conf}" != *"-fastdebug" ]]; then
    return
  fi
  if [ -z "${seen[$conf]+x}" ]; then
    build_list+=("${conf}")
    seen["$conf"]=1
  fi
}

if [ ${#requested[@]} -gt 0 ]; then
  if [ "${requested[0]}" = "everything" ]; then
    for conf in "${confs[@]}"; do
      append_if_allowed "${conf}"
    done
  else
    for r in "${requested[@]}"; do
      matched=false

      # Exact config name match
      for i in "${!confs[@]}"; do
        if [ "${confs[$i]}" = "$r" ]; then
          append_if_allowed "${confs[$i]}"
          matched=true
        fi
      done

      # Variant-name match: <variant>-linux-x86_64-server-<level>
      if [ "$matched" = false ]; then
        for i in "${!confs[@]}"; do
          if [[ "${confs[$i]}" == "${r}-linux-x86_64-server-"* ]]; then
            append_if_allowed "${confs[$i]}"
            matched=true
          fi
        done
      fi

      if [ "$matched" = false ]; then
        echo "Warning: requested config '$r' not found in ${MAPPING_FILE}" 1>&2
      fi
    done
  fi
else
  for conf in "${confs[@]}"; do
    append_if_allowed "${conf}"
  done
fi

if [ ${#build_list[@]} -eq 0 ]; then
  echo "No configurations to build." 1>&2
  exit 1
fi

# Install variant source files by layering patches onto src/
# - "none" variant: no patches (builds unmodified upstream src/)
# - "weak_fields" variant: apply only patches/weak_fields/src/ (standalone)
# - ref-proc variants: apply patches/base/src/ (except for dyn_only), then patches/<variant>/src/
install_variant_files() {
  local variant="$1"
  local base_dir="${PATCHES_DIR}/base/src"
  local variant_dir="${PATCHES_DIR}/${variant}/src"

  if [ "${variant}" = "none" ]; then
    # Baseline: no patches, build unmodified upstream src/
    return 0
  fi

  if [ "${variant}" = "weak_fields" ]; then
    # Standalone: only weak_fields patches, no base
    if [ ! -d "${variant_dir}" ]; then
      echo "Error: weak_fields patch directory not found: ${variant_dir}" >&2
      return 1
    fi
    cp -r "${variant_dir}/." "${REPO_ROOT}/src/"
    return 0
  fi

  # Apply base patches for all ref-proc variants except dyn_only
  if [ "${variant}" != "dyn_only" ]; then
    if [ ! -d "${base_dir}" ]; then
      echo "Error: base patch directory not found: ${base_dir}" >&2
      return 1
    fi
    cp -r "${base_dir}/." "${REPO_ROOT}/src/"
  fi

  # Apply variant-specific patches on top
  if [ ! -d "${variant_dir}" ]; then
    echo "Error: variant patch directory not found: ${variant_dir}" >&2
    return 1
  fi
  cp -r "${variant_dir}/." "${REPO_ROOT}/src/"
}

# Save a pristine copy of src/ before any patches are applied
SRC_BACKUP="${REPO_ROOT}/.src_backup"
if [ -d "${SRC_BACKUP}" ]; then
  echo "Backup already exists at ${SRC_BACKUP}, reusing it."
else
  echo "Backing up src/ to ${SRC_BACKUP}"
  cp -a "${REPO_ROOT}/src/." "${SRC_BACKUP}/"
fi

# Restore src/ from the backup
restore_src() {
  rm -rf "${REPO_ROOT}/src"
  mkdir -p "${REPO_ROOT}/src"
  cp -a "${SRC_BACKUP}/." "${REPO_ROOT}/src/"
}

cleanup() {
  restore_src
  rm -rf "${SRC_BACKUP}"
}
trap cleanup EXIT

for conf in "${build_list[@]}"; do
  # Find variant for this conf
  idx=-1
  for i in "${!confs[@]}"; do
    if [ "${confs[$i]}" = "$conf" ]; then idx=$i; break; fi
  done
  if [ $idx -lt 0 ]; then
    echo "Skipping unknown conf: $conf" 1>&2
    continue
  fi
  variant="${variants_arr[$idx]}"

  echo
  echo "=== Building: ${conf} (variant: ${variant}) ==="

  echo "Installing variant files: ${variant}"
  install_variant_files "${variant}"

  echo "Running: make CONF=${conf} ${MAKE_TARGET} JOBS=${JOBS}"
  make CONF="${conf}" ${MAKE_TARGET} JOBS="${JOBS}"
  echo "Finished build: build/${conf}"

  # Restore src/ to clean original state before applying patches, then overlay this variant's files
  echo "Restoring src/ to original state before applying patches"
  restore_src
done

# Cleanup handled by trap

echo "All requested builds complete."
