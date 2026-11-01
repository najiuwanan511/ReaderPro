"""Deterministic HTTP fixtures used by the iOS engine and UI tests.

No third-party sites, copyrighted books or user data. The host app really uses
URLSession, so an ATS regression fails instead of passing via URLProtocol.
"""
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlsplit, parse_qs
import json
import time
import ssl
import subprocess
import threading
import socketserver
import socket
import select
import base64
import os
from pathlib import Path

class SocksFixture(socketserver.BaseRequestHandler):
    """Minimal SOCKS5 endpoint proving that URLSession uses the proxy."""
    def read_exact(self, count):
        data = b''
        while len(data) < count:
            part = self.request.recv(count - len(data))
            if not part:
                raise ConnectionError('short SOCKS request')
            data += part
        return data

    def handle(self):
        self.request.settimeout(10)
        try:
            version, methods = self.read_exact(2)
            offered = self.read_exact(methods)
            credentials = getattr(self.server, 'expected_credentials', None)
            method = 2 if credentials else 0
            if version != 5 or method not in offered:
                return
            self.request.sendall(bytes((5, method)))
            if credentials:
                version, user_length = self.read_exact(2)
                user = self.read_exact(user_length)
                password_length = self.read_exact(1)[0]
                password = self.read_exact(password_length)
                if version != 1 or (user, password) != credentials:
                    self.request.sendall(b'\x01\x01')
                    return
                self.request.sendall(b'\x01\x00')
            version, command, _, address_type = self.read_exact(4)
            if version != 5 or command != 1:
                return
            if address_type == 1:
                self.read_exact(4)
            elif address_type == 3:
                self.read_exact(self.read_exact(1)[0])
            elif address_type == 4:
                self.read_exact(16)
            else:
                return
            self.read_exact(2)
            self.request.sendall(b'\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00')
            request = b''
            while b'\r\n\r\n' not in request and len(request) < 32768:
                request += self.read_exact(1)
            if b'\r\nproxy:' in request.lower():
                body = b'proxy header leaked'
                status = b'400 Bad Request'
            else:
                body = b'socks5-routed'
                status = b'200 OK'
            self.request.sendall(b'HTTP/1.1 ' + status + b'\r\nContent-Type: text/plain\r\nContent-Length: ' + str(len(body)).encode() + b'\r\nConnection: close\r\n\r\n' + body)
        except (OSError, ConnectionError):
            pass

class SocksFixtureServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f'{time.time():.3f} {self.command} {self.path} {fmt % args}', flush=True)

    def do_POST(self):
        self.do_GET()

    def do_CONNECT(self):
        # Tunnel only this synthetic host to the local TLS fixture. Never act
        # as an open network proxy for arbitrary destinations.
        if self.path not in ('readerproxy.invalid:80', 'readerproxy.invalid:443'):
            self.send_error(403)
            return
        expected = getattr(self.server, 'expected_proxy_auth', None)
        if expected and self.headers.get('Proxy-Authorization') != expected:
            self.send_response(407, 'Proxy Authentication Required')
            self.send_header('Proxy-Authenticate', 'Basic realm="fixture"')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        try:
            if self.path.endswith(':80'):
                self.send_response(200, 'Connection Established')
                self.end_headers()
                self.connection.settimeout(10)
                request = b''
                while b'\r\n\r\n' not in request and len(request) < 32768:
                    part = self.connection.recv(4096)
                    if not part: return
                    request += part
                if b'\r\nproxy-authorization:' in request.lower() or b'\r\nproxy:' in request.lower():
                    body, status = b'proxy credentials leaked', b'400 Bad Request'
                else:
                    body, status = b'proxy-routed:readerproxy.invalid', b'200 OK'
                self.connection.sendall(b'HTTP/1.1 ' + status + b'\r\nContent-Type: text/plain\r\nContent-Length: ' + str(len(body)).encode() + b'\r\nConnection: close\r\n\r\n' + body)
                return
            upstream = socket.create_connection(('127.0.0.1', 8766), timeout=5)
            self.send_response(200, 'Connection Established')
            self.end_headers()
            sockets = (self.connection, upstream)
            while True:
                ready, _, _ = select.select(sockets, (), (), 10)
                if not ready:
                    break
                for source in ready:
                    data = source.recv(16384)
                    if not data:
                        return
                    (upstream if source is self.connection else self.connection).sendall(data)
        except OSError:
            pass
        finally:
            if 'upstream' in locals(): upstream.close()

    def do_GET(self):
        parsed = urlsplit(self.path)
        expected = getattr(self.server, 'expected_proxy_auth', None)
        if parsed.scheme and expected and self.headers.get('Proxy-Authorization') != expected:
            self.send_response(407, 'Proxy Authentication Required')
            self.send_header('Proxy-Authenticate', 'Basic realm="fixture"')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        path = parsed.path
        status, mime = 200, 'text/html; charset=utf-8'
        if path == '/health':
            body = 'ready'
        elif path == '/source-proxy-test':
            # An HTTP proxy receives absolute-form targets. This deterministic
            # endpoint never forwards or resolves the fictional destination.
            if urlsplit(self.path).scheme != 'http' or self.headers.get('proxy') is not None:
                status, body = 400, 'missing proxy routing or leaked proxy header'
            else:
                body = 'proxy-routed:' + urlsplit(self.path).hostname
        elif path == '/source-proxy-https-test':
            if self.headers.get('Proxy-Authorization') or self.headers.get('proxy'):
                status, body = 400, 'proxy credentials leaked to destination'
            else:
                body = 'https-proxy-routed'
        elif path == '/source-proxy-cross-scheme':
            self.send_response(302)
            self.send_header('Location', 'https://readerproxy.invalid/source-proxy-https-test')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        elif path == '/packs/audit-config':
            mime = 'application/json; charset=utf-8'
            body = json.dumps({key: int(os.environ.get('SOURCE_AUDIT_' + key.upper(), default))
                               for key, default in [('start', '0'), ('count', '0'), ('concurrency', '24')]})
        elif path == '/packs/user':
            mime = 'application/json; charset=utf-8'
            body = Path('build/source-pack-1325.json').read_text(encoding='utf-8')
        elif path == '/packs/rss203':
            mime = 'application/json; charset=utf-8'
            body = Path('build/rss-pack-203.json').read_text(encoding='utf-8')
        elif path == '/rss/list':
            if self.headers.get('X-Fixture') != 'RSS':
                status, body = 403, 'missing RSS header'
            else:
                body = '<article><a class="title" href="/rss/article">样本文章</a><img data-cover="/rss/cover.jpg"><span class="date">今天</span></article><a class="next" href="/rss/list2">下一页</a>'
        elif path == '/rss/list2':
            body = '<article><a class="title" href="/rss/article">第二页文章</a></article>'
        elif path == '/rss/style-list':
            if self.headers.get('X-Fixture') != 'RSS':
                status, body = 403, 'missing RSS header'
            else:
                body = ''.join(f'<article><a class="title" href="/rss/article">样本文章{i}</a><img data-cover="/rss/cover{i}.jpg"></article>' for i in range(1, 7))
        elif path == '/rss/article':
            body = '<main><div class="content"><p>订阅测试正文</p></div></main>'
        elif path == '/rss/atom':
            mime, body = 'application/atom+xml; charset=utf-8', '<?xml version="1.0"?><feed xmlns:media="http://search.yahoo.com/mrss/"><entry><title>Atom 样本</title><link href="/rss/article"/><media:thumbnail url="/rss/cover.jpg"/><content><![CDATA[<p>内容</p>]]></content></entry></feed>'
        elif path == '/packs/chuangshi':
            mime = 'application/json; charset=utf-8'
            entries = json.loads(Path('build/source-pack-1325.json').read_text(encoding='utf-8'))
            body = json.dumps(next(s for s in entries if s['bookSourceUrl'] == 'https://chuangshi.qq.com/'), ensure_ascii=False)
        elif path == '/slow-search':
            time.sleep(4)
            mime, body = 'application/json; charset=utf-8', '{"data":[]}'
        elif path == '/web-script':
            body = '<html><body><div id="dynamic"></div><script>setTimeout(function(){document.getElementById("dynamic").innerHTML="网页脚本正文";document.cookie="wv=ready; path=/";},100);</script></body></html>'
        elif path == '/bridge-cookie':
            body = self.headers.get('Cookie', '')
        elif path == '/bridge-library':
            body = "function remoteCategory() { return '远程分类'; }"
        elif path == '/bridge-special':
            body = '中文😀"\\\n\r\t\x00end'
        elif path == '/bridge-library-first':
            body = "var libraryOrder='first'; function Map(key){return key+'-value';}"
        elif path == '/bridge-library-second':
            body = "libraryOrder+='-second'; function categories(){return Map('proxy')+'|'+libraryOrder;}"
        elif path == '/comic-multiple-scripts':
            body = '<script>var analytics=true;</script><script>var pages=["https://cdn.imagedeliveries.com/sample/one.webp","https://cdn.imagedeliveries.com/sample/two.jpg"];</script><script>var more=true;</script>'
        elif path == '/bridge-post':
            body = self.rfile.read(int(self.headers.get('Content-Length', 0))).decode()
        elif path == '/bridge-redirect':
            self.send_response(302)
            self.send_header('Location', '/json/search')
            self.end_headers()
            return
        elif path == '/packs/mixed':
            mime = 'application/json; charset=utf-8'
            body = json.dumps({'data': [{'bookSourceName': 'direct', 'bookSourceUrl': 'https://direct.test',
                                        'ruleSearch': {'url': '/must-not-fetch-rule-url'}},
                                       {'name': 'nested', 'url': 'nested'},
                                       {'name': 'failed', 'url': '/denied'}]})
        elif path == '/packs/nested':
            mime = 'application/json; charset=utf-8'
            body = json.dumps([{'name': 'large', 'url': 'large'}, {'name': 'cycle', 'url': 'mixed'}])
        elif path == '/packs/large':
            mime = 'application/json; charset=utf-8'
            entries = [{'bookSourceName': f'linked{i}', 'bookSourceUrl': f'https://linked{i}.test'} for i in range(1500)]
            body = json.dumps(entries + [entries[0]])
        elif path == '/packs/broken':
            mime, body = 'application/json; charset=utf-8', '[{"name":"broken","url":"/denied"}]'
        elif path == '/denied':
            status, body = 403, 'login required'
        elif path == '/empty':
            body = ''
        elif path == '/navigation':
            body = '<a href="/home">网站首页</a><a href="/login">用户登录</a>'
        elif path == '/redirect':
            self.send_response(302)
            self.send_header('Location', '/library/categories/fiction')
            self.end_headers()
            return
        elif path == '/discovery/pages':
            page = int(parse_qs(urlsplit(self.path).query).get('page', ['1'])[0])
            if page <= 2:
                body = f'<ul class="books"><li><a class="name" href="/book/{page}/">发现第{page}页小说</a><em>测试作者</em></li></ul>'
            else:
                body = '<ul class="books"></ul>'
        elif path == '/library/categories/fiction' or path == '/search':
            if self.headers.get('X-Fixture') != 'ReaderPro':
                status, body = 403, 'missing source header'
            elif path == '/search' and (self.command != 'POST' or self.rfile.read(int(self.headers.get('Content-Length', 0))).decode() != 'key=%E6%B5%8B%E8%AF%95&n=1'):
                status, body = 400, 'wrong POST body or method'
            else:
                body = '<main><ul class="books"><li><div><a class="name" href="/book/1/">测试小说</a><em>测试作者</em></div></li></ul></main>'
                if path.startswith('/library'):
                    body = body.replace('/book/1/', '../../book/1/')
        elif path == '/library/categories/alternate':
            if self.headers.get('X-Fixture') != 'ReaderPro':
                status, body = 403, 'missing source header'
            else:
                body = '<main><ul class="books"><li><div><a class="name" href="/book/1/">另一本小说</a><em>测试作者</em></div></li></ul></main>'
        elif path == '/book/1/':
            body = '<h1>测试小说</h1><div id="intro">用于回归测试的原创样本文字</div><a class="toc" href="toc/1">查看目录</a>'
        elif path.startswith('/book/1/toc/'):
            page = int(path.rsplit('/', 1)[1])
            # Six pages proves the old four-page truncation has been removed.
            # A back-edge and repeated chapter prove cycle and dedup handling.
            nxt = str(page + 1 if page < 6 else 1)
            body = f'<section id="chapters"><p><a href="../chapter/{page}">第{page}章</a></p><p><a href="../chapter/1">第1章</a></p></section><a class="next" href="{nxt}">下一页</a>'
            body += '<select>' + ''.join(f'<option value="{i}">{i}</option>' for i in range(1, 7)) + '</select>'
        elif path == '/reader-boundary/long':
            body = '<article id="content">' + ('第一章分页内容。' * 1200) + '第一章末尾标记</article>'
        elif path.startswith('/book/1/chapter/'):
            chapter = int(path.rsplit('/', 1)[1])
            page = int(parse_qs(urlsplit(self.path).query).get('page', ['1'])[0])
            body = f'<article id="content"><p>第{chapter}章第{page}段。这是完整正文。</p></article>'
            if page < 7:
                body += f'<a class="next" href="{chapter}?page={page + 1}">下一页</a>'
            else:
                body += f'<a class="next-chapter" href="{chapter + 1}">下一章</a>'
        elif path == '/json/noresults':
            mime, body = 'application/json; charset=utf-8', '{"data":[]}'
        elif path == '/json/search':
            mime = 'application/json; charset=utf-8'
            body = json.dumps({'data': [{'name': 'JSON测试', 'url': '/json/book'}]}, ensure_ascii=False)
        elif path == '/json/many-books':
            mime = 'application/json; charset=utf-8'
            # Include a duplicate title to verify both deduplication and
            # preservation of alternative sources in a large response.
            batch = parse_qs(urlsplit(self.path).query).get('batch', [''])[0]
            prefix = f'{batch}-' if batch else ''
            entries = [{'name': f'批量书籍{prefix}{i}', 'url': f'/json/book/{i}'} for i in range(400)]
            entries.append({'name': f'批量书籍{prefix}0', 'url': '/json/book/duplicate'})
            body = json.dumps({'data': entries}, ensure_ascii=False)
        elif path == '/json/book' or path.startswith('/json/book/'):
            mime = 'application/json; charset=utf-8'
            body = json.dumps({'name': 'JSON测试', 'toc': '/json/toc'}, ensure_ascii=False)
        elif path == '/json/toc':
            mime = 'application/json; charset=utf-8'
            body = json.dumps({'chapters': [{'name': 'JSON首章', 'url': '/json/chapter'}]}, ensure_ascii=False)
        elif path == '/json/chapter':
            mime, body = 'application/json; charset=utf-8', '{"text":"JSON首章正文"}'
        else:
            status, body = 404, path
        self.send_response(status)
        self.send_header('Content-Type', mime)
        if path == '/bridge-special':
            self.send_header('X-Bridge-Fixture', 'quote"backslash\\end')
        data = body.encode('utf-8')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

