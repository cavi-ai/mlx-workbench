# Library and Overview

## Overview

**Overview** is the landing screen. It leads with a **Model budget** instrument for this Mac, offers one **Next step** action and shows the **Flight path** of the model chosen in Library: how far it has come from source to ready. **Watch alerts** appear here; see [Health and alerts](health.md).

## Library

**Library** lists the GGUF and MLX models under your configured roots. The output directory is scanned as an MLX root unless another root already reaches it. Families with multiple variants expand to show their models; single variants appear directly in the table.

The **Source** picker switches between **All models** and **LM Studio**. Switching sources preserves the main table's filters and selected model, without changing configuration or starting conversion or serving.

**Show in Library** on a source model opens **All models**, clears search and readiness/quantization filters, and selects the model in the inspector. This explicit reveal leaves column and grouping preferences intact.

| Column | Meaning |
|---|---|
| Quantization | Declared bits or quant type |
| Size | Bytes on disk, with a relative size bar |
| Memory fit | **Fits**, **Tight** or **Won't fit** at the selected context, against current available memory |
| Status | Shown for models that are not ready |
| Modified | Last change on disk |

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

- **Model lineage**: a provenance timeline of source, converted, verified, benchmarked, served, wired and quarantined events, built from the records the app already keeps. Events whose model signature no longer matches are dimmed. Export it as Markdown or JSON.
- **Measured performance**: throughput and first-token latency aggregated from past comparisons.
- **Generate**, for image-generation models: prompt, size, steps and seed. Each run writes a new PNG to `~/Pictures/MLX Workbench`.
- **Classify**, for ready classification models: a state description and questions with choice, score or probability answers.
- **Generate music**, for ready music models: caption, optional lyrics, duration, steps and seed, with playback of completed audio.
- **Transcribe audio** and **Speak text**, for ready speech models: transcription from a selected local audio file, or text-to-speech with optional voice, speed and language settings.

During rendering, **Cancel generation** stops that model's owned worker. The panel stays busy until the worker returns, and another model's panel cannot cancel it. Cancellation keeps any files already written and does not publish a late image as a completed result. After cleanup, Generate accepts a new request with a distinct output filename, including retries within the same second.

Actions: **Run model** opens the existing server preview flow; **Compare**
selects the model for comparison. Models needing conversion offer **Prepare
to run**. **Reveal in Finder** and **Copy Path** are in the model's action menu.

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

For **Speak text**, enter text and optionally set a voice, speed or language
code. Leave those controls blank to let the engine apply its defaults. A
completed result exposes a verified WAV for playback and export. Workbench
does not assign an automatic quality score to speech output.

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

## LM Studio source

Choose **Library → Source → LM Studio** to list models in LM Studio's downloads folder from the last Library scan; it does not scan on its own. The folder comes from `downloadsFolder` in `~/.lmstudio/settings.json`. The view states, per format, whether the last scan reaches that folder. Existing saved LM Studio navigation opens this source inside Library.

Two lanes are ranked by fit:

- **MLX**: models that run as they are; **Run…** opens Run.
- **GGUF**: files that need converting; **Prepare…** opens Prepare, or **Run…** when a converted output already exists. Split GGUF files are summed; vision projector files appear as tags.

The fit summary shows **fit unknown** until the MLX models have fit estimates. A partial set of estimates is labeled **known to fit**; a complete set uses **fit now**. Zero is shown only as the known count, never as a substitute for unavailable estimates.

The screen never writes configuration. When the scan does not reach the folder, add it to your roots in Settings.
