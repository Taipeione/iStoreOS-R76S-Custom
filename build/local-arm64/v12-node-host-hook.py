#!/usr/bin/env python3
"""Use the matching prebuilt host Node, retaining all target build rules."""
from pathlib import Path
import sys


def patch(makefile, root):
    root = Path(root).resolve()
    for tool in ('node', 'npm', 'npx'):
        if not (root / 'bin' / tool).is_file():
            raise ValueError(f'External host {tool} missing')
    if any(character in str(root) for character in (' ', '\n', '$', '"')):
        raise ValueError('Unsupported Node root path')
    source = Path(makefile).read_text()
    anchor = '$(eval $(call HostBuild))'
    marker = '# R76S_EXTERNAL_NODE_HOST'
    injection = f'''{marker}
# This is a host dependency only; the target Node package remains unchanged.
HOST_BUILD_DEPENDS:=
define Host/Prepare
\t$(INSTALL_DIR) $(HOST_BUILD_DIR)
endef
define Host/Configure
endef
define Host/Compile
\t{root}/bin/node --version | grep -qxF v20.20.2
endef
define Host/Install
\t$(INSTALL_DIR) $(1)/bin
\tln -sf {root}/bin/node $(1)/bin/node
\tln -sf {root}/bin/npm $(1)/bin/npm
\tln -sf {root}/bin/npx $(1)/bin/npx
endef

'''
    if marker in source:
        if injection not in source:
            raise ValueError('Existing external Node hook differs')
        return
    if source.count(anchor) != 1 or 'PKG_VERSION:=20.20.2' not in source:
        raise ValueError('Unexpected pinned Node package')
    Path(makefile).write_text(source.replace(anchor, injection + anchor))


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('Usage: hook.py node-Makefile node-root')
    patch(sys.argv[1], sys.argv[2])
    print('R76S_EXTERNAL_NODE_HOST=PASS')
