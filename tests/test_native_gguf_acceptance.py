import json
import os
import subprocess
import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory


ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "scripts" / "native_gguf_acceptance.py"


class NativeGGUFAcceptanceContractTests(unittest.TestCase):
    def _runtime_fixture(self, root: Path, *, host: str = "127.0.0.1") -> Path:
        models = root / "models"
        models.mkdir()
        source = models / "fixture-Q4_K_M.gguf"
        source.write_bytes(b"test fixture; never converted")

        agent_home = root / "mlx-agent"
        agent_cli = agent_home / "scripts" / "mlx-agent"
        agent_cli.parent.mkdir(parents=True)
        agent_cli.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        agent_cli.chmod(0o755)

        config_path = root / "config.json"
        config_path.write_text(
            json.dumps({"gguf_roots": [str(models)], "host": host}),
            encoding="utf-8",
        )
        manifest_path = root / "runtime.json"
        manifest_path.write_text(
            json.dumps(
                {
                    "source_path": str(source),
                    "model_query": "fixture-Q4_K_M",
                    "agent_home": str(agent_home),
                    "config_path": str(config_path),
                    "evidence_root": str(root / "evidence"),
                }
            ),
            encoding="utf-8",
        )
        return manifest_path

    def _fake_xcodebuild(self, root: Path, *, exit_code: int = 0) -> tuple[Path, Path, Path]:
        bin_dir = root / "bin"
        bin_dir.mkdir()
        args_path = root / "xcodebuild-args.json"
        env_path = root / "xcodebuild-env.json"
        executable = bin_dir / "xcodebuild"
        executable.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, pathlib, sys\n"
            f"pathlib.Path({str(args_path)!r}).write_text(json.dumps(sys.argv[1:]))\n"
            f"pathlib.Path({str(env_path)!r}).write_text(json.dumps({{'manifest': os.environ.get('TASK6_RUNTIME_MANIFEST'), 'evidence': os.environ.get('TASK6_EVIDENCE_DIR')}}))\n"
            "args = sys.argv[1:]\n"
            "if '-resultBundlePath' in args:\n"
            "    pathlib.Path(args[args.index('-resultBundlePath') + 1]).mkdir(parents=True)\n"
            "print('fake xcodebuild: no UI or conversion executed')\n"
            f"raise SystemExit({exit_code})\n",
            encoding="utf-8",
        )
        executable.chmod(0o755)
        return bin_dir, args_path, env_path

    def test_make_target_requires_an_explicit_manifest(self):
        result = subprocess.run(
            ["make", "accept-native-gguf"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=10,
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn(
            "RUNTIME_MANIFEST is required and must be an absolute path",
            result.stdout + result.stderr,
        )

    def test_make_target_rejects_a_relative_manifest_path(self):
        result = subprocess.run(
            ["make", "accept-native-gguf", "RUNTIME_MANIFEST=runtime.json"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=10,
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn(
            "RUNTIME_MANIFEST is required and must be an absolute path",
            result.stdout + result.stderr,
        )

    def test_manifest_rejects_missing_required_values(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = root / "runtime.json"
            manifest.write_text(json.dumps({"source_path": "/tmp/model.gguf"}), encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(RUNNER), "--manifest", str(manifest)],
                cwd=ROOT,
                capture_output=True,
                text=True,
                timeout=10,
            )

        self.assertEqual(result.returncode, 2)
        self.assertIn("manifest-invalid: missing required keys:", result.stderr)
        self.assertIn("model_query", result.stderr)

    def test_manifest_rejects_a_non_loopback_runtime_config(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = self._runtime_fixture(root, host="0.0.0.0")
            result = subprocess.run(
                [sys.executable, str(RUNNER), "--manifest", str(manifest)],
                cwd=ROOT,
                capture_output=True,
                text=True,
                timeout=10,
            )

        self.assertEqual(result.returncode, 2)
        self.assertIn("manifest-invalid: config host must be loopback-only", result.stderr)

    def test_manifest_rejects_an_unexpanded_xcode_placeholder(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = self._runtime_fixture(root)
            values = json.loads(manifest.read_text(encoding="utf-8"))
            values["model_query"] = "$(MODEL_QUERY)"
            manifest.write_text(json.dumps(values), encoding="utf-8")
            bin_dir, args_path, _ = self._fake_xcodebuild(root)
            environment = dict(os.environ)
            environment["PATH"] = f"{bin_dir}:{environment['PATH']}"

            result = subprocess.run(
                [sys.executable, str(RUNNER), "--manifest", str(manifest)],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
                timeout=10,
            )

        self.assertEqual(result.returncode, 2)
        self.assertIn("manifest-invalid: model_query contains an unexpanded placeholder", result.stderr)
        self.assertFalse(args_path.exists(), "invalid manifest must not launch xcodebuild")

    def test_manifest_rejects_a_source_outside_configured_roots(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = self._runtime_fixture(root)
            config_path = root / "config.json"
            config_path.write_text(
                json.dumps({"gguf_roots": [str(root / "other-models")], "host": "127.0.0.1"}),
                encoding="utf-8",
            )
            bin_dir, args_path, _ = self._fake_xcodebuild(root)
            environment = dict(os.environ)
            environment["PATH"] = f"{bin_dir}:{environment['PATH']}"

            result = subprocess.run(
                [sys.executable, str(RUNNER), "--manifest", str(manifest)],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
                timeout=10,
            )

        self.assertEqual(result.returncode, 2)
        self.assertIn("source_path must be inside an explicitly configured gguf_roots entry", result.stderr)
        self.assertFalse(args_path.exists(), "out-of-root source must not launch xcodebuild")

    def test_manifest_rejects_evidence_inside_a_model_root(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = self._runtime_fixture(root)
            values = json.loads(manifest.read_text(encoding="utf-8"))
            values["evidence_root"] = str(root / "models" / "acceptance-evidence")
            manifest.write_text(json.dumps(values), encoding="utf-8")
            bin_dir, args_path, _ = self._fake_xcodebuild(root)
            environment = dict(os.environ)
            environment["PATH"] = f"{bin_dir}:{environment['PATH']}"

            result = subprocess.run(
                [sys.executable, str(RUNNER), "--manifest", str(manifest)],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
                timeout=10,
            )

        self.assertEqual(result.returncode, 2)
        self.assertIn("evidence_root must be outside configured gguf_roots", result.stderr)
        self.assertFalse(args_path.exists(), "in-root evidence destination must not launch xcodebuild")

    def test_manifest_rejects_a_configured_agent_that_differs_from_agent_home(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = self._runtime_fixture(root)
            config_path = root / "config.json"
            config = json.loads(config_path.read_text(encoding="utf-8"))
            config["mlx_agent_path"] = str(root / "different-agent")
            config_path.write_text(json.dumps(config), encoding="utf-8")
            bin_dir, args_path, _ = self._fake_xcodebuild(root)
            environment = dict(os.environ)
            environment["PATH"] = f"{bin_dir}:{environment['PATH']}"

            result = subprocess.run(
                [sys.executable, str(RUNNER), "--manifest", str(manifest)],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
                timeout=10,
            )

        self.assertEqual(result.returncode, 2)
        self.assertIn("config mlx_agent_path must match manifest agent_home", result.stderr)
        self.assertFalse(args_path.exists(), "agent identity mismatch must not launch xcodebuild")

    def test_unusable_evidence_root_is_classified_as_manifest_invalid(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = self._runtime_fixture(root)
            values = json.loads(manifest.read_text(encoding="utf-8"))
            evidence_file = root / "not-a-directory"
            evidence_file.write_text("occupied", encoding="utf-8")
            values["evidence_root"] = str(evidence_file)
            manifest.write_text(json.dumps(values), encoding="utf-8")

            result = subprocess.run(
                [sys.executable, str(RUNNER), "--manifest", str(manifest)],
                cwd=ROOT,
                capture_output=True,
                text=True,
                timeout=10,
            )

        self.assertEqual(result.returncode, 2)
        self.assertIn("manifest-invalid: cannot create evidence_root", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_make_target_runs_only_the_real_data_test_and_emits_evidence(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = self._runtime_fixture(root)
            bin_dir, args_path, env_path = self._fake_xcodebuild(root)
            environment = dict(os.environ)
            environment["PATH"] = f"{bin_dir}:{environment['PATH']}"

            result = subprocess.run(
                [
                    "make",
                    "accept-native-gguf",
                    f"RUNTIME_MANIFEST={manifest}",
                    f"PYTHON={sys.executable}",
                ],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
                timeout=20,
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            arguments = json.loads(args_path.read_text(encoding="utf-8"))
            runtime_environment = json.loads(env_path.read_text(encoding="utf-8"))
            evidence = Path(runtime_environment["evidence"])
            outcome = json.loads((evidence / "outcome.json").read_text(encoding="utf-8"))

            self.assertEqual(runtime_environment["manifest"], str(manifest.resolve()))
            self.assertIn("mlx-workbench-real-data-e2e", arguments)
            self.assertIn(
                "-only-testing:mlx-workbenchUITests/GGUFToRunRealDataUITests/testRealGGUFToRunningMLXGoldenPath",
                arguments,
            )
            self.assertEqual(arguments[arguments.index("-resultBundlePath") + 1], str(evidence / "result.xcresult"))
            self.assertTrue((evidence / "xcodebuild.log").is_file())
            self.assertEqual(outcome["classification"], "passed")
            self.assertEqual(outcome["xcodebuild_exit_code"], 0)
            self.assertIn(f"evidence directory: {evidence}", result.stdout)

    def test_xcodebuild_failure_is_classified_in_the_evidence_directory(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = self._runtime_fixture(root)
            bin_dir, _, env_path = self._fake_xcodebuild(root, exit_code=65)
            environment = dict(os.environ)
            environment["PATH"] = f"{bin_dir}:{environment['PATH']}"

            result = subprocess.run(
                [sys.executable, str(RUNNER), "--manifest", str(manifest)],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
                timeout=20,
            )

            self.assertTrue(env_path.is_file(), result.stdout + result.stderr)
            runtime_environment = json.loads(env_path.read_text(encoding="utf-8"))
            evidence = Path(runtime_environment["evidence"])
            outcome = json.loads((evidence / "outcome.json").read_text(encoding="utf-8"))

        self.assertEqual(result.returncode, 4)
        self.assertEqual(outcome["classification"], "acceptance-failed")
        self.assertEqual(outcome["xcodebuild_exit_code"], 65)


if __name__ == "__main__":
    unittest.main()
