#!/usr/bin/env python3
import pathlib
import re
import subprocess
import unittest

ROOT=pathlib.Path(__file__).resolve().parents[3]
STAGES=ROOT/'build/local-arm64/stages'


def get(num):
    paths=list(STAGES.glob(f'{num:02d}-*.sh'))
    assert len(paths)==1
    return paths[0].read_text()


class Safety(unittest.TestCase):
    def test_29_stage_syntax(self):
        paths=list(STAGES.glob('[0-9][0-9]-*.sh'))
        self.assertEqual(len(paths),29)
        for f in paths:
            with self.subTest(path=f.name):
                self.assertEqual(subprocess.run(['bash','-n',str(f)], capture_output=True).returncode,0)

    def test_no_runner_deletion(self):
        s=get(2)
        self.assertNotIn('sudo rm -rf',s)
        self.assertNotIn('apt clean',s)

    def test_staging_overlay_not_wiped(self):
        self.assertNotIn('rm -rf openwrt/files',get(16))

    def test_arm_memory_limit(self):
        self.assertIn('R76S_JOBS:-4',get(20))
        self.assertNotIn('JOBS="$(nproc)"',get(20))

    def test_maintains_source_cache(self):
        s=get(11)
        self.assertNotIn('\nrm -rf package/passwall-packages',s)
        self.assertIn('9178f2e627a1a104b0b35d1c47a7672dff42c970',s)
        self.assertIn('701d982a26ee0b960d248754b8f8868f6f18fb59',s)
        self.assertIn('2de5aee7a4c704a5b689fdab47b97a18ad11c1a2',s)

    def test_versions_are_v12(self):
        self.assertIn('CONFIG_VERSION_CODE="V1.2"',(ROOT/'config/R76S.config').read_text())
        for i in (6,23,24,27,29):
            self.assertIn('V1.2',get(i))

    def test_production_is_guarded(self):
        runner=ROOT/'build/local-arm64/macmini.sh'
        p=subprocess.run(['bash',str(runner),'build'], capture_output=True,text=True)
        self.assertEqual(p.returncode,3)
        self.assertIn('DENIED',p.stderr)

    def test_preflight_reports_inputs_and_keeps_release_blocked(self):
        script=ROOT/'build/local-arm64/preflight.py'
        p=subprocess.run(['python3',str(script),'--repo',str(ROOT)],capture_output=True,text=True)
        self.assertEqual(p.returncode,0,p.stdout + p.stderr)
        self.assertIn('MISSING_REPO_FILES=0',p.stdout)
        self.assertIn('REPO_INPUTS=PASS',p.stdout)
        self.assertIn('PRODUCTION_IMAGE_RELEASE=BLOCKED',p.stdout)


if __name__=='__main__': unittest.main()
