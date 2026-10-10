#!/usr/bin/env bash
# Original workflow step: Verify PassWall source defaults
# REVIEW REQUIRED: not yet adapted for local execution.

cd openwrt

PASSWALL_DIR="package/passwall-luci/luci-app-passwall"
PASSWALL_MK="$PASSWALL_DIR/Makefile"
PASSWALL_DEFAULT="$PASSWALL_DIR/root/usr/share/passwall/0_default_config"

test -f "$PASSWALL_MK"
test -f "$PASSWALL_DEFAULT"

grep -q 'Nftables Transparent Proxy' "$PASSWALL_MK"
grep -q 'PACKAGE_kmod-nft-socket' "$PASSWALL_MK"
grep -q 'PACKAGE_kmod-nft-tproxy' "$PASSWALL_MK"
grep -q 'PACKAGE_$(PKG_NAME)_INCLUDE_Xray' "$PASSWALL_MK"
grep -q 'PACKAGE_$(PKG_NAME)_INCLUDE_SingBox' "$PASSWALL_MK"

# Upstream package remains disabled in ROM; v1.1.1 first-boot defaults
# enable only the verified node-free shunt framework.
grep -q "option enabled '0'" "$PASSWALL_DEFAULT"

PASSWALL_APP="$PASSWALL_DIR/root/usr/share/passwall/app.sh"
test -f "$PASSWALL_APP"

# The runtime DNS guard uses this stable anchor when a PassWall App
# Update replaces app.sh. Fail before compilation if upstream changes
# the layout instead of shipping an unpatchable image.
grep -qF \
  'uci -q delete dhcp.@dnsmasq[0].min_cache_ttl' \
  "$PASSWALL_APP"

# R76S_V111_UNVERIFIED_AGH_CONDITIONAL_PATCH_DISABLED
# Do not inject AGH into PassWall-generated dnsmasq until the
# live upstream app.sh, dynamic teardown, and loop boundaries are tested.
# Existing V1.1 PassWall behavior is left intact.
echo "V1.1.1 provisional: unsafe AdGuard auto-injection disabled"
echo "===== V1.1.1: patch PassWall SmartDNS direct-group mapping ====="

PW_SMARTDNS_HELPER="$PASSWALL_DIR/root/usr/share/passwall/helper_smartdns_add.lua"
test -f "$PW_SMARTDNS_HELPER"

# R76S_V111_PASSWALL_GROUP_SCOPED_GUARD
# Patch only psw-shunt-direct, never the adjacent proxy mapping.
# Already-correct upstream files are accepted without rewriting groups.
python3 ../scripts/r76s-v111-passwall-groups.py --patch "$PW_SMARTDNS_HELPER"
python3 ../scripts/r76s-v111-passwall-groups.py --verify "$PW_SMARTDNS_HELPER"

# R76S_V111_PASSWALL_DNS_GENERATOR_GUARD
# Keep upstream DNS generator UCI behavior intact; patch ONLY an
# exactly recognized legacy unconditional AGH 3053 injection.
# No live DNS takeover or shutdown callback is installed.
PW_DNSMASQ_HELPER="$PASSWALL_DIR/root/usr/share/passwall/helper_dnsmasq.lua"
test -s "$PW_DNSMASQ_HELPER"
python3 ../scripts/r76s-v111-passwall-dns-generator.py --patch "$PASSWALL_APP" "$PW_DNSMASQ_HELPER"
python3 ../scripts/r76s-v111-passwall-dns-generator.py --verify "$PASSWALL_APP" "$PW_DNSMASQ_HELPER"

test -f package/diy/luci-app-ota/Makefile
