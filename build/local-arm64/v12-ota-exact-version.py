#!/usr/bin/env python3
"""Strict, fail-closed source patch for the old /bin/ota substring version bug.
Run only after the package providing /bin/ota has been staged into OpenWrt.
Unknown layouts fail and must be reviewed, rather than shipping an unverified OTA.
"""
import sys
from pathlib import Path

OLD = 'grep -Fq "$current"'
NEW = 'sed -n \'1s/^\\[\\([^]]*\\)\\](.*)$/\\1/p\' | grep -Fxq "$current"'

def patch(contents):
    if OLD in contents:
        if contents.count(OLD) != 1:
            raise ValueError('ambiguous legacy version comparison')
        return contents.replace(OLD, NEW, 1), True
    if NEW in contents:
        return contents, False
    raise ValueError('OTA source version comparison not recognized; do not publish')

if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('Usage: v12-ota-exact-version.py PATH_TO_STAGED_BIN_OTA')
    p = Path(sys.argv[1]).resolve()
    if p.name != 'ota' or not p.is_file():
        raise SystemExit('ERROR: supply the staged source file named ota (not a live /bin/ota)')
    original = p.read_text()
    try:
        updated, modified = patch(original)
    except ValueError as exc:
        raise SystemExit(str(exc))
    if modified:
        p.write_text(updated)
    assert NEW in p.read_text()
    print('OTA_EXACT_VERSION_SOURCE=PASS', 'patched' if modified else 'already-safe')
