#!/usr/bin/env bash
set -euo pipefail
# R76S_V12_CANDIDATE_LOCAL_BUILD_GUARD_20261010
# Original workflow step: Locate R76S firmware
# REVIEW REQUIRED: not yet adapted for local execution.

TARGET_DIR="openwrt/bin/targets/rockchip/armv8"

echo "===== Build output ====="

find \
  "$TARGET_DIR" \
  -maxdepth 1 \
  -type f \
  -printf '%f\n' \
  | sort

mapfile -t MATCHES < <(find "$TARGET_DIR" -maxdepth 1 -type f \
  -name '*friendlyarm_nanopi-r76s*squashfs*.img.gz' -print)
if [ "${#MATCHES[@]}" -ne 1 ]; then
  echo "ERROR: expected one unambiguous R76S image, got ${#MATCHES[@]}" >&2
  printf '%s\n' "${MATCHES[@]}" >&2
  exit 1
fi
CUSTOM_IMAGE="${MATCHES[0]}"
test -s "$CUSTOM_IMAGE"

echo
echo "Found:"
echo "$CUSTOM_IMAGE"

echo "CUSTOM_IMAGE=$CUSTOM_IMAGE" >> "$GITHUB_ENV"
echo "TARGET_DIR=$TARGET_DIR" >> "$GITHUB_ENV"
