#!/bin/sh
# R76S V111 AdGuard YAML renderer.
# Reads YAML and writes a candidate to stdout ONLY.
# Never modifies the source file or service.

set -eu

[ "$#" -eq 2 ] || exit 2

INPUT="$1"
TARGET="$2"

[ -s "$INPUT" ] && [ -f "$INPUT" ] || exit 4

# R76S_V111_STRICT_DNS_TARGET
# Only an explicitly approved SmartDNS endpoint or a valid IPv4.
validate_ipv4() {
    printf '%s\n' "$1" | awk -F. '
        NF != 4 { exit 1 }
        {
            for (i = 1; i <= 4; i++) {
                if ($i !~ /^[0-9]+$/ ||
                    length($i) > 3 ||
                    (length($i) > 1 && substr($i, 1, 1) == "0") ||
                    ($i + 0) > 255)
                    exit 1
            }

            if (($1 + 0) == 0 ||
                ($1 + 0) == 127 ||
                ($1 + 0) >= 224 ||
                (($1 + 0) == 169 && ($2 + 0) == 254))
                exit 1
        }
    '
}

case "$TARGET" in
    127.0.0.1:6053)
        ;;
    *)
        if ! validate_ipv4 "$TARGET" ||
           [ "$TARGET" = "${R76S_LOCAL_DNS_IPV4:-192.168.50.1}" ]; then
            echo "BLOCKED: Invalid, local-loop, or unsupported DNS target" >&2
            exit 4
        fi
        ;;
esac

awk -v target="$TARGET" '
{
    lines[NR] = $0
    if (index($0, "\r")) bad = 1
}
END {
    dns_count = 0
    upstream_count = 0
    external_count = 0
    in_dns = 0
    start = 0
    finish = 0
    items = 0

    for (i = 1; i <= NR; i++) {
        v = lines[i]

        if (v == "dns:") {
            dns_count++
            in_dns = 1
            continue
        }

        if (in_dns && v ~ /^[^[:space:]#]/)
            in_dns = 0

        if (!in_dns)
            continue

        if (v == "  upstream_dns:") {
            upstream_count++
            start = i
        }

        if (v ~ /^  upstream_dns_file:/) {
            external_count++

            if (v != "  upstream_dns_file: \"\"" &&
                v != "  upstream_dns_file: \047\047")
                bad = 1
        }
    }

    if (dns_count != 1 ||
        upstream_count != 1 ||
        external_count != 1 ||
        bad) {
        exit 4
    }

    for (i = start + 1; i <= NR; i++) {
        v = lines[i]

        if (v ~ /^  [[:alpha:]_][[:alnum:]_-]*:/) {
            finish = i
            break
        }

        if (v ~ /^    - [^[:space:]].*$/) {
            items++
            continue
        }

        bad = 1
        break
    }

    if (finish == 0 || items == 0 || bad)
        exit 4

    for (i = 1; i <= NR; i++) {
        print lines[i]

        if (i == start) {
            print "    - " target
            i = finish - 1
        }
    }
}
' "$INPUT"
