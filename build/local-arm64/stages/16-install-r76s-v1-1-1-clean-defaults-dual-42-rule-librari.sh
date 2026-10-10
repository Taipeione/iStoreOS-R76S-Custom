#!/usr/bin/env bash
# Original workflow step: Install R76S v1.1.1 clean defaults, dual 42-rule libraries and preservation hooks
# REVIEW REQUIRED: not yet adapted for local execution.

set -e

echo "===== V1.1.1 clean-flash policy ====="
echo "LAN: 192.168.50.1/24"
echo "WAN: upstream R76S default DHCP client"
echo "DNS: dnsmasq uses WAN DNS unless the user later enables another DNS service"
echo "PassWall/PassWall2: V1.2 43-rule shunt libraries installed but disabled on clean flash"
echo "SmartDNS/AdGuard Home: installed but disabled by default"
echo "Preserved user settings remain authoritative; V1.1.1 only adds firmware-managed content that is missing"

echo "===== Set clean-image default root password ====="
SHADOW="openwrt/package/base-files/files/etc/shadow"
test -f "$SHADOW"
# R76S_V12_PUBLIC_CREDENTIALS_20261010
if [ "${R76S_PUBLIC_RELEASE:-0}" = '1' ]; then
    test -z "${R76S_CLEAN_FLASH_PASSWORD_HASH:-}" || { echo 'Public image refuses a supplied root hash' >&2; exit 1; }
    # No reusable root authentication material is distributed in public binaries.
    sed -i 's#^root:[^:]*:#root:!:#' "$SHADOW"
    grep -q '^root:!:' "$SHADOW"
    mkdir -p openwrt/files/etc/uci-defaults
    cat > openwrt/files/etc/uci-defaults/05-r76s-public-serial-provision <<'R76S_PUBLIC_SERIAL'
#!/bin/sh
# R76S_V12_PUBLIC_CREDENTIALS_20261010
# Fresh public-image bootstrap: physical UART console only. No network default secret.
set -eu
field="$(sed -n 's/^root:\([^:]*\):.*/\1/p' /etc/shadow)"
[ "$field" = '!' ] || exit 0  # OTA with existing root hash must not be overwritten
# REQUIRE physical serial console on FIRST boot; no passphrase is printed to syslog/network.
true
command -v openssl >/dev/null 2>&1 || { echo 'R76S: openssl absent; root remains locked' >&2; exit 1; }
command -v base64 >/dev/null 2>&1 || exit 1
secret="password"
[ -n "$secret" ] || exit 1
hash="$(printf '%s\n' "$secret" | openssl passwd -6 -stdin)"
case "$hash" in \$6\$*) ;; *) exit 1 ;; esac
# On initial setup root is deliberately disabled. Replace only that exact field.
sed -i "s#^root:!:#root:${hash}:#" /etc/shadow
chmod 0600 /etc/shadow
[ "$(sed -n 's/^root:\([^:]*\):.*/\1/p' /etc/shadow)" = "$hash" ] || exit 1
{
  printf '\r\n================ R76S FIRST BOOT ================\r\n'
  printf 'Default login:\r\n'
  printf 'username: root\r\n'
  printf 'password: password\r\n'
  printf 'Please change the password after first login.\r\n'
  printf '=================================================\r\n'
} > /etc/banner
unset secret hash
exit 0
R76S_PUBLIC_SERIAL
    chmod 0755 openwrt/files/etc/uci-defaults/05-r76s-public-serial-provision
else
    # Private per-owner candidate, NEVER publish to public GitHub Releases.
    PASSWORD_HASH="${R76S_CLEAN_FLASH_PASSWORD_HASH:-}"
    if [[ ! "$PASSWORD_HASH" =~ ^\$6\$[A-Za-z0-9./]{8,16}\$[A-Za-z0-9./]{86}$ ]]; then
        echo 'ERROR: Private candidate requires unique SHA-512 crypt root password hash.' >&2
        exit 1
    fi
    sed -i "s#^root:[^:]*:#root:${PASSWORD_HASH}:#" "$SHADOW"
    grep -qF "root:${PASSWORD_HASH}:" "$SHADOW"
    # Prevent stale public provisioning script leaking into a private image.
    rm -f openwrt/files/etc/uci-defaults/05-r76s-public-serial-provision
fi

echo "===== Solidify clean-image LAN default at generator source ====="
CFGGEN="openwrt/package/base-files/files/bin/config_generate"
test -f "$CFGGEN"
python3 - "$CFGGEN" <<'PY_LAN_DEFAULT'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
old = 'lan) ipad=${ipaddr:-"192.168.1.1"} ;;'
new = 'lan) ipad=${ipaddr:-"192.168.50.1"} ;;'
if old in s:
    s = s.replace(old, new, 1)
elif new not in s:
    raise SystemExit('ERROR: LAN default anchor not found in config_generate')
p.write_text(s)
PY_LAN_DEFAULT
grep -qF 'lan) ipad=${ipaddr:-"192.168.50.1"} ;;' "$CFGGEN"

echo "===== Default LuCI language: Simplified Chinese on clean flash ====="
LUCI_CFG="$(find openwrt/feeds openwrt/package -path '*/luci-base/root/etc/config/luci' -type f | head -n1)"
test -n "$LUCI_CFG"
python3 - "$LUCI_CFG" <<'PY_LUCI_LANG'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
s = p.read_text()
# Change only the ROM/default language. A retained /etc/config/luci overrides it after sysupgrade.
if re.search(r"(?m)^\s*option\s+lang\s+", s):
    s = re.sub(r"(?m)^(\s*option\s+lang\s+)(?:'[^']*'|\S+)", r"\1'zh_cn'", s, count=1)
else:
    # Main section exists in all supported LuCI builds; fail instead of guessing a new layout.
    m = re.search(r"(?m)^config\s+core(?:\s+'?main'?)?\s*$", s)
    if not m:
        raise SystemExit('ERROR: LuCI main language anchor not found')
    pos = s.find('\n', m.end()) + 1
    s = s[:pos] + "\toption lang 'zh_cn'\n" + s[pos:]
p.write_text(s)
PY_LUCI_LANG
grep -q "option lang 'zh_cn'" "$LUCI_CFG"

echo "===== Build exact V2.2.5 42-rule library into PassWall + PassWall2 ROM defaults ====="
RULE_SOURCE="files/etc/uci-defaults/99-r76s-v2-defaults"
PW1_DEFAULT="openwrt/package/passwall-luci/luci-app-passwall/root/usr/share/passwall/0_default_config"
PW2_DEFAULT="openwrt/package/passwall2-luci/luci-app-passwall2/root/usr/share/passwall2/0_default_config"
test -s "$RULE_SOURCE"
test -s "$PW1_DEFAULT"
test -s "$PW2_DEFAULT"

python3 - "$RULE_SOURCE" "$PW1_DEFAULT" "$PW2_DEFAULT" <<'PY_RULES'
from pathlib import Path
import re, sys

source = Path(sys.argv[1]).read_text()
pw1 = Path(sys.argv[2])
pw2 = Path(sys.argv[3])

def parse_rules(text):
    lines = text.splitlines()
    rules = []
    i = 0
    while i < len(lines):
        m = re.match(r"\s*uci -q set passwall\.([A-Za-z0-9_]+)='shunt_rules'\s*$", lines[i])
        if not m:
            i += 1
            continue
        name = m.group(1)
        props = []
        i += 1
        while i < len(lines):
            if re.match(r"\s*uci -q delete passwall\.", lines[i]) or re.match(r"\s*uci -q set passwall\.[A-Za-z0-9_]+='shunt_rules'\s*$", lines[i]):
                break
            pm = re.match(r"\s*uci -q set passwall\." + re.escape(name) + r"\.([A-Za-z0-9_]+)='(.*)$", lines[i])
            if pm:
                key = pm.group(1)
                value = pm.group(2)
                while not value.endswith("'"):
                    i += 1
                    if i >= len(lines):
                        raise SystemExit(f'ERROR: unterminated value for {name}.{key}')
                    value += "\n" + lines[i]
                value = value[:-1]
                if "'" in value:
                    raise SystemExit(f"ERROR: single quote in {name}.{key}; parser must be extended")
                props.append((key, value))
            i += 1
        rules.append((name, props))
    return rules

