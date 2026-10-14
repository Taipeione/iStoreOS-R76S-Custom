#!/usr/bin/env bash
# Original workflow step: Stage V1.1.1 component updater and SmartDNS Release48.4 runtime
# REVIEW REQUIRED: not yet adapted for local execution.

mkdir -p openwrt/package/custom

if [ -e openwrt/package/custom/luci-app-r76s-updater ]; then
  backup="$(mktemp -d /home/builder/work/.r76s-source-backup.XXXXXX)"
  mv openwrt/package/custom/luci-app-r76s-updater "$backup/source"
fi
cp -r feeds/luci-app-r76s-updater openwrt/package/custom/

UPDATER_DIR="openwrt/package/custom/luci-app-r76s-updater"
SMARTDNS_TAG="Release48.4"
SMARTDNS_ASSET="smartdns.1.2026.08.05-0921.aarch64-linux-all.tar.gz"
SMARTDNS_URL="https://github.com/pymumu/smartdns/releases/download/${SMARTDNS_TAG}/${SMARTDNS_ASSET}"

echo "===== SmartDNS ${SMARTDNS_TAG} official asset ====="
echo "SmartDNS asset: $SMARTDNS_URL"

rm -f /tmp/smartdns-aarch64.tar.gz

curl -fL --retry 5 --retry-delay 3 --retry-all-errors "$SMARTDNS_URL" -o /tmp/smartdns-aarch64.tar.gz

test -s /tmp/smartdns-aarch64.tar.gz
printf '%s  %s\n' d769cff42af9b8e76823aca130ddfd174cf24cbe56f702bc95f1ef20eb5fcf02 /tmp/smartdns-aarch64.tar.gz | sha256sum -c -
gzip -t /tmp/smartdns-aarch64.tar.gz

echo "SmartDNS archive SHA256:"
sha256sum /tmp/smartdns-aarch64.tar.gz

SMARTDNS_EXTRACT="$(mktemp -d /tmp/r76s-smartdns-extract.XXXXXX)"
tar -xzf /tmp/smartdns-aarch64.tar.gz -C "$SMARTDNS_EXTRACT"

# Select the real ARM64 ELF executable, not /etc/default/smartdns.
SMARTDNS_BIN=""
while IFS= read -r -d '' candidate; do
  if file -b "$candidate" | grep -Eqi "^ELF.*(aarch64|ARM64)"; then
    SMARTDNS_BIN="$candidate"
    break
  fi
done < <(find "$SMARTDNS_EXTRACT" -type f -name smartdns -print0)

if [ -z "$SMARTDNS_BIN" ]; then
  echo "ERROR: No AArch64 ELF SmartDNS executable found."
  find "$SMARTDNS_EXTRACT" -type f -name smartdns -exec file {} +
  exit 1
fi

echo "SMARTDNS_AARCH64_BINARY=$SMARTDNS_BIN"
file "$SMARTDNS_BIN"

install -m 0755 \
  "$SMARTDNS_BIN" \
  "$UPDATER_DIR/files/root/usr/libexec/r76s/smartdns.bin"

CTRL="$UPDATER_DIR/files/controller/r76s_updater.lua"
VIEW="$UPDATER_DIR/files/view/r76s_updater/index.htm"
PRESERVE_HELPER="$UPDATER_DIR/files/root/usr/libexec/r76s/r76s-ota-preserve-state"

for required in \
  "$UPDATER_DIR/Makefile" \
  "$CTRL" \
  "$VIEW" \
  "$UPDATER_DIR/files/root/usr/libexec/r76s/r76s-component-updater" \
  "$UPDATER_DIR/files/root/usr/libexec/r76s/smartdns.bin"; do
  test -s "$required"
done

echo "===== V1.1.1: remove automatic DNS takeover from component package ====="

echo "===== V1.1.1: install online-upgrade service state capture helper ====="

# Use the repository helper for every stage, including the first package build.
test -x files/usr/libexec/r76s/r76s-ota-preserve-state || exit 1
install -m 0755 files/usr/libexec/r76s/r76s-ota-preserve-state "$PRESERVE_HELPER" || exit 1
mkdir -p openwrt/files/etc/config
if [ ! -e openwrt/files/etc/config/r76s_ota_state ]; then
  install -m 0644 files/etc/config/r76s_ota_state openwrt/files/etc/config/r76s_ota_state || exit 1
