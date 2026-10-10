#!/usr/bin/env python3
"""Conservative idempotent adapter; modifies ONLY selected local-source files.
Stops without writes if expected anchors differ, saves timestamped backups.
Does not compile, publish or modify any router.
"""
from pathlib import Path
from datetime import datetime
import argparse, os, re, shutil, tempfile

MARKER = 'R76S_V12_PUBLIC_CREDENTIALS_20261010'
SERIAL_NAME = '05-r76s-public-serial-provision'
SERIAL_SCRIPT = r'''#!/bin/sh
# R76S_V12_PUBLIC_CREDENTIALS_20261010
# Fresh public-image bootstrap: physical UART console only. No network default secret.
set -eu
field="$(sed -n 's/^root:\([^:]*\):.*/\1/p' /etc/shadow)"
[ "$field" = '!' ] || exit 0  # OTA with existing root hash must not be overwritten
# REQUIRE physical serial console on FIRST boot; no passphrase is printed to syslog/network.
[ -c /dev/ttyS0 ] || { echo 'R76S: UART not detected; root remains locked' >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo 'R76S: openssl absent; root remains locked' >&2; exit 1; }
command -v base64 >/dev/null 2>&1 || exit 1
secret="$(dd if=/dev/urandom bs=24 count=1 2>/dev/null | base64 | tr -d '\r\n')"
[ "${#secret}" -ge 32 ] || exit 1
hash="$(printf '%s\n' "$secret" | openssl passwd -6 -stdin)"
case "$hash" in \$6\$*) ;; *) exit 1 ;; esac
# On initial setup root is deliberately disabled. Replace only that exact field.
sed -i "s#^root:!:#root:${hash}:#" /etc/shadow
chmod 0600 /etc/shadow
[ "$(sed -n 's/^root:\([^:]*\):.*/\1/p' /etc/shadow)" = "$hash" ] || exit 1
{
  printf '\r\n================ R76S FIRST BOOT ================\r\n'
  printf 'Device-generated root password (record it securely):\r\n%s\r\n' "$secret"
  printf 'Set a new password immediately after login: passwd\r\n'
  printf 'Password appears ONCE on local physical UART console only.\r\n'
  printf '=================================================\r\n'
} > /dev/ttyS0 || exit 1
unset secret hash
exit 0
'''

def once(s,old,new,label):
    if s.count(old)!=1: raise ValueError(f'{label}: expected one anchor, got {s.count(old)}')
    return s.replace(old,new,1)

def transform_stage16(s):
    original = '''PASSWORD_HASH="${R76S_CLEAN_FLASH_PASSWORD_HASH:-}"
if [[ ! "$PASSWORD_HASH" =~ ^\\$6\\$[A-Za-z0-9./]{8,16}\\$[A-Za-z0-9./]{86}$ ]]; then # R76S_V12_SECURITY_GATE_20261010
    echo "ERROR: Unique clean-flash root password hash required." >&2
    exit 1
fi
test -n "$PASSWORD_HASH"
sed -i "s#^root:[^:]*:#root:${PASSWORD_HASH}:#" "$SHADOW"
grep -qF "root:${PASSWORD_HASH}:" "$SHADOW"
'''
    replacement = '''# R76S_V12_PUBLIC_CREDENTIALS_20261010
if [ "${R76S_PUBLIC_RELEASE:-0}" = '1' ]; then
    test -z "${R76S_CLEAN_FLASH_PASSWORD_HASH:-}" || { echo 'Public image refuses a supplied root hash' >&2; exit 1; }
    # No reusable root authentication material is distributed in public binaries.
    sed -i 's#^root:[^:]*:#root:!:#' "$SHADOW"
    grep -q '^root:!:' "$SHADOW"
    mkdir -p openwrt/files/etc/uci-defaults
    cat > openwrt/files/etc/uci-defaults/05-r76s-public-serial-provision <<'R76S_PUBLIC_SERIAL'
''' + SERIAL_SCRIPT + '''R76S_PUBLIC_SERIAL
    chmod 0755 openwrt/files/etc/uci-defaults/05-r76s-public-serial-provision
else
    # Private per-owner candidate, NEVER publish to public GitHub Releases.
    PASSWORD_HASH="${R76S_CLEAN_FLASH_PASSWORD_HASH:-}"
    if [[ ! "$PASSWORD_HASH" =~ ^\\$6\\$[A-Za-z0-9./]{8,16}\\$[A-Za-z0-9./]{86}$ ]]; then
        echo 'ERROR: Private candidate requires unique SHA-512 crypt root password hash.' >&2
        exit 1
    fi
    sed -i "s#^root:[^:]*:#root:${PASSWORD_HASH}:#" "$SHADOW"
    grep -qF "root:${PASSWORD_HASH}:" "$SHADOW"
    # Prevent stale public provisioning script leaking into a private image.
    rm -f openwrt/files/etc/uci-defaults/05-r76s-public-serial-provision
afi
'''.replace('\nafi\n','\nfi\n')
    return once(s,original,replacement,'Stage16 password block')

