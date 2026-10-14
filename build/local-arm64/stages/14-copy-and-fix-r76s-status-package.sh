#!/usr/bin/env bash
# Original workflow step: Copy and fix R76S status package
# REVIEW REQUIRED: not yet adapted for local execution.

mkdir -p openwrt/package/custom

if [ -e openwrt/package/custom/luci-app-r76s-status ]; then
  backup="$(mktemp -d /home/builder/work/.r76s-source-backup.XXXXXX)"
  mv openwrt/package/custom/luci-app-r76s-status "$backup/source"
fi

cp -r \
  feeds/luci-app-r76s-status \
  openwrt/package/custom/

STATUS_DIR="openwrt/package/custom/luci-app-r76s-status"
STATUS_CTRL="$STATUS_DIR/files/controller/r76s_status.lua"
STATUS_VIEW="$STATUS_DIR/files/view/r76s_status/status.htm"

test -f "$STATUS_DIR/Makefile"
test -f "$STATUS_CTRL"
test -f "$STATUS_VIEW"

# Canonical source files are installed verbatim; no generated UI overlays.
cmp -s feeds/luci-app-r76s-status/files/controller/r76s_status.lua "$STATUS_CTRL"
cmp -s feeds/luci-app-r76s-status/files/view/r76s_status/status.htm "$STATUS_VIEW"
echo 'R76S_STATUS_CANONICAL_SOURCE=PASS'

cp -a "${R76S_REPO_ROOT:-/r76s-repo}/feeds/r76s-core" openwrt/package/custom/
