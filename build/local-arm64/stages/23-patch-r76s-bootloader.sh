#!/usr/bin/env bash
set -euo pipefail
# R76S_V12_CANDIDATE_LOCAL_BUILD_GUARD_20261010
# Original workflow step: Patch R76S bootloader
# REVIEW REQUIRED: not yet adapted for local execution.

RAW_IMAGE="${R76S_LOCAL_TMP:-/tmp}/R76S-V1.2.img"
STRIPPED_IMAGE="${R76S_LOCAL_TMP:-/tmp}/R76S-V1.2-stripped.img.gz"
SYSUPGRADE_META="${R76S_LOCAL_TMP:-/tmp}/R76S-V1.2.sysupgrade.meta"
FWTOOL="$GITHUB_WORKSPACE/openwrt/staging_dir/host/bin/fwtool"

test -x "$FWTOOL"
cp -f "$CUSTOM_IMAGE" "$STRIPPED_IMAGE"

echo "===== Preserve and strip OpenWrt sysupgrade metadata ====="
rm -f "$SYSUPGRADE_META" ${R76S_LOCAL_TMP:-/tmp}/r76s-build.ucert
"$FWTOOL" -s ${R76S_LOCAL_TMP:-/tmp}/r76s-build.ucert -t "$STRIPPED_IMAGE" >/dev/null 2>&1 || true
"$FWTOOL" -i "$SYSUPGRADE_META" -t "$STRIPPED_IMAGE"
test -s "$SYSUPGRADE_META"

python3 - "$SYSUPGRADE_META" <<'PY_META'
import json, sys
p=sys.argv[1]
with open(p, 'r', encoding='utf-8') as f: meta=json.load(f)
if 'friendlyarm,nanopi-r76s' not in meta.get('supported_devices', []):
    raise SystemExit('ERROR: source sysupgrade metadata lacks friendlyarm,nanopi-r76s')
meta['metadata_version']='1.1'
meta['compat_version']=meta.get('compat_version','1.0')
v=meta.setdefault('version',{})
v.update({'dist':'iStoreOS','version':'24.10.8','revision':'V1.2','target':'rockchip/armv8','board':'friendlyarm,nanopi-r76s'})
with open(p,'w',encoding='utf-8') as f:
    json.dump(meta,f,ensure_ascii=False,separators=(',',':')); f.write('\n')
PY_META
cat "$SYSUPGRADE_META"

gzip -t "$STRIPPED_IMAGE"
echo "===== Decompress stripped custom image ====="
gzip -dc "$STRIPPED_IMAGE" > "$RAW_IMAGE"
test -s "$RAW_IMAGE"
echo "SYSUPGRADE_META=$SYSUPGRADE_META" >> "$GITHUB_ENV"
echo "FWTOOL=$FWTOOL" >> "$GITHUB_ENV"

echo
echo "===== Preserve first 32KB hash ====="

FIRST32_BEFORE=$(
  dd \
    if="$RAW_IMAGE" \
    bs=512 \
    count=64 \
    status=none \
    | md5sum \
    | awk '{print $1}'
)

echo "First 32KB before: $FIRST32_BEFORE"

echo
echo "===== Current custom bootloader ====="

CUSTOM_BOOT_BEFORE=$(
  dd \
    if="$RAW_IMAGE" \
    bs=512 \
    skip=64 \
    count=32704 \
    status=none \
    | md5sum \
    | awk '{print $1}'
)

echo "Custom bootloader before: $CUSTOM_BOOT_BEFORE"

echo
echo "===== Patch official bootloader into custom image ====="

dd \
  if="$BOOT_BIN" \
  of="$RAW_IMAGE" \
  bs=512 \
  seek=64 \
  count=32704 \
  conv=notrunc,fsync \
  status=progress

sync

echo
echo "===== Verify bootloader after patch ====="

PATCHED_BOOT=$(
  dd \
    if="$RAW_IMAGE" \
    bs=512 \
    skip=64 \
    count=32704 \
    status=none \
    | md5sum \
    | awk '{print $1}'
)

echo "Patched bootloader: $PATCHED_BOOT"
echo "Expected bootloader: $BOOT_MD5"

if [ "$PATCHED_BOOT" != "$BOOT_MD5" ]; then
  echo "ERROR: Bootloader patch verification failed."
  exit 1
fi
echo
echo "===== Verify first 32KB was NOT modified ====="

FIRST32_AFTER=$(
  dd \
    if="$RAW_IMAGE" \
    bs=512 \
    count=64 \
    status=none \
    | md5sum \
    | awk '{print $1}'
)

echo "First 32KB before: $FIRST32_BEFORE"
echo "First 32KB after:  $FIRST32_AFTER"

if [ "$FIRST32_BEFORE" != "$FIRST32_AFTER" ]; then
  echo "ERROR: Partition table area was modified."
  exit 1
fi
echo
echo "===== Partition table ====="

fdisk -l "$RAW_IMAGE"

echo "RAW_IMAGE=$RAW_IMAGE" >> "$GITHUB_ENV"