if __name__ == '__main__':
    # An isolated, deliberately untrusted certificate proves that legacy TLS
    # compatibility is opt-in per source and never weakens normal requests.
    Path('build').mkdir(exist_ok=True)
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                    '-keyout', 'build/fixture-key.pem', '-out', 'build/fixture-cert.pem',
                    '-days', '1', '-subj', '/CN=localhost'], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    tls = ThreadingHTTPServer(('0.0.0.0', 8766), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain('build/fixture-cert.pem', 'build/fixture-key.pem')
    tls.socket = context.wrap_socket(tls.socket, server_side=True)
    threading.Thread(target=tls.serve_forever, daemon=True).start()
    socks = SocksFixtureServer(('0.0.0.0', 8767), SocksFixture)
    threading.Thread(target=socks.serve_forever, daemon=True).start()
    socks_auth = SocksFixtureServer(('0.0.0.0', 8769), SocksFixture)
    socks_auth.expected_credentials = (b'fixture-user', b'fixture-pass')
    threading.Thread(target=socks_auth.serve_forever, daemon=True).start()
    auth_proxy = ThreadingHTTPServer(('0.0.0.0', 8768), Handler)
    auth_proxy.expected_proxy_auth = 'Basic ' + base64.b64encode(b'fixture-user:fixture-pass').decode('ascii')
    threading.Thread(target=auth_proxy.serve_forever, daemon=True).start()
    ThreadingHTTPServer(('0.0.0.0', 8765), Handler).serve_forever()
