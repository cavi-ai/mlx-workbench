import json
import threading
import unittest
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from tempfile import TemporaryDirectory

from mlx_workbench import bridge, config, server


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
        self.responses = {"stdout": envelope(data={"models": [], "totals": {"gguf": 0}})}
        self.token = "test-token"
        self.httpd = server.build(
            "127.0.0.1", 0, config_path=self.config_path, token=self.token, runner=self._runner
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
        self.assertIn("--confirm", self.commands[0])
        self.assertIn("c" * 64, self.commands[0])

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