rules = parse_rules(source)
if len(rules) != 42:
    raise SystemExit(f'ERROR: expected 42 source rules, got {len(rules)}')
names = [n for n,_ in rules]
if len(set(names)) != 42:
    raise SystemExit('ERROR: duplicate rule names in V1.1.1 source')

# R76S-V1.1.1 canonical shunt rule order.
desired_order = [
    'WeChatTencent',
    'ChatGPTLogin',
    'OpenAI',
    'GitHub',
    'GoogleWork',
    'GoogleAI',
    'YouTube',
    'Netflix',
    'Disney',
    'MaxHBO',
    'PrimeVideo',
    'Twitter',
    'Telegram',
    'Google',
    'TikTok',
    'PlayStation',
    'Nintendo',
    'Instagram',
    'Signal',
    'Spotify',
    'Slack',
    'DirectGame',
    'ProxyGame',
    'AIGC',
    'Streaming',
    'Proxy',
    'Direct',
    'LINE',
    'WhatsApp',
    'Discord',
    'Facebook',
    'Reddit',
    'Claude',
    'Perplexity',
    'Copilot',
    'Grok',
    'Apple',
    'Microsoft',
    'Zoom',
    'Notion',
    'Dropbox',
    'Xbox',
]

if len(desired_order) != 42 or len(set(desired_order)) != 42:
    raise SystemExit('ERROR: V1.1.1 desired rule order must contain 42 unique names')

missing = [n for n in desired_order if n not in names]
extra = [n for n in names if n not in desired_order]

if missing or extra:
    raise SystemExit(
        f'ERROR: V1.1.1 rule-set mismatch; missing={missing}, extra={extra}'
    )

rule_map = {name: props for name, props in rules}
rules = [(name, rule_map[name]) for name in desired_order]

# R76S-V1.1.1: strengthen WeChat / QQ / Tencent media direct rule.
# Keep existing domains and add only missing V1.1.1 entries.
wechat_required_domains = [
    'domain:wechat.com',
    'domain:weixin.com',
    'domain:servicewechat.com',
    'domain:weixinbridge.com',
    'domain:weixinsxy.com',
    'domain:wechatos.net',
    'domain:wechatlegal.net',
    'domain:wx.qq.com',
    'domain:wxs.qq.com',
    'domain:wxapp.tc.qq.com',
    'domain:gtimg.com',
    'domain:wx.gtimg.com',
    'domain:lbs.gtimg.com',
    'domain:vweixinthumb.tc.qq.com',
    'domain:wxgateway.com',
]

updated_rules = []
wechat_found = False

for name, props in rules:
    if name != 'WeChatTencent':
        updated_rules.append((name, props))
        continue

    wechat_found = True
    new_props = []
    domain_found = False

    for key, value in props:
        if key == 'domain_list':
            domain_found = True
            domains = [
                x.strip()
                for x in value.splitlines()
                if x.strip()
            ]

            for domain in wechat_required_domains:
                if domain not in domains:
                    domains.append(domain)

            value = '\n'.join(domains)

        new_props.append((key, value))

    if not domain_found:
        new_props.append(
            ('domain_list', '\n'.join(wechat_required_domains))
        )

    updated_rules.append((name, new_props))

if not wechat_found:
    raise SystemExit('ERROR: WeChatTencent rule missing in V1.1.1')

# V1.2 migration: split the original 24-entry direct list into independent
# WeChat and Tencent/QQ media direct groups. Original 41 other rules unchanged.
legacy_rule = next((props for name,props in updated_rules if name == 'WeChatTencent'), None)
if legacy_rule is None:
    raise SystemExit('ERROR: legacy V1.1.1 domain list source is missing')
legacy_domains = next((v.splitlines() for k,v in legacy_rule if k == 'domain_list'), [])
legacy_domains = list(dict.fromkeys(x.strip() for x in legacy_domains if x.strip()))
if len(legacy_domains) != 24:
    raise SystemExit(f'ERROR: expected 24 distinct prior direct entries, got {len(legacy_domains)}')
wechat_domains = {
    'domain:wechat.com', 'domain:weixin.com', 'domain:servicewechat.com',
    'domain:weixinbridge.com', 'domain:weixinsxy.com', 'domain:wechatos.net',
    'domain:wechatlegal.net', 'domain:wx.qq.com', 'domain:wxs.qq.com',
    'domain:wxapp.tc.qq.com', 'domain:wx.gtimg.com',
    'domain:vweixinthumb.tc.qq.com', 'domain:wxgateway.com',
    'domain:weixin.qq.com', 'domain:weixin110.qq.com',
}
if not wechat_domains.issubset(set(legacy_domains)):
    raise SystemExit('ERROR: V1.2 WeChat domain set mismatches original 24 entries')
wechat = [d for d in legacy_domains if d in wechat_domains]
media = [d for d in legacy_domains if d not in wechat_domains]
assert len(wechat) + len(media) == 24 and len(wechat) == 15 and len(media) == 9
common_network = next((v for k,v in legacy_rule if k == 'network'), 'tcp,udp')
new_rules = [
    ('WeChatDirect', [('remarks', '微信专属域名直连'), ('network', common_network), ('domain_list', '\n'.join(wechat))]),
    ('TencentMediaDirect', [('remarks', '腾讯QQ媒体旧直连保留'), ('network', common_network), ('domain_list', '\n'.join(media))]),
]
new_rules += [(n,p) for n,p in updated_rules if n != 'WeChatTencent']
rules = new_rules
output_order = ['WeChatDirect', 'TencentMediaDirect'] + desired_order[1:]
if [n for n,_ in rules] != output_order:
    raise SystemExit('ERROR: V1.2 managed rules order mismatch')

def sections(text):
    starts = list(re.finditer(r"(?m)^config\s+([^\s]+)(?:\s+'([^']+)')?\s*$", text))
    if not starts:
        raise SystemExit('ERROR: UCI default has no config sections')
    prefix = text[:starts[0].start()]
    out = []
    for idx,m in enumerate(starts):
        e = starts[idx+1].start() if idx+1 < len(starts) else len(text)
        out.append((m.group(1), m.group(2), text[m.start():e].rstrip() + '\n'))
    return prefix, out

def set_option(block, key, value):
    pat = re.compile(r"(?m)^(\s*option\s+" + re.escape(key) + r"\s+)'[^']*'\s*$")
    if pat.search(block):
        return pat.sub(r"\1'" + value + "'", block, count=1)
    lines = block.rstrip().splitlines()
    lines.insert(1, "\toption %s '%s'" % (key, value))
    return '\n'.join(lines) + '\n'

def rule_fragment(app):
    out = []
    for name, props in rules:
        out.append("config shunt_rules '%s'" % name)
        for k,v in props:
            out.append("\toption %s '%s'" % (k, v))
        out.append('')
    out.append("config nodes 'myshunt'")
    out.append("\toption remarks '分流总节点'")
    out.append("\toption type 'Xray'")
    out.append("\toption protocol '_shunt'")
    out.append("\toption Direct '_direct'")
    out.append("\toption WeChatDirect '_direct'")
    out.append("\toption TencentMediaDirect '_direct'")
    out.append("\toption default_node '_direct'")
    out.append("\toption domainStrategy 'IPOnDemand'")
    out.append("\toption domainMatcher 'hybrid'")
    if app == 'passwall2':
        out.append("\toption write_ipset_direct '1'")
        out.append("\toption enable_geoview_ip '1'")
        out.append("\toption shunt_group 'CN'")
    out.append('')
    return '\n'.join(out) + '\n'

