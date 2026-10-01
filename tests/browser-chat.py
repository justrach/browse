#!/usr/bin/env python3
"""Same-session browser access against an offline ACP agent and account relay."""
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
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'build/browse.app'


def run():
    world = 'browser-chat-' + uuid.uuid4().hex[:8]
    suite = 'com.codegraff.search.test.' + world
    profile = Path.home() / 'Library/Application Support' / f'browse ({world})'
    socket_path = profile / 'bench.sock'
    devices, commands, events, answers, uploads = {}, [], [], {}, []
    failures = {'events': 0, 'poll': 0}
    checks = []
    lock = threading.Lock()

    class Relay(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def reply(self, value, code=200):
            data = json.dumps(value).encode()
            self.send_response(code)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if self.path.startswith('/api/remote/'):
                from urllib.parse import parse_qs, urlparse
                cursor = int(parse_qs(urlparse(self.path).query).get('from', ['1'])[0])
                time.sleep(.1)
                with lock:
                    selected = [json.dumps(e) for e in events if e['seq'] >= cursor]
                    last = max([cursor - 1] + [e['seq'] for e in events])
                return self.reply({'events': selected, 'next_from': last + 1, 'gap': False, 'in_flight': False})
            preview = ROOT / 'build/browser-chat-preview'
            asset = self.path.split('?')[0]
            names = {'/': ('index.html', 'text/html'), '/app.js': ('app.js', 'text/javascript'), '/app.css': ('app.css', 'text/css'), '/style.css': ('style.css', 'text/css')}
            if asset not in names:
                return self.reply({}, 404)
            name, mime = names[asset]
            data = (preview / name).read_bytes()
            self.send_response(200)
            self.send_header('Content-Type', mime)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))))
            if self.path.startswith('/v1/'):
                assert self.headers['Authorization'] == 'Bearer cg_sk_offline_test_only'
            if self.path.startswith('/api/remote/sessions/'):
                id = uuid.uuid4().hex
                with lock:
                    commands.append({'id': id, 'kind': 'request', 'session_id': self.path.rsplit('/', 1)[-1], 'body': body})
                return self.reply({'ok': True, 'command_id': id}, 202)
            action = self.path.rsplit('/', 1)[-1]
            with lock:
                if action == 'register':
                    devices[self.path.split('/')[-2]] = body
                    return self.reply({'ok': True})
                if action == 'poll':
                    time.sleep(.1)
                    if failures['poll']:
                        failures['poll'] -= 1
                        return self.reply({'error': 'test reconnect'}, 503)
                    devices[self.path.split('/')[-2]]['sessions'] = body['sessions']
                    batch = commands[:]
                    commands.clear()
                    return self.reply({'commands': batch})
                if action == 'events':
                    if failures['events']:
                        failures['events'] -= 1
                        return self.reply({'error': 'test dropped upload'}, 503)
                    uploads.append(body)
                    events.extend(body.get('events', []))
                    if 'result' in body:
                        answers[body['command_id']] = body['result']
                    return self.reply({'ok': True})
            self.reply({}, 404)

        def do_DELETE(self):
            with lock:
                devices.pop(self.path.rsplit('/', 1)[-1], None)
            self.reply({'ok': True})

    server = ThreadingHTTPServer(('127.0.0.1', 0), Relay)
    threading.Thread(target=server.serve_forever, daemon=True).start()

    def ask(verb, **params):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(15)
            client.connect(str(socket_path))
            client.sendall((json.dumps({'do': verb, **params}) + '\n').encode())
            data = b''
            while b'\n' not in data:
                data += client.recv(65536)
        result = json.loads(data.split(b'\n')[0])
        assert 'error' not in result, result
        return result

    def until(predicate):
        end = time.monotonic() + 20
        while time.monotonic() < end:
            try:
                if predicate():
                    return
            except (FileNotFoundError, ConnectionRefusedError):
                pass
            time.sleep(.1)
        raise AssertionError('Timed out waiting for browser access')

    def send(body, session=None, kind='request'):
        id = uuid.uuid4().hex
        commands.append({'id': id, 'kind': kind, 'session_id': session or current(), 'body': body})
        until(lambda: id in answers)
        return answers[id]

    def current():
        return ask('probe')['agent']['browserChat']['session']

    def state():
        return next(e['state'] for e in reversed(events) if e['type'] == 'browse_state')

    with tempfile.TemporaryDirectory(prefix='browse-web-chat-') as temporary:
        scratch = Path(temporary)
        program = scratch / 'graff'
        program.write_text(f'#!{sys.executable}\n' + (ROOT / 'tests/agent-recovery.py').read_text())
        program.chmod(0o700)
        log = scratch / 'acp.jsonl'
        env = {**os.environ, 'SEARCH_PROBE': world, 'SEARCH_REMOTE_URL': f'http://127.0.0.1:{server.server_port}',
               'BROWSE_AGENT_TEST_LOG': str(log)}
        subprocess.run(['defaults', 'write', suite, 'bench', '-bool', 'true'], check=True)
        subprocess.run(['defaults', 'write', suite, 'agent.path', str(program)], check=True)
        subprocess.run(['defaults', 'write', suite, 'settings.page', 'agent'], check=True)
        subprocess.run(['open', '-n', str(APP), '--env', 'SEARCH_PROBE=' + world,
                        '--env', 'SEARCH_REMOTE_URL=' + env['SEARCH_REMOTE_URL'],
                        '--env', 'BROWSE_AGENT_TEST_LOG=' + str(log)], env=env, check=True)
        try:
            until(lambda: socket_path.exists())
            assert not ask('probe')['agent']['browserChat']['on']
            ask('ui', agent=True)
            until(lambda: ask('probe')['agent']['connected'])
            ask('ui', browserchat=True)
            assert not ask('probe')['agent']['browserChat']['on']
            checks.append('Browser access is off by default and requires a Codegraff sign-in')
            profile.mkdir(parents=True, exist_ok=True)
            (profile / 'codegraff-login.json').write_text(json.dumps({'api_key': 'cg_sk_offline_test_only'}))
            (profile / 'codegraff-login.json').chmod(0o600)
            ask('ui', ask='NATIVE FIRST')
            until(lambda: ask('probe')['agent']['taskState'] == 'Finished')
            ask('agent-context', draft='UNSENT NATIVE DRAFT', withPage=False)
            ask('ui', browserchat=True)
            until(lambda: ask('probe')['agent']['browserChat']['connected'])
            until(lambda: any(e.get('entry', {}).get('text') == 'NATIVE FIRST' for e in events))
            url = ask('probe')['agent']['browserChat']['url']
            assert url.startswith('https://codegraff.com/browse/chat?session=browse-')
            assert 'cg_sk_' not in url and 'UNSENT NATIVE DRAFT' not in json.dumps(events)
            assert all('Authorization' not in json.dumps(b) for b in uploads)
            checks.append('Native history reaches the same-session relay; links and event bodies contain no credentials or unsent drafts')
            result = send({'type': 'user', 'text': 'REMOTE SECOND'})
            assert result['status'] == 200
            until(lambda: ask('probe')['agent']['taskState'] == 'Finished')
            records = [json.loads(line) for line in log.read_text().splitlines()]
            assert sum(r.get('method') == 'session/new' for r in records) == 1
            prompt = next(r['params']['prompt'] for r in records if r.get('method') == 'session/prompt' and r['params']['prompt'][-1].get('text') == 'REMOTE SECOND')
            assert not any(p['type'] == 'resource' for p in prompt)
            assert ask('probe')['agent']['draft'] == 'UNSENT NATIVE DRAFT'
            checks.append('Browser messages use the existing ACP session and preserve native drafts without implicitly attaching a page')
            send({'type': 'user', 'text': 'RETRY ONCE', 'client_message_id': 'retry-test'})
            send({'type': 'user', 'text': 'RETRY ONCE', 'client_message_id': 'retry-test'})
            records = [json.loads(line) for line in log.read_text().splitlines()]
            assert sum(r.get('method') == 'session/prompt' and r['params']['prompt'][-1].get('text') == 'RETRY ONCE' for r in records) == 1
            checks.append('Retrying an unconfirmed browser message does not run the same prompt twice')
            send({'type': 'user', 'text': 'QUESTION'})
            until(lambda: state().get('ask'))
            q = state()['ask']
            result = send({'type': 'answer', 'ask_id': 'stale', 'text': 'wrong question'})
            assert result['status'] == 409
            result = send({'type': 'answer', 'ask_id': q['id'], 'text': 'First'})
            assert result['status'] == 200
            until(lambda: ask('probe')['agent']['taskState'] == 'Finished')
            assert ask('probe')['agent']['draft'] == 'UNSENT NATIVE DRAFT'
            checks.append('Questions can be answered in the browser; stale answers are refused and native drafts survive')
            failures['events'] = 1
            ask('ui', ask='AFTER LOST UPLOAD')
            until(lambda: any(e.get('entry', {}).get('text') == 'AFTER LOST UPLOAD' for e in events))
            assert ask('probe')['agent']['browserChat']['on']
            checks.append('A failed upload reconnects and republishes changed history')
            before = len(events)
            send({'type': 'reattach', 'resume_from': 1})
            replay = [e for e in events[before:] if e['type'] == 'browse_entry']
            assert any(e['entry']['text'] == 'NATIVE FIRST' for e in replay)
            assert len({e['entry']['id'] for e in replay}) == len(replay)
            checks.append('Reconnect replay uses stable entry IDs and includes native conversation history')
            result = send({'type': 'user', 'text': 'NO OTHER CHAT'}, session='another-conversation')
            assert result['status'] == 403
            result = send({}, kind='create', session='another-conversation')
            assert result['status'] == 403
            checks.append('Remote requests cannot create an extra agent or target another conversation')
            if '--preview' in sys.argv:
                ask('ui', settings=True)
                ask('picture', path=str(ROOT / 'build/browser-chat-setup.png'), page=False)
                ask('ui', settings=False)
                print(f'PREVIEW http://127.0.0.1:{server.server_port}/?session={current()}', flush=True)
                print('Preview is the running offline test conversation. Interrupt to finish checks and clean up.', flush=True)
                try:
                    while True:
                        time.sleep(1)
                except KeyboardInterrupt:
                    pass
            send({'type': 'user', 'text': 'STALL'})
            until(lambda: ask('probe')['agent']['pendingTools'] > 0)
            send({'type': 'user', 'text': 'QUEUE FROM BROWSER'})
            assert ask('probe')['agent']['queue'] == 1
            assert send({'type': 'cancel'})['status'] == 200
            records = [json.loads(line) for line in log.read_text().splitlines()]
            assert any(r.get('method') == 'session/cancel' for r in records)
            checks.append('Busy messages queue in the existing agent and browser Stop sends ACP cancellation')
            ask('ui', reconnect=True)
            until(lambda: ask('probe')['agent']['connected'])
            ask('ui', browserchat=False)
            until(lambda: not devices)
            old_session = current()
            ask('ui', browserchat=True)
            until(lambda: ask('probe')['agent']['browserChat']['connected'])
            assert current() != old_session
            ask('ui', chat='new')
            until(lambda: not ask('probe')['agent']['browserChat']['on'])
            checks.append('Disabling revokes relay access; re-enabling gets a new identity; switching conversations disconnects')
            ask('ui', browserchat=True)
            until(lambda: ask('probe')['agent']['browserChat']['connected'])
            ask('ui', agentenabled=False)
            until(lambda: not ask('probe')['agent']['browserChat']['on'])
            checks.append('Disabling Codegraff immediately ends browser access')
            for check in checks:
                print('PASS', check)
        finally:
            found = subprocess.run(['lsof', '-t', str(socket_path)], capture_output=True, text=True)
            for pid in set(found.stdout.split()):
                executable = subprocess.check_output(['ps', '-p', pid, '-ww', '-o', 'comm='], text=True).strip()
                if executable == str(APP / 'Contents/MacOS/Browse'):
                    os.kill(int(pid), signal.SIGTERM)
            subprocess.run(['defaults', 'delete', suite], capture_output=True)
            server.shutdown()


if __name__ == '__main__':
    run()
