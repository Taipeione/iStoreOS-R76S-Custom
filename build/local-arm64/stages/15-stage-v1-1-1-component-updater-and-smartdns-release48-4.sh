#!/usr/bin/env bash
# Original workflow step: Stage V1.1.1 component updater and SmartDNS Release48.4 runtime
# REVIEW REQUIRED: not yet adapted for local execution.

mkdir -p openwrt/package/custom

rm -rf openwrt/package/custom/luci-app-r76s-updater
cp -r feeds/luci-app-r76s-updater openwrt/package/custom/

UPDATER_DIR="openwrt/package/custom/luci-app-r76s-updater"
SMARTDNS_TAG="Release48.4"
SMARTDNS_ASSET="smartdns.1.2026.08.05-0921.aarch64-linux-all.tar.gz"
SMARTDNS_URL="https://github.com/pymumu/smartdns/releases/download/${SMARTDNS_TAG}/${SMARTDNS_ASSET}"

echo "===== SmartDNS ${SMARTDNS_TAG} official asset ====="
echo "SmartDNS asset: $SMARTDNS_URL"

rm -f /tmp/smartdns-aarch64.tar.gz

curl -fL --retry 5 --retry-delay 3 --retry-all-errors "$SMARTDNS_URL" -o /tmp/smartdns-aarch64.tar.gz

test -s /tmp/smartdns-aarch64.tar.gz
gzip -t /tmp/smartdns-aarch64.tar.gz

echo "SmartDNS archive SHA256:"
sha256sum /tmp/smartdns-aarch64.tar.gz

rm -rf /tmp/smartdns-extract
mkdir -p /tmp/smartdns-extract
tar -xzf /tmp/smartdns-aarch64.tar.gz -C /tmp/smartdns-extract

# Select the real ARM64 ELF executable, not /etc/default/smartdns.
SMARTDNS_BIN=""
while IFS= read -r -d '' candidate; do
  if file -b "$candidate" | grep -Eqi "^ELF.*(aarch64|ARM64)"; then
    SMARTDNS_BIN="$candidate"
    break
  fi
done < <(find /tmp/smartdns-extract -type f -name smartdns -print0)

if [ -z "$SMARTDNS_BIN" ]; then
  echo "ERROR: No AArch64 ELF SmartDNS executable found."
  find /tmp/smartdns-extract -type f -name smartdns -exec file {} +
  exit 1
fi

echo "SMARTDNS_AARCH64_BINARY=$SMARTDNS_BIN"
file "$SMARTDNS_BIN"

install -m 0755 \
  "$SMARTDNS_BIN" \
  "$UPDATER_DIR/files/root/usr/libexec/r76s/smartdns.bin"

CTRL="$UPDATER_DIR/files/controller/r76s_updater.lua"
VIEW="$UPDATER_DIR/files/view/r76s_updater/index.htm"
POLICY="$UPDATER_DIR/files/root/usr/libexec/r76s/r76s-smartdns-policy"
BOOT_HOOK="$UPDATER_DIR/files/root/etc/init.d/r76s-fix3-boot"
PRESERVE_HELPER="$UPDATER_DIR/files/root/usr/libexec/r76s/r76s-ota-preserve-state"

for required in \
  "$UPDATER_DIR/Makefile" \
  "$CTRL" \
  "$VIEW" \
  "$UPDATER_DIR/files/root/usr/libexec/r76s/r76s-component-updater" \
  "$POLICY" \
  "$BOOT_HOOK" \
  "$UPDATER_DIR/files/root/usr/libexec/r76s/smartdns.bin"; do
  test -s "$required"
done

echo "===== V1.1.1: remove automatic DNS takeover from component package ====="

cat > "$POLICY" <<'EOF_POLICY'
#!/bin/sh
# R76S V1.1.1 policy: SmartDNS is user-controlled.
# Component updates must not rewrite DNS, WAN, dnsmasq or user settings.
exit 0
EOF_POLICY
chmod 0755 "$POLICY"

cat > "$BOOT_HOOK" <<'EOF_BOOT_HOOK'
#!/bin/sh /etc/rc.common
# R76S V1.1.1: intentionally no automatic DNS/proxy configuration.
# User-enabled services keep their own normal init/procd state.
START=99
STOP=10
USE_PROCD=1

