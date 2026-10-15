# Clients

**Clients** points local coding tools at a running loopback server. Every write is previewed, backed up and reversible.

## Supported clients

| Client | Config file | Mode |
|---|---|---|
| opencode | `~/.config/opencode/opencode.jsonc` | Writable |
| Continue | `~/.continue/config.json` | Writable |
| Zed | `~/.config/zed/settings.json` | Writable |
| Aider | `~/.aider.conf.yml` | Writable |
| LM Studio, Ollama | None | Advisory only |

Write targets are a fixed allowlist of these paths. Symbolic links at the config, backup or restore path are refused.

## The wiring board

The board reads each writable client's config and draws what it points at against the servers running now. It reads only the URL parts and model names, never writes, and refreshes when you open the screen, refresh clients and servers, or finish a confirm or rollback. Refresh also detects clients configured or removed while the screen is open. When no clients are detected, the board lists the supported writable clients.

## Wire a client

1. **Refresh clients and servers**, then choose a running server.
2. **Preview client wiring** shows the exact change to each config file. The preview binds the server's identity.
3. **Confirm client wiring** reads fresh serving status first and refuses a server that stopped, was replaced or is ambiguous. It then rechecks each file for changes since the preview, backs it up and writes it atomically.

The result reports zero, partial or full outcomes per client. The opencode adapter adds opencode's `$schema` when it is missing or empty, since opencode rewrites a loaded config without one.

## Manual wiring

For a model by Hugging Face repository id, enter the repo id, a config file path and a target runtime, then **Preview Wire**. The review lists all three; **Confirm manual wiring** applies the engine's wire transaction.

## Roll back

**Roll back last wiring** restores each file from its backup. A config file the wiring created moves to the Trash only while it still holds exactly what was written; a file you have since edited is kept.

## Handoffs

**Wire into clients** in Compare's model guidance opens Clients with that model and port preselected, when a matching endpoint is running. After a successful wiring, **Review report in Compare…** opens Compare's workflow-evidence import with the endpoint and wired clients prefilled. Wiring records configuration context only; it never proves a task used the endpoint. See [Compare](compare.md).
