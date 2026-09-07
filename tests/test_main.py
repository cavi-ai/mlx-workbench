"""Entry-point tests: argument handling, loopback enforcement, PID file."""

import os
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest import mock

from mlx_workbench import __main__ as main_module
from mlx_workbench import config as config_module


class _FakeServer:
    def __init__(self, host, port):
        self.server_address = (host, port)
        self.served = False
        self.closed = False

    def serve_forever(self):
        self.served = True

    def server_close(self):
        self.closed = True


def _healthy_agent(_path):
    return {"ok": True, "path": "/opt/agent/scripts/mlx-agent", "message": ""}


def _ready_runtime():
    return {
        "convert": {"ok": True, "message": ""},
        "serve": {"ok": True, "message": ""},
    }


def _settings(**overrides):
    base = {"host": "127.0.0.1", "port": 8765, "mlx_agent_path": "/opt/agent"}
    base.update(overrides)
    return base


class MainTests(unittest.TestCase):
    def setUp(self):
        patches = [
            mock.patch.object(main_module.bridge, "agent_health", _healthy_agent),
            mock.patch.object(main_module.deps_module, "runtime_report", _ready_runtime),
            mock.patch.object(main_module.webbrowser, "open"),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def test_refuses_non_loopback_host(self):
        with mock.patch.object(main_module.config_module, "load", return_value=_settings()):
            with mock.patch.object(main_module.server_module, "build") as build:
                exit_code = main_module.main(["--host", "0.0.0.0", "--no-open"])
        self.assertEqual(exit_code, 2)
        build.assert_not_called()

    def test_accepts_all_loopback_aliases(self):
        for host in ("127.0.0.1", "localhost", "::1"):
            server = _FakeServer(host, 8765)
            with mock.patch.object(main_module.config_module, "load", return_value=_settings(host=host)):
                with mock.patch.object(main_module.server_module, "build", return_value=server):
                    exit_code = main_module.main(["--no-open"])
            self.assertEqual(exit_code, 0, host)
            self.assertTrue(server.served)
            self.assertTrue(server.closed)

    def test_config_error_returns_2(self):
        with mock.patch.object(
            main_module.config_module, "load",
            side_effect=config_module.ConfigError("bad config"),
        ):
            self.assertEqual(main_module.main(["--no-open"]), 2)

    def test_bind_failure_returns_2(self):
        with mock.patch.object(main_module.config_module, "load", return_value=_settings()):
            with mock.patch.object(
                main_module.server_module, "build", side_effect=OSError("address in use")
            ):
                self.assertEqual(main_module.main(["--no-open"]), 2)

    def test_pid_file_records_this_process(self):
        with TemporaryDirectory() as directory:
            pid_path = Path(directory) / "nested" / "workbench.pid"
            server = _FakeServer("127.0.0.1", 8765)
            with mock.patch.object(main_module.config_module, "load", return_value=_settings()):
                with mock.patch.object(main_module.server_module, "build", return_value=server):
                    exit_code = main_module.main(["--no-open", "--pid-file", str(pid_path)])
            self.assertEqual(exit_code, 0)
            self.assertEqual(pid_path.read_text(encoding="utf-8").strip(), str(os.getpid()))

    def test_no_pid_file_by_default(self):
        with TemporaryDirectory() as directory:
            pid_path = Path(directory) / "workbench.pid"
            server = _FakeServer("127.0.0.1", 8765)
            with mock.patch.object(main_module.config_module, "load", return_value=_settings()):
                with mock.patch.object(main_module.server_module, "build", return_value=server):
                    self.assertEqual(main_module.main(["--no-open"]), 0)
            self.assertFalse(pid_path.exists())

    def test_cli_overrides_config_port(self):
        server = _FakeServer("127.0.0.1", 9999)
        with mock.patch.object(main_module.config_module, "load", return_value=_settings(port=8765)):
            with mock.patch.object(
                main_module.server_module, "build", return_value=server
            ) as build:
                self.assertEqual(main_module.main(["--port", "9999", "--no-open"]), 0)
        self.assertEqual(build.call_args.args[:2], ("127.0.0.1", 9999))


if __name__ == "__main__":
    unittest.main()
