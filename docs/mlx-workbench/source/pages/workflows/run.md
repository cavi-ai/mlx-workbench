# Run and endpoints

**Run** serves chat and vision-language models on loopback ports. Every server speaks the OpenAI chat API on `127.0.0.1`.

## Serve a model

1. Select a ready model in Library, then open Run. Existing models can be served without a conversion record. Image, speech and other non-servable types get no verdict and no serve actions. An unfinished or failed current workflow for the selected output links back to **Prepare** for review.
2. Read the memory runway: what is already loaded, what this model needs (weights, KV cache and runtime overhead) and whether it **fits**, is **tight** or **won't fit** at the chosen context. A won't-fit verdict suggests a maximum context. Unavailable memory readings show as unknown.
3. **Preview serve** checks the selected runtime and shows the engine's plan. The default **Auto** uses the model's declared runtime, including an installed isolated Strata runtime. A missing base runtime does not block this check; an unavailable selected runtime fails the preview. **Confirm and run** is available only after a successful preview and starts the server.

Run lists every running server with **Stop** or **Unload**. Refreshing Run only reads serving status.

**Experimental M5 prompt acceleration** opts the server started with **Preview
serve** into the engine's Q4 prompt kernel. It requires an M5 GPU, macOS 26,
MLX/`mlx-metal` 0.31.1 and `mlx-lm` 0.29.1. It targets inference-only Qwen2 MLPs
with FP16 activations, affine 4-bit weights and group size 64, on prompt batches
of at least 128 rows. Original weight storage is retained; inputs with fewer than 128 rows use native MLX.
Unsupported inputs and a failed preparation compile use native MLX. The first
load compiles the kernel; speed depends on model and prompt shape. The server log
reports the adapted layer count. No speedup is guaranteed.
The engine wraps only its own Python environment's MLX-LM entrypoint; separately
installed runtimes retain their native launch and report `adapter_enabled: false`
in the preview. Selecting another serving runtime requires disabling this option.

The option is off by default. Saved endpoints have separate acceleration settings;
comparisons, verification, LoRA adapters and Strata profiles retain their existing
execution. Changing the option after preview requires a new
preview. Source and dependency hashes are bound into the engine plan and receipt.

The status timeout includes engine startup and time spent waiting behind another
status check; replacing the status process does not reset that timeout.

**Experimental code-edit acceleration** uses text already in the prompt to propose
short continuations, then verifies them with the loaded model. It is intended for
small edits that copy most of the supplied source. Set the client temperature to
zero. Plain greedy requests run one at a time on this server; keep the option off
when concurrent chat throughput matters. Speed depends on how much text the model
can reuse, and prompts without matching source may be slower.

This option requires MLX/`mlx-metal` 0.31.1 and `mlx-lm` 0.29.1 on macOS. Sampled
requests, logit penalties or biases, seeds, logprobs and LoRA or draft models use
native generation. Unsupported cache types and runtimes also use native generation.
No draft model is downloaded and weights are unchanged. The option is off by
default, can also be selected for saved endpoints, and can be combined with M5
prompt acceleration. Changing either option requires a new preview. The engine
records the requested configuration as `decode_profile` in the plan and receipt.

Choose **Configure clients…** on a running endpoint to open Clients with that
server selected. Clients rechecks its process and adapter identity; a changed or
stopped server requires a fresh selection from Run. Opening Clients does not
write configuration. Preview and confirm client wiring before applying it.

Model-only Run and endpoint setup do not reuse a server reported with an adapter
as its base model. Unknown adapter metadata also prevents adoption. A conflicting
endpoint names the adapter when its path is available. Model-only handoffs to
Clients match servers without adapters. Selecting an endpoint in Run or Clients
keeps its adapter identity attached to the confirmation checks.

## Try a prompt

On a running server, **Try a prompt…** opens a temporary test window for that
endpoint, including its adapter when present. Enter up to 4,000 characters and
choose **Send prompt**. Each request sends one question with a 256-token output
limit. A load-on-request endpoint may load its model; its memory checks still apply.
Opening the window and editing the prompt never send a request.

Workbench checks the selected server's process and adapter identity before and
after the request. A changed or unavailable endpoint requires reopening the test
from Run. Verification and comparisons keep priority; Stop and Unload are refused
while this test holds the model.

The window distinguishes a returned answer, a token limit, missing answer text
and unconfirmed completion. Reasoning is available separately when returned.
Editing the prompt clears the previous result. A returned answer does not mark
the model verified or establish its quality, and tests do not enter comparison
history. **Configure clients…** after a finished answer opens the existing client
configuration review for this endpoint.

