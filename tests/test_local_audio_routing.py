"""Exercise the native audio preference and prompt controls without opening an app."""
import platform
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


@unittest.skipUnless(platform.system() == 'Darwin' and shutil.which('swiftc'), 'Requires the installed macOS Swift compiler')
class LocalAudioRoutingTests(unittest.TestCase):
    def test_native_audio_preferences_and_purposes(self):
        root = Path(__file__).resolve().parents[1]
        services = root / 'mlx-mac/mlx-mac/Services'
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'audio-tests'
            sources = [services / name for name in ('LocalAudioRouting.swift', 'JSONStore.swift',
                       'JSONRecordStream.swift', 'WorkbenchStatePaths.swift')]
            build = subprocess.run(['swiftc', *map(str, sources),
                                    str(root / 'tests/fixtures/local_audio_routing.swift'), '-o', str(binary)],
                                   capture_output=True, text=True, timeout=120)
            self.assertEqual(build.returncode, 0, build.stderr)
            run = subprocess.run([str(binary), directory], capture_output=True, text=True, timeout=20)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