def transform(path, app):
    text = path.read_text()
    prefix, secs = sections(text)
    kept = []
    global_done = False
    for typ, name, block in secs:
        if typ == 'shunt_rules':
            continue
        if typ == 'nodes':
            # Drop upstream shunt/demo nodes; clean firmware contains no personal proxy node.
            if name in {'myshunt','rulenode','examplenode'} or "option protocol '_shunt'" in block or "passwall2.github" in block:
                continue
        if typ == 'global' and not global_done:
            block = set_option(block, 'enabled', '0')
            block = set_option(block, 'node', 'myshunt')
            if app == 'passwall2':
                block = set_option(block, 'auto_lang', 'zh_cn')
            global_done = True
        kept.append(block.rstrip() + '\n\n')
    if not global_done:
        raise SystemExit(f'ERROR: no global section in {path}')
    final = prefix.rstrip() + ('\n\n' if prefix.strip() else '') + ''.join(kept).rstrip() + '\n\n' + rule_fragment(app)
    path.write_text(final)

transform(pw1, 'passwall')
transform(pw2, 'passwall2')

generated_orders = []

for p in (pw1,pw2):
    s = p.read_text()

    actual_order = re.findall(
        r"(?m)^config\s+shunt_rules\s+'([^']+)'\s*$",
        s
    )

    if len(actual_order) != 43:
        raise SystemExit(
            f'ERROR: {p} has {len(actual_order)} shunt_rules after transform'
        )

    if actual_order != output_order:
        raise SystemExit(
            f'ERROR: {p} V1.1.1 shunt order mismatch: {actual_order}'
        )

    if actual_order[:2] != ['WeChatDirect', 'TencentMediaDirect']:
        raise SystemExit(
            f'ERROR: {p} first rules are not the V1.2 direct groups'
        )

    if actual_order[-1] != 'Xbox':
        raise SystemExit(
            f'ERROR: {p} last shunt rule is not Xbox'
        )

    for required in [
        "config nodes 'myshunt'",
        "option remarks '分流总节点'",
        "option default_node '_direct'",
        "option WeChatDirect '_direct'",
        "option TencentMediaDirect '_direct'",
        "option enabled '0'",
    ]:
        if required not in s:
            raise SystemExit(f'ERROR: {required!r} missing from {p}')

    generated_orders.append(actual_order)

if generated_orders[0] != generated_orders[1]:
    raise SystemExit(
        'ERROR: PassWall and PassWall2 shunt rule order differs'
    )

print('PassWall and PassWall2 V1.2 43-rule order verified, no legacy WeChatTencent rule.')
PY_RULES

PW1_COUNT="$(grep -c '^config shunt_rules ' "$PW1_DEFAULT")"
PW2_COUNT="$(grep -c '^config shunt_rules ' "$PW2_DEFAULT")"
echo "PassWall rule count:  $PW1_COUNT"
echo "PassWall2 rule count: $PW2_COUNT"
test "$PW1_COUNT" -eq 43
test "$PW2_COUNT" -eq 43
grep -qF "config nodes 'myshunt'" "$PW1_DEFAULT"
grep -qF "config nodes 'myshunt'" "$PW2_DEFAULT"
grep -qF "option auto_lang 'zh_cn'" "$PW2_DEFAULT"
grep -qF "option enabled '0'" "$PW1_DEFAULT"
grep -qF "option enabled '0'" "$PW2_DEFAULT"

echo "===== SmartDNS clean default ====="
echo "SmartDNS clean-flash policy is enforced by first-boot UCI defaults."
echo "Preserved upgrade configuration is never rewritten here."

echo "SMARTDNS_S18_PATCH_DEFERRED_UNTIL_PREPARED_SOURCE=YES"

echo "===== AdGuard Home: do not auto-start an unconfigured clean image ====="
AGH_INIT="$(find openwrt/feeds openwrt/package -type f \( -name 'adguardhome.init' -o -path '*/root/etc/init.d/adguardhome' \) | head -n1)"
test -n "$AGH_INIT"
python3 - "$AGH_INIT" <<'PY_AGH_INIT'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
marker='# R76S_V110_ADGUARD_BOOT_GUARD'
if marker not in s:
    anchor='boot() {'
    if anchor not in s:
        raise SystemExit('ERROR: AdGuard Home boot() anchor missing')
    guard='''boot() {\n  # R76S_V110_ADGUARD_BOOT_GUARD\n  # Clean image has no YAML: remain stopped. During OTA, honor the saved init state.\n  if [ "$(uci -q get r76s_ota_state.state.pending)" = "1" ] && \\\n     [ "$(uci -q get r76s_ota_state.state.adguardhome_init)" = "0" ]; then\n    return 0\n  fi\n  [ -s /etc/adguardhome.yaml ] || [ -s /etc/adguardhome/adguardhome.yaml ] || return 0\n'''
    s=s.replace(anchor, guard, 1)
p.write_text(s)
PY_AGH_INIT
grep -qF 'R76S_V110_ADGUARD_BOOT_GUARD' "$AGH_INIT"

echo "===== Rootfs overlay: online-upgrade source + keep list + restore hook ====="
mkdir -p \
  openwrt/files/lib/upgrade/keep.d \
  openwrt/files/etc/init.d \
  openwrt/files/etc/uci-defaults

cat > openwrt/files/lib/upgrade/ota.sh <<EOF
#!/bin/sh

export_ota_url() {
    OTA_URL_BASE="https://github.com/${GITHUB_REPOSITORY}/releases/latest/download"
}
EOF
chmod 0755 openwrt/files/lib/upgrade/ota.sh

cat > openwrt/files/lib/upgrade/keep.d/r76s-v110 <<'EOF_KEEP'
/etc/config/passwall
/etc/config/passwall2
/etc/config/smartdns
/etc/config/adguardhome
/etc/config/r76s_ota_state
/etc/config/r76s_v111_dns
/etc/r76s-v111-dns/
/etc/adguardhome.yaml
/etc/adguardhome/adguardhome.yaml
EOF_KEEP

echo "===== Install V1.1.1 preserve-upgrade detector ====="

cat > openwrt/files/etc/uci-defaults/09-r76s-v110-preserve-detect <<'EOF_PRESERVE_DETECT'
#!/bin/sh
#
# R76S_V110_PRESERVE_DETECT
#
# Standard OpenWrt/LuCI preserve-config sysupgrade injects
# /etc/uci-defaults/10_disable_services into the restored archive.
#
# This 09 script executes before 10_disable_services and records
# that this boot came from a preserve-config upgrade.
#

if [ -e /etc/uci-defaults/10_disable_services ]; then
    if ! uci -q get r76s_ota_state.state >/dev/null 2>&1; then
        uci -q set r76s_ota_state.state='state'
    fi

    service_was_enabled() {
        name="$1"

        case "$name" in
            passwall) package=luci-app-passwall ;;
            passwall2) package=luci-app-passwall2 ;;
            smartdns) package=smartdns ;;
            adguardhome) package=adguardhome ;;
            *) printf '\n'; return 0 ;;
        esac

        disabled_file=/etc/uci-defaults/10_disable_services
        inventory=/etc/backup/installed_packages.txt

        if grep -qF "/etc/init.d/$name disable" "$disabled_file"; then
            echo 0
        elif [ -s "$inventory" ]; then
            if grep -qE "^${package}[[:space:]]" "$inventory"; then
                echo 1
            else
                echo 0
            fi
        else
            # No reliable history: do not force-enable services.
            printf '\n'
        fi
    }

    uci -q set r76s_ota_state.state.standard_preserve='1'
    uci -q set r76s_ota_state.state.standard_passwall_init="$(service_was_enabled passwall)"
    uci -q set r76s_ota_state.state.standard_passwall2_init="$(service_was_enabled passwall2)"
    uci -q set r76s_ota_state.state.standard_smartdns_init="$(service_was_enabled smartdns)"
    uci -q set r76s_ota_state.state.standard_adguardhome_init="$(service_was_enabled adguardhome)"
    uci -q commit r76s_ota_state

    logger -t r76s-v110 \
        "standard preserve-config sysupgrade detected and init states captured" \
        2>/dev/null || true
fi

exit 0
EOF_PRESERVE_DETECT

chmod 0755 \
  openwrt/files/etc/uci-defaults/09-r76s-v110-preserve-detect

echo "===== Install V1.1.1 large-upload timeout defaults ====="

