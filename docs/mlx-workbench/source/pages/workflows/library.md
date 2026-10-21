# Library and Overview

## Overview

**Overview** is the landing screen. It leads with a **Model budget** instrument for this Mac, offers one **Next step** action and shows the **Flight path** of the model chosen in Library: how far it has come from source to ready. **Watch alerts** appear here; see [Health and alerts](health.md).

## Library

**Library** lists the GGUF and MLX models under your configured roots. The output directory is scanned as an MLX root unless another root already reaches it. Families with multiple variants expand to show their models; single variants appear directly in the table.

The **Source** menu offers **All local models** and each saved model host, including Ollama, LM Studio and ComfyUI. Host choices use their saved identity and show their provider; connections with matching names and providers include their address to distinguish them. Adding, editing or removing a saved connection updates the menu. **Hosted models** opens host selection and connection setup. The separate **Local files** group contains **LM Studio files**.

Switching sources preserves the main table's filters and selected model without refreshing a host, changing configuration or starting conversion or serving. Selecting a host shows that exact connection. If it is removed, Library returns to hosted selection rather than displaying another host.

**Show in Library** on a source model opens **All local models**, clears search and readiness/quantization filters, and selects the model in the inspector. This explicit reveal leaves column and grouping preferences intact.

| Column | Meaning |
|---|---|
| Quantization | Declared bits or quant type |
| Size | Bytes on disk, with a relative size bar |
| Memory fit | **Fits**, **Tight** or **Won't fit** at the selected context, against current available memory |
| Status | For ready models, the canary verdict for the current files: **Verified**, **Failed checks**, **Verify again** after the files changed, **Verifying…**, or **Ready** when never verified. Otherwise the readiness, such as **Needs Conversion** or **Needs Runtime** when the backend that runs the model (mlx-audio, mlx-vlm, …) is not installed |
| Modified | Newest file change on disk, including MLX folders and Hugging Face cache snapshots |

Columns collapse as the window narrows. Filters narrow the list by quantization and readiness. **Refresh** rescans; a failed scan offers **Retry scan**.

When a scan finds no models, **Add from Hugging Face…** opens intake for review,
**Open Settings** lets you choose model folders, and **Scan again** refreshes the inventory.
Opening intake does not download a model. If search or filters hide existing models,
**Clear search** and **Clear filters** reveal them without adding another model.

### Model details

In wide windows, the first selected model opens the inspector beside the table.
In compact windows, selecting a model opens its details in a sheet. Use
**Inspector** in the toolbar or ⌥⌘I to hide or show details. Actions and the current memory fit come first;
expand **Model details** for paths, runtime and other technical facts,
including a speculative-decoding drafter's target. The inspector also holds:

- **Repair runtime…**, for models whose declared backend is missing: review and explicitly confirm its installation in Health, then **Return to model** to refresh readiness and reveal the same model. No model download or execution starts from this navigation.

- **Model lineage**: a provenance timeline of source, converted, verified, benchmarked, served, wired and quarantined events, built from the records the app already keeps. Events whose model signature no longer matches are dimmed. Export it as Markdown or JSON.
- **Measured performance**: throughput and first-token latency aggregated from past comparisons.
- **Generate image**, for ready image-generation models: prompt, optional width, height, steps and seed. Completed output is retained with its task and can be inspected or exported as a verified PNG.
- **Understand image**, for ready vision-language models: choose a local image and ask a question. The engine retains a verified input copy with the task; the result shows the full answer and input image.
- **Classify**, for ready classification models: a state description and questions with choice, score or probability answers.
- **Generate music**, for ready music models: caption, optional lyrics, duration, steps and seed, with playback of completed audio.
- **Transcribe audio** and **Speak text**, for ready speech models: transcription from a selected local audio file, or text-to-speech with optional voice, speed and language settings.

Actions: **Run model** opens the existing server preview flow; **Compare**
selects the model for comparison. Models needing conversion offer **Prepare
to run**. **Verify now** runs the canary suite for a ready model; when a run
cannot reach a verdict, the Verification section says why. **Reveal in Finder** and **Copy Path** are in the model's action menu.

**Select for Compare** is available for ready chat, speech, music, image and video models. It opens the matching comparison mode and selects the model without starting a run. Run remains a chat-serving action. Runtime restrictions take precedence over task labels: Strata supports Chat only.

