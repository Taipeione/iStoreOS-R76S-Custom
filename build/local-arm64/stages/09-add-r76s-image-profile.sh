#!/usr/bin/env bash
# Original workflow step: Add R76S image profile
# REVIEW REQUIRED: not yet adapted for local execution.

cd openwrt

ARMV8_MK="target/linux/rockchip/image/armv8.mk"

if grep -q \
  '^define Device/friendlyarm_nanopi-r76s$' \
  "$ARMV8_MK"; then

  echo "R76S profile already exists."

else

  echo >> "$ARMV8_MK"

  cat >> "$ARMV8_MK" <<'EOF'

define Device/friendlyarm_nanopi-r76s
  $(Device/Legacy)
  DEVICE_VENDOR := FriendlyARM
  DEVICE_MODEL := NanoPi R76S
  SOC := rk3576
  UBOOT_DEVICE_NAME := easepi-rk3576
  DEVICE_PACKAGES := kmod-r8169 kmod-rtw88-8822cs wpad-basic-mbedtls
endef
TARGET_DEVICES += friendlyarm_nanopi-r76s
EOF


echo
echo "===== Final R76S profile ====="

sed -n \
  '/define Device\/friendlyarm_nanopi-r76s/,/TARGET_DEVICES += friendlyarm_nanopi-r76s/p' \
  "$ARMV8_MK"

grep -q \
  '^define Device/friendlyarm_nanopi-r76s$' \
  "$ARMV8_MK"

grep -q \
  '^TARGET_DEVICES += friendlyarm_nanopi-r76s$' \
  "$ARMV8_MK"

fi
