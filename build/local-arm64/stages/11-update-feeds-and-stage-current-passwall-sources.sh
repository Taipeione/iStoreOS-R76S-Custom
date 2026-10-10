#!/usr/bin/env bash
# Original workflow step: Update feeds and stage current PassWall sources
# REVIEW REQUIRED: not yet adapted for local execution.

cd openwrt

if [ ! -s feeds/feeds.index ] && [ ! -s feeds/packages.index ]; then
  ./scripts/feeds update -a
fi
./scripts/feeds install -a

echo "===== V1.1.1: patch LuCI large firmware upload ====="

FLASH_JS="$(find feeds package -type f \
  -path '*/luci-mod-system/htdocs/luci-static/resources/view/system/flash.js' \
  -print | head -n1)"

UI_JS="$(find feeds package -type f \
  -path '*/luci-base/htdocs/luci-static/resources/ui.js' \
  -print | head -n1)"

echo "FLASH_JS=$FLASH_JS"
echo "UI_JS=$UI_JS"

test -s "$FLASH_JS"
test -s "$UI_JS"

python3 - "$UI_JS" "$FLASH_JS" <<'PY_FLASH_UPLOAD'
from pathlib import Path
import sys

ui_path = Path(sys.argv[1])
flash_path = Path(sys.argv[2])

ui = ui_path.read_text()
flash = flash_path.read_text()

#
# 1. LuCI upload request must have no client-side total timeout.
#
pos = ui.find("cgi-upload")

if pos < 0:
    raise SystemExit("ERROR: cgi-upload not found in ui.js")

region_start = max(0, pos - 500)
region_end = min(len(ui), pos + 1600)
region = ui[region_start:region_end]

if "timeout: 0" not in region:
    req_start = ui.rfind("request.post(", 0, pos)

    if req_start < 0:
        raise SystemExit(
            "ERROR: request.post for cgi-upload not found"
        )

    progress_pos = ui.find("progress", pos)

    if progress_pos < 0 or progress_pos > pos + 1600:
        raise SystemExit(
            "ERROR: cgi-upload progress option not found"
        )

    line_start = ui.rfind("\n", 0, progress_pos) + 1
    indent = ui[line_start:progress_pos]

    ui = (
        ui[:progress_pos]
        + "timeout: 0,\n"
        + indent
        + ui[progress_pos:]
    )

#
# 2. Standard firmware page must still upload through ui.uploadFile.
#
if "/tmp/firmware.bin" not in flash or "ui.uploadFile" not in flash:
    raise SystemExit(
        "ERROR: standard LuCI sysupgrade upload anchor missing"
    )

#
# 3. Explicitly explain preserve vs clean-flash semantics.
#
keep_anchor = (
    "opts.keep[0], ' ', "
    "_('Keep settings and retain the current configuration')"
)

if "清除全部配置（干净刷机）" not in flash:
    if keep_anchor not in flash:
        raise SystemExit(
            "ERROR: keep-settings label anchor not found"
        )

    flash = flash.replace(
        keep_anchor,
        keep_anchor
        + ", E('br'), "
        + "E('small', "
        + "{ 'style': 'opacity:.75' }, "
        + "'勾选：保留当前配置；"
        + "取消勾选：清除全部配置（干净刷机）')",
        1
    )

#
# 4. Preserve-config stays enabled by default.
#
if "opts.keep[0].checked = true;" not in flash:
    raise SystemExit(
        "ERROR: LuCI no longer defaults to keep settings"
    )

#
# 5. Our clean image comes back on 192.168.50.1, not 192.168.1.1.
#
flash = flash.replace(
    "'192.168.1.1'",
    "'192.168.50.1'"
)

if "192.168.1.1" in flash:
    raise SystemExit(
        "ERROR: stale 192.168.1.1 reconnect target remains"
    )

#
# 6. Internal patch marker.
#
if "R76S_V110_FLASH_UPLOAD_PATCH" not in flash:
    strict = "'use strict';"

    if strict not in flash:
        raise SystemExit(
            "ERROR: flash.js use-strict anchor missing"
        )

    flash = flash.replace(
        strict,
        strict
        + "\n\n"
        + "// R76S_V110_FLASH_UPLOAD_PATCH\n",
        1
    )

ui_path.write_text(ui)
flash_path.write_text(flash)

