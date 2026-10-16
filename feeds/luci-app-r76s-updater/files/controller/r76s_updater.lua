module("luci.controller.r76s_updater", package.seeall)
-- R76S_UPDATER_UI_PATCH=4

local http = require "luci.http"
local sys = require "luci.sys"
local fs = require "nixio.fs"
local nixio = require "nixio"
local jsonc = require "luci.jsonc"

local VERIFY_STATE = "/tmp/r76s-ota-verify.state"
local META_FILE = "/tmp/r76s-ota.meta"
local FIRMWARE = "/tmp/firmware.img"
local INSTALL_UI_LOCK = "/tmp/r76s-ota-install-ui.lock"

function index()
    local root = entry({"admin", "system", "r76s_updater"}, firstchild(), _("R76S 在线升级"), 91)
    root.dependent = false

    local fw = entry({"admin", "system", "r76s_updater", "firmware"}, call("action_firmware"), _("固件升级"), 10)
    fw.dependent = false

    local comp = entry({"admin", "system", "r76s_updater", "components"}, call("action_components"), _("组件升级"), 20)
    comp.dependent = false

    entry({"admin", "system", "r76s_updater", "api", "status"}, call("api_status")).leaf = true
    entry({"admin", "system", "r76s_updater", "api", "check"}, post("api_check")).leaf = true
    entry({"admin", "system", "r76s_updater", "api", "download"}, post("api_download")).leaf = true
    entry({"admin", "system", "r76s_updater", "api", "verify"}, post("api_verify")).leaf = true
    entry({"admin", "system", "r76s_updater", "api", "install"}, post("api_install")).leaf = true
    entry({"admin", "system", "r76s_updater", "api", "channel"}, post("api_channel")).leaf = true
    entry({"admin", "system", "r76s_updater", "api", "backup"}, post("api_backup")).leaf = true
    entry({"admin", "system", "r76s_updater", "api", "restore"}, post("api_restore")).leaf = true

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

local function release_ui_install_lock()
    fs.remove(INSTALL_UI_LOCK .. "/pid")
    fs.rmdir(INSTALL_UI_LOCK)
end

local function acquire_ui_install_lock()
    if fs.mkdir(INSTALL_UI_LOCK) then
        local ok, pid = pcall(function() return nixio.getpid() end)
        fs.writefile(INSTALL_UI_LOCK .. "/pid", tostring(ok and pid or 0) .. "\n")
        return true
    end
    local pid = trim(readfile(INSTALL_UI_LOCK .. "/pid")):match("^(%d+)$")
    if pid and fs.access("/proc/" .. pid .. "/cmdline") then
        return false
    end
    release_ui_install_lock()
    if not fs.mkdir(INSTALL_UI_LOCK) then return false end
    local ok, newpid = pcall(function() return nixio.getpid() end)
    fs.writefile(INSTALL_UI_LOCK .. "/pid", tostring(ok and newpid or 0) .. "\n")
    return true
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

local function selected_channel()
    return "stable"
end

local function channel_label(channel)
    return "稳定版"
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
        "ota_signature=" .. (state.ota_signature or "not_checked"),
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
    local transaction = jsonc.parse(readfile("/tmp/r76s-ota/state.json")) or {}
    local partial_stat = part_exists and fs.stat("/tmp/firmware.img.part") or nil
    local downloaded_bytes = partial_stat and partial_stat.size or 0
    local total_bytes = tonumber(transaction.size) or 0
    local elapsed = 0
    if tonumber(transaction.started_at) then
        elapsed = math.max(0, os.time() - tonumber(transaction.started_at))
    end
    local speed = elapsed > 0 and downloaded_bytes / elapsed or 0
    local eta = speed > 0 and math.max(0, total_bytes - downloaded_bytes) / speed or 0
    local function mb(value) return string.format("%.1f", (value or 0) / 1024 / 1024) end
    local function duration(value)
        value = math.floor(value or 0)
        if value < 60 then return tostring(value) .. " 秒" end
        return tostring(math.floor(value / 60)) .. " 分 " .. tostring(value % 60) .. " 秒"
    end
    local percent = last_percent(progress_text) or 0
    local state = "idle"
    local message = "尚未下载"

    if firmware_exists and sum_file ~= "" and latest.sha256 ~= "" and sum_file == latest.sha256 then
        state = "done"
        percent = 100
        message = "下载完成"
    elseif part_exists then
        state = "downloading"
        if total_bytes > 0 then
            percent = math.min(99.9, downloaded_bytes * 100 / total_bytes)
            message = "已下载 " .. mb(downloaded_bytes) .. " / " .. mb(total_bytes) .. " MB；速度 " ..
                mb(speed) .. " MB/s；预计剩余 " .. duration(eta) .. "；正在续传"
        else
            message = "正在下载或续传"
        end
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
        size = st and st.size or downloaded_bytes,
        total = total_bytes,
        speed = speed,
        elapsed = elapsed,
        eta = eta
    }
end

