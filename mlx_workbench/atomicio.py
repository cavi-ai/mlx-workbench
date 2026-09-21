"""Atomic text-file writes with fsync and symlink refusal. Stdlib only."""

from __future__ import annotations

import os
from pathlib import Path


def write_text_atomic(path, text, encoding="utf-8"):
    """Write text to path atomically; refuse to write through a symlink.

    The temporary file is opened with O_NOFOLLOW so a pre-placed symbolic
    link at the ``.tmp`` path cannot redirect the write elsewhere. The file
    contents are fsynced before the rename, and the containing directory is
    fsynced afterwards, so a power loss cannot leave a truncated file under
    the real name.
    """
    location = Path(path)
    if location.is_symlink():
        raise OSError(
            "symlink_refused",
            "{0} is a symbolic link; refusing to write through it.".format(location),
        )
    location.parent.mkdir(parents=True, exist_ok=True)
    temporary = location.with_name(location.name + ".tmp")
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(str(temporary), flags, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding=encoding) as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
    except BaseException:
        try:
            os.unlink(str(temporary))
        except OSError:
            pass
        raise
    os.replace(str(temporary), str(location))
    _fsync_directory(location.parent)
    return location


def _fsync_directory(directory):
    try:
        descriptor = os.open(str(directory), os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(descriptor)
    except OSError:
        pass
    finally:
        os.close(descriptor)