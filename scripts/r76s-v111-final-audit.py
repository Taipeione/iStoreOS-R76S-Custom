#!/usr/bin/env python3
"""Post-build diagnostics and *image-grounded* critical-file gate for R76S.

Staging trees are evidence only; only extraction from the GPT SquashFS
partition in the built raw image can pass the final firmware file gate.
No router/network/mount access. No configuration changes.
"""
import argparse
import importlib.util
import hmac
import re
# R76S_V12_SECURITY_GATE_20261010
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

EXECUTABLES = (
    'usr/bin/r76s-health',
    *(f'usr/libexec/r76s/{name}' for name in ('r76s-service-manager','r76s-ota','r76s-dns-manager','r76s-config-migrate','r76s-healthcheck','r76s-watchdog','r76s-wireguard-endpoint')),
    'etc/init.d/r76s-reconcile',
    'usr/libexec/r76s/r76s-ip-family-policy',
    'usr/libexec/r76s/r76s-ip6-guard',
    'etc/init.d/r76s-ip6-guard',
    'etc/firewall.r76s-ip6-guard',
    'usr/libexec/r76s/r76s-ota-preserve-state',
    *(f'usr/libexec/r76s/v111-dns-readonly/{name}' for name in (
        'r76s-v111-dns-detect.sh', 'r76s-v111-dns-guard.sh',
        'r76s-v111-dns-policy.sh', 'r76s-v111-dns-manager.sh',
        'r76s-v111-dns-runtime-audit.sh', 'r76s-v111-agh-upstream.sh',
        'r76s-v111-agh-yaml-render.sh')),
    'usr/libexec/r76s/v111-dns-runtime/r76s-v111-dns-runtime-manager.sh',
    'etc/init.d/r76s-v111-dns-manager',
)
REQUIRED = (
    'usr/bin/r76s-health',
    'etc/config/r76s',
    'etc/init.d/r76s-reconcile',
    'usr/libexec/r76s/r76s-service-manager',
    'usr/libexec/r76s/r76s-ota',
    'usr/libexec/r76s/r76s-dns-manager',
    'usr/libexec/r76s/r76s-config-migrate',
    'usr/libexec/r76s/r76s-healthcheck',
    'usr/share/r76s/ota-public.pem',
    'usr/share/r76s/release.json',
    'usr/share/r76s/sources.lock.json',
    'lib/upgrade/keep.d/r76s',
*EXECUTABLES,
    'www/luci-static/resources/ui.js',
    'www/luci-static/resources/view/system/flash.js',
    'etc/config/r76s_v111_dns',
    'etc/init.d/smartdns',
    'etc/shadow',
    'etc/init.d/r76s-ota-restore',
    'etc/init.d/r76s-root-password',
    'etc/uci-defaults/99-r76s-root-auth',
    'etc/init.d/r76s-root-password',
    'lib/upgrade/keep.d/r76s-v110',
    'etc/config/r76s_ip_policy',
    'usr/share/r76s/tencent-direct.list',
    'etc/uci-defaults/99-r76s-v110-ota-restore',
    'usr/lib/lua/luci/controller/r76s_updater.lua',
    'usr/lib/lua/luci/controller/r76s_adguardhome.lua',
    'usr/lib/lua/luci/view/r76s_adguardhome/status.htm',
    'www/luci-static/resources/r76s/wireguard.js',
    'www/luci-static/resources/r76s/wireguard-status.js',
    'www/luci-static/resources/view/r76s_wireguard/client.js',
    'usr/share/luci/menu.d/r76s-wireguard-client.json',
    'usr/lib/lua/luci/controller/r76s_diagnostics.lua',
    'usr/lib/lua/luci/model/r76s/diagnostics.lua',
    'usr/lib/lua/luci/model/r76s/diagnostics_collect.lua',
    'usr/lib/lua/luci/view/r76s_diagnostics/status.htm',
    'usr/lib/lua/luci/controller/r76s_wireguard.lua',
    'usr/lib/lua/luci/view/r76s_wireguard/status.htm',
    'usr/lib/lua/luci/model/r76s/services.lua',
    'usr/lib/lua/luci/controller/r76s_ip_policy.lua',
    'usr/lib/lua/luci/view/r76s_ip_policy/status.htm')