local function build_status()
    local current = release_info()
    local channel = selected_channel()
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
    elseif verify.sha256 == "pass" and verify.ota_signature == "pass" and verify.sysupgrade == "pass" then
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
        channel = channel,
        channel_label = channel_label(channel),
        latest = latest,
        boot = boot,
        download = download,
        verify = {
            sha256 = verify.sha256 or "not_checked",
            metadata = verify.metadata or "not_checked",
            ota_signature = verify.ota_signature or "not_checked",
            sysupgrade = verify.sysupgrade or "not_checked"
        },
        checked = checked,
        is_latest = is_latest,
        update_available = update_available,
        status_text = status_text,
        can_install = update_available and boot.safe and download.state == "done" and verify.sha256 == "pass" and verify.metadata == "pass" and verify.ota_signature == "pass" and verify.sysupgrade == "pass"
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
        ota_signature = "fail",
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

    local signature_rc, signature_out = run_with_rc("/usr/libexec/r76s/r76s-ota verify 2>&1")
    if signature_rc ~= 0 then
        result.message = "OTA 签名校验失败：" .. (signature_out ~= "" and signature_out or ("RC=" .. signature_rc))
        save_verify_state(result)
        return result
    end
    result.ota_signature = "pass"

    local test_rc, test_out = run_with_rc("/sbin/sysupgrade -T " .. FIRMWARE .. " 2>&1")
    if test_rc ~= 0 then
        result.message = "sysupgrade 镜像兼容性检查失败：" .. (test_out ~= "" and test_out or ("RC=" .. test_rc))
        save_verify_state(result)
        return result
    end

    result.sysupgrade = "pass"
    result.ok = true
    result.message = "SHA256、metadata、OTA 签名、sysupgrade -T 全部通过。"
    save_verify_state(result)
    return result
end

function action_firmware()
    local template = require "luci.template"
    template.render("r76s_updater/index")
end

local valid = {
    passwall=true, passwall2=true, ['xray-core']=true, ['sing-box']=true,
    ['chinadns-ng']=true, smartdns=true, adguardhome=true, ['dnsmasq-full']=true,
    wireguard=true, ddns=true, upnp=true, docker=true, istore=true,
    quickstart=true, ['r76s-status']=true, ['r76s-updater']=true, ['r76s-health']=true
}

