import json
import pathlib
import re
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]


class V141Features(unittest.TestCase):
    def test_health_command_is_safe_and_prefers_wan_6(self):
        path = ROOT / 'feeds/r76s-core/files/usr/bin/r76s-health'
        text = path.read_text()
        self.assertEqual(subprocess.run(['sh', '-n', str(path)]).returncode, 0)
        self.assertLess(text.find("iface_field wan_6"), text.find("iface_field wan6"))
        self.assertNotRegex(text, r'network\.wan[^ ]*\.password|pppoe.*password|private_key')

    def test_component_center_has_all_plugins_and_core_blacklist(self):
        updater = (ROOT / 'feeds/luci-app-r76s-updater/files/root/usr/libexec/r76s/r76s-component-updater').read_text()
        for name in ('passwall', 'passwall2', 'xray-core', 'sing-box', 'chinadns-ng', 'smartdns', 'adguardhome', 'dnsmasq-full', 'wireguard', 'ddns', 'upnp', 'docker', 'istore', 'quickstart', 'r76s-status', 'r76s-updater', 'r76s-health'):
            self.assertIn(name, updater)
        for name in ('kernel', 'kmod-*', 'base-files', 'busybox', 'firewall4', 'netifd', 'procd', 'ubus', 'uci', 'opkg', 'libc'):
            self.assertIn(name, updater)
        self.assertNotIn('smartdns.bin: not found', updater)
        self.assertIn('has_core_dependency', updater)
        self.assertIn('restore_service_state', updater)
        self.assertIn('opkg update', updater)
        for name in ('r76s-status', 'r76s-updater', 'r76s-health'):
            self.assertRegex(updater, rf'{name}\\|[^\\n]+\\|firmware')
        self.assertIn('需要随固件升级', updater)
        self.assertEqual(subprocess.run(['sh', '-n', str(ROOT / 'feeds/luci-app-r76s-updater/files/root/usr/libexec/r76s/r76s-component-updater')]).returncode, 0)

    def test_updater_and_restore_are_real_operations(self):
        controller = (ROOT / 'feeds/luci-app-r76s-updater/files/controller/r76s_updater.lua').read_text()
        page = (ROOT / 'feeds/luci-app-r76s-updater/files/view/r76s_updater/index.htm').read_text()
        self.assertIn('api_restore', controller)
        self.assertIn('/sbin/sysupgrade -b', controller)
        self.assertIn('/sbin/sysupgrade -r', controller)
        self.assertIn('tar -tvzf', controller)
        self.assertIn('OTA 签名', page)
        self.assertIn('name="backup"', page)
        self.assertIn('<%=api_base%>/restore', page)
        self.assertIn('ota_signature', controller)
        self.assertIn('R76S_V14_OTA_BACKEND', controller)

    def test_stage_adapter_is_idempotent_and_preserves_controller_tail(self):
        adapter = (ROOT / 'scripts/r76s-v14-stage.py').read_text()
        self.assertIn("text.find('\\nfunction api_backup()', start)", adapter)
        self.assertIn("'/usr/libexec/r76s/r76s-ota install' not in text", adapter)
        self.assertEqual(subprocess.run(['python3', '-m', 'py_compile', str(ROOT / 'scripts/r76s-v14-stage.py')]).returncode, 0)

    def test_rules_remain_exactly_stable(self):
        rules = json.loads((ROOT / 'config/rules/r76s-rules.json').read_text())['rules']
        self.assertEqual(len(rules), 43)
        self.assertEqual(rules[0]['name'], 'WeChatDirect')
        self.assertEqual(rules[-1]['name'], 'TencentMediaDirect')

    def test_prerelease_metadata_and_release_assets(self):
        release = json.loads((ROOT / 'config/r76s-release.json').read_text())
        self.assertEqual(release['version'], 'R76S-V1.4.1')
        self.assertEqual(release['channel'], 'prerelease')
        workflow = (ROOT / '.github/workflows/r76s-v1.4-build.yml').read_text()
        self.assertIn('--prerelease --latest=false', workflow)
        self.assertIn('gh release upload R76S-V1.4.1', workflow)
        self.assertIn('--clobber', workflow)
        self.assertNotIn('gh release edit R76S-V1.4.1 --repo "$GITHUB_REPOSITORY" --latest', workflow)


if __name__ == '__main__':
    unittest.main()
