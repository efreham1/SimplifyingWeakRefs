#!/usr/bin/env bash
set -euo pipefail

# create_configs.sh
# Prepares the minimal set of configured build directories used by the
# variant build workflow and writes scripts/variants.conf.
#
# The ref-proc variants share one configured build per debug level and swap
# per-variant HotSpot caches in and out of that workspace. The weak_fields
# variant keeps a dedicated configured build because it patches code outside
# HotSpot as well.
#
# Usage:
#   ./scripts/create_configs.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/variant_common.sh"

OUT_CONF_FILE="${SCRIPT_DIR}/variants.conf"
DEBUG_LEVELS=("release" "fastdebug")
HEADLESS_ONLY="${HEADLESS_ONLY:-1}"
BOOT_JDK_CACHE_ROOT="${BOOT_JDK_CACHE_ROOT:-${REPO_ROOT}/build/boot-jdks}"
BOOT_JDK_DIR="${BOOT_JDK_DIR:-${BOOT_JDK_CACHE_ROOT}/jdk-26}"
BOOT_JDK_ARCHIVE="${BOOT_JDK_ARCHIVE:-${BOOT_JDK_CACHE_ROOT}/openjdk-26_linux-x64_bin.tar.gz}"
BOOT_JDK_URL="${BOOT_JDK_URL:-https://download.java.net/java/GA/jdk26/c3cc523845074aa0af4f5e1e1ed4151d/35/GPL/openjdk-26_linux-x64_bin.tar.gz}"
BOOT_JDK_SHA256_URL="${BOOT_JDK_SHA256_URL:-${BOOT_JDK_URL}.sha256}"
ALSA_CACHE_ROOT="${ALSA_CACHE_ROOT:-${REPO_ROOT}/build/native-deps/alsa}"
ALSA_RPM_DIR="${ALSA_RPM_DIR:-${ALSA_CACHE_ROOT}/rpms}"
ALSA_EXTRACT_ROOT="${ALSA_EXTRACT_ROOT:-${ALSA_CACHE_ROOT}/root}"
ALSA_PREFIX="${ALSA_PREFIX:-${ALSA_EXTRACT_ROOT}/usr}"
ALSA_PACKAGES=(alsa-lib alsa-lib-devel)
CUPS_CACHE_ROOT="${CUPS_CACHE_ROOT:-${REPO_ROOT}/build/native-deps/cups}"
CUPS_RPM_DIR="${CUPS_RPM_DIR:-${CUPS_CACHE_ROOT}/rpms}"
CUPS_EXTRACT_ROOT="${CUPS_EXTRACT_ROOT:-${CUPS_CACHE_ROOT}/root}"
CUPS_PREFIX="${CUPS_PREFIX:-${CUPS_EXTRACT_ROOT}/usr}"
CUPS_PACKAGES=(cups-libs cups-devel)

require_command() {
  local command_name="$1"

  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "${command_name} is required" >&2
    exit 1
  }
}

