#!/usr/bin/env python3
"""Post-build diagnostics and *image-grounded* critical-file gate for R76S.

Staging trees are evidence only; only extraction from the GPT SquashFS
partition in the built raw image can pass the final firmware file gate.
No router/network/mount access. No configuration changes.
"""
import argparse
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

EXECUTABLES = (
    'usr/libexec/r76s/r76s-ota-preserve-state',
    *(f'usr/libexec/r76s/v111-dns-readonly/{name}' for name in (
        'r76s-v111-dns-detect.sh', 'r76s-v111-dns-guard.sh',
        'r76s-v111-dns-policy.sh', 'r76s-v111-dns-manager.sh',
        'r76s-v111-dns-runtime-audit.sh', 'r76s-v111-agh-upstream.sh',
        'r76s-v111-agh-yaml-render.sh')),
    'usr/libexec/r76s/v111-dns-runtime/r76s-v111-dns-runtime-manager.sh',
    'etc/init.d/r76s-v111-dns-manager',
)
REQUIRED = (*EXECUTABLES,
    'www/luci-static/resources/ui.js',
    'www/luci-static/resources/view/system/flash.js',
    'etc/config/r76s_v111_dns',
    'etc/init.d/smartdns')
BANNED = (
    'etc/rc.d/S99r76s-v111-dns-manager',
    'usr/libexec/r76s/v111-dns-readonly/r76s-v111-dns-transaction.sh',
    'usr/libexec/r76s/v111-dns-readonly/r76s-v111-dns-topology.py',
)
CONTENT = {
    'usr/libexec/r76s/r76s-ota-preserve-state': 'r76s_ota_state.state.pending',
    'www/luci-static/resources/ui.js': 'timeout: 0',
    'www/luci-static/resources/view/system/flash.js': 'R76S_V110_FLASH_UPLOAD_PATCH',
    'etc/config/r76s_v111_dns': "option enabled '0'",
    'etc/init.d/smartdns': 'START=18',
}
LMO = (
    'usr/lib/lua/luci/i18n/passwall2.zh-cn.lmo',
    'usr/share/luci/i18n/passwall2.zh-cn.lmo',
)


def check_tree(root, image=False):
    issues = []
    for rel in REQUIRED:
        p = root / rel
        if p.is_symlink():
            # Symlink init scripts need to resolve inside this extracted tree.
            try:
                resolved = p.resolve(strict=True)
                if not resolved.is_relative_to(root.resolve()):
                    issues.append(f'OUTSIDE_TREE_SYMLINK: {rel}')
            except (OSError, ValueError):
                issues.append(f'BROKEN_SYMLINK: {rel}')
        if not p.is_file():
            issues.append(f'MISSING: {rel}')
            continue
        if p.stat().st_size == 0:
            issues.append(f'EMPTY: {rel}')
        if rel in EXECUTABLES and not (p.stat().st_mode & stat.S_IXUSR):
            issues.append(f'NOT_EXECUTABLE: {rel}')
        if rel in CONTENT:
            raw = p.read_bytes()
            needle = CONTENT[rel].encode()
            if needle not in raw:
                issues.append(f'CONTENT_MISMATCH: {rel} ({CONTENT[rel]})')
            if rel == 'etc/init.d/smartdns' and b'START=18' not in raw.splitlines():
                issues.append('CONTENT_MISMATCH: etc/init.d/smartdns (exact START=18 line)')
    for rel in BANNED:
        p = root / rel
        if p.exists() or p.is_symlink():
            issues.append(f'FORBIDDEN: {rel}')
    if image and not any((root / rel).is_file() and (root / rel).stat().st_size > 0 for rel in LMO):
        issues.append('MISSING: PassWall2 zh-cn LMO (both supported paths absent)')
    return issues


