#!/usr/bin/env bash
set -euo pipefail
# Original workflow step: Verify R76S status package
# REVIEW REQUIRED: not yet adapted for local execution.

echo "===== R76S custom package ====="

find \
  openwrt/package/custom/luci-app-r76s-status \
  -maxdepth 4 \
  -type f \
  -print

grep -qF 'Rockchip RK3576' \
  openwrt/package/custom/luci-app-r76s-status/files/controller/r76s_status.lua

grep -qF 'd.soc' \
  openwrt/package/custom/luci-app-r76s-status/files/controller/r76s_status.lua

grep -qF '<%=data.soc%>' \
  openwrt/package/custom/luci-app-r76s-status/files/view/r76s_status/status.htm

grep -qF 'PassWall2' \
  openwrt/package/custom/luci-app-r76s-status/files/view/r76s_status/status.htm
grep -qF 'AdGuard Home' \
  openwrt/package/custom/luci-app-r76s-status/files/view/r76s_status/status.htm
grep -qF "pgrep -f '[s]martdns'" \
  openwrt/package/custom/luci-app-r76s-status/files/controller/r76s_status.lua
grep -qF "pgrep -f '/tmp/etc/passwall/'" \
  openwrt/package/custom/luci-app-r76s-status/files/controller/r76s_status.lua

grep -q \
  'view/r76s_status/\*' \
  openwrt/package/custom/luci-app-r76s-status/Makefile

echo
echo "R76S status page verified."
