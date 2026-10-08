#!/usr/bin/env python3
"""PassWall SmartDNS direct-group patch: scoped, idempotent, fail closed.

Operate on build-tree helper_smartdns_add.lua only. Never touches live router.
"""
import argparse
import os
from pathlib import Path
import re
import stat
import tempfile

MARKER = '-- R76S_V111_SMARTDNS_DIRECT_GROUP_PATCH'
GROUP_LINE = re.compile(
    r"(string\.format\('domain-rules /domain-set:%s/ -nameserver %s',\s*"
    r"domain_set_name,\s*)(LOCAL_GROUP|REMOTE_GROUP)(\))"
)


def boundaries(source):
    matches = []
    for name in ('direct', 'proxy', 'black'):
        exp = re.compile(
            r'(?m)^[ \t]*local domain_set_name = "psw-shunt-' + name + r'"[ \t]*$'
        )
        found = list(exp.finditer(source))
        if len(found) != 1:
            raise ValueError(f'BLOCKED: expected one psw-shunt-{name} anchor, got {len(found)}')
        matches.append(found[0].start())
    if not matches[0] < matches[1] < matches[2]:
        raise ValueError('BLOCKED: unexpected shunt block order')
    return matches


def one_group(section, label):
    found = list(GROUP_LINE.finditer(section))
    if len(found) != 1:
        raise ValueError(f'BLOCKED: expected one {label} group mapping, got {len(found)}')
    return found[0].group(2)


def patch_text(source):
    a, b, c = boundaries(source)
    direct = source[a:b]
    proxy = source[b:c]
    actual_direct = one_group(direct, 'direct')
    if one_group(proxy, 'proxy') != 'REMOTE_GROUP':
        raise ValueError('BLOCKED: proxy rule is not REMOTE_GROUP')
    if source.count(MARKER) > 1:
        raise ValueError('BLOCKED: duplicate patch markers')
    if MARKER in source and actual_direct != 'LOCAL_GROUP':
        raise ValueError('BLOCKED: inconsistent existing patch marker')
    if actual_direct == 'REMOTE_GROUP':
        direct, edits = GROUP_LINE.subn(lambda m: m.group(1) + 'LOCAL_GROUP' + m.group(3), direct)
        if edits != 1:
            raise ValueError('BLOCKED: ambiguous direct-group rewrite')
    if MARKER not in source:
        direct = '\t\t' + MARKER + '\n' + direct
    result = source[:a] + direct + source[b:]
    verify_text(result, require_marker=True)
    if result[result.index('local domain_set_name = "psw-shunt-proxy"'):] != source[source.index('local domain_set_name = "psw-shunt-proxy"'):]:
        raise ValueError('BLOCKED: non-direct rule changes')
    return result


def verify_text(source, require_marker=False):
    a, b, c = boundaries(source)
    if one_group(source[a:b], 'direct') != 'LOCAL_GROUP':
        raise ValueError('BLOCKED: direct rule is not LOCAL_GROUP')
    if one_group(source[b:c], 'proxy') != 'REMOTE_GROUP':
        raise ValueError('BLOCKED: proxy rule is not REMOTE_GROUP')
    if require_marker and source.count(MARKER) != 1:
        raise ValueError('BLOCKED: marker missing or repeated')


def save_atomic(path, data):
    mode = stat.S_IMODE(path.stat().st_mode)
    fd, tempname = tempfile.mkstemp(prefix='.r76s-groups-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8', newline='') as fp:
            fp.write(data)
        os.chmod(tempname, mode)
        os.replace(tempname, path)
    finally:
        if os.path.exists(tempname):
            os.unlink(tempname)


def self_test():
    def sample(direct, proxy):
        return ('before\n'
                'if is_file_nonzero(shunt_direct_host) then\n'
                '\t\tlocal domain_set_name = "psw-shunt-direct"\n'
                "\t\tlocal domain_rules_str = string.format('domain-rules /domain-set:%s/ -nameserver %s', domain_set_name, " + direct + ')\n'
                'end\n'
                'if is_file_nonzero(shunt_proxy_host) then\n'
                '\t\tlocal domain_set_name = "psw-shunt-proxy"\n'
                "\t\tlocal domain_rules_str = string.format('domain-rules /domain-set:%s/ -nameserver %s', domain_set_name, " + proxy + ')\n'
                'end\n'
                'if is_file_nonzero(shunt_black_host) then\n'
                '\t\tlocal domain_set_name = "psw-shunt-black"\n'
                'end\n')
    for direct in ('LOCAL_GROUP', 'REMOTE_GROUP'):
        original = sample(direct, 'REMOTE_GROUP')
        patched = patch_text(original)
        verify_text(patched, require_marker=True)
        assert patch_text(patched) == patched
        assert original[original.index('if is_file_nonzero(shunt_proxy_host)'):] == patched[patched.index('if is_file_nonzero(shunt_proxy_host)'):]
    for broken in (sample('LOCAL_GROUP', 'LOCAL_GROUP'), sample('LOCAL_GROUP', 'REMOTE_GROUP').replace('psw-shunt-black','psw-shunt-other')):
        try:
            patch_text(broken)
        except ValueError:
            pass
        else:
            raise AssertionError('unsafe source should be blocked')
    print('PASSWALL_GROUP_SELF_TESTS=PASS')


def main():
    parser = argparse.ArgumentParser()
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument('--self-test', action='store_true')
    modes.add_argument('--patch', type=Path)
    modes.add_argument('--verify', type=Path)
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    path = args.patch or args.verify
    source = path.read_text(encoding='utf-8')
    if args.patch:
        result = patch_text(source)
        if result != source:
            save_atomic(path, result)
        print('PASSWALL_DIRECT_GROUP_SCOPED_PATCH=PASS')
    else:
        verify_text(source, require_marker=True)
        print('PASSWALL_SMARTDNS_DIRECT_AND_PROXY_GROUPS=PASS')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, AssertionError) as exc:
        raise SystemExit(str(exc))
