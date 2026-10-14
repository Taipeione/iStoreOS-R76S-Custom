-- Read-only classifiers. Inputs contain selected fields only; output never contains secrets.
local M={}
local function values(v)
    if type(v)=='table' then return v end
    local r={}; for x in tostring(v or ''):gmatch('%S+') do r[#r+1]=x end; return r
end
local function add(rows,title,level,detail,advice)
    rows[#rows+1]={title=title,level=level,detail=detail,advice=advice or ''}
end
local function target(value, local_ips)
    value=tostring(value or '')
    local conditional=value:sub(1,1)=='/'
    if conditional then value=value:match('^/.*/(.+)$') or '' end
    if value:match('^%[/') then conditional=true;value=value:match('^%[/.*/%](.*)$') or '' end
    if value=='' or value=='#' then return {label='本地区域 / 默认继承上游',unknown=true,conditional=conditional} end
    local scheme=value:match('^(%a+)://')
    if scheme then value=value:gsub('^%a+://',''):match('^[^/]+') or '' end
    -- Do not render URI credentials, tokens or raw upstream strings.
    if value:find('@',1,true) then return {label='上游含认证信息（已隐藏）',unknown=true,conditional=conditional} end
    local host,port=value:match('^%[([^%]]+)%][:#](%d+)$')
    if not host then host,port=value:match('^(.-)#(%d+)$') end
    if not host then host,port=value:match('^([^:#]+)[#:]([0-9]+)$') end
    if not host then host=value:match('^%[([^%]]+)%]$') or value end
    port=tonumber(port) or ((scheme=='https' and 443) or (scheme=='tls' and 853) or 53)
    local islocal=host=='localhost' or host=='::1' or host:match('^127%.%d+%.%d+%.%d+$') or (local_ips or {})[host]
    if islocal then return {port=port,label='本机 DNS :'..port,conditional=conditional} end
    return {label=scheme and ('外部 '..scheme:upper()..' 上游（地址隐藏）') or '外部 DNS 上游（地址隐藏）',conditional=conditional}
end
M.target=target

function M.dns(s)
    local rows, graph, ports = {}, {}, {}
    for _, node in ipairs(s.nodes or {}) do
        graph[node.name]={}
        if node.port==0 then
            add(rows,node.name,'info','DNS 监听端口为 0，DNS 解析功能已禁用。','可用于仅保留 DHCP；确认另有 DNS 服务监听 53。')
        else
            local owners=ports[node.port] or {}; ports[node.port]=owners; owners[#owners+1]=node
            local idle=node.enabled==false and not node.running
            local state=idle and '可选服务未启用' or not s.listeners_known and '端口归属未确认' or (node.listening and '进程所属端口已监听' or '未确认所属端口监听')
            add(rows,node.name..' · :'..node.port,idle and 'info' or not s.listeners_known and 'unknown' or (node.listening and 'pass' or 'warn'),
                (node.running and '检测到进程；' or '未检测到进程；')..state,
                not idle and not node.listening and '核对服务启用状态、实际监听地址与端口。' or '')
        end
    end
    for port,nodes in pairs(ports) do
        if #nodes>1 then add(rows,'端口共用 :'..port,'warn','多个 DNS 实例配置相同端口。','检查绑定地址；不同地址可共存，通配地址可能冲突。') end
    end
    for _,node in ipairs(s.nodes or {}) do
        if node.port~=0 then
            local labels={}
            for _,value in ipairs(node.upstreams or {}) do
                local t=target(value,s.local_ips); labels[#labels+1]=(t.conditional and '按域名：' or '')..t.label
                if t.port then
                    local candidates=ports[t.port] or {}
                    if #candidates==0 then
                        add(rows,node.name..' 本机上游 :'..t.port,'unknown','未识别该本机 DNS 实例。','可能是 PassWall 或自定义解析器，请核对运行配置及端口。')
                    else
                        for _,dest in ipairs(candidates) do
                            graph[node.name][#graph[node.name]+1]=dest.name
                            if not dest.listening then add(rows,node.name..' → '..dest.name,'warn','配置指向未确认监听的本机服务。','检查服务是否运行，避免 DNS 链路中断。') end
                        end
                    end
                end
            end
            add(rows,node.name..' 上游链路',#labels>0 and 'info' or 'unknown',
                #labels>0 and table.concat(labels,'；') or '未识别上游配置。',
                '此项按已读取配置推导；运行时重写、条件规则和加密 DNS 可能改变路径。')
            if node.noresolv and #(node.upstreams or {})==0 then
                add(rows,node.name..' 默认解析出口','warn','已禁用 resolv 文件，未配置 server 上游。','检查是否由额外运行时配置提供上游。')
            elseif node.noresolv and #(node.upstreams or {})>0 then
                local unconditional=false
                for _,v in ipairs(node.upstreams) do if tostring(v):sub(1,1)~='/' then unconditional=true end end
                if not unconditional then add(rows,node.name..' 默认解析出口','warn','仅识别按域名转发规则，未识别默认上游。','检查其他域名的默认解析出口。') end
            end
        end
    end
    local seen,active={},{}
    local function walk(name)
        if active[name] then return true end
        if seen[name] then return false end
        active[name]=true
        for _,dest in ipairs(graph[name] or {}) do if walk(dest) then return true end end
        active[name]=nil; seen[name]=true; return false
    end
    local cycle=false; for name in pairs(graph) do if walk(name) then cycle=true;break end end
    add(rows,'本机 DNS 回环',cycle and 'warn' or 'info',cycle and '检测到可能的本机 DNS 转发回环。' or '已识别链路中未发现回环。',
        '条件规则、不同绑定地址及未解析的 include 需要人工确认；这不是 DNS 查询成功证明。')
    local system_labels={}
    for _,value in ipairs(s.system_upstreams or {}) do system_labels[#system_labels+1]=target(value,s.local_ips).label end
    add(rows,'系统 DNS 入口',#system_labels>0 and 'info' or 'unknown',#system_labels>0 and table.concat(system_labels,'；') or '未识别系统 resolv.conf 的 nameserver。','系统进程与 LAN 客户端可能采用不同 DNS 入口。')
    add(rows,'WAN DNS',s.wan_dns_count>0 and 'info' or 'unknown','运行接口报告 '..s.wan_dns_count..' 个上游 DNS 地址。','配置固定上游时不依赖 WAN 下发 DNS。')
    if s.passwall and s.passwall2 then add(rows,'双代理并行','warn','PassWall 和 PassWall2 均配置启用。','核对各自 DNS 端口、透明代理规则及防火墙接管范围。') end
    if s.incomplete then add(rows,'配置覆盖范围','unknown','存在未解析的运行时配置或 include。','需结合原生服务页面核对；页面不读取订阅、节点密码或完整配置。') end
    return rows
end

local function match_port(value,port)
    if value==nil or value=='' then return true end
    for _,v in ipairs(values(value)) do
        local low,high=v:match('^(%d+)[:%-](%d+)$')
        if tonumber(v)==port or (low and port>=tonumber(low) and port<=tonumber(high)) then return true end
    end
    return false
end
function M.security(s)
    local rows={}
    local password=s.password_state or 'unknown'
    local labels={empty='root 未设置密码。',default='root 仍使用固件默认密码。',locked='root 密码登录已锁定。',set='已设置 root 密码，且未匹配已知默认密码。',unknown='无法确认 root 密码状态。'}
    add(rows,'root 认证','unknown',labels[password] or labels.unknown,'请在系统管理中核对密码及 SSH 密钥。')
    -- Explicit precedence: empty/default must be warnings, configured/locked are limited passes.
    rows[#rows].level=(password=='empty' or password=='default') and 'warn' or ((password=='set' or password=='locked') and 'pass' or 'unknown')
    add(rows,'防火墙运行状态',s.firewall_active and 'pass' or 'unknown',s.firewall_active and '检测到 fw4 规则表。' or '未确认 fw4 规则表已加载。','运行表存在不代表所有自定义规则均安全。')
    local wan_zones={}
    for _,zone in ipairs(s.zones or {}) do
        local iswan=zone.name=='wan'
        for _,network in ipairs(values(zone.network)) do if network=='wan' or network=='wan6' or network=='wan_6' then iswan=true end end
        if iswan and zone.enabled~='0' then
            local name=zone.name or '未命名区域'
            wan_zones[name]=true
            local input=zone.input or s.default_input
            local forward=zone.forward or s.default_forward
            local closed=input=='REJECT' or input=='DROP'
            add(rows,'WAN 区域 '..name..' 入站',closed and 'pass' or 'warn','默认 input = '..tostring(input or '未确认'),'核对显式允许规则、自定义 nft 规则和 IPv6 入站。')
            add(rows,'WAN 区域 '..name..' 转发',(forward=='REJECT' or forward=='DROP') and 'pass' or 'warn','默认 forward = '..tostring(forward or '未确认'),'主路由通常应显式允许 LAN → WAN，而非开放 WAN 转发。')
        end
    end
    if next(wan_zones)==nil then add(rows,'WAN 防火墙区域','unknown','未识别 wan/wan_6/wan6 所属区域。','检查自定义网络和防火墙区域映射。') end
    local function tcp(proto)
        if not proto or proto=='' then return true end
        for _,v in ipairs(values(proto)) do if v=='tcp' or v=='all' or v=='tcpudp' then return true end end
        return false
    end
    local exposed=0
    for _,rule in ipairs(s.rules or {}) do
        if rule.enabled~='0' and rule.target=='ACCEPT' and tcp(rule.proto) and (rule.dest==nil or rule.dest=='') and
            (wan_zones[rule.src] or rule.src=='*' or rule.src==nil or rule.src=='') then
            local hits={}
            for _,port in ipairs(s.management_ports or {22,80,443}) do
                if match_port(rule.dest_port,port) then hits[#hits+1]=tostring(port) end
            end
            if #hits>0 then
                exposed=exposed+1
                add(rows,'管理端口允许规则 '..(rule.name or '未命名'),'warn','配置允许 WAN/全局入站到端口 '..table.concat(hits,', ')..'。',
                    '源 IP、协议、目标地址及运行规则可能限制范围；请核对是否确需远程管理。')
            end
        end
    end
    for _,rule in ipairs(s.rules or {}) do
        local dns_proto=rule.proto==nil or rule.proto==''
        for _,v in ipairs(values(rule.proto)) do if v=='tcp' or v=='udp' or v=='all' or v=='tcpudp' then dns_proto=true end end
        if dns_proto and rule.enabled~='0' and rule.target=='ACCEPT' and
            (rule.dest==nil or rule.dest=='') and (wan_zones[rule.src] or rule.src=='*' or rule.src==nil or rule.src=='') and match_port(rule.dest_port,53) then
            add(rows,'WAN DNS 允许规则 '..(rule.name or '未命名'),'warn','配置可能允许 WAN 访问本机 DNS 端口 53。','检查源地址限制及 DNS 监听范围，避免开放解析服务。')
        end
    end
    if exposed==0 then add(rows,'管理端口允许规则','info','未在已读取 UCI input 规则中发现管理端口开放。','不覆盖自定义 nft include、UPnP 或端口转发；不是 WAN 不可达证明。') end
    add(rows,'管理服务绑定',s.management_wildcard and 'info' or 'unknown',s.management_wildcard and '管理服务存在通配地址监听配置。' or '未识别通配地址监听配置。','实际可达性取决于服务运行状态和防火墙。')
    if s.upnp then add(rows,'自动端口映射','warn','UPnP 配置启用。','确认需要自动端口映射的设备和授权范围。') end
    if s.redirect_count>0 then add(rows,'端口转发','info','配置了 '..s.redirect_count..' 条端口转发。','在防火墙页面核对暴露的内部服务。') end
    add(rows,'WAN 链路',s.wan_up and 'info' or 'unknown',s.wan_up and '检测到 WAN/wan_6/wan6 接口运行。' or '未确认 WAN/wan_6/wan6 接口运行。','自定义接口名称需人工核对。')
    if s.proxy_enabled then
        add(rows,'代理 IPv6 出站保护',s.guard_active and 'info' or 'warn',s.guard_active and '检测到独立 IPv6 出站保护规则。' or '代理已配置启用，未检测到独立 IPv6 出站保护规则。','规则存在不等于实测无绕过；结合 DNS 策略和出口测试确认。')
        if s.guard_active and s.offload then add(rows,'IPv6 保护与流量卸载','warn','IPv6 保护规则存在，同时配置流量卸载。','核对卸载是否绕过保护；使用 Phase2.1 预检。') end
    end
    return rows
end
return M
