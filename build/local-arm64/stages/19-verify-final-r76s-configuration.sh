#!/usr/bin/env bash
set -euo pipefail
# R76S_V12_BUILD_STAGE_FIX_20261010: enforce OTA verification from correct cwd.
# Original workflow step: Verify final R76S configuration
# REVIEW REQUIRED: not yet adapted for local execution.

cd openwrt

echo "===== TARGET ====="

grep -E \
  '^CONFIG_TARGET_(rockchip|rockchip_armv8)' \
  .config

echo
echo "===== DEVICE ====="

grep \
  '^CONFIG_TARGET_rockchip_armv8_DEVICE_.*=y$' \
  .config \
  || true

echo
echo "===== PARTITIONS ====="

grep -E \
  '^CONFIG_TARGET_(KERNEL_PARTSIZE|ROOTFS_PARTSIZE)=' \
  .config

echo
echo "===== ROOTFS ====="

grep -E \
  '^CONFIG_TARGET_ROOTFS_|^# CONFIG_TARGET_ROOTFS_' \
  .config \
  || true

for required in \
  'CONFIG_TARGET_rockchip=y' \
  'CONFIG_TARGET_rockchip_armv8=y' \
  'CONFIG_TARGET_rockchip_armv8_DEVICE_friendlyarm_nanopi-r76s=y' \
  'CONFIG_TARGET_KERNEL_PARTSIZE=64' \
  'CONFIG_TARGET_ROOTFS_PARTSIZE=256' \
  'CONFIG_TARGET_ROOTFS_SQUASHFS=y' \
  '# CONFIG_TARGET_ROOTFS_EXT4FS is not set' \
  'CONFIG_PACKAGE_luci-app-r76s-status=y' \
  'CONFIG_PACKAGE_luci-app-r76s-updater=y' \
  'CONFIG_PACKAGE_quickstart=y' \
  'CONFIG_PACKAGE_luci-app-quickstart=y' \
  'CONFIG_PACKAGE_luci-i18n-quickstart-zh-cn=y' \
  'CONFIG_PACKAGE_luci-theme-argon=y' \
  'CONFIG_PACKAGE_luci-app-ota=y' \
  'CONFIG_PACKAGE_luci-app-package-manager=y' \
  'CONFIG_PACKAGE_kmod-tun=y' \
  'CONFIG_PACKAGE_smartdns=y' \
  'CONFIG_PACKAGE_luci-app-smartdns=y' \
  'CONFIG_PACKAGE_luci-i18n-smartdns-zh-cn=y' \
  'CONFIG_PACKAGE_adguardhome=y' \
  'CONFIG_PACKAGE_dockerd=y' \
  'CONFIG_PACKAGE_luci-app-dockerman=y' \
  'CONFIG_PACKAGE_luci-app-passwall=y' \
  'CONFIG_PACKAGE_luci-app-passwall2=y' \
  'CONFIG_PACKAGE_luci-i18n-passwall2-zh-cn=y' \
  'CONFIG_PACKAGE_luci-app-passwall_Nftables_Transparent_Proxy=y' \
  'CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Xray=y' \
  'CONFIG_PACKAGE_luci-app-passwall_INCLUDE_SingBox=y' \
  'CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Geoview=y' \
  'CONFIG_PACKAGE_luci-app-passwall_INCLUDE_V2ray_Geodata=y' \
  'CONFIG_PACKAGE_kmod-nft-socket=y' \
  'CONFIG_PACKAGE_kmod-nft-tproxy=y' \
  'CONFIG_PACKAGE_chinadns-ng=y' \
  'CONFIG_PACKAGE_xray-core=y' \
  'CONFIG_PACKAGE_sing-box=y'; do
  if ! grep -qxF "$required" .config; then
    echo "ERROR: required config missing after defconfig: $required"
    exit 1
  fi
done

echo
echo "===== PASSWALL ====="
grep -E \
  '^CONFIG_PACKAGE_(luci-app-passwall|chinadns-ng|xray-core|sing-box|kmod-nft-(socket|tproxy))' \
  .config \
  | sort

DEVICE_COUNT=$(
  grep -c \
    '^CONFIG_TARGET_rockchip_armv8_DEVICE_.*=y$' \
    .config \
    || true
)

echo
echo "Enabled device count: $DEVICE_COUNT"

if [ "$DEVICE_COUNT" -ne 1 ]; then
  echo "ERROR: Exactly one Rockchip device must be selected."
  exit 1
fi

echo
echo "===== FINAL V1.1.1 ROOTFS OVERLAY ASSERTIONS ====="
test -x files/usr/libexec/r76s/r76s-ota-preserve-state
grep -qF 'r76s_ota_state.state.pending' files/usr/libexec/r76s/r76s-ota-preserve-state
test -s files/www/luci-static/resources/ui.js
grep -qF 'timeout: 0' files/www/luci-static/resources/ui.js
test -s files/www/luci-static/resources/view/system/flash.js
grep -qF 'R76S_V110_FLASH_UPLOAD_PATCH' files/www/luci-static/resources/view/system/flash.js
echo "Final rootfs overlay assertions: PASS"

# R76S_V12_PUBLIC_CREDENTIALS_20261010
if [ "${R76S_PUBLIC_RELEASE:-0}" = 1 ]; then
    grep -qxF 'CONFIG_PACKAGE_openssl-util=y' .config || {
       echo 'ERROR: public firstboot requires openssl-util in final config' >&2; exit 1;
    }
    test -x files/etc/uci-defaults/05-r76s-public-serial-provision
    sh -n files/etc/uci-defaults/05-r76s-public-serial-provision
fi

echo "R76S v1.1.1 configuration verified successfully."

# R76S_V12_OTA_HARDENING_CHECK: final generated-source contract.
grep -qF 'R76S_V12_OTA_HARDENING' files/usr/libexec/r76s/r76s-ota-preserve-state
grep -qF 'R76S_V12_OTA_HARDENING' files/etc/init.d/r76s-ota-restore
grep -qF 'R76S_V12_OTA_HARDENING' files/etc/uci-defaults/99-r76s-v110-ota-restore
grep -qF 'local preserve_rc = sys.call(' package/custom/luci-app-r76s-updater/files/controller/r76s_updater.lua
! grep -qF 'r76s-ota-preserve-state && /sbin/sysupgrade' package/custom/luci-app-r76s-updater/files/controller/r76s_updater.lua
