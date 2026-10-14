"""Regression against the exact upstream init which failed cloud Stage20."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[3]
FIXTURE=ROOT/'build/local-arm64/tests/fixtures/smartdns-1.2023.43.init'
spec=importlib.util.spec_from_file_location('boot_policy',ROOT/'scripts/r76s-v111-image-boot-policy.py')
policy=importlib.util.module_from_spec(spec);spec.loader.exec_module(policy)

class Stage20(unittest.TestCase):
    def test_real_upstream_multiline_function_and_idempotence(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);source=root/'smartdns';overlay=root/'files';overlay.mkdir()
            shutil.copyfile(FIXTURE,source)
            policy.patch_smartdns_source(source,overlay)
            first=source.read_bytes()
            policy.patch_smartdns_source(source,overlay)
            self.assertEqual(source.read_bytes(),first)
            self.assertEqual((overlay/'etc/init.d/smartdns').read_bytes(),first)
            self.assertIn('start_service()\n{\n\t/usr/libexec/r76s/r76s-service-manager check smartdns || return 1',first.decode())

    def test_unrecognized_or_misplaced_guard_blocks_without_writes(self):
        for text in ('#!/bin/sh /etc/rc.common\nSTART=19\n',
                     '#!/bin/sh /etc/rc.common\nSTART=19\nstart_service() {\n true\n}\n/usr/libexec/r76s/r76s-service-manager check smartdns || return 1\n'):
            with tempfile.TemporaryDirectory() as directory:
                root=Path(directory);source=root/'smartdns';overlay=root/'files';overlay.mkdir()
                source.write_text(text)
                with self.assertRaises(policy.Blocked):policy.patch_smartdns_source(source,overlay)
                self.assertEqual(source.read_text(),text)
                self.assertFalse((overlay/'etc/init.d/smartdns').exists())

    def test_entire_stage20_prerequisites_standalone(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);work=root/'work';work.mkdir();repo=root/'repo'
            prepare=repo/'build/local-arm64/v12-prepare-go-and-passwall.sh'
            prepare.parent.mkdir(parents=True)
            prepare.write_text('#!/bin/sh\necho GO126_PASSWALL_SOURCES=PASS\n')
            shutil.copyfile(ROOT/'build/local-arm64/v12-ota-exact-version.py',prepare.parent/'v12-ota-exact-version.py')
            scripts=work/'scripts';scripts.mkdir()
            shutil.copyfile(ROOT/'scripts/r76s-v111-image-boot-policy.py',scripts/'r76s-v111-image-boot-policy.py')
            fw=work/'openwrt';(fw/'files').mkdir(parents=True)
            ota=fw/'package/diy/luci-app-ota/root/bin/ota';ota.parent.mkdir(parents=True)
            ota.write_text('#!/bin/sh\nif echo "$remote" | grep -Fq "$current"; then true; fi\n')
            source=fw/'build_dir/smartdns-1.2023.43/package/openwrt/files/etc/init.d/smartdns'
            source.parent.mkdir(parents=True);shutil.copyfile(FIXTURE,source)
            bindir=root/'bin';bindir.mkdir()
            make=bindir/'make';make.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$MAKE_LOG"\n');make.chmod(0o755)
            stage=next((ROOT/'build/local-arm64/stages').glob('20-*.sh'))
            result=subprocess.run(['bash',str(stage)],cwd=work,env={**os.environ,
                'PATH':str(bindir)+':'+os.environ['PATH'],'R76S_REPO_ROOT':str(repo),
                'R76S_STAGE20_PREPARE_ONLY':'1','MAKE_LOG':str(root/'make.log')},capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertIn('STAGE20_PREPARE_ONLY=PASS',result.stdout)
            self.assertEqual((root/'make.log').read_text().splitlines(),['-j1 package/smartdns/prepare V=s'])

if __name__=='__main__':unittest.main()
