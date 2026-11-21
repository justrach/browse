#!/usr/bin/env python3
"""End-to-end test of browse-mcp (modelcontextprotocol/swift-sdk) talking to browse.app.

Build first (`./build.sh`), then `python3 tests/mcp-live.py`.
Launches browse.app in a hidden test world, spawns browse-mcp over stdio,
auto-pairs via bench, calls initialize, tools/list, open, snapshot, scroll,
press_key, hover, wait_for, and screenshot (inline image + save_to PNG).
"""
import base64
import http.server
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "build/browse.app"
MCP_BIN = APP / "Contents/MacOS/browse-mcp"

HTML = """<!doctype html>
<html><head><title>MCP Test Page</title><style>
body { font-family: -apple-system; margin: 20px; height: 2400px; }
#box { width: 220px; height: 80px; background: #2563eb; color: white; padding: 12px; }
#tip { display: none; }
#box:hover + #tip { display: block; }
</style></head>
<body>
<h1>MCP Playground</h1>
<input id="q" type="text" placeholder="Search items" />
<input id="pw" type="password" value="supersecret123" />
<button id="btn" onclick="document.getElementById('status').textContent = 'Clicked ' + document.getElementById('q').value">Run Action</button>
<div id="status">Idle</div>
<div id="box" onmouseenter="document.getElementById('hoverState').textContent='Hovered'">Hover Card</div>
<div id="tip">Tooltip</div>
<div id="hoverState">None</div>
<div id="keyState">NoKey</div>
<script>
document.getElementById('q').addEventListener('keydown', function (e) {
  document.getElementById('keyState').textContent = 'Key:' + e.key;
});
</script>
</body></html>"""


