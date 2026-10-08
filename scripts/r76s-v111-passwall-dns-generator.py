#!/usr/bin/env python3
"""V1.1.1 build-only PassWall DNS generator guard; never touches router state.

Legacy app.sh 3053 injection: gate generation on AGH process and TCP/UDP
loopback listeners. No legacy injection: retain upstream defaults unmodified.
This is NOT a live eight-state manager or runtime removal of stale references.
"""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile
import os

LEGACY_START = '# R76S_AGH_FULLCHAIN_BEGIN'
LEGACY_END = '# R76S_AGH_FULLCHAIN_END'
GUARD_START = '# R76S_V111_AGH_GENERATOR_READY_GATE_BEGIN'
GUARD_END = '# R76S_V111_AGH_GENERATOR_READY_GATE_END'
GUARD = """# R76S_V111_AGH_GENERATOR_READY_GATE_BEGIN
# Build-time fallback for legacy R76S injection. DNS restarts still require an
# external audited manager; this only gates generation, not subsequent shutdown.
if [ "${DNS_SHUNT}" = "smartdns" ] &&
   command -v netstat >/dev/null 2>&1 &&
   pidof AdGuardHome >/dev/null 2>&1 &&
   netstat -lntup 2>/dev/null | awk '
     $1 ~ /^tcp/ && $4 == "127.0.0.1:3053" && $NF ~ /[0-9]+\\/AdGuardHome$/ {tcp=1}
     $1 ~ /^udp/ && $4 == "127.0.0.1:3053" && $NF ~ /[0-9]+\\/AdGuardHome$/ {udp=1}
     END {exit !(tcp && udp)}'; then
    # Portable across BusyBox and macOS: avoid sed -i and BSD sed's i syntax.
    if grep -qFx "server=127.0.0.1#${SMARTDNS_LISTEN_PORT}" "${GLOBAL_DNSMASQ_CONF}"; then
        _r76s_agh_existing=0
        if grep -qFx 'server=127.0.0.1#3053' "${GLOBAL_DNSMASQ_CONF}"; then
            _r76s_agh_existing=1
        fi
        _r76s_agh_tmp=$(mktemp "${GLOBAL_DNSMASQ_CONF}.agh.XXXXXX") || exit 1
        if cp -p "${GLOBAL_DNSMASQ_CONF}" "${_r76s_agh_tmp}" &&
           awk -v marker="server=127.0.0.1#${SMARTDNS_LISTEN_PORT}" \\
               -v existing="${_r76s_agh_existing}" '
             $0 == marker && !inserted {
                 if (existing != "1") print "server=127.0.0.1#3053"
                 inserted=1
             }
             $0 == "all-servers" { print "strict-order"; next }
             { print }
             END { if (!inserted) exit 1 }
           ' "${GLOBAL_DNSMASQ_CONF}" > "${_r76s_agh_tmp}"; then
            if ! mv -f "${_r76s_agh_tmp}" "${GLOBAL_DNSMASQ_CONF}"; then
                rm -f "${_r76s_agh_tmp}"
                echo 'R76S: could not update generated PassWall DNS config' >&2
                exit 1
            fi
        else
            rm -f "${_r76s_agh_tmp}"
            echo 'R76S: refused incomplete PassWall DNS config rewrite' >&2
            exit 1
        fi
    fi
fi
# R76S_V111_AGH_GENERATOR_READY_GATE_END
"""

LEGACY_PATTERN = re.compile(r'(?m)^' + re.escape(LEGACY_START) +
                            r'\n.*?^' + re.escape(LEGACY_END) + r'[ \t]*(?:\n|$)', re.S)
GUARD_PATTERN = re.compile(r'(?m)^' + re.escape(GUARD_START) +
                           r'\n.*?^' + re.escape(GUARD_END) + r'[ \t]*(?:\n|$)', re.S)


