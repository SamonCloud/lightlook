"""验证局域网媒体服务与模拟 DLNA 电视，所有服务仅用于本地测试。"""
import http.server
import threading
import subprocess
import urllib.request
import urllib.error
import xml.etree.ElementTree as ET
import pathlib
import time
import os
import socket
import struct

ROOT = pathlib.Path(__file__).resolve().parents[1]
EXE = ROOT / 'build/media-tests'
MEDIA = ROOT / 'build/测试素材/05-视频测试.mp4'
ENV = dict(os.environ, NO_PROXY='*', no_proxy='*')
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

def request(url, method='GET', headers=None):
    return opener.open(urllib.request.Request(url, method=method, headers=headers or {}), timeout=10)

proc = subprocess.Popen([str(EXE), '--serve', str(MEDIA)], stdout=subprocess.PIPE, text=True, env=ENV)
try:
    url = proc.stdout.readline().strip()
    assert url.startswith('http://'), url
    raw = MEDIA.read_bytes()
    with request(url) as r:
        assert r.status == 200 and r.read() == raw
        assert r.headers['Accept-Ranges'] == 'bytes'
    with request(url, 'HEAD') as r:
        assert int(r.headers['Content-Length']) == len(raw) and r.read() == b''
    for value, expected in [('bytes=10-199', raw[10:200]), ('bytes=-100', raw[-100:]), ('bytes=100-', raw[100:])]:
        with request(url, headers={'Range':value}) as r:
            assert r.status == 206 and r.read() == expected
            assert r.headers['Content-Range'].startswith('bytes ')
    for target, headers, code in [(url, {'Range':'bytes=999999999-'}, 416), (url+'/../secret', {}, 404)]:
        try:
            request(target, headers=headers)
            raise AssertionError('Expected failure')
        except urllib.error.HTTPError as e:
            assert e.code == code, e.code
    with request(url, headers={'Range':'bytes=0-9'}) as r:
        assert r.read() == raw[:10]
    print('PASS HTTP GET/HEAD, bounded byte ranges, suffix/open ranges, 416/404, repeated connection')
finally:
    proc.terminate(); proc.wait(timeout=5)

state = {'uri':None, 'metadata':None, 'actions':[], 'errors':[], 'kind':'video'}
ready = threading.Event()
class Television(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_GET(self):
        body = f'''<root xmlns="urn:schemas-upnp-org:device-1-0"><device><friendlyName>Test TV &amp; Screen</friendlyName><serviceList><service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><controlURL>/control</controlURL></service></serviceList></device></root>'''.encode()
        self.send_response(200); self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        try:
            root = ET.fromstring(self.rfile.read(int(self.headers['Content-Length'])))
            action = list(list(root)[0])[0]
            name = action.tag.rsplit('}',1)[-1]
            state['actions'].append(name)
            if name == 'SetAVTransportURI':
                state['uri'] = action.findtext('CurrentURI')
                state['metadata'] = ET.fromstring(action.findtext('CurrentURIMetaData'))
                assert state['uri'].startswith('http://')
            self.send_response(200); self.send_header('Content-Length','0'); self.end_headers()
            if name == 'Play':
                def fetch():
                    try:
                        with request(state['uri'], headers={'Range':'bytes=0-1023'}) as r:
                            assert r.status == 206
                            data = r.read()
                            if state['kind'] == 'image':
                                assert data.startswith(b'\xff\xd8') and r.headers['Content-Type'] == 'image/jpeg'
                            else:
                                assert data == MEDIA.read_bytes()[:1024]
                    except Exception as e:
                        state['errors'].append(str(e))
                    finally:
                        ready.set()
                threading.Thread(target=fetch,daemon=True).start()
        except Exception as e:
            state['errors'].append(str(e)); ready.set(); self.send_error(500)

server = http.server.ThreadingHTTPServer(('127.0.0.1',0),Television)
threading.Thread(target=server.serve_forever,daemon=True).start()
proc = subprocess.Popen([str(EXE),'--cast',f'http://127.0.0.1:{server.server_port}/description.xml',str(MEDIA)],stdout=subprocess.PIPE, text=True, env=ENV)
try:
    assert ready.wait(20), 'mock TV timeout'
    assert state['errors'] == [], state['errors']
    assert state['actions'] == ['SetAVTransportURI','Play'], state['actions']
    print('PASS DLNA device XML, relative control URL, SOAP/DIDL escaping, SetAVTransportURI → Play → TV range fetch')
finally:
    proc.terminate(); proc.wait(timeout=5); server.shutdown()

# 验证照片转为 JPEG 后实际可供电视读取。
ready.clear(); state.update(uri=None,metadata=None,actions=[],errors=[],kind='image')
server = http.server.ThreadingHTTPServer(('127.0.0.1',0),Television)
threading.Thread(target=server.serve_forever,daemon=True).start()
proc = subprocess.Popen([str(EXE),'--cast',f'http://127.0.0.1:{server.server_port}/description.xml',str(ROOT/'build/测试素材/01-参数测试.jpg')],stdout=subprocess.PIPE,text=True,env=ENV)
try:
    assert ready.wait(20), 'image cast timeout'
    assert not state['errors'], state['errors']
    assert state['actions'] == ['SetAVTransportURI','Play']
    print('PASS DLNA image conversion → JPEG resource → TV range fetch')
finally:
    proc.terminate(); proc.wait(timeout=5); server.shutdown()

# 验证 M-SEARCH、多播接收、LOCATION 解析和设备描述加载。
udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
udp.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
udp.bind(('',1900))
udp.setsockopt(socket.IPPROTO_IP,socket.IP_ADD_MEMBERSHIP,socket.inet_aton('239.255.255.250')+socket.inet_aton('0.0.0.0'))
udp.settimeout(10)
server = http.server.ThreadingHTTPServer(('0.0.0.0',0),Television)
threading.Thread(target=server.serve_forever,daemon=True).start()
def respond_ssdp():
    try:
        for _ in range(2):
            data, peer = udp.recvfrom(8192)
            if b'M-SEARCH' in data:
                description = f'http://127.0.0.1:{server.server_port}/description.xml'
                udp.sendto(f'HTTP/1.1 200 OK\r\nLOCATION: {description}\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n'.encode(),peer)
    except socket.timeout:
        pass
threading.Thread(target=respond_ssdp,daemon=True).start()
try:
    result = subprocess.run([str(EXE),'--discover'],capture_output=True,text=True,env=ENV,timeout=18)
    assert result.returncode == 0, (result.stdout,result.stderr)
    assert 'Test TV & Screen' in result.stdout
    print('PASS SSDP multicast discovery → LOCATION → device description → renderer')
finally:
    udp.close(); server.shutdown()
