#!/usr/bin/env bash
set -euo pipefail
cd openwrt
# Use the reviewed complete official feed snapshot rather than a moving URL.
PINNED=/r76s-repo/config/feeds.conf
test -s "$PINNED"
if [ -e feeds.conf ] && ! cmp -s "$PINNED" feeds.conf; then
  mkdir -p ../logs/v12-source-registration
  cp -p feeds.conf "../logs/v12-source-registration/feeds-before-pin-$(date -u +%Y%m%dT%H%M%S)-$$.conf"
fi
cp "$PINNED" feeds.conf
cmp -s "$PINNED" feeds.conf
cat feeds.conf