### Local inference tasks

Choose a ready model and fill its task form in the inspector. **Start** submits
one task to the engine and shows its ID and state. Editing inputs does not run
the model. If the engine is busy or its backend is unavailable, the form keeps
your inputs and shows the error.

For **Classify**, describe the **State** and add at least one question with
instructions. Choice questions use two or more ordered labels; score questions
use two or more ordered level descriptions. A probability question (`noul`)
can include descriptions of its false and true outcomes. Results show the
model's returned answers, probabilities and score legend when available.
Missing fields remain unavailable. These are model predictions, without
ground-truth checks or an automatic quality verdict.

For **Generate music**, enter a caption and optional lyrics. Blank lyrics mean
instrumental music. Defaults are 15 seconds, 30 steps and seed 42. The engine
accepts captions up to 2,000 characters, lyrics up to 10,000, duration above
zero through 360 seconds, 1–30 steps and seeds from 0 through 4,294,967,295.
Completed tasks offer WAV playback and recorded generation settings. A valid
audio file does not establish musical quality. Playback stops when you leave
the inspector or select another model or task.

For **Transcribe audio**, choose a local WAV, FLAC or MP3 file and optionally
enter a language code. The engine records a verified copy with the task before
accepting it; later reuse reads that retained copy. Completed results show the
full transcript and the input's recorded digest.

For **Speak text**, enter up to 2,000 characters and optionally set a voice,
speed (0.5–2) or language code. Leave those controls blank to let the engine
apply its defaults. A
completed result exposes a verified WAV for playback and export. Workbench
does not assign an automatic quality score to speech output.

For **Generate image**, enter a prompt of up to 2,000 characters and optionally
set width and height (multiples of 16 from 256 to 2048), steps (1–100) or seed.
Blank settings are left to the engine planner. The completed task
shows the verified PNG and supports PNG export. For **Understand image**, choose
a local image and ask a question of up to 4,000 characters. **Advanced options**
sets max tokens (1–4096), temperature (0–2) and max pixels (up to 100,000,000);
blank values leave these to the engine planner.
The engine records a retained image copy before accepting the
task. The completed view shows that verified image and the full returned
answer. Both task kinds appear in Recent tasks and can reuse their recorded
request when the matching Ready model is available.

For **Generate video**, enter a prompt of up to 2,000 characters and optionally
set width and height (64–1920), frame count (1–241), whole frames per second
(1–60), steps (1–100) or seed. Blank settings are left to the engine planner,
which also checks the model's size alignment and frame grouping. The completed
task offers verified MP4 playback and export. For
**Understand video**, choose a local MP4, MOV or M4V file and ask about its contents. Advanced
options set frames per second (0.1–8), temperature, maximum tokens and maximum
pixels, with the image limits above; blank values leave these to the engine planner. The engine retains a verified
copy of the input with the task, and completed results show that video and the
full returned answer. Video tasks appear in Recent tasks and can reuse their
recorded request when the matching Ready model is available. Video playback
stops when you leave the inspector or select another model or task.

Each form names an out-of-range value and keeps **Run** unavailable until it is
fixed. Compare prompt sets apply the same limits.

**Recent tasks** in the inspector shows the selected model's tasks. The Library
toolbar also opens Recent tasks independently of model selection, so recorded
results remain accessible when their model is no longer in the Library. At
narrow widths, find Recent tasks in the toolbar's overflow menu. The
list contains at most the engine's 100 most recent records. Failed refreshes
label the last known data and offer Retry.

The engine retains accepted inputs, task records and output files; agents
using the same engine store can inspect the same task IDs. Closing Workbench
does not cancel a task. Reopening refreshes its state without starting it
again. **Cancel** requests that the engine stop the identified task; its row
remains active until the engine reports a terminal state. If Start loses its
response, **Start outcome unknown** offers Refresh without automatically
resubmitting the request or guessing its task ID.

**Reuse** verifies the retained request and fills a new draft without changing
the original task or starting another one. It requires the matching model to
be ready and unchanged. Missing or changed request files prevent reuse;
recorded results remain readable. Result and audio files are checked before
display, playback or export. Missing or changed outputs show an error and do
not trigger generation.

