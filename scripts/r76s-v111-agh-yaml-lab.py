#!/usr/bin/env python3
# R76S V111 AdGuard YAML atomic-switch laboratory.
# Mac offline test only. Never modifies router or source backups.

import hashlib
import importlib.util
import os
import sys
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parent
HELPER = BASE / "r76s-v111-agh-yaml-preview.py"

spec = importlib.util.spec_from_file_location("agh_preview", HELPER)
preview = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preview)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def atomic_write(path, data):
    fd, tmp = tempfile.mkstemp(
        prefix=".agh-stage-", dir=str(path.parent)
    )
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def guarded_switch(path, expected, replacement):
    if path.is_symlink() or not path.is_file():
        raise ValueError("Unsafe managed file")

    if path.read_bytes() != expected:
        raise ValueError("External modification detected")

    atomic_write(path, replacement)


def test(real_yaml, wan_file):
    source = Path(real_yaml)
    original = source.read_bytes()
    original_sha = sha(original)
    original_text = original.decode("utf-8")

    wan_ip = preview.wan_primary(
        Path(wan_file).read_text()
    )

    old, wan_text = preview.render_yaml(
        original_text, wan_ip
    )
    _, smartdns_text = preview.render_yaml(
        original_text, "127.0.0.1:6053"
    )

    if old != ["127.0.0.1:6053"]:
        raise ValueError(
            "Unexpected original upstream; migration blocked"
        )

    if smartdns_text != original_text:
        raise ValueError("Original YAML not reproducible")

    wan_bytes = wan_text.encode("utf-8")
    smartdns_bytes = smartdns_text.encode("utf-8")

    if wan_bytes == original:
        raise ValueError("WAN test did not change upstream")

    # Verify that only the selected YAML list changed.
    def outside_upstream(text):
        header, body = text.split(
            "  upstream_dns:\n", 1
        )
        _, remainder = body.split(
            "  upstream_dns_file:", 1
        )
        return header, remainder

    if outside_upstream(original_text) != \
            outside_upstream(wan_text):
        raise ValueError("Non-upstream YAML changed")

    print("REAL_YAML_UPSTREAM_ONLY=PASS")

    # All writes occur inside a private temporary directory.
    with tempfile.TemporaryDirectory(
        prefix="r76s-v111-agh-lab."
    ) as directory:

        lab = Path(directory)
        current = lab / "adguardhome.yaml"

        current.write_bytes(original)
        current.chmod(0o600)

        guarded_switch(
            current, original, wan_bytes
        )

        assert current.read_bytes() == wan_bytes
        print("ADGUARD_WAN_SWITCH=PASS")

        guarded_switch(
            current, wan_bytes, smartdns_bytes
        )

        assert current.read_bytes() == original
        print("ADGUARD_SMARTDNS_RESTORE=PASS")

        # Simulate an unfinished temporary file.
        orphan = lab / ".agh-stage-interrupted"
        orphan.write_text("interrupted")

        guarded_switch(
            current, original, wan_bytes
        )

        assert current.read_bytes() == wan_bytes
        print("INTERRUPTED_TEMP_RECOVERY=PASS")

        # Simulate a user's external modification.
        current.write_bytes(
            current.read_bytes() + b"\n# user edit\n"
        )

        edited = current.read_bytes()

        try:
            guarded_switch(
                current, wan_bytes, original
            )
        except ValueError:
            pass
        else:
            raise AssertionError(
                "External modification was overwritten"
            )

        assert current.read_bytes() == edited
        print("EXTERNAL_EDIT_PROTECTION=PASS")

        # A separate, unmodified managed copy can restore.
        clean = lab / "clean.yaml"
        clean.write_bytes(wan_bytes)
        clean.chmod(0o600)

        guarded_switch(
            clean, wan_bytes, original
        )

        assert clean.read_bytes() == original
        print("EXACT_ORIGINAL_RESTORE=PASS")

    if sha(source.read_bytes()) != original_sha:
        raise ValueError("Source backup changed")

    print("PRIVATE_BACKUP_UNCHANGED=PASS")
    print("ROUTER_CONFIG_CHANGES=NONE")
    print("AGH_YAML_ATOMIC_LAB_TESTS=PASS")


if __name__ == "__main__":
    try:
        if len(sys.argv) != 3:
            raise ValueError(
                "Usage: script REAL_YAML WAN_RESOLV_FILE"
            )
        test(sys.argv[1], sys.argv[2])
    except (ValueError, OSError, AssertionError) as error:
        print("FAILED:", error, file=sys.stderr)
        sys.exit(1)
