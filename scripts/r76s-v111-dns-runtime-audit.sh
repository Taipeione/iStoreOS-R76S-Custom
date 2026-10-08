#!/bin/sh
# R76S V1.1.1: read-only DNS dependency audit based on generated files.
# Does not source config files, change UCI, restart services, or write files.
# Usage: r76s-v111-dns-runtime-audit.sh 111 [FIXTURE_ROOT]
set -eu

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || { echo 'Usage: audit STATE [FIXTURE_ROOT]' >&2; exit 2; }
state=$1
case "$state" in 000|001|010|011|100|101|110|111) ;; *) echo 'INVALID_STATE' >&2; exit 2;; esac
root=${2:-/}
[ -d "$root" ] || { echo 'INVALID_ROOT' >&2; exit 2; }
root=${root%/}
[ -n "$root" ] || root=/
path() { if [ "$root" = / ]; then printf '/%s\n' "${1#/}"; else printf '%s/%s\n' "$root" "${1#/}"; fi; }
main_count=0
main_agh=0
main_sd=0
main_other=0
main_noresolv=0
for f in "$(path /var/etc)"/dnsmasq.conf.*; do
    [ -f "$f" ] || continue
    main_count=$((main_count+1))
    result=$(awk '
      /^[[:space:]]*#/ {next}
      /^server=/ {
        if ($0 ~ /127[.]0[.]0[.]1#3053([^0-9]|$)/) agh++
        else if ($0 ~ /127[.]0[.]0[.]1#6053([^0-9]|$)/) sd++
        else other++
      }
      /^no-resolv([[:space:]]|$)/ {nr++}
      END {printf "%d %d %d %d", agh+0, sd+0, other+0, nr+0}
    ' "$f")
    set -- $result
    main_agh=$((main_agh+$1)); main_sd=$((main_sd+$2))
    main_other=$((main_other+$3)); main_noresolv=$((main_noresolv+$4))
done

pw_file=$(path /tmp/etc/passwall/acl/default/dnsmasq.conf)
pw_present=0
pw_agh=0
pw_split=0
pw_other=0
if [ -r "$pw_file" ]; then
    pw_present=1
    result=$(awk '
      /^[[:space:]]*#/ {next}
      /^server=/ {
        if ($0 ~ /127[.]0[.]0[.]1#3053([^0-9]|$)/) agh++
        else if ($0 ~ /(127[.]0[.]0[.]1|::1)#15355([^0-9]|$)/) shunt++
        else other++
      }
      END {printf "%d %d %d", agh+0, shunt+0, other+0}
    ' "$pw_file")
    set -- $result
    pw_agh=$1; pw_split=$2; pw_other=$3
fi

agh_file=$(path /etc/adguardhome.yaml)
agh_present=0
agh_primary_sd=0
agh_primary_other=0
agh_primary_reverse=0
agh_fallback_count=0
if [ -r "$agh_file" ]; then
    agh_present=1
    result=$(awk '
      /^dns:[[:space:]]*$/ {section=1; field=""; next}
      /^[^[:space:]#][^:]*:/ && $0 !~ /^dns:/ {section=0; field=""}
      !section {next}
      /^  (upstream_dns|fallback_dns|bootstrap_dns):/ {
        field=$1; sub(/:$/, "", field); next
      }
      /^  [^ #][^:]*:/ {field=""; next}
      /^    -[[:space:]]+/ {
        if (field == "upstream_dns") {
          if ($0 ~ /(127[.]0[.]0[.]1|localhost):6053([^0-9]|$)/) sd++
          else if ($0 ~ /(127[.]0[.]0[.]1|localhost):[0-9]+([^0-9]|$)/ ||
                   $0 ~ /::1:[0-9]+([^0-9]|$)/) reverse++
          else other++
        }
        if (field == "fallback_dns") fallback++
      }
      END {printf "%d %d %d %d", sd+0, other+0, reverse+0, fallback+0}
    ' "$agh_file")
    set -- $result
    agh_primary_sd=$1; agh_primary_other=$2
    agh_primary_reverse=$3; agh_fallback_count=$4
fi

sd_main=$(path /var/etc/smartdns/smartdns.conf)
sd_main_present=0
sd_custom_include=0
sd_other_includes=0
if [ -r "$sd_main" ]; then
    sd_main_present=1
    result=$(awk '
      $1=="conf-file" && $0 !~ /^[[:space:]]*#/ {
        p=$2; gsub(/^[\047\"]|[\047\"]$/, "", p)
        if (p == "/etc/smartdns/custom.conf") found++
        else extra++
      }
      END {printf "%d %d", found+0, extra+0}
    ' "$sd_main")
    set -- $result
    sd_custom_include=$1; sd_other_includes=$2
fi
custom=$(path /etc/smartdns/custom.conf)
sd_pw_glob=0
if [ -r "$custom" ]; then
    sd_pw_glob=$(awk '
      $1=="conf-file" && $0 !~ /^[[:space:]]*#/ {
        p=$2; gsub(/^[\047\"]|[\047\"]$/, "", p)
        if (p == "/tmp/etc/smartdns/passwall*.conf") found++
      }
      END {print found+0}
    ' "$custom")
fi
sd_pw_count=0
sd_proxy=0
if [ "$sd_custom_include" -ge 1 ] && [ "$sd_pw_glob" -ge 1 ]; then
    for f in "$(path /tmp/etc/smartdns)"/passwall*.conf; do
        [ -f "$f" ] || continue
        sd_pw_count=$((sd_pw_count+1))
        n=$(awk '
          /^[[:space:]]*#/ {next}
          $1 ~ /^server(-[a-z0-9-]+)?$/ &&
          $0 ~ /(127[.]0[.]0[.]1|localhost):15356([^0-9]|$)/ {c++}
          END {print c+0}
        ' "$f")
        sd_proxy=$((sd_proxy+n))
    done
fi

pw=${state%??}; rem=${state#?}; sd=${rem%?}; agh=${state#??}
issues=0
issue() { echo "ISSUE=$1"; issues=$((issues+1)); }
echo "REQUESTED_STATE=$state"
echo "MAIN_CONFIG_FILES=$main_count"
echo "MAIN_TO_AGH=$main_agh"
echo "MAIN_TO_SMARTDNS=$main_sd"
echo "MAIN_OTHER_SERVERS=$main_other"
echo "MAIN_NO_RESOLV=$main_noresolv"
echo "PASSWALL_GENERATED_PRESENT=$pw_present"
echo "PASSWALL_TO_AGH=$pw_agh"
echo "PASSWALL_TO_SPLIT=$pw_split"
echo "ADGUARD_YAML_PRESENT=$agh_present"
echo "ADGUARD_MAIN_TO_SMARTDNS=$agh_primary_sd"
echo "ADGUARD_OTHER_MAIN_UPSTREAMS=$agh_primary_other"
echo "ADGUARD_REVERSE_LOCAL_UPSTREAMS=$agh_primary_reverse"
echo "ADGUARD_FALLBACK_COUNT=$agh_fallback_count"
echo "SMARTDNS_MAIN_PRESENT=$sd_main_present"
echo "SMARTDNS_OTHER_INCLUDE_COUNT=$sd_other_includes"
echo "SMARTDNS_PASSWALL_INCLUDE_MATCHES=$sd_pw_count"
echo "SMARTDNS_TO_XRAY=$sd_proxy"
[ "$main_count" -eq 1 ] || issue MAIN_DNSMASQ_CONFIG_AMBIGUOUS
[ "$main_other" -eq 0 ] || issue MAIN_UNCLASSIFIED_DNS_UPSTREAM
[ "$agh_primary_reverse" -eq 0 ] || issue ADGUARD_REVERSE_LOCAL_REFERENCE
if [ "$agh" = 1 ]; then
    [ "$main_agh" -eq 1 ] || issue SYSTEM_NOT_ROUTED_TO_ADGUARD
    [ "$agh_present" -eq 1 ] || issue ADGUARD_YAML_UNAVAILABLE
    if [ "$sd" = 1 ]; then
        [ "$agh_primary_sd" -eq 1 ] || issue ADGUARD_NOT_ROUTED_TO_SMARTDNS
    else
        [ "$agh_primary_sd" -eq 0 ] || issue ADGUARD_DANGLING_SMARTDNS_UPSTREAM
        [ "$agh_primary_other" -ge 1 ] || issue ADGUARD_NO_INDEPENDENT_UPSTREAM
    fi
else
    [ "$main_agh" -eq 0 ] || issue SYSTEM_DANGLING_ADGUARD_REFERENCE
fi
if [ "$agh" = 0 ] && [ "$sd" = 1 ]; then
    [ "$main_sd" -eq 1 ] || issue SYSTEM_NOT_ROUTED_TO_SMARTDNS
fi
if [ "$sd" = 0 ]; then
    [ "$main_sd" -eq 0 ] || issue SYSTEM_DANGLING_SMARTDNS_REFERENCE
fi
if [ "$agh" = 0 ] && [ "$sd" = 0 ]; then
    [ "$main_noresolv" -eq 0 ] || issue WAN_RESOLV_FALLBACK_NOT_PROVEN
fi
if [ "$pw" = 1 ]; then
    [ "$pw_present" -eq 1 ] || issue PASSWALL_GENERATED_CONFIG_NOT_FOUND
    [ "$agh" = 1 ] || { [ "$pw_agh" -eq 0 ] || issue PASSWALL_DANGLING_ADGUARD_REFERENCE; }
    [ "$sd" = 1 ] || { [ "$pw_split" -eq 0 ] || issue PASSWALL_DANGLING_SPLIT_REFERENCE; }
    if [ "$state" = 101 ]; then
        # Presence of a native upstream is not proof of independent proxy DNS.
        issue PROXY_DNS_ISOLATION_NOT_VERIFIED
    fi
fi
if [ "$sd" = 1 ]; then
    [ "$sd_main_present" -eq 1 ] || issue SMARTDNS_ACTIVE_CONFIG_NOT_FOUND
    if [ "$pw" = 0 ] && [ "$sd_pw_count" -gt 0 ]; then
        issue STALE_PASSWALL_SMARTDNS_INCLUDE
    fi
fi
if [ "$sd" = 0 ] && [ "$agh" = 1 ] && [ "$agh_primary_sd" -gt 0 ]; then
    : # Already reported above; only count once.
fi
if [ "$issues" -eq 0 ]; then
    echo 'REFERENCE_AUDIT=CONSISTENT_NOT_LIVE_PROVEN'
else
    echo "REFERENCE_AUDIT=BLOCKED_ISSUES_$issues"
fi
echo 'CONFIG_CHANGES=NONE'
echo 'SERVICE_RESTARTS=NONE'
[ "$issues" -eq 0 ]
