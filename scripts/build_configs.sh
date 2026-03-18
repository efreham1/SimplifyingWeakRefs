#!/usr/bin/env bash
set -euo pipefail

# build_configs.sh
# Builds configurations created by scripts/create_configs.sh
# Usage: ./scripts/build_configs.sh --debug-level release|fastdebug [everything|variant|conf_name ...]

MAPPING_FILE="$(dirname "$0")/variants.conf"
MAKE_TARGET="exploded-image"
JOBS="$(nproc)"
DEBUG_LEVEL=""
DEBUG_LEVEL_SET=false

if [ ! -f "${MAPPING_FILE}" ]; then
  echo "Missing mapping file: ${MAPPING_FILE}" 1>&2
  echo "Run scripts/create_configs.sh first." 1>&2
  exit 1
fi

# Read mapping into arrays
declare -a confs
declare -a flags_arr
while IFS='|' read -r conf flags; do
  # Skip comments and empty lines
  case "$conf" in
    \#*|"") continue ;;
  esac
  confs+=("$conf")
  flags_arr+=("$flags")
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
  echo "Usage: ./scripts/build_configs.sh --debug-level release|fastdebug [all|variant|conf_name ...]" 1>&2
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

for conf in "${build_list[@]}"; do
  # Find mapping index
  idx=-1
  for i in "${!confs[@]}"; do
    if [ "${confs[$i]}" = "$conf" ]; then idx=$i; break; fi
  done
  if [ $idx -lt 0 ]; then
    echo "Skipping unknown conf: $conf" 1>&2
    continue
  fi
  flags="${flags_arr[$idx]}"

  echo
  echo "=== Building: ${conf} ==="
  echo "Flags: ${flags}"

  echo "Running: make CONF=${conf} JVM_EXTRA_CFLAGS='${flags}' ${MAKE_TARGET} JOBS=${JOBS}"
  make CONF="${conf}" \
    JVM_EXTRA_CFLAGS="${flags}" \
    ${MAKE_TARGET} JOBS="${JOBS}"

  echo "Finished build: build/${conf}"
done

echo
echo "All requested builds complete."
