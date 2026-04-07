#!/usr/bin/env bash

if [ -n "${VARIANT_COMMON_SH_LOADED:-}" ]; then
  return 0
fi
VARIANT_COMMON_SH_LOADED=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PATCHES_DIR="${REPO_ROOT}/patches"
VARIANT_IMAGES_ROOT="${REPO_ROOT}/build/variant-images"
VARIANT_STATE_ROOT="${REPO_ROOT}/build/variant-build-state"

VARIANT_LIST=(
  "none"
  "clear_path_only"
  "sep_only"
  "dyn_only"
  "clear_path_sep"
  "clear_path_dyn"
  "sep_dyn"
  "all"
  "weak_fields"
)

variant_image_name() {
  local variant="$1"
  local level="$2"

  printf '%s-linux-x86_64-server-%s\n' "${variant}" "${level}"
}

shared_conf_name() {
  local level="$1"

  printf 'shared-linux-x86_64-server-%s\n' "${level}"
}

dedicated_conf_name() {
  local variant="$1"
  local level="$2"

  variant_image_name "${variant}" "${level}"
}

variant_image_dir_by_name() {
  local image_name="$1"

  printf '%s/%s\n' "${VARIANT_IMAGES_ROOT}" "${image_name}"
}

variant_cache_dir() {
  local variant="$1"
  local level="$2"

  printf '%s/%s/%s\n' "${VARIANT_STATE_ROOT}" "${level}" "${variant}"
}

variant_cache_hotspot_dir() {
  local variant="$1"
  local level="$2"

  printf '%s/hotspot/variant-server\n' "$(variant_cache_dir "${variant}" "${level}")"
}

variant_cache_signature_file() {
  local variant="$1"
  local level="$2"

  printf '%s/signature\n' "$(variant_cache_dir "${variant}" "${level}")"
}

shared_conf_dir() {
  local level="$1"

  printf '%s/build/%s\n' "${REPO_ROOT}" "$(shared_conf_name "${level}")"
}

shared_hotspot_dir() {
  local level="$1"

  printf '%s/hotspot/variant-server\n' "$(shared_conf_dir "${level}")"
}

shared_work_state_dir() {
  local level="$1"

  printf '%s/.variant_work_state\n' "$(shared_conf_dir "${level}")"
}

copy_tree_contents() {
  local source_dir="$1"
  local dest_dir="$2"

  mkdir -p "${dest_dir}"
  cp -a --reflink=auto "${source_dir}/." "${dest_dir}/"
}

replace_tree_from_source() {
  local source_dir="$1"
  local dest_dir="$2"
  local dest_parent
  local temp_dir

  dest_parent="$(dirname "${dest_dir}")"
  mkdir -p "${dest_parent}"
  temp_dir="$(mktemp -d "${dest_parent}/.$(basename "${dest_dir}").tmp.XXXXXX")"

  if ! copy_tree_contents "${source_dir}" "${temp_dir}"; then
    rm -rf "${temp_dir}"
    return 1
  fi

  rm -rf "${dest_dir}"
  mv "${temp_dir}" "${dest_dir}"
}

ensure_patch_layout() {
  local variant

  if [ ! -d "${PATCHES_DIR}/base/src" ]; then
    echo "Error: missing base patch directory: ${PATCHES_DIR}/base/src" >&2
    return 1
  fi

  for variant in "${VARIANT_LIST[@]}"; do
    if [ "${variant}" = "none" ]; then
      continue
    fi

    if [ ! -d "${PATCHES_DIR}/${variant}/src" ]; then
      echo "Error: missing patch directory: ${PATCHES_DIR}/${variant}/src" >&2
      return 1
    fi
  done
}

variant_overlay_dirs() {
  local variant="$1"

  case "${variant}" in
    none)
      return 0
      ;;
    weak_fields)
      printf '%s\n' "${PATCHES_DIR}/${variant}/src"
      ;;
    dyn_only)
      printf '%s\n' "${PATCHES_DIR}/${variant}/src"
      ;;
    *)
      printf '%s\n' "${PATCHES_DIR}/base/src"
      printf '%s\n' "${PATCHES_DIR}/${variant}/src"
      ;;
  esac
}

install_variant_files() {
  local variant="$1"
  local -a overlay_dirs=()
  local overlay_dir

  if [ "${variant}" = "none" ]; then
    return 0
  fi

  mapfile -t overlay_dirs < <(variant_overlay_dirs "${variant}")
  for overlay_dir in "${overlay_dirs[@]}"; do
    if [ ! -d "${overlay_dir}" ]; then
      echo "Error: patch directory not found: ${overlay_dir}" >&2
      return 1
    fi
    copy_tree_contents "${overlay_dir}" "${REPO_ROOT}/src"
  done
}

compute_variant_signature() {
  local variant="$1"
  local -a overlay_dirs=()
  local overlay_dir

  mapfile -t overlay_dirs < <(variant_overlay_dirs "${variant}")

  {
    printf 'variant:%s\n' "${variant}"
    for overlay_dir in "${overlay_dirs[@]}"; do
      printf 'dir:%s\n' "${overlay_dir}"
      while IFS= read -r -d '' file; do
        sha256sum "${file}"
      done < <(find "${overlay_dir}" -type f -print0 | LC_ALL=C sort -z)
    done
  } | sha256sum | awk '{print $1}'
}

touch_variant_sources() {
  local variant="$1"
  local -a overlay_dirs=()
  local overlay_dir

  mapfile -t overlay_dirs < <(variant_overlay_dirs "${variant}")
  if [ "${#overlay_dirs[@]}" -eq 0 ]; then
    return 0
  fi

  while IFS= read -r -d '' rel_path; do
    if [ -e "${REPO_ROOT}/src/${rel_path}" ]; then
      touch "${REPO_ROOT}/src/${rel_path}"
    fi
  done < <(
    for overlay_dir in "${overlay_dirs[@]}"; do
      while IFS= read -r -d '' file; do
        printf '%s\0' "${file#${overlay_dir}/}"
      done < <(find "${overlay_dir}" -type f -print0)
    done | LC_ALL=C sort -zu
  )
}

snapshot_variant_image() {
  local image_name="$1"
  local conf_dir="$2"
  local image_dir
  local temp_dir
  local temp_jdk_dir
  local launcher_count=0

  image_dir="$(variant_image_dir_by_name "${image_name}")"
  mkdir -p "$(dirname "${image_dir}")"
  temp_dir="$(mktemp -d "$(dirname "${image_dir}")/.$(basename "${image_dir}").tmp.XXXXXX")"
  temp_jdk_dir="${temp_dir}/jdk"

  mkdir -p "${temp_jdk_dir}"
  if ! cp -aL --reflink=auto "${conf_dir}/jdk/." "${temp_jdk_dir}/"; then
    rm -rf "${temp_dir}"
    return 1
  fi

  mkdir -p "${temp_jdk_dir}/bin"
  while IFS= read -r -d '' launcher; do
    cp -aL --reflink=auto "${launcher}" "${temp_jdk_dir}/bin/"
    launcher_count=$((launcher_count + 1))
  done < <(
    find "${conf_dir}/support/modules_cmds" -mindepth 2 -maxdepth 2 \( -type f -o -type l \) ! -name '*.debuginfo' -print0 2>/dev/null | LC_ALL=C sort -z
  )

  if [ "${launcher_count}" -eq 0 ]; then
    rm -rf "${temp_dir}"
    echo "Error: no launcher binaries found under ${conf_dir}/support/modules_cmds" >&2
    return 1
  fi

  rm -rf "${image_dir}"
  mv "${temp_dir}" "${image_dir}"
}