# Make targets

The `Makefile` is the supported command surface. Run `make help` for the short list. Every target that touches the machine requires an Apple Silicon Mac.

## Setup

| Target | Action |
|---|---|
| `make install` | Initialize the engine submodule when no engine is configured, create `.venv` with Python 3.12, install `requirements.txt` and the engine's `requirements-lab.txt`, then run the checks |
| `make install-convert` | Reinstall the Python packages into an existing `.venv` |
| `make install-strata` | Install the optional Strata runtime into `~/.cache/mlx-agent/strata` |
| `make check` | Verify the configured engine checkout has `scripts/mlx-agent` |
| `make doctor` | `make check`, then verify the conversion environment |
| `make pip-audit` | Audit `.venv` and every optional backend lock against the OSV database |

## Run

| Target | Action |
|---|---|
| `make start`, `make run`, `make open` | Build the Release app and open it |
| `make build-swift` | Build the Release app into `.run/swift-build` |
| `make run-swift` | Open the built app |
| `make dmg` | Package a distribution build as a DMG under `.release/`; add `DEVELOPER_TEAM=<team id>` to sign with Developer ID and notarize, `DMG_CHANNEL=nightly` for a nightly name |

## Test

| Target | Action |
|---|---|
| `make test` | Python compatibility and contract tests |
| `make test-swift` | XCTest suite for the native app |
| `make test-native-ui` | UI tests in an isolated macOS VM; `NATIVE_UI_BASE_VM` names a prepared Tart VM |
| `make test-live-scan` | Opt-in, read-only check of scanned model sizes against the filesystem |
| `make test-swift-live-scan` | The same check through the native app's scan |
| `make render-clients`, `make render-discover`, `make render-lmstudio`, `make render-settings` | Render a screen's states into an xcresult bundle |
| `make accept-native-gguf RUNTIME_MANIFEST=/absolute/path/runtime.json` | Opt-in real conversion from an allowlisted local GGUF through to Run; writes per-run evidence |
| `make accept-native-mlx RUNTIME_MANIFEST=/absolute/path/runtime.json` | Opt-in verification, serving and completion request for an existing local MLX model; writes per-run evidence |

The live-scan and acceptance targets are not part of `make test`. Acceptance may perform a real conversion and runs only with an explicit runtime manifest.

Run native acceptance inside a prepared Apple Silicon macOS VM with an active desktop session. The MLX target uses the same manifest fields as GGUF acceptance: `source_path`, `model_query`, `agent_home`, `config_path`, and `evidence_root`. Its source is an existing model directory with `config.json` and safetensors weights under explicitly configured `mlx_roots`; evidence must be outside those roots and the configured host must be loopback. It does not download or convert a model. Set `MLX_WORKBENCH_PYTHON` to the runtime interpreter when needed. A skipped native test fails acceptance.

## Docs and release

| Target | Action |
|---|---|
| `make docs-test` | Documentation contract tests |
| `make docs-build` | Build the versioned docs into `docs/mlx-workbench/v<version>/` |
| `make docs-verify` | Verify the built docs against their manifest |
| `make docs-release` | Build, verify and package the docs archive and checksum under `.release/` |
| `make version-bump V=x.y.z` | Bump the version everywhere and promote the changelog's Unreleased section |

## Clean

| Target | Action |
|---|---|
| `make clean` | Remove `.run/` |
| `make clean-swift` | Remove the Swift build directory |
| `make clean-venv` | Remove `.venv` |
