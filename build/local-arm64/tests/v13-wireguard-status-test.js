'use strict';
const fs=require('fs'), assert=require('assert');
function element(tag) {
 return {tag,textContent:'',dataset:{},style:{},children:[],appendChild(n){this.children.push(n);},replaceChildren(...n){this.children=n;},addEventListener(event,fn){this[event]=fn;}};
}
const root=element('div'),note=element('p'),button=element('button');root.dataset.url='/authenticated/data';
let interval, request, fail=false, count=0;
const data={timestamp:1000,healthy:true,rows:[{name:'wg0',up:true,configured_peers:1,peers:1,recent:1,rx:1024,tx:2048,clients:[{label:'<img onerror=bad>',state:'近期握手',stamp:990,age:10,rx:1024,tx:2048}]}]};
global.document={hidden:false,createElement:element,getElementById:id=>({'r76s-wg-live':root,'r76s-wg-note':note,'r76s-wg-refresh':button}[id]),addEventListener(){}};
global.window={addEventListener(){}};global.setInterval=fn=>{interval=fn;return 1;};
global.fetch=async(url,options)=>{count++;request={url,options};if(fail)throw Error('offline');return {ok:true,json:async()=>JSON.parse(JSON.stringify(data))};};
new Function(fs.readFileSync('feeds/luci-app-r76s-status/files/htdocs/luci-static/resources/r76s/wireguard-status.js','utf8'))();
const tick=()=>new Promise(resolve=>setImmediate(resolve));
function text(n){return n.textContent+n.children.map(text).join(' ');}
(async()=>{
 await tick();assert(root.children.length);assert(text(root).includes('<img onerror=bad>'));assert.equal(request.options.cache,'no-store');
 data.timestamp+=5;data.rows[0].rx+=1024;await button.click();assert(text(root).includes('/s'));
 data.timestamp+=5;data.rows[0].rx=0;await button.click();assert(!text(root).includes('/s'));
 const previous=text(root);fail=true;await button.click();assert.equal(text(root),previous);assert(note.textContent.includes('刷新失败'));
 document.hidden=true;const before=count;await interval();assert.equal(count,before);
 console.log('WIREGUARD_STATUS_REFRESH=PASS');
})().catch(error=>{console.error(error);process.exitCode=1;});