jdk_major_version() {
  local jdk_home="$1"
  local version_line
  local version_string

  version_line="$(${jdk_home}/bin/java -version 2>&1 | head -1)" || return 1
  version_string="$(printf '%s\n' "${version_line}" | sed -n 's/.*version "\([^"]*\)".*/\1/p')"
  [ -n "${version_string}" ] || return 1

  printf '%s\n' "${version_string}" | sed -E 's/^([0-9]+).*/\1/'
}

is_valid_boot_jdk_dir() {
  local candidate="$1"
  local major

  if [ ! -x "${candidate}/bin/java" ] || [ ! -x "${candidate}/bin/javac" ]; then
    return 1
  fi

  major="$(jdk_major_version "${candidate}")" || return 1
  case "${major}" in
    26|27)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

download_boot_jdk_archive() {
  local archive_dir
  local checksum_file
  local expected_checksum
  local actual_checksum

  archive_dir="$(dirname "${BOOT_JDK_ARCHIVE}")"
  checksum_file="${BOOT_JDK_ARCHIVE}.sha256"
  mkdir -p "${archive_dir}"

  if [ ! -f "${BOOT_JDK_ARCHIVE}" ]; then
    echo "Downloading Boot JDK archive to ${BOOT_JDK_ARCHIVE}" >&2
    curl -fL "${BOOT_JDK_URL}" -o "${BOOT_JDK_ARCHIVE}"
  fi

  echo "Downloading Boot JDK checksum from ${BOOT_JDK_SHA256_URL}" >&2
  curl -fsSL "${BOOT_JDK_SHA256_URL}" -o "${checksum_file}"

  expected_checksum="$(awk '{print $1}' "${checksum_file}")"
  actual_checksum="$(sha256sum "${BOOT_JDK_ARCHIVE}" | awk '{print $1}')"
  if [ "${expected_checksum}" != "${actual_checksum}" ]; then
    echo "Boot JDK checksum mismatch for ${BOOT_JDK_ARCHIVE}" >&2
    echo "Expected: ${expected_checksum}" >&2
    echo "Actual:   ${actual_checksum}" >&2
    return 1
  fi
}

extract_boot_jdk_archive() {
  local temp_root
  local extracted_root

  mkdir -p "$(dirname "${BOOT_JDK_DIR}")"
  temp_root="$(mktemp -d "${BOOT_JDK_CACHE_ROOT}/.boot-jdk.XXXXXX")"
  tar -xzf "${BOOT_JDK_ARCHIVE}" -C "${temp_root}"

  extracted_root="$(find "${temp_root}" -mindepth 1 -maxdepth 1 -type d | head -1)"
  if [ -z "${extracted_root}" ]; then
    echo "Failed to locate extracted Boot JDK root in ${temp_root}" >&2
    rm -rf "${temp_root}"
    return 1
  fi

  rm -rf "${BOOT_JDK_DIR}"
  mv "${extracted_root}" "${BOOT_JDK_DIR}"
  rm -rf "${temp_root}"
}

resolve_requested_boot_jdk() {
  local requested="${BOOT_JDK:-}"

  if [ -z "${requested}" ]; then
    return 1
  fi

  if [ -d "${requested}" ] && is_valid_boot_jdk_dir "${requested}"; then
    printf '%s\n' "${requested}"
    return 0
  fi

  if [ -f "${requested}" ]; then
    printf '%s\n' "${requested}"
    return 0
  fi

  echo "BOOT_JDK is set but does not point to a valid JDK directory or archive: ${requested}" >&2
  return 1
}

ensure_boot_jdk() {
  local requested_boot_jdk

  if requested_boot_jdk="$(resolve_requested_boot_jdk 2>/dev/null)"; then
    printf '%s\n' "${requested_boot_jdk}"
    return 0
  fi

  if is_valid_boot_jdk_dir "${BOOT_JDK_DIR}"; then
    printf '%s\n' "${BOOT_JDK_DIR}"
    return 0
  fi

  require_command curl
  require_command sha256sum
  require_command tar

  download_boot_jdk_archive
  extract_boot_jdk_archive

  if ! is_valid_boot_jdk_dir "${BOOT_JDK_DIR}"; then
    echo "Extracted Boot JDK at ${BOOT_JDK_DIR} is not a valid JDK 26/27 installation" >&2
    exit 1
  fi

  printf '%s\n' "${BOOT_JDK_DIR}"
}

normalise_vendor_prefix_layout() {
  local prefix="$1"
  local lib_dir="${prefix}/lib"
  local lib64_dir="${prefix}/lib64"
  local entry
  local name

  [ -d "${lib64_dir}" ] || return 0

  if [ ! -e "${lib_dir}" ]; then
    ln -s lib64 "${lib_dir}"
    return 0
  fi

  if [ -L "${lib_dir}" ]; then
    return 0
  fi

  shopt -s nullglob
  for entry in "${lib64_dir}"/*; do
    name="${entry##*/}"
    if [ ! -e "${lib_dir}/${name}" ]; then
      ln -s "../lib64/${name}" "${lib_dir}/${name}"
    fi
  done
  shopt -u nullglob
}

vendor_prefix_has_lib() {
  local prefix="$1"
  shift
  local candidate

  for candidate in "$@"; do
    if [ -e "${prefix}/lib/${candidate}" ]; then
      return 0
    fi
  done

  return 1
}

is_valid_vendor_prefix() {
  local prefix="$1"
  local include_dir="$2"
  shift 2

  [ -d "${prefix}/include/${include_dir}" ] || return 1
  vendor_prefix_has_lib "${prefix}" "$@" || return 1
}

download_vendor_rpms() {
  local rpm_dir="$1"
  shift

  mkdir -p "${rpm_dir}"
  dnf download --destdir "${rpm_dir}" --arch x86_64 "$@"
}

extract_vendor_rpms() {
  local rpm_dir="$1"
  local extract_root="$2"
  local prefix="$3"
  local rpm

  rm -rf "${extract_root}"
  mkdir -p "${extract_root}"

  shopt -s nullglob
  for rpm in "${rpm_dir}"/*.rpm; do
    rpm2cpio "${rpm}" | (cd "${extract_root}" && cpio -idmu --quiet)
  done
  shopt -u nullglob

  normalise_vendor_prefix_layout "${prefix}"
}

ensure_alsa_prefix() {
  normalise_vendor_prefix_layout "${ALSA_PREFIX}"

  if is_valid_vendor_prefix "${ALSA_PREFIX}" alsa libasound.so libasound.so.2; then
    printf '%s\n' "${ALSA_PREFIX}"
    return 0
  fi

  require_command dnf
  require_command rpm2cpio
  require_command cpio

  download_vendor_rpms "${ALSA_RPM_DIR}" "${ALSA_PACKAGES[@]}"
  extract_vendor_rpms "${ALSA_RPM_DIR}" "${ALSA_EXTRACT_ROOT}" "${ALSA_PREFIX}"

  if ! is_valid_vendor_prefix "${ALSA_PREFIX}" alsa libasound.so libasound.so.2; then
    echo "Failed to prepare a valid local ALSA prefix at ${ALSA_PREFIX}" >&2
    exit 1
  fi

  printf '%s\n' "${ALSA_PREFIX}"
}

ensure_cups_prefix() {
  normalise_vendor_prefix_layout "${CUPS_PREFIX}"

  if is_valid_vendor_prefix "${CUPS_PREFIX}" cups libcups.so libcups.so.2; then
    printf '%s\n' "${CUPS_PREFIX}"
    return 0
  fi

  require_command dnf
  require_command rpm2cpio
  require_command cpio

  download_vendor_rpms "${CUPS_RPM_DIR}" "${CUPS_PACKAGES[@]}"
  extract_vendor_rpms "${CUPS_RPM_DIR}" "${CUPS_EXTRACT_ROOT}" "${CUPS_PREFIX}"

  if ! is_valid_vendor_prefix "${CUPS_PREFIX}" cups libcups.so libcups.so.2; then
    echo "Failed to prepare a valid local CUPS prefix at ${CUPS_PREFIX}" >&2
    exit 1
  fi

  printf '%s\n' "${CUPS_PREFIX}"
}

BOOT_JDK_PATH="$(ensure_boot_jdk)"
ALSA_PATH="$(ensure_alsa_prefix)"
CUPS_PATH="$(ensure_cups_prefix)"
CONFIGURE_COMMON_ARGS=("--with-boot-jdk=${BOOT_JDK_PATH}" "--with-alsa=${ALSA_PATH}" "--with-cups=${CUPS_PATH}")

if [ "${HEADLESS_ONLY}" = "1" ]; then
  CONFIGURE_COMMON_ARGS+=("--enable-headless-only")
fi

if [ -n "${VARIANT_CONFIGURE_EXTRA_ARGS:-}" ]; then
  read -r -a extra_args <<< "${VARIANT_CONFIGURE_EXTRA_ARGS}"
  CONFIGURE_COMMON_ARGS+=("${extra_args[@]}")
fi

ensure_patch_layout

cd "${REPO_ROOT}"

echo "Using Boot JDK: ${BOOT_JDK_PATH}"
echo "Using ALSA prefix: ${ALSA_PATH}"
echo "Using CUPS prefix: ${CUPS_PATH}"
echo "Headless-only build: ${HEADLESS_ONLY}"

cat > "${OUT_CONF_FILE}" <<EOF
# debug_level|conf_name|variant|image_name|mode
# Auto-generated by scripts/create_configs.sh
EOF

for level in "${DEBUG_LEVELS[@]}"; do
  shared_conf="$(shared_conf_name "${level}")"
  weak_fields_conf="$(dedicated_conf_name "weak_fields" "${level}")"

  for conf_name in "${shared_conf}" "${weak_fields_conf}"; do
    echo
    echo "=== Preparing config: ${conf_name} ==="

    if [ -d "build/${conf_name}" ] && [ ! -f "build/${conf_name}/spec.gmk" ]; then
      echo "Removing incomplete configure output in build/${conf_name}"
      rm -rf "build/${conf_name}"
    fi

    if [ ! -f "build/${conf_name}/spec.gmk" ]; then
      echo "Running: bash configure --with-conf-name=${conf_name} --with-debug-level=${level} ${CONFIGURE_COMMON_ARGS[*]}"
      bash configure --with-conf-name="${conf_name}" --with-debug-level="${level}" "${CONFIGURE_COMMON_ARGS[@]}"
    else
      echo "Skipping configure; build/${conf_name}/spec.gmk already exists"
    fi
  done

  for variant in "${VARIANT_LIST[@]}"; do
    image_name="$(variant_image_name "${variant}" "${level}")"
    mode="shared-hotspot"
    conf_name="${shared_conf}"

    if [ "${variant}" = "weak_fields" ]; then
      mode="dedicated"
      conf_name="${weak_fields_conf}"
    fi

    printf '%s|%s|%s|%s|%s\n' \
      "${level}" \
      "${conf_name}" \
      "${variant}" \
      "${image_name}" \
      "${mode}" >> "${OUT_CONF_FILE}"
  done
done

echo
echo "Wrote mapping to ${OUT_CONF_FILE}"
echo "Run scripts/build_configs.sh to refresh variant images under build/variant-images/."
