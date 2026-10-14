#!/usr/bin/env python3
"""Build V1.2.3 from the exact V1.2.2 baseline, changing only OTA and identity."""
import argparse
import ast
from pathlib import Path
import subprocess

BASE = '1daed16ac79d66666847bca6e4c29bc5f4c88b95'

def prepare(root):
    assert subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip() == BASE
    patch = root / 'build/local-arm64/patches/r76s-v12-ota-hardening.py'
    source = patch.read_text()
    old = "uci -q set r76s_ota_state.state='state' || fail 'cannot create OTA state section'"
    new = """# UCI requires its package file before creating a named section.
mkdir -p /etc/config || fail 'cannot create config directory'
if [ ! -s /etc/config/r76s_ota_state ]; then
    (umask 077; printf "config state 'state'\\n" > /etc/config/r76s_ota_state) || fail 'cannot initialize OTA state file'
fi
uci -q set r76s_ota_state.state='state' || fail 'cannot create OTA state section'"""
    assert source.count(old) == 1
    patch.write_text(source.replace(old, new))
    # Restrict identity substitution to files tracked by the baseline.
    tracked = subprocess.check_output(['git', '-C', str(root), 'ls-files', '-z']).split(b'\0')
    for name in tracked:
        if not name:
            continue
        path = root / name.decode()
        data = path.read_bytes()
        if b'1.2.2' in data:
            path.write_bytes(data.replace(b'1.2.2', b'1.2.3'))
    compile(patch.read_text(), str(patch), 'exec')
    tree = ast.parse(patch.read_text())
    preserve = next(ast.literal_eval(node.value) for node in tree.body
                    if isinstance(node, ast.Assign) and any(
                        isinstance(target, ast.Name) and target.id == 'PRESERVE'
                        for target in node.targets))
    assets = root / 'build/maintenance-v123'
    assets.mkdir(parents=True, exist_ok=True)
    helper = assets / 'r76s-ota-preserve-state'
    helper.write_text(preserve)
    helper.chmod(0o755)
    subprocess.run(['sh', '-n', str(helper)], check=True)
    print('V123_BASELINE_OTA_PATCH=PASS')

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', type=Path, required=True)
    prepare(parser.parse_args().repo.resolve())
