#!/bin/sh
# R76S V1.1.1 DNS State Detector
# Read-only. No UCI changes or service restarts.

uci_flag() {
    VALUE="$(uci -q get "$1" 2>/dev/null)"
    [ "$VALUE" = "1" ] && echo 1 || echo 0
}

has_port() {
    netstat -lnut 2>/dev/null | awk -v port=":$1" '
        $1 ~ /^(tcp|udp)/ && $4 ~ port "$" {
            found=1
        }
        END {
            exit(found ? 0 : 1)
        }
    '
}

# SmartDNS on R76S is started via /lib/ld-musl-aarch64.so.1.
# /proc/PID/comm says ld-musl-aarch64, not smartdns.bin.
# Match the exact process argv to avoid false negative from pidof smartdns.bin.
smartdns_pid() {
    proc_root="${R76S_V111_PROC_ROOT:-/proc}"
    for f in "$proc_root"/[0-9]*/cmdline; do
        [ -r "$f" ] || continue
        if tr '\000' '\n' < "$f" 2>/dev/null | grep -Fxq             -e /usr/libexec/r76s/smartdns.bin -e /usr/sbin/smartdns; then
            pid="${f%/cmdline}"
            printf '%s\n' "${pid##*/}"
            return 0
        fi
    done
    return 1
}

# Owner verification is required: an unrelated DNS process could bind 6053.
port_owned_by_pid() {
    port=":$1"
    wanted_pid="$2"
    netstat -lnutp 2>/dev/null | awk -v port="$port" -v owner="$wanted_pid/" '
        $1 ~ /^(tcp|udp)/ && $4 ~ port "$" && index($NF, owner) == 1 { found=1 }
        END { exit(found ? 0 : 1) }
    '
}

PW_ENABLED="$(uci_flag 'passwall.@global[0].enabled')"
PW2_ENABLED="$(uci_flag 'passwall2.@global[0].enabled')"
SD_ENABLED="$(uci_flag 'smartdns.@smartdns[0].enabled')"

if /etc/init.d/adguardhome enabled >/dev/null 2>&1; then
    AGH_BOOT_ENABLED=1
else
    AGH_BOOT_ENABLED=0
fi

AGH_CONFIG=0
[ -s /etc/adguardhome.yaml ] && AGH_CONFIG=1
[ -s /etc/adguardhome/adguardhome.yaml ] && AGH_CONFIG=1

PW_PROCESS=0
if ps w 2>/dev/null | grep -Eq \
'[x]ray.*[/]tmp/etc/passwall/|[s]ing-box.*[/]tmp/etc/passwall/|[d]nsmasq_default.*[/]tmp/etc/passwall/'; then
    PW_PROCESS=1
fi

PW2_PROCESS=0
if ps w 2>/dev/null | grep -Eq \
'[x]ray.*[/]tmp/etc/passwall2/|[s]ing-box.*[/]tmp/etc/passwall2/'; then
    PW2_PROCESS=1
fi

SD_LISTEN=0
has_port 6053 && SD_LISTEN=1
SD_PROCESS=0
SD_OWNER=0
SD_PID="$(smartdns_pid || true)"
if [ -n "$SD_PID" ]; then
    SD_PROCESS=1
    for pid in $SD_PID; do
        if port_owned_by_pid 6053 "$pid"; then
            SD_OWNER=1
            break
        fi
    done
fi

AGH_LISTEN=0
has_port 3053 && AGH_LISTEN=1

AGH_PROCESS=0
if ps w 2>/dev/null | grep -q '[A]dGuardHome'; then
    AGH_PROCESS=1
fi

PW_READY="$PW_PROCESS"
SD_READY=0
if [ "$SD_LISTEN" = 1 ] && [ "$SD_OWNER" = 1 ]; then
    SD_READY=1
fi

AGH_READY=0
if [ "$AGH_LISTEN" = 1 ] && [ "$AGH_PROCESS" = 1 ]; then
    AGH_READY=1
fi

# A manually started AdGuard process counts as active.
# Boot enablement alone also expresses desired availability.
AGH_ENABLED=0
if [ "$AGH_BOOT_ENABLED" = 1 ] && [ "$AGH_CONFIG" = 1 ]; then
    AGH_ENABLED=1
fi
[ "$AGH_PROCESS" = 1 ] && AGH_ENABLED=1

echo "PW_ENABLED=$PW_ENABLED"
echo "PW_READY=$PW_READY"
echo "PW2_ENABLED=$PW2_ENABLED"
echo "PW2_PROCESS=$PW2_PROCESS"
echo "SD_ENABLED=$SD_ENABLED"
echo "SD_READY=$SD_READY"
echo "SD_PROCESS=$SD_PROCESS"
echo "SD_LISTEN=$SD_LISTEN"
echo "SD_PORT_OWNER_VERIFIED=$SD_OWNER"
echo "AGH_ENABLED=$AGH_ENABLED"
echo "AGH_READY=$AGH_READY"
echo "AGH_BOOT_ENABLED=$AGH_BOOT_ENABLED"
echo "AGH_CONFIG=$AGH_CONFIG"
echo "AGH_LISTEN=$AGH_LISTEN"
echo "READINESS_METHOD=smartdns_exact_argv_and_port_pid"
echo "CONFIG_CHANGES=NONE"
