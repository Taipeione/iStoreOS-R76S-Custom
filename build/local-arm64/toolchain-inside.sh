#!/usr/bin/env bash
set -euo pipefail
cd /home/builder/work/openwrt

BASE_COMMIT=fb971407ffd9a094e6f16d9c029f1f580ed5c2ad
ACTUAL_COMMIT="$(git rev-parse HEAD)"
test "$BASE_COMMIT" = "$ACTUAL_COMMIT" || {
  echo "BASE_SOURCE_DRIFT=$ACTUAL_COMMIT expected $BASE_COMMIT" >&2; exit 1;
}

test -d feeds/packages || { echo 'OFFICIAL_FEEDS_MISSING' >&2; exit 1; }
test -s /r76s-repo/config/R76S.config
mkdir -p ../logs

# Save current test config; V1.2 staging re-imports the real configuration.
if [ -f .config ]; then
  cp -p .config ../config.before-toolchain-test
fi
cp /r76s-repo/config/R76S.config .config
make defconfig 2>&1 | tee ../logs/r76s-defconfig-toolchain.log

grep -qxF 'CONFIG_TARGET_rockchip_armv8_DEVICE_friendlyarm_nanopi-r76s=y' .config || {
  echo 'R76S_TARGET_DROPPED_BY_DEFCONFIG' >&2; exit 1;
}

echo '===== TARGET VERIFIED; COMPILE CROSS TOOLCHAIN ====='
ccache -M 5G || true
set +e
make -j"${R76S_JOBS:-4}" toolchain/install V=0 2>&1 | tee ../logs/r76s-toolchain-arm64.log
result=${PIPESTATUS[0]}
set -e
printf 'TOOLCHAIN_EXIT=%s\n' "$result"
if [ "$result" -ne 0 ]; then
    echo 'TOOLCHAIN=FAIL: see /home/builder/work/logs/r76s-toolchain-arm64.log' >&2
    exit "$result"
fi
# We only claim full toolchain compatibility after make actually succeeds.
echo 'R76S_ARM64_TOOLCHAIN=PASS'
