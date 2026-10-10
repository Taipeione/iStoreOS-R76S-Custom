#!/usr/bin/env python3
"""Offline tests against staged source, not a live R76S or a flashable image."""
from pathlib import Path
import importlib.util
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
STAGES = ROOT / 'build/local-arm64/stages'
FEATURES = ROOT / 'build/local-arm64/v12-overlays'
STAGE16 = next(STAGES.glob('16-*.sh'))
STAGE15 = next(STAGES.glob('15-*.sh'))

class V12Features(unittest.TestCase):
    def test_direct_rule_generator(self):
        stage = STAGE16.read_text()
        code = stage.split("<<'PY_RULES'\n",1)[1].split('\nPY_RULES\n',1)[0]
        with tempfile.TemporaryDirectory() as t:
            p=Path(t)
            for name in ('pw','pw2'):
                (p/name).write_text("config global 'global'\n\toption enabled '0'\n\n")
            source=ROOT/'files/etc/uci-defaults/99-r76s-v2-defaults'
            result=subprocess.run(['python3','-',str(source),str(p/'pw'),str(p/'pw2')],input=code,text=True,capture_output=True)
            self.assertEqual(result.returncode,0,result.stderr)
            for name in ('pw','pw2'):
                s=(p/name).read_text()
                self.assertEqual(s.count('config shunt_rules '),43)
                self.assertNotIn("config shunt_rules 'WeChatTencent'",s)
                self.assertIn("option WeChatDirect '_direct'",s)
                self.assertIn("option TencentMediaDirect '_direct'",s)
                section=re.findall(r"(?ms)^config shunt_rules '(WeChatDirect|TencentMediaDirect)'\n(.*?)(?=^config |\Z)",s)
                self.assertEqual(len(section),2)
                domains=[]
                for sec,body in section:
                    dm=re.search(r"(?ms)\toption domain_list '(.*?)'",body)
                    self.assertIsNotNone(dm)
                    ds=dm.group(1).splitlines()
                    if sec=='WeChatDirect':
                        self.assertIn('domain:weixin.qq.com',ds)
                        self.assertIn('domain:wechat.com',ds)
                        self.assertNotIn('domain:qq.com',ds)
                        self.assertNotIn('domain:tencent.com',ds)
                    domains += ds
                self.assertEqual(len(domains),24)
                self.assertEqual(len(set(domains)),24)
                self.assertIn('domain:qq.com',domains)
                self.assertIn('domain:tencent.com',domains)

    def test_safe_legacy_migration_staged(self):
        s=STAGE16.read_text()
        self.assertIn('cp -p "/etc/config/$pkg"',s)
        self.assertIn('uci -q delete "$pkg.WeChatTencent"',s)
        self.assertIn('migrate_v12_direct "$pkg" || exit 1',s)
        self.assertIn('uci -q set "$pkg.myshunt.WeChatDirect=_direct"',s)

    def test_ota_dom_and_logic_preserved(self):
        original = STAGE15.read_text().split("view = r'''",1)[1].split("'''\n\np.write_text(view)",1)[0]
        view = (FEATURES/'ota/index.htm').read_text()
        a=re.search(r'(?s)<script type="text/javascript">.*?</script>',original)
        b=re.search(r'(?s)<script type="text/javascript">.*?</script>',view)
        self.assertIsNotNone(a)
        self.assertIsNotNone(b)
        self.assertEqual(a.group(0),b.group(0))
        for element in ('r76s-check','r76s-download','r76s-install','r76s-sha','r76s-metadata','r76s-sysupgrade'):
            self.assertIn('id="'+element+'"',view)
        self.assertIn('R76S_UPDATER_UI_PATCH=7',view)

    def test_status_is_readonly(self):
        controller = (FEATURES/'status/r76s_status.lua').read_text()
        view=(FEATURES/'status/status.htm').read_text()
        self.assertIn('d.storage',controller)
        self.assertIn('d.dns_listeners',controller)
        for service in ('passwall','passwall2','smartdns','adguard'):
            self.assertIn('d.'+service,controller)
        for forbidden in ('uci set ','sysupgrade ', '/etc/init.d/passwall restart','io.popen('):
            self.assertNotIn(forbidden,controller)
        self.assertIn('八模式切换验证前保持禁用',view)

    def test_exact_version_patcher(self):
        path=ROOT/'build/local-arm64/v12-ota-exact-version.py'
        spec=importlib.util.spec_from_file_location('ota_exact',path)
        mod=importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        src='if echo "$remote" | grep -Fq "$current"; then\n  echo latest\nfi\n'
        changed, yes=mod.patch(src)
        self.assertTrue(yes)
        self.assertIn('grep -Fxq "$current"',changed)
        self.assertFalse(mod.patch(changed)[1])
        with self.assertRaises(ValueError): mod.patch('unknown OTA comparison')

    def test_release_locked(self):
        result=subprocess.run(['bash',str(ROOT/'build/local-arm64/macmini.sh'),'build'],capture_output=True,text=True)
        self.assertEqual(result.returncode,3)
        self.assertIn('DENIED',result.stderr)

if __name__=='__main__':unittest.main()
