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
