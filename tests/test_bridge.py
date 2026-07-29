import json
import subprocess
import unittest
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


class SkillLocationTests(unittest.TestCase):
    def setUp(self):
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def _checkout(self):
        script = self.root / bridge.SKILL_RELATIVE
        script.parent.mkdir(parents=True)
        script.write_text("", encoding="utf-8")
        return self.root

    def test_unconfigured_path(self):
        with self.assertRaises(bridge.BridgeError) as caught:
            bridge.skill_script("")
        self.assertEqual(caught.exception.code, "agent_not_configured")

    def test_missing_script(self):
        with self.assertRaises(bridge.BridgeError) as caught:
            bridge.skill_script(str(self.root))
        self.assertEqual(caught.exception.code, "agent_not_found")

    def test_found_script(self):
        self._checkout()
        self.assertTrue(str(bridge.skill_script(str(self.root))).endswith("mlx_converter.py"))


class RunTests(unittest.TestCase):
    def setUp(self):
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        script = self.root / bridge.SKILL_RELATIVE
        script.parent.mkdir(parents=True)
        script.write_text("", encoding="utf-8")

    def test_scan_builds_the_expected_argv(self):
        recorder = Recorder(stdout=envelope(data={"totals": {"gguf": 0}}))
        result = bridge.scan(
            str(self.root),
            gguf_roots=["/a", "/b"],
            mlx_roots=["/c"],
            signatures=False,
            runner=recorder,
        )
        command = recorder.commands[0]
        self.assertIn("scan", command)
        self.assertEqual(command.count("--gguf-root"), 2)
        self.assertIn("--mlx-root", command)
        self.assertIn("--no-signature", command)
        self.assertEqual(command[-1], "--json")
        self.assertEqual(result["totals"]["gguf"], 0)

    def test_preview_does_not_confirm(self):
        recorder = Recorder(stdout=envelope(data={"plan": {"preview_hash": "a" * 64}}))
        bridge.preview(str(self.root), "/models/a.gguf", 8, "/out", runner=recorder)
        command = recorder.commands[0]
        self.assertNotIn("--confirm", command)
        self.assertIn("8", command)
        self.assertIn("/out", command)

    def test_start_passes_the_reviewed_hash(self):
        recorder = Recorder(stdout=envelope(data={"receipt": {"pid": 1}}))
        bridge.start(str(self.root), "/models/a.gguf", "b" * 64, runner=recorder)
        command = recorder.commands[0]
        self.assertIn("--confirm", command)
        self.assertIn("b" * 64, command)

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


if __name__ == "__main__":
    unittest.main()
