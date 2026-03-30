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
# The backup is stored in .src_backup/ at the repo root. It is created
# automatically on the first "copy" if it does not already exist.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PATCHES_DIR="${REPO_ROOT}/patches"
SRC_BACKUP="${REPO_ROOT}/.src_backup"

usage() {
  echo "Usage:"
  echo "  $0 copy <variant>   Apply variant patches to src/"
  echo "  $0 restore          Restore src/ from backup"
  echo ""
  echo "Available variants:"
  for d in "${PATCHES_DIR}"/*/; do
    v="$(basename "$d")"
    [ "$v" = "base" ] && continue
    [ "$v" = "sep_base" ] && continue
    echo "  $v"
  done
  exit 1
}

backup_src() {
  if [ -d "${SRC_BACKUP}" ]; then
    echo "Backup already exists at ${SRC_BACKUP}, skipping backup."
    return 0
  fi
  echo "Backing up src/ to ${SRC_BACKUP}"
  cp -a "${REPO_ROOT}/src/." "${SRC_BACKUP}/"
}

restore_src() {
  if [ ! -d "${SRC_BACKUP}" ]; then
    echo "Error: No backup found at ${SRC_BACKUP}. Nothing to restore." >&2
    exit 1
  fi
  echo "Restoring src/ from ${SRC_BACKUP}"
  rm -rf "${REPO_ROOT}/src"
  mkdir -p "${REPO_ROOT}/src"
  cp -a "${SRC_BACKUP}/." "${REPO_ROOT}/src/"
  rm -rf "${SRC_BACKUP}"
  echo "Restore complete. Backup removed."
}

install_variant_files() {
  local variant="$1"
  local base_dir="${PATCHES_DIR}/base/src"
  local sep_base_dir="${PATCHES_DIR}/sep_base/src"
  local variant_dir="${PATCHES_DIR}/${variant}/src"

  if [ "${variant}" = "none" ]; then
    echo "Variant 'none': no patches to apply."
    return 0
  fi

  if [ "${variant}" = "weak_fields" ]; then
    if [ ! -d "${variant_dir}" ]; then
      echo "Error: weak_fields patch directory not found: ${variant_dir}" >&2
      return 1
    fi
    cp -r "${variant_dir}/." "${REPO_ROOT}/src/"
    return 0
  fi

  if [ ! -d "${base_dir}" ]; then
    echo "Error: base patch directory not found: ${base_dir}" >&2
    return 1
  fi

  # Always apply base patches (zStat) for ref-proc variants
  cp -r "${base_dir}/." "${REPO_ROOT}/src/"

  # Apply sep_base patches for variants with separate discovered lists
  case "${variant}" in
    sep_only|clear_path_sep|sep_dyn|all)
      cp -r "${sep_base_dir}/." "${REPO_ROOT}/src/"
      ;;
  esac

  # Apply variant-specific patches on top
  if [ ! -d "${variant_dir}" ]; then
    echo "Error: variant patch directory not found: ${variant_dir}" >&2
    return 1
  fi
  cp -r "${variant_dir}/." "${REPO_ROOT}/src/"
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
    backup_src
    echo "Applying variant: ${variant}"
    install_variant_files "${variant}"
    echo "Done. Run '$0 restore' to revert src/."
    ;;
  restore)
    restore_src
    ;;
  *)
    echo "Error: Unknown command '${command}'" >&2
    usage
    ;;
esac
