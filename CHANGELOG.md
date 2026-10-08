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
### Added

- Serve presets ("endpoint profiles"): save the current model, runtime,
  port, max tokens, and LoRA adapter as a named preset from the Serve tab,
  then relaunch it in two clicks (Load → Preview & Start). Presets persist
  in their own state file (`serve-presets.json`, schema-validated, atomic
  writes) so neither frontend's config save can clobber them. The tab also
  gains a "Find free port" suggestion, max-tokens and adapter fields
  surfaced from the agent CLI, and a "Copy URL" action on running servers
  (`http://127.0.0.1:<port>/v1`).
- Quarantine lifecycle in the web UI: the Quarantine Area lists what is
  being held, and each row gains a "Delete permanently" action that moves
  the file to the macOS Trash and marks its ledger entry `deleted_at`
  (append-only history kept). The ledger file itself can never be deleted
  and symlinked targets are refused; every purge lands in the audit trail
  (`quarantine.delete`).
- Scan cache (stale-while-revalidate): `/api/scan` now returns the last
  scan immediately (with `cached`/`stale` flags) and refreshes in the
  background, so screens never block on a full signature walk; `?refresh=1`
  (the Rescan button) still scans synchronously. The UI also keeps the
  last-known inventory in `localStorage` so a reload renders models
  instantly, worst case showing a clearly-labeled cold cache.
- Serve tab UX: the model field is a picker fed by converted models from the
  latest scan (repo id or local path) instead of raw free text, and the
  chosen runtime is remembered across visits.
- Web UI: conversion progress banner (`/api/convert/progress`), a live
  Convert tab panel with dismiss and retry, and a Compare Conversions
  redesign (scan-fed model picker, 4-bit / 8-bit / both).
- Native app, Add from Hugging Face: paste a link or `org/name` for a
  conversion verdict before any download; optional converter backends
  (mlx-vlm, mlx-audio, mlx-embeddings, mflux, mlx-video) install into
  isolated hash-locked environments; downloads are confirmed and
  receipt-tracked; the output size estimate is read from safetensors headers.
- Native app model types beyond chat: speech-to-text, classification, image
  generation, video generation, and speculative-decoding drafters.
  Speech-to-text, classification, and image-generation conversions each get
  a Quality Gate canary; image-generation models get a Generate panel;
  drafters are never served.
- Native app ports: Edge0/Audio8-ASR-Infinite (mlx-audio), Laya
  classification (mlx-embeddings, 8-bit only), the Qwen-Image 2.1 recipe
  with its LoRA (mflux), and DeepSeek-V4 DSpark `dflash` drafter GGUFs.
- Native app Compare modes: vision, video understanding, speech to text,
  text to speech, image generation, and video generation; each prompt's
  output is saved under `comparison-outputs/` and the 10 newest media runs
  keep their files.
- Native app Compare decisions: model pickers and filters, reviewed task
  outcomes, **Promote winner** (saves the use-case preference and can swap
  the always-on endpoint), and task-specific model guidance with
  **Use model…** and **Wire into clients…**.
- Native app workflow evidence: capture requests for Claude, OpenClaw,
  OpenCode, and custom harnesses; previewed report import; runtime,
  timing-breakdown, task-quality, peak-memory, and quality-vs-runtime
  charts; **Compare these models** and **Measure this workflow…**.
- Native app fleet endpoints: up to four always-on endpoint slots
  (`endpoint-fleet.json`, migrated once from `endpoint-config.json`) with
  per-slot crash guards, a menu-bar aggregate, a fleet memory budget, and
  role routing through `mlx-agent fleet --port-map`.
- Native app reclaim: task-scoped replacement chains, macOS Trash for
  quarantined GGUF files, and previewed quarantine, Put back, and Trash for
  local MLX model folders.
- Native app source reuse and cleanup: intake reuses ready local models,
  local directories are served by path, downloaded checkpoints go straight
  to conversion, and verified conversions offer source cleanup to the Trash
  with a recovery journal and a guarded restore from Duplicates.
