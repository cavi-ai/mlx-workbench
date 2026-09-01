# 02 — Cross-client Wiring

**Status:** implemented (opencode, Continue, Zed, Aider writable; LM Studio + Ollama advisory) · **Tier:** Premium

## Problem

`wire apply` writes mlx-agent's own config. But the user's actual clients are
elsewhere: `opencode.jsonc`, LM Studio, Continue, Zed, Aider, Ollama. After
every model swap the user hand-edits three or four JSON files, restarts
clients, and hopes they didn't typo a port. That is exactly the glue work a
premium tool should eliminate — without becoming another abstraction layer:
the app writes the *clients' own* configs, in their own formats, atomically,
with rollback.

## Goal

**"Make this my coding model everywhere"** — one action: detect installed
clients, compute a per-client edit plan, show a unified diff preview, apply
all edits as one transaction with per-file backup, and offer one-click
rollback.

## Non-goals

- No new config format. The app never becomes the runtime authority for any
  client; it only writes each client's native file.
- No client plugins or extensions. Files only.
- No network calls. Detection is local filesystem + defaults.

## User experience

- New **Wiring** tab (replaces/extends today's Wire view) with two sections:
  1. **mlx-agent target** — existing `wire apply` flow, unchanged.
  2. **Detected clients** — rows: name, config path, current model/baseURL,
     proposed change, status icon.
- Button **"Wire selected model to all detected clients"** → unified preview
  sheet: per-client diffs (old → new), checkboxes to exclude a client, one
  **Confirm** → transaction applies → per-client results, restart hints
  ("Restart Zed to pick up the change"), and a **Rollback** button valid
  until the next wiring transaction.
- A model row context menu in Library: **Wire to clients…** (prefilled).

## Architecture

### ClientAdapter protocol

```swift
protocol ClientAdapter: Sendable {
    var clientID: String { get }          // "opencode", "zed", "continue", ...
    var displayName: String { get }
    func detect(fileManager: FileManager) -> ClientInstallation?
    func plan(install: ClientInstallation, endpoint: WireEndpoint) throws -> ClientEditPlan
    func apply(_ plan: ClientEditPlan) throws -> ClientEditReceipt
    func rollback(_ receipt: ClientEditReceipt) throws
}

struct WireEndpoint: Equatable {          // what we're pointing clients at
    let baseURL: URL                      // http://127.0.0.1:<port>/v1
    let modelName: String                 // served model id
    let apiKey: String?                   // usually nil locally
}

struct ClientEditPlan: Equatable {
    let clientID: String
    let configPath: String
    let before: String                    // full file contents
    let after: String
    let summary: String                   // "Set openai.baseURL, set model to X"
    var diff: String                      // unified diff for the preview sheet
}

struct ClientEditReceipt: Codable {
    let clientID: String
    let configPath: String
    let backupPath: String                // config.json.mlxmac-backup-<timestamp>
    let appliedAt: Date
}
```

### Initial adapters (ship set)

| Adapter | Detection | Edit |
| --- | --- | --- |
| **opencode** | `opencode.jsonc` in project or `~/.config/opencode/` | JSONC parse → set provider baseURL + model; JSONC round-trip preserving comments (JSONC is already in-repo practice) |
| **Continue** | `~/.continue/config.json` (and `.continue/config.yaml` v2) | add/update an `OpenAI` provider entry |
| **Zed** | `~/.config/zed/settings.json` | `language_models.openai.api_url` + default model |
| **Aider** | `~/.aider.conf.yml` | `openai-api-base`, `model` (YAML, minimal key update) |
| **LM Studio** | `~/.lmstudio/` presence | *Not* a config write — instead surface "import path" guidance pointing at the converted output dir; LM Studio owns its own state. Detection only, marked `advisory`. |
| **Ollama** | `ollama` on PATH | advisory row: suggests `OLLAMA_HOST` note; no file writes. |

Advisory rows are deliberate: the feature **augments** LM Studio/Ollama
instead of fighting their state models.

### WiringCoordinator

```
Services/WiringCoordinator.swift    — detect → plan → preview → apply/rollback
Services/WiringTransactionStore.swift
Models/WiringModels.swift
```

Mirrors the established discipline:

- **Preview/confirm**: `plan()` produces all diffs + a `previewHash`
  (SHA-256 over canonicalized plans) computed locally; confirm requires the
  hash, same UX grammar as convert/serve/wire.
- **Atomic per file**: write to `config.json.tmp-<pid>`, `fsync`, rename over
  the original. Backup the original to a sibling
  `.<name>.mlxmac-backup-<timestamp>` before rename.
- **Post-write validation**: re-parse the written file (JSON/JSONC/YAML per
  adapter); parse failure → automatic rollback of that file, transaction
  reports partial failure.
- **Transaction journal**: receipts persisted to
  `$XDG_STATE_HOME/mlx-workbench/wiring-transactions.json` (same corrupt-file
  preservation convention). Rollback replays backups in reverse order.

### Endpoint source of truth

The `WireEndpoint` comes from **authoritative serve status**, not user text:
`modelWorkflow.servers` first entry with `state == running`, or the planned
endpoint from the Always-on supervisor (spec 06) when enabled. If no server
is running, the Wiring tab offers **"Start endpoint first"** which routes to
Serve with the model preselected — it never writes a config pointing at a
dead port without telling the user.

## Security constraints (repo rules carried through)

- Writes restricted to a hard-coded allowlist of well-known per-client config
  paths (expanded from `~`, symlink-resolved); anything outside → row shows
  "manual only".
- No shell strings; adapters are pure Swift file I/O.
- JSONC handling uses a tolerant parser but **never strips comments** —
  round-trip preserves user formatting wherever possible; if faithful
  round-trip fails, the plan is marked "rewrite required" and needs an
  explicit extra checkbox.
- Secrets: adapters never read or copy API-key values into logs/diffs; key
  fields render as `•••` in the preview.

## Failure modes & edges

- **Client not installed** → not listed (detection is positive-only).
- **Config doesn't exist but client is installed** → plan offers "create
  minimal config" with the new-file content shown in full.
- **Concurrent modification** (file changed between plan and confirm) →
  hash mismatch, confirm refused, re-plan offered. Same intent-drift guard as
  `ModelWorkflowCoordinator.confirm`.
- **Partial apply** (2 of 4 clients succeeded) → transaction receipt records
  per-client outcome; rollback restores exactly the touched files.

## Tests

- Per-adapter fixtures: real sample configs in, expected plans out.
- JSONC round-trip preservation tests (comments, trailing commas).
- Transaction tests: partial failure rollback, concurrent-modification
  refusal, backup integrity.
- `WiringCoordinatorTests`: end-to-end with temp-dir homes.

## Rollout

Ship adapters incrementally: opencode + Continue first (the repo's own
users), Zed/Aider next, advisory rows from day one.
