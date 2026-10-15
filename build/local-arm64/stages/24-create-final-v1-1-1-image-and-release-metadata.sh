#!/usr/bin/env bash
set -euo pipefail
# R76S_V12_CANDIDATE_LOCAL_BUILD_GUARD_20261010
# Original workflow step: Create final v1.2 image and release metadata
# REVIEW REQUIRED: not yet adapted for local execution.

TARGET_DIR="$(realpath "$TARGET_DIR")"
RELEASE_DIR="$TARGET_DIR/R76S-V1.4.1"

FINAL_NAME="R76S-V1.4.1-TF-squashfs.img.gz"
FINAL_IMAGE="$RELEASE_DIR/$FINAL_NAME"

mkdir -p "$RELEASE_DIR"

echo "===== Compress final patched image ====="

pigz -9 -c \
  "$RAW_IMAGE" \
  > "$FINAL_IMAGE"

# Verify gzip payload BEFORE appending fwtool metadata.
gzip -t "$FINAL_IMAGE"

echo
echo "===== Restore OpenWrt sysupgrade metadata ====="
test -x "$FWTOOL"
test -s "$SYSUPGRADE_META"
"$FWTOOL" -I "$SYSUPGRADE_META" "$FINAL_IMAGE"
FINAL_RAW="$RELEASE_DIR/R76S-V1.4.1-TF-squashfs.img"
cp "$RAW_IMAGE" "$FINAL_RAW"
"$FWTOOL" -I "$SYSUPGRADE_META" "$FINAL_RAW"

FINAL_META_CHECK="${R76S_LOCAL_TMP:-/tmp}/R76S-V1.4.1.final.meta"
rm -f "$FINAL_META_CHECK"
"$FWTOOL" -i "$FINAL_META_CHECK" "$FINAL_IMAGE"
test -s "$FINAL_META_CHECK"
python3 - "$FINAL_META_CHECK" <<'PY_FINAL_META'
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as f: meta=json.load(f)
if 'friendlyarm,nanopi-r76s' not in meta.get('supported_devices', []):
    raise SystemExit('ERROR: final metadata lacks R76S support')
v=meta.get('version',{})
exp={'dist':'iStoreOS','version':'24.10.8','revision':'R76S-V1.4.1','target':'rockchip/armv8'}
for k,val in exp.items():
    if v.get(k) != val: raise SystemExit(f'ERROR: metadata {k}={v.get(k)!r}, expected {val!r}')
PY_FINAL_META
cat "$FINAL_META_CHECK"

echo
echo "===== SHA256 ====="

cd "$RELEASE_DIR"

FINAL_SHA="$(
  sha256sum "$FINAL_NAME" | awk '{print $1}'
)"

printf '%s  %s\n' \
  "$FINAL_SHA" \
  "$FINAL_NAME" \
  | tee sha256sums

# iStoreOS luci-app-ota reads version.latest/version.index from the
# device-specific OTA_URL_BASE. Our ota.sh points that base to this
# repository's latest GitHub Release assets.
cat > version.latest <<EOF
[24.10.8-R76S-V1.4.1]($FINAL_NAME)
R76S-V1.4.1 / RK3576 / TF
SHA256: $FINAL_SHA
EOF

cat > version.index <<'EOF'
24.10.8-R76S-V1.4.1
EOF

cat > ota.footer.html <<'EOF'
<p>R76S-V1.4.1: TF-first / eMMC-fallback boot policy. Online upgrade preserves configuration by default.</p>
EOF

# R76S_V12_BUILD_STAGE_FIX_20261010: no comments inside backslash-continued printf arguments.
printf '%s\n' \
  'R76S-V1.4.1 / PassWall2 / PassWall' \
  '' \
  'Target:' \
  'rockchip/armv8' \
  '' \
  'Device:' \
  'FriendlyElec NanoPi R76S' \
  '' \
  'SoC:' \
  'Rockchip RK3576' \
  '' \
  'Bootloader source:' \
  'iStoreOS 24.10.8-2026073111 R76S' \
  '' \
  'Patched range:' \
  '32KB - 16MB' \
  '' \
  "Bootloader MD5: $BOOT_MD5" \
  '' \
  'The first 32KB of the custom image is preserved.' \
  '' \
  'v1.2 features:' \
  'LAN: 192.168.50.1/24' \
  'WAN clean default: DHCP client' \
  'DHCP/DNS: dnsmasq uses WAN DNS without forced SmartDNS/AdGuard chain' \
  'LuCI theme: Argon' \
  "System login: $(if [ "${R76S_PUBLIC_RELEASE:-0}" = 1 ]; then echo 'clean flash default root password: password; OTA preserves existing credentials'; else echo 'PRIVATE image includes build-supplied root hash; DO NOT PUBLISH'; fi)" \
  'PassWall: installed, clean default disabled, user settings persist' \
  'PassWall2: installed, clean default disabled, user settings persist' \
  'SmartDNS: bundled Release48.4 runtime, clean default disabled/user-controlled' \
  'AdGuard Home: installed, clean default disabled and not preconfigured by R76S custom scripts' \
  'Enabled services keep normal init/procd state across reboot/power loss' \
  'Online firmware upgrade: preserves existing configuration by default' \
  'Online-upgrade fixes: async download state + PARTUUID boot safety + centered UI' \
  'R76S status fixes: SmartDNS/PassWall/PassWall2/AdGuard runtime state + memory units' \
  'Xray core: pinned to 26.7.28 for Go 1.26 compatibility' \
  'PassWall transparent proxy: nftables' \
  'PassWall cores: Xray + Sing-box' \
  'QuickStart: official iStoreOS UI unchanged' \
  'UU accelerator: not included' \
  'Firmware online upgrade: GitHub Releases latest/download' \
  'Component online update: PassWall + PassWall2 + SmartDNS + AdGuard Home without forced DNS reset' \
  'Boot policy: TF-first / eMMC fallback' \
  > BOOTLOADER_INFO.txt

echo
echo "===== Final image and release metadata ====="

ls -lh \
  "$FINAL_NAME" \
  sha256sums \
  version.latest \
  version.index \
  ota.footer.html \
  BOOTLOADER_INFO.txt

python3 /r76s-repo/build/local-arm64/release-assets.py \
  --release "$RELEASE_DIR" --target "$TARGET_DIR" \
  --repository "$GITHUB_REPOSITORY" --commit "$GITHUB_SHA"
