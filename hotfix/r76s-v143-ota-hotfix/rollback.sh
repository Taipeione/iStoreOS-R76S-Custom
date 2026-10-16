#!/bin/sh
set -eu

TARGET=/usr/libexec/r76s/r76s-ota
BACKUP_ROOT=/root/r76s-v143-ota-hotfix-backup

fail() { echo "OTA hotfix rollback refused: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || fail "must run as root"
[ -r "$BACKUP_ROOT/current" ] || fail "no recorded backup"
BACKUP=$(cat "$BACKUP_ROOT/current")
[ -f "$BACKUP/r76s-ota" ] || fail "backup missing: $BACKUP/r76s-ota"

TMP="$TARGET.rollback.$$"
trap 'rm -f "$TMP"' EXIT HUP INT TERM
cp -p "$BACKUP/r76s-ota" "$TMP"
chmod 0700 "$TMP"
mv "$TMP" "$TARGET"
trap - EXIT HUP INT TERM

if command -v lua >/dev/null 2>&1; then
    lua -e "assert(loadfile('$TARGET'))"
elif command -v luac >/dev/null 2>&1; then
    luac -p "$TARGET"
else
    fail "Lua interpreter unavailable; rollback validation failed"
fi
echo "OTA hotfix rollback complete: $BACKUP"
