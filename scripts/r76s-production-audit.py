#!/usr/bin/env python3
"""Verify production requirements against files extracted from the actual image."""
from pathlib import Path
import argparse
import re

VERSION = 'R76S-V1.2.2'
RULES = '''ChatGPTLogin OpenAI GitHub GoogleWork GoogleAI YouTube Netflix Disney
MaxHBO PrimeVideo Twitter Telegram Google TikTok PlayStation Nintendo Instagram
Xbox Signal Spotify Slack DirectGame ProxyGame AIGC Streaming Proxy Direct LINE
WhatsApp Discord Facebook Reddit Claude Perplexity Copilot Grok Apple Microsoft
Zoom Notion Dropbox'''.split()
PACKAGES = '''luci-app-store luci-app-ota ppp-mod-pppoe dnsmasq-full firewall4
odhcp6c odhcpd-ipv6only wireguard-tools kmod-wireguard luci-proto-wireguard
luci-app-passwall luci-app-passwall2 smartdns luci-app-smartdns adguardhome'''.split()


def audit(root):
    root = Path(root)
    issues = []
    release = (root / 'etc/openwrt_release').read_text()
    for key, expected in [('DISTRIB_RELEASE', '24.10.8'), ('DISTRIB_REVISION', VERSION)]:
        if not re.search(rf"(?m)^{key}=['\"]{re.escape(expected)}['\"]$", release):
            issues.append(f'firmware identity mismatch: {key}')
    status = (root / 'usr/lib/opkg/status').read_text()
    installed = set()
    for block in status.split('\n\n'):
        name = re.search(r'(?m)^Package: (\S+)$', block)
        if name and re.search(r'(?m)^Status: .* installed$', block):
            installed.add(name.group(1))
    issues += [f'package absent from image: {name}' for name in PACKAGES if name not in installed]
    for app in ('passwall', 'passwall2'):
        text = (root / f'usr/share/{app}/0_default_config').read_text()
        order = re.findall(r"(?m)^config shunt_rules '([^']+)'$", text)
        if order != ['WeChatDirect'] + RULES + ['TencentMediaDirect']:
            issues.append(f'{app}: actual image rule order mismatch')
        global_section = re.search(r'(?ms)^config global[^\n]*\n(.*?)(?=^config |\Z)', text)
        if not global_section or "option enabled '0'" not in global_section.group(1):
            issues.append(f'{app}: enabled by default')
        node = re.search(r"(?ms)^config nodes 'myshunt'\n(.*?)(?=^config |\Z)", text)
        if not node or "option WeChatDirect '_direct'" not in node.group(1):
            issues.append(f'{app}: WeChat DIRECT mapping absent')
        wechat = re.search(r"(?ms)^config shunt_rules 'WeChatDirect'\n(.*?)(?=^config |\Z)", text)
        for domain in ('wechat.com', 'weixin.com', 'weixin.qq.com', 'servicewechat.com',
                       'wx.qq.com', 'wxapp.tc.qq.com', 'gtimg.com', 'vweixinthumb.tc.qq.com'):
            if not wechat or f'domain:{domain}' not in wechat.group(1):
                issues.append(f'{app}: WeChat domain missing: {domain}')
    clean = (root / 'etc/uci-defaults/98-r76s-v110-clean-services').read_text()
    for app in ('passwall', 'passwall2', 'smartdns', 'adguardhome'):
        if f'/etc/init.d/{app} disable' not in clean:
            issues.append(f'{app}: first-boot disable missing')
    if 'for optional_service in dockerd containerd ttyd ddns haproxy; do' not in clean or \
       '"/etc/init.d/$optional_service" disable' not in clean:
        issues.append('optional utility first-boot disable missing')
    for requirement in ("smartdns.@smartdns[0].port='6053'",
                        "smartdns.@smartdns[0].auto_set_dnsmasq='0'"):
        if requirement not in clean:
            issues.append(f'SmartDNS clean default missing: {requirement}')
    return issues


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    issues = audit(args.root)
    for issue in issues:
        print('ERROR: ' + issue)
    if issues:
        raise SystemExit(1)
    print('R76S_PRODUCTION_IMAGE_REQUIREMENTS=PASS')