print("LuCI large firmware upload patch applied.")
PY_FLASH_UPLOAD

grep -qF 'timeout: 0' "$UI_JS"
grep -qF 'R76S_V110_FLASH_UPLOAD_PATCH' "$FLASH_JS"
grep -qF '清除全部配置（干净刷机）' "$FLASH_JS"
grep -qF 'opts.keep[0].checked = true;' "$FLASH_JS"
grep -qF '192.168.50.1' "$FLASH_JS"

! grep -qF '192.168.1.1' "$FLASH_JS"

echo "LuCI manual firmware upload patch verified."

echo "===== Stage patched LuCI files into final image overlay ====="
mkdir -p files/www/luci-static/resources/view/system
install -m 0644 "$UI_JS" files/www/luci-static/resources/ui.js
install -m 0644 "$FLASH_JS" files/www/luci-static/resources/view/system/flash.js
grep -qF 'timeout: 0' files/www/luci-static/resources/ui.js
grep -qF 'R76S_V110_FLASH_UPLOAD_PATCH' files/www/luci-static/resources/view/system/flash.js
echo "LuCI final-image overlay staged."


echo "===== Refresh Go toolchain for current PassWall cores ====="
# R76S_V12_GO_FEED_SAFE_REFRESH
# The official packages feed contains lang/golang as a SUBDIRECTORY,
# not a standalone Git checkout. Never delete that source tree.
GO_DIR="feeds/packages/lang/golang"
GO_PARENT="feeds/packages/lang"
GO_URL="https://github.com/sbwml/packages_lang_golang.git"
GO_BACKUP_ROOT="/home/builder/work/.r76s-candidate/go-feed-backups"
GO_STAGING_ROOT="/home/builder/work/.r76s-candidate/go-feed-staging"

validate_go() {
  local dir="$1"
  test -s "$dir/golang/Makefile" &&
  test -s "$dir/golang-package.mk" &&
  test -s "$dir/golang-build.sh"
}

if [ -L "$GO_DIR" ]; then
  echo "ERROR: Go source path is a symlink; refusing to replace it" >&2
  exit 1
fi

if [ -d "$GO_DIR/.git" ]; then
  echo "GO_FEED_CACHE=STANDALONE_GIT"
  actual_origin="$(git -C "$GO_DIR" remote get-url origin)"
  case "$actual_origin" in
    https://github.com/sbwml/packages_lang_golang|https://github.com/sbwml/packages_lang_golang.git)
      ;;
    *) echo "ERROR: Existing Go source has unexpected origin: $actual_origin" >&2; exit 1;;
  esac
  [ "$(git -C "$GO_DIR" branch --show-current)" = '26.x' ] || {
    echo 'ERROR: Existing Go checkout is not on branch 26.x' >&2
    exit 1
  }
  validate_go "$GO_DIR" || { echo 'ERROR: Existing Go checkout incomplete' >&2; exit 1; }
elif [ -e "$GO_DIR" ] && [ ! -d "$GO_DIR" ]; then
  echo 'ERROR: Go source is not a directory' >&2
  exit 1
else
  if [ -d "$GO_DIR" ]; then
    validate_go "$GO_DIR" || {
      echo 'ERROR: Existing packages feed Go source is incomplete; refusing replacement' >&2
      exit 1
    }
  fi

  mkdir -p "$GO_BACKUP_ROOT" "$GO_STAGING_ROOT"
  chmod 0700 "$GO_BACKUP_ROOT" "$GO_STAGING_ROOT"
  NEW_GO=""
  for attempt in 1 2 3; do
    # Unique new destination; never reuse or remove other sources.
    NEW_GO="$GO_STAGING_ROOT/clone-$(date -u +%Y%m%dT%H%M%S)-$$-$attempt"
    echo "Go 26.x clone attempt $attempt/3"
    if git -c http.version=HTTP/1.1 clone \
      --filter=blob:none --depth=1 --single-branch --branch 26.x \
      "$GO_URL" "$NEW_GO"; then
      break
    fi
    NEW_GO=""
  done
  [ -n "$NEW_GO" ] || { echo 'ERROR: Go 26.x checkout unavailable; original source kept' >&2; exit 1; }
  [ -d "$NEW_GO/.git" ] && validate_go "$NEW_GO" || {
    echo 'ERROR: Downloaded Go 26.x source missing required files; original source kept' >&2
    exit 1
  }
  [ "$(git -C "$NEW_GO" branch --show-current)" = '26.x' ] || {
    echo 'ERROR: Downloaded Go checkout on unexpected branch' >&2
    exit 1
  }

  if [ -d "$GO_DIR" ]; then
    GO_BACKUP="$GO_BACKUP_ROOT/golang-before-26x-$(date -u +%Y%m%dT%H%M%S)-$$"
    mv "$GO_DIR" "$GO_BACKUP"
    echo "GO_FEED_ORIGINAL_BACKUP=$GO_BACKUP"
  else
    GO_BACKUP=""
  fi

  if ! mv "$NEW_GO" "$GO_DIR"; then
    echo 'ERROR: Go checkout activation failed' >&2
    if [ -n "$GO_BACKUP" ]; then
      mv "$GO_BACKUP" "$GO_DIR" || echo "CRITICAL: restore manually from $GO_BACKUP" >&2
    fi
    exit 1
  fi
  echo 'GO_FEED_26X=ACTIVATED_WITH_ORIGINAL_PRESERVED'
