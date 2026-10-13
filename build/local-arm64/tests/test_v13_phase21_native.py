"""Actual kernel packets in a disposable --network none container only."""
from pathlib import Path
import json
import os
import shutil
import socket
import struct
import subprocess
import tempfile
import threading
import time
import unittest

ROOT=Path(__file__).resolve().parents[3]
BASE=ROOT/'feeds/luci-app-r76s-updater/files/root'
FOREIGN='2001:4860:4860::8888'
DOMESTIC='2400:3200::10'
WECHAT='2606:4700:4700::1111'
TENCENT='2606:4700:4700::1001'


@unittest.skipUnless(os.environ.get('R76S_TEST_NATIVE_PREFIX'), 'isolated NET_ADMIN test environment not set')
class NativeGuard(unittest.TestCase):
    def test_actual_dns_sets_output_forward_established_and_reload(self):
        prefix=json.loads(os.environ['R76S_TEST_NATIVE_PREFIX'])
        root=Path(os.environ['R76S_TEST_NATIVE_ROOT'])
        def run(tool,*args,input=None):
            result=subprocess.run(prefix+[str(root/tool),*args],input=input,text=True,capture_output=True)
            self.assertEqual(result.returncode,0,result.stderr)
            return result.stdout
        def nft(text):return run('usr/sbin/nft','-f','-',input=text)
        def counter(name):
            data=json.loads(run('usr/sbin/nft','-j','list','counter','inet','r76s_test',name))
            return next(x['counter']['packets'] for x in data['nftables'] if 'counter' in x)
        def mac(device):return bytes.fromhex(Path('/sys/class/net',device,'address').read_text().strip().replace(':',''))
        def checksum(data):
            if len(data)%2:data+=b'\0'
            total=sum(struct.unpack('!'+str(len(data)//2)+'H',data))
            while total>>16:total=(total&0xffff)+(total>>16)
            return (~total)&0xffff or 0xffff
        def udp6(src,dst,sport,dport,payload=b'guard-test'):
            source=socket.inet_pton(socket.AF_INET6,src);target=socket.inet_pton(socket.AF_INET6,dst)
            length=8+len(payload);udp=struct.pack('!HHHH',sport,dport,length,0)+payload
            pseudo=source+target+struct.pack('!I3xB',length,17)
            udp=udp[:6]+struct.pack('!H',checksum(pseudo+udp))+udp[8:]
            return struct.pack('!IHBB16s16s',0x60000000,length,17,64,source,target)+udp
        def inject(device,dest_mac,src_mac,packet):
            with socket.socket(socket.AF_PACKET,socket.SOCK_RAW) as raw:
                raw.bind((device,0));raw.send(dest_mac+src_mac+b'\x86\xdd'+packet)
            time.sleep(.05)
        for a,b in [('r76s-lan','r76s-client'),('r76s-wan','r76s-peer')]:
            run('usr/libexec/ip-full','link','add',a,'type','veth','peer','name',b)
            for device in (a,b):run('usr/libexec/ip-full','link','set',device,'up')
        run('usr/libexec/ip-full','-6','addr','add','2001:db8:10::1/64','dev','r76s-lan','nodad')
        run('usr/libexec/ip-full','-6','addr','add','2001:db8:20::1/64','dev','r76s-wan','nodad')
        run('usr/libexec/ip-full','addr','add','198.18.0.1/24','dev','r76s-wan')
        run('usr/libexec/ip-full','-6','route','add','default','dev','r76s-wan')
        run('usr/libexec/ip-full','route','add','default','dev','r76s-wan')
        peer_mac=mac('r76s-peer');peer_text=':'.join(f'{x:02x}' for x in peer_mac)
        for address in (FOREIGN,DOMESTIC,WECHAT,TENCENT):
            run('usr/libexec/ip-full','-6','neigh','add',address,'lladdr',peer_text,'dev','r76s-wan','nud','permanent')
        run('usr/libexec/ip-full','neigh','add','1.1.1.1','lladdr',peer_text,'dev','r76s-wan','nud','permanent')
        nft('''table inet r76s_test {
          counter out6 {}
          counter out4 {}
          counter forwarded {}
          counter ct_established {}
          chain sink { type filter hook prerouting priority -200; policy accept;
            iifname "r76s-peer" drop
          }
          chain output { type filter hook output priority 10; policy accept;
            oifname "r76s-wan" meta l4proto udp meta nfproto ipv6 counter name out6
            oifname "r76s-wan" meta l4proto udp meta nfproto ipv4 counter name out4
            oifname "r76s-wan" meta l4proto udp ct state established counter name ct_established
          }
          chain forward { type filter hook forward priority 10; policy accept;
            oifname "r76s-wan" meta l4proto udp counter name forwarded
          }
        }
        table inet passwall {
          chain forward { type filter hook forward priority 0; policy accept; accept; }
          chain pw_mark { type route hook output priority -150; policy accept; meta mark set 1; }
        }
        table inet passwall2 {
          chain forward { type filter hook forward priority 0; policy accept; accept; }
          chain pw_mark { type filter hook prerouting priority -150; policy accept; meta mark set 2; }
        }
        ''')
        before_tables={name:run('usr/sbin/nft','list','table','inet',name) for name in ('passwall','passwall2')}
        # Create a real established UDP flow BEFORE loading the guard.
        client=socket.socket(socket.AF_INET6,socket.SOCK_DGRAM)
        self.addCleanup(client.close);client.bind(('2001:db8:20::1',0));client.settimeout(2)
        client.sendto(b'first',(FOREIGN,443))
        inject('r76s-peer',mac('r76s-wan'),peer_mac,
               udp6(FOREIGN,'2001:db8:20::1',443,client.getsockname()[1],b'reply'))
        self.assertEqual(client.recv(100),b'reply')
        client.sendto(b'established',(FOREIGN,443));time.sleep(.05)
        self.assertGreater(counter('ct_established'),0)

        with tempfile.TemporaryDirectory() as directory:
            work=Path(directory);routes=work/'cn6';routes.write_text('2400:3200::/32\n')
            env={**os.environ,'R76S_GUARD_CN_ROUTES':str(routes),'R76S_GUARD_LAN_DEVICES':'r76s-lan'}
            rules=subprocess.check_output(['sh',str(BASE/'usr/libexec/r76s/r76s-ip6-guard'),'render'],env=env,text=True)
            run('usr/sbin/nft','-c','-f','-',input=rules);nft(rules)
            before=counter('out6')
            try: client.sendto(b'blocked',(FOREIGN,443))
            except PermissionError: pass  # Linux reports nft output drop as EPERM.
            time.sleep(.05)
            self.assertEqual(counter('out6'),before,'established foreign IPv6 bypassed guard')
            def send_output(address,allowed):
                before=counter('out6')
                with socket.socket(socket.AF_INET6,socket.SOCK_DGRAM) as sender:
                    try: sender.sendto(b'test',(address,443))
                    except PermissionError:
                        if allowed: raise
                time.sleep(.05)
                self.assertEqual(counter('out6')-before,1 if allowed else 0,address)
            def send_forward(address,allowed):
                before=counter('forwarded')
                inject('r76s-client',mac('r76s-lan'),mac('r76s-client'),udp6('2001:db8:10::2',address,2222,443))
                self.assertEqual(counter('forwarded')-before,1 if allowed else 0,address)
            send_output(FOREIGN,False);send_forward(FOREIGN,False)
            send_output(DOMESTIC,True);send_forward(DOMESTIC,True)
            before=counter('out4')
            with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as v4:v4.sendto(b'v4',('1.1.1.1',443))
            self.assertEqual(counter('out4')-before,1,'IPv4 was affected')

            # Real SmartDNS populates the allow set for Tencent IPv6 outside CN CIDRs.
            upstream=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
            upstream.bind(('127.0.0.1',0));upstream.settimeout(.2);self.addCleanup(upstream.close)
            stopped=threading.Event()
            def serve():
                while not stopped.is_set():
                    try:request,address=upstream.recvfrom(4096)
                    except socket.timeout:continue
                    except OSError:return
                    end=12;labels=[]
                    while request[end]:
                        length=request[end];labels.append(request[end+1:end+1+length].decode());end+=length+1
                    end+=1;name='.'.join(labels);kind=struct.unpack('!H',request[end:end+2])[0]
                    answer_ip=TENCENT if name.endswith('tencent.com') else WECHAT if name.endswith('wechat.com') else DOMESTIC
                    value=socket.inet_pton(socket.AF_INET if kind==1 else socket.AF_INET6,'223.5.5.5' if kind==1 else answer_ip)
                    answer=b'\xc0\x0c'+struct.pack('!HHIH',kind,1,60,len(value))+value
                    response=request[:2]+struct.pack('!HHHHH',0x8180,1,1,0,0)+request[12:end+4]+answer
                    upstream.sendto(response,address)
            thread=threading.Thread(target=serve,daemon=True);thread.start()
            cn=work/'cn.list';cn.write_text('cn.example\n')
            tencent=work/'tencent.list';shutil.copy2(BASE/'usr/share/r76s/tencent-direct.list',tencent)
            policy=subprocess.check_output(['sh',str(BASE/'usr/libexec/r76s/r76s-ip-family-policy'),'render'],
                env={**env,'R76S_POLICY_CN_FILE':str(cn),'R76S_POLICY_TENCENT_FILE':str(tencent),'R76S_POLICY_NFTSET':'1'},text=True)
            include=work/'policy.conf';include.write_text(policy)
            config=work/'smartdns.conf'
            config.write_text(f'bind 127.0.0.1:15453\ncache-size 128\nspeed-check-mode none\n'
                f'server 127.0.0.1:{upstream.getsockname()[1]} -group cn\n'
                f'server 127.0.0.1:{upstream.getsockname()[1]} -group foreign\n'
                f'log-file {work}/dns.log\nconf-file {include}\n')
            command=prefix+[str(root/'usr/libexec/r76s/smartdns.bin')]
            process=subprocess.Popen(command+['-f','-c',str(config),'-p',str(work/'pid')],stdout=subprocess.PIPE,stderr=subprocess.PIPE,cwd='/')
            try:
                time.sleep(.5);self.assertIsNone(process.poll())
                seen=set()
                for name,kind,count in [('cn.example',1,1),('cn.example',28,1),('foreign.example',1,1),
                                        ('foreign.example',28,0),('sns.wechat.com',28,1),('tencent.com',28,1),
                                        ('sns.wechat.com',28,1)]:
                    with self.subTest(name=name,kind=kind):
                        if (name,kind) in seen:
                            nft(f'delete element inet r76s_ip6_guard direct6 {{ {WECHAT} }}\n')
                        seen.add((name,kind))
                        query=struct.pack('!HHHHHH',321,0x100,1,0,0,0)
                        query+=b''.join(bytes([len(p)])+p.encode() for p in name.split('.'))+b'\0'+struct.pack('!HH',kind,1)
                        with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as dns:
                            dns.settimeout(3);dns.sendto(query,('127.0.0.1',15453));response=dns.recv(4096)
                        self.assertEqual(struct.unpack('!H',response[6:8])[0],count)
                learned=run('usr/sbin/nft','list','set','inet','r76s_ip6_guard','direct6')
                self.assertIn(WECHAT,learned);self.assertIn(TENCENT,learned)
                send_output(WECHAT,True);send_forward(WECHAT,True)
                send_output(TENCENT,True);send_forward(TENCENT,True)
                nft(rules)  # Reload must retain learned Tencent addresses.
                send_output(WECHAT,True);send_forward(FOREIGN,False)
                snapshot=run('usr/sbin/nft','list','table','inet','r76s_ip6_guard')
                run('usr/sbin/nft','delete','table','inet','r76s_ip6_guard')
                nft(snapshot)  # The same snapshot format used by rollback.
                send_output(WECHAT,True);send_output(FOREIGN,False)
            finally:
                process.terminate();process.communicate(timeout=5);stopped.set();thread.join(timeout=1)
        for name,content in before_tables.items():
            self.assertEqual(run('usr/sbin/nft','list','table','inet',name),content)
