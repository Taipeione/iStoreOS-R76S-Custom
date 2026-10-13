from pathlib import Path
import json
import os
import shutil
import subprocess
import unittest
ROOT=Path(__file__).resolve().parents[3]
FILES=ROOT/'feeds/luci-app-r76s-status/files'
NODE=os.environ.get('R76S_TEST_NODE') or shutil.which('node')

class WireGuardUX(unittest.TestCase):
    @unittest.skipUnless(NODE, 'Node runtime unavailable')
    def test_config_generator_and_view(self):
        result=subprocess.run([NODE,'build/local-arm64/tests/v13-wireguard-client-test.js'],cwd=ROOT,text=True,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('WIREGUARD_CLIENT_CONFIG_AND_VIEW=PASS',result.stdout)
        if os.environ.get('R76S_TEST_UQR'):
            self.assertIn('WIREGUARD_REAL_QR=PASS',result.stdout)

    @unittest.skipUnless(NODE, 'Node runtime unavailable')
    def test_javascript_syntax(self):
        for file in (FILES/'htdocs').rglob('*.js'):
            result=subprocess.run([NODE,'--check',str(file)],text=True,capture_output=True)
            self.assertEqual(result.returncode,0,result.stderr)

    @unittest.skipUnless(NODE, 'Node runtime unavailable')
    def test_status_refresh(self):
        result=subprocess.run([NODE,'build/local-arm64/tests/v13-wireguard-status-test.js'],cwd=ROOT,text=True,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('WIREGUARD_STATUS_REFRESH=PASS',result.stdout)

    def test_packaging_and_authorization(self):
        menu=json.loads((FILES/'root/usr/share/luci/menu.d/r76s-wireguard-client.json').read_text())
        self.assertEqual(menu['admin/network/r76s_wireguard_client']['depends']['acl'],['luci-proto-wireguard'])
        makefile=(FILES.parent/'Makefile').read_text()
        for relative in ('root/usr/share/luci/menu.d/r76s-wireguard-client.json','htdocs/luci-static/resources/view/r76s_wireguard/client.js'):
            self.assertIn(relative,makefile)
        self.assertIn('+luci-lib-uqr',makefile)
        generator=(FILES/'htdocs/luci-static/resources/view/r76s_wireguard/client.js').read_text()
        self.assertNotIn('localStorage',generator)
        self.assertNotIn('sessionStorage',generator)
        self.assertNotIn('uci.set',generator)

    @unittest.skipUnless(os.environ.get('R76S_TEST_WG_ROOT') and NODE, 'isolated native WireGuard environment unavailable')
    def test_actual_wireguard_accepts_generated_peer_config(self):
        root=Path(os.environ['R76S_TEST_WG_ROOT'])
        prefix=[str(root/'lib/ld-musl-aarch64.so.1'),'--library-path',str(root/'lib')+':'+str(root/'usr/lib')]
        wg=prefix+[str(root/'usr/bin/wg')]
        ip=prefix+[str(root/'usr/libexec/ip-full')]
        def command(args, data=None):
            result=subprocess.run(args,input=data,text=True,capture_output=True)
            self.assertEqual(result.returncode,0,result.stderr)
            return result.stdout.strip()
        private=command(wg+['genkey'])
        public=command(wg+['pubkey'], private+'\n')
        server_private=command(wg+['genkey'])
        server_public=command(wg+['pubkey'],server_private+'\n')
        script="""
const fs=require('fs'),net=require('net');
const c=new Function('baseclass','validation',fs.readFileSync('feeds/luci-app-r76s-status/files/htdocs/luci-static/resources/r76s/wireguard.js','utf8'))({extend:x=>x},{parseIPv4:v=>net.isIP(v)===4,parseIPv6:v=>net.isIP(v)===6});
const data=JSON.parse(fs.readFileSync(0,'utf8'));process.stdout.write(c.build(data).text);
"""
        settings=dict(name='test',privateKey=private,serverKey=server_public,address='10.7.0.2/24, fd00:7::2/64',allowed='0.0.0.0/0, ::/0',endpoint='127.0.0.1:51820',keepalive='25')
        generated=subprocess.run([NODE,'-e',script],cwd=ROOT,input=json.dumps(settings),text=True,capture_output=True)
        self.assertEqual(generated.returncode,0,generated.stderr)
        # Address/DNS/MTU are wg-quick/client directives; wg setconf consumes the core sections.
        native='\n'.join(line for line in generated.stdout.splitlines() if not line.startswith(('Address =','DNS =','MTU =')))+'\n'
        command(ip+['link','add','wg22test','type','wireguard'])
        try:
            import tempfile
            with tempfile.NamedTemporaryFile(mode='w') as config:
                config.write(native);config.flush()
                command(wg+['setconf','wg22test',config.name])
            self.assertEqual(command(wg+['show','wg22test','public-key']),public)
            self.assertEqual(command(wg+['show','wg22test','peers']),server_public)
            self.assertIn('0.0.0.0/0',command(wg+['show','wg22test','allowed-ips']))
            self.assertIn('::/0',command(wg+['show','wg22test','allowed-ips']))
        finally:
            command(ip+['link','del','wg22test'])
