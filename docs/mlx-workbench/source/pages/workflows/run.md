# Serving and Monitor

**Serving** serves supported local models on loopback ports. Text and vision-language endpoints use the OpenAI chat API. Classification, text embeddings, speech, music, image generation, video generation and 3D generation use typed model jobs. The installed backend must implement the selected architecture.

Typed model servers offer **Run a task…** when their ready model is in Library.
The task form opens with that server selected and uses its existing worker,
inference authentication and memory policy. Recent jobs and verified artifacts
remain attached to their original server session. See [Local inference tasks](library.md#local-inference-tasks).

**Use…** opens a work session with that server selected. Chat history and typed
task results remain accessible in [Use](use.md). **Try a prompt…** remains a
separate transient diagnostic.

## Music, sound effects and ambience

Music task forms offer a **Purpose** picker: **Music**, **Sound effects** or
**Ambience**. FX and ambience use an instrumental prompt on the selected music
model. These modes are experimental: a music model can still produce music.
They reuse the existing music API, worker and memory policy.

In **Settings → Artist Brain local audio**, choose **Use music model
(experimental)** to share Artist Brain's music endpoint, or **Specific served
audio model** to select a running local endpoint advertising `music_generation`
or `sound_effects`. Save the audio choice to apply it. A specific music endpoint
also uses experimental FX prompting. Models without a compatible installed
execution adapter are not offered. No weights or dependencies are downloaded.

Artist Brain profiles opt into this preference with `audio_routing_file` pointing
to `local-audio-routing.json` under Workbench's Application Support directory.
The shared option follows the profile's music route; the specific option records
the selected model, loopback port and receipts directory. The plugin verifies
the live service and its task capability before submitting. Unloading a shared
FX route also unloads its music worker. In Serving, the purpose picker always uses
the model being inspected.

## Serve a model

1. Select a ready model in Library, then open **Serving**, or use **+** in the endpoint list. Choose the model in the setup form. Supported standalone model types can serve without a conversion record; speculative drafters remain paired with their target.
2. **Save as endpoint** keeps a stable loopback port. Review the port, authentication, residency and inference settings, then confirm. **Start now** offers a temporary server with a runtime preview before confirmation.
3. Select an endpoint to work in **API & security**, **Inference**, **Memory** or **Connect apps**. Its start/stop and prompt actions stay above these sections.

The endpoint list combines saved endpoints, temporary Workbench servers and other detected local services. It shows model, provider, port and status. **Include available models** adds external models that are not loaded; these are hidden by default. Filtering changes only this list. Connection failures are behind **Connection issues** and do not cover the working endpoints with diagnostics. Refresh reads status without loading models.

**API & security** contains the base URL, model ID, port and API-key controls. Copy the URL or model ID directly. Stop a saved endpoint before changing its port, enabling/disabling authentication or resetting its key. Authentication changes are previewed and confirmed. The endpoint remains bound to loopback.

## Live Monitor

**Monitor** is a separate workspace for active model servers from the shared inventory. It shows provider, status, input/output tokens, active requests and the most recent response throughput. Select a row for its API address, measurement interval, completed/failed/measured request counts and source/memory details. **Open model settings** selects that exact endpoint in Serving.

Managed chat gateways report process-lifetime counters, reset when the gateway restarts. Token totals include only completed responses whose workers reported usage. Missing measurements display a dash; a reported zero stays zero. Response tokens per second includes queueing, loading and response generation, so it differs from a decoder-only benchmark. External providers without these metrics retain status and source visibility. Monitor uses the existing inventory refresh and never starts inference.

## Inference settings

Serving shows controls for the selected model's runtime. Acceleration and output settings are available in **Start now** and **Save as endpoint**. Changing a launch setting
clears its preview; review the new plan before confirming.

- **Text · MLX-LM:** choose **Standard** for native decoding and batching, or
  **Reuse prompt text** for edits that copy supplied source. Prompt reuse needs
  client temperature zero and runs eligible requests one at a time, without a
  draft model. General chat and concurrent workloads may favor Standard.
- **Vision · MLX-VLM:** **Reuse image features** caches repeated images on
  supported Qwen2.5-VL and Qwen3-VL models, up to 20 entries or 128 MiB while
  loaded. Other models retain native processing.
- **Strata:** choose decoding, expert memory and context in a serving profile.
  **New profile…** saves configuration without loading weights. Verify it before
  serving; see [Strata](strata.md).
- **Text · Splash:** in **Start now**, serves quantized MLX, GGUF and Strata
  profile weights in place with the model family's DFlash2 draft. Install Splash
  and the draft first; the preview checks both and reports the Splash version and
  served model ID. Startup waits up to 15 minutes for the model to load; see
  [Splash](splash.md).
- **Task endpoints:** generation controls belong to the typed request. Server
  residency and memory controls remain available.

The **Inference** section offers **Skip reasoning** for MLX-LM and Splash models
whose chat template supports it, and a default output length for MLX-LM and Strata. Output
length ranges from 256 to 65,536 tokens; the engine default is 8,192. Client
requests can supply their own token limits. Temperature and sampling belong to
the client. Reasoning overrides can trade deliberation for shorter responses.

Under **Hardware acceleration**, **M5 prompt processing** requests the engine's
experimental Q4 kernel. It requires an M5 GPU and supported Qwen2 models, FP16
activations, affine 4-bit weights and group size 64. First load compiles kernels;
unsupported inputs use native MLX. The control is unavailable on other chips.
It can be combined with prompt text reuse.

The launch configuration shows whether the engine configured an adapter,
reported native fallback, or did not report activation. A configured adapter
still depends on eligible models and requests; it does not establish a measured
speedup. These options are off by default and download no draft weights.

The status timeout includes engine startup and time spent waiting behind another
status check; replacing the status process does not reset that timeout.

Saved load-on-request chat endpoints also offer a default system prompt,
temperature and top-p. The gateway applies sampling defaults only when omitted
by the client, and adds the system prompt only when the client has supplied no
system or developer prompt. Typed task endpoints retain their per-request
settings. A saved endpoint must be stopped to edit launch defaults; preview and
confirm the new configuration before starting it again.

Choose **Configure clients…** on a running endpoint to open its **Connect apps**
section. Clients rechecks its process and adapter identity; a changed or
stopped server requires a fresh selection from Serving. Opening Clients does not
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
from Serving. Verification and comparisons keep priority; Stop and Unload are refused
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

Select a ready model, then choose **Save as endpoint** in **Serve a model** (**Start now** starts one server instead).
Set the port, role and **Load on request**, and, with load on request, whether weights are
released after each request or kept loaded. Choose **Add endpoint…** (**Add unverified endpoint…** for a
model that has not passed verification) and review the model, port, verification and memory warnings, then
confirm. Up to four endpoints can be saved, each on its own stable port between 1024 and 65535
that no endpoint or server already uses.

Each endpoint row shows its state and base URL. Chat endpoints use the OpenAI-compatible API; typed endpoints advertise their operations at `/v1/models` and accept jobs at `/v1/tasks`. Use **Copy base URL**
and, when a matching running server reports it, **Copy model ID** in the other
application's matching provider settings. The toolbar popover and the menu bar list the same
rows with status and copy controls. **Start…** reviews fit and verification before starting; **Stop** stops its endpoint.

**Remove…** in a row's overflow menu removes an endpoint and stops it after confirmation.
The model files stay in Library. Work using that model must finish before its
endpoint can stop. The overflow menu also holds role, load mode, memory management, inference settings,
API key and **Show in Library** actions, and **Wire roles…** and login startup sit below the list. Acceleration remains opt-in; serving a
model does not establish that one configuration is fastest for every workload.

## Always-on endpoints

Saved endpoints in **Served models** keep chosen models serving on stable ports. The app reconciles each endpoint's desired state against the engine's serving status and restarts a crashed endpoint, with a crash-loop guard per endpoint.

- **Add endpoint…** suggests the next free port. Up to four endpoints.
- Endpoints require a verified model unless you explicitly override for an unverified one.
- Each endpoint row shows status, restarts, a fit chip, a role, **Stop** or **Start…**, and an overflow menu with the remaining controls.
- The section sums the memory estimates of enabled endpoints that are not already resident. Enabling an endpoint that tips the total past won't-fit needs an explicit override. An unknown model size leaves the total unknown.
- **Wire roles…** maps roles onto running endpoints and writes the router config through the engine's `fleet apply`, with preview and receipt. Only running endpoints with Hugging Face cache repository ids are assigned; the rest are reported as skipped.

The menu bar item aggregates endpoints ("N of M endpoints running") and provides a submenu for each selected model. An optional login item, `ai.cavi.mlxworkbench.endpoint`, runs `mlx-agent serve start` once at login for the first endpoint. Its engine preview and plist are prepared before confirmation. The captured command preserves local paths, runtime selection, inference settings, load-on-request policy and receipt storage, using the preview’s Python environment. Changed or disabled endpoint settings prevent login startup; changed model or runtime evidence requires a fresh preview. Remove and reinstall the login item after changing its endpoint settings. It has no KeepAlive: the app's supervisor reconciles while it runs, and engine receipts remain the process authority.

### Inference settings for saved endpoints

Open an endpoint's actions menu and choose **Inference settings…** to review its
configuration. Stop it before changing settings, then **Preview settings** and
**Confirm and save**. Enable it again to use the saved configuration. Existing
endpoints retain runtime defaults until changed. Changing the model clears its
inference settings; Strata decoding stays in its verified profile.

The settings apply to eager servers, load-on-request workers, automatic restarts
and the first endpoint's generated login command. Reinstall an existing login
item after changing them. The endpoint row summarizes its saved choices; live
adapter details distinguish configured options from native fallback. Adoption
requires matching accelerator metadata and a confirmed receipt or fresh preview.

## Load on request

Endpoint changes are saved before starting or stopping a server. If saving fails,
the previous settings and running servers are retained. Wait for an endpoint
operation to finish before applying another change; refreshes never start a
second operation over an active edit.

New endpoints default to **Load on request**. The engine runs a loopback gateway that answers `/v1/models` while unloaded and starts the model on the first inference request.

- Concurrent cold requests share one load.
- Streaming responses hold the model until they finish; a model cannot unload mid-stream.
- **Unload model…** releases the model and keeps the endpoint enabled. The next request loads it again.
- **Stop** stops an endpoint and saves its desired state as disabled, so it is not restarted. Model files stay on disk.
- Model file identity is checked before and after loading; changed files require a fresh plan.

Endpoints created before this mode existed keep eager serving until you change them. Changing the mode restarts the endpoint. Comparison and verification always use eager serving. While verification, a comparison or a hosted comparison's local lane is serving a model, **Stop** and **Unload** refuse its server.

## Memory policy

**Settings → Serving** can apply a shared agent memory limit and a transient
reserve within that limit. The engine accounts for pending loads, resident model
workers and included agent processes. This limit is separate from system headroom
and each Strata model's memory budget. Applying it preserves the engine's included
process identities; it does not stop unrelated applications.

Each load-on-request endpoint has compact controls for:

| Control | Default for new endpoints |
|---|---|
| Idle unload | After 600 seconds without requests |
| Keep loaded after use | Off; when on, the model is not unloaded automatically, but manual Unload still works |
| Headroom reserve | 2 GB |

The engine owns the idle timer, so idle unload works for requests from any client, with or without the app open. Idle time starts when the last request ends. Policy changes apply to the running gateway without a restart.

Before a cold load, the engine checks fresh system headroom against local weight bytes × 1.10 + 1.5 GB runtime allowance + the reserve, in decimal GB. Unknown headroom or weight size blocks the load and the reason stays visible. This is an estimate at load time, not a reservation: other processes, other endpoints and growing contexts change memory use afterwards.

## The memory header

The toolbar's memory header shows estimated RAM use and headroom on every screen, refreshed every five seconds. Its label adds the loaded count at wider window sizes, plus the serving count when some served models are not in memory (for example `3 serving · 1 loaded`), and flags an endpoint that is starting or degraded. Open it for the same rows as Serving’s endpoint list, with reviewed **Unload model…** and **Stop server…** controls and **Open Serving**. Its context selector feeds model-fit reviews, not server configuration.

Choose **What’s using memory…** from the toolbar popover
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

## Local serving inventory and menu bar

**Served models** shows Workbench endpoints alongside services started by MLX Agent, including Strata, and recognized local Ollama, LM Studio, ComfyUI, llama.cpp and OpenAI-compatible server processes. Discovery reads this user’s listening processes and provider APIs at their actual ports. Engine services are found through registered receipt locations and live engine process arguments. Discovery does not search model folders or add external servers to automatic restart supervision. An older engine reports that cross-location engine discovery needs an update.

Rows distinguish loaded, unloaded, loading, failed and unknown residency. The same service reported through its engine receipt and listening process appears once. Failed sources retain dated observations and an error. Paths, runtime, active requests and process identity appear when available. Provider APIs may omit storage locations or residency.

System headroom, observed process RAM, shared host process RAM, provider-reported model memory and source estimates are shown separately. They are not added into a model-memory total: shared pages, host processes and GPU allocations overlap. **Unload model…** and **Stop server…** review the selected process, recheck ownership before acting and read status afterwards. Provider unload uses that provider’s model, instance or whole-host scope; unsupported actions are unavailable.

The menu bar lists observed models and residency and opens the same controls, Settings and main window. Closing the last window keeps serving controls available. **Quit MLX Workbench** exits the app; detached engine services keep their engine-owned lifecycle.

### Vision feature reuse

**Reuse image features** requests the engine’s MLX-VLM image-feature cache for repeated images. It is off by default and separate from MLX-LM text acceleration. A new launch preview checks runtime and model compatibility. Saved endpoints use the same source-bound setting; a reported request for acceleration does not establish that every inference used it.

### Review memory policy

For a load-on-request endpoint, **Review memory policy…** previews idle unloading, reserve, pressure handling and supported context or Strata budget settings before confirmation. A changed endpoint or launch preview requires reviewing again.

Pressure handling checks reserve before new requests and unloads idle weights when headroom falls below it. Active requests finish first. Keep loaded disables automatic pressure unloading. For native text runtimes, admission context changes the KV-cache estimate used before loading; it does not change the runtime’s context limit. Strata uses the context from its serving profile.

A Strata total model budget estimates fixed weights, runtime and context requirements, then assigns the remaining allowance to the expert cache. It cannot be combined with a fixed expert-memory profile. Changing a budget schedules a loaded worker to reload after active requests finish. This is an estimated allowance, not a measured allocation or an operating-system memory cap.

## Typed model jobs and residency

When adding a model, choose **Release weights after each request** for one-off
jobs and benchmarks, or **Keep loaded between requests** for a session. Both load
weights on the first request. Release mode stops the owned model worker after
completion; keep mode retains the same model object for the next job. Existing
caches stay in place and serving never downloads weights. Change either choice
later in the endpoint's **Memory management** controls. Manual Unload keeps the
endpoint reachable; Stop also closes it. Active jobs finish or are cancelled
before their weights are released.

Typed endpoints accept `POST /v1/tasks` with `kind` and `parameters`:

| Model | Job kind | Output |
| --- | --- | --- |
| Classifier | `classification` | Typed answers |
| Text embedding | `embedding` | Finite embedding vectors |
| Speech recognition | `transcribe` | Transcript |
| Speech synthesis | `speak` | WAV audio |
| Music generation | `music_generation` | WAV audio |
| Image generation | `image_generation` | PNG image |
| Video generation | `video_generation` | MP4 video |
| 3D generation | `mesh_generation` | GLB model |

Use only the kinds returned by that endpoint's `/v1/models`. Parameters follow
the engine's [task contract](https://cavi-ai.xyz/docs/mlx-agent/lifecycle/tasks).
For example, a music endpoint accepts:

```json
{"kind":"music_generation","parameters":{"caption":"Gentle instrumental piano","duration":15,"seed":42}}
```

The response supplies a durable task ID. Read `/v1/tasks/ID` for status and
`/v1/tasks/ID/result` for validated results. Download generated media from
`/v1/tasks/ID/artifacts/output`, or the complete result JSON from
`/v1/tasks/ID/artifacts/result`. Cancel with `POST /v1/tasks/ID/cancel` and an empty
JSON object. Each endpoint runs one job at a time and refuses overlapping jobs.
Input media is retained with the task; changed model files, adapters, inputs or
result artifacts require a fresh review or job. Job history survives a client
disconnection. Interrupted endpoint processes leave an interrupted job rather
than a successful result.

Typed endpoints expose residency, worker PID, memory controls and source paths
in the same inventory and menu bar as chat endpoints. Chat prompt tests, chat
client wiring and role routing are available only for chat endpoints.

## Require an API key

When saving a model as an endpoint in **Serve a model**, turn on **Require API key**; an existing endpoint's overflow menu offers **Require API key…**, **Reset API key…** and **Disable authentication…** while it is stopped. The
endpoint stays on loopback and loads weights on request. Use **Copy base URL**,
**Copy model ID** and **Copy API key** to configure each authorized client.
Keys are generated securely and saved in Keychain. Endpoint settings, launch
arguments and exports contain only a verification digest.

For a saved endpoint, stop it first, then choose **Require API key…**. Review
and save the change, then start the endpoint. **Reset API key…** creates a new
key and revokes the previous one after restart. Authentication changes leave
the endpoint stopped. **Disable authentication…** explicitly restores access
for local clients without a key.

Protected endpoints require `Authorization: Bearer KEY` or `x-api-key: KEY`
for model discovery, inference, task history, cancellation and artifacts.
Requests without a valid key receive HTTP 401 before inference. Internal
workers require separate credentials over Unix sockets or loopback ports. Workbench's **Try a prompt**
uses the endpoint key from Keychain. Automatic client wiring and role routing
skip protected endpoints; configure the copied key directly in each client.

Any client holding the key is authorized. Keep it private and reset it if it
has been shared unintentionally. Loopback limits access to this machine; API
keys do not create an executable allowlist. Authentication is optional, and
existing endpoints keep their current access mode.

## Menu-bar access

The **CPU** icon identifies MLX Workbench in the macOS menu bar; a green dot
indicates loaded models. Open it for model status, start/stop, reviewed unload,
API copy actions, Monitor, Settings and Quit. Available-but-unloaded external
models are omitted from this quick menu. Closing the main window keeps
Workbench and its model servers running. Use **Open MLX Workbench** to return
to the window. Login-item controls remain under Memory for startup persistence.
