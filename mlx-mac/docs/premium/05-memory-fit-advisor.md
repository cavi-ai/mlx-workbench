# 05 — Memory-fit Advisor at serve time

**Status:** spec · **Tier:** **Free** (trust-builder for the core loop)

## Problem

Apple Silicon unified memory makes serve failures late and ugly: the user
confirms a serve of a 70B at 32k context on a 36 GB machine, mlx_lm starts
loading, the system swaps to death or the process is killed minutes in. All
inputs to predict this exist locally; nothing combines them.

## Goal

Before the serve preview is confirmed, compute a **fit verdict** from the
hardware profile, current memory pressure, model size, and requested context
length — and suggest the max context that fits. Cheap to build, big
frustration removal.

## User experience

- Serve view gains a verdict line above the preview button:
  - ✅ **Fits** — "≈19.2 GB needed, 26 GB available"
  - ⚠️ **Tight** — "fits, but other apps may swap; consider 8k context"
  - ⛔ **Won't fit** — preview button disabled-ish (confirm still possible via
    explicit override), with the suggested max context shown as a one-click
    "use 4k instead".
- Same verdict chip on Discover rows (Scout already has `est_ram_gb`/`fits`
  hints — the advisor replaces the guess with local math) and on Compare
  variant rows (spec 03 uses it to skip hopeless variants).

## Architecture

```
Services/FitAdvisor.swift    — pure estimation + live memory probe
Models/FitModels.swift
```

```swift
enum FitVerdict: Equatable {
    case fits(headroomGB: Double)
    case tight(headroomGB: Double)
    case wontFit(deficitGB: Double, suggestedMaxContext: Int?)
}

struct FitAdvisor {
    static func verdict(
        modelBytes: Int64,           // from scan item / output dir size
        contextTokens: Int,
        kvBytesPerToken: Int64?,     // arch-derived when known, else heuristic
        hardware: HardwareProfile,   // existing
        memory: MemorySnapshot       // live, see below
    ) -> FitVerdict
}
```

### Estimation model (deliberately simple, versioned)

- **Weights** = on-disk size of the model (MLX output dir sum or GGUF bytes).
  Loading cost ≈ weights (MLX maps them; no double-count).
- **KV cache** = `contextTokens × kvBytesPerToken`. When architecture +
  layer/heads dims are known from scan metadata, compute exactly; otherwise
  use a per-parameter-count heuristic table (documented, conservative).
- **Runtime overhead** = fixed 1.5 GB allowance (mlx + python + server).
- **Available** = live memory, not just total: `host_statistics64` for free +
  reclaimable, minus a safety reserve (default 4 GB, configurable). Read at
  verdict time and refreshed while the Serve sheet is open.

Thresholds: `fits` when needed ≤ available × 0.85; `tight` when ≤ available;
`wontFit` otherwise. `suggestedMaxContext` binary-searches the largest
context (power-of-two steps, min 2k) that yields `fits`.

The estimator carries an `estimatorVersion`; when it changes, cached verdicts
recompute — verdicts are **never persisted**, always derived (no stale-cache
class of bugs).

### Integration points

- `ServeView`: verdict shown next to runtime/port pickers; context-length
  field gets the suggestion button.
- `ModelWorkflowCoordinator.previewServe`: attaches the verdict to the
  workflow message; override requires re-confirm (same intent-drift guard).
- `FitAdvisor` is pure + injected (hardware, memory probe) → fully testable.

## Settings

```json
{
  "fit_reserve_gb": 4,
  "fit_default_context": 8192
}
```

## Failure modes & edges

- Unknown model size (unreadable item) → verdict `.unknown`-style message
  ("size unavailable, fit not checked"), never blocks.
- Memory probe fails → fall back to `memoryBytes × 0.6` heuristic, marked
  estimated.
- User overrides a `wontFit` → recorded in the workflow message; if the serve
  then fails, the Jobs view links the verdict ("was predicted wont-fit") —
  builds trust in the advisor over time.

## Tests

- `FitAdvisorTests`: synthetic hardware/memory/models covering all three
  verdicts, suggestion binary search, probe-failure fallback.
- ServeView view-model tests: override flow, suggestion application.

## Why free

It makes every other feature (including premium verification and
comparisons) trustworthy, and it's small. This is the taste of the app's
judgment that justifies the premium tier.
