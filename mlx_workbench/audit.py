"""Append-only local audit trail for state-changing operations.

The web server records every operation that changes durable state — config
saves, conversions, serve lifecycles, quarantine moves, queue operations —
as one JSONL line per event under $XDG_STATE_HOME/mlx-workbench/audit.jsonl.
Nothing here is security-critical alone: receipts and durable stores stay
authoritative. The trail exists so an operator can answer "what changed,
and when" from a single file. Reads return the newest entries first.
"""

from __future__ import annotations

import json
import threading
from datetime import datetime, timezone
from pathlib import Path


AUDIT_NAME = "audit.jsonl"
MAX_AUDIT_BYTES = 8 * 1024 * 1024
MAX_ENTRY_BYTES = 16 * 1024
_lock = threading.Lock()


def audit_path(config_path=None):
    """The audit file lives beside the durable state it describes."""
    if config_path is not None:
        return Path(config_path).expanduser().with_name(AUDIT_NAME)
    import os

    state_home = os.environ.get("XDG_STATE_HOME")
    root = Path(state_home).expanduser() if state_home else Path.home() / ".local" / "state"
    return root / "mlx-workbench" / AUDIT_NAME


def record(operation, path=None, clock=None, **details):
    """Append one audit entry; failures are silent by design.

    The audit trail must never break or delay the operation it observes.
    When the file is full (or the disk refuses), new entries are dropped —
    the durable stores remain the source of truth.
    """
    if not operation or not isinstance(operation, str):
        return None
    now = (clock or (lambda: datetime.now(timezone.utc)))()
    entry = {
        "at": now.isoformat(timespec="seconds"),
        "operation": operation,
    }
    if path is not None:
        entry["path"] = str(path)
    for key, value in details.items():
        if value is not None:
            entry[key] = value
    line = json.dumps(entry, sort_keys=True)
    if len(line) > MAX_ENTRY_BYTES:
        entry["details"] = "truncated"
        line = json.dumps(entry, sort_keys=True)
    location = path if path is not None else audit_path()
    try:
        with _lock:
            if location.exists() and location.stat().st_size > MAX_AUDIT_BYTES:
                return None
            location.parent.mkdir(parents=True, exist_ok=True)
            with location.open("a", encoding="utf-8") as handle:
                handle.write(line + "\n")
    except OSError:
        return None
    return entry


def recent(limit=100, path=None):
    """Newest audit entries first; unreadable lines are skipped."""
    location = path if path is not None else audit_path()
    try:
        lines = location.read_text(encoding="utf-8").splitlines()
    except (OSError, ValueError):
        return []
    entries = []
    for line in lines[-limit:]:
        try:
            value = json.loads(line)
        except ValueError:
            continue
        if isinstance(value, dict) and value.get("operation"):
            entries.append(value)
    entries.reverse()
    return entries