#!/bin/bash
# build_and_copy_uppmax.sh
# Builds all configs (fastdebug and release) on an UPPMAX node and copies them back to the current directory.
# Usage: ./build_and_copy_uppmax.sh <uppmax_user>@<uppmax_host> <remote_build_dir> <local_copy_dir> [config1 config2 ...]

set -e

if [ "$#" -lt 3 ]; then
  echo "Usage: $0 <uppmax_user>@<uppmax_host> <remote_build_dir> <local_copy_dir> [config1 config2 ...]"
  exit 1
fi

UPPMAX_USER_HOST="$1"
REMOTE_BUILD_DIR="$2"
LOCAL_COPY_DIR="$3"
shift 3
CONFIGS=("$@")

if [ ${#CONFIGS[@]} -eq 0 ]; then
  CONFIGS=(weak_fields) # Default config if none specified
fi

BUILD_TYPES=(fastdebug release)

# Step 1: Rsync source to UPPMAX node
rsync -az --delete --exclude 'build/' --exclude 'output/' ./ "$UPPMAX_USER_HOST":"$REMOTE_BUILD_DIR"/

# Step 2: SSH to UPPMAX and build
ssh "$UPPMAX_USER_HOST" bash -c "'
set -e
cd "$REMOTE_BUILD_DIR"
for config in ${CONFIGS[@]}; do
  for build_type in ${BUILD_TYPES[@]}; do
    echo "Building config: $config, type: $build_type"
    bash scripts/build_configs.sh --debug-level $build_type $config
  done
done
'"

# Step 3: Rsync build outputs back
for config in "${CONFIGS[@]}"; do
  for build_type in "${BUILD_TYPES[@]}"; do
    REMOTE_BUILD_PATH="$REMOTE_BUILD_DIR/build/${config}-linux-x86_64-server-$build_type/"
    LOCAL_BUILD_PATH="$LOCAL_COPY_DIR/build/${config}-linux-x86_64-server-$build_type/"
    mkdir -p "$LOCAL_BUILD_PATH"
    rsync -az "$UPPMAX_USER_HOST":"$REMOTE_BUILD_PATH" "$LOCAL_BUILD_PATH"
  done
done

echo "Build and copy complete."
