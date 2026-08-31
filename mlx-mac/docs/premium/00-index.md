# Premium features — index & packaging

Design specs for the mlx-mac premium tier. Ground rules inherited from the
repo, carried through every spec: argv-only subprocess boundary to mlx-agent,
preview/confirm with hashes for anything mutating, receipts as the authority
for process state, quarantine never deletes, loopback only, durable state in
the XDG state dir with corrupt-file preservation.

**Augment, don't abstract:** every feature either proves something (quality
gate, comparisons), removes glue work (wiring, endpoint, disk), or surfaces
what already exists (lineage, watch). None of them add a new runtime, config
format, or chat surface.

## The specs

| # | Feature | Tier | One-liner |
| --- | --- | --- | --- |
| 01 | [Conversion Quality Gate](01-conversion-quality-gate.md) | Premium | Auto-verify every conversion with a canary suite before it's marked ready |
| 02 | [Cross-client Wiring](02-cross-client-wiring.md) | Premium | "Make this my model everywhere" — atomic multi-client config writes with rollback |
| 03 | [Measured Comparisons](03-measured-comparisons.md) | Premium | Replay real prompt sets across quant variants; measured tok/s + output diffs |
| 04 | [Disk Pressure Advisor](04-disk-pressure-advisor.md) | Premium | Ranked reclaim opportunities (stale / superseded / cross-root) via batched quarantine |
| 05 | [Memory-fit Advisor](05-memory-fit-advisor.md) | **Free** | Fits/tight/won't-fit verdict before serving, with suggested max context |
| 06 | [Always-on Endpoint + Menu Bar](06-always-on-endpoint.md) | Premium | launchd-backed stable port, auto-restart, hot-swap, minimal menu-bar status |
| 07 | [Model Lineage](07-model-lineage.md) | Premium | One provenance timeline per model, assembled from existing stores, exportable |
| 08 | [Watch & Regression Alerts](08-watch-regression-alerts.md) | Premium | Upstream change digests + re-verify prompts on macOS/MLX drift |

## Shared components (build once)

- **`ServeProbe`** (spec 01): ephemeral loopback serve + HTTP probe harness.
  Consumed by 01 (canary verification) and 03 (comparison runs). The single
  biggest cost synergy in the tier.
- **Usage-event tracking** (spec 04): `lastServedAt` stamps. Consumed by 04
  (staleness) and 07 (served events).
- **Environment fingerprint** (spec 08): `(macOS, chip, mlx-lm)` tuple,
  recorded on every verification/benchmark report from day one.
- **State-store pattern**: every new store follows the convert-queue
  conventions — XDG state dir, JSON, atomic write, `*.N.corrupt` preservation.

## Dependency graph

```
05 Fit Advisor (free, standalone)
01 Quality Gate ──┬── 03 Measured Comparisons (shares ServeProbe)
                  ├── 06 Always-on (verified-models default)
                  └── 08 Watch (re-verification target)
02 Wiring ◄── 06 (stable endpoint as wire target)
04 Disk Advisor (standalone; consumes 01's verified state for supersede rules)
07 Lineage (indexes 01–04 stores — ship after them)
```

## Suggested build order

1. **05 Fit Advisor** — small, free, immediately builds trust in judgment.
2. **01 Quality Gate** (+ `ServeProbe`) — the flagship; nothing else does it.
3. **03 Measured Comparisons** — cheap once ServeProbe exists; feeds the
   RecommendationEngine real evidence.
4. **02 Cross-client Wiring** — the glue-elimination story.
5. **06 Always-on Endpoint** — completes "new model everywhere, always".
6. **04 Disk Advisor** — read-only advisor first, batched apply second.
7. **07 Lineage** — the receipt that the tier worked.
8. **08 Watch** — passive value, lowest noise tolerance required.

## Free vs premium rationale

Free tier keeps everything current plus 05: the core loop
(scan → prepare → run) must feel *trustworthy* before anyone pays for
verification of it. Premium is the proof-and-plumbing tier: verification
(01), measurement (03), wiring (02), reliability (06), hygiene (04), and the
record that ties them together (07, 08).