fi

echo "===== Stage online-upgrade preserve helper into final image overlay ====="
mkdir -p openwrt/files/usr/libexec/r76s
install -m 0755 "$PRESERVE_HELPER" openwrt/files/usr/libexec/r76s/r76s-ota-preserve-state
test -x openwrt/files/usr/libexec/r76s/r76s-ota-preserve-state
grep -qF 'r76s_ota_state.state.pending' openwrt/files/usr/libexec/r76s/r76s-ota-preserve-state
echo "Online-upgrade preserve helper final-image overlay staged."

echo "===== V1.1.1: patch firmware online-upgrade controller ====="

python3 - "$CTRL" <<'PY_OTA_PATCH'
from pathlib import Path
import sys

p = Path(sys.argv[1])
t = p.read_text()

import re

t, marker_count = re.subn(
    r'-- R76S_UPDATER_UI_PATCH=\d+',
    '-- R76S_UPDATER_UI_PATCH=6',
    t,
    count=1,
)
if marker_count != 1:
    raise SystemExit('ERROR: updater UI patch marker not found')

old_return = '    return rc, trim(out)'
new_return = "\n".join([
    '    -- /bin/ota download starts an asynchronous curl job. Some builds',
    '    -- return a non-zero launcher rc even though the download is alive.',
    '    if cmd:find("/bin/ota download", 1, true) and rc ~= 0 then',
    '        sys.call("sleep 1")',
    '        local active = fs.access("/tmp/firmware.img.part")',
    '            or sys.call("pgrep -f \'[/]bin/ota\' >/dev/null 2>&1") == 0',
    '            or sys.call("pgrep -f \'[c]url.*firmware.img\' >/dev/null 2>&1") == 0',
    '        if active then',
    '            rc = 0',
    '            if trim(out) == "" then',
    '                out = "下载任务已启动"',
    '            end',
    '        end',
    '    end',
    '    return rc, trim(out)',
])
if old_return not in t:
    raise SystemExit('ERROR: run_with_rc return anchor not found in updater controller')
t = t.replace(old_return, new_return, 1)

old_download = "\n".join([
    '    elseif progress_exists then',
    '        state = "failed"',
    '        message = trim(progress_text:match("([^\\r\\n]+)%s*$") or "下载失败")',
])
new_download = "\n".join([
    '    elseif progress_exists and (',
    '        sys.call("pgrep -f \'[/]bin/ota\' >/dev/null 2>&1") == 0',
    '        or sys.call("pgrep -f \'[c]url.*firmware.img\' >/dev/null 2>&1") == 0',
    '    ) then',
    '        state = "downloading"',
    '        message = "正在下载"',
    '    elseif progress_exists then',
    '        state = "failed"',
    '        message = trim(progress_text:match("([^\\r\\n]+)%s*$") or "下载失败")',
])
if old_download not in t:
    raise SystemExit('ERROR: download_info progress anchor not found in updater controller')
t = t.replace(old_download, new_download, 1)

old_safe = '    local safe = (dev == "mmcblk0" or dev == "mmcblk2") and romdev:find("/dev/" .. dev, 1, true) == 1'
new_safe = "\n".join([
    '    -- /rom can be /dev/root; resolve root=PARTUUID through blkid first.',
    '    local resolved_root = romdev',
    '    if romdev == "/dev/root" or romdev == "rootfs" then',
    '        local cmdline = readfile("/proc/cmdline")',
    '        local partuuid = cmdline:match("root=PARTUUID=([%w%-]+)")',
    '        if partuuid and partuuid ~= "" then',
    '            resolved_root = trim(sys.exec(',
    '                "blkid 2>/dev/null | grep -i \'PARTUUID=\\\"" .. partuuid .. "\\\"\' | head -n1 | cut -d: -f1"',
    '            ))',
    '        end',
    '    end',
    '',
    '    local allowed = (dev == "mmcblk0" or dev == "mmcblk2")',
    '    local expected = dev ~= "" and ("/dev/" .. dev) or ""',
    '    local safe = allowed and expected ~= "" and (',
    '        romdev:find(expected, 1, true) == 1',
    '        or (resolved_root ~= "" and resolved_root:find(expected, 1, true) == 1)',
    '    )',
])
if old_safe not in t:
    raise SystemExit('ERROR: boot_info safety anchor not found in updater controller')
