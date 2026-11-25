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
3. Select an endpoint to work in one scrolling form. A bar pinned above the form keeps the endpoint in view while you scroll: its state and model, the base URL with a copy button, the port with **Change…**, a lock that turns Workbench key protection on or off, and **Start server…** or **Stop server**. The sections are **Status** (model, role, state, model ID), **Load** (runtime, system headroom, load on request, residency, memory check and reserve, execution wait, Splash preset, with **Review memory policy…**, **Model router…** and the login item in one row), **Inference** and **Experimental** (chat roles only), **Server** (API key, Tailscale share, app setup) and **Tasks** (typed roles only). Hover a control for a plain-English explanation and its valid range. **Preview settings** and **Discard changes** are available only while an inference setting differs from what the endpoint serves with.

When a discovered endpoint already serves the selected model, **Open existing endpoint** takes you to its settings. The endpoint keeps its existing configuration. If the engine refuses a start because the model already has an endpoint, the message names that endpoint's address, runtime, state and whether it requires an API key.

To run one model on more than one endpoint, open **Settings → Serving → Duplicate serving** and choose **Allow a model…**. Workbench shows the exact model the engine will allow; **Confirm** saves it. **Remove…** returns a model to one endpoint. A change applies to endpoints started after it, and API keys and memory admission stay in effect.

