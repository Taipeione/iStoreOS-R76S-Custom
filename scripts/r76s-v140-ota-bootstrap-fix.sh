#!/bin/sh
# R76S_V140_BOOTSTRAP_FIX
# Apply only to a running R76S-V1.4.0 installer.  This script never downloads
# or flashes firmware.  It replaces the old OTA launcher with a guarded
# compatibility wrapper and makes configuration backup an atomic transaction.
set -eu

PATH=/usr/sbin:/usr/bin:/sbin:/bin
RUN=/tmp/r76s-ota
TARGET=/usr/libexec/r76s/r76s-ota
ORIGINAL=/usr/libexec/r76s/r76s-ota.v140-original.lua
BACKUP_HELPER=/usr/libexec/r76s/r76s-ota-config-backup
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
SAVE="$RUN/bootstrap-backup/$STAMP"

fail() { echo "R76S OTA bootstrap: $*" >&2; exit 1; }

[ -r /etc/openwrt_release ] || fail '无法读取固件版本'
grep -q "DISTRIB_REVISION='R76S-V1.4.0'" /etc/openwrt_release || \
    fail '只允许应用于 R76S-V1.4.0'
[ -x "$TARGET" ] || fail '未找到 V1.4.0 OTA installer'
[ ! -e "$TARGET.bootstrap-wrapper" ] || fail 'bootstrap 修复已经应用'

mkdir -p "$SAVE"
cp -p "$TARGET" "$SAVE/r76s-ota.original"

if [ ! -e "$ORIGINAL" ]; then
    cp -p "$TARGET" "$ORIGINAL"
fi

# Patch exactly the unsafe V1.4.0 backup sequence.  Refuse an unknown source
# rather than applying a broad or ambiguous replacement.
grep -qF "assert(call('/sbin/sysupgrade -b '..run..'/configuration.tar.gz'),'configuration backup failed')" "$ORIGINAL" || \
    fail 'V1.4.0 backup anchor不存在，拒绝模糊修改'
sed -i \
    "s#            assert(call('/sbin/sysupgrade -b '..run..'/configuration.tar.gz'),'configuration backup failed')#            assert(call('$BACKUP_HELPER'),'configuration backup failed')#" \
    "$ORIGINAL"
sed -i \
    "/assert(call('tar -tzf '..run..'\/configuration.tar.gz'),'invalid configuration backup')/d" \
    "$ORIGINAL"

cat > "$BACKUP_HELPER" <<'R76S_BACKUP'
#!/bin/sh
# R76S_V140_BOOTSTRAP_BACKUP
set -eu
RUN=/tmp/r76s-ota
PART="$RUN/configuration.tar.gz.part"
FINAL="$RUN/configuration.tar.gz"
LOG="$RUN/configuration-backup.log"
LOCK="$RUN/config-backup.lock"

fail() { echo "配置备份失败：$*；详情见 $LOG" >&2; exit 1; }
mkdir -p "$RUN"

if ! mkdir "$LOCK" 2>/dev/null; then
    owner=''
    [ -r "$LOCK/pid" ] && owner=$(cat "$LOCK/pid" 2>/dev/null || true)
    live=0
    case "$owner" in
        ''|*[!0-9]*) ;;
        *)
            if [ -r "/proc/$owner/cmdline" ] &&
               tr '\000' ' ' < "/proc/$owner/cmdline" 2>/dev/null |
               grep -qE 'r76s-ota(-config-backup)?'; then live=1; fi
            ;;
    esac
    [ "$live" -eq 0 ] || fail '已有配置备份事务正在运行'
    rm -rf "$LOCK"
    mkdir "$LOCK" 2>/dev/null || fail '无法取得配置备份锁'
fi
printf '%s\n' "$$" > "$LOCK/pid"
cleanup() { rm -rf "$LOCK"; }
trap cleanup EXIT HUP INT TERM

# A recursive keep entry can make sysupgrade archive its own temporary OTA
# transaction.  Reject it before starting the one and only backup process.
for keep in /etc/sysupgrade.conf /lib/upgrade/keep.d/*; do
    [ -f "$keep" ] || continue
    if grep -Eq '(^|[[:space:]])/tmp(/|$)|/tmp/r76s-ota' "$keep"; then
        fail "keep 列表包含临时目录：$keep"
    fi
done

rm -f "$PART"
if ! /sbin/sysupgrade -b "$PART" >"$LOG" 2>&1; then
    fail 'sysupgrade -b 返回失败'
fi
[ -s "$PART" ] || fail 'configuration.tar.gz.part 为 0 字节'
tar -tzf "$PART" >/dev/null 2>&1 || fail '备份归档 tar -tzf 校验失败'
mv -f "$PART" "$FINAL"
[ -s "$FINAL" ] || fail '原子替换后的 configuration.tar.gz 为空'
R76S_BACKUP
chmod 0700 "$BACKUP_HELPER"

cat > "$TARGET" <<R76S_WRAPPER
#!/bin/sh
# R76S_V140_BOOTSTRAP_WRAPPER
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
RUN=/tmp/r76s-ota
ORIGINAL=$ORIGINAL
WRAPPER_LOCK="\$RUN/bootstrap.lock"

live_pid() {
    p="\$1"
    [ -r "/proc/\$p/cmdline" ] || return 1
    tr '\000' ' ' < "/proc/\$p/cmdline" 2>/dev/null |
        grep -qE 'r76s-ota(\.v140-original\.lua|-config-backup)?'
}

clear_stale_backend_lock() {
    [ -d "\$RUN/lock" ] || return 0
    owner=''
    [ -r "\$RUN/lock/pid" ] && owner=\$(cat "\$RUN/lock/pid" 2>/dev/null || true)
    case "\$owner" in
        ''|*[!0-9]*) rm -rf "\$RUN/lock" ;;
        *) live_pid "\$owner" || rm -rf "\$RUN/lock" ;;
    esac
}

phase=\${1:-check}
[ "\$phase" = status ] && exec /usr/bin/lua "\$ORIGINAL" "\$@"
mkdir -p "\$RUN"
if ! mkdir "\$WRAPPER_LOCK" 2>/dev/null; then
    owner=''
    [ -r "\$WRAPPER_LOCK/pid" ] && owner=\$(cat "\$WRAPPER_LOCK/pid" 2>/dev/null || true)
    if [ -n "\$owner" ] && live_pid "\$owner"; then
        echo 'OTA 正在执行：已有 V1.4.0 OTA 事务' >&2
        exit 1
    fi
    rm -rf "\$WRAPPER_LOCK"
    mkdir "\$WRAPPER_LOCK" 2>/dev/null || { echo 'OTA busy' >&2; exit 1; }
fi
printf '%s\n' "\$\$" > "\$WRAPPER_LOCK/pid"
cleanup() { rm -rf "\$WRAPPER_LOCK"; }
trap cleanup EXIT HUP INT TERM

# Only the owner of the wrapper transaction may reclaim the legacy lock.  This
# ordering prevents a second request from deleting the first request's lock.
clear_stale_backend_lock

state=\$(cat "\$RUN/state.json" 2>/dev/null || true)
case "\$state" in
    *'"phase":"flashing"'*) echo 'OTA 已进入刷写阶段，请等待设备重启' >&2; exit 1 ;;
esac

/usr/bin/lua "\$ORIGINAL" "\$@"
R76S_WRAPPER
chmod 0700 "$TARGET"
touch "$TARGET.bootstrap-wrapper"

echo "R76S OTA bootstrap fix applied"
echo "backup=$SAVE"
echo '现有 /tmp/firmware.img 未修改；请回到 LuCI 点击“在线升级并保留配置”。'
