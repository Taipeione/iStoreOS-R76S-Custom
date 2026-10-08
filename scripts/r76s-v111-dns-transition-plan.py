#!/usr/bin/env python3
"""R76S V1.1.1 eight-state DNS transition *planning* and safety gate.

Offline / stdout only. No config writes, UCI, subprocesses or service actions.
This is a specification for later transactional implementation, NOT an apply tool.
"""
import argparse
import json

STATES = tuple(f'{n:03b}' for n in range(8))


def topology(state):
    """Conservative intended DNS endpoints, not evidence of actual device wiring."""
    p, s, a = [v == '1' for v in state]
    main = 'AGH:3053' if a else 'SMARTDNS:6053' if s else 'WAN_DNS'
    agh_upstream = ('SMARTDNS:6053' if s else 'INDEPENDENT_WAN_DNS') if a else 'OFF'
    if not p:
        pw_upstreams = []
    elif s and a:
        pw_upstreams = ['AGH:3053', 'SMARTDNS_SPLIT:15355']
    elif s:
        pw_upstreams = ['SMARTDNS_SPLIT:15355']
    else:
        pw_upstreams = ['INDEPENDENT_PROXY_DNS']
    smartdns_proxy = 'XRAY:15356' if p and s else 'OFF'
    return dict(main=main, adguard_upstream=agh_upstream,
                passwall_dns_upstreams=pw_upstreams,
                smartdns_proxy_upstream=smartdns_proxy)


def requirements(state):
    p, s, a = [v == '1' for v in state]
    necessary = ['USER_DNS_OWNERSHIP_APPROVAL', 'ATOMIC_SNAPSHOT_AND_RESTORE',
                 'WAN_RESOLVER_INDEPENDENCE', 'BOOT_RECOVERY_VALIDATED',
                 'RUNTIME_READINESS_AND_PROBE', 'LIVE_GENERATED_CONFIG_AUDIT']
    if a:
        necessary += ['ADGUARD_YAML_SAVE_AND_RESTART_VALIDATED',
                      'ADGUARD_ACCOUNT_FILTER_PRESERVATION']
    if p:
        necessary += ['PASSWALL_DNS_REGENERATION_VERIFIED',
                      'PASSWALL_42_RULES_PRESERVED',
                      'PASSWALL_DNS_REDIRECT_INTERCEPTION_VERIFIED']
    if p and not s:
        necessary += ['ISOLATED_PASSWALL_PROXY_DNS_VERIFIED']
    if s:
        necessary += ['SMARTDNS_DYNAMIC_LOADER_AND_PORT_OWNER_VERIFIED',
                      'SMARTDNS_INCLUDE_CHAIN_VALIDATED']
    return necessary


def phases(before, after):
    """Safe conceptual order: prepare targets before switching primary; no commands."""
    p, s, a = [v == '1' for v in after]
    steps = [
        'READ_SNAPSHOT_UCI_DNSMASQ_AGH_YAML_PASSWALL_SMARTDNS_AND_INIT_STATE',
        'VERIFY_UNMODIFIED_BASELINE_AND_USER_OWNERSHIP',
        'CHECK_WAN_DNS_NOT_ROUTED_BACK_TO_DEVICE',
        'RENDER_ALL_CANDIDATES_OFFLINE_AND_REJECT_DANGLING_EDGES',
    ]
    if s:
        steps += ['PREPARE_SMARTDNS_EXTERNAL_WAN_UPSTREAM',
                  'START_OR_VERIFY_SMARTDNS_AND_PROXY_UPSTREAM_AS_NEEDED']
    if p:
        steps += ['PREPARE_PASSWALL_GENERATED_DNS_WITHOUT_DISABLED_SERVICES',
                  'VERIFY_PASSWALL_INDEPENDENT_PROXY_DNS_AND_RULES']
    if a:
        steps += ['PREPARE_ADGUARD_YAML_WITHOUT_ERASING_USER_FIELDS',
                  'START_OR_VERIFY_ADGUARD_AND_ITS_UPSTREAM']
    steps += ['STAGE_DNSMASQ_MAIN_UPSTREAM_LAST',
              'RUN_POST_STAGE_LOOP_AND_RESOLUTION_CHECKS',
              'SWITCH_MAIN_DNS_WITH_RECORDED_ROLLBACK_STATE',
              'VERIFY_LAN_WAN_PROXY_DNS_AND_SERVICE_RECOVERY',
              'ONLY_THEN_REMOVE_UNUSED_UPSTREAM_REFERENCES_AND_STOP_SERVICES',
              'VERIFY_FULL_GRAPH_AGAIN_AND_RECORD_CLEAN_COMMIT']
    return steps


def make_plan(before, after):
    if before not in STATES or after not in STATES:
        raise ValueError('state must be a 3-bit string (P,S,A)')
    return {
        'from_state': before, 'to_state': after,
        'requested_topology': topology(after),
        'required_live_evidence': requirements(after),
        'ordered_phases': phases(before, after),
        'automatic_apply': False,
        'status': 'OFFLINE_PLAN_ONLY',
        'special_warning': ('101 requires independent PassWall proxy DNS without an AdGuard/SmartDNS reverse path'
                            if after == '101' else
                            'No automatic modification or service restart is authorized'),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('before', choices=STATES)
    parser.add_argument('after', choices=STATES)
    args = parser.parse_args()
    print(json.dumps(make_plan(args.before, args.after), ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
