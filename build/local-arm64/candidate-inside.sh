#!/usr/bin/env bash
# Run only in the existing ARM64 Docker build environment; candidate artifacts stay private.
set -euo pipefail
umask 022
# Keep logs and build state private even though generated firmware overlay uses ordinary 0644 defaults.
WORK=/home/builder/work
REPO=/r76s-repo
cd "$WORK"
[ -d openwrt/.git ] || { echo 'Existing OpenWrt worktree missing; will not clone a new tree silently' >&2; exit 2; }
BASE=fb971407ffd9a094e6f16d9c029f1f580ed5c2ad
[ "$(git -C openwrt rev-parse HEAD)" = "$BASE" ] || { echo 'Base source has drifted' >&2; exit 2; }
# Stage only the expected repository inputs. Do not delete existing build trees.
for d in config feeds files scripts; do
  test -d "$REPO/$d" || { echo "Missing input directory: $d" >&2; exit 2; }
  if [ -d "$WORK/$d" ] && [ "$REPO/$d" -ef "$WORK/$d" ]; then
    echo "INPUT_STAGING_SKIP_SAME_DIR=$d"
    continue
  fi
  mkdir -p "$WORK/$d"
  cp -a "$REPO/$d/." "$WORK/$d/"
done
mkdir -p "$WORK/.r76s-candidate" "$WORK/logs" "$WORK/.r76s-local-tmp"
chmod 0700 "$WORK/.r76s-candidate" "$WORK/.r76s-local-tmp"
export R76S_LOCAL_TMP="$WORK/.r76s-local-tmp"
export GITHUB_WORKSPACE="$WORK"
export GITHUB_ENV="$WORK/.r76s-candidate/stage.env"
export R76S_REPO_ROOT="$REPO"
export HOME=/home/builder
: > "$GITHUB_ENV"
# Stage 01 requires executable temporary mock commands; Docker /tmp is a limited exec tmpfs.
# Explicit stage environment exports: never eval/source untrusted contents of GITHUB_ENV.
apply_env() {
  local key value
  while IFS='=' read -r key value; do
    case "$key" in
      BOOT_BIN|BOOT_MD5|TARGET_DIR|CUSTOM_IMAGE|RAW_IMAGE|SYSUPGRADE_META|FWTOOL)
        printf -v "$key" '%s' "$value"
        export "$key"
        ;;
      *) echo "Unrecognized stage env key: $key" >&2; exit 3;;
    esac
  done < "$GITHUB_ENV"
}
# Detect inadequate disk space before lengthy compilation. It does not remove anything.
free_kib=$(df -Pk "$WORK" | awk 'END{print $4}')
if [ "$free_kib" -lt 20971520 ]; then
  echo "Less than 20 GiB free in Docker work volume: ${free_kib} KiB; abort" >&2
  exit 2
fi
stage=00
on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'CANDIDATE_FAILED_STAGE=%s exit=%s\n' "$stage" "$rc" >&2
    bash -e -o pipefail "$REPO/build/local-arm64/stages/28-collect-v1-1-1-diagnostic-report-even-on-failure.sh" \
      > "$WORK/logs/r76s-v12-candidate-diagnostics.log" 2>&1 || true
    echo "See $WORK/logs/r76s-v12-candidate-stage-${stage}.log" >&2
  fi
}
trap on_exit EXIT
for n in $(seq -w 1 27); do
  stage="$n"
  shopt -s nullglob
  paths=("$REPO/build/local-arm64/stages/${n}-"*.sh)
  shopt -u nullglob
  [ "${#paths[@]}" -eq 1 ] || { echo "Expected one stage ${n}, found ${#paths[@]}" >&2; exit 2; }
  f="${paths[0]}"
  echo "===== CANDIDATE STAGE ${n}: $(basename "$f") ====="
  # Bash -e and pipefail apply even to old GitHub Actions stages without strict flags.
  bash -e -o pipefail "$f" 2>&1 | tee "$WORK/logs/r76s-v12-candidate-stage-${n}.log"
  apply_env
  echo "CANDIDATE_STAGE_${n}=PASS"
done
stage=29
bash -e -o pipefail "$REPO/build/local-arm64/stages/28-collect-v1-1-1-diagnostic-report-even-on-failure.sh" \
  > "$WORK/logs/r76s-v12-candidate-diagnostics.log" 2>&1 || true
# Keep candidate separate from any publication. Rootfs audit ran at stage25.
release="$WORK/openwrt/bin/targets/rockchip/armv8/release-v1.2"
test -s "$release/R76S-V1.2-TF-squashfs.img.gz"
printf '%s\n' 'Candidate only. Not flash-tested. Not approved for publication.' > "$release/CANDIDATE-NOT-FOR-RELEASE.txt"
sha256sum "$release/R76S-V1.2-TF-squashfs.img.gz" > "$WORK/logs/r76s-v12-candidate-final.sha256"
trap - EXIT
echo 'CANDIDATE_BUILD=PASS_STATIC_IMAGE_AUDIT_ONLY; no publish or flash'