To reach several endpoints through one address, use the **Workbench API** row at the top of the Serving list; **Settings → Serving → Workbench API port** sets its port (default 8090). Choose **Create key and start**. Workbench creates one Workbench API key in Keychain, saves the port and key reference in `endpoint-fleet.json`, and runs `mlx-agent serve front-door` on 127.0.0.1 while Workbench is open. A port already in use is refused. The row shows the address, state and the number of routed models, with **Start**/**Stop**, **Copy address**, **Workbench key…** and **Set up an app…**. **Workbench key…** opens the Workbench key wizard (see Require an API key below). The Workbench API routes requests by model name to running load-on-request chat endpoints and typed task endpoints (such as `/v1/embeddings` for `embedding` routes and `/v1/systemone` for `classification` routes) that use its key; to add an endpoint, stop it and turn on the endpoint bar's key lock (or choose **Use Workbench key…** in **Server** for an endpoint with its own key), which is previewed and confirmed like other authentication changes. `/v1/models` advertises both chat models and typed routes with their `task_kinds`, and the row lists the routed model count. Starting, stopping, swapping or removing an endpoint automatically refreshes the Workbench API's route list while it is running. Each model name behind the Workbench API must map to a single endpoint using the Workbench API key: if two enabled endpoints share the key and advertise the same model name, the Workbench API row warns about the collision and the Workbench API omits that name from `/v1/models` and returns `409 ambiguous_model` until only one endpoint uses the Workbench API key for that model. Endpoints keep their own ports, loading and memory admission, and the Workbench API key stays in Keychain when no endpoint uses it.

The endpoint list has three sections. **Roles** has one row per serving role, in catalog order, each on its own canonical port; an assigned role shows its model, port and status with **Stop** or **Start** and **Change model…**, and an unassigned role shows **Not assigned - :port** and **Choose model…**. **Custom endpoints** lists saved endpoints without a role and **Add custom endpoint…**. **Other servers on this Mac** is collapsed, with a count, and lists external servers and inventory entries. **Choose model…** lists ready Library models whose task the role accepts; the review shows the role's port and a confirmation adds the endpoint. Each row shows model, provider, address and status. **Include available models** adds external models that are not loaded; these are hidden by default. When live endpoints identify the same local model path, select an address in the model details to manage that endpoint. Filtering changes only this list. Sources that missed the latest refresh are listed under the endpoint list, with each source and its message in the sheet. They do not cover the working endpoints with diagnostics. Refresh reads status without loading models.

The pinned bar holds the base URL, port and key lock; **Status** shows the model ID and **Server** copies or resets the API key. Stop a saved endpoint before changing its port, enabling/disabling authentication or resetting its key. Authentication changes are previewed and confirmed. The endpoint remains bound to loopback.

## Share a chat endpoint with Tailscale

For a running managed chat endpoint that requires an API key, select **Access → Share via Tailscale…**. The wizard checks for Tailscale 1.104.2 or later, MagicDNS, and HTTPS. Tailnet grants or ACLs control reachability. Client requests also require the endpoint's API key. Enabling HTTPS can publish the device's DNS name in a certificate transparency log.

Review the model and HTTPS address, then choose **Start sharing**. Copy the API URL and model ID to a permitted device. To confirm that device can connect, use the model-list command under **Test from another device** and copy the API key separately. If the HTTPS port is occupied, choose another port and check again. If the endpoint has no key, select an already protected endpoint or create an eligible one in Endpoint setup.

Sharing lasts while Workbench runs, including after you close the wizard. While it is on, the endpoint shows its Tailscale address in Serving and Live Monitor, and its menu bar entry adds **Copy Tailscale URL** and **Stop sharing**. **Stop sharing** keeps the local endpoint and its credentials in place.

## Live Monitor

**Monitor** is a separate workspace for active model servers from the shared inventory.

**Memory** shows available and total memory, then one bar that splits physical memory into the categories Activity Monitor uses: app memory, wired, compressed, cached files and free. Hover a category for what it holds. **Using the most** lists the six processes with the largest physical footprint, read when Monitor opens and on **Refresh**; a process that serves a listed model is tagged with that model. **All processes…** opens the full list.

Three tiles follow: live endpoints and how many are loaded, the memory of the processes that serve them, and completed requests with output tokens since each gateway started. The endpoint list shows provider, status, known memory and the last request's decode speed. Models that need attention come first; their **Needs attention** status, here and in Serving, opens the engine's reason in place, and the selected endpoint's header repeats it.

Select an endpoint for its cards:

| Card | Shows |
|---|---|
| Header | Name, status, runtime and port; **Edit settings…** selects that exact endpoint in Serving |
| Performance | Decode and prompt tokens per second, time to first token and response time of the last request; a bar splits that response into wait, prompt and decode shares; completed, failed, input and output token totals |
| Settings | The endpoint's current loading, generation and acceleration settings, resolved with the model's defaults; **Edit…** opens them in Serving |
| Memory | Provider allocation, model process, gateway and shared host memory with their PIDs, MLX allocator memory and the source estimate |
| Connection | API address and Tailscale address |
| Source | Model ID, model path, receipts and runtime; **Reveal in Finder** opens a local model |

Managed chat gateways report process-lifetime counters, reset when the gateway restarts. Stage timing comes from streamed requests: wait covers queueing and loading, prompt runs until the first output token and decode covers the rest. A gateway that does not report stage timing shows whole-response output speed instead, which includes waiting and prompt processing. Token totals include only completed responses whose workers reported usage. Missing measurements display a dash; a reported zero stays zero.

Process values are the physical footprint macOS reports, as Activity Monitor's Memory column does. Shared pages count in more than one process, so the values do not add up to system memory use. Provider-reported model allocation and source estimates are separate measurements. External providers without request metrics retain status and source visibility. Monitor uses the existing inventory refresh and never starts inference.

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

The **Inference** section offers **Thinking** (off) for MLX-LM and Splash models
whose chat template supports it, and a default output length for MLX-LM and Strata. Output
length ranges from 256 to 65536 tokens; the engine default is 8,192. On
load-on-request chat endpoints it also sets a default system prompt (up to 8,192
UTF-8 bytes), temperature (0 to 2) and top-p (0 to 1), used only when a client omits
them. Client requests can supply their own limits. Thinking off can trade
deliberation for shorter responses. **Experimental** holds M5 prefill, prompt
lookup, the vision cache and the shared prefix cache (16 to 2048 MiB). The same
bounds validate the settings, so each caption states the range the preview accepts.

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

Choose **Configure clients…** on a running endpoint to open the app setup in its
**Server** section. Clients rechecks its process and adapter identity; a changed or
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
Choose **Load on request** to start the gateway before loading the adapter.
**Require API key** also enables load on request. Review the paths and port,
then choose **Confirm and run adapter**.

Changed or missing artifacts require a fresh preview. Run refuses an occupied
port or a second server for the same training artifacts. The running server's
adapter label also appears in Activity, Clients and the memory header; use the
existing server controls to stop it. **Use Library model** returns to the regular
Run controls without stopping servers.

Trained adapters use explicit MLX-LM serving. They do not inherit the base
model's quality verdict. After the preview, **Save as endpoint…** then
**Save unverified endpoint** adds an always-on endpoint for that pinned base,
adapter, load mode and authentication settings. Historical training receipts without a pinned base identity cannot
be previewed or saved. A later update of the base model does not retarget this
endpoint.

## Serve models to other apps

To serve a model for a role, choose **Choose model…** on that role's row in the endpoint list. To serve one on a port you pick, choose **Add custom endpoint…**; this is the only place a new endpoint gets a port you choose. An endpoint's port can also be changed afterward in **API & security**.
Select a ready model, then choose **Save as endpoint** in **Serve a model** (**Start now** starts one server instead).
Set the port and **Load on request**, and, with load on request, whether weights are
released after each request or kept loaded. Choose **Add endpoint…** (**Add unverified endpoint…** for a
model that has not passed verification) and review the model, port, verification and memory warnings, then
confirm. Up to sixteen endpoints can be saved, each on its own stable port between 1024 and 65535
that no endpoint or server already uses, supporting simultaneous co-resident chat, vision, audio, video/media and embedding servers.

Each endpoint row shows its state and base URL. Chat endpoints use the OpenAI-compatible API; typed endpoints advertise their operations at `/v1/models` and accept jobs at `/v1/tasks`. Use **Copy base URL**
and, when a matching running server reports it, **Copy model ID** in the other
application's matching provider settings. The toolbar popover and the menu bar list the same
rows with status and copy controls. **Start…** reviews fit and verification before starting; **Stop** stops its endpoint.

**Remove…** in a row's overflow menu removes an endpoint and stops it after confirmation.
The model files stay in Library. Work using that model must finish before its
endpoint can stop. **Change model…** on an assigned role swaps its model on the same port. The overflow menu also holds load mode, memory management, inference settings,
API key and **Show in Library** actions, and **Wire roles…** and login startup sit below the list. Acceleration remains opt-in; serving a
model does not establish that one configuration is fastest for every workload.

## Always-on endpoints

Saved endpoints in **Served models** keep chosen models serving on stable ports. The app reconciles each endpoint's desired state against the engine's serving status and restarts a crashed endpoint, with a crash-loop guard per endpoint.
Starting one endpoint checks that endpoint immediately. The background supervisor handles repairs for the rest of the fleet.

- **Choose model…** on a role row uses that role's canonical port; **Add custom endpoint…** suggests the next free port. Up to sixteen endpoints.
- Endpoints require a verified model unless you explicitly override for an unverified one.
- Each endpoint row shows status, restarts, a fit chip, **Stop** or **Start…**, and an overflow menu with the remaining controls.
- **Load** displays a live **Fleet co-residency budget** bar combining per-modality estimates (LLM, Vision, Audio, Video, Image, Embedding), load-on-request dormant state, Splash memory caps and any configured shared agent memory limit. When one or more models lack size data, the bar surfaces the partial known total alongside the unknown slot count without fabricating sizes.
- **Model router…** (**Wire roles…**) writes routes for running chat, vision and embedding endpoints that serve a `publisher/model` ID. Routes follow each endpoint's role; an endpoint's advertised `task_kinds` decide the route only for endpoints without a role. Workbench lists local endpoints with basename-only IDs and typed audio or media endpoints separately from the generated config. A route can use the Workbench API when the listener advertises the model and the endpoint shares its key. The generated `fleet-router.yaml` uses `MLX_AGENT_LOCAL_API_KEY` for protected routes, so a config can include only endpoints that use the same API key.

The menu bar item aggregates endpoints ("N of M endpoints running") and provides a submenu for each selected model. An optional login item installs one `RunAtLoad` agent per enabled endpoint, `ai.cavi.mlxworkbench.endpoint.<slot id>`, and each runs `mlx-agent serve start` once at login. The preview lists every command before confirmation. Each captured command preserves that endpoint's local path, runtime selection, inference settings, load-on-request policy and receipt storage, using the preview’s Python environment. Changed or disabled endpoint settings prevent that endpoint's login startup; a change to any included endpoint requires a fresh preview. Remove and reinstall the login item after changing endpoint settings. Installing is refused when the enabled fleet will not fit, until you choose **Install anyway**, the same override as enabling an endpoint. It has no KeepAlive: the app's supervisor reconciles while it runs, and engine receipts remain the process authority. An older single-agent plist, `ai.cavi.mlxworkbench.endpoint`, is removed when you install or remove the login item.

If login-item installation fails partway through, Workbench rolls back the
changes and reports any part of the previous setup it could not restore.

### Model defaults

Endpoints created by role assignment, swap, Use chat setup or **Add custom endpoint** follow
the model's serving defaults for every field they do not set themselves. The Serving
inspector marks each inference field **Model default** or **This endpoint**; **Reset** returns
an overridden field to the default. **Save as model default** writes the endpoint's current
values. Before a changed default is saved, the preview lists the endpoints that follow it and
the running ones that restart on confirm, shown by port. Confirm rechecks
the endpoints, refuses while work holds the model or requests are active, stops each endpoint
through the idle-checked stop, saves the defaults, and reports any endpoint that did not
restart. A default that makes an endpoint's settings illegal is refused at the preview. **Reset**
on a field previews and confirms like other inference changes, with the endpoint stopped.
Changing a field on an endpoint (load mode, memory policy, Splash preset, inference) makes
it that endpoint's own value.
Splash draft and template paths also follow model defaults unless the endpoint overrides them.
Changing those defaults reviews the resulting launch plans for affected Splash preset endpoints.
Endpoints saved by earlier releases keep all of their own values.

### Serving inspector layout, presets and profiles

In a wide window the inspector has two columns: **Status**, **Load**, **Server** and **Tasks**
(up to 640 pt), with **Inference**, **Experimental** and **Presets** beside them. Narrower
windows use one column with **Presets** after **Status**. Numeric fields and pickers size to
their content; the system prompt takes the column width.

**Presets** lists only the settings of the chosen preset that differ from the model default,
each with its value and a source badge (**This endpoint**, **Model default** or **Profile**).
The picker switches between the endpoint, the model default and saved profiles. **Show JSON…**
opens the chosen preset as sorted-key JSON with **Copy JSON**. The JSON contains no API key or
key digest; protection appears as `"protected" : true`.

A profile is a named settings set saved per model: inference settings, memory policy, load
on request, Splash preset and serving profile id.

- **Save as profile…** stores the endpoint's effective settings under a name (unique per model, up to 60 characters).
- **Apply…** writes the selected profile's values into the endpoint. Fields that equal the model default keep following it. The preview lists a running endpoint that restarts; confirm rechecks the endpoint, refuses while work holds the model or requests are active, stops it through the idle-checked stop, saves, restarts it and reports an endpoint that did not come back.
- **Make model default…** (with a profile selected) previews and confirms that profile as the model default. For the endpoint's own values use **Save as model default**.
- **Rename…** edits the selected profile. **Remove…** asks for confirmation naming the profile before deleting it. Neither restarts an endpoint.

The menu bar lists each endpoint as one line (state dot, model, port) with an actions menu
(the ⋯ button) holding the same actions as before.

### Inference settings for saved endpoints

Open an endpoint's actions menu and choose **Inference settings…** to jump to its
**Inference** section. Stop the endpoint before changing settings, then **Preview settings** and
**Confirm and save**. Enable it again to use the saved configuration. Existing
endpoints retain runtime defaults until changed. Changing the model clears its
inference settings; Strata decoding stays in its verified profile.

The settings apply to eager servers, load-on-request workers, automatic restarts
and each enabled endpoint's generated login command. Reinstall an existing login
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

Each load-on-request endpoint has compact controls in **Load**. **Residency** is one choice: **Release weights after each request**, **Keep loaded**, or **Unload after idle** with its duration.

| Control | Default for new endpoints |
|---|---|
| Residency | Unload after 10 minutes idle |
| Keep loaded | Off; when chosen, the model is not unloaded automatically, but manual Unload still works |
| Memory check reserve | 2 GB |

The engine owns the idle timer, so idle unload works for requests from any client, with or without the app open. Idle time starts when the last request ends. Policy changes apply to the running gateway without a restart.

Before a cold load, the engine checks fresh system headroom against local weight bytes × 1.10 + 1.5 GB runtime allowance + the reserve, in decimal GB. Unknown headroom or weight size blocks the load and the reason stays visible. This is an estimate at load time, not a reservation: other processes, other endpoints and growing contexts change memory use afterwards.

## The memory header

The toolbar's memory header shows estimated RAM use and headroom on every screen, refreshed every five seconds while a window is visible and every minute while none is. Serving status comes from one engine discovery per ten seconds (per minute while no window is visible) shared by the header, Serving, Monitor and endpoint supervision. Its label counts the models Monitor lists (for example `1 loaded · 2 on request · 12.0 GB free`), flags an endpoint that is starting or degraded, and shortens to fit the toolbar: headroom alone, then a bare figure. A model whose load failed adds a red `A model failed to load` badge. The shortest label says `Load failed` and drops the memory figure so it still fits. Open it for the same rows as Serving’s endpoint list, models that need attention first with the engine's reason, with reviewed **Unload model…** and **Stop server…** controls and **Open Serving**. Its context selector feeds model-fit reviews, not server configuration.

Choose **What’s using memory…** from the toolbar popover
for an on-demand snapshot of up to 15 readable processes, sorted by memory.
The table shows process names, PIDs and a capture time; **Refresh** reads again.
It never stops a process. **Open Activity Monitor** opens macOS’s process inspector.

Each value is the process's physical footprint, including GPU buffers it owns.
Shared pages count in more than one process, so the rows
do not add up to system-wide usage and cannot identify which model or client
requested an allocation. Exited or unreadable processes are omitted. Failed
refreshes retain the dated reading with a warning. The serving headroom guard
and model-fit estimate continue to use system memory readings.

**Saved model hosts** shows cached readings from your configured Ollama, LM Studio, ComfyUI and other local connections. Each row shows reported loaded models, any reported model memory, activity and capture times. Unknown residency stays unknown, including ComfyUI checkpoint inventories. These values are not added to system memory estimates.

Opening the panel never refreshes external hosts. The refresh button beside each host reads only that connection; a failed refresh keeps its dated inventory and shows the error. **Open host** selects that exact connection in Library's Hosted models source, where memory actions retain their activity review and confirmation.

## Serving profiles

Saved serving profiles carry runtime settings for one model through verification and the endpoint configuration. They are used by the optional Strata runtime; see [Strata](strata.md).

The selected endpoint shows its configured profile or Splash preset. To change a saved Strata endpoint's profile, stop it, choose **Change serving profile…** beside **Serving profile**, choose a verified profile or runtime defaults, and review the launch settings before saving. This choice overrides the model's default profile for that endpoint. The endpoint stays stopped until you start it.

If disabling or removing an endpoint cannot confirm its server stopped, Run keeps the failure visible. **Retry stopping servers** rechecks the server identity and retries the stop. Automatic starts for that endpoint remain paused until the stop is confirmed.

## Local serving inventory and menu bar

**Served models** shows Workbench endpoints alongside services started by MLX Agent, including Strata, and recognized local Ollama, LM Studio, ComfyUI, llama.cpp and OpenAI-compatible server processes. Discovery reads this user’s listening processes and provider APIs at their actual ports. Engine services are found through registered receipt locations and live engine process arguments. Discovery does not search model folders or add external servers to automatic restart supervision. An older engine reports that cross-location engine discovery needs an update.

**Serving Doctor** is available from Serving, the menu bar and a blocked Library removal. **Recheck connections** reads serving and source status without stopping services or retrying removal. Independently identified offline discoveries and authenticated local mirrors matched to a running engine process do not count as connection issues. Remaining source errors and reported endpoint failures are shown with links to the relevant endpoint, Model Sources or Health; choose and review any action yourself. Saved sources are separate from running services.

Rows distinguish loaded, unloaded, loading, failed and unknown residency. The same service reported through its engine receipt and listening process appears once. Failed sources retain dated observations and an error. Paths, runtime, active requests and process identity appear when available. Provider APIs may omit storage locations or residency.
Background discovery checks less often when a successful scan finds no active local servers. Opening Serving, Monitor, Model sources or the menu bar panel refreshes discovery immediately.

System headroom, observed process RAM, shared host process RAM, provider-reported model memory and source estimates are shown separately. They are not added into a model-memory total: shared pages, host processes and GPU allocations overlap. A load-on-request worker that reports MLX allocator memory shows its memory in use, cache and peak in the row details. **Unload model…** and **Stop server…** review the selected process, recheck ownership before acting and read status afterwards. **Release cache…** in **Disk space → Models** uses the same review for an idle task worker whose runtime exposes cache control, and keeps the model loaded. Provider unload uses that provider’s model, instance or whole-host scope; unsupported actions are unavailable.

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
later in the endpoint's **Residency** control in **Load**. Manual Unload keeps the
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

Protected endpoints share one Workbench key. When saving a model as an endpoint in **Serve a model**, turn on **Require API key**; an existing endpoint's overflow menu offers **Protect with Workbench key…** and **Disable authentication…** while it is stopped. The
endpoint stays on loopback and loads weights on request. Use **Copy base URL**,
**Copy model ID** and **Copy API key** to configure each authorized client;
clients read the key from `MLX_AGENT_API_KEY`.

The **Workbench key wizard** (the key button in the Serving list header, **Workbench key…** on the Workbench API row, or the endpoint bar's key lock and
**Protect with Workbench key…** while no key exists) has three steps and opens at the first one that still has work.
**Create key** makes the key once, or shows an existing one as `…` and its last four digest characters.
**Protect endpoints** lists every fleet endpoint not on the key, including endpoints with their own key, all checked
by default. **Review restart…** shows which running endpoints stop and restart, in ascending port order; **Protect
endpoints** then stops each only when it is idle and not in use, saves the fleet, restarts them and confirms each runs
on the Workbench key. If any stop is refused nothing is saved. Previous own keys leave Keychain once nothing uses them.
**Connect apps** names `MLX_AGENT_API_KEY`, offers **Copy key**, an export template without the key, and
**Set up an app…**, which opens Connect app.
The Workbench key is generated securely once, saved in Keychain and shared with
the Workbench API. Endpoint settings, launch arguments and exports contain only
a verification digest. Protecting an endpoint never creates another key.

For a saved endpoint, stop it first, then choose **Protect with Workbench key…**.
Review and save the change, then start the endpoint. Authentication changes
leave the endpoint stopped. **Disable authentication…** explicitly restores
access for local clients without a key. An endpoint saved with its own key keeps
working with it; its **Server** section offers **Use Workbench key…** to move it
onto the Workbench key through the same review.

**Reset Workbench key…** lists every protected endpoint and the Workbench API.
Confirming refuses, changing nothing, when a running endpoint is in use by another
operation or has active requests. Otherwise it stops the running endpoints, saves
the new key, restarts the endpoints by ascending port and then the Workbench API,
and removes the previous key from Keychain only after every restart succeeded. If
a stop fails, nothing is saved and stopped endpoints restart on the previous key.
If a restart fails, the previous key stays in Keychain and the failed ports are
reported. Reviews never save a key; a new Workbench key is saved when the change
that uses it is confirmed.

Protected endpoints require `Authorization: Bearer KEY` or `x-api-key: KEY`
for model discovery, inference, task history, cancellation and artifacts.
Requests without a valid key receive HTTP 401 before inference. Internal
workers require separate credentials over Unix sockets or loopback ports. Workbench's **Try a prompt**
uses the endpoint key from Keychain. Automatic client wiring skips protected endpoints; role routing includes protected endpoints via the Workbench API or environment-variable references without writing raw API keys.

Any client holding the key is authorized. Keep it private and reset it if it
has been shared unintentionally. Loopback limits access to this machine; API
keys do not create an executable allowlist. Authentication is optional, and
existing endpoints keep their current access mode.

## Menu-bar access

The **CPU** icon identifies MLX Workbench in the macOS menu bar. Use
**Settings → Serving → Show in macOS menu bar** to show it again if removed.
Open it for the Workbench API address, one row per assigned role
(model, port, loaded or unloaded, Copy base URL, Copy model ID, reviewed
Unload or Stop), the Tailscale share, Monitor, Settings and Quit. The header
counts Workbench endpoints only, such as "2 of 3 endpoints running". Servers
outside the fleet and endpoints without a role appear under a collapsed
**Other servers (N)** group. Available-but-unloaded external
models are omitted from this quick menu. Closing the main window keeps
Workbench and its model servers running. Use **Open MLX Workbench** to return
to the window. Login-item controls remain under Memory for startup persistence.

Roles are chosen on the Serving page: each role row names its endpoint, and the menu bar lists the assigned roles. There are no separate Coding or Utility defaults; OpenCode setup uses the Coding role's endpoint. Open an assigned role's endpoint to review its memory settings. Coding can use an idle timeout, while Utility can release weights after each request, including with a Splash preset. For Splash, Serving shows reported effective context separately from a configured limit. If a Splash load fails, review its saved launch preset before applying changes.
