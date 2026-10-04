module("luci.controller.r76s_updater", package.seeall)
-- R76S_UPDATER_UI_PATCH=3

local http = require "luci.http"
local sys = require "luci.sys"
local fs = require "nixio.fs"
local jsonc = require "luci.jsonc"

local VERIFY_STATE = "/tmp/r76s-ota-verify.state"
local META_FILE = "/tmp/r76s-ota.meta"
local FIRMWARE = "/tmp/firmware.img"

function index()
    local root = entry({"admin", "system", "r76s_updater"}, firstchild(), _("R76S 在线升级"), 91)
    root.dependent = false

    local fw = entry({"admin", "system", "r76s_updater", "firmware"}, call("action_firmware"), _("固件升级"), 10)
    fw.dependent = false

    local comp = entry({"admin", "system", "r76s_updater", "components"}, call("action_components"), _("组件升级"), 20)
    comp.dependent = false

    entry({"admin", "system", "r76s_updater", "api", "status"}, call("api_status")).leaf = true
    entry({"admin", "system", "r76s_updater", "api", "check"}, call("api_check")).leaf = true
    entry({"admin", "system", "r76s_updater", "api", "download"}, call("api_download")).leaf = true
    entry({"admin", "system", "r76s_updater", "api", "verify"}, call("api_verify")).leaf = true
    entry({"admin", "system", "r76s_updater", "api", "install"}, call("api_install")).leaf = true

    -- Keep the old component-updater URL usable after moving the UI under System.
    local legacy = entry({"admin", "services", "r76s_updater"}, alias("admin", "system", "r76s_updater", "components"), nil)
    legacy.dependent = false
end

local function trim(s)
    return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function readfile(path)
    return fs.readfile(path) or ""
end

local function run_with_rc(cmd)
    local marker = "__R76S_RC__"
    local out = sys.exec("(" .. cmd .. "); rc=$?; printf '\\n" .. marker .. "%s\\n' \"$rc\"") or ""
    local rc = tonumber(out:match("\n" .. marker .. "(%d+)%s*$")) or 255
    out = out:gsub("\n" .. marker .. "%d+%s*$", "")
    return rc, trim(out)
end

local function release_info()
    local text = readfile("/etc/openwrt_release")
    local release = text:match("DISTRIB_RELEASE='([^']*)'") or "unknown"
    local revision = text:match("DISTRIB_REVISION='([^']*)'") or "unknown"
    local target = text:match("DISTRIB_TARGET='([^']*)'") or "unknown"
    return {
        release = release,
        revision = revision,
        target = target,
        key = release .. "-" .. revision
    }
end

local function latest_info()
    local text = readfile("/var/run/ota/ota.latest")
    if text == "" then
        return { checked = false }
    end

    local first = text:match("([^\r\n]+)") or ""
    local key, image = first:match("^%[([^%]]+)%]%(([^%)]+)%)")
    local sha = text:match("SHA256:%s*([0-9a-fA-F]+)")
    local revision = key and key:match("(V[%w%.%-_]+)$") or nil

    return {
        checked = key ~= nil,
        key = key or "",
        revision = revision or key or "",
        image = image or "",
        sha256 = sha or ""
    }
end

local function boot_info()
    local data = readfile("/tmp/.bootdisk")
    local dev = data:match("DEVNAME=([^\r\n]+)") or ""
    local romdev = ""

    for line in readfile("/proc/mounts"):gmatch("[^\r\n]+") do
        local src, mnt = line:match("^(%S+)%s+(%S+)")
        if mnt == "/rom" then
            romdev = src or ""
            break
        end
    end

    local medium = "未知"
    if dev == "mmcblk0" then
        medium = "TF"
    elseif dev == "mmcblk2" then
        medium = "eMMC"
    end

    local safe = (dev == "mmcblk0" or dev == "mmcblk2") and romdev:find("/dev/" .. dev, 1, true) == 1

    return {
        device = dev,
        path = dev ~= "" and ("/dev/" .. dev) or "未知",
        medium = medium,
        rom = romdev ~= "" and romdev or "未知",
        safe = safe and true or false
    }
end

local function parse_verify_state()
    local state = {}
    for line in readfile(VERIFY_STATE):gmatch("[^\r\n]+") do
        local k, v = line:match("^([%w_]+)=(.*)$")
        if k then state[k] = v end
    end
    return state