local function rows_from_tsv(text)
    local rows = {}
    for line in (text or ""):gmatch("[^\r\n]+") do
        local a,b,c,d,e,f,g,h,i,j,k = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
        if a then rows[#rows+1] = {id=a, name=b, category=c, current=d, remote=e, installed=f, running=g, autostart=h, backup=i, update=j, message=k} end
    end
    return rows
end

function action_components()
    local template = require "luci.template"
    local message = nil
    local action = http.formvalue("action")
    local id = http.formvalue("id")

    if valid[id] and (action == "update" or action == "restart" or action == "log") then
        message = sys.exec("/usr/libexec/r76s/r76s-component-updater " .. action .. " " .. id .. " 2>&1")
    end

    local mode = (http.formvalue("check") or http.formvalue("checkid")) and "check" or "status"
    local check_id = http.formvalue("checkid")
    local target = (check_id and valid[check_id]) and check_id or "all"
    local out = sys.exec("/usr/libexec/r76s/r76s-component-updater " .. mode .. " " .. target .. " 2>&1")
    template.render("r76s_updater/components", { rows=rows_from_tsv(out), result=message })
end

function api_status()
    json_reply({ ok=true, status=build_status() })
end

function api_channel()
    local channel = http.formvalue("channel") or ""
    if channel ~= "stable" then
        json_reply({ok=false, message="R76S-V1.4.5 只支持正式稳定 OTA 通道。", status=build_status()})
        return
    end

    local rc, out = run_with_rc("/usr/libexec/r76s/r76s-ota channel " .. channel .. " 2>&1")
    if rc == 0 then
        fs.remove(VERIFY_STATE)
        fs.remove(META_FILE)
    end
    json_reply({
        ok = rc == 0,
        rc = rc,
        channel = selected_channel(),
        output = out,
        status = build_status()
    })
end

function api_check()
    local rc, out = run_with_rc("/usr/libexec/r76s/r76s-ota check 2>&1")
    local success = (rc == 0)
    json_reply({
        ok = success,
        rc = rc,
        output = out,
        status = build_status()
    })
end

function api_download()
    if not latest_info().checked then
        run_with_rc("/usr/libexec/r76s/r76s-ota check >/tmp/r76s-ota-check.log 2>&1")
    end

    fs.remove(VERIFY_STATE)
    fs.remove(META_FILE)

    -- The large transfer runs in the backend transaction.  Return immediately
    -- so LuCI can poll the .part file and render progress/resume information.
    local rc, out = run_with_rc("( /usr/libexec/r76s/r76s-ota download >/tmp/r76s-ota-download.log 2>&1 ) </dev/null >/dev/null 2>&1 &")
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

-- R76S_V14_OTA_BACKEND: all install checks are serialized by the signed backend.
-- R76S_V12_OTA_HARDENING: preserve/flash sequencing is owned by r76s-ota.
function api_install()
    if not acquire_ui_install_lock() then
        json_reply({ok=false, message="升级请求正在处理中，请勿重复点击；请稍候查看状态。", status=build_status()})
        return
    end

    local ok, response = pcall(function()
        local current = release_info()
        local latest = latest_info()
        local boot = boot_info()

        if not latest.checked or current.key == latest.key then
            return {ok=false, message="当前已经是最新版，不执行重复刷写。"}
        end

        if not boot.safe then
            return {ok=false, message="当前启动盘识别异常，已阻止升级。"}
        end

        local verified = verify_image()
        if not verified.ok then
            return {ok=false, message=verified.message, status=build_status()}
        end

        -- The signed backend repeats manifest, device, state-preservation and
        -- boot-disk checks before any flash operation.
        local launch_rc, launch_out = run_with_rc("/usr/libexec/r76s/r76s-ota install 2>&1")
        return {
            ok = launch_rc == 0,
            message = launch_rc == 0 and
                ("升级已启动，目标为当前启动盘 " .. boot.medium .. " (" .. boot.path .. ")。设备将自动重启。") or
                (launch_out ~= "" and launch_out or "升级未启动，已保留当前配置。")
        }
    end)
    release_ui_install_lock()
    if not ok then
        json_reply({ok=false, message="升级事务异常，已释放锁并保留诊断日志。"})
    else
        json_reply(response)
    end
end

function api_backup()
    local backup = "/tmp/r76s-r76s-config-backup.tar.gz"
    fs.remove(backup)
    local rc, out = run_with_rc("/sbin/sysupgrade -b " .. backup .. " 2>&1")
    if rc ~= 0 or not fs.access(backup) then
        json_reply({ok=false, message="配置备份生成失败，请查看系统日志。" .. (out ~= "" and (" " .. out) or "")})
        return
    end
    http.prepare_content("application/gzip")
    http.header("Content-Disposition", 'attachment; filename="R76S-config-backup.tar.gz"')
    http.write(fs.readfile(backup) or "")
end

function api_restore()
    local archive = "/tmp/r76s-config-restore.tar.gz"
    local current = "/tmp/r76s-pre-restore-backup.tar.gz"
    local upload = nil
    local upload_error = nil
    fs.remove(archive)

    http.setfilehandler(function(meta, chunk, eof)
        if not meta or meta.name ~= "backup" then return end
        if meta.file and not upload then
            upload = io.open(archive, "w")
        end
        if upload and chunk and #chunk > 0 then
            if not upload:write(chunk) then upload_error = "无法写入上传文件。" end
        end
        if eof and upload then upload:close(); upload = nil end
    end)
    http.formvalue("token")
    if upload then upload:close(); upload = nil end
    if upload_error or not fs.access(archive) then
        json_reply({ok=false, message=upload_error or "未收到配置备份文件。"})
        return
    end

    local listing = sys.exec("tar -tzf " .. archive .. " 2>/dev/null") or ""
    local details = sys.exec("tar -tvzf " .. archive .. " 2>/dev/null") or ""
    -- Only accept the /etc tree emitted by sysupgrade -b.  Reject traversal,
    -- absolute paths, and links so a crafted archive cannot write elsewhere.
    if listing == "" or details == "" or listing:find("..", 1, true) or listing:sub(1, 1) == "/" or
       details:find(" -> ", 1, true) or details:find("\nl", 1, true) or details:sub(1, 1) == "l" or
       details:find("\nh", 1, true) or details:sub(1, 1) == "h" then
        fs.remove(archive)
        json_reply({ok=false, message="备份文件无效或包含不安全路径，已拒绝恢复。"})
        return
    end
    local invalid = false
    for path in listing:gmatch("[^\r\n]+") do
        if path:sub(1, 4) ~= "etc/" then invalid = true; break end
    end
    if invalid then
        fs.remove(archive)
        json_reply({ok=false, message="只允许恢复同设备生成的 /etc 配置备份。"})
        return
    end

    fs.remove(current)
    local backup_rc = run_with_rc("/sbin/sysupgrade -b " .. current .. " 2>&1")
    if backup_rc ~= 0 or not fs.access(current) then
        fs.remove(archive)
        json_reply({ok=false, message="恢复前保护性备份失败，未修改当前配置。"})
        return
    end
    local restore_rc, restore_out = run_with_rc("/sbin/sysupgrade -r " .. archive .. " 2>&1")
    fs.remove(archive)
    if restore_rc ~= 0 then
        json_reply({ok=false, message="恢复失败，当前配置保护备份保留在 " .. current .. "。" .. (restore_out ~= "" and (" " .. restore_out) or "")})
        return
    end
    json_reply({ok=true, message="配置已恢复；建议重启设备使网络、DNS 和服务状态完全生效。"})
end
