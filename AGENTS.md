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
