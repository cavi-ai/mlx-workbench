# 09 — Fleet Endpoints (multi-model always-on) + Role Router

**Status:** P1 + P2 implemented (model/migration/supervisor; Run tab fleet UI + menu-bar aggregate); P3–P4 design · **Tier:** Premium · **Synergy:** extends spec 06 (Always-on Endpoint), feeds spec 02 (Cross-client Wiring) and `mlx-agent fleet`

## Problem

Spec 06 supervises exactly **one** model on one stable port. Real usage is
per-role: a small fast model for chat/autocomplete, a big one for coding, a
reasoning variant for hard problems. Today that means either one model
serving everything (wrong trade-off most of the time) or manual
start/stop/swap churn — the exact babysitting spec 06 removed, one layer up.
`mlx-agent` already ships the router half (`fleet render/apply`: a one-shot
per-role router config through the same preview/confirm boundary); what does
not exist is the app-side guarantee that **every role's endpoint is actually
alive**.

## Goal

A small fleet of supervised endpoints — one model per slot, one stable
loopback port per slot, one supervisor reconciling all of them — plus a
one-click **role router** that maps use cases (coding, chat, reasoning,
vision) onto those endpoints via `mlx-agent fleet`. Clients keep one URL per
role; the app keeps every URL serving.

## Non-goals

- **No proxy/router process.** Routing is client-side configuration written
  by `mlx-agent fleet apply` (preview/confirm, hash-gated), not a new daemon
  this app must keep alive.
- **No auto-scaling or load balancing.** Two slots for the same role is a
  configuration the UI declines, not a pool.
- **No remote binding.** Loopback only, same as every other surface.
- Slot count is deliberately small (cap: 4). This is a per-Mac convenience,
  not an inference server.

## User experience

- Run tab's "Always-on endpoint" card becomes an **Endpoints** list. Each
  slot: model picker (verified models first, same gating as today), port
  (auto-suggested next free from 8766), enable toggle, status pill
  (running/restarting/stopped/degraded), crash count, Memory-fit verdict
  chip. "Add endpoint" button (disabled at the cap).
- **Fleet memory budget**: the list header shows the summed fit verdict —
  weights + KV of all *enabled* slots against live available memory
  (`FitAdvisor`/`MemorySnapshot`, derived never persisted). Enabling a slot
  that would push the fleet past `tight` warns in place; past `won't-fit`
  requires the same explicit override pattern as the quality gate.
- **"Wire roles…"** button on the list: opens a preview of the
  `mlx-agent fleet render` output (role → endpoint URL, resolved from
  *running* slots only) → confirm applies it via `fleet apply` with the
  preview hash. Roles without a running slot are listed as skipped, never
  silently pointed at a dead port.
- Menu bar item aggregates: "2 of 3 endpoints running", worst-state icon,
  per-slot start/stop submenu. LaunchAgent story is unchanged — one login
  item launches the app; the supervisor reconciles the whole fleet.

## Architecture

### Data model + migration

```swift
struct EndpointSlot: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var enabled: Bool
    var port: Int
    var modelPath: String
    var role: UseCase?          // nil = unassigned; unique across slots
}

struct EndpointFleetConfig: Codable {
    var slots: [EndpointSlot]   // cap 4
    var installedAtLogin: Bool
}
```

- Store: `endpoint-fleet.json` (JSONStore conventions). On first launch
  after upgrade, a legacy `endpoint-config.json` migrates to a one-slot
  fleet (same port, same model, same login-item flag) and is left in place
  read-only for downgrade safety — never deleted, same discipline as
  quarantine and corrupt-queue preservation.
- Uniqueness invariants enforced in the store layer, not the view: distinct
  ports, at most one slot per role, model may repeat across slots only with
  distinct ports.

### EndpointSupervisor: single → fleet

`EndpointSupervisor` today persists one `EndpointConfig` and reconciles one
desired state. It becomes fleet-shaped internally:

- One **reconcile loop** over all enabled slots, per-slot desired state vs
  authoritative `serve status` (still the only process-state authority).
- Per-slot crash-loop guard (restart timestamps keyed by slot id, same
  3-per-5-min default), per-slot `EndpointState`, one aggregated
  `lastError` feed.
- `mlx-agent serve start/stop` calls remain per-port argv tokens; the
  one-live-conversion rule does not apply to serve, and `serve status`
  already returns a list.
- The existing single-slot public API (`enable/swap/disable`) is kept as a
  thin shim over slot 0 during the transition so the current call sites and
  `EndpointSupervisorTests` (352 lines) stay green; new slot APIs land
  alongside. The shim is removed in the last phase.

### Role router (app side of `mlx-agent fleet`)

- `Services/FleetRouter.swift`: builds the render request from running
  slots (role → `http://127.0.0.1:<port>/v1` + model identity), calls
  `fleet render` then `fleet apply --confirm --preview-hash` through
  `WorkbenchAPI` — argv tokens, no shell, same as every other agent call.
- Applies only when at least one role maps to a running slot; otherwise the
  button is disabled with the reason shown.

### Memory budget

- `FitAdvisor` already estimates weights + KV + overhead for one model. The
  fleet verdict is the sum over enabled slots (KV context sizes are
  per-slot), compared against one `MemorySnapshot`. No new measurement
  machinery; the composition lives in a `FleetFitAdvisor` value type so it
  is unit-testable without Mach probes.

## Boundaries (unchanged)

argv-only subprocess transport; preview/confirm with hashes for every
mutation (slot enable goes through serve preview/confirm exactly as today);
receipts/`serve status` authoritative; loopback only; quarantine never
deletes; durable state via JSONStore with corrupt-file preservation.

## Rollout

1. **P1 — model + migration + supervisor internals.** `EndpointSlot`,
   `EndpointFleetConfig`, legacy migration, multi-slot reconcile, per-slot
   crash guards. Single-slot shim keeps UI and tests green. Pure plumbing,
   no visible change.
2. **P2 — Run tab fleet UI.** Slots list, add/remove/enable/swap, per-slot
   status + fit chip, aggregated menu bar. This is the user-facing feature.
3. **P3 — fleet memory budget.** `FleetFitAdvisor`, header verdict,
   enable-time warnings/override.
4. **P4 — role router.** `FleetRouter`, "Wire roles…" preview/confirm in the
   Run tab, roles-skipped reporting. Requires P2 (running slots to map).

## Test plan

- Migration: legacy config → one-slot fleet; corrupt fleet file preserved.
- Store invariants: duplicate port/role rejected.
- Supervisor: multi-slot reconcile starts only diverged slots; crash-loop
  guard is per-slot (one slot degraded does not starve others); legacy shim
  tests stay untouched and green.
- `FleetFitAdvisor`: summed verdicts against a stubbed snapshot.
- Router: render request built from running slots only; skipped roles
  reported; apply refuses a stale preview hash.
