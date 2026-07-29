"""Convert/serve runtime dependency checks for the active interpreter."""

from __future__ import annotations

import importlib.util
import shutil


CONVERT_MODULES = ("torch", "transformers", "gguf")
CONVERT_EXECUTABLES = ("mlx_lm.convert",)
SERVE_EXECUTABLES = ("mlx_lm.server",)
INSTALL_HINT = "make install"


def _module_present(name):
    return importlib.util.find_spec(name) is not None


def _executable_present(name):
    return shutil.which(name) is not None


def missing_modules(names=CONVERT_MODULES):
    return [name for name in names if not _module_present(name)]


def missing_executables(names=CONVERT_EXECUTABLES):
    return [name for name in names if not _executable_present(name)]


def convert_ready():
    """Whether this interpreter can run a GGUF → MLX conversion."""
    modules = missing_modules(CONVERT_MODULES)
    executables = missing_executables(CONVERT_EXECUTABLES)
    ok = not modules and not executables
    parts = []
    if modules:
        parts.append("missing modules: {0}".format(", ".join(modules)))
    if executables:
        parts.append("missing on PATH: {0}".format(", ".join(executables)))
    message = (
        "Convert dependencies ready."
        if ok
        else "{0}. On this Mac run `{1}`.".format("; ".join(parts), INSTALL_HINT)
    )
    return {
        "ok": ok,
        "modules": {
            name: _module_present(name) for name in CONVERT_MODULES
        },
        "executables": {
            name: _executable_present(name) for name in CONVERT_EXECUTABLES
        },
        "missing_modules": modules,
        "missing_executables": executables,
        "install": INSTALL_HINT,
        "message": message,
    }


def serve_ready():
    """Whether mlx_lm.server is available for the Serve tab."""
    missing = missing_executables(SERVE_EXECUTABLES)
    ok = not missing
    return {
        "ok": ok,
        "executables": {
            name: _executable_present(name) for name in SERVE_EXECUTABLES
        },
        "missing_executables": missing,
        "install": INSTALL_HINT,
        "message": (
            "Serve runtime ready."
            if ok
            else "missing on PATH: {0}. On this Mac run `{1}`.".format(
                ", ".join(missing), INSTALL_HINT
            )
        ),
    }


def runtime_report():
    """Combined runtime status for health / Settings."""
    convert = convert_ready()
    serve = serve_ready()
    return {
        "convert": convert,
        "serve": serve,
        "install": INSTALL_HINT,
        "ok": convert["ok"] and serve["ok"],
    }
