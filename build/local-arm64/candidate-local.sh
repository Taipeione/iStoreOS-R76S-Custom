#!/usr/bin/env bash
# R76S V1.3.2 candidate only. Does NOT publish or flash.
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
    "$IMAGE" bash -c 'find /home/builder/work/openwrt/bin/targets/rockchip/armv8/R76S-V1.4.3 -maxdepth 1 -type f -printf "%f %s bytes\n" 2>/dev/null || true'
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
# R76S_V143_FIXED_CLEAN_FLASH_PASSWORD
# V1.4.3 has one deterministic root credential policy for both public and
# local validation builds. Never prompt for or generate another password.
R76S_PUBLIC_RELEASE=1
export R76S_PUBLIC_RELEASE
[ -z "${R76S_CLEAN_FLASH_PASSWORD_HASH:-}" ] || { echo 'V1.4.3 rejects supplied root password hashes' >&2; exit 2; }
echo 'PUBLIC_ROOT_CREDENTIAL_MODE=FIXED_PASSWORD'
# Required staging inputs must be present, and the host repository stays read-only.
for item in config/R76S.config feeds/luci-app-r76s-status/Makefile feeds/luci-app-r76s-updater/Makefile config/rules/r76s-rules.json; do
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
