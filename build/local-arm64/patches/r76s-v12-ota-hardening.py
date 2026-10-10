#!/usr/bin/env python3
"""R76S V1.2 OTA hardening, invoked at the end of build stage 16.

Operates on generated OpenWrt worktree, never on a live router.
All edits are checked before writing, and are idempotent.
"""
from pathlib import Path
import os
import shutil
import subprocess
import sys

MARK = 'R76S_V12_OTA_HARDENING'

PRESERVE = r'''#!/bin/sh
# R76S_V12_OTA_HARDENING: must return failure if state cannot be saved.
set -eu

fail() {
    echo "r76s-ota-preserve-state: $*" >&2
    logger -t r76s-ota-preserve-state "$*" 2>/dev/null || true
    exit 1
}

init_enabled() {
    name="$1"
    if [ -x "/etc/init.d/$name" ] && /etc/init.d/"$name" enabled >/dev/null 2>&1; then
        printf '1\n'
    else
        printf '0\n'
    fi
}

uci_flag() {
    key="$1"
    value="$(uci -q get "$key" 2>/dev/null)" || value=0
    case "$value" in
        0|1) printf '%s\n' "$value" ;;
        *) fail "invalid enabled value for $key: $value" ;;
    esac
}

pw_init="$(init_enabled passwall)"
pw2_init="$(init_enabled passwall2)"
sd_init="$(init_enabled smartdns)"
agh_init="$(init_enabled adguardhome)"
pw_uci="$(uci_flag 'passwall.@global[0].enabled')"
pw2_uci="$(uci_flag 'passwall2.@global[0].enabled')"
sd_uci="$(uci_flag 'smartdns.@smartdns[0].enabled')"

# Never create a snapshot requiring both proxy engines to start together.
if [ "$pw_init" = 1 ] && [ "$pw_uci" = 1 ] && \
   [ "$pw2_init" = 1 ] && [ "$pw2_uci" = 1 ]; then
    fail "PassWall and PassWall2 are both enabled; resolve the conflict before OTA"
fi

uci -q set r76s_ota_state.state='state' || fail 'cannot create OTA state section'
uci -q set r76s_ota_state.state.pending='1' || fail 'cannot set pending'
uci -q set r76s_ota_state.state.passwall_init="$pw_init" || fail 'cannot record passwall init'
uci -q set r76s_ota_state.state.passwall2_init="$pw2_init" || fail 'cannot record passwall2 init'
uci -q set r76s_ota_state.state.smartdns_init="$sd_init" || fail 'cannot record smartdns init'
uci -q set r76s_ota_state.state.adguardhome_init="$agh_init" || fail 'cannot record adguardhome init'
uci -q set r76s_ota_state.state.passwall_uci="$pw_uci" || fail 'cannot record passwall config'
uci -q set r76s_ota_state.state.passwall2_uci="$pw2_uci" || fail 'cannot record passwall2 config'
uci -q set r76s_ota_state.state.smartdns_uci="$sd_uci" || fail 'cannot record smartdns config'
uci -q commit r76s_ota_state || fail 'UCI commit failed'
[ -s /etc/config/r76s_ota_state ] || fail 'OTA state file is missing/empty'
[ "$(uci -q get r76s_ota_state.state.pending 2>/dev/null)" = 1 ] || fail 'pending not persisted'
[ "$(uci -q get r76s_ota_state.state.passwall_init 2>/dev/null)" = "$pw_init" ] || fail 'passwall state not persisted'
[ "$(uci -q get r76s_ota_state.state.passwall2_init 2>/dev/null)" = "$pw2_init" ] || fail 'passwall2 state not persisted'
[ "$(uci -q get r76s_ota_state.state.smartdns_init 2>/dev/null)" = "$sd_init" ] || fail 'smartdns state not persisted'
[ "$(uci -q get r76s_ota_state.state.adguardhome_init 2>/dev/null)" = "$agh_init" ] || fail 'adguardhome state not persisted'
[ "$(uci -q get r76s_ota_state.state.passwall_uci 2>/dev/null)" = "$pw_uci" ] || fail 'passwall enabled state not persisted'
[ "$(uci -q get r76s_ota_state.state.passwall2_uci 2>/dev/null)" = "$pw2_uci" ] || fail 'passwall2 enabled state not persisted'
[ "$(uci -q get r76s_ota_state.state.smartdns_uci 2>/dev/null)" = "$sd_uci" ] || fail 'smartdns enabled state not persisted'
sync || fail 'sync failed'
exit 0
'''

