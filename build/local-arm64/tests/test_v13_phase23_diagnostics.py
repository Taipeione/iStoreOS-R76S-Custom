from pathlib import Path
from html.parser import HTMLParser
import os
import shutil
import subprocess
import unittest
ROOT=Path(__file__).resolve().parents[3]
FILES=ROOT/'feeds/luci-app-r76s-status/files'
LUA=os.environ.get('R76S_TEST_LUA') or shutil.which('lua5.1') or shutil.which('lua')

class TableLabels(HTMLParser):
    def __init__(self):
        super().__init__();self.headers=0
    def handle_starttag(self,tag,attrs):
        if tag=='th' and dict(attrs).get('scope')=='row':self.headers+=1

class Diagnostics(unittest.TestCase):
    @unittest.skipUnless(LUA,'Lua test interpreter not available')
    def test_classifiers_collectors_and_readonly_controllers(self):
        result=subprocess.run([LUA,'build/local-arm64/tests/v13-diagnostics-test.lua'],cwd=ROOT,text=True,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('DNS_SECURITY_CLASSIFIERS=PASS',result.stdout)
        self.assertIn('DNS_SECURITY_COLLECTOR_AND_CONTROLLERS=PASS',result.stdout)

    def test_new_components_are_packaged(self):
        makefile=(FILES.parent/'Makefile').read_text()
        stage=next((ROOT/'build/local-arm64/stages').glob('19-*.sh')).read_text()
        for relative in ('controller/r76s_diagnostics.lua','model/r76s/diagnostics.lua',
                         'model/r76s/diagnostics_collect.lua','view/r76s_diagnostics/status.htm'):
            self.assertIn(relative,makefile)
            self.assertIn(relative,stage)
            self.assertTrue((FILES/relative).is_file())
        template=(FILES/'view/r76s_diagnostics/status.htm').read_text()
        for field in ('row.title','row.detail','row.advice'):
            self.assertIn('h('+field+')',template)

    def test_final_ota_labels_and_links(self):
        page=(ROOT/'build/local-arm64/v12-overlays/ota/index.htm').read_text()
        parser=TableLabels();parser.feed(page.split('<script type="text/javascript">')[0])
        self.assertEqual(parser.headers,10)
        self.assertIn('r76s_dns_diagnostics',page)
        self.assertIn('r76s_router_security',page)
        self.assertIn('R76S-V1.3.2 · 在线升级',page)
        self.assertIn('aria-hidden="true"',page)
