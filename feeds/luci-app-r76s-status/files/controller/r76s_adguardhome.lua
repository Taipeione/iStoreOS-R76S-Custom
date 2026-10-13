module("luci.controller.r76s_adguardhome", package.seeall)

-- Read-only even when the service is disabled or not yet configured.
function index()
    local page = entry({"admin", "services", "r76s_adguardhome"},
        call("action_status"), _("AdGuard Home"), 60)
    page.dependent = false
end

function action_status()
    local fs = require "nixio.fs"
    local sys = require "luci.sys"
    local json = require "luci.jsonc"
    local model = require "luci.model.r76s.services"
    local installed = fs.access("/usr/bin/AdGuardHome", "x")
    local init_present = fs.access("/etc/init.d/adguardhome", "x")
    local enabled = init_present and
        sys.call("/etc/init.d/adguardhome enabled >/dev/null 2>&1") == 0
    local running, pids, paths = false, {}, {}
    local service = json.parse(sys.exec(
        "ubus call service list '{\"name\":\"adguardhome\"}' 2>/dev/null"))
    local instances = type(service) == "table" and type(service.adguardhome) == "table"
        and service.adguardhome.instances or {}
    if type(instances) ~= "table" then instances = {} end
    for _, instance in pairs(instances) do
        if type(instance) == "table" and instance.running == true then
            running = true
            if tonumber(instance.pid) then pids[tonumber(instance.pid)] = true end
            if type(instance.command) == "table" then
                for i, arg in ipairs(instance.command) do
                    if (arg == "-c" or arg == "--config") and
                       type(instance.command[i+1]) == "string" and
                       instance.command[i+1]:sub(1,1) == "/" then
                        paths[#paths + 1] = instance.command[i+1]
                    end
                end
            end
        end
    end
    for pid in sys.exec("pgrep -x AdGuardHome 2>/dev/null"):gmatch("%d+") do
        pids[tonumber(pid)] = true
    end
    paths[#paths + 1] = "/etc/adguardhome.yaml"
    paths[#paths + 1] = "/etc/adguardhome/adguardhome.yaml"
    local configured, dns_port, web_port = false, nil, nil
    for _, path in ipairs(paths) do
        local stat = fs.stat(path)
        if stat and stat.type == "reg" and stat.size > 0 then
            configured = true
            dns_port, web_port = model.adguard_ports(fs.readfile(path))
            break
        end
    end
    if not configured then web_port = 3000 end
    local available = sys.call("command -v netstat >/dev/null 2>&1") == 0
    local listeners = available and sys.exec("netstat -lnutp 2>/dev/null") or ""
    local health = model.adguard({installed=installed, enabled=enabled,
        configured=configured, procd_running=running, pids=pids,
        dns_port=dns_port, web_port=web_port, listeners=listeners,
        listener_available=available})
    require("luci.template").render("r76s_adguardhome/status", { data = {
        installed=installed and "已安装" or "未安装",
        init=init_present and "可用" or "不可用",
        running=health.state, enabled=enabled and "已启用" or "已关闭",
        configured=configured and "已有配置" or "未找到默认或服务声明的配置",
        dns_port=dns_port or "未知", web_port=health.web_port
    } })
end
