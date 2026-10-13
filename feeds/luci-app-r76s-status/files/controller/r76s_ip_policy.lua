module("luci.controller.r76s_ip_policy", package.seeall)

function index()
    local page = entry({"admin", "services", "r76s_ip_policy"},
        call("action_status"), _("国内 / 国外 DNS 策略"), 61)
    page.dependent = false
end

function action_status()
    local fs = require "nixio.fs"
    local sys = require "luci.sys"
    local uci = require("luci.model.uci").cursor()
    local present = fs.access("/usr/libexec/r76s/r76s-ip-family-policy", "x")
    local result = present and sys.exec("/usr/libexec/r76s/r76s-ip-family-policy check 2>&1")
        or "策略工具未安装"
    local includes = uci:get_list("smartdns", "@smartdns[0]", "conf_files") or {}
    local selected = false
    for _, path in ipairs(includes) do
        if path == "/etc/smartdns/r76s-v13/ip-family.conf" then selected = true end
    end
    local guard_enabled = uci:get("r76s_ip_policy", "main", "ipv6_guard") == "1"
    local guard_rules = sys.exec("nft list table inet r76s_ip6_guard 2>/dev/null")
    local guard_active = guard_rules:find("R76S_V13_IPV6_GUARD", 1, true) ~= nil
    local guard_check = fs.access("/usr/libexec/r76s/r76s-ip6-guard", "x") and
        sys.exec("/usr/libexec/r76s/r76s-ip6-guard check 2>&1") or "IPv6 保护工具未安装"
    require("luci.template").render("r76s_ip_policy/status", { data = {
        selected=selected, result=result, guard_enabled=guard_enabled, guard_active=guard_active,
        guard_check=guard_check
    } })
end
