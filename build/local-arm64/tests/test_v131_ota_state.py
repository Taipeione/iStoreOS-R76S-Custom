"""Exercise the OTA snapshot against firmware UCI in an isolated directory.

Set R76S_TEST_ROOTFS to a firmware rootfs, or R76S_TEST_UCI=/sbin/uci
and R76S_TEST_SHELL="busybox ash" on a real OpenWrt device (requires Python 3).
No router paths, build inputs, or firmware artifacts are written.
"""
import importlib.util
import itertools
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
HELPER = ROOT / 'files/usr/libexec/r76s/r76s-ota-preserve-state'
spec = importlib.util.spec_from_file_location(
    'hardening', ROOT / 'build/local-arm64/patches/r76s-v12-ota-hardening.py')
hardening = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hardening)


class Sources(unittest.TestCase):
    def test_generated_helper_matches_overlay(self):
        self.assertEqual(HELPER.read_text(), hardening.PRESERVE)
        self.assertEqual((ROOT / 'files/etc/config/r76s_ota_state').read_text(),
                         "config state 'state'\n")
        for source in (hardening.PRESERVE, hardening.RESTORE_INIT,
                       hardening.RESTORE_DEFAULTS):
            subprocess.run(['sh', '-n'], input=source, text=True, check=True)


