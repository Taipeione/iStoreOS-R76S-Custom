import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    'release_assets', Path(__file__).parents[1] / 'release-assets.py')
assets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assets)


class ReleaseAssetsTests(unittest.TestCase):
    def test_manifest_and_checksums_cover_published_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / 'target'
            release = target / 'release'
            release.mkdir(parents=True)
            for name in ('R76S-V1.4.3-TF-squashfs.img',
                         'R76S-V1.4.3-TF-squashfs.img.gz', 'version.latest',
                         'version.index', 'ota.footer.html', 'BOOTLOADER_INFO.txt'):
                (release / name).write_bytes(name.encode())
            # Internal build metadata is not uploaded by the Release workflow.
            (release / 'config.buildinfo').write_text('internal\n')
            binary = target / 'friendlyarm_nanopi-r76s-test.bin'
            binary.write_bytes(b'real bin')
            assets.generate(release, target, 'owner/repo', 'abc123')
            manifest = json.loads((release / 'ota.json').read_text())
            self.assertEqual(manifest['version'], 'R76S-V1.4.3')
            self.assertEqual(manifest['source_commit'], 'abc123')
            self.assertIn('/releases/download/R76S-V1.4.3/', manifest['url'])
            self.assertEqual(len(manifest['artifacts']), 3)
            self.assertEqual(binary.read_bytes(), b'real bin')
            checksums = (release / 'sha256').read_text()
            self.assertEqual(checksums, (release / 'sha256sums').read_text())
            for line in checksums.splitlines():
                expected, name = line.split('  ', 1)
                self.assertEqual(expected, hashlib.sha256((release / name).read_bytes()).hexdigest())
            self.assertNotIn('config.buildinfo', checksums)
            (release / manifest['image']).write_bytes(b'tampered')
            self.assertNotEqual(manifest['sha256'], assets.digest(release / manifest['image']))

    def test_missing_final_images_blocks_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                assets.generate(directory, directory, 'owner/repo', 'abc123')
