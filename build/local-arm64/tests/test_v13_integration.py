"""Check actual staging and phase-one preservation, without compiling firmware."""
from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]


class V13Integration(unittest.TestCase):
    def test_adguard_entry_survives_status_stage(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            shutil.copytree(ROOT / 'feeds/luci-app-r76s-status',
                            work / 'feeds/luci-app-r76s-status')
            stage = next((ROOT / 'build/local-arm64/stages').glob('14-*.sh'))
            result = subprocess.run(['bash', '-e', str(stage)], cwd=work,
                env={**os.environ, 'R76S_REPO_ROOT': str(ROOT)},
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            package = work / 'openwrt/package/custom/luci-app-r76s-status'
            controller = package / 'files/controller/r76s_adguardhome.lua'
            view = package / 'files/view/r76s_adguardhome/status.htm'
            self.assertTrue(controller.is_file())
            self.assertTrue(view.is_file())
            text = controller.read_text()
            self.assertIn('"admin", "services", "r76s_adguardhome"', text)
            for mutation in ('uci set', 'uci commit', ' restart', ' start ',
                             ' enable ', ' stop ', ' disable '):
                self.assertNotIn(mutation, text)
            makefile = (package / 'Makefile').read_text()
            for path in ('controller/r76s_adguardhome.lua',
                         'view/r76s_adguardhome/status.htm'):
                self.assertIn(path, makefile)

    def test_wireguard_selected_without_network_defaults(self):
        config = (ROOT / 'config/R76S.config').read_text()
        for package in ('wireguard-tools', 'kmod-wireguard', 'luci-proto-wireguard',
                        'luci-lib-uqr', 'ucode'):
            self.assertIn(f'CONFIG_PACKAGE_{package}=y', config.splitlines())
        # Phase one does not inject keys, peers or routing/firewall defaults.
        self.assertFalse((ROOT / 'files/etc/config/network').exists())
        self.assertFalse((ROOT / 'files/etc/config/firewall').exists())

    def test_ota_javascript_and_ids_match_baseline(self):
        path = 'build/local-arm64/v12-overlays/ota/index.htm'
        baseline = subprocess.check_output(['git', 'show', '1daed16:' + path],
                                           cwd=ROOT, text=True)
        current = (ROOT / path).read_text()
        pattern = r'(?s)<script type="text/javascript">.*?</script>'
        self.assertEqual(re.findall(pattern, current), re.findall(pattern, baseline))
        self.assertEqual(re.findall(r'id="([^"]+)"', current),
                         re.findall(r'id="([^"]+)"', baseline))
        self.assertIn('R76S-V1.3.1 · 在线升级', current)

    def test_generated_rules_match_stable_baseline(self):
        stage = next((ROOT / 'build/local-arm64/stages').glob('16-*.sh'))
        baseline = subprocess.check_output(['git', 'show', '1daed16:' +
            str(stage.relative_to(ROOT))], cwd=ROOT, text=True)
        with tempfile.TemporaryDirectory() as directory:
            outputs = []
            for index, text in enumerate((baseline, stage.read_text())):
                folder = Path(directory) / str(index)
                folder.mkdir()
                paths = [folder / name for name in ('pw', 'pw2')]
                for path in paths:
                    path.write_text("config global 'global'\n")
                code = text.split("<<'PY_RULES'\n", 1)[1].split('\nPY_RULES\n', 1)[0]
                result = subprocess.run(['python3', '-',
                    str(ROOT / 'files/etc/uci-defaults/99-r76s-v2-defaults'),
                    *map(str, paths)], input=code, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                outputs.append([path.read_bytes() for path in paths])
            self.assertEqual(outputs[0], outputs[1])
