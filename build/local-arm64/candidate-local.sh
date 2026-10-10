#!/usr/bin/env bash
# R76S V1.2 candidate only. Does NOT publish or flash.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODE="${1:-check}"
IMAGE='r76s-builder:arm64-ubuntu2204-final'
JOBS="${R76S_JOBS:-4}"
case "$JOBS" in 1|2|3|4) ;; *) echo 'R76S_JOBS must be 1..4' >&2; exit 2;; esac
case "$MODE" in check|build|status) ;; *) echo 'Usage: candidate-local.sh {check|build|status}' >&2; exit 2;; esac
if [ "$MODE" = check ] || [ "$MODE" = build ]; then
  python3 "$ROOT/build/local-arm64/preflight.py" --repo "$ROOT"
  python3 -m unittest discover -s "$ROOT/build/local-arm64/tests" -p 'test_*.py' -q
fi
command -v docker >/dev/null || { echo 'Docker CLI missing' >&2; exit 2; }
docker info >/dev/null || { echo 'Docker/Colima is not running' >&2; exit 2; }
docker volume inspect r76s-v12-work >/dev/null
docker volume inspect r76s-v12-ccache >/dev/null
docker image inspect "$IMAGE" >/dev/null
if [ "$MODE" = check ]; then
  echo 'CANDIDATE_PREFLIGHT=PASS; PRODUCTION_RELEASE=BLOCKED'
  exit 0
fi
if [ "$MODE" = status ]; then
  docker run --rm --platform linux/arm64 --user 1000:1000 \
    --mount type=volume,src=r76s-v12-work,dst=/home/builder/work,readonly \
    "$IMAGE" bash -c 'find /home/builder/work/openwrt/bin/targets/rockchip/armv8/release-v1.2 -maxdepth 1 -type f -printf "%f %s bytes\n" 2>/dev/null || true'
  exit 0
fi
# No assumptions about GitHub account ownership: derive from the actual repository origin.
GITHUB_REPOSITORY="${R76S_GITHUB_REPOSITORY:-}"
if [ -z "$GITHUB_REPOSITORY" ]; then
  ORIGIN="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
  case "$ORIGIN" in
    https://github.com/*) GITHUB_REPOSITORY="${ORIGIN#https://github.com/}";;
    git@github.com:*) GITHUB_REPOSITORY="${ORIGIN#git@github.com:}";;
    *) echo 'Set R76S_GITHUB_REPOSITORY=owner/repo (GitHub origin not recognized)' >&2; exit 2;;
  esac
  GITHUB_REPOSITORY="${GITHUB_REPOSITORY%.git}"
fi
if [[ ! "$GITHUB_REPOSITORY" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]]; then
  echo 'Invalid R76S_GITHUB_REPOSITORY; expected owner/repo' >&2; exit 2
fi
# R76S_V12_PUBLIC_CREDENTIALS_20261010
R76S_PUBLIC_RELEASE="${R76S_PUBLIC_RELEASE:-0}"
case "$R76S_PUBLIC_RELEASE" in 0|1) ;; *) echo 'R76S_PUBLIC_RELEASE must be 0 or 1' >&2; exit 2;; esac
export R76S_PUBLIC_RELEASE
if [ "$R76S_PUBLIC_RELEASE" = 1 ]; then
  [ -z "${R76S_CLEAN_FLASH_PASSWORD_HASH:-}" ] || { echo 'Public image forbids build-supplied root hash' >&2; exit 2; }
  echo 'PUBLIC_ROOT_CREDENTIAL_MODE=SERIAL_FIRST_BOOT'
else
# Require an independently chosen clean-flash login secret without saving plaintext to files or shell history.
if [ -z "${R76S_CLEAN_FLASH_PASSWORD_HASH:-}" ]; then
  if [ ! -t 0 ]; then echo 'A terminal is needed to enter the build-only root password' >&2; exit 2; fi
  printf 'Enter a unique R76S clean-flash root password (14+ characters): ' >&2
  IFS= read -r -s SECRET_ONE; printf '\n' >&2
  printf 'Confirm password: ' >&2
  IFS= read -r -s SECRET_TWO; printf '\n' >&2
  if [ "$SECRET_ONE" != "$SECRET_TWO" ] || [ "${#SECRET_ONE}" -lt 14 ]; then
    unset SECRET_ONE SECRET_TWO
    echo 'Passwords differ or are too short; build not started' >&2; exit 2
  fi
  R76S_CLEAN_FLASH_PASSWORD_HASH="$(printf '%s\n' "$SECRET_ONE" | docker run --rm -i --network none --platform linux/arm64 "$IMAGE" openssl passwd -6 -stdin)"
  unset SECRET_ONE SECRET_TWO
  export R76S_CLEAN_FLASH_PASSWORD_HASH
fi
if [[ ! "$R76S_CLEAN_FLASH_PASSWORD_HASH" =~ ^\$6\$[A-Za-z0-9./]{8,16}\$[A-Za-z0-9./]{86}$ ]]; then
  echo 'Build root hash rejected (expected SHA-512 crypt format)' >&2; exit 2
fi
fi
# Required staging inputs must be present, and the host repository stays read-only.
for item in config/R76S.config feeds/luci-app-r76s-status/Makefile feeds/luci-app-r76s-updater/Makefile files/etc/uci-defaults/99-r76s-v2-defaults; do
  test -s "$ROOT/$item" || { echo "Missing required input: $item" >&2; exit 2; }
done
export GITHUB_REPOSITORY
GITHUB_SHA="$(git -C "$ROOT" rev-parse HEAD)"; export GITHUB_SHA
GITHUB_RUN_ID="candidate-$(date -u +%Y%m%dT%H%M%SZ)"; export GITHUB_RUN_ID
printf 'CANDIDATE_ONLY=YES; Repository=%s; Jobs=%s\n' "$GITHUB_REPOSITORY" "$JOBS"
set +e
docker run --rm -i --platform linux/arm64 \
  --user 1000:1000 \
  --mount "type=bind,src=$ROOT,dst=/r76s-repo,readonly" \
  --mount type=volume,src=r76s-v12-work,dst=/home/builder/work \
  --mount type=volume,src=r76s-v12-ccache,dst=/home/builder/.ccache \
  --tmpfs /tmp:rw,exec,nosuid,size=512m,mode=1777 \
  --workdir /home/builder/work \
  --env "R76S_JOBS=$JOBS" \
  --env R76S_CLEAN_FLASH_PASSWORD_HASH \
  --env R76S_PUBLIC_RELEASE \
  --env GITHUB_REPOSITORY --env GITHUB_SHA --env GITHUB_RUN_ID \
  "$IMAGE" \
  bash /r76s-repo/build/local-arm64/candidate-inside.sh
rc=$?
set -e
unset R76S_CLEAN_FLASH_PASSWORD_HASH
if [ "$rc" -ne 0 ]; then
  echo "CANDIDATE_BUILD=FAILED exit=$rc; preserved Docker work volume/logs; nothing published" >&2
  exit "$rc"
fi
echo 'CANDIDATE_BUILD=BUILT_AND_STATICALLY_AUDITED; NOT FLASH-TESTED; NOT PUBLISHED'
