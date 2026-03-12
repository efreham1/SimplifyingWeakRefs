#!/usr/bin/env bash
set -euo pipefail

# build_configs.sh
# Builds configurations created by scripts/create_configs.sh
# Usage: ./scripts/build_configs.sh [all|conf_name ...]

MAPPING_FILE="$(dirname "$0")/variants.conf"
MAKE_TARGET="exploded-image"
JOBS="$(nproc)"

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

# If args given, build only those; otherwise build all from mapping file
requested=("${@}")

build_list=()
if [ ${#requested[@]} -gt 0 ]; then
  if [ "${requested[0]}" = "all" ]; then
    build_list=("${confs[@]}")
  else
    for r in "${requested[@]}"; do
      # Accept either conf_name or short variant name
      matched=false
      for i in "${!confs[@]}"; do
        if [ "${confs[$i]}" = "$r" ] || [[ "${confs[$i]}" == *"$r"* ]]; then
          build_list+=("${confs[$i]}")
          matched=true
          break
        fi
      done
      if [ "$matched" = false ]; then
        echo "Warning: requested config '$r' not found in ${MAPPING_FILE}" 1>&2
      fi
    done
  fi
else
  build_list=("${confs[@]}")
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