def check_helper(text):
    """Treat unseen upstream generator code as unsafe rather than guessing."""
    required = [
        r'function\s+stretch\s*\(',
        r'function\s+logic_restart\s*\(',
        r'function\s+copy_instance\s*\(',
        r'function\s+add_rule\s*\(',
        r'api\.uci_(?:del|set)\("dhcp",\s*"@dnsmasq\[0\]",\s*"noresolv"',
        r'api\.uci_set\("dhcp",\s*"@dnsmasq\[0\]",\s*"server"',
        r'"no-resolv"',
    ]
    missing = [pattern for pattern in required if not re.search(pattern, text)]
    if missing:
        raise ValueError('PASSWALL_DNSMASQ_HELPER_LAYOUT_UNRECOGNIZED')


def transform(app):
    for name, pattern in ((LEGACY_START, LEGACY_PATTERN), (GUARD_START, GUARD_PATTERN)):
        count = app.count(name)
        if count > 1:
            raise ValueError('DUPLICATE_' + name)
    legacy = list(LEGACY_PATTERN.finditer(app))
    guards = list(GUARD_PATTERN.finditer(app))
    if (LEGACY_START in app or LEGACY_END in app) and len(legacy) != 1:
        raise ValueError('MALFORMED_LEGACY_AGH_BLOCK')
    if (GUARD_START in app or GUARD_END in app) and len(guards) != 1:
        raise ValueError('MALFORMED_GUARDED_AGH_BLOCK')
    if legacy and guards:
        raise ValueError('MIXED_LEGACY_AND_GUARDED_BLOCKS')
    if guards:
        if guards[0].group().rstrip() != GUARD.rstrip():
            raise ValueError('UNKNOWN_GUARDED_CODE')
        return app, 'ALREADY_GUARDED'
    if not legacy:
        # Upstream without custom 3053 injection is already appropriate.
        if 'server=127.0.0.1#3053' in app:
            raise ValueError('UNSCOPED_3053_REFERENCE_FOUND')
        return app, 'NO_LEGACY_INJECTION'
    original = legacy[0].group()
    if ('sed -i' not in original or
        'server=127.0.0.1#3053' not in original or
        'strict-order' not in original or
        '"${DNS_SHUNT}" = "smartdns"' not in original):
        raise ValueError('UNEXPECTED_LEGACY_AGH_BLOCK')
    if app.count('server=127.0.0.1#3053') != 1:
        raise ValueError('OTHER_3053_REFERENCES')
    return app[:legacy[0].start()] + GUARD + app[legacy[0].end():], 'LEGACY_GATED'


def invoke_guard(block, state, proc_ok=True, tcp=True, udp=True, owner=True,
                 source="server=127.0.0.1#15355\nall-servers\n"):
    with tempfile.TemporaryDirectory(prefix='v111-generator-guard-') as t:
        root = Path(t); bins = root/'bin'; bins.mkdir()
        (bins/'pidof').write_text('#!/bin/sh\nexit ' + ('0' if proc_ok else '1') + '\n')
        (bins/'netstat').write_text('#!/bin/sh\ncat <<\\EOF\n' +
            ('tcp 0 0 127.0.0.1:3053 0.0.0.0:* LISTEN 123/'+('AdGuardHome' if owner else 'OtherDns')+'\n' if tcp else '') +
            ('udp 0 0 127.0.0.1:3053 0.0.0.0:* 123/'+('AdGuardHome' if owner else 'OtherDns')+'\n' if udp else '') +
            'EOF\n')
        for f in bins.iterdir(): f.chmod(0o755)
        conf = root/'dnsmasq.conf'
        conf.write_text(source)
        env = os.environ.copy()
        env.update(PATH=str(bins)+os.pathsep+env.get('PATH',''), DNS_SHUNT=state,
                   SMARTDNS_LISTEN_PORT='15355', GLOBAL_DNSMASQ_CONF=str(conf))
        script = root/'probe.sh'; script.write_text('#!/bin/sh\nset -eu\n'+block)
        p = subprocess.run(['sh', '-n', str(script)],capture_output=True,text=True)
        assert p.returncode == 0, p.stderr
        for _ in range(2):
            p = subprocess.run(['sh', str(script)], env=env,capture_output=True,text=True)
            assert p.returncode == 0, p.stderr
        assert not list(root.glob('dnsmasq.conf.agh.*')), 'temporary files leaked'
        return conf.read_text()