BANNED = (
    'etc/rc.d/S99r76s-v111-dns-manager',
    'usr/libexec/r76s/v111-dns-readonly/r76s-v111-dns-transaction.sh',
    'usr/libexec/r76s/v111-dns-readonly/r76s-v111-dns-topology.py',
    'etc/uci-defaults/99-r76s-v2-defaults',
    'etc/uci-defaults/98-r76s-passwall-autostart',
    'etc/init.d/r76s-fix3-boot',
)
CONTENT = {
    'usr/libexec/r76s/r76s-ota-preserve-state': 'r76s_ota_state.state.pending',
    'www/luci-static/resources/ui.js': 'timeout: 0',
    'www/luci-static/resources/view/system/flash.js': 'R76S_V110_FLASH_UPLOAD_PATCH',
    'etc/config/r76s_v111_dns': "option enabled '0'",
    'etc/init.d/smartdns': 'START=18',
    'etc/init.d/r76s-ota-restore': 'R76S_V12_OTA_HARDENING',
    'etc/uci-defaults/99-r76s-v110-ota-restore': 'R76S_V12_OTA_HARDENING',
    'usr/lib/lua/luci/controller/r76s_updater.lua': 'R76S_V14_OTA_BACKEND',
}
LMO = (
    'usr/lib/lua/luci/i18n/passwall2.zh-cn.lmo',
    'usr/share/luci/i18n/passwall2.zh-cn.lmo',
)
FIXED_CLEAN_FLASH_ROOT_HASH = '$6$r76sv143$j/yuToJ35nP6zluEW5qQzsYySWhM0mx8xaNVL.ZK2/J00HuN1d1Qr1h6PP2yWHgXmRlkRnA/Ymtqj60ETzJoi.'


