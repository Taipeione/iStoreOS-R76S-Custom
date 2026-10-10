#!/usr/bin/env bash
# R76S V1.2 Mac mini M4 local builder helper (safe, no direct flashing).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODE="${1:-check}"

case "$MODE" in
  check)
    python3 "$ROOT/build/local-arm64/preflight.py" --repo "$ROOT"
    ;;
  toolchain)
    command -v docker >/dev/null || { echo 'Docker CLI missing' >&2; exit 1; }
    test -s "$ROOT/config/R76S.config" || { echo 'Missing config/R76S.config' >&2; exit 1; }
    docker info >/dev/null || { echo 'Colima Docker engine not available; start Colima first' >&2; exit 1; }
    # The named volumes were created earlier; do NOT create a fresh volume silently.
    docker volume inspect r76s-v12-work >/dev/null
    docker volume inspect r76s-v12-ccache >/dev/null
    JOBS="${R76S_JOBS:-4}"
    case "$JOBS" in 1|2|3|4) ;; *) echo 'R76S_JOBS must be 1..4' >&2; exit 1;; esac
    echo '===== START PINNED R76S TOOLCHAIN TEST ====='
    docker run --rm -it --platform linux/arm64 \
      --user 1000:1000 \
      --mount "type=bind,src=$ROOT,dst=/r76s-repo,readonly" \
      --mount type=volume,src=r76s-v12-work,dst=/home/builder/work \
      --mount type=volume,src=r76s-v12-ccache,dst=/home/builder/.ccache \
      --workdir /home/builder/work \
      --env "R76S_JOBS=$JOBS" \
      r76s-builder:arm64-ubuntu2204 \
      bash /r76s-repo/build/local-arm64/toolchain-inside.sh
    ;;
  build|publish|flash)
    echo 'DENIED: production V1.2 not yet feature-complete and verified.' >&2
    echo 'Missing rules: WeChat direct bypass, OTA exact-version, eight DNS modes, GUI, preservation, image audit.' >&2
    exit 3
    ;;
  *)
    echo "Usage: $0 {check|toolchain}" >&2
    exit 2
    ;;
esac
