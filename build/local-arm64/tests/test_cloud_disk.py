from pathlib import Path
import importlib.util
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('cloud_disk', Path(__file__).parents[1] / 'prepare-cloud-disk.py')
disk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(disk)


class CloudDiskTests(unittest.TestCase):
    def test_source_files_and_source_archives_are_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, content in [('source.c', b'int main() {}'), ('script.py', b'print(1)'),
                                  ('sdk-sources.jar', b'PK\x03\x04'), ('source.tar.gz', b'\x1f\x8b')]:
                path = root / name
                path.write_bytes(content)
                self.assertFalse(disk.compiled_asset(path), name)

    def test_binary_assets_and_symlink_boundary(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, content in [('compiler', b'\x7fELF'), ('runtime.dll', b'MZ'),
                                  ('library.a', b'!<arch>\n'), ('android.jar', b'PK\x03\x04')]:
                path = root / name
                path.write_bytes(content)
                self.assertTrue(disk.compiled_asset(path), name)
            link = root / 'linked-library'
            link.symlink_to(root / 'compiler')
            self.assertFalse(disk.compiled_asset(link))
