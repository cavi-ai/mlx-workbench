import importlib.util
import plistlib
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/install_app.py'
spec = importlib.util.spec_from_file_location('install_app', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class LocalAppInstallTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.app = Path(temporary.name).resolve() / 'MLX Workbench.app'
        binaries = self.app / 'Contents/MacOS'
        binaries.mkdir(parents=True)
        for name in ('mlx-workbench', 'mlx-workbench.debug.dylib', '__preview.dylib'):
            (binaries / name).write_bytes(b'\xcf\xfa\xed\xfe' + b'fixture')
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'com.cavi.mlxworkbench', 'CFBundleExecutable': 'mlx-workbench',
            'MLXWorkbenchInstallationProbe': 1}))

    def test_valid_individual_signatures_cannot_hide_a_mixed_team_debug_library(self):
        def identity(path):
            return {'team': None if path.name == 'mlx-workbench.debug.dylib' else 'EXISTINGTEAM'}
        with self.assertRaisesRegex(ValueError, 'debug.dylib'):
            module.verify_teams(self.app, 'EXISTINGTEAM', inspect=identity)

    def test_signing_covers_the_debug_library_before_the_outer_application(self):
        commands = []
        module.sign_app(self.app, 'a' * 40, None, run=lambda argv: commands.append(argv))
        paths = [row[-1] for row in commands]
        self.assertIn(str(self.app / 'Contents/MacOS/mlx-workbench.debug.dylib'), paths)
        self.assertIn(str(self.app / 'Contents/MacOS/__preview.dylib'), paths)
        self.assertEqual(paths[-1], str(self.app))
        self.assertTrue(all(row[row.index('--sign') + 1] == 'a' * 40 for row in commands))

    def test_probe_is_refused_for_an_app_without_the_headless_protocol_marker(self):
        p = self.app / 'Contents/Info.plist'
        value = plistlib.loads(p.read_bytes())
        value.pop('MLXWorkbenchInstallationProbe')
        p.write_bytes(plistlib.dumps(value))
        with self.assertRaises(ValueError): module.probe(self.app)


if __name__ == '__main__': unittest.main()
