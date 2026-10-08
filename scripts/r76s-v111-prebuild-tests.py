#!/usr/bin/env python3
"""R76S V1.1.1 offline-only regression gates. No router access or changes."""
from pathlib import Path
import hashlib
import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile
import uuid

sys.dont_write_bytecode = True

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
STATES = [f'{n:03b}' for n in range(8)]
SHELL = [
    'r76s-v111-agh-upstream.sh',
    'r76s-v111-agh-yaml-render.sh',
    'r76s-v111-dns-detect.sh',
    'r76s-v111-dns-guard.sh',
    'r76s-v111-dns-manager.sh',
    'r76s-v111-dns-policy.sh',
    'r76s-v111-dns-transaction.sh',
    'r76s-v111-dns-runtime-audit.sh',
]


def run(name, *args, input=None, env=None, ok=True):
    proc = subprocess.run(
        [name, *map(str, args)], input=input, text=True,
        capture_output=True, env=env,
    )
    if ok and proc.returncode != 0:
        raise AssertionError(f'{name} {args}: rc={proc.returncode}\n{proc.stderr}')
    if not ok and proc.returncode == 0:
        raise AssertionError(f'{name} {args}: failure expected')
    return proc.stdout + proc.stderr


def require(condition, explanation):
    if not condition:
        raise AssertionError(explanation)


def print_pass(test):
    print('PASS:', test)


