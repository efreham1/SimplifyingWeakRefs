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
  save)
    if [ $# -lt 1 ]; then
      echo "Error: 'save' requires a variant name." >&2
      usage
    fi
    variant="$1"

    # Build list of patch dirs to save into (same layering as copy)
    save_dirs=()
    if [ "${variant}" != "none" ] && [ "${variant}" != "weak_fields" ] && [ "${variant}" != "dyn_only" ]; then
      save_dirs+=("${PATCHES_DIR}/base/src")
    fi
    variant_dir="${PATCHES_DIR}/${variant}/src"
    if [ -d "${variant_dir}" ]; then
      save_dirs+=("${variant_dir}")
    elif [ "${variant}" != "none" ]; then
      echo "Error: patch directory not found: ${variant_dir}" >&2
      exit 1
    fi

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
