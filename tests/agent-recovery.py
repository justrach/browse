#!/usr/bin/env python3
"""Exercise browse's ACP recovery against an offline agent, in a fresh test world."""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "build/browse.app"


def mock_agent():
    log = Path(os.environ["BROWSE_AGENT_TEST_LOG"])
    question = None
    for line in sys.stdin:
        request = json.loads(line)
        with log.open("a") as output:
            output.write(json.dumps(request) + "\n")
        method = request.get("method")
        result = {}

        def update(value):
            print(json.dumps({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": "recovery-test", "update": value}}), flush=True)

        if method in ("session/new", "session/load"):
            result = {"sessionId": "recovery-test", "configOptions": [{
                "id": "thought_level", "category": "thought_level", "type": "select",
                "currentValue": "medium", "options": [{"value": "medium", "name": "Medium"}]}]}
        elif method == "graff/models":
            result = {"models": [{"provider": "test", "name": "research", "authenticated": True}],
                      "current": {"provider": "test", "model": "research"}}
        elif method == "session/prompt":
            words = request["params"]["prompt"][-1].get("text", "")
            if words == "QUESTION":
                question = request["id"]
                update({"sessionUpdate": "gui_ask_user", "question": "Which source should I use?", "input": {"options": ["First", "Second"]}})
                continue
            if words == "FAILED":
                print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "error": {"code": -32001, "message": "Test connection interrupted"}}), flush=True)
                continue
            if words == "STOPPED":
                print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": {"stopReason": "cancelled"}}), flush=True)
                continue
            if words == "CRASH":
                sys.exit(2)
            if words == "FORGET":
                log.with_suffix(".forget").touch()
            if words == "STALL":
                update({"sessionUpdate": "tool_call", "toolCallId": "waiting-" + uuid.uuid4().hex[:8],
                        "title": "Waiting for researcher", "kind": "other", "status": "in_progress"})
                continue  # Ignore cancellation too: reconnect must replace this process.
            update({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Finished."}})
            result = {"stopReason": "end_turn"}
        elif method == "session/answer" and question is not None:
            print(json.dumps({"jsonrpc": "2.0", "id": question, "result": {"stopReason": "end_turn"}}), flush=True)
            question = None
        if "id" in request:
            reply = {"jsonrpc": "2.0", "id": request["id"], "result": result}
            if method == "session/load" and log.with_suffix(".forget").exists():
                log.with_suffix(".forget").unlink()
                reply = {"jsonrpc": "2.0", "id": request["id"], "error": {
                    "code": -32602, "message": "Session not found"}}
            print(json.dumps(reply), flush=True)


def run_checks():
    assert APP.exists(), "Run ./build.sh debug first"
    world = "agent-recovery-" + uuid.uuid4().hex[:8]
    suite = "com.codegraff.search.test." + world
    profile = Path.home() / "Library/Application Support" / f"browse ({world})"
    socket_path = profile / "bench.sock"
    opened = []
    checks = []

    def ask(verb, **params):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(15)
            client.connect(str(socket_path))
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
        raise AssertionError("Timed out waiting for the test agent")

    with tempfile.TemporaryDirectory(prefix="browse-agent-") as scratch:
        scratch = Path(scratch)
        log = scratch / "acp.jsonl"
        program = scratch / "graff"
        program.write_text(f"#!{sys.executable}\n" + Path(__file__).read_text())
        program.chmod(0o700)
        page = scratch / "page.html"
        page.write_text("<html><title>Focus check</title><input autofocus><p id='passage'>A claim to check against the original evidence.</p><p>Unselected background.</p><input id='password' type='password' value='fake-test-password'></html>")
        subprocess.run(["defaults", "write", suite, "bench", "-bool", "true"], check=True)
        subprocess.run(["defaults", "write", suite, "welcomed", "-bool", "true"], check=True)
        subprocess.run(["defaults", "write", suite, "agent.path", "-string", str(program)], check=True)
        try:
            subprocess.run(["open", "-g", "-j", "-n", "--env", f"SEARCH_PROBE={world}",
                            "--env", f"BROWSE_AGENT_TEST_LOG={log}", str(APP)], check=True)
            until(lambda: socket_path.exists())
            tab = ask("open", url=page.as_uri())["id"]
            opened.append(tab)
            ask("wait", id=tab, seconds=10)
            ask("select", id=tab)
            ask("key", id=tab, text="x")
            assert ask("probe")["keys"] == tab[:8].lower()
            ask("ui", agent=True)
            until(lambda: ask("probe")["agent"]["connected"])
            time.sleep(0.5)
            assert ask("probe")["keys"] == tab[:8].lower(), "Appearance stole page focus"
            ask("acp", ask="Background turn")
            ask("acp", update={"sessionUpdate": "agent_message_chunk",
                                "content": {"type": "text", "text": "A streamed answer"}})
            time.sleep(0.2)
            assert ask("probe")["keys"] == tab[:8].lower(), "Streaming stole page focus"
            ask("acp", done=True)
            checks.append("Agent appearance and streaming preserve page keyboard focus")

            # A printable shortcut must never take punctuation from an editor.
            ask("ui", agent=False)
            ask("press", code=47, chars=".")
            assert not ask("probe")["agent"]["shown"], "Period in a page input opened the agent"
            ask("key", id=tab, text=".")
            assert "." in ask("eval", id=tab, js="document.querySelector('input').value")["value"]
            ask("eval", id=tab, js="document.activeElement.blur()")
            time.sleep(0.2)
            ask("key", id=tab, text="x")
            ask("press", code=47, chars=".")
            state = ask("probe")
            assert state["agent"]["shown"] and not state["agent"]["full"], state
            # Hidden windows defer SwiftUI layout until the bench renders them.
            ask("picture", path=str(scratch / "period-open.png"), page=False)
            ask("ui", agent=False)
            ask("press", code=37, chars="l", mods=["cmd"])
            ask("picture", path=str(scratch / "address-focus.png"), page=False)
            ask("press", code=47, chars=".")
            assert not ask("probe")["agent"]["shown"], "Address-field punctuation opened the agent"
            ask("press", code=53, chars="\x1b")
            checks.append("Period opens the side agent while reading and leaves form/address punctuation alone")

            ask("ui", ask="STALL")
            until(lambda: ask("probe")["agent"]["pendingTools"] == 1)
            ask("ui", ask="QUEUED")
            assert ask("probe")["agent"]["queue"] == 1
            ask("ui", reconnect=True)
            until(lambda: log.exists() and '"session/load"' in log.read_text())
            until(lambda: ask("probe")["agent"]["phase"] == "")
            state = ask("probe")["agent"]
            assert state["pendingTools"] == 0 and state["queue"] == 1, state
            records = [json.loads(line) for line in log.read_text().splitlines()]
            load = next(row for row in records if row.get("method") == "session/load")
            assert load["params"]["sessionId"] == "recovery-test"
            assert sum(row.get("method") == "session/new" for row in records) == 1
            time.sleep(0.3)
            assert sum('"session/prompt"' in line for line in log.read_text().splitlines()) == 1
            checks.append("Reconnect restores the session, settles pending tools and holds the queue")

            ask("ui", ask="CONTINUE")
            until(lambda: ask("probe")["agent"]["queue"] == 0)
            until(lambda: sum('"session/prompt"' in line for line in log.read_text().splitlines()) == 3)
            records = [json.loads(line) for line in log.read_text().splitlines()]
            sent = [row["params"]["prompt"][-1]["text"] for row in records if row.get("method") == "session/prompt"]
            assert sent == ["STALL", "CONTINUE", "QUEUED"], sent
            checks.append("Queued messages resume after an explicit send, in order")

            ask("ui", ask="CRASH")
            until(lambda: ask("probe")["agent"]["phase"] == "Stopped")
            ask("ui", reconnect=True)
            until(lambda: sum('"session/load"' in line for line in log.read_text().splitlines()) == 2)
            until(lambda: ask("probe")["agent"]["phase"] == "")
            checks.append("Recovery after a process exit loads the saved conversation")

            ask("ui", ask="FORGET")
            until(lambda: log.with_suffix(".forget").exists())
            until(lambda: ask("probe")["agent"]["phase"] == "")
            ask("ui", reconnect=True)
            until(lambda: sum('"session/new"' in line for line in log.read_text().splitlines()) == 2)
            until(lambda: ask("probe")["agent"]["phase"] == "")
            ask("ui", ask="AFTER FALLBACK")
            until(lambda: '"AFTER FALLBACK"' in log.read_text())
            records = [json.loads(line) for line in log.read_text().splitlines()]
            fallback = next(row for row in records if row.get("method") == "session/prompt"
                            and row["params"]["prompt"][-1].get("text") == "AFTER FALLBACK")
            assert any("Earlier in this conversation" in block.get("text", "")
                       for block in fallback["params"]["prompt"])
            checks.append("An unavailable saved session carries the transcript into the next prompt")

            ask("ui", ask="/feedback-extra")
            until(lambda: '"/feedback-extra"' in log.read_text())
            assert not ask("probe")["agent"]["feedback"]
            checks.append("Other slash-command names remain agent prompts")

            until(lambda: ask("probe")["agent"]["phase"] == "")
            ask("ui", ask="STALL")
            until(lambda: ask("probe")["agent"]["pendingTools"] == 1)
            ask("ui", ask="/feedback The agent stopped responding")
            until(lambda: ask("probe")["agent"]["feedback"])
            state = ask("probe")["agent"]
            assert state["phase"] == "Working…" and state["queue"] == 0
            assert sum('"session/prompt"' in line for line in log.read_text().splitlines()) == 8
            checks.append("/feedback opens a local review during a stuck run without queuing or prompting")

            # The actual selection reader and draft route, with no prompt sent on capture.
            ask("ui", agentfeedback=False, chat="none")
            until(lambda: ask("probe")["agent"]["phase"] == "")
            ask("select", id=tab)
            select_passage = "document.activeElement.blur();var r=document.createRange();r.selectNodeContents(document.querySelector('#passage'));getSelection().removeAllRanges();getSelection().addRange(r);"
            ask("eval", id=tab, js=select_passage)
            assert not ask("agent-context", action="selection")["attached"], "Selection action should start off"
            ask("agent-context", enabled=True, draft="Keep my existing question", withPage=False)
            before = log.read_text().count('"session/prompt"')
            ask("agent-context", action="selection")
            state = ask("probe")["agent"]
            assert state["draft"] == "Keep my existing question", state
            assert state["passage"]["text"] == "A claim to check against the original evidence.", state
            assert log.read_text().count('"session/prompt"') == before, "Capturing a selection sent a prompt"
            original = state["passage"].copy()
            other = scratch / "other.html"
            other.write_text("<html><title>Different source</title><p>Unrelated text on another page.</p></html>")
            other_tab = ask("open", url=other.as_uri())["id"]
            opened.append(other_tab)
            ask("wait", id=other_tab, seconds=10)
            ask("select", id=other_tab)
            ask("agent-context", draft="SELECTED QUESTION")
            ask("agent-context", action="send")
            until(lambda: ask("probe")["agent"]["taskState"] == "Finished")
            records = [json.loads(line) for line in log.read_text().splitlines()]
            prompt = next(row["params"]["prompt"] for row in records if row.get("method") == "session/prompt" and row["params"]["prompt"][-1].get("text") == "SELECTED QUESTION")
            resources = [block["resource"] for block in prompt if block["type"] == "resource"]
            assert len(resources) == 1 and resources[0]["uri"] == original["url"] and resources[0]["text"] == original["text"], resources
            assert not ask("probe")["agent"]["passage"]
            checks.append("Selection is optional, preserves the draft, waits for Send and keeps its source across tab switches")

            ask("select", id=tab)
            ask("eval", id=tab, js="getSelection().removeAllRanges();var p=document.querySelector('#password');p.focus();p.select();")
            assert not ask("agent-context", action="selection")["attached"], "Password selection became an attachment"
            checks.append("Password selections never become agent attachments")

            ask("ui", ask="STALL")
            until(lambda: ask("probe")["agent"]["pendingTools"] == 1)
            assert ask("probe")["agent"]["taskState"] == "Working"
            ask("eval", id=tab, js=select_passage)
            ask("agent-context", action="selection")
            ask("agent-context", draft="QUEUED PASSAGE")
            ask("agent-context", action="send")
            assert ask("probe")["agent"]["queue"] == 1
            ask("eval", id=tab, js="document.querySelector('#passage').textContent='Changed after queuing';")
            ask("ui", reconnect=True)
            until(lambda: ask("probe")["agent"]["phase"] == "")
            assert ask("probe")["agent"]["taskState"] == "Ready to continue"
            ask("ui", ask="CONTINUE QUEUE")
            until(lambda: '"QUEUED PASSAGE"' in log.read_text())
            until(lambda: ask("probe")["agent"]["taskState"] == "Finished")
            records = [json.loads(line) for line in log.read_text().splitlines()]
            queued = next(row["params"]["prompt"] for row in records if row.get("method") == "session/prompt" and row["params"]["prompt"][-1].get("text") == "QUEUED PASSAGE")
            assert any(block.get("resource", {}).get("text") == original["text"] for block in queued), queued
            checks.append("Queued excerpts survive reconnect and retain the text captured before the page changed")

            ask("agent-context", action="pin", on=True)
            ask("select", id=other_tab)
            ask("agent-context", draft="PINNED QUESTION")
            ask("agent-context", action="send")
            until(lambda: ask("probe")["agent"]["taskState"] == "Finished")
            records = [json.loads(line) for line in log.read_text().splitlines()]
            pinned = next(row["params"]["prompt"] for row in records if row.get("method") == "session/prompt" and row["params"]["prompt"][-1].get("text") == "PINNED QUESTION")
            assert any(block.get("resource", {}).get("uri") == page.as_uri() for block in pinned), pinned
            assert not any(block.get("resource", {}).get("uri") == other.as_uri() for block in pinned), pinned
            ask("agent-context", action="pin", on=False)
            ask("agent-context", draft="NO PAGE")
            ask("agent-context", action="send")
            until(lambda: ask("probe")["agent"]["taskState"] == "Finished")
            records = [json.loads(line) for line in log.read_text().splitlines()]
            excluded = next(row["params"]["prompt"] for row in records if row.get("method") == "session/prompt" and row["params"]["prompt"][-1].get("text") == "NO PAGE")
            assert all(block["type"] != "resource" for block in excluded), excluded
            checks.append("Pinned context follows its original tab; excluding context sends no page resource")

            ask("ui", ask="QUESTION")
            until(lambda: ask("probe")["agent"]["taskState"] == "Needs your answer")
            ask("agent-context", draft="First")
            ask("agent-context", action="send")
            until(lambda: ask("probe")["agent"]["taskState"] == "Finished")
            ask("ui", ask="FAILED")
            until(lambda: ask("probe")["agent"]["taskState"] == "Interrupted")
            ask("ui", ask="STOPPED")
            until(lambda: ask("probe")["agent"]["taskState"] == "Ready to continue")
            checks.append("Task status distinguishes working, questions, completion, interrupted and stopped turns")

            # Use the real local MCP server; only the isolated world's token is read.
            config = json.loads((profile / "Agent/mcp.json").read_text())["mcpServers"]["browse"]
            def tool(name, arguments):
                payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": name, "arguments": arguments}}).encode()
                req = urllib.request.Request(config["url"], data=payload, headers={**config["headers"], "Content-Type": "application/json"})
                with urllib.request.urlopen(req, timeout=20) as response:
                    reply = json.load(response)
                assert "error" not in reply, reply
                return reply
            ask("select", id=tab)
            ask("key", id=tab, text="x")
            keys = ask("probe")["keys"]
            tool("open", {"url": other.as_uri()})
            until(lambda: len(ask("probe")["agent"]["openPages"]) == 1)
            assert ask("probe")["keys"] == keys, "Agent page updates stole page focus"
            agent_page = ask("probe")["agent"]["openPages"][0]
            tool("go", {"page": agent_page["id"], "url": page.as_uri()})
            until(lambda: ask("probe")["agent"]["openPages"][0]["title"] == "Focus check")
            ask("agent-context", action="inspect", id=agent_page["id"])
            assert ask("probe")["keys"] == keys
            tool("close", {"page": agent_page["id"]})
            assert not ask("probe")["agent"]["openPages"]
            tool("open", {"url": other.as_uri()})
            ask("ui", chat="none")
            assert not ask("probe")["agent"]["openPages"]
            checks.append("Agent page navigation updates the list without taking focus; close and new-chat actions clear it")
            # Draft separation is opt-in; excerpts and context choices travel
            # with the unsent words, without creating an ACP prompt.
            ask("select", id=tab)
            ask("agent-context", action="pin", on=False, drafts=True, draft="Page one question", withPage=False)
            ask("eval", id=tab, js=select_passage)
            ask("agent-context", action="selection")
            passage = ask("probe")["agent"]["passage"]
            before = log.read_text().count('"session/prompt"')
            ask("select", id=other_tab)
            state = ask("probe")["agent"]
            assert state["draft"] == "" and not state["passage"], state
            ask("agent-context", draft="Page two question")
            ask("select", id=tab)
            state = ask("probe")["agent"]
            assert state["draft"] == "Page one question" and state["passage"] == passage, state
            ask("agent-context", prepare="Research instructions")
            assert ask("probe")["agent"]["draft"] == "Page one question\n\nResearch instructions"
            assert log.read_text().count('"session/prompt"') == before
            checks.append("Opt-in tab drafts restore words and excerpts; task preparation appends without prompting")
            ask("agent-context", action="pin", on=True)
            ask("select", id=other_tab)
            assert ask("probe")["agent"]["draft"].startswith("Page one question")
            ask("agent-context", action="pin", on=False)
            assert ask("probe")["agent"]["draft"] == "Page two question"
            ask("agent-context", drafts=False)
            ask("select", id=tab)
            assert ask("probe")["agent"]["draft"] == "Page two question"
            checks.append("Pinned chat keeps its draft; unpin restores the current tab and disabling preserves current words")
            ask("agent-context", drafts=True, draft="Tab one follow-up")
            ask("select", id=other_tab)
            ask("agent-context", draft="Tab two follow-up")
            ask("select", id=tab)
            ask("ui", ask="QUESTION")
            until(lambda: ask("probe")["agent"]["taskState"] == "Needs your answer")
            ask("select", id=other_tab)
            ask("agent-context", prepare="Do not put a task into an answer")
            assert ask("probe")["agent"]["draft"] == ""
            ask("agent-context", draft="Use the original source")
            ask("agent-context", action="send")
            until(lambda: ask("probe")["agent"]["taskState"] == "Finished")
            assert ask("probe")["agent"]["draft"] == "Tab two follow-up"
            checks.append("A pending agent question keeps its answer field across tab switches, then restores the tab draft")
            ask("select", id=tab)
            ask("agent-context", draft="Pinned tab question", action="pin", on=True)
            ask("select", id=other_tab)
            ask("ui", chat="none")
            until(lambda: ask("probe")["agent"]["phase"] == "")
            assert ask("probe")["agent"]["draft"] == "Tab two follow-up"
            checks.append("Starting a new chat releases the old pin and restores the current tab draft")
            for check in checks:
                print("PASS", check)
        finally:
            for tab in opened:
                try:
                    ask("close", id=tab)
                except (OSError, AssertionError):
                    pass
            found = subprocess.run(["lsof", "-t", str(socket_path)], capture_output=True, text=True)
            for pid in set(found.stdout.split()):
                executable = subprocess.check_output(["ps", "-p", pid, "-ww", "-o", "comm="], text=True).strip()
                if executable == str(APP / "Contents/MacOS/Browse"):
                    os.kill(int(pid), signal.SIGTERM)
            subprocess.run(["defaults", "delete", suite], capture_output=True)


if __name__ == "__main__":
    if "acp" in sys.argv:
        mock_agent()
    else:
        run_checks()
