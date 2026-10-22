This repository is `mlx-workbench`, a native SwiftUI application for
`mlx-agent` model lifecycle tasks on Apple Silicon. It shells out to the
vendored `mlx-agent` binary and renders results. The application has no web
server.

## Current truth docs

- `README.md` is the entry point; `docs/mlx-workbench/source/pages` is the
  operator guide, published per release to cavi-ai.xyz/docs/mlx-workbench
  (`docs/mlx-workbench/CONSUMER.md`). Behavior changes update the matching
  page in the same change. Feature behavior lives there, not here.
- `Makefile` defines the supported local command surface.
- `mlx_workbench/__init__.py` (`__version__`) is the single version source of
  truth; `CHANGELOG.md` records releases. `make version-bump V=x.y.z` bumps
  both plus the Swift `MARKETING_VERSION` and docs-test constants;
  `tests/test_version_sync.py` enforces the sync.
- Premium feature design specs live in `mlx-mac/docs/premium/`.

## Repository map

- `vendor/mlx-agent`: git submodule, the execution engine.
- `scripts/mlx-workbench` → `mlx_workbench/__main__.py`: opens the built app
  (`--app`, `$MLX_WORKBENCH_APP`, or the Release build under `.run/swift-build`).
- `mlx_workbench/`: Python configuration and compatibility utilities used by
  `make install`/`make check`. `config.py` preserves keys it does not manage;
  `serve_presets.py` validates `serve-presets.json`; `convert_queue.py`
  imports the engine's `mlx_agent.convert_queue`.
- `tests/`: Python unit and release-doc coverage. `tests/fixtures/` is shared
  by the Python and XCTest suites; a fixture change keeps both green
  (`tests/fixtures/README.md`).
- `mlx-mac/`: the native app. `project.pbxproj` has an explicit file list:
  register new sources there. `make test-swift` runs the XCTest suite;
  `make dmg` packages a distribution build (no source path compiled in);
  `DEVELOPER_TEAM=<team id>` signs, notarizes and staples it. The app icon
  master is `mlx-mac/assets/app-icon.svg`.
- `.run/`, `.venv/`, `convert-queue.json`: generated runtime state, never a
  source of truth.

## Native app map

Behavior detail for each area is in the operator guide; this lists owners.

- `AppHost` (`@Observable`): shared state and coordinators. Views read only
  the properties they render and observe each child coordinator they display
  with `@ObservedObject`. `AppHost.startLiveServices()` owns all launch-time
  live work.
- Routes: `UI/ContentView.swift`; cross-tab requests go through
  `AppHost.handoffs` (`UI/RouteHandoffs.swift`), one pending request per kind.
- Engine calls: `WorkbenchAPI` (dispatch worker per call, actor never
  blocked) → `CLIProcess` (argv tokens, own process group, stdout/stderr
  drained on dedicated threads, SIGTERM then SIGKILL after 2 s;
  `CLIProcessRegistry` stops live children on quit). `serve status` reuses
  one persistent engine process (`Bridge/AgentWorker.swift`,
  `Resources/agent-worker.py`) and falls back to the CLI.
  Status calls share a monotonic deadline across startup, queueing and fallback;
  cancellation stops their owned worker, without holding the state lock during I/O.
  Detached work (`convert start`, `serve`) uses its own session and is not stopped.
  `BoundedProcessCapture` runs other commands from blocking workers with an
  output limit and a deadline.
- Python resolution: `Services/WorkbenchPython.swift` (env → repo `.venv` →
  PATH), shared by every launcher.
- Durable JSON state: `JSONStore` (one lock per file path shared by every
  instance, decoded-value cache keyed by inode/size/mtime, temporary file and
  directory fsync around the replace, symlinks refused). Workflow,
  verification and comparison histories use `RecordArchive` (transactional
  per-record storage, one-time JSON migration, legacy JSON kept as backup)
  through `ModelWorkflowStore`, `VerificationStore` and
  `ComparisonRecordArchive`, on their coordinators' serial I/O queues.
  Usage and Watch histories also use serial I/O queues. Watch batches new alerts
  in one locked JSON mutation and publishes them after the write succeeds.
- Default state paths: `Services/WorkbenchStatePaths.swift`.
- Model identity and occupancy: `HFRepoID` (cached symlink resolution,
  `HFRepoID.Identity`), `ModelOccupancy` via `AppHost.occupancy`; Stop,
  Unload, reclaim and guidance refuse claimed models.
- Library: `ModelLibraryBuilder`, `LibraryView`; inspector tasks
  (`InferenceTaskCoordinator`, `InferenceTaskPanels`); LM Studio source
  (`LMStudioShelfResolver`, `LMStudioShelfPresentation`); Hosted models
  (`ModelHostsCoordinator`, `ModelHostClient`, `HostResourceClient`, one
  `ModelHostAdapter` per provider in `Services/*HostAdapter.swift`,
  `model-hosts.json`, tokens in Keychain).
  `HostHTTPClient` receives bounded data chunks with a per-task redirect fence;
  cancellation and response rejection cancel only that request.
