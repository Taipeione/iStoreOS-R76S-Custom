#!/usr/bin/env python3
"""Strict, offline-only scan of staged rootfs DNS override assignments.

Only the exact audited read-only classifier/renderer and development runtime
manager may mention managed ports without creating a static DNS takeover.
No router state is read or modified.
"""
from pathlib import Path
import re
import sys

EXEMPT = frozenset({
    'usr/libexec/r76s/v111-dns-readonly/r76s-v111-dns-manager.sh',
    'usr/libexec/r76s/v111-dns-readonly/r76s-v111-dns-guard.sh',
    'usr/libexec/r76s/v111-dns-runtime/r76s-v111-dns-runtime-manager.sh',
})
FINGERPRINTS = re.compile(
    rb'127\.0\.0\.1#(?:3053|6053)|R76S_EXTERNAL_DNS_BEGIN|'
    rb'noresolv=.1.|noresolv=.0.'
)


def check(root):
    root = Path(root)
    if not root.is_dir() or root.is_symlink():
        raise ValueError('overlay directory missing or symlinked')
    checked = 0
    skipped = set()
    errors = []
    for file in sorted(root.rglob('*')):
        rel = file.relative_to(root).as_posix()
        if file.is_symlink():
            raise ValueError('unexpected rootfs overlay symlink: ' + rel)
        if not file.is_file():
            continue
        if rel in EXEMPT:
            skipped.add(rel)
            continue
        try:
            with file.open('rb') as src:
                for n, line in enumerate(src, 1):
                    if FINGERPRINTS.search(line):
                        errors.append((rel, n))
        except OSError as exc:
            raise ValueError('unreadable overlay file: ' + rel) from exc
        checked += 1
    missing = EXEMPT - skipped
    if missing:
        raise ValueError('reviewed DNS helper absent: ' + ', '.join(sorted(missing)))
    if errors:
        for rel, n in errors[:25]:
            print(f'UNAUTHORIZED_DNS_OVERLAY={rel}:{n}', file=sys.stderr)
        raise ValueError(f'{len(errors)} unauthorized DNS overlay matches')
    print('DNS_ROOTFS_POLICY_SCAN=PASS')
    print(f'DNS_ROOTFS_FILES_CHECKED={checked}')
    print(f'DNS_CLASSIFIER_EXEMPTIONS_VERIFIED={len(skipped)}')


if __name__ == '__main__':
    try:
        if len(sys.argv) != 2:
            raise ValueError('usage: python3 scanner.py <staged-rootfs-files-directory>')
        check(sys.argv[1])
    except ValueError as exc:
        print('DNS_ROOTFS_POLICY_SCAN=FAIL: ' + str(exc), file=sys.stderr)
        sys.exit(1)
