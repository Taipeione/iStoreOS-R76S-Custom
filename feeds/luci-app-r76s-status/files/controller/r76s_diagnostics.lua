module('luci.controller.r76s_diagnostics', package.seeall)
function index()
    entry({'admin','status','r76s_dns_diagnostics'},call('action_dns'),_('DNS 链路诊断'),72).dependent=false
    entry({'admin','status','r76s_router_security'},call('action_security'),_('主路由安全检查'),73).dependent=false
end
local function render(kind)
    local collector=require 'luci.model.r76s.diagnostics_collect'
    local model=require 'luci.model.r76s.diagnostics'
    local snapshot,env=collector.snapshot()
    local rows=kind=='dns' and model.dns(snapshot) or model.security(collector.security(snapshot,env))
    require('luci.http').header('Cache-Control','no-store')
    require('luci.template').render('r76s_diagnostics/status',{data={kind=kind,rows=rows,timestamp=os.date('%Y-%m-%d %H:%M:%S')}})
end
function action_dns() render('dns') end
function action_security() render('security') end
