#!/usr/bin/env bash
# Original workflow step: Copy and fix R76S status package
# REVIEW REQUIRED: not yet adapted for local execution.

mkdir -p openwrt/package/custom

rm -rf \
  openwrt/package/custom/luci-app-r76s-status

cp -r \
  feeds/luci-app-r76s-status \
  openwrt/package/custom/

STATUS_DIR="openwrt/package/custom/luci-app-r76s-status"
STATUS_CTRL="$STATUS_DIR/files/controller/r76s_status.lua"
STATUS_VIEW="$STATUS_DIR/files/view/r76s_status/status.htm"

test -f "$STATUS_DIR/Makefile"
test -f "$STATUS_CTRL"
test -f "$STATUS_VIEW"

cat > "$STATUS_CTRL" <<'EOF_STATUS_CTRL'
module("luci.controller.r76s_status", package.seeall)

function index()
    local e = entry({"admin", "status", "r76s"}, call("action_status"), _("R76S 状态"), 90)
    e.dependent = false
end

local function trim(s)
    return (s or ""):gsub("%s+$", "")
end

local function running(cmd)
    local sys = require "luci.sys"
    return sys.call(cmd .. " >/dev/null 2>&1") == 0
end

function action_status()
    local sys = require "luci.sys"
    local data = {}

    data.model = "FriendlyElec NanoPi R76S"
    data.soc = "Rockchip RK3576"
    data.kernel = trim(sys.exec("uname -r 2>/dev/null"))
    data.arch = trim(sys.exec("uname -m 2>/dev/null"))
    data.uptime = trim(sys.exec("uptime 2>/dev/null"))
    data.load = trim(sys.exec("cut -d' ' -f1-3 /proc/loadavg 2>/dev/null"))
    data.mem = trim(sys.exec([[awk '/MemTotal:/{t=$2}/MemAvailable:/{a=$2} END{if(t>0){printf "%.0f / %.0f MB",(t-a)/1024,t/1024}}' /proc/meminfo 2>/dev/null]]))
    data.temp = trim(sys.exec("for f in /sys/class/thermal/thermal_zone*/temp; do [ -r \"$f\" ] && awk '{printf \"%.1f C\", $1/1000}' \"$f\" && break; done"))
    data.lan = trim(sys.exec("uci -q get network.lan.ipaddr 2>/dev/null"))
    data.wan = trim(sys.exec("ubus call network.interface.wan status 2>/dev/null | jsonfilter -e '@[\"ipv4-address\"][0].address' 2>/dev/null"))

    local smartdns_running = running("pgrep -f '[s]martdns'")
    local passwall_running = running("pgrep -f '/tmp/etc/passwall/'") or running("pgrep -f '[p]asswall/monitor.sh'")
    local passwall2_running = running("pgrep -f '/tmp/etc/passwall2/'") or running("pgrep -f '[p]asswall2/monitor.sh'")
    local adguard_running = running("pgrep -f '[A]dGuardHome'")

    data.smartdns = smartdns_running and "运行中" or "已停止"
    data.passwall = passwall_running and "运行中" or "已停止"
    data.passwall2 = passwall2_running and "运行中" or "已停止"
    data.adguard = adguard_running and "运行中" or "已停止"

    luci.template.render("r76s_status/status", { data = data })
end
EOF_STATUS_CTRL

cat > "$STATUS_VIEW" <<'EOF_STATUS_VIEW'
<%+header%>

<style>
.r76s-status-wrap{max-width:1080px;margin:0 auto}
.r76s-status-card{background:var(--background-color-high,#fff);border:1px solid rgba(127,127,127,.22);border-radius:12px;padding:18px 20px;margin-top:14px}
.r76s-status-card h3{margin-top:0}
.r76s-status-table{width:100%;border-collapse:collapse}
.r76s-status-table td{padding:9px 10px;border-bottom:1px solid rgba(127,127,127,.16)}
.r76s-status-table td:first-child{width:180px;font-weight:600}
.r76s-status-table tr:last-child td{border-bottom:0}
</style>

<div class="r76s-status-wrap">
  <h2>R76S 状态</h2>
  <div class="r76s-status-card">
    <h3>FriendlyElec NanoPi R76S / Rockchip RK3576</h3>
    <table class="r76s-status-table">
      <tr><td>设备</td><td><%=data.model%></td></tr>
      <tr><td>SoC</td><td><%=data.soc%></td></tr>
      <tr><td>架构</td><td><%=data.arch%></td></tr>
      <tr><td>内核</td><td><%=data.kernel%></td></tr>
      <tr><td>温度</td><td><%=data.temp%></td></tr>
      <tr><td>内存</td><td><%=data.mem%></td></tr>
      <tr><td>负载</td><td><%=data.load%></td></tr>
      <tr><td>LAN</td><td><%=data.lan%></td></tr>
      <tr><td>WAN</td><td><%=data.wan%></td></tr>
      <tr><td>运行时间</td><td><%=data.uptime%></td></tr>
      <tr><td>SmartDNS</td><td><%=data.smartdns%></td></tr>
      <tr><td>PassWall</td><td><%=data.passwall%></td></tr>
      <tr><td>PassWall2</td><td><%=data.passwall2%></td></tr>
      <tr><td>AdGuard Home</td><td><%=data.adguard%></td></tr>
    </table>
  </div>
</div>

<%+footer%>
EOF_STATUS_VIEW

grep -qF 'data.passwall2' "$STATUS_CTRL"
grep -qF 'data.adguard' "$STATUS_CTRL"
grep -qF 'MemAvailable' "$STATUS_CTRL"
# V1.2 status overlay is copied AFTER the V1.1.1 generator to avoid overwrite.
V12_STATUS_SRC="${R76S_REPO_ROOT:-/r76s-repo}/build/local-arm64/v12-overlays/status"
test -s "$V12_STATUS_SRC/r76s_status.lua"
test -s "$V12_STATUS_SRC/status.htm"
cp "$V12_STATUS_SRC/r76s_status.lua" "$STATUS_CTRL"
cp "$V12_STATUS_SRC/status.htm" "$STATUS_VIEW"
grep -qF 'DNS 监听端口' "$STATUS_VIEW"
grep -qF 'read-only status' "$STATUS_CTRL"
echo 'R76S_V12_STATUS=STAGED_READ_ONLY'

grep -qF 'PassWall2' "$STATUS_VIEW"
grep -qF 'AdGuard Home' "$STATUS_VIEW"