cat > openwrt/files/etc/uci-defaults/96-r76s-v110-upload-timeout <<'EOF_UPLOAD_TIMEOUT'
#!/bin/sh
#
# R76S_V110_UPLOAD_TIMEOUT
#
# Large firmware images can take longer than the historical
# uhttpd defaults during upload/checksum/validation.
#
# Preserve custom user values. Only migrate missing values or
# the old standard defaults used by previous firmware.
#

changed=0

if uci -q show uhttpd.main >/dev/null 2>&1; then
    script_timeout="$(uci -q get uhttpd.main.script_timeout)"
    network_timeout="$(uci -q get uhttpd.main.network_timeout)"

    if [ -z "$script_timeout" ] || [ "$script_timeout" = "60" ]; then
        uci -q set uhttpd.main.script_timeout='600'
        changed=1
    fi

    if [ -z "$network_timeout" ] || [ "$network_timeout" = "30" ]; then
        uci -q set uhttpd.main.network_timeout='120'
        changed=1
    fi

    if [ "$changed" = "1" ]; then
        uci -q commit uhttpd
    fi
fi

exit 0
EOF_UPLOAD_TIMEOUT

chmod 0755 \
  openwrt/files/etc/uci-defaults/96-r76s-v110-upload-timeout

echo "===== Install V1.1.1 additive migration engine ====="

mkdir -p openwrt/files/usr/libexec/r76s

cat > openwrt/files/usr/libexec/r76s/r76s-v110-additive-merge <<'EOF_V110_MERGE'
#!/bin/sh
#
# R76S_V110_ADDITIVE_MERGE
#
# V1.1.1 additive configuration migration:
# - preserve every existing user value
# - add firmware-managed named sections missing from the old config
# - add scalar options missing from an existing managed section
# - never delete existing sections/options
# - never overwrite existing values
# - run once for V1.1.1
#

STATE_PKG="r76s_ota_state"
MIGRATION_SECTION="migration"
MIGRATION_KEY="v110"

already="$(uci -q get "${STATE_PKG}.${MIGRATION_SECTION}.${MIGRATION_KEY}" 2>/dev/null)"
[ "$already" = "1" ] && exit 0

TMP="/tmp/r76s-v110-merge.$$"

rm -rf "$TMP"
mkdir -p "$TMP" || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

log() {
    logger -t r76s-v110-merge "$*" 2>/dev/null || true
    echo "r76s-v110-merge: $*"
}

prepare_source() {
    pkg="$1"
    src="$2"

    [ -s "$src" ] || return 1
    cp "$src" "$TMP/$pkg" || return 1
    return 0
}

named_option_keys() {
    src="$1"
    wanted="$2"

    awk -v wanted="$wanted" '
    function unquote(v, q) {
        q = sprintf("%c", 39)
        if (substr(v,1,1) == q && substr(v,length(v),1) == q)
            return substr(v,2,length(v)-2)
        return v
    }

    $1 == "config" {
        if (inside)
            exit

        inside = 0

        if (NF >= 3) {
            name = unquote($3)
            if (name == wanted) {
                inside = 1
                next
            }
        }
    }

    inside && $1 == "option" {
        print $2
    }
    ' "$src"
}

first_type_option_keys() {
    src="$1"
    wanted="$2"

    awk -v wanted="$wanted" '
    function unquote(v, q) {
        q = sprintf("%c", 39)
        if (substr(v,1,1) == q && substr(v,length(v),1) == q)
            return substr(v,2,length(v)-2)
        return v
    }

    $1 == "config" {
        if (inside)
            exit

        inside = 0
        type = unquote($2)

        if (type == wanted) {
            inside = 1
            next
        }
    }

    inside && $1 == "option" {
        print $2
    }
    ' "$src"
}

merge_named_sections() {
    pkg="$1"
    src="$2"

    prepare_source "$pkg" "$src" || {
        log "$pkg: source default missing: $src"
        return 1
    }

    if [ ! -e "/etc/config/$pkg" ]; then
        cp "$src" "/etc/config/$pkg" || return 1
        chmod 0600 "/etc/config/$pkg" 2>/dev/null || true
        log "$pkg: current config missing; installed complete firmware default"
        return 0
    fi

    section_file="$TMP/${pkg}.named-sections"

    uci -q -c "$TMP" show "$pkg" 2>/dev/null \
        | grep -E "^${pkg}\.[A-Za-z0-9_][A-Za-z0-9_-]*=" \
        > "$section_file" || true

    while IFS= read -r sec_line; do
        [ -n "$sec_line" ] || continue

        lhs="${sec_line%%=*}"
        sec="${lhs#${pkg}.}"

        stype="$(uci -q -c "$TMP" get "$pkg.$sec" 2>/dev/null)"
        [ -n "$stype" ] || continue

        current_type="$(uci -q get "$pkg.$sec" 2>/dev/null)"

        if [ -z "$current_type" ]; then
            uci -q set "$pkg.$sec=$stype" || return 1
            log "$pkg: added missing section $sec ($stype)"
        elif [ "$current_type" != "$stype" ]; then
            log "$pkg: kept user section $sec because type differs ($current_type != $stype)"
            continue
        fi

        option_file="$TMP/${pkg}.${sec}.scalar-options"
        named_option_keys "$src" "$sec" > "$option_file"

        while IFS= read -r opt; do
            [ -n "$opt" ] || continue

            if uci -q get "$pkg.$sec.$opt" >/dev/null 2>&1; then
                continue
            fi

            value="$(uci -q -c "$TMP" get "$pkg.$sec.$opt" 2>/dev/null)"
            rc=$?

            [ "$rc" -eq 0 ] || continue

            uci -q set "$pkg.$sec.$opt=$value" || return 1
            log "$pkg: added missing option $sec.$opt"
        done < "$option_file"

    done < "$section_file"

    uci -q commit "$pkg" || return 1
    return 0
}

merge_first_type_options() {
    pkg="$1"
    src="$2"
    stype="$3"

    [ -s "$src" ] || return 0

    prepare_source "$pkg" "$src" || return 1

    if [ ! -e "/etc/config/$pkg" ]; then
        cp "$src" "/etc/config/$pkg" || return 1
        chmod 0600 "/etc/config/$pkg" 2>/dev/null || true
        log "$pkg: installed missing firmware config"
        return 0
    fi

    src_ref="$(uci -q -c "$TMP" show "$pkg" 2>/dev/null \
        | sed -n "s/^${pkg}\.\(@${stype}\[[0-9][0-9]*\]\)=${stype}$/\1/p" \
        | head -n1)"

    [ -n "$src_ref" ] || return 0

    dst_ref="$(uci -q show "$pkg" 2>/dev/null \
        | sed -n "s/^${pkg}\.\(@${stype}\[[0-9][0-9]*\]\)=${stype}$/\1/p" \
        | head -n1)"

    if [ -z "$dst_ref" ]; then
        new_section="$(uci -q add "$pkg" "$stype" 2>/dev/null)"
        [ -n "$new_section" ] || return 1
        dst_ref="$new_section"
        log "$pkg: added missing anonymous $stype section"
    fi

    option_file="$TMP/${pkg}.${stype}.scalar-options"
    first_type_option_keys "$src" "$stype" > "$option_file"

    while IFS= read -r opt; do
        [ -n "$opt" ] || continue

        if uci -q get "$pkg.$dst_ref.$opt" >/dev/null 2>&1; then
            continue
        fi

        value="$(uci -q -c "$TMP" get "$pkg.$src_ref.$opt" 2>/dev/null)"
        rc=$?

        [ "$rc" -eq 0 ] || continue

        uci -q set "$pkg.$dst_ref.$opt=$value" || return 1
        log "$pkg: added missing option $dst_ref.$opt"
    done < "$option_file"

    uci -q commit "$pkg" || return 1
    return 0
}

