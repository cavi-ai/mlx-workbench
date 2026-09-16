This repository is `mlx-workbench`, a loopback-only web UI wrapper for
`mlx-agent` model lifecycle tasks on Apple Silicon. It shells out to the
vendored `mlx-agent` binary and renders results; there are no Python imports
from `mlx-agent` at runtime.

## Current truth docs

- `README.md` is the primary operator guide.
- `docs/mlx-workbench` contains versioned guide pages and documentation tests.
- `Makefile` defines the supported local command surface.
- `mlx_workbench/__init__.py` (`__version__`) is the single version source of
  truth; `CHANGELOG.md` records releases. Use `make version-bump V=x.y.z` to
  bump both plus the Swift `MARKETING_VERSION` and docs-test constants;
  `tests/test_version_sync.py` enforces the sync.

## Repository shape to keep in sync

- `vendor/mlx-agent` is a git submodule used as the execution engine.
- `scripts/mlx-workbench` is the launcher.
- `mlx_workbench/` is the application package. The web UI is scoped to the
  core loop (Models / Convert / Duplicates / Scout / Doctor / Serve /
  Training Studio / Compare Conversions / Model Arch / Jobs / Settings);
  Adopt, Wire, and the other lifecycle surfaces live in the native app.
- The shared `config.json` contract: `mlx_workbench/config.py` preserves keys
  it does not manage (e.g. the native app's premium toggles), and the web
  Settings save overlays posted fields onto the loaded config so a web save
  never strips native-app keys. Keep that invariant.
- `tests/fixtures/` is the shared contract-fixture set consumed by BOTH the
  Python suite (`tests/test_contract_fixtures.py`) and the XCTest suite
  (`ScanContractTests`, `WorkbenchAPISubprocessTests`, `ContractFixtureTests`).
  A fixture change must keep both suites green; see `tests/fixtures/README.md`.
- The web UI's durable convert queue (`convert-queue.json`, schema 1.1) has
  exactly one writer: the web server. The native app reads it read-only via
  `Services/WebConvertQueue.swift` and shows it in Jobs as "Web Queue" with
  provenance; schema and path resolution mirror
  `mlx_workbench/convert_queue.py` and are pinned by shared fixtures. Never
  write to that file from the native app.
- `tests/` contains unit and release-doc coverage.
- `mlx-mac/` is the native SwiftUI app (Xcode project, explicit file list in
  `project.pbxproj` — register new sources there). `make test-swift` runs its
  XCTest suite. Design specs for premium features live in
  `mlx-mac/docs/premium/`.
- `make accept-native-gguf RUNTIME_MANIFEST=/absolute/path/runtime.json` is the
  opt-in real-data native GGUF-to-Run acceptance surface. Its runner validates
  an explicit allowlisted local source and loopback config, selects only the
  existing golden-path UI test, and writes per-run evidence beneath the
  manifest's `evidence_root`. Never invoke it with an arbitrary local model.
- The Swift app gates conversions with a **Conversion Quality Gate**: after a
  fresh scan confirms a conversion output, `VerificationCoordinator` serves it
  on an ephemeral loopback port (via the existing serve preview/confirm
  boundary), runs the canary suite in `Models/VerificationModels.swift`, and
  only then marks the workflow `verified`. The gate attaches in `App.swift`;
  without an attached verifier the workflow behavior is unchanged.
- Serve accepts HF repo ids or local directories (`serve start --path`,
  upstream ≥ the local-path serve change). `WorkbenchAPI.serveModelArguments`
  maps HF-cache snapshot paths to repo ids and absolute paths outside the HF
  layout to `--path`; status comparisons normalize through
  `ServerInfo.modelIdentity` (repo id or path, whichever the agent reports).
- The Compare tab runs **Measured Comparisons**: `ComparisonCoordinator`
  replays a prompt set against selected ready variants (one at a time, via
  the shared `ServeProbe` harness), persists runs, and feeds measured
  tok/s/TTFT into the RecommendationEngine as local benchmark evidence.
  **Promote winner** (on a completed run) chains the verdict:
  `AppHost.setPreferredModel` persists the winner as the use-case preference
  (`recommendation-preferences.json`), optionally enables/swaps the
  Always-on Endpoint (verified gating kept), and links onward to the Wire
  and Duplicates tabs — wiring and reclaim keep their own preview/confirm
  flows.
  Samples also capture `prompt_tokens` (prefill speed = prompt tokens over
  TTFT, always labeled an estimate) and tool calls (builtin "Tool calling"
  set offers `PromptToolSpec`s; streamed `tool_calls` are counted and their
  arguments validated against the schema's required keys). Past runs are
  browsable history with Swift Charts; `ModelPerformanceProfile` aggregates
  per-model stats into Model Details.
- Python resolution is centralized in `Services/WorkbenchPython.swift`
  (env override → repo `.venv` → PATH) and shared by `CLIProcess`,
  `RuntimeChecker`, and the watch fingerprint probe. `RuntimeInstaller`
  runs `make install` in-app when the runtime is missing.
- **Never spawn a process synchronously inside view evaluation.** A
  `Process.waitUntilExit` reached from a view body/layout crashes the app
  (AttributeGraph precondition via re-entrant layout). The watch
  fingerprint probe answers from a prewarmed cache and degrades to
  "unknown" on the main thread instead of probing. Keep this invariant.
- The Wire tab also does **Cross-client Wiring**: `WiringCoordinator` detects
  installed clients (opencode/Continue/Zed/Aider writable; LM Studio/Ollama
  advisory-only) and previews/confirms atomic writes to each client's own
  config with per-file backups, drift re-checks, and rollback. Client write
  targets are a fixed allowlist of well-known config paths.
- The Run tab hosts the **Always-on Endpoint**: `EndpointSupervisor` keeps a
  chosen verified model serving on a stable loopback port by reconciling
  desired state against authoritative serve status (crash-loop guarded;
  enable/swap require verified models unless explicitly overridden).
  Internally it is fleet-shaped (spec 09 P1): `EndpointFleetConfig` slots in
  `endpoint-fleet.json` (migrated one-time from the legacy
  `endpoint-config.json`, which stays read-only), one reconcile pass over
  all enabled slots, per-slot crash guards. The single-slot API is a shim
  over slot 0. The Run tab's **Endpoints** section (spec 09 P2) lists the
  slots with per-slot status/restarts/fit chip, enable/disable, role picker,
  remove,   and an "Add endpoint" flow (suggested next-free port, verified
  gating with explicit unverified override, cap 4). The menu bar aggregates
  ("N of M endpoints running", worst-state icon, per-slot start/stop).
  The **fleet memory budget** (spec 09 P3): `FleetFitAdvisor` sums
  FitAdvisor estimates over enabled slots against one live
  `MemorySnapshot` (per-slot runtime overhead; unknown model sizes make the
  verdict unknown, never fabricated). The section header shows the summed
  verdict; enabling a slot that tips the fleet past won't-fit needs an
  explicit inline override.
  `LaunchAgentManager` optionally installs a RunAtLoad login item (no
  KeepAlive — the app's supervisor reconciles; receipts stay authoritative).
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
- **Completion notifications**: `ModelWorkflowCoordinator.onTerminalState`
  fires once when a workflow enters a terminal state (completed / verified /
  verificationFailed / failed) and AppHost wires it to `AlertNotifier`
  (Notification Center; silent when permission is denied). Restores and
  launch-loads never notify — only live transitions.
- `SetupCoordinator` provides the **first-launch Setup Assistant**: a guided
  sheet over the app's existing probes (agent health, runtime report,
  discovered roots) with the RuntimeInstaller for one-click runtime setup.
  Persisted via UserDefaults once completed; re-openable from Health.
- `UpdateCoordinator` provides **in-app updates** for checkout-run installs:
  Official channel checks out the newest `v*` tag, Beta fast-forwards to
  `origin/main`; both refuse a dirty tree, sync submodules, and finish with a
  streamed `make build-swift` rebuild-and-relaunch. Git runs as argv tokens
  through an injectable runner; the apply path is integration-tested against
  a throwaway git repo.
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
- `make accept-native-gguf` is excluded from normal tests and requires an
  explicit runtime manifest because it may perform a real conversion.
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
