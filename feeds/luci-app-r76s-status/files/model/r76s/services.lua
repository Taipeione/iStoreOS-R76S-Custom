-- Pure read-only classifiers. Never return keys, YAML or raw process commands.
local M = {}

local function words(line)
    local fields = {}
    for value in line:gmatch("%S+") do fields[#fields + 1] = value end
    return fields
end

function M.wireguard(configured, live, handshakes, transfers, now, healthy)
    local interfaces = {}
    for _, item in ipairs(configured or {}) do
        interfaces[item.name] = { name=item.name, device=item.name,
            configured_peers=item.peers or 0, up=false, peers=0,
            recent=0, last=0, rx=0, tx=0, clients={}, client_map={} }
        for _, peer in ipairs(item.clients or {}) do
            local client = {label=peer.label, disabled=peer.disabled, stamp=0, rx=0, tx=0}
            interfaces[item.name].clients[#interfaces[item.name].clients+1] = client
            interfaces[item.name].client_map[peer.key] = client
        end
    end
    local devices = {}
    for _, item in ipairs(live or {}) do
        local row = interfaces[item.interface]
        if row then
            row.up = item.up == true
            row.device = item.l3_device or item.device or row.name
        end
    end
    for _, row in pairs(interfaces) do devices[row.device] = row end
    for line in (handshakes or ""):gmatch("[^\n]+") do
        local f = words(line)
        local row = devices[f[1]]
        local stamp = tonumber(f[3])
        if row and #f == 3 and stamp and stamp >= 0 then
            local client = row.client_map[f[2]]
            if not client then
                client = {label="运行 Peer " .. (#row.clients+1), stamp=0, rx=0, tx=0}
                row.clients[#row.clients+1]=client; row.client_map[f[2]]=client
            end
            client.stamp=stamp
            row.peers = row.peers + 1
            if stamp > row.last then row.last = stamp end
            if row.up and stamp > 0 and stamp <= now and now-stamp <= 180 then
                row.recent = row.recent + 1
            end
        end
    end
    for line in (transfers or ""):gmatch("[^\n]+") do
        local f = words(line)
        local row = devices[f[1]]
        local rx, tx = tonumber(f[3]), tonumber(f[4])
        if row and #f == 4 and rx and tx and rx >= 0 and tx >= 0 then
            row.rx = row.rx + rx; row.tx = row.tx + tx
            local client=row.client_map[f[2]]
            if client then client.rx=rx; client.tx=tx end
        end
    end
    local result = {}
    for _, row in pairs(interfaces) do
        if row.last == 0 then row.handshake = "尚无握手"
        elseif row.last > now then row.handshake = "系统时间待校准"
        else row.handshake = string.format("%d 秒前", now-row.last) end
        for _, client in ipairs(row.clients) do
            client.age=client.stamp > 0 and now-client.stamp or nil
            if healthy == false then client.state="检测失败"
            elseif not row.up then client.state="接口已停止"
            elseif client.disabled then client.state="配置已禁用"
            elseif client.stamp > now then client.state="系统时间待校准"
            elseif client.stamp == 0 then client.state="尚无握手"
            elseif now-client.stamp <= 180 then client.state="近期握手"
            else client.state="空闲 / 待确认" end
        end
        row.client_map=nil
        row.last = nil
        result[#result + 1] = row
    end
    table.sort(result, function(a,b) return a.name < b.name end)
    return result
end

local function port(value)
    local n = tonumber(value)
    if n and n >= 1 and n <= 65535 and n == math.floor(n) then return n end
end

function M.adguard_ports(yaml)
    local section, dns, web, legacy_web = "", nil, nil, nil
    for line in (yaml or ""):gmatch("[^\n]+") do
        line = line:gsub("%s+#.*$", "")
        if line:match("^%S") then section = line:match("^([%w_]+):") or "" end
        if section == "dns" then
            dns = port(line:match("^  port:%s*(%d+)%s*$")) or dns
        elseif section == "http" then
            web = port(line:match('^  address:%s*["\']?[^%s]+:(%d+)["\']?%s*#?.*$')) or web
        end
        legacy_web = port(line:match("^bind_port:%s*(%d+)%s*$")) or legacy_web
    end
    return dns, web or legacy_web
end

function M.adguard(s)
    local pids = s.pids or {}
    local running = s.procd_running or next(pids) ~= nil
    local ports, web_access, ownership_available = {}, false, false
    for line in (s.listeners or ""):gmatch("[^\n]+") do
        local f = words(line)
        local pid = f[#f] and f[#f]:match("^(%d+)/")
        if pid then ownership_available = true end
        if pid and pids[tonumber(pid)] and f[4] and f[1]:match("^[tu][cd]p") then
            local n = port(f[4]:match(":(%d+)$"))
            if n then
                ports[n] = true
                if n == s.web_port and f[1]:match("^tcp") and f[6] == "LISTEN" and
                   not f[4]:match("^127%.") and not f[4]:match(":127%.") and
                   not f[4]:match("^::1:") and not f[4]:match("^%[::1%]:") then
                    web_access = true
                end
            end
        end
    end
    local state
    if not s.installed then state = "未安装"
    elseif not running then state = s.enabled and "已启用但未运行" or "已关闭"
    elseif not s.configured then state = "运行中（未发现配置）"
    elseif not s.dns_port then state = "运行中（配置端口未知）"
    elseif ports[s.dns_port] then state = "DNS 端口已监听"
    elseif not s.listener_available or not ownership_available or next(pids) == nil then state = "运行中（端口未确认）"
    else state = "运行中（DNS 端口未就绪）" end
    return { state=state, running=running, dns_ready=ports[s.dns_port] == true,
        dns_port=s.dns_port, web_port=web_access and s.web_port or nil }
end

return M