def selftest():
    original = ("# R76S_AGH_FULLCHAIN_BEGIN\n"
                "# Prefer AdGuard Home, fall back to PassWall SmartDNS.\n"
                '[ "${DNS_SHUNT}" = "smartdns" ] && {\n'
                'sed -i \\\n-e "/^server=127\\.0\\.0\\.1#${SMARTDNS_LISTEN_PORT}$/i server=127.0.0.1#3053" \\\n'
                '-e "s/^all-servers$/strict-order/" \\\n${GLOBAL_DNSMASQ_CONF}\n}\n'
                "# R76S_AGH_FULLCHAIN_END\n")
    app = '#!/bin/sh\n' + original
    updated, action = transform(app)
    assert action == 'LEGACY_GATED'
    assert transform(updated) == (updated, 'ALREADY_GUARDED')
    assert transform('#!/bin/sh\necho clean\n')[1] == 'NO_LEGACY_INJECTION'
    for bad in [original + original, original.replace('strict-order', 'all-servers'),
                original.replace('3053', '6053')]:
        try: transform(bad)
        except ValueError: pass
        else: raise AssertionError('unsafe legacy template accepted')
    base = invoke_guard(GUARD, 'smartdns',True,True,True)
    assert base == 'server=127.0.0.1#3053\nserver=127.0.0.1#15355\nstrict-order\n'
    preexisting = invoke_guard(GUARD, 'smartdns', source=base)
    assert preexisting == base, 'already-managed config was changed'
    missing = invoke_guard(GUARD, 'smartdns', source='server=9.9.9.9\nall-servers\n')
    assert missing == 'server=9.9.9.9\nall-servers\n', 'missing anchor modified'
    for kw in [dict(state='dnsmasq'), dict(state='smartdns',proc_ok=False),
               dict(state='smartdns',tcp=False),dict(state='smartdns',udp=False),
               dict(state='smartdns',owner=False)]:
        conf = invoke_guard(GUARD, **kw)
        assert '3053' not in conf and 'all-servers' in conf, kw
    print('PASSWALL_GENERATOR_GATE_SELFTEST=PASS')
    print('REAL_RUNTIME_TEARDOWN=NOT_IMPLEMENTED')


def main():
    ap=argparse.ArgumentParser()
    modes=ap.add_mutually_exclusive_group(required=True)
    modes.add_argument('--patch',action='store_true')
    modes.add_argument('--verify',action='store_true')
    modes.add_argument('--selftest',action='store_true')
    ap.add_argument('app',nargs='?')
    ap.add_argument('helper',nargs='?')
    args=ap.parse_args()
    if args.selftest:
        selftest();return
    if not args.app or not args.helper:
        ap.error('app.sh and helper_dnsmasq.lua required')
    app_path=Path(args.app)
    helper_path=Path(args.helper)
    check_helper(helper_path.read_text(encoding='utf-8'))
    app=app_path.read_text(encoding='utf-8')
    updated, action=transform(app)
    if args.patch and updated!=app:
        app_path.write_text(updated,encoding='utf-8')
    if args.verify and updated!=app:
        raise ValueError('UNGATED_LEGACY_AGH_INJECTION')
    print('PASSWALL_DNS_GENERATOR_LAYOUT=VERIFIED')
    print('PASSWALL_AGH_GATE='+action)
    print('DNS_EIGHT_STATE_AUTO_APPLY=NOT_IMPLEMENTED')


if __name__=='__main__':
    try: main()
    except (OSError, ValueError, AssertionError) as ex:
        raise SystemExit('BLOCKED: '+str(ex))
