(function () {
  'use strict';
  const root = document.getElementById('r76s-wg-live');
  if (!root) return;
  const note = document.getElementById('r76s-wg-note');
  let running = false, previous = null;
  function bytes(value) {
    const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB']; let index = 0;
    while (value >= 1024 && index < units.length - 1) { value /= 1024; index++; }
    return value.toFixed(index ? 1 : 0) + ' ' + units[index];
  }
  function cell(tag, value) { const node = document.createElement(tag); node.textContent = value; return node; }
  function draw(data) {
    const nodes = [];
    data.rows.forEach(row => {
      const section = document.createElement('section'); section.className = 'cbi-section';
      section.appendChild(cell('h3', row.name + ' · ' + (row.up ? '已启动' : '已停止')));
      let rate = '';
      const old = previous && previous.rows.find(v => v.name === row.name);
      const elapsed = previous && data.timestamp - previous.timestamp;
      if (old && old.up && row.up && elapsed > 0 && row.rx >= old.rx && row.tx >= old.tx)
        rate = ' · 接收 / 发送速率 ' + bytes((row.rx - old.rx) / elapsed) + '/s / ' + bytes((row.tx - old.tx) / elapsed) + '/s';
      section.appendChild(cell('p', '配置 Peer ' + row.configured_peers + ' · 运行 Peer ' + row.peers + ' · 近期握手 ' + row.recent + ' · 累计接收 / 发送 ' + bytes(row.rx) + ' / ' + bytes(row.tx) + rate));
      const scroll = document.createElement('div'); scroll.style.overflowX = 'auto';
      const table = document.createElement('table'); table.className = 'table';
      const header = document.createElement('tr'); ['Peer', '状态', '最后握手', '接收', '发送'].forEach(v => header.appendChild(cell('th', v))); table.appendChild(header);
      row.clients.forEach(peer => {
        const tr = document.createElement('tr');
        const time = peer.stamp ? new Date(peer.stamp * 1000).toLocaleString() + (peer.age >= 0 ? '（' + peer.age + ' 秒前）' : '') : '尚无握手';
        [peer.label, peer.state, time, bytes(peer.rx), bytes(peer.tx)].forEach(v => tr.appendChild(cell('td', v)));
        table.appendChild(tr);
      });
      scroll.appendChild(table); section.appendChild(scroll); nodes.push(section);
    });
    if (!nodes.length) nodes.push(cell('p', '尚未配置 WireGuard 接口，请在接口页面添加 WireGuard VPN。'));
    root.replaceChildren.apply(root, nodes); previous = data;
    note.textContent = data.healthy ? '更新时间：' + new Date(data.timestamp * 1000).toLocaleTimeString() : 'WireGuard 工具未安装或状态查询失败，握手数据不可用。';
  }
  async function refresh() {
    if (running || document.hidden) return;
    running = true;
    try {
      const response = await fetch(root.dataset.url, {credentials: 'same-origin', cache: 'no-store'});
      if (!response.ok) throw new Error('HTTP ' + response.status);
      const data = await response.json(); if (!Array.isArray(data.rows)) throw new Error('无效状态'); draw(data);
    } catch (error) { note.textContent = '刷新失败，保留上次状态；请检查登录状态或网络连接。'; }
    finally { running = false; }
  }
  document.getElementById('r76s-wg-refresh').addEventListener('click', refresh);
  document.addEventListener('visibilitychange', refresh);
  const timer = setInterval(refresh, 5000);
  window.addEventListener('pagehide', () => clearInterval(timer), {once: true}); refresh();
}());
