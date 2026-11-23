#!/usr/bin/env python3
"""Static safety gate for the R76S TF-boot-test artifact.

This script only reads the input firmware and writes ordinary files under the
requested output directory. It never opens a block device and never invokes
sysupgrade, RKDevTool, upgrade_tool, MASKROM, EraseAll, or any eMMC/SPI write.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import struct
import subprocess
import tempfile
import zlib
from pathlib import Path


EXPECTED_DEVICE = "friendlyarm,nanopi-r76s"
EXPECTED_BOARD = "friendlyarm_nanopi-r76s"
EXPECTED_TARGET = "rockchip/armv8"
EXPECTED_VERSION = "25.12.6"
EXPECTED_KERNEL = "6.12.112"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def copy_range(source: Path, target: Path, offset: int, length: int) -> None:
    with source.open("rb") as src, target.open("wb") as dst:
        src.seek(offset)
        remaining = length
        while remaining:
            block = src.read(min(1024 * 1024, remaining))
            if not block:
                raise RuntimeError("unexpected EOF while extracting image partition")
            dst.write(block)
            remaining -= len(block)


def decode_image(path: Path) -> tuple[bytes, dict, bytes]:
    decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
    with path.open("rb") as source:
        compressed = source.read()
    raw = decoder.decompress(compressed) + decoder.flush()
    if not decoder.eof:
        raise RuntimeError("gzip stream is truncated")
    trailer = decoder.unused_data
    start = trailer.find(b"{")
    end = trailer.rfind(b"}")
    if start < 0 or end < start:
        raise RuntimeError("OpenWrt metadata JSON trailer is missing")
    metadata = json.loads(trailer[start : end + 1].decode())
    return raw, metadata, trailer[end + 1 :]


def partition(raw: bytes, index: int) -> tuple[int, int, int]:
    entry = raw[446 + (index - 1) * 16 : 462 + (index - 1) * 16]
    if len(entry) != 16:
        raise RuntimeError("short MBR partition entry")
    part_type = entry[4]
    start_lba, sectors = struct.unpack_from("<II", entry, 8)
    return part_type, start_lba * 512, sectors * 512


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()

    image = args.image.resolve()
    source_root = args.source_root.resolve()
    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    raw, metadata, trailer = decode_image(image)
    require(metadata.get("supported_devices") == [EXPECTED_DEVICE], "metadata device mismatch")
    version = metadata.get("version", {})
    require(version.get("version") == EXPECTED_VERSION, "metadata OpenWrt version mismatch")
    require(version.get("target") == EXPECTED_TARGET, "metadata target mismatch")
    require(version.get("board") == EXPECTED_BOARD, "metadata board mismatch")
    require(raw[510:512] == b"\x55\xaa", "MBR signature is missing")
    require(raw[440:444] == b"OWRT", "OpenWrt MBR disk signature is missing")

    kernel_type, kernel_offset, kernel_size = partition(raw, 1)
    root_type, root_offset, root_size = partition(raw, 2)
    require(kernel_type == 0x83 and root_type == 0x83, "unexpected partition type")
    require(kernel_offset + kernel_size <= len(raw), "kernel partition exceeds image")
    require(root_offset + root_size <= len(raw), "rootfs partition exceeds image")
    require(raw[root_offset : root_offset + 4] == b"hsqs", "rootfs is not SquashFS")

    raw_text = raw.decode("latin1", errors="ignore")
    required_markers = {
        "U-Boot SPL": "SPL/U-Boot marker",
        "ARM64 OpenWrt FIT": "FIT marker",
        "ARM64 OpenWrt Linux-" + EXPECTED_KERNEL: "kernel release",
        "friendlyarm,nanopi-r76s": "R76S DT compatible",
        "rockchip,rk3576": "RK3576 DT compatible",
        "kernel.img": "kernel filename",
        "root=PARTUUID": "PARTUUID root argument",
        "boot_targets=mmc1 mmc0": "TF-first default U-Boot boot order",
        "bootcmd=bootflow scan -lb": "U-Boot bootflow command",
    }
    for marker, description in required_markers.items():
        require(marker in raw_text, f"missing {description}: {marker}")

    boot_makefile = source_root / "target/linux/rockchip/image/Makefile"
    bootscript = source_root / "target/linux/rockchip/image/default.bootscript"
    device_recipe = source_root / "target/linux/rockchip/image/armv8.mk"
    dts_patch = source_root / "target/linux/rockchip/patches-6.12/052-v6.19-arm64-dts-rockchip-Add-devicetree-for-the-FriendlyElec-Na.patch"
    for path in (boot_makefile, bootscript, device_recipe, dts_patch):
        require(path.is_file(), f"missing source evidence: {path}")
    makefile_text = boot_makefile.read_text(errors="replace")
    bootscript_text = bootscript.read_text(errors="replace")
    recipe_text = device_recipe.read_text(errors="replace")
    dts_text = dts_patch.read_text(errors="replace")
    require("Creates the final SD/eMMC images" in makefile_text, "image recipe is not the SD/eMMC image builder")
    require("IMAGES := sysupgrade.img.gz" in makefile_text, "target image output is not locked")
    require("pine64-img | gzip | append-metadata" in makefile_text, "full disk image pipeline is missing")
    require("load ${devtype} ${devnum}:1" in bootscript_text, "boot script does not load kernel from selected boot media")
    require("root=PARTUUID=${uuid}" in bootscript_text, "boot script does not select rootfs by selected-media PARTUUID")
    require("part uuid ${devtype} ${devnum}:2 uuid" in bootscript_text, "boot script does not derive rootfs PARTUUID from selected media")
    require("define Device/friendlyarm_nanopi-r76s" in recipe_text, "R76S image recipe is missing")
    require("UBOOT_DEVICE_NAME := generic-rk3576" in recipe_text, "RK3576 U-Boot profile is missing")
    require('compatible = "friendlyarm,nanopi-r76s", "rockchip,rk3576"' in dts_text, "R76S DTS compatible is missing")

    with tempfile.TemporaryDirectory(prefix="r76s-tf-audit-") as temp_name:
        temp = Path(temp_name)
        kernel = temp / "kernel-partition.bin"
        rootfs = temp / "rootfs.squashfs"
        # Extract partitions from the decompressed disk image, never from the
        # gzip container or its metadata trailer.
        raw_image = temp / "image.raw"
        raw_image.write_bytes(raw)
        copy_range(raw_image, kernel, kernel_offset, kernel_size)
        copy_range(raw_image, rootfs, root_offset, root_size)
        squashfs = subprocess.run(
            ["unsquashfs", "-s", str(rootfs)], capture_output=True, text=True, check=True
        ).stdout
        listing = subprocess.run(
            ["unsquashfs", "-ll", str(rootfs)], capture_output=True, text=True, check=True
        ).stdout.lower()
        forbidden = (
            "eflasher",
            "eflasher.conf",
            "rkdevtool",
            "upgrade_tool",
            "eraseall",
            "maskrom",
        )
        for token in forbidden:
            require(token not in listing, f"automatic eMMC/USB installer marker found in rootfs: {token}")

    tf_image = output_dir / "openwrt-rockchip-armv8-friendlyarm_nanopi-r76s-squashfs-tf-boot-test.img.gz"
    shutil.copy2(image, tf_image)
    require(sha256(image) == sha256(tf_image), "TF artifact is not byte-identical to audited source image")

    audit = output_dir / "TF-BOOT-AUDIT.md"
    audit.write_text(
        "\n".join(
            [
                "# R76S-V2.0.0 TF Boot Test Audit",
                "",
                "- Artifact type: raw OpenWrt RK3576 full-disk image for isolated TF boot testing",
                "- Source image: byte-identical copy of the cloud-built R76S sysupgrade disk image",
                f"- Source SHA256: `{sha256(image)}`",
                f"- TF artifact SHA256: `{sha256(tf_image)}`",
                f"- Raw image bytes: {len(raw)}",
                f"- Kernel partition: offset={kernel_offset}, bytes={kernel_size}",
                f"- Rootfs partition: offset={root_offset}, bytes={root_size}",
                f"- Metadata device: `{EXPECTED_DEVICE}`",
                f"- Metadata target: `{EXPECTED_TARGET}`",
                f"- Metadata version: OpenWrt `{EXPECTED_VERSION}`",
                f"- Rootfs inspection: PASS ({squashfs.splitlines()[0] if squashfs else 'SquashFS'})",
                "- SPL/U-Boot/FIT/DTS/kernel markers: PASS",
                "- Default U-Boot boot order: `mmc1 mmc0`; R76S DTS aliases `mmc1=sdmmc` (TF), `mmc0=sdhci` (eMMC)",
                "- Rootfs selection: PASS statically; U-Boot derives PARTUUID from the selected `${devtype} ${devnum}`",
                "- Automatic EFlasher/eMMC installer markers in rootfs: ABSENT",
                "- SPI/eMMC writes in this CI packaging step: NONE",
                "- Runtime TF boot and current U-Boot persistent environment: NOT TESTED",
                "- HARDWARE BOOT TESTED: NOT TESTED",
                "",
                "This artifact must only be used on a disposable TF card. Do not use eFlasher, USB upgrade, MASKROM, EraseAll, RKDevTool, or sysupgrade as part of this test.",
                "",
            ]
        )
    )
    print(f"TF_BOOT_AUDIT=PASS image={tf_image} sha256={sha256(tf_image)}")
    print("HARDWARE_BOOT_TESTED=NOT_TESTED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
