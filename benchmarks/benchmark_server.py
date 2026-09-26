"""Local static page and readiness beacon for browser memory benchmarks."""

import http.server
import time
import urllib.parse


PAGE = b"""<!doctype html><html><head><meta charset=utf-8><title>Local launch probe</title>
<script>document.addEventListener('DOMContentLoaded', () => {
  navigator.sendBeacon('/ready' + location.search, 'ready');
});</script></head><body><h1>Local launch probe</h1></body></html>"""


class Probe(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlsplit(self.path)
        if parsed.path == "/page":
            body = PAGE
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
        elif parsed.path == "/ready":
            trial = urllib.parse.parse_qs(parsed.query).get("trial", [""])[0]
            with self.server.condition:
                self.server.ready[trial] = time.monotonic_ns()
                self.server.condition.notify_all()
            body = b"ok"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
        else:
            body = b"not found"
            self.send_response(404)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        self.do_GET()

    def log_message(self, *_):
        pass
