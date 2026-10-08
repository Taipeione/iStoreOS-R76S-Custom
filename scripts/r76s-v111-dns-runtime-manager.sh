#!/bin/sh
# R76S V1.1.1 transactional DNS runtime coordinator.
# Installed in firmware but deliberately disabled until live validation.
# It never changes PassWall/SmartDNS/AdGuard boot-enable flags.  It only
# reconciles DNS wiring for the requested P/S/A state when explicitly run or
# when its own init service is later enabled by the user.

set -eu

TAG="r76s-v111-dns"
HELPER_DIR="${R76S_V111_HELPER_DIR:-/usr/libexec/r76s/v111-dns-readonly}"
DETECT="$HELPER_DIR/r76s-v111-dns-detect.sh"
GUARD="$HELPER_DIR/r76s-v111-dns-guard.sh"
AUDIT="$HELPER_DIR/r76s-v111-dns-runtime-audit.sh"
YAML_RENDER="$HELPER_DIR/r76s-v111-agh-yaml-render.sh"
STATE_DIR="${R76S_V111_STATE_DIR:-/etc/r76s-v111-dns}"
RUN_DIR="${R76S_V111_RUN_DIR:-/var/run/r76s-v111-dns}"
LOCK_DIR="${R76S_V111_LOCK_DIR:-/var/lock/r76s-v111-dns-manager.lock}"
OVERRIDE_FILE="$RUN_DIR/passwall-dns-shunt"
CONFIG_NAME="r76s_v111_dns"
CONFIG_SECTION="main"

log() {
    logger -t "$TAG" "$*" 2>/dev/null || true
    printf '%s\n' "$*" >&2
}

fatal() {
    log "BLOCKED: $*"
    return 1
}

require_tools() {
    for f in "$DETECT" "$GUARD" "$AUDIT" "$YAML_RENDER"; do
        [ -x "$f" ] || fatal "missing helper: $f" || return 1
    done
    for c in uci netstat awk sed grep cp mv rm mkdir nslookup cmp mktemp timeout sort tr; do
        command -v "$c" >/dev/null 2>&1 || fatal "missing command: $c" || return 1
    done
}

cfg_get() {
    uci -q get "$CONFIG_NAME.$CONFIG_SECTION.$1" 2>/dev/null || true
}

manager_enabled() {
    [ "$(cfg_get enabled)" = "1" ]
}

poll_seconds() {
    n="$(cfg_get poll_seconds)"
    case "$n" in
        ''|*[!0-9]*) n=10 ;;
    esac
    [ "$n" -ge 5 ] 2>/dev/null || n=5
    [ "$n" -le 300 ] 2>/dev/null || n=300
    printf '%s\n' "$n"
}

ensure_dirs() {
    umask 077
    mkdir -p "$STATE_DIR" "$RUN_DIR"
    chmod 700 "$STATE_DIR" "$RUN_DIR" 2>/dev/null || true
}

acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        trap 'rm -rf "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM HUP
        return 0
    fi
    return 1
}

release_lock() {
    rm -rf "$LOCK_DIR" 2>/dev/null || true
    trap - EXIT INT TERM HUP
}

uci_flag() {
    [ "$(uci -q get "$1" 2>/dev/null || true)" = "1" ] && printf '1\n' || printf '0\n'
}

adguard_requested() {
    if /etc/init.d/adguardhome enabled >/dev/null 2>&1 && \
       { [ -s /etc/adguardhome.yaml ] || [ -s /etc/adguardhome/adguardhome.yaml ]; }; then
        printf '1\n'; return
    fi
    if ps w 2>/dev/null | grep -q '[A]dGuardHome'; then
        printf '1\n'; return
    fi
    printf '0\n'
}

requested_state() {
    p="$(uci_flag 'passwall.@global[0].enabled')"
    s="$(uci_flag 'smartdns.@smartdns[0].enabled')"
    a="$(adguard_requested)"
    printf '%s%s%s\n' "$p" "$s" "$a"
}

passwall2_guard() {
    if [ "$(uci_flag 'passwall2.@global[0].enabled')" = "1" ]; then
        fatal "PassWall2 is enabled; V1.1.1 runtime coordinator manages PassWall only"
        return 1
    fi
}

