local model=dofile('feeds/luci-app-r76s-status/files/model/r76s/diagnostics.lua')
local function find(rows,title)
    for _,row in ipairs(rows) do if row.title==title then return row end end
end
local function dns(nodes)
    return model.dns({nodes=nodes,listeners_known=true,wan_dns_count=2,local_ips={['192.168.50.1']=true}})
end
local healthy={
    {name='dnsmasq',port=53,running=true,listening=true,noresolv=true,upstreams={'127.0.0.1#6053'}},
    {name='SmartDNS',port=6053,running=true,listening=true,upstreams={'https://dns.example/dns-query?token=SECRET'}}}
assert(find(dns(healthy),'本机 DNS 回环').level=='info')
assert(model.target('::1#6053').port==6053)
assert(model.target('[::1]:3053').port==3053)
assert(model.target('[::1]').port==53)
assert(model.target('[/qq.com/]127.0.0.1:6053').port==6053)
assert(model.target('#').unknown)
assert(find(dns({{name='dnsmasq',port=0}}),'dnsmasq').level=='info')
assert(model.target('/qq.com/192.168.50.1#53',{['192.168.50.1']=true}).conditional)
assert(model.target('https://user:SECRET@resolver.example/dns-query').unknown)
healthy[2].upstreams={'127.0.0.1#53'}
assert(find(dns(healthy),'本机 DNS 回环').level=='warn')
healthy[2].upstreams={'8.8.8.8'};healthy[2].listening=false
assert(find(dns(healthy),'dnsmasq → SmartDNS').level=='warn')
local disabled=dns({{name='SmartDNS',port=6053,enabled=false,running=false,listening=false,upstreams={}}})
assert(find(disabled,'SmartDNS · :6053').level=='info')
local conditional=dns({{name='dnsmasq',port=53,noresolv=true,upstreams={'/qq.com/8.8.8.8'}}})
assert(find(conditional,'dnsmasq 默认解析出口').level=='warn')
local missing=dns({{name='dnsmasq',port=53,upstreams={'127.0.0.1#9999'}}})
assert(find(missing,'dnsmasq 本机上游 :9999').level=='unknown')
local function no_secrets(rows)
    for _,row in ipairs(rows) do
        assert(not row.detail:find('SECRET',1,true))
        assert(not row.detail:find('private_key',1,true))
    end
end
no_secrets(dns({{name='AGH',port=3053,upstreams={'https://user:SECRET@host/dns-query','https://resolver/dns-query?SECRET'}}}))
local s={password_state='default',firewall_active=true,zones={{name='wan',input='REJECT',forward='REJECT'}},
    rules={{name='Ping',src='wan',proto='icmp',target='ACCEPT'},{name='SSH',src='wan',proto='tcp',target='ACCEPT',dest_port='22'}},
    management_ports={22,80,443},redirect_count=0,proxy_enabled=true,guard_active=false,wan_up=true}
assert(find(model.security(s),'root 认证').level=='warn')
assert(find(model.security(s),'管理端口允许规则 SSH').level=='warn')
assert(not find(model.security(s),'管理端口允许规则 Ping'))
s.rules[2].enabled='0';s.password_state='empty';assert(find(model.security(s),'root 认证').level=='warn')
assert(find(model.security(s),'管理端口允许规则').level=='info')
s.password_state='locked';assert(find(model.security(s),'root 认证').level=='pass')
s.password_state='unknown';assert(find(model.security(s),'root 认证').level=='unknown')
s.rules={{name='Range',src='*',proto={'udp','tcp'},target='ACCEPT',dest_port='1:1024'}}
assert(find(model.security(s),'管理端口允许规则 Range').level=='warn')
s.rules={{name='DNS',src='wan',proto='udp',target='ACCEPT',dest_port='53'}}
assert(find(model.security(s),'WAN DNS 允许规则 DNS').level=='warn')
assert(not find(model.security(s),'管理端口允许规则 DNS'))
s.rules={{name='Forward',src='wan',dest='lan',target='ACCEPT',dest_port='22'}}
assert(not find(model.security(s),'管理端口允许规则 Forward'))
s.guard_active=true;s.offload=true;assert(find(model.security(s),'IPv6 保护与流量卸载').level=='warn')
s.zones={{network={'wan'}}};assert(find(model.security(s),'WAN 区域 未命名区域 入站'))
print('DNS_SECURITY_CLASSIFIERS=PASS')

local fixtures={
 ['/var/etc/dnsmasq.conf.live']='port=53\nno-resolv\nserver=127.0.0.1#6053\nconf-dir=/tmp/etc/passwall\n',
 ['/custom/agh.yaml']='http:\n  address: 0.0.0.0:3000\ndns:\n  port: 3053\n  upstream_dns:\n    - 127.0.0.1:6053\n',
 ['/etc/shadow']='root:$6$SECRET_HASH:0:0:0:0:0:0:\n',
 ['/proc/20/cmdline']='/lib/ld-musl-aarch64.so.1\000/usr/libexec/r76s/smartdns.bin\000-c\000/etc/smartdns.conf\000'
}
local calls={}
local function iterator(items)
    local i=0;return function() i=i+1;return items[i] end
