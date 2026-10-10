#!/usr/bin/env bash
# R76S V1.2 public, device-provisioned image: never publish a private root hash.
set -euo pipefail
umask 077
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
REPO="Taipeione/iStoreOS-R76S-Custom"
TAG='R76S-V1.2'
IMAGE='r76s-builder:arm64-ubuntu2204-final'
NAME='R76S-V1.2-TF-squashfs.img.gz'
RELEASE='/home/builder/work/openwrt/bin/targets/rockchip/armv8/release-v1.2'
DEST="$HOME/Downloads/R76S-V1.2-public-draft"
MODE="${1:-check}"

require_tools() { command -v docker >/dev/null; docker info >/dev/null; }
require_clean_git() {
  command -v git >/dev/null
  [ -z "$(git -C "$ROOT" status --porcelain)" ] || { echo 'ERROR: commit and review local changes first' >&2; exit 3; }
  [ "$(git -C "$ROOT" remote get-url origin)" = "https://github.com/$REPO.git" ] || \
    [ "$(git -C "$ROOT" remote get-url origin)" = "git@github.com:${REPO}.git" ] || \
    [ "$(git -C "$ROOT" remote get-url origin)" = "https://github.com/$REPO" ] || { echo 'ERROR: unexpected GitHub origin' >&2; exit 3; }
  git -C "$ROOT" fetch origin main --quiet
  [ "$(git -C "$ROOT" rev-parse HEAD)" = "$(git -C "$ROOT" rev-parse origin/main)" ] || {
    echo 'ERROR: local code differs from GitHub origin/main; commit + push source first' >&2; exit 3;
  }
}
verify_public_image() {
  require_tools
  docker run --rm -i --platform linux/arm64 --user 1000:1000 \
    --mount "type=bind,src=$ROOT,dst=/r76s-repo,readonly" \
    --mount type=volume,src=r76s-v12-work,dst=/home/builder/work \
    --workdir /home/builder/work \
    --env R76S_PUBLIC_RELEASE=1 \
    --env "R76S_SOURCE_SHA=$(git -C "$ROOT" rev-parse HEAD)" \
    "$IMAGE" bash -euo pipefail -s <<'IN'
export R76S_PUBLIC_RELEASE=1
D=/home/builder/work/openwrt/bin/targets/rockchip/armv8/release-v1.2
NAME=R76S-V1.2-TF-squashfs.img.gz
cd "$D"
test -s "$NAME"
test -s PUBLIC_BUILD_SOURCE_SHA
[ "$(cat PUBLIC_BUILD_SOURCE_SHA)" = "${R76S_SOURCE_SHA}" ] || { echo "ERROR: public image source commit mismatch" >&2; exit 3; }
grep -qxF '24.10.8-V1.2' version.index
grep -qF '[24.10.8-V1.2](R76S-V1.2-TF-squashfs.img.gz)' version.latest
sha256sum -c sha256sums
expect="$(sha256sum "$NAME" | awk '{print $1}')"
grep -qF "SHA256: $expect" version.latest
T="$(mktemp -d /home/builder/work/.r76s-local-tmp/public-final-audit-XXXXXXXX)"
trap 'rm -rf "$T"' EXIT
cp "$NAME" "$T/image.gz"
fwtool=/home/builder/work/openwrt/staging_dir/host/bin/fwtool
test -x "$fwtool"
"$fwtool" -i "$T/meta.json" -t "$T/image.gz"
python3 - "$T/meta.json" <<'PY'
import json,sys
m=json.load(open(sys.argv[1]))
assert 'friendlyarm,nanopi-r76s' in m['supported_devices']
for k,v in {'dist':'iStoreOS','version':'24.10.8','revision':'V1.2','target':'rockchip/armv8'}.items():
    assert m['version'][k]==v,(k,m['version'].get(k))
PY
gzip -t "$T/image.gz"
gzip -dc "$T/image.gz" > "$T/image.raw"
python3 /r76s-repo/scripts/r76s-v111-final-audit.py --phase image --image "$T/image.raw"
echo 'PUBLIC_FIRMWARE_ROOTFS_LOCKED=PASS'
echo 'PUBLIC_FIRMWARE_METADATA=PASS'
echo 'PUBLIC_FIRMWARE_SHA256=PASS'
echo 'PUBLIC_FIRMWARE_STATIC_AUDIT=PASS'
IN
}
prepare_files() {
  verify_public_image
  mkdir -p "$DEST"
  docker run --rm --platform linux/arm64 --user 1000:1000 \
    --mount type=volume,src=r76s-v12-work,dst=/home/builder/work,readonly \
    --mount "type=bind,src=$DEST,dst=/public-draft" \
    "$IMAGE" bash -euc '
      src=/home/builder/work/openwrt/bin/targets/rockchip/armv8/release-v1.2
      for f in R76S-V1.2-TF-squashfs.img.gz sha256sums version.latest version.index ota.footer.html BOOTLOADER_INFO.txt; do
        test -s "$src/$f"
        cp "$src/$f" "/public-draft/$f"
      done
      cd /public-draft
      sha256sum -c sha256sums
      echo PREPARED_PUBLIC_RELEASE=PASS
    '
  # Never copy CANDIDATE-NOT-FOR-RELEASE.txt as publishable material.
  echo "DRAFT_ASSETS=$DEST"
}
case "$MODE" in
 check)
   python3 "$ROOT/build/local-arm64/public-release/install.py" --repo "$ROOT" --check
   require_tools
   echo 'PUBLIC_RELEASE_CHECK=PASS; physical hardware tests still required'
   ;;
 build-draft)
   bash "$0" build
   bash "$0" draft
   echo 'PUBLIC_BUILD_AND_DRAFT=COMPLETE; NOT LATEST, NOT OTA-VISIBLE'
   ;;
 build)
   require_tools
   require_clean_git
   echo 'Building NEW public root-locked image. Existing private candidate cannot be reused.'
   R76S_PUBLIC_RELEASE=1 R76S_JOBS="${R76S_JOBS:-4}" bash "$ROOT/build/local-arm64/candidate-local.sh" build
   docker run --rm --platform linux/arm64 --user 1000:1000 \
      --mount type=volume,src=r76s-v12-work,dst=/home/builder/work \
      --env "BUILT_SHA=$(git -C "$ROOT" rev-parse HEAD)" "$IMAGE" \
      sh -ec 'printf "%s\n" "$BUILT_SHA" > /home/builder/work/openwrt/bin/targets/rockchip/armv8/release-v1.2/PUBLIC_BUILD_SOURCE_SHA'
   echo 'PUBLIC_CANDIDATE_REBUILD_COMPLETE=YES; NOT PUBLISHED'
   ;;
 audit) verify_public_image ;;
 prepare) prepare_files ;;
 draft)
   prepare_files
   require_clean_git
   command -v gh >/dev/null || { echo 'ERROR: install GitHub CLI gh first' >&2; exit 2; }
   gh auth status >/dev/null
   if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
     echo "ERROR: Release $TAG already exists; refusing to overwrite" >&2; exit 3
   fi
   gh release create "$TAG" --repo "$REPO" --draft --target main \
     --title 'R76S V1.2 - Pending hardware QA' \
     --notes 'PUBLIC ROOT-LOCKED CANDIDATE: not validated on physical hardware. Not a stable/latest release. Clean flash requires physical UART access to capture the generated first-boot password; verify OTA credential preservation before promotion.' \
     "$DEST/$NAME" "$DEST/sha256sums" "$DEST/version.latest" "$DEST/version.index" "$DEST/ota.footer.html" "$DEST/BOOTLOADER_INFO.txt"
   echo 'GITHUB_DRAFT_CREATED=PASS; NOT LATEST; NO AUTOMATIC OTA YET'
   ;;
 promote)
   # Deliberately NO fully unattended promotion: first real OTA + clean-flash QA required.
   require_clean_git
   command -v gh >/dev/null
   report="${R76S_QA_REPORT:-}"
   [ -f "$report" ] || { echo 'ERROR: provide R76S_QA_REPORT path with physical test evidence' >&2; exit 3; }
   for line in 'UART_FIRST_BOOT=PASS' 'EMMC_OTA_TEST=PASS' 'ROOT_PASSWORD_PRESERVED=PASS' \
      'LAN_DNS_TEST=PASS' 'WEB_OTA_TEST=PASS'; do
     grep -qxF "$line" "$report" || { echo "ERROR: missing QA evidence $line" >&2; exit 3; }
   done
   [ "${R76S_APPROVE_PUBLISH:-}" = 'I_VERIFIED_PHYSICAL_R76S_V1_2' ] || {
      echo 'ERROR: explicit approval required; never promote a build automatically' >&2; exit 3;
   }
   gh release view "$TAG" --repo "$REPO" --json isDraft --jq '.isDraft' | grep -qx true
   verify_public_image
   for f in "$DEST/$NAME" "$DEST/version.latest" "$DEST/version.index" "$DEST/sha256sums"; do
     test -s "$f" || { echo "ERROR: missing prepared asset $f" >&2; exit 3; }
   done
   # Prevent an edited/replaced remote draft being promoted without re-verification.
   gh api "repos/$REPO/releases/tags/$TAG" > "$DEST/remote-release-audit.json"
   python3 - "$DEST" "$DEST/remote-release-audit.json" <<'VERIFY_REMOTE'
import hashlib,json,sys
from pathlib import Path
local=Path(sys.argv[1]); remote=json.loads(Path(sys.argv[2]).read_text())
if not remote.get('draft'): raise SystemExit('Remote release is not draft')
assets={a['name']:a for a in remote['assets']}
for f in ('R76S-V1.2-TF-squashfs.img.gz','version.latest','version.index','sha256sums','ota.footer.html','BOOTLOADER_INFO.txt'):
    data=local/f
    if f not in assets or not data.is_file(): raise SystemExit('MISSING_ASSET: '+f)
    if assets[f]['digest']!='sha256:'+hashlib.sha256(data.read_bytes()).hexdigest():
        raise SystemExit('REMOTE_SHA256_MISMATCH: '+f)
print('REMOTE_DRAFT_ASSETS_SHA256=PASS')
VERIFY_REMOTE
   gh release edit "$TAG" --repo "$REPO" --draft=false --prerelease=false --latest
   echo 'PUBLIC_RELEASE_PUBLISHED_LATEST=PASS; router web OTA may now check for V1.2'
   ;;
 *) echo 'Usage: release-local.sh {check|build|audit|prepare|draft|build-draft|promote}' >&2; exit 2;;
esac
