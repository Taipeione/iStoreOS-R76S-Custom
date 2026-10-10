#!/usr/bin/env bash
set -euo pipefail
# Dependencies are baked into build/local-arm64/Dockerfile; no sudo in build process.
for cmd in gcc g++ make git python3 ccache pigz fdisk sfdisk openssl; do
  command -v "$cmd" >/dev/null || { echo "MISSING BUILD DEPENDENCY: $cmd" >&2; exit 1; }
done
python3 -c 'from elftools.elf.elffile import ELFFile; print("ELFTOOLS=PASS")'
