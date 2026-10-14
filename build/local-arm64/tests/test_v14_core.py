"""V1.4 state transactions and target Lua syntax, without touching host services."""
from pathlib import Path
import itertools,json,os,shutil,subprocess,sys,tempfile,unittest

ROOT=Path(__file__).resolve().parents[3]
CORE=ROOT/'feeds/r76s-core/files/usr/libexec/r76s'
LUA=os.environ.get('R76S_TEST_LUA') or shutil.which('lua5.1') or shutil.which('lua')

class ServiceTransactions(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name)
        (self.root/'etc/init.d').mkdir(parents=True)
        (self.root/'bin').mkdir()
        self.state=self.root/'state.json'
        self.env={**os.environ,'R76S_SERVICE_ROOT':str(self.root),'STATE':str(self.state),
                  'PATH':str(self.root/'bin')+':'+os.environ['PATH']}
        uci=self.root/'bin/uci'
        uci.write_text('#!'+sys.executable+'\n'+'''import json,os,sys
from pathlib import Path
p=Path(os.environ['STATE']);s=json.loads(p.read_text());a=[x for x in sys.argv[1:] if x!='-q']
if a[0]=='get':
    if a[1] not in s:sys.exit(1)
    print(s[a[1]])
elif a[0]=='set':k,v=a[1].split('=',1);s[k]=v;p.write_text(json.dumps(s))
elif a[0]=='commit' and os.environ.get('FAIL_COMMIT')=='1':sys.exit(1)
''');uci.chmod(0o755)
        if not shutil.which('flock'):
            p=self.root/'bin/flock';p.write_text('#!/bin/sh\nexit 0\n');p.chmod(0o755)
        for name in ('passwall','passwall2','smartdns'):
            p=self.root/'etc/init.d'/name
            p.write_text('''#!/bin/sh
root="$R76S_SERVICE_ROOT"
name="${0##*/}"
case "$1" in
enabled) test -f "$root/$name.enabled";;
enable) touch "$root/$name.enabled";;
disable) rm -f "$root/$name.enabled";;
restart) [ "${FAIL_RESTART:-0}" != 1 ];;
stop) exit 0;;
esac
''');p.chmod(0o755)

    def seed(self,pw,pw2,sd):
        self.state.write_text(json.dumps({'passwall.@global[0].enabled':str(pw),
            'passwall2.@global[0].enabled':str(pw2),'smartdns.@smartdns[0].enabled':str(sd)}))

    def run_manager(self,*args,**env):
        return subprocess.run(['sh',str(CORE/'r76s-service-manager'),*args],env={**self.env,**env},capture_output=True,text=True)

    def test_reconcile_all_intents_and_proxy_conflicts(self):
        for pw,pw2,sd in itertools.product((0,1),repeat=3):
            self.seed(pw,pw2,sd)
            result=self.run_manager('reconcile')
            self.assertEqual(result.returncode==0,not(pw and pw2),result.stderr)
            if result.returncode==0:
                for service,flag in zip(('passwall','passwall2','smartdns'),(pw,pw2,sd)):
                    self.assertEqual((self.root/(service+'.enabled')).exists(),bool(flag))
            self.assertEqual(json.loads(self.state.read_text())['passwall.@global[0].enabled'],str(pw))

    def test_set_synchronizes_and_failed_restart_restores(self):
        self.seed(0,0,0)
        self.assertEqual(self.run_manager('set','passwall','1').returncode,0)
        self.assertTrue((self.root/'passwall.enabled').exists())
        self.assertNotEqual(self.run_manager('set','passwall2','1').returncode,0)
        self.assertEqual(self.run_manager('set','passwall','0').returncode,0)
        self.assertFalse((self.root/'passwall.enabled').exists())
        result=self.run_manager('set','passwall2','1',FAIL_RESTART='1')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(json.loads(self.state.read_text())['passwall2.@global[0].enabled'],'0')
        self.assertFalse((self.root/'passwall2.enabled').exists())

    def test_status_handles_disabled_and_invalid_input_is_rejected(self):
        self.seed(0,0,0)
        self.assertEqual(len(self.run_manager('status').stdout.splitlines()),3)
        self.assertNotEqual(self.run_manager('set','passwall;reboot','1').returncode,0)
        self.assertNotEqual(self.run_manager('set','passwall','2').returncode,0)

