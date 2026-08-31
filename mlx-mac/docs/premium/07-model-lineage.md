# 07 — Model Lineage & Receipt Timeline

**Status:** spec · **Tier:** Premium (the coherence layer — makes the tier feel like one product)

## Problem

Three weeks after a conversion, a model misbehaves. What exactly is this
file? What was it converted from, with what quant settings, did verification
pass, which clients are wired to it, when was it last served? All of these
facts exist — in receipts, workflow history, verification reports, wiring
transactions — but scattered across stores. The user reconstructs the story
by hand.

## Goal

Every model gets a **Lineage**: a single provenance timeline assembled from
the stores the app already keeps, viewable from the model row, and exportable
as JSON or Markdown. No new data collection beyond one indexer — this feature
is *surfacing*, which is why it's cheap and why it ties the premium tier
together.

## User experience

- ModelDetailsView gains a **Lineage** section: vertical timeline,
  newest first:
  - ⬇ **Source** — GGUF path or HF repo+revision, size, signature
  - ⚙ **Converted** — receipt id, q-bits, duration, preview hash
  - ✅ **Verified** — suite version, tok/s, TTFT (or ❌ failed + override)
  - 📊 **Benchmarked** — comparison runs this model joined
  - ▶ **Served** — first/last served, total sessions
  - 🔌 **Wired** — clients + dates (from spec 02 transactions)
  - 📦 **Quarantined/Restored** — moves with timestamps
- **Copy lineage** (Markdown) and **Export JSON** buttons — audit-ready.
- Stale markers: if the file's current signature ≠ the signature an event was
  recorded against, that event renders dimmed with "predates current bytes".

## Architecture

```
Services/LineageIndexer.swift    — read-only assembly over existing stores
Models/LineageModels.swift
UI/Views/LineageView.swift       — embedded in ModelDetailsView
```

```swift
struct ModelLineage: Equatable {
    let modelPath: String            // canonical
    let currentSignature: String?
    let events: [LineageEvent]       // sorted desc by date
}

struct LineageEvent: Identifiable, Equatable {
    let id: UUID
    let kind: Kind                   // source, converted, verified, benchmarked,
                                     // served, wired, quarantined, restored
    let at: Date
    let summary: String
    let detail: [String: String]     // receipt id, hash, client, tok/s, ...
    let signatureAtEvent: String?    // for staleness dimming
}
```

### Sources (all existing or specced in this series)

| Event kind | Source store |
| --- | --- |
| source | scan result (`signature`, provenance on `MLXOutput`) |
| converted | `ConversionWorkflow` history (receipt, q-bits via jobs) |
| verified | `VerificationStore` (spec 01) |
| benchmarked | `ComparisonStore` (spec 03) |
| served | usage-events (spec 04) + serve receipts |
| wired | `WiringTransactionStore` (spec 02) |
| quarantined/restored | quarantine records |

The indexer is **pure and read-only**: given the loaded stores + a canonical
model path, assemble events, match by path or signature, sort. No writes, no
background work — assembled on demand when ModelDetailsView appears (cheap:
all stores are small JSON).

### Export

- Markdown: human timeline, one line per event, detail table per event.
- JSON: the `ModelLineage` Codable verbatim. Export goes through
  `NSSavePanel`; the app never writes outside user-chosen locations.

## Failure modes & edges

- Store missing/corrupt → that event kind is absent; a footer notes "N event
  sources unavailable" instead of failing the whole view.
- Model converted before lineage existed → timeline starts at first known
  event; source event synthesized from scan provenance when present.
- Signature unknown (signatures disabled in config) → staleness dimming
  disabled, noted in the footer.

## Tests

- `LineageIndexerTests`: assembly from synthetic stores, path-vs-signature
  matching, staleness dimming, missing-store degradation.
- Export snapshot tests (Markdown shape stability).

## Rollout

Ships after specs 01–04 (it has nothing to index without them). This
ordering is deliberate: lineage is the receipt that the premium tier worked.