start_service() {
    return 0
}

stop_service() {
    return 0
}
EOF_BOOT_HOOK
chmod 0755 "$BOOT_HOOK"

echo "===== V1.1.1: install online-upgrade service state capture helper ====="

cat > "$PRESERVE_HELPER" <<'EOF_PRESERVE_HELPER'
#!/bin/sh
# Save service/UCI state immediately before online sysupgrade.
# /etc/config/r76s_ota_state is retained by the V1.1.1 keep.d list.
init_enabled() {
    name="$1"
    if [ -x "/etc/init.d/$name" ] && /etc/init.d/"$name" enabled >/dev/null 2>&1; then
        echo 1
    else
        echo 0
    fi
}

uci -q delete r76s_ota_state.state
uci -q set r76s_ota_state.state='state'
uci -q set r76s_ota_state.state.pending='1'
uci -q set r76s_ota_state.state.passwall_init="$(init_enabled passwall)"
uci -q set r76s_ota_state.state.passwall2_init="$(init_enabled passwall2)"
uci -q set r76s_ota_state.state.smartdns_init="$(init_enabled smartdns)"
uci -q set r76s_ota_state.state.adguardhome_init="$(init_enabled adguardhome)"
uci -q set r76s_ota_state.state.passwall_uci="$(uci -q get passwall.@global[0].enabled || echo 0)"
uci -q set r76s_ota_state.state.passwall2_uci="$(uci -q get passwall2.@global[0].enabled || echo 0)"
uci -q set r76s_ota_state.state.smartdns_uci="$(uci -q get smartdns.@smartdns[0].enabled || echo 0)"
uci -q commit r76s_ota_state
sync
exit 0
EOF_PRESERVE_HELPER
chmod 0755 "$PRESERVE_HELPER"

echo "===== Stage online-upgrade preserve helper into final image overlay ====="
mkdir -p openwrt/files/usr/libexec/r76s
install -m 0755 "$PRESERVE_HELPER" openwrt/files/usr/libexec/r76s/r76s-ota-preserve-state
test -x openwrt/files/usr/libexec/r76s/r76s-ota-preserve-state
grep -qF 'r76s_ota_state.state.pending' openwrt/files/usr/libexec/r76s/r76s-ota-preserve-state
echo "Online-upgrade preserve helper final-image overlay staged."

echo "===== V1.1.1: patch firmware online-upgrade controller ====="

python3 - "$CTRL" <<'PY_OTA_PATCH'
from pathlib import Path
import sys

p = Path(sys.argv[1])
t = p.read_text()

import re

t, marker_count = re.subn(
    r'-- R76S_UPDATER_UI_PATCH=\d+',
    '-- R76S_UPDATER_UI_PATCH=6',
    t,
    count=1,
)
if marker_count != 1:
    raise SystemExit('ERROR: updater UI patch marker not found')

old_return = '    return rc, trim(out)'
new_return = "\n".join([
    '    -- /bin/ota download starts an asynchronous curl job. Some builds',
    '    -- return a non-zero launcher rc even though the download is alive.',
    '    if cmd:find("/bin/ota download", 1, true) and rc ~= 0 then',
    '        sys.call("sleep 1")',
    '        local active = fs.access("/tmp/firmware.img.part")',
    '            or sys.call("pgrep -f \'[/]bin/ota\' >/dev/null 2>&1") == 0',
    '            or sys.call("pgrep -f \'[c]url.*firmware.img\' >/dev/null 2>&1") == 0',
    '        if active then',
    '            rc = 0',
    '            if trim(out) == "" then',
    '                out = "下载任务已启动"',
    '            end',
    '        end',
    '    end',
    '    return rc, trim(out)',
])
if old_return not in t:
    raise SystemExit('ERROR: run_with_rc return anchor not found in updater controller')
t = t.replace(old_return, new_return, 1)