t = t.replace(old_safe, new_safe, 1)

install_old = 'sys.call("(sleep 2; /sbin/sysupgrade " .. FIRMWARE .. " >/tmp/r76s-sysupgrade.log 2>&1) >/dev/null 2>&1 &")'
install_new = 'sys.call("(sleep 2; /usr/libexec/r76s/r76s-ota-preserve-state && /sbin/sysupgrade " .. FIRMWARE .. " >/tmp/r76s-sysupgrade.log 2>&1) >/dev/null 2>&1 &")'
if install_old in t:
    t = t.replace(install_old, install_new, 1)
elif 'local preserve_rc = sys.call(' not in t and '/usr/libexec/r76s/r76s-ota-preserve-state && /sbin/sysupgrade ' not in t:
    raise SystemExit('ERROR: online-upgrade install call anchor not found')

if '/sbin/sysupgrade -n' in t or 'sysupgrade -n' in t:
    raise SystemExit('ERROR: updater would erase settings by default (sysupgrade -n found)')
if 'local preserve_rc = sys.call(' not in t and '/usr/libexec/r76s/r76s-ota-preserve-state && /sbin/sysupgrade " .. FIRMWARE' not in t:
    raise SystemExit('ERROR: online-upgrade preserve-state helper is not chained before sysupgrade')

verify_anchor = 'local verified = verify_image()'
verify_fail_anchor = 'if not verified.ok then'
install_anchor = 'local launch_rc = sys.call(' if 'local launch_rc = sys.call(' in t else '/usr/libexec/r76s/r76s-ota-preserve-state && /sbin/sysupgrade " .. FIRMWARE'

if verify_anchor not in t or verify_fail_anchor not in t:
    raise SystemExit('ERROR: online-upgrade install path does not re-run verify_image() before flashing')

if t.find(verify_anchor) > t.find(install_anchor):
    raise SystemExit('ERROR: online-upgrade verify_image() occurs after sysupgrade install call')

p.write_text(t)
PY_OTA_PATCH

echo "===== V1.1.1: install full online-upgrade UI with additive-upgrade status ====="

# OTA view is installed directly from its canonical package source.
test -s "$VIEW"
grep -qF 'R76S_UPDATER_UI_PATCH=7' "$VIEW"


grep -qF 'R76S_UPDATER_UI_PATCH=6' "$CTRL"
grep -qF 'root=PARTUUID' "$CTRL"
grep -qF 'firmware.img.part' "$CTRL"
grep -qF '下载任务已启动' "$CTRL"
grep -qF 'R76S_V110_LAYOUT' "$VIEW"
grep -qF '保留用户配置 + 增量补齐新版本内容' "$VIEW"
grep -qF 'id="r76s-metadata"' "$VIEW"
grep -qF 'id="r76s-boot-safe"' "$VIEW"
grep -qF '在线升级并保留配置' "$VIEW"
grep -qF "downloadBtn.disabled = true" "$VIEW"
grep -qF 'r76s-ota-preserve-state' "$CTRL"
test -x "$PRESERVE_HELPER"
grep -qF 'r76s_ota_state.state.pending' "$PRESERVE_HELPER"
! grep -qF 'sysupgrade -n' "$CTRL"

if grep -RnsE --exclude='r76s-ota-preserve-state' \
  'sysupgrade|dd[[:space:]].*of=/dev/|mmcblk[0-9]|partx[[:space:]]|fdisk[[:space:]]|sfdisk[[:space:]]|blkdiscard' \
  "$UPDATER_DIR/files/root"; then
  echo "ERROR: forbidden firmware/block-device operation in component updater."
  exit 1
fi

PKG_MK="$UPDATER_DIR/Makefile"
grep -qF '$(INSTALL_BIN)' "$PKG_MK"
