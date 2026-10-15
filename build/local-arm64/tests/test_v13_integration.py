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
            verify = next((ROOT/'build/local-arm64/stages').glob('17-*.sh'))
            checked=subprocess.run(['bash','-e',str(verify)],cwd=work,capture_output=True,text=True)
            self.assertEqual(checked.returncode,0,checked.stdout+checked.stderr)
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
        path = 'feeds/luci-app-r76s-updater/files/view/r76s_updater/index.htm'
        baseline = subprocess.check_output(['git', 'show', '1daed16:build/local-arm64/v12-overlays/ota/index.htm'],
                                           cwd=ROOT, text=True)
        current = (ROOT / path).read_text()
        pattern = r'(?s)<script type="text/javascript">.*?</script>'
        self.assertIn('r76s-sysupgrade', current)
        self.assertIn('r76s-metadata', current)
        baseline_ids = re.findall(r'id="([^"]+)"', baseline)
        current_ids = re.findall(r'id="([^"]+)"', current)
        # V1.4.1 adds explicit OTA-signature status and a real restore form;
        # all existing DOM IDs remain in their original order.
        self.assertEqual([x for x in current_ids if x not in
                          ('r76s-ota-signature', 'r76s-restore-file')], baseline_ids)
        self.assertIn('r76s-ota-signature', current_ids)
        self.assertIn('r76s-restore-file', current_ids)
        self.assertIn('R76S-V1.4.1 · 在线升级', current)

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
                source = ROOT/'config/rules/r76s-rules.json'
                if index == 0:
                    source=folder/'legacy'
                    source.write_text(subprocess.check_output(['git','show',
                        '1daed16:files/etc/uci-defaults/99-r76s-v2-defaults'],cwd=ROOT,text=True))
                result = subprocess.run(['python3', '-', str(source),
                    *map(str, paths)], input=code, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                outputs.append([path.read_bytes() for path in paths])
            # Only the duplicate media domains move out of WeChatDirect.
            for old,new in zip(outputs[0],outputs[1]):
                pattern=r"(?ms)^config shunt_rules 'WeChatDirect'\n.*?(?=^config |\Z)"
                self.assertEqual(re.sub(pattern,'',old.decode()),re.sub(pattern,'',new.decode()))
                domains=lambda text:set(re.findall(r'domain:([a-z0-9.-]+)',text.decode()))
                self.assertEqual(domains(old),domains(new))
