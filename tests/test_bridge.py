import json
import subprocess
import unittest
from unittest import mock
from pathlib import Path
from tempfile import TemporaryDirectory

from mlx_workbench import bridge


def envelope(status="ok", data=None, error=None):
    payload = {
        "schema_version": "1.0",
        "generated_at": "2026-07-28T00:00:00+00:00",
        "operation": "convert-scan",
        "status": status,
        "data": data or {},
        "warnings": [],
    }
    if error is not None:
        payload["error"] = error
    return json.dumps(payload)


class Recorder:
    """Stands in for the subprocess call and records the argv it was given."""

    def __init__(self, stdout="", stderr="", returncode=0, raises=None):
        self.stdout = stdout
        self.stderr = stderr
        self.returncode = returncode
        self.raises = raises
        self.commands = []

    def __call__(self, command, timeout):
        self.commands.append(command)
        if self.raises is not None:
            raise self.raises
        return {"returncode": self.returncode, "stdout": self.stdout, "stderr": self.stderr}


class CliLocationTests(unittest.TestCase):
    def setUp(self):
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def _checkout(self):
        script = self.root / bridge.CLI_RELATIVE
        script.parent.mkdir(parents=True)
        script.write_text("", encoding="utf-8")
        return self.root

    def test_unconfigured_path(self):
        with self.assertRaises(bridge.BridgeError) as caught:
            bridge.cli_script("")
        self.assertEqual(caught.exception.code, "agent_not_configured")

    def test_missing_script(self):
        with self.assertRaises(bridge.BridgeError) as caught:
            bridge.cli_script(str(self.root))
        self.assertEqual(caught.exception.code, "agent_not_found")

    def test_found_script(self):
        self._checkout()
        self.assertTrue(str(bridge.cli_script(str(self.root))).endswith("mlx-agent"))

    def test_health_reports_missing_cli(self):
        health = bridge.agent_health(str(self.root))
        self.assertFalse(health["ok"])


