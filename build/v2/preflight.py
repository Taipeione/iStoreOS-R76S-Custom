#!/usr/bin/env python3
"""Read-only gates for the R76S V2 source tree."""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
from pathlib import Path


def need(path: Path, failures: list[str]) -> None:
    if not path.is_file():
        failures.append(f"missing file: {path}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    ap.add_argument("--openwrt", type=Path)
    args = ap.parse_args()
    repo = args.repo.resolve()
    failures: list[str] = []
    cfg = repo / "config/R76S-V2.config"
    lock = repo / "config/r76s-v2-sources.lock.json"
    need(cfg, failures)
    need(lock, failures)
    for path in (
        repo / "scripts/r76s-import-app-rules.py",
        repo / "scripts/r76s-generate-rules.py",
        repo / "feeds/r76s-core/files/usr/libexec/r76s/r76s-rules-merge.lua",
        repo / "feeds/r76s-core/files/usr/share/r76s/r76s-app-rules.json",
    ):
        need(path, failures)

    if cfg.is_file():
        text = cfg.read_text()
        required = (
            "CONFIG_TARGET_rockchip=y",
            "CONFIG_TARGET_rockchip_armv8=y",
            "CONFIG_TARGET_rockchip_armv8_DEVICE_friendlyarm_nanopi-r76s=y",
            "CONFIG_USE_APK=y",
            "CONFIG_PACKAGE_apk-mbedtls=y",
            'CONFIG_VERSION_NUMBER="25.12.6"',
            'CONFIG_VERSION_CODE="R76S-V2.0.0"',
        )
        for item in required:
            if item not in text:
                failures.append(f"config missing: {item}")
        if "CONFIG_PACKAGE_opkg=y" in text:
            failures.append("legacy opkg is enabled")

    if lock.is_file():
        data = json.loads(lock.read_text())
        if data.get("openwrt", {}).get("commit") != "64900e756efa667774214f9c6b17c113222e01f7":
            failures.append("OpenWrt lock is not v25.12.6 commit 64900e7...")
        if data.get("openwrt", {}).get("device") != "friendlyarm_nanopi-r76s":
            failures.append("locked device is not friendlyarm_nanopi-r76s")

    rules = repo / "config/rules/r76s-rules.json"
    if rules.is_file():
        names = [x["name"] for x in json.loads(rules.read_text())["rules"]]
        if len(names) != 43 or len(set(names)) != 43:
            failures.append(f"baseline rule count/uniqueness is not 43: {len(names)}")
        if names[:1] != ["WeChatDirect"] or names[-1:] != ["TencentMediaDirect"]:
            failures.append("baseline rule boundary changed")
    else:
        failures.append("baseline rules manifest missing")

    wechat = repo / "config/rules/wechat-direct.txt"
    if wechat.is_file() and re.search(r"(?:^|\n)(?:domain|full):qq\.com(?:\n|$)", wechat.read_text(), re.I):
        failures.append("forbidden broad qq.com rule found in WeChat input")

    updater = repo / "feeds/luci-app-r76s-updater/files/root/usr/libexec/r76s/r76s-component-updater"
    if updater.is_file() and re.search(r"\bopkg\b", updater.read_text(), re.I):
        failures.append("component updater still references opkg")

    for path in sorted((repo / "feeds").rglob("*.sh")) + sorted((repo / "files").rglob("*.sh")) + sorted((repo / "build/v2").glob("*.sh")):
        interpreter = "bash" if path.read_text(errors="replace").startswith("#!" ) and "bash" in path.read_text(errors="replace").splitlines()[0] else "sh"
        result = subprocess.run([interpreter, "-n", str(path)], capture_output=True, text=True)
        if result.returncode:
            failures.append(f"shell syntax: {path}: {result.stderr.strip()}")
    lua = shutil.which("lua")
    luac = shutil.which("luac")
    if luac or lua:
        for path in sorted((repo / "feeds").rglob("*.lua")):
            if luac:
                command = [luac, "-p", str(path)]
            else:
                # Lua 5.1 has no `lua -p`; loadfile performs syntax-only
                # parsing without executing the module body.
                command = [lua, "-e", "assert(loadfile(arg[1]))", str(path)]
            result = subprocess.run(command, capture_output=True, text=True)
            if result.returncode:
                failures.append(f"Lua syntax: {path}: {result.stderr.strip()}")

    if args.openwrt:
        result = subprocess.run(["git", "-C", str(args.openwrt), "rev-parse", "HEAD"], capture_output=True, text=True)
        if result.returncode or result.stdout.strip() != "64900e756efa667774214f9c6b17c113222e01f7":
            failures.append("OpenWrt source checkout is not the locked v25.12.6 commit")

    if failures:
        print("PREFLIGHT=FAIL")
        print("\n".join(f"- {x}" for x in failures))
        return 2
    print("PREFLIGHT=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
