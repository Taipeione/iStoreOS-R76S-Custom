#!/usr/bin/env python3
"""Offline DNS dependency checker. Never connects to a router or modifies files.

Input JSON is a symbolic, redacted EDGE MODEL, not raw router configurations.
Edges use labels SYSTEM, WAN, AGH, SD, PW, PROXY, SPLIT and must be verified
against observed dnsmasq/SmartDNS/AdGuard/PassWall configs before any deployment.
"""
import argparse
import json
import sys
from collections import defaultdict

NODES = frozenset({'SYSTEM', 'WAN', 'AGH', 'SD', 'PW', 'PROXY', 'SPLIT'})
STATES = {f'{i:03b}' for i in range(8)}


def check(model):
    issues = []
    state = model.get('state')
    edges = model.get('edges')
    if state not in STATES:
        return ['INVALID_STATE']
    if not isinstance(edges, list) or not all(isinstance(e, list) and len(e) == 2 and
                                               all(isinstance(v, str) and v in NODES for v in e)
                                               for e in edges):
        return ['INVALID_EDGES']
    pw, sd, agh = (int(c) for c in state)
    graph = defaultdict(list)
    for a, b in edges:
        if b not in graph[a]:
            graph[a].append(b)
        if a == 'WAN':
            issues.append('WAN_CANNOT_BE_SOURCE')
        if a == b:
            issues.append('SELF_LOOP_' + a)
        if ((a in ('PW', 'PROXY') or b in ('PW', 'PROXY')) and not pw or
            (a in ('SD', 'SPLIT') or b in ('SD', 'SPLIT')) and not sd or
            (a == 'AGH' or b == 'AGH') and not agh):
            issues.append('DISABLED_SERVICE_REFERENCE_' + a + '_' + b)
    system_target = 'AGH' if agh else 'SD' if sd else 'WAN'
    if graph['SYSTEM'] != [system_target]:
        issues.append('SYSTEM_TARGET_MISMATCH')
    if agh:
        target = 'SD' if sd else 'WAN'
        if graph['AGH'] != [target]:
            issues.append('ADGUARD_UPSTREAM_MISMATCH')
    if pw and 'PROXY' not in graph['PW'] and 'WAN' not in graph['PW']:
        # For this conservative design, PW DNS must have an independent path.
        issues.append('PROXY_DNS_ISOLATION_NOT_SHOWN')
    if state == '101' and any(dest in ('AGH', 'SYSTEM', 'SD', 'SPLIT')
                              for dest in graph['PW']):
        issues.append('101_PROXY_DNS_NOT_ISOLATED')
    seen = set()
    active = set()

    def walk(node):
        if node in active:
            return True
        if node in seen:
            return False
        active.add(node)
        if any(walk(n) for n in graph[node]):
            return True
        active.remove(node)
        seen.add(node)
        return False

    if any(walk(node) for node in sorted(NODES)):
        issues.append('DNS_CYCLE_DETECTED')
    # All paths from system and AdGuard must terminate at a safe labelled sink.
    def reaches_wan(source):
        stack, visited = [source], set()
        while stack:
            node = stack.pop()
            if node == 'WAN':
                return True
            if node in visited:
                continue
            visited.add(node)
            stack.extend(graph[node])
        return False

    if not reaches_wan('SYSTEM'):
        issues.append('NO_SYSTEM_WAN_TERMINATION')
    if agh and not reaches_wan('AGH'):
        issues.append('NO_ADGUARD_WAN_TERMINATION')
    # The WAN node is purely symbolic. Real WAN resolver IPs still require
    # independent verification, and paths may not reflect actual rules.
    return sorted(set(issues))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('model', help='Path to a symbolic redacted topology JSON')
    args = parser.parse_args()
    with open(args.model, encoding='utf-8') as stream:
        model = json.load(stream)
    failures = check(model)
    state = model.get('state', 'INVALID')
    print('STATE=' + str(state))
    print('TOPOLOGY_RESULT=' + ('BLOCKED' if failures else 'SYMBOLIC_MODEL_PASS'))
    for issue in failures:
        print('ISSUE=' + issue)
    print('LIVE_ROUTER_VERIFICATION=NOT_PERFORMED')
    print('ROUTER_CONFIG_CHANGES=NONE')
    return 4 if failures else 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as exc:
        print('TOPOLOGY_RESULT=BLOCKED: ' + str(exc), file=sys.stderr)
        sys.exit(4)
