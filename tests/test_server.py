import json
import threading
import unittest
import urllib.error
import urllib.parse
import urllib.request
import time
from pathlib import Path
from tempfile import TemporaryDirectory

from mlx_workbench import bridge, config, convert_queue, server


def envelope(status="ok", data=None, error=None, operation="convert-scan"):
    payload = {
        "schema_version": "1.0",
        "generated_at": "2026-07-28T00:00:00+00:00",
        "operation": operation,
        "status": status,
        "data": data or {},
        "warnings": [],
    }
    if error is not None:
        payload["error"] = error
    return json.dumps(payload)


class SignalingStore:
    def __init__(self, path):
        self.store = convert_queue.QueueStore(path)
        self.empty = threading.Event()

    def load(self):
        return self.store.load()

    def save(self, items):
        self.store.save(items)
        if not items:
            self.empty.set()


class ObservedStore:
    def __init__(self, path):
        self.store = convert_queue.QueueStore(path)
        self.snapshots = []
        self.two_items = threading.Event()

    def load(self):
        return self.store.load()

    def save(self, items):
        self.store.save(items)
        snapshot = [dict(item) for item in items]
        self.snapshots.append(snapshot)
        if len(snapshot) == 2:
            self.two_items.set()


class FailingSaveStore:
    def load(self):
        return []

    def save(self, items):
        raise convert_queue.QueuePersistenceError(
            "queue_write_failed",
            "disk full",
            "Free disk space and retry.",
        )


class ConversionWorkerTests(unittest.TestCase):
    def setUp(self):
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.agent = self.root / "mlx-agent"
        script = self.agent / bridge.CLI_RELATIVE
        script.parent.mkdir(parents=True)
        script.write_text("", encoding="utf-8")

    def test_worker_drains_persisted_queue_and_stops(self):
        store = SignalingStore(self.root / "convert-queue.json")
        queue = convert_queue.ConvertQueue(store=store)
        queue.enqueue(
            "gguf", "a" * 64, 4, path="/a.gguf", out="/out", label="a.gguf",
        )
        commands = []

        def runner(command, timeout):
            commands.append(command)
            if "status" in command:
                return {
                    "returncode": 0,
                    "stdout": envelope(data={"jobs": []}, operation="convert-status"),
                    "stderr": "",
                }
            if "--confirm" in command:
                return {
                    "returncode": 0,
                    "stdout": envelope(
                        data={"status": "started", "receipt": {"pid": 9}},
                        operation="convert-start",
                    ),
                    "stderr": "",
                }
            raise AssertionError("unexpected command: {0}".format(command))

        worker = server.ConversionWorker(
            queue, lambda: str(self.agent), runner=runner, interval=0.01,
        )
        self.addCleanup(worker.stop)
        worker.start()

        self.assertTrue(store.empty.wait(2.0))
        self.assertEqual(queue.snapshot(), [])
        self.assertEqual(worker.last_result["status"], "started")
        self.assertTrue(any("--confirm" in command for command in commands))

        worker.stop()
        self.assertFalse(worker._thread.is_alive())

    def test_server_worker_restores_and_launches_without_jobs_request(self):
        config_path = self.root / "profile" / "config.json"
        models = self.root / "models"
        models.mkdir()
        config.save({
            "gguf_roots": [str(models)],
            "mlx_agent_path": str(self.agent),
            "quarantine_dir": str(self.root / "hold"),
            "output_dir": str(self.root / "out"),
        }, config_path)
        state_path = self.root / "profile" / "convert-queue.json"
        persisted = convert_queue.ConvertQueue(path=state_path)
        persisted.enqueue(
            "repo", "b" * 64, 4, repo="org/model", out="/out", label="org/model",
        )
        started = threading.Event()
        commands = []

        def runner(command, timeout):
            commands.append(command)
            if "status" in command:
                return {
                    "returncode": 0,
                    "stdout": envelope(data={"jobs": []}, operation="convert-status"),
                    "stderr": "",
                }
            if "--confirm" in command:
                started.set()
                return {
                    "returncode": 0,
                    "stdout": envelope(
                        data={"status": "started", "receipt": {"pid": 10}},
                        operation="convert-start",
                    ),
                    "stderr": "",
                }
            raise AssertionError("unexpected command: {0}".format(command))

        httpd = server.build(
            "127.0.0.1",
            0,
            config_path=config_path,
            runner=runner,
            queue_path_override=state_path,
            worker_interval=0.01,
            start_worker=True,
        )
        self.addCleanup(httpd.server_close)

        self.assertTrue(started.wait(2.0))
        httpd.app.worker.stop()

        self.assertEqual(httpd.app.convert_queue.snapshot(), [])
        self.assertTrue(any("--confirm" in command for command in commands))
        httpd.server_close()
        self.assertFalse(httpd.app.worker._thread.is_alive())

    def test_worker_records_job_status_payload_error_and_keeps_item_queued(self):
        store = convert_queue.QueueStore(self.root / "convert-queue.json")
        queue = convert_queue.ConvertQueue(store=store)
        queue.enqueue("gguf", "a" * 64, 4, path="/a.gguf", out="/out")

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

        worker = server.ConversionWorker(
            queue,
            lambda: str(self.agent),
            runner=runner,
            interval=0.01,
        )
        self.addCleanup(worker.stop)
        worker.start()

        for _ in range(200):
            if worker.last_error is not None:
                break
            time.sleep(0.01)

        self.assertIsNotNone(worker.last_error)
        self.assertEqual(worker.last_error["code"], "job_status_invalid")
        self.assertEqual(worker.last_error["message"], "convert status did not return a job list.")
        self.assertEqual(queue.snapshot()[0]["state"], "queued")
        self.assertTrue(commands)
        self.assertIn("status", " ".join(commands[0]))


