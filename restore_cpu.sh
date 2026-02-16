#!/usr/bin/env bash
# Restores all CPUs to their hardware min/max frequencies and sets the scaling governor.

set -euo pipefail
shopt -s nullglob

# Default governor can be overridden by first argument, e.g. "performance" or "powersave".
DEFAULT_GOVERNOR="powersave"
GOVERNOR="${1:-$DEFAULT_GOVERNOR}"
CPUROOT="/sys/devices/system/cpu"
POLICIES=("${CPUROOT}"/cpufreq/policy*)

if [[ ${#POLICIES[@]} -eq 0 ]]; then
  echo "No cpufreq policy directories found under ${CPUROOT}." >&2
  exit 1
fi

for policy in "${POLICIES[@]}"; do
  min_freq=$(cat "${policy}/cpuinfo_min_freq")
  max_freq=$(cat "${policy}/cpuinfo_max_freq")

  echo "Restoring $(basename "$policy") -> governor=${GOVERNOR}, min=${min_freq}, max=${max_freq}" >&2
  echo "${GOVERNOR}" | sudo tee "${policy}/scaling_governor" >/dev/null
  echo "${min_freq}" | sudo tee "${policy}/scaling_min_freq" >/dev/null
  echo "${max_freq}" | sudo tee "${policy}/scaling_max_freq" >/dev/null

  # Also update per-CPU sysfs entries for this policy's CPUs (helps on some platforms).
  for cpu in $(cat "${policy}/affected_cpus"); do
    cpu_path="${CPUROOT}/cpu${cpu}/cpufreq"
    if [[ -d "${cpu_path}" ]]; then
      echo "${GOVERNOR}" | sudo tee "${cpu_path}/scaling_governor" >/dev/null || true
      echo "${min_freq}" | sudo tee "${cpu_path}/scaling_min_freq" >/dev/null || true
      echo "${max_freq}" | sudo tee "${cpu_path}/scaling_max_freq" >/dev/null || true
    fi
  done

done

echo "CPU scaling restored." >&2