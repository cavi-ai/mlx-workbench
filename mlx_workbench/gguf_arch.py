"""Read general.architecture from a GGUF header. Stdlib only.

This exists for fail-fast conversion previews: transformers' GGUF loader
refuses architectures it does not know ("GGUF model with architecture X is
not supported yet") only after a multi-minute dequantize has already run.
Reading the single header field up front lets the UI refuse those files
immediately, with the architecture named. Only the header is read — never
the weights.
"""

from __future__ import annotations

import struct
from pathlib import Path


GGUF_MAGIC = b"GGUF"
MAX_METADATA_PAIRS = 4096
_MAX_STRING_BYTES = 4 * 1024 * 1024


class GGUFFormatError(ValueError):
    """The file is not a GGUF file this module can read."""

    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def _read_exactly(handle, count):
    data = handle.read(count)
    if len(data) != count:
        raise GGUFFormatError("truncated_header", "truncated GGUF header")
    return data


def _read_string(handle):
    (length,) = struct.unpack("<Q", _read_exactly(handle, 8))
    if length > _MAX_STRING_BYTES:
        raise GGUFFormatError(
            "gguf_unreadable", "GGUF string is implausibly large"
        )
    return _read_exactly(handle, length)


def _skip_value(handle, value_type):
    sizes = {
        0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8,
        11: 8, 12: 8,
    }
    if value_type == 8:
        _read_string(handle)
        return
    if value_type == 9:  # array: type + count of nested values
        (inner_type,) = struct.unpack("<I", _read_exactly(handle, 4))
        (count,) = struct.unpack("<Q", _read_exactly(handle, 8))
        for _ in range(min(count, MAX_METADATA_PAIRS)):
            _skip_value(handle, inner_type)
        return
    size = sizes.get(value_type)
    if size is None:
        raise GGUFFormatError(
            "gguf_unreadable",
            "unknown GGUF metadata value type {0}".format(value_type),
        )
    if size:
        _read_exactly(handle, size)


def _read_value(handle, value_type):
    if value_type == 8:
        return _read_string(handle).decode("utf-8", "replace")
    if value_type == 9:  # array
        (inner_type,) = struct.unpack("<I", _read_exactly(handle, 4))
        (count,) = struct.unpack("<Q", _read_exactly(handle, 8))
        return [_read_value(handle, inner_type) for _ in range(min(count, 64))]
    widths = {
        0: ("<b", 1), 1: ("<b", 1), 2: ("<H", 2), 3: ("<h", 2),
        4: ("<I", 4), 5: ("<i", 4), 6: ("<f", 4),
        7: ("<B", 1), 10: ("<d", 8),
        11: ("<Q", 8), 12: ("<q", 8),
    }
    packed = widths.get(value_type)
    if packed is None:
        raise GGUFFormatError(
            "gguf_unreadable",
            "unknown GGUF metadata value type {0}".format(value_type),
        )
    fmt, size = packed
    (value,) = struct.unpack(fmt, _read_exactly(handle, size))
    return value


def read_architecture(path):
    """Return general.architecture from a GGUF file, or raise GGUFFormatError.

    Reads only the header: magic, version, tensor/pair counts, and metadata
    pairs until general.architecture is found. Unknown value types are
    skipped so an exotic-but-valid header never blocks the lookup.
    """
    location = Path(path)
    try:
        with location.open("rb") as handle:
            if _read_exactly(handle, 4) != GGUF_MAGIC:
                raise GGUFFormatError("not_gguf", "not a GGUF file")
            (version,) = struct.unpack("<I", _read_exactly(handle, 4))
            if version not in (2, 3):
                raise GGUFFormatError(
                    "unsupported_gguf_version",
                    "GGUF version {0} is not supported.".format(version),
                )
            _read_exactly(handle, 8)  # tensor count
            (pair_count,) = struct.unpack("<Q", _read_exactly(handle, 8))
            for _ in range(min(pair_count, MAX_METADATA_PAIRS)):
                key = _read_string(handle).decode("utf-8", "replace")
                (value_type,) = struct.unpack("<I", _read_exactly(handle, 4))
                if key == "general.architecture":
                    value = _read_value(handle, value_type)
                    return value.decode("utf-8", "replace") if isinstance(value, bytes) else str(value)
                _skip_value(handle, value_type)
    except (OSError, struct.error) as error:
        if isinstance(error, GGUFFormatError):
            raise
        raise GGUFFormatError(
            "gguf_unreadable",
            "The GGUF header could not be read: {0}".format(error),
        ) from error
    return None
