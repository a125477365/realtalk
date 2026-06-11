"""管理台本地开发服务器：模拟生产 nginx —— 同源下提供静态文件 + API 反向代理。

用法：
    REALTALK_API=http://127.0.0.1:8000 python3 scripts/admin_dev_proxy.py
然后浏览器访问 http://127.0.0.1:8080 （Cookie 同源，与生产行为一致）。
"""
import http.server
import os
import urllib.error
import urllib.request

STATIC_DIR = os.environ.get(
    "REALTALK_ADMIN_STATIC",
    os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "admin-frontend", "public"),
)
BACKEND = os.environ.get("REALTALK_API", "http://127.0.0.1:8000")
PORT = int(os.environ.get("PORT", "8080"))
API_PREFIXES = ("/api/", "/admin", "/payment/", "/auth/", "/health", "/ready",
                "/billing/", "/transcript/", "/learning/", "/scenario/",
                "/roleplay/", "/practice/", "/training/", "/apple/")


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=STATIC_DIR, **kwargs)

    def _proxy(self):
        url = BACKEND + self.path
        body = None
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            body = self.rfile.read(length)
        req = urllib.request.Request(url, data=body, method=self.command)
        for key in ("Content-Type", "Authorization", "Cookie", "Accept"):
            if self.headers.get(key):
                req.add_header(key, self.headers[key])
        try:
            with urllib.request.urlopen(req) as resp:
                self._relay(resp.status, resp.headers, resp.read())
        except urllib.error.HTTPError as e:
            self._relay(e.code, e.headers, e.read())

    def _relay(self, status, headers, data):
        self.send_response(status)
        for key, value in headers.items():
            if key.lower() in ("set-cookie", "content-type"):
                self.send_header(key, value)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if any(self.path.startswith(p) for p in API_PREFIXES):
            self._proxy()
        else:
            super().do_GET()

    def do_POST(self):
        self._proxy()

    def do_PATCH(self):
        self._proxy()

    def do_DELETE(self):
        self._proxy()

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    print(f"admin dev server: http://127.0.0.1:{PORT}  →  {BACKEND}")
    http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