port_owned_protocol() {
    proto="$1"; port="$2"; pattern="$3"
    netstat -lnutp 2>/dev/null | awk -v proto="$proto" -v port=":$port" -v pat="$pattern" '
        $1 ~ ("^" proto) && $4 ~ port "$" && $NF ~ pat { found=1 }
        END { exit(found ? 0 : 1) }
    '
}

adguard_ready() {
    ps w 2>/dev/null | grep -q '[A]dGuardHome' || return 1
    port_owned_protocol tcp 3053 '/AdGuardHome$' &&
    port_owned_protocol udp 3053 '/AdGuardHome$'
}

smartdns_pid() {
    for f in /proc/[0-9]*/cmdline; do
        [ -r "$f" ] || continue
        if tr '\000' '\n' < "$f" 2>/dev/null | grep -Fxq \
           -e /usr/libexec/r76s/smartdns.bin -e /usr/sbin/smartdns; then
            pid="${f%/cmdline}"; printf '%s\n' "${pid##*/}"; return 0
        fi
    done
    return 1
}

smartdns_ready() {
    pid="$(smartdns_pid || true)"
    [ -n "$pid" ] || return 1
    netstat -lnutp 2>/dev/null | awk -v port=':6053' -v owner="$pid/" '
        $1 ~ /^tcp/ && $4 ~ port "$" && index($NF, owner) == 1 { tcp=1 }
        $1 ~ /^udp/ && $4 ~ port "$" && index($NF, owner) == 1 { udp=1 }
        END { exit(tcp && udp ? 0 : 1) }
    '
}

passwall_ready() {
    if ps w 2>/dev/null | grep -Eq \
      '[x]ray.*[/]tmp/etc/passwall/|[s]ing-box.*[/]tmp/etc/passwall/|[d]nsmasq_default.*[/]tmp/etc/passwall/'; then
        return 0
    fi
    netstat -lnutp 2>/dev/null | awk '$4 ~ /:11400$/ && $NF ~ /dnsmasq/ {found=1} END {exit(found?0:1)}'
}

wait_ready() {
    fn="$1"; limit="$2"; i=0
    while [ "$i" -lt "$limit" ]; do
        if "$fn"; then return 0; fi
        sleep 1
        i=$((i + 1))
    done
    return 1
}

adguard_yaml() {
    if [ -s /etc/adguardhome.yaml ]; then
        printf '/etc/adguardhome.yaml\n'
    elif [ -s /etc/adguardhome/adguardhome.yaml ]; then
        printf '/etc/adguardhome/adguardhome.yaml\n'
    else
        return 1
    fi
}

resolv_file() {
    if [ -s /tmp/resolv.conf.d/resolv.conf.auto ]; then
        printf '/tmp/resolv.conf.d/resolv.conf.auto\n'
    elif [ -s /tmp/resolv.conf.auto ]; then
        printf '/tmp/resolv.conf.auto\n'
    else
        return 1
    fi
}

eligible_wan_ipv4() {
    file="$1"
    awk -v local_ip="${R76S_LOCAL_DNS_IPV4:-192.168.50.1}" '
    $1 == "nameserver" && NF == 2 {
        ip=$2; n=split(ip,a,"."); if (n != 4) next
        ok=1
        for (i=1;i<=4;i++) {
            if (a[i] !~ /^[0-9]+$/ || length(a[i]) > 3 ||
                (length(a[i]) > 1 && substr(a[i],1,1) == "0") || a[i]+0 > 255) ok=0
        }
        if (!ok) next
        if (a[1]+0 < 1 || a[1]+0 == 127 || a[1]+0 >= 224 ||
            (a[1]+0 == 169 && a[2]+0 == 254) || ip == local_ip) next
        if (!seen[ip]++) print ip
    }' "$file"
}

choose_wan_ipv4() {
    file="$(resolv_file)" || return 1
    command -v timeout >/dev/null 2>&1 || {
        fatal "timeout command required for WAN DNS probe"; return 1;
    }
    candidates="$(eligible_wan_ipv4 "$file")"
    [ -n "$candidates" ] || { fatal "no eligible IPv4 WAN DNS"; return 1; }
    for ip in $candidates; do
        if timeout 6 nslookup -type=A www.baidu.com "$ip" >/dev/null 2>&1; then
            printf '%s\n' "$ip"; return 0
        fi
    done
    fatal "no WAN DNS candidate answered probe"
    return 1
}

