#!/usr/bin/env python3
"""Final source adapters after legacy compatibility stages; no live-device edits."""
from pathlib import Path
import re,sys

root=Path(sys.argv[1])
repo=Path(__file__).resolve().parent.parent
controller=root/'package/custom/luci-app-r76s-updater/files/controller/r76s_updater.lua'
text=controller.read_text()
assert 'local preserve_rc = sys.call(' in text or '/usr/libexec/r76s/r76s-ota install' in text
text=text.replace('/bin/ota check','/usr/libexec/r76s/r76s-ota check')
text=text.replace('run_with_rc("/bin/ota download 2>&1")',
    'run_with_rc("(/usr/libexec/r76s/r76s-ota download >/tmp/r76s-ota-download.log 2>&1) </dev/null >/dev/null 2>&1 &")')
if '/usr/libexec/r76s/r76s-ota install' not in text:
    start=text.index('function api_install()')
    end=text.find('\nfunction api_backup()', start)
    if end < 0: end=len(text)
    text=text[:start]+'''-- R76S_V14_OTA_BACKEND: all install checks are serialized by the signed backend.
function api_install()
    local preserve_rc, out = run_with_rc("/usr/libexec/r76s/r76s-ota install 2>&1")
    json_reply({ok=preserve_rc==0, message=preserve_rc==0 and
        "升级已启动，请勿断电。" or out, status=build_status()})
end
'''+text[end:]
# Verify the signed manifest as well as the existing UI verification fields.
if 'result.ota_signature = "pass"' not in text:
    text=text.replace('    result.sysupgrade = "pass"', '''    local signed_rc, signed_out = run_with_rc("/usr/libexec/r76s/r76s-ota verify 2>&1")
    if signed_rc ~= 0 then
        result.message = signed_out
        save_verify_state(result)
        return result
    end
    result.ota_signature = "pass"
    result.sysupgrade = "pass"''')
controller.write_text(text)
for app in ('passwall','passwall2'):
    path=root/f'package/{app}-luci/luci-app-{app}/root/etc/init.d/{app}'
    contents=path.read_text()
    for action in ('start','restart'):
        anchor=action+'() {\n'
        contents,count=re.subn(r'(?m)^'+re.escape(anchor),lambda m:anchor+
            f'\t/usr/libexec/r76s/r76s-service-manager check {app} || return 1\n',contents)
        assert count==1
    path.write_text(contents)
# Keep UCI/init consistency when users apply the native SmartDNS page too.
for path in root.glob('feeds/**/smartdns.init'):
    contents=path.read_text()
    if re.search(r'(?m)^start_service\(\)[ \t]*(?:\n[ \t]*)?\{', contents):
        contents=re.sub(r'(?m)^start_service\(\)[ \t]*(?:\n[ \t]*)?\{', lambda m: m.group(0) + '\n    /usr/libexec/r76s/r76s-service-manager check smartdns || return 1', contents, count=1)
        path.write_text(contents)
        overlay=root/'files/etc/init.d/smartdns'
        if overlay.exists(): overlay.write_text(contents); overlay.chmod(0o755)
# Ship provenance and public verification key from the committed source.
destination=root/'files/usr/share/r76s'
destination.mkdir(parents=True,exist_ok=True)
for name,path in [('release.json','config/r76s-release.json'),('sources.lock.json','config/r76s-sources.lock.json'),
                  ('rules.json','config/rules/r76s-rules.json'),('ota-public.pem','config/ota-public.pem')]:
    (destination/name).write_bytes((repo/path).read_bytes())
print('R76S_V14_SOURCE_ADAPTERS=PASS')
