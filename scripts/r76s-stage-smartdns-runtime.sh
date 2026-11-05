#!/bin/sh
# Stage the locked SmartDNS ARM64 runtime required by luci-app-r76s-updater.
# This is a build-time operation only; it never contacts or changes a router.
set -eu

UPDATER_DIR=${1:?usage: $0 UPDATER_SOURCE_DIR [WORK_DIR]}
WORK_DIR=${2:-${RUNNER_TEMP:-/tmp}/r76s-smartdns-runtime}
SMARTDNS_RELEASE=Release48.4
SMARTDNS_ASSET=smartdns.1.2026.08.05-0921.aarch64-linux-all.tar.gz
SMARTDNS_URL="https://github.com/pymumu/smartdns/releases/download/${SMARTDNS_RELEASE}/${SMARTDNS_ASSET}"
SMARTDNS_SHA256=d769cff42af9b8e76823aca130ddfd174cf24cbe56f702bc95f1ef20eb5fcf02

test -d "$UPDATER_DIR"
mkdir -p "$WORK_DIR"
ARCHIVE="$WORK_DIR/$SMARTDNS_ASSET"
EXTRACT_DIR=$(mktemp -d "$WORK_DIR/extract.XXXXXX")

curl -fL --retry 5 --retry-delay 3 --retry-all-errors "$SMARTDNS_URL" -o "$ARCHIVE"
test -s "$ARCHIVE"
printf '%s  %s\n' "$SMARTDNS_SHA256" "$ARCHIVE" | sha256sum -c -
gzip -t "$ARCHIVE"
tar -xzf "$ARCHIVE" -C "$EXTRACT_DIR"

SMARTDNS_BIN=
for candidate in $(find "$EXTRACT_DIR" -type f -name smartdns -print); do
	if file -b "$candidate" | grep -Eqi 'ELF.*(aarch64|ARM64)'; then
		SMARTDNS_BIN=$candidate
		break
	fi
done

if [ -z "$SMARTDNS_BIN" ]; then
	echo "ERROR: no AArch64 SmartDNS ELF was found in $SMARTDNS_ASSET" >&2
	find "$EXTRACT_DIR" -type f -name smartdns -exec file {} \; >&2 || true
	exit 1
fi

install -d "$UPDATER_DIR/files/root/usr/libexec/r76s"
install -m 0755 "$SMARTDNS_BIN" "$UPDATER_DIR/files/root/usr/libexec/r76s/smartdns.bin"
test -s "$UPDATER_DIR/files/root/usr/libexec/r76s/smartdns.bin"
echo "SMARTDNS_RUNTIME=PASS release=$SMARTDNS_RELEASE sha256=$SMARTDNS_SHA256"
