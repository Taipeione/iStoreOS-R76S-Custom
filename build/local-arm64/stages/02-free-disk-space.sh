#!/usr/bin/env bash
set -euo pipefail
# LOCAL SAFE REPLACEMENT. Never delete host toolchains or system directories.
echo "===== Local volume disk check (no deletion) ====="
df -h "$(pwd)"
