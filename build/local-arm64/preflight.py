#!/usr/bin/env python3
"""Read-only audit for the Mac mini M4 R76S V1.2 build. Never runs stages."""
from pathlib import Path
import argparse
import re
import subprocess
import sys

REQUIRED_REPO = (
    'config/R76S.config',
    'files/etc/uci-defaults/99-r76s-v2-defaults',
    'feeds/luci-app-r76s-status/Makefile',
    'feeds/luci-app-r76s-status/files/controller/r76s_status.lua',
    'feeds/luci-app-r76s-updater/Makefile',
    'feeds/luci-app-r76s-updater/files/controller/r76s_updater.lua',
    'feeds/luci-app-r76s-updater/files/view/r76s_updater/index.htm',
    'scripts/r76s-v111-prebuild-tests.py',
    'scripts/r76s-v111-final-audit.py',
)


def audit(root: Path):
    print('===== R76S V1.2 LOCAL PRE-FLIGHT (READ ONLY) =====')
    stages = sorted((root / 'build/local-arm64/stages').glob('[0-9][0-9]-*.sh'))
    syntax_bad = []
    for stage in stages:
        result = subprocess.run(['bash', '-n', str(stage)], capture_output=True, text=True)
        if result.returncode:
            syntax_bad.append((stage.name, result.stderr.strip()))
    print(f'STAGE_COUNT={len(stages)}')
    print(f'STAGE_BASH_SYNTAX={"PASS" if len(stages) == 29 and not syntax_bad else "FAIL"}')
    for name, error in syntax_bad:
        print('SYNTAX_ERROR:', name, error)

    missing = [path for path in REQUIRED_REPO if not (root / path).is_file()]
    print('MISSING_REPO_FILES=' + str(len(missing)))
    for path in missing:
        print('  MISSING:', path)

    stage02 = next(iter((root / 'build/local-arm64/stages').glob('02-*.sh')), None)
    if stage02 is not None:
        stage02_text = stage02.read_text()
        safe = not re.search(r'\b(sudo\s+rm|rm\s+-rf|apt\s+clean)\b', stage02_text)
    else:
        safe = False
    print('HOST_DISK_CLEANUP_DISABLED=' + ('YES' if safe else 'NO'))

    # These are HARD build/release gates, not automatically corrected by this bundle.
    s16 = next(iter((root / 'build/local-arm64/stages').glob('16-*.sh')), None)
    t = s16.read_text() if s16 else ''
    issue_legacy = '\\toption WeChatTencent' in t or 'if len(actual_order) != 42:' in t
    issue_password = 'openssl passwd -6 -salt R76Sv110 password' in t
    print('V12_WECHAT_INDEPENDENT_RULES=' + ('LEGACY_OUTPUT_BLOCKER' if issue_legacy else 'OFFLINE_TEST_REQUIRED'))
    print('V12_WEAK_CLEAN_FLASH_PASSWORD=' + ('BLOCKER' if issue_password else 'REVIEW_REQUIRED'))
    print('V12_OTA_EXACT_VERSION_FIX=UNVERIFIED')
    print('V12_DNS_8_MODE_LIVE_SAFETY=UNVERIFIED')
    print('V12_GUI_CHANGES=UNVERIFIED')

    ok = len(stages) == 29 and not syntax_bad and not missing and safe
    print('REPO_INPUTS=' + ('PASS' if ok else 'INCOMPLETE'))
    print('PRODUCTION_IMAGE_RELEASE=BLOCKED_PENDING_V12_FUNCTIONAL_GATES')
    print('===== PRE-FLIGHT FINISHED =====')
    return 0 if ok else 2


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()
    sys.exit(audit(args.repo.resolve()))