def run_checks():
    assert MCP_BIN.exists(), f"Missing {MCP_BIN} — run ./build.sh first"
    world = "mcp-live-" + uuid.uuid4().hex[:8]
    suite = "com.codegraff.search.test." + world
    profile = Path.home() / "Library/Application Support" / f"browse ({world})"
    sock = profile / "bench.sock"
    connect_json = profile / "Agent/connect.json"

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            data = HTML.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{srv.server_port}/"

    def bench_ask(verb, **params):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as c:
            c.settimeout(15)
            c.connect(str(sock))
            c.sendall((json.dumps({"do": verb, **params}) + "\n").encode())
            data = b""
            while b"\n" not in data:
                chunk = c.recv(65536)
                if not chunk:
                    break
                data += chunk
        return json.loads(data.split(b"\n")[0])

    def until(pred, what, timeout=20):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            try:
                v = pred()
                if v:
                    return v
            except Exception:
                pass
            time.sleep(0.15)
        raise AssertionError(f"Timed out waiting for {what}")

    for k, kind, val in [
        ("bench", "-bool", "true"),
        ("welcomed", "-bool", "true"),
        ("connect.on", "-bool", "true"),
    ]:
        subprocess.run(["defaults", "write", suite, k, kind, val], check=True)

    mcp_proc = None
    try:
        subprocess.run(["open", "-g", "-j", "-n", "--env", f"SEARCH_PROBE={world}", str(APP)], check=True)
        until(lambda: sock.exists() and connect_json.exists(), "browse socket + connect.json")

        # Launch browse-mcp over stdio.
        mcp_proc = subprocess.Popen(
            [str(MCP_BIN), "--world", world, "--name", "TestAgent"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )

        # Auto-accept the pairing sheet in browse in a background thread.
        stop_accept = threading.Event()
        def auto_accept():
            while not stop_accept.is_set():
                try:
                    bench_ask("ui", connect="yes")
                except Exception:
                    pass
                time.sleep(0.3)
        threading.Thread(target=auto_accept, daemon=True).start()

        req_id = [0]
        def rpc(method, params=None):
            req_id[0] += 1
            msg = {"jsonrpc": "2.0", "id": req_id[0], "method": method}
            if params is not None:
                msg["params"] = params
            mcp_proc.stdin.write(json.dumps(msg) + "\n")
            mcp_proc.stdin.flush()
            line = mcp_proc.stdout.readline()
            assert line, f"EOF from browse-mcp; stderr:\n{mcp_proc.stderr.read()}"
            resp = json.loads(line)
            assert "error" not in resp, resp
            return resp["result"]

        # 1. MCP initialize
        init = rpc("initialize", {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "mcp-live-test", "version": "1.0"},
        })
        assert init["serverInfo"]["name"] == "browse", init
        mcp_proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
        mcp_proc.stdin.flush()
        print("PASS MCP initialize via swift-sdk StdioTransport")

        # 2. tools/list (triggers automatic P-256 pairing!)
        listed = rpc("tools/list", {})
        names = {t["name"] for t in listed["tools"]}
        if not names:
            mcp_proc.stdin.close()
            raise AssertionError(f"Empty tools list; browse-mcp stderr:\n{mcp_proc.stderr.read()}")
        for expected in ("open", "snapshot", "scroll", "press_key", "hover", "wait_for", "screenshot", "click", "type"):
            assert expected in names, f"Missing tool {expected} in {names}"
        stop_accept.set()
        print(f"PASS Auto-paired & listed {len(names)} MCP tools")

        # 3. open + snapshot (verifying secret redaction!)
        opened = rpc("tools/call", {"name": "open", "arguments": {"url": url}})
        assert not opened.get("isError"), opened
        snap = rpc("tools/call", {"name": "snapshot", "arguments": {}})
        snap_text = snap["content"][0]["text"]
        assert "[button]" in snap_text and "Run Action" in snap_text, snap_text
        assert "[secret]" in snap_text and "supersecret123" not in snap_text, snap_text
        print("PASS snapshot lists interactive elements & redacts password values")

        # 4. type + press_key + click + wait_for + hover + scroll
        rpc("tools/call", {"name": "type", "arguments": {"selector": "#q", "text": "hello"}})
        rpc("tools/call", {"name": "press_key", "arguments": {"selector": "#q", "key": "Enter"}})
        rpc("tools/call", {"name": "click", "arguments": {"selector": "#btn"}})
        waited = rpc("tools/call", {"name": "wait_for", "arguments": {"selector": "#status", "text": "Clicked hello", "timeout": 5}})
        assert not waited.get("isError"), waited
        rpc("tools/call", {"name": "hover", "arguments": {"selector": "#box"}})
        waited_hover = rpc("tools/call", {"name": "wait_for", "arguments": {"selector": "#hoverState", "text": "Hovered", "timeout": 5}})
        assert not waited_hover.get("isError"), waited_hover
        scrolled = rpc("tools/call", {"name": "scroll", "arguments": {"direction": "down", "amount": 500}})
        scroll_data = json.loads(scrolled["content"][0]["text"])
        assert scroll_data.get("scrollY", 0) >= 400, scroll_data
        print("PASS type, press_key, click, hover, wait_for, and scroll work end to end")

        # 5. screenshot (element crop + save_to PNG + inline MCP image)
        with tempfile.TemporaryDirectory() as tmp:
            shot_path = os.path.join(tmp, "box.png")
            shot = rpc("tools/call", {"name": "screenshot", "arguments": {"selector": "#box", "save_to": shot_path}})
            assert not shot.get("isError"), shot
            img_blocks = [c for c in shot["content"] if c.get("type") == "image"]
            assert img_blocks and len(base64.b64decode(img_blocks[0]["data"])) > 100, shot
            assert os.path.exists(shot_path) and os.path.getsize(shot_path) > 100
        print("PASS screenshot returns inline MCP image block and saves PNG to disk")
    finally:
        if mcp_proc and mcp_proc.poll() is None:
            mcp_proc.stdin.close()
            try:
                mcp_proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                mcp_proc.terminate()
        found = subprocess.run(["lsof", "-t", str(sock)], capture_output=True, text=True)
        for pid in set(found.stdout.split()):
            executable = subprocess.check_output(["ps", "-p", pid, "-ww", "-o", "comm="], text=True).strip()
            if executable == str(APP / "Contents/MacOS/Browse"):
                os.kill(int(pid), signal.SIGTERM)
        time.sleep(0.3)
        subprocess.run(["defaults", "delete", suite], capture_output=True)
        shutil.rmtree(profile, ignore_errors=True)
        srv.shutdown()


if __name__ == "__main__":
    run_checks()
