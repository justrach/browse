#!/usr/bin/env python3
"""Exercise passkeys end to end in a hidden test world.

Build first (`./build.sh`), then `python3 tests/passkeys-live.py`.
Checks:
1. GitHub's webauthn-json pattern: credential methods (like toJSON) are writable (#407).
2. Same-site cross-origin iframe gets a passkey with topOrigin/crossOrigin (#679).
3. Cross-site iframe is refused before reaching macOS (#679).
4. Conditional passkeys appear under a webauthn sign-in field and resolve when picked (#17).
"""
import http.server
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "build/browse.app"

FRAME_HTML = """<!doctype html><script>
navigator.credentials.get({ publicKey: { challenge: new Uint8Array(16), rpId: location.hostname, timeout: 5000 } })
  .then(function (c) { parent.postMessage({ from: location.hostname, got: c && c.type }, '*'); },
        function (e) { parent.postMessage({ from: location.hostname, error: e.name + ': ' + e.message }, '*'); });
</script>"""

GITHUB_HTML = """<!doctype html><title>github-tojson</title><script>
window.__out = null;
navigator.credentials.get({ publicKey: { challenge: new Uint8Array(16), rpId: location.hostname, timeout: 5000 } })
  .then(function (c) {
    c.toJSON = function () { return 'overridden'; };
    window.__out = { type: c.type, toJSON: c.toJSON() };
  }, function (e) {
    window.__out = { error: e.name + ': ' + e.message };
  });
</script>"""

CONDITIONAL_HTML = """<!doctype html><title>conditional</title>
<input id="user" type="text" autocomplete="username webauthn" style="width:240px;height:32px">
<script>
window.__cond = null;
window.__avail = null;
PublicKeyCredential.isConditionalMediationAvailable().then(function (v) { window.__avail = v; });
navigator.credentials.get({
  mediation: 'conditional',
  publicKey: { challenge: new Uint8Array(16), rpId: location.hostname, timeout: 5000 }
}).then(function (c) {
  window.__cond = { type: c && c.type, id: c && c.id };
}, function (e) {
  window.__cond = { error: e.name + ': ' + e.message };
});
</script>"""