- Native app shell: sidebar navigation, a sortable Library table with an
  inspector, grouping by type and use case, a Prepare progress ring with
  the converter log, a read-only "Web Queue" in Jobs, and completion
  notifications.
- Native app memory: the header shows estimated RAM use, available headroom,
  and serving-model residency with unload controls; new endpoints default to
  Load on request with a 10-minute idle unload and a 2 GB headroom reserve,
  set per endpoint; existing endpoints keep their mode.
- Native app Compare: a quality-vs-runtime workflow chart.

### Changed

- The native app is named MLX Workbench: bundle name, About, menu bar, and
  the DMG volume and app. The executable, bundle identifier, and state paths
  are unchanged.
- The DMG app is a distribution build with no build-machine source path. An
  installed app uses the checkout whose `vendor/mlx-agent` is set in Settings
  for its `.venv` and **Install Runtime…**; in-app updates apply only to an
  app built from its checkout.
- `make dmg DEVELOPER_TEAM=<team id>` ships the Xcode Developer ID export,
  notarized through the signed-in Xcode account and stapled.
- Removed unused web API routes (adopt, wire, sloth, LM Studio import, serve
  metrics, arbitrary-argv CLI) whose panels were already gone.
- `make docs-build` regenerates a stale versioned docs tree in place.
- Vendored mlx-agent `86f5586` → `v0.6.0`: intake, optional backends and
  ports, `convert transcribe|decide|generate|speak|describe|video`,
  `serve start --path|--jit`, `serve unload|policy`, `fleet --port-map`, and
  local source reuse.

### Fixed

- Compare speech-to-text: the built-in "Spoken sentences" clips are
  transcribed with `--language en`; user-picked clips pass no language.
- `vendor/mlx-agent` bumped to fcf0d91: `convert describe` drops special
  tokens from answers (moondream3 no longer starts with
  `<|md_reserved_4|>`).
- `vendor/mlx-agent` bumped to b460e5e: Whisper models whose vocabulary
  has no `<|nospeech|>` (those before large-v3) stop transcribing at the
  end of speech instead of running to the token limit with invented text,
  in Compare and in the speech-to-text canary.
- Native app conversions failed with "[Errno 30] Read-only file system:
  '/.mlx-agent-receipts'": convert start/status commands did not pass
  `--receipts-dir`, so the agent derived its receipts directory from the
  app's working directory (which is `/` for a GUI app). All convert
  invocations now pass the app's receipt directory, matching serve.
- Native app packaging: `make dmg` builds the Release SwiftUI app and
  packages it as a compressed DMG with an `/Applications` symlink, ad-hoc
  signed.
- App icon: the app ships a proper macOS squircle icon (anvil + MLX mark +
  spark + loopback dot), full 16–1024 px ladder in `AppIcon.appiconset`,
  master SVG checked in at `mlx-mac/assets/app-icon.svg`.
- Web Settings saves preserve native-app config keys; unexpected server
  errors return a classified `internal_error` 500.
- Web conversions of a GGUF with an unsupported architecture are refused at
  confirm time (422 `architecture_unsupported`), naming the architecture.
- Native intake: the output directory is scanned once when a root already
  contains it; Prepare status refreshes while a job runs; the bit picker
  re-targets repo destinations; unservable models get no Run action.
- Native watch alerts offer the action that resolves them.
- Native Overview opens the Library for completed non-servable outputs.
- Native toolbar status badges are no longer nested.
- Native agent timeouts and app quit stop the agent's whole process group,
  including media backends it started.
- Native Compare video cells no longer abort the app (AVKit is linked).
- The native login item serves with the checkout's `.venv` interpreter
  instead of `/usr/bin/python3`.

### Security

- P3 hardening: `make pip-audit` joins the PR gates (`.github/pr.yml`) with
  the five transformers 4.x advisories recorded as explicit accepted-risk
  ignores in the Makefile, so only new advisories fail CI; the native app's
  durable stores gain symlink refusal parity with the Python side —
  `JSONStore` refuses a symlinked store file, and Swift `Quarantine` refuses
  symlinked sources, quarantine directories, and restore targets (checks run
  on the unresolved path, matching `mlx_workbench/quarantine.py`).
