#!/bin/sh
set -eu

TARGET=/usr/libexec/r76s/r76s-ota
BACKUP_ROOT=/root/r76s-v143-ota-hotfix-backup
EXPECTED_REVISION=R76S-V1.4.3
EXPECTED_SHA256=684e80f5ac274ef732d726eb19b3691bb6c83a645250febe4212c3d698943666

fail() { echo "OTA hotfix refused: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || fail "must run as root"
[ -r /etc/openwrt_release ] || fail "missing /etc/openwrt_release"
REVISION=$(sed -n "s/^DISTRIB_REVISION=['\"]\([^'\"]*\)['\"].*/\1/p" /etc/openwrt_release)
[ "$REVISION" = "$EXPECTED_REVISION" ] || fail "expected $EXPECTED_REVISION, found ${REVISION:-unknown}"
[ -f "$TARGET" ] || fail "missing $TARGET"

if command -v sha256sum >/dev/null 2>&1; then
    CURRENT_SHA=$(sha256sum "$TARGET" | awk '{print $1}')
else
    CURRENT_SHA=$(busybox sha256sum "$TARGET" | awk '{print $1}')
fi
[ "$CURRENT_SHA" = "$EXPECTED_SHA256" ] || fail "unexpected OTA client hash; refusing to overwrite"

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP="$BACKUP_ROOT/$STAMP"
mkdir -p "$BACKUP"
cp -p "$TARGET" "$BACKUP/r76s-ota"
printf '%s\n' "$CURRENT_SHA" > "$BACKUP/original.sha256"
printf '%s\n' "$BACKUP" > "$BACKUP_ROOT/current"

TMP="$TARGET.hotfix.$$"
trap 'rm -f "$TMP"' EXIT HUP INT TERM
sed \
  -e "s#return 'R76S-V1.4.3'#return 'R76S-stable'#" \
  -e "s#V1.4.3 只支持正式稳定 OTA 通道#只支持正式稳定 OTA 通道#" \
  -e "s#assert(m.version==release_tag(channel),'OTA 版本不是正式 V1.4.3')#assert(revision(m.version or ''),'OTA metadata 未提供有效版本')#" \
  -e "s#release='R76S-V1.4.3'#release='stable'#" \
  "$TARGET" > "$TMP"

grep -q "return 'R76S-stable'" "$TMP" || fail "stable channel replacement missing"
grep -q "OTA metadata 未提供有效版本" "$TMP" || fail "version validation replacement missing"
grep -q "releases/download/" "$TMP" || fail "release URL logic missing"
! grep -q "return 'R76S-V1.4.3'" "$TMP" || fail "old release pin remains"
chmod 0700 "$TMP"
if command -v lua >/dev/null 2>&1; then
    lua -e "assert(loadfile('$TMP'))" || fail "Lua syntax check failed"
elif command -v luac >/dev/null 2>&1; then
    luac -p "$TMP" || fail "Lua syntax check failed"
else
    fail "Lua interpreter unavailable; no patch applied"
fi
mv "$TMP" "$TARGET"
trap - EXIT HUP INT TERM

echo "OTA hotfix applied: stable metadata uses R76S-stable"
echo "Backup: $BACKUP"
echo "No firmware download or sysupgrade was performed."
