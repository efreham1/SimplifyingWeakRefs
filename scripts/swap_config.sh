#!/usr/bin/env bash
set -euo pipefail

# swap_config.sh
# Copies variant patch files into src/ or restores src/ to its original state.
# Works the same way as build_configs.sh but without building.
#
# Usage:
#   ./scripts/swap_config.sh copy <variant>     # Apply variant patches to src/
#   ./scripts/swap_config.sh restore             # Restore src/ from backup
#
# The backup path is recorded under build/.swap_config_state/backup_path.
# A temporary backup directory under .src_backup.* stores only the affected
# src files plus a manifest; it is created on the first "copy" and removed by
# "restore".

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/variant_common.sh"
LOCK_FILE="${REPO_ROOT}/build/.build_configs.lock"
SWAP_STATE_DIR="${REPO_ROOT}/build/.swap_config_state"
BACKUP_PATH_FILE="${SWAP_STATE_DIR}/backup_path"

mkdir -p "${REPO_ROOT}/build" "${SWAP_STATE_DIR}"
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  echo "Another src overlay operation is already active." >&2
  exit 1
fi

usage() {
  echo "Usage:"
  echo "  $0 copy <variant>   Apply variant patches to src/"
  echo "  $0 restore          Restore src/ from backup"
  echo "  $0 save <patch>     Copy files from src/ back into patches/<patch>/"
  echo ""
  echo "Available variants/patches:"
  for d in "${PATCHES_DIR}"/*/; do
    v="$(basename "$d")"
    [ "$v" = "base" ] && continue
    echo "  $v"
  done
  exit 1
}

current_backup_dir() {
  if [ ! -f "${BACKUP_PATH_FILE}" ]; then
    return 0
  fi

  cat "${BACKUP_PATH_FILE}"
}

backup_variant_src() {
  local variant="$1"
  local backup_dir=""
  local manifest_file=""
  local added_count="0"
  local total_count="0"

  backup_dir="$(current_backup_dir)"
  if [ -n "${backup_dir}" ]; then
    if [ -d "${backup_dir}" ]; then
      manifest_file="$(src_backup_manifest_file "${backup_dir}")"
      if [ ! -f "${manifest_file}" ]; then
        echo "Legacy full src backup already exists at ${backup_dir}, keeping it."
        return 0
      fi
    else
      rm -f "${BACKUP_PATH_FILE}"
      backup_dir=""
    fi
  fi

  if [ -z "${backup_dir}" ]; then
    backup_dir="$(mktemp -d "${REPO_ROOT}/.src_backup.XXXXXX")"
    printf '%s\n' "${backup_dir}" > "${BACKUP_PATH_FILE}"
  fi

  added_count="$(backup_variant_sources "${backup_dir}" "${variant}")"
  total_count="$(count_src_backup_paths "${backup_dir}")"

  if [ "${added_count}" -gt 0 ]; then
    echo "Backed up ${added_count} additional affected src file(s) to ${backup_dir} (${total_count} total tracked)."
  else
    echo "Backup already covers all affected src files at ${backup_dir}."
  fi
}

restore_src() {
  local backup_dir=""
  local manifest_file=""

  backup_dir="$(current_backup_dir)"
  if [ -z "${backup_dir}" ] || [ ! -d "${backup_dir}" ]; then
    echo "Error: No backup found. Nothing to restore." >&2
    exit 1
  fi

  manifest_file="$(src_backup_manifest_file "${backup_dir}")"
  if [ -f "${manifest_file}" ]; then
    echo "Restoring affected src files from ${backup_dir}"
    restore_src_from_backup "${backup_dir}"
  else
    echo "Restoring src/ from legacy backup ${backup_dir}"
    rm -rf "${REPO_ROOT}/src"
    mkdir -p "${REPO_ROOT}/src"
    copy_tree_contents "${backup_dir}" "${REPO_ROOT}/src"
  fi

  rm -rf "${backup_dir}"
  rm -f "${BACKUP_PATH_FILE}"
  echo "Restore complete. Backup removed."
}

# --- Main ---

if [ $# -lt 1 ]; then
  usage
fi

command="$1"
shift

case "${command}" in
  copy)
    if [ $# -lt 1 ]; then
      echo "Error: 'copy' requires a variant name." >&2
      usage
    fi
    variant="$1"
    backup_variant_src "${variant}"
    echo "Applying variant: ${variant}"
    install_variant_files "${variant}"
    echo "Done. Run '$0 restore' to revert src/."
    ;;
  restore)
    restore_src
    ;;
  save)
    if [ $# -lt 1 ]; then
      echo "Error: 'save' requires a variant name." >&2
      usage
    fi
    variant="$1"

    mapfile -t save_dirs < <(variant_overlay_dirs "${variant}")

    total=0
    for patch_dir in "${save_dirs[@]}"; do
      patch_name="${patch_dir#${PATCHES_DIR}/}"
      echo "Copying files from src/ back into patches/${patch_name}"
      while IFS= read -r -d '' rel; do
        cp "${REPO_ROOT}/src/${rel}" "${patch_dir}/${rel}"
        echo "  ${rel}"
        total=$((total + 1))
      done < <(cd "${patch_dir}" && find . -type f -print0 | sed -z 's|^\./||')
    done
    echo "Done. ${total} file(s) updated."
    ;;
  *)
    echo "Error: Unknown command '${command}'" >&2
    usage
    ;;
esac
