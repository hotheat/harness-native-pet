#!/usr/bin/env python3
"""Exercise short-lived hook processes against a packaged native app, recording notifications."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
app = args.app.resolve() / 'Contents/MacOS/DSHNativePet'
helper = args.app.resolve() / 'Contents/MacOS/pet-hook'
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
results = []
for scenario in ['parallel-ended', 'waiting', 'closed-ended']:
    with tempfile.TemporaryDirectory(prefix='dnp-ha-', dir='/tmp') as directory:
        env = {**os.environ, 'DSH_NATIVE_PET_RUNTIME_DIR': directory}
        capture = out / (scenario + '.png')
        notices = out / (scenario + '.jsonl')
        process = subprocess.Popen([str(app), '--capture-live', str(capture), '--capture-after', '2',
                                    '--notification-log', str(notices), '-pet.skin', 'dshPet',
                                    '-pet.size', 'medium', '-pet.visible', 'YES', '-pet.systemNotifications', 'YES'],
                                   env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        def send(host, event, session='same-name', turn='turn-a', **fields):
            payload = {'hook_event_name': event, 'session_id': session,
                       'turn_id' if host == 'codex' else 'prompt_id': turn, **fields}
            result = subprocess.run([str(helper), host, '--strict'], input=json.dumps(payload),
                                    env=env, text=True, capture_output=True, timeout=2)
            assert result.returncode == 0, result.stderr
            assert result.stdout.strip() == '{}', result.stdout
        try:
            deadline = time.monotonic() + 8
            while not (Path(directory) / 'pet.sock').exists():
                assert process.poll() is None, 'Application stopped before socket was ready'
                assert time.monotonic() < deadline, 'Socket startup timed out'
                time.sleep(.02)
            if scenario == 'parallel-ended':
                send('codex', 'UserPromptSubmit')
                send('codex', 'PreToolUse', tool_use_id='tool-a')
                send('claude-code', 'UserPromptSubmit')
                send('claude-code', 'Stop', last_assistant_message='fixture response')
                send('claude-code', 'Stop', last_assistant_message='fixture response')
            elif scenario == 'waiting':
                send('claude-code', 'UserPromptSubmit')
                send('claude-code', 'PermissionRequest', tool_name='Bash')
            else:
                send('codex', 'Stop', last_assistant_message='fixture response')
                send('codex', 'SessionEnd')
            stdout, stderr = process.communicate(timeout=12)
            assert process.returncode == 0, stderr
            evidence = json.loads(capture.with_suffix('.json').read_text())
            records = [json.loads(line) for line in notices.read_text().splitlines()]
            assert len(records) == 1, records
            assert evidence['characterHeight'] == 100
            assert evidence['skin'] == 'dshPet'
            if scenario == 'parallel-ended':
                assert evidence['storePose'] == 'working', evidence
                assert set(evidence['sourceLabels']) == {'Codex', 'Claude Code'}, evidence
                assert records[0]['sourceLabel'] == 'Claude Code' and records[0]['kind'] == 'ended'
            elif scenario == 'waiting':
                assert evidence['storePose'] == 'waiting', evidence
                assert records[0]['kind'] == 'waiting' and records[0]['sourceLabel'] == 'Claude Code'
            else:
                assert evidence['storePose'] == 'completed', evidence
                assert 'Codex' in evidence['displayText'] and '结束' in evidence['displayText'], evidence
                assert records[0]['kind'] == 'ended'
            results.append({'scenario': scenario, 'passed': True, 'capture': str(capture), 'notices': records,
                            'state': evidence, 'stdout': stdout, 'stderr': stderr})
            print(f'{scenario}: passed', flush=True)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
(out / 'hook-app.json').write_text(json.dumps(results, ensure_ascii=False, indent=2) + '\n')