end

local function save_verify_state(state)
    local lines = {
        "sha256=" .. (state.sha256 or "not_checked"),
        "metadata=" .. (state.metadata or "not_checked"),
        "sysupgrade=" .. (state.sysupgrade or "not_checked"),
        "actual_sha=" .. (state.actual_sha or "")
    }
    fs.writefile(VERIFY_STATE, table.concat(lines, "\n") .. "\n")
end

local function last_percent(text)
    local p = nil
    for n in (text or ""):gmatch("([0-9]+%.?[0-9]*)%%") do
        p = tonumber(n)
    end
    if p and p > 100 then p = 100 end
    return p
end

local function download_info(latest)
    local firmware_exists = fs.access(FIRMWARE) and true or false
    local part_exists = fs.access("/tmp/firmware.img.part") and true or false
    local progress_exists = fs.access("/tmp/firmware.img.progress") and true or false
    local sum_file = trim(readfile("/tmp/firmware.img.sha256sum"))
    local progress_text = readfile("/tmp/firmware.img.progress")
    local percent = last_percent(progress_text) or 0
    local state = "idle"
    local message = "尚未下载"

    if firmware_exists and sum_file ~= "" and latest.sha256 ~= "" and sum_file == latest.sha256 then
        state = "done"
        percent = 100
        message = "下载完成"
    elseif part_exists then
        state = "downloading"
        message = "正在下载"
    elseif progress_exists then
        state = "failed"
        message = trim(progress_text:match("([^\r\n]+)%s*$") or "下载失败")
    elseif firmware_exists then
        state = "downloaded"
        message = "固件文件已存在，等待校验"
    end

    local st = firmware_exists and fs.stat(FIRMWARE) or nil

    return {
        state = state,
        message = message,
        percent = percent,
        firmware_exists = firmware_exists,
        size = st and st.size or 0
    }
end

local function build_status()
    local current = release_info()
    local latest = latest_info()
    local boot = boot_info()
    local download = download_info(latest)
    local verify = parse_verify_state()

    local checked = latest.checked and true or false
    local is_latest = checked and current.key == latest.key or false
    local update_available = checked and not is_latest or false
    local status_text = "尚未检查"

    if checked then
        if is_latest then
            status_text = "已是最新版"
        else
            status_text = "发现新版本 " .. (latest.revision or latest.key)
        end
    end

    if download.state == "downloading" then
        status_text = "正在下载固件"
    elseif download.state == "done" and verify.sysupgrade ~= "pass" then
        status_text = "下载完成，正在等待安全校验"
    elseif verify.sha256 == "pass" and verify.sysupgrade == "pass" then
        if update_available then
            status_text = "固件已通过安全校验，可以安装"
        elseif is_latest then
            status_text = "已是最新版 · 镜像校验通过"
        else
            status_text = "当前版本镜像校验通过"
        end
    end

    return {
        current = current,
        latest = latest,
        boot = boot,
        download = download,
        verify = {
            sha256 = verify.sha256 or "not_checked",
            metadata = verify.metadata or "not_checked",
            sysupgrade = verify.sysupgrade or "not_checked"
        },
        checked = checked,
        is_latest = is_latest,
        update_available = update_available,
        status_text = status_text,
        can_install = update_available and boot.safe and download.state == "done" and verify.sha256 == "pass" and verify.metadata == "pass" and verify.sysupgrade == "pass"
    }
end

local function json_reply(data)
    http.prepare_content("application/json")
    http.write(jsonc.stringify(data))
end

