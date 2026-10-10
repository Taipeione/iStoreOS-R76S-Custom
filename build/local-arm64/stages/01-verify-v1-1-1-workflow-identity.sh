#!/usr/bin/env bash
set -euo pipefail
echo "===== R76S V1.2 local build identity ====="
test -s config/R76S.config
test -s files/etc/uci-defaults/99-r76s-v2-defaults
test -s feeds/luci-app-r76s-status/Makefile
test -s feeds/luci-app-r76s-updater/Makefile
python3 scripts/r76s-v111-prebuild-tests.py
python3 scripts/r76s-v111-passwall-groups.py --self-test
echo "BASELINE_SOURCE_CHECK=PASS"
