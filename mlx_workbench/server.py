"""Loopback HTTP server for the mlx-workbench UI. Standard library only."""

from __future__ import annotations

import json
import secrets
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

from . import bridge, config as config_module, quarantine as quarantine_module


STATIC_ROOT = Path(__file__).resolve().with_name("static")
MAX_BODY_BYTES = 64 * 1024
TOKEN_HEADER = "X-MLX-Workbench-Token"
_ALLOWED_HOSTS = ("127.0.0.1", "localhost", "[::1]")
_CONTENT_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".svg": "image/svg+xml",
}


class Application:
    """Everything the handler needs, with no global state."""

    def __init__(self, config_path=None, token=None, runner=None):
        self.config_path = config_path
        self.token = token or secrets.token_urlsafe(24)
        self.runner = runner
        self.lock = threading.Lock()

    def config(self):
        return config_module.load(self.config_path)

    def save_config(self, value):
        with self.lock:
            return config_module.save(value, self.config_path)


def _json_bytes(payload, status=200):
    return status, "application/json; charset=utf-8", json.dumps(payload).encode("utf-8")


def _error(code, message, remediation, status=400):
    return _json_bytes(
        {"status": "error", "error": {
            "code": code, "message": message, "remediation": remediation,
        }},
        status,
    )


def _ok(data):
    return _json_bytes({"status": "ok", "data": data})


def _static(name):
    location = (STATIC_ROOT / name).resolve()
    if not location.is_file() or STATIC_ROOT not in location.parents:
        return 404, "text/plain; charset=utf-8", b"not found"
    content_type = _CONTENT_TYPES.get(location.suffix, "application/octet-stream")
    return 200, content_type, location.read_bytes()


