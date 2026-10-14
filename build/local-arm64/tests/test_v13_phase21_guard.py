"""Isolated lifecycle tests; optional native nftables packet tests live separately."""
from pathlib import Path
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import test_v13_phase2_dns as dns_tests
POLICY, TENCENT = dns_tests.POLICY, dns_tests.TENCENT

ROOT=Path(__file__).resolve().parents[3]
GUARD=ROOT/'feeds/luci-app-r76s-updater/files/root/usr/libexec/r76s/r76s-ip6-guard'

UCI=r'''import json,os,sys
from pathlib import Path
root=Path(os.environ['R76S_POLICY_ROOT']); args=[a for a in sys.argv[1:] if a!='-q']
action=args[0]; package=args[1].split('.')[0].split('=')[0]
path=root/'etc/config'/package
state=json.loads(path.read_text()) if path.exists() else {}
if action=='changes':print(state.get('_pending',''),end='');sys.exit(0)
if action=='get':
    value=state.get(args[1])
    if value is None:sys.exit(1)
    print(' '.join(value) if isinstance(value,list) else value);sys.exit(0)
if action=='show':
    for k,v in state.items():print(k+"='"+str(v)+"'")
    sys.exit(0)
if action=='set':key,value=args[1].split('=',1);state[key]=value
elif action in ('add_list','del_list'):
    key,value=args[1].split('=',1);values=state.get(key,[])
    state[key]=values+[value] if action=='add_list' else [v for v in values if v!=value]
elif action=='delete':
    state={k:v for k,v in state.items() if k!=args[1] and not k.startswith(args[1]+'.')}
elif action in ('commit','revert'):sys.exit(0)
else:sys.exit(2)
path.write_text(json.dumps(state))
'''

NFT=r'''import os,sys
from pathlib import Path
root=Path(os.environ['R76S_POLICY_ROOT']); args=sys.argv[1:];table=root/'nft-table'
with (root/'nft-log').open('a') as log:log.write(' '.join(args)+'\n')
if args[:2]==['list','ruleset']:
    print('table inet passwall {}\ntable inet passwall2 {}')
    if os.environ.get('FLOWTABLE')=='1':print(' flowtable bypass { }')
elif args[:2]==['list','table']:
    if not table.exists():sys.exit(1)
    print(table.read_text())
elif args[:2]==['delete','table']:table.unlink(missing_ok=True)
elif '-f' in args:
    text=Path(args[args.index('-f')+1]).read_text()
    assert 'flush ruleset' not in text and 'flush table inet passwall' not in text
    if '-c' not in args:
        if os.environ.get('FAIL_NFT')=='1' and not (root/'nft-failed').exists():
            (root/'nft-failed').touch();sys.exit(1)
        table.write_text('table inet r76s_ip6_guard { comment "R76S_V13_IPV6_GUARD"; }')
else:sys.exit(2)
'''


