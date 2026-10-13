from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
FILES = ROOT / 'feeds/luci-app-r76s-status/files'
NODE = os.environ.get('R76S_TEST_NODE') or shutil.which('node')
LUA = os.environ.get('R76S_TEST_LUA') or shutil.which('lua5.1') or shutil.which('lua')


class Phase2UI(unittest.TestCase):
    @unittest.skipUnless(LUA, 'Lua test interpreter not available')
    def test_status_classifiers(self):
        result = subprocess.run([LUA, 'build/local-arm64/tests/v13-services-test.lua'],
                                cwd=ROOT, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('WIREGUARD_SERVICE_CLASSIFIER=PASS', result.stdout)
        self.assertIn('ADGUARD_SERVICE_CLASSIFIER=PASS', result.stdout)

    @unittest.skipUnless(LUA, 'Lua test interpreter not available')
    def test_controller_and_template_lua_syntax(self):
        paths = list((FILES / 'controller').glob('r76s_*.lua')) + list((FILES/'model/r76s').glob('*.lua'))
        for path in paths:
            code = 'assert(loadfile(' + repr(str(path)) + '))'
            result = subprocess.run([LUA, '-'], input=code, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
        for path in (FILES/'view').rglob('*.htm'):
            chunks = []
            for tag in re.findall(r'<%(.*?)%>', path.read_text(), re.S):
                if tag.startswith('+'): continue
                chunks.append('local value = (' + tag[1:] + ')' if tag.startswith('=') else tag)
            source = '\n'.join(chunks)
            with tempfile.NamedTemporaryFile(mode='w', suffix='.lua') as script:
                script.write(source); script.flush()
                result = subprocess.run([LUA, '-'], input='assert(loadfile('+repr(script.name)+'))',
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, str(path) + ': ' + result.stderr)

    @unittest.skipUnless(NODE, 'Node syntax checker not available')
    def test_page_javascript_syntax(self):
        pages = [ROOT/'build/local-arm64/v12-overlays/ota/index.htm',
                 FILES/'view/r76s_adguardhome/status.htm']
        for path in pages:
            for script in re.findall(r'<script[^>]*>(.*?)</script>', path.read_text(), re.S):
                result = subprocess.run([NODE, '--check'], input=script, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_phase2_pages_and_models_survive_staging(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            shutil.copytree(ROOT/'feeds/luci-app-r76s-status', work/'feeds/luci-app-r76s-status')
            stage = next((ROOT/'build/local-arm64/stages').glob('14-*.sh'))
            result = subprocess.run(['bash','-e',str(stage)], cwd=work,
                env={**os.environ,'R76S_REPO_ROOT':str(ROOT)}, text=True,capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            package = work/'openwrt/package/custom/luci-app-r76s-status'
            for relative in ('controller/r76s_wireguard.lua','view/r76s_wireguard/status.htm',
                             'model/r76s/services.lua','controller/r76s_ip_policy.lua',
                             'view/r76s_ip_policy/status.htm',
                             'controller/r76s_diagnostics.lua','model/r76s/diagnostics.lua',
                             'model/r76s/diagnostics_collect.lua','view/r76s_diagnostics/status.htm',
                             'htdocs/luci-static/resources/view/r76s_wireguard/client.js',
                             'root/usr/share/luci/menu.d/r76s-wireguard-client.json'):
                self.assertEqual((package/'files'/relative).read_bytes(),(FILES/relative).read_bytes())
                self.assertIn(relative, (package/'Makefile').read_text())

            for relative in ('htdocs/luci-static/resources/r76s/wireguard.js',
                             'htdocs/luci-static/resources/r76s/wireguard-status.js'):
                self.assertEqual((package/'files'/relative).read_bytes(),(FILES/relative).read_bytes())
            self.assertIn('htdocs/luci-static/resources/r76s/*.js', (package/'Makefile').read_text())
