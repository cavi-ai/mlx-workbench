# mlx-mac — native macOS app

Native SwiftUI front end for the mlx-agent model lifecycle on Apple Silicon.
It talks to the same pinned `vendor/mlx-agent` CLI as the web workbench —
argv tokens, preview/confirm hashes, receipts as the process authority — and
adds a lifecycle layer on top (verification, measurement, wiring, hygiene).

## Requirements

- macOS on Apple Silicon, Xcode installed
- The Python runtime from the repo root: `make install` (conversion and
  serving packages live in the project `.venv`)

## Build, run, test

```bash
make build-swift    # Release build into $(MLX_SWIFT_DD) (default /tmp/mlx-mac-build)
make run-swift      # build + open the app
make test-swift     # XCTest unit suite
```

`MLX_SWIFT_DD` overrides the derived-data path. UI tests that exercise real
local models live behind the `mlx-workbench-real-data-e2e` scheme and require
runtime values (`TASK6_*` environment or manifest) — they are not part of the
default test action.

## Opt-in GGUF-to-Run acceptance

The existing native real-data harness can be launched through one guarded
Make target:

```bash
make accept-native-gguf RUNTIME_MANIFEST=/absolute/path/to/runtime.json
```

`RUNTIME_MANIFEST` is mandatory and must be an absolute path. The target runs
only `GGUFToRunRealDataUITests.testRealGGUFToRunningMLXGoldenPath`; neither
`make test` nor `make test-swift` selects it. The harness may convert the named
GGUF, reuse an equivalent existing MLX output, and briefly start a local model
server. Use a deliberately selected disposable or otherwise approved source,
not an arbitrary model library entry.

The manifest is a strict JSON object with these fields and no additional
keys:

```json
{
  "source_path": "/absolute/path/to/models/example-Q4_K_M.gguf",
  "model_query": "example-Q4_K_M",
  "agent_home": "/absolute/path/to/mlx-agent",
  "config_path": "/absolute/path/to/mlx-workbench-config.json",
  "evidence_root": "/absolute/path/to/acceptance-evidence"
}
```

Prerequisites and preflight constraints:

- Apple Silicon macOS with Xcode's `xcodebuild` on `PATH`.
- The repository's conversion/serving runtime installed with `make install`.
- `source_path` is an existing regular `.gguf` smaller than 29 GB and resolves
  beneath one of the config's explicit, non-empty `gguf_roots` entries.
- `agent_home/scripts/mlx-agent` exists and is executable.
- If the config sets `mlx_agent_path`, it resolves to the same checkout as
  `agent_home`; divergent runtime identities are rejected before Xcode starts.
- `config_path` contains a JSON object whose `host` is `127.0.0.1`,
  `localhost`, or `::1` (an omitted or empty host uses `127.0.0.1`).
- `evidence_root` is absolute and outside every configured GGUF root.

The runner creates and prints a unique
`<evidence_root>/native-gguf-<UTC timestamp>-<pid>/` directory before invoking
Xcode. It contains `xcodebuild.log`, `result.xcresult` when Xcode produces one,
`DerivedData/`, screenshots and `ui-observations.log` from the harness, and an
atomic `outcome.json` summary. Existing evidence directories are never reused.

Failure classification:

| Exit | Classification | Meaning and evidence |
| --- | --- | --- |
| 2 | `manifest-invalid` | The manifest or referenced local inputs failed preflight. No run directory is promised because `evidence_root` was not trusted. |
| 3 | `prerequisite-unavailable` | The validated runtime cannot launch on this host. `outcome.json` records the reason. |
| 4 | `acceptance-failed` | Xcode launched but its test action failed. Use `xcodebuild.log` and `result.xcresult` to distinguish a product assertion, local model/runtime failure, or Xcode/build infrastructure failure. |
| 0 | `passed` | This manifest's configured real-data path passed; it does not certify other local models. |

The wrapper does not call conversion or serve commands itself. The UI harness
still previews each conversion and serve plan, confirms with the returned
preview hash, reconciles process state from mlx-agent receipts, binds serving
to loopback through the native app, and stops only the exact server receipt it
created. It does not delete or quarantine model data.

## Feature map

| Surface | What it does |
| --- | --- |
| **Home** | One concrete next action derived from workflow state, library evidence, watch alerts, and disk pressure |
| **Library** | Scanned GGUF/MLX inventory with readiness, signatures, and per-model details (verification status, lineage) |
| **Discover** | Hub candidates by role via the agent's scout |
| **Prepare** | Preview/confirm conversion; completed outputs pass through the **Conversion Quality Gate** (canary suite on an ephemeral loopback server) before they are marked verified |
| **Run** | Preview/confirm serving with a live **memory-fit verdict** (fits/tight/won't-fit + suggested context); hosts the **Always-on Endpoint** card |
| **Compare** | **Measured comparisons**: replay built-in or imported prompt sets across variants; per-prompt output diffs; measured tok/s/TTFT feed recommendations |
| **Activity** | Conversion receipts, log tails, server table |
| **Duplicates** | Duplicate groups plus the **Disk Pressure Advisor** (stale / superseded / cross-root reclaim via batched quarantine; HF-cache prune via doctor) |
| **Wire** | mlx-agent wiring plus **cross-client wiring** (opencode, Continue, Zed, Aider — atomic writes with backup and rollback; LM Studio/Ollama advisory) |
| **Menu bar** | Endpoint state and start/stop at a glance |

## Design rules

- Everything mutating is previewed, hashed, and confirmed; intent drift
  between preview and confirm is refused.
- mlx-agent receipts are the authority for process state; app-side state
  reconciles against them.
- Verification reports and benchmark evidence are keyed to exact file
  signatures — stale evidence is marked, never silently trusted.
- Quarantine moves; nothing deletes.
- The endpoint and probes bind loopback only.

Feature specs and the packaging rationale live in `docs/premium/`.
