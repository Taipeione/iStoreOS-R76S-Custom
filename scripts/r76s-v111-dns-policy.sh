#!/bin/sh
# R76S V1.1.1 DNS Policy Matrix
# Read-only planner. Does not change UCI or services.
# Arguments: PassWall SmartDNS AdGuard (0 or 1)

[ "$#" -eq 3 ] || {
    echo "Usage: $0 PASSWALL SMARTDNS ADGUARD" >&2
    exit 2
}

for value in "$1" "$2" "$3"; do
    case "$value" in
        0|1) ;;
        *)
            echo "ERROR: Each argument must be 0 or 1" >&2
            exit 2
            ;;
    esac
done

STATE="$1$2$3"
SPECIAL_CASE=none

case "$STATE" in
    000)
        SYSTEM_DNS=wan
        PASSWALL_DNS=off
        ADGUARD_UPSTREAM=off
        ;;
    001)
        SYSTEM_DNS=adguard
        PASSWALL_DNS=off
        ADGUARD_UPSTREAM=domestic
        ;;
    010)
        SYSTEM_DNS=smartdns
        PASSWALL_DNS=off
        ADGUARD_UPSTREAM=off
        ;;
    011)
        SYSTEM_DNS=adguard
        PASSWALL_DNS=off
        ADGUARD_UPSTREAM=smartdns
        ;;
    100)
        SYSTEM_DNS=wan
        PASSWALL_DNS=native
        ADGUARD_UPSTREAM=off
        ;;
    101)
        SYSTEM_DNS=adguard
        PASSWALL_DNS=native_with_adguard
        ADGUARD_UPSTREAM=domestic
        SPECIAL_CASE=isolated_proxy_dns_required
        ;;
    110)
        SYSTEM_DNS=smartdns
        PASSWALL_DNS=smartdns
        ADGUARD_UPSTREAM=off
        ;;
    111)
        SYSTEM_DNS=adguard
        PASSWALL_DNS=adguard_then_smartdns
        ADGUARD_UPSTREAM=smartdns
        ;;
esac

printf 'STATE=%s\n' "$STATE"
printf 'SYSTEM_DNS=%s\n' "$SYSTEM_DNS"
printf 'PASSWALL_DNS=%s\n' "$PASSWALL_DNS"
printf 'ADGUARD_UPSTREAM=%s\n' "$ADGUARD_UPSTREAM"
printf 'SPECIAL_CASE=%s\n' "$SPECIAL_CASE"