class Handler(BaseHTTPRequestHandler):
    server_version = "mlx-workbench"
    protocol_version = "HTTP/1.1"

    @property
    def app(self):
        return self.server.app

    def log_message(self, format, *args):  # noqa: A002 - stdlib signature
        return

    def _host_is_local(self):
        host = (self.headers.get("Host") or "").rsplit(":", 1)[0]
        return host in _ALLOWED_HOSTS

    def _origin_is_local(self):
        origin = self.headers.get("Origin")
        if not origin:
            return True
        hostname = urlparse(origin).hostname
        return hostname in ("127.0.0.1", "localhost", "::1")

    def _authorized(self):
        supplied = self.headers.get(TOKEN_HEADER) or ""
        return secrets.compare_digest(supplied, self.app.token)

    def _send(self, status, content_type, body):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'none'; style-src 'self'; script-src 'self'; connect-src 'self'",
        )
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _body(self):
        length = self.headers.get("Content-Length")
        try:
            size = int(length or 0)
        except ValueError:
            return None
        if size <= 0 or size > MAX_BODY_BYTES:
            return None
        try:
            return json.loads(self.rfile.read(size).decode("utf-8"))
        except (OSError, ValueError, UnicodeDecodeError):
            return None

    def do_GET(self):
        self._dispatch("GET")

    def do_POST(self):
        self._dispatch("POST")

    def _dispatch(self, method):
        if not self._host_is_local() or not self._origin_is_local():
            self._send(*_error(
                "forbidden_origin",
                "This server only answers same-origin loopback requests.",
                "Open the printed http://127.0.0.1 URL directly.",
                403,
            ))
            return
        route = urlparse(self.path).path
        try:
            status, content_type, body = self._route(method, route)
        except bridge.BridgeError as error:
            status, content_type, body = _json_bytes(
                {"status": "error", "error": error.to_dict()}, 502
            )
        except quarantine_module.QuarantineError as error:
            status, content_type, body = _json_bytes(
                {"status": "error", "error": error.to_dict()}, 400
            )
        except config_module.ConfigError as error:
            status, content_type, body = _error("invalid_config", str(error), "Fix the field and save again.")
        self._send(status, content_type, body)

    def _route(self, method, route):
        if method == "GET" and route in ("/", "/index.html"):
            status, content_type, body = _static("index.html")
            body = body.replace(b"__MLX_TOKEN__", self.app.token.encode("ascii"))
            return status, content_type, body
        if method == "GET" and route.startswith("/static/"):
            return _static(route[len("/static/"):])
        if not route.startswith("/api/"):
            return 404, "text/plain; charset=utf-8", b"not found"
        if not self._authorized():
            return _error(
                "unauthorized",
                "Missing or invalid session token.",
                "Reload the page served by this process.",
                401,
            )
        return self._api(method, route)

    def _api(self, method, route):
        settings = self.app.config()
        agent = settings["mlx_agent_path"]
        runner = self.app.runner
        if method == "GET" and route == "/api/config":
            return _ok({
                "config": settings,
                "discovered_roots": config_module.discover_gguf_roots(),
                "config_path": str(self.app.config_path or config_module.config_path()),
            })
        if method == "POST" and route == "/api/config":
            payload = self._body()
            if payload is None:
                return _error("invalid_body", "Send a JSON object.", "Retry from the UI.")
            return _ok({"config": self.app.save_config(payload)})
        if method == "GET" and route == "/api/scan":
            return _ok(bridge.scan(
                agent,
                gguf_roots=config_module.scan_roots(settings),
                mlx_roots=settings["mlx_roots"],
                signatures=settings["signatures"],
                runner=runner,
            ))
        if method == "GET" and route == "/api/jobs":
            return _ok(bridge.jobs(agent, runner=runner))
        if method == "GET" and route == "/api/quarantine":
            return _ok({"records": quarantine_module.ledger(settings["quarantine_dir"])})
        if method == "POST" and route in ("/api/convert/preview", "/api/convert/start"):
            payload = self._body()
            if not isinstance(payload, dict) or not isinstance(payload.get("path"), str):
                return _error("invalid_body", "A gguf path is required.", "Retry from the UI.")
            q_bits = payload.get("q_bits", settings["q_bits"])
            if q_bits not in config_module.Q_BITS_CHOICES:
                return _error("invalid_body", "q_bits must be 4 or 8.", "Pick 4 or 8 in the UI.")
            out = _output_path(settings, payload)
            if route.endswith("preview"):
                return _ok(bridge.preview(agent, payload["path"], q_bits, out, runner=runner))
            preview_hash = payload.get("preview_hash")
            if not isinstance(preview_hash, str) or not preview_hash:
                return _error(
                    "preview_required",
                    "Confirming a conversion needs the hash from its preview.",
                    "Preview the plan first, then confirm it.",
                )
            return _ok(bridge.start(agent, payload["path"], preview_hash, q_bits, out, runner=runner))
        if method == "POST" and route == "/api/quarantine":
            payload = self._body()
            if not isinstance(payload, dict) or not isinstance(payload.get("path"), str):
                return _error("invalid_body", "A gguf path is required.", "Retry from the UI.")
            record = quarantine_module.quarantine(
                payload["path"],
                config_module.scan_roots(settings),
                settings["quarantine_dir"],
            )
            return _ok({"moved": record})
        return 404, "text/plain; charset=utf-8", b"not found"


def _output_path(settings, payload):
    """Where a conversion should write, from the request or the config."""
    explicit = payload.get("out")
    if isinstance(explicit, str) and explicit.strip():
        return str(Path(explicit).expanduser())
    directory = settings.get("output_dir")
    if not directory:
        return None
    stem = Path(payload["path"]).stem
    q_bits = payload.get("q_bits", settings["q_bits"])
    return str(Path(directory).expanduser() / "{0}-MLX-{1}bit".format(stem, q_bits))


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, app):
        self.app = app
        ThreadingHTTPServer.__init__(self, address, Handler)


def build(host="127.0.0.1", port=8765, config_path=None, token=None, runner=None):
    """Create a bound server; the caller decides how to run it."""
    return Server((host, port), Application(config_path, token, runner))
