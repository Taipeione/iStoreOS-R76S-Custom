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

PRESERVE = (Path(__file__).resolve().parents[3] / 'files/usr/libexec/r76s/r76s-ota-preserve-state').read_text()

RESTORE_INIT = (Path(__file__).resolve().parents[3] / 'files/etc/init.d/r76s-ota-restore').read_text()

RESTORE_DEFAULTS = (Path(__file__).resolve().parents[3] / 'files/etc/uci-defaults/99-r76s-v110-ota-restore').read_text()

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
    state_config = root / 'files/etc/config/r76s_ota_state'
    state_config.parent.mkdir(parents=True, exist_ok=True)
    # Preserve an existing snapshot when reapplying this build patch.
    if not state_config.exists():
        replacements[state_config] = "config state 'state'\n"

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
        if not p.exists() or p.read_text() != content:
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
