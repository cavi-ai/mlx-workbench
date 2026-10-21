# Installation

MLX Workbench uses the native app, local MLX Agent sources and a Python environment. Distribution builds include the engine sources; Python dependencies are installed separately.

## Requirements

- macOS on Apple Silicon
- Apple's Command Line Tools (`xcode-select --install`) for the runtime installer
- Git with submodule support, when using a source checkout
- Python 3.12; [uv](https://docs.astral.sh/uv/getting-started/installation/) is recommended. If Homebrew is already installed, `brew install python@3.12` is another option.
- Xcode, for source builds only
- Disk space for source weights, converted outputs, comparison outputs and quarantine

## Install the app and bundled engine

Download `mlx-workbench-{{PRODUCT_VERSION}}.dmg` from the [{{RELEASE_TAG}} release](https://github.com/cavi-ai/mlx-workbench/releases/tag/{{RELEASE_TAG}}) and drag **MLX Workbench** into **Applications**.

In Setup Assistant, choose **Use bundled engine…** and confirm **Prepare engine**. The app validates the packaged manifest and file hashes, then copies the pinned sources into a versioned folder under `~/Library/Application Support/mlx-workbench/runtimes`. Only a successful preparation updates the selected engine. Identical sources are reused; changed files in an existing runtime folder are refused rather than overwritten. An existing configured checkout remains selected unless you explicitly choose the bundled engine.

Continue to the runtime step and choose **Install Runtime…**. This separate confirmation runs `make install` in the prepared folder to create its Python environment. Preparing sources alone does not install packages, download models or require a source clone.

Before installation, Workbench checks Command Line Tools, Python and uv without installing anything. Missing prerequisites appear beside a **Recheck prerequisites** action. Tool discovery includes standard Homebrew and user-local locations so launching from Finder does not require shell startup files. The confirmed installer uses that search path, including the new environment's commands. uv may download Python 3.12 as part of the confirmed installation. An incomplete or wrong-version existing environment requires repair or another engine folder; Workbench does not delete it.

When a prerequisite is missing, **Copy command** copies the displayed command
for you to run in Terminal; **Copied** confirms the clipboard write. Workbench
shows the Homebrew Python command only when a Homebrew executable is found.
Without Homebrew, the Python prerequisite links to the official **uv installation
guide**. A missing bootstrap `python3` links to the **Python setup guide**.
Opening a guide or copying a command installs nothing. After completing the
external setup, return to **Recheck prerequisites**, then review **Install Runtime…**.
The same guidance is available in Setup Assistant and Health. Setup Assistant
keeps its step content scrollable and its navigation buttons visible in smaller
windows.

## Or use an engine checkout

```bash
git clone --recurse-submodules https://github.com/cavi-ai/mlx-workbench.git
cd mlx-workbench
git checkout {{RELEASE_TAG}}
git submodule update --init --recursive
make install
```

`make install` creates a project `.venv` with Python 3.12, installs the pinned `requirements.txt` (torch, transformers 4, gguf, mlx-lm, accelerate) and the engine's `requirements-lab.txt`, then runs `make check`. Re-run it at any time to refresh the environment. `make pip-audit` audits the pinned packages against the OSV database.

The engine is the vendored submodule at `vendor/mlx-agent`, pinned to a tested revision. If Settings or `MLX_AGENT_HOME` already names a usable engine checkout, `make install` uses that one and leaves the submodule alone.

Open the app and set **Settings → Engine → mlx-agent checkout** to the checkout's `vendor/mlx-agent`. The Setup Assistant checks the engine, runtime and model folders. Distribution builds contain no build-machine source path; the app uses the selected checkout's `.venv` for conversion and serving. When the runtime is missing, **Install Runtime…** runs `make install` in that checkout.

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
| Study tools | **Studies → Runtime setup → Install study tools** | Controlled experiments |
| Video runtime | **Studies → Runtime setup → Install video runtime** | Video generation in studies (adds Torch) |
| Strata | `make install-strata` | Qwen3.8-Flash-Next GGUF serving; see [Strata](../workflows/strata.md) |

Optional backends install into their own environments from hash-locked requirement files and leave the main `.venv` unchanged.

## Updates

Installed apps update from **Settings → Updates**. **Releases** follows published releases; **Nightly** follows the nightly build of `main`. A download is installed only when its sha256 matches GitHub's published digest and it is a notarized Developer ID build of MLX Workbench. The previous app moves to the Trash.

Source builds update their checkout instead: the official channel checks out the newest `v*` tag, the beta channel fast-forwards to the reviewed commit from `origin/main`. Changing channels discards the previous offer. Both refuse a dirty or changed checkout, update submodules and rebuild with `make build-swift` before relaunching. Checks run in the background; Git checks stop after 60 seconds and update commands after 120 seconds.

A DMG update replaces only the app and does not switch the selected engine. To use its new bundled sources, reopen Setup Assistant and explicitly prepare them, then install their runtime. For a source checkout, use the matching tag and re-run `make install` there; see [Version and support](../release/version-and-support.md).
