#!/usr/bin/env bash
set -euo pipefail

echo "===== R76S V1.2 GO126 AND PASSWALL PREFLIGHT ====="

test -s .config
test -d package/feeds/packages

G="/home/builder/work/tools/go126-module-cache/golang.org/toolchain@v0.0.1-go1.26.6.linux-arm64"
H="/r76s-repo/build/local-arm64/v12-go126-package-hook.py"
F="feeds/packages/lang/golang/golang-package.mk"

test -x "$G/bin/go"
test -s "$H"
test -s "$F"

test "$("$G/bin/go" env GOVERSION)" = "go1.26.6"
test "$("$G/bin/go" env GOARCH)" = "arm64"

python3 "$H" "$F" "$G"

grep -qF "R76S_GO126_TARGET_PACKAGES" "$F"

echo "GO126_BUILD_HOOK=PASS"

mkdir -p ../logs/v12-source-registration

NEED_REFRESH=0

for item in sing-box:1.14.3 xray-core:26.7.28; do
  NAME="${item%%:*}"
  VERSION="${item#*:}"

  LINK="package/feeds/packages/$NAME"
  OLD="feeds/packages/net/$NAME"
  NEW="package/passwall-packages/$NAME"

  test -s "$NEW/Makefile"
  grep -qxF "PKG_VERSION:=$VERSION" "$NEW/Makefile"

  test -L "$LINK"

  if [ "$(realpath "$LINK")" != "$(realpath "$NEW")" ]; then
    test -s "$OLD/Makefile"

    if [ "$(realpath "$LINK")" != "$(realpath "$OLD")" ]; then
      echo "ERROR: Unexpected $NAME source; refusing replacement"
      exit 1
    fi

    BACKUP="../logs/v12-source-registration/$NAME-original-link.txt"

    if test ! -e "$BACKUP"; then
      readlink "$LINK" > "$BACKUP"
    fi

    ln -s "../../passwall-packages/$NAME" "${LINK}.r76s-new"
    mv -Tf "${LINK}.r76s-new" "$LINK"

    NEED_REFRESH=1
  fi

  test "$(realpath "$LINK")" = "$(realpath "$NEW")"

  if ! awk -v n="$NAME" -v v="$VERSION" '
    $0 == "Package: " n { found=1; next }
    found && /^Version: / {
      good = (index($2, v "-") == 1)
      exit
    }
    END { exit !good }
  ' tmp/.packageinfo 2>/dev/null; then
    NEED_REFRESH=1
  fi

  echo "$NAME SOURCE=$VERSION"
done

if [ "$NEED_REFRESH" -eq 1 ]; then
  echo "===== REFRESH PACKAGE REGISTRATION ====="

  cp -p .config ../logs/v12-source-registration/config-before-refresh.bak

  rm -f \
    tmp/info/.packageinfo-feeds_packages_sing-box \
    tmp/info/.packageinfo-feeds_packages_xray-core \
    tmp/.packageinfo \
    tmp/.config-package.in

  make defconfig > ../logs/v12-source-registration/defconfig.log 2>&1 || {
    tail -n 40 ../logs/v12-source-registration/defconfig.log
    exit 1
  }
fi

for item in sing-box:1.14.3 xray-core:26.7.28; do
  NAME="${item%%:*}"
  VERSION="${item#*:}"

  awk -v n="$NAME" -v v="$VERSION" '
    $0 == "Package: " n { found=1; next }
    found && /^Version: / {
      good = (index($2, v "-") == 1)
      exit
    }
    END { exit !good }
  ' tmp/.packageinfo

  grep -qxF "CONFIG_PACKAGE_${NAME}=y" .config
done

grep -qxF \
  "CONFIG_TARGET_rockchip_armv8_DEVICE_friendlyarm_nanopi-r76s=y" \
  .config

grep -qxF "CONFIG_PACKAGE_luci-app-ota=y" .config

echo "GO126_PASSWALL_SOURCES=PASS"
echo "===== V1.2 SOURCE PREPARATION PASS ====="
