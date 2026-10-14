-- Run each scenario in a fresh Lua process; every filesystem/service API is virtual.
local scenario,script=arg[1],arg[2]
local function clone(v)
    if type(v)~='table' then return v end
    local t={} for k,x in pairs(v) do t[k]=clone(x) end return t
end
local config={dhcp={main={['.name']='main',['.type']='dnsmasq',server={'9.9.9.9'},start='100'}},
    smartdns={main={['.name']='main',['.type']='smartdns',enabled='0',port='6053'}},
    r76s={main={dns_mode='system',dns_active='system',agh_config='/etc/adguardhome.yaml'}}}
local files={['/etc/adguardhome.yaml']={dns={port=53,bind_hosts={'0.0.0.0'},upstream_dns={'9.9.9.9'}}}}
for p,v in pairs(config) do files['/etc/config/'..p]=clone(v) end
local original=clone(config)
local enabled={smartdns=false,adguardhome=false}
local calls={}
local fs={}
function fs.mkdir() return true end
function fs.mkdirr() return true end
function fs.chmod() return true end
function fs.rmdir() return true end
function fs.access(p) return files[p]~=nil end
function fs.copy(a,b) if not files[a] then return nil end files[b]=clone(files[a]);return true end
function fs.readfile(p) return files[p] end
function fs.writefile(p,v) files[p]=clone(v);return true end
function fs.remove(p) files[p]=nil;return true end
local uci={}
function uci:foreach(p,t,f) for _,s in pairs(config[p]) do if s['.type']==t then f(s) end end end
function uci:get(p,s,k) return config[p][s][k] end
function uci:set(p,s,k,v) config[p][s][k]=clone(v);return true end
function uci:delete(p,s,k) config[p][s][k]=nil;return true end
function uci:changes() return {} end
function uci:commit(p) files['/etc/config/'..p]=clone(config[p]);return true end
function uci:unload(p) config[p]=clone(files['/etc/config/'..p]) end
local sys={}
function sys.call(cmd)
    calls[#calls+1]=cmd
    if cmd:match(' enabled') then return 1 end
    if cmd:match('pgrep') then return 1 end
    if scenario=='fail' and cmd:match('dig @127.0.0.1 %-p 3053') then return 1 end
    return 0
end
package.preload['nixio.fs']=function()return fs end
package.preload['luci.sys']=function()return sys end
package.preload['uci']=function()return {cursor=function()return uci end} end
package.preload['luci.jsonc']=function()return {parse=clone,stringify=clone} end
package.preload['lyaml']=function()return {load=clone,dump=function(t)return clone(t[1]) end} end
local original_exit=os.exit
local exited
os.exit=function(code) exited=code;error('EXIT:'..code) end
arg={'set','combined'}
local ok,err=pcall(dofile,script)
if scenario=='fail' then
    assert(exited==1,tostring(err))
    assert(config.dhcp.main.server[1]==original.dhcp.main.server[1])
    assert(config.smartdns.main.enabled=='0')
    assert(config.r76s.main.dns_mode=='system')
    assert(files['/etc/adguardhome.yaml'].dns.port==53)
    assert(files['/etc/r76s/dns/original.json']==nil,'failed first activation left a stale baseline')
else
    assert(ok,tostring(err))
    assert(config.dhcp.main.server[1]=='127.0.0.1#3053')
    assert(config.smartdns.main.enabled=='1')
    assert(files['/etc/adguardhome.yaml'].dns.port==3053)
    assert(files['/etc/adguardhome.yaml'].dns.upstream_dns[1]=='127.0.0.1:6053')
    -- Restore only DNS fields; later user DHCP edits must survive.
    config.dhcp.main.start='200';uci:commit('dhcp')
    arg={'set','system'}
    assert(pcall(dofile,script))
    assert(config.dhcp.main.server[1]=='9.9.9.9')
    assert(config.dhcp.main.start=='200')
end
print('V14_DNS_TRANSACTION_'..scenario..'=PASS')
os.exit=original_exit