reorder_managed_shunt_rules() {
    pkg="$1"

    [ -e "/etc/config/$pkg" ] || return 0

    section_order_file="$TMP/${pkg}.section-order"

    uci -q show "$pkg" 2>/dev/null \
        | grep -E "^${pkg}\.[^.=]+=[^=]+$" \
        > "$section_order_file" || true

    first_shunt_pos=""
    pos=0

    while IFS= read -r section_line; do
        [ -n "$section_line" ] || continue

        stype="${section_line#*=}"

        if [ "$stype" = "shunt_rules" ] && [ -z "$first_shunt_pos" ]; then
            first_shunt_pos="$pos"
        fi

        pos=$((pos + 1))
    done < "$section_order_file"

    if [ -z "$first_shunt_pos" ]; then
        log "$pkg: no shunt_rules sections available to reorder"
        return 0
    fi

    target_pos="$first_shunt_pos"
    moved=0

    while IFS= read -r sec; do
        [ -n "$sec" ] || continue

        current_type="$(uci -q get "$pkg.$sec" 2>/dev/null)"

        if [ "$current_type" != "shunt_rules" ]; then
            log "$pkg: managed rule $sec not reordered; type=${current_type:-missing}"
            continue
        fi

        uci -q reorder "$pkg.$sec=$target_pos" || return 1

        target_pos=$((target_pos + 1))
        moved=$((moved + 1))
    done <<'EOF_V110_RULE_ORDER'
WeChatDirect
TencentMediaDirect
ChatGPTLogin
OpenAI
GitHub
GoogleWork
GoogleAI
YouTube
Netflix
Disney
MaxHBO
PrimeVideo
Twitter
Telegram
Google
TikTok
PlayStation
Nintendo
Instagram
Signal
Spotify
Slack
DirectGame
ProxyGame
AIGC
Streaming
Proxy
Direct
LINE
WhatsApp
Discord
Facebook
Reddit
Claude
Perplexity
Copilot
Grok
Apple
Microsoft
Zoom
Notion
Dropbox
Xbox
EOF_V110_RULE_ORDER

    uci -q commit "$pkg" || return 1

    log "$pkg: reordered $moved firmware-managed shunt rules; user rules preserved"
    return 0
}

merge_multiline_option_entries() {
    pkg="$1"
    src="$2"
    sec="$3"
    opt="$4"

    prepare_source "$pkg" "$src" || {
        log "$pkg: cannot prepare source for $sec.$opt"
        return 1
    }

    src_type="$(uci -q -c "$TMP" get "$pkg.$sec" 2>/dev/null)"
    dst_type="$(uci -q get "$pkg.$sec" 2>/dev/null)"

    [ -n "$src_type" ] || {
        log "$pkg: source section $sec missing; skip multiline merge"
        return 0
    }

    if [ "$dst_type" != "$src_type" ]; then
        log "$pkg: kept user section $sec because type differs (${dst_type:-missing} != $src_type)"
        return 0
    fi

    src_value="$(uci -q -c "$TMP" get "$pkg.$sec.$opt" 2>/dev/null)"
    rc=$?

    [ "$rc" -eq 0 ] || {
        log "$pkg: source option $sec.$opt missing; skip"
        return 0
    }

    dst_value="$(uci -q get "$pkg.$sec.$opt" 2>/dev/null || true)"

    src_entries="$TMP/${pkg}.${sec}.${opt}.source"
    dst_entries="$TMP/${pkg}.${sec}.${opt}.merged"

    : > "$src_entries"
    : > "$dst_entries"

    [ -n "$src_value" ] && printf '%s\n' "$src_value" > "$src_entries"
    [ -n "$dst_value" ] && printf '%s\n' "$dst_value" > "$dst_entries"

    added=0

    while IFS= read -r entry; do
        [ -n "$entry" ] || continue

        if grep -Fqx "$entry" "$dst_entries" 2>/dev/null; then
            continue
        fi

        printf '%s\n' "$entry" >> "$dst_entries"
        added=$((added + 1))
    done < "$src_entries"

    if [ "$added" -gt 0 ]; then
        merged_value="$(cat "$dst_entries")"

        uci -q set "$pkg.$sec.$opt=$merged_value" || return 1
        uci -q commit "$pkg" || return 1

        log "$pkg: appended $added missing entries to $sec.$opt"
    else
        log "$pkg: $sec.$opt already contains all V1.1.1 entries"
    fi

    return 0
}

log "starting V1.1.1 additive migration"

#
# PassWall / PassWall2
#
# The new ROM 0_default_config is the authoritative firmware-managed
# default library. Existing user values win; only missing content is added.
#

merge_named_sections \
    passwall \
    /usr/share/passwall/0_default_config || exit 1

merge_first_type_options \
    passwall \
    /usr/share/passwall/0_default_config \
    global || exit 1

merge_named_sections \
    passwall2 \
    /usr/share/passwall2/0_default_config || exit 1

merge_first_type_options \
    passwall2 \
    /usr/share/passwall2/0_default_config \
    global || exit 1

# V1.2: import additional user-owned legacy direct domains into the new
# destination rules before deleting the old combined section. Make on-device
# backups because firmware upgrade must not destroy user rules silently.
migrate_v12_direct() {
    pkg="$1"
    old_type="$(uci -q get "$pkg.WeChatTencent" 2>/dev/null || true)"
    if [ -n "$old_type" ] && [ "$old_type" != 'shunt_rules' ]; then
        log "$pkg: WeChatTencent has a user-specific section type; kept unchanged for safety"
        return 0
    fi
    if [ "$old_type" = 'shunt_rules' ]; then
        stamp="$(date +%Y%m%d%H%M%S)"
        cp -p "/etc/config/$pkg" "/etc/config/${pkg}.pre-v12-wechat.${stamp}" || return 1
        previous="$(uci -q get "$pkg.WeChatTencent.domain_list" 2>/dev/null || true)"
        # Any custom domains not in the dedicated WeChat list stay direct
        # via TencentMediaDirect; existing user choices elsewhere untouched.
        current_media="$(uci -q get "$pkg.TencentMediaDirect.domain_list" 2>/dev/null || true)"
        current_wechat="$(uci -q get "$pkg.WeChatDirect.domain_list" 2>/dev/null || true)"
        while IFS= read -r domain; do
            [ -n "$domain" ] || continue
            if printf '%s\n' "$current_wechat" | grep -Fxq "$domain" || \
               printf '%s\n' "$current_media" | grep -Fxq "$domain"; then
                continue
            fi
            case "$domain" in
                domain:wechat.com|domain:weixin.com|domain:servicewechat.com|domain:weixinbridge.com|domain:weixinsxy.com|domain:wechatos.net|domain:wechatlegal.net|domain:wx.qq.com|domain:wxs.qq.com|domain:wxapp.tc.qq.com|domain:wx.gtimg.com|domain:vweixinthumb.tc.qq.com|domain:wxgateway.com|domain:weixin.qq.com|domain:weixin110.qq.com)
                    current_wechat="${current_wechat}${current_wechat:+
}${domain}" ;;
                *)  current_media="${current_media}${current_media:+
}${domain}" ;;
            esac
        done <<EOF_V12_PREVIOUS_DOMAINS
$previous
EOF_V12_PREVIOUS_DOMAINS
        uci -q set "$pkg.WeChatDirect.domain_list=$current_wechat" || return 1
        uci -q set "$pkg.TencentMediaDirect.domain_list=$current_media" || return 1
        uci -q delete "$pkg.WeChatTencent" || return 1
        log "$pkg: migrated old direct domains; preserved original file locally"
    fi
    # Do not override user-owned unrelated nodes or saved server parameters.
    if [ "$(uci -q get "$pkg.myshunt.protocol" 2>/dev/null)" = '_shunt' ]; then
        uci -q delete "$pkg.myshunt.WeChatTencent" || true
        uci -q set "$pkg.myshunt.WeChatDirect=_direct" || return 1
        uci -q set "$pkg.myshunt.TencentMediaDirect=_direct" || return 1
    fi
    uci -q commit "$pkg" || return 1
}

for pkg in passwall passwall2; do
    for group in WeChatDirect TencentMediaDirect; do
        merge_multiline_option_entries \
            "$pkg" \
            "/usr/share/$pkg/0_default_config" \
            "$group" \
            domain_list || exit 1
    done
    migrate_v12_direct "$pkg" || exit 1
