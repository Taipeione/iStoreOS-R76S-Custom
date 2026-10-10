#!/usr/bin/env bash
set -euo pipefail
if [ ! -d openwrt/.git ]; then
    test ! -e openwrt || { echo 'ERROR: openwrt path exists but is not a Git clone'; exit 1; }
    git clone --depth=1 --branch istoreos-24.10 https://github.com/istoreos/istoreos.git openwrt
fi
actual=$(git -C openwrt rev-parse HEAD)
expected=fb971407ffd9a094e6f16d9c029f1f580ed5c2ad
[ "$actual" = "$expected" ] || { echo "ERROR: source drift: $actual != $expected"; exit 1; }
echo "ISTOREOS_BASE_COMMIT=$actual"
