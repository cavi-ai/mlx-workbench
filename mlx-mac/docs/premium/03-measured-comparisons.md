# 03 — Measured Comparisons (prompt-set replay)

**Status:** implemented (phase 1 + phase 2: history import and output diffs) · **Tier:** Premium · **Depends on:** shared `ServeProbe` harness (spec 01)

## Problem

"Which quant should I keep — Q4, Q6, or Q8?" is currently answered by vibes
and spec sheets. The Compare (Quant) view shows static quant metadata; the
RecommendationEngine stores benchmark results but has no harness to produce
them on demand across variants. Meanwhile the user has *real prompts* they
actually care about — and no way to replay them across variants.

## Goal

Turn quant/variant selection into a 5-minute measured answer: pick a set of
model variants, pick (or auto-build) a prompt set, run the set against each
variant on an ephemeral server, and get measured tok/s + TTFT + **output
diffs** per prompt. Results persist and feed the RecommendationEngine.

## User experience

- Compare tab becomes a matrix builder:
  - **Rows**: model variants (any ready/verified MLX outputs — typically the
    quant variants of one base model, but any set is allowed).
  - **Columns/metrics**: tok/s, TTFT, per-prompt output (expandable,
    side-by-side diff view between two variants).
- **Prompt sets**: built-in starter sets per `UseCase` (coding, chat,
  reasoning, vision) + user-created sets. One-click **"Import my prompts"**
  (opt-in) builds a set from local client histories where readable
  (opencode session files) — prompts never leave the machine.
- Run → progress per (variant × prompt) → results grid. **"Promote winner"**
  sets the RecommendationEngine's `preferredModelIDs[useCase]` and offers to
  quarantine the losers via the Disk Advisor flow (spec 04).

## Architecture

### Shared harness

Reuses `ServeProbe` (spec 01) verbatim: serve variant on ephemeral loopback
port → probe → stop. The Quality Gate and Comparisons share readiness
polling, TTFT timing, and the orphan-server reconciliation. One harness, two
consumers — this is the main cost-of-build synergy in the premium tier.

### New pieces

```
Services/ComparisonCoordinator.swift   — run scheduling, one variant at a time
Services/PromptSetStore.swift          — durable prompt sets
Services/ComparisonStore.swift         — durable run results
Models/ComparisonModels.swift
UI/Views/CompareRunView.swift          — replaces static QuantView content
```

### Models

```swift
struct PromptSet: Codable, Identifiable {
    let id: UUID
    var name: String
    var useCase: UseCase?
    var prompts: [PromptEntry]           // text + optional system prompt + tags
    var origin: PromptSetOrigin          // builtin / userCreated / imported
}

struct ComparisonRun: Codable, Identifiable {
    let id: UUID
    let promptSetID: UUID
    let variants: [String]               // canonical model paths
    let results: [VariantResult]
    let startedAt: Date
    let finishedAt: Date?
}

struct VariantResult: Codable {
    let modelPath: String
    let modelSignature: String?
    let samples: [PromptSample]          // per-prompt: output text, tok/s, TTFT, tokens
    let aggregateTokensPerSecond: Double?
    let aggregateTTFTSeconds: Double?
    let error: String?
}
```

`VariantResult` aggregates roll up into the **existing**
`RecommendationBenchmarkResult` (modelID + useCase + tok/s + TTFT +
sampleCount + measuredAt) — no parallel metrics world; the
RecommendationEngine's speed/quality weighting immediately uses real data.

### Scheduling rules

- **One variant at a time** (mirrors mlx-agent's one-live-convert rule and
  avoids memory-pressure interference that would poison measurements).
- A run is a durable record from the moment it's queued; app restart resumes
  at the next unmeasured variant.
- While a comparison runs, conversion confirmation and other serve actions
  are blocked with a clear message (same "authoritative state" discipline as
  the convert queue).
- Warm-up: one throwaway prompt per variant before timing, so first-token
  JIT/load cost doesn't contaminate TTFT.

### Output diff view

Per prompt: select two variants → token-level diff (LCS over lines, rendered
with +/- coloring), plus the metric deltas. Deliberately simple — this is
evidence for a keep/quarantine decision, not an eval framework.

## Settings

```json
{
  "comparison_max_tokens": 512,
  "comparison_timeout_seconds": 180,
  "comparison_import_histories": false
}
```

## Failure modes & edges

- Variant deleted/quarantined mid-run → sample marked `error`, run continues.
- Memory pressure (Fit Advisor, spec 05, reports `wontFit` for a variant) →
  that variant is skipped with the fit verdict as the error, not measured
  into nonsense numbers.
- Signature change on a variant after the run → results kept but stamped
  stale; aggregates stop feeding the RecommendationEngine until re-measured.
- Prompt-set import is **off by default**, per-client opt-in, read-only.

## Tests

- `ComparisonCoordinatorTests`: ordering (one at a time), resume-after-restart,
  skip-on-wontFit, stale-signature handling.
- `PromptSetStoreTests`: persistence + corrupt-file preservation convention.
- Aggregate → `RecommendationBenchmarkResult` mapping tests.
- Diff view model tests (pure functions over strings).

## Rollout

Phase 1: builtin prompt sets + manual sets + metrics grid.
Phase 2: history import + output diffs + "promote winner" integration.
