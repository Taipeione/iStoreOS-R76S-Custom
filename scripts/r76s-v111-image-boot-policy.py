#!/usr/bin/env python3
"""Build-time R76S V1.1.1 boot-policy edits; never runs on the router.

The rootfs.mk edit is restricted to image construction. It does NOT alter
/etc/rc.common on the router, so /etc/init.d/r76s-v111-dns-manager enable
still functions when the owner opts in after live validation.
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

SERVICE = 'r76s-v111-dns-manager'
BASE = 'if ! echo " $(3) " | grep -q " $$(basename $$script) "; then \\'
DISABLED = 'if ! echo " $(3) ' + SERVICE + ' " | grep -q " $$(basename $$script) "; then \\'
MARKER = '# R76S_V111_SMARTDNS_BOOT_ORDER'

class Blocked(RuntimeError):
    pass


def patch_rootfs_makefile(path):
    if path.is_symlink() or not path.is_file():
        raise Blocked('ROOTFS_MK_UNSAFE_OR_MISSING: ' + str(path))
    content = path.read_text()
    if content.count(DISABLED) == 1 and content.count(BASE) == 0:
        print('R76S_V111_ROOTFS_AUTOSTART_GUARD=ALREADY_STAGED')
        return
    if content.count(BASE) != 1 or content.count(DISABLED) != 0:
        raise Blocked('ROOTFS_MK_UPSTREAM_ANCHOR_UNEXPECTED')
    if content.count('$(call prepare_rootfs,') == 0 and 'define prepare_rootfs' not in content:
        raise Blocked('ROOTFS_MK_PREPARE_ROOTFS_MISSING')
    new = content.replace(BASE, DISABLED, 1)
    path.write_text(new)
    if path.read_text().count(DISABLED) != 1:
        raise Blocked('ROOTFS_MK_PATCH_VERIFICATION_FAILED')
    print('R76S_V111_ROOTFS_AUTOSTART_GUARD=PASS')


def patch_smartdns_source(source, overlay):
    if not source.is_file() or source.is_symlink():
        raise Blocked('SMARTDNS_PREPARED_INIT_MISSING_OR_UNSAFE')
    if overlay.is_symlink() or not overlay.is_dir():
        raise Blocked('OPENWRT_FILES_OVERLAY_MISSING_OR_UNSAFE')
    original = source.read_text()
    if '#!/bin/sh /etc/rc.common' not in original[:120]:
        raise Blocked('SMARTDNS_INIT_IS_NOT_RC_COMMON')
    starts = list(re.finditer(r'(?m)^START=([0-9]+)[ \t]*$', original))
    if len(starts) != 1 or starts[0].group(1) not in ('18', '19'):
        raise Blocked('SMARTDNS_START_ANCHOR_INVALID')
    if MARKER in original:
        if original.count(MARKER) != 1 or starts[0].group(1) != '18':
            raise Blocked('SMARTDNS_BOOT_MARKER_CONFLICT')
        updated = original
    else:
        updated = (original[:starts[0].start()] + 'START=18\n' + MARKER + '\n'
                   + original[starts[0].end():])
    if len(re.findall(r'(?m)^START=18[ \t]*$', updated)) != 1:
        raise Blocked('SMARTDNS_START_POSTPATCH_INVALID')
    if updated != original:
        source.write_text(updated)
    subprocess.run(['sh', '-n', str(source)], check=True, capture_output=True)
    folder = overlay / 'etc/init.d'
    if folder.is_symlink():
        raise Blocked('SMARTDNS_OVERLAY_INIT_DIR_SYMLINK')
    folder.mkdir(parents=True, exist_ok=True)
    destination = folder / 'smartdns'
    if destination.is_symlink():
        raise Blocked('SMARTDNS_OVERLAY_INIT_SYMLINK')
    shutil.copyfile(source, destination)
    destination.chmod(0o755)
    if (destination.read_bytes() != source.read_bytes()
            or not os.access(destination, os.X_OK)):
        raise Blocked('SMARTDNS_OVERLAY_COPY_VERIFY_FAILED')
    print('SMARTDNS_S18_SOURCE_AND_FINAL_OVERLAY=PASS')


def selftest():
    with tempfile.TemporaryDirectory(prefix='r76s-v111-image-boot-') as t:
        root = Path(t)
        makefile = root/'rootfs.mk'
        makefile.write_text('define prepare_rootfs\n  ' + BASE + '\nendef\n')
        patch_rootfs_makefile(makefile)
        patch_rootfs_makefile(makefile)
        if DISABLED not in makefile.read_text() or BASE in makefile.read_text():
            raise Blocked('SELFTEST_BUILD_SERVICE_DISABLE_FAILED')
        for target in ('r76s-v111-dns-manager', 'smartdns'):
            # Mirrors the upstream echo | grep membership check.
            members = ' $(3) ' + SERVICE + ' '
            found = (' ' + target + ' ') in members
            if found != (target == SERVICE):
                raise Blocked('SELFTEST_DISABLED_LIST_MEMBERSHIP_FAILED')
        makefile.write_text('define prepare_rootfs\n  invalid\nendef\n')
        try:
            patch_rootfs_makefile(makefile)
        except Blocked:
            pass
        else:
            raise Blocked('SELFTEST_UPSTREAM_DRIFT_NOT_BLOCKED')
        source = root/'smartdns.prepared'
        source.write_text('#!/bin/sh /etc/rc.common\nSTART=19\nSTOP=10\n')
        overlay = root/'overlay'
        overlay.mkdir()
        patch_smartdns_source(source, overlay)
        patch_smartdns_source(source, overlay)
        dest = overlay/'etc/init.d/smartdns'
        if dest.read_bytes() != source.read_bytes() or dest.stat().st_mode & 0o111 == 0:
            raise Blocked('SELFTEST_SMARTDNS_OVERLAY_MISMATCH')
        source.write_text('#!/bin/sh /etc/rc.common\nSTART=92\n')
        try:
            patch_smartdns_source(source, overlay)
        except Blocked:
            pass
        else:
            raise Blocked('SELFTEST_BAD_SMARTDNS_VERSION_NOT_BLOCKED')
    print('R76S_V111_BOOT_POLICY_SELFTEST=PASS')


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest='action', required=True)
    s = sub.add_parser('rootfs', help='patch image-only autostart list')
    s.add_argument('rootfs_mk', type=Path)
    s = sub.add_parser('smartdns', help='stage prepared SmartDNS init in rootfs overlay')
    s.add_argument('prepared_init', type=Path)
    s.add_argument('files_overlay', type=Path)
    sub.add_parser('selftest')
    args = parser.parse_args()
    if args.action == 'rootfs':
        patch_rootfs_makefile(args.rootfs_mk)
    elif args.action == 'smartdns':
        patch_smartdns_source(args.prepared_init, args.files_overlay)
    else:
        selftest()


if __name__ == '__main__':
    try:
        main()
    except (Blocked, OSError, subprocess.CalledProcessError) as ex:
        print('R76S_V111_BOOT_POLICY=BLOCKED: ' + str(ex), file=sys.stderr)
        sys.exit(1)
