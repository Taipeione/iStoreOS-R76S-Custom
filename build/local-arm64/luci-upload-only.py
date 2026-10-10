from pathlib import Path
import sys

ui_path = Path(sys.argv[1])
flash_path = Path(sys.argv[2])

ui = ui_path.read_text()
flash = flash_path.read_text()

#
# 1. LuCI upload request must have no client-side total timeout.
#
pos = ui.find("cgi-upload")

if pos < 0:
    raise SystemExit("ERROR: cgi-upload not found in ui.js")

region_start = max(0, pos - 500)
region_end = min(len(ui), pos + 1600)
region = ui[region_start:region_end]

if "timeout: 0" not in region:
    req_start = ui.rfind("request.post(", 0, pos)

    if req_start < 0:
        raise SystemExit(
            "ERROR: request.post for cgi-upload not found"
        )

    progress_pos = ui.find("progress", pos)

    if progress_pos < 0 or progress_pos > pos + 1600:
        raise SystemExit(
            "ERROR: cgi-upload progress option not found"
        )

    line_start = ui.rfind("\n", 0, progress_pos) + 1
    indent = ui[line_start:progress_pos]

    ui = (
        ui[:progress_pos]
        + "timeout: 0,\n"
        + indent
        + ui[progress_pos:]
    )

#
# 2. Standard firmware page must still upload through ui.uploadFile.
#
if "/tmp/firmware.bin" not in flash or "ui.uploadFile" not in flash:
    raise SystemExit(
        "ERROR: standard LuCI sysupgrade upload anchor missing"
    )

#
# 3. Explicitly explain preserve vs clean-flash semantics.
#
keep_anchor = (
    "opts.keep[0], ' ', "
    "_('Keep settings and retain the current configuration')"
)

if "清除全部配置（干净刷机）" not in flash:
    if keep_anchor not in flash:
        raise SystemExit(
            "ERROR: keep-settings label anchor not found"
        )

    flash = flash.replace(
        keep_anchor,
        keep_anchor
        + ", E('br'), "
        + "E('small', "
        + "{ 'style': 'opacity:.75' }, "
        + "'勾选：保留当前配置；"
        + "取消勾选：清除全部配置（干净刷机）')",
        1
    )

#
# 4. Preserve-config stays enabled by default.
#
if "opts.keep[0].checked = true;" not in flash:
    raise SystemExit(
        "ERROR: LuCI no longer defaults to keep settings"
    )

#
# 5. Our clean image comes back on 192.168.50.1, not 192.168.1.1.
#
flash = flash.replace(
    "'192.168.1.1'",
    "'192.168.50.1'"
)

if "192.168.1.1" in flash:
    raise SystemExit(
        "ERROR: stale 192.168.1.1 reconnect target remains"
    )

#
# 6. Internal patch marker.
#
if "R76S_V110_FLASH_UPLOAD_PATCH" not in flash:
    strict = "'use strict';"

    if strict not in flash:
        raise SystemExit(
            "ERROR: flash.js use-strict anchor missing"
        )

    flash = flash.replace(
        strict,
        strict
        + "\n\n"
        + "// R76S_V110_FLASH_UPLOAD_PATCH\n",
        1
    )

ui_path.write_text(ui)
flash_path.write_text(flash)

print("LuCI large firmware upload patch applied.")
