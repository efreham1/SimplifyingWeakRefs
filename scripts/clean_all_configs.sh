#!/usr/bin/env bash
set -euo pipefail

# clean_all_configs.sh
# Runs `make clean` for all known build configurations.
#
# Priority order for config discovery:
# 1) scripts/variants.conf (same source used by create/build scripts)
# 2) Any existing build config with build/<conf>/spec.gmk
#
# Usage:
#   ./scripts/clean_all_configs.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MAPPING_FILE="${SCRIPT_DIR}/variants.conf"

cd "${REPO_ROOT}"

declare -a confs=()

if [[ -f "${MAPPING_FILE}" ]]; then
  while IFS='|' read -r conf _flags; do
    case "${conf}" in
      \#*|"") continue ;;
    esac
    confs+=("${conf}")
  done < <(grep -vE '^\s*#|^\s*$' "${MAPPING_FILE}")
fi

if [[ ${#confs[@]} -eq 0 ]]; then
  while IFS= read -r spec; do
    confs+=("$(basename "$(dirname "${spec}")")")
  done < <(find build -mindepth 2 -maxdepth 2 -type f -name spec.gmk 2>/dev/null | sort)
fi

if [[ ${#confs[@]} -eq 0 ]]; then
  echo "No configurations found to clean."
  exit 1
fi

echo "Cleaning ${#confs[@]} configuration(s)..."
for conf in "${confs[@]}"; do
  echo "=== Cleaning: ${conf} ==="
  make CONF="${conf}" clean
  echo "Done: ${conf}"
done

echo "All configurations cleaned."
