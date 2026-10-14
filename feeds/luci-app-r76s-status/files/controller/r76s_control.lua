module('luci.controller.r76s_control',package.seeall)
function index()
    local e=entry({'admin','services','r76s_control'},call('page'),_('R76S 服务与 DNS'),59)
    e.dependent=false
    entry({'admin','services','r76s_control','apply'},post('apply')).leaf=true
end
function page()
    local uci=require('luci.model.uci').cursor()
    require('luci.template').render('r76s_control/index',{mode=uci:get('r76s','main','dns_mode') or 'system'})
end
function apply()
    local http=require 'luci.http'
    local sys=require 'luci.sys'
    local kind=http.formvalue('kind')
    local value=http.formvalue('value')
    local command
    if kind=='dns' and ({system=true,smartdns=true,adguard=true,combined=true})[value] then
        command='/usr/libexec/r76s/r76s-dns-manager set '..value
    elseif ({passwall=true,passwall2=true,smartdns=true})[kind] and (value=='0' or value=='1') then
        command='/usr/libexec/r76s/r76s-service-manager set '..kind..' '..value
    end
    if not command then http.status(400,'Invalid operation');return end
    local output=sys.exec(command..' 2>&1')
    require('luci.template').render('r76s_control/result',{output=output})
end
