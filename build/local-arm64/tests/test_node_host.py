from pathlib import Path
import importlib.util
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('node_host', Path(__file__).parents[1] / 'v12-node-host-hook.py')
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)


class NodeHostTests(unittest.TestCase):
    def test_make_expansion_installs_matching_host_tools(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'bin').mkdir()
            for name in ('node', 'npm', 'npx'):
                path = root / 'bin' / name
                path.write_text('#!/bin/sh\necho v20.20.2\n')
                path.chmod(0o755)
            makefile = root / 'Makefile'
            makefile.write_text(f'''PKG_VERSION:=20.20.2
INSTALL_DIR:=mkdir -p
HOST_BUILD_DIR:={root}/host-build
define HostBuild
.PHONY: host
host:
\t$(call Host/Prepare)
\t$(call Host/Compile)
\t$(call Host/Install,{root}/staging)
endef
$(eval $(call HostBuild))
# Target package sentinel: must stay untouched.
TARGET_RULE:=original
''')
            hook.patch(makefile, root)
            once = makefile.read_text()
            hook.patch(makefile, root)
            self.assertEqual(once, makefile.read_text())
            self.assertIn('TARGET_RULE:=original', once)
            result = subprocess.run(['make', '-f', str(makefile), 'host'], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            for name in ('node', 'npm', 'npx'):
                self.assertTrue((root / 'staging/bin' / name).samefile(root / 'bin' / name))

    def test_unexpected_package_or_missing_tools_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            makefile = root / 'Makefile'
            makefile.write_text('PKG_VERSION:=20.20.2\n$(eval $(call HostBuild))\n')
            with self.assertRaises(ValueError):
                hook.patch(makefile, root)