class GuardTransactions(unittest.TestCase):
    def setUp(self):
        fixture=dns_tests.PolicyTransactions();fixture.setUp()
        self.addCleanup(fixture.temp.cleanup)
        self.root,self.env=fixture.root,fixture.env
        self.config=fixture.config
        for name,text in [('uci',UCI),('nft',NFT)]:
            path=self.root/'bin'/name
            path.write_text('#!'+sys.executable+'\n'+text);path.chmod(0o755)
        def config(name,state):
            (self.root/'etc/config'/name).write_text(json.dumps(state))
        config('firewall',{'firewall.@defaults[0].flow_offloading':'0'})
        config('r76s_ip_policy',{'r76s_ip_policy.main':'policy','r76s_ip_policy.main.ipv6_guard':'0'})
        config('network',{'network.lan.device':'br-lan'})
        (self.root/'usr/share/passwall/rules/chnroute6').write_text('2400:3200::/32\n')
        (self.root/'etc/init.d').mkdir()
        for name in ('smartdns','firewall'):
            path=self.root/'etc/init.d'/name
            path.write_text('#!/bin/sh\nprintf "%s %s\\n" "'+name+'" "$1" >> "$R76S_POLICY_ROOT/service-log"\n'
                'if [ "${FAIL_RESTART:-0}" = 1 ] && [ "$1" = restart ] && [ ! -f "$R76S_POLICY_ROOT/restart-failed" ]; then\n'
                'touch "$R76S_POLICY_ROOT/restart-failed"; exit 1; fi\nexit 0\n')
            path.chmod(0o755)
        for name in ('passwall','passwall2'):
            (self.root/'etc/config'/name).write_text('USER_RULE_ORDER_AND_NODES\n')
        self.env={**self.env,'R76S_GUARD_DNS_TOOL':str(POLICY)}

    def call(self, action, ok=True, **env):
        result=subprocess.run(['sh',str(GUARD),action],env={**self.env,**env},text=True,capture_output=True)
        self.assertEqual(result.returncode==0,ok,result.stdout+result.stderr)
        return result

    def configs(self):return {p.name:p.read_bytes() for p in (self.root/'etc/config').iterdir()}

    def test_lifecycle_is_idempotent_and_preserves_both_passwalls(self):
        original=self.configs()
        self.call('enable');self.call('enable')
        self.assertTrue((self.root/'nft-table').exists())
        profile=self.root/'etc/smartdns/r76s-v13/ip-family.conf'
        self.assertIn('#6:inet#r76s_ip6_guard#direct6',profile.read_text())
        includes=json.loads(self.config.read_text())['smartdns.@smartdns[0].conf_files']
        self.assertEqual(includes.count('/etc/smartdns/r76s-v13/ip-family.conf'),1)
        for name in ('passwall','passwall2'):
            self.assertEqual((self.root/'etc/config'/name).read_bytes(),original[name])
        self.call('disable')
        self.assertFalse((self.root/'nft-table').exists())
        self.assertNotIn('r76s_ip6_guard#direct6',profile.read_text())
        self.assertIn('-address #6',profile.read_text())

    def test_dns_restart_failure_restores_all_configs_and_table(self):
        before=self.configs()
        self.call('enable',ok=False,FAIL_RESTART='1')
        self.assertEqual(self.configs(),before)
        self.assertFalse((self.root/'nft-table').exists())
        self.assertFalse((self.root/'etc/smartdns/r76s-v13/ip-family.conf').exists())

    def test_nft_failure_restores_snapshot(self):
        before=self.configs()
        self.call('enable',ok=False,FAIL_NFT='1')
        self.assertEqual(self.configs(),before)
        self.assertFalse((self.root/'nft-table').exists())

    def test_offloading_and_external_flowtable_fail_before_writes(self):
        firewall=self.root/'etc/config/firewall'
        for option in ('flow_offloading','flow_offloading_hw'):
            firewall.write_text(json.dumps({'firewall.@defaults[0].'+option:'1'}))
            before=self.configs();self.call('enable',ok=False)
            self.assertEqual(self.configs(),before)
        firewall.write_text('{}');before=self.configs()
        self.call('enable',ok=False,FLOWTABLE='1');self.assertEqual(self.configs(),before)

    def test_disabled_reload_has_no_side_effects(self):
        before=self.configs();self.call('reload')
        self.assertEqual(self.configs(),before)
        self.assertFalse((self.root/'nft-log').exists())

    def test_enabled_reload_retains_guard_if_route_data_is_missing(self):
        self.call('enable')
        (self.root/'usr/share/passwall/rules/chnroute6').unlink()
        self.call('reload',ok=False)
        self.assertTrue((self.root/'nft-table').exists())
        self.assertTrue((self.root/'etc/r76s-ip6-guard/last-good.nft').exists())

    def test_enabled_reload_without_saved_data_stays_restrictive(self):
        self.call('enable')
        (self.root/'usr/share/passwall/rules/chnroute6').unlink()
        (self.root/'etc/r76s-ip6-guard/last-good.nft').unlink()
        self.call('reload',ok=False)
        self.assertTrue((self.root/'nft-table').exists())

    def test_rule_render_is_ipv6_only_and_has_no_mark_or_conntrack_bypass(self):
        text=self.call('render').stdout
        for marker in ('meta nfproto != ipv6 return','ip6 daddr @cn6 return',
                       'ip6 daddr @direct6 return','hook forward priority -5','hook output priority -5'):
            self.assertIn(marker,text)
        for forbidden in ('flush ruleset','ct state established','meta mark','passwall'):
            self.assertNotIn(forbidden,text)

    def test_tencent_domains_equal_both_stable_direct_groups(self):
        stage=next((ROOT/'build/local-arm64/stages').glob('16-*.sh')).read_text()
        code=stage.split("<<'PY_RULES'\n",1)[1].split('\nPY_RULES\n',1)[0]
        paths=[self.root/'pw',self.root/'pw2']
        for path in paths:path.write_text("config global 'global'\n")
        result=subprocess.run(['python3','-',str(ROOT/'config/rules/r76s-rules.json'),*map(str,paths)],
                              input=code,text=True,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
        import re
        for path in paths:
            domains=set()
            for body in re.findall(r"(?ms)^config shunt_rules '(?:WeChatDirect|TencentMediaDirect)'\n(.*?)(?=^config |\Z)",path.read_text()):
                domains.update(re.findall(r'domain:([^\s\x27]+)',body))
            self.assertEqual(domains,set(TENCENT.read_text().splitlines()))
