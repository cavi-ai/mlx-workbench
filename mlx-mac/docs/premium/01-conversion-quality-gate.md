# 01 — Conversion Quality Gate

**Status:** implemented (core gate, canary suite, UI surfaces) · **Tier:** Premium · **Depends on:** shared `ServeProbe` harness (see 00-index)

## Problem

Today the workflow ends at `completed`: the receipt says the conversion
finished, a fresh scan confirms the output exists, and the model is marked
`ready`. Nothing checks that the output actually *works*. The user discovers a
broken conversion (degenerate repetition, empty responses, refusal loops,
NaN-collapsed weights) only after wiring it into their coding client — 30+
minutes and several hand-edited configs later.

## Goal

Between "conversion completed" and "model is ready", insert an automatic
verification step: serve the fresh output on an ephemeral loopback port, run a
canary prompt suite, measure tok/s and TTFT, stop the server, and only then
mark the model `verified`. Failures are surfaced with evidence, not silently.

No other tool in the local-model toolchain (LM Studio, Ollama, HF UI) does
this.

## User experience

- After a conversion completes, the workflow shows **"Verifying output…"**
  with a live canary checklist. No user action required.
- On success: model row gains a **Verified** badge; the measured tok/s and
  TTFT land in the recommendation evidence automatically.
- On failure: state becomes `verificationFailed` with the failing canary
  output attached, plus two offered actions: **Quarantine output** (safe move,
  existing mechanism) and **Keep anyway** (explicit override, recorded).
- Home's `HomeNextAction.derive` gains two branches: verify-in-progress →
  route to `jobs`; `verificationFailed` → route to the failed verification.

## Architecture

### New workflow states

`ConversionWorkflowState` (Models/WorkflowModels.swift) gains:

```swift
case verifying           // conversion confirmed by scan; canary run in flight
case verified            // canary passed; terminal "good" state
case verificationFailed  // canary failed; requires user decision
```

`verified` is the new "ready to serve" terminal state. `completed` remains
for pre-gate meaning ("output exists on disk") and for models the user
explicitly keeps despite failure. `ModelReadiness` (LibraryDomain.swift)
gains `.verified` mapping to `isAvailable == true`; `.ready` stays available
but unverified (badge-only distinction in the UI).

### VerificationCoordinator

New `@MainActor` service mirroring `ModelWorkflowCoordinator`'s shape:

```
Services/VerificationCoordinator.swift   — state machine + reconciliation
Services/VerificationStore.swift         — durable reports (see persistence)
Services/ServeProbe.swift                — SHARED ephemeral-serve harness
Models/VerificationModels.swift          — CanaryCase, CanaryResult, VerificationReport
```

Trigger: `ModelWorkflowCoordinator.resolveCompletionAfterFreshScan` already
runs when a fresh scan confirms the output. Instead of transitioning straight
to `.completed`, it hands the confirmed path to `VerificationCoordinator.begin(modelPath:)`
which sets state `.verifying`.

### ServeProbe (shared harness)

This is the load-bearing piece, reused by spec 03 (Measured Comparisons):

1. Pick an ephemeral loopback port (bind port 0, read assignment, close).
2. `api.servePreview` / `api.serveStart` the target model on that port using
   the existing preview/confirm hash flow — **no new mlx-agent subcommand**.
3. Poll `http://127.0.0.1:<port>/v1/models` until ready or timeout
   (default 120 s, configurable).
4. Run probes over the OpenAI-compatible `/v1/chat/completions` endpoint
   (plain `URLSession`, loopback only).
5. `api.serveStop(port)` in a `defer`; reconcile `serveStatus` afterwards so a
   crashed probe never leaves an orphan the app doesn't know about.

The probe harness is argv-boundary-clean: serving goes through mlx-agent,
only the HTTP probes talk to the port.

### Canary suite

Fixed, versioned, small (target: < 90 s total on a 4-bit 8B model):

| Canary | Prompt class | Pass check |
| --- | --- | --- |
| `echo` | "Reply with exactly: …" | exact substring present |
| `code-fib` | write a trivial function | contains `def fib`, no repetition collapse |
| `reasoning-arithmetic` | multi-step arithmetic | final number present |
| `refusal-shape` | benign-but-edgy request | response is not empty, not a degenerate loop |
| `long-context` | ~2k-token input, summarize | non-empty, length in band |

Degenerate-output detectors applied to every response:

- **repetition ratio**: max 4-gram frequency above threshold → fail
- **empty/whitespace-only** → fail
- **token loop**: identical trailing window repeated ≥ 3× → fail
- **non-UTF8 / replacement-char flood** → fail

Also measured per run: tokens/sec (usage or timing fallback) and TTFT
(first-chunk latency with `stream: true`). These become a
`RecommendationBenchmarkResult` and flow into `AppHost.benchmarkResults` —
the RecommendationEngine gets real local evidence for free.

### Report

```swift
struct VerificationReport: Codable, Identifiable {
    let id: UUID
    let modelPath: String          // canonical, symlink-resolved
    let modelSignature: String?    // from scan; ties report to exact bytes
    let suiteVersion: Int          // canary definitions are versioned
    let canaries: [CanaryResult]
    let tokensPerSecond: Double?
    let timeToFirstTokenSeconds: Double?
    let startedAt: Date
    let finishedAt: Date
    let outcome: Outcome           // passed / failed(canaryIDs) / error(message)
}
```

### Persistence

`$XDG_STATE_HOME/mlx-workbench/verification-reports.json` with the same
fallback and corrupt-file preservation (`*.N.corrupt`) convention as the
convert queue. Keyed lookup by `(modelPath, modelSignature)`: a report only
vouches for the exact bytes that were probed — if the file changes, the badge
drops.

### Settings additions

```json
{
  "verification_enabled": true,
  "verification_timeout_seconds": 120,
  "verification_on_convert": "always"   // always | ask | never
}
```

## Failure modes & edges

- **Serve runtime missing** → verification is skipped, model stays `ready`
  (unverified) with an explanatory message. Never blocks the library.
- **App quit mid-verify** → on next launch, reconcile: `serveStatus` shows no
  server for the ephemeral port (or an orphan to stop), no report exists →
  state drops back to `completed`, user can re-run verification manually.
- **User converts the same source again** → new output path, new report; old
  report keyed to the old path/signature is untouched.
- **"Keep anyway"** → recorded in the report as `outcome: .keptDespiteFailure`;
  badge shows **Unverified**, lineage (spec 07) shows the override.

## Tests

- `VerificationCoordinatorTests`: state transitions, orphan-server reconcile,
  timeout, keep-anyway override, signature-mismatch badge drop.
- `ServeProbeTests`: fake HTTP server (loopback `NWListener`) exercising
  readiness polling, TTFT timing, and guaranteed `serveStop` on throw.
- Canary detector unit tests (repetition ratio, token loop) — pure functions.
- `HomeViewTests`: new `HomeNextAction` branches.

## Rollout

Ship behind `verification_enabled` default **on** for new conversions; manual
"Verify now" button on any ready model row so existing libraries benefit
immediately.
