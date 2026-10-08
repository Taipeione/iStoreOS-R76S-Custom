#!/bin/sh
# R76S V111 AdGuard upstream planner.
# Read-only: never writes YAML, UCI or service state.

set -eu

[ "$#" -eq 3 ] || {
    echo "Usage: $0 STATE SMARTDNS_READY WAN_RESOLV_FILE" >&2
    exit 2
}

STATE="$1"
SD_READY="$2"
WAN_FILE="$3"

case "$STATE" in
    000|010|100|110)
        echo "ADGUARD_UPSTREAM=OFF"
        echo "CONFIG_CHANGES=NONE"
        exit 0
        ;;
    001|011|101|111) ;;
    *)
        echo "ERROR: Invalid state" >&2
        exit 2
        ;;
esac

case "$SD_READY" in
    0|1) ;;
    *) echo "ERROR: Invalid readiness" >&2; exit 2 ;;
esac

[ -f "$WAN_FILE" ] || {
    echo "BLOCKED: WAN DNS file missing" >&2
    exit 4
}

# Candidate input must be usable by the IPv4-only YAML renderer.
# Never accept malformed addresses, loopbacks or the router's own LAN DNS IP.
# R76S_LOCAL_DNS_IPV4 can override the default LAN address for offline tests.
LOCAL_IP="${R76S_LOCAL_DNS_IPV4:-192.168.50.1}"
WAN_SERVERS="$(awk -v local_ip="$LOCAL_IP" '
$1 == "nameserver" && NF == 2 {
    ip=$2
    count=split(ip, octets, ".")
    if (count != 4) next
    valid=1
    for (i=1; i<=4; i++) {
        if (octets[i] !~ /^[0-9]+$/ || length(octets[i]) > 3 ||
            (length(octets[i]) > 1 && substr(octets[i],1,1) == "0") ||
            (octets[i]+0) > 255) valid=0
    }
    if (!valid) next
    first=octets[1]+0; second=octets[2]+0
    if (first < 1 || first == 127 || first >= 224 ||
        (first == 169 && second == 254)) next
    if (ip == local_ip) next
    if (!seen[ip]++) print ip
}' "$WAN_FILE")"

[ -n "$WAN_SERVERS" ] || {
    echo "BLOCKED: No eligible WAN DNS servers" >&2
    exit 4
}

FIRST_WAN="$(printf '%s\n' "$WAN_SERVERS" | head -n1)"

case "${STATE}:${SD_READY}" in
    011:1|111:1)
        UPSTREAM_KIND=SMARTDNS
        echo "ADGUARD_UPSTREAM_SOURCE=SMARTDNS"
        echo "ADGUARD_PRIMARY_DNS=127.0.0.1:6053"
        ;;
    *)
        UPSTREAM_KIND=WAN
        echo "ADGUARD_UPSTREAM_SOURCE=WAN"
        echo "ADGUARD_PRIMARY_DNS=$FIRST_WAN"
        ;;
esac

for IP in $WAN_SERVERS; do
    # Do not repeat the WAN primary as its own fallback.
    if [ "$UPSTREAM_KIND" = "WAN" ] &&
       [ "$IP" = "$FIRST_WAN" ]; then
        continue
    fi
    echo "ADGUARD_FALLBACK_DNS=$IP"
done

case "${STATE}:${SD_READY}" in
    101:*)
        echo "SAFETY=UPSTREAM_PLAN_ONLY"
        echo "ISOLATION=VERIFY_PASSWALL_NATIVE_PROXY_AT_RUNTIME"
        ;;
    111:0)
        echo "SAFETY=BLOCK_SMARTDNS_READINESS_REQUIRED"
        ;;
    *)
        echo "SAFETY=UPSTREAM_PLAN_ONLY"
        ;;
esac

echo "CONFIG_CHANGES=NONE"