class RunTests(unittest.TestCase):
    def setUp(self):
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        script = self.root / bridge.CLI_RELATIVE
        script.parent.mkdir(parents=True)
        script.write_text("", encoding="utf-8")

    def test_scan_builds_the_expected_argv(self):
        recorder = Recorder(stdout=envelope(data={"models": [], "totals": {"gguf": 0, "bytes": 0}}))
        result = bridge.scan(
            str(self.root),
            gguf_roots=["/a", "/b"],
            mlx_roots=["/c"],
            signatures=False,
            runner=recorder,
        )
        command = recorder.commands[0]
        self.assertEqual(command[1], str(self.root / bridge.CLI_RELATIVE))
        self.assertIn("convert", command)
        self.assertIn("scan", command)
        self.assertEqual(command.count("--gguf-root"), 2)
        self.assertIn("--mlx-root", command)
        self.assertIn("--no-signature", command)
        self.assertEqual(command[-1], "--json")
        self.assertEqual(result["totals"]["gguf"], 0)

    def test_scan_rejects_a_model_without_a_byte_count(self):
        recorder = Recorder(stdout=envelope(data={
            "models": [{"path": "/models/a.gguf", "name": "a.gguf"}],
            "totals": {"bytes": 1},
        }))

        with self.assertRaises(bridge.BridgeError) as caught:
            bridge.scan(str(self.root), runner=recorder)

        self.assertEqual(caught.exception.code, "scan_contract_invalid")

    def test_scan_rejects_a_model_without_required_identity_fields(self):
        for model in (
            {"name": "a.gguf", "bytes": 1},
            {"path": "/models/a.gguf", "bytes": 1},
            {"path": "", "name": "a.gguf", "bytes": 1},
        ):
            with self.subTest(model=model):
                recorder = Recorder(stdout=envelope(data={
                    "models": [model],
                    "totals": {"bytes": 1},
                }))

                with self.assertRaises(bridge.BridgeError) as caught:
                    bridge.scan(str(self.root), runner=recorder)

                self.assertEqual(caught.exception.code, "scan_contract_invalid")

    def test_duplicate_scan_reuses_strict_scan_contract_and_roots(self):
        recorder = Recorder(stdout=envelope(data={
            "models": [
                {"path": "/a/duplicate.gguf", "name": "duplicate.gguf", "bytes": 1},
                {"path": "/b/duplicate.gguf", "name": "duplicate.gguf", "bytes": 2},
            ],
            "totals": {"bytes": 3},
        }))

        result = bridge.scan_duplicates(
            str(self.root),
            gguf_roots=["/a", "/b"],
            mlx_roots=["/out"],
            runner=recorder,
        )

        self.assertEqual(result["duplicates"][0]["files"], ["/a/duplicate.gguf", "/b/duplicate.gguf"])
        self.assertEqual(recorder.commands[0].count("--gguf-root"), 2)
        self.assertIn("--mlx-root", recorder.commands[0])

    def test_duplicate_scan_rejects_malformed_inventory(self):
        recorder = Recorder(stdout=envelope(data={
            "models": [{"path": "/models/a.gguf", "name": "a.gguf"}],
            "totals": {"bytes": 1},
        }))

        with self.assertRaises(bridge.BridgeError) as caught:
            bridge.scan_duplicates(str(self.root), runner=recorder)

        self.assertEqual(caught.exception.code, "scan_contract_invalid")

    def test_sloth_connect_rejects_malformed_inventory(self):
        response = mock.MagicMock()
        response.read.return_value = b'{"status":"ok"}'
        malformed_scan = envelope(data={
            "models": [{"path": "/models/a.gguf", "name": "a.gguf"}],
            "totals": {"bytes": 1},
        })
        with mock.patch("urllib.request.urlopen") as urlopen, mock.patch.object(
            bridge,
            "_default_runner",
            return_value={"returncode": 0, "stdout": malformed_scan, "stderr": ""},
        ):
            urlopen.return_value.__enter__.return_value = response
            with self.assertRaises(bridge.BridgeError) as caught:
                bridge.sloth_connect(str(self.root), address="http://sloth.test")

        self.assertEqual(caught.exception.code, "scan_contract_invalid")

    def test_scan_rejects_missing_model_inventory_and_totals_bytes(self):
        for payload in (
            {"totals": {"bytes": 0}},
            {"models": []},
        ):
            with self.subTest(payload=payload):
                recorder = Recorder(stdout=envelope(data=payload))

                with self.assertRaises(bridge.BridgeError) as caught:
                    bridge.scan(str(self.root), runner=recorder)

                self.assertEqual(caught.exception.code, "scan_contract_invalid")

    def test_scan_preserves_a_large_model_byte_count(self):
        recorder = Recorder(stdout=envelope(data={
            "models": [{"path": "/models/a.gguf", "name": "a.gguf", "bytes": 29_047_084_448}],
            "totals": {"bytes": 29_047_084_448},
        }))

        result = bridge.scan(str(self.root), runner=recorder)

        self.assertEqual(result["models"][0]["bytes"], 29_047_084_448)

    def test_model_architecture_scans_the_selected_models_parent(self):
        models = self.root / "models"
        models.mkdir()
        model = models / "qwen.gguf"
        model.write_bytes(b"weights")
        recorder = Recorder(stdout=envelope(data={
            "models": [{
                "path": str(model),
                "name": "qwen.gguf",
                "bytes": 2048,
                "architecture": "qwen35",
                "quantization": "Q8_0",
                "tensor_count": 866,
            }],
            "totals": {"bytes": 2048},
        }))

        result = bridge.model_architecture(str(self.root), str(model), runner=recorder)

        self.assertEqual(result["architecture"], {
            "model_path": str(model.resolve()),
            "name": "qwen.gguf",
            "bytes": 2048,
            "architecture": "qwen35",
            "quantization": "Q8_0",
            "tensor_count": 866,
        })
        command = recorder.commands[0]
        self.assertIn("--gguf-root", command)
        self.assertIn(str(models.resolve()), command)
        self.assertNotIn("--path", command)

    def test_quant_profile_uses_convert_start_preview_contract(self):
        source = self.root / "qwen.gguf"
        source.write_bytes(b"weights")
        recorder = Recorder(stdout=envelope(data={"plan": {
            "q_bits": 4,
            "out": "qwen-MLX-4bit",
            "preview_hash": "a" * 64,
            "source": {"bytes": 2048},
            "argv": ["converter", "--q-bits", "4"],
        }}))

        result = bridge.quant_profile(
            str(self.root), str(source), ["mlx-4bit"], runner=recorder,
        )

        self.assertEqual(result["profiles"], [{
            "target": "MLX 4-bit",
            "q_bits": 4,
            "source_bytes": 2048,
            "output": "qwen-MLX-4bit",
            "preview_hash": "a" * 64,
            "command": ["converter", "--q-bits", "4"],
        }])
        command = recorder.commands[0]
        self.assertEqual(command[2:4], ["convert", "start"])
        self.assertIn("--gguf", command)
        self.assertIn(str(source), command)
        self.assertIn("--q-bits", command)
        self.assertNotIn("preview", command)

    def test_preview_does_not_confirm(self):
        recorder = Recorder(stdout=envelope(data={"plan": {"preview_hash": "a" * 64}}))
        bridge.preview(str(self.root), "/models/a.gguf", 8, "/out", runner=recorder)
        command = recorder.commands[0]
        self.assertEqual(command[2:4], ["convert", "start"])
        self.assertNotIn("--confirm", command)
        self.assertIn("8", command)
        self.assertIn("/out", command)

    def test_start_passes_the_reviewed_hash(self):
        recorder = Recorder(stdout=envelope(data={"receipt": {"pid": 1}}))
        bridge.start(str(self.root), "/models/a.gguf", "b" * 64, runner=recorder)
        command = recorder.commands[0]
        self.assertIn("--confirm", command)
        self.assertIn("b" * 64, command)

    def test_preview_repo_builds_argv(self):
        recorder = Recorder(stdout=envelope(data={"plan": {"preview_hash": "a" * 64}}))
        bridge.preview_repo(
            str(self.root), "org/Model", 8, "/out", hf_cache="/hf", runner=recorder,
        )
        command = recorder.commands[0]
        self.assertEqual(command[2:4], ["convert", "start"])
        self.assertIn("--repo", command)
        self.assertIn("org/Model", command)
        self.assertNotIn("--confirm", command)
        self.assertIn("--hf-cache", command)
        self.assertIn("/hf", command)
        self.assertIn("8", command)

    def test_start_repo_passes_hash(self):
        recorder = Recorder(stdout=envelope(data={"receipt": {"pid": 2}}))
        bridge.start_repo(str(self.root), "org/Model", "c" * 64, runner=recorder)
        command = recorder.commands[0]
        self.assertIn("--repo", command)
        self.assertIn("--confirm", command)
        self.assertIn("c" * 64, command)

    def test_convert_is_busy(self):
        recorder = Recorder(stdout=envelope(data={"jobs": [{"state": "running"}]}))
        self.assertTrue(bridge.convert_is_busy(str(self.root), runner=recorder))
        recorder = Recorder(stdout=envelope(data={"jobs": [{"state": "done"}]}))
        self.assertFalse(bridge.convert_is_busy(str(self.root), runner=recorder))

    def test_read_convert_receipts(self):
        receipt_path = self.root / "convert.json"
        receipt = {
            "preview_hash": "a" * 64,
            "source": {"kind": "gguf", "path": "/models/a.gguf"},
            "out": "/models/a-mlx",
            "q_bits": 4,
        }
        receipt_path.write_text(json.dumps(receipt), encoding="utf-8")

        loaded = bridge.read_convert_receipts([{"receipt": str(receipt_path)}])

        self.assertEqual(loaded, [receipt])

    def test_read_convert_receipts_rejects_unreadable_files(self):
        missing = self.root / "missing.json"
        invalid = self.root / "invalid.json"
        invalid.write_text("{bad-json", encoding="utf-8")
        oversized = self.root / "oversized.json"
        oversized.write_text("x" * 17, encoding="utf-8")
        cases = [
            ("missing", missing, 64, "receipt_missing"),
            ("invalid", invalid, 64, "receipt_unreadable"),
            ("oversized", oversized, 16, "receipt_too_large"),
        ]
        for name, path, max_bytes, code in cases:
            with self.subTest(name=name):
                with self.assertRaises(bridge.BridgeError) as raised:
                    bridge.read_convert_receipts(
                        [{"receipt": str(path)}], max_bytes=max_bytes,
                    )
                self.assertEqual(raised.exception.code, code)

    def test_convert_progress_heuristics(self):
        progress = bridge.convert_progress("hello\nLoading weights…\n")
        self.assertEqual(progress["summary"], "Loading")
        self.assertIn("Loading", progress["last_line"])
        progress = bridge.convert_progress("step 40%")
        self.assertIn("%", progress["summary"])

    def test_discover_builds_argv(self):
        recorder = Recorder(stdout=envelope(data={"roles": {}}))
        bridge.discover(str(self.root), role="coding", limit=3, fast=True, runner=recorder)
        command = recorder.commands[0]
        self.assertIn("discover", command)
        self.assertIn("--role", command)
        self.assertIn("coding", command)
        self.assertIn("--fast", command)
        self.assertIn("3", command)

    def test_prune_and_train_build_argv(self):
        recorder = Recorder(stdout=envelope(data={"plan": {"preview_hash": "a" * 64}}))
        bridge.doctor_prune_preview(str(self.root), runner=recorder)
        self.assertIn("--prune", recorder.commands[-1])
        bridge.adopt_start(str(self.root), role="coding", runner=recorder)
        self.assertEqual(recorder.commands[-1][2:4], ["adopt", "start"])
        bridge.wire_preview(str(self.root), "org/m", "/cfg.json", runner=recorder)
        self.assertIn("wire", recorder.commands[-1])
        bridge.lora_preview(str(self.root), "org/m", "/data", iters=5, runner=recorder)
        self.assertIn("lora", recorder.commands[-1])
        bridge.fuse_preview(str(self.root), "org/m", "/adapter", runner=recorder)
        self.assertIn("fuse", recorder.commands[-1])

    def test_run_cli_rejects_shell_strings(self):
        with self.assertRaises(bridge.BridgeError) as caught:
            bridge.run_cli(str(self.root), [])
        self.assertEqual(caught.exception.code, "invalid_argv")

    def test_error_envelope_becomes_bridge_error(self):
        recorder = Recorder(stdout=envelope(
            status="error",
            error={"code": "source_not_found", "message": "gone", "remediation": "rescan"},
        ))
        with self.assertRaises(bridge.BridgeError) as caught:
            bridge.scan(str(self.root), runner=recorder)
        self.assertEqual(caught.exception.code, "source_not_found")
        self.assertEqual(caught.exception.to_dict()["remediation"], "rescan")

    def test_non_json_output(self):
        recorder = Recorder(stdout="Traceback (most recent call last):", stderr="boom")
        with self.assertRaises(bridge.BridgeError) as caught:
            bridge.scan(str(self.root), runner=recorder)
        self.assertEqual(caught.exception.code, "skill_output_unreadable")

    def test_unexpected_payload(self):
        recorder = Recorder(stdout=json.dumps([1, 2, 3]))
        with self.assertRaises(bridge.BridgeError) as caught:
            bridge.scan(str(self.root), runner=recorder)
        self.assertEqual(caught.exception.code, "skill_output_unreadable")

    def test_timeout(self):
        recorder = Recorder(raises=subprocess.TimeoutExpired(cmd="x", timeout=1))
        with self.assertRaises(bridge.BridgeError) as caught:
            bridge.scan(str(self.root), runner=recorder)
        self.assertEqual(caught.exception.code, "skill_timeout")

    def test_oversized_output(self):
        recorder = Recorder(stdout="x" * (bridge.MAX_OUTPUT_BYTES + 1))
        with self.assertRaises(bridge.BridgeError) as caught:
            bridge.scan(str(self.root), runner=recorder)
        self.assertEqual(caught.exception.code, "skill_output_too_large")

    def test_read_log_requires_allowlisted_path(self):
        log = self.root / "job.log"
        log.write_text("hello\n", encoding="utf-8")
        recorder = Recorder(stdout=envelope(data={"jobs": []}))
        with self.assertRaises(bridge.BridgeError) as caught:
            bridge.read_log(str(self.root), str(log), runner=recorder)
        self.assertEqual(caught.exception.code, "log_forbidden")

    def test_read_log_tails_allowlisted_file(self):
        log = self.root / "job.log"
        log.write_text("phase one\n", encoding="utf-8")
        recorder = Recorder(stdout=envelope(data={
            "jobs": [{"log_path": str(log)}],
        }))
        # serve_status also called; return empty servers
        def dual(command, timeout):
            recorder.commands.append(command)
            if "serve" in command:
                return {
                    "returncode": 0,
                    "stdout": envelope(data={"servers": []}),
                    "stderr": "",
                }
            return {
                "returncode": 0,
                "stdout": envelope(data={"jobs": [{"log_path": str(log)}]}),
                "stderr": "",
            }

        result = bridge.read_log(str(self.root), str(log), runner=dual)
        self.assertIn("phase one", result["text"])


if __name__ == "__main__":
    unittest.main()
