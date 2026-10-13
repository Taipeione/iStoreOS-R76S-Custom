module("luci.controller.r76s_adguardhome", package.seeall)

-- Always expose the installed package under Services, including when disabled
-- or not yet configured. This controller only reads local service state.
function index()
    local page = entry({"admin", "services", "r76s_adguardhome"},
        call("action_status"), _("AdGuard Home"), 60)
    page.dependent = false
end

function action_status()
    local fs = require "nixio.fs"
    local sys = require "luci.sys"
    local json = require "luci.jsonc"
    local installed = fs.access("/usr/bin/AdGuardHome", "x")
    local init_present = fs.access("/etc/init.d/adguardhome", "x")
    local enabled = init_present and
        sys.call("/etc/init.d/adguardhome enabled >/dev/null 2>&1") == 0
    local running = false
    local service = json.parse(sys.exec(
        "ubus call service list '{\"name\":\"adguardhome\"}' 2>/dev/null"))
    if type(service) == "table" and type(service.adguardhome) == "table" then
        for _, instance in pairs(service.adguardhome.instances or {}) do
            if type(instance) == "table" and instance.running == true then
                running = true
            end
        end
    end
    -- Also recognize a manually launched instance outside procd.
    if not running then
        running = sys.call("pgrep -x AdGuardHome >/dev/null 2>&1") == 0
    end
    local configured = false
    for _, path in ipairs({"/etc/adguardhome.yaml", "/etc/adguardhome/adguardhome.yaml"}) do
        local stat = fs.stat(path)
        if stat and stat.type == "reg" and stat.size > 0 then
            configured = true
        end
    end
    luci.template.render("r76s_adguardhome/status", { data = {
        installed = installed and "已安装" or "未安装",
        init = init_present and "可用" or "不可用",
        running = running and "运行中" or "已停止",
        enabled = enabled and "已启用" or "已关闭",
        configured = configured and "已有配置" or "尚未配置"
    } })
end
