#!/usr/bin/env python3
"""Generate both ROM defaults from the versioned rule manifest; never edit live UCI."""
from pathlib import Path
import json,re,sys
manifest=json.loads(Path(sys.argv[1]).read_text())
assert manifest['schema_version']==1
base_rules=[(rule['name'],list(rule['options'].items())) for rule in manifest['rules']]
base_order=[name for name,_ in base_rules]
assert len(base_order)==43 and len(set(base_order))==43
assert base_order[0]=='WeChatDirect' and base_order[-1]=='TencentMediaDirect'
rules=base_rules
app_manifest_path=Path(sys.argv[4]) if len(sys.argv)>4 else None
if app_manifest_path:
    app_manifest=json.loads(app_manifest_path.read_text())
    assert app_manifest['schema_version']==1
    app_rules=[(rule['name'],list(rule['options'].items())) for rule in app_manifest['rules']]
    app_names=[name for name,_ in app_rules]
    assert len(app_names)==len(set(app_names))
    assert not set(app_names) & set(base_order), 'application rule name collides with baseline'
    assert all(name not in {'WeChatDirect', 'TencentMediaDirect'} for name in app_names)
    for name, props in app_rules:
        options = dict(props)
        assert options.get('network') == 'tcp,udp', f'{name}: application rule must cover TCP and UDP'
        assert options.get('domain_list', '').strip(), f'{name}: empty domain_list'
        if name == 'AppleEcosystem':
            assert not any(key in options for key in ('node', 'outbound', 'strategy')), \
                'AppleEcosystem must follow the system default outbound strategy'
    # Preserve the order of every baseline rule and keep TencentMediaDirect as
    # the final legacy rule; the new groups are an additive block immediately
    # before it. WeChatDirect remains the first rule.
    rules=[]
    for item in base_rules:
        if item[0]=='TencentMediaDirect':
            rules.extend(app_rules)
        rules.append(item)
    output_order=[name for name,_ in rules]
else:
    output_order=base_order
pw1,pw2=map(Path,sys.argv[2:4])

def sections(text):
    starts = list(re.finditer(r"(?m)^config\s+([^\s]+)(?:\s+'([^']+)')?\s*$", text))
    if not starts:
        raise SystemExit('ERROR: UCI default has no config sections')
    prefix = text[:starts[0].start()]
    out = []
    for idx,m in enumerate(starts):
        e = starts[idx+1].start() if idx+1 < len(starts) else len(text)
        out.append((m.group(1), m.group(2), text[m.start():e].rstrip() + '\n'))
    return prefix, out

def set_option(block, key, value):
    pat = re.compile(r"(?m)^(\s*option\s+" + re.escape(key) + r"\s+)'[^']*'\s*$")
    if pat.search(block):
        return pat.sub(r"\1'" + value + "'", block, count=1)
    lines = block.rstrip().splitlines()
    lines.insert(1, "\toption %s '%s'" % (key, value))
    return '\n'.join(lines) + '\n'

def rule_fragment(app):
    out = []
    for name, props in rules:
        out.append("config shunt_rules '%s'" % name)
        for k,v in props:
            out.append("\toption %s '%s'" % (k, v))
        out.append('')
    out.append("config nodes 'myshunt'")
    out.append("\toption remarks '分流总节点'")
    out.append("\toption type 'Xray'")
    out.append("\toption protocol '_shunt'")
    out.append("\toption Direct '_direct'")
    out.append("\toption WeChatDirect '_direct'")
    out.append("\toption TencentMediaDirect '_direct'")
    out.append("\toption default_node '_direct'")
    out.append("\toption domainStrategy 'IPOnDemand'")
    out.append("\toption domainMatcher 'hybrid'")
    if app == 'passwall2':
        out.append("\toption write_ipset_direct '1'")
        out.append("\toption enable_geoview_ip '1'")
        out.append("\toption shunt_group 'CN'")
    out.append('')
    return '\n'.join(out) + '\n'

def transform(path, app):
    text = path.read_text()
    prefix, secs = sections(text)
    kept = []
    global_done = False
    for typ, name, block in secs:
        if typ == 'shunt_rules':
            continue
        if typ == 'nodes':
            # Drop upstream shunt/demo nodes; clean firmware contains no personal proxy node.
            if name in {'myshunt','rulenode','examplenode'} or "option protocol '_shunt'" in block or "passwall2.github" in block:
                continue
        if typ == 'global' and not global_done:
            block = set_option(block, 'enabled', '0')
            block = set_option(block, 'node', 'myshunt')
            if app == 'passwall2':
                block = set_option(block, 'auto_lang', 'zh_cn')
            global_done = True
        kept.append(block.rstrip() + '\n\n')
    if not global_done:
        raise SystemExit(f'ERROR: no global section in {path}')
    final = prefix.rstrip() + ('\n\n' if prefix.strip() else '') + ''.join(kept).rstrip() + '\n\n' + rule_fragment(app)
    path.write_text(final)

transform(pw1, 'passwall')
transform(pw2, 'passwall2')

generated_orders = []

for p in (pw1,pw2):
    s = p.read_text()

    actual_order = re.findall(
        r"(?m)^config\s+shunt_rules\s+'([^']+)'\s*$",
        s
    )

    if len(actual_order) != len(output_order):
        raise SystemExit(
            f'ERROR: {p} has {len(actual_order)} shunt_rules after transform; expected {len(output_order)}'
        )

    if actual_order != output_order:
        raise SystemExit(f'ERROR: {p} shunt order mismatch: {actual_order}')

    if actual_order[0] != 'WeChatDirect':
        raise SystemExit(
            f'ERROR: {p} first rules are not the V1.3.2 direct groups'
        )

    if actual_order[-1] != 'TencentMediaDirect':
        raise SystemExit(
            f'ERROR: {p} last shunt rule is not TencentMediaDirect'
        )

    wechat_start = s.find("config shunt_rules 'WeChatDirect'")
    wechat_end = s.find("\nconfig ", wechat_start + 1) if wechat_start >= 0 else -1
    wechat_block = s[wechat_start:wechat_end if wechat_end >= 0 else len(s)]
    if wechat_start < 0 or "option network 'tcp,udp'" not in wechat_block:
        raise SystemExit(f'ERROR: {p} WeChatDirect is not explicitly TCP+UDP direct')
    if 'domain:qq.com' in wechat_block or 'full:qq.com' in wechat_block:
        raise SystemExit(f'ERROR: {p} contains forbidden broad qq.com WeChat rule')

    for required in [
        "config nodes 'myshunt'",
        "option remarks '分流总节点'",
        "option default_node '_direct'",
        "option WeChatDirect '_direct'",
        "option TencentMediaDirect '_direct'",
        "option enabled '0'",
    ]:
        if required not in s:
            raise SystemExit(f'ERROR: {required!r} missing from {p}')

    generated_orders.append(actual_order)

if generated_orders[0] != generated_orders[1]:
    raise SystemExit(
        'ERROR: PassWall and PassWall2 shunt rule order differs'
    )

print(f'PassWall and PassWall2 baseline {len(base_order)}-rule order verified, additive apps={len(output_order) - len(base_order)}, no legacy WeChatTencent rule.')
