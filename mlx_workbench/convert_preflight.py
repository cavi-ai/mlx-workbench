"""Fail-fast conversion pre-flight for local GGUF files.

transformers' GGUF loader raises "GGUF model with architecture X is not
supported yet" only after a long dequantize has already run. The workbench
reads the header field up front and refuses unsupported architectures at
preview time, naming the architecture in the refusal.

The supported set comes from the installed transformers; when it cannot be
imported (bare interpreters, tests), the check degrades to allow — the
conversion still surfaces the underlying error if it is genuinely
unsupported, just later.
"""

from __future__ import annotations

from .gguf_arch import GGUFFormatError, read_architecture


class UnsupportedArchitecture(ValueError):
    """The GGUF file's architecture is not convertible by this runtime."""

    def __init__(self, architecture, path):
        super().__init__(
            "GGUF architecture '{0}' is not supported by the installed "
            "transformers; this model cannot be converted here yet.".format(architecture)
        )
        self.code = "architecture_unsupported"
        self.remediation = (
            "Wait for an mlx-lm/transformers release that adds '{0}', or "
            "convert with llama.cpp directly.".format(architecture)
        )
        self.architecture = architecture
        self.path = path

    def to_dict(self):
        return {
            "code": self.code,
            "message": str(self),
            "remediation": self.remediation,
        }


_SUPPORTED_CACHE = None


def _normalize_arch(name):
    for suffix in ("_text_model", "_vision_model", "_model"):
        if name.endswith(suffix):
            return name[: -len(suffix)]
    return name


def supported_architectures():
    """HF model names the installed transformers knows, or None.

    Reads CONFIG_MAPPING from the transformers source on disk rather than
    importing the package: importing transformers eagerly pulls torch into
    the caller, and in minimal interpreters that crashes the process on
    duplicate OpenMP runtimes. The file parse is cheap and pure-stdlib.
    """
    global _SUPPORTED_CACHE
    if _SUPPORTED_CACHE is not None:
        return _SUPPORTED_CACHE
    import importlib.util
    import re as regex

    spec = importlib.util.find_spec("transformers")
    if spec is None or not spec.submodule_search_locations:
        return None
    candidate = None
    for root in spec.submodule_search_locations:
        path = (
            __import__("pathlib").Path(root)
            / "models" / "auto" / "configuration_auto.py"
        )
        if path.is_file():
            candidate = path
            break
    if candidate is None:
        return None
    try:
        text = candidate.read_text(encoding="utf-8")
    except OSError:
        return None
    names = regex.findall(
        r'^\s*\(\s*"([^"]+)",\s*"([A-Za-z0-9_]+)"\)', text, regex.M
    )
    if not names:
        return None
    _SUPPORTED_CACHE = {_normalize_arch(key) for key, _ in names}
    return _SUPPORTED_CACHE


def check(path):
    """Refuse unsupported GGUF architectures; allow when unverifiable.

    Returns the architecture when the file converts; raises
    UnsupportedArchitecture when the header names an architecture the
    installed transformers cannot load. Missing or unreadable headers are
    left to the agent's own validation.
    """
    try:
        architecture = read_architecture(path)
    except GGUFFormatError:
        return None  # not readable here — let the agent report it properly
    if not architecture:
        return None
    supported = supported_architectures()
    if supported is None:
        return architecture
    if architecture.lower() not in supported:
        raise UnsupportedArchitecture(architecture, str(path))
    return architecture