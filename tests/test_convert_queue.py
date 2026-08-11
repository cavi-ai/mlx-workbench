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


class FailingStore:
    def __init__(self, items):
        self.items = [dict(item) for item in items]

    def load(self):
        return [dict(item) for item in self.items]

    def save(self, items):
        raise convert_queue.QueuePersistenceError(
            "queue_write_failed",
            "disk full",
            "Free disk space and retry.",
        )


class FailAfterSaveStore:
    def __init__(self, items, fail_on):
        self.items = [dict(item) for item in items]
        self.fail_on = fail_on
        self.saves = 0

    def load(self):
        return [dict(item) for item in self.items]

    def save(self, items):
        self.saves += 1
        if self.saves == self.fail_on:
            raise convert_queue.QueuePersistenceError(
                "queue_write_failed",
                "disk full",
                "Free disk space and retry.",
            )
        self.items = [dict(item) for item in items]


class ConvertQueueTests(unittest.TestCase):
    def setUp(self):
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        script = self.root / bridge.CLI_RELATIVE
        script.parent.mkdir(parents=True)
        script.write_text("", encoding="utf-8")
        self.queue = convert_queue.ConvertQueue()

    def test_queue_path_uses_explicit_config_directory(self):
        config = self.root / "profile" / "config.json"
        self.assertEqual(
            convert_queue.queue_path(config),
            config.with_name("convert-queue.json"),
        )

    def test_store_round_trip_is_schema_versioned(self):
        path = self.root / "state" / "convert-queue.json"
        store = convert_queue.QueueStore(path)
        items = [{
            "id": "cq-7",
            "kind": "repo",
            "preview_hash": "a" * 64,
            "q_bits": 4,
            "out": "/out",
            "path": None,
            "repo": "org/model",
            "hf_cache": "/hf",
            "label": "org/model",
            "state": "queued",
        }]
        store.save(items)
        self.assertEqual(store.load(), items)
        payload = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(payload["schema_version"], "1.0")

    def test_store_rejects_unknown_schema_and_invalid_items(self):
        valid_item = {
            "id": "cq-1",
            "kind": "gguf",
            "preview_hash": "a" * 64,
            "q_bits": 4,
            "out": "/out",
            "path": "/model.gguf",
            "repo": None,
            "hf_cache": None,
            "label": "model.gguf",
            "state": "queued",
        }
        both_sources = dict(valid_item, repo="org/model")
        unsupported_quantization = dict(valid_item, q_bits=3)
        cases = [
            ("schema", {"schema_version": "2.0", "items": [valid_item]}),
            ("sources", {"schema_version": "1.0", "items": [both_sources]}),
            ("quantization", {"schema_version": "1.0", "items": [unsupported_quantization]}),
        ]
        for name, payload in cases:
            with self.subTest(name=name):
                path = self.root / name / "convert-queue.json"
                path.parent.mkdir(parents=True)
                path.write_text(json.dumps(payload), encoding="utf-8")
                with self.assertRaises(convert_queue.QueuePersistenceError) as raised:
                    convert_queue.QueueStore(path).load()
                self.assertEqual(raised.exception.code, "queue_state_invalid")

    def test_store_preserves_malformed_state_as_corrupt(self):
        path = self.root / "bad" / "convert-queue.json"
        path.parent.mkdir(parents=True)
        path.write_text("{not-json", encoding="utf-8")

        with self.assertRaises(convert_queue.QueuePersistenceError) as raised:
            convert_queue.QueueStore(path).load()

        self.assertEqual(raised.exception.code, "queue_state_invalid")
        self.assertFalse(path.exists())
        preserved = list(path.parent.glob("convert-queue.json.*.corrupt"))
        self.assertEqual(len(preserved), 1)
        self.assertEqual(preserved[0].read_text(encoding="utf-8"), "{not-json")

    def test_store_classifies_write_failures(self):
        blocked_parent = self.root / "not-a-directory"
        blocked_parent.write_text("occupied", encoding="utf-8")
        item = {
            "id": "cq-1",
            "kind": "repo",
            "preview_hash": "a" * 64,
            "q_bits": 4,
            "out": None,
            "path": None,
            "repo": "org/model",
            "hf_cache": None,
            "label": "org/model",
            "state": "queued",
        }

        with self.assertRaises(convert_queue.QueuePersistenceError) as raised:
            convert_queue.QueueStore(blocked_parent / "convert-queue.json").save([item])

        self.assertEqual(raised.exception.code, "queue_write_failed")

    def test_restart_restores_items_and_advances_ids(self):
        path = self.root / "restart" / "convert-queue.json"
        items = [
            {
                "id": "cq-3",
                "kind": "gguf",
                "preview_hash": "a" * 64,
                "q_bits": 4,
                "out": "/out-a",
                "path": "/a.gguf",
                "repo": None,
                "hf_cache": None,
                "label": "a.gguf",
                "state": "queued",
            },
            {
                "id": "cq-9",
                "kind": "repo",
                "preview_hash": "b" * 64,
                "q_bits": 8,
                "out": "/out-b",
                "path": None,
                "repo": "org/model",
                "hf_cache": "/hf",
                "label": "org/model",
                "state": "queued",
            },
        ]
        convert_queue.QueueStore(path).save(items)

        restored = convert_queue.ConvertQueue(path=path)

        self.assertEqual(restored.snapshot(), items)
        added = restored.enqueue(
            "repo", "c" * 64, 4, repo="org/next", label="org/next",
        )
        self.assertEqual(added["id"], "cq-10")
        self.assertEqual(added["state"], "queued")

    def test_failed_mutations_leave_published_snapshot_unchanged(self):
        original = {
            "id": "cq-4",
            "kind": "gguf",
            "preview_hash": "a" * 64,
            "q_bits": 4,
            "out": "/out",
            "path": "/a.gguf",
            "repo": None,
            "hf_cache": None,
            "label": "a.gguf",
            "state": "queued",
        }

        enqueue_queue = convert_queue.ConvertQueue(store=FailingStore([original]))
        with self.assertRaises(convert_queue.QueuePersistenceError):
            enqueue_queue.enqueue("repo", "b" * 64, 4, repo="org/model")
        self.assertEqual(enqueue_queue.snapshot(), [original])

        cancel_queue = convert_queue.ConvertQueue(store=FailingStore([original]))
        with self.assertRaises(convert_queue.QueuePersistenceError):
            cancel_queue.cancel("cq-4")
        self.assertEqual(cancel_queue.snapshot(), [original])

        clear_queue = convert_queue.ConvertQueue(store=FailingStore([original]))
        with self.assertRaises(convert_queue.QueuePersistenceError):
            clear_queue.clear()
        self.assertEqual(clear_queue.snapshot(), [original])

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

    def test_try_start_next_rejects_non_list_job_status(self):
        self.queue.enqueue("gguf", "a" * 64, 4, path="/a.gguf", out="/out")
        commands = []

        def runner(command, timeout):
            commands.append(command)
            if "status" in command:
                return {
                    "returncode": 0,
                    "stdout": envelope(data={"jobs": "running"}),
                    "stderr": "",
                }
            raise AssertionError("unexpected command: {0}".format(command))

        with self.assertRaises(bridge.BridgeError) as raised:
            self.queue.try_start_next(str(self.root), runner=runner)

        self.assertEqual(raised.exception.code, "job_status_invalid")
        self.assertEqual(self.queue.snapshot(), [{
            "id": "cq-1",
            "kind": "gguf",
            "preview_hash": "a" * 64,
            "q_bits": 4,
            "out": "/out",
            "path": "/a.gguf",
            "repo": None,
            "hf_cache": None,
            "label": "/a.gguf",
            "state": "queued",
        }])
        self.assertEqual(len(commands), 1)
        self.assertIn("status", commands[0])

    def test_recovered_starting_item_rejects_non_list_job_status(self):
        state_path = self.root / "bad-status" / "convert-queue.json"
        item = {
            "id": "cq-1",
            "kind": "gguf",
            "preview_hash": "a" * 64,
            "q_bits": 4,
            "out": "/out",
            "path": "/a.gguf",
            "repo": None,
            "hf_cache": None,
            "label": "a.gguf",
            "state": "starting",
        }
        convert_queue.QueueStore(state_path).save([item])
        queue = convert_queue.ConvertQueue(path=state_path)
        commands = []

        def runner(command, timeout):
            commands.append(command)
            if "status" in command:
                return {
                    "returncode": 0,
                    "stdout": envelope(data={"jobs": {"state": "running"}}),
                    "stderr": "",
                }
            raise AssertionError("unexpected command: {0}".format(command))

        with self.assertRaises(bridge.BridgeError) as raised:
            queue.try_start_next(str(self.root), runner=runner)

        self.assertEqual(raised.exception.code, "job_status_invalid")
        self.assertEqual(queue.snapshot()[0]["state"], "starting")
        self.assertEqual(len(commands), 1)

    def test_start_persists_starting_before_confirm_and_removes_after_acceptance(self):
        state_path = self.root / "handoff" / "convert-queue.json"
        queue = convert_queue.ConvertQueue(path=state_path)
        queue.enqueue(
            "gguf", "a" * 64, 4, path="/a.gguf", out="/out", label="a.gguf",
        )
        observed_states = []
        commands = []

        def runner(command, timeout):
            commands.append(command)
            if "status" in command:
                return {
                    "returncode": 0,
                    "stdout": envelope(data={"jobs": []}),
                    "stderr": "",
                }
            if "--confirm" in command:
                observed_states.append(
                    convert_queue.QueueStore(state_path).load()[0]["state"]
                )
                return {
                    "returncode": 0,
                    "stdout": envelope(data={"status": "started", "receipt": {"pid": 9}}),
                    "stderr": "",
                }
            raise AssertionError("unexpected command: {0}".format(command))

        result = queue.try_start_next(str(self.root), runner=runner)

        self.assertEqual(result["status"], "started")
        self.assertEqual(observed_states, ["starting"])
        self.assertEqual(queue.snapshot(), [])
        self.assertEqual(convert_queue.QueueStore(state_path).load(), [])
        self.assertEqual(len([cmd for cmd in commands if "--confirm" in cmd]), 1)

    def test_accepted_start_reports_cleanup_failure_and_keeps_starting(self):
        item = {
            "id": "cq-1",
            "kind": "gguf",
            "preview_hash": "a" * 64,
            "q_bits": 4,
            "out": "/out",
            "path": "/a.gguf",
            "repo": None,
            "hf_cache": None,
            "label": "a.gguf",
            "state": "queued",
        }
        store = FailAfterSaveStore([item], fail_on=2)
        queue = convert_queue.ConvertQueue(store=store)
        runner = SequenceRunner([
            envelope(data={"jobs": []}),
            envelope(data={"status": "started", "receipt": {"pid": 9}}),
        ])

        result = queue.try_start_next(str(self.root), runner=runner)

        self.assertEqual(result["status"], "started")
        self.assertEqual(result["persistence_error"]["code"], "queue_write_failed")
        self.assertEqual(queue.snapshot()[0]["state"], "starting")

    def test_try_start_next_requeues_on_job_in_progress(self):
        state_path = self.root / "busy" / "convert-queue.json"
        queue = convert_queue.ConvertQueue(path=state_path)
        queue.enqueue("repo", "a" * 64, 4, repo="org/m")
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
        self.assertIsNone(queue.try_start_next(str(self.root), runner=runner))
        self.assertEqual(queue.snapshot()[0]["state"], "queued")
        self.assertEqual(
            convert_queue.QueueStore(state_path).load()[0]["state"],
            "queued",
        )

    def test_restored_starting_item_with_matching_receipt_is_recovered(self):
        state_path = self.root / "recover" / "convert-queue.json"
        receipt_path = self.root / "recover" / "receipt.json"
        item = {
            "id": "cq-2",
            "kind": "gguf",
            "preview_hash": "a" * 64,
            "q_bits": 4,
            "out": "/out",
            "path": "/a.gguf",
            "repo": None,
            "hf_cache": None,
            "label": "a.gguf",
            "state": "starting",
        }
        convert_queue.QueueStore(state_path).save([item])
        receipt_path.write_text(json.dumps({
            "preview_hash": "a" * 64,
            "source": {"kind": "gguf", "path": "/a.gguf"},
            "q_bits": 4,
            "out": "/out",
        }), encoding="utf-8")
        runner = SequenceRunner([
            envelope(data={"jobs": [{
                "state": "running", "receipt": str(receipt_path),
            }]}),
        ])
        queue = convert_queue.ConvertQueue(path=state_path)

        result = queue.try_start_next(str(self.root), runner=runner)

        self.assertEqual(result["status"], "recovered")
        self.assertEqual(queue.snapshot(), [])
        self.assertFalse(any("--confirm" in command for command in runner.commands))

    def test_restored_starting_item_without_receipt_starts_once(self):
        state_path = self.root / "retry" / "convert-queue.json"
        item = {
            "id": "cq-5",
            "kind": "repo",
            "preview_hash": "b" * 64,
            "q_bits": 8,
            "out": "/out",
            "path": None,
            "repo": "org/model",
            "hf_cache": "/hf",
            "label": "org/model",
            "state": "starting",
        }
        convert_queue.QueueStore(state_path).save([item])
        runner = SequenceRunner([
            envelope(data={"jobs": []}),
            envelope(data={"status": "started", "receipt": {"pid": 9}}),
        ])
        queue = convert_queue.ConvertQueue(path=state_path)

        result = queue.try_start_next(str(self.root), runner=runner)

        self.assertEqual(result["status"], "started")
        starts = [command for command in runner.commands if "--confirm" in command]
        self.assertEqual(len(starts), 1)
        self.assertEqual(queue.snapshot(), [])

    def test_unreadable_receipt_keeps_starting_item_for_recovery(self):
        state_path = self.root / "unreadable" / "convert-queue.json"
        receipt_path = self.root / "unreadable" / "receipt.json"
        item = {
            "id": "cq-8",
            "kind": "repo",
            "preview_hash": "c" * 64,
            "q_bits": 4,
            "out": "/out",
            "path": None,
            "repo": "org/model",
            "hf_cache": None,
            "label": "org/model",
            "state": "starting",
        }
        convert_queue.QueueStore(state_path).save([item])
        receipt_path.write_text("{bad-json", encoding="utf-8")
        runner = SequenceRunner([
            envelope(data={"jobs": [{
                "state": "running", "receipt": str(receipt_path),
            }]}),
        ])
        queue = convert_queue.ConvertQueue(path=state_path)

        result = queue.try_start_next(str(self.root), runner=runner)

        self.assertEqual(result["status"], "waiting_recovery")
        self.assertEqual(queue.snapshot()[0]["state"], "starting")
        self.assertEqual(
            convert_queue.QueueStore(state_path).load()[0]["state"],
            "starting",
        )

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