end
package.preload['nixio.fs']=function() return {
 stat=function(path) if fixtures[path] then return {type='reg',size=#fixtures[path]} end end,
 readfile=function(path) return fixtures[path] end,
 glob=function(pattern) return iterator(pattern:find('/proc/',1,true) and {'/proc/20/cmdline'} or {}) end
} end
local procd={dnsmasq={instances={main={running=true,pid=10,command={'/usr/sbin/dnsmasq','-C','/var/etc/dnsmasq.conf.live'}}}},
 adguardhome={instances={main={running=true,pid=30,command={'/usr/bin/AdGuardHome','-c','/custom/agh.yaml'}}}}}
local interface={interface={{interface='wan',up=true,['dns-server']={'1.1.1.1'},['ipv4-address']={{address='192.0.2.1'}}}}}
package.preload['luci.jsonc']=function() return {parse=function(value) return value=='PROCD' and procd or value=='INTERFACE' and interface or nil end} end
package.preload['luci.sys']=function() return {
 exec=function(command)
  calls[#calls+1]=command
  if command=='ubus call service list 2>/dev/null' then return 'PROCD' end
  if command=='ubus call network.interface dump 2>/dev/null' then return 'INTERFACE' end
  if command=='netstat -lnutp 2>/dev/null' then return 'udp 0 0 0.0.0.0:53 0.0.0.0:* 10/dnsmasq\nudp 0 0 127.0.0.1:6053 0.0.0.0:* 20/ld-musl\nudp 0 0 127.0.0.1:3053 0.0.0.0:* 30/AdGuardHome\n' end
  return ''
 end,
 call=function(command) calls[#calls+1]=command;return 0 end
} end
local sections={dhcp={},smartdns={server={{ip='1.1.1.1',enabled='1'}}},
 firewall={zone=s.zones,rule=s.rules,redirect={}},dropbear={dropbear={{Port='2222'}}},uhttpd={uhttpd={{listen_http={'0.0.0.0:8080'},listen_https={'[::]:8443'}}}}}
local options={['smartdns.@smartdns[0].enabled']='1',['smartdns.@smartdns[0].port']='6053',['passwall.@global[0].enabled']='1'}
package.preload['luci.model.uci']=function() return {cursor=function() return {
 get=function(_,config,section,option) return options[config..'.'..section..'.'..option] end,
 foreach=function(_,config,section,callback) for _,v in ipairs(sections[config] and sections[config][section] or {}) do callback(v) end end
} end} end
package.preload['nixio']=function() return {crypt=function(pass,hash) assert(pass=='password');return hash end} end
package.loaded['luci.model.r76s.services']=dofile('feeds/luci-app-r76s-status/files/model/r76s/services.lua')
local collector=dofile('feeds/luci-app-r76s-status/files/model/r76s/diagnostics_collect.lua')
local snapshot,env=collector.snapshot()
assert(#snapshot.nodes==3 and snapshot.nodes[1].listening and snapshot.nodes[2].listening and snapshot.nodes[3].listening)
assert(snapshot.nodes[3].upstreams[1]=='127.0.0.1:6053')
assert(snapshot.wan_dns_count==1 and snapshot.wan_up and snapshot.incomplete)
local safety=collector.security(snapshot,env)
assert(safety.password_state=='default' and safety.management_wildcard)
assert(safety.management_ports[4]==2222)
fixtures['/etc/shadow']='root:!:0:\n';assert(collector.security(snapshot,env).password_state=='locked')
fixtures['/etc/shadow']=nil;assert(collector.security(snapshot,env).password_state=='unknown')
no_secrets(model.dns(snapshot));no_secrets(model.security(safety))
for _,command in ipairs(calls) do
 assert(not command:find('restart',1,true) and not command:find('reload',1,true) and not command:find('uci set',1,true))
 assert(not command:find('SECRET',1,true))
end
package.loaded['luci.model.r76s.diagnostics']=model
package.loaded['luci.model.r76s.diagnostics_collect']=collector
local rendered
package.preload['luci.http']=function() return {header=function(name,value) assert(name=='Cache-Control' and value=='no-store') end} end
package.preload['luci.template']=function() return {render=function(name,value) assert(name=='r76s_diagnostics/status');rendered=value.data end} end
dofile('feeds/luci-app-r76s-status/files/controller/r76s_diagnostics.lua')
luci.controller.r76s_diagnostics.action_dns();assert(rendered.kind=='dns');no_secrets(rendered.rows)
luci.controller.r76s_diagnostics.action_security();assert(rendered.kind=='security');no_secrets(rendered.rows)
-- Malformed ubus data and missing files must produce unknown evidence, not a crash.
procd={dnsmasq={instances='bad'},adguardhome={instances='bad'}};interface={interface='bad'}
snapshot,env=collector.snapshot();assert(snapshot.wan_dns_count==0);collector.security(snapshot,env)
print('DNS_SECURITY_COLLECTOR_AND_CONTROLLERS=PASS')