def run_checks():
    world = "passkeys-live-" + uuid.uuid4().hex[:8]
    suite = "com.codegraff.search.test." + world
    profile = Path.home() / "Library/Application Support" / f"browse ({world})"
    sock = profile / "bench.sock"

    frame_port = [0]

    class Site(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            if self.path.startswith("/top?f="):
                host = self.path.split("=", 1)[1]
                body = (
                    "<!doctype html><title>top</title><script>window.__r = [];"
                    "addEventListener('message', function (e) { window.__r.push(e.data); });</script>"
                    f"<iframe src='http://{host}:{frame_port[0]}/frame'></iframe>"
                )
            elif self.path == "/frame":
                body = FRAME_HTML
            elif self.path == "/github":
                body = GITHUB_HTML
            elif self.path == "/conditional":
                body = CONDITIONAL_HTML
            else:
                body = "<!doctype html><title>blank</title>"
            data = body.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    frame_srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Site)
    frame_port[0] = frame_srv.server_port
    threading.Thread(target=frame_srv.serve_forever, daemon=True).start()

    top_srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Site)
    top_port = top_srv.server_port
    threading.Thread(target=top_srv.serve_forever, daemon=True).start()

    def ask(verb, **params):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(15)
            client.connect(str(sock))
            client.sendall((json.dumps({"do": verb, **params}) + "\n").encode())
            data = b""
            while b"\n" not in data:
                chunk = client.recv(65536)
                if not chunk:
                    break
                data += chunk
        reply = json.loads(data.split(b"\n")[0])
        assert "error" not in reply, reply
        return reply

    def until(predicate, what="condition", timeout=15):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                value = predicate()
                if value:
                    return value
            except (FileNotFoundError, ConnectionRefusedError):
                pass
            time.sleep(0.15)
        raise AssertionError(f"Timed out waiting for {what}")

    for key, kind, value in [
        ("bench", "-bool", "true"),
        ("welcomed", "-bool", "true"),
        ("passkeys", "-bool", "true"),
    ]:
        subprocess.run(["defaults", "write", suite, key, kind, value], check=True)

    try:
        subprocess.run(
            ["open", "-g", "-j", "-n", "--env", f"SEARCH_PROBE={world}", str(APP)],
            check=True,
        )
        until(lambda: sock.exists(), "bench socket")

        # 1. GitHub webauthn-json writable toJSON (#407)
        tid = ask("open", url=f"http://localhost:{top_port}/github")["id"]
        ask("wait", id=tid, seconds=10)
        out = until(lambda: ask("eval", id=tid, js="JSON.stringify(window.__out)").get("value") not in (None, "null")
                    and json.loads(ask("eval", id=tid, js="JSON.stringify(window.__out)")["value"]), "github result")
        assert out == {"type": "public-key", "toJSON": "overridden"}, out
        ask("close", id=tid)
        print("PASS GitHub webauthn-json writable credential methods (#407)")

        # 2. Same-site cross-origin iframe (#679)
        before = ask("probe").get("passkeyAsks", 0)
        tid = ask("open", url=f"http://localhost:{top_port}/top?f=localhost")["id"]
        ask("wait", id=tid, seconds=10)
        got = until(lambda: (
            (v := ask("eval", id=tid, js="JSON.stringify(window.__r || [])").get("value"))
            and v != "[]" and json.loads(v)
        ), "same-site iframe result")
        probe = ask("probe")
        last = probe.get("passkeyLast") or {}
        assert got[0].get("got") == "public-key", got
        assert last.get("crossOrigin") is True and last.get("topOrigin") == f"http://localhost:{top_port}", last
        assert probe.get("passkeyAsks", 0) == before + 1, probe
        ask("close", id=tid)
        print("PASS Same-site cross-origin iframe allowed with topOrigin/crossOrigin (#679)")

        # 3. Cross-site iframe refused (#679)
        tid = ask("open", url=f"http://localhost:{top_port}/top?f=other.localhost")["id"]
        ask("wait", id=tid, seconds=10)
        got = until(lambda: (
            (v := ask("eval", id=tid, js="JSON.stringify(window.__r || [])").get("value"))
            and v != "[]" and json.loads(v)
        ), "cross-site iframe result")
        assert "NotAllowedError" in got[0].get("error", ""), got
        assert ask("probe").get("passkeyAsks", 0) == before + 1
        ask("close", id=tid)
        print("PASS Cross-site iframe refused before reaching macOS (#679)")

        # 4. Conditional passkeys under the sign-in field (#17)
        tid = ask("open", url=f"http://localhost:{top_port}/conditional")["id"]
        ask("select", id=tid)
        ask("wait", id=tid, seconds=10)
        avail = until(lambda: ask("eval", id=tid, js="String(window.__avail)").get("value") == "true", "conditional availability")
        assert avail
        ask("eval", id=tid, js="document.getElementById('user').focus()")
        accounts = until(lambda: (
            (a := ask("accounts")) and a.get("shown") and a
        ), "accounts list under field")
        assert accounts["rows"] == [{"passkey": "probe@localhost"}], accounts
        # Wait past the 0.5 s anti-clickjacking window before picking row 0.
        time.sleep(0.65)
        ask("accounts", pick=0)
        cond = until(lambda: (
            (v := ask("eval", id=tid, js="JSON.stringify(window.__cond)").get("value"))
            and v != "null" and json.loads(v)
        ), "conditional credential resolved")
        assert cond.get("type") == "public-key" and cond.get("id"), cond
        assert ask("probe").get("passkeyLast", {}).get("conditional") is True
        ask("close", id=tid)
        print("PASS Conditional passkeys offered under sign-in field and resolved on pick (#17)")
    finally:
        found = subprocess.run(["lsof", "-t", str(sock)], capture_output=True, text=True)
        for pid in set(found.stdout.split()):
            executable = subprocess.check_output(["ps", "-p", pid, "-ww", "-o", "comm="], text=True).strip()
            if executable == str(APP / "Contents/MacOS/Browse"):
                os.kill(int(pid), signal.SIGTERM)
        time.sleep(0.3)
        subprocess.run(["defaults", "delete", suite], capture_output=True)
        shutil.rmtree(profile, ignore_errors=True)
        frame_srv.shutdown()
        top_srv.shutdown()


if __name__ == "__main__":
    run_checks()
