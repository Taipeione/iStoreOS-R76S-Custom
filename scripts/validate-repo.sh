#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

WF='.github/workflows/r76s-v2.2.4.yml'
CFG='config/R76S.config'
DEF='files/etc/uci-defaults/99-r76s-v2-defaults'
UP='feeds/luci-app-r76s-updater/files/root/usr/libexec/r76s/r76s-component-updater'
POL='feeds/luci-app-r76s-updater/files/root/usr/libexec/r76s/r76s-smartdns-policy'
MK='feeds/luci-app-r76s-updater/Makefile'
CTL='feeds/luci-app-r76s-updater/files/controller/r76s_updater.lua'
VIEW='feeds/luci-app-r76s-updater/files/view/r76s_updater/index.htm'

test -s "$WF"; test -s "$CFG"; test -s "$DEF"; test -s "$UP"; test -s "$POL"
sh -n "$DEF"
sh -n "$UP"
sh -n "$POL"
sh -n feeds/luci-app-r76s-updater/files/root/usr/libexec/r76s/r76s-uu-autostart
sh -n feeds/luci-app-r76s-updater/files/root/usr/libexec/r76s/smartdns-wrapper
sh -n feeds/luci-app-r76s-updater/files/root/etc/init.d/r76s-fix3-boot
sh -n feeds/luci-app-r76s-updater/files/root/etc/init.d/r76s-uu-autostart

RULES="$(grep -c "='shunt_rules'" "$DEF")"
[ "$RULES" -eq 42 ] || { echo "FAIL: expected 42 shunt rules, found $RULES"; exit 1; }

grep -qF "uuplugin.@uuplugin[0].enabled='0'" "$DEF"
grep -qF "dualstack_ip_selection='0'" "$POL"
grep -qF "force_aaaa_soa='0'" "$POL"
grep -qF "uci -q delete smartdns.@smartdns[0].conf_files || true" "$POL"
grep -qF "UU_URL='https://router.uu.163.com/api/plugin?type=openwrt-aarch64'" "$UP"
grep -qF '/etc/config/uuplugin' "$UP"
! grep -qF '/etc/config/uugamebooster' "$UP"
grep -qF '$(INSTALL_BIN)' "$MK"
grep -qF 'PKG_RELEASE:=3' "$MK"
! grep -qF 'S99r76s-uu-autostart' "$MK"
grep -qF 'R76S_UPDATER_UI_PATCH=3' "$CTL"
grep -qF 'R76S_UPDATER_UI_PATCH=3' "$VIEW"
grep -qF 'CONFIG_PACKAGE_luci-app-r76s-updater=y' "$CFG"
grep -qF 'CONFIG_PACKAGE_quickstart=y' "$CFG"
grep -qF 'CONFIG_PACKAGE_luci-app-quickstart=y' "$CFG"
grep -qF 'CONFIG_PACKAGE_luci-i18n-quickstart-zh-cn=y' "$CFG"
grep -qF 'https://github.com/linkease/nas-packages.git' "$WF"
grep -qF 'https://github.com/linkease/nas-packages-luci.git' "$WF"
grep -qF '24.10.8-V2.2.4' "$WF"
grep -qF 'friendlyarm,nanopi-r76s' "$WF"
grep -qF 'github.com/${GITHUB_REPOSITORY}/releases/latest/download' "$WF"

if grep -RnsE 'sysupgrade|dd[[:space:]].*of=/dev/|mmcblk[0-9]|partx[[:space:]]|fdisk[[:space:]]|sfdisk[[:space:]]|blkdiscard' \
  feeds/luci-app-r76s-updater/files/root >/tmp/r76s-forbidden.$$; then
  cat /tmp/r76s-forbidden.$$
  rm -f /tmp/r76s-forbidden.$$
  echo 'FAIL: forbidden firmware/block operation in component updater package.'
  exit 1
fi
rm -f /tmp/r76s-forbidden.$$ 2>/dev/null || true

echo 'PASS: R76S V2.2.4 latest recovery repository static validation succeeded.'
