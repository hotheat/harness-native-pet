import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch
from contextlib import redirect_stdout
import io
import tempfile
import stat
import copy
import json
import shlex
spec = importlib.util.spec_from_file_location('install_hooks', Path(__file__).parents[1] / 'install-hooks.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class InstallHooksTests(unittest.TestCase):
    def test_shared_fixtures_match_installer(self):
        fixtures = json.loads((Path(__file__).parents[2] / 'contracts/fixtures/host-hooks.json').read_text())
        self.assertEqual(module.EVENTS, fixtures['events'])
        for case in fixtures['cases']:
            with self.subTest(case=case['name']):
                original = copy.deepcopy(case['config'])
                self.assertEqual(case['command'], shlex.quote(case['helperPath']) + ' ' + case['target'])
                if 'error' in case:
                    with self.assertRaisesRegex(ValueError, case['error']):
                        module.merge_hooks(case['config'], case['command'], module.EVENTS[case['target']], case['operation'] == 'remove')
                else:
                    result = module.merge_hooks(case['config'], case['command'], module.EVENTS[case['target']], case['operation'] == 'remove')
                    self.assertEqual(result, case['expected'])
                self.assertEqual(case['config'], original)

    def test_shared_quotes_match_real_shlex(self):
        fixtures = json.loads((Path(__file__).parents[2] / 'contracts/fixtures/host-hooks.json').read_text())
        for case in fixtures['quotes']:
            with self.subTest(path=case['path']):
                self.assertEqual(shlex.quote(case['path']), case['quoted'])

    def test_merge_is_idempotent_and_preserves_other_settings(self):
        command = "'/a space/pet-hook' codex"
        original = {'env': {'private': 'keep'}, 'hooks': {'Stop': [{'matcher': 'x', 'hooks': [
            {'type': 'command', 'command': 'other'}, {'type': 'command', 'command': command}]}]}}
        merged = module.merge_hooks(original, command, module.EVENTS['codex'])
        self.assertEqual(merged, module.merge_hooks(merged, command, module.EVENTS['codex']))
        self.assertEqual(merged['env'], original['env'])
        self.assertEqual(merged['hooks']['Stop'][0], {'matcher': 'x', 'hooks': [{'type': 'command', 'command': 'other'}]})
        self.assertEqual(len(original['hooks']['Stop'][0]['hooks']), 2)

    def test_uninstall_only_removes_owned_commands(self):
        installed = module.merge_hooks({'permissions': {'allow': ['Read']}}, 'pet-hook codex', module.EVENTS['codex'])
        self.assertEqual(module.merge_hooks(installed, 'pet-hook codex', [], True), {'permissions': {'allow': ['Read']}})

    def test_invalid_existing_config_fails_instead_of_overwriting(self):
        for config in [{'hooks': []}, {'hooks': {'Stop': 'bad'}}, {'hooks': {'Stop': [{}]}}]:
            with self.assertRaises(ValueError):
                module.merge_hooks(config, 'pet-hook codex', module.EVENTS['codex'])

    def test_reinstall_atomically_replaces_helper_in_isolated_home(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory) / 'home'
            app = Path(directory) / 'Pet.app'
            source = app / 'Contents/MacOS/pet-hook'
            source.parent.mkdir(parents=True)
            source.write_bytes(b'first helper')
            argv = ['install-hooks.py', '--app', str(app), '--home', str(home)]
            with patch('sys.argv', argv), redirect_stdout(io.StringIO()):
                module.main()
                destination = home / 'Library/Application Support/dsh-native-pet/bin/pet-hook'
                original_inode = destination.stat().st_ino
                source.write_bytes(b'upgraded helper')
                module.main()
                self.assertNotEqual(destination.stat().st_ino, original_inode)
                self.assertEqual(destination.read_bytes(), b'upgraded helper')
                self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o700)
                configs = [(home / '.codex/hooks.json').read_bytes(), (home / '.claude/settings.json').read_bytes()]
                module.main()
                self.assertEqual(configs, [(home / '.codex/hooks.json').read_bytes(), (home / '.claude/settings.json').read_bytes()])
                self.assertEqual(list(destination.parent.iterdir()), [destination])

    def test_failed_helper_upgrade_preserves_old_bytes_permissions_and_configs(self):
        for operation in ['shutil.copy2', 'os.chmod', 'os.replace']:
            with self.subTest(operation=operation), tempfile.TemporaryDirectory() as directory:
                home = Path(directory) / 'home'
                app = Path(directory) / 'Pet.app'
                source = app / 'Contents/MacOS/pet-hook'
                source.parent.mkdir(parents=True)
                source.write_bytes(b'new helper')
                destination = home / 'Library/Application Support/dsh-native-pet/bin/pet-hook'
                destination.parent.mkdir(parents=True)
                destination.write_bytes(b'old helper')
                destination.chmod(0o500)
                original_inode = destination.stat().st_ino
                with patch('sys.argv', ['install-hooks.py', '--app', str(app), '--home', str(home)]), \
                     patch.object(module.shutil if operation.startswith('shutil') else module.os,
                                  operation.split('.')[1], side_effect=OSError('injected failure')):
                    with self.assertRaisesRegex(OSError, 'injected failure'):
                        module.main()
                self.assertEqual(destination.read_bytes(), b'old helper')
                self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o500)
                self.assertEqual(destination.stat().st_ino, original_inode)
                self.assertEqual(list(destination.parent.iterdir()), [destination])
                self.assertFalse((home / '.codex/hooks.json').exists())
                self.assertFalse((home / '.claude/settings.json').exists())


if __name__ == '__main__':
    unittest.main()
