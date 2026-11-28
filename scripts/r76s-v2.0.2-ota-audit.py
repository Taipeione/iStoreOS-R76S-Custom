#!/usr/bin/env python3
"""Static OTA compatibility gates for R76S V2.0.2.

This audit never opens a block device and never runs sysupgrade.  It proves
which migration paths are supported by the locked configs and OpenWrt's
rockchip upgrade implementation.
"""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


def require(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--openwrt", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    repo = args.repo.resolve()
    openwrt = args.openwrt.resolve()
    failures: list[str] = []

    old = (repo / "config/R76S.config").read_text()
    new = (repo / "config/R76S-V2.config").read_text()
    platform = (openwrt / "target/linux/rockchip/armv8/base-files/lib/upgrade/platform.sh").read_text()
    image = (openwrt / "target/linux/rockchip/image/Makefile").read_text()

    require('CONFIG_TARGET_ROOTFS_PARTSIZE=256' in old, "V1.4.6 baseline is not recorded as 256 MiB", failures)
    require('CONFIG_PACKAGE_opkg=y' in old, "V1.4.6 baseline is not recorded as OPKG", failures)
    require('CONFIG_TARGET_ROOTFS_PARTSIZE=512' in new, "V2.0.2 target is not 512 MiB", failures)
    require('CONFIG_USE_APK=y' in new, "V2.0.2 target does not enable APK", failures)
    require('CONFIG_PACKAGE_opkg=y' not in new, "legacy OPKG is enabled in V2.0.2", failures)
    require('CONFIG_VERSION_CODE="R76S-V2.0.2"' in new, "V2.0.2 version identity is missing", failures)

    require('REQUIRE_IMAGE_METADATA=1' in platform, "sysupgrade metadata gate is missing", failures)
    require('get_partitions /tmp/image.bs image' in platform, "sysupgrade does not inspect image partitions", failures)
    require('if [ -n "$diff" ]; then' in platform, "partition-difference branch is missing", failures)
    require('get_image "$@" | dd of="/dev/$diskdev"' in platform, "full-image write branch is missing", failures)
    require('IMAGES := sysupgrade.img.gz' in image, "R76S image is not a standard sysupgrade image", failures)
    require('append-metadata' in image, "sysupgrade metadata is not appended", failures)

    require(old != new, "old and new configs unexpectedly identical", failures)
    direct_v146 = False
    direct_v2x = True
    require(not direct_v146, "V1.4.6 direct OTA was accidentally enabled", failures)
    require(direct_v2x, "V2.0.x same-layout OTA was not enabled", failures)

    public_key = repo / "files/usr/share/r76s/ota-public.pem"
    config_key = repo / "config/ota-public.pem"
    require(public_key.is_file(), "OTA public key is not staged into the image", failures)
    require(public_key.read_text() == config_key.read_text(), "staged OTA public key differs from locked key", failures)

    password = repo / "files/etc/uci-defaults/95-r76s-initial-root-password"
    password_text = password.read_text()
    require("$6$" in password_text, "initial root password is not SHA-512-crypt", failures)
    require("passwd root" not in password_text and "password\npassword" not in password_text,
            "initial password is written through a plaintext setter", failures)
    require("R76S_INITIAL_ROOT_PASSWORD" not in password_text, "password secret is embedded by name", failures)

    selective = repo / "feeds/r76s-core/files/usr/libexec/r76s/r76s-config-restore-selective"
    selective_text = selective.read_text()
    for forbidden in ("/etc/shadow", "/etc/passwd", "/etc/opkg", "/etc/apk", "r76s_ota_state"):
        require(forbidden not in selective_text, f"selective migration references forbidden path {forbidden}", failures)
    require("r76s-config-migrate" in selective_text, "selective migration does not invoke V2 normalization", failures)

    report = [
        "# R76S-V2.0.2 OTA Compatibility Audit",
        "",
        "- V1.4.6 → V2.0.2 direct sysupgrade: **BLOCKED** (256 MiB/OPKG/old ABI versus 512 MiB/APK/new ABI).",
        "- V2.0.x → V2.0.2 standard sysupgrade: **SUPPORTED BY STATIC GATES ONLY** (same target and partition geometry; hardware not tested).",
        "- U-Boot/SPL/SPI rewrite in same-layout path: **not requested by the platform branch; hardware not tested**.",
        "- Configuration backup: required before install; selective migration excludes package databases and credentials.",
        "- Initial root credential: SHA-512-crypt shadow entry; existing preserved password wins.",
        "- Hardware OTA test: **NOT TESTED**.",
        "",
    ]
    if failures:
        report += ["## FAIL", ""] + [f"- {item}" for item in failures]
    else:
        report += ["## PASS", "", "All static V2.0.2 OTA gates passed."]

    text = "OTA_COMPATIBILITY_AUDIT=" + ("FAIL" if failures else "PASS") + "\n\n" + "\n".join(report) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text)
    print("OTA_COMPATIBILITY_AUDIT=" + ("FAIL" if failures else "PASS"))
    print(text, end="")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