RESTORE_INIT = r'''#!/bin/sh /etc/rc.common
# R76S_V12_OTA_HARDENING: fail closed and retain pending on restore failure.
START=98
STOP=10

restore_error() {
    echo "r76s-ota-restore: $*" >&2
    logger -t r76s-ota-restore "$*" 2>/dev/null || true
    return 1
}

is_flag() {
    case "$1" in 0|1) return 0 ;; *) return 1 ;; esac
}

service_init_state() {
    name="$1"
    enabled="$2"
    [ -x "/etc/init.d/$name" ] || { restore_error "missing service $name"; return 1; }
    case "$enabled" in
        1) /etc/init.d/"$name" enable >/dev/null 2>&1 || { restore_error "enable $name failed"; return 1; } ;;
        0)
            /etc/init.d/"$name" stop >/dev/null 2>&1 || true
            /etc/init.d/"$name" disable >/dev/null 2>&1 || { restore_error "disable $name failed"; return 1; }
            ;;
        *) restore_error "unknown init state $name=$enabled"; return 1 ;;
    esac
}

start() {
    [ "$(uci -q get r76s_ota_state.state.pending 2>/dev/null)" = 1 ] || return 0
    pw_uci="$(uci -q get r76s_ota_state.state.passwall_uci)"
    pw2_uci="$(uci -q get r76s_ota_state.state.passwall2_uci)"
    sd_uci="$(uci -q get r76s_ota_state.state.smartdns_uci)"
    pw_init="$(uci -q get r76s_ota_state.state.passwall_init)"
    pw2_init="$(uci -q get r76s_ota_state.state.passwall2_init)"
    sd_init="$(uci -q get r76s_ota_state.state.smartdns_init)"
    agh_init="$(uci -q get r76s_ota_state.state.adguardhome_init)"

    for value in "$pw_uci" "$pw2_uci" "$sd_uci" "$pw_init" "$pw2_init" "$sd_init" "$agh_init"; do
        is_flag "$value" || { restore_error 'incomplete/invalid OTA snapshot'; return 1; }
    done

    if [ "$pw_init" = 1 ] && [ "$pw_uci" = 1 ] && \
       [ "$pw2_init" = 1 ] && [ "$pw2_uci" = 1 ]; then
        /etc/init.d/passwall stop >/dev/null 2>&1 || true
        /etc/init.d/passwall2 stop >/dev/null 2>&1 || true
        restore_error 'PassWall and PassWall2 conflict; no proxy auto-start; pending retained'
        return 1
    fi

    uci -q set 'passwall.@global[0].enabled'="$pw_uci" || return 1
    uci -q set 'passwall2.@global[0].enabled'="$pw2_uci" || return 1
    uci -q set 'smartdns.@smartdns[0].enabled'="$sd_uci" || return 1
    uci -q commit passwall || return 1
    uci -q commit passwall2 || return 1
    uci -q commit smartdns || return 1

    service_init_state passwall "$pw_init" || return 1
    service_init_state passwall2 "$pw2_init" || return 1
    service_init_state smartdns "$sd_init" || return 1
    service_init_state adguardhome "$agh_init" || return 1

    if [ "$pw_init" = 1 ] && [ "$pw_uci" = 1 ]; then
        /etc/init.d/passwall restart >/dev/null 2>&1 || { restore_error 'passwall restart failed'; return 1; }
    fi
    if [ "$pw2_init" = 1 ] && [ "$pw2_uci" = 1 ]; then
        /etc/init.d/passwall2 restart >/dev/null 2>&1 || { restore_error 'passwall2 restart failed'; return 1; }
    fi
    if [ "$sd_init" = 1 ] && [ "$sd_uci" = 1 ]; then
        /etc/init.d/smartdns restart >/dev/null 2>&1 || { restore_error 'smartdns restart failed'; return 1; }
    fi
    if [ "$agh_init" = 1 ]; then
        if [ ! -s /etc/adguardhome.yaml ] && [ ! -s /etc/adguardhome/adguardhome.yaml ]; then
            restore_error 'AdGuard Home was enabled but its YAML configuration is absent'
            return 1
        fi
        /etc/init.d/adguardhome restart >/dev/null 2>&1 || { restore_error 'adguardhome restart failed'; return 1; }
    fi

    uci -q set r76s_ota_state.state.pending='0' || return 1
    uci -q commit r76s_ota_state || return 1
    [ "$(uci -q get r76s_ota_state.state.pending)" = 0 ] || return 1
    return 0
}
'''