old_download = "\n".join([
    '    elseif progress_exists then',
    '        state = "failed"',
    '        message = trim(progress_text:match("([^\\r\\n]+)%s*$") or "下载失败")',
])
new_download = "\n".join([
    '    elseif progress_exists and (',
    '        sys.call("pgrep -f \'[/]bin/ota\' >/dev/null 2>&1") == 0',
    '        or sys.call("pgrep -f \'[c]url.*firmware.img\' >/dev/null 2>&1") == 0',
    '    ) then',
    '        state = "downloading"',
    '        message = "正在下载"',
    '    elseif progress_exists then',
    '        state = "failed"',
    '        message = trim(progress_text:match("([^\\r\\n]+)%s*$") or "下载失败")',
])
if old_download not in t:
    raise SystemExit('ERROR: download_info progress anchor not found in updater controller')
t = t.replace(old_download, new_download, 1)

old_safe = '    local safe = (dev == "mmcblk0" or dev == "mmcblk2") and romdev:find("/dev/" .. dev, 1, true) == 1'
new_safe = "\n".join([
    '    -- /rom can be /dev/root; resolve root=PARTUUID through blkid first.',
    '    local resolved_root = romdev',
    '    if romdev == "/dev/root" or romdev == "rootfs" then',
    '        local cmdline = readfile("/proc/cmdline")',
    '        local partuuid = cmdline:match("root=PARTUUID=([%w%-]+)")',
    '        if partuuid and partuuid ~= "" then',
    '            resolved_root = trim(sys.exec(',
    '                "blkid 2>/dev/null | grep -i \'PARTUUID=\\\"" .. partuuid .. "\\\"\' | head -n1 | cut -d: -f1"',
    '            ))',
    '        end',
    '    end',
    '',
    '    local allowed = (dev == "mmcblk0" or dev == "mmcblk2")',
    '    local expected = dev ~= "" and ("/dev/" .. dev) or ""',
    '    local safe = allowed and expected ~= "" and (',
    '        romdev:find(expected, 1, true) == 1',
    '        or (resolved_root ~= "" and resolved_root:find(expected, 1, true) == 1)',
    '    )',
])
if old_safe not in t:
    raise SystemExit('ERROR: boot_info safety anchor not found in updater controller')
t = t.replace(old_safe, new_safe, 1)

install_old = 'sys.call("(sleep 2; /sbin/sysupgrade " .. FIRMWARE .. " >/tmp/r76s-sysupgrade.log 2>&1) >/dev/null 2>&1 &")'
install_new = 'sys.call("(sleep 2; /usr/libexec/r76s/r76s-ota-preserve-state && /sbin/sysupgrade " .. FIRMWARE .. " >/tmp/r76s-sysupgrade.log 2>&1) >/dev/null 2>&1 &")'
if install_old in t:
    t = t.replace(install_old, install_new, 1)
elif 'local preserve_rc = sys.call(' not in t and '/usr/libexec/r76s/r76s-ota-preserve-state && /sbin/sysupgrade ' not in t:
    raise SystemExit('ERROR: online-upgrade install call anchor not found')

if '/sbin/sysupgrade -n' in t or 'sysupgrade -n' in t:
    raise SystemExit('ERROR: updater would erase settings by default (sysupgrade -n found)')
if 'local preserve_rc = sys.call(' not in t and '/usr/libexec/r76s/r76s-ota-preserve-state && /sbin/sysupgrade " .. FIRMWARE' not in t:
    raise SystemExit('ERROR: online-upgrade preserve-state helper is not chained before sysupgrade')

verify_anchor = 'local verified = verify_image()'
verify_fail_anchor = 'if not verified.ok then'
install_anchor = 'local launch_rc = sys.call(' if 'local launch_rc = sys.call(' in t else '/usr/libexec/r76s/r76s-ota-preserve-state && /sbin/sysupgrade " .. FIRMWARE'

if verify_anchor not in t or verify_fail_anchor not in t:
    raise SystemExit('ERROR: online-upgrade install path does not re-run verify_image() before flashing')

if t.find(verify_anchor) > t.find(install_anchor):
    raise SystemExit('ERROR: online-upgrade verify_image() occurs after sysupgrade install call')

p.write_text(t)
PY_OTA_PATCH

echo "===== V1.1.1: install full online-upgrade UI with additive-upgrade status ====="

python3 - "$VIEW" <<'PY_OTA_VIEW'
from pathlib import Path
import sys

p = Path(sys.argv[1])