fi

validate_go "$GO_DIR" || { echo 'ERROR: Final Go source incomplete' >&2; exit 1; }
GO_COMMIT="$(git -C "$GO_DIR" rev-parse HEAD)"
printf 'GO_FEED_26X_COMMIT=%s\n' "$GO_COMMIT"
mkdir -p /home/builder/work/logs/v12-source-registration
printf '%s\n' "$GO_COMMIT" > /home/builder/work/logs/v12-source-registration/go26-commit.txt

echo "===== Remove conflicting/older proxy cores from OpenWrt feeds ====="

rm -rf feeds/packages/net/xray-core
rm -rf feeds/packages/net/v2ray-geodata
rm -rf feeds/packages/net/sing-box
rm -rf feeds/packages/net/chinadns-ng
rm -rf feeds/packages/net/dns2socks
rm -rf feeds/packages/net/hysteria
rm -rf feeds/packages/net/ipt2socks
rm -rf feeds/packages/net/microsocks
rm -rf feeds/packages/net/naiveproxy
rm -rf feeds/packages/net/shadowsocks-rust
rm -rf feeds/packages/net/shadowsocksr-libev
rm -rf feeds/packages/net/simple-obfs
rm -rf feeds/packages/net/tcping
rm -rf feeds/packages/net/v2ray-plugin
rm -rf feeds/packages/net/xray-plugin
rm -rf feeds/packages/net/geoview
rm -rf feeds/packages/net/shadow-tls

rm -rf feeds/luci/applications/luci-app-passwall

# Preserve previously verified PassWall source checkouts and their pinned commits.
for d in package/passwall-packages package/passwall-luci package/passwall2-luci; do
  if [ -e "$d" ] && [ ! -d "$d/.git" ]; then
    echo "ERROR: unversioned source exists at $d" >&2; exit 1
  fi
done

echo "===== Clone PassWall package sources directly ====="

PWPKG_OK=0
for attempt in 1 2 3; do
  echo "PassWall packages clone attempt: $attempt/3"
  if [ -d "package/passwall-packages/.git" ]; then PWPKG_OK=1; break; fi
  if git -c http.version=HTTP/1.1 clone \
    --filter=blob:none \
    --depth=1 \
    --single-branch \
    --branch main \
    https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git \
    package/passwall-packages; then
    PWPKG_OK=1
    break
  fi

  rm -rf package/passwall-packages
  sleep 5
done

if [ "$PWPKG_OK" -ne 1 ]; then
  echo "ERROR: Failed to clone openwrt-passwall-packages after 3 attempts."
  exit 1
fi

# Pin shadowsocks-rust to Rust-1.90-compatible v1.24.0
# shadowsocks-rust 1.25.0 requires Rust >= 1.91
# iStoreOS 24.10 currently provides rustc 1.90.0
SS_RUST_MK="package/passwall-packages/shadowsocks-rust/Makefile"
test -f "$SS_RUST_MK"

