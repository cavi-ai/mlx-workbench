# Run and endpoints

**Run** serves chat and vision-language models on loopback ports. Every server speaks the OpenAI chat API on `127.0.0.1`.

## Serve a model

1. Select a ready model in Library, then open Run. Existing models can be served without a conversion record. Image, speech and other non-servable types get no verdict and no serve actions. An unfinished or failed current workflow for the selected output links back to **Prepare** for review.
2. Read the memory runway: what is already loaded, what this model needs (weights, KV cache and runtime overhead) and whether it **fits**, is **tight** or **won't fit** at the chosen context. A won't-fit verdict suggests a maximum context. Unavailable memory readings show as unknown.
3. **Preview serve** checks the selected runtime and shows the engine's plan. The default **Auto** uses the model's declared runtime, including an installed isolated Strata runtime. A missing base runtime does not block this check; an unavailable selected runtime fails the preview. **Confirm and run** is available only after a successful preview and starts the server.

Run lists every running server with **Stop** or **Unload**. Refreshing Run only reads serving status.

Choose **Configure clients…** on a running endpoint to open Clients with that
server selected. Clients rechecks its process and adapter identity; a changed or
stopped server requires a fresh selection from Run. Opening Clients does not
write configuration. Preview and confirm client wiring before applying it.

Model-only Run and endpoint setup do not reuse a server reported with an adapter
as its base model. Unknown adapter metadata also prevents adoption. A conflicting
endpoint names the adapter when its path is available. Model-only handoffs to
Clients match servers without adapters. Selecting an endpoint in Run or Clients
keeps its adapter identity attached to the confirmation checks.

## Serve a trained adapter

In Training, choose **Use in Run** on a completed job. This stages the receipt
without starting a server or changing your selected Library model. **Preview
adapter serve** rechecks the receipt, pinned base snapshot and adapter files.
Review the paths and port, then choose **Confirm and run adapter**.

Changed or missing artifacts require a fresh preview. Run refuses an occupied
port or a second server for the same training artifacts. The running server's
adapter label also appears in Activity, Clients and the memory header; use the
existing server controls to stop it. **Use Library model** returns to the regular
Run controls without stopping servers.

Trained adapters use explicit MLX-LM serving. They do not inherit the base
model's quality verdict and cannot be added as Always-on endpoints from this
panel. Historical training receipts without a pinned base identity cannot be
used here.

## Always-on endpoints

The **Endpoints** section keeps chosen models serving on stable ports. The app reconciles each endpoint's desired state against the engine's serving status and restarts a crashed endpoint, with a crash-loop guard per endpoint.

- **Add endpoint** suggests the next free port. Up to four endpoints.
- Endpoints require a verified model unless you explicitly override for an unverified one.
- Each endpoint row shows status, restarts, a fit chip, a role, and enable, disable and remove controls.
- The section sums the memory estimates of enabled endpoints that are not already resident. Enabling an endpoint that tips the total past won't-fit needs an explicit override. An unknown model size leaves the total unknown.
- **Wire roles…** maps roles onto running endpoints and writes the router config through the engine's `fleet apply`, with preview and receipt. Only running endpoints with Hugging Face cache repository ids are assigned; the rest are reported as skipped.

The menu bar item aggregates endpoints ("N of M endpoints running") and starts or stops each one. An optional login item, `ai.cavi.mlxworkbench.endpoint`, runs `mlx-agent serve start` once at login for the first endpoint. Its plist is shown before installation. It has no KeepAlive: the app's supervisor reconciles while it runs, and engine receipts remain the process authority.

## Load on request

New endpoints default to **Load on request**. The engine runs a loopback gateway that answers `/v1/models` while unloaded and starts the model on the first inference request.

- Concurrent cold requests share one load.
- Streaming responses hold the model until they finish; a model cannot unload mid-stream.
- **Unload** releases the model and keeps the endpoint enabled. The next request loads it again.
- **Stop server** stops an eager endpoint and saves its desired state as disabled, so it is not restarted. Model files stay on disk.
- Model file identity is checked before and after loading; changed files require a fresh plan.

Endpoints created before this mode existed keep eager serving until you change them. Changing the mode restarts the endpoint. Comparison and verification always use eager serving, and their models are protected from unload.

## Memory policy

Each load-on-request endpoint has compact controls for:

| Control | Default for new endpoints |
|---|---|
| Idle unload | After 600 seconds without requests |
| Keep loaded after use | Off; when on, the model is not unloaded automatically, but manual Unload still works |
| Headroom reserve | 2 GB |

The engine owns the idle timer, so idle unload works for requests from any client, with or without the app open. Idle time starts when the last request ends. Policy changes apply to the running gateway without a restart.

Before a cold load, the engine checks fresh system headroom against local weight bytes × 1.10 + 1.5 GB runtime allowance + the reserve, in decimal GB. Unknown headroom or weight size blocks the load and the reason stays visible. This is an estimate at load time, not a reservation: other processes, other endpoints and growing contexts change memory use afterwards.

## The memory header

The toolbar's memory header shows estimated RAM use and headroom on every screen, refreshed every five seconds. Open it for serving status and the same **Unload** and **Stop server** controls. Its context selector feeds model-fit reviews, not server configuration.

Choose **What’s using memory…** from Run’s memory runway or the toolbar popover
for an on-demand snapshot of up to 15 readable processes, sorted by resident RAM.
The table shows process names, PIDs and a capture time; **Refresh** reads again.
It never stops a process. **Open Activity Monitor** opens macOS’s process inspector.

Resident memory can include shared pages and omit GPU allocations, so the rows
do not add up to system-wide usage and cannot identify which model or client
requested an allocation. Exited or unreadable processes are omitted. Failed
refreshes retain the dated reading with a warning. The serving headroom guard
and model-fit estimate continue to use system memory readings.

**Saved model hosts** shows cached readings from your configured Ollama, LM Studio, ComfyUI and other local connections. Each row shows reported loaded models, any reported model memory, activity and capture times. Unknown residency stays unknown, including ComfyUI checkpoint inventories. These values are not added to system memory estimates.

Opening the panel never refreshes external hosts. The refresh button beside each host reads only that connection; a failed refresh keeps its dated inventory and shows the error. **Open host** selects that exact connection in Library's Hosted models source, where memory actions retain their activity review and confirmation.

## Serving profiles

Saved serving profiles carry runtime settings for one model through verification and the endpoint configuration. They are used by the optional Strata runtime; see [Strata](strata.md).
