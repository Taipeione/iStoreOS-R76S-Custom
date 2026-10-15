#!/usr/bin/env python3
"""Validate the V1.4.2 clean-flash and first-boot credential policy.

The source tree carries the fixed clean-flash password policy directly. This
check is read-only; it never changes source files, builds an image, publishes a
release, or contacts a router.
"""
from pathlib import Path
import argparse

MARKER = 'R76S_V142_FIXED_CLEAN_FLASH_PASSWORD'
MIGRATION_MARKER = 'R76S_V142_ROOT_PASSWORD_MIGRATION'
RANDOM_MARKERS = (
    'R76S_V12_PUBLIC_CREDENTIALS_20261010',
    '05-r76s-public-serial-provision',
    'PUBLIC_ROOT_CREDENTIAL_MODE=SERIAL_FIRST_BOOT',
)


def require(text: str, needle: str, label: str, errors: list[str]) -> None:
    if needle not in text:
        errors.append(f'{label}: missing {needle}')


def check(repo: Path) -> None:
    errors: list[str] = []
    stage16 = next(iter((repo / 'build/local-arm64/stages').glob('16-*.sh')), None)
    if stage16 is None:
        errors.append('stage16: missing')
    else:
        text = stage16.read_text()
        require(text, MARKER, 'stage16', errors)
        require(text, "passwd root", 'stage16', errors)
        require(text, "password\npassword", 'stage16', errors)
        require(text, 'CLEAN_FLASH_ROOT_HASH=', 'stage16', errors)
        require(text, 'root:${CLEAN_FLASH_ROOT_HASH}:', 'stage16', errors)
        if '/dev/urandom' in text:
            errors.append('stage16: random password initialization remains')
        for marker in RANDOM_MARKERS:
            if marker in text:
                errors.append(f'stage16: obsolete marker remains: {marker}')

    candidate = repo / 'build/local-arm64/candidate-local.sh'
    if not candidate.is_file():
        errors.append('candidate-local.sh: missing')
    else:
        text = candidate.read_text()
        require(text, MARKER, 'candidate-local.sh', errors)
        require(text, 'PUBLIC_ROOT_CREDENTIAL_MODE=FIXED_PASSWORD', 'candidate-local.sh', errors)
        for marker in RANDOM_MARKERS:
            if marker in text:
                errors.append(f'candidate-local.sh: obsolete marker remains: {marker}')

    audit = repo / 'scripts/r76s-v111-final-audit.py'
    if not audit.is_file():
        errors.append('final audit: missing')
    else:
        text = audit.read_text()
        require(text, MARKER, 'final audit', errors)
        require(text, 'etc/uci-defaults/99-r76s-first-root-password', 'final audit', errors)
        require(text, 'FIXED_CLEAN_FLASH_ROOT_HASH', 'final audit', errors)
        require(text, 'V142_ROOT_PASSWORD_BOOT_MIGRATION', 'final audit', errors)
        require(text, 'V142_ROOT_PASSWORD_AUTH_DEFAULT', 'final audit', errors)
        if 'cat > openwrt/files/etc/uci-defaults/05-r76s-public-serial-provision' in text:
            errors.append('final audit: random first-boot policy remains')

    stage19 = repo / 'build/local-arm64/stages/19-verify-final-r76s-configuration.sh'
    if not stage19.is_file():
        errors.append('stage19: missing')
    else:
        text = stage19.read_text()
        require(text, MARKER, 'stage19', errors)
        require(text, '99-r76s-first-root-password', 'stage19', errors)
        if 'cat > files/etc/uci-defaults/05-r76s-public-serial-provision' in text:
            errors.append('stage19: random first-boot policy remains')

    stage24 = repo / 'build/local-arm64/stages/24-create-final-v1-1-1-image-and-release-metadata.sh'
    if not stage24.is_file():
        errors.append('stage24: missing')
    else:
        text = stage24.read_text()
        require(text, 'clean flash default root credential policy: fixed', 'stage24', errors)
        if 'random UART password' in text:
            errors.append('stage24: obsolete random-password release text remains')

    firstboot = repo / 'files/etc/uci-defaults/99-r76s-first-root-password'
    if not firstboot.is_file():
        errors.append('firstboot: missing')
    else:
        text = firstboot.read_text()
        require(text, MARKER, 'firstboot', errors)
        require(text, 'password\npassword', 'firstboot', errors)
        require(text, 'ROOT_FIELD', 'firstboot', errors)
        if '/dev/urandom' in text or '/dev/ttyS0' in text:
            errors.append('firstboot: random/UART initialization remains')

    migration = repo / 'files/etc/uci-defaults/99-r76s-v142-root-password-migration'
    if not migration.is_file() or not migration.stat().st_mode & 0o111:
        errors.append('migration: missing or not executable')
    else:
        text = migration.read_text()
        require(text, MIGRATION_MARKER, 'migration', errors)
        require(text, "R76S-V1.4.2", 'migration', errors)
        require(text, "MARKER=\"/etc/config/r76s_v142_root_password_migrated\"", 'migration', errors)
        require(text, 'passwd root', 'migration', errors)
        require(text, 'password\npassword', 'migration', errors)
        if '/dev/urandom' in text or '/dev/ttyS0' in text:
            errors.append('migration: random/UART initialization remains')

    if errors:
        raise SystemExit('ERROR: ' + '; '.join(errors))
    print('R76S_FIXED_CLEAN_FLASH_PASSWORD_POLICY=PASS')
    print('R76S_V142_PRESERVE_UPGRADE_PASSWORD_MIGRATION=PASS')
    print('R76S_RANDOM_FIRSTBOOT_REMOVED=YES')
    print('PUBLIC_RELEASE_CREDENTIAL_CHECK=PASS')


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', type=Path, required=True)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    if not args.check:
        print('Read-only validator: use --check')
        raise SystemExit(2)
    check(args.repo.expanduser().resolve())


if __name__ == '__main__':
    main()
