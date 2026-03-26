#!/usr/bin/env bash
set -euo pipefail

# diff_patches.sh
# Show side-by-side diffs between patch files and their upstream counterparts in src/.
#
# Usage:
#   ./scripts/diff_patches.sh [variant ...]
#   ./scripts/diff_patches.sh                  # all variants
#   ./scripts/diff_patches.sh all weak_fields  # specific variants
#   ./scripts/diff_patches.sh base --stat      # summary only

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PATCHES_DIR="${REPO_ROOT}/patches"

DIFF_OPTS=()
VARIANTS=()
STAT_ONLY=false

while [ $# -gt 0 ]; do
  case "$1" in
    --stat) STAT_ONLY=true; shift ;;
    --*)    DIFF_OPTS+=("$1"); shift ;;
    *)      VARIANTS+=("$1"); shift ;;
  esac
done

# Default: all variant directories that contain a src/ subdir
if [ ${#VARIANTS[@]} -eq 0 ]; then
  for d in "${PATCHES_DIR}"/*/src; do
    [ -d "$d" ] && VARIANTS+=("$(basename "$(dirname "$d")")")
  done
fi

COLS="${COLUMNS:-$(tput cols 2>/dev/null || echo 200)}"

for variant in "${VARIANTS[@]}"; do
  variant_src="${PATCHES_DIR}/${variant}/src"
  if [ ! -d "${variant_src}" ]; then
    echo "No src/ directory for variant '${variant}'; skipping" >&2
    continue
  fi

  echo "===== ${variant} ====="

  while IFS= read -r patch_file; do
    rel="${patch_file#"${variant_src}/"}"
    upstream="${REPO_ROOT}/src/${rel}"

    if [ "$STAT_ONLY" = true ]; then
      if [ -f "$upstream" ]; then
        changes=$(diff -u "$upstream" "$patch_file" | grep -c '^[+-]' || true)
        printf "  %-80s %4d changed lines\n" "$rel" "$changes"
      else
        printf "  %-80s (new file)\n" "$rel"
      fi
    else
      echo ""
      echo "--- ${variant}  ${rel} ---"
      if [ -f "$upstream" ]; then
        diff --color=always -y "$upstream" "$patch_file" "${DIFF_OPTS[@]}" || true
      else
        echo "(new file - no upstream counterpart)"
        head -50 "$patch_file"
      fi
    fi
  done < <(find "$variant_src" -type f | sort)

  echo ""
done
