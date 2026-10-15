import json
import os
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]


class V143Features(unittest.TestCase):
    def _run_root_policy(self, shadow_value, marker=False):
        source = (ROOT / 'files/etc/init.d/r76s-root-password').read_text()
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            etc = root / 'etc'
            (etc / 'config').mkdir(parents=True)
            shadow = etc / 'shadow'
            release = etc / 'openwrt_release'
            marker_path = etc / 'config/r76s_root_password_v143_done'
            fakebin = root / 'bin'; fakebin.mkdir()
            passwd = fakebin / 'passwd'
            passwd.write_text(
                '#!/bin/sh\n'
                'cat > "$R76S_TEST_PASSWD_INPUT"\n'
                "printf '%s\\n' 'root:$6$new$password:0:0:root:/root:/bin/ash' > \"$R76S_TEST_SHADOW\"\n"
            )
            passwd.chmod(0o755)
            runner = root / 'runner'
            runner.write_text(source.replace('#!/bin/sh /etc/rc.common', '#!/bin/sh').replace('/etc/config', str(etc / 'config'))
                              .replace('/etc/openwrt_release', str(release))
                              .replace('/etc/shadow', str(shadow)) + '\nboot\n')
            runner.chmod(0o755)
            env = dict(os.environ, PATH=str(fakebin) + ':' + os.environ['PATH'],
                       R76S_TEST_SHADOW=str(shadow), R76S_TEST_PASSWD_INPUT=str(root / 'passwd-input'))
            release.write_text("DISTRIB_REVISION='R76S-V1.4.3'\n")
            shadow.write_text(f'root:{shadow_value}:0:0:root:/root:/bin/ash\n')
            if marker:
                marker_path.touch()
            result = subprocess.run([str(runner)], env=env, capture_output=True, text=True)
            input_file = root / 'passwd-input'
            return (result.returncode, result.stderr, marker_path.exists(), shadow.read_text(),
                    input_file.exists(), input_file.read_text() if input_file.exists() else '')

    def test_unified_policy_resets_preserved_password_once_and_allows_later_change(self):
        rc, err, marker, shadow, input_exists, input_text = self._run_root_policy('$6$old$hash')
        self.assertEqual(rc, 0, err)
        self.assertTrue(marker)
        self.assertIn('root:$6$new$password:', shadow)
        self.assertTrue(input_exists)
        self.assertEqual(input_text, 'password\npassword\n')
        # A boot with the marker is side-effect free after an administrator change.
        rc, err, marker, shadow, input_exists, input_text = self._run_root_policy('$6$user$changed', marker=True)
        self.assertEqual(rc, 0, err)
        self.assertIn('root:$6$user$changed:', shadow)
        self.assertFalse(input_exists)

    def test_fixed_clean_flash_password_and_old_mechanisms_are_absent(self):
        stage = next((ROOT / 'build/local-arm64/stages').glob('16-*.sh')).read_text()
        policy = (ROOT / 'files/etc/init.d/r76s-root-password').read_text()
        auth = (ROOT / 'files/etc/uci-defaults/99-r76s-root-auth').read_text()
        self.assertIn('CLEAN_FLASH_ROOT_HASH=', stage)
        self.assertIn('R76S_V143_ROOT_PASSWORD_POLICY', policy)
        self.assertIn('R76S_V143_ROOT_PASSWORD_AUTH', auth)
        self.assertIn("option Interface 'lan'", stage)
        self.assertIn('password\npassword', policy)
        self.assertNotIn('/dev/urandom', stage + policy + auth)
        self.assertNotIn('/dev/ttyS0', stage + policy + auth)
        self.assertFalse((ROOT / 'files/etc/uci-defaults/99-r76s-first-root-password').exists())
        self.assertFalse((ROOT / 'files/etc/uci-defaults/99-r76s-v142-root-password-migration').exists())
        self.assertFalse((ROOT / 'files/etc/uci-defaults/99-r76s-v143-root-password-migration').exists())

    def test_artifact_gate_verifies_password_hash_and_dropbear_auth(self):
        audit = (ROOT / 'scripts/r76s-v111-final-audit.py').read_text()
        self.assertIn('FIXED_CLEAN_FLASH_ROOT_HASH', audit)
        self.assertIn("crypt.crypt('password', value)", audit)
        self.assertIn('RANDOM_PASSWORD_MECHANISM_PRESENT', audit)
        self.assertIn('DROPBEAR_ROOT_PASSWORD_AUTH_DISABLED', audit)
        self.assertIn('R76S_V143_ROOT_PASSWORD_POLICY', audit)
        self.assertIn("boot_link.resolve(strict=True) != policy.resolve(strict=True)", audit)
        self.assertIn("boot_link.is_symlink()", audit)

    def test_clean_flash_lan_default_is_fixed(self):
        stage = next((ROOT / 'build/local-arm64/stages').glob('16-*.sh')).read_text()
        self.assertIn('lan) ipad=${ipaddr:-"192.168.50.1"} ;;', stage)
        self.assertIn('LAN: 192.168.50.1/24', stage)
        self.assertIn('WAN: upstream R76S default DHCP client', stage)

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
        self.assertIn('R76S_V12_OTA_HARDENING', controller)

    def test_ota_is_formal_stable_and_transactional(self):
        controller = (ROOT / 'feeds/luci-app-r76s-updater/files/controller/r76s_updater.lua').read_text()
        backend = (ROOT / 'feeds/r76s-core/files/usr/libexec/r76s/r76s-ota').read_text()
        page = (ROOT / 'feeds/luci-app-r76s-updater/files/view/r76s_updater/index.htm').read_text()
        config = (ROOT / 'feeds/r76s-core/files/etc/config/r76s').read_text()
        self.assertIn("option channel 'stable'", config)
        self.assertIn('api_channel', controller)
        self.assertIn('selected_channel', backend)
        self.assertNotIn('测试版 / 预发布版', page)
        self.assertIn("R76S-V1.4.3", backend)
        self.assertIn("phase=='channel'", backend)
        self.assertIn("m.version==release_tag(channel)", backend)
        for check in ('sysupgrade -T', 'firmware.img.sha256sum', 'configuration.tar.gz',
                      'configuration.tar.gz.part', 'tar -tzf', '0700',
                      '--continue-at -', '--retry-delay', 'transaction', 'pid_alive'):
            self.assertIn(check, backend + controller + page)
        self.assertEqual(backend.count('/sbin/sysupgrade -b '), 1)
        self.assertIn("request(\n      'check',\n      'POST'", page)
        self.assertIn("request(\n      'download',\n      'POST'", page)
        self.assertIn("request(\n      'verify',\n      'POST'", page)
        self.assertIn("request(\n      'install',\n      'POST'", page)

    def test_lua_chmod_and_transaction_syntax_fixture(self):
        backend = (ROOT / 'feeds/r76s-core/files/usr/libexec/r76s/r76s-ota').read_text()
        self.assertIn("fs.chmod(run,'0700')", backend)
        self.assertNotIn('fs.chmod(run,448)', backend)
        self.assertIn('ok,err=pcall(transaction_body)', backend)
        self.assertIn('release_lock()', backend)
        self.assertIn('flash_launched=true', backend)

    def test_unpatched_v140_fixture_is_repaired_by_source(self):
        old_page = subprocess.check_output([
            'git', 'show', '7dcf3a7:feeds/luci-app-r76s-updater/files/view/r76s_updater/index.htm'
        ], text=True)
        old_backend = subprocess.check_output([
            'git', 'show', '7dcf3a7:feeds/r76s-core/files/usr/libexec/r76s/r76s-ota'
        ], text=True)
        self.assertIn("'check',\n      'GET'", old_page)
        self.assertIn('fs.chmod(run,448)', old_backend)
        page = (ROOT / 'feeds/luci-app-r76s-updater/files/view/r76s_updater/index.htm').read_text()
        backend = (ROOT / 'feeds/r76s-core/files/usr/libexec/r76s/r76s-ota').read_text()
        for action in ('check', 'download', 'verify', 'install'):
            self.assertIn("'" + action + "',\n      'POST'", page)
        self.assertIn("fs.chmod(run,'0700')", backend)

    @unittest.skipUnless(shutil.which('lua5.1') or shutil.which('lua'), 'requires Lua interpreter')
    def test_lua_runtime_accepts_string_chmod_mode(self):
        lua = shutil.which('lua5.1') or shutil.which('lua')
        backend = ROOT / 'feeds/r76s-core/files/usr/libexec/r76s/r76s-ota'
        with tempfile.TemporaryDirectory() as directory:
            fixture = pathlib.Path(directory) / 'chmod-test.lua'
            fixture.write_text("""
local chmod_mode
package.preload['nixio.fs'] = function()
  return {
    mkdirr=function() return true end,
    chmod=function(_, mode) chmod_mode=mode; assert(type(mode)=='string'); assert(mode=='0700') end,
    readfile=function() return '' end,
    access=function() return false end,
    rmdir=function() return true end,
    remove=function() return true end,
    writefile=function() return true end,
    rename=function() return true end
  }
end
package.preload['nixio'] = function() return {getpid=function() return 1234 end} end
package.preload['luci.sys'] = function() return {exec=function() return '' end, call=function() return 0 end} end
package.preload['luci.jsonc'] = function() return {parse=function() return nil end, stringify=function() return '{}' end} end
arg={'status'}
dofile(%s)
""" % (repr(str(backend))))
            result = subprocess.run([lua, str(fixture)], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)

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

    def test_formal_metadata_and_release_assets(self):
        release = json.loads((ROOT / 'config/r76s-release.json').read_text())
        self.assertEqual(release['version'], 'R76S-V1.4.3')
        self.assertEqual(release['channel'], 'stable')
        workflow = (ROOT / '.github/workflows/r76s-v1.4-build.yml').read_text()
        self.assertIn('--prerelease=false --draft=false --latest', workflow)
        self.assertIn('R76S-stable', workflow)
        self.assertIn('RELEASE_ASSET_REPLACEMENT_REQUIRES_USER_CONFIRMATION=YES', workflow)
        self.assertIn('gh release edit R76S-V1.4.3', workflow)
        self.assertIn('gh release upload R76S-stable', workflow)


if __name__ == '__main__':
    unittest.main()
