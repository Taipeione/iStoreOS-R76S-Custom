'use strict';
'require baseclass';
'require validation';

function fail(message) { throw new Error(message); }
function clean(value) {
	value = String(value == null ? '' : value);
	if (/[\r\n\x00-\x1f]/.test(value)) fail('字段不能包含换行或控制字符');
	return value.trim();
}
function key(value) {
	value = clean(value);
	if (!/^[A-Za-z0-9+/]{43}=$/.test(value) || btoa(atob(value)) !== value || /^A{43}=$/.test(value)) fail('密钥必须是有效的 32 字节 Base64');
	return value;
}
function ip(value) { return validation.parseIPv4(value) ? 4 : validation.parseIPv6(value) ? 6 : 0; }
function list(value, cidr) {
	const values = clean(value).split(',').map(v => v.trim());
	if (!values.length || values.length > 32) fail('地址数量无效');
	values.forEach(v => {
		const parts = v.split('/'), family = ip(parts[0]);
		if (!family || (cidr ? parts.length !== 2 || !/^\d+$/.test(parts[1]) || Number(parts[1]) > (family === 4 ? 32 : 128) : parts.length !== 1)) fail('请输入有效的 IP 地址' + (cidr ? '及 CIDR 前缀' : ''));
	});
	return values.join(', ');
}
function endpoint(value) {
	value = clean(value);
	const match = value.match(/^(?:\[([^\]]+)\]|([^:\s]+)):(\d+)$/);
	if (!match || +match[3] < 1 || +match[3] > 65535) fail('Endpoint 格式为主机:端口或 [IPv6]:端口');
	if (match[1]) { if (ip(match[1]) !== 6) fail('Endpoint IPv6 无效'); }
	else if (!ip(match[2])) {
		if (match[2].length > 253 || /^[\d.]+$/.test(match[2]) || !match[2].split('.').every(v => /^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$/.test(v))) fail('Endpoint 主机名无效');
	}
	return value;
}
return baseclass.extend({
	build: function(s) {
		const name = clean(s.name || 'r76s-client');
		if (!/^[A-Za-z0-9_-]{1,32}$/.test(name)) fail('配置名称仅支持 1–32 个英文字母、数字、下划线及短横线');
		const addresses = list(s.address, true), allowed = list(s.allowed, true);
		const lines = ['[Interface]', 'PrivateKey = ' + key(s.privateKey), 'Address = ' + addresses];
		if (clean(s.dns)) lines.push('DNS = ' + list(s.dns, false));
		if (clean(s.mtu)) {
			if (!/^\d+$/.test(clean(s.mtu)) || +s.mtu < 1280 || +s.mtu > 9000) fail('MTU 范围为 1280–9000');
			lines.push('MTU = ' + Number(s.mtu));
		}
		lines.push('', '[Peer]', 'PublicKey = ' + key(s.serverKey));
		if (clean(s.psk)) lines.push('PresharedKey = ' + key(s.psk));
		lines.push('AllowedIPs = ' + allowed, 'Endpoint = ' + endpoint(s.endpoint));
		if (!/^\d+$/.test(clean(s.keepalive)) || +s.keepalive > 65535) fail('Keepalive 范围为 0–65535');
		lines.push('PersistentKeepalive = ' + Number(s.keepalive));
		return {name: name + '.conf', text: lines.join('\n') + '\n', peerAddresses: addresses.split(', ').map(v => v.split('/')[0] + (ip(v.split('/')[0]) === 4 ? '/32' : '/128')).join(', ')};
	}
});
