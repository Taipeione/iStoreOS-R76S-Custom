#!/usr/bin/env python3
"""Audit user TXT domain inputs and emit an additive PassWall rule manifest."""
from __future__ import annotations

import argparse
import json
import re
from collections import defaultdict
from pathlib import Path

APPS = (
    ("amazon-prime", "AmazonPrime", "Amazon Prime"),
    ("chatgpt", "ChatGPT", "ChatGPT"),
    ("disney", "Disney", "Disney"),
    ("emby", "Emby", "Emby"),
    ("hbo-max", "HBO Max", "HBO Max"),
    ("netflix", "Netflix", "Netflix"),
    ("nintendo", "Nintendo", "Nintendo"),
    ("telegram", "Telegram", "Telegram"),
    ("tiktok", "TikTok", "TikTok"),
    ("youtube-youtube-tv", "YouTubeYouTubeTV", "YouTube & YouTube TV"),
    ("apple", "AppleEcosystem", "Apple 生态"),
)
APP_COUNT = len(APPS)

# Accept the spellings used by PassWall/PassWall2 rule files, while retaining
# the exact source text in the output domain_list.
DOMAIN_RE = re.compile(
    r"^(?:(?:domain|full|keyword|regexp|geosite|ext):)?"
    r"(?:\*\.)?(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+"
    r"[A-Za-z]{2,63}\.?$"
)


def audit(input_dir: Path, output: Path, report: Path, allow_missing: bool) -> int:
    rows = []
    global_seen: dict[str, list[str]] = defaultdict(list)
    errors = 0
    missing = 0
    for slug, name, label in APPS:
        path = input_dir / f"{slug}.txt"
        source_lines = []
        blank_lines = 0
        comment_lines = 0
        format_errors = []
        duplicates = []
        if not path.is_file():
            missing += 1
            rows.append({"slug": slug, "name": name, "label": label,
                         "source_file": str(path), "present": False,
                         "domain_count": 0, "blank_lines": 0,
                         "comment_lines": 0, "duplicates": [],
                         "format_errors": [], "domains": []})
            continue
        for line_no, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            value = raw.strip()
            if not value:
                blank_lines += 1
                continue
            if value.startswith("#"):
                comment_lines += 1
                continue
            source_lines.append(value)
            key = value.lower()
            if not DOMAIN_RE.fullmatch(value):
                format_errors.append({"line": line_no, "value": value})
            if key in {x.lower() for x in source_lines[:-1]}:
                duplicates.append({"line": line_no, "value": value, "scope": "file"})
            global_seen[key].append(f"{name}:{line_no}")
        rows.append({"slug": slug, "name": name, "label": label,
                     "source_file": str(path), "present": True,
                     "domain_count": len(source_lines),
                     "blank_lines": blank_lines, "comment_lines": comment_lines,
                     "duplicates": duplicates, "format_errors": format_errors,
                     "domains": source_lines})
        errors += len(format_errors) + len(duplicates)

    cross_duplicates = {k: v for k, v in global_seen.items() if len(v) > 1}
    for row in rows:
        for domain in row["domains"]:
            if len(global_seen[domain.lower()]) > 1:
                row["duplicates"].append({"value": domain, "scope": "cross-file",
                                           "locations": global_seen[domain.lower()]})
    errors += sum(len(v) - 1 for v in cross_duplicates.values())
    if missing and not allow_missing:
        errors += missing

    rules = []
    for row in rows:
        if not row["present"]:
            continue
        rules.append({"name": row["name"], "options": {
            "remarks": f"{row['label']}（用户 TXT 增量规则）",
            "network": "tcp,udp",
            "domain_list": "\n".join(row["domains"]),
        }})
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({"schema_version": 1,
                                  "source": "project-rule-inputs",
                                  "rules": rules}, ensure_ascii=False, indent=2) + "\n",
                      encoding="utf-8")
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(render_report(input_dir, rows, missing, cross_duplicates,
                                    errors, allow_missing), encoding="utf-8")
    print(f"APP_RULE_INPUTS={len(rows)-missing}/{APP_COUNT}")
    print(f"APP_RULE_DOMAINS={sum(r['domain_count'] for r in rows)}")
    print(f"APP_RULE_MISSING={missing}")
    print(f"APP_RULE_ERRORS={errors}")
    return 0 if errors == 0 else 2


def render_report(input_dir, rows, missing, cross_duplicates, errors, allow_missing):
    lines = ["# R76S-V2.0.0 application domain rule audit", "",
             f"Input directory: `{input_dir}`", "",
             "The report preserves source lines in the generated manifest; it does not rewrite domains.", "",
             "AppleEcosystem is project-maintained from Apple’s official enterprise-network host list; it has no forced node and follows the system default outbound strategy.", "",
             "| Application | File | Present | Domains | Blank | Comments | Duplicate/format findings |", "|---|---|---:|---:|---:|---:|---:|"]
    for r in rows:
        findings = len(r["duplicates"]) + len(r["format_errors"])
        lines.append(f"| {r['label']} | `{Path(r['source_file']).name}` | {'yes' if r['present'] else 'no'} | {r['domain_count']} | {r['blank_lines']} | {r['comment_lines']} | {findings} |")
    lines += ["", "## Cross-file duplicates", ""]
    if cross_duplicates:
        for domain, locations in sorted(cross_duplicates.items()):
            lines.append(f"- `{domain}`: {', '.join(locations)}")
    else:
        lines.append("None.")
    lines += ["", "## Final write locations", "",
              "- Manifest: `config/rules/r76s-app-rules.json`",
              "- Firmware default: `/usr/share/r76s/r76s-app-rules.json`",
              "- PassWall and PassWall2 build defaults: their pinned `0_default_config` files, generated additively before `TencentMediaDirect`",
              "- Runtime migration: `/usr/libexec/r76s/r76s-rules-merge.lua`; existing user-named sections are preserved",
              "- Rule priority: baseline order is unchanged; additive application groups are inserted immediately before `TencentMediaDirect`; `WeChatDirect` remains first and explicit TCP/UDP direct",
              "",
              "## Gate", "", f"- Expected input files: {APP_COUNT}", f"- Missing files: {missing}", f"- Total errors: {errors}", f"- Allow missing: {allow_missing}"]
    if missing:
        result = "INCOMPLETE; user TXT inputs are required before release"
    elif errors:
        result = "FAIL; not release-ready"
    else:
        result = "PASS"
    lines.append("- Result: " + result)
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--input-dir", type=Path, default=Path("config/rules/apps"))
    p.add_argument("--output", type=Path, default=Path("config/rules/r76s-app-rules.json"))
    p.add_argument("--report", type=Path, default=Path("reports/R76S-V2.0.0-app-domain-audit.md"))
    p.add_argument("--allow-missing", action="store_true")
    args = p.parse_args()
    raise SystemExit(audit(args.input_dir, args.output, args.report, args.allow_missing))
