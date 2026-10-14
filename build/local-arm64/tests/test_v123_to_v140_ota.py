"""Execute the actual V1.2.3 release helper, then the V1.4 restore implementation."""
import hashlib
import os
from pathlib import Path
import subprocess
import unittest
import test_v131_ota_state as ota
hardening=ota.hardening

ROOT=Path(__file__).resolve().parents[3]
HELPER=ROOT/'build/local-arm64/tests/fixtures/v123-r76s-ota-preserve-state'
DIGEST='38f92ae81a4998a4229638b4520fc5f37e91f7fd77cb7cc7d2f30e8df3a7c4d2'

class V123Artifact(unittest.TestCase):
    def test_source_release_helper_is_pinned_and_initializes_uci(self):
        self.assertEqual(hashlib.sha256(HELPER.read_bytes()).hexdigest(),DIGEST)
        self.assertIn("printf \"config state 'state'\\n\"",HELPER.read_text())

@unittest.skipUnless(os.environ.get('R76S_TEST_ROOTFS') or os.environ.get('R76S_TEST_UCI'),'requires real firmware UCI')
class V123ToV140(ota.RealUCI):
    def setUp(self):
        super().setUp()
        self.source=HELPER.read_text().replace('/etc/config',str(self.config))
        self.source=self.source.replace('/etc/init.d',str(self.init))
        self.source=self.source.replace('/tmp/r76s-ota-state.',str(self.base/'verify-'))

    def test_first_ota_does_not_recreate_initialized_section(self):
        # V1.2.3 deliberately always sets the named section; it predates the
        # V1.4 no-recreation optimization. Test its actual repeated-save contract.
        self.seed((1,0,1),(1,0,1,0))
        for _ in range(2):
            result=self.run_helper()
            self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn("option pending '1'",self.snapshot())

    def test_unpersisted_changes_cannot_pass_verification(self):
        # Reproduce the source release defect, then prove the distributed fixed
        # pre-upgrade helper rejects the exact same fault. Never hide this as a skip.
        self.seed((1,0,1),(1,0,1,0))
        import shlex
        self.wrapper.write_text('#!/bin/sh\ncase " $* " in *" commit r76s_ota_state "*) exit 0;; esac\nexec '
            +shlex.join(self.command)+' "$@"\n')
        old=self.run_helper()
        self.assertEqual(old.returncode,0,old.stderr)
        self.assertNotIn("option pending '1'",(self.config/'r76s_ota_state').read_text())
        self.source=(ROOT/'files/usr/libexec/r76s/r76s-ota-preserve-state').read_text().replace('/etc/config',str(self.config))
        self.source=self.source.replace('/etc/init.d',str(self.init)).replace('/tmp/r76s-ota-state.',str(self.base/'verify-'))
        fixed=self.run_helper()
        self.assertNotEqual(fixed.returncode,0)
        self.assertIn('cannot read committed pending',fixed.stderr)

    def test_user_network_nodes_and_all_rules_survive(self):
        self.seed((1,0,1),(1,0,1,1))
        payloads={
            'network':"config interface 'wan'\n option proto 'pppoe'\n option username 'test-user'\n option password 'TEST-ONLY'\n option ipv6 'auto'\nconfig interface 'wan6'\n option proto 'dhcpv6'\n option reqprefix 'auto'\nconfig interface 'wg0'\n option proto 'wireguard'\n option private_key 'TEST-ONLY'\n",
            'dhcp':"config dhcp 'lan'\n option ra 'server'\n option dhcpv6 'server'\n",
            'firewall':"config defaults\n option input 'REJECT'\n",
            'ddns':"config service 'home'\n option domain 'test.example'\n"}
        for name,text in payloads.items():(self.config/name).write_text(text)
        for name in ('passwall','passwall2'):
            with (self.config/name).open('a') as file:
                file.write("config nodes 'user_node'\n option address 'test.example'\n option password 'TEST-ONLY'\n")
                # Realistic complete library plus a user-owned rule.
                for index in range(44):file.write(f"config shunt_rules 'rule_{index}'\n option domain_list 'domain:test{index}.example'\n")
        agh=self.base/'adguardhome.yaml';agh.write_text('dns:\n  port: 3053\n  upstream_dns: [127.0.0.1:6053]\n')
        sd=self.base/'smartdns-user.conf';sd.write_text('server 223.5.5.5 -group cn\n')
        before={name:subprocess.check_output(self.command+['export',name],text=True) for name in ('passwall','passwall2','smartdns')}
        self.assertEqual(self.run_helper().returncode,0)
        restore=hardening.RESTORE_INIT.replace('/etc/init.d',str(self.init)).replace('/etc/adguardhome.yaml',str(agh))
        result=subprocess.run(self.shell+['-c',restore+'\nstart\n'],env=self.env,capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        for name,export in before.items():self.assertEqual(subprocess.check_output(self.command+['export',name],text=True),export)
        for name,text in payloads.items():self.assertEqual((self.config/name).read_text(),text)
        self.assertEqual(agh.read_text(),'dns:\n  port: 3053\n  upstream_dns: [127.0.0.1:6053]\n')
        self.assertEqual(sd.read_text(),'server 223.5.5.5 -group cn\n')
