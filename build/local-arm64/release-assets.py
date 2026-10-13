#!/usr/bin/env python3
"""Generate the Release OTA manifest and checksums without changing sources."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

VERSION = 'R76S-V1.3.1'


def digest(path):
    with path.open('rb') as stream:
        result = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(chunk)
        return result.hexdigest()


def generate(release, target, repository, commit):
    release, target = Path(release), Path(target)
    # Upload real device-specific .bin outputs when the image profile produces them.
    # Never invent a .bin by renaming a disk image.
    for path in sorted(target.glob('*friendlyarm_nanopi-r76s*.bin')):
        shutil.copy2(path, release / path.name)
    images = sorted(p for p in release.iterdir()
                    if p.is_file() and p.suffix in ('.img', '.bin', '.gz'))
    primary = release / f'{VERSION}-TF-squashfs.img.gz'
    raw = release / f'{VERSION}-TF-squashfs.img'
    if primary not in images or raw not in images:
        raise ValueError('Final compressed and raw R76S images are required')
    base = f'https://github.com/{repository}/releases/download/{VERSION}'
    artifacts = [{'name': p.name, 'size': p.stat().st_size,
                  'sha256': digest(p), 'url': f'{base}/{p.name}'} for p in images]
    data = {'schema_version': 1, 'version': VERSION,
            'openwrt_version': '24.10.8', 'revision': VERSION,
            'target': 'rockchip/armv8',
            'supported_devices': ['friendlyarm,nanopi-r76s'],
            'source_commit': commit, 'image': primary.name,
            'url': f'{base}/{primary.name}', 'sha256': digest(primary),
            'artifacts': artifacts}
    (release / 'ota.json').write_text(json.dumps(data, indent=2) + '\n')
    metadata = ['ota.json', 'version.latest', 'version.index',
                'ota.footer.html', 'BOOTLOADER_INFO.txt']
    paths = images + [release / name for name in metadata]
    checksums = ''.join(f'{digest(p)}  {p.name}\n' for p in paths)
    for name in ('sha256', 'sha256sums'):
        (release / name).write_text(checksums)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    for name in ('release', 'target', 'repository', 'commit'):
        parser.add_argument('--' + name, required=True)
    args = parser.parse_args()
    generate(args.release, args.target, args.repository, args.commit)
