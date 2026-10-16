#!/usr/bin/env python3
"""Generate the R76S plugin lifecycle regression matrix.

This report deliberately separates source/config evidence from tests that need
an actual R76S.  It never reports a device-only check as PASS.
"""
from __future__ import annotations

import argparse
from pathlib import Path


TESTS = [f"TEST-{number:02d}" for number in range(1, 18)]

# Package selections are the authoritative clean-image inventory.  Internal
# R76S services are identified by their source files instead of pretending
# that they are external packages.
PACKAGE_CANDIDATES = {
    "passwall": ("luci-app-passwall",),
    "passwall2": ("luci-app-passwall2",),
    "smartdns": ("smartdns", "luci-app-smartdns"),
    "adguardhome": ("adguardhome",),
    "ddns": ("luci-app-ddns", "ddns-scripts"),
    "dockerd": ("dockerd", "luci-app-dockerman"),
    "ttyd": ("luci-app-ttyd",),
    "irqbalance": ("irqbalance",),
    "zram": ("zram-swap",),
    "quickstart": ("quickstart", "luci-app-quickstart"),
    "istore": ("luci-app-store",),
    "wireguard": ("wireguard-tools", "kmod-wireguard"),
    "upnp": ("miniupnpd", "luci-app-upnp"),
}

INTERNAL_SERVICES = {
    "passwall_server",
    "passwall2_server",
    "r76s-reconcile",
    "r76s-ota-restore",
    "r76s-ip6-guard",
    "r76s-v111-dns-manager",
}

DEVICE_TESTS = set(TESTS) - {"TEST-01", "TEST-02", "TEST-03", "TEST-16"}


def selected_packages(config: Path) -> set[str]:
    selected = set()
    for line in config.read_text(encoding="utf-8").splitlines():
        if line.startswith("CONFIG_PACKAGE_") and line.endswith("=y"):
            selected.add(line[len("CONFIG_PACKAGE_") : -2])
    return selected


def registry_entries(registry: Path) -> list[tuple[str, str, str, str, str]]:
    entries = []
    for line in registry.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        fields = line.split("|")
        if len(fields) != 5:
            raise ValueError(f"invalid registry record: {line}")
        entries.append(tuple(fields))
    return entries


def installed(name: str, selected: set[str], repo: Path) -> tuple[bool, str]:
    if name in INTERNAL_SERVICES:
        return True, "R76S source package"
    candidates = PACKAGE_CANDIDATES.get(name, ())
    present = [package for package in candidates if package in selected]
    if present:
        return True, "config: " + ", ".join(present)
    return False, "not selected in config/R76S.config"


def row_for(name: str, service: str, key: str, ownership: str, group: str,
            is_installed: bool, evidence: str, repo: Path) -> dict[str, str]:
    row = {"plugin": name, "service": service, "ownership": ownership,
           "group": group, "installed": "PASS" if is_installed else "N/A",
           "evidence": evidence}
    if not is_installed:
        row.update({test: "N/A" for test in TESTS})
        return row

    manager = repo / "feeds/r76s-core/files/usr/libexec/r76s/r76s-service-manager"
    trigger = repo / f"feeds/r76s-core/files/usr/share/ucitrack/r76s-{name}.json"
    has_lifecycle = manager.is_file() and "snapshot()" in manager.read_text(encoding="utf-8")
    has_config_trigger = trigger.is_file() and "r76s-config-event" in trigger.read_text(encoding="utf-8")
    row["TEST-01"] = "PASS"
    row["TEST-02"] = "PASS" if key != "-" or ownership == "init" else "NOT TESTED"
    row["TEST-03"] = "PASS" if ownership == "uci" and has_config_trigger else "N/A"
    row["TEST-16"] = "PASS" if has_lifecycle else "FAIL"
    for test in DEVICE_TESTS:
        if test in {"TEST-05", "TEST-15"} and group not in {"proxy", "dns", "network"}:
            row[test] = "N/A"
        elif test == "TEST-17" and group not in {"proxy", "dns", "network", "container"}:
            row[test] = "N/A"
        else:
            row[test] = "NEEDS_DEVICE_TEST"
    return row


def generate(repo: Path) -> str:
    selected = selected_packages(repo / "config/R76S.config")
    entries = registry_entries(repo / "feeds/r76s-core/files/usr/share/r76s/plugin-registry")
    rows = [row_for(*entry, *installed(entry[0], selected, repo), repo) for entry in entries]
    lines = [
        "# R76S-V1.4.6 Plugin Lifecycle Regression Matrix",
        "",
        "This is a source/configuration audit. `NEEDS_DEVICE_TEST` is not a PASS and must be replaced only by evidence from a real NanoPi R76S.",
        "",
        "| Plugin | Service | Installed | Ownership | Group | Evidence | " + " | ".join(TESTS) + " |",
        "|---|---|---:|---|---|---|" + "---:|" * len(TESTS),
    ]
    for row in rows:
        values = [row["plugin"], row["service"], row["installed"], row["ownership"], row["group"], row["evidence"]]
        values.extend(row[test] for test in TESTS)
        lines.append("| " + " | ".join(values) + " |")
    lines.extend([
        "",
        "## Interpretation",
        "",
        "- `PASS`: verified from source/configuration or deterministic local simulation.",
        "- `N/A`: the package is not selected or the test does not apply to that component.",
        "- `NEEDS_DEVICE_TEST`: requires clean-flash, reboot, network, firewall, OTA, or functional testing on a real R76S.",
        "- `NOT TESTED`/`FAIL`: a release blocker until resolved or explicitly accepted with a documented reason.",
        "",
    ])
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    report = generate(args.repo.resolve())
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(report, encoding="utf-8")
    else:
        print(report, end="")


if __name__ == "__main__":
    main()
