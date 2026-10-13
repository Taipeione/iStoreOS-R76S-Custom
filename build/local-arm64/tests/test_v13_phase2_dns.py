"""Policy transactions plus optional real SmartDNS DNS checks on loopback only."""
from pathlib import Path
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[3]
POLICY = ROOT / 'feeds/luci-app-r76s-updater/files/root/usr/libexec/r76s/r76s-ip-family-policy'
TENCENT = ROOT / 'feeds/luci-app-r76s-updater/files/root/usr/share/r76s/tencent-direct.list'

MOCK_UCI = '''import json,os,sys
from pathlib import Path
root=Path(os.environ['R76S_POLICY_ROOT']); config=root/'etc/config/smartdns'
args=[a for a in sys.argv[1:] if a!='-q']; action=args[0]; state=json.loads(config.read_text())
if action=='changes':
    print(state.get('_pending',''),end=''); sys.exit(0)
if action=='show':
    for k,v in state.items():
        if k.startswith('smartdns.'): print(k+"='"+str(v)+"'")
    sys.exit(0)
if action=='get':
    value=state.get(args[1]);
    if value is None: sys.exit(1)
    print(' '.join(value) if isinstance(value,list) else value); sys.exit(0)
if action in ('add_list','del_list'):
    key,value=args[1].split('=',1); items=state.get(key,[])
    if action=='add_list': items.append(value)
    else: items=[v for v in items if v!=value]
    state[key]=items; config.write_text(json.dumps(state)); sys.exit(0)
if action=='commit': sys.exit(1 if os.environ.get('FAIL_COMMIT')=='1' else 0)
if action=='revert': sys.exit(0)
sys.exit(2)
'''


class PolicyTransactions(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'etc/config').mkdir(parents=True)
        (self.root / 'usr/share/passwall/rules').mkdir(parents=True)
        (self.root / 'usr/share/passwall/rules/chnlist').write_text('cn.example\n')
        (self.root / 'usr/share/r76s').mkdir(parents=True)
        shutil.copy2(TENCENT, self.root/'usr/share/r76s/tencent-direct.list')
        self.config = self.root / 'etc/config/smartdns'
        self.state = {'smartdns.@smartdns[0].enabled': '1',
            'smartdns.@smartdns[0].conf_files': ['/etc/smartdns/user.conf'],
            'smartdns.cn': 'server', 'smartdns.foreign': 'server',
            'smartdns.cn.enabled': '1', 'smartdns.cn.server_group': 'cn',
            'smartdns.foreign.enabled': '1', 'smartdns.foreign.server_group': 'foreign',
            'smartdns.cn.ip': '223.5.5.5', 'smartdns.foreign.ip': '1.1.1.1'}
        self.config.write_text(json.dumps(self.state))
        bindir = self.root / 'bin'; bindir.mkdir()
        uci = bindir / 'uci'
        uci.write_text('#!' + sys.executable + '\n' + MOCK_UCI); uci.chmod(0o755)
        self.env = {**os.environ, 'R76S_POLICY_ROOT': str(self.root),
                    'PATH': str(bindir) + ':' + os.environ['PATH']}

    def call(self, action, ok=True, **env):
        result = subprocess.run(['sh', str(POLICY), action], env={**self.env, **env},
                                capture_output=True, text=True)
        if ok: self.assertEqual(result.returncode, 0, result.stderr)
        else: self.assertNotEqual(result.returncode, 0)
        return result

    def test_domestic_and_local_ipv6_render(self):
        text = self.call('render').stdout
        self.assertIn('/domain-set:r76s-v13-cn/ -nameserver cn -address -6', text)
        self.assertIn('/home.arpa/ -nameserver - -address -6', text)
        self.assertIn('-dualstack-ip-selection no', text)
        self.assertFalse((self.root / 'etc/smartdns').exists())

    def test_foreign_ipv4_render_and_input_rejection(self):
        self.assertIn('/./ -nameserver foreign -address #6', self.call('render').stdout)
        self.call('render', ok=False, R76S_POLICY_CN_GROUP='cn\nserver 8.8.8.8')
        self.call('render', ok=False, R76S_POLICY_FOREIGN_GROUP='cn')

    def test_enable_is_additive_idempotent_and_disable_preserves_users(self):
        self.call('enable'); self.call('enable')
        state = json.loads(self.config.read_text())
        self.assertEqual(state['smartdns.@smartdns[0].conf_files'],
                         ['/etc/smartdns/user.conf', '/etc/smartdns/r76s-v13/ip-family.conf'])
        for key, value in self.state.items():
            if not key.endswith('conf_files'): self.assertEqual(state[key], value)
        self.call('disable')
        self.assertEqual(json.loads(self.config.read_text()), self.state)

    def test_failed_commit_restores_configuration(self):
        original = self.config.read_bytes()
        self.call('enable', ok=False, FAIL_COMMIT='1')
        self.assertEqual(self.config.read_bytes(), original)
        self.assertFalse((self.root / 'etc/smartdns/r76s-v13/ip-family.conf').exists())

    def test_user_profile_and_concurrent_operation_are_not_overwritten(self):
        directory = self.root / 'etc/smartdns/r76s-v13'
        directory.mkdir(parents=True)
        profile = directory / 'ip-family.conf'
        profile.write_text('# User configuration\n')
        before = self.config.read_bytes()
        self.call('enable', ok=False)
        self.assertEqual(profile.read_text(), '# User configuration\n')
        self.assertEqual(self.config.read_bytes(), before)
        profile.unlink()
        (directory / '.lock').mkdir()
        self.call('enable', ok=False)
        self.assertTrue((directory / '.lock').is_dir())
        self.assertEqual(self.config.read_bytes(), before)

    def test_disable_failure_keeps_original_include_and_profile(self):
        self.call('enable')
        before = self.config.read_bytes()
        profile = self.root / 'etc/smartdns/r76s-v13/ip-family.conf'
        text = profile.read_bytes()
        self.call('disable', ok=False, FAIL_COMMIT='1')
        self.assertEqual(self.config.read_bytes(), before)
        self.assertEqual(profile.read_bytes(), text)

    def test_unsafe_preconditions_leave_configuration_untouched(self):
        for changes in ({'smartdns.@smartdns[0].enabled': '0'},
                        {'smartdns.cn.enabled': '0'},
                        {'smartdns.cn': 'unrelated_section'},
                        {'smartdns.@smartdns[0].force_aaaa_soa': '1'},
                        {'dhcp.@dnsmasq[0].filter_aaaa': '1'},
                        {'dhcp.@dnsmasq[0].filter_a': '1'}, {'_pending': 'unsaved'}):
            with self.subTest(changes=changes):
                self.config.write_text(json.dumps({**self.state, **changes}))
                before = self.config.read_bytes()
                self.call('enable', ok=False)
                self.assertEqual(self.config.read_bytes(), before)