classify_dns() {
    uci -q show 'dhcp.@dnsmasq[0]' 2>/dev/null | sh "$GUARD" | sed -n 's/^DNS_PROFILE=//p'
}

adopt_if_safe() {
    [ -f "$STATE_DIR/owned" ] && return 0
    profile="$(classify_dns)"
    case "$profile" in
        WAN_BASELINE|LEGACY_3053) ;;
        *) fatal "dnsmasq profile $profile is not safe for automatic ownership"; return 1 ;;
    esac
    tmp="$STATE_DIR/.adopt.$$"
    rm -rf "$tmp" 2>/dev/null || true
    mkdir -p "$tmp/original"
    chmod 700 "$tmp" "$tmp/original" 2>/dev/null || true
    cp -p /etc/config/dhcp "$tmp/original/dhcp"
    yaml="$(adguard_yaml || true)"
    if [ -n "$yaml" ]; then
        cp -p "$yaml" "$tmp/original/adguardhome.yaml"
        printf '%s\n' "$yaml" > "$tmp/original/adguard-path"
    else
        : > "$tmp/original/adguard-absent"
    fi
    printf '%s\n' "$profile" > "$tmp/original-profile"
    printf '%s\n' "R76S_V111_DNS_OWNER=1" > "$tmp/owned"
    # Move individual objects so STATE_DIR itself remains stable for sysupgrade.
    mkdir -p "$STATE_DIR/original"
    cp -p "$tmp/original/dhcp" "$STATE_DIR/original/dhcp"
    if [ -f "$tmp/original/adguardhome.yaml" ]; then
        cp -p "$tmp/original/adguardhome.yaml" "$STATE_DIR/original/adguardhome.yaml"
        cp -p "$tmp/original/adguard-path" "$STATE_DIR/original/adguard-path"
    else
        : > "$STATE_DIR/original/adguard-absent"
    fi
    cp -p "$tmp/original-profile" "$STATE_DIR/original-profile"
    cp -p "$tmp/owned" "$STATE_DIR/owned"
    chmod 600 "$STATE_DIR"/owned "$STATE_DIR"/original-profile "$STATE_DIR"/original/* 2>/dev/null || true
    rm -rf "$tmp"
    sync
    log "adopted DNS ownership profile=$profile after local backup"
}

capture_running() {
    p=0; s=0; a=0
    passwall_ready && p=1 || true
    smartdns_ready && s=1 || true
    adguard_ready && a=1 || true
    printf 'P=%s\nS=%s\nA=%s\n' "$p" "$s" "$a"
}

begin_txn() {
    target="$1"
    [ ! -d "$STATE_DIR/txn" ] || { fatal "transaction already present"; return 1; }
    tmp="$STATE_DIR/.txn.$$"
    rm -rf "$tmp" 2>/dev/null || true
    mkdir -p "$tmp"
    chmod 700 "$tmp" 2>/dev/null || true
    cp -p /etc/config/dhcp "$tmp/before.dhcp"
    yaml="$(adguard_yaml || true)"
    if [ -n "$yaml" ]; then
        cp -p "$yaml" "$tmp/before.adguard"
        printf '%s\n' "$yaml" > "$tmp/adguard-path"
    else
        : > "$tmp/adguard-absent"
    fi
    if [ -f "$OVERRIDE_FILE" ]; then
        cp -p "$OVERRIDE_FILE" "$tmp/before.override"
    else
        : > "$tmp/override-absent"
    fi
    capture_running > "$tmp/before.running"
    printf '%s\n' "$target" > "$tmp/target"
    printf 'APPLYING\n' > "$tmp/state"
    chmod 600 "$tmp"/* 2>/dev/null || true
    mv "$tmp" "$STATE_DIR/txn"
    sync
}

runtime_restore_services() {
    file="$1"
    p="$(sed -n 's/^P=//p' "$file")"; s="$(sed -n 's/^S=//p' "$file")"; a="$(sed -n 's/^A=//p' "$file")"
    if [ "$a" = 1 ]; then /etc/init.d/adguardhome start >/dev/null 2>&1 || true
    else /etc/init.d/adguardhome stop >/dev/null 2>&1 || true; fi
    if [ "$s" = 1 ]; then /etc/init.d/smartdns start >/dev/null 2>&1 || true
    else /etc/init.d/smartdns stop >/dev/null 2>&1 || true; fi
    if [ "$p" = 1 ]; then /etc/init.d/passwall restart >/dev/null 2>&1 || true
    else /etc/init.d/passwall stop >/dev/null 2>&1 || true; fi
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
}

rollback_txn() {
    [ -d "$STATE_DIR/txn" ] || return 0
    tx="$STATE_DIR/txn"
    [ -f "$tx/before.dhcp" ] || { fatal "transaction backup missing dhcp"; return 1; }
    # Stop writers first so AdGuard/PassWall cannot save over restored files.
    /etc/init.d/passwall stop >/dev/null 2>&1 || true
    /etc/init.d/adguardhome stop >/dev/null 2>&1 || true
    /etc/init.d/smartdns stop >/dev/null 2>&1 || true
    cp -p "$tx/before.dhcp" /etc/config/dhcp
    if [ -f "$tx/before.adguard" ]; then
        path="$(cat "$tx/adguard-path")"
        cp -p "$tx/before.adguard" "$path"
    elif [ -f "$tx/adguard-absent" ]; then
        now="$(adguard_yaml || true)"
        [ -z "$now" ] || rm -f "$now"
    fi
    if [ -f "$tx/before.override" ]; then
        mkdir -p "$RUN_DIR"; cp -p "$tx/before.override" "$OVERRIDE_FILE"
    else
        rm -f "$OVERRIDE_FILE"
    fi
    sync
    runtime_restore_services "$tx/before.running"
    rm -rf "$tx"
    sync
    log "transaction rolled back"
}

recover_if_needed() {
    if [ -d "$STATE_DIR/txn" ]; then
        st="$(cat "$STATE_DIR/txn/state" 2>/dev/null || true)"
        if [ "$st" = APPLYING ]; then
            log "recovering interrupted DNS transaction"
            rollback_txn || return 1
        else
            fatal "unknown transaction journal state"
            return 1
        fi
    fi
}

commit_txn() {
    target="$1"
    printf '%s\n' "$target" > "$STATE_DIR/last-good-state"
    rm -f "$STATE_DIR/blocked-state"
    rm -rf "$STATE_DIR/txn"
    sync
}

preserve_domain_servers() {
    uci -q show 'dhcp.@dnsmasq[0]' 2>/dev/null | awk '
      index($0,".server=") {
        p=index($0,"="); v=substr($0,p+1)
        q=sprintf("%c",39)
        if (substr(v,1,1)==q && substr(v,length(v),1)==q) v=substr(v,2,length(v)-2)
        if (index(v,"/") > 0) print v
      }'
}

set_main_dns() {
    mode="$1"
    saved="$(preserve_domain_servers)"
    uci -q delete 'dhcp.@dnsmasq[0].server' || true
    if [ -n "$saved" ]; then
        printf '%s\n' "$saved" | while IFS= read -r val; do
            [ -n "$val" ] && uci -q add_list "dhcp.@dnsmasq[0].server=$val"
        done
    fi
    case "$mode" in
        WAN)
            uci -q delete 'dhcp.@dnsmasq[0].noresolv' || true
            rf="$(resolv_file)" || { fatal "WAN resolv file missing"; return 1; }
            uci -q set "dhcp.@dnsmasq[0].resolvfile=$rf"
            ;;
        AGH)
            uci -q set 'dhcp.@dnsmasq[0].noresolv=1'
            uci -q set 'dhcp.@dnsmasq[0].resolvfile=/tmp/resolv.conf.d/r76s-unused'
            uci -q add_list 'dhcp.@dnsmasq[0].server=127.0.0.1#3053'
            ;;
        SMARTDNS)
            uci -q set 'dhcp.@dnsmasq[0].noresolv=1'
            uci -q set 'dhcp.@dnsmasq[0].resolvfile=/tmp/resolv.conf.d/r76s-unused'
            uci -q add_list 'dhcp.@dnsmasq[0].server=127.0.0.1#6053'
            ;;
        *) fatal "bad main DNS mode $mode"; return 1 ;;
    esac
    uci -q commit dhcp
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || { fatal "dnsmasq restart failed"; return 1; }
}

write_override() {
    value="$1"
    mkdir -p "$RUN_DIR"; chmod 700 "$RUN_DIR" 2>/dev/null || true
    tmp="$OVERRIDE_FILE.$$"
    printf '%s\n' "$value" > "$tmp"
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$OVERRIDE_FILE"
}

remove_override() { rm -f "$OVERRIDE_FILE"; }

write_adguard_target() {
    target="$1"
    yaml="$(adguard_yaml)" || { fatal "AdGuard YAML missing"; return 1; }
    dir="${yaml%/*}"; [ -n "$dir" ] || dir=/
    tmp="$dir/.r76s-v111-adguard.$$"
    cp -p "$yaml" "$tmp"
    if ! sh "$YAML_RENDER" "$yaml" "$target" > "$tmp"; then
        rm -f "$tmp"; fatal "AdGuard YAML candidate rejected"; return 1
    fi
    if cmp -s "$yaml" "$tmp"; then rm -f "$tmp"; return 0; fi
    /etc/init.d/adguardhome stop >/dev/null 2>&1 || true
    mv -f "$tmp" "$yaml"
    sync
}

ensure_smartdns() {
    if smartdns_ready; then return 0; fi
    /etc/init.d/smartdns start >/dev/null 2>&1 || true
    wait_ready smartdns_ready 15 || { fatal "SmartDNS 6053 not ready"; return 1; }
}

ensure_adguard() {
    if adguard_ready; then return 0; fi
    /etc/init.d/adguardhome start >/dev/null 2>&1 || true
    wait_ready adguard_ready 15 || { fatal "AdGuard 3053 not ready"; return 1; }
}

ensure_passwall() {
    /etc/init.d/passwall restart >/dev/null 2>&1 || true
    wait_ready passwall_ready 20 || { fatal "PassWall not ready"; return 1; }
}

stop_adguard() { /etc/init.d/adguardhome stop >/dev/null 2>&1 || true; }
stop_smartdns() { /etc/init.d/smartdns stop >/dev/null 2>&1 || true; }
stop_passwall() { /etc/init.d/passwall stop >/dev/null 2>&1 || true; }

remove_stale_passwall_smartdns() {
    rm -f /tmp/etc/smartdns/passwall*.conf 2>/dev/null || true
}

passwall_dns_redirect_supported() {
    [ "$(uci -q get 'passwall.@global[0].dns_redirect' 2>/dev/null || true)" = "1" ]
}

native_proxy_refs() {
    {
        [ -r /tmp/etc/passwall/acl/default/dnsmasq.conf ] && cat /tmp/etc/passwall/acl/default/dnsmasq.conf
        for f in /tmp/etc/passwall/acl/default/dnsmasq.d/*.conf; do [ -r "$f" ] && cat "$f"; done
    } 2>/dev/null | awk '
      /^[[:space:]]*#/ {next}
      /^server=/ {
        line=$0
        if (line ~ /127[.]0[.]0[.]1#3053([^0-9]|$)/) next
        if (line ~ /127[.]0[.]0[.]1#6053([^0-9]|$)/) next
        if (line ~ /(127[.]0[.]0[.]1|::1)#15355([^0-9]|$)/) next
        if (line ~ /127[.]0[.]0[.]1#[0-9]+/ || line ~ /::1#[0-9]+/ || line ~ /[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+#[0-9]+/) print line
      }'
}

verify_native_proxy_isolation() {
    state="$1"
    refs="$(native_proxy_refs)"
    [ -n "$refs" ] || { fatal "PassWall native proxy DNS upstream not found"; return 1; }
    if printf '%s\n' "$refs" | grep -Eq '(127[.]0[.]0[.]1|::1)#(3053|6053|15355)([^0-9]|$)'; then
        fatal "PassWall native proxy DNS still depends on AdGuard/SmartDNS"
        return 1
    fi
    # 101 must prove a live local proxy DNS endpoint, not merely a public
    # resolver line.  Accept the PassWall DNS engines used by this source tree.
    if [ "$state" = 101 ]; then
        ports="$(printf '%s\n' "$refs" | awk '
            match($0, /(127[.]0[.]0[.]1|::1)#[0-9]+/) {
                v=substr($0,RSTART,RLENGTH); sub(/^.*#/,"",v); print v
            }' | sort -u)"
        [ -n "$ports" ] || { fatal "101 has no local PassWall proxy DNS endpoint"; return 1; }
        live=0
        for port in $ports; do
            if netstat -lnutp 2>/dev/null | awk -v p=":$port" '
                $4 ~ p "$" && $NF ~ /(xray|sing-box|chinadns|dns2socks|ss-|socks)/ {ok=1}
                END {exit(ok?0:1)}'; then
                live=1; break
            fi
        done
        [ "$live" = 1 ] || { fatal "101 proxy DNS endpoint owner not verified"; return 1; }
    fi
    return 0
}

probe_dns() {
    server="$1"
    command -v timeout >/dev/null 2>&1 || return 1
    timeout 8 nslookup -type=A www.baidu.com "$server" >/dev/null 2>&1 && \
    timeout 8 nslookup -type=A www.google.com "$server" >/dev/null 2>&1
}

target_runtime_ready() {
    state="$1"; p="${state%??}"; rest="${state#?}"; s="${rest%?}"; a="${state#??}"
    if [ "$p" = 1 ]; then
        passwall_ready || return 1
    else
        if passwall_ready; then return 1; fi
    fi
    if [ "$s" = 1 ]; then
        smartdns_ready || return 1
    else
        if smartdns_ready; then return 1; fi
    fi
    if [ "$a" = 1 ]; then
        adguard_ready || return 1
    else
        if adguard_ready; then return 1; fi
    fi
    return 0
}

final_probe() {
    state="$1"; p="${state%??}"; rest="${state#?}"; s="${rest%?}"; a="${state#??}"
    probe_dns 127.0.0.1 || { fatal "main DNS probe failed"; return 1; }
    [ "$a" = 0 ] || probe_dns '127.0.0.1#3053' || { fatal "AdGuard DNS probe failed"; return 1; }
    [ "$s" = 0 ] || probe_dns '127.0.0.1#6053' || { fatal "SmartDNS DNS probe failed"; return 1; }
    if [ "$p" = 1 ]; then
        probe_dns '127.0.0.1#11400' || { fatal "PassWall DNS probe failed"; return 1; }
    fi
}

apply_target() {
    state="$1"; p="${state%??}"; rest="${state#?}"; s="${rest%?}"; a="${state#??}"
    case "$state" in 000|001|010|011|100|101|110|111) ;; *) fatal "invalid target $state"; return 1;; esac
    [ "$p" = 0 ] || passwall_dns_redirect_supported || { fatal "PassWall dns_redirect must be 1 for managed runtime"; return 1; }

    # 1. Prepare SmartDNS if the target needs it.
    if [ "$s" = 1 ]; then ensure_smartdns || return 1; fi

    # 2. Prepare AdGuard upstream.  If a running AdGuard must be rewritten,
    # route main DNS away first so its restart cannot strand the router.
    if [ "$a" = 1 ]; then
        if [ "$s" = 1 ]; then agh_target='127.0.0.1:6053'; fallback=SMARTDNS
        else agh_target="$(choose_wan_ipv4)" || return 1; fallback=WAN
        fi
        yaml="$(adguard_yaml)" || { fatal "AdGuard YAML unavailable"; return 1; }
        cand="$(mktemp /tmp/r76s-v111-agh.XXXXXX)"
        if ! sh "$YAML_RENDER" "$yaml" "$agh_target" > "$cand"; then rm -f "$cand"; return 1; fi
        if ! cmp -s "$yaml" "$cand"; then
            rm -f "$cand"
            set_main_dns "$fallback" || return 1
            write_adguard_target "$agh_target" || return 1
        else
            rm -f "$cand"
        fi
        ensure_adguard || return 1
    fi

    # 3. Stop services the target does not use only after downstreams have a
    # safe replacement route.
    if [ "$a" = 0 ]; then
        if [ "$s" = 1 ]; then set_main_dns SMARTDNS || return 1
        else set_main_dns WAN || return 1
        fi
        stop_adguard
    fi
    if [ "$s" = 0 ]; then
        # If A=1 it is already running on independent WAN; otherwise main is WAN.
        stop_smartdns
    fi

    # In 101, make AdGuard the direct/default path before PassWall generates
    # dnsmasq rules.  Proxy-domain rules still use PassWall's independent
    # TUN_DNS, which is verified below.
    if [ "$state" = 101 ]; then
        set_main_dns AGH || return 1
    fi

    # 4. Regenerate PassWall DNS after A/S reach their target readiness so the
    # build-time 3053 gate sees the correct truth.  Runtime override avoids
    # persistently changing the user's dns_shunt UCI option.
    if [ "$p" = 1 ]; then
        if [ "$s" = 1 ]; then write_override smartdns
        else write_override dnsmasq
        fi
        ensure_passwall || return 1
        if [ "$s" = 0 ]; then
            remove_stale_passwall_smartdns
            verify_native_proxy_isolation "$state" || return 1
        fi
    else
        remove_override
        stop_passwall
        remove_stale_passwall_smartdns
    fi

    # PassWall smartdns mode may have reloaded SmartDNS; re-check it.
    [ "$s" = 0 ] || ensure_smartdns || return 1

    # 5. Switch the system resolver last.
    if [ "$a" = 1 ]; then set_main_dns AGH || return 1
    elif [ "$s" = 1 ]; then set_main_dns SMARTDNS || return 1
    else set_main_dns WAN || return 1
    fi

    # 6. File-grounded graph audit followed by live resolver probes.
    sh "$AUDIT" "$state" >/tmp/r76s-v111-dns-audit.$$ 2>&1 || {
        cat /tmp/r76s-v111-dns-audit.$$ >&2 || true
        rm -f /tmp/r76s-v111-dns-audit.$$
        fatal "runtime dependency audit failed"
        return 1
    }
    rm -f /tmp/r76s-v111-dns-audit.$$
    final_probe "$state" || return 1
}

reconcile() {
    require_tools || return 1
    ensure_dirs
    if ! /etc/init.d/r76s-v111-dns-manager enabled >/dev/null 2>&1; then
        fatal "enable r76s-v111-dns-manager init first so interrupted transactions recover on boot"
        return 1
    fi
    acquire_lock || { log "another reconcile is running"; return 0; }
    recover_if_needed || { release_lock; return 1; }
    passwall2_guard || { release_lock; return 1; }
    adopt_if_safe || { release_lock; return 1; }
    target="$(requested_state)"
    begin_txn "$target" || { release_lock; return 1; }
    if apply_target "$target"; then
        commit_txn "$target"
        printf 'REQUESTED_STATE=%s\n' "$target"
        printf 'RUNTIME_RECONCILE=PASS\n'
        log "reconcile success state=$target"
        release_lock
        return 0
    fi
    printf '%s\n' "$target" > "$STATE_DIR/blocked-state" 2>/dev/null || true
    log "reconcile failed state=$target; rolling back"
    rollback_txn || true
    release_lock
    return 1
}

status_cmd() {
    require_tools || return 1
    req="$(requested_state)"
    printf 'REQUESTED_STATE=%s\n' "$req"
    printf 'MANAGER_CONFIG_ENABLED=%s\n' "$(cfg_get enabled)"
    if [ -f "$STATE_DIR/owned" ]; then printf 'OWNERSHIP=ADOPTED\n'; else printf 'OWNERSHIP=NOT_ADOPTED\n'; fi
    if [ -f "$STATE_DIR/last-good-state" ]; then printf 'LAST_GOOD_STATE=%s\n' "$(cat "$STATE_DIR/last-good-state")"; else printf 'LAST_GOOD_STATE=NONE\n'; fi
    if [ -f "$STATE_DIR/blocked-state" ]; then printf 'BLOCKED_STATE=%s\n' "$(cat "$STATE_DIR/blocked-state")"; else printf 'BLOCKED_STATE=NONE\n'; fi
    sh "$DETECT"
}

restore_original() {
    ensure_dirs
    acquire_lock || { log "manager busy"; return 1; }
    recover_if_needed || { release_lock; return 1; }
    [ -f "$STATE_DIR/original/dhcp" ] || { release_lock; fatal "no original snapshot"; return 1; }
    cp -p "$STATE_DIR/original/dhcp" /etc/config/dhcp
    if [ -f "$STATE_DIR/original/adguardhome.yaml" ]; then
        p="$(cat "$STATE_DIR/original/adguard-path")"
        /etc/init.d/adguardhome stop >/dev/null 2>&1 || true
        cp -p "$STATE_DIR/original/adguardhome.yaml" "$p"
    fi
    remove_override
    sync
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    if [ "$(uci_flag 'smartdns.@smartdns[0].enabled')" = 1 ]; then /etc/init.d/smartdns start >/dev/null 2>&1 || true; fi
    if [ "$(uci_flag 'passwall.@global[0].enabled')" = 1 ]; then /etc/init.d/passwall restart >/dev/null 2>&1 || true; fi
    if [ "$(adguard_requested)" = 1 ]; then /etc/init.d/adguardhome start >/dev/null 2>&1 || true; fi
    # Emergency restore also disables the coordinator so it cannot immediately
    # re-adopt and overwrite the restored snapshot.
    uci -q set "$CONFIG_NAME.$CONFIG_SECTION.enabled=0" || true
    uci -q commit "$CONFIG_NAME" || true
    rm -rf "$STATE_DIR/txn" "$STATE_DIR/last-good-state" "$STATE_DIR/blocked-state"
    rm -f "$STATE_DIR/owned"
    log "original DNS snapshot restored; manager disabled"
    release_lock
}

selftest() {
    # Pure invariants only; no router commands or paths are touched.
    for state in 000 001 010 011 100 101 110 111; do
        p="${state%??}"; rest="${state#?}"; s="${rest%?}"; a="${state#??}"
        [ "${p}${s}${a}" = "$state" ] || exit 1
        if [ "$p" = 1 ] && [ "$s" = 0 ]; then override=dnsmasq
        elif [ "$p" = 1 ]; then override=smartdns
        else override=none
        fi
        if [ "$a" = 1 ]; then main=AGH
        elif [ "$s" = 1 ]; then main=SMARTDNS
        else main=WAN
        fi
        printf 'SELFTEST_STATE=%s MAIN=%s OVERRIDE=%s\n' "$state" "$main" "$override"
    done
    echo 'RUNTIME_MANAGER_SELFTEST=PASS'
    echo 'LIVE_APPLY_DEFAULT=DISABLED'
}

boot_recover() {
    require_tools || return 1
    ensure_dirs
    acquire_lock || return 0
    recover_if_needed
    rc=$?
    release_lock
    return "$rc"
}

daemon() {
    require_tools || exit 1
    ensure_dirs
    last=''
    while :; do
        if manager_enabled; then
            now="$(requested_state)"
            good="$(cat "$STATE_DIR/last-good-state" 2>/dev/null || true)"
            blocked="$(cat "$STATE_DIR/blocked-state" 2>/dev/null || true)"
            if [ "$now" != "$blocked" ]; then
                if [ "$now" != "$good" ] || ! target_runtime_ready "$now"; then
                    reconcile || true
                fi
            fi
            last="$now"
        fi
        sleep "$(poll_seconds)"
    done
}

usage() {
    cat <<'USAGE'
Usage: r76s-v111-dns-runtime-manager.sh COMMAND
  status            Read requested/readiness/manager state
  reconcile         Transactionally reconcile current P/S/A request
  restore-original  Restore the exact pre-adoption DHCP/AdGuard snapshot
  daemon             Poll and reconcile only when UCI manager enabled=1
  boot-recover       Restore an interrupted transaction only; no new apply
  --selftest          Offline pure-invariant test
USAGE
    exit 2
}

case "${1:-}" in
    status) status_cmd ;;
    reconcile) reconcile ;;
    restore-original) restore_original ;;
    daemon) daemon ;;
    boot-recover) boot_recover ;;
    --selftest) selftest ;;
    *) usage ;;
esac
