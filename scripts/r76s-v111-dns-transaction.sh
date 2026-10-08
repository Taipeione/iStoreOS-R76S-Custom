#!/bin/sh
# R76S V111 atomic DNS transaction laboratory.
# Offline only; never changes router configuration.

set -eu
umask 077

[ "$#" -eq 3 ] || exit 2

ACTION="$1"
STATE="$2"
LAB="$3"

case "$ACTION" in
    stage|rollback) ;;
    *) echo "ERROR: Invalid action" >&2; exit 2 ;;
esac

case "$LAB" in
    /tmp/r76s-v111-lab.*) ;;
    *) echo "BLOCKED: Invalid lab path" >&2; exit 4 ;;
esac

SUFFIX="${LAB#/tmp/r76s-v111-lab.}"

case "$SUFFIX" in
    ""|*[!a-zA-Z0-9]*)
        echo "BLOCKED: Unsafe lab suffix" >&2
        exit 4
        ;;
esac

[ -d "$LAB" ] && [ ! -L "$LAB" ] || exit 4

BASE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
MANAGER="$BASE/r76s-v111-dns-manager.sh"

CONF="$LAB/r76s-v111.conf"
OLD_HASH="$LAB/r76s-v111.sha256"

[ ! -L "$CONF" ] && [ ! -e "$OLD_HASH" ] && \
[ ! -L "$OLD_HASH" ] || {
    echo "BLOCKED: Symlink or old two-file format" >&2
    exit 4
}

EXPECTED="$(mktemp "$LAB/.expected.XXXXXX")"

trap 'rm -f "$EXPECTED"' 0

# Verify ownership by regenerating the entire existing file.
if [ -e "$CONF" ]; then
    [ -f "$CONF" ] || exit 4

    IFS= read -r HEADER < "$CONF" || true

    case "$HEADER" in
        '# R76S V111 managed DNS, state '*)
            OLD_STATE="${HEADER##* }"
            ;;
        *)
            echo "BLOCKED: Unmanaged file" >&2
            exit 4
            ;;
    esac

    if ! sh "$MANAGER" render "$OLD_STATE" \
        WAN_BASELINE > "$EXPECTED" 2>/dev/null; then
        echo "BLOCKED: Old state cannot be verified" >&2
        exit 4
    fi

    if ! cmp -s "$CONF" "$EXPECTED"; then
        echo "BLOCKED: Existing file modified" >&2
        exit 4
    fi
fi

if [ "$ACTION" = "rollback" ]; then
    rm -f "$CONF"
    echo "ATOMIC_ROLLBACK=PASS"
    exit 0
fi

TMP="$(mktemp "$LAB/.r76s-conf.XXXXXX")"
trap 'rm -f "$EXPECTED" "$TMP"' 0

if ! sh "$MANAGER" render "$STATE" \
    WAN_BASELINE > "$TMP"; then
    echo "BLOCKED: Renderer rejected state" >&2
    exit 5
fi

[ -s "$TMP" ] || exit 5

chmod 0644 "$TMP"

# Same-directory rename: a single atomic replacement.
mv -f "$TMP" "$CONF"

echo "STAGED_STATE=$STATE"
echo "ATOMIC_STAGE=PASS"
echo "ROUTER_CONFIG_CHANGES=NONE"
