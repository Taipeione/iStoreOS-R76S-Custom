#!/usr/bin/env bash
# Original workflow step: Collect V1.1.1 diagnostic report even on failure
# REVIEW REQUIRED: not yet adapted for local execution.

mkdir -p r76s-build-diagnostics
{
  echo "BUILD_SHA=$GITHUB_SHA"
  echo "RUN_ID=$GITHUB_RUN_ID"
  echo "ROOTFS_VALIDATION=SEE_IMAGE_AUDIT_LOG"
  echo "RELEASE_PUBLISH=MANUAL_OPT_IN_ONLY"
  echo "===== OpenWrt image files ====="
  find openwrt/bin/targets/rockchip/armv8 -maxdepth 2 -type f -printf '%P %s bytes\n' 2>/dev/null || true
  echo "===== Root trees ====="
  find openwrt/build_dir -type d \( -name root-rockchip -o -name 'target-dir-*' \) -print 2>/dev/null | head -n 40 || true
} > r76s-build-diagnostics/summary.txt
