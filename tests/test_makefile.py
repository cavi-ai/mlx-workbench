import subprocess
import sys
import unittest
import os
import json
from pathlib import Path
from tempfile import TemporaryDirectory


ROOT = Path(__file__).resolve().parents[1]


class MakefileStopTests(unittest.TestCase):

    def test_install_stops_after_environment_creation_failure(self):
        for executable in ("uv", "python3.12"):
            with self.subTest(executable=executable), TemporaryDirectory() as directory:
                root = Path(directory)
                bin_dir = root / "bin"
                bin_dir.mkdir()
                creator = bin_dir / executable
                creator.write_text(
                    "#!/bin/sh\necho 'Fixture environment creation failed' >&2\nexit 57\n",
                    encoding="utf-8",
                )
                creator.chmod(0o755)
                environment = dict(os.environ)
                environment["PATH"] = str(bin_dir) + os.pathsep + "/usr/bin:/bin"

                result = subprocess.run(
                    ["make", "install-convert", "VENV=" + str(root / "venv"),
                     "PYTHON=" + sys.executable],
                    cwd=ROOT, env=environment, capture_output=True, text=True, timeout=10,
                )

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Fixture environment creation failed", result.stderr)
                self.assertNotIn("venv created:", result.stdout)
                self.assertNotIn("Installing into", result.stdout)

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

    def test_install_and_audit_cover_the_agent_lab_requirements(self):
        lab = "-r vendor/mlx-agent/requirements-lab.txt"
        for target in ("_pkgs", "pip-audit"):
            result = subprocess.run(
                ["make", "-n", target, "VENV_PY=/nonexistent/python"],
                cwd=ROOT,
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(lab, result.stdout, target)


if __name__ == "__main__":
    unittest.main()
