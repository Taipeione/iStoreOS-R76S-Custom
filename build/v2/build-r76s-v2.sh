#!/bin/bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OPENWRT_SOURCE=${OPENWRT_SOURCE:-"$ROOT/../openwrt-25.12.6"}
BUILD_PLATFORM=${R76S_BUILD_PLATFORM:-linux/amd64}
IMAGE=${R76S_BUILDER_IMAGE:-r76s-v2-builder:amd64-r1}
WORK_VOLUME=${R76S_WORK_VOLUME:-r76s-v2-work-amd64}
OUT="$ROOT/outputs/R76S-V2.0.0"

python3 "$ROOT/build/v2/preflight.py" --repo "$ROOT" --openwrt "$OPENWRT_SOURCE"
python3 "$ROOT/scripts/r76s-import-app-rules.py" --allow-missing \
    --input-dir "$ROOT/config/rules/apps" \
    --output "$ROOT/config/rules/r76s-app-rules.json" \
    --report "$ROOT/reports/R76S-V2.0.0-app-domain-audit.md"
git -C "$ROOT" diff --check
docker info >/dev/null
mkdir -p "$OUT"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    docker build --platform "$BUILD_PLATFORM" -t "$IMAGE" -f "$ROOT/build/v2/Dockerfile" "$ROOT/build/v2"
fi
docker run --rm --platform "$BUILD_PLATFORM" \
    --env "R76S_V2_ALLOW_MISSING=${R76S_V2_ALLOW_MISSING:-0}" \
    --env "R76S_JOBS=${R76S_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 8)}" \
    --mount "type=bind,src=$ROOT,dst=/r76s-repo,readonly" \
    --mount "type=bind,src=$OPENWRT_SOURCE,dst=/openwrt-source,readonly" \
    --mount "type=volume,src=$WORK_VOLUME,dst=/work/r76s-build" \
    --mount "type=bind,src=$OUT,dst=/artifacts" \
    "$IMAGE" bash /r76s-repo/build/v2/build-inside.sh
echo "ARTIFACT_DIR=$OUT"