class CoreSources(unittest.TestCase):
    @unittest.skipUnless(LUA,'requires Lua interpreter')
    def test_dns_transaction_rollback_and_dhcp_preservation(self):
        for scenario in ('success','fail'):
            result=subprocess.run([LUA,str(ROOT/'build/local-arm64/tests/v14-dns-test.lua'),scenario,
                str(CORE/'r76s-dns-manager')],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)

    def test_final_staging_uses_signed_backend_and_native_adapters(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            package=root/'package/custom/luci-app-r76s-updater'
            shutil.copytree(ROOT/'feeds/luci-app-r76s-updater',package)
            stage=next((ROOT/'build/local-arm64/stages').glob('15-*.sh')).read_text()
            code=stage.split("<<'PY_OTA_PATCH'\n",1)[1].split('\nPY_OTA_PATCH',1)[0]
            controller=package/'files/controller/r76s_updater.lua'
            result=subprocess.run([sys.executable,'-',str(controller)],input=code,capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            # Apply the existing tested synchronous preflight adapter before V1.4 finalization.
            import importlib.util
            spec=importlib.util.spec_from_file_location('hardening14',ROOT/'build/local-arm64/patches/r76s-v12-ota-hardening.py')
            hardening=importlib.util.module_from_spec(spec);spec.loader.exec_module(hardening)
            controller.write_text(controller.read_text().replace(hardening.OLD_CONTROLLER,hardening.NEW_CONTROLLER))
            for name in ('passwall','passwall2'):
                p=root/f'package/{name}-luci/luci-app-{name}/root/etc/init.d/{name}'
                p.parent.mkdir(parents=True);p.write_text('start() {\n true\n}\nrestart() {\n true\n}\n')
            result=subprocess.run([sys.executable,str(ROOT/'scripts/r76s-v14-stage.py'),str(root)],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            contents=controller.read_text()
            self.assertIn('r76s-ota install',contents)
            self.assertIn('r76s-ota verify',contents)
            self.assertNotIn('/sbin/sysupgrade " .. FIRMWARE',contents)
            self.assertTrue((root/'files/usr/share/r76s/ota-public.pem').exists())
            if LUA:
                result=subprocess.run([LUA,'-'],input='assert(loadfile('+repr(str(controller))+'))',text=True,capture_output=True)
                self.assertEqual(result.returncode,0,result.stderr)

    @unittest.skipUnless(LUA,'requires Lua interpreter')
    def test_new_lua_syntax(self):
        for p in CORE.iterdir():
            if p.read_text().startswith('#!/usr/bin/lua'):
                result=subprocess.run([LUA,'-'],input='assert(loadfile('+repr(str(p))+'))',text=True,capture_output=True)
                self.assertEqual(result.returncode,0,result.stderr)

    def test_rules_have_disjoint_direct_groups_and_preserve_24_domains(self):
        rules=json.loads((ROOT/'config/rules/r76s-rules.json').read_text())['rules']
        groups={r['name']:set(r['options'].get('domain_list','').splitlines()) for r in rules}
        self.assertFalse(groups['WeChatDirect'] & groups['TencentMediaDirect'])
        union=groups['WeChatDirect']|groups['TencentMediaDirect']
        self.assertEqual(len(union),24)
        tencent=set((ROOT/'feeds/luci-app-r76s-updater/files/root/usr/share/r76s/tencent-direct.list').read_text().splitlines())
        self.assertEqual({d.removeprefix('domain:') for d in union},tencent)

    def test_no_fixed_password_and_signed_backend_is_staged_last(self):
        stage=next((ROOT/'build/local-arm64/stages').glob('16-*.sh')).read_text()
        self.assertNotIn('secret="password"',stage)
        self.assertIn('/dev/urandom',stage)
        self.assertIn('r76s-v14-stage.py',stage.splitlines()[-1])

if __name__=='__main__':unittest.main()
