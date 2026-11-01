"""Serve the inputs needed by the live source audit without UI/proxy fixtures."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import os


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            content_type, body = "text/plain", b"ready"
        elif self.path == "/packs/user":
            content_type = "application/json; charset=utf-8"
            body = Path("build/source-pack-1325.json").read_bytes()
        elif self.path == "/packs/audit-config":
            content_type = "application/json; charset=utf-8"
            config = {key: int(os.environ.get("SOURCE_AUDIT_" + key.upper(), default))
                      for key, default in (("start", "0"), ("count", "0"), ("concurrency", "24"))}
            body = json.dumps(config).encode("utf-8")
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 8765), Handler).serve_forever()