class ServerTests(unittest.TestCase):
    def setUp(self):
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.models = self.root / "models"
        self.models.mkdir()
        self.agent = self.root / "mlx-agent"
        script = self.agent / bridge.CLI_RELATIVE
        script.parent.mkdir(parents=True)
        script.write_text("", encoding="utf-8")

        self.config_path = self.root / "config.json"
        config.save({
            "gguf_roots": [str(self.models)],
            "mlx_agent_path": str(self.agent),
            "quarantine_dir": str(self.root / "hold"),
            "output_dir": str(self.root / "out"),
        }, self.config_path)

        self.commands = []
        self.convert_jobs = []
        self.responses = {"stdout": envelope(data={
            "models": [],
            "duplicates": [],
            "totals": {"gguf": 0, "bytes": 0},
        })}
        self.token = "test-token"
        self.httpd = server.build(
            "127.0.0.1",
            0,
            config_path=self.config_path,
            token=self.token,
            runner=self._runner,
            queue_path_override=self.root / "convert-queue.json",
            start_worker=False,
        )
        self.addCleanup(self.httpd.server_close)
        self.port = self.httpd.server_address[1]
        thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.httpd.shutdown)

    def _runner(self, command, timeout):
        self.commands.append(command)
        if "serve" in command and "status" in command:
            return {
                "returncode": 0,
                "stdout": envelope(data={"servers": []}, operation="serve-status"),
                "stderr": "",
            }
        if "lora" in command and "status" in command:
            return {
                "returncode": 0,
                "stdout": envelope(data={"jobs": []}, operation="lora-status"),
                "stderr": "",
            }
        if "fuse" in command and "status" in command:
            return {
                "returncode": 0,
                "stdout": envelope(data={"jobs": []}, operation="fuse-status"),
                "stderr": "",
            }
        if "convert" in command and "status" in command:
            jobs = self.convert_jobs
            return {
                "returncode": 0,
                "stdout": envelope(data={"jobs": jobs}, operation="convert-status"),
                "stderr": "",
            }
        return {"returncode": 0, "stdout": self.responses["stdout"], "stderr": ""}

    def _request(self, path, method="GET", body=None, token=None, headers=None):
        url = "http://127.0.0.1:{0}{1}".format(self.port, path)
        data = None if body is None else json.dumps(body).encode("utf-8")
        request = urllib.request.Request(url, data=data, method=method)
        if data is not None:
            request.add_header("Content-Type", "application/json")
        supplied = self.token if token is None else token
        if supplied:
            request.add_header(server.TOKEN_HEADER, supplied)
        for key, value in (headers or {}).items():
            request.add_header(key, value)
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return response.status, json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as error:
            with error:
                payload = error.read().decode("utf-8")
            try:
                return error.code, json.loads(payload)
            except ValueError:
                return error.code, payload

    def test_index_carries_the_token(self):
        url = "http://127.0.0.1:{0}/".format(self.port)
        with urllib.request.urlopen(url, timeout=10) as response:
            page = response.read().decode("utf-8")
        self.assertIn(self.token, page)
        self.assertNotIn("__MLX_TOKEN__", page)

    def test_api_requires_the_token(self):
        status, payload = self._request("/api/config", token="")
        self.assertEqual(status, 401)
        self.assertEqual(payload["error"]["code"], "unauthorized")

    def test_api_rejects_a_foreign_origin(self):
        status, payload = self._request(
            "/api/config", headers={"Origin": "http://evil.example"}
        )
        self.assertEqual(status, 403)
        self.assertEqual(payload["error"]["code"], "forbidden_origin")

    def test_config_includes_runtime_report(self):
        status, payload = self._request("/api/config")
        self.assertEqual(status, 200)
        self.assertIn("runtime", payload["data"])
        self.assertIn("convert", payload["data"]["runtime"])
        self.assertEqual(payload["data"]["runtime"]["install"], "make install")

    def test_invalid_config_is_classified(self):
        status, payload = self._request("/api/config", "POST", {"q_bits": 3})
        self.assertEqual(status, 400)
        self.assertEqual(payload["error"]["code"], "invalid_config")

    def test_scan_passes_configured_roots_to_the_cli(self):
        status, payload = self._request("/api/scan")
        self.assertEqual(status, 200)
        self.assertEqual(payload["data"]["totals"]["gguf"], 0)
        self.assertIn(str(self.models), self.commands[0])
        self.assertIn("convert", self.commands[0])
        self.assertIn("scan", self.commands[0])

    def test_scan_contract_failure_becomes_a_502(self):
        self.responses["stdout"] = envelope(data={
            "models": [{"path": "/models/a.gguf", "name": "a.gguf"}],
            "totals": {"bytes": 1},
        })

        status, payload = self._request("/api/scan")

        self.assertEqual(status, 502)
        self.assertEqual(payload["error"]["code"], "scan_contract_invalid")

    def test_duplicate_scan_contract_failure_becomes_a_502(self):
        self.responses["stdout"] = envelope(data={
            "models": [{"path": "/models/a.gguf", "name": "a.gguf"}],
            "totals": {"bytes": 1},
        })

        status, payload = self._request("/api/duplicates/scan", "POST", {})

        self.assertEqual(status, 502)
        self.assertEqual(payload["error"]["code"], "scan_contract_invalid")

    def test_duplicate_scan_passes_configured_roots_to_the_cli(self):
        status, payload = self._request("/api/duplicates/scan", "POST", {})

        self.assertEqual(status, 200)
        self.assertEqual(payload["data"]["total_models"], 0)
        self.assertIn(str(self.models), self.commands[0])

    def test_serve_metrics_route_does_not_pass_a_subprocess_runner(self):
        calls = []
        original = bridge.serve_metrics
        self.addCleanup(setattr, bridge, "serve_metrics", original)

        def metrics(agent_path, port, **kwargs):
            calls.append((agent_path, port, kwargs))
            return {"connected": False, "metrics": {}}

        bridge.serve_metrics = metrics
        status, payload = self._request("/api/serve/metrics", "POST", {"port": 8766})

        self.assertEqual(status, 200)
        self.assertFalse(payload["data"]["connected"])
        self.assertEqual(calls, [(str(self.agent), 8766, {})])

    def test_sloth_route_forwards_configured_roots_and_runner(self):
        calls = []
        original = bridge.sloth_connect
        self.addCleanup(setattr, bridge, "sloth_connect", original)

        def connect(agent_path, address, **kwargs):
            calls.append((agent_path, address, kwargs))
            return {"connected": True, "models_synced": 0}

        bridge.sloth_connect = connect
        status, payload = self._request(
            "/api/sloth/connect", "POST", {"address": "http://sloth.test"}
        )

        self.assertEqual(status, 200)
        self.assertTrue(payload["data"]["connected"])
        self.assertEqual(calls, [(
            str(self.agent),
            "http://sloth.test",
            {
                "gguf_roots": [str(self.models)],
                "mlx_roots": [],
                "runner": self._runner,
            },
        )])

    def test_model_architecture_route_forwards_the_subprocess_runner(self):
        calls = []
        original = bridge.model_architecture
        self.addCleanup(setattr, bridge, "model_architecture", original)

        def inspect(agent_path, path, **kwargs):
            calls.append((agent_path, path, kwargs))
            return {"architecture": {"name": "qwen.gguf"}}

        bridge.model_architecture = inspect
        path = str(self.models / "qwen.gguf")
        status, payload = self._request("/api/model/arch", "POST", {"path": path})

        self.assertEqual(status, 200)
        self.assertEqual(payload["data"]["architecture"]["name"], "qwen.gguf")
        self.assertEqual(calls, [(str(self.agent), path, {"runner": self._runner})])

    def test_quant_profile_route_forwards_the_subprocess_runner(self):
        calls = []
        original = bridge.quant_profile
        self.addCleanup(setattr, bridge, "quant_profile", original)

        def profile(agent_path, path, targets, **kwargs):
            calls.append((agent_path, path, targets, kwargs))
            return {"profiles": []}

        bridge.quant_profile = profile
        path = str(self.models / "qwen.gguf")
        status, payload = self._request(
            "/api/quant/profile", "POST", {"path": path, "targets": ["mlx-4bit"]}
        )

        self.assertEqual(status, 200)
        self.assertEqual(payload["data"], {"profiles": []})
        self.assertEqual(calls, [(
            str(self.agent), path, ["mlx-4bit"], {"runner": self._runner},
        )])

    def test_skill_failure_becomes_a_502(self):
        self.responses["stdout"] = envelope(
            status="error",
            error={"code": "no_scan_roots", "message": "none", "remediation": "add one"},
        )
        status, payload = self._request("/api/scan")
        self.assertEqual(status, 502)
        self.assertEqual(payload["error"]["code"], "no_scan_roots")

    def test_preview_defaults_the_output_path(self):
        self.responses["stdout"] = envelope(data={"plan": {"preview_hash": "a" * 64}})
        status, _ = self._request(
            "/api/convert/preview", "POST", {"path": str(self.models / "m-Q4_K_M.gguf")}
        )
        self.assertEqual(status, 200)
        command = self.commands[0]
        self.assertIn("--out", command)
        self.assertIn(str(self.root / "out" / "m-Q4_K_M-MLX-4bit"), command)
        self.assertNotIn("--confirm", command)

    def test_start_requires_a_preview_hash(self):
        status, payload = self._request(
            "/api/convert/start", "POST", {"path": str(self.models / "m-Q4_K_M.gguf")}
        )
        self.assertEqual(status, 400)
        self.assertEqual(payload["error"]["code"], "preview_required")

    def test_start_forwards_the_hash(self):
        self.responses["stdout"] = envelope(data={"receipt": {"pid": 5}})
        status, _ = self._request("/api/convert/start", "POST", {
            "path": str(self.models / "m-Q4_K_M.gguf"),
            "preview_hash": "c" * 64,
            "q_bits": 8,
        })
        self.assertEqual(status, 200)
        self.assertIn("--confirm", self.commands[-1])
        self.assertIn("c" * 64, self.commands[-1])

    def test_idle_start_is_persisted_before_confirm(self):
        state_path = self.root / "convert-queue.json"
        observed = []

        def runner(command, timeout):
            self.commands.append(command)
            if "status" in command:
                return {
                    "returncode": 0,
                    "stdout": envelope(data={"jobs": []}, operation="convert-status"),
                    "stderr": "",
                }
            if "--confirm" in command:
                observed.extend(convert_queue.QueueStore(state_path).load())
                return {
                    "returncode": 0,
                    "stdout": envelope(
                        data={"status": "started", "receipt": {"pid": 5}},
                        operation="convert-start",
                    ),
                    "stderr": "",
                }
            raise AssertionError("unexpected command: {0}".format(command))

        self.httpd.app.runner = runner
        status, payload = self._request("/api/convert/start", "POST", {
            "path": str(self.models / "durable.gguf"),
            "preview_hash": "a" * 64,
            "q_bits": 4,
        })

        self.assertEqual(status, 200)
        self.assertEqual(payload["data"]["status"], "started")
        self.assertEqual(len(observed), 1)
        self.assertEqual(observed[0]["state"], "starting")
        self.assertEqual(convert_queue.QueueStore(state_path).load(), [])

    def test_existing_queue_head_starts_before_new_submission(self):
        older = self.httpd.app.convert_queue.enqueue(
            "gguf", "a" * 64, 4, path="/older.gguf", out="/older-out",
            label="older.gguf",
        )
        self.responses["stdout"] = envelope(data={"receipt": {"pid": 5}})

        status, payload = self._request("/api/convert/start", "POST", {
            "path": str(self.models / "new.gguf"),
            "preview_hash": "b" * 64,
            "q_bits": 4,
        })

        self.assertEqual(status, 200)
        self.assertEqual(payload["data"]["status"], "queued")
        self.assertNotEqual(payload["data"]["item"]["id"], older["id"])
        starts = [command for command in self.commands if "--confirm" in command]
        self.assertEqual(len(starts), 1)
        self.assertIn("/older.gguf", starts[0])
        self.assertEqual(
            self.httpd.app.convert_queue.snapshot()[0]["id"],
            payload["data"]["item"]["id"],
        )

    def test_concurrent_confirmations_are_persisted_fifo_with_one_start(self):
        state_path = self.root / "convert-queue.json"
        store = ObservedStore(state_path)
        self.httpd.app.convert_queue = convert_queue.ConvertQueue(store=store)
        running = threading.Event()
        confirm_entered = threading.Event()
        commands = []
        lock = threading.Lock()

        def runner(command, timeout):
            with lock:
                commands.append(command)
            if "status" in command:
                jobs = [{"state": "running", "repo": "first"}] if running.is_set() else []
                return {
                    "returncode": 0,
                    "stdout": envelope(data={"jobs": jobs}, operation="convert-status"),
                    "stderr": "",
                }
            if "--confirm" in command:
                confirm_entered.set()
                if not store.two_items.wait(2.0):
                    raise AssertionError("second confirmation was not durably enqueued")
                running.set()
                return {
                    "returncode": 0,
                    "stdout": envelope(
                        data={"status": "started", "receipt": {"pid": 7}},
                        operation="convert-start",
                    ),
                    "stderr": "",
                }
            raise AssertionError("unexpected command: {0}".format(command))

        self.httpd.app.runner = runner
        responses = {}

        def submit(name, preview_hash):
            responses[name] = self._request("/api/convert/start", "POST", {
                "path": str(self.models / (name + ".gguf")),
                "preview_hash": preview_hash,
                "q_bits": 4,
            })

        first = threading.Thread(target=submit, args=("first", "c" * 64))
        second = threading.Thread(target=submit, args=("second", "d" * 64))
        first.start()
        self.assertTrue(confirm_entered.wait(2.0))
        second.start()
        first.join(5.0)
        second.join(5.0)

        self.assertFalse(first.is_alive())
        self.assertFalse(second.is_alive())
        starts = [command for command in commands if "--confirm" in command]
        self.assertEqual(len(starts), 1)
        two_item_snapshot = next(items for items in store.snapshots if len(items) == 2)
        self.assertEqual([item["state"] for item in two_item_snapshot], ["starting", "queued"])
        self.assertEqual(responses["first"][1]["data"]["status"], "started")
        self.assertEqual(responses["second"][1]["data"]["status"], "queued")
        remaining = self.httpd.app.convert_queue.snapshot()
        self.assertEqual(len(remaining), 1)
        self.assertIn("second.gguf", remaining[0]["path"])

    def test_preview_repo_uses_hf_cache_argv(self):
        self.responses["stdout"] = envelope(data={"plan": {"preview_hash": "a" * 64}})
        status, _ = self._request(
            "/api/convert/preview", "POST", {"repo": "org/Model", "q_bits": 4}
        )
        self.assertEqual(status, 200)
        command = self.commands[0]
        self.assertIn("--repo", command)
        self.assertIn("org/Model", command)
        self.assertIn("--out", command)
        self.assertNotIn("--confirm", command)

    def test_start_queues_when_convert_is_busy(self):
        self.convert_jobs = [{"state": "running", "repo": "busy"}]
        status, payload = self._request("/api/convert/start", "POST", {
            "path": str(self.models / "m-Q4_K_M.gguf"),
            "preview_hash": "d" * 64,
            "q_bits": 4,
        })
        self.assertEqual(status, 200)
        self.assertEqual(payload["data"]["status"], "queued")
        self.assertEqual(len(payload["data"]["queue"]), 1)
        self.assertTrue(any("status" in cmd for cmd in self.commands))
        self.assertFalse(any("--confirm" in cmd for cmd in self.commands))

    def test_start_queues_repo_hf_cache(self):
        self.convert_jobs = [{"state": "running", "repo": "busy"}]
        status, payload = self._request("/api/convert/start", "POST", {
            "repo": "org/Model",
            "hf_cache": "/custom/hf",
            "preview_hash": "d" * 64,
            "q_bits": 4,
        })
        self.assertEqual(status, 200)
        self.assertEqual(payload["data"]["status"], "queued")
        self.assertEqual(payload["data"]["item"]["hf_cache"], "/custom/hf")

    def test_jobs_includes_convert_queue(self):
        self.convert_jobs = [{"state": "running", "repo": "busy"}]
        self.httpd.app.convert_queue.enqueue(
            "gguf", "e" * 64, 4, path="/x.gguf", label="x.gguf",
        )
        status, payload = self._request("/api/jobs")
        self.assertEqual(status, 200)
        self.assertEqual(len(payload["data"]["convert_queue"]), 1)
        self.assertEqual(payload["data"]["convert_queue"][0]["label"], "x.gguf")

    def test_jobs_is_read_only_for_the_convert_queue(self):
        self.httpd.app.convert_queue.enqueue(
            "gguf", "e" * 64, 4, path="/waiting.gguf", label="waiting.gguf",
        )

        status, _ = self._request("/api/jobs")

        self.assertEqual(status, 200)
        convert_statuses = [
            command for command in self.commands
            if "convert" in command and "status" in command
        ]
        starts = [command for command in self.commands if "--confirm" in command]
        self.assertEqual(len(convert_statuses), 1)
        self.assertEqual(starts, [])

    def test_jobs_exposes_queue_and_worker_recovery_errors(self):
        state_path = self.root / "corrupt-queue.json"
        state_path.write_text("{bad-json", encoding="utf-8")
        self.httpd.app.convert_queue = convert_queue.ConvertQueue(path=state_path)
        self.httpd.app.convert_queue.last_error = {
            "status": "waiting_recovery",
            "error": {"code": "queue_write_failed"},
        }
        self.httpd.app.worker.last_result = {"status": "waiting_recovery"}

        status, payload = self._request("/api/jobs")

        self.assertEqual(status, 200)
        data = payload["data"]
        self.assertEqual(data["convert_queue_load_error"]["code"], "queue_state_invalid")
        self.assertEqual(data["convert_queue_error"]["error"]["code"], "queue_write_failed")
        self.assertEqual(data["convert_worker_result"]["status"], "waiting_recovery")

    def test_queue_persistence_failure_is_a_structured_500(self):
        self.httpd.app.convert_queue = convert_queue.ConvertQueue(store=FailingSaveStore())

        status, payload = self._request("/api/convert/start", "POST", {
            "repo": "org/model",
            "preview_hash": "f" * 64,
            "q_bits": 4,
        })

        self.assertEqual(status, 500)
        self.assertEqual(payload["error"]["code"], "queue_write_failed")

    def test_queue_cancel_and_clear(self):
        item = self.httpd.app.convert_queue.enqueue(
            "repo", "f" * 64, 4, repo="org/m", label="org/m",
        )
        status, payload = self._request(
            "/api/convert/queue/cancel", "POST", {"id": item["id"]}
        )
        self.assertEqual(status, 200)
        self.assertTrue(payload["data"]["removed"])
        self.httpd.app.convert_queue.enqueue(
            "repo", "g" * 64, 4, repo="org/n", label="org/n",
        )
        status, payload = self._request("/api/convert/queue/clear", "POST", {})
        self.assertEqual(status, 200)
        self.assertEqual(payload["data"]["cleared"], 1)
        self.assertEqual(payload["data"]["queue"], [])

    def test_cli_runs_argv(self):
        self.responses["stdout"] = envelope(data={"ok": True}, operation="discover")
        status, payload = self._request("/api/cli", "POST", {"argv": ["discover", "--fast"]})
        self.assertEqual(status, 200)
        self.assertTrue(payload["data"]["ok"])
        self.assertIn("discover", self.commands[0])
        self.assertIn("--fast", self.commands[0])

    def test_cli_rejects_empty_argv(self):
        status, payload = self._request("/api/cli", "POST", {"argv": []})
        self.assertEqual(status, 502)
        self.assertEqual(payload["error"]["code"], "invalid_argv")

    def test_jobs_log_rejects_unknown_path(self):
        status, payload = self._request(
            "/api/jobs/log?path=" + urllib.parse.quote(str(self.root / "nope.log"))
        )
        self.assertEqual(status, 502)
        self.assertEqual(payload["error"]["code"], "log_forbidden")

    def test_quarantine_moves_a_file_and_lists_it(self):
        source = self.models / "dupe-Q4_K_M.gguf"
        source.write_bytes(b"x" * 8)
        status, payload = self._request("/api/quarantine", "POST", {"path": str(source)})
        self.assertEqual(status, 200)
        self.assertFalse(source.exists())
        self.assertTrue(Path(payload["data"]["moved"]["to"]).is_file())
        status, payload = self._request("/api/quarantine")
        self.assertEqual(len(payload["data"]["records"]), 1)

    def test_quarantine_refuses_paths_outside_the_roots(self):
        outside = self.root / "loose-Q4_K_M.gguf"
        outside.write_bytes(b"x")
        status, payload = self._request("/api/quarantine", "POST", {"path": str(outside)})
        self.assertEqual(status, 400)
        self.assertEqual(payload["error"]["code"], "outside_roots")
        self.assertTrue(outside.exists())

    def test_unknown_route(self):
        status, _ = self._request("/api/nope")
        self.assertEqual(status, 404)


if __name__ == "__main__":
    unittest.main()
