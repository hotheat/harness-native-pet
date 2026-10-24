#!/usr/bin/env python3
"""Isolated real Codex/Claude hooks acceptance, with localhost model fixtures only."""
import argparse
import http.server
import json
import os
from pathlib import Path
import queue
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
HOSTS = {
    'codex-cli': (shutil.which('codex') or 'codex', 'codex'),
    'codex-desktop-runtime': ('/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex', 'codex'),
    'claude-code': (shutil.which('claude') or 'claude', 'claude-code'),
}
PROMPT = 'Fixture acceptance: respond with FIXTURE_OK only. Do not use tools.'


def write_json(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')


def clean_env(home, runtime):
    # Never inherit credentials, proxy settings, or the user's host configuration.
    return {
        'PATH': os.environ.get('PATH', '/usr/bin:/bin:/usr/sbin:/sbin'),
        'HOME': str(home), 'CODEX_HOME': str(home / '.codex'),
        'CLAUDE_CONFIG_DIR': str(home / '.claude'), 'TMPDIR': str(home / 'tmp'),
        'LANG': 'en_US.UTF-8', 'TERM': 'dumb',
        'DSH_NATIVE_PET_RUNTIME_DIR': str(runtime),
        'ANTHROPIC_API_KEY': 'fixture-local-only-not-a-secret',
        'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC': '1',
        'DISABLE_TELEMETRY': '1', 'DISABLE_ERROR_REPORTING': '1',
        'CLAUDE_CODE_SKIP_UPDATE_CHECK': '1',
    }


class FixtureServer(http.server.ThreadingHTTPServer):
    def __init__(self, log):
        self.log = log
        super().__init__(('127.0.0.1', 0), FixtureHandler)


class FixtureHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        try:
            request = json.loads(body)
        except ValueError:
            request = {}
        # Store routing evidence only; no prompts or headers are retained.
        with self.server.log.open('a') as log:
            log.write(json.dumps({'path': self.path, 'model': request.get('model'), 'stream': request.get('stream')}) + '\n')
        if self.path.split('?')[0].endswith('/responses'):
            events = [
                {'type': 'response.created', 'response': {'id': 'resp_fixture'}},
                {'type': 'response.output_item.done', 'item': {'type': 'message', 'role': 'assistant', 'id': 'msg_fixture', 'content': [{'type': 'output_text', 'text': 'FIXTURE_OK'}]}},
                {'type': 'response.completed', 'response': {'id': 'resp_fixture', 'usage': {'input_tokens': 0, 'input_tokens_details': None, 'output_tokens': 0, 'output_tokens_details': None, 'total_tokens': 0}}},
            ]
            payload = ''.join('data: ' + json.dumps(event) + '\n\n' for event in events)
            mime = 'text/event-stream'
        elif self.path.split('?')[0].endswith('/messages'):
            message = {'id': 'msg_fixture', 'type': 'message', 'role': 'assistant', 'model': request.get('model', 'fixture'), 'content': [{'type': 'text', 'text': 'FIXTURE_OK'}], 'stop_reason': 'end_turn', 'stop_sequence': None, 'usage': {'input_tokens': 1, 'output_tokens': 1}}
            if request.get('stream'):
                start = dict(message, content=[], stop_reason=None)
                events = [('message_start', {'type': 'message_start', 'message': start}), ('content_block_start', {'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': ''}}), ('content_block_delta', {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': 'FIXTURE_OK'}}), ('content_block_stop', {'type': 'content_block_stop', 'index': 0}), ('message_delta', {'type': 'message_delta', 'delta': {'stop_reason': 'end_turn', 'stop_sequence': None}, 'usage': {'output_tokens': 1}}), ('message_stop', {'type': 'message_stop'})]
                payload = ''.join('event: ' + kind + '\ndata: ' + json.dumps(value) + '\n\n' for kind, value in events)
                mime = 'text/event-stream'
            else:
                payload, mime = json.dumps(message), 'application/json'
        elif self.path.split('?')[0].endswith('/count_tokens'):
            payload, mime = '{"input_tokens": 1}', 'application/json'
        else:
            self.send_response(404)
            self.end_headers()
            return
        data = payload.encode()
        self.send_response(200)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class RPC:
    def __init__(self, binary, cwd, env, evidence):
        self.messages = queue.Queue()
        self.events = []
        self.counter = 0
        self.log = (evidence / 'rpc.jsonl').open('w')
        self.err = (evidence / 'host.stderr').open('w')
        self.process = subprocess.Popen([binary, 'app-server'], cwd=cwd, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.err, text=True, start_new_session=True)
        threading.Thread(target=self.read, daemon=True).start()

    def read(self):
        for line in self.process.stdout:
            self.log.write(line)
            self.log.flush()
            try:
                self.messages.put(json.loads(line))
            except ValueError:
                pass

    def send(self, value):
        self.process.stdin.write(json.dumps(value) + '\n')
        self.process.stdin.flush()

    def until(self, predicate, timeout=15):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                value = self.messages.get(timeout=min(1, deadline - time.monotonic()))
            except queue.Empty:
                if self.process.poll() is not None:
                    raise RuntimeError('app-server exited: ' + str(self.process.returncode))
                continue
            self.events.append(value)
            if predicate(value):
                return value
        raise TimeoutError('app-server response timeout')

    def call(self, method, params):
        self.counter += 1
        request_id = self.counter
        self.send({'id': request_id, 'method': method, 'params': params})
        value = self.until(lambda item: item.get('id') == request_id)
        if 'error' in value:
            raise RuntimeError(method + ': ' + json.dumps(value['error']))
        return value.get('result', {})

    def close(self):
        stop(self.process)
        self.err.close()
        self.log.close()


def stop(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=4)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()


def prepare(home, app, target, events_log):
    for directory in (home / '.codex', home / '.claude', home / 'tmp', home / 'workspace'):
        directory.mkdir(parents=True, exist_ok=True)
    subprocess.run([sys.executable, str(ROOT / 'scripts/install-hooks.py'), '--app', str(app), '--target', target, '--home', str(home)], check=True, capture_output=True, text=True)
    # Keep actual helper execution and capture only the isolated fixture's hook input.
    recorder = home / 'fixture-hook.py'
    recorder.write_text('import json,subprocess,sys\nfrom pathlib import Path\nraw=sys.stdin.buffer.read()\nwith Path(sys.argv[1]).open("ab") as f: f.write(raw.rstrip(b"\\n")+b"\\n")\nr=subprocess.run(sys.argv[2:],input=raw)\nraise SystemExit(r.returncode)\n')
    config_path = home / ('.codex/hooks.json' if target == 'codex' else '.claude/settings.json')
    config = json.loads(config_path.read_text())
    for groups in config['hooks'].values():
        for group in groups:
            for hook in group['hooks']:
                hook['command'] = shlex.join([sys.executable, str(recorder), str(events_log)]) + ' ' + hook['command']
    write_json(config_path, config)
    return home / 'workspace'


def codex(binary, cwd, env, evidence, base):
    config = f'''model = "mock-model"
model_provider = "fixture"
approval_policy = "never"
sandbox_mode = "read-only"
[features]
hooks = true
[model_providers.fixture]
name = "Local deterministic fixture"
base_url = "{base}/v1"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false
request_max_retries = 0
stream_max_retries = 0
'''
    (Path(env['CODEX_HOME']) / 'config.toml').write_text(config)
    rpc = RPC(binary, cwd, env, evidence)
    try:
        initialized = rpc.call('initialize', {'clientInfo': {'name': 'pet-real-host-fixture', 'version': '1'}, 'capabilities': {'experimentalApi': True}})
        rpc.send({'method': 'initialized'})
        discovered = rpc.call('hooks/list', {'cwds': [str(cwd)]})
        write_json(evidence / 'hooks-discovered.json', discovered)
        hooks = [hook for item in discovered.get('data', []) for hook in item.get('hooks', [])]
        discovered_events = {hook['eventName'] for hook in hooks}
        if not {'userPromptSubmit', 'stop'}.issubset(discovered_events):
            raise RuntimeError('Required hooks missing from isolated hooks.json')
        trusted = {hook['key']: {'trusted_hash': hook['currentHash']} for hook in hooks}
        rpc.call('config/batchWrite', {'edits': [{'keyPath': 'hooks.state', 'value': trusted, 'mergeStrategy': 'upsert'}], 'reloadUserConfig': True})
        write_json(evidence / 'hooks-trusted.json', rpc.call('hooks/list', {'cwds': [str(cwd)]}))
        thread = rpc.call('thread/start', {'model': 'mock-model', 'cwd': str(cwd), 'approvalPolicy': 'never', 'sandbox': 'read-only'})
        rpc.call('turn/start', {'threadId': thread['thread']['id'], 'input': [{'type': 'text', 'text': PROMPT, 'textElements': []}]})
        completed = rpc.until(lambda value: value.get('method') == 'turn/completed', timeout=45)
        return {'initialize': initialized, 'turnCompleted': completed}
    finally:
        rpc.close()


def claude(binary, cwd, env, evidence, base):
    env['ANTHROPIC_BASE_URL'] = base
    write_json(Path(env['CLAUDE_CONFIG_DIR']) / '.claude.json', {'hasCompletedOnboarding': True})
    with (evidence / 'host.stdout').open('w') as out, (evidence / 'host.stderr').open('w') as err:
        process = subprocess.Popen([binary, '-p', PROMPT, '--model', 'claude-sonnet-4-6', '--max-turns', '1', '--tools', '', '--output-format', 'json', '--setting-sources', 'user'], cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=out, stderr=err, start_new_session=True)
        try:
            code = process.wait(timeout=50)
        finally:
            stop(process)
    if code:
        raise RuntimeError('Claude exited: ' + str(code))
    return {'returncode': code}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--codex', default=HOSTS['codex-cli'][0])
    parser.add_argument('--desktop-codex', default=HOSTS['codex-desktop-runtime'][0])
    parser.add_argument('--claude', default=HOSTS['claude-code'][0])
    parser.add_argument('--keep-home', action='store_true', help='Retain isolated HOME for fixture debugging')
    parser.add_argument('--host', action='append', choices=list(HOSTS))
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    HOSTS['codex-cli'] = (args.codex, 'codex')
    HOSTS['codex-desktop-runtime'] = (args.desktop_codex, 'codex')
    HOSTS['claude-code'] = (args.claude, 'claude-code')
    stamp = time.strftime('%Y%m%d-%H%M%S')
    evidence_root = (args.output or ROOT / 'work' / ('real-host-hooks-' + stamp)).resolve()
    evidence_root.mkdir(parents=True, exist_ok=True)
    results = {}
    for name in args.host or HOSTS:
        evidence = evidence_root / name
        evidence.mkdir(exist_ok=True)
        binary, target = HOSTS[name]
        print(name + ': starting isolated host acceptance', flush=True)
        home = Path(tempfile.mkdtemp(prefix='pet-host-', dir='/tmp'))
        runtime = home / 'ipc'
        runtime.mkdir(mode=0o700)
        events_log, notices = evidence / 'hook-events.jsonl', evidence / 'notifications.jsonl'
        app_process = None
        server = FixtureServer(evidence / 'local-model-requests.jsonl')
        threading.Thread(target=server.serve_forever, daemon=True).start()
        env = clean_env(home, runtime)
        result = {'home': str(home), 'binary': binary, 'scope': 'installed host runtime; no desktop UI interaction', 'modelEndpoint': f'http://127.0.0.1:{server.server_port}'}
        try:
            cwd = prepare(home, args.app.resolve(), target, events_log)
            result['version'] = subprocess.check_output([binary, '--version'], env=env, text=True, timeout=10).strip()
            with (evidence / 'app.stdout').open('w') as out, (evidence / 'app.stderr').open('w') as err:
                app_process = subprocess.Popen([str(args.app.resolve() / 'Contents/MacOS/DSHNativePet'), '--notification-log', str(notices), '-pet.visible', 'NO', '-pet.skin', 'character', '-pet.systemNotifications', 'YES'], env=env, cwd=cwd, stdout=out, stderr=err, start_new_session=True)
                deadline = time.monotonic() + 10
                while not (runtime / 'pet.sock').exists() and time.monotonic() < deadline:
                    if app_process.poll() is not None:
                        raise RuntimeError('Pet app exited before socket ready')
                    time.sleep(.05)
                if not (runtime / 'pet.sock').exists():
                    raise TimeoutError('Pet socket did not appear')
                base = result['modelEndpoint']
                result['hostResult'] = codex(binary, cwd, env, evidence, base) if target == 'codex' else claude(binary, cwd, env, evidence, base)
                deadline = time.monotonic() + 4
                while time.monotonic() < deadline:
                    if notices.exists() and any(json.loads(line).get('kind') == 'ended' for line in notices.read_text().splitlines()):
                        break
                    time.sleep(.1)
                hooks = [json.loads(line) for line in events_log.read_text().splitlines()] if events_log.exists() else []
                notifications = [json.loads(line) for line in notices.read_text().splitlines()] if notices.exists() else []
                result['events'] = [item.get('hook_event_name') for item in hooks]
                result['noticeKinds'] = [item.get('kind') for item in notifications]
                result['sourceLabels'] = [item.get('sourceLabel') for item in notifications]
                expected_label = 'Codex' if target == 'codex' else 'Claude Code'
                result['passed'] = all(event in result['events'] for event in ('UserPromptSubmit', 'Stop')) and any(item.get('kind') == 'ended' and item.get('sourceLabel') == expected_label for item in notifications)
                if not result['passed']:
                    result['error'] = 'Required real host hook events or ended notification missing'
        except Exception as error:
            result['passed'], result['error'] = False, str(error)
        finally:
            if app_process:
                stop(app_process)
            server.shutdown()
            server.server_close()
            if not args.keep_home:
                shutil.rmtree(home)
            result['temporaryHomeRetained'] = args.keep_home
        results[name] = result
        write_json(evidence / 'result.json', result)
        print(name + ': ' + ('PASS' if result.get('passed') else 'FAIL ' + result.get('error', '')), flush=True)
    write_json(evidence_root / 'results.json', results)
    print(evidence_root, flush=True)
    return 0 if all(result.get('passed') for result in results.values()) else 1


if __name__ == '__main__':
    raise SystemExit(main())