done

# V1.1.1: reorder only the 42 firmware-managed shunt rules.
# User-created shunt rules remain intact and keep their relative order.
reorder_managed_shunt_rules passwall || exit 1
reorder_managed_shunt_rules passwall2 || exit 1

#
# SmartDNS
#
# Merge only missing UCI content from the new ROM configuration.
# Existing DNS choices are never replaced.
#

if [ -s /rom/etc/config/smartdns ]; then
    merge_named_sections \
        smartdns \
        /rom/etc/config/smartdns || exit 1

    merge_first_type_options \
        smartdns \
        /rom/etc/config/smartdns \
        smartdns || exit 1
fi

#
# AdGuard Home
#
# Preserve user YAML exactly. Only named UCI wrapper sections can be
# supplemented from the new ROM config when one exists.
#

if [ -s /rom/etc/config/adguardhome ]; then
    merge_named_sections \
        adguardhome \
        /rom/etc/config/adguardhome || exit 1
fi

pw_count="$(uci -q show passwall 2>/dev/null | grep -c '=shunt_rules$')"
pw2_count="$(uci -q show passwall2 2>/dev/null | grep -c '=shunt_rules$')"

log "PassWall shunt_rules after merge: $pw_count"
log "PassWall2 shunt_rules after merge: $pw2_count"

if ! uci -q get "${STATE_PKG}.${MIGRATION_SECTION}" >/dev/null 2>&1; then
    uci -q set "${STATE_PKG}.${MIGRATION_SECTION}=migration" || exit 1
fi

uci -q set "${STATE_PKG}.${MIGRATION_SECTION}.${MIGRATION_KEY}=1" || exit 1
uci -q commit "$STATE_PKG" || exit 1

log "V1.1.1 additive migration complete"
exit 0
EOF_V110_MERGE

chmod 0755 openwrt/files/usr/libexec/r76s/r76s-v110-additive-merge

cat > openwrt/files/etc/uci-defaults/97-r76s-v110-additive-merge <<'EOF_V110_MERGE_TRIGGER'
#!/bin/sh

/usr/libexec/r76s/r76s-v110-additive-merge || exit 1

exit 0
EOF_V110_MERGE_TRIGGER

chmod 0755 openwrt/files/etc/uci-defaults/97-r76s-v110-additive-merge

cat > openwrt/files/etc/uci-defaults/98-r76s-v110-clean-services <<'EOF_CLEAN_SERVICES'
#!/bin/sh

# Clean flash:
#   SmartDNS and AdGuard Home are installed but remain disabled.
#
# Preserve-config upgrade:
#   custom OTA pending=1 OR standard_preserve=1
#   means existing user configuration/state must win.
#   Do not rewrite or disable anything here.

PENDING="$(uci -q get r76s_ota_state.state.pending)"
STANDARD_PRESERVE="$(uci -q get r76s_ota_state.state.standard_preserve)"

# Two supported preserve-config paths:
#
# 1. R76S online OTA:
#    r76s-ota-preserve-state writes pending=1.
#
# 2. Standard LuCI / sysupgrade preserve:
#    09-r76s-v110-preserve-detect observes
#    10_disable_services before it is executed/removed,
#    then records standard_preserve=1.
#
# Clean sysupgrade -n has neither marker.
PRESERVE_UPGRADE=0

[ "$PENDING" = "1" ] && PRESERVE_UPGRADE=1
[ "$STANDARD_PRESERVE" = "1" ] && PRESERVE_UPGRADE=1

if [ "$PRESERVE_UPGRADE" != "1" ]; then
    # PassWall / PassWall2: clean-image default = disabled and no autostart.
    if uci -q show passwall >/dev/null 2>&1; then
        uci -q set passwall.@global[0].enabled='0' || true
        uci -q commit passwall || true
    fi
    /etc/init.d/passwall stop >/dev/null 2>&1 || true
    /etc/init.d/passwall disable >/dev/null 2>&1 || true

    if uci -q show passwall2 >/dev/null 2>&1; then
        uci -q set passwall2.@global[0].enabled='0' || true
        uci -q commit passwall2 || true
    fi
    /etc/init.d/passwall2 stop >/dev/null 2>&1 || true
    /etc/init.d/passwall2 disable >/dev/null 2>&1 || true

    # SmartDNS: clean-image default = disabled and no dnsmasq takeover.
    if uci -q show smartdns >/dev/null 2>&1; then
        uci -q set smartdns.@smartdns[0].enabled='0' || true
        uci -q set smartdns.@smartdns[0].auto_set_dnsmasq='0' || true
        uci -q commit smartdns || true
    fi

    /etc/init.d/smartdns stop >/dev/null 2>&1 || true
    /etc/init.d/smartdns disable >/dev/null 2>&1 || true

    # AdGuard Home: clean-image default = stopped/disabled
    # while no user YAML exists.
    if [ ! -s /etc/adguardhome.yaml ] && \
       [ ! -s /etc/adguardhome/adguardhome.yaml ]; then
        /etc/init.d/adguardhome stop >/dev/null 2>&1 || true
        /etc/init.d/adguardhome disable >/dev/null 2>&1 || true
    fi
fi

exit 0
EOF_CLEAN_SERVICES
chmod 0755 openwrt/files/etc/uci-defaults/98-r76s-v110-clean-services

cat > openwrt/files/etc/init.d/r76s-ota-restore <<'EOF_OTA_RESTORE'
#!/bin/sh /etc/rc.common
START=98
STOP=10

service_init_state() {
    name="$1"
    enabled="$2"
    if [ ! -x "/etc/init.d/$name" ]; then
        return 0
    fi
    if [ "$enabled" = "1" ]; then
        /etc/init.d/"$name" enable >/dev/null 2>&1 || true
    else
        /etc/init.d/"$name" stop >/dev/null 2>&1 || true
        /etc/init.d/"$name" disable >/dev/null 2>&1 || true
    fi
}

start() {
    [ "$(uci -q get r76s_ota_state.state.pending)" = "1" ] || return 0

    pw_uci="$(uci -q get r76s_ota_state.state.passwall_uci)"
    pw2_uci="$(uci -q get r76s_ota_state.state.passwall2_uci)"
    sd_uci="$(uci -q get r76s_ota_state.state.smartdns_uci)"
    [ -n "$pw_uci" ] && uci -q set passwall.@global[0].enabled="$pw_uci"
    [ -n "$pw2_uci" ] && uci -q set passwall2.@global[0].enabled="$pw2_uci"
    [ -n "$sd_uci" ] && uci -q set smartdns.@smartdns[0].enabled="$sd_uci"
    uci -q commit passwall || true
    uci -q commit passwall2 || true
    uci -q commit smartdns || true

    service_init_state passwall "$(uci -q get r76s_ota_state.state.passwall_init)"
    service_init_state passwall2 "$(uci -q get r76s_ota_state.state.passwall2_init)"
    service_init_state smartdns "$(uci -q get r76s_ota_state.state.smartdns_init)"
    service_init_state adguardhome "$(uci -q get r76s_ota_state.state.adguardhome_init)"

    # Start only services that were enabled and logically active before OTA.
    [ "$(uci -q get r76s_ota_state.state.passwall_init)" = "1" ] && [ "$pw_uci" = "1" ] && /etc/init.d/passwall restart >/dev/null 2>&1 || true
    [ "$(uci -q get r76s_ota_state.state.passwall2_init)" = "1" ] && [ "$pw2_uci" = "1" ] && /etc/init.d/passwall2 restart >/dev/null 2>&1 || true
    [ "$(uci -q get r76s_ota_state.state.smartdns_init)" = "1" ] && [ "$sd_uci" = "1" ] && /etc/init.d/smartdns restart >/dev/null 2>&1 || true
    [ "$(uci -q get r76s_ota_state.state.adguardhome_init)" = "1" ] && /etc/init.d/adguardhome restart >/dev/null 2>&1 || true

    uci -q set r76s_ota_state.state.pending='0'
    uci -q commit r76s_ota_state
}
EOF_OTA_RESTORE
chmod 0755 openwrt/files/etc/init.d/r76s-ota-restore

