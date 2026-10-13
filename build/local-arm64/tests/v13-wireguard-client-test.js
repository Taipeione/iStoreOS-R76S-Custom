'use strict';
const fs = require('fs'), assert = require('assert'), net = require('net'), path = require('path');
const base = 'feeds/luci-app-r76s-status/files/htdocs/luci-static/resources';
const baseclass = {extend: x => x};
const validation = {parseIPv4: v => net.isIP(v) === 4, parseIPv6: v => net.isIP(v) === 6};
const config = new Function('baseclass', 'validation', fs.readFileSync(base + '/r76s/wireguard.js', 'utf8'))(baseclass, validation);
const key = Buffer.alloc(32, 1).toString('base64');
const input = {name:'iphone',privateKey:key,serverKey:key,address:'10.7.0.2/24, fd00:7::2/64',allowed:'0.0.0.0/0, ::/0',endpoint:'vpn.example.com:51820',dns:'10.7.0.1, fd00:7::1',keepalive:'25',psk:key,mtu:'1420'};
const result=config.build(input);
assert.equal(result.name,'iphone.conf'); assert.equal(result.peerAddresses,'10.7.0.2/32, fd00:7::2/128');
assert(result.text.includes('PrivateKey = '+key)); assert(result.text.includes('PresharedKey = '+key));
assert(result.text.includes('AllowedIPs = 0.0.0.0/0, ::/0')); assert(result.text.endsWith('\n'));
assert(config.build({...input,endpoint:'[2001:db8::1]:51820'}).text.includes('Endpoint = [2001:db8::1]:51820'));
assert(!config.build({...input,dns:'',psk:'',mtu:''}).text.includes('DNS ='));
for (const [field,value] of [['endpoint','evil\nPostUp = bad'],['endpoint','\nvpn.example.com:51820'],['endpoint','999.1.1.1:4'],['endpoint','host:65536'],['endpoint','[notipv6]:1'],['address','10.0.0.1/33'],['address','fd00::1/129'],['dns','https://dns.example'],['keepalive','-1'],['mtu','1279'],['privateKey','secret'],['serverKey',Buffer.alloc(32).toString('base64')],['name','../x'],['allowed','0.0.0.0/0\nPostUp = bad']]) {
  assert.throws(() => config.build({...input,[field]:value}), undefined, field + ':' + value);
}
// Real pinned LuCI QR library, when present: no network encoder dependency.
if (process.env.R76S_TEST_UQR) {
  const uqr=new Function('L',fs.readFileSync(process.env.R76S_TEST_UQR,'utf8'))({Class:baseclass});
  const svg=uqr.renderSVG(result.text,{pixelSize:4,whiteColor:'white',blackColor:'black'});
  assert(svg.startsWith('<svg')); assert(svg.includes('<path')); assert(!svg.includes(key));
  console.log('WIREGUARD_REAL_QR=PASS');
}
// The native view must use key-pair RPC and produce usable DOM without saving keys.
let actions=[], rpcCalls=[];
function E(tag,attrs,children) {
  if (typeof attrs==='string' || Array.isArray(attrs)) {children=attrs;attrs={};}
  attrs=attrs||{};
  const node={tag,attrs,value:attrs.value||'',style:{},children:[],appendChild(n){this.children.push(n);},replaceChildren(...n){this.children=n;},addEventListener(event,fn){this[event]=fn;},remove(){},click(){}};
  if (Array.isArray(children)) node.children.push(...children); else if (children != null) node.children.push(children);
  if (attrs.click) {node.click=attrs.click;actions.push(node);}
  return node;
}
global.E=E; global.window={addEventListener(){}};global.document={body:{appendChild(){}}};
const view={extend:x=>x}, rpc={declare:s=>async value=>{rpcCalls.push({s,value});return {priv:key,pub:key};}},ui={addNotification(){throw Error('Unexpected UI error: '+arguments[1].children.join(''));}},uqr={renderSVG:()=>'<svg></svg>'};
const page=new Function('view','rpc','ui','uqr','config',fs.readFileSync(base+'/view/r76s_wireguard/client.js','utf8'))(view,rpc,ui,uqr,config);
const tree=page.render();let inputs=[],areas=[];
function walk(n){if(!n || typeof n!=='object')return;if(n.tag==='input')inputs.push(n);if(n.tag==='textarea')areas.push(n);n.children.forEach(walk);} walk(tree);
inputs[1].value=key;inputs[2].value='vpn.example.com:51820';inputs[3].value='10.7.0.2/24';
(async()=>{
 await actions[0].click();assert.equal(rpcCalls[0].s.method,'generateKeyPair');assert(areas[0].value.includes('[Peer]'));
 const old=areas[0].value;actions[2].click();assert(old===areas[0].value);
 inputs[8].value=key;inputs[8].input();assert.equal(areas[0].value,'');await actions[0].click();assert.equal(rpcCalls[1].s.method,'getPublicAndPrivateKeyFromPrivate');
 actions[3].click();assert.equal(areas[0].value,'');assert.equal(inputs[8].value,'');
 console.log('WIREGUARD_CLIENT_CONFIG_AND_VIEW=PASS');
})().catch(e=>{console.error(e);process.exitCode=1;});
