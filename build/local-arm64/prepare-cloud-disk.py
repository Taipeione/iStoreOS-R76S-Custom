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
        # These SDKs are preinstalled convenience toolchains and are not used
        # by the pinned OpenWrt cross build. Removing each exact root avoids a
        # multi-million-file Python walk while leaving the workspace untouched.
        subprocess.run(['rm', '-rf', '--', str(root)], check=True)
        print(f'UNUSED_PREINSTALLED_SDK_ROOT={root}', flush=True)
    print(f'RECLAIMED_SDK_ALLOCATED_BYTES={released}', flush=True)


if __name__ == '__main__':
    main()
