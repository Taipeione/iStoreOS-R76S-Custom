"""V1.4.6 plugin lifecycle and first-enable regression tests.

These tests use a temporary fake OpenWrt root. They never call a host init
script, UCI, procd, nftables, sysupgrade or a real router.
"""
from pathlib import Path
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
MANAGER = ROOT / "feeds/r76s-core/files/usr/libexec/r76s/r76s-service-manager"
REGISTRY = ROOT / "feeds/r76s-core/files/usr/share/r76s/plugin-registry"


class PluginLifecycleSources(unittest.TestCase):
    def test_registry_covers_preinstalled_service_families(self):
        registry = REGISTRY.read_text()
        for name in (
            "passwall|", "passwall2|", "smartdns|", "adguardhome|", "ddns|",
            "dockerd|", "ttyd|", "quickstart|", "istore|", "sysntpd|",
            "passwall_server|", "passwall2_server|", "wireguard|", "upnp|",
        ):
            self.assertIn(name, registry)
        config = (ROOT / "config/R76S.config").read_text()
        for package in ("luci-app-passwall", "luci-app-passwall2", "smartdns",
                        "adguardhome", "luci-app-ddns", "dockerd", "luci-app-dockerman",
                        "luci-app-ttyd", "quickstart", "wireguard-tools"):
            self.assertIn(f"CONFIG_PACKAGE_{package}=y", config)

    def test_config_change_trigger_does_not_require_autostart_link(self):
        for name in ("passwall", "passwall2", "smartdns", "ddns"):
            data = json.loads((ROOT / f"feeds/r76s-core/files/usr/share/ucitrack/r76s-{name}.json").read_text())
            self.assertEqual(data["config"], name)
            self.assertIn("r76s-config-event", data["exec"])
            self.assertNotIn("init", data)

    def test_preserve_and_health_are_registry_driven(self):
        preserve = (ROOT / "files/usr/libexec/r76s/r76s-ota-preserve-state").read_text()
        health = (ROOT / "feeds/r76s-core/files/usr/libexec/r76s/r76s-healthcheck").read_text()
        manager = MANAGER.read_text()
        self.assertIn("snapshot custom", preserve)
        self.assertIn("plugin_passwall_init", preserve)
        self.assertIn("records()", manager)
        self.assertIn("restore()", manager)
        self.assertIn("R76S_V146_PLUGIN_LIFECYCLE", health)
        self.assertNotIn("/etc/init.d/passwall enable", health)
        self.assertNotIn("/etc/init.d/passwall restart", health)

    def test_plugin_matrix_is_explicit_about_device_only_checks(self):
        matrix = ROOT / "scripts/r76s-plugin-matrix.py"
        result = subprocess.run(
            [sys.executable, str(matrix), "--repo", str(ROOT)],
            capture_output=True, text=True, check=True,
        )
        self.assertIn("NEEDS_DEVICE_TEST", result.stdout)
        self.assertIn("| upnp | miniupnpd | N/A |", result.stdout)
        self.assertIn("| passwall | passwall | PASS |", result.stdout)


class FakeOpenWrtApply(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "etc/init.d").mkdir(parents=True)
        (self.root / "etc/rc.d").mkdir()
        (self.root / "usr/share/r76s").mkdir(parents=True)
        (self.root / "bin").mkdir()
        (self.root / "usr/share/r76s/plugin-registry").write_text(
            "passwall|passwall|passwall.@global[0].enabled|uci|proxy\n"
            "passwall2|passwall2|passwall2.@global[0].enabled|uci|proxy\n"
            "smartdns|smartdns|smartdns.@smartdns[0].enabled|uci|dns\n"
        )
        self.state = self.root / "state.json"
        self.state.write_text(json.dumps({
            "passwall.@global[0].enabled": "0",
            "passwall2.@global[0].enabled": "0",
            "smartdns.@smartdns[0].enabled": "0",
        }))
        uci = self.root / "bin/uci"
        uci.write_text("#!" + sys.executable + "\n" + """
import json, os, sys
from pathlib import Path
p = Path(os.environ['STATE'])
s = json.loads(p.read_text())
a = [x for x in sys.argv[1:] if x != '-q']
if a[0] == 'get':
    if a[1] not in s: sys.exit(1)
    print(s[a[1]])
elif a[0] == 'set':
    k, v = a[1].split('=', 1); s[k] = v; p.write_text(json.dumps(s))
elif a[0] == 'commit':
    pass
""")
        uci.chmod(0o755)
        flock = self.root / "bin/flock"
        flock.write_text("#!/bin/sh\nexit 0\n")
        flock.chmod(0o755)
        for name in ("passwall", "passwall2", "smartdns"):
            init = self.root / "etc/init.d" / name
            init.write_text("""#!/bin/sh
root="$R76S_SERVICE_ROOT"
name="${0##*/}"
printf '%s\n' "$1" >> "$root/actions"
case "$1" in
  enable) ln -sf "../init.d/$name" "$root/etc/rc.d/S99$name" ;;
  disable) rm -f "$root/etc/rc.d/S99$name" ;;
  restart|stop) exit 0 ;;
esac
""")
            init.chmod(0o755)
        self.env = {
            **os.environ,
            "R76S_SERVICE_ROOT": str(self.root),
            "STATE": str(self.state),
            "PATH": str(self.root / "bin") + ":" + os.environ["PATH"],
        }

    def run_manager(self, *args):
        return subprocess.run(["sh", str(MANAGER), *args], env=self.env,
                              capture_output=True, text=True)

    def test_luci_apply_enabled_starts_without_preexisting_rc_link(self):
        state = json.loads(self.state.read_text())
        state["passwall.@global[0].enabled"] = "1"
        self.state.write_text(json.dumps(state))
        result = self.run_manager("apply", "passwall")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / "etc/rc.d/S99passwall").is_symlink())
        self.assertEqual((self.root / "actions").read_text().splitlines(), ["enable", "restart"])

    def test_luci_apply_disabled_stops_and_removes_link(self):
        (self.root / "etc/rc.d/S99passwall").symlink_to("../init.d/passwall")
        result = self.run_manager("apply", "passwall")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / "etc/rc.d/S99passwall").exists())
        self.assertEqual((self.root / "actions").read_text().splitlines(), ["disable", "stop", "disable"])


if __name__ == "__main__":
    unittest.main()
