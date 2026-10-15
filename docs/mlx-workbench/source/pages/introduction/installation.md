# Installation

MLX Workbench is two parts: the native app, and a local checkout that holds the MLX Agent engine and its Python runtime. Install both.

## Requirements

- macOS on Apple Silicon
- Git with submodule support
- Python 3.12; [uv](https://github.com/astral-sh/uv) is recommended, otherwise `brew install python@3.12`
- Xcode, for source builds only
- Disk space for source weights, converted outputs, comparison outputs and quarantine

## 1. Set up the engine checkout

```bash
git clone --recurse-submodules https://github.com/cavi-ai/mlx-workbench.git
cd mlx-workbench
git checkout {{RELEASE_TAG}}
git submodule update --init --recursive
make install
```

`make install` creates a project `.venv` with Python 3.12, installs the pinned `requirements.txt` (torch, transformers 4, gguf, mlx-lm, accelerate) and the engine's `requirements-lab.txt`, then runs `make check`. Re-run it at any time to refresh the environment. `make pip-audit` audits the pinned packages against the OSV database.

The engine is the vendored submodule at `vendor/mlx-agent`, pinned to a tested revision. If Settings or `MLX_AGENT_HOME` already names a usable engine checkout, `make install` uses that one and leaves the submodule alone.

## 2. Install the app

Download `mlx-workbench-{{PRODUCT_VERSION}}.dmg` from the [{{RELEASE_TAG}} release](https://github.com/cavi-ai/mlx-workbench/releases/tag/{{RELEASE_TAG}}) and drag **MLX Workbench** into **Applications**. Release builds are signed with a Developer ID and notarized.

Open the app. The Setup Assistant checks the engine, the runtime and your model folders in four steps. Set **Settings → Engine → mlx-agent checkout** to the checkout's `vendor/mlx-agent`. Distribution builds contain no build-machine source path, so this setting is required; the app then uses that checkout's `.venv` for conversion and serving. When the runtime is missing, **Install Runtime…** runs `make install` in that checkout.

## Or build from source

In the checkout, after `make install`:

```bash
make start
```

`make start`, `make run` and `make open` build the app with Xcode and open it. `make build-swift` builds the Release app without opening it. A source build finds its own `vendor/mlx-agent` without configuration.

`make dmg` packages a distribution build as `MLX Workbench.app` on a disk image under `.release/`. It is ad-hoc signed unless `DEVELOPER_TEAM=<team id>` is set, which archives, exports with Developer ID, notarizes and staples.

## Optional runtimes

| Runtime | Install | Used by |
|---|---|---|
| mlx-vlm, mlx-audio backends | One click in the Add from Hugging Face window | Vision, audio and other models those backends convert or serve |
| Study tools | **Compare → Controlled studies → Install study tools** | Controlled experiments |
| Video runtime | **Compare → Controlled studies → Install video runtime** | Video generation in studies (adds Torch) |
| Strata | `make install-strata` | Qwen3.8-Flash-Next GGUF serving; see [Strata](../workflows/strata.md) |

Optional backends install into their own environments from hash-locked requirement files and leave the main `.venv` unchanged.

## Updates

Installed apps update from **Settings → Updates**. **Releases** follows published releases; **Nightly** follows the nightly build of `main`. A download is installed only when its sha256 matches GitHub's published digest and it is a notarized Developer ID build of MLX Workbench. The previous app moves to the Trash.

Source builds update their checkout instead: the official channel checks out the newest `v*` tag, the beta channel fast-forwards to `origin/main`. Both refuse a dirty tree, update submodules and rebuild with `make build-swift` before relaunching.

A DMG update replaces only the app. Keep the engine checkout on the matching tag and re-run `make install` there; see [Version and support](../release/version-and-support.md).