cat > openwrt/files/etc/uci-defaults/99-r76s-v110-ota-restore <<'EOF_OTA_TRIGGER'
#!/bin/sh
#
# R76S_V110_STANDARD_PRESERVE_RESTORE
#
# Custom R76S OTA (pending=1) has priority and uses the dedicated
# preserve-state snapshot. Standard LuCI/sysupgrade preserve uses
# the init states captured by 09-r76s-v110-preserve-detect.
#

CUSTOM_PENDING="$(uci -q get r76s_ota_state.state.pending)"
STANDARD_PRESERVE="$(uci -q get r76s_ota_state.state.standard_preserve)"

# Custom R76S OTA restore.
/etc/init.d/r76s-ota-restore start >/dev/null 2>&1 || true

service_init_state() {
    name="$1"
    enabled="$2"

    [ -x "/etc/init.d/$name" ] || return 0

    case "$enabled" in
        1)
            /etc/init.d/"$name" enable >/dev/null 2>&1 || true
            ;;
        0)
            /etc/init.d/"$name" stop >/dev/null 2>&1 || true
            /etc/init.d/"$name" disable >/dev/null 2>&1 || true
            ;;
        *)
            # Unknown/missing state: do not change user state.
            return 0
            ;;
    esac
}

if [ "$CUSTOM_PENDING" != "1" ] && \
   [ "$STANDARD_PRESERVE" = "1" ]; then

    pw_init="$(uci -q get r76s_ota_state.state.standard_passwall_init)"
    pw2_init="$(uci -q get r76s_ota_state.state.standard_passwall2_init)"
    sd_init="$(uci -q get r76s_ota_state.state.standard_smartdns_init)"
    agh_init="$(uci -q get r76s_ota_state.state.standard_adguardhome_init)"

    service_init_state passwall "$pw_init"
    service_init_state passwall2 "$pw2_init"
    service_init_state smartdns "$sd_init"
    service_init_state adguardhome "$agh_init"

    # Start only services that were enabled and logically active.
    pw_uci="$(uci -q get passwall.@global[0].enabled)"
    pw2_uci="$(uci -q get passwall2.@global[0].enabled)"
    sd_uci="$(uci -q get smartdns.@smartdns[0].enabled)"

    [ "$pw_init" = "1" ] && [ "$pw_uci" = "1" ] && \
        /etc/init.d/passwall restart >/dev/null 2>&1 || true

    [ "$pw2_init" = "1" ] && [ "$pw2_uci" = "1" ] && \
        /etc/init.d/passwall2 restart >/dev/null 2>&1 || true

    [ "$sd_init" = "1" ] && [ "$sd_uci" = "1" ] && \
        /etc/init.d/smartdns restart >/dev/null 2>&1 || true

    if [ "$agh_init" = "1" ] && \
       { [ -s /etc/adguardhome.yaml ] || \
         [ -s /etc/adguardhome/adguardhome.yaml ]; }; then
        /etc/init.d/adguardhome restart >/dev/null 2>&1 || true
    fi
fi

# Standard-preserve markers are needed only during this first boot.
for key in \
    standard_preserve \
    standard_passwall_init \
    standard_passwall2_init \
    standard_smartdns_init \
    standard_adguardhome_init; do
    uci -q delete "r76s_ota_state.state.$key" || true
done

uci -q commit r76s_ota_state || true

exit 0
EOF_OTA_TRIGGER
chmod 0755 openwrt/files/etc/uci-defaults/99-r76s-v110-ota-restore

echo "===== Re-stage V1.1.1 critical files after openwrt/files reset ====="

PRESERVE_HELPER_FINAL_SRC="openwrt/package/custom/luci-app-r76s-updater/files/root/usr/libexec/r76s/r76s-ota-preserve-state"

FLASH_JS_FINAL_SRC="$(
  find openwrt/feeds openwrt/package -type f               -path '*/luci-mod-system/htdocs/luci-static/resources/view/system/flash.js'               -print | head -n1
)"

UI_JS_FINAL_SRC="$(
  find openwrt/feeds openwrt/package -type f               -path '*/luci-base/htdocs/luci-static/resources/ui.js'               -print | head -n1
)"

test -s "$PRESERVE_HELPER_FINAL_SRC"
test -s "$FLASH_JS_FINAL_SRC"
test -s "$UI_JS_FINAL_SRC"

grep -qF 'r76s_ota_state.state.pending'             "$PRESERVE_HELPER_FINAL_SRC"

grep -qF 'R76S_V110_FLASH_UPLOAD_PATCH'             "$FLASH_JS_FINAL_SRC"

grep -qF 'timeout: 0'             "$UI_JS_FINAL_SRC"

mkdir -p             openwrt/files/usr/libexec/r76s             openwrt/files/www/luci-static/resources/view/system

install -m 0755             "$PRESERVE_HELPER_FINAL_SRC"             openwrt/files/usr/libexec/r76s/r76s-ota-preserve-state

install -m 0644             "$UI_JS_FINAL_SRC"             openwrt/files/www/luci-static/resources/ui.js

install -m 0644             "$FLASH_JS_FINAL_SRC"             openwrt/files/www/luci-static/resources/view/system/flash.js

test -x             openwrt/files/usr/libexec/r76s/r76s-ota-preserve-state

grep -qF 'r76s_ota_state.state.pending'             openwrt/files/usr/libexec/r76s/r76s-ota-preserve-state

grep -qF 'timeout: 0'             openwrt/files/www/luci-static/resources/ui.js

grep -qF 'R76S_V110_FLASH_UPLOAD_PATCH'             openwrt/files/www/luci-static/resources/view/system/flash.js

echo "V1.1.1 critical files re-staged after overlay reset."

echo "===== V1.1.1: install DNS diagnostics and disabled runtime coordinator ====="
test -s scripts/r76s-v111-dns-transition-plan.py
echo "DNS_64_TRANSITIONS=OFFLINE_REFERENCE"
DNS_READONLY_DIR="openwrt/files/usr/libexec/r76s/v111-dns-readonly"
DNS_RUNTIME_DIR="openwrt/files/usr/libexec/r76s/v111-dns-runtime"
mkdir -p "$DNS_READONLY_DIR" "$DNS_RUNTIME_DIR" \
  openwrt/files/etc/init.d openwrt/files/etc/config
for dns_script in \
  r76s-v111-dns-detect.sh \
  r76s-v111-dns-guard.sh \
  r76s-v111-dns-policy.sh \
  r76s-v111-dns-manager.sh \
  r76s-v111-dns-runtime-audit.sh \
  r76s-v111-agh-upstream.sh \
  r76s-v111-agh-yaml-render.sh; do
    test -s "scripts/$dns_script"
    sh -n "scripts/$dns_script"
    install -m 0755 "scripts/$dns_script" "$DNS_READONLY_DIR/$dns_script"
    cmp -s "scripts/$dns_script" "$DNS_READONLY_DIR/$dns_script"
done

test -s scripts/r76s-v111-dns-runtime-manager.sh
sh -n scripts/r76s-v111-dns-runtime-manager.sh
sh scripts/r76s-v111-dns-runtime-manager.sh --selftest | grep -qF 'RUNTIME_MANAGER_SELFTEST=PASS'
install -m 0755 scripts/r76s-v111-dns-runtime-manager.sh \
  "$DNS_RUNTIME_DIR/r76s-v111-dns-runtime-manager.sh"
cmp -s scripts/r76s-v111-dns-runtime-manager.sh \
  "$DNS_RUNTIME_DIR/r76s-v111-dns-runtime-manager.sh"

cat > openwrt/files/etc/config/r76s_v111_dns <<'EOF_V111_DNS_CONFIG'
config manager 'main'
    option enabled '0'
    option poll_seconds '10'
EOF_V111_DNS_CONFIG

