module("luci.controller.r76s_status", package.seeall)
-- R76S V1.2: read-only status, no calls to modify router configuration.
function index()
    local e = entry({"admin", "status", "r76s"}, call("action_status"), _("R76S 状态中心"), 90)
    e.dependent = false
    entry({"admin","status","r76s","data"},call("action_data")).leaf=true
end
local function query(cmd)
    local s = require("luci.sys").exec(cmd) or ""
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end
local function running(cmd)
    return require("luci.sys").call(cmd .. " >/dev/null 2>&1") == 0 and "运行中" or "已停止"
end
local function snapshot()
    local d = {}
    d.model = "FriendlyElec NanoPi R76S"
    d.soc = "Rockchip RK3576"
    d.kernel = query("uname -r 2>/dev/null")
    d.arch = query("uname -m 2>/dev/null")
    d.uptime = query("uptime 2>/dev/null")
    d.load = query("cut -d' ' -f1-3 /proc/loadavg 2>/dev/null")
    d.mem = query([[awk '/MemTotal:/{t=$2}/MemAvailable:/{a=$2} END{if(t>0)printf "%.0f / %.0f MiB",(t-a)/1024,t/1024}' /proc/meminfo 2>/dev/null]])
    d.temp = query([[for f in /sys/class/thermal/thermal_zone*/temp; do [ -r "$f" ] && awk '{printf "%.1f C", $1/1000}' "$f" && break; done]])
    d.lan = query([[ubus call network.interface.lan status 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null]])
    if d.lan == "" then d.lan = query("uci -q get network.lan.ipaddr 2>/dev/null") end
    d.wan = query([[ubus call network.interface.wan status 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null]])
    d.storage = query([[df -h /overlay 2>/dev/null | awk 'NR==2{print $3 " / " $2 " (" $5 ")"}']])
    d.smartdns = running("pgrep -f '[s]martdns'")
    d.passwall = running("pgrep -f '/tmp/etc/passwall/'")
    d.passwall2 = running("pgrep -f '/tmp/etc/passwall2/'")
    d.adguard = running("pgrep -f '[A]dGuardHome'")
    d.dnsmasq = running("pgrep -f '[d]nsmasq'")
    d.dns_upstream = query([[uci -q get dhcp.@dnsmasq[0].extraconftext 2>/dev/null | grep -m1 '^server=' 2>/dev/null]])
    if d.dns_upstream == "" then d.dns_upstream = "未检测到固定上游" end
    d.dns_manager = query("uci -q get r76s.main.dns_active 2>/dev/null")
    local v6if = query([[ubus call network.interface.wan_6 status 2>/dev/null | jsonfilter -e '@.up' 2>/dev/null]]) == 'true' and 'wan_6' or 'wan6'
    d.ipv6_interface = v6if
    d.wan6 = query("ubus call network.interface."..v6if..[[ status 2>/dev/null | jsonfilter -e '@["ipv6-address"][*].address' 2>/dev/null]])
    d.pd = query("ubus call network.interface."..v6if..[[ status 2>/dev/null | jsonfilter -e '@["ipv6-prefix"][*].address' 2>/dev/null]])
    d.cpu = query("head -n1 /proc/stat")
    d.services = {}
    for _,name in ipairs({'passwall','passwall2','smartdns','adguardhome'}) do
        local key=name=='smartdns' and 'smartdns.@smartdns[0].enabled' or (name..'.@global[0].enabled')
        d.services[#d.services+1]={name=name,
            configured=name=='adguardhome' and 'YAML/init' or query("uci -q get '"..key.."' 2>/dev/null"),
            autostart=running('/etc/init.d/'..name..' enabled')=='运行中',
            runtime=name=='adguardhome' and d.adguard or d[name]}
    end
    d.dns_listeners = query("ss -lnut 2>/dev/null | grep -E '(:53|:3053|:6053)[[:space:]]' | awk '{print $5}' | sort -u | tr '\\n' ' '")
    if d.dns_listeners == "" then d.dns_listeners = "未检测到（需进一步检查）" end
    return d
end

function action_status()
    luci.template.render("r76s_status/status", {data=snapshot()})
end
function action_data()
    local http=require 'luci.http'
    http.header('Cache-Control','no-store')
    http.prepare_content('application/json')
    http.write_json(snapshot())
end
