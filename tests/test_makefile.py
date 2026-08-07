import subprocess
import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory


ROOT = Path(__file__).resolve().parents[1]


class MakefileStopTests(unittest.TestCase):
    def test_stop_does_not_kill_unowned_listener(self):
        script = (
            "import socket, time; "
            "sock = socket.socket(); "
            "sock.bind(('127.0.0.1', 0)); "
            "sock.listen(); "
            "print(sock.getsockname()[1], flush=True); "
            "time.sleep(30)"
        )
        listener = subprocess.Popen(
            [sys.executable, "-c", script],
            stdout=subprocess.PIPE,
            text=True,
        )
        try:
            port = int(listener.stdout.readline().strip())
            listener.stdout.close()
            with TemporaryDirectory() as run_dir:
                result = subprocess.run(
                    [
                        "make",
                        "stop",
                        "PORT={0}".format(port),
                        "RUN_DIR={0}".format(run_dir),
                    ],
                    cwd=ROOT,
                    capture_output=True,
                    text=True,
                    timeout=10,
                )
            self.assertIsNone(listener.poll())
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("refusing to stop unowned listener", result.stderr)
        finally:
            if listener.poll() is None:
                listener.terminate()
            listener.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
