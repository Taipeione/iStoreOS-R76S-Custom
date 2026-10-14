#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"
python3 build/local-arm64/preflight.py --repo .
python3 -m unittest discover -s build/local-arm64/tests -q
python3 scripts/r76s-v111-prebuild-tests.py
