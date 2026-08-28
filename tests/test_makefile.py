import subprocess
import sys
import unittest
import os
import json
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

    def test_check_accepts_a_healthy_agent_from_the_configured_external_checkout(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            agent = root / "external-mlx-agent"
            script = agent / "scripts" / "mlx-agent"
            script.parent.mkdir(parents=True)
            script.write_text("", encoding="utf-8")
            config_path = root / "config.json"
            config_path.write_text(
                json.dumps({"mlx_agent_path": str(agent)}), encoding="utf-8"
            )
            environment = dict(os.environ)
            environment["MLX_WORKBENCH_CONFIG"] = str(config_path)

            result = subprocess.run(
                ["make", "check"],
                cwd=ROOT,
                capture_output=True,
                text=True,
                env=environment,
                timeout=10,
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("mlx-agent OK: {0}".format(agent), result.stdout)

    def test_agent_bootstrap_does_not_clone_when_configured_agent_is_healthy(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            agent = root / "external-mlx-agent"
            script = agent / "scripts" / "mlx-agent"
            script.parent.mkdir(parents=True)
            script.write_text("", encoding="utf-8")
            config_path = root / "config.json"
            config_path.write_text(
                json.dumps({"mlx_agent_path": str(agent)}), encoding="utf-8"
            )
            bin_dir = root / "bin"
            bin_dir.mkdir()
            fake_git = bin_dir / "git"
            fake_git.write_text("#!/bin/sh\nexit 93\n", encoding="utf-8")
            fake_git.chmod(0o755)
            environment = dict(os.environ)
            environment["MLX_WORKBENCH_CONFIG"] = str(config_path)
            environment["PATH"] = "{0}:{1}".format(bin_dir, environment["PATH"])

            result = subprocess.run(
                ["make", "agent-bootstrap"],
                cwd=ROOT,
                capture_output=True,
                text=True,
                env=environment,
                timeout=10,
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("mlx-agent already configured: {0}".format(agent), result.stdout)


if __name__ == "__main__":
    unittest.main()
