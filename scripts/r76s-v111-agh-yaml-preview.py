#!/usr/bin/env python3
# R76S V111 AdGuard YAML upstream preview.
# Offline-only. Never modifies the input YAML.

import ipaddress
import os
import re
import sys
from pathlib import Path


def wan_primary(text):
    for line in text.splitlines():
        parts = line.split()
        if len(parts) != 2 or parts[0] != "nameserver":
            continue

        try:
            ip = ipaddress.ip_address(parts[1])
        except ValueError:
            continue

        # Current BusyBox renderer supports IPv4 endpoints only.
        if ip.version != 4 or ip.is_loopback or ip.is_unspecified or \
                ip.is_multicast or ip.is_link_local or ip.is_reserved:
            continue
        if str(ip) == os.environ.get("R76S_LOCAL_DNS_IPV4", "192.168.50.1"):
            continue

        return str(ip)

    raise ValueError("No eligible WAN DNS server")


def render_yaml(text, target):
    if not text.endswith("\n") or "\r" in text:
        raise ValueError("Unsupported YAML line endings")

    lines = text.splitlines(keepends=True)

    roots = [
        i for i, line in enumerate(lines)
        if line == "dns:\n"
    ]

    if len(roots) != 1:
        raise ValueError("Expected exactly one root dns section")

    root = roots[0]
    end = len(lines)

    for i in range(root + 1, len(lines)):
        if lines[i].strip() and not lines[i][0].isspace() \
                and not lines[i].startswith("#"):
            end = i
            break

    upstream = [
        i for i in range(root + 1, end)
        if lines[i] == "  upstream_dns:\n"
    ]

    if len(upstream) != 1:
        raise ValueError("Unsupported upstream_dns layout")

    start = upstream[0]

    file_fields = [
        lines[i].strip()
        for i in range(root + 1, end)
        if lines[i].startswith("  upstream_dns_file:")
    ]

    if len(file_fields) != 1 or file_fields[0] not in (
        'upstream_dns_file: ""',
        "upstream_dns_file: ''",
    ):
        raise ValueError("External upstream file or unknown layout")

    stop = end

    for i in range(start + 1, end):
        if re.match(r"^  [A-Za-z_][A-Za-z_0-9-]*:", lines[i]):
            stop = i
            break

    old = []

    for line in lines[start + 1:stop]:
        match = re.fullmatch(r"    - (.+)\n", line)
        if not match:
            raise ValueError("Complex upstream YAML requires manual review")
        old.append(match.group(1))

    if not old:
        raise ValueError("Empty upstream DNS list")

    replacement = ["    - " + target + "\n"]
    result = "".join(
        lines[:start + 1] +
        replacement +
        lines[stop:]
    )

    if result[:len("".join(lines[:start + 1]))] != \
            "".join(lines[:start + 1]):
        raise ValueError("Unexpected prefix change")

    if not result.endswith("".join(lines[stop:])):
        raise ValueError("Unexpected non-DNS change")

    return old, result


def selftest():
    sample = (
        'http:\n'
        '  address: 192.168.50.1:3000\n'
        'users:\n'
        '  - name: example\n'
        '    password: test-placeholder\n'
        'dns:\n'
        '  bind_hosts:\n'
        '    - 127.0.0.1\n'
        '  port: 3053\n'
        '  upstream_dns:\n'
        '    - 127.0.0.1:6053\n'
        '  upstream_dns_file: ""\n'
        '  fallback_dns:\n'
        '    - 223.5.5.5\n'
        '    - 119.29.29.29\n'
        'filters:\n'
        '  - enabled: true\n'
        '    url: https://example.invalid/filter.txt\n'
    )

    old, result = render_yaml(sample, "61.134.1.5")

    assert old == ["127.0.0.1:6053"]
    assert "    - 61.134.1.5\n" in result
    assert "    - 127.0.0.1:6053\n" not in result
    assert result.count("password: test-placeholder") == 1
    assert "    - 119.29.29.29\n" in result
    assert "filters:\n" in result
    assert result.count("url: https://example.invalid/filter.txt") == 1

    _, restored = render_yaml(result, "127.0.0.1:6053")
    assert restored == sample

    assert wan_primary(
        "nameserver 127.0.0.1\n"
        "nameserver 61.134.1.5\n"
    ) == "61.134.1.5"

    for invalid in (
        sample.replace("  upstream_dns:\n", "  upstream_dns: []\n"),
        sample.replace('upstream_dns_file: ""',
                       'upstream_dns_file: "/tmp/custom"'),
    ):
        try:
            render_yaml(invalid, "61.134.1.5")
        except ValueError:
            pass
        else:
            raise AssertionError("Unsafe YAML accepted")

    print("YAML_STRUCTURE_GUARD=PASS")
    print("YAML_OTHER_SETTINGS_PRESERVED=PASS")
    print("YAML_UPSTREAM_RESTORE=PASS")
    print("YAML_UNSUPPORTED_LAYOUT_BLOCKED=PASS")
    print("AGH_YAML_OFFLINE_TESTS=PASS")


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "selftest":
        selftest()
        return

    if len(sys.argv) != 6 or sys.argv[1] != "preview":
        raise ValueError(
            "Usage: preview wan|smartdns SD_READY YAML_FILE WAN_FILE"
        )

    _, _, mode, ready, yaml_file, wan_file = sys.argv

    if ready not in ("0", "1"):
        raise ValueError("Invalid SmartDNS readiness")

    if mode == "smartdns":
        if ready != "1":
            raise ValueError("SmartDNS is not ready")
        target = "127.0.0.1:6053"
    elif mode == "wan":
        target = wan_primary(Path(wan_file).read_text())
    else:
        raise ValueError("Invalid upstream mode")

    old, candidate = render_yaml(
        Path(yaml_file).read_text(), target
    )

    print("CURRENT_UPSTREAM=" + ",".join(old))
    print("PROPOSED_UPSTREAM=" + target)
    print("OTHER_YAML_FIELDS=UNCHANGED")
    print("PREVIEW_ONLY=YES")
    print("YAML_WRITE=NONE")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as error:
        print("BLOCKED: " + str(error), file=sys.stderr)
        sys.exit(4)