def transform_candidate(s):
    start=s.index('# Require an independently chosen clean-flash login secret')
    end=s.index('# Required staging inputs must be present',start)
    segment=s[start:end]
    if 'R76S_V12_PUBLIC_CREDENTIALS' in segment: raise ValueError('already patched')
    # Keep existing hash checks/private prompt intact, wrap them in a private-only branch.
    wrapped="""# R76S_V12_PUBLIC_CREDENTIALS_20261010
R76S_PUBLIC_RELEASE="${R76S_PUBLIC_RELEASE:-0}"
case "$R76S_PUBLIC_RELEASE" in 0|1) ;; *) echo 'R76S_PUBLIC_RELEASE must be 0 or 1' >&2; exit 2;; esac
export R76S_PUBLIC_RELEASE
if [ "$R76S_PUBLIC_RELEASE" = 1 ]; then
  [ -z "${R76S_CLEAN_FLASH_PASSWORD_HASH:-}" ] || { echo 'Public image forbids build-supplied root hash' >&2; exit 2; }
  echo 'PUBLIC_ROOT_CREDENTIAL_MODE=SERIAL_FIRST_BOOT'
else
"""+segment+"fi\n"
    s=s[:start]+wrapped+s[end:]
    s=once(s,'  --env R76S_CLEAN_FLASH_PASSWORD_HASH \\\n', '  --env R76S_CLEAN_FLASH_PASSWORD_HASH \\\n  --env R76S_PUBLIC_RELEASE \\\n','candidate Docker public env')
    return s

def transform_audit(s):
    old="""    value = roots[0]
    if not re.fullmatch(r'\\$6\\$[A-Za-z0-9./]{8,16}\\$[A-Za-z0-9./]{86}', value):
"""
    new="""    value = roots[0]
    # R76S_V12_PUBLIC_CREDENTIALS_20261010
    if os.environ.get('R76S_PUBLIC_RELEASE') == '1':
        if value != '!':
            return ['PUBLIC_IMAGE_ROOT_NOT_LOCKED_OR_EMBEDS_HASH']
        firstboot = root / 'etc/uci-defaults/05-r76s-public-serial-provision'
        if not firstboot.is_file() or not (firstboot.stat().st_mode & stat.S_IXUSR):
            return ['PUBLIC_SERIAL_FIRSTBOOT_MISSING_OR_NOT_EXECUTABLE']
        if b'R76S_V12_PUBLIC_CREDENTIALS_20261010' not in firstboot.read_bytes():
            return ['PUBLIC_SERIAL_FIRSTBOOT_UNRECOGNIZED']
        if not (root / 'usr/bin/openssl').is_file():
            return ['PUBLIC_OPENSSL_RUNTIME_MISSING']
        return []
    if not re.fullmatch(r'\\$6\\$[A-Za-z0-9./]{8,16}\\$[A-Za-z0-9./]{86}', value):
"""
    s = once(s,old,new,'audit root shadow')
    s = once(s, "    root_pathlist = list(dict.fromkeys((*REQUIRED, *BANNED, *LMO, 'etc')))\n", "    root_pathlist = list(dict.fromkeys((*REQUIRED, *BANNED, *LMO, 'etc')))\n    if os.environ.get('R76S_PUBLIC_RELEASE') == '1':\n        root_pathlist.append('usr/bin/openssl')\n", 'public image openssl extraction')
    return s

