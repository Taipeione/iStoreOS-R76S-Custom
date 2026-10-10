#!/usr/bin/env bash
# Original workflow step: Verify ACTUAL SquashFS rootfs before allowing artifact
# REVIEW REQUIRED: not yet adapted for local execution.

set -euo pipefail
# R76S_V12_CANDIDATE_LOCAL_BUILD_GUARD_20261010
mkdir -p "$GITHUB_WORKSPACE/r76s-build-diagnostics"
echo "===== Image-grounded V1.1.1 critical files ====="
python3 scripts/r76s-v111-final-audit.py --phase image --image "$RAW_IMAGE" \
  | tee "$GITHUB_WORKSPACE/r76s-build-diagnostics/image-audit.log"
echo "IMAGE_ROOTFS_EVIDENCE=PASS"
