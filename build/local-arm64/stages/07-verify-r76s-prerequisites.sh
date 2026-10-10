#!/usr/bin/env bash
# Original workflow step: Verify R76S prerequisites
# REVIEW REQUIRED: not yet adapted for local execution.

cd openwrt

echo "===== Check RK3576 / R76S prerequisites ====="

test -f \
  target/linux/rockchip/dts/rk3576/rk3576-nanopi-r76s.dts

grep -q \
  'compatible = "friendlyarm,nanopi-r76s", "rockchip,rk3576"' \
  target/linux/rockchip/dts/rk3576/rk3576-nanopi-r76s.dts

grep -q \
  'define U-Boot/easepi-rk3576' \
  package/boot/uboot-rk35xx/Makefile

grep -q \
  'define Device/Legacy' \
  target/linux/rockchip/image/Makefile

test -f \
  target/linux/rockchip/image/legacy/default.bootscript

echo
echo "R76S prerequisites verified."
