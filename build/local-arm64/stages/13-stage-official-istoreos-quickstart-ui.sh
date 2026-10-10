#!/usr/bin/env bash
# Original workflow step: Stage official iStoreOS QuickStart UI
# REVIEW REQUIRED: not yet adapted for local execution.

cd openwrt

echo "===== Stage official iStoreOS QuickStart ====="

# Use the official LinkEase/iStoreOS release sources directly.
# Do not use the refactoring-only istoreos/quickstart repository;
# its own README points release builds to these two package trees.
rm -rf \
  /tmp/r76s-nas-packages \
  /tmp/r76s-nas-packages-luci \
  package/custom/quickstart \
  package/custom/luci-app-quickstart

git clone \
  --depth=1 \
  --filter=blob:none \
  --sparse \
  --branch master \
  https://github.com/linkease/nas-packages.git \
  /tmp/r76s-nas-packages

git -C /tmp/r76s-nas-packages sparse-checkout set \
  network/services/quickstart

git clone \
  --depth=1 \
  --filter=blob:none \
  --sparse \
  --branch main \
  https://github.com/linkease/nas-packages-luci.git \
  /tmp/r76s-nas-packages-luci

git -C /tmp/r76s-nas-packages-luci sparse-checkout set \
  luci/luci-app-quickstart

mkdir -p package/custom

cp -a \
  /tmp/r76s-nas-packages/network/services/quickstart \
  package/custom/quickstart

cp -a \
  /tmp/r76s-nas-packages-luci/luci/luci-app-quickstart \
  package/custom/luci-app-quickstart

test -f package/custom/quickstart/Makefile
test -f package/custom/luci-app-quickstart/Makefile

grep -q '^PKG_NAME:=quickstart$' \
  package/custom/quickstart/Makefile
grep -q 'LUCI_DEPENDS:=+quickstart +luci-app-store' \
  package/custom/luci-app-quickstart/Makefile

echo "===== Official QuickStart package versions ====="
grep -E '^(PKG_NAME|PKG_VERSION|PKG_RELEASE):=' \
  package/custom/quickstart/Makefile || true
grep -E '^(PKG_VERSION|PKG_RELEASE):=' \
  package/custom/luci-app-quickstart/Makefile || true

echo "Official iStoreOS QuickStart sources staged."