RESTORE_DEFAULTS = r'''#!/bin/sh
# R76S_V110_STANDARD_PRESERVE_RESTORE
# R76S_V12_OTA_HARDENING: preserve first-boot restore marker until success.
CUSTOM_PENDING="$(uci -q get r76s_ota_state.state.pending)"
STANDARD_PRESERVE="$(uci -q get r76s_ota_state.state.standard_preserve)"

restore_error() {
    echo "r76s-ota-restore: $*" >&2
    logger -t r76s-ota-restore "$*" 2>/dev/null || true
    exit 1
}

is_flag() {
    case "$1" in 0|1) return 0 ;; *) return 1 ;; esac
}

service_init_state() {
    name="$1"
    enabled="$2"
    [ -x "/etc/init.d/$name" ] || restore_error "missing service $name"
    case "$enabled" in
        1) /etc/init.d/"$name" enable >/dev/null 2>&1 || restore_error "enable $name failed" ;;
        0)
            /etc/init.d/"$name" stop >/dev/null 2>&1 || true
            /etc/init.d/"$name" disable >/dev/null 2>&1 || restore_error "disable $name failed"
            ;;
        *) restore_error "invalid init state $name=$enabled" ;;
    esac
}

if [ "$CUSTOM_PENDING" = 1 ]; then
    /etc/init.d/r76s-ota-restore start || restore_error 'custom OTA restore failed; pending retained'
fi

if [ "$CUSTOM_PENDING" != 1 ] && [ "$STANDARD_PRESERVE" = 1 ]; then
    pw_init="$(uci -q get r76s_ota_state.state.standard_passwall_init)"
    pw2_init="$(uci -q get r76s_ota_state.state.standard_passwall2_init)"
    sd_init="$(uci -q get r76s_ota_state.state.standard_smartdns_init)"
    agh_init="$(uci -q get r76s_ota_state.state.standard_adguardhome_init)"
    pw_uci="$(uci -q get 'passwall.@global[0].enabled')"
    pw2_uci="$(uci -q get 'passwall2.@global[0].enabled')"
    sd_uci="$(uci -q get 'smartdns.@smartdns[0].enabled')"

    for value in "$pw_init" "$pw2_init" "$sd_init" "$agh_init" "$pw_uci" "$pw2_uci" "$sd_uci"; do
        is_flag "$value" || restore_error 'invalid/missing standard-preserve state; marker retained'
    done

    if [ "$pw_init" = 1 ] && [ "$pw_uci" = 1 ] && \
       [ "$pw2_init" = 1 ] && [ "$pw2_uci" = 1 ]; then
        /etc/init.d/passwall stop >/dev/null 2>&1 || true
        /etc/init.d/passwall2 stop >/dev/null 2>&1 || true
        restore_error 'PassWall and PassWall2 conflict; marker retained, neither restarted'
    fi

    service_init_state passwall "$pw_init"
    service_init_state passwall2 "$pw2_init"
    service_init_state smartdns "$sd_init"
    service_init_state adguardhome "$agh_init"

    if [ "$pw_init" = 1 ] && [ "$pw_uci" = 1 ]; then
        /etc/init.d/passwall restart >/dev/null 2>&1 || restore_error 'passwall restart failed'
    fi
    if [ "$pw2_init" = 1 ] && [ "$pw2_uci" = 1 ]; then
        /etc/init.d/passwall2 restart >/dev/null 2>&1 || restore_error 'passwall2 restart failed'
    fi
    if [ "$sd_init" = 1 ] && [ "$sd_uci" = 1 ]; then
        /etc/init.d/smartdns restart >/dev/null 2>&1 || restore_error 'smartdns restart failed'
    fi
    if [ "$agh_init" = 1 ]; then
        [ -s /etc/adguardhome.yaml ] || [ -s /etc/adguardhome/adguardhome.yaml ] || \
            restore_error 'AdGuard Home config YAML missing'
        /etc/init.d/adguardhome restart >/dev/null 2>&1 || restore_error 'adguardhome restart failed'
    fi

fi

# The standard marker is also produced on custom OTA. Clear it only when
# custom or standard restoration is successful, never on a failed restore.
if [ "$CUSTOM_PENDING" = 1 ] || [ "$STANDARD_PRESERVE" = 1 ]; then
    for key in standard_preserve standard_passwall_init standard_passwall2_init \
               standard_smartdns_init standard_adguardhome_init; do
        uci -q delete "r76s_ota_state.state.$key" 2>/dev/null || true
    done
    uci -q commit r76s_ota_state || restore_error 'cannot commit restore cleanup'
fi
exit 0
'''