@unittest.skipUnless((os.environ.get('R76S_TEST_ROOTFS') or os.environ.get('R76S_TEST_UCI')), 'requires firmware UCI')
class RealUCI(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='r76s-v131-test-')
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.config = self.base / 'config'
        self.config.mkdir()
        self.delta = self.base / 'delta'
        self.delta.mkdir()
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        if os.environ.get('R76S_TEST_UCI'):
            self.command = [os.environ['R76S_TEST_UCI']]
        else:
            fw = Path(os.environ['R76S_TEST_ROOTFS'])
            self.command = [str(fw / 'lib/ld-musl-aarch64.so.1'),
                            '--library-path', str(fw / 'lib'), str(fw / 'sbin/uci')]
        self.command += ['-c', str(self.config), '-C', str(self.config),
                         '-t', str(self.delta)]
        self.shell = shlex.split(os.environ.get('R76S_TEST_SHELL', 'sh'))
        self.wrapper = self.bin / 'uci'
        self.wrapper.write_text('#!/bin/sh\nexec ' + shlex.join(self.command) + ' "$@"\n')
        self.wrapper.chmod(0o755)
        self.init = self.base / 'init.d'
        self.init.mkdir()
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'])
        self.source = HELPER.read_text().replace('/etc/config', str(self.config))
        self.source = self.source.replace('/etc/init.d', str(self.init))
        self.source = self.source.replace('/tmp/r76s-ota-state.', str(self.base / 'verify-'))

    def seed(self, flags, init):
        for name, section, flag in zip(('passwall', 'passwall2', 'smartdns'),
                                        ('global', 'global', 'smartdns'), flags):
            (self.config / name).write_text(
                f"config {section} 'main'\n\toption enabled '{flag}'\n")
        for name, enabled in zip(('passwall', 'passwall2', 'smartdns', 'adguardhome'), init):
            path = self.init / name
            state = self.base / (name + '-init')
            state.write_text(str(enabled))
            path.write_text('#!/bin/sh\nstate=' + shlex.quote(str(state)) + '\n'
                            'case "$1" in\n'
                            'enabled) [ "$(cat "$state")" = 1 ];;\n'
                            'enable) printf 1 > "$state";;\n'
                            'disable) printf 0 > "$state";;\n'
                            '*) exit 0;;\nesac\n')
            path.chmod(0o755)

    def run_helper(self):
        return subprocess.run(self.shell + ['-c', self.source], env=self.env,
                              capture_output=True, text=True)

    def snapshot(self):
        result = subprocess.run(self.command + ['-q', 'export', 'r76s_ota_state'],
                                capture_output=True, text=True, check=True)
        return result.stdout

    def test_first_and_repeated_ota_all_service_flags(self):
        # Independent config enabled and init.d flags, including AGH both ways.
        for values in itertools.product((0, 1), repeat=7):
            flags, init = values[:3], values[3:]
            self.seed(flags, init)
            result = self.run_helper()
            conflict = flags[0] and flags[1] and init[0] and init[1]
            if conflict:
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('both enabled', result.stderr)
                continue
            self.assertEqual(result.returncode, 0, result.stderr)
            saved = self.snapshot()
            self.assertIn("option pending '1'", saved)
            for name, flag in zip(('passwall', 'passwall2', 'smartdns'), flags):
                self.assertIn(f"option {name}_uci '{flag}'", saved)
            for name, flag in zip(('passwall', 'passwall2', 'smartdns', 'adguardhome'), init):
                self.assertIn(f"option {name}_init '{flag}'", saved)

    def test_first_ota_does_not_recreate_initialized_section(self):
        self.seed((1, 0, 1), (1, 0, 1, 1))
        self.wrapper.write_text('#!/bin/sh\ncase " $* " in *" set r76s_ota_state.state=state "*) exit 1;; esac\nexec '
                                + shlex.join(self.command) + ' "$@"\n')
        self.assertFalse((self.config / 'r76s_ota_state').exists())
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.config / 'r76s_ota_state').stat().st_mode & 0o777, 0o600)
        self.assertIn("option pending '1'", self.snapshot())

    def test_existing_package_without_state_section(self):
        (self.config / 'r76s_ota_state').write_text("config other 'keep'\n\toption value 'saved'\n")
        self.seed((0, 1, 1), (0, 1, 1, 0))
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("option value 'saved'", self.snapshot())
        self.assertIn("option pending '1'", self.snapshot())

    def test_existing_empty_package(self):
        (self.config / 'r76s_ota_state').touch()
        self.seed((1, 0, 1), (1, 0, 0, 1))
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_restore_commits_flags_and_init_states(self):
        for flags, init in (((1, 0, 1), (1, 0, 1, 1)),
                            ((0, 1, 0), (0, 1, 0, 0))):
            self.seed(flags, init)
            result = self.run_helper()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.seed((0, 0, 0), (0, 0, 0, 0))
            yaml = self.base / 'adguardhome.yaml'
            yaml.write_text('dns: {}\n')
            source = hardening.RESTORE_INIT.replace('/etc/init.d', str(self.init))
            source = source.replace('/etc/adguardhome.yaml', str(yaml))
            result = subprocess.run(self.shell + ['-c', source + '\nstart\n'],
                                    env=self.env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("option pending '0'", self.snapshot())
            for name, section, value in zip(('passwall', 'passwall2', 'smartdns'),
                                            ('global', 'global', 'smartdns'), flags):
                result = subprocess.run(self.command + ['get', f'{name}.@{section}[0].enabled'],
                                        capture_output=True, text=True, check=True)
                self.assertEqual(result.stdout.strip(), str(value))
            for name, value in zip(('passwall', 'passwall2', 'smartdns', 'adguardhome'), init):
                self.assertEqual((self.base / (name + '-init')).read_text(), str(value))

    def test_commit_failure_blocks_ota(self):
        self.seed((1, 0, 1), (1, 0, 1, 0))
        self.wrapper.write_text('#!/bin/sh\ncase " $* " in *" commit r76s_ota_state "*) exit 1;; esac\nexec '
                                + shlex.join(self.command) + ' "$@"\n')
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('UCI commit failed', result.stderr)

    def test_unpersisted_changes_cannot_pass_verification(self):
        self.seed((1, 0, 1), (1, 0, 1, 0))
        self.wrapper.write_text('#!/bin/sh\ncase " $* " in *" commit r76s_ota_state "*) exit 0;; esac\nexec '
                                + shlex.join(self.command) + ' "$@"\n')
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('cannot read committed pending', result.stderr)

    def test_invalid_enabled_blocks_ota(self):
        self.seed(('invalid', 0, 0), (1, 0, 0, 0))
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('invalid enabled value', result.stderr)


if __name__ == '__main__':
    unittest.main()
