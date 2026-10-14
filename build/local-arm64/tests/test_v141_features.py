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
        self.assertNotIn('gh release edit R76S-V1.4.1 --repo "$GITHUB_REPOSITORY" --latest', workflow)


if __name__ == '__main__':
    unittest.main()