**Result JSON** expands the complete recorded payload. **Export result** saves
verified result data and metrics while omitting request, source-path and artifact
references; **Export WAV** saves a separately verified audio output.
Private input content is not included by default. Workbench does not delete
engine task artifacts, and Compare's ten-run media retention does not apply
to these tasks. Use [Compare](compare.md) for matched model runs and listening
ratings.

### Delete a model

**Delete…** moves a model to the Trash after a review that rechecks its identity, its folders and whether it is serving. Trash keeps the disk space until you empty it. For quarantine with restore, use [Reclaim](reclaim.md).

### Task types

The engine labels each model with a task type. The type decides what the app offers.

| Task type | Run and endpoints | Quality gate canary | Compare modes |
|---|---|---|---|
| Text LLM | Yes | Served canary prompts | Chat |
| Vision-language | Yes | Served canary prompts | Chat, Vision, Video understanding |
| Speech-to-text | No | Transcribes a synthesized sentence; passes at 25% word error or less | Speech to text |
| Classification | No | Routes a billing ticket to billing as a refund request | None |
| Image generation | No | Renders a fixed prompt at 512×512 and checks the image is not blank | Image generation |
| Text-to-speech | No | None | Text to speech |
| Music generation | No | None | Music generation |
| Video generation | No | None | Video generation |
| Embedding, other | No | None | None |
| Speculative drafter | Never | None | None |

Drafters such as llama.cpp `dflash` or `eagle3` GGUFs borrow their target's embeddings and output head, so they are never served on their own.

## LM Studio files

Choose **LM Studio files** in the Source menu's **Local files** group to list models in LM Studio's downloads folder from the last Library scan; it does not scan on its own. This filesystem shelf is separate from a saved LM Studio server connection. The folder comes from `downloadsFolder` in `~/.lmstudio/settings.json`. The view states, per format, whether the last scan reaches that folder. Existing saved LM Studio navigation opens this shelf inside Library.

Two lanes are ranked by fit:

- **MLX**: models that run as they are; **Run…** opens Run.
- **GGUF**: files that need converting; **Prepare…** opens Prepare, or **Run…** when a converted output already exists. Split GGUF files are summed; vision projector files appear as tags.

The fit summary shows **fit unknown** until the MLX models have fit estimates. A partial set of estimates is labeled **known to fit**; a complete set uses **fit now**. Zero is shown only as the known count, never as a substitute for unavailable estimates.

The screen never writes configuration. When the scan does not reach the folder, add it to your roots in Settings.

## Hosted models

Choose **Library → Source → Hosted models**, then **Add host…**. Presets cover Ollama, LM Studio, ComfyUI and llama.cpp; **OpenAI-compatible** accepts other local servers exposing a model-list API. Enter the server's HTTP or HTTPS loopback address, including its port. A trailing `/v1` is accepted. Remote addresses are not supported. Optional API tokens are stored in macOS Keychain, separately from the saved connection.

The editor shows invalid names or addresses before Save. **Test connection** is
optional: it reads the selected provider's model inventory using the entered
replacement token, or the saved token when replacement is off. Authentication
and missing-API errors offer guidance without showing server response bodies.
A successful check shows the reported model count and check time; it does not
test generation or establish that a model is ready to run. Editing any connection
field or token clears the result. **Cancel check** stops waiting for a result.
Testing never saves the host, changes Keychain, loads a model or publishes the
inventory to Library. **Save host** remains the explicit persistence action;
you can save a valid connection without testing it, then use **Refresh** later.

**Refresh** reads inventory without loading models, generating outputs, downloading weights or changing the host's configuration. Refresh is manual. A failed refresh retains the previous inventory with its capture time and an error. Editing an address or provider clears that connection's cached inventory. Removing a connection leaves the host and its models untouched.

Failed refreshes distinguish authentication, missing API and connection errors.
**Retry refresh** rereads only the inventory. **Edit connection…** opens the saved
provider, address and token controls; Cancel preserves the connection and error.
When no prior inventory exists, the error says so. Retained inventory is dated
evidence and does not establish the host's current state. A successful refresh
replaces it and clears the error. Recovery actions never start generation.

The table shows model identifiers, available or loaded state, parameter size, quantization and file size where reported. Select a row and expand **Reported model details** for context, memory, capabilities and digest. Missing metadata is **Unknown**. Reported model memory is separate from whole-device memory; model context limits are separate from loaded context.

