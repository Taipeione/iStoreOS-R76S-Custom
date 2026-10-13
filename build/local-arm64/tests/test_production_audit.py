import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('production', ROOT / 'scripts/r76s-production-audit.py')
production = importlib.util.module_from_spec(spec)
spec.loader.exec_module(production)


class ProductionAuditTests(unittest.TestCase):
    def test_image_content_gate_and_regressions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def write(name, text):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text)
                return path
            release = write('etc/openwrt_release',
                "DISTRIB_RELEASE='24.10.8'\nDISTRIB_REVISION='R76S-V1.2.2'\n")
            status = write('usr/lib/opkg/status', ''.join(
                f'Package: {name}\nStatus: install user installed\n\n'
                for name in production.PACKAGES))
            stage = next((ROOT / 'build/local-arm64/stages').glob('16-*.sh')).read_text()
            code = stage.split("<<'PY_RULES'\n", 1)[1].split('\nPY_RULES\n', 1)[0]
            defaults = [write(f'usr/share/{app}/0_default_config', "config global 'global'\n")
                        for app in ('passwall', 'passwall2')]
            result = subprocess.run(['python3', '-', str(ROOT / 'files/etc/uci-defaults/99-r76s-v2-defaults'),
                *map(str, defaults)], input=code, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            clean_text = stage.split("<<'EOF_CLEAN_SERVICES'\n", 1)[1].split('\nEOF_CLEAN_SERVICES', 1)[0]
            clean = write('etc/uci-defaults/98-r76s-v110-clean-services', clean_text)
            self.assertEqual(production.audit(root), [])
            for path, old, new, expected in (
                (release, 'R76S-V1.2.2', 'V1.2', 'identity mismatch'),
                (status, 'Package: wireguard-tools', 'Package: absent', 'wireguard-tools'),
                (defaults[0], "shunt_rules 'Xbox'", "shunt_rules 'WrongOrder'", 'order mismatch'),
                (clean, "port='6053'", "port='53'", 'SmartDNS clean default'),
            ):
                with self.subTest(expected=expected):
                    original = path.read_text()
                    path.write_text(original.replace(old, new))
                    self.assertTrue(any(expected in issue for issue in production.audit(root)))
                    path.write_text(original)
