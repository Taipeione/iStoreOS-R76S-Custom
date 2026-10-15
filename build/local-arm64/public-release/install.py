#!/usr/bin/env python3
"""Read-only V1.4.3 credential-policy validator."""
from pathlib import Path
import argparse

HASH = '$6$r76sv143$j/yuToJ35nP6zluEW5qQzsYySWhM0mx8xaNVL.ZK2/J00HuN1d1Qr1h6PP2yWHgXmRlkRnA/Ymtqj60ETzJoi.'
RANDOM_MARKERS = (
    'R76S_V12_PUBLIC_CREDENTIALS_20261010',
    '05-r76s-public-serial-provision',
    'PUBLIC_ROOT_CREDENTIAL_MODE=SERIAL_FIRST_BOOT',
    '/dev/urandom',
    '/dev/ttyS0',
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
        require(text, 'CLEAN_FLASH_ROOT_HASH=', 'stage16', errors)
        require(text, 'root:${CLEAN_FLASH_ROOT_HASH}:', 'stage16', errors)
        require(text, HASH, 'stage16', errors)
        require(text, 'R76S_V143_ROOT_PASSWORD_POLICY', 'stage16', errors)
        require(text, "R76S-V1.4.3", 'stage16', errors)
        for marker in RANDOM_MARKERS:
            if marker in text:
                errors.append(f'stage16: obsolete/random password mechanism remains: {marker}')

    candidate = repo / 'build/local-arm64/candidate-local.sh'
    if not candidate.is_file():
        errors.append('candidate-local.sh: missing')
    else:
        text = candidate.read_text()
        require(text, 'PUBLIC_ROOT_CREDENTIAL_MODE=FIXED_PASSWORD', 'candidate-local.sh', errors)
        for marker in RANDOM_MARKERS:
            if marker in text:
                errors.append(f'candidate-local.sh: obsolete/random marker remains: {marker}')

    audit = repo / 'scripts/r76s-v111-final-audit.py'
    if not audit.is_file():
        errors.append('final audit: missing')
    else:
        text = audit.read_text()
        require(text, 'FIXED_CLEAN_FLASH_ROOT_HASH', 'final audit', errors)
        require(text, 'crypt.crypt(\'password\', value)', 'final audit', errors)
        require(text, 'R76S_V143_ROOT_PASSWORD_POLICY', 'final audit', errors)
        require(text, 'RANDOM_PASSWORD_MECHANISM_PRESENT', 'final audit', errors)

    stage19 = repo / 'build/local-arm64/stages/19-verify-final-r76s-configuration.sh'
    if not stage19.is_file():
        errors.append('stage19: missing')
    else:
        text = stage19.read_text()
        for needle in ('R76S_V143_ROOT_PASSWORD_POLICY', 'R76S_V143_ROOT_PASSWORD_AUTH', HASH,
                       'files/etc/init.d/r76s-root-password'):
            require(text, needle, 'stage19', errors)
        if '99-r76s-first-root-password' in text and '! test -e files/etc/uci-defaults/99-r76s-first-root-password' not in text:
            errors.append('stage19: old firstboot password mechanism remains')

    policy = repo / 'files/etc/init.d/r76s-root-password'
    if not policy.is_file() or not policy.stat().st_mode & 0o111:
        errors.append('policy: missing or not executable')
    else:
        text = policy.read_text()
        for needle in ('R76S_V143_ROOT_PASSWORD_POLICY', 'R76S-V1.4.3', 'password\npassword',
                       '/etc/config/r76s_root_password_v143_done'):
            require(text, needle, 'policy', errors)
        if any(marker in text for marker in RANDOM_MARKERS):
            errors.append('policy: random password mechanism remains')

    auth = repo / 'files/etc/uci-defaults/99-r76s-root-auth'
    if not auth.is_file() or not auth.stat().st_mode & 0o111:
        errors.append('auth: missing or not executable')
    else:
        text = auth.read_text()
        require(text, 'R76S_V143_ROOT_PASSWORD_AUTH', 'auth', errors)
        require(text, "RootPasswordAuth='1'", 'auth', errors)
        if 'passwd root' in text or any(marker in text for marker in RANDOM_MARKERS):
            errors.append('auth: password setter/random mechanism remains')

    for old in ('files/etc/uci-defaults/99-r76s-first-root-password',
                'files/etc/uci-defaults/99-r76s-v142-root-password-migration',
                'files/etc/uci-defaults/99-r76s-v143-root-password-migration'):
        if (repo / old).exists():
            errors.append(f'old password mechanism remains: {old}')

    if errors:
        raise SystemExit('ERROR: ' + '; '.join(errors))
    print('R76S_V143_FIXED_ROOT_PASSWORD_POLICY=PASS')
    print('R76S_V143_PRESERVE_UPGRADE_PASSWORD_MIGRATION=PASS')
    print('R76S_RANDOM_PASSWORD_MECHANISM_REMOVED=PASS')
    print('PUBLIC_RELEASE_CREDENTIAL_CHECK=PASS')

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', type=Path, required=True)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    if not args.check:
        raise SystemExit('Read-only validator: use --check')
    check(args.repo.expanduser().resolve())

if __name__ == '__main__':
    main()
