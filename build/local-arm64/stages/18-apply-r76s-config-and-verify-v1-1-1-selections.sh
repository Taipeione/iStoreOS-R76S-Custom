#!/usr/bin/env bash
# Original workflow step: Apply R76S config and verify v1.1.1 selections
# REVIEW REQUIRED: not yet adapted for local execution.

cd openwrt

cp ../config/R76S.config .config
# The runner host architecture determines bootstrap, not the R76S target.
case "$(uname -m)" in
  x86_64) GO_BOOTSTRAP="$(go env GOROOT)" ;;
  aarch64|arm64) GO_BOOTSTRAP=/home/builder/work/tools/go126-module-cache/golang.org/toolchain@v0.0.1-go1.26.6.linux-arm64 ;;
  *) echo "ERROR: Unsupported Go bootstrap host" >&2; exit 1 ;;
esac
test -x "$GO_BOOTSTRAP/bin/go"
test "$("$GO_BOOTSTRAP/bin/go" env GOVERSION)" = go1.26.6
sed -i '/^CONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT=/d' .config
printf 'CONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT="%s"\n' "$GO_BOOTSTRAP" >> .config

echo "===== Input R76S.config PassWall selections ====="
grep -E \
  '^CONFIG_PACKAGE_(luci-app-passwall|chinadns-ng|xray-core|sing-box|kmod-nft-(socket|tproxy)|firewall4)' \
  .config \
  || true

# The repository config is the single source of truth.
# Do not call ./scripts/config here: in OpenWrt this path is a
# directory containing Kconfig helper sources, not an executable.
for required in \
  'CONFIG_PACKAGE_firewall4=y' \
  'CONFIG_PACKAGE_dnsmasq-full=y' \
  'CONFIG_PACKAGE_luci-app-ota=y' \
  'CONFIG_PACKAGE_luci-app-package-manager=y' \
  'CONFIG_PACKAGE_luci-app-r76s-updater=y' \
  'CONFIG_PACKAGE_quickstart=y' \
  'CONFIG_PACKAGE_luci-app-quickstart=y' \
  'CONFIG_PACKAGE_luci-i18n-quickstart-zh-cn=y' \
  'CONFIG_PACKAGE_kmod-tun=y' \
  'CONFIG_PACKAGE_luci-app-ddns=y' \
  'CONFIG_PACKAGE_ddns-scripts=y' \
  'CONFIG_PACKAGE_wireguard-tools=y' \
  'CONFIG_PACKAGE_kmod-wireguard=y' \
  'CONFIG_PACKAGE_luci-proto-wireguard=y' \
  'CONFIG_PACKAGE_luci-app-passwall=y' \
  'CONFIG_PACKAGE_luci-app-passwall2=y' \
  'CONFIG_PACKAGE_luci-i18n-passwall2-zh-cn=y' \
  'CONFIG_PACKAGE_luci-app-passwall_Nftables_Transparent_Proxy=y' \
  'CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Geoview=y' \
  'CONFIG_PACKAGE_luci-app-passwall_INCLUDE_SingBox=y' \
  'CONFIG_PACKAGE_luci-app-passwall_INCLUDE_V2ray_Geodata=y' \
  'CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Xray=y' \
  'CONFIG_PACKAGE_chinadns-ng=y' \
  'CONFIG_PACKAGE_kmod-nft-socket=y' \
  'CONFIG_PACKAGE_kmod-nft-tproxy=y'; do
  if ! grep -qxF "$required" .config; then
    echo "ERROR: Required v1.1.1 selection missing from config/R76S.config:"
    echo "$required"
    exit 1
  fi
done

make defconfig

# Do not let PassWall2 defaults silently bring back a multi-hour Rust build.
grep -qxF '# CONFIG_PACKAGE_shadowsocks-rust-sslocal is not set' .config
grep -qxF '# CONFIG_PACKAGE_shadowsocks-rust-ssserver is not set' .config

echo
echo "===== Final PassWall selections after make defconfig ====="
grep -E \
  '^CONFIG_PACKAGE_(luci-app-passwall|chinadns-ng|xray-core|sing-box|kmod-nft-(socket|tproxy)|firewall4)' \
  .config \
  || true

if ! grep -qxF 'CONFIG_PACKAGE_luci-app-passwall=y' .config; then
  echo "ERROR: luci-app-passwall was removed by make defconfig."
  echo
  echo "===== PassWall package definition ====="
  sed -n '1,190p' package/passwall-luci/luci-app-passwall/Makefile 2>/dev/null || true
  echo
  echo "===== Kconfig block for luci-app-passwall ====="
  LINE=$(
    grep -n '^config PACKAGE_luci-app-passwall$' \
      tmp/.config-package.in 2>/dev/null \
      | head -n 1 \
      | cut -d: -f1
  )
  if [ -n "$LINE" ]; then
    START=$((LINE > 12 ? LINE - 12 : 1))
    END=$((LINE + 35))
    sed -n "${START},${END}p" tmp/.config-package.in
  else
    echo "PACKAGE_luci-app-passwall symbol was not generated."
    echo
  echo "===== Direct dependency symbols ====="
  grep -E \
    '^(config PACKAGE_(coreutils|coreutils-base64|coreutils-nohup|coreutils-timeout|curl|chinadns-ng|dns2socks|dnsmasq-full|ip-full|libuci-lua|lua|luci-compat|luci-lib-jsonc|microsocks|resolveip|tcping|lyaml)|# CONFIG_PACKAGE_(coreutils|coreutils-base64|coreutils-nohup|coreutils-timeout|curl|chinadns-ng|dns2socks|dnsmasq-full|ip-full|libuci-lua|lua|luci-compat|luci-lib-jsonc|microsocks|resolveip|tcping|lyaml))' \
    .config tmp/.config-package.in 2>/dev/null \
    | head -n 250 \
    || true
  fi
  exit 1
fi
