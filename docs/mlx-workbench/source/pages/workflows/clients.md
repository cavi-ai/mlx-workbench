# Clients

**Clients** points local coding tools at a running loopback server. Every write is previewed, backed up and reversible.

## Supported clients

| Client | Config file | Mode |
|---|---|---|
| opencode | `~/.config/opencode/opencode.jsonc` | Writable |
| OpenClaw | `~/.openclaw/openclaw.json` | Writable JSON5 |
| Hermes | `~/.hermes/config.yaml` | Writable YAML |
| Codex | `~/.codex/config.toml` | Writable TOML |
| Claude Code | `~/.claude/settings.json` | Writable |
| Continue | `~/.continue/config.json` | Writable legacy JSON configs |
| Zed | `~/.config/zed/settings.json` | Writable |
| Aider | `~/.aider.conf.yml` | Writable |
| LM Studio, Ollama | None | Advisory only |

Write targets are a fixed allowlist of these paths. Symbolic links at the config, backup or restore path are refused.

## Add clients and check setup

**Connect app…** opens setup for OpenCode, OpenClaw, Hermes, Codex and Claude Code. Choose the app and a running model endpoint, **Review setup**, then **Apply setup**. Workbench creates missing config files, retains unrelated setting values and backs up existing files. JSON5, YAML and TOML files are reformatted; the review warns when comments may be removed. API keys are supplied automatically for protected endpoints.

**Test connection** sends one short prompt through the bundled CAVI API client using Chat Completions, Responses or Messages, according to the selected app. It checks the exact written configuration and server identity before and after the request. Testing may load the selected model. Success means the server responded using that protocol; open a new client session to use the configuration. App detection is separate from connection testing. Missing apps have an official installation link and can be configured before installation. OpenClaw gateways need a restart to reload configuration. Project settings and launch options can override user settings.

**Undo setup** reverses that setup transaction while its files still match the applied contents. **Connect another app** reuses the same flow for another client.

**Check existing setup…** checks supported config files, running Workbench endpoints and saved model-host connections. Progress names the current check; results show the check time, missing configs, unreadable or linked files, and endpoint mismatches. Checks never install applications, write configs, start servers or generate output.

Choose a running endpoint, then **Review config…** beside one client. OpenCode, Zed and Aider can create a config even when its folder does not exist. The wiring preview lists only that client; **Confirm client wiring** performs the existing server and file checks before writing. Rollback restores a backup or moves an unchanged newly created config to Trash. Unreadable and linked configs require manual review. Continue’s adapter supports existing legacy JSON files; its guide covers current YAML setup, and the doctor does not create a legacy file for a new installation.

**Install / setup guide** opens the application’s official instructions. Creating a config does not establish that the application is installed or that it used the endpoint.

The doctor offers the same **Add connection…** flow for Ollama, LM Studio, ComfyUI, llama.cpp and OpenAI-compatible hosts, including when no application folder was detected. Presets fill the local URL; review it and use **Test connection** before **Save host**. Saved hosts offer **Edit / test…**, dated inventory results and connection errors. Tests read inventory only; failed checks retain earlier snapshots. Canceling an editor saves nothing. See [Hosted models](library.md#hosted-models) for host capabilities.

## The wiring board

The board reads each writable client's config and draws what it points at against the servers running now. It reads only the URL parts and model names, never writes, and refreshes when you open the screen, refresh clients and servers, or finish a confirm or rollback. Refresh also detects clients configured or removed while the screen is open. When no clients are detected, the board lists the supported writable clients.

## Wire a client

1. **Refresh clients and servers**, then choose a running server.
2. **Preview client wiring** shows the exact change to each config file. The preview binds the server's identity.
3. **Confirm client wiring** reads fresh serving status first and refuses a server that stopped, was replaced or is ambiguous. It then rechecks each file for changes since the preview, backs it up and writes it atomically.

The result reports zero, partial or full outcomes per client. The opencode adapter adds opencode's `$schema` when it is missing or empty, since opencode rewrites a loaded config without one.

## API-key protected endpoints

Protected endpoints appear in the same server picker and **Wire into clients** handoff. Preview checks that Workbench can read the matching inference key from Keychain. Confirmation rechecks the running process, model and key identity before writing. Key lookups run off the UI thread and refuse permission prompts. A missing, locked or reset key requires a new preview; authentication is never disabled to complete setup.

OpenCode, OpenClaw, Hermes, Codex, Claude Code, Continue’s legacy JSON adapter and Aider receive the inference key in their supported configuration fields. Configs, temporary writes and backups are readable and writable only by your macOS user. The review names the credential destination and masks key values. Wiring history records paths and content digests, never keys. Keep these config files and backups out of shared folders and source control.

Zed stores API keys in its own system-keychain entry. Workbench writes its endpoint settings and shows **Finish API-key setup in Zed**. Use **Copy inference key**, then paste it into Zed’s OpenAI provider in Agent Settings. Workbench never puts the key in Zed’s settings file. Continue’s current YAML format remains a guided setup; use its official secret configuration instructions.

**Try a prompt…** checks the selected endpoint with its configured inference key. It generates output and may load a model configured to load on request. A successful prompt proves endpoint access, not that another client has used it. Missing or wrong credentials are refused by the endpoint. Keys authorize requests; they do not identify an operating-system process. Each endpoint has one inference key: resetting it affects every app using that key. Control credentials are never given to clients.

Client credential formats: [OpenCode](https://opencode.ai/docs/providers/), [Aider](https://aider.chat/docs/config/api-keys.html), [Zed](https://zed.dev/docs/ai/use-api-access), [Continue](https://docs.continue.dev/guides/configuring-models-rules-tools).

## Manual wiring

For a model by Hugging Face repository id, enter the repo id, a config file path and a target runtime, then **Preview Wire**. The review lists all three; **Confirm manual wiring** applies the engine's wire transaction.

## Roll back

**Roll back last wiring** restores each file from its backup only while its contents still match what wiring wrote. A config file the wiring created moves to the Trash under the same check. Files you have since edited are kept. Older backup records without a recorded content digest require manual review and recovery from their backup.

A partial rollback keeps the action available for retry. Clients already restored are skipped, including after restarting the app.

## Handoffs

**Wire into clients** in Compare's model guidance opens Clients with that model and port preselected, when a matching endpoint is running. After a successful wiring, **Review report in Compare…** opens Compare's workflow-evidence import with the endpoint and wired clients prefilled. Wiring records configuration context only; it never proves a task used the endpoint. See [Compare](compare.md).

## Connect from the serving model

In **Serving**, select a running chat endpoint and open **Connect apps**. Choose the app, then **Connect…** to open the same reviewed setup with that endpoint preselected. Address, port, model and authentication stay bound to the selected process.

**Manual setup** offers copyable provider fragments or launch commands for temporary overrides. Protected recipes refer to `WORKBENCH_API_KEY`; copy the key from **API & security** and supply it through the client’s environment. Recipes contain no inference key.

Codex and Claude Code require a managed load-on-request chat gateway, which supports Responses and Messages respectively. A model’s tool support determines its usefulness in coding agents. Setup links to each client’s documentation.