- Ollama lists installed tags separately from **Reported running models**. Expand that disclosure for each running model's digest, host-reported memory and loaded context, including weights absent from the installed tags or with a different digest. Warnings identify these differences. Running allocation size is not disk size. Maximum context and capabilities require an explicit model-details read.
- LM Studio uses its native inventory API, with compatibility fallbacks for older servers. Multiple loaded instances with different contexts have an unknown loaded context.
- ComfyUI lists model files by category, plus reported device and version information. File availability does not establish whether a model is loaded. Unsupported categories can produce a partial inventory with a warning.
- llama.cpp and compatible servers expose their advertised models. Additional metadata is shown only when reported; names never establish capabilities or identical weights.

For ComfyUI, expand **Reported device memory** in the host inventory or the Memory panel's **Saved model hosts** section. Refresh reads each device's reported free and total bytes with a separate capture time. Missing or invalid values are **Unknown**; a reported zero free-memory value remains zero, and an empty device list says **No devices reported**. Opening the disclosure uses cached readings without contacting the host.

MPS and CPU readings describe shared system memory and overlap system headroom. Other device types retain their host-reported readings. Devices are never added together; these values do not measure per-model allocation or memory released by cleanup. A reading describes its capture time, independently of inventory and queue activity.

For an installed Ollama tag, select its row, expand **Reported model details**, then choose **Read model details**. This reads the selected tag's reported capabilities and its architecture's maximum context, with a separate read time. Loaded context remains the current running allocation. Missing fields are **Unknown**; an explicitly empty capability list is **None reported**. The action requires a reported digest and checks that the installed digest matches before and after the metadata read. These are dated host observations, not an atomic runtime snapshot.

The read refreshes inventory and publishes the selected model's details only after the final identity check. Failed reads retain the previous dated inventory. Ordinary **Refresh** replaces inspected metadata with the basic inventory; read details again when needed. Selection and disclosure expansion perform no metadata requests. Reading details does not generate, load, unload or download models.

**Compare…** sends the selected model to the **Hosted & mixed** comparison setup without starting a run. Text models can be compared with ready native models. ComfyUI image comparisons require checkpoint models and an explicitly imported API workflow. Host inventories remain separate from local scan, conversion, verification and reclaim state.

### Release host memory

The toolbar memory panel also lists saved hosts and their dated residency and activity readings. **Open host** selects the corresponding connection here; the refresh button beside each host reads only that host without loading or unloading models.

Ollama's memory summary includes its complete reported running list, even when installed tags differ. A successful empty running list reports zero; a failed or malformed list leaves residency unknown. Running-only weights do not become comparison candidates or unload targets. Use Ollama to manage weights absent from or different from the installed tags. Workbench unload still requires a loaded installed tag with the same digest.

Select a model reported as loaded, then **Unload model…** for Ollama or **Unload instance…** for LM Studio. LM Studio requires its native loaded-instance identities; when several instances are loaded, choose the exact instance first. Legacy inventory without those identities cannot authorize unloading. ComfyUI offers **Free host memory…**, which requests cleanup of all cached models on that host, independently of the selected checkpoint. llama.cpp and generic OpenAI-compatible connections do not offer a supported unload action.

The review shows the target, host address, activity and check time. ComfyUI reports running and queued jobs. Ollama and LM Studio remain **Activity unknown** because their public inventory APIs do not report other clients' active requests. Missing or failed activity checks never imply idle. Busy, queued and unknown activity carry a warning; **Cancel** or Escape sends no memory-release request.

Explicit confirmation checks the target and activity again. Changed activity or model details require renewed confirmation. Activity is a snapshot; another client can start work after any check. Workbench blocks memory operations during its active comparisons and blocks host edits while an operation is in flight.

The action uses the host's memory-management API. It never deletes model files, quits the application, clears queues or interrupts shared jobs. ComfyUI cleanup may be deferred until work finishes, and later jobs can reload models. Ollama and LM Studio unload requests may affect other clients using the selected model or instance.

Workbench refreshes inventory after a request and distinguishes acceptance from observed unloaded state. ComfyUI does not expose cleanup completion, so acceptance does not establish released memory. Failed readback retains the dated inventory and reports that the effect could not be verified. A connection failure after submission can leave the outcome unknown; requests are never automatically retried.
