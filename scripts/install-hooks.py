#!/usr/bin/env python3
"""Install the native hook helper and merge only this application's handlers."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shlex
import shutil
import stat
import tempfile

EVENTS = {
    'codex': ['SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PermissionRequest',
              'PostToolUse', 'Stop', 'Interrupt', 'SessionEnd'],
    'claude-code': ['SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PermissionRequest',
                    'PostToolUse', 'PostToolUseFailure', 'Stop', 'StopFailure', 'SessionEnd'],
}


def merge_hooks(config, command, events, remove=False):
    """Preserve every unrelated setting and hook; make installation idempotent."""
    result = json.loads(json.dumps(config))
    hooks = result.setdefault('hooks', {})
    if not isinstance(hooks, dict):
        raise ValueError('Existing hooks must be an object')
    for event, groups in list(hooks.items()):
        if not isinstance(groups, list):
            raise ValueError(f'Existing hook {event} must be an array')
        kept = []
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get('hooks'), list):
                raise ValueError(f'Invalid hook group in {event}')
            handlers = [handler for handler in group['hooks']
                        if not (isinstance(handler, dict) and handler.get('type') == 'command'
                                and handler.get('command') == command)]
            if len(handlers) == len(group['hooks']):
                kept.append(group)
            elif handlers:
                kept.append({**group, 'hooks': handlers})
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]
    if not remove:
        for event in events:
            hooks.setdefault(event, []).append({'hooks': [{'type': 'command', 'command': command, 'timeout': 2}]})
    if not hooks:
        result.pop('hooks', None)
    return result


def atomic_write(path, content, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(prefix='.pet-hooks-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def install_helper(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(prefix='.pet-hook-', dir=destination.parent)
    os.close(fd)
    try:
        shutil.copy2(source, temporary)
        os.chmod(temporary, 0o700)
        os.replace(temporary, destination)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, help='Path to DSH Native Pet.app')
    parser.add_argument('--target', choices=['both', *EVENTS], default='both')
    parser.add_argument('--uninstall', action='store_true')
    parser.add_argument('--home', type=Path, help='Explicit isolated home, useful for tests')
    args = parser.parse_args()
    home = (args.home or Path.home()).expanduser().resolve()
    destination = home / 'Library/Application Support/dsh-native-pet/bin/pet-hook'
    configs = {
        'codex': (Path(os.environ.get('CODEX_HOME', str(home / '.codex'))) if not args.home else home / '.codex') / 'hooks.json',
        'claude-code': (Path(os.environ.get('CLAUDE_CONFIG_DIR', str(home / '.claude'))) if not args.home else home / '.claude') / 'settings.json',
    }
    targets = list(EVENTS) if args.target == 'both' else [args.target]
    source = args.app.expanduser().resolve() / 'Contents/MacOS/pet-hook' if args.app else None
    if not args.uninstall and (source is None or not source.is_file()):
        parser.error('--app must point to a built application containing pet-hook')
    updates = []
    for target in targets:
        path = configs[target].expanduser().resolve()
        config = json.loads(path.read_text()) if path.exists() else {}
        if not isinstance(config, dict):
            raise ValueError(f'{path}: settings must be a JSON object')
        command = shlex.quote(str(destination)) + ' ' + target
        merged = merge_hooks(config, command, EVENTS[target], args.uninstall)
        if merged != config:
            updates.append((path, json.dumps(merged, ensure_ascii=False, indent=2) + '\n'))
    if not args.uninstall:
        install_helper(source, destination)
    for path, content in updates:
        mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600
        if path.exists():
            stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
            backup = path.with_name(path.name + '.dsh-native-pet-' + stamp + '.bak')
            shutil.copy2(path, backup)
            backup.chmod(0o600)
            print(f'Backup: {backup}')
        atomic_write(path, content, mode)
        print(f'Updated: {path}')
    # Keep the tiny helper when uninstalling one host: the other may still use it.
    print('Hooks removed.' if args.uninstall else 'Hooks installed. Restart Claude Code; review and enable Codex hooks in /hooks or its Hooks settings.')


if __name__ == '__main__':
    main()