def stage(openwrt):
    print('STAGING_TREES_ARE_NOT_IMAGE_PROOF=YES', flush=True)
    overlay = openwrt / 'files'
    if not overlay.is_dir():
        print('OVERLAY_MISSING=' + str(overlay), flush=True)
        return 1
    # Overlay intentionally may omit package-installed files; check its own content only.
    for rel in ('usr/libexec/r76s/r76s-ota-preserve-state',
                'www/luci-static/resources/ui.js',
                'www/luci-static/resources/view/system/flash.js',
                'etc/config/r76s_v111_dns'):
        p = overlay / rel
        print(f'OVERLAY_FILE={rel} EXIST={p.is_file()} SIZE={p.stat().st_size if p.is_file() else 0}', flush=True)
        if not p.is_file() or not p.stat().st_size:
            print('ERROR: STAGED_OVERLAY_REQUIRED_FILE_MISSING=' + rel, flush=True)
            return 1
    target_base = openwrt / 'build_dir'
    matches = []
    for name in ('root-rockchip', 'target-dir-*'):
        matches.extend(p for p in target_base.rglob(name) if p.is_dir())
    for root in sorted(set(matches)):
        issues = check_tree(root)
        print(f'STAGING_CANDIDATE={root} ISSUE_COUNT={len(issues)}', flush=True)
        for issue in issues:
            print('STAGING_ONLY_' + issue, flush=True)
    print('STAGING_DIAGNOSTICS=PASS (image gate still mandatory)', flush=True)
    return 0


def partitions(image):
    p = subprocess.run(['sfdisk', '--json', str(image)], capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(f'sfdisk partition metadata failed: {p.stderr.strip()}')
    info = json.loads(p.stdout)['partitiontable']
    sec = int(info.get('sectorsize', 512))
    if sec < 512 or sec & (sec - 1):
        raise RuntimeError('Unexpected disk sector size: ' + str(sec))
    for item in info['partitions']:
        start, size = int(item['start']), int(item['size'])
        pos = start * sec
        if pos + 4 > image.stat().st_size or size < 8:
            continue
        with image.open('rb') as f:
            f.seek(pos)
            magic = f.read(4)
        print(f'PARTITION_START={start} SECTOR_SIZE={sec} MAGIC={magic.hex()}', flush=True)
        if magic == b'hsqs':
            yield pos


def image_audit(image):
    if not image.is_file() or not image.stat().st_size:
        print('ERROR: MISSING_OR_EMPTY_IMAGE=' + str(image))
        return 1
    candidates = list(partitions(image))
    if len(candidates) != 1:
        print(f'ERROR: EXPECTED_EXACTLY_ONE_SQUASHFS_PARTITION_FOUND={len(candidates)}')
        return 1
    offset = candidates[0]
    print('IMAGE_SQUASHFS_OFFSET=' + str(offset), flush=True)
    root_pathlist = list(dict.fromkeys((*REQUIRED, *BANNED, *LMO)))
    with tempfile.TemporaryDirectory(prefix='r76s-image-audit-') as tmp:
        root = Path(tmp) / 'extracted'
        cmd = ['unsquashfs', '-no-progress', '-d', str(root), '-offset', str(offset),
               str(image), *root_pathlist]
        p = subprocess.run(cmd, capture_output=True, text=True)
        if p.returncode:
            print('ERROR: UNSQUASHFS_EXTRACT_FAILED=' + str(p.returncode), flush=True)
            print(p.stdout[-3000:], flush=True)
            print(p.stderr[-3000:], flush=True)
            return 1
        issues = check_tree(root, image=True)
        for issue in issues:
            print('IMAGE_' + issue, flush=True)
        if issues:
            print('R76S_V111_IMAGE_AUDIT=FAIL issue_count=' + str(len(issues)), flush=True)
            return 1
    print('SMARTDNS_S18_FINAL_ROOTFS=PASS', flush=True)
    print('R76S_V111_IMAGE_AUDIT=PASS', flush=True)
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--phase', choices=['stage','image'], required=True)
    parser.add_argument('--openwrt', type=Path)
    parser.add_argument('--image', type=Path)
    a = parser.parse_args()
    try:
        if a.phase == 'stage':
            if not a.openwrt: parser.error('--openwrt required for stage')
            return stage(a.openwrt.resolve())
        if not a.image: parser.error('--image required for image phase')
        return image_audit(a.image.resolve())
    except (OSError, ValueError, KeyError, RuntimeError) as e:
        print('R76S_V111_IMAGE_AUDIT=FAIL error=' + str(e), flush=True)
        return 1


if __name__ == '__main__':
    sys.exit(main())