- P2 hardening: adversarial route tests pin classified 4xx handling for
  type-confused bodies, header spoofing, control-character paths, and
  oversized payloads (the NUL-byte 500 and the boolean string-coercion gap
  they found are fixed); the config key universe is closed — unknown keys are
  rejected on load and refused on save while native premium keys stay
  preserved; state-changing web operations now append to a bounded local
  audit trail (`mlx_workbench/audit.py`,
  `$XDG_STATE_HOME/mlx-workbench/audit.jsonl`).
- Supply chain: `make install` now installs from pinned `requirements.txt`
  (exact versions validated together on Apple Silicon), and a new
  `make pip-audit` target checks the runtime against the OSV database. The
  audit currently reports 5 known `transformers` 4.x advisories; the pin is
  required by mlx-lm's GGUF→HF path (transformers 5 writes incompatible rope
  keys) and is a tracked, accepted risk — see the pip-audit note in
  `requirements.txt` when a 4.x patch release lands.
- Hardened response headers: CSP now pins `frame-ancestors 'none'`,
  `form-action 'self'`, and `base-uri 'none'`; `X-Frame-Options: DENY` added;
  the `Server:` header no longer advertises the Python version.
- Durable writes (`config.json`, `convert-queue.json`) now fsync file contents
  before the atomic rename and fsync the containing directory afterwards, so
  a power loss can no longer leave truncated state under the real name
  (`mlx_workbench/atomicio.py`).
- Concurrent HTTP requests are capped by a bounded semaphore; excess requests
  receive a structured 503 (`server_busy`) instead of unbounded thread growth.
- Timed-out agent subprocesses are now killed as a whole process group
  (`start_new_session=True`, SIGTERM then SIGKILL to the group), so a
  timeout can no longer orphan grandchildren such as in-flight conversions.
- The agent subprocess environment is an explicit allowlist
  (`bridge.agent_environment`): PATH (interpreter bin dir first), HOME,
  XDG_*, HF_*, TLS/proxy basics — never the web server's full environment.
- Symbolic links are refused before every durable write: config saves,
  queue saves, quarantine moves (both source and quarantine dir), and the
  native app's cross-client wiring writes (target, backup, and restore).

## [0.3.0] - 2026-09-09
### Added

- In-app updates in the native app's Settings: two channels — Official
  (checkout the newest `v*` release tag) and Beta (fast-forward to
  `origin/main`). Read-only check previews current → target with a dirty-tree
  count; applying refuses an uncommitted checkout, syncs submodules, and
  streams git output into a log; a "Rebuild & relaunch" action then runs
  `make build-swift` and restarts the app on the new build. Channel choice
  persists across launches.

- Quarantine put-back in the native app: the Reclaim surface lists
  currently-quarantined files from the ledger, newest first, with a
  one-click "Put back" that restores the file to its original location
  (refused with a classified error if the original is taken again; the
  ledger itself stays an append-only audit trail).

- Setup assistant UI dogfood (XCUITest with screenshot evidence) and the
  golden-path e2e bypass for the first-launch overlay.

- First-launch Setup Assistant in the native app: a guided sheet that walks
  agent connection, Python runtime (one-click guided install), and model
  roots, then runs the first library scan. Persisted once completed;
  re-openable from Health via "Run setup assistant again".
### Fixed

- Endpoint port field: a non-numeric or out-of-range port was silently
  coerced to the default port and the endpoint enabled anyway. Invalid
  input is now refused with an error; an empty field still means the
  default.
- Setup assistant wording: the runtime step no longer reads "Install…"
  when the probe already reports READY — the badge carries the state.

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

[Unreleased]: https://github.com/cavi-ai/mlx-workbench/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/cavi-ai/mlx-workbench/releases/tag/v0.3.0
[0.2.0]: https://github.com/cavi-ai/mlx-workbench/releases/tag/v0.2.0
[0.1.0]: https://github.com/cavi-ai/mlx-workbench/releases/tag/v0.1.0
