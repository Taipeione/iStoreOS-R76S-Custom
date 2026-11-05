#!/bin/bash
set -Eeuo pipefail
trap 'rc=$?; echo "BUILD_RESULT=FAIL rc=$rc line=$LINENO" >&2; exit "$rc"' ERR

REPO=/r76s-repo
OPENWRT=/openwrt-source
WORK=/work/r76s-build
LOG_DIR="$WORK/logs"
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_DIR/build.log") 2>&1

BUILD_START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "BUILD_START=$BUILD_START"
test "$(git -C "$OPENWRT" rev-parse HEAD)" = 64900e756efa667774214f9c6b17c113222e01f7
mkdir -p "$WORK/source"
if [ ! -f "$WORK/source/.r76s-openwrt-source" ]; then
    rm -rf "$WORK/source"
    git clone --local "$OPENWRT" "$WORK/source"
    git -C "$WORK/source" checkout --detach 64900e756efa667774214f9c6b17c113222e01f7
    chmod -R u+rwX "$WORK/source"
    touch "$WORK/source/.r76s-openwrt-source"
fi
cd "$WORK/source"
if [ ! -f .r76s-feeds-ready ]; then
    cp "$REPO/config/feeds-v2.conf" feeds.conf.default
    ./scripts/feeds update -a
    ./scripts/feeds install -a
    touch .r76s-feeds-ready
fi

mkdir -p package/r76s
cp -a "$REPO/feeds/." package/r76s/
cp -a "$REPO/files/." .

APP_DIR="$REPO/config/rules/apps"
APP_MANIFEST="$WORK/r76s-app-rules.json"
APP_REPORT="$WORK/R76S-V2.0.0-app-domain-audit.md"
IMPORT_ARGS=(--input-dir "$APP_DIR" --output "$APP_MANIFEST" --report "$APP_REPORT")
if [ "${R76S_V2_ALLOW_MISSING:-0}" = 1 ]; then
    IMPORT_ARGS+=(--allow-missing)
fi
python3 "$REPO/scripts/r76s-import-app-rules.py" "${IMPORT_ARGS[@]}"
cp "$APP_MANIFEST" package/r76s/r76s-core/files/usr/share/r76s/r76s-app-rules.json

PW1=$(find -L package -path '*/luci-app-passwall/root/usr/share/passwall/0_default_config' -type f | sort | head -1 || true)
PW2=$(find -L package -path '*/luci-app-passwall2/root/usr/share/passwall2/0_default_config' -type f | sort | head -1 || true)
echo "PW1=$PW1"
echo "PW2=$PW2"
test -n "$PW1" -a -n "$PW2"
python3 "$REPO/scripts/r76s-generate-rules.py" \
    "$REPO/config/rules/r76s-rules.json" "$PW1" "$PW2" "$APP_MANIFEST"
python3 "$REPO/scripts/r76s-v2-rules-audit.py" \
    "$REPO/config/rules/r76s-rules.json" "$APP_MANIFEST" "$PW1" "$PW2"

cp "$REPO/config/R76S-V2.config" .config
make defconfig
make -j"${R76S_JOBS:-$(nproc)}" V=s

RELEASE="$WORK/release/R76S-V2.0.0"
mkdir -p "$RELEASE"
find bin/targets/rockchip/armv8 -maxdepth 1 -type f \
    \( -name '*nanopi-r76s*' -o -name '*friendlyarm*' \) -exec cp -a {} "$RELEASE/" \;
test -n "$(find "$RELEASE" -type f -name '*.img*' -print -quit)"
cp "$APP_REPORT" "$RELEASE/domain-rule-audit.md"
printf '%s\n' 'R76S-V2.0.0' > "$RELEASE/Version"
cat > "$RELEASE/BuildInfo.json" <<EOF
{
  "version": "R76S-V2.0.0",
  "openwrt_commit": "64900e756efa667774214f9c6b17c113222e01f7",
  "target": "rockchip/armv8",
  "device": "friendlyarm_nanopi-r76s",
  "kernel_patchver": "6.12",
  "build_started_utc": "${BUILD_START:-unknown}",
  "builder_arch": "$(uname -m)",
  "apk": true,
  "physical_test": "NOT TESTED"
}
EOF
cp "$REPO/docs/R76S-V2.0.0-TEST-PLAN.md" "$RELEASE/TestPlan.md"
printf '%s\n' 'BUILD_VALIDATION=COMPILED_ONLY; physical boot and network tests are NOT TESTED' > "$RELEASE/BUILD-VALIDATION.txt"
find "$RELEASE" -type f -not -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > "$RELEASE/SHA256SUMS"
cp "$LOG_DIR/build.log" "$RELEASE/build.log"
mkdir -p /artifacts
cp -a "$RELEASE/." /artifacts/
echo "BUILD_RESULT=PASS_COMPILE_ONLY"