**Cancel request**, closing the window or leaving Run cancels Workbench's request;
the server remains running and may still be finishing generation. Requests time
out after at most two minutes of transport activity. Errors retain the prompt for
an explicit retry; there is no automatic resubmission. Closing clears the test's
prompt and output from the window.

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

## Serve models to other apps

Choose **Manage served models…** from the menu bar to open the model manager.
Search ready local models and choose **Add…**, review the model, port, verification
and memory warnings, then confirm. New selections use the existing load-on-request
endpoints; there is no separate serving process for the manager. Up to four models
can be selected, each on its own stable port. Models already selected are omitted
from the add list.

Each selection shows its state and OpenAI-compatible base URL. Use **Copy base URL**
and, when a matching running server reports it, **Copy model ID** in the other
application's OpenAI-compatible provider settings. **Refresh status** updates the
reported servers. The menu bar also lists each selected model with status and copy
controls. **Start…** opens the manager for review; **Stop** stops its endpoint.

**Remove…** removes a serving selection and stops its endpoint after confirmation.
The model files stay in Library. Work using that model must finish before its
endpoint can stop. **Serving settings…** opens Run for memory policy, acceleration,
login startup and client configuration. Acceleration remains opt-in; serving a
model does not establish that one configuration is fastest for every workload.

## Always-on endpoints

The **Endpoints** section keeps chosen models serving on stable ports. The app reconciles each endpoint's desired state against the engine's serving status and restarts a crashed endpoint, with a crash-loop guard per endpoint.

- **Add endpoint** suggests the next free port. Up to four endpoints.
- Endpoints require a verified model unless you explicitly override for an unverified one.
- Each endpoint row shows status, restarts, a fit chip, a role, and enable, disable and remove controls.
- The section sums the memory estimates of enabled endpoints that are not already resident. Enabling an endpoint that tips the total past won't-fit needs an explicit override. An unknown model size leaves the total unknown.
- **Wire roles…** maps roles onto running endpoints and writes the router config through the engine's `fleet apply`, with preview and receipt. Only running endpoints with Hugging Face cache repository ids are assigned; the rest are reported as skipped.

The menu bar item aggregates endpoints ("N of M endpoints running") and provides a submenu for each selected model. An optional login item, `ai.cavi.mlxworkbench.endpoint`, runs `mlx-agent serve start` once at login for the first endpoint. Its engine preview and plist are prepared before confirmation. The captured command preserves local paths, runtime selection, acceleration, load-on-request policy and receipt storage, using the preview’s Python environment. Changed or disabled endpoint settings prevent login startup; changed model or runtime evidence requires a fresh preview. Remove and reinstall the login item after changing its endpoint settings. It has no KeepAlive: the app's supervisor reconciles while it runs, and engine receipts remain the process authority.

### Acceleration for saved endpoints

Disable the endpoint and wait for its server to stop. Open its actions menu and
choose **Acceleration…**, select **M5 prompt acceleration**, **Code-edit
acceleration**, or both, then **Preview acceleration** and **Confirm and save**.
Enable the endpoint again to use the saved settings. Existing endpoints keep native
MLX defaults until you change them. Changing the model clears its acceleration
settings; Strata profiles use their own controls.

Saved acceleration applies to eager servers, load-on-request workers, automatic
restarts and the first endpoint's generated login command. Reinstall an existing
login item after changing these settings. Code-edit requests need client temperature
zero and run one at a time. Hardware and request restrictions are the same as for
manual launches. The endpoint row reports acceleration as requested; unsupported
inputs may still use native execution. A running server must match the saved acceleration settings and either its recorded
launch receipt or a fresh launch preview before it is adopted.

## Load on request

Endpoint changes are saved before starting or stopping a server. If saving fails,
the previous settings and running servers are retained. Wait for an endpoint
operation to finish before applying another change; refreshes never start a
second operation over an active edit.

New endpoints default to **Load on request**. The engine runs a loopback gateway that answers `/v1/models` while unloaded and starts the model on the first inference request.

- Concurrent cold requests share one load.
- Streaming responses hold the model until they finish; a model cannot unload mid-stream.
- **Unload** releases the model and keeps the endpoint enabled. The next request loads it again.
- **Stop server** stops an eager endpoint and saves its desired state as disabled, so it is not restarted. Model files stay on disk.
- Model file identity is checked before and after loading; changed files require a fresh plan.

Endpoints created before this mode existed keep eager serving until you change them. Changing the mode restarts the endpoint. Comparison and verification always use eager serving. While verification, a comparison or a hosted comparison's local lane is serving a model, **Stop server** and **Unload** refuse its server.

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

If disabling or removing an endpoint cannot confirm its server stopped, Run keeps the failure visible. **Retry stopping servers** rechecks the server identity and retries the stop. Automatic starts for that endpoint remain paused until the stop is confirmed.
