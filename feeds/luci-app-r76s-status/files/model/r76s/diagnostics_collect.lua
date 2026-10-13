-- All commands are fixed read-only probes. Never shell-interpolate configuration values.
local M={}
function M.snapshot()
    local fs=require 'nixio.fs'
    local sys=require 'luci.sys'
    local json=require 'luci.jsonc'
    local uci=require('luci.model.uci').cursor()
    local services=require 'luci.model.r76s.services'
    local function read(path)
        local stat=fs.stat(path)
        if not stat or stat.type~='reg' or stat.size>524288 then return nil end
        return fs.readfile(path)
    end
    local function array(v)
        if type(v)=='table' then return v end
        local r={}; for value in tostring(v or ''):gmatch('%S+') do r[#r+1]=value end;return r
    end
    local function port(v,default)
        local n=tonumber(v);return n and n>=0 and n<=65535 and n==math.floor(n) and n or default
    end
    local function glob(pattern,limit)
        local result={}
        if fs.glob then
            for path in fs.glob(pattern) do
                result[#result+1]=path;if #result>=(limit or 128) then break end
            end
        end
        table.sort(result);return result
    end
    local owners={dnsmasq={},smartdns={},adguardhome={}}
    local procd=json.parse(sys.exec('ubus call service list 2>/dev/null'))
    if type(procd)=='table' then
        for name,pids in pairs(owners) do
            local service=procd[name]
            local instances=type(service)=='table' and service.instances
            if type(instances)=='table' then
                for _,instance in pairs(instances) do
                    if type(instance)=='table' and instance.running and tonumber(instance.pid) then pids[tonumber(instance.pid)]=true end
                end
            end
        end
    end
    -- SmartDNS uses the musl loader, so process names alone cannot identify it.
    for _,path in ipairs(glob('/proc/[0-9]*/cmdline',4096)) do
        local argv=read(path) or ''
        local pid=tonumber(path:match('/proc/(%d+)/'))
        for arg in argv:gmatch('[^%z]+') do
            local name=(arg=='/usr/libexec/r76s/smartdns.bin' or arg=='/usr/sbin/smartdns') and 'smartdns' or
                (arg=='/usr/bin/AdGuardHome' and 'adguardhome') or
                ((arg=='/usr/sbin/dnsmasq' or arg=='dnsmasq') and 'dnsmasq')
            if name and pid then owners[name][pid]=true end
        end
    end
    local listeners_known=sys.call('command -v netstat >/dev/null 2>&1')==0
    local listeners=listeners_known and sys.exec('netstat -lnutp 2>/dev/null') or ''
    -- A port without visible PID ownership cannot confirm the service.
    listeners_known=listeners_known and listeners:match('%d+/')~=nil
    local function listening(name,n)
        for line in listeners:gmatch('[^\n]+') do
            local f={};for v in line:gmatch('%S+') do f[#f+1]=v end
            local pid=f[#f] and tonumber(f[#f]:match('^(%d+)/'))
            if pid and owners[name][pid] and f[1] and f[1]:match('^[tu][cd]p') and f[4] and tonumber(f[4]:match(':(%d+)$'))==n then return true end
        end
        return false
    end
    local interface=json.parse(sys.exec('ubus call network.interface dump 2>/dev/null'))
    local local_ips={['::1']=true,['127.0.0.1']=true}
    local wan_dns_count,wan_up=0,false
    for _,item in ipairs(type(interface)=='table' and type(interface.interface)=='table' and interface.interface or {}) do
        if type(item)=='table' then
            for _,field in ipairs({'ipv4-address','ipv6-address'}) do
                for _,address in ipairs(type(item[field])=='table' and item[field] or {}) do
                    if type(address)=='table' and type(address.address)=='string' then local_ips[address.address]=true end
                end
            end
            if item.interface=='wan' or item.interface=='wan6' then
                wan_up=wan_up or item.up==true
                wan_dns_count=wan_dns_count+#(type(item['dns-server'])=='table' and item['dns-server'] or {})
            end
        end
    end
    local s={nodes={},local_ips=local_ips,listeners_known=listeners_known,wan_dns_count=wan_dns_count,wan_up=wan_up,
        system_upstreams={},passwall=uci:get('passwall','@global[0]','enabled')=='1',passwall2=uci:get('passwall2','@global[0]','enabled')=='1',incomplete=false}
    for addr in (read('/etc/resolv.conf') or ''):gmatch('nameserver%s+([^%s]+)') do s.system_upstreams[#s.system_upstreams+1]=addr end
    local function node(name,service,n,upstreams,extra)
        local item={name=name,port=n,upstreams=upstreams,running=next(owners[service])~=nil,listening=listening(service,n)}
        for k,v in pairs(extra or {}) do item[k]=v end
        s.nodes[#s.nodes+1]=item
    end
    -- Prefer generated dnsmasq files: proxy integrations can change them after UCI generation.
    local runtime={}
    local dnsmasq=type(procd)=='table' and procd.dnsmasq
    local dns_instances=type(dnsmasq)=='table' and dnsmasq.instances
    if type(dns_instances)=='table' then
        for _,instance in pairs(dns_instances) do
            if type(instance)=='table' and instance.running and type(instance.command)=='table' then
                for i,arg in ipairs(instance.command) do
                    local path=type(arg)=='string' and arg:match('^%-%-conf%-file=(/.+)$') or nil
                    if arg=='-C' or arg=='--conf-file' then path=instance.command[i+1] end
                    if type(path)=='string' and path:sub(1,1)=='/' then runtime[#runtime+1]=path end
                end
            end
        end
    end
    if #runtime==0 then runtime=glob('/var/etc/dnsmasq.conf*');s.incomplete=true end
    local loaded=0
    for _,path in ipairs(runtime) do
        local content=read(path)
        if content then
            loaded=loaded+1
            local upstreams,noresolv,n={},false,53
            local resolv='/tmp/resolv.conf.d/resolv.conf.auto'
            for line in content:gmatch('[^\n]+') do
                local server=line:match('^server=(.+)$');if server then upstreams[#upstreams+1]=server end
                if line=='no-resolv' then noresolv=true end
                resolv=line:match('^resolv%-file=(/.+)$') or resolv
                n=port(line:match('^port=(%d+)$'),n)
                if line:match('^conf%-') then s.incomplete=true end
            end
            if not noresolv then
                local resolv_data=read(resolv)
                if resolv_data then
                    for addr in resolv_data:gmatch('nameserver%s+([^%s]+)') do upstreams[#upstreams+1]=addr end
                else s.incomplete=true end
            end
            node('dnsmasq 运行实例 '..loaded,'dnsmasq',n,upstreams,{noresolv=noresolv})
        end
    end
    if loaded==0 then
        s.incomplete=true
        uci:foreach('dhcp','dnsmasq',function(section)
            local servers=array(section.server)
            if section.noresolv~='1' then
                local resolv=read(section.resolvfile or '/tmp/resolv.conf.d/resolv.conf.auto')
                for addr in (resolv or ''):gmatch('nameserver%s+([^%s]+)') do servers[#servers+1]=addr end
            end
            node('dnsmasq 配置 '..(#s.nodes+1),'dnsmasq',port(section.port,53),servers,{noresolv=section.noresolv=='1'})
        end)
    end
    local smart_port=port(uci:get('smartdns','@smartdns[0]','port'),6053)
    local upstreams={}
    uci:foreach('smartdns','server',function(section)
        if section.enabled~='0' and section.ip then
            local addr=section.ip
            if addr:match('^%a+://') then upstreams[#upstreams+1]=addr
            else
                if addr:find(':',1,true) and addr:sub(1,1)~='[' then addr='['..addr..']' end
                upstreams[#upstreams+1]=addr..':'..port(section.port,53)
            end
        end
    end)
    node('SmartDNS','smartdns',smart_port,upstreams,{enabled=uci:get('smartdns','@smartdns[0]','enabled')=='1'})
    s.incomplete=true -- SmartDNS domain groups/includes and proxy-generated configs are not fully parsed.
    local paths={}
    local agh=type(procd)=='table' and procd.adguardhome
    local instances=type(agh)=='table' and agh.instances
    if type(instances)=='table' then
        for _,instance in pairs(instances) do
            if type(instance)=='table' and type(instance.command)=='table' then
                for i,arg in ipairs(instance.command) do
                    local path=instance.command[i+1]
                    if (arg=='-c' or arg=='--config') and type(path)=='string' and path:sub(1,1)=='/' then paths[#paths+1]=path end
                end
            end
        end
    end
    paths[#paths+1]='/etc/adguardhome.yaml';paths[#paths+1]='/etc/adguardhome/adguardhome.yaml'
    local yaml
    for _,path in ipairs(paths) do yaml=read(path);if yaml and #yaml>0 then break end end
    local agh_port=services.adguard_ports(yaml or '')
    upstreams={};local in_upstream=false
    for line in (yaml or ''):gmatch('[^\n]+') do
        if line:match('^  upstream_dns:') then in_upstream=true
        elseif in_upstream then
            local value=line:match('^  %- (.+)$') or line:match('^    %- (.+)$')
            if value then upstreams[#upstreams+1]=value:gsub('^["\']',''):gsub('["\']$','')
            else in_upstream=false end
        end
    end
    node('AdGuard Home','adguardhome',agh_port or 3053,upstreams,{enabled=sys.call('/etc/init.d/adguardhome enabled >/dev/null 2>&1')==0})
    return s, {fs=fs,sys=sys,uci=uci,read=read}
end

function M.security(s,env)
    local fs,sys,uci,read=env.fs,env.sys,env.uci,env.read
    local state='unknown'
    local shadow=read('/etc/shadow')
    local hash=shadow and shadow:match('^root:([^:]*):')
    if not hash and shadow then hash=shadow:match('\nroot:([^:]*):') end
    if hash=='' then state='empty'
    elseif hash and (hash:sub(1,1)=='!' or hash:sub(1,1)=='*') then state='locked'
    elseif hash then
        local ok,nixio=pcall(require,'nixio')
        if ok and type(nixio.crypt)=='function' then
            local success,result=pcall(nixio.crypt,'password',hash)
            if success and type(result)=='string' and #result>2 then state=result==hash and 'default' or 'set' end
        end
    end
    shadow=nil;hash=nil
    local result={password_state=state,wan_up=s.wan_up,zones={},rules={},management_ports={22,80,443},redirect_count=0,
        proxy_enabled=s.passwall or s.passwall2,firewall_active=sys.call('nft list table inet fw4 >/dev/null 2>&1')==0,
        guard_active=sys.exec('nft list table inet r76s_ip6_guard 2>/dev/null'):find('R76S_V13_IPV6_GUARD',1,true)~=nil,
        offload=uci:get('firewall','@defaults[0]','flow_offloading')=='1' or uci:get('firewall','@defaults[0]','flow_offloading_hw')=='1',
        default_input=uci:get('firewall','@defaults[0]','input'),default_forward=uci:get('firewall','@defaults[0]','forward'),
        upnp=uci:get('upnpd','config','enabled')=='1',management_wildcard=false}
    local function copy(section,fields)
        local item={};for _,field in ipairs(fields) do item[field]=section[field] end;return item
    end
    uci:foreach('firewall','zone',function(v) result.zones[#result.zones+1]=copy(v,{'name','network','enabled','input','forward'}) end)
    uci:foreach('firewall','rule',function(v) result.rules[#result.rules+1]=copy(v,{'name','enabled','src','dest','target','dest_port','proto'}) end)
    uci:foreach('firewall','redirect',function(v) if v.enabled~='0' then result.redirect_count=result.redirect_count+1 end end)
    uci:foreach('dropbear','dropbear',function(v)
        local n=tonumber(v.Port) or 22;result.management_ports[#result.management_ports+1]=n
        if not v.Interface or v.Interface=='' then result.management_wildcard=true end
    end)
    uci:foreach('uhttpd','uhttpd',function(v)
        for _,key in ipairs({'listen_http','listen_https'}) do
            local list=type(v[key])=='table' and v[key] or {v[key]}
            for _,addr in ipairs(list) do
                local n=tonumber(tostring(addr):match(':(%d+)$'))
                if n then result.management_ports[#result.management_ports+1]=n end
                if tostring(addr):match('^0%.0%.0%.0:') or tostring(addr):match('^%[::%]:') then result.management_wildcard=true end
            end
        end
    end)
    return result
end
return M
