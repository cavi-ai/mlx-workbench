This repository is `mlx-workbench`, a loopback-only web UI wrapper for
`mlx-agent` model lifecycle tasks on Apple Silicon. It shells out to the
vendored `mlx-agent` binary and renders results; there are no Python imports
from `mlx-agent` at runtime.

## Current truth docs

- `README.md` is the primary operator guide.
- `docs/mlx-workbench` contains versioned guide pages and documentation tests.
- `Makefile` defines the supported local command surface.

## Repository shape to keep in sync

- `vendor/mlx-agent` is a git submodule used as the execution engine.
- `scripts/mlx-workbench` is the launcher.
- `mlx_workbench/` is the application package.
- `tests/` contains unit and release-doc coverage.
- `mlx-mac/` is the native SwiftUI app (Xcode project, explicit file list in
  `project.pbxproj` — register new sources there). `make test-swift` runs its
  XCTest suite. Design specs for premium features live in
  `mlx-mac/docs/premium/`.
- The Swift app gates conversions with a **Conversion Quality Gate**: after a
  fresh scan confirms a conversion output, `VerificationCoordinator` serves it
  on an ephemeral loopback port (via the existing serve preview/confirm
  boundary), runs the canary suite in `Models/VerificationModels.swift`, and
  only then marks the workflow `verified`. The gate attaches in `App.swift`;
  without an attached verifier the workflow behavior is unchanged.
- Serve accepts HF repo ids only (agent contract: `model_not_local` for
  paths). `HFRepoID.serveIdentity(for:)` maps HF-cache snapshot paths to repo
  ids at the WorkbenchAPI boundary, and status comparisons normalize through
  the same identity. Converted outputs outside the HF cache cannot be served
  by the pinned agent yet — that is an upstream gap.
- The Compare tab runs **Measured Comparisons**: `ComparisonCoordinator`
  replays a prompt set against selected ready variants (one at a time, via
  the shared `ServeProbe` harness), persists runs, and feeds measured
  tok/s/TTFT into the RecommendationEngine as local benchmark evidence.
- The Wire tab also does **Cross-client Wiring**: `WiringCoordinator` detects
  installed clients (opencode/Continue/Zed/Aider writable; LM Studio/Ollama
  advisory-only) and previews/confirms atomic writes to each client's own
  config with per-file backups, drift re-checks, and rollback. Client write
  targets are a fixed allowlist of well-known config paths.
- The Run tab hosts the **Always-on Endpoint**: `EndpointSupervisor` keeps a
  chosen verified model serving on a stable loopback port by reconciling
  desired state against authoritative serve status (crash-loop guarded;
  enable/swap require verified models unless explicitly overridden).
  `LaunchAgentManager` optionally installs a RunAtLoad login item (no
  KeepAlive — the app's supervisor reconciles; receipts stay authoritative).
  A `MenuBarExtra` reports endpoint state and start/stop actions.
- The Duplicates tab hosts the **Disk Pressure Advisor**: `ReclaimAdvisor`
  ranks reclaim opportunities (stale per `UsageTracker` evidence, superseded
  by verified siblings, cross-root duplicates) and `ReclaimCoordinator`
  applies them as batched quarantine moves via `Services/Quarantine.swift`
  (a Swift port of `mlx_workbench/quarantine.py` — same guard: `.gguf` only,
  inside configured roots, never deletes).
- `ModelDetailsView` hosts the **Model Lineage**: `LineageIndexer` assembles
  a read-only provenance timeline per model (source, converted, verified,
  benchmarked, served, wired, quarantined) from the stores the app already
  keeps, with signature-based staleness dimming and Markdown/JSON export.
- `WatchCoordinator` provides **Watch & Regression Alerts**: upstream
  `mlx-agent watch diff` digests (baseline established silently on first
  check; network failures stay silent) and macOS/MLX environment-drift
  alerts offering one-click re-verification of stale verified models.
  Alerts dedupe by fingerprint and persist snooze/mute state.
- The Run view shows a **Memory-fit Advisor** verdict before serving:
  `FitAdvisor` estimates weights + KV cache + runtime overhead against live
  available memory (`MemorySnapshot` via Mach probes), yielding
  fits/tight/won't-fit with a suggested max context. Verdicts are derived,
  never persisted.
- `.run/`, `.venv/`, and `convert-queue.json` are generated/runtime state and
  are not source of truth.

## Fast onboarding (for a new agent)

- `make install` installs the required Python 3.12 environment and converter libs.
- `make start` runs the UI on `127.0.0.1:8765` and writes PID/logs to `.run/`.
- `make run` runs foreground.
- `make status`, `make stop`, `make open` are standard operations.
- `make test` and `python3 -m unittest discover -s tests -t .` run unit tests.
- `make docs-test` and `make docs-verify` run documentation contract checks.

## Ingest/pipeline behavior to respect

- Conversion plans are always previewed first.
- Only one conversion runs at a time.
- Confirmed jobs are written to a durable queue before launch.
- Queue entries are FIFO and auto-drain; they resume on restart.
- Actual running state is recovered from mlx-agent receipts (queue state is never the
  only authority).
- Queue state defaults to `$XDG_STATE_HOME/mlx-workbench/convert-queue.json`
  with fallback to `~/.local/state/mlx-workbench/convert-queue.json`.

## Security and boundaries

- UI binds loopback only; non-loopback hosts are rejected.
- Job arguments are argv tokens (no shell string execution).
- Quarantine operations are constrained to configured model roots and `.gguf` files.

## Review/build guidance for an agent

- Prefer project-local inspection first, keep edits scoped.
- Update this file when execution/integration behavior changes so it continues to
  match the README and docs.
- Do not invent cross-repo semantics for conversion/receipt behavior; state
  comes from observed implementation and tests.