def check_root_shadow(root):
    """Inspect the extracted rootfs and verify the real password hash."""
    p = root / 'etc/shadow'
    if not p.is_file() or p.is_symlink():
        return ['ROOT_SHADOW_MISSING_OR_SYMLINK']
    try:
        lines = p.read_text(encoding='utf-8').splitlines()
    except (UnicodeDecodeError, OSError):
        return ['ROOT_SHADOW_UNREADABLE']
    roots = [line.split(':', 2)[1] for line in lines if line.startswith('root:')]
    if len(roots) != 1:
        return ['ROOT_ACCOUNT_COUNT_INVALID']
    value = roots[0]
    if os.environ.get('R76S_PUBLIC_RELEASE') == '1':
        if value in ('!', '*', '') or value.startswith('!') or value.startswith('*'):
            return ['ROOT_ACCOUNT_LOCKED']
        if value != FIXED_CLEAN_FLASH_ROOT_HASH:
            return ['CLEAN_IMAGE_ROOT_HASH_MISMATCH']
        try:
            import crypt
            if not hmac.compare_digest(crypt.crypt('password', value), value):
                return ['CLEAN_IMAGE_ROOT_PASSWORD_HASH_MISMATCH']
        except (ImportError, TypeError):
            return ['CLEAN_IMAGE_ROOT_PASSWORD_CHECK_UNAVAILABLE']
        policy = root / 'etc/init.d/r76s-root-password'
        if not policy.is_file() or not (policy.stat().st_mode & stat.S_IXUSR):
            return ['V143_ROOT_PASSWORD_POLICY_MISSING_OR_NOT_EXECUTABLE']
        policy_text = policy.read_text(encoding='utf-8')
        if 'R76S_V143_ROOT_PASSWORD_POLICY' not in policy_text or 'R76S-V1.4.3' not in policy_text:
            return ['V143_ROOT_PASSWORD_POLICY_INVALID']
        if '/dev/urandom' in policy_text or '/dev/ttyS0' in policy_text:
            return ['RANDOM_PASSWORD_MECHANISM_PRESENT']
        if (root / 'etc/uci-defaults/99-r76s-first-root-password').exists():
            return ['OLD_FIRSTBOOT_PASSWORD_MECHANISM_PRESENT']
        if (root / 'etc/uci-defaults/99-r76s-v142-root-password-migration').exists():
            return ['OLD_V142_PASSWORD_MIGRATION_PRESENT']
        if (root / 'etc/uci-defaults/99-r76s-v143-root-password-migration').exists():
            return ['MULTIPLE_PASSWORD_SETTERS_PRESENT']
        auth_defaults = root / 'etc/uci-defaults/99-r76s-root-auth'
        if not auth_defaults.is_file() or not (auth_defaults.stat().st_mode & stat.S_IXUSR):
            return ['V143_ROOT_PASSWORD_AUTH_DEFAULT_MISSING_OR_NOT_EXECUTABLE']
        auth_text = auth_defaults.read_text(encoding='utf-8')
        if 'R76S_V143_ROOT_PASSWORD_AUTH' not in auth_text or "RootPasswordAuth='1'" not in auth_text:
            return ['V143_ROOT_PASSWORD_AUTH_DEFAULT_INVALID']
        if '/dev/urandom' in auth_text or '/dev/ttyS0' in auth_text:
            return ['RANDOM_PASSWORD_MECHANISM_PRESENT']
        boot_link = root / 'etc/rc.d/S99r76s-root-password'
        if not boot_link.is_file() or not (boot_link.stat().st_mode & stat.S_IXUSR):
            return ['V143_ROOT_PASSWORD_BOOT_WRAPPER_MISSING_OR_NOT_EXECUTABLE']
        if '/etc/init.d/r76s-root-password' not in boot_link.read_text(encoding='utf-8'):
            return ['V143_ROOT_PASSWORD_BOOT_WRAPPER_INVALID']
        dropbear = root / 'etc/config/dropbear'
        if not dropbear.is_file():
            return ['DROPBEAR_CONFIG_MISSING']
        cfg = dropbear.read_text(encoding='utf-8')
        if not re.search(r"option\s+PasswordAuth\s+'(?:1|on)'", cfg):
            return ['DROPBEAR_PASSWORD_AUTH_DISABLED']
        if not re.search(r"option\s+RootPasswordAuth\s+'(?:1|on)'", cfg):
            return ['DROPBEAR_ROOT_PASSWORD_AUTH_DISABLED']
        if not re.search(r"option\s+Interface\s+'lan'", cfg):
            return ['DROPBEAR_NOT_LAN_BOUND']
        return []
    if not re.fullmatch(r'\$6\$[A-Za-z0-9./]{8,16}\$[A-Za-z0-9./]{86}', value):
        return ['ROOT_PASSWORD_NOT_STRONG_SHA512_CRYPT_FORMAT']
    try:
        import crypt
    except ImportError:
        return ['ROOT_WEAK_PASSWORD_CHECK_UNAVAILABLE']
    for candidate in ('password', 'root', 'admin', '123456', '12345678',
                      '123456789', '1234567890', 'r76s', 'istoreos', 'openwrt'):
        computed = crypt.crypt(candidate, value)
        if not computed or computed.startswith('*'):
            return ['ROOT_PASSWORD_CRYPT_UNSUPPORTED']
        if hmac.compare_digest(computed, value):
            return ['ROOT_WEAK_DEFAULT_PASSWORD_DETECTED']
    return []

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
    if image:
        issues.extend(check_root_shadow(root))
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
    # Extract etc/ to inspect the shadow file and detect unsafe legacy uci-defaults.
    root_pathlist = list(dict.fromkeys((*REQUIRED, *BANNED, *LMO, 'etc',
        'usr/lib/opkg/status', 'usr/share/passwall/0_default_config',
        'usr/share/passwall2/0_default_config')))
    if os.environ.get('R76S_PUBLIC_RELEASE') == '1':
        root_pathlist.append('usr/bin/openssl')
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
        spec = importlib.util.spec_from_file_location('production_audit',
            Path(__file__).with_name('r76s-production-audit.py'))
        production = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(production)
        issues.extend(production.audit(root))
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
