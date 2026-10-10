#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit("Usage: hook.py golang-package.mk go-root")

p = Path(sys.argv[1])
go_root = Path(sys.argv[2])

if not (go_root / "bin/go").is_file():
    raise SystemExit("ERROR: Go binary missing")

s = p.read_text()
marker = "# R76S_GO126_TARGET_PACKAGES"
anchor = "GO_PKG_BUILD_CONFIG_VARS= " + chr(92) + "\n"
injection = (
    marker + "\n" + anchor +
    "\tPATH=\"" + str(go_root / "bin") + ":$(PATH)\" " +
    chr(92) + "\n"
)

if marker in s:
    if injection not in s:
        raise SystemExit("ERROR: Existing Go hook differs")
    print("GO126_HOOK=ALREADY_PRESENT")
else:
    if s.count(anchor) != 1:
        raise SystemExit("ERROR: Go package configuration anchor unexpected")
    p.write_text(s.replace(anchor, injection, 1))
    print("GO126_HOOK=INSTALLED")