def transform_info(s):
    if 'System login: $(if [ ' in s and 'PRIVATE image includes build-supplied root hash' in s:
        return s
    old="  'System login: root with a unique build-supplied SHA-512 crypt hash; no shared default password' \\\n"
    new="  \"System login: ${R76S_PUBLIC_RELEASE:+public clean-flash serial provisioning; old OTA credentials MUST be preserved and verified}\" \\\n"
    # Prefer stable no-substitution comment: dynamic line based on public flag.
    return once(s,old,"  \"System login: $(if [ \"${R76S_PUBLIC_RELEASE:-0}\" = 1 ]; then echo 'fresh flash uses one-time UART password; OTA MUST preserve existing credentials'; else echo 'PRIVATE image includes build-supplied root hash; DO NOT PUBLISH'; fi)\" \\\n",'stage24 text')


def transform_stage19(s):
    needle='echo "R76S v1.1.1 configuration verified successfully."'
    extra="""# R76S_V12_PUBLIC_CREDENTIALS_20261010
if [ "${R76S_PUBLIC_RELEASE:-0}" = 1 ]; then
    grep -qxF 'CONFIG_PACKAGE_openssl-util=y' .config || {
       echo 'ERROR: public firstboot requires openssl-util in final config' >&2; exit 1;
    }
    test -x files/etc/uci-defaults/05-r76s-public-serial-provision
    sh -n files/etc/uci-defaults/05-r76s-public-serial-provision
fi
"""
    return once(s,needle,extra+'\n'+needle,'Stage19 public provisioning contract')

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--repo',type=Path,required=True)
    ap.add_argument('--check',action='store_true')
    args=ap.parse_args()
    root=args.repo.expanduser().resolve()
    stage16=list((root/'build/local-arm64/stages').glob('16-*.sh'))
    if len(stage16)!=1: raise SystemExit('ERROR: unexpected Stage16 path')
    files={
      stage16[0]:transform_stage16,
      root/'build/local-arm64/candidate-local.sh':transform_candidate,
      root/'scripts/r76s-v111-final-audit.py':transform_audit,
      root/'build/local-arm64/stages/19-verify-final-r76s-configuration.sh':transform_stage19,
      root/'build/local-arm64/stages/24-create-final-v1-1-1-image-and-release-metadata.sh':transform_info,
    }
    planned={}
    for path,func in files.items():
      if not path.is_file(): raise SystemExit(f'ERROR: missing {path}')
      s=path.read_text()
      if MARKER in s:
        print('ALREADY_PATCHED',path.relative_to(root))
        continue
      try:
        revised=func(s)
        if revised != s: planned[path]=revised
        else: print('ALREADY_PATCHED',path.relative_to(root))
      except (ValueError,IndexError) as e: raise SystemExit(f'ERROR: no changes made: {path.name}: {e}')
    config=root/'config/R76S.config'
    sc=config.read_text()
    if 'CONFIG_PACKAGE_openssl-util=y' not in sc:
      if 'CONFIG_PACKAGE_ca-certificates=y' not in sc:
        raise SystemExit('ERROR: no changes made: config package anchor missing')
      planned[config]=once(sc,'CONFIG_PACKAGE_ca-certificates=y', 'CONFIG_PACKAGE_ca-certificates=y\nCONFIG_PACKAGE_openssl-util=y','openssl-util config')
    if args.check:
      for p in planned: print('WOULD_PATCH',p.relative_to(root))
      print('PREFLIGHT_PATCH_ANCHORS=PASS')
      return
    backup=Path.home()/'Documents'/('R76S-public-release-source-backup-'+datetime.now().strftime('%Y%m%d-%H%M%S'))
    backup.mkdir(parents=True,exist_ok=False)
    for path in planned:
      old=backup/path.relative_to(root)
      old.parent.mkdir(parents=True,exist_ok=True)
      shutil.copy2(path,old)
    for path,data in planned.items():
      temp=path.with_name(path.name+'.public-tmp')
      temp.write_text(data)
      os.chmod(temp,path.stat().st_mode)
      os.replace(temp,path)
      print('PATCHED',path.relative_to(root))
    print('BACKUP_DIR',backup)
    print('PUBLIC_RELEASE_ADAPTER=INSTALLED; PRODUCTION_GATES_STILL_BLOCKED')

if __name__=='__main__':main()
