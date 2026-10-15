import pathlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]
SCRIPT = ROOT / 'scripts/r76s-v140-ota-bootstrap-fix.sh'


class V140BootstrapFix(unittest.TestCase):
    def test_bootstrap_script_is_shell_valid(self):
        self.assertEqual(subprocess.run(['sh', '-n', str(SCRIPT)]).returncode, 0)

    def test_bootstrap_is_non_flashing_and_atomic(self):
        text = SCRIPT.read_text()
        self.assertIn('R76S_V140_BOOTSTRAP_FIX', text)
        self.assertIn('configuration.tar.gz.part', text)
        self.assertIn('tar -tzf "$PART"', text)
        self.assertIn('mv -f "$PART" "$FINAL"', text)
        self.assertIn('/sbin/sysupgrade -b "$PART"', text)
        self.assertNotIn('/sbin/sysupgrade "$', text)
        self.assertNotIn('curl ', text)
        # The script may mention the existing image in its safety message; it
        # must not contain a download or flash command for that image.
        self.assertNotIn('curl.*firmware.img', text)
        self.assertNotIn('sysupgrade /tmp/firmware.img', text)

    def test_bootstrap_has_stale_pid_and_transaction_guards(self):
        text = SCRIPT.read_text()
        for marker in ('WRAPPER_LOCK', 'live_pid', 'clear_stale_backend_lock',
                       '已有配置备份事务正在运行', 'phase":"flashing',
                       'keep 列表包含临时目录'):
            self.assertIn(marker, text)

    def test_v140_source_root_cause_fixture_is_unchanged(self):
        backend = subprocess.check_output([
            'git', 'show', '7dcf3a7:feeds/r76s-core/files/usr/libexec/r76s/r76s-ota'
        ], text=True)
        self.assertIn("fs.chmod(run,448)", backend)
        self.assertIn("/sbin/sysupgrade -b '..run..'/configuration.tar.gz", backend)
        self.assertNotIn('configuration.tar.gz.part', backend)


if __name__ == '__main__':
    unittest.main()