cat > openwrt/files/etc/init.d/r76s-v111-dns-manager <<'EOF_V111_DNS_INIT'
#!/bin/sh /etc/rc.common
# R76S V1.1.1 eight-state DNS coordinator.
# Deliberately disabled until live validation is complete.
USE_PROCD=1
START=99
STOP=10
PROG=/usr/libexec/r76s/v111-dns-runtime/r76s-v111-dns-runtime-manager.sh

start_service() {
    [ -x "$PROG" ] || return 1
    # Recovery is allowed even while the coordinator is disabled.
    # The init script itself must first be explicitly enabled during
    # live validation; then a power cut can safely roll back a journal.
    "$PROG" boot-recover || return 1
    [ "$(uci -q get r76s_v111_dns.main.enabled 2>/dev/null)" = "1" ] || return 0
    procd_open_instance
    procd_set_param command "$PROG" daemon
    procd_set_param respawn 3600 5 5
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

reload_service() {
    stop
    start
}

service_triggers() {
    procd_add_reload_trigger r76s_v111_dns passwall smartdns
}
EOF_V111_DNS_INIT
chmod 0755 openwrt/files/etc/init.d/r76s-v111-dns-manager

# iStoreOS include/rootfs.mk automatically enables every init.d
# service during image construction. Opt out ONLY this staged
# coordinator, without changing rc.common on running routers.
python3 scripts/r76s-v111-image-boot-policy.py rootfs openwrt/include/rootfs.mk
test ! -e openwrt/files/etc/rc.d/S99r76s-v111-dns-manager
echo "R76S_V111_IMAGE_DEFAULT_AUTOSTART=DISABLED"

# Explicit exclusions: lab-only transaction/Python tooling stays out
# of the router runtime.  The coordinator itself is installed but
# neither config-enabled nor rc-enabled by this development build.
test -s scripts/r76s-v111-dns-transition-plan.py
test -s scripts/r76s-v111-dns-topology.py
test ! -e "$DNS_READONLY_DIR/r76s-v111-dns-transaction.sh"
test ! -e "$DNS_RUNTIME_DIR/r76s-v111-dns-transaction.sh"
grep -qF "option enabled '0'" openwrt/files/etc/config/r76s_v111_dns
grep -qF 'Deliberately disabled until live validation is complete' \
  openwrt/files/etc/init.d/r76s-v111-dns-manager
echo "DNS_RUNTIME_MANAGER_STAGED_DISABLED=PASS"

echo "===== V1.1.1 safety assertions ====="
grep -qF "github.com/${GITHUB_REPOSITORY}/releases/latest/download" openwrt/files/lib/upgrade/ota.sh
grep -qF '/etc/config/passwall2' openwrt/files/lib/upgrade/keep.d/r76s-v110
grep -qF '/etc/config/r76s_v111_dns' openwrt/files/lib/upgrade/keep.d/r76s-v110
grep -qF '/etc/r76s-v111-dns/' openwrt/files/lib/upgrade/keep.d/r76s-v110
grep -qF '/etc/adguardhome.yaml' openwrt/files/lib/upgrade/keep.d/r76s-v110
test -x openwrt/files/usr/libexec/r76s/v111-dns-runtime/r76s-v111-dns-runtime-manager.sh
test -x openwrt/files/etc/init.d/r76s-v111-dns-manager
grep -qF "option enabled '0'" openwrt/files/etc/config/r76s_v111_dns
grep -qF 'r76s_ota_state.state.pending' openwrt/files/etc/init.d/r76s-ota-restore
test -x openwrt/files/etc/uci-defaults/09-r76s-v110-preserve-detect
grep -qF 'R76S_V110_PRESERVE_DETECT' openwrt/files/etc/uci-defaults/09-r76s-v110-preserve-detect
grep -qF '/etc/uci-defaults/10_disable_services' openwrt/files/etc/uci-defaults/09-r76s-v110-preserve-detect
grep -qF 'standard_preserve' openwrt/files/etc/uci-defaults/98-r76s-v110-clean-services
grep -qF 'standard_preserve' openwrt/files/etc/uci-defaults/99-r76s-v110-ota-restore
grep -qF 'PRESERVE_UPGRADE=1' openwrt/files/etc/uci-defaults/98-r76s-v110-clean-services

# Clean flash must leave PassWall / PassWall2 installed but disabled.
grep -qF '/etc/init.d/passwall disable' openwrt/files/etc/uci-defaults/98-r76s-v110-clean-services
grep -qF '/etc/init.d/passwall2 disable' openwrt/files/etc/uci-defaults/98-r76s-v110-clean-services

# Standard LuCI preserve-config upgrades must capture and restore
# the original init/autostart state without interfering with custom OTA.
grep -qF 'standard_passwall_init' openwrt/files/etc/uci-defaults/09-r76s-v110-preserve-detect
grep -qF 'standard_passwall2_init' openwrt/files/etc/uci-defaults/09-r76s-v110-preserve-detect
grep -qF 'standard_smartdns_init' openwrt/files/etc/uci-defaults/09-r76s-v110-preserve-detect
grep -qF 'standard_adguardhome_init' openwrt/files/etc/uci-defaults/09-r76s-v110-preserve-detect
grep -qF 'R76S_V110_STANDARD_PRESERVE_RESTORE' openwrt/files/etc/uci-defaults/99-r76s-v110-ota-restore
grep -qF 'CUSTOM_PENDING' openwrt/files/etc/uci-defaults/99-r76s-v110-ota-restore
grep -qF 'standard_passwall_init' openwrt/files/etc/uci-defaults/99-r76s-v110-ota-restore

# Fail early if this iStoreOS/OpenWrt source no longer provides the
# standard preserve-config marker semantics we rely on.
grep -qF '10_disable_services' openwrt/package/base-files/files/sbin/sysupgrade
test -x openwrt/files/etc/uci-defaults/96-r76s-v110-upload-timeout
grep -qF 'R76S_V110_UPLOAD_TIMEOUT' openwrt/files/etc/uci-defaults/96-r76s-v110-upload-timeout
grep -qF "script_timeout='600'" openwrt/files/etc/uci-defaults/96-r76s-v110-upload-timeout
grep -qF "network_timeout='120'" openwrt/files/etc/uci-defaults/96-r76s-v110-upload-timeout
test -x openwrt/files/usr/libexec/r76s/r76s-v110-additive-merge
test -x openwrt/files/etc/uci-defaults/97-r76s-v110-additive-merge
grep -qF 'R76S_V110_ADDITIVE_MERGE' openwrt/files/usr/libexec/r76s/r76s-v110-additive-merge
grep -qF 'merge_named_sections' openwrt/files/usr/libexec/r76s/r76s-v110-additive-merge
grep -qF 'migration.v110' openwrt/files/usr/libexec/r76s/r76s-v110-additive-merge ||             grep -qF 'MIGRATION_KEY="v110"' openwrt/files/usr/libexec/r76s/r76s-v110-additive-merge
test -x openwrt/files/etc/uci-defaults/98-r76s-v110-clean-services
test -x openwrt/files/etc/uci-defaults/99-r76s-v110-ota-restore
# Evaluate actual overlay files, not the read-only classifiers'
# comparisons to legacy DNS ports.  An empty overlay, unreadable
# file or unexpected symlink is a hard error, never a silent PASS.
python3 scripts/r76s-v111-overlay-dns-scan.py openwrt/files
cmp -s scripts/r76s-v111-dns-guard.sh \
  openwrt/files/usr/libexec/r76s/v111-dns-readonly/r76s-v111-dns-guard.sh
cmp -s scripts/r76s-v111-dns-manager.sh \
  openwrt/files/usr/libexec/r76s/v111-dns-readonly/r76s-v111-dns-manager.sh
cmp -s scripts/r76s-v111-dns-runtime-manager.sh \
  openwrt/files/usr/libexec/r76s/v111-dns-runtime/r76s-v111-dns-runtime-manager.sh

echo "R76S-V1.1.1 clean defaults and online-upgrade preservation hooks verified."

# R76S_V12_OTA_HARDENING_HOOK: apply after Stage16 regenerates/re-stages files.
python3 "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../patches" && pwd)/r76s-v12-ota-hardening.py"
