#!/usr/bin/env python3
"""Verify generated PassWall/PassWall2 rule order and safety invariants."""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


def shunts(path: Path):
    text = path.read_text()
    matches = list(re.finditer(r"(?m)^config shunt_rules '([^']+)'\s*$", text))
    blocks = {}
    for i, match in enumerate(matches):
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        blocks[match.group(1)] = text[match.start():end]
    return [m.group(1) for m in matches], blocks


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("baseline", type=Path)
    ap.add_argument("app_manifest", type=Path)
    ap.add_argument("passwall", type=Path)
    ap.add_argument("passwall2", type=Path)
    args = ap.parse_args()
    errors = []
    base = json.loads(args.baseline.read_text())["rules"]
    apps = json.loads(args.app_manifest.read_text())["rules"]
    expected = [x["name"] for x in base[:-1]] + [x["name"] for x in apps] + [base[-1]["name"]]
    for path in (args.passwall, args.passwall2):
        actual, blocks = shunts(path)
        if actual != expected:
            errors.append(f"{path}: order/count mismatch ({len(actual)} != {len(expected)})")
        block = blocks.get("WeChatDirect", "")
        if "option network 'tcp,udp'" not in block:
            errors.append(f"{path}: WeChatDirect is not explicit TCP/UDP direct")
        if "option WeChatDirect '_direct'" not in path.read_text():
            errors.append(f"{path}: WeChatDirect is not mapped to _direct in the shunt node")
        if re.search(r"(?:domain|full):qq\.com", block, re.I):
            errors.append(f"{path}: broad qq.com rule found in WeChatDirect")
        for rule in apps:
            name = rule["name"]
            app_block = blocks.get(name, "")
            if "option network 'tcp,udp'" not in app_block:
                errors.append(f"{path}: {name} is not TCP/UDP")
            for domain in rule["options"]["domain_list"].splitlines():
                if domain and domain not in app_block:
                    errors.append(f"{path}: {name} lost source domain {domain!r}")
            if name == "AppleEcosystem":
                if any(key in rule["options"] for key in ("node", "outbound", "strategy")):
                    errors.append(f"{path}: AppleEcosystem has a forced outbound option in the manifest")
                if re.search(r"(?m)^\s*option\s+(?:node|outbound|strategy)\s+", app_block):
                    errors.append(f"{path}: AppleEcosystem has a forced outbound option in the generated rule")
    if errors:
        print("RULE_AUDIT=FAIL")
        print("\n".join(f"- {x}" for x in errors))
        return 2
    print(f"RULE_AUDIT=PASS rules={len(expected)} apps={len(apps)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
