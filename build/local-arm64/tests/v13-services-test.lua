local model = dofile("feeds/luci-app-r76s-status/files/model/r76s/services.lua")
local rows = model.wireguard({{name="wg0",peers=3},{name="wg1",peers=1}},
    {{interface="wg0",up=true,l3_device="wg-device"}},
    "wg-device pub1 990\nwg-device pub2 0\nwg-device pub3 500\nwg1 pub4 1200\n",
    "wg-device pub1 1024 2048\nwg-device pub3 10 20\n", 1000)
assert(#rows==2 and rows[1].name=="wg0")
assert(rows[1].configured_peers==3 and rows[1].peers==3 and rows[1].recent==1)
assert(rows[1].rx==1034 and rows[1].tx==2068 and rows[1].handshake=="10 秒前")
assert(rows[2].recent==0 and rows[2].handshake=="系统时间待校准")
local missing=model.wireguard({{name="wg0"}}, {}, "malformed\n", "bad\n", 1000)
assert(missing[1].peers==0 and missing[1].handshake=="尚无握手")
for _,row in ipairs(rows) do
    assert(row.private_key==nil and row.public_key==nil and row.preshared_key==nil)
end
print("WIREGUARD_SERVICE_CLASSIFIER=PASS")
local dns,web=model.adguard_ports('http:\n  address: 0.0.0.0:3000\ndns:\n  port: 3053\n  upstream_dns:\n    - 127.0.0.1:6053\n')
assert(dns==3053 and web==3000)
local _,legacy=model.adguard_ports('bind_port: 8080\ndns:\n  port: 3053\n')
assert(legacy==8080)
local s={installed=true,enabled=false,configured=true,pids={[42]=true},
    dns_port=3053,web_port=3000,listener_available=true,
    listeners='udp 0 0 127.0.0.1:3053 0.0.0.0:* 42/AdGuardHome\n'..
        'tcp 0 0 0.0.0.0:3000 0.0.0.0:* LISTEN 42/AdGuardHome\n'}
local health=model.adguard(s)
assert(health.dns_ready and health.web_port==3000 and health.state=='DNS 端口已监听')
s.listeners='udp 0 0 127.0.0.1:3053 0.0.0.0:* 99/other\n'
assert(not model.adguard(s).dns_ready and model.adguard(s).web_port==nil)
s.listeners='tcp 0 0 127.0.0.1:3000 0.0.0.0:* LISTEN 42/AdGuardHome\n'
assert(model.adguard(s).web_port==nil)
s.listeners='udp 0 0 0.0.0.0:3000 0.0.0.0:* 42/AdGuardHome\n'
assert(model.adguard(s).web_port==nil)
s.listeners='udp 0 0 127.0.0.1:3053 0.0.0.0:* -\n'
assert(model.adguard(s).state=='运行中（端口未确认）')
s.pids={};s.procd_running=false;s.enabled=true
assert(model.adguard(s).state=='已启用但未运行')
s.enabled=false
assert(model.adguard(s).state=='已关闭')
s.procd_running=true;s.listener_available=false
assert(model.adguard(s).state=='运行中（端口未确认）')
local bad_dns,bad_web=model.adguard_ports('dns:\n  port: 70000\nhttp:\n  address: custom\n')
assert(bad_dns==nil and bad_web==nil)
print('ADGUARD_SERVICE_CLASSIFIER=PASS')

-- Exercise actual LuCI controllers with read-only dependency mocks.
package.loaded['luci.model.r76s.services']=model
local captured, json_data, commands, outputs = nil, {}, {}, {}
package.preload['nixio.fs']=function() return {
    access=function() return true end,
    stat=function(path) if path=='/custom/agh.yaml' then return {type='reg',size=100} end end,
    readfile=function() return 'dns:\n  port: 3053\nhttp:\n  address: 0.0.0.0:3000\n' end
} end
package.preload['luci.sys']=function() return {
    call=function(command)
        commands[#commands+1]=command
        if command:find(' enabled ',1,true) then return 1 end
        return 0
    end,
    exec=function(command)
        commands[#commands+1]=command
        if outputs[command] then return outputs[command] end
        if command:find('pgrep',1,true) then return '42\n' end
        if command:find('netstat',1,true) then return
            'udp 0 0 127.0.0.1:3053 0.0.0.0:* 42/AdGuardHome\n' end
        return '{}'
    end
} end
package.preload['luci.jsonc']=function() return {parse=function() return json_data end} end
package.preload['luci.template']=function() return {
    render=function(_,value) captured=value.data end
} end
json_data={adguardhome={instances={main={running=true,pid=42,
    command={'/usr/bin/AdGuardHome','-c','/custom/agh.yaml'}}}}}
dofile('feeds/luci-app-r76s-status/files/controller/r76s_adguardhome.lua')
luci.controller.r76s_adguardhome.action_status()
assert(captured.running=='DNS 端口已监听' and captured.enabled=='已关闭')
assert(captured.configured=='已有配置' and captured.dns_port==3053)
-- Malformed procd instances must not crash the status page.
json_data={adguardhome={instances='invalid'}}
luci.controller.r76s_adguardhome.action_status()
assert(captured.running=='运行中（未发现配置）')
for _,command in ipairs(commands) do
    assert(not command:find('restart',1,true) and not command:find('uci set',1,true))
end
print('ADGUARD_LUCI_CONTROLLER=PASS')
package.preload['luci.model.uci']=function() return {cursor=function() return {
    foreach=function(_,_,section,callback)
        if section=='interface' then callback({['.name']='wg0',proto='wireguard',private_key='DO_NOT_RENDER'})
        elseif section=='wireguard_wg0' then callback({public_key='peer',preshared_key='DO_NOT_RENDER'}) end
    end,
    get_list=function() return {'/etc/smartdns/user.conf','/etc/smartdns/r76s-v13/ip-family.conf'} end
    ,get=function() return '0' end
} end} end
outputs['wg show all latest-handshakes 2>/dev/null']='wg0 peer '..os.time()..'\n'
outputs['wg show all transfer 2>/dev/null']='wg0 peer 512 1024\n'
json_data={interface={{interface='wg0',up=true,l3_device='wg0'}}}
dofile('feeds/luci-app-r76s-status/files/controller/r76s_wireguard.lua')
luci.controller.r76s_wireguard.action_status()
assert(captured.rows[1].configured_peers==1 and captured.rows[1].recent==1)
assert(captured.rows[1].rx==512 and captured.rows[1].private_key==nil)
print('WIREGUARD_LUCI_CONTROLLER=PASS')
dofile('feeds/luci-app-r76s-status/files/controller/r76s_ip_policy.lua')
luci.controller.r76s_ip_policy.action_status()
assert(captured.selected==true)
print('IP_POLICY_LUCI_CONTROLLER=PASS')

local clients=model.wireguard({{name='wg0',clients={
    {key='a',label='iPhone'}, {key='b',label='Windows'}, {key='c',label='Never'},
    {key='d',label='Clock'}, {key='e',label='Disabled',disabled=true}}}},
    {{interface='wg0',up=true}}, 'wg0 a 990\nwg0 b 500\nwg0 c 0\nwg0 d 1200\nwg0 e 990\n',
    'wg0 a 100 200\n', 1000, true)[1].clients
assert(clients[1].state=='近期握手' and clients[1].rx==100 and clients[1].age==10)
assert(clients[2].state=='空闲 / 待确认' and clients[3].state=='尚无握手')
assert(clients[4].state=='系统时间待校准' and clients[5].state=='配置已禁用')
assert(model.wireguard({{name='wg0',clients={{key='a',label='a'}}}}, {}, '', '', 1000, false)[1].clients[1].state=='检测失败')
package.preload['luci.http']=function() return {
    header=function(name,value) assert(name=='Cache-Control' and value=='no-store') end,
    prepare_content=function(value) assert(value=='application/json') end,
    write_json=function(value) captured=value end
} end
json_data={interface={{interface='wg0',up=true}}}
luci.controller.r76s_wireguard.action_data()
local function no_secrets(value)
    for key,item in pairs(value) do
        assert(key~='private_key' and key~='preshared_key' and key~='public_key' and key~='client_map')
        assert(item~='DO_NOT_RENDER')
        if type(item)=='table' then no_secrets(item) end
    end
end
no_secrets(captured)
assert(captured.rows[1].clients[1].rx==512)
print('WIREGUARD_PHASE22_STATUS=PASS')