OLD_CONTROLLER = '    sys.call("(sleep 2; /usr/libexec/r76s/r76s-ota-preserve-state && /sbin/sysupgrade " .. FIRMWARE .. " >/tmp/r76s-sysupgrade.log 2>&1) >/dev/null 2>&1 &")'
NEW_CONTROLLER = '''    -- R76S_V12_OTA_HARDENING: save state synchronously; only then schedule flashing.
    local preserve_rc = sys.call("/usr/libexec/r76s/r76s-ota-preserve-state >/tmp/r76s-ota-preserve.log 2>&1")
    if preserve_rc ~= 0 then
        json_reply({ ok=false, message="升级前配置保存失败，已停止升级。请检查 /tmp/r76s-ota-preserve.log。" })
        return
    end

    local launch_rc = sys.call("(sleep 2; /sbin/sysupgrade " .. FIRMWARE .. " >/tmp/r76s-sysupgrade.log 2>&1) >/dev/null 2>&1 &")
    if launch_rc ~= 0 then
        json_reply({ ok=false, message="升级后台任务启动失败，请检查系统日志。" })
        return
    end'''


def root_for_worktree():
    p = Path.cwd()
    return p / 'openwrt' if (p / 'openwrt').is_dir() else p


def must_exist(path):
    if not path.is_file():
        raise RuntimeError(f'Required generated file missing: {path}')


def apply():
    root = root_for_worktree()
    controller = root / 'package/custom/luci-app-r76s-updater/files/controller/r76s_updater.lua'
    helpers = [
        root / 'files/usr/libexec/r76s/r76s-ota-preserve-state',
        root / 'package/custom/luci-app-r76s-updater/files/root/usr/libexec/r76s/r76s-ota-preserve-state',
    ]
    restore_init = root / 'files/etc/init.d/r76s-ota-restore'
    restore_defaults = root / 'files/etc/uci-defaults/99-r76s-v110-ota-restore'
    keep = root / 'files/lib/upgrade/keep.d/r76s-v110'
    all_files = [controller, restore_init, restore_defaults, keep] + helpers
    for p in all_files:
        must_exist(p)
    if '/etc/config/r76s_ota_state' not in keep.read_text():
        raise RuntimeError('keep.d list does not retain /etc/config/r76s_ota_state')

    original = controller.read_text()
    if OLD_CONTROLLER in original:
        controller_new = original.replace(OLD_CONTROLLER, NEW_CONTROLLER, 1)
    elif NEW_CONTROLLER in original:
        controller_new = original
    else:
        raise RuntimeError('Controller install anchor changed; refusing unsafe partial patch')
    if controller_new.count('local preserve_rc = sys.call(') != 1:
        raise RuntimeError('Unexpected number of OTA preflight calls')
    if controller_new.count('/sbin/sysupgrade " .. FIRMWARE') != 1:
        raise RuntimeError('Unexpected number of sysupgrade launch calls')

    replacements = {controller: controller_new, restore_init: RESTORE_INIT, restore_defaults: RESTORE_DEFAULTS}
    for h in helpers:
        replacements[h] = PRESERVE

    # Only patch installed rootfs when it already exists; canonical build inputs
    # above remain the source of truth on the next package/image build.
    installed = root / 'build_dir/target-aarch64_generic_musl/root-rockchip'
    optional_files = {
        installed / 'usr/lib/lua/luci/controller/r76s_updater.lua': controller_new,
        installed / 'usr/libexec/r76s/r76s-ota-preserve-state': PRESERVE,
        installed / 'etc/init.d/r76s-ota-restore': RESTORE_INIT,
        installed / 'etc/uci-defaults/99-r76s-v110-ota-restore': RESTORE_DEFAULTS,
    }
    for p, content in optional_files.items():
        if p.is_file():
            # Controller installed might be from a different build; refuse ambiguity.
            if p.name == 'r76s_updater.lua' and OLD_CONTROLLER not in p.read_text() and NEW_CONTROLLER not in p.read_text():
                raise RuntimeError('Installed controller diverged, refusing to patch')
            replacements[p] = content

    for p, content in replacements.items():
        if content.startswith('#!/bin/sh'):
            proc = subprocess.run(['sh', '-n'], input=content, text=True, capture_output=True)
            if proc.returncode:
                raise RuntimeError(f'Shell syntax error {p}: {proc.stderr}')

    changed = []
    for p, content in replacements.items():
        if p.read_text() != content:
            p.write_text(content)
            changed.append(p)
        if content.startswith('#!/bin/sh'):
            p.chmod(p.stat().st_mode | 0o111)
    print(f'{MARK}: patched {len(changed)} file(s), checked {len(replacements)}')
    for p in changed:
        print('  UPDATED', p)
    print('  Safety: preserve-preflight before async flash; restart errors retain OTA markers')
    print('  NOTE: static patch only; no build, no live flash, no service actions')


if __name__ == '__main__':
    try:
        apply()
    except Exception as e:
        print(f'{MARK}: ERROR: {e}', file=sys.stderr)
        sys.exit(1)
