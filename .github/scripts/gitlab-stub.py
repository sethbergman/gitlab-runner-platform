"""The two calls of GitLab's runner API a runner manager makes while idle,
over HTTPS, for .github/scripts/terraform-e2e.sh.

POST /api/v4/runners/verify accepts any token, as GitLab does a valid one,
so the runner starts and its liveness check passes. POST /api/v4/jobs/request
answers 204, no job pending. Every other request also gets 204. Each request
is logged with the token it carried, which shows which runner made it.

Usage: python3 gitlab-stub.py CERT KEY
"""

import http.server
import json
import ssl
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            return json.loads(raw or b"{}")
        except ValueError:
            return {}

    def _reply(self, status, payload=None):
        out = json.dumps(payload).encode() if payload is not None else b""
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def do_POST(self):
        body = self._body()
        token = body.get("token", "")
        print(f"{self.command} {self.path} token={token}", flush=True)
        if self.path == "/api/v4/runners/verify":
            self._reply(200, {"id": 1, "token": token, "token_expires_at": None})
        else:
            self._reply(204)

    def do_DELETE(self):
        print(f"{self.command} {self.path} token={self._body().get('token', '')}", flush=True)
        self._reply(204)

    def do_GET(self):
        print(f"{self.command} {self.path}", flush=True)
        self._reply(204)

    def log_message(self, fmt, *args):
        pass


def main():
    cert, key = sys.argv[1], sys.argv[2]
    server = http.server.ThreadingHTTPServer(("", 443), Handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    server.socket = ctx.wrap_socket(server.socket, server_side=True)
    print("serving on 443", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