view = r'''<!-- R76S_UPDATER_UI_PATCH=6 -->
<!-- R76S_V110_LAYOUT -->
<%+header%>
<%
local dsp = require "luci.dispatcher"
local api_base = dsp.build_url("admin", "system", "r76s_updater", "api")
%>

<style>
.r76s-wrap {
    width: 100%;
    max-width: 1080px;
    margin: 0 auto;
    box-sizing: border-box;
}

.r76s-title {
    margin: 4px 0 16px;
}

.r76s-card {
    width: 100%;
    margin-top: 12px;
    box-sizing: border-box;
}

.r76s-section {
    padding: 18px 22px 22px;
    box-sizing: border-box;
}

.r76s-table {
    width: 100%;
    table-layout: fixed;
}

.r76s-table .td:first-child {
    width: 210px;
    font-weight: 600;
}

.r76s-mode {
    font-weight: 600;
}

.r76s-actions {
    display: flex;
    gap: 12px;
    flex-wrap: wrap;
    margin: 20px 0;
}

.r76s-actions .cbi-button {
    min-width: 140px;
}

.r76s-progress {
    width: 100%;
    height: 18px;
    border-radius: 9px;
    overflow: hidden;
    background: rgba(127,127,127,.18);
    position: relative;
}

.r76s-progress-bar {
    width: 0%;
    height: 100%;
    transition: width .35s ease;
    background: linear-gradient(90deg,#5e72e4,#825ee4);
}

.r76s-progress-text {
    margin-top: 7px;
    font-size: 12px;
    opacity: .8;
}

.r76s-pass {
    font-weight: 600;
}

.r76s-fail {
    font-weight: 600;
}

.r76s-muted {
    opacity: .7;
}

.r76s-install {
    margin: 26px 0 16px;
    text-align: center;
}

.r76s-install .cbi-button {
    min-width: 230px;
    min-height: 38px;
}

.r76s-install .cbi-button:disabled,
.r76s-actions .cbi-button:disabled {
    opacity: .45;
    cursor: not-allowed;
    filter: grayscale(1);
}

.r76s-message {
    margin-top: 14px;
    white-space: pre-wrap;
}

.r76s-notice {
    margin-top: 20px;
    padding: 15px 18px;
    border-radius: 8px;
    background: rgba(127,127,127,.10);
    line-height: 1.7;
}

.r76s-notice strong {
    font-size: 14px;
}

.r76s-notice ul {
    margin: 8px 0 0 20px;
}

.r76s-notice li {
    margin: 3px 0;
}

@media (max-width: 700px) {
    .r76s-section {
        padding: 14px;
    }

    .r76s-table .td:first-child {
        width: 130px;
    }

    .r76s-actions {
        display: block;
    }

    .r76s-actions .cbi-button {
        width: 100%;
        margin-bottom: 8px;
    }

    .r76s-install .cbi-button {
        width: 100%;
    }
}
</style>

<div class="r76s-wrap">

  <h2 class="r76s-title">R76S 在线升级</h2>

  <div class="cbi-map r76s-card">
    <div class="cbi-section r76s-section">

      <table class="table r76s-table">

        <tr class="tr">
          <td class="td">当前版本</td>
          <td class="td" id="r76s-current">读取中...</td>
        </tr>

        <tr class="tr">
          <td class="td">最新版本</td>
          <td class="td" id="r76s-latest">尚未检查</td>
        </tr>

        <tr class="tr">
          <td class="td">当前启动盘</td>
          <td class="td" id="r76s-boot">读取中...</td>
        </tr>

        <tr class="tr">
          <td class="td">升级方式</td>
          <td class="td r76s-mode">
            保留用户配置 + 增量补齐新版本内容
          </td>
        </tr>

        <tr class="tr">
          <td class="td">状态</td>
          <td class="td" id="r76s-status">读取中...</td>
        </tr>

      </table>

      <div class="r76s-actions">
        <button
          class="cbi-button cbi-button-action"
          id="r76s-check"
          type="button">
          检查更新
        </button>

        <button
          class="cbi-button cbi-button-apply"
          id="r76s-download"
          type="button"
          disabled>
          请先检查更新
        </button>
      </div>

      <table class="table r76s-table">

        <tr class="tr">
          <td class="td">下载进度</td>
          <td class="td">
            <div class="r76s-progress">
              <div
                class="r76s-progress-bar"
                id="r76s-progress-bar">
              </div>
            </div>

            <div
              class="r76s-progress-text"
              id="r76s-progress-text">
              0%
            </div>
          </td>
        </tr>

        <tr class="tr">
          <td class="td">SHA256</td>
          <td class="td" id="r76s-sha">
            — 未校验
          </td>
        </tr>

        <tr class="tr">
          <td class="td">Metadata</td>
          <td class="td" id="r76s-metadata">
            — 未校验
          </td>
        </tr>

        <tr class="tr">
          <td class="td">Sysupgrade</td>
          <td class="td" id="r76s-sysupgrade">
            — 未校验
          </td>
        </tr>

        <tr class="tr">
          <td class="td">启动盘安全检查</td>
          <td class="td" id="r76s-boot-safe">
            — 检查中
          </td>
        </tr>

      </table>

      <div class="r76s-install">
        <button
          class="cbi-button cbi-button-negative"
          id="r76s-install"
          type="button"
          disabled>
          请先检查更新
        </button>
      </div>

      <pre
        class="r76s-message"
        id="r76s-message"
        style="display:none"></pre>

      <div class="r76s-notice">
        <strong>
          在线升级：保留用户配置 + 增量补齐新版本内容
        </strong>

        <ul>
          <li>保留 LAN / WAN 网络设置。</li>
          <li>保留 PassWall / PassWall2 节点、订阅、规则和启用状态。</li>
          <li>保留 SmartDNS、AdGuard Home 和其他用户配置。</li>
          <li>新固件存在而当前系统缺失的固件管理内容会自动补齐。</li>
          <li>已经存在的内容不会重复添加。</li>
          <li>不会删除或覆盖用户已有的自定义内容。</li>
        </ul>
      </div>

    </div>
  </div>

</div>

<script type="text/javascript">
(function() {
  'use strict';

  var API = '<%=api_base%>';
  var pollTimer = null;
  var verifying = false;

  function byId(id) {
    return document.getElementById(id);
  }

  function request(action, method, done) {
    var xhr = new XMLHttpRequest();

    xhr.open(
      method || 'GET',
      API + '/' + action + '?_=' + Date.now(),
      true
    );

    xhr.setRequestHeader(
      'X-Requested-With',
      'XMLHttpRequest'
    );

    xhr.onreadystatechange = function() {
      if (xhr.readyState !== 4)
        return;

      var data = null;

      try {
        data = JSON.parse(xhr.responseText || '{}');
      }
      catch (e) {}

      if (!data)
        data = {
          ok: false,
          message: '返回数据解析失败'
        };

      if (done)
        done(data, xhr.status);
    };

    xhr.send(null);
  }

  function verifyText(state, okText, failText) {
    if (state === 'pass')
      return '<span class="r76s-pass">✓ ' +
        okText + '</span>';

    if (state === 'fail')
      return '<span class="r76s-fail">✗ ' +
        failText + '</span>';

    return '<span class="r76s-muted">— 未校验</span>';
  }

  function setBusy(button, busy, text) {
    button.disabled = !!busy;

    if (text)
      button.textContent = text;
  }

  function showMessage(text) {
    var el = byId('r76s-message');

    if (!text) {
      el.style.display = 'none';
      el.textContent = '';
      return;
    }

    el.style.display = 'block';
    el.textContent = text;
  }

  function render(s) {
    if (!s)
      return;

    byId('r76s-current').textContent =
      (s.current && s.current.revision) || '未知';

    byId('r76s-latest').textContent =
      s.checked
        ? ((s.latest && s.latest.revision) || '未知')
        : '尚未检查';

    byId('r76s-status').textContent =
      s.status_text || '未知';

    var boot = s.boot || {};

    byId('r76s-boot').textContent =
      (boot.medium || '未知') +
      ' (' + (boot.path || '未知') + ')';

    byId('r76s-boot-safe').innerHTML =
      verifyText(
        boot.safe ? 'pass' : 'fail',
        '通过',
        '未通过'
      );

    var pct =
      (s.download &&
       typeof s.download.percent === 'number')
        ? s.download.percent
        : 0;

    if (pct < 0)
      pct = 0;

    if (pct > 100)
      pct = 100;

    byId('r76s-progress-bar').style.width =
      pct + '%';

    byId('r76s-progress-text').textContent =
      pct.toFixed(pct % 1 ? 1 : 0) +
      '%' +
      (
        s.download && s.download.message
          ? ' · ' + s.download.message
          : ''
      );

    var verify = s.verify || {};

    byId('r76s-sha').innerHTML =
      verifyText(
        verify.sha256,
        '通过',
        '失败'
      );

    byId('r76s-metadata').innerHTML =
      verifyText(
        verify.metadata,
        '通过',
        '失败'
      );

    byId('r76s-sysupgrade').innerHTML =
      verifyText(
        verify.sysupgrade,
        '通过',
        '失败'
      );

    var downloading =
      s.download &&
      s.download.state === 'downloading';

    var downloadBtn = byId('r76s-download');

    if (downloading) {
      downloadBtn.disabled = true;
      downloadBtn.textContent = '正在下载...';
    }
    else if (!s.checked) {
      downloadBtn.disabled = true;
      downloadBtn.textContent = '请先检查更新';
    }
    else if (s.is_latest) {
      downloadBtn.disabled = true;
      downloadBtn.textContent = '已是最新版';
    }
    else if (s.update_available) {
      downloadBtn.disabled = false;
      downloadBtn.textContent = '下载固件';
    }
    else {
      downloadBtn.disabled = true;
      downloadBtn.textContent = '暂无可用更新';
    }

    var installBtn = byId('r76s-install');

    installBtn.disabled = !s.can_install;

    if (s.can_install) {
      installBtn.textContent =
        '在线升级并保留配置';
    }
    else if (!s.checked) {
      installBtn.textContent =
        '请先检查更新';
    }
    else if (s.is_latest) {
      installBtn.textContent =
        '已是最新版';
    }
    else if (s.update_available) {
      installBtn.textContent =
        '等待安全校验';
    }
    else {
      installBtn.textContent =
        '暂不可安装';
    }

    if (downloading) {
      startPolling();
    }
    else if (pollTimer) {
      clearInterval(pollTimer);
      pollTimer = null;
    }

    var downloadDone =
      s.download &&
      s.download.state === 'done';

    var neverVerified =
      verify.sha256 !== 'pass' &&
      verify.sha256 !== 'fail' &&
      verify.metadata !== 'pass' &&
      verify.metadata !== 'fail' &&
      verify.sysupgrade !== 'pass' &&
      verify.sysupgrade !== 'fail';

    if (
      downloadDone &&
      neverVerified &&
      !verifying
    ) {
      verifyFirmware();
    }
  }

  function refreshStatus() {
    request(
      'status',
      'GET',
      function(data) {
        if (data && data.status)
          render(data.status);
      }
    );
  }

  function startPolling() {
    if (pollTimer)
      return;

    pollTimer = setInterval(
      refreshStatus,
      1000
    );
  }

  function verifyFirmware() {
    if (verifying)
      return;

    verifying = true;

    byId('r76s-sha').textContent =
      '正在校验...';

    byId('r76s-metadata').textContent =
      '正在检查...';

    byId('r76s-sysupgrade').textContent =
      '正在检查...';

    request(
      'verify',
      'GET',
      function(data) {
        verifying = false;

        if (data && data.status)
          render(data.status);

        if (!data || !data.ok) {
          showMessage(
            (data &&
             data.verify &&
             data.verify.message) ||
            (data && data.message) ||
            '固件校验失败'
          );
        }
        else {
          showMessage(
            '固件安全校验完成：' +
            'SHA256、Metadata、Sysupgrade ' +
            '和启动盘安全检查全部通过。'
          );
        }
      }
    );
  }

  byId('r76s-check').onclick = function() {
    var btn = this;

    showMessage('');

    setBusy(
      btn,
      true,
      '检查中...'
    );

    request(
      'check',
      'GET',
      function(data) {
        setBusy(
          btn,
          false,
          '检查更新'
        );

        if (data && data.status)
          render(data.status);

        if (!data || !data.ok) {
          showMessage(
            (data && data.output) ||
            '检查更新失败'
          );
        }
      }
    );
  };

  byId('r76s-download').onclick = function() {
    var btn = this;

    if (btn.disabled)
      return;

    showMessage('');

    setBusy(
      btn,
      true,
      '准备下载...'
    );

    request(
      'download',
      'GET',
      function(data) {
        if (data && data.status)
          render(data.status);

        if (!data || !data.ok) {
          showMessage(
            (data && data.output) ||
            '启动下载失败'
          );

          refreshStatus();
          return;
        }

        startPolling();
      }
    );
  };

  byId('r76s-install').onclick = function() {
    if (this.disabled)
      return;

    var boot =
      byId('r76s-boot').textContent;

    if (
      !confirm(
        '确认在线升级并保留现有配置？\n\n' +
        '当前启动盘：' + boot + '\n' +
        '升级方式：保留用户配置 + 增量补齐新版本内容\n\n' +
        '升级过程中请勿断电。'
      )
    ) {
      return;
    }

    this.disabled = true;
    this.textContent =
      '正在启动升级...';

    showMessage(
      '正在重新校验镜像并启动 sysupgrade，' +
      '请勿断电。'
    );

    request(
      'install',
      'POST',
      function(data) {
        if (!data || !data.ok) {
          byId('r76s-install').textContent =
            '在线升级并保留配置';

          refreshStatus();

          showMessage(
            (data && data.message) ||
            '启动升级失败'
          );

          return;
        }

        showMessage(
          data.message ||
          '升级已启动，设备即将重启。'
        );

        byId('r76s-install').textContent =
          '设备正在升级...';
      }
    );
  };

  refreshStatus();

})();
</script>

<%+footer%>
'''

