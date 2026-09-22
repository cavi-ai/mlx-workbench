import json
import os
import signal
import subprocess
import sys
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from tempfile import TemporaryDirectory

from mlx_workbench import audit, bridge, config, convert_queue, quarantine, server
from mlx_workbench.atomicio import write_text_atomic


class ServerHeaderTests(unittest.TestCase):
    """P0-1: response hardening headers must be present and informative."""

    @classmethod
    def setUpClass(cls):
        cls.directory = TemporaryDirectory()
        cls.root = Path(cls.directory.name)
        config_path = cls.root / "config.json"
        config.save({
            "gguf_roots": [str(cls.root / "models")],
            "quarantine_dir": str(cls.root / "hold"),
            "output_dir": str(cls.root / "out"),
        }, config_path)
        cls.httpd = server.build(
            "127.0.0.1", 0, config_path=config_path, token="hardening",
            start_worker=False,
        )
        cls.port = cls.httpd.server_address[1]
        cls.thread = None
        import threading
        cls.thread = threading.Thread(target=cls.httpd.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.httpd.server_close()
        cls.directory.cleanup()

    def _get(self, path="/"):
        url = "http://127.0.0.1:{0}{1}".format(self.port, path)
        try:
            with urllib.request.urlopen(url, timeout=10) as response:
                return response.status, dict(response.headers)
        except urllib.error.HTTPError as error:
            with error:
                return error.code, dict(error.headers)

    def test_security_headers_are_complete(self):
        _, headers = self._get("/")
        policy = headers["Content-Security-Policy"]
        self.assertIn("frame-ancestors 'none'", policy)
        self.assertIn("form-action 'self'", policy)
        self.assertIn("base-uri 'none'", policy)
        self.assertIn("default-src 'none'", policy)
        self.assertEqual(headers["X-Frame-Options"], "DENY")

    def test_server_header_does_not_leak_python_version(self):
        _, headers = self._get("/")
        self.assertEqual(headers["Server"], "mlx-workbench")
        self.assertNotIn("Python", headers["Server"])


class RequestSlotTests(unittest.TestCase):
    """P0-3: more concurrent requests than slots must yield 503, not unbounded
    thread growth."""

    def setUp(self):
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.config_path = self.root / "config.json"
        config.save({
            "gguf_roots": [],
            "quarantine_dir": str(self.root / "hold"),
            "output_dir": str(self.root / "out"),
        }, self.config_path)

    def _build(self, slots):
        httpd = server.build(
            "127.0.0.1", 0, config_path=self.config_path, token="hardening",
            start_worker=False, request_slots=slots,
        )
        self.addCleanup(httpd.server_close)
        port = httpd.server_address[1]
        thread = None
        import threading
        thread = threading.Thread(target=httpd.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(httpd.shutdown)
        return httpd, port

    def _request_config(self, port, token="hardening"):
        url = "http://127.0.0.1:{0}/api/config".format(port)
        request = urllib.request.Request(url)
        request.add_header(server.TOKEN_HEADER, token)
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return response.status
        except urllib.error.HTTPError as error:
            with error:
                error.read()
            return error.code

    def test_exhausted_slots_return_503(self):
        httpd, port = self._build(slots=1)
        # Take the only slot without releasing it.
        self.assertTrue(httpd.app.request_slots.acquire(blocking=False))
        self.addCleanup(httpd.app.request_slots.release)

        self.assertEqual(self._request_config(port), 503)

    def test_slots_are_released_after_a_request(self):
        _, port = self._build(slots=1)
        self.assertEqual(self._request_config(port), 200)
        self.assertEqual(self._request_config(port), 200)


class AtomicWriteTests(unittest.TestCase):
    """P0-2: durable atomic writes; P1-6: symlink refusal at the primitives."""

    def setUp(self):
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def test_write_is_fsynced_and_replaces_atomically(self):
        target = self.root / "state" / "file.json"
        write_text_atomic(target, "{\"a\": 1}\n")
        self.assertEqual(target.read_text(encoding="utf-8"), "{\"a\": 1}\n")
        self.assertFalse(target.with_name(target.name + ".tmp").exists())

    def test_symlink_at_target_is_refused(self):
        victim = self.root / "victim.txt"
        victim.write_text("keep me", encoding="utf-8")
        target = self.root / "link.txt"
        os.symlink(victim, target)
        with self.assertRaises(OSError):
            write_text_atomic(target, "overwritten")
        self.assertEqual(victim.read_text(encoding="utf-8"), "keep me")

    def test_symlink_at_temp_path_cannot_redirect_write(self):
        victim = self.root / "victim.txt"
        victim.write_text("keep me", encoding="utf-8")
        target = self.root / "state.json"
        os.symlink(victim, target.with_name(target.name + ".tmp"))
        with self.assertRaises(OSError):
            write_text_atomic(target, "overwritten")
        self.assertEqual(victim.read_text(encoding="utf-8"), "keep me")

    def test_config_save_refuses_symlink_target(self):
        real = self.root / "real.json"
        real.write_text("{}", encoding="utf-8")
        link = self.root / "config.json"
        os.symlink(real, link)
        with self.assertRaises(config.ConfigError):
            config.save({"port": 8765}, link)
        self.assertEqual(json.loads(real.read_text(encoding="utf-8")), {})

    def test_config_save_still_round_trips(self):
        location = self.root / "nested" / "config.json"
        saved = config.save({"port": 9100}, location)
        self.assertEqual(saved["port"], 9100)
        self.assertEqual(config.load(location)["port"], 9100)

    def test_queue_save_refuses_symlink_target(self):
        victim = self.root / "victim.json"
        victim.write_text("{}", encoding="utf-8")
        link = self.root / "convert-queue.json"
        os.symlink(victim, link)
        store = convert_queue.QueueStore(link)
        with self.assertRaises(convert_queue.QueuePersistenceError) as caught:
            store.save([])
        self.assertEqual(caught.exception.code, "queue_write_failed")
        self.assertEqual(victim.read_text(encoding="utf-8"), "{}")

    def test_queue_store_round_trip_unchanged(self):
        store = convert_queue.QueueStore(self.root / "convert-queue.json")
        store.save([{
            "id": "cq-1", "kind": "repo", "preview_hash": "h", "q_bits": 4,
            "out": None, "path": None, "repo": "org/m", "hf_cache": None,
            "label": "org/m", "state": "queued", "failure": None,
        }])
        self.assertEqual(len(store.load()), 1)

    def test_queue_survives_simulated_truncated_tmp(self):
        # The old failure mode: a partial temp file would have been renamed
        # over the real state on power loss. fsync-before-replace closes it.
        store = convert_queue.QueueStore(self.root / "q.json")
        store.save([])
        self.assertEqual(store.load(), [])


class RunnerHardeningTests(unittest.TestCase):
    """P1-4 / P1-5: process-group timeout kills and the env allowlist."""

    def test_timeout_kills_the_whole_process_group(self):
        # A parent that forks a never-exiting grandchild; the classic leak
        # this guard exists for. Total runtime stays bounded (~2s).
        command = [
            sys.executable, "-c",
            "import os, sys, time\n"
            "child = os.fork()\n"
            "if child == 0:\n"
            "    time.sleep(600)\n"
            "    os._exit(0)\n"
            "sys.stdout.write(str(child))\n"
            "sys.stdout.flush()\n"
            "time.sleep(600)\n",
        ]
        started = time.monotonic()
        with self.assertRaises(bridge.BridgeError) as caught:
            bridge._default_runner(command, timeout=1.5)
        elapsed = time.monotonic() - started
        self.assertEqual(caught.exception.code, "skill_timeout")
        self.assertLess(elapsed, 15.0)

    def test_environment_allowlist_drops_unlisted_variables(self):
        base = {
            "PATH": "/usr/bin",
            "HOME": "/home/tester",
            "MLX_AGENT_SECRET_TOKEN": "do-not-propagate",
            "SOME_RANDOM_VAR": "nope",
            "HF_HUB_OFFLINE": "1",
        }
        environment = bridge.agent_environment(base)
        self.assertNotIn("MLX_AGENT_SECRET_TOKEN", environment)
        self.assertNotIn("SOME_RANDOM_VAR", environment)
        self.assertEqual(environment["HF_HUB_OFFLINE"], "1")
        self.assertEqual(environment["HOME"], "/home/tester")
        # Interpreter bin dir always wins the PATH race.
        expected = str(Path(sys.executable).resolve().parent)
        self.assertTrue(environment["PATH"].startswith(expected + os.pathsep))

    def test_environment_allowlist_keeps_interpreter_bin_dir_first(self):
        environment = bridge.agent_environment(base={})
        expected = str(Path(sys.executable).resolve().parent)
        self.assertTrue(environment["PATH"].startswith(expected + os.pathsep))

    def test_default_runner_keeps_prepending_interpreter_bin_dir(self):
        result = bridge._default_runner(["/usr/bin/env"], timeout=10)
        self.assertEqual(result["returncode"], 0)
        path_line = next(
            line for line in result["stdout"].splitlines()
            if line.startswith("PATH=")
        )
        expected = str(Path(sys.executable).resolve().parent)
        self.assertTrue(path_line.startswith("PATH=" + expected + ":"))


class ConfigKeyUniverseTests(unittest.TestCase):
    """P2-9: the web save cannot inject keys outside the shared contract."""

    def setUp(self):
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.config_path = self.root / "config.json"
        config.save({}, self.config_path)

    def test_web_save_rejects_unknown_keys(self):
        status = None
        import threading
        import urllib.error
        import urllib.request
        httpd = server.build(
            "127.0.0.1", 0, config_path=self.config_path, token="keys",
            start_worker=False,
        )
        self.addCleanup(httpd.server_close)
        port = httpd.server_address[1]
        thread = threading.Thread(target=httpd.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(httpd.shutdown)
        url = "http://127.0.0.1:{0}/api/config".format(port)
        body = json.dumps({"port": 9100, "smuggled": {"evil": True}}).encode("utf-8")
        request = urllib.request.Request(url, data=body, method="POST")
        request.add_header(server.TOKEN_HEADER, "keys")
        request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                status = response.status
        except urllib.error.HTTPError as error:
            with error:
                payload = json.loads(error.read().decode("utf-8"))
            status = error.code
        self.assertEqual(status, 400)
        self.assertEqual(payload["error"]["code"], "invalid_config")
        on_disk = json.loads(self.config_path.read_text(encoding="utf-8"))
        self.assertNotIn("smuggled", on_disk)


class AuditTrailTests(unittest.TestCase):
    """P2-10: state-changing operations land in one readable trail."""

    def setUp(self):
        from mlx_workbench import audit
        self.audit = audit
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.path = self.root / "audit.jsonl"

    def test_record_appends_and_recent_reverses(self):
        self.audit.record("a.one", path=self.path)
        self.audit.record("a.two", path=self.path, detail="x")
        entries = self.audit.recent(path=self.path)
        self.assertEqual([e["operation"] for e in entries], ["a.two", "a.one"])
        self.assertEqual(entries[0]["detail"], "x")
        self.assertIn("at", entries[0])

    def test_record_skips_empty_operation(self):
        self.assertIsNone(self.audit.record("", path=self.path))
        self.assertEqual(self.audit.recent(path=self.path), [])

    def test_record_is_silent_when_the_disk_refuses(self):
        # A missing directory chain that cannot be created must not raise.
        blocker = self.root / "file-blocks-the-way"
        blocker.write_text("not a directory", encoding="utf-8")
        self.assertIsNone(
            self.audit.record("a.op", path=blocker / "audit.jsonl")
        )

    def test_record_drops_entries_once_the_file_is_full(self):
        self.audit.record("a.seed", path=self.path)
        with open(self.path, "r+", encoding="utf-8") as handle:
            handle.seek(self.audit.MAX_AUDIT_BYTES)
            handle.write("x")
        self.assertIsNone(self.audit.record("a.late", path=self.path))
        entries = self.audit.recent(path=self.path)
        self.assertEqual([e["operation"] for e in entries], ["a.seed"])

    def test_recent_skips_corrupt_lines(self):
        self.audit.record("a.good", path=self.path)
        with open(self.path, "a", encoding="utf-8") as handle:
            handle.write("{broken\n")
        entries = self.audit.recent(path=self.path)
        self.assertEqual([e["operation"] for e in entries], ["a.good"])

    def test_server_routes_write_the_trail(self):
        import threading
        import urllib.error
        import urllib.request
        config_path = self.root / "profile" / "config.json"
        config.save({
            "gguf_roots": [],
            "quarantine_dir": str(self.root / "hold"),
            "output_dir": str(self.root / "out"),
        }, config_path)
        httpd = server.build(
            "127.0.0.1", 0, config_path=config_path, token="audit",
            start_worker=False,
        )
        self.addCleanup(httpd.server_close)
        port = httpd.server_address[1]
        thread = threading.Thread(target=httpd.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(httpd.shutdown)
        url = "http://127.0.0.1:{0}/api/config".format(port)
        body = json.dumps({"port": 9200}).encode("utf-8")
        request = urllib.request.Request(url, data=body, method="POST")
        request.add_header(server.TOKEN_HEADER, "audit")
        request.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(request, timeout=10):
            pass
        audit_file = self.root / "profile" / "audit.jsonl"
        entries = self.audit.recent(path=audit_file)
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["operation"], "config.save")
        self.assertEqual(entries[0]["changed"], ["port"])


class ScanCacheTests(unittest.TestCase):
    """Bug 3: /api/scan serves a cached snapshot and refreshes in the
    background, so screens never block on a full signature scan."""

    def setUp(self):
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.config_path = self.root / "config.json"
        config.save({
            "gguf_roots": [str(self.root / "models")],
            "quarantine_dir": str(self.root / "hold"),
            "output_dir": str(self.root / "out"),
        }, self.config_path)
        self.scans = []

    def _scan_payload(self, marker):
        return {
            "models": [{"path": "/m/a.gguf", "name": "a.gguf", "bytes": 1}],
            "duplicates": [],
            "totals": {"gguf": 1, "bytes": 1, "pending": 1, "converted": 0},
            "generation": len(self.scans),
        }

    def _build(self, ttl=60.0):
        httpd = server.build(
            "127.0.0.1", 0, config_path=self.config_path, token="cache",
            start_worker=False, scan_ttl_seconds=ttl,
        )
        self.addCleanup(httpd.server_close)

        def runner(command, timeout):
            self.scans.append(list(command))
            return {
                "returncode": 0,
                "stdout": json.dumps({
                    "schema_version": "1.0", "generated_at": "now",
                    "operation": "convert-scan", "status": "ok",
                    "data": self._scan_payload(len(self.scans)), "warnings": [],
                }),
                "stderr": "",
            }

        httpd.app.runner = runner
        return httpd

    def test_first_scan_populates_and_second_call_serves_cache(self):
        httpd = self._build()
        app = httpd.app
        settings = app.config()
        agent = settings["mlx_agent_path"]

        first, stale1 = app.cached_scan(settings, agent, app.runner)
        second, stale2 = app.cached_scan(settings, agent, app.runner)

        self.assertFalse(stale1)
        self.assertFalse(stale2)
        self.assertEqual(first["generation"], second["generation"])
        self.assertEqual(len(self.scans), 1)

    def test_refresh_true_scans_synchronously(self):
        httpd = self._build()
        app = httpd.app
        settings = app.config()
        agent = settings["mlx_agent_path"]

        app.cached_scan(settings, agent, app.runner)
        payload, stale = app.cached_scan(settings, agent, app.runner, refresh=True)

        self.assertFalse(stale)
        self.assertEqual(len(self.scans), 2)

    def test_stale_cache_is_served_while_background_refresh_runs(self):
        httpd = self._build(ttl=0.05)
        app = httpd.app
        settings = app.config()
        agent = settings["mlx_agent_path"]

        app.cached_scan(settings, agent, app.runner)
        time.sleep(0.1)
        stale_payload, stale = app.cached_scan(settings, agent, app.runner)

        self.assertTrue(stale)
        self.assertIn("generation", stale_payload)
        # The background refresh completes on its own.
        for _ in range(100):
            with app.lock:
                if not app._scan_refreshing:
                    break
            time.sleep(0.02)
        self.assertFalse(app._scan_refreshing)

    def test_route_reports_cache_flags(self):
        import threading
        import urllib.request
        httpd = self._build()
        port = httpd.server_address[1]
        thread = threading.Thread(target=httpd.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(httpd.shutdown)

        def get(path):
            request = urllib.request.Request(
                "http://127.0.0.1:{0}{1}".format(port, path)
            )
            request.add_header(server.TOKEN_HEADER, "cache")
            with urllib.request.urlopen(request, timeout=10) as response:
                return json.loads(response.read().decode("utf-8"))

        first = get("/api/scan")
        self.assertTrue(first["data"]["cached"])
        self.assertFalse(first["data"]["stale"])
        second = get("/api/scan?refresh=1")
        self.assertFalse(second["data"]["cached"])


class ServePresetTests(unittest.TestCase):
    """Named endpoint profiles: CRUD, schema discipline, API surface."""

    def setUp(self):
        from mlx_workbench import serve_presets
        self.sp = serve_presets
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.config_dir = Path(self.directory.name)
        self.book = self.sp.PresetBook(
            self.sp.presets_path(self.config_dir / "config.json")
        )

    def test_upsert_create_update_delete_round_trip(self):
        created = self.book.upsert(
            name="Coder", model="mlx-community/Qwen3-8B-4bit", kind="repo",
            runtime="mlx_lm", port=8766, max_tokens=4096,
        )
        self.assertEqual(created["id"], "sp-1")
        updated = self.book.upsert(
            preset_id=created["id"], name="Coder (8k)", port=None,
        )
        self.assertEqual(updated["name"], "Coder (8k)"[:0] + "Coder (8k)")
        self.assertIsNone(updated["port"])
        self.assertEqual(updated["max_tokens"], 4096)
        self.book.delete(created["id"])
        self.assertEqual(self.book.list(), [])

    def test_persisted_file_survives_reload_and_rejects_schema_drift(self):
        created = self.book.upsert(
            name="Vision", model="/models/mlx/vlm", kind="path", runtime="mlx-vlm",
        )
        again = self.sp.PresetBook(self.sp.presets_path(self.config_dir / "config.json"))
        loaded = again.list()
        self.assertEqual(len(loaded), 1)
        self.assertEqual(loaded[0]["model"], "/models/mlx/vlm")

        corrupt = self.sp.presets_path(self.config_dir / "config.json")
        corrupt.write_text('{"schema_version": "9.9", "presets": []}', encoding="utf-8")
        self.assertEqual(again.list(), [])

        _ = created

    def test_invalid_fields_are_classified(self):
        for fields in (
            {"name": "", "model": "m", "kind": "repo", "runtime": "mlx_lm"},
            {"name": "x", "model": "", "kind": "repo", "runtime": "mlx_lm"},
            {"name": "x", "model": "m", "kind": "nope", "runtime": "mlx_lm"},
            {"name": "x", "model": "m", "kind": "repo", "runtime": "ollama"},
            {"name": "x", "model": "m", "kind": "repo", "runtime": "mlx_lm", "port": 70000},
        ):
            with self.subTest(fields=fields):
                with self.assertRaises(self.sp.PresetError):
                    self.book.upsert(**fields)

    def test_route_crud_and_audit(self):
        import threading
        import urllib.error
        import urllib.request
        config_path = self.config_dir / "config.json"
        config.save({}, config_path)
        httpd = server.build(
            "127.0.0.1", 0, config_path=config_path, token="presets",
            start_worker=False,
        )
        self.addCleanup(httpd.server_close)
        port = httpd.server_address[1]
        thread = threading.Thread(target=httpd.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(httpd.shutdown)

        def request(path, method="GET", body=None, expect=200):
            url = "http://127.0.0.1:{0}{1}".format(port, path)
            data = None if body is None else json.dumps(body).encode("utf-8")
            request = urllib.request.Request(url, data=data, method=method)
            request.add_header(server.TOKEN_HEADER, "presets")
            if data is not None:
                request.add_header("Content-Type", "application/json")
            try:
                with urllib.request.urlopen(request, timeout=10) as response:
                    return response.status, json.loads(response.read().decode("utf-8"))
            except urllib.error.HTTPError as error:
                with error:
                    payload = json.loads(error.read().decode("utf-8"))
                return error.code, payload

        free = request("/api/serve/port")
        self.assertEqual(free[0], 200)
        self.assertTrue(1 <= free[1]["data"]["port"] <= 65535)

        status, payload = request("/api/serve/presets", "POST", {
            "name": "Coder", "model": "mlx-community/Qwen3-8B-4bit",
            "kind": "repo", "runtime": "mlx_lm", "port": 8766,
        })
        self.assertEqual(status, 200)
        preset_id = payload["data"]["preset"]["id"]

        status, payload = request("/api/serve/presets")
        self.assertEqual(len(payload["data"]["presets"]), 1)

        status, payload = request("/api/serve/presets", "POST", {"name": ""})
        self.assertEqual(status, 400)

        status, _ = request(
            "/api/serve/presets/delete", "POST", {"id": preset_id}
        )
        self.assertEqual(status, 200)
        status, payload = request("/api/serve/presets")
        self.assertEqual(payload["data"]["presets"], [])

        entries = audit.recent(path=self.config_dir / "audit.jsonl")
        operations = [entry["operation"] for entry in entries]
        self.assertIn("serve.preset.save", operations)
        self.assertIn("serve.preset.delete", operations)

    def test_serve_preview_and_start_forward_max_tokens_and_adapter(self):
        import threading
        import urllib.request
        config_path = self.config_dir / "config.json"
        config.save({}, config_path)
        commands = []

        def runner(command, timeout):
            commands.append(list(command))
            if "--confirm" in command:
                data = {}
            else:
                data = {"plan": {"preview_hash": "h" * 64}}
            return {
                "returncode": 0,
                "stdout": json.dumps({
                    "schema_version": "1.0", "generated_at": "now",
                    "operation": "serve-start", "status": "ok",
                    "data": data, "warnings": [],
                }),
                "stderr": "",
            }

        httpd = server.build(
            "127.0.0.1", 0, config_path=config_path, token="tokens",
            start_worker=False, runner=runner,
        )
        self.addCleanup(httpd.server_close)
        port = httpd.server_address[1]
        thread = threading.Thread(target=httpd.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(httpd.shutdown)

        def post(body):
            url = "http://127.0.0.1:{0}/api/serve/preview".format(port)
            data = json.dumps(body).encode("utf-8")
            request = urllib.request.Request(url, data=data, method="POST")
            request.add_header(server.TOKEN_HEADER, "tokens")
            request.add_header("Content-Type", "application/json")
            with urllib.request.urlopen(request, timeout=10) as response:
                return json.loads(response.read().decode("utf-8"))

        post({
            "repo": "org/model", "runtime": "mlx_lm", "port": 8900,
            "max_tokens": 8192, "adapter_path": "/adapters/coder",
        })
        self.assertIn("--max-tokens", commands[-1])
        self.assertIn("8192", commands[-1])
        self.assertIn("--adapter-path", commands[-1])


class QuarantineDeleteTests(unittest.TestCase):
    """Bug 2: quarantine contents are visible and deletable (to Trash)."""

    def setUp(self):
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.roots = [str(self.root / "models")]
        (self.root / "models").mkdir()
        self.hold = self.root / "hold"

    def _quarantine_file(self, name="dupe.gguf", payload=b"x" * 16):
        source = self.root / "models" / name
        source.write_bytes(payload)
        record = quarantine.quarantine(str(source), self.roots, str(self.hold))
        return record

    def test_purge_moves_file_to_trash_and_marks_ledger(self):
        record = self._quarantine_file()
        quarantined = record["to"]
        trashed = []

        def fake_trash(path):
            trashed.append(path)
            os.unlink(path)

        result = quarantine.purge(
            quarantined, str(self.hold), trash=fake_trash
        )
        self.assertEqual(trashed, [str(Path(quarantined).resolve())])
        self.assertFalse(Path(trashed[0]).exists())
        self.assertEqual(result["deleted"], str(Path(quarantined).resolve()))
        self.assertEqual(result["bytes"], 16)
        entries = quarantine.ledger(str(self.hold))
        entry = next(e for e in entries if e["to"] == quarantined)
        self.assertTrue(entry["deleted"])
        self.assertIn("deleted_at", entry)

    def test_purge_refuses_paths_outside_quarantine(self):
        outside = self.root / "models" / "keep.gguf"
        outside.write_bytes(b"x")
        with self.assertRaises(quarantine.QuarantineError) as caught:
            quarantine.purge(str(outside), str(self.hold), trash=lambda p: None)
        self.assertEqual(caught.exception.code, "not_in_quarantine")
        self.assertTrue(outside.exists())

    def test_purge_refuses_relative_paths_and_the_ledger(self):
        with self.assertRaises(quarantine.QuarantineError):
            quarantine.purge("relative/file.gguf", str(self.hold), trash=lambda p: None)
        with self.assertRaises(quarantine.QuarantineError) as caught:
            quarantine.purge(
                str(self.hold / quarantine.LEDGER_NAME), str(self.hold),
                trash=lambda p: None,
            )
        self.assertEqual(caught.exception.code, "ledger_protected")

    def test_purge_refuses_symlinks(self):
        record = self._quarantine_file()
        real = self.root / "real.bin"
        real.write_bytes(b"payload")
        link = self.hold / "link.gguf"
        os.symlink(real, link)
        with self.assertRaises(quarantine.QuarantineError) as caught:
            quarantine.purge(str(link), str(self.hold), trash=lambda p: None)
        self.assertEqual(caught.exception.code, "symlink_refused")
        self.assertTrue(real.exists())
        self.assertTrue(Path(record["to"]).exists())

    def test_purge_failure_leaves_file_in_place(self):
        record = self._quarantine_file()

        def explode(path):
            raise OSError("disk refusing")

        with self.assertRaises(quarantine.QuarantineError) as caught:
            quarantine.purge(record["to"], str(self.hold), trash=explode)
        self.assertEqual(caught.exception.code, "delete_failed")
        self.assertTrue(Path(record["to"]).exists())
        # Ledger not marked when nothing was deleted.
        entry = next(
            e for e in quarantine.ledger(str(self.hold))
            if e["to"] == record["to"]
        )
        self.assertFalse(entry["deleted"])

    def test_server_route_deletes_and_audits(self):
        import threading
        import urllib.error
        import urllib.request
        record = self._quarantine_file()
        config_path = self.root / "config.json"
        config.save({
            "gguf_roots": self.roots,
            "quarantine_dir": str(self.hold),
            "output_dir": str(self.root / "out"),
        }, config_path)
        httpd = server.build(
            "127.0.0.1", 0, config_path=config_path, token="purge",
            start_worker=False,
        )
        self.addCleanup(httpd.server_close)
        port = httpd.server_address[1]
        thread = threading.Thread(target=httpd.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(httpd.shutdown)
        url = "http://127.0.0.1:{0}/api/quarantine/delete".format(port)
        body = json.dumps({"path": record["to"]}).encode("utf-8")
        request = urllib.request.Request(url, data=body, method="POST")
        request.add_header(server.TOKEN_HEADER, "purge")
        request.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(request, timeout=10) as response:
            payload = json.loads(response.read().decode("utf-8"))
        self.assertEqual(payload["data"]["deleted"], str(Path(record["to"]).resolve()))
        self.assertFalse(Path(record["to"]).exists())
        audit_file = self.root / "audit.jsonl"
        entries = audit.recent(path=audit_file)
        self.assertEqual(entries[0]["operation"], "quarantine.delete")


class QuarantineSymlinkTests(unittest.TestCase):
    """P1-6: quarantine never follows symlinks, in or out."""

    def setUp(self):
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.roots = str(self.root / "models")
        (self.root / "models").mkdir()
        self.hold = str(self.root / "hold")

    def test_symlink_source_is_refused(self):
        outside = self.root / "real" / "x.gguf"
        (self.root / "real").mkdir()
        outside.write_bytes(b"x")
        link = self.root / "models" / "x.gguf"
        os.symlink(outside, link)
        with self.assertRaises(quarantine.QuarantineError) as caught:
            quarantine.quarantine(str(link), [self.roots], self.hold)
        self.assertEqual(caught.exception.code, "symlink_refused")
        self.assertTrue(outside.exists())
        self.assertFalse(link.exists() and not link.is_symlink())

    def test_symlink_quarantine_dir_is_refused(self):
        real_hold = self.root / "elsewhere"
        real_hold.mkdir()
        link_hold = self.root / "hold"
        os.symlink(real_hold, link_hold)
        source = self.root / "models" / "dupe.gguf"
        source.write_bytes(b"x")
        with self.assertRaises(quarantine.QuarantineError) as caught:
            quarantine.quarantine(str(source), [self.roots], str(link_hold))
        self.assertEqual(caught.exception.code, "symlink_refused")
        self.assertTrue(source.exists())


class AdversarialRouteTests(unittest.TestCase):
    """P2-8: hostile requests must get classified 4xx, never a 500 or a hang.

    Complements ServerTests: here the point is that every malformed input —
    type-confused JSON, header edge cases, oversized arrays — is refused by
    the same envelope contract as ordinary misuse.
    """

    def setUp(self):
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.config_path = self.root / "config.json"
        config.save({
            "gguf_roots": [str(self.root / "models")],
            "quarantine_dir": str(self.root / "hold"),
            "output_dir": str(self.root / "out"),
        }, self.config_path)
        self.httpd = server.build(
            "127.0.0.1", 0, config_path=self.config_path, token="adversarial",
            start_worker=False,
        )
        self.addCleanup(self.httpd.server_close)
        self.port = self.httpd.server_address[1]
        import threading
        thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.httpd.shutdown)

    def _raw(self, path, method="GET", body=None, headers=None):
        url = "http://127.0.0.1:{0}{1}".format(self.port, path)
        request = urllib.request.Request(url, data=body, method=method)
        request.add_header(server.TOKEN_HEADER, "adversarial")
        for key, value in (headers or {}).items():
            request.add_header(key, value)
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return response.status
        except urllib.error.HTTPError as error:
            with error:
                error.read()
            return error.code

    def _post_json(self, route, payload):
        body = json.dumps(payload).encode("utf-8")
        return self._raw(route, "POST", body, {"Content-Type": "application/json"})

    def test_host_spoofing_suffix_is_rejected(self):
        # DNS-rebinding shape: "127.0.0.1.evil.com" is not a loopback host.
        self.assertEqual(
            self._raw("/", headers={"Host": "127.0.0.1.evil.com"}), 403
        )

    def test_origin_subdomain_trick_is_rejected(self):
        self.assertEqual(
            self._raw(
                "/api/config",
                headers={"Origin": "http://127.0.0.1.attacker.example"},
            ),
            403,
        )

    def test_origin_hostname_with_embedded_loopback_is_rejected(self):
        self.assertEqual(
            self._raw(
                "/api/config",
                headers={"Origin": "http://localhost.evil.example"},
            ),
            403,
        )

    def test_type_confused_bodies_are_classified_not_500(self):
        hostile_bodies = [
            ("list", []),
            ("string", "convert everything"),
            ("int", 7),
            ("bool", True),
            ("null", None),
            ("nested_list", {"path": ["nested", "list", "not", "string"]}),
            ("numeric_path", {"path": 3.14}),
            ("dict_path", {"path": {"deep": True}}),
        ]
        for name, payload in hostile_bodies:
            with self.subTest(body=name):
                status = self._post_json("/api/convert/preview", payload)
                self.assertIn(status, (400, 409))

    def test_type_confused_scout_body_is_classified(self):
        for payload in ({"role": {"deep": True}}, {"limit": "many"},
                        {"limit": True}, {"fast": "yes"}):
            with self.subTest(payload=payload):
                status = self._post_json("/api/scout", payload)
                self.assertIn(status, (400, 502))

    def test_oversized_body_is_rejected(self):
        # 64 KiB is the cap; a 1 MiB body must not be read or buffered. The
        # client may learn of the refusal either as the 400 reply or as a
        # broken pipe while still uploading; either way the server must
        # answer its next request normally.
        blob = "x" * (1024 * 1024)
        try:
            status = self._post_json("/api/convert/preview", {"path": blob})
            self.assertEqual(status, 400)
        except (urllib.error.URLError, BrokenPipeError, ConnectionResetError):
            pass
        self.assertEqual(self._raw("/api/config"), 200)

    def test_content_length_garbage_is_rejected(self):
        body = b'{"path": "/x.gguf"}'
        status = self._raw(
            "/api/convert/preview", "POST", body, {"Content-Length": "abc"}
        )
        self.assertEqual(status, 400)

    def test_huge_root_list_is_rejected(self):
        payload = {"gguf_roots": ["/r{0}".format(i) for i in range(64)]}
        status = self._post_json("/api/config", payload)
        self.assertEqual(status, 400)

    def test_unicode_and_null_bytes_in_paths_are_classified(self):
        for path in ("mod\x00el.gguf", "mødel.gguf", "../../etc/passwd"):
            with self.subTest(path=path):
                status = self._post_json(
                    "/api/convert/preview", {"path": path, "preview_hash": "a" * 64}
                )
                self.assertIn(status, (400, 502))

    def test_broken_json_body_is_classified(self):
        status = self._raw(
            "/api/convert/preview", "POST", b'{"path": ', {"Content-Type": "application/json"}
        )
        self.assertEqual(status, 400)


if __name__ == "__main__":
    unittest.main()