local function verify_image()
    local latest = latest_info()
    local result = {
        ok = false,
        sha256 = "fail",
        metadata = "fail",
        sysupgrade = "fail",
        message = ""
    }

    if not fs.access(FIRMWARE) then
        result.message = "未找到 /tmp/firmware.img，请先下载固件。"
        save_verify_state(result)
        return result
    end

    if not latest.checked or latest.sha256 == "" then
        result.message = "没有有效的 OTA 版本信息，请先检查更新。"
        save_verify_state(result)
        return result
    end

    local actual = trim(sys.exec("sha256sum " .. FIRMWARE .. " 2>/dev/null | awk '{print $1}'"))
    result.actual_sha = actual

    if actual == "" or actual ~= latest.sha256 then
        result.message = "SHA256 校验失败。"
        save_verify_state(result)
        return result
    end
    result.sha256 = "pass"

    fs.remove(META_FILE)
    local meta_rc = run_with_rc("fwtool -q -i " .. META_FILE .. " " .. FIRMWARE .. " >/dev/null 2>&1")
    local meta = readfile(META_FILE)
    if meta_rc ~= 0 or meta == "" or not meta:find('"friendlyarm,nanopi-r76s"', 1, true) or not meta:find('"rockchip/armv8"', 1, true) then
        result.message = "固件 metadata 校验失败。"
        save_verify_state(result)
        return result
    end
    result.metadata = "pass"

    local test_rc, test_out = run_with_rc("/sbin/sysupgrade -T " .. FIRMWARE .. " 2>&1")
    if test_rc ~= 0 then
        result.message = "sysupgrade 镜像兼容性检查失败：" .. (test_out ~= "" and test_out or ("RC=" .. test_rc))
        save_verify_state(result)
        return result
    end

    result.sysupgrade = "pass"
    result.ok = true
    result.message = "SHA256、metadata、sysupgrade -T 全部通过。"
    save_verify_state(result)
    return result
end

function action_firmware()
    local template = require "luci.template"
    template.render("r76s_updater/index")
end

local valid = { passwall=true, smartdns=true, adguardhome=true, uu=true }

local function rows_from_tsv(text)
    local rows = {}
    for line in (text or ""):gmatch("[^\r\n]+") do
        local a,b,c,d,e,f = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
        if a then rows[#rows+1] = {id=a, name=b, current=c, remote=d, update=e, message=f} end
    end
    return rows
end

function action_components()
    local template = require "luci.template"
    local message = nil
    local action = http.formvalue("action")
    local id = http.formvalue("id")

    if action == "update" and valid[id] then
        message = sys.exec("/usr/libexec/r76s/r76s-component-updater update " .. id .. " 2>&1")
    end

    local mode = http.formvalue("check") and "check" or "status"
    local out = sys.exec("/usr/libexec/r76s/r76s-component-updater " .. mode .. " all 2>&1")
    template.render("r76s_updater/components", { rows=rows_from_tsv(out), result=message })
end

function api_status()
    json_reply({ ok=true, status=build_status() })
end

function api_check()
    local rc, out = run_with_rc("/bin/ota check 2>&1")
    local success = (rc == 0 or rc == 1)
    json_reply({
        ok = success,
        rc = rc,
        output = out,
        status = build_status()
    })
end

function api_download()
    if not latest_info().checked then
        run_with_rc("/bin/ota check >/tmp/r76s-ota-check.log 2>&1")
    end

    fs.remove(VERIFY_STATE)
    fs.remove(META_FILE)

    local rc, out = run_with_rc("/bin/ota download 2>&1")
    json_reply({
        ok = rc == 0,
        rc = rc,
        output = out,
        status = build_status()
    })
end

function api_verify()
    local result = verify_image()
    json_reply({ ok=result.ok, verify=result, status=build_status() })
end

function api_install()
    local current = release_info()
    local latest = latest_info()
    local boot = boot_info()

    if not latest.checked or current.key == latest.key then
        json_reply({ ok=false, message="当前已经是最新版，不执行重复刷写。" })
        return
    end

    if not boot.safe then
        json_reply({ ok=false, message="当前启动盘识别异常，已阻止升级。" })
        return
    end

    local verified = verify_image()
    if not verified.ok then
        json_reply({ ok=false, message=verified.message, status=build_status() })
        return
    end

    -- No mmc device is hard-coded here. platform.sh/sysupgrade resolves and writes
    -- only the current boot disk (TF when booted from TF, eMMC when booted from eMMC).
    sys.call("(sleep 2; /sbin/sysupgrade " .. FIRMWARE .. " >/tmp/r76s-sysupgrade.log 2>&1) >/dev/null 2>&1 &")

    json_reply({
        ok = true,
        message = "升级已启动，目标为当前启动盘 " .. boot.medium .. " (" .. boot.path .. ")。设备将自动重启。"
    })
end
