#!/usr/bin/env python3
"""Free unrelated compiled SDK assets on a disposable GitHub runner only."""
import os
import subprocess
from pathlib import Path

SDK_ROOTS = tuple(map(Path, (
    '/usr/local/lib/android', '/usr/share/dotnet', '/opt/ghc',
    '/usr/local/.ghcup', '/usr/share/swift', '/opt/hostedtoolcache/CodeQL',
)))


def compiled_asset(path):
    if path.is_symlink() or not path.is_file():
        return False
    # Never remove source archives, regardless of their container format.
    if any(word in path.name.lower() for word in ('source', 'sources', 'src')):
        return False
    with path.open('rb') as stream:
        magic = stream.read(8)
    if magic.startswith((b'\x7fELF', b'MZ', b'!<arch>\n')):
        return True
    return path.suffix == '.img' or (path.suffix == '.jar' and magic.startswith(b'PK\x03\x04'))


def main():
    if os.environ.get('GITHUB_ACTIONS') != 'true' or os.geteuid() != 0:
        raise SystemExit('Only run as root on a disposable GitHub Actions runner')
    if Path('/home/builder/work/openwrt').exists():
        raise SystemExit('Run before creating the firmware build environment')
    released = 0
    for root in SDK_ROOTS:
        if not root.is_dir() or root.is_symlink():
            continue
        count = 0
        # Let find do the directory traversal in native code. Most SDK trees
        # contain millions of headers/text files; inspecting every file in
        # Python made the runner appear hung before the build even started.
        candidates = subprocess.run(
            ['find', str(root), '-xdev', '-maxdepth', '8',
             '(', '-type', 'd', '(', '-name', 'sources', '-o', '-name', 'source', '-o', '-name', 'src', ')', '-prune', ')', '-o',
             '-type', 'f', '(', '-perm', '-111', '-o', '-name', '*.img', '-o', '-name', '*.jar', '-o', '-name', '*.a', ')', '-print0'],
            check=True, capture_output=True).stdout.split(b'\0')
        for raw in candidates:
            if not raw:
                continue
            path = Path(os.fsdecode(raw))
            if path.resolve().is_relative_to(root.resolve()) and compiled_asset(path):
                released += path.stat().st_blocks * 512
                path.unlink()
                count += 1
        print(f'UNUSED_COMPILED_SDK_ASSETS={root} files={count}', flush=True)
    print(f'RECLAIMED_SDK_ALLOCATED_BYTES={released}', flush=True)


if __name__ == '__main__':
    main()
