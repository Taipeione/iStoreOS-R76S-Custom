#!/usr/bin/env bash
set -euo pipefail
# Original workflow step: Build firmware
# REVIEW REQUIRED: not yet adapted for local execution.

cd openwrt

# R76S_V12_OTA_EXACT_VERSION_GUARD
echo "===== Verify V1.2 OTA exact-version patch ====="

OTA_BIN="package/diy/luci-app-ota/root/bin/ota"
OTA_PATCHER="/r76s-repo/build/local-arm64/v12-ota-exact-version.py"

test -s "$OTA_BIN" || {
  echo "ERROR: OTA source missing" >&2
  exit 1
}

test -s "$OTA_PATCHER" || {
  echo "ERROR: OTA patcher missing" >&2
  exit 1
}

python3 "$OTA_PATCHER" "$OTA_BIN"

sh -n "$OTA_BIN"

grep -qF 'grep -Fxq "$current"' "$OTA_BIN" || {
  echo "ERROR: OTA exact comparison missing" >&2
  exit 1
}

if grep -qF 'grep -Fq "$current"' "$OTA_BIN"; then
  echo "ERROR: Legacy OTA substring comparison remains" >&2
  exit 1
fi

echo "R76S_V12_OTA_EXACT_VERSION_GUARD=PASS"

# R76S_V12_GO126_PASSWALL_PREP
bash /r76s-repo/build/local-arm64/v12-prepare-go-and-passwall.sh

echo "===== V1.1.1: Prepare SmartDNS source before S18 patch ====="

# The package Makefile installs init from PKG_BUILD_DIR; it is not
# necessarily available in feeds/ before package preparation.
make -j1 package/smartdns/prepare V=s
mapfile -t SMARTDNS_INIT_CANDIDATES < <(
  find build_dir -type f -path '*/smartdns*/package/openwrt/files/etc/init.d/smartdns' -print
)
if [ "${#SMARTDNS_INIT_CANDIDATES[@]}" -ne 1 ]; then
  echo "ERROR: expected one prepared SmartDNS init script, got ${#SMARTDNS_INIT_CANDIDATES[@]}" >&2
  find build_dir -type f -path '*/etc/init.d/smartdns' -print | head -n 20 >&2 || true
  exit 1
fi
SMARTDNS_INIT="${SMARTDNS_INIT_CANDIDATES[0]}"
test -f "$SMARTDNS_INIT"

echo "SMARTDNS_INIT=$SMARTDNS_INIT"

# Important: editing PKG_BUILD_DIR alone is insufficient. The
# final image must copy this exact init into openwrt/files overlay.
python3 ../scripts/r76s-v111-image-boot-policy.py smartdns "$SMARTDNS_INIT" files
test -x files/etc/init.d/smartdns
cmp -s "$SMARTDNS_INIT" files/etc/init.d/smartdns
grep -qxF 'START=18' files/etc/init.d/smartdns
grep -qF 'R76S_V111_SMARTDNS_BOOT_ORDER' files/etc/init.d/smartdns
sh -n files/etc/init.d/smartdns
echo "SMARTDNS_BOOT_ORDER=PASS_FINAL_OVERLAY_STAGED"


JOBS="${R76S_JOBS:-4}"
case "$JOBS" in 1|2|3|4) ;; *) echo "ERROR: R76S_JOBS must be 1..4 on 10GiB Colima VM" >&2; exit 1;; esac
echo "===== Build with $JOBS parallel jobs + ccache ====="

export CCACHE_DIR="$HOME/.ccache"
ccache -M 5G >/dev/null 2>&1 || true
ccache -z >/dev/null 2>&1 || true

if ! make -j"$JOBS"; then
  echo "Parallel build failed; retrying once with -j1 V=s for diagnosis."
  make -j1 V=s
fi

ccache -s || true
