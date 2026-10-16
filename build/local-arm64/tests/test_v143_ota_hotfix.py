import hashlib
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
OTA = ROOT / "feeds/r76s-core/files/usr/libexec/r76s/r76s-ota"
HOTFIX = ROOT / "hotfix/r76s-v143-ota-hotfix"
INSTALL = HOTFIX / "install.sh"
ROLLBACK = HOTFIX / "rollback.sh"


class V143OtaHotfix(unittest.TestCase):
    def test_current_source_uses_stable_metadata_release(self):
        text = OTA.read_text()
        self.assertIn("return 'R76S-stable'", text)
        self.assertIn("OTA metadata 未提供有效版本", text)
        self.assertNotIn("return 'R76S-V1.4.4'", text)

    def test_v143_client_pin_is_the_real_root_cause(self):
        patch = (HOTFIX / "r76s-ota-stable-channel.patch").read_text()
        self.assertIn("-    return 'R76S-V1.4.3'", patch)
        self.assertIn("-        assert(m.version==release_tag(channel)", patch)
        self.assertIn("+    return 'R76S-stable'", patch)

    def test_exact_hotfix_transform(self):
        patch = (HOTFIX / "r76s-ota-stable-channel.patch").read_text()
        self.assertIn("+    return 'R76S-stable'", patch)
        self.assertIn("+        assert(revision(m.version or ''),", patch)
        self.assertIn("+        persist({phase='channel_changed',channel='stable',release='stable'})", patch)

    def test_installer_is_guarded_and_non_flashing(self):
        text = INSTALL.read_text()
        self.assertIn("EXPECTED_REVISION=R76S-V1.4.3", text)
        self.assertIn("EXPECTED_SHA256=684e80f5ac274ef732d726eb19b3691bb6c83a645250febe4212c3d698943666", text)
        self.assertIn("return 'R76S-stable'", text)
        self.assertNotIn("r76s-ota install", text)
        self.assertIsNone(re.search(r"(?:^|[\n;])[ \t]*(?:/sbin/)?sysupgrade(?:[ \t]|$)", text))
        self.assertNotIn("firmware.img", text)
        self.assertIn("loadfile('$TMP')", text)

    def test_rollback_is_present(self):
        text = ROLLBACK.read_text()
        self.assertIn("r76s-v143-ota-hotfix-backup", text)
        self.assertIn("mv \"$TMP\" \"$TARGET\"", text)
        self.assertNotIn("sysupgrade", text)

    def test_v143_artifact_hash_reference(self):
        artifact = Path("/tmp/r76s-v143-rootfs.IoUGT2/usr/libexec/r76s/r76s-ota")
        if artifact.is_file():
            digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
            self.assertEqual(digest, "684e80f5ac274ef732d726eb19b3691bb6c83a645250febe4212c3d698943666")


if __name__ == "__main__":
    unittest.main()
