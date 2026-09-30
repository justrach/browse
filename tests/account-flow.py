#!/usr/bin/env python3
"""Exercise device web approval and agent recovery with an offline gateway."""
import http.server
import json
import os
from pathlib import Path
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


def run_checks():
    world = "account-flow-" + uuid.uuid4().hex[:8]
    suite = "com.codegraff.search.test." + world
    profile = Path.home() / "Library/Application Support" / f"browse ({world})"
    sock = profile / "bench.sock"
    login = profile / "codegraff-login.json"
    state = {"status": "pending", "starts": 0, "revoked": False}

    class Gateway(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            data = b"<html><title>Approve this test Mac</title><p>TEST-CODE</p></html>"
            self.send_response(200)
            self.end_headers()
            self.wfile.write(data)

        def do_POST(self):
            self.rfile.read(int(self.headers.get("Content-Length", 0)))
            if self.path == "/v1/device/start":
                state["starts"] += 1
                reply = {"device_code": f"test-{state['starts']}", "user_code": "TEST-CODE",
                         "verification_uri_complete": f"http://127.0.0.1:{server.server_port}/approve",
                         "interval": 1, "expires_in": 60}
            elif self.path == "/v1/device/poll":
                reply = {"status": state["status"]}
                if state["status"] == "ok":
                    reply.update(api_key="cg_sk_offline_test_only", email="test@example.invalid")
            elif self.path == "/v1/keys/revoke":
                state["revoked"] = True
                reply = {}
            else:
                reply = {}
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(reply).encode())

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Gateway)
    threading.Thread(target=server.serve_forever, daemon=True).start()

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

    def until(predicate):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            try:
                if predicate():
                    return
            except (FileNotFoundError, ConnectionRefusedError):
                pass
            time.sleep(0.1)
        raise AssertionError("Timed out waiting for device sign-in")

    with tempfile.TemporaryDirectory(prefix="browse-account-") as scratch:
        scratch = Path(scratch)
        program = scratch / "graff"
        program.write_text(f"#!{sys.executable}\n" + (ROOT / "tests/agent-recovery.py").read_text())
        program.chmod(0o700)
        log = scratch / "acp.jsonl"
        for key, kind, value in [("bench", "-bool", "true"), ("welcomed", "-bool", "true"),
                                 ("agent.path", "-string", str(program))]:
            subprocess.run(["defaults", "write", suite, key, kind, value], check=True)
        try:
            subprocess.run(["open", "-g", "-j", "-n", "--env", f"SEARCH_PROBE={world}",
                            "--env", f"SEARCH_LOGIN_URL=http://127.0.0.1:{server.server_port}",
                            "--env", f"BROWSE_AGENT_REQUIRE_LOGIN={login}",
                            "--env", f"BROWSE_AGENT_TEST_LOG={log}", str(APP)], check=True)
            until(lambda: sock.exists())
            ask("ui", agent=True)
            until(lambda: ask("probe")["agent"]["phase"] == "Signed out")
            ask("agent-context", draft="Keep this question through setup")

            # Repeated sign-in cancels the old attempt; its completion must
            # leave the latest code visible, and cancellation must stay put.
            ask("ui", signin=True)
            until(lambda: ask("probe")["account"]["phase"] == "waiting")
            ask("ui", signin=True)
            until(lambda: state["starts"] == 2)
            time.sleep(1.2)
            assert ask("probe")["account"]["phase"] == "waiting"
            ask("ui", signincancel=True)
            time.sleep(1.2)
            assert ask("probe")["account"]["phase"] == "signed out"
            assert not login.exists()
            print("PASS Retrying and cancelling device approval preserve the latest attempt and save no key")

            for status in ("denied", "expired"):
                state["status"] = status
                ask("ui", signin=True)
                until(lambda: ask("probe")["account"]["phase"].startswith("failed:"))
                assert not login.exists()
            print("PASS Denied and expired codes report failure without signing in")

            state["status"] = "pending"
            ask("ui", signin=True)
            until(lambda: ask("probe")["account"]["phase"] == "waiting")
            tabs = ask("tabs")["tabs"]
            assert any("/approve" in t.get("url", "") for t in tabs), tabs
            state["status"] = "ok"
            until(lambda: ask("probe")["account"]["phase"] == "signed in")
            until(lambda: ask("probe")["agent"]["phase"] == "")
            assert login.stat().st_mode & 0o777 == 0o600
            assert ask("probe")["agent"]["draft"] == "Keep this question through setup"
            assert len([r for r in map(json.loads, log.read_text().splitlines()) if r.get("method") == "session/new"]) >= 2
            ask("agent-context", action="send")
            until(lambda: ask("probe")["agent"]["taskState"] == "Finished")
            print("PASS Approval saves only the isolated profile key, restarts the signed-out agent and permits the preserved draft to send")

            ask("ui", agentfull=True, signout=True)
            until(lambda: state["revoked"] and ask("probe")["account"]["phase"] == "signed out")
            agent = ask("probe")["agent"]
            assert not login.exists() and not agent["enabled"] and not agent["connected"] and not agent["shown"] and not agent["full"], agent
            assert ask("probe")["sync"]["phase"] == "off"
            print("PASS Signing out revokes the test key and stops both chat modes and sync")
        finally:
            found = subprocess.run(["lsof", "-t", str(sock)], capture_output=True, text=True)
            for pid in set(found.stdout.split()):
                executable = subprocess.check_output(["ps", "-p", pid, "-ww", "-o", "comm="], text=True).strip()
                if executable == str(APP / "Contents/MacOS/Browse"):
                    os.kill(int(pid), signal.SIGTERM)
            subprocess.run(["defaults", "delete", suite], capture_output=True)
            server.shutdown()


if __name__ == "__main__":
    run_checks()