p.write_text(view)
PY_OTA_VIEW

# Theme-only OTA upgrade: preserve IDs, JS, SHA256/metadata/sysupgrade, and can_install.
V12_OTA_VIEW="${R76S_REPO_ROOT:-/r76s-repo}/build/local-arm64/v12-overlays/ota/index.htm"
test -s "$V12_OTA_VIEW"
cp "$V12_OTA_VIEW" "$VIEW"
grep -qF 'R76S_UPDATER_UI_PATCH=7' "$VIEW"
for id in r76s-check r76s-download r76s-install r76s-sha r76s-metadata r76s-sysupgrade; do
  grep -qF "id=\"$id\"" "$VIEW"
done
echo 'R76S_V12_OTA_THEME=STAGED_WITH_UNMODIFIED_SECURITY_GATES'

grep -qF 'R76S_UPDATER_UI_PATCH=6' "$CTRL"
grep -qF 'root=PARTUUID' "$CTRL"
grep -qF 'firmware.img.part' "$CTRL"
grep -qF '下载任务已启动' "$CTRL"
grep -qF 'R76S_V110_LAYOUT' "$VIEW"
grep -qF '保留用户配置 + 增量补齐新版本内容' "$VIEW"
grep -qF 'id="r76s-metadata"' "$VIEW"
grep -qF 'id="r76s-boot-safe"' "$VIEW"
grep -qF '在线升级并保留配置' "$VIEW"
grep -qF "downloadBtn.disabled = true" "$VIEW"
grep -qF 'r76s-ota-preserve-state' "$CTRL"
test -x "$PRESERVE_HELPER"
grep -qF 'r76s_ota_state.state.pending' "$PRESERVE_HELPER"
! grep -qF 'sysupgrade -n' "$CTRL"
grep -qF 'R76S V1.1.1 policy: SmartDNS is user-controlled.' "$POLICY"
grep -qF 'intentionally no automatic DNS/proxy configuration' "$BOOT_HOOK"

if grep -RnsE --exclude='r76s-ota-preserve-state' \
  'sysupgrade|dd[[:space:]].*of=/dev/|mmcblk[0-9]|partx[[:space:]]|fdisk[[:space:]]|sfdisk[[:space:]]|blkdiscard' \
  "$UPDATER_DIR/files/root"; then
  echo "ERROR: forbidden firmware/block-device operation in component updater."
  exit 1
fi

PKG_MK="$UPDATER_DIR/Makefile"
grep -qF '$(INSTALL_BIN)' "$PKG_MK"
