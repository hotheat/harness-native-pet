import importlib.util
from pathlib import Path
import unittest
spec = importlib.util.spec_from_file_location('install_hooks', Path(__file__).parents[1] / 'install-hooks.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class InstallHooksTests(unittest.TestCase):
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


if __name__ == '__main__':
    unittest.main()
