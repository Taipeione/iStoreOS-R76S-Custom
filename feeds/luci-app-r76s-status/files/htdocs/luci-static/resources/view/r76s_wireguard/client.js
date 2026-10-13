'use strict';
'require view';
'require rpc';
'require ui';
'require uqr';
'require r76s.wireguard as config';

const generate = rpc.declare({object: 'luci.wireguard', method: 'generateKeyPair', expect: {keys: {}}});
const derive = rpc.declare({object: 'luci.wireguard', method: 'getPublicAndPrivateKeyFromPrivate', params: ['privkey'], expect: {keys: {}}});

return view.extend({
	render: function() {
		let revision = 0, output = null, busy = false;
		const fields = {}, preview = E('textarea', {readonly: '', rows: 12, style: 'width:100%', autocomplete: 'off'});
		const qr = E('div'), pub = E('input', {readonly: '', style: 'width:100%'}), hint = E('p');
		const clearOutput = () => { revision++; output = null; preview.value = ''; pub.value = ''; hint.textContent = ''; qr.replaceChildren(); };
		const form = E('div', {'class': 'cbi-section'});
		const add = (id, label, value, secret) => {
			const input = fields[id] = E('input', {type: secret ? 'password' : 'text', value: value || '', autocomplete: 'off', spellcheck: 'false', style: 'width:100%'});
			input.addEventListener('input', clearOutput);
			form.appendChild(E('div', {'class': 'cbi-value'}, [E('label', {'class': 'cbi-value-title'}, label), E('div', {'class': 'cbi-value-field'}, input)]));
		};
		add('name', '配置名称', 'r76s-client');
		add('serverKey', '服务器公钥'); add('endpoint', '公网 Endpoint（主机:端口）');
		add('address', '客户端隧道地址（CIDR，可逗号分隔）');
		add('allowed', 'AllowedIPs', '0.0.0.0/0, ::/0'); add('dns', 'DNS IP（可选）');
		add('keepalive', 'PersistentKeepalive（秒）', '25'); add('mtu', 'MTU（可选）');
		add('privateKey', '已有客户端私钥（留空生成新密钥）', '', true); add('psk', '预共享密钥（可选）', '', true);
		const report = error => ui.addNotification(null, E('p', error.message || '操作失败'), 'error');
		const button = (label, action) => E('button', {type: 'button', 'class': 'cbi-button cbi-button-action', click: action}, label);
		const make = button('生成客户端配置', async () => {
			if (busy) return;
			clearOutput(); const current = revision; busy = true; make.disabled = true;
			try {
				const s = {}; Object.keys(fields).forEach(k => s[k] = fields[k].value);
				// Validate all user fields before requesting ephemeral keys.
				config.build(Object.assign({}, s, {privateKey: s.privateKey || 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE='}));
				const pair = s.privateKey ? await derive(s.privateKey.trim()) : await generate();
				if (current !== revision) return;
				if (!pair.priv || !pair.pub) throw new Error('密钥 RPC 未返回有效密钥，请检查写入权限');
				s.privateKey = pair.priv;
				output = config.build(s); preview.value = output.text; pub.value = pair.pub;
				hint.textContent = '请手动在服务器添加 Peer：使用上方客户端公钥，AllowedIPs = ' + output.peerAddresses + '。确认防火墙 UDP 入站及转发配置。';
			} catch (error) { if (current === revision) report(error); }
			finally { busy = false; make.disabled = false; }
		});
		const download = button('下载 .conf', () => {
			if (!output) return report(new Error('请先生成配置'));
			const url = URL.createObjectURL(new Blob([output.text], {type: 'text/plain;charset=utf-8'}));
			const link = E('a', {href: url, download: output.name}); document.body.appendChild(link); link.click(); link.remove(); setTimeout(() => URL.revokeObjectURL(url), 1000);
		});
		const showQR = button('显示导入二维码', () => {
			if (!output) return report(new Error('请先生成配置'));
			try { const svg = E(uqr.renderSVG(output.text, {pixelSize: 4, whiteColor: 'white', blackColor: 'black'})); svg.style.cssText = 'width:min(100%,420px);height:auto'; qr.replaceChildren(svg); }
			catch (error) { qr.replaceChildren(); report(new Error('配置过长无法生成二维码，请下载 .conf 导入')); }
		});
		const clear = button('清除配置与密钥', () => { clearOutput(); fields.privateKey.value = ''; fields.psk.value = ''; });
		window.addEventListener('pagehide', () => { clearOutput(); fields.privateKey.value = ''; fields.psk.value = ''; }, {once: true});
		return E('div', {'class': 'cbi-map'}, [E('h2', 'WireGuard 客户端配置'),
			E('p', '生成标准配置供 iPhone 扫码或 Windows 导入。仅在当前页面生成，不保存密钥，也不自动添加服务器 Peer。二维码和配置包含客户端私钥，请妥善保管。'),
			E('p', '默认双栈全隧道需要服务器支持 IPv6 路由。仅填写 0.0.0.0/0 时，客户端本地 IPv6 不经过此隧道。DNS 留空时保持客户端原有 DNS。'),
			form, E('div', [make, ' ', download, ' ', showQR, ' ', clear]), E('h3', '客户端公钥（添加至服务器 Peer）'), pub, hint,
			E('h3', '客户端配置'), preview, qr,
			E('p', '导入已有服务器配置：进入“接口与 Peer 配置”，编辑 WireGuard 接口使用原生“导入配置”；手机在 WireGuard App 选择扫描二维码。')]);
	},
	handleSave: null, handleSaveApply: null, handleReset: null
});
