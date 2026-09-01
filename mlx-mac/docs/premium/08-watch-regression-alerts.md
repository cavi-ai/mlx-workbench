# 08 — Watch & Regression Alerts

**Status:** implemented (upstream watch + environment-drift re-verification, in-app alerts; Notification Center delivery and RecommendationEngine staleness marking are follow-ups) · **Tier:** Premium · **Priority:** lowest (passive value; build last)

## Problem

Two slow-burn risks the user can't see today:

1. **Upstream drift** — an owned model's HF repo gets a fix (tokenizer patch,
   weight re-upload, config correction). The local copy silently ages.
2. **Environment drift** — a macOS or MLX update changes performance or
   correctness of already-verified models. Last month's tok/s and canary
   results may no longer describe reality.

## Goal

A low-noise notification layer: digest-worthy upstream changes for owned
models, and re-verification prompts when the runtime environment changes.
Alerts are rare, actionable, and never block anything.

## User experience

- **Watchlist**: auto-built from the library (models with HF provenance);
  user can remove entries or add arbitrary repos. Visible as a small section
  in Settings.
- **Alerts land in Notification Center** and collect in a badge on the Home
  tab. Two kinds:
  - **Upstream**: "Qwen3-8B-MLX-4bit updated 3 files since your copy
    (config.json, tokenizer). Re-sync?" → routes to Convert.
  - **Regression check**: "macOS 26.5 → 26.6 detected. Re-verify your 4
    verified models?" → one click queues canary re-runs (spec 01 harness).
- Every alert has: **Act**, **Snooze 7d**, **Mute this model**. No alert
  fires more than once per (model, change-set).

## Architecture

```
Services/WatchCoordinator.swift      — scheduling, baseline, digest
Services/AlertStore.swift            — alerts, snooze/mute state
Models/WatchModels.swift
```

### Upstream watch

- Polls via the existing mlx-agent watch capability (argv through
  `WorkbenchAPI.raw`, `--json`, same as every other subcommand) — the app
  does not call the HF API directly; the agent boundary is preserved.
- Cadence: on app launch (if >24 h since last check) + daily timer while
  running. A check is cheap (metadata only); downloads never happen
  automatically — the alert routes the user to the Convert flow.
- Baseline: `watch-baseline.json` in the state dir (last-seen
  `lastModified`/etag per repo), with the corrupt-file preservation
  convention.

### Regression watch

- Environment fingerprint = `(macOSVersion, chip, mlx-lm version)` — first
  two from the existing `HardwareProfile`, mlx-lm version probed once via the
  RuntimeChecker's python path (`python -m mlx_lm --version`-style module
  query, argv-only).
- Fingerprint stored with each `VerificationReport` and benchmark aggregate
  (specs 01/03 record it). On fingerprint change:
  - Verified models whose report fingerprint ≠ current → one batch alert
    offering re-verification.
  - Benchmark aggregates from the old fingerprint are marked
    `environmentStale` in the RecommendationEngine — still shown, but ranked
    below fresh evidence, never silently trusted.

### Alert discipline

```swift
struct WatchAlert: Codable, Identifiable {
    let id: UUID
    let kind: Kind            // upstreamChange / environmentDrift
    let modelKey: String
    let fingerprint: String   // dedupe key: kind+model+changeset
    let title: String
    let body: String
    let route: String         // "convert" / "jobs"
    let createdAt: Date
    var snoozedUntil: Date?
    var muted: Bool
}
```

Dedupe by fingerprint; mute/snooze per model; Notification Center via
`UNUserNotificationCenter` with a single notification category and actions.
If notification permission is denied, alerts live in-app only (badge).

## Settings

```json
{
  "watch_enabled": true,
  "watch_interval_hours": 24,
  "watch_repos_extra": []
}
```

## Failure modes & edges

- Offline / HF unreachable → check skipped silently, next cadence. Watch is
  the one feature allowed to be quiet about network failure: it is advisory.
- Agent lacks watch capability (older pin) → feature hidden with a one-line
  note in Settings.
- Model quarantined/removed → watchlist entry auto-pruned on next scan
  reconcile; pending alerts for it dismissed.

## Tests

- `WatchCoordinatorTests`: digest dedupe, snooze/mute, cadence gating,
  offline silence, auto-prune.
- Fingerprint-change tests: verification staleness marking, batch alert
  construction.
- AlertStore persistence + corrupt-file convention.

## Rollout

Last of the eight. Requires spec 01 (re-verification target) and benefits
from 03 (benchmark staleness). Ship upstream-watch first; environment-watch
lands when verification reports exist to make stale.
