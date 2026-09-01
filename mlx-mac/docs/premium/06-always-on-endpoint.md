# 06 — Always-on Endpoint + Menu Bar

**Status:** implemented (all three phases) · **Tier:** Premium · **Synergy:** endpoint feeds spec 02 (Wiring)

## Problem

Serving today is session-scoped: the user starts a server, and it dies with
the terminal/app/nap. Their clients (opencode, Zed, Continue) then fail with
connection refused, and the user babysits `serve start` again. LM Studio
solves this with its own always-on server — but only for LM Studio's models
and its own port discipline. The premium move isn't a new server; it's
**reliable plumbing on a stable port** for the models this app already
manages.

## Goal

A launchd-backed, auto-restarting, OpenAI-compatible endpoint on a stable
loopback port, serving a chosen model, hot-swappable, with a minimal menu-bar
surface. Clients always find *something* on the port.

## User experience

- Serve tab gains **"Always-on endpoint"** card: toggle, stable port
  (default `127.0.0.1:8766`), selected model, status (running/restarting/
  stopped), crash count.
- Menu bar item (icon shows state): current model, tok/s of last probe,
  actions — Swap model…, Restart, Stop, Open mlx-mac.
- Swap = preview/confirm → graceful drain (finish in-flight request or
  10 s grace) → stop → start new model on the **same port** → clients never
  reconfigure. Combined with spec 02 this is the full "new model everywhere
  in one click" loop.

## Architecture

### EndpointSupervisor

```
Services/EndpointSupervisor.swift      — desired state ↔ authoritative state
Services/LaunchAgentManager.swift      — plist preview/confirm/install/remove
UI/MenuBar/MenuBarController.swift     — MenuBarExtra scene
Models/EndpointModels.swift
```

### Launchd integration (with repo-discipline preview/confirm)

- Managed as a user LaunchAgent
  (`~/Library/LaunchAgents/ai.cavi.mlxmac.endpoint.plist`) whose program is
  `scripts/mlx-agent serve start --repo <model> --runtime mlx --port <port>`
  with `KeepAlive` + `ThrottleInterval` (backoff) and logs redirected into
  the receipts-visible log location.
- **Install/remove follow the same preview grammar**: the plist is generated,
  shown to the user in full (it's short), confirmed, then written atomically
  and `bootstrap`ed via `launchctl` invoked as argv tokens through
  `CLIProcess`-style execution — never a shell string.
- `launchctl bootstrap/bootout/print` outputs are parsed for status; the
  LaunchAgent is a *supervision mechanism*, not a state authority — the
  authoritative "is it serving" answer still comes from `serve status`
  receipts plus a loopback health probe (`/v1/models`).

### Reconciliation loop

`EndpointSupervisor` keeps `desired: EndpointConfig?` (model + port, persisted
in state dir). On app launch, wake, and a 30 s timer:

1. Read authoritative state: `serveStatus()` + health probe of the stable
   port + `launchctl print` presence.
2. Diff against desired:
   - desired running, actually stopped → report (launchd should have
     restarted it; repeated mismatch = surface crash-loop warning with the
     log tail link).
   - desired model ≠ served model → offer swap card.
   - desired none, something on our stable port → offer adopt-or-stop.
3. Crash-loop guard: ≥3 restarts in 5 min → supervisor marks degraded,
   stops retrying, surfaces the log; never silently burn CPU.

### Menu bar

`MenuBarExtra` scene (SwiftUI-native). Read-only status + the four actions.
No chat, no prompt field — deliberately minimal; the menu bar is plumbing
status, not a surface for doing work.

### Interactions with existing rules

- Only **verified** models (spec 01) are offered for always-on by default;
  unverified requires the same explicit override as the quality gate's
  "keep anyway".
- Fit Advisor (spec 05) verdict is shown in the always-on card; `wontFit`
  blocks enablement without override.
- The single live-convert rule is untouched: the endpoint uses `serve`,
  conversions still serialize through the existing queue.

## Settings

```json
{
  "endpoint_enabled": false,
  "endpoint_port": 8766,
  "endpoint_model_path": "",
  "endpoint_keepalive": true
}
```

## Failure modes & edges

- Port already bound by something else (e.g. LM Studio) → enable refused
  with the owner identified (`lsof` via argv tokens, parsed) and a suggested
  alternate port.
- Machine sleeps/wakes → health probe on wake; launchd KeepAlive restarts a
  killed server; supervisor only reports.
- Model file moved/quarantined → health probe fails, supervisor marks
  degraded, menu bar shows the model-missing state with a route to Library.
- Uninstall path: bootout + plist delete, previewed the same way.

## Tests

- `EndpointSupervisorTests`: reconcile matrix (desired × actual), crash-loop
  guard, port-conflict refusal, model-missing degradation.
- `LaunchAgentManagerTests`: plist generation, atomic write, bootstrapping
  argv construction (no shell), uninstall.
- Menu-bar view-model tests.

## Rollout

Phase 1: supervisor + Serve-tab card (no launchd; restart-on-launch only).
Phase 2: LaunchAgent install/remove.
Phase 3: menu bar extra.
