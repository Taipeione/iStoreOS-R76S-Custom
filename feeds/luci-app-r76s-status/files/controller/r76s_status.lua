module("luci.controller.r76s_status", package.seeall)

function index()
    local e = entry({"admin", "status", "r76s"}, call("action_status"), _("R76S 状态"), 90)
    e.dependent = false
end

local function trim(s)
    return (s or ""):gsub("%s+$", "")
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
    data.mem = trim(sys.exec("free -m 2>/dev/null | awk '/^Mem:/{print $3 \" / \" $2 \" MB\"}'"))
    data.temp = trim(sys.exec("for f in /sys/class/thermal/thermal_zone*/temp; do [ -r \"$f\" ] && awk '{printf \"%.1f C\", $1/1000}' \"$f\" && break; done"))
    data.lan = trim(sys.exec("uci -q get network.lan.ipaddr 2>/dev/null"))
    data.wan = trim(sys.exec("ubus call network.interface.wan status 2>/dev/null | jsonfilter -e '@[\"ipv4-address\"][0].address' 2>/dev/null"))
    data.smartdns = trim(sys.exec("/usr/libexec/r76s/smartdns.bin -v 2>&1 | head -n1"))
    data.passwall = trim(sys.exec("/etc/init.d/passwall status 2>/dev/null || true"))
    luci.template.render("r76s_status/status", { data = data })
end
