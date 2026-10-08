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
        run(sys.executable, '-m', 'py_compile', f)
    print_pass('seven POSIX shell syntax and Python compilation')

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
        require('scripts/r76s-v111-prebuild-tests.py' in t,
                'Offline suite not called in workflow')
    print_pass('release gating, overlay re-stage ordering, disabled unsafe hook')
    print('R76S_V111_PREBUILD_TESTS=PASS')
    print('IMPORTANT: DNS_AUTOMATIC_EIGHT_STATES=NOT_IMPLEMENTED')
    print('IMPORTANT: ROUTER_OR_GITHUB_CHANGES=NONE')


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(f'R76S_V111_PREBUILD_TESTS=FAIL: {exc}', file=sys.stderr)
        sys.exit(1)
