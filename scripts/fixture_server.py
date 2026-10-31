"""Deterministic HTTP fixtures used by the iOS engine and UI tests.

No third-party sites, copyrighted books or user data. The host app really uses
URLSession, so an ATS regression fails instead of passing via URLProtocol.
"""
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlsplit, parse_qs
import json

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def do_POST(self):
        self.do_GET()

    def do_GET(self):
        path = urlsplit(self.path).path
        status, mime = 200, 'text/html; charset=utf-8'
        if path == '/health':
            body = 'ready'
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
        elif path == '/library/categories/fiction' or path == '/search':
            if self.headers.get('X-Fixture') != 'ReaderPro':
                status, body = 403, 'missing source header'
            elif path == '/search' and (self.command != 'POST' or self.rfile.read(int(self.headers.get('Content-Length', 0))).decode() != 'key=%E6%B5%8B%E8%AF%95&n=1'):
                status, body = 400, 'wrong POST body or method'
            else:
                body = '<main><ul class="books"><li><div><a class="name" href="/book/1/">测试小说</a><em>测试作者</em></div></li></ul></main>'
                if path.startswith('/library'):
                    body = body.replace('/book/1/', '../../book/1/')
        elif path == '/book/1/':
            body = '<h1>测试小说</h1><div id="intro">用于回归测试的原创样本文字</div><a class="toc" href="toc/1">查看目录</a>'
        elif path.startswith('/book/1/toc/'):
            page = int(path.rsplit('/', 1)[1])
            # Six pages proves the old four-page truncation has been removed.
            # A back-edge and repeated chapter prove cycle and dedup handling.
            nxt = str(page + 1 if page < 6 else 1)
            body = f'<section id="chapters"><p><a href="../chapter/{page}">第{page}章</a></p><p><a href="../chapter/1">第1章</a></p></section><a class="next" href="{nxt}">下一页</a>'
        elif path.startswith('/book/1/chapter/'):
            chapter = int(path.rsplit('/', 1)[1])
            page = int(parse_qs(urlsplit(self.path).query).get('page', ['1'])[0])
            body = f'<article id="content"><p>第{chapter}章第{page}段。这是完整正文。</p></article>'
            if page < 7:
                body += f'<a class="next" href="{chapter}?page={page + 1}">下一页</a>'
        elif path == '/json/noresults':
            mime, body = 'application/json; charset=utf-8', '{"data":[]}'
        elif path == '/json/search':
            mime = 'application/json; charset=utf-8'
            body = json.dumps({'data': [{'name': 'JSON测试', 'url': '/json/book'}]}, ensure_ascii=False)
        elif path == '/json/book':
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
        data = body.encode('utf-8')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

if __name__ == '__main__':
    ThreadingHTTPServer(('0.0.0.0', 8765), Handler).serve_forever()