echo "===== Pin shadowsocks-rust v1.24.0 ====="
sed -i \
  -e 's/^PKG_VERSION:=.*/PKG_VERSION:=1.24.0/' \
  -e 's/^PKG_HASH:=.*/PKG_HASH:=a89865d1c5203de1b732017dd032e85f943d1592e8d3152eb7d2c4f3fca387bf/' \
  "$SS_RUST_MK"

grep -qxF 'PKG_VERSION:=1.24.0' "$SS_RUST_MK"
grep -qxF 'PKG_HASH:=a89865d1c5203de1b732017dd032e85f943d1592e8d3152eb7d2c4f3fca387bf' "$SS_RUST_MK"
grep -E '^PKG_(VERSION|HASH):=' "$SS_RUST_MK"

# Xray 26.9.8+ requires Go >= 1.27, while the OpenWrt 24.10
# compatibility toolchain used here is Go 1.26.x. Keep Xray on
# the last Go-1.26-compatible release so Sing-box can also remain
# on the proven Go 1.26 toolchain.
XRAY_MK="package/passwall-packages/xray-core/Makefile"
test -f "$XRAY_MK"

echo "===== Pin Xray to Go 1.26-compatible v26.7.28 ====="
sed -i \
  -e 's/^PKG_VERSION:=.*/PKG_VERSION:=26.7.28/' \
  -e 's/^PKG_HASH:=.*/PKG_HASH:=a9afe86349c7bd3e6cae60125e62a5ada09d102e1a2760623e77c24a84dbfb46/' \
  "$XRAY_MK"

grep -qxF 'PKG_VERSION:=26.7.28' "$XRAY_MK"
grep -qxF 'PKG_HASH:=a9afe86349c7bd3e6cae60125e62a5ada09d102e1a2760623e77c24a84dbfb46' "$XRAY_MK"
grep -E '^PKG_(VERSION|HASH):=' "$XRAY_MK"

PWLUC_OK=0
for attempt in 1 2 3; do
  echo "PassWall LuCI clone attempt: $attempt/3"
  if [ -d "package/passwall-luci/.git" ]; then PWLUC_OK=1; break; fi
  if git -c http.version=HTTP/1.1 clone \
    --filter=blob:none \
    --depth=1 \
    --single-branch \
    --branch main \
    https://github.com/Openwrt-Passwall/openwrt-passwall.git \
    package/passwall-luci; then
    PWLUC_OK=1
    break
  fi

  rm -rf package/passwall-luci
  sleep 5
done

if [ "$PWLUC_OK" -ne 1 ]; then
  echo "ERROR: Failed to clone openwrt-passwall after 3 attempts."
  exit 1
fi

test -f package/passwall-luci/luci-app-passwall/Makefile

echo "===== Clone PassWall2 LuCI source ====="

PWLUC2_OK=0
for attempt in 1 2 3; do
  echo "PassWall2 LuCI clone attempt: $attempt/3"
  if [ -d "package/passwall2-luci/.git" ]; then PWLUC2_OK=1; break; fi

  if git -c http.version=HTTP/1.1 clone \
    --filter=blob:none \
    --depth=1 \
    --single-branch \
    --branch main \
    https://github.com/Openwrt-Passwall/openwrt-passwall2.git \
    package/passwall2-luci; then
    PWLUC2_OK=1
    break
  fi

  rm -rf package/passwall2-luci
  sleep 5
done

if [ "$PWLUC2_OK" -ne 1 ]; then
  echo "ERROR: Failed to clone openwrt-passwall2 after 3 attempts."
  exit 1
fi

test -f package/passwall2-luci/luci-app-passwall2/Makefile
test -f package/passwall-packages/xray-core/Makefile
test -f package/passwall-packages/sing-box/Makefile
test -f package/passwall-packages/chinadns-ng/Makefile


# These hashes are the source revisions reviewed during local V1.2 preparation.
for pair in \
  "package/passwall-packages:9178f2e627a1a104b0b35d1c47a7672dff42c970" \
  "package/passwall-luci:701d982a26ee0b960d248754b8f8868f6f18fb59" \
  "package/passwall2-luci:2de5aee7a4c704a5b689fdab47b97a18ad11c1a2"; do
  path=${pair%%:*}; expected=${pair#*:}
  actual=$(git -C "$path" rev-parse HEAD)
  [ "$actual" = "$expected" ] || { echo "SOURCE_COMMIT_MISMATCH $path: $actual" >&2; exit 1; }
done
