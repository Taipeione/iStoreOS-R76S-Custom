#!/bin/sh
# R76S V1.1.1 DNS Manager
# Phase 1: offline planning and failure-state decisions.
# No configuration writes or service restarts.

set -eu

BASE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
POLICY="$BASE_DIR/r76s-v111-dns-policy.sh"

[ -f "$POLICY" ] || {
    echo "ERROR: DNS policy missing" >&2
    exit 1
}

usage() {
    echo "Usage:"
    echo "  $0 plan PW SD AGH"
    echo "  $0 plan PW SD AGH PW_READY SD_READY AGH_READY"
    echo "  $0 upstream-plan STATE SD_READY WAN_RESOLV_FILE"
    exit 2
}

# R76S_V111_UPSTREAM_INTEGRATION
# Read-only AdGuard upstream planning.
if [ "${1:-}" = "upstream-plan" ]; then
    [ "$#" -eq 4 ] || usage

    AGH_HELPER="$BASE_DIR/r76s-v111-agh-upstream.sh"

    [ -f "$AGH_HELPER" ] || {
        echo "ERROR: AdGuard upstream helper missing" >&2
        exit 4
    }

    case "$2" in
        001|011|101|111) ;;
        *)
            echo "BLOCKED: AdGuard not active in requested state" >&2
            exit 4
            ;;
    esac

    if ! RESULT="$(sh "$AGH_HELPER" "$2" "$3" "$4")"; then
        echo "BLOCKED: Upstream planning failed" >&2
        exit 5
    fi

    SAFETY="$(printf '%s\n' "$RESULT" |
        sed -n 's/^SAFETY=//p')"

    PRIMARY="$(printf '%s\n' "$RESULT" |
        sed -n 's/^ADGUARD_PRIMARY_DNS=//p')"

    if [ "$SAFETY" != "UPSTREAM_PLAN_ONLY" ] ||
       [ -z "$PRIMARY" ]; then
        echo "BLOCKED: Upstream isolation not verified" >&2
        exit 5
    fi

    case "$2:$3" in
        011:1|111:1)
            [ "$PRIMARY" = "127.0.0.1:6053" ] || {
                echo "BLOCKED: Incorrect SmartDNS upstream" >&2
                exit 5
            }
            ;;
        001:*|011:0)
            [ "$PRIMARY" != "127.0.0.1:6053" ] || {
                echo "BLOCKED: Unexpected SmartDNS dependency" >&2
                exit 5
            }
            ;;
    esac

    printf '%s\n' "$RESULT"
    echo "UPSTREAM_INTEGRATION=PASS"
    echo "CONFIG_CHANGES=NONE"
    exit 0
fi

# R76S_V111_SAFE_RENDER
# Produce a candidate dnsmasq fragment on stdout.
# This mode never writes files, UCI or service state.
if [ "${1:-}" = "render" ]; then
    [ "$#" -eq 3 ] || usage

    STATE="$2"
    PROFILE="$3"

    case "$STATE" in
        000|001|010|011|100|101|110|111) ;;
        *)
            echo "ERROR: Invalid DNS state" >&2
            exit 2
            ;;
    esac

    # Never overwrite an unapproved preserved configuration.
    case "$PROFILE" in
        WAN_BASELINE) ;;
        LEGACY_3053)
            echo "BLOCKED: Legacy 3053 requires migration approval" >&2
            exit 4
            ;;
        *)
            echo "BLOCKED: Custom or unknown DNS configuration" >&2
            exit 4
            ;;
    esac

    # These combinations require additional upstream isolation.
    case "$STATE" in
        001)
            echo "BLOCKED: AdGuard standalone upstream unverified" >&2
            exit 5
            ;;
        101)
            echo "BLOCKED: Isolated PassWall proxy DNS required" >&2
            exit 5
            ;;
    esac

    printf '# R76S V111 managed DNS, state %s\n' "$STATE"

    case "$STATE" in
        000|100)
            # No override: retain WAN DNS configuration.
            printf '# WAN passthrough; no upstream override\n'
            ;;
        010|110)
            printf 'no-resolv\n'
            printf 'server=127.0.0.1#6053\n'
            ;;
        011|111)
            printf 'no-resolv\n'
            printf 'server=127.0.0.1#3053\n'
            ;;
    esac

    exit 0
fi

[ "$#" -eq 4 ] || [ "$#" -eq 7 ] || usage
[ "$1" = "plan" ] || usage

PW="$2"
SD="$3"
AGH="$4"

# If readiness is omitted, simulate healthy services.
PW_READY="${5:-1}"
SD_READY="${6:-1}"
AGH_READY="${7:-1}"

for VALUE in "$PW" "$SD" "$AGH" \
             "$PW_READY" "$SD_READY" "$AGH_READY"; do
    case "$VALUE" in
        0|1) ;;
        *)
            echo "ERROR: flags must be 0 or 1" >&2
            exit 2
            ;;
    esac
done

# Effective state = requested AND confirmed ready.
E_PW=$((PW * PW_READY))
E_SD=$((SD * SD_READY))
E_AGH=$((AGH * AGH_READY))

REQUESTED="${PW}${SD}${AGH}"
EFFECTIVE="${E_PW}${E_SD}${E_AGH}"

echo "REQUESTED_STATE=$REQUESTED"
echo "EFFECTIVE_STATE=$EFFECTIVE"

if [ "$REQUESTED" = "$EFFECTIVE" ]; then
    echo "DEGRADED=0"
else
    echo "DEGRADED=1"
fi

sh "$POLICY" "$E_PW" "$E_SD" "$E_AGH"

case "$EFFECTIVE" in
    101)
        echo "SAFETY=BLOCK_ISOLATED_PROXY_DNS_REQUIRED"
        echo "REASON=PassWall DNS must not loop through AdGuard"
        ;;
    *)
        echo "SAFETY=PLAN_ONLY"
        ;;
esac

if [ "$PW" = "1" ] && [ "$PW_READY" = "0" ]; then
    echo "WARNING=PROXY_UNAVAILABLE"
fi

if [ "$SD" = "1" ] && [ "$SD_READY" = "0" ]; then
    echo "WARNING=SMARTDNS_UNAVAILABLE"
fi

if [ "$AGH" = "1" ] && [ "$AGH_READY" = "0" ]; then
    echo "WARNING=ADGUARD_UNAVAILABLE"
fi

echo "CONFIG_CHANGES=NONE"
echo "SERVICE_RESTARTS=NONE"
