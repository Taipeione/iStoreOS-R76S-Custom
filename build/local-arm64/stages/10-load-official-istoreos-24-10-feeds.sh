#!/usr/bin/env bash
# Original workflow step: Load official iStoreOS 24.10 feeds
# REVIEW REQUIRED: not yet adapted for local execution.

cd openwrt

if [ ! -s feeds.conf ]; then
  curl -fL --retry 3 --retry-delay 3 \
    https://fw.koolcenter.com/iStoreOS/r76s/24.10-feeds.conf -o feeds.conf
fi

test -s feeds.conf

echo "===== feeds.conf ====="
cat feeds.conf
