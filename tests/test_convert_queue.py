import json
import threading
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from mlx_workbench import bridge, convert_queue


def envelope(status="ok", data=None, error=None):
    payload = {
        "schema_version": "1.0",
        "generated_at": "2026-07-28T00:00:00+00:00",
        "operation": "convert-status",
        "status": status,
        "data": data or {},
        "warnings": [],
    }
    if error is not None:
        payload["error"] = error
    return json.dumps(payload)


class SequenceRunner:
    def __init__(self, responses):
        self.responses = list(responses)
        self.commands = []

    def __call__(self, command, timeout):
        self.commands.append(command)
        if not self.responses:
            raise AssertionError("unexpected command: {0}".format(command))
        stdout = self.responses.pop(0)
        return {"returncode": 0, "stdout": stdout, "stderr": ""}


class RacingRunner:
    """Expose the idle-check race without launching a real process."""

    def __init__(self):
        self.commands = []
        self.lock = threading.Lock()
        self.first_status = threading.Event()
        self.release_first = threading.Event()
        self.status_calls = 0
        self.started = False

    def __call__(self, command, timeout):
        with self.lock:
            self.commands.append(command)
        if "convert" in command and "status" in command:
            with self.lock:
                self.status_calls += 1
                call = self.status_calls
                started = self.started
            if started:
                stdout = envelope(data={"jobs": [{"state": "running"}]})
            else:
                if call == 1:
                    self.first_status.set()
                    self.release_first.wait(1.0)
                else:
                    self.release_first.set()
                stdout = envelope(data={"jobs": []})
            return {"returncode": 0, "stdout": stdout, "stderr": ""}
        if "--confirm" in command:
            with self.lock:
                self.started = True
            stdout = envelope(data={"status": "started", "receipt": {"pid": 9}})
            return {"returncode": 0, "stdout": stdout, "stderr": ""}
        raise AssertionError("unexpected command: {0}".format(command))


class ConvertQueueTests(unittest.TestCase):
    def setUp(self):
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        script = self.root / bridge.CLI_RELATIVE
        script.parent.mkdir(parents=True)
        script.write_text("", encoding="utf-8")
        self.queue = convert_queue.ConvertQueue()

    def test_enqueue_cancel_clear(self):
        first = self.queue.enqueue(
            "gguf", "a" * 64, 4, path="/a.gguf", label="a.gguf",
        )
        second = self.queue.enqueue(
            "repo", "b" * 64, 8, repo="org/m", label="org/m",
        )
        self.assertEqual(len(self.queue.snapshot()), 2)
        self.assertTrue(self.queue.cancel(first["id"]))
        self.assertEqual(self.queue.snapshot()[0]["id"], second["id"])
        self.assertEqual(self.queue.clear(), 1)
        self.assertEqual(self.queue.snapshot(), [])

    def test_try_start_next_noops_when_busy(self):
        self.queue.enqueue("gguf", "a" * 64, 4, path="/a.gguf")
        runner = SequenceRunner([
            envelope(data={"jobs": [{"state": "running"}]}),
        ])
        self.assertIsNone(self.queue.try_start_next(str(self.root), runner=runner))
        self.assertEqual(len(self.queue.snapshot()), 1)
        self.assertEqual(len(runner.commands), 1)

    def test_try_start_next_starts_when_idle(self):
        self.queue.enqueue("gguf", "a" * 64, 4, path="/a.gguf", out="/out")
        runner = SequenceRunner([
            envelope(data={"jobs": []}),
            envelope(data={"status": "started", "receipt": {"pid": 9}}),
        ])
        result = self.queue.try_start_next(str(self.root), runner=runner)
        self.assertEqual(result["status"], "started")
        self.assertEqual(self.queue.snapshot(), [])
        start_cmd = runner.commands[1]
        self.assertIn("--confirm", start_cmd)
        self.assertIn("/a.gguf", start_cmd)

    def test_try_start_next_requeues_on_job_in_progress(self):
        self.queue.enqueue("repo", "a" * 64, 4, repo="org/m")
        runner = SequenceRunner([
            envelope(data={"jobs": []}),
            envelope(
                status="error",
                error={
                    "code": "job_in_progress",
                    "message": "busy",
                    "remediation": "wait",
                },
            ),
        ])
        self.assertIsNone(self.queue.try_start_next(str(self.root), runner=runner))
        self.assertEqual(len(self.queue.snapshot()), 1)

    def test_try_start_next_preserves_repo_hf_cache(self):
        self.queue.enqueue(
            "repo", "a" * 64, 4, repo="org/m", hf_cache="/custom/hf",
        )
        runner = SequenceRunner([
            envelope(data={"jobs": []}),
            envelope(data={"status": "started", "receipt": {"pid": 9}}),
        ])
        result = self.queue.try_start_next(str(self.root), runner=runner)
        self.assertEqual(result["status"], "started")
        self.assertIn("--hf-cache", runner.commands[1])
        self.assertIn("/custom/hf", runner.commands[1])

    def test_try_start_next_is_single_flight(self):
        self.queue.enqueue("gguf", "a" * 64, 4, path="/a.gguf")
        self.queue.enqueue("gguf", "b" * 64, 4, path="/b.gguf")
        runner = RacingRunner()
        results = []

        def drain():
            results.append(self.queue.try_start_next(str(self.root), runner=runner))

        first = threading.Thread(target=drain)
        second = threading.Thread(target=drain)
        first.start()
        self.assertTrue(runner.first_status.wait(1.0))
        second.start()
        first.join(3.0)
        second.join(3.0)
        self.assertFalse(first.is_alive())
        self.assertFalse(second.is_alive())

        starts = [command for command in runner.commands if "--confirm" in command]
        self.assertEqual(len(starts), 1)
        self.assertEqual(len(self.queue.snapshot()), 1)


if __name__ == "__main__":
    unittest.main()
