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

link_tree_contents() {
  local source_dir="$1"
  local dest_dir="$2"

  mkdir -p "${dest_dir}"
  cp -al "${source_dir}/." "${dest_dir}/"
}

copy_module_launchers() {
  local conf_dir="$1"
  local dest_jdk_dir="$2"
  local launcher
  local launcher_count=0

  mkdir -p "${dest_jdk_dir}/bin"
  while IFS= read -r -d '' launcher; do
    cp -aL --reflink=auto "${launcher}" "${dest_jdk_dir}/bin/"
    launcher_count=$((launcher_count + 1))
  done < <(
    find "${conf_dir}/support/modules_cmds" -mindepth 2 -maxdepth 2 \( -type f -o -type l \) ! -name '*.debuginfo' -print0 2>/dev/null | LC_ALL=C sort -z
  )

  if [ "${launcher_count}" -eq 0 ]; then
    echo "Error: no launcher binaries found under ${conf_dir}/support/modules_cmds" >&2
    return 1
  fi
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

variant_overlay_relative_paths() {
  local variant="$1"
  local -a overlay_dirs=()
  local overlay_dir

  mapfile -t overlay_dirs < <(variant_overlay_dirs "${variant}")
  if [ "${#overlay_dirs[@]}" -eq 0 ]; then
    return 0
  fi

  for overlay_dir in "${overlay_dirs[@]}"; do
    while IFS= read -r -d '' file; do
      printf '%s\n' "${file#${overlay_dir}/}"
    done < <(find "${overlay_dir}" \( -type f -o -type l \) -print0 | LC_ALL=C sort -z)
  done | LC_ALL=C sort -u
}

variant_overlay_relative_paths_for_variants() {
  local variant

  for variant in "$@"; do
    variant_overlay_relative_paths "${variant}"
  done | LC_ALL=C sort -u
}

src_backup_manifest_file() {
  local backup_dir="$1"

  printf '%s/manifest.txt\n' "${backup_dir}"
}

src_backup_files_dir() {
  local backup_dir="$1"

  printf '%s/files\n' "${backup_dir}"
}

count_src_backup_paths() {
  local backup_dir="$1"
  local manifest_file

  manifest_file="$(src_backup_manifest_file "${backup_dir}")"
  if [ ! -f "${manifest_file}" ]; then
    printf '0\n'
    return 0
  fi

  awk 'END { print NR + 0 }' "${manifest_file}"
}

backup_src_paths_from_stdin() {
  local backup_dir="$1"
  local manifest_file
  local files_dir
  local rel_path
  local src_path
  local backup_path
  local added_count=0
  declare -A tracked_paths=()

  manifest_file="$(src_backup_manifest_file "${backup_dir}")"
  files_dir="$(src_backup_files_dir "${backup_dir}")"

  mkdir -p "${backup_dir}" "${files_dir}"

  if [ -f "${manifest_file}" ]; then
    while IFS= read -r rel_path; do
      [ -n "${rel_path}" ] || continue
      tracked_paths["${rel_path}"]=1
    done < "${manifest_file}"
  fi

  while IFS= read -r rel_path; do
    [ -n "${rel_path}" ] || continue

    if [ -n "${tracked_paths[${rel_path}]+x}" ]; then
      continue
    fi

    tracked_paths["${rel_path}"]=1
    src_path="${REPO_ROOT}/src/${rel_path}"
    backup_path="${files_dir}/${rel_path}"

    if [ -e "${src_path}" ] || [ -L "${src_path}" ]; then
      mkdir -p "$(dirname "${backup_path}")"
      cp -a --reflink=auto "${src_path}" "${backup_path}"
    fi

    added_count=$((added_count + 1))
  done

  : > "${manifest_file}"
  if [ "${#tracked_paths[@]}" -gt 0 ]; then
    printf '%s\n' "${!tracked_paths[@]}" | LC_ALL=C sort > "${manifest_file}"
  fi

  printf '%s\n' "${added_count}"
}

backup_variant_sources() {
  local backup_dir="$1"

  shift
  backup_src_paths_from_stdin "${backup_dir}" < <(variant_overlay_relative_paths_for_variants "$@")
}

prune_empty_parent_dirs() {
  local dir_path="$1"
  local stop_dir="$2"

  while [ "${dir_path}" != "${stop_dir}" ] && [ "${dir_path}" != "/" ]; do
    rmdir "${dir_path}" 2>/dev/null || break
    dir_path="$(dirname "${dir_path}")"
  done
}

restore_src_from_backup() {
  local backup_dir="$1"
  local manifest_file
  local files_dir
  local rel_path
  local src_path
  local backup_path

  manifest_file="$(src_backup_manifest_file "${backup_dir}")"
  files_dir="$(src_backup_files_dir "${backup_dir}")"

  if [ ! -f "${manifest_file}" ]; then
    return 0
  fi

  while IFS= read -r rel_path; do
    [ -n "${rel_path}" ] || continue

    src_path="${REPO_ROOT}/src/${rel_path}"
    backup_path="${files_dir}/${rel_path}"

    if [ -e "${backup_path}" ] || [ -L "${backup_path}" ]; then
      mkdir -p "$(dirname "${src_path}")"
      rm -rf "${src_path}"
      cp -a --reflink=auto "${backup_path}" "${src_path}"
    else
      rm -rf "${src_path}"
      prune_empty_parent_dirs "$(dirname "${src_path}")" "${REPO_ROOT}/src"
    fi
  done < "${manifest_file}"
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
  local variant="${3:-}"
  local mode="${4:-}"
  local level="${image_name##*-}"
  local image_dir
  local temp_dir
  local temp_jdk_dir
  local base_image_dir

  image_dir="$(variant_image_dir_by_name "${image_name}")"
  mkdir -p "$(dirname "${image_dir}")"
  temp_dir="$(mktemp -d "$(dirname "${image_dir}")/.$(basename "${image_dir}").tmp.XXXXXX")"
  temp_jdk_dir="${temp_dir}/jdk"

  mkdir -p "${temp_jdk_dir}"

  if [ "${mode}" = "shared-hotspot" ] && [ "${variant}" != "none" ]; then
    base_image_dir="$(variant_image_dir_by_name "$(variant_image_name "none" "${level}")")"

    if [ -d "${base_image_dir}/jdk" ] && link_tree_contents "${base_image_dir}/jdk" "${temp_jdk_dir}"; then
      rm -rf "${temp_jdk_dir}/lib/server"
      mkdir -p "${temp_jdk_dir}/lib/server"
      if ! cp -aL --reflink=auto "${conf_dir}/jdk/lib/server/." "${temp_jdk_dir}/lib/server/"; then
        rm -rf "${temp_dir}"
        return 1
      fi
    else
      rm -rf "${temp_jdk_dir}"
      mkdir -p "${temp_jdk_dir}"
      if ! cp -aL --reflink=auto "${conf_dir}/jdk/." "${temp_jdk_dir}/"; then
        rm -rf "${temp_dir}"
        return 1
      fi
    fi
  elif [ "${mode}" = "dedicated" ] && [ "${variant}" != "none" ] && command -v rsync >/dev/null 2>&1; then
    base_image_dir="$(variant_image_dir_by_name "$(variant_image_name "none" "${level}")")"

    if [ -d "${base_image_dir}/jdk" ]; then
      if ! rsync -aL --delete --link-dest="${base_image_dir}/jdk" "${conf_dir}/jdk/" "${temp_jdk_dir}/"; then
        rm -rf "${temp_dir}"
        return 1
      fi

      if ! copy_module_launchers "${conf_dir}" "${temp_jdk_dir}"; then
        rm -rf "${temp_dir}"
        return 1
      fi
    else
      if ! cp -aL --reflink=auto "${conf_dir}/jdk/." "${temp_jdk_dir}/"; then
        rm -rf "${temp_dir}"
        return 1
      fi

      if ! copy_module_launchers "${conf_dir}" "${temp_jdk_dir}"; then
        rm -rf "${temp_dir}"
        return 1
      fi
    fi
  else
    if ! cp -aL --reflink=auto "${conf_dir}/jdk/." "${temp_jdk_dir}/"; then
      rm -rf "${temp_dir}"
      return 1
    fi

    if ! copy_module_launchers "${conf_dir}" "${temp_jdk_dir}"; then
      rm -rf "${temp_dir}"
      return 1
    fi
  fi

  if [ ! -e "${temp_jdk_dir}/bin/java" ]; then
    rm -rf "${temp_dir}"
    echo "Error: missing java launcher in snapshot for ${image_name}" >&2
    return 1
  fi

  rm -rf "${image_dir}"
  mv "${temp_dir}" "${image_dir}"
}