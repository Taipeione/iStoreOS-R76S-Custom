#!/usr/bin/env bash
# Original workflow step: Set R76S v1.1.1 firmware identity
# REVIEW REQUIRED: not yet adapted for local execution.

cd openwrt

RELEASE_FILE="package/base-files/files/etc/openwrt_release"
test -f "$RELEASE_FILE"

# iStoreOS OTA compares DISTRIB_RELEASE-DISTRIB_REVISION.
# Keep the 24.10.8 release number and give the custom firmware a
# stable revision identity that our GitHub Release metadata can match.
sed -i \
  "s/^DISTRIB_REVISION=.*/DISTRIB_REVISION='V1.2'/" \
  "$RELEASE_FILE"

grep -q "^DISTRIB_REVISION='V1.2'$" "$RELEASE_FILE"

echo "===== Custom release identity ====="
grep -E '^DISTRIB_(RELEASE|REVISION)=' "$RELEASE_FILE" || true
