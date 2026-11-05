#!/bin/sh
set -eu

# The pinned PassWall packages feed currently references a removed GitHub
# release asset for dns2socks. OpenWrt's @SF downloader resolves the original
# SourceForge project archive, whose hash and archive layout remain unchanged.
target="${1:-package/feeds/passwall_packages/dns2socks/Makefile}"

test -f "$target"
grep -q '^PKG_SOURCE:=SourceCode\.zip$' "$target"
grep -q '^PKG_HASH:=406b5003523577d39da66767adfe54f7af9b701374363729386f32f6a3a995f4$' "$target"

if grep -q '^PKG_SOURCE_URL:=https://github.com/Openwrt-Passwall/openwrt-passwall-packages/releases/download/dns2socks$' "$target"; then
    temporary="${target}.r76s-tmp"
    awk '{ if ($0 == "PKG_SOURCE_URL:=https://github.com/Openwrt-Passwall/openwrt-passwall-packages/releases/download/dns2socks") print "PKG_SOURCE_URL:=@SF/dns2socks"; else print }' "$target" > "$temporary"
    mv "$temporary" "$target"
fi

grep -q '^PKG_SOURCE_URL:=@SF/dns2socks$' "$target"
printf '%s\n' "DNS2SOCKS_SOURCE=PASS url=@SF/dns2socks hash=406b5003523577d39da66767adfe54f7af9b701374363729386f32f6a3a995f"
