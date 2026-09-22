"""Named serve presets: one saved endpoint profile per entry.

A preset captures everything needed to relaunch a hosted model without
re-choosing settings: the model (repo id or local path), runtime, port,
max-tokens, and an optional LoRA adapter. Presets live in their own
state file (`serve-presets.json`) rather than the shared `config.json` —
they are a web-UI concept and the native app keeps its own endpoint fleet,
so neither frontend's save can clobber the other's keys.

The file is a JSON object of `{"schema_version": ..., "presets": [...]}`
written atomically; each preset validates on load and unknown fields are
dropped, so a hand-edited file can never inject anything.
"""

from __future__ import annotations

import itertools
import threading

from .atomicio import write_text_atomic

import json
from pathlib import Path


PRESETS_SCHEMA_VERSION = "1.0"
PRESET_FIELDS = {
    "id", "name", "model", "model_kind", "runtime", "port",
    "max_tokens", "adapter_path",
}
RUNTIMES = ("mlx_lm", "mlx-vlm")


class PresetError(ValueError):
    """A classified invalid preset operation."""

    def __init__(self, code, message, remediation):
        super().__init__(message)
        self.code = code
        self.remediation = remediation

    def to_dict(self):
        return {"code": self.code, "message": str(self), "remediation": self.remediation}


def presets_path(config_path=None):
    """Beside an explicit config profile, else the default state dir."""
    if config_path is not None:
        return Path(config_path).expanduser().with_name("serve-presets.json")
    import os

    state_home = os.environ.get("XDG_STATE_HOME")
    root = Path(state_home).expanduser() if state_home else Path.home() / ".local" / "state"
    return root / "mlx-workbench" / "serve-presets.json"


def _validate_preset(preset, allow_missing_id=False):
    if not isinstance(preset, dict):
        raise PresetError("invalid_preset", "A preset must be an object.", "Retry from the Serve tab.")
    expected = PRESET_FIELDS - ({"id"} if allow_missing_id else set())
    if set(preset) != expected:
        raise PresetError(
            "invalid_preset",
            "Preset fields do not match the schema.",
            "Recreate the preset from the Serve tab.",
        )
    name = preset["name"]
    model = preset["model"]
    if not isinstance(name, str) or not name.strip() or len(name) > 80:
        raise PresetError(
            "invalid_preset", "Preset name must be 1-80 characters.", "Rename the preset."
        )
    if not isinstance(model, str) or not model.strip():
        raise PresetError(
            "invalid_preset", "A preset needs a model.", "Pick a model in the Serve tab."
        )
    if preset["model_kind"] not in ("repo", "path"):
        raise PresetError(
            "invalid_preset", "model_kind must be repo or path.", "Recreate the preset."
        )
    if preset["runtime"] not in RUNTIMES:
        raise PresetError(
            "invalid_preset", "runtime must be mlx_lm or mlx-vlm.", "Pick a runtime."
        )
    port = preset["port"]
    if port is not None and (isinstance(port, bool) or not isinstance(port, int) or not 1 <= port <= 65535):
        raise PresetError("invalid_preset", "port must be 1-65535 or null.", "Pick a port.")
    max_tokens = preset["max_tokens"]
    if max_tokens is not None and (
        isinstance(max_tokens, bool) or not isinstance(max_tokens, int) or not 1 <= max_tokens <= 131072
    ):
        raise PresetError(
            "invalid_preset", "max_tokens must be a positive integer or null.", "Adjust max tokens."
        )
    adapter = preset["adapter_path"]
    if adapter is not None and (not isinstance(adapter, str) or not adapter.strip()):
        raise PresetError(
            "invalid_preset", "adapter_path must be a non-empty string or null.", "Clear the adapter."
        )


def _validated_presets(payload):
    if not isinstance(payload, dict) or set(payload) != {"schema_version", "presets"}:
        raise PresetError(
            "presets_invalid",
            "The serve presets file does not match the schema.",
            "Fix or remove serve-presets.json; the UI will start empty.",
        )
    if payload["schema_version"] != PRESETS_SCHEMA_VERSION:
        raise PresetError(
            "presets_invalid",
            "The serve presets schema version is unsupported.",
            "Update mlx-workbench.",
        )
    if not isinstance(payload["presets"], list):
        raise PresetError("presets_invalid", "presets must be a list.", "Fix the file.")
    return [dict(preset) for preset in payload["presets"]]


class PresetStore:
    """Atomically persisted named serve presets. One writer, thread-safe."""

    def __init__(self, path):
        self.path = Path(path)
        self.lock = threading.Lock()

    def load(self):
        if not self.path.exists():
            return []
        try:
            return _validated_presets(json.loads(self.path.read_text(encoding="utf-8")))
        except (OSError, ValueError):
            return []

    def save(self, presets):
        payload = {
            "schema_version": PRESETS_SCHEMA_VERSION,
            "presets": presets,
        }
        _validated_presets({
            "schema_version": PRESETS_SCHEMA_VERSION,
            "presets": [dict(p) for p in presets],
        })
        write_text_atomic(
            self.path, json.dumps(payload, indent=2, sort_keys=True) + "\n"
        )
        return presets


class PresetBook:
    """CRUD over the presets file with classified errors for the API."""

    def __init__(self, path):
        self.store = PresetStore(path)
        self.lock = threading.Lock()
        self._ids = itertools.count(1)

    def list(self):
        with self.lock:
            return self.store.load()

    load = list

    def upsert(self, preset_id=None, **fields):
        fields["model_kind"] = fields.pop("kind", "repo")
        with self.lock:
            presets = self.store.load()
            if preset_id is None:
                fields.setdefault("adapter_path", None)
                fields.setdefault("max_tokens", None)
                fields.setdefault("port", None)
                while True:
                    candidate = "sp-{0}".format(next(self._ids))
                    if not any(p["id"] == candidate for p in presets):
                        break
                preset = {"id": candidate, **fields}
                self._validate(preset)
                presets.append(preset)
            else:
                found = next((p for p in presets if p["id"] == preset_id), None)
                if found is None:
                    raise PresetError(
                        "preset_not_found",
                        "No preset with id {0}.".format(preset_id),
                        "Reload the Serve tab.",
                    )
                merged = dict(found)
                merged.update({k: v for k, v in fields.items() if v is not None or k in ("port", "max_tokens", "adapter_path")})
                merged.pop("id", None)
                merged = {"id": found["id"], **merged}
                self._validate(merged)
                presets = [merged if p["id"] == found["id"] else p for p in presets]
                preset = merged
            self.store.save(presets)
            return dict(preset)

    def delete(self, preset_id):
        with self.lock:
            presets = self.store.load()
            remaining = [p for p in presets if p["id"] != preset_id]
            if len(remaining) == len(presets):
                raise PresetError(
                    "preset_not_found",
                    "No preset with id {0}.".format(preset_id),
                    "Reload the Serve tab.",
                )
            self.store.save(remaining)
            return True

    def _validate(self, preset):
        _validate_preset(preset)