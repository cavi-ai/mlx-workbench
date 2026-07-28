"""User configuration: where the weights live, and where mlx-agent lives.

Stdlib only. The file is created on first read with conservative defaults and
is the single place the UI edits.
"""

from __future__ import annotations

import json
import os
from pathlib import Path


APP_NAME = "mlx-converter"
CONFIG_ENV = "MLX_CONVERTER_CONFIG"
AGENT_ENV = "MLX_AGENT_HOME"
SCHEMA_VERSION = "1.0"

_LIST_FIELDS = ("gguf_roots", "mlx_roots")
_STRING_FIELDS = ("output_dir", "mlx_agent_path", "quarantine_dir", "host")
_INT_FIELDS = ("port", "q_bits")
_BOOL_FIELDS = ("signatures",)
MAX_ROOTS = 32
Q_BITS_CHOICES = (4, 8)


class ConfigError(ValueError):
    """The supplied configuration is not usable."""


def config_path():
    override = os.environ.get(CONFIG_ENV)
    if override:
        return Path(override).expanduser()
    base = os.environ.get("XDG_CONFIG_HOME")
    root = Path(base).expanduser() if base else Path.home() / ".config"
    return root / APP_NAME / "config.json"


def default_quarantine_dir():
    base = os.environ.get("XDG_DATA_HOME")
    root = Path(base).expanduser() if base else Path.home() / ".local" / "share"
    return str(root / APP_NAME / "quarantine")


def _existing(candidates):
    return [str(path) for path in candidates if path.is_dir()]


def discover_gguf_roots():
    """Well-known local weight directories that exist on this host."""
    home = Path.home()
    return _existing([
        home / ".cache" / "huggingface" / "hub",
        home / ".cache" / "lm-studio" / "models",
        home / ".lmstudio" / "models",
        home / "models",
        home / "Models",
    ])


def discover_agent_path(start=None):
    """Find an mlx-agent checkout: env, then a sibling of this repository."""
    override = os.environ.get(AGENT_ENV)
    if override and (Path(override).expanduser() / "skills").is_dir():
        return str(Path(override).expanduser())
    here = Path(start) if start is not None else Path(__file__).resolve().parents[1]
    for candidate in (here.parent / "mlx-agent", here / "mlx-agent"):
        if (candidate / "skills" / "mlx-converter").is_dir():
            return str(candidate)
    return ""


def defaults():
    return {
        "schema_version": SCHEMA_VERSION,
        "gguf_roots": discover_gguf_roots(),
        "mlx_roots": [],
        "output_dir": str(Path.home() / "models" / "mlx"),
        "mlx_agent_path": discover_agent_path(),
        "quarantine_dir": default_quarantine_dir(),
        "q_bits": 4,
        "signatures": True,
        "host": "127.0.0.1",
        "port": 8765,
    }


def _coerce(value):
    """Validate an inbound configuration object; never trusts its own file."""
    if not isinstance(value, dict):
        raise ConfigError("configuration must be an object")
    merged = defaults()
    for field in _LIST_FIELDS:
        if field not in value:
            continue
        items = value[field]
        if not isinstance(items, list) or len(items) > MAX_ROOTS:
            raise ConfigError("{0} must be a list of at most {1} paths".format(field, MAX_ROOTS))
        cleaned = []
        for item in items:
            if not isinstance(item, str) or not item.strip():
                raise ConfigError("{0} entries must be non-empty strings".format(field))
            cleaned.append(str(Path(item).expanduser()))
        merged[field] = cleaned
    for field in _STRING_FIELDS:
        if field not in value:
            continue
        item = value[field]
        if not isinstance(item, str):
            raise ConfigError("{0} must be a string".format(field))
        merged[field] = str(Path(item).expanduser()) if item else ""
    for field in _INT_FIELDS:
        if field not in value:
            continue
        item = value[field]
        if not isinstance(item, int) or isinstance(item, bool):
            raise ConfigError("{0} must be an integer".format(field))
        merged[field] = item
    for field in _BOOL_FIELDS:
        if field in value:
            merged[field] = bool(value[field])
    if merged["q_bits"] not in Q_BITS_CHOICES:
        raise ConfigError("q_bits must be one of {0}".format(list(Q_BITS_CHOICES)))
    if not 1 <= merged["port"] <= 65535:
        raise ConfigError("port must be between 1 and 65535")
    merged["schema_version"] = SCHEMA_VERSION
    return merged


def load(path=None):
    """Read the configuration, falling back to defaults for anything absent."""
    location = Path(path) if path is not None else config_path()
    try:
        raw = json.loads(location.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return defaults()
    except (OSError, ValueError) as error:
        raise ConfigError("{0} is not readable JSON: {1}".format(location, error))
    return _coerce(raw)


def save(value, path=None):
    """Validate and atomically write the configuration."""
    location = Path(path) if path is not None else config_path()
    merged = _coerce(value)
    location.parent.mkdir(parents=True, exist_ok=True)
    temporary = location.with_name(location.name + ".tmp")
    temporary.write_text(
        json.dumps(merged, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    os.replace(str(temporary), str(location))
    return merged


def scan_roots(value):
    """The roots a scan should walk, with a usable fallback."""
    roots = list(value.get("gguf_roots") or [])
    return roots or discover_gguf_roots()