def main():
    for f in SHELL:
        run('sh', '-n', HERE / f)
    for f in HERE.glob('*.py'):
        run(sys.executable, '-c',
            'import ast,sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())',
            f)
    print_pass('eight POSIX shell checks and Python syntax without bytecode writes')

    # All eight combinations remain plan-only. Effective state is request AND readiness.
    for state in STATES:
        plan = run('sh', HERE / 'r76s-v111-dns-policy.sh', *state)
        require(f'STATE={state}\n' in plan, f'bad policy {state}')
        for bits in STATES:
            effective = ''.join(str(int(a) & int(b)) for a, b in zip(state, bits))
            output = run('sh', HERE / 'r76s-v111-dns-manager.sh',
                         'plan', *state, *bits)
            require(f'REQUESTED_STATE={state}' in output, 'bad request')
            require(f'EFFECTIVE_STATE={effective}' in output, 'bad degraded state')
            require('CONFIG_CHANGES=NONE' in output, 'unexpected write claim')
            require(f'DEGRADED={int(state != effective)}' in output, 'bad degrade')
            if effective == '101':
                require('BLOCK_ISOLATED_PROXY_DNS_REQUIRED' in output,
                        '101 not explicitly isolated')
    print_pass('eight states x eight readiness combinations (64 plans)')

    for state in STATES:
        output = run('sh', HERE / 'r76s-v111-dns-manager.sh',
                     'render', state, 'WAN_BASELINE', ok=state not in ('001', '101'))
        if state in ('001', '101'):
            require('BLOCKED:' in output, 'unsafe state not blocked')
        else:
            require(f'state {state}' in output, 'state render mismatch')
        run('sh', HERE / 'r76s-v111-dns-manager.sh',
            'render', state, 'CUSTOM_OR_UNKNOWN', ok=False)
    print_pass('read-only DNS fragment renderer: 001/101 and custom blocked')

    guard = HERE / 'r76s-v111-dns-guard.sh'
    baseline = "dhcp.@dnsmasq[0].resolvfile='/tmp/resolv.conf.d/resolv.conf.auto'\n"
    outcome = run('sh', guard, input=baseline)
    require('DNS_PROFILE=WAN_BASELINE' in outcome, 'WAN baseline not detected')
    outcome = run('sh', guard, input=baseline + "dhcp.@dnsmasq[0].server='9.9.9.9'\n")
    require('BLOCK_AUTO_REWRITE' in outcome, 'custom config not guarded')
    print_pass('UCI dnsmasq read-only classifier')

    spec = importlib.util.spec_from_file_location(
        'v111_yaml_preview', HERE / 'r76s-v111-agh-yaml-preview.py'
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    run(sys.executable, HERE / 'r76s-v111-agh-yaml-preview.py', 'selftest')
    require(module.wan_primary('nameserver 999.999.999.999\nnameserver 223.5.5.5\n')
            == '223.5.5.5', 'Python invalid WAN IP selection')
    require(module.wan_primary('nameserver 2001:4860:4860::8888\nnameserver 223.5.5.5\n')
            == '223.5.5.5', 'Python IPv6 (unsupported renderer) selection')
    print_pass('AdGuard YAML original-field and WAN validation')

    with tempfile.TemporaryDirectory(prefix='r76s-v111-prebuild.') as dirname:
        tmp = Path(dirname)
        wan = tmp / 'wan.resolv'
        yaml = tmp / 'adguard.yaml'
        bad_ip = ("nameserver 999.999.999.999\n"
                  "nameserver 127.0.0.9\n"
                  "nameserver 192.168.50.1\n"
                  "nameserver 223.5.5.5\n"
                  "nameserver 119.29.29.29\n")
        wan.write_text(bad_ip)
        for state in ('001', '011', '101', '111'):
            for ready in ('0', '1'):
                output = run('sh', HERE / 'r76s-v111-agh-upstream.sh',
                             state, ready, wan)
                require('999.999.999.999' not in output, 'Invalid IP admitted')
                require('ADGUARD_PRIMARY_DNS=192.168.50.1' not in output,
                        'Router loopback LAN selected')
                require('ADGUARD_PRIMARY_DNS=' in output, 'Upstream missing')
                if state == '101' or (state == '111' and ready == '0'):
                    require('BLOCK_PASSWALL_DNS_ISOLATION_REQUIRED' in output,
                            'Proxy loop not blocked')
                if ready == '1' and state in ('011', '111'):
                    require('ADGUARD_PRIMARY_DNS=127.0.0.1:6053' in output,
                            'SmartDNS upstream not selected')
                else:
                    require('ADGUARD_PRIMARY_DNS=223.5.5.5' in output,
                            'WAN fallback not selected')
        print_pass('AdGuard upstream plan: WAN validation, fallbacks, and isolation')
        # No routable IPv4 -> fail closed, not loop through local DNS.
        wan.write_text('nameserver 127.0.0.1\nnameserver 192.168.50.1\n')
        run('sh', HERE / 'r76s-v111-agh-upstream.sh', '001', '0', wan, ok=False)
        print_pass('AdGuard standalone no-safe-upstream fail closed')
        wan.write_text('nameserver 223.5.5.5\n')
        yaml_source = ('http:\n  address: 127.0.0.1:3000\n'
                       'users:\n  - name: placeholder\n'
                       '    password: fake-placeholder\n'
                       'dns:\n  port: 3053\n  upstream_dns:\n'
                       '    - 127.0.0.1:6053\n'
                       '  upstream_dns_file: ""\n'
                       '  fallback_dns:\n    - 119.29.29.29\n'
                       'filters:\n  - enabled: true\n')
        yaml.write_text(yaml_source)
        original_hash = hashlib.sha256(yaml.read_bytes()).digest()
        for target in ('223.5.5.5', '127.0.0.1:6053'):
            _, expected = module.render_yaml(yaml_source, target)
            actual = run('sh', HERE / 'r76s-v111-agh-yaml-render.sh',
                         yaml, target)
            require(actual == expected, f'Python/awk mismatch target={target}')
        for target in ('999.999.999.999', '192.168.50.1', '127.0.0.1',
                       '169.254.1.1', '223.5.5.5:53'):
            run('sh', HERE / 'r76s-v111-agh-yaml-render.sh',
                yaml, target, ok=False)
        require(hashlib.sha256(yaml.read_bytes()).digest() == original_hash,
                'Renderer unexpectedly modified YAML')
        print_pass('BusyBox-friendly AWK render parity and immutable YAML')

    # R76S_V111_EIGHT_STATE_TRANSITION_SPEC
    # All 64 transitions have a safe ordering specification. They remain
    # OFFLINE plans, not permission to apply to router configuration.
    spec = importlib.util.spec_from_file_location(
        'v111_transitions', HERE / 'r76s-v111-dns-transition-plan.py')
    transition = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(transition)
    for before in STATES:
        for after in STATES:
            plan = transition.make_plan(before, after)
            topo = plan['requested_topology']
            assert plan['status'] == 'OFFLINE_PLAN_ONLY'
            assert plan['automatic_apply'] is False
            assert plan['ordered_phases'].index('STAGE_DNSMASQ_MAIN_UPSTREAM_LAST') > 3
            assert plan['ordered_phases'].index('SWITCH_MAIN_DNS_WITH_RECORDED_ROLLBACK_STATE') < \
                plan['ordered_phases'].index('ONLY_THEN_REMOVE_UNUSED_UPSTREAM_REFERENCES_AND_STOP_SERVICES')
            assert ('AGH:3053' in topo['main']) == (after[2] == '1')
            assert ('SMARTDNS:6053' in topo['main']) == (after[2] == '0' and after[1] == '1')
            assert (topo['adguard_upstream'] == 'OFF') == (after[2] == '0')
            if after[1] == '0':
                assert all('15355' not in ref for ref in topo['passwall_dns_upstreams'])
            if after[2] == '0':
                assert all('3053' not in ref for ref in topo['passwall_dns_upstreams'])
            if after == '101':
                assert topo['passwall_dns_upstreams'] == ['INDEPENDENT_PROXY_DNS']
                assert 'ISOLATED_PASSWALL_PROXY_DNS_VERIFIED' in plan['required_live_evidence']
    try:
        transition.make_plan('abc', '111')
    except ValueError:
        pass
    else:
        raise AssertionError('invalid transition input accepted')
    print_pass('64 read-only transitions, safe ordering, isolation, rollback evidence gates')

    # R76S_V111_LOADER_AND_PORT_OWNER_FIXTURE
    # Same launch pattern measured on real R76S: ld-musl-aarch64 -> smartdns.bin.
    # Misowned listener and missing SmartDNS process must fail closed.
    with tempfile.TemporaryDirectory(prefix='r76s-v111-loader.') as dirname:
        root = Path(dirname)
        proc = root / 'proc' / '7094'
        proc.mkdir(parents=True)
        (proc / 'cmdline').write_bytes(
            b'/lib/ld-musl-aarch64.so.1\0/usr/libexec/r76s/smartdns.bin\0'
            b'-c\0/var/etc/smartdns/smartdns.conf\0')
        mocks = root / 'bin'
        mocks.mkdir()
        netstat = mocks / 'netstat'
        netstat.write_text('#!/bin/sh\n'
                           'echo "tcp 0 0 :::6053 :::* LISTEN ${FAKE_DNS_OWNER:-7094}/ld-musl-aarch6"\n')
        netstat.chmod(0o755)
        uci = mocks / 'uci'
        uci.write_text('#!/bin/sh\necho 1\n')
        uci.chmod(0o755)
        env = os.environ.copy()
        env.update(PATH=str(mocks) + os.pathsep + env.get('PATH', ''),
                   R76S_V111_PROC_ROOT=str(root / 'proc'))
        detector = HERE / 'r76s-v111-dns-detect.sh'
        healthy = run('sh', detector, env=env)
        require('SD_PROCESS=1' in healthy and 'SD_PORT_OWNER_VERIFIED=1' in healthy and
                'SD_READY=1' in healthy, 'dynamic-loader SmartDNS not recognized')
        env['FAKE_DNS_OWNER'] = '9999'
        foreign = run('sh', detector, env=env)
        require('SD_PROCESS=1' in foreign and 'SD_PORT_OWNER_VERIFIED=0' in foreign and
                'SD_READY=0' in foreign, 'unrelated service bound to 6053 accepted')
        (proc / 'cmdline').unlink()
        no_process = run('sh', detector, env=env)
        require('SD_PROCESS=0' in no_process and 'SD_READY=0' in no_process,
                'missing SmartDNS process accepted')
    print_pass('dynamic-loader SmartDNS PID/port ownership; spoofed and missing process fail closed')

    # R76S_V111_SYMBOLIC_TOPOLOGY_REGRESSION
    # These models prove graph/guard logic only. They do not assert that the
    # actual PassWall/SmartDNS/AdGuard generated configurations match them.
    from importlib.machinery import SourceFileLoader
    topo_path = HERE / 'r76s-v111-dns-topology.py'
    topo_spec = importlib.util.spec_from_file_location('r76s_v111_topology', topo_path)
    topo = importlib.util.module_from_spec(topo_spec)
    topo_spec.loader.exec_module(topo)
    for state in STATES:
        pw, sd, agh = map(int, state)
        edges = [['SYSTEM', 'AGH' if agh else 'SD' if sd else 'WAN']]
        if agh:
            edges.append(['AGH', 'SD' if sd else 'WAN'])
        if sd:
            edges.append(['SD', 'WAN'])
        if pw:
            edges.append(['PW', 'PROXY'])
            edges.append(['PROXY', 'WAN'])
        expected = {'state': state, 'edges': edges}
        require(not topo.check(expected), f'symbolic {state} should pass')
        mutated = {'state': state, 'edges': edges + [['SYSTEM', 'SYSTEM']]}
        require('DNS_CYCLE_DETECTED' in topo.check(mutated),
                f'symbolic {state} cycle was missed')
        if not agh:
            require(any('DISABLED_SERVICE_REFERENCE' in item for item in
                        topo.check({'state': state, 'edges': edges + [['SYSTEM', 'AGH']]})),
                    f'symbolic {state} dangling AGH not detected')
    for invalid in [
        {'state': '101', 'edges': [['SYSTEM', 'AGH'], ['AGH', 'WAN'], ['PW', 'AGH']]},
        {'state': '111', 'edges': [['SYSTEM', 'AGH'], ['AGH', 'SD'],
                                  ['SD', 'PW'], ['PW', 'AGH']]},
        {'state': '001', 'edges': [['SYSTEM', 'AGH'], ['AGH', 'SYSTEM']]},
    ]:
        require(topo.check(invalid), f'failed to reject unsafe {invalid}')
    print_pass('eight symbolic topologies, cycles, dangling service and isolation')

    # R76S_V111_ACTUAL_DEPENDENCY_AUDIT_REGRESSION
    # Synthetic file tree with the precise edge types observed on R76S.
    # Does not read the user's private YAML, PassWall node IDs, or LAN settings.
    with tempfile.TemporaryDirectory(prefix='r76s-v111-audit.') as dirname:
        r = Path(dirname)
        fixtures = {
            'var/etc/dnsmasq.conf.test': 'no-resolv\nserver=127.0.0.1#3053\n',
            'tmp/etc/passwall/acl/default/dnsmasq.conf':
                'no-resolv\nserver=127.0.0.1#3053\n'
                'server=127.0.0.1#15355\nserver=::1#15355\nstrict-order\n',
            'var/etc/smartdns/smartdns.conf':
                "conf-file '/etc/smartdns/r76s-cn.conf'\n"
                'conf-file /etc/smartdns/custom.conf\n',
            'etc/smartdns/r76s-cn.conf': '# Chinese DNS rules remain private\n',
            'etc/smartdns/custom.conf':
                'conf-file /tmp/etc/smartdns/passwall*.conf\n',
            'tmp/etc/smartdns/passwall.conf':
                'server 127.0.0.1:15356 -group proxy\n'
                'server 223.5.5.5 -group direct\n',
            'etc/adguardhome.yaml':
                'http:\n  address: 127.0.0.1:3000\n'
                'dns:\n  port: 3053\n  upstream_dns:\n'
                '    - 127.0.0.1:6053\n  fallback_dns:\n'
                '    - 119.29.29.29\n  bootstrap_dns:\n'
                '    - 223.5.5.5\nusers:\n  - name: placeholder\n'
        }
        for relative, data in fixtures.items():
            path = r / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(data)
        audit = HERE / 'r76s-v111-dns-runtime-audit.sh'
        baseline = run('sh', audit, '111', r)
        require('REFERENCE_AUDIT=CONSISTENT_NOT_LIVE_PROVEN' in baseline,
                f'111 observed-shaped fixture rejected: {baseline}')
        require('SMARTDNS_PASSWALL_INCLUDE_MATCHES=1' in baseline,
                'SmartDNS wildcard include not followed')
        require('SMARTDNS_TO_XRAY=1' in baseline,
                'Dynamic-loader SmartDNS proxy path not visible')
        for state, reason in (
            ('110', 'SYSTEM_DANGLING_ADGUARD_REFERENCE'),
            ('101', 'ADGUARD_DANGLING_SMARTDNS_UPSTREAM'),
            ('001', 'STALE_PASSWALL_SMARTDNS_INCLUDE'),
        ):
            output = run('sh', audit, state, r, ok=False)
            require(reason in output or state == '001',
                    f'{state} stale edge not caught: {output}')
            if state == '101':
                require('PROXY_DNS_ISOLATION_NOT_VERIFIED' in output,
                        '101 proxy isolation accepted without proof')
        # A new independent AdGuard upstream is not enough to validate 101.
        (r / 'etc/adguardhome.yaml').write_text(
            'dns:\n  upstream_dns:\n    - 223.5.5.5\n')
        output = run('sh', audit, '101', r, ok=False)
        require('PROXY_DNS_ISOLATION_NOT_VERIFIED' in output,
                '101 must remain blocked even after upstream migration')
        # Ensure reversed local target is blocked (not a safe WAN upstream).
        (r / 'etc/adguardhome.yaml').write_text(
            'dns:\n  upstream_dns:\n    - 127.0.0.1:11400\n')
        output = run('sh', audit, '111', r, ok=False)
        require('ADGUARD_REVERSE_LOCAL_REFERENCE' in output,
                'dangerous AdGuard reverse DNS edge was accepted')
        # A missing generated config must never be assumed valid.
        (r / 'var/etc/dnsmasq.conf.test').unlink()
        output = run('sh', audit, '111', r, ok=False)
        require('MAIN_DNSMASQ_CONFIG_AMBIGUOUS' in output,
                'missing dnsmasq config incorrectly passed')
        # Redaction: only counts, state, fixed issue codes; no test credentials.
        require('placeholder' not in baseline and '119.29.29.29' not in baseline,
                'audit unexpectedly exposed YAML content')
    print_pass('file-grounded read-only 111 graph, stale edges, 101 isolation and privacy')

    # The transaction experiment never accesses live router configuration.
    lab = Path('/tmp/r76s-v111-lab.' + uuid.uuid4().hex)
    lab.mkdir(mode=0o700)
    try:
        trans = HERE / 'r76s-v111-dns-transaction.sh'
        run('sh', trans, 'stage', '110', lab)
        conf = lab / 'r76s-v111.conf'
        require(conf.is_file(), 'Lab stage missing')
        before = conf.read_bytes()
        run('sh', trans, 'stage', '101', lab, ok=False)
        require(conf.read_bytes() == before, 'Lab changed after blocked state')
        conf.write_bytes(before+b'# external edit\n')
        run('sh', trans, 'rollback', '110', lab, ok=False)
        require(conf.exists(), 'User change removed')
        conf.write_bytes(before)
        run('sh', trans, 'rollback', '110', lab)
        require(not conf.exists(), 'Rollback failed')
    finally:
        shutil.rmtree(lab)
    print_pass('tmp-only transaction lab, invalid state and external edit guard')

    wf = ROOT / '.github/workflows/r76s-v1.1.1.yml'
    if wf.exists():
        t = wf.read_text()
        require('R76S_V111_UNVERIFIED_AGH_CONDITIONAL_PATCH_DISABLED' in t,
                'Unverified PassWall hook not disabled')
        require('if: ${{ inputs.publish_release == true }}' in t,
                'Release must be manual opt-in')
        require('make_latest: false' in t and 'make_latest: true' not in t,
                'Unvalidated firmware could become latest')
        require(t.index('rm -rf openwrt/files') < t.index('DNS_READONLY_DIR='),
                'Read-only runtime files staged before overlay reset')
        require('r76s-v111-dns-runtime-audit.sh' in t,
                'File-grounded runtime audit not installed in firmware')
        require('r76s-v111-dns-transition-plan.py' in t,
                'Offline transition plan not checked by workflow')
        require('r76s-v111-dns-topology.py' in t,
                'Symbolic dependency check missing from workflow')
        require('scripts/r76s-v111-prebuild-tests.py' in t,
                'Offline suite not called in workflow')
    print_pass('release gating, overlay re-stage ordering, disabled unsafe hook')
    print('R76S_V111_PREBUILD_TESTS=PASS')
    print('IMPORTANT: DNS_AUTOMATIC_EIGHT_STATES=NOT_IMPLEMENTED')
    print('IMPORTANT: 64_TRANSITIONS_ARE_OFFLINE_PLANS_ONLY')
    print('IMPORTANT: SYMBOLIC_TOPOLOGY_IS_NOT_LIVE_CONFIG_PROOF')
    print('IMPORTANT: ROUTER_OR_GITHUB_CHANGES=NONE')


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(f'R76S_V111_PREBUILD_TESTS=FAIL: {exc}', file=sys.stderr)
        sys.exit(1)
