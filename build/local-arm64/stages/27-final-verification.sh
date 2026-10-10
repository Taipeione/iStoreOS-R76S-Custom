#!/usr/bin/env bash
set -euo pipefail
# R76S_V12_CANDIDATE_LOCAL_BUILD_GUARD_20261010
# Original workflow step: Final verification
# REVIEW REQUIRED: not yet adapted for local execution.

RELEASE_DIR="$TARGET_DIR/release-v1.2"

FINAL_IMAGE="$RELEASE_DIR/R76S-V1.2-TF-squashfs.img.gz"

echo "===== Final verification ====="

test -s "$FINAL_IMAGE"

echo "===== Verify final sysupgrade metadata ====="
FINAL_META="${R76S_LOCAL_TMP:-/tmp}/R76S-V1.2.verify.meta"
FINAL_STRIPPED="${R76S_LOCAL_TMP:-/tmp}/R76S-V1.2.verify.img.gz"
cp -f "$FINAL_IMAGE" "$FINAL_STRIPPED"
"$FWTOOL" -i "$FINAL_META" -t "$FINAL_STRIPPED"
grep -qF 'friendlyarm,nanopi-r76s' "$FINAL_META"
grep -qF 'V1.2' "$FINAL_META"
gzip -t "$FINAL_STRIPPED"

for ota_file in version.latest version.index sha256sums ota.footer.html; do
  test -s "$RELEASE_DIR/$ota_file"
done

grep -qF '24.10.8-V1.2' "$RELEASE_DIR/version.latest"
grep -qxF '24.10.8-V1.2' "$RELEASE_DIR/version.index"

echo
echo "Final image:"
ls -lh "$FINAL_IMAGE"

echo
echo "===== Verify final bootloader directly ====="

# gzip archive was validated above; bounded dd intentionally closes its input pipe early.
set +o pipefail
FINAL_BOOT_MD5=$(
  gzip -dc "$FINAL_STRIPPED" \
    | dd \
        bs=512 \
        skip=64 \
        count=32704 \
        status=none \
    | md5sum \
    | awk '{print $1}'
)

set -o pipefail
echo "Final bootloader MD5: $FINAL_BOOT_MD5"
echo "Expected bootloader MD5: $BOOT_MD5"

if [ "$FINAL_BOOT_MD5" != "$BOOT_MD5" ]; then
  echo "ERROR: Final image bootloader mismatch."
  exit 1
fi

echo
echo "R76S-V1.2 / PassWall2 / PassWall verified successfully."
