#!/usr/bin/env bash
set -euo pipefail
# R76S_V12_CANDIDATE_LOCAL_BUILD_GUARD_20261010
# Original workflow step: Download and verify R76S bootloader
# REVIEW REQUIRED: not yet adapted for local execution.

OFFICIAL_URL="https://fw.koolcenter.com/iStoreOS/r76s/istoreos-24.10.8-2026073111-r76s-squashfs.img.gz"

OFFICIAL_GZ="${R76S_LOCAL_TMP:-/tmp}/official-r76s-24.10.8.img.gz"
BOOT_BIN="${R76S_LOCAL_TMP:-/tmp}/r76s-official-bootloader.bin"

# An already verified bootloader can be reused; never accept a partial cache.
if [ -s "$BOOT_BIN" ] && [ "$(stat -c%s "$BOOT_BIN")" = '16744448' ] && \
   [ "$(md5sum "$BOOT_BIN" | awk '{print $1}')" = '80f6bcbcbb912ecce884f24e275f2ac6' ]; then
  echo 'VERIFIED_BOOTLOADER_CACHE=REUSED'
  BOOT_MD5=80f6bcbcbb912ecce884f24e275f2ac6
  printf 'BOOT_BIN=%s\nBOOT_MD5=%s\n' "$BOOT_BIN" "$BOOT_MD5" >> "$GITHUB_ENV"
  exit 0
fi

# R76S_V12_STAGE04_GZIP_WARNING_GUARD
# A complete gzip member with non-gzip trailing bytes makes GNU gzip -t
# exit 2 (warning). Accept only this precise warning; Stage04 MUST then
# validate the exact pinned bootloader size and hash before caching it.
echo "===== Validate official R76S reference image ====="
if [ -s "$OFFICIAL_GZ" ]; then
  echo 'OFFICIAL_IMAGE_CACHE=EXISTS; verifying before use'
else
  curl -fL \
    --retry 3 \
    --retry-delay 5 \
    "$OFFICIAL_URL" \
    -o "$OFFICIAL_GZ"
fi

test -s "$OFFICIAL_GZ"
GZIP_TEST_LOG="${R76S_LOCAL_TMP:-/tmp}/r76s-official-gzip-check.log"
gzip_rc=0
gzip -t "$OFFICIAL_GZ" 2>"$GZIP_TEST_LOG" || gzip_rc=$?
case "$gzip_rc" in
  0)
    echo 'OFFICIAL_GZIP_INTEGRITY=PASS'
    ;;
  2)
    nonblank=$(awk 'NF { n++ } END { print n+0 }' "$GZIP_TEST_LOG")
    if [ "$nonblank" = 1 ] &&
       grep -Fq 'decompression OK, trailing garbage ignored' "$GZIP_TEST_LOG"; then
      echo 'OFFICIAL_GZIP_INTEGRITY=PASS_WITH_TRAILING_BYTES_WARNING'
      echo 'REQUIRES_PINNED_BOOTLOADER_HASH=YES'
    else
      cat "$GZIP_TEST_LOG" >&2
      echo 'ERROR: unexpected gzip warnings; abort' >&2
      exit 2
    fi
    ;;
  *)
    cat "$GZIP_TEST_LOG" >&2
    echo "ERROR: gzip validation failed (rc=$gzip_rc)" >&2
    exit "$gzip_rc"
    ;;
esac

echo
echo "===== Extract 32KB - 16MB bootloader region ====="

set +o pipefail # bounded dd expects upstream gzip SIGPIPE
gzip -dc "$OFFICIAL_GZ" 2>/dev/null | \
  dd \
    of="$BOOT_BIN" \
    bs=512 \
    skip=64 \
    count=32704 \
    status=none
set -o pipefail

test -s "$BOOT_BIN"

BOOT_SIZE=$(stat -c%s "$BOOT_BIN")

echo "Bootloader size: $BOOT_SIZE bytes"

EXPECTED_SIZE=16744448

if [ "$BOOT_SIZE" -ne "$EXPECTED_SIZE" ]; then
  echo "ERROR: Bootloader region size mismatch."
  echo "Expected: $EXPECTED_SIZE"
  echo "Actual:   $BOOT_SIZE"
  exit 1
fi

BOOT_MD5=$(
  md5sum "$BOOT_BIN" \
    | awk '{print $1}'
)

EXPECTED_MD5="80f6bcbcbb912ecce884f24e275f2ac6"

echo "Bootloader MD5: $BOOT_MD5"

if [ "$BOOT_MD5" != "$EXPECTED_MD5" ]; then
  echo "ERROR: Official bootloader hash mismatch."
  echo "Expected: $EXPECTED_MD5"
  echo "Actual:   $BOOT_MD5"
  exit 1
fi

echo
echo "Official R76S bootloader verified successfully."

echo "BOOT_BIN=$BOOT_BIN" >> "$GITHUB_ENV"
echo "BOOT_MD5=$BOOT_MD5" >> "$GITHUB_ENV"
