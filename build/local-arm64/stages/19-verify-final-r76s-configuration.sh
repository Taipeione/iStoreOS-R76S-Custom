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
  'CONFIG_PACKAGE_r76s-core=y' \
  'CONFIG_PACKAGE_bind-dig=y' \
  'CONFIG_PACKAGE_flock=y' \
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
  'CONFIG_PACKAGE_luci-app-store=y' \
  'CONFIG_PACKAGE_luci-app-ota=y' \
  'CONFIG_PACKAGE_luci-app-passwall2=y' \
  'CONFIG_PACKAGE_smartdns=y' \
  'CONFIG_PACKAGE_adguardhome=y' \
  'CONFIG_PACKAGE_ppp-mod-pppoe=y' \
  'CONFIG_PACKAGE_odhcp6c=y' \
  'CONFIG_PACKAGE_odhcpd-ipv6only=y' \
  'CONFIG_PACKAGE_wireguard-tools=y' \
  'CONFIG_PACKAGE_kmod-wireguard=y' \
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
test -x package/custom/r76s-core/files/usr/bin/r76s-health
grep -qF 'r76s_ota_state.state.pending' files/usr/libexec/r76s/r76s-ota-preserve-state
test -s files/www/luci-static/resources/ui.js
grep -qF 'timeout: 0' files/www/luci-static/resources/ui.js
test -s files/www/luci-static/resources/view/system/flash.js
grep -qF 'R76S_V110_FLASH_UPLOAD_PATCH' files/www/luci-static/resources/view/system/flash.js
echo "Final rootfs overlay assertions: PASS"

# R76S_V143_FIXED_CLEAN_FLASH_PASSWORD
if [ "${R76S_PUBLIC_RELEASE:-0}" = 1 ]; then
    test -x files/etc/init.d/r76s-root-password
    sh -n files/etc/init.d/r76s-root-password
    grep -qF 'R76S_V143_ROOT_PASSWORD_POLICY' files/etc/init.d/r76s-root-password
    grep -qF 'R76S-V1.4.3' files/etc/init.d/r76s-root-password
    grep -qF 'password' files/etc/init.d/r76s-root-password
    test -x files/etc/rc.d/S99r76s-root-password
    grep -qF '/etc/init.d/r76s-root-password' files/etc/rc.d/S99r76s-root-password
    test -x files/etc/uci-defaults/99-r76s-root-auth
    sh -n files/etc/uci-defaults/99-r76s-root-auth
    grep -qF 'R76S_V143_ROOT_PASSWORD_AUTH' files/etc/uci-defaults/99-r76s-root-auth
    ! test -e files/etc/uci-defaults/99-r76s-first-root-password
    ! test -e files/etc/uci-defaults/99-r76s-v142-root-password-migration
    ! test -e files/etc/uci-defaults/99-r76s-v143-root-password-migration
    ! grep -RqsE '/dev/(urandom|ttyS0)' files/etc/init.d/r76s-root-password files/etc/uci-defaults/99-r76s-root-auth
    grep -qF 'root:$6$r76sv143$j/yuToJ35nP6zluEW5qQzsYySWhM0mx8xaNVL.ZK2/J00HuN1d1Qr1h6PP2yWHgXmRlkRnA/Ymtqj60ETzJoi.:' package/base-files/files/etc/shadow
    grep -qF "option PasswordAuth '1'" files/etc/config/dropbear
    grep -qF "option RootPasswordAuth '1'" files/etc/config/dropbear
    grep -qF "option Interface 'lan'" files/etc/config/dropbear
fi

echo "R76S v1.1.1 configuration verified successfully."

# R76S_V12_OTA_HARDENING_CHECK: final generated-source contract.
grep -qF 'R76S_V12_OTA_HARDENING' files/usr/libexec/r76s/r76s-ota-preserve-state
grep -qF 'R76S_V12_OTA_HARDENING' files/etc/init.d/r76s-ota-restore
grep -qF 'R76S_V12_OTA_HARDENING' files/etc/uci-defaults/99-r76s-v110-ota-restore
grep -qF 'R76S_V14_OTA_BACKEND' package/custom/luci-app-r76s-updater/files/controller/r76s_updater.lua
grep -qF 'R76S_V12_OTA_HARDENING' package/custom/luci-app-r76s-updater/files/controller/r76s_updater.lua
grep -qF '/usr/libexec/r76s/r76s-ota install' package/custom/luci-app-r76s-updater/files/controller/r76s_updater.lua
! grep -qF 'r76s-ota-preserve-state && /sbin/sysupgrade' package/custom/luci-app-r76s-updater/files/controller/r76s_updater.lua

# R76S-V1.4.3 phase 1: native WireGuard UI and read-only AGH service entry.
for required in wireguard-tools kmod-wireguard luci-proto-wireguard luci-lib-uqr ucode; do
    grep -qxF "CONFIG_PACKAGE_${required}=y" .config || {
        echo "ERROR: WireGuard integration missing: $required" >&2; exit 1;
    }
done
test -s package/custom/luci-app-r76s-status/files/controller/r76s_adguardhome.lua
test -s package/custom/luci-app-r76s-status/files/view/r76s_adguardhome/status.htm
for path in controller/r76s_diagnostics.lua model/r76s/diagnostics.lua \
    model/r76s/diagnostics_collect.lua view/r76s_diagnostics/status.htm \
    controller/r76s_wireguard.lua view/r76s_wireguard/status.htm \
    model/r76s/services.lua controller/r76s_ip_policy.lua view/r76s_ip_policy/status.htm \
    htdocs/luci-static/resources/r76s/wireguard.js \
    htdocs/luci-static/resources/r76s/wireguard-status.js \
    htdocs/luci-static/resources/view/r76s_wireguard/client.js \
    root/usr/share/luci/menu.d/r76s-wireguard-client.json; do
    test -s "package/custom/luci-app-r76s-status/files/$path"
done
test -s package/custom/luci-app-r76s-updater/files/root/usr/libexec/r76s/r76s-ip-family-policy
sh -n package/custom/luci-app-r76s-updater/files/root/usr/libexec/r76s/r76s-ip-family-policy
for path in usr/libexec/r76s/r76s-ip6-guard etc/init.d/r76s-ip6-guard etc/firewall.r76s-ip6-guard; do
    test -s "package/custom/luci-app-r76s-updater/files/root/$path"
    sh -n "package/custom/luci-app-r76s-updater/files/root/$path"
done
test -s package/custom/luci-app-r76s-updater/files/root/usr/share/r76s/tencent-direct.list
test -s package/custom/luci-app-r76s-updater/files/root/etc/config/r76s_ip_policy
