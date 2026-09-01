# 04 — Disk Pressure Advisor

**Status:** implemented (stale / superseded / cross-root detectors, batched quarantine apply; doctor-prune cache path remains a follow-up) · **Tier:** Premium

## Problem

Local-model users accumulate hundreds of GB across HF cache blobs, LM Studio
directories, converted MLX outputs, and quarantine. The current Duplicates
view finds exact/variant duplicate groups, and scan already reports
`reclaimable_bytes`. What's missing: **time-aware, cross-root, batched
reclaim decisions**. "What haven't I actually run in 60 days, what's
superseded by a better variant, and how much do I get back per action?"

## Goal

A single **Reclaim** surface that ranks reclaim opportunities by GB saved,
shows the evidence for each ("not served in 74 days", "superseded by verified
Q6 variant"), and applies them through the existing quarantine-only,
never-delete, preview/confirm pipeline — batched.

## User experience

- New **Reclaim** section inside the Duplicates tab (or its own sidebar row
  when reclaimable > threshold, e.g. 20 GB — a badge with GB count does the
  marketing for free).
- Table: opportunity, kind (Stale / Superseded / Cross-root duplicate /
  Incomplete cache), size, evidence, destination (quarantine).
- Multi-select → **Preview reclaim** → unified plan with total GB →
  **Confirm** → quarantine moves with per-item results. Undo via the existing
  quarantine restore.

## Architecture

### Opportunity detectors

```
Services/ReclaimAdvisor.swift    — builds ReclaimPlan from snapshot + history
Models/ReclaimModels.swift
```

```swift
enum ReclaimKind: String, Codable {
    case stale                 // not served/verified in N days
    case supersededVariant     // same modelKey, a verified better variant exists
    case crossRootDuplicate    // same weights in >1 root (HF cache + LM Studio + output)
    case incompleteCache       // existing doctor finding, folded in
}

struct ReclaimOpportunity: Identifiable, Equatable {
    let id: UUID
    let kind: ReclaimKind
    let paths: [String]              // what would move
    let bytes: Int64
    let evidence: String             // human-readable "why"
    let confidence: Confidence       // high = safe auto-select, low = review
}
```

Inputs, all already available or cheap:

- **Staleness**: needs `lastServedAt` — new tracking. Every successful
  `confirmServe`, verification run, and comparison sample stamps the model
  path in a `usage-events.json` state file. Until history exists, staleness
  uses file `modifiedAt` and is marked low confidence.
- **Superseded**: group `LibraryModel`s by `modelKey`; a variant is
  superseded when another variant of the same key is `verified` (spec 01)
  with equal-or-higher quant bits. Unverified winners never supersede.
- **Cross-root**: existing `DuplicateGroup` (kind/members/reclaimableBytes)
  already groups same-model copies; extend detection to match across root
  *types* (HF cache blob hash ↔ GGUF signature ↔ converted output provenance).
- **Incomplete cache**: existing `doctor models` findings, re-presented here
  so all reclaim lives in one place.

### Apply path

Reuse, don't reinvent:

- Moves go through the **existing quarantine pipeline**
  (`mlx_workbench/quarantine.py` semantics: `.gguf`-in-configured-roots
  constraint, never delete). For non-GGUF reclaim candidates (MLX output
  dirs, HF cache blobs), the advisor emits **preview-only** plans and the
  apply step calls `doctor models --prune --confirm --preview-hash` for
  cache entries — reclaim of non-GGUF paths rides mlx-agent's own
  preview/confirm rather than inventing new file-moving code in the app.
- Batched GGUF moves produce one preview hash over the full set; confirm
  applies sequentially; per-item failures don't roll back prior successes
  (quarantine is reversible).

### Surfaces

- Sidebar badge when total reclaimable exceeds the configured threshold.
- Home next-action branch: when reclaimable > threshold **and** disk free
  space < 15%, "Reclaim N GB" outranks routine suggestions (but never
  outranks an active workflow or a failure).

## Settings

```json
{
  "reclaim_stale_days": 60,
  "reclaim_badge_threshold_gb": 20
}
```

## Failure modes & edges

- Path occupied by a running server or queued conversion → opportunity hidden
  (authoritative serve/queue state checked at plan time *and* again at
  confirm time; drift → re-plan, same intent-drift discipline as elsewhere).
- Quarantine root full/different volume → per-item error in results, plan
  continues.
- All detectors are read-only; the advisor never moves anything outside the
  preview/confirm flow.

## Tests

- `ReclaimAdvisorTests`: detector unit tests over synthetic snapshots
  (stale windows, supersede rules, cross-root matching, occupied-path
  exclusion).
- Plan/confirm drift test: mutate state between preview and confirm →
  refused.
- Aggregation test: badge threshold math.

## Rollout

Ships in two steps: (1) read-only advisor + badge (zero risk, immediate
"wow, 80 GB"), (2) batched quarantine apply.
