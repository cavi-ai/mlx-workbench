# Changelog

All notable changes to mlx-workbench are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The single source of truth for the version is `mlx_workbench/__init__.py`
(`__version__`). The Swift app's `MARKETING_VERSION`, the release-docs
contract, and this file's headings are kept in sync by
`make version-bump V=x.y.z`. `mlx-agent` is vendored under `vendor/mlx-agent`
and is versioned independently; submodule bumps are recorded here.

## [Unreleased]

### Fixed

- Native app settings save: the second and later saves failed with
  "config.json.tmp couldn't be moved" because `ConfigModule.save` used
  `moveItem`, which refuses to overwrite. Save is now idempotent
  (unique temp + replace-on-existing) and clears stale fixed-name temp
  litter from the old writer.
- Library STORAGE stat: `totalBytes` counted only GGUF sources, so a
  library of pure MLX outputs (HF-cache models) showed Zero KB. Outputs'
  on-disk sizes are now included (deduped by path).

## [0.2.0] - 2026-09-08
### Added

- Web UI modularization: DOM helpers (`dom.js`), API envelope unwrapping
  (`envelope.js`), payload assembly (`payloads.js`), and duplicate-group
  splitting (`duplicates.js`) extracted from `app.js` following the existing
  module pattern, with behavioral tests. Static JS tests now run as part of
  `make test` (new `test-js` target).
- View presentation tests: `HomeNextAction` derivation ladder (Home tab's
  next safe action).
- Serve converted outputs outside the Hugging Face cache: the agent's
  `serve start --path` flows through the workbench bridge, web route
  (`/api/serve/preview|start` accept exactly one of `repo`/`path`), and the
  SwiftUI app (WorkbenchAPI picks `--repo` vs `--path`; serve-status
  comparisons normalize through `ServerInfo.modelIdentity`). Requires the
  pinned mlx-agent with local-path serve support.

## [0.1.0] - 2026-09-07

Initial release. Local loopback UI over the vendored `mlx-agent` CLI, plus a
native SwiftUI app (`mlx-mac`) that layers a full model-lifecycle workflow on
the same agent boundary.

### Added

- Release provenance: this CHANGELOG (Keep a Changelog), a single version
  source of truth (`mlx_workbench.__version__`) mirrored by the Swift app's
  `MARKETING_VERSION` and the docs-release contract, `make version-bump
  V=x.y.z`, and `tests/test_version_sync.py` enforcing the sync.
- PR gates CI: `make test`, `make docs-test`, and `make test-swift` run on
  every pull request and push to main.
- Test hardening: Swift suites for quarantine parity, JSONStore,
  JSONCTolerant, workflow/verification stores, LaunchAgentManager, and
  WorkbenchPython; Python entry-point tests (`tests/test_main.py`).

- Web UI (`mlx_workbench/`): stdlib-only loopback HTTP server with token
  header auth and host allowlist, subprocess bridge to `scripts/mlx-agent
  --json`, and tabs for Scout, Adopt, Convert, Serve, Wire, Doctor, Models,
  Duplicates, Training, and Quantization Profiler.
- Durable FIFO conversion queue: preview-before-run, one job at a time,
  auto-drain, resume on restart, and running state recovered from mlx-agent
  receipts (queue schema 1.1 with legacy 1.0 migration).
- Move-not-delete quarantine for redundant `.gguf` weights, confined to
  configured model roots, with a JSONL ledger and classified refusals.
- Native SwiftUI app (`mlx-mac`) with a model library built from HF-cache and
  configured roots, workflow-tracked conversions, and persisted UI state.
- Premium feature layer in the native app (specs in `mlx-mac/docs/premium/`):
  - Conversion Quality Gate — every output is served on an ephemeral loopback
    port and probed with a canary suite before being marked verified.
  - Measured Comparisons — prompt-set replay (built-in sets, tool-calling set
    with argument validation, opencode history import) producing measured
    tok/s, TTFT, prompt-token/prefill estimates, and output diffs; results
    feed the RecommendationEngine as local benchmark evidence.
  - Cross-client Wiring — preview/confirm atomic config writes for opencode,
    Continue, Zed, and Aider (LM Studio and Ollama advisory-only) with
    per-file backups, drift re-checks, and rollback.
  - Always-on Endpoint — stable loopback port with crash-loop-guarded
    supervision, optional RunAtLoad login item, and menu-bar status item.
  - Disk Pressure Advisor — ranked reclaim opportunities (stale, superseded,
    cross-root duplicates, HF-cache prune) applied as batched quarantine
    moves.
  - Memory-fit Advisor — fits/tight/won't-fit verdict with suggested max
    context before serving.
  - Model Lineage — read-only provenance timeline per model with staleness
    dimming and Markdown/JSON export.
  - Watch & Regression Alerts — upstream HF watch digests and macOS/MLX
    environment-drift alerts with one-click re-verification.
- Serve HF-cache library models by repo id (`HFRepoID` identity mapping at
  the WorkbenchAPI boundary).
- `make accept-native-gguf RUNTIME_MANIFEST=...` — opt-in, manifest-gated
  real-data native GGUF-to-Run acceptance surface with per-run evidence.
- Versioned, deterministic documentation pipeline (`docs/mlx-workbench`,
  `make docs-test/docs-build/docs-verify/docs-release`) and a
  release-published GitHub workflow that gates on tests and uploads an
  immutable docs archive.

### Changed

- Python resolution centralized (`Services/WorkbenchPython.swift`): env
  override → repo `.venv` → PATH, shared by CLIProcess, RuntimeChecker, and
  the watch fingerprint probe.
- Health surface in the native app narrowed to environment status and
  findings; UX consolidated across Run/Compare/Wire/Library after live
  dogfooding.
- Internal: `server.py` route dispatch is a route table with per-route
  handlers instead of a single `_api` if-chain (behavior verified unchanged
  by the HTTP-level test suite).
- Internal: `AppHost.swift` split — `Config`, `ConfigModule`, coercion, and
  agent health moved to `Services/AppConfig.swift`.
- Internal: the release workflow now derives the expected tag from
  `mlx_workbench.__version__` instead of a hardcoded `v0.1.0`.

### Fixed

- Crash loop from spawning processes on the SwiftUI render path; the watch
  fingerprint probe now answers from a prewarmed cache and degrades to
  "unknown" on the main thread.
- Serve probes use a real model id and read reasoning deltas; live
  comparisons are runnable end to end.
- Conversion/serve integration bugs found by real-data dogfooding; workflow
  store mutations serialized process-wide; rescan after terminal conversion
  status.

### Security

- UI binds loopback only; non-loopback hosts are rejected.
- Job arguments are passed as argv tokens (no shell string execution).
- Quarantine operations are constrained to configured model roots and
  `.gguf` files; nothing is deleted.

[Unreleased]: https://github.com/cavi-ai/mlx-workbench/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/cavi-ai/mlx-workbench/releases/tag/v0.2.0
[0.1.0]: https://github.com/cavi-ai/mlx-workbench/releases/tag/v0.1.0