- Prepare and intake: `IntakeCoordinator`, `ModelWorkflowCoordinator`,
  `ConversionWorkflow`; Quality Gate: `VerificationCoordinator` with
  per-task canaries in `Models/VerificationModels.swift`; source cleanup:
  `ConvertedSourceCleanup`.
- Run and endpoints: `EndpointSupervisor` (fleet in `endpoint-fleet.json`,
  JIT gateway, memory policy), `FitAdvisor`, `FleetFitAdvisor`, role router
  via `mlx-agent fleet render/apply`, `LaunchAgentManager` (RunAtLoad only).
- Compare: `ComparisonCoordinator` (chat via `ServeProbe`, media via
  `ComparisonMediaRunner`, histories via `ComparisonHistoryWorker`),
  `HostedComparisonCoordinator`; prompt sets via `PromptSetDraft`; outputs in
  `ComparisonOutputStore`. Views: `QuantView.swift`, `ComparePresentation.swift`,
  `CompareMediaViews.swift`, `ComparisonPromptEditorViews.swift`,
  `ComparisonPickerViews.swift`, `CompareSheets.swift`.
- Wire: `WiringCoordinator` (allowlisted client configs, backups, rollback).
- Duplicates: `ReclaimAdvisor`, `ReclaimCoordinator`, `Services/Quarantine.swift`.
- Studies and Training: `LabCoordinator`, `TrainingSession`.
- Watch, notifications, setup and updates: `WatchCoordinator`,
  `AlertNotifier`, `SetupCoordinator`, `UpdateCoordinator` (checkout
  installs), `Services/ReleaseUpdater.swift` (installed builds).
- Workflow evidence: `WorkflowReport` (schema 1) in `workflow-evidence.json`,
  `AgentTaskAdvisor`, `LineageIndexer`.

## Invariants

- Never spawn a process synchronously inside view evaluation; a
  `waitUntilExit` reached from a view body crashes the app. Probes answer
  from prewarmed caches on the main thread.
- Hosted unit tests never start live services or touch real state: live work
  stays behind `AppHost.startLiveServices()`, state paths resolve through
  `WorkbenchStatePaths.hostedTestRoot`, and tests use private `UserDefaults`
  suites. UI tests launch a separate app process.
- The native app never writes `convert-queue.json`; Jobs uses
  `mlx-agent lab queue` (`WorkbenchAPI.conversionQueue`).
- Mutations are previewed, rechecked for drift at confirmation, and move
  files to Quarantine or the macOS Trash; nothing is deleted permanently.
- Hosted inventory refresh is read-only; host memory actions are serialized,
  confirmed, never retried automatically and followed by readback.
- Media comparisons never feed the RecommendationEngine; Promote winner is
  chat-only; recommendations require matching model signatures and
  environment fingerprints.
- Workflow evidence is imported explicitly and never relabeled as current.
- Native serving, verification and chat comparisons use `--runtime auto`;
  intake never executes repository code or passes `--trust-remote-code`.
- `make accept-native-gguf RUNTIME_MANIFEST=…` is the only real-data
  acceptance run; never invoke it with an arbitrary local model.

## Fast onboarding

- `make install` installs the Python 3.12 environment and converter libs.
- `make start` (also `make run`, `make open`) builds the Release app under
  `.run/swift-build` and opens it.
- `make test` and `python3 -m unittest discover -s tests -t .` run unit tests.
- `make docs-test` and `make docs-verify` run documentation contract checks.

## Ingest/pipeline behavior to respect

- Conversion plans are always previewed first.
- Only one conversion runs at a time.
- Confirmed jobs are written to a durable queue before launch.
- Queue entries are FIFO and auto-drain; they resume on restart.
- Running state is recovered from mlx-agent receipts (queue state is never
  the only authority).
- Queue state defaults to `$XDG_STATE_HOME/mlx-workbench/convert-queue.json`
  with fallback to `~/.local/state/mlx-workbench/convert-queue.json`.

## Security and boundaries

- `config.json` accepts only loopback hosts (`127.0.0.1`, `localhost`,
  `::1`); its key universe is closed (`config._ALLOWED_KEYS`), and Settings
  edits only its visible controls.
- Job arguments are argv tokens (no shell string execution); agent
  subprocesses get an allowlisted environment (`bridge.agent_environment`).
- Quarantine is constrained to configured model roots; purge moves files to
  the macOS Trash and never touches the ledger.
- Durable state writes are atomic and refuse symbolic links at the target or
  temporary path (`mlx_workbench/atomicio.py`, `JSONStore`, Swift
  `Quarantine`, `WiringCoordinator`).
- `mlx_workbench/audit.py` appends a bounded local audit trail; durable stores
  stay authoritative.
- Convert/serve dependencies are pinned in `requirements.txt` and
  `vendor/mlx-agent/requirements-lab.txt`; `make pip-audit` checks them and
  every optional backend lock (`PIP_AUDIT_IGNORES` lists accepted risks).

## Review/build guidance

- Prefer project-local inspection first and keep edits scoped.
- Update this file when execution or integration ownership changes.
- Do not invent cross-repo semantics for conversion or receipt behavior;
  state comes from observed implementation and tests.
