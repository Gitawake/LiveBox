"""Check nested signing order and preservation without requiring Apple credentials."""
import importlib.machinery
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

script = Path(__file__).resolve().parents[1] / 'tools/build-ipa'
loader = importlib.machinery.SourceFileLoader('build_ipa', str(script))
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)


class SigningTests(unittest.TestCase):
    def test_nested_signing_and_entitlements(self):
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder) / 'Example.app'
            framework = app / 'PlugIns/Widget.appex/Frameworks/Example.framework'
            framework.mkdir(parents=True)
            extension = app / 'PlugIns/Widget.appex'
            dylib = framework / 'Libraries/Example.dylib'
            dylib.parent.mkdir()
            dylib.touch()
            (app / 'FrameworkAlias.framework').symlink_to(framework, target_is_directory=True)
            commands = []
            saved_entitlements = []
            def record(command):
                commands.append(command)
                if '--entitlements' in command:
                    path = Path(command[command.index('--entitlements') + 1])
                    saved_entitlements.append(plistlib.loads(path.read_bytes()))
            def existing(command, **kwargs):
                data = plistlib.dumps({'get-task-allow': False}) if command[-1] == str(extension) else b''
                return subprocess.CompletedProcess(command, 0 if data else 1, data, b'')
            with patch.object(module, 'run', side_effect=record), patch.object(module.subprocess, 'run', side_effect=existing):
                module.sign_for_sideloading(app)
            signed = [Path(c[-1]) for c in commands if '--sign' in c]
            self.assertEqual(signed, [dylib, framework, extension, app])
            self.assertEqual(saved_entitlements, [{'get-task-allow': False}])
            self.assertEqual(commands[-1], ['codesign', '--verify', '--deep', '--strict', str(app)])

    def test_signing_failure_stops_processing(self):
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder) / 'Example.app'
            app.mkdir()
            with patch.object(module.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, b'', b'')), patch.object(module, 'run', side_effect=RuntimeError('signing failed')):
                with self.assertRaisesRegex(RuntimeError, 'signing failed'):
                    module.sign_for_sideloading(app)


if __name__ == '__main__':
    unittest.main()
