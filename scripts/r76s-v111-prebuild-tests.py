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
    'r76s-v111-dns-runtime-manager.sh',
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
        # macOS tar/xattr handling can create AppleDouble sidecars such as
        # ._script.py; they are metadata, not Python source files.
        if f.name.startswith('._'):
            continue
        run(sys.executable, '-c',
            'import ast,sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())',
            f)
    print_pass('nine POSIX shell checks and Python syntax without bytecode writes')

    # R76S_V111_PASSWALL_DNS_GENERATOR_BUILD_GUARD
    # Check real-world templates separately when the upstream clone is present.
    # The internal test exercises legacy injection, no-injection, missing
    # AdGuard process or TCP/UDP port and repeated generation.
    result = run(sys.executable, HERE / 'r76s-v111-passwall-dns-generator.py', '--selftest')
    require('PASSWALL_GENERATOR_GATE_SELFTEST=PASS' in result,
            'PassWall DNS generator selftest failed')
    require('PASSWALL_RUNTIME_DNS_SHUNT_OVERRIDE=PASS' in result,
            'PassWall runtime DNS_SHUNT override selftest failed')
    print_pass('PassWall DNS generator guard, AGH readiness, runtime override and idempotence')

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
                require('RUNTIME_NATIVE_PROXY_VERIFICATION_REQUIRED' in output,
                        '101 runtime native proxy verification missing')
    print_pass('eight states x eight readiness combinations (64 plans)')

    for state in STATES:
        output = run('sh', HERE / 'r76s-v111-dns-manager.sh',
                     'render', state, 'WAN_BASELINE')
        require(f'state {state}' in output, 'state render mismatch')
        if state[2] == '1':
            require('server=127.0.0.1#3053' in output, 'AdGuard main route missing')
        elif state[1] == '1':
            require('server=127.0.0.1#6053' in output, 'SmartDNS main route missing')
        run('sh', HERE / 'r76s-v111-dns-manager.sh',
            'render', state, 'CUSTOM_OR_UNKNOWN', ok=False)
    print_pass('read-only DNS fragment renderer: all eight states; custom ownership blocked')

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
                if state == '101':
                    require('VERIFY_PASSWALL_NATIVE_PROXY_AT_RUNTIME' in output,
                            '101 runtime isolation requirement missing')
                if state == '111' and ready == '0':
                    require('BLOCK_SMARTDNS_READINESS_REQUIRED' in output,
                            '111 missing-SmartDNS state not blocked')
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

    runtime_selftest = run('sh', HERE / 'r76s-v111-dns-runtime-manager.sh', '--selftest')
    require('RUNTIME_MANAGER_SELFTEST=PASS' in runtime_selftest,
            'runtime manager pure selftest failed')
    require('LIVE_APPLY_DEFAULT=DISABLED' in runtime_selftest,
            'runtime manager must remain disabled before live validation')
    for state in STATES:
        require(f'SELFTEST_STATE={state}' in runtime_selftest,
                f'runtime manager missing state {state}')
    print_pass('runtime manager eight-state invariants; live daemon default disabled')

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
    # Synthetic file trees model the observed 111 chain and the new 101 native
    # PassWall proxy path without exposing private YAML, node IDs, or rules.
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

        # 110 must reject the observed stale 3053 edge.
        output = run('sh', audit, '110', r, ok=False)
        require('SYSTEM_DANGLING_ADGUARD_REFERENCE' in output,
                '110 stale AdGuard edge not caught')

        # Convert the fixture to target 101: system -> AGH -> WAN, PassWall
        # direct/default -> AGH, proxy-domain rules -> independent 15353.
        (r / 'etc/adguardhome.yaml').write_text(
            'dns:\n  upstream_dns:\n    - 223.5.5.5\n')
        (r / 'tmp/etc/passwall/acl/default/dnsmasq.conf').write_text(
            'no-resolv\nserver=127.0.0.1#3053\nstrict-order\n')
        d = r / 'tmp/etc/passwall/acl/default/dnsmasq.d'
        d.mkdir(parents=True, exist_ok=True)
        (d / '001-server.conf').write_text(
            'server=/.example-proxy.test/127.0.0.1#15353\n')
        (r / 'tmp/etc/smartdns/passwall.conf').unlink()
        output = run('sh', audit, '101', r)
        require('REFERENCE_AUDIT=CONSISTENT_NOT_LIVE_PROVEN' in output,
                f'101 native proxy fixture rejected: {output}')
        require('PASSWALL_NATIVE_PROXY_REFS=1' in output,
                '101 native proxy DNS reference not detected')

        # Removing the independent proxy reference must fail closed.
        (d / '001-server.conf').unlink()
        output = run('sh', audit, '101', r, ok=False)
        require('PROXY_DNS_ISOLATION_NOT_VERIFIED' in output,
                '101 accepted without independent PassWall proxy DNS')

        # P=0 ignores an inactive dnsmasq file, but SmartDNS must not keep
        # actively including a stale PassWall SmartDNS fragment.
        (r / 'tmp/etc/smartdns/passwall.conf').write_text(
            'server 127.0.0.1:15356 -group proxy\n')
        output = run('sh', audit, '001', r, ok=False)
        require('STALE_PASSWALL_SMARTDNS_INCLUDE' in output,
                '001 stale active SmartDNS include not detected')
        (r / 'tmp/etc/smartdns/passwall.conf').unlink()

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
    print_pass('file-grounded 111 and 101 graphs, stale edges, native isolation and privacy')

    # The transaction experiment never accesses live router configuration.
    lab = Path('/tmp/r76s-v111-lab.' + uuid.uuid4().hex)
    lab.mkdir(mode=0o700)
    try:
        trans = HERE / 'r76s-v111-dns-transaction.sh'
        run('sh', trans, 'stage', '110', lab)
        conf = lab / 'r76s-v111.conf'
        require(conf.is_file(), 'Lab stage missing')
        run('sh', trans, 'stage', '101', lab)
        require(b'state 101' in conf.read_bytes(), '101 lab stage missing')
        before = conf.read_bytes()
        conf.write_bytes(before+b'# external edit\n')
        run('sh', trans, 'rollback', '101', lab, ok=False)
        require(conf.exists(), 'User change removed')
        conf.write_bytes(before)
        run('sh', trans, 'rollback', '101', lab)
        require(not conf.exists(), 'Rollback failed')
        run('sh', trans, 'stage', 'abc', lab, ok=False)
    finally:
        shutil.rmtree(lab)
    print_pass('tmp-only transaction lab, eight-state renderer and external edit guard')

    # R76S_V111_MULTI_FILE_TRANSACTION_LAB (explicitly not deployed to rootfs).
    # Models crashes, candidate drift, external edits and exact-byte recovery.
    snapshot_script = HERE / 'r76s-v111-dns-snapshot-lab.py'
    snap_spec = importlib.util.spec_from_file_location('v111_snapshot_lab', snapshot_script)
    snap_module = importlib.util.module_from_spec(snap_spec)
    snap_spec.loader.exec_module(snap_module)
    def make_lab():
        lab = Path('/tmp/r76s-v111-lab.' + uuid.uuid4().hex)
        lab.mkdir(mode=0o700)
        os.chmod(lab, 0o700)
        (lab / 'current').mkdir(mode=0o700)
        (lab / 'candidate').mkdir(mode=0o700)
        names = ('dhcp.conf', 'adguardhome.yaml', 'passwall-dnsmasq.conf',
                 'smartdns.conf')
        originals = {}
        for name in names:
            original = (f'# original untouched {name}\n' +
                        ('users: - private-placeholder\n' if name == 'adguardhome.yaml' else '')).encode()
            target = (f'# planned candidate for {name}\n').encode()
            originals[name] = original
            (lab / 'current' / name).write_bytes(original)
            (lab / 'candidate' / name).write_bytes(target)
        return lab, names, originals

    def snap(action, lab, state=None, ok=True):
        from contextlib import redirect_stdout
        from io import StringIO
        output = StringIO()
        try:
            with redirect_stdout(output):
                if action == 'prepare':
                    snap_module.prepare(snap_module.root_dir(str(lab)), state)
                elif action == 'apply':
                    snap_module.apply(snap_module.root_dir(str(lab)))
                elif action == 'rollback':
                    snap_module.rollback(snap_module.root_dir(str(lab)))
            if not ok:
                raise AssertionError('failed-open transaction: ' + action)
        except snap_module.Blocked as exc:
            if ok:
                raise AssertionError('transaction was unexpectedly blocked: ' + str(exc))
            output.write(str(exc))
        return output.getvalue()

    for target in STATES:
        lab, names, before = make_lab()
        try:
            out = snap('prepare', lab, target)
            require('LAB_TRANSACTION=PREPARED' in out, 'snapshot not prepared')
            out = snap('apply', lab)
            require('LAB_TRANSACTION=COMMITTED' in out, 'lab apply failed')
            for name in names:
                require((lab / 'current' / name).read_bytes() ==
                        (lab / 'candidate' / name).read_bytes(), 'candidate not staged')
            snap('rollback', lab)
            for name in names:
                require((lab / 'current' / name).read_bytes() == before[name],
                        'original bytes not recovered')
            require('ALREADY_ROLLED_BACK' in snap('rollback', lab),
                    'rollback idempotence failed')
            snap('apply', lab, ok=False)
        finally:
            shutil.rmtree(lab)

    lab, names, before = make_lab()
    try:
        snap('prepare', lab, '110')
        (lab / 'current' / names[0]).write_bytes(b'# external change\n')
        require('EXTERNAL_EDIT_BLOCKED' in snap('apply', lab, ok=False),
                'external current change accepted')
        (lab / 'current' / names[0]).write_bytes(before[names[0]])
        (lab / 'candidate' / names[1]).write_bytes(b'# drifted candidate\n')
        require('CANDIDATE_CHANGED_BLOCKED' in snap('apply', lab, ok=False),
                'candidate drift accepted')
        (lab / 'candidate' / names[1]).write_bytes(b'# planned candidate for adguardhome.yaml\n')
        # Simulate a power cut after only one file was staged, but before
        # transaction journal could be marked committed.
        (lab / 'current' / names[0]).write_bytes(
            (lab / 'candidate' / names[0]).read_bytes())
        snap('apply', lab, ok=False)
        snap('rollback', lab)
        for name in names:
            require((lab / 'current' / name).read_bytes() == before[name],
                    'interrupted transaction not recovered')
    finally:
        shutil.rmtree(lab)

    lab, names, before = make_lab()
    try:
        snap('prepare', lab, '001')
        snap('apply', lab)
        (lab / 'current' / names[2]).write_bytes(b'# user edited after apply\n')
        require('EXTERNAL_EDIT_BLOCKED' in snap('rollback', lab, ok=False),
                'rollback clobbered external edit')
        require((lab / 'current' / names[2]).read_bytes() ==
                b'# user edited after apply\n', 'external edit not preserved')
    finally:
        shutil.rmtree(lab)

    lab, names, before = make_lab()
    try:
        (lab / 'candidate' / names[0]).unlink()
        (lab / 'candidate' / names[0]).symlink_to(lab / 'current' / names[0])
        require('SYMLINK_BLOCKED' in snap('prepare', lab, '101', ok=False),
                'symlink escape admitted')
    finally:
        shutil.rmtree(lab)

    try:
        snap_module.root_dir('/etc')
    except snap_module.Blocked as exc:
        require('ONLY_TMP_LAB_PATHS_ALLOWED' in str(exc), 'wrong live-path guard')
    else:
        raise AssertionError('live /etc path accepted')
    print_pass('eight lab multi-file snapshots, exact rollback, interrupted staging, edit guards')

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
        require('r76s-v111-dns-runtime-manager.sh' in t,
                'Runtime DNS coordinator not staged by workflow')
        require('DNS_RUNTIME_MANAGER_STAGED_DISABLED=PASS' in t,
                'Runtime manager staging gate missing')
        require("option enabled '0'" in t,
                'Development runtime manager must default disabled')
        require('/etc/config/r76s_v111_dns' in t and '/etc/r76s-v111-dns/' in t,
                'Runtime manager config/state not preserved across upgrades')
        require('test ! -e "$ROOTFS_DIR/etc/rc.d/S99r76s-v111-dns-manager"' in t,
                'Development manager unexpectedly rc-enabled')
        require('r76s-v111-dns-transition-plan.py' in t,
                'Offline transition plan not checked by workflow')
        require('r76s-v111-dns-topology.py' in t,
                'Symbolic dependency check missing from workflow')
        require('scripts/r76s-v111-prebuild-tests.py' in t,
                'Offline suite not called in workflow')
        # An OpenWrt source checkout contains its own scripts/ directory.
        # After `cd openwrt`, repository-maintained helpers live in ../scripts/.
        # A misplaced relative path fails Actions late in the build.
        bad = []
        for step in re.split(r'(?m)^      - name: ', t):
            if re.search(r'(?m)^          cd openwrt\s*$', step):
                for line in step.splitlines():
                    if re.search(r'(?<![./])scripts/r76s-v111-', line) or '"scripts/$dns_script"' in line:
                        bad.append(line.strip())
        require(not bad, 'relative helper paths wrong after cd openwrt: ' + repr(bad))
        require('SMARTDNS_S18_PATCH_DEFERRED_UNTIL_PREPARED_SOURCE=YES' in t,
                'SmartDNS patched before prepared package source exists')
        require('make -j1 package/smartdns/prepare V=s' in t,
                'SmartDNS prepared source stage missing')
        require('SMARTDNS_INIT_CANDIDATES' in t and
                "'*/smartdns*/package/openwrt/files/etc/init.d/smartdns'" in t,
                'Prepared SmartDNS init discovery missing')
        require('SMARTDNS_S18_FINAL_ROOTFS=PASS' in t,
                'Built rootfs does not verify installed SmartDNS S18')
        require('python3 ../scripts/r76s-v111-passwall-groups.py --patch' in t,
                'PassWall group patch helper path wrong')
        require('test -s ../scripts/r76s-v111-dns-transition-plan.py' in t,
                'Transition-plan check path wrong')
        require('install -m 0755 "../scripts/$dns_script"' in t,
                'Read-only overlay staging source path wrong')
    print_pass('release gating, overlay re-stage ordering, disabled runtime manager and preserve state')
    print('R76S_V111_PREBUILD_TESTS=PASS')
    print('IMPORTANT: EIGHT_STATE_RUNTIME_MANAGER=STAGED_DISABLED_FOR_LIVE_VALIDATION')
    print('IMPORTANT: 64_TRANSITION_SPEC_REMAINS_OFFLINE_REFERENCE')
    print('IMPORTANT: SYMBOLIC_TOPOLOGY_IS_NOT_LIVE_CONFIG_PROOF')
    print('IMPORTANT: ROUTER_OR_GITHUB_CHANGES=NONE')


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(f'R76S_V111_PREBUILD_TESTS=FAIL: {exc}', file=sys.stderr)
        sys.exit(1)
