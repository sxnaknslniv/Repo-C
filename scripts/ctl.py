#!/usr/bin/env python3
# tiny control server on the Tailscale IP only: GET /ready, GET /role, POST /sync
import http.server, os, subprocess, sys

BIND, SCRIPTS = sys.argv[1], sys.argv[2]
RUN = "/run/vps"


class H(http.server.BaseHTTPRequestHandler):

    def _send(self, code, body=""):
        b = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path == "/role":
            p = f"{RUN}/role"
            self._send(200, open(p).read().strip() if os.path.exists(p) else "none")
        elif self.path == "/ready":
            self._send(200 if os.path.exists(f"{RUN}/ready") else 503, "ok")
        else:
            self._send(404)

    def do_POST(self):
        if self.path == "/sync":
            r = subprocess.run(["bash", f"{SCRIPTS}/sync_in.sh"], capture_output=True, text=True)
            self._send(200 if r.returncode == 0 else 500, (r.stdout + r.stderr)[-800:])
        else:
            self._send(404)

    def log_message(self, *a):
        pass


http.server.ThreadingHTTPServer((BIND, 9001), H).serve_forever()
