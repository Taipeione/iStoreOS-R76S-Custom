#!/usr/bin/env python3
"""Generate both ROM defaults from the versioned rule manifest; never edit live UCI."""
from pathlib import Path
import json,re,sys
manifest=json.loads(Path(sys.argv[1]).read_text())
assert manifest['schema_version']==1
rules=[(rule['name'],list(rule['options'].items())) for rule in manifest['rules']]
output_order=[name for name,_ in rules]
assert len(output_order)==43 and len(set(output_order))==43
assert output_order[0]=='WeChatDirect' and output_order[-1]=='TencentMediaDirect'
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

    if len(actual_order) != 43:
        raise SystemExit(
            f'ERROR: {p} has {len(actual_order)} shunt_rules after transform'
        )

    if actual_order != output_order:
        raise SystemExit(
            f'ERROR: {p} V1.1.1 shunt order mismatch: {actual_order}'
        )

    if actual_order[0] != 'WeChatDirect':
        raise SystemExit(
            f'ERROR: {p} first rules are not the V1.3.2 direct groups'
        )

    if actual_order[-2:] != ['Dropbox', 'TencentMediaDirect']:
        raise SystemExit(
            f'ERROR: {p} last shunt rule is not Dropbox'
        )

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

print('PassWall and PassWall2 V1.3.2 43-rule order verified, no legacy WeChatTencent rule.')