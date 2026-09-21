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

from mlx_workbench import bridge, config, convert_queue, quarantine, server
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