#!/usr/bin/env bash
# Original workflow step: Fix R76S boot console
# REVIEW REQUIRED: not yet adapted for local execution.

cd openwrt

BOOT_SCRIPT="target/linux/rockchip/image/legacy/default.bootscript"

echo "===== Boot script before patch ====="

grep -n 'console=' "$BOOT_SCRIPT" || true

sed -i \
  's/console=ttyS2,1500000/console=ttyS0,1500000/g' \
  "$BOOT_SCRIPT"

echo
echo "===== Boot script after patch ====="

grep -n 'console=' "$BOOT_SCRIPT" || true

grep -q \
  'console=ttyS0,1500000' \
  "$BOOT_SCRIPT"

if grep -q \
  'console=ttyS2,1500000' \
  "$BOOT_SCRIPT"; then

  echo "ERROR: ttyS2 still exists."
  exit 1
fi

echo
echo "R76S boot console verified: ttyS0."