@unittest.skipUnless(os.environ.get('R76S_TEST_SMARTDNS_CMD'), 'real SmartDNS test command not set')
class RealSmartDNS(unittest.TestCase):
    def test_domestic_A_AAAA_foreign_A_only(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            domains = folder / 'cn.list'; domains.write_text('cn.example\n')
            tencent = folder/'tencent.list'; shutil.copy2(TENCENT,tencent)
            env = {**os.environ, 'R76S_POLICY_CN_FILE': str(domains),
                   'R76S_POLICY_TENCENT_FILE': str(tencent), 'R76S_POLICY_NFTSET': '0'}
            policy = subprocess.check_output(['sh', str(POLICY), 'render'], env=env, text=True)
            include = folder / 'policy.conf'; include.write_text(policy)
            upstream = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            upstream.bind(('127.0.0.1', 0)); upstream.settimeout(.2)
            self.addCleanup(upstream.close)
            probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            probe.bind(('127.0.0.1', 0)); port = probe.getsockname()[1]; probe.close()
            stopped = threading.Event()
            def serve():
                while not stopped.is_set():
                    try: request, address = upstream.recvfrom(4096)
                    except socket.timeout: continue
                    except OSError: return
                    end = 12
                    while request[end]: end += request[end] + 1
                    end += 1
                    kind = struct.unpack('!H', request[end:end+2])[0]
                    value = socket.inet_pton(socket.AF_INET if kind == 1 else socket.AF_INET6,
                                            '223.5.5.5' if kind == 1 else '2400:3200::1')
                    header = request[:2] + struct.pack('!HHHHH', 0x8180, 1, 1, 0, 0)
                    answer = b'\xc0\x0c' + struct.pack('!HHIH', kind, 1, 60, len(value)) + value
                    upstream.sendto(header + request[12:end+4] + answer, address)
            thread = threading.Thread(target=serve, daemon=True); thread.start()
            config = folder / 'smartdns.conf'
            config.write_text(f'bind 127.0.0.1:{port}\ncache-size 0\nspeed-check-mode none\n'
                f'server 127.0.0.1:{upstream.getsockname()[1]} -group cn\n'
                f'server 127.0.0.1:{upstream.getsockname()[1]} -group foreign\n'
                f'log-file {folder}/smartdns.log\nconf-file {include}\n')
            command = json.loads(os.environ['R76S_TEST_SMARTDNS_CMD'])
            process = subprocess.Popen(command + ['-f', '-c', str(config), '-p', str(folder/'pid')],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd='/')
            try:
                time.sleep(.5)
                self.assertIsNone(process.poll(), 'SmartDNS did not start')
                for name, kind, expected in [('cn.example', 1, 1), ('cn.example', 28, 1),
                                             ('foreign.example', 1, 1), ('foreign.example', 28, 0),
                                             ('sns.wechat.com', 28, 1), ('tencent.com', 28, 1)]:
                    with self.subTest(domain=name, kind=kind):
                        query = struct.pack('!HHHHHH', 123, 0x100, 1, 0, 0, 0)
                        query += b''.join(bytes([len(p)])+p.encode() for p in name.split('.'))
                        query += b'\0' + struct.pack('!HH', kind, 1)
                        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
                            client.settimeout(3); client.sendto(query, ('127.0.0.1', port))
                            response = client.recv(4096)
                        _, flags, _, count, _, _ = struct.unpack('!HHHHHH', response[:12])
                        self.assertEqual(flags & 15, 0)
                        self.assertEqual(count, expected)
            finally:
                process.terminate()
                process.communicate(timeout=5)
                stopped.set(); thread.join(timeout=1)
