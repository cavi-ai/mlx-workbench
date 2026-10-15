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
| Fits now | **Fits**, **Tight** or **Won't fit** at the selected context, against current available memory |
| Status | Shown for models that are not ready |
| Modified | Last change on disk |

Columns collapse as the window narrows. Filters narrow the list by quantization and readiness. **Refresh** rescans; a failed scan offers **Retry scan**.

### Model details

In wide windows, the first selected model opens the inspector beside the table.
In compact windows, selecting a model opens its details in a sheet. Use
**Inspector** in the toolbar or ⌥⌘I to hide or show details. Actions and the current memory fit come first;
expand **Model details** for paths, runtime and other technical facts,
including a speculative-decoding drafter's target. The inspector also holds:

- **Model lineage**: a provenance timeline of source, converted, verified, benchmarked, served, wired and quarantined events, built from the records the app already keeps. Events whose model signature no longer matches are dimmed. Export it as Markdown or JSON.
- **Measured performance**: throughput and first-token latency aggregated from past comparisons.
- **Generate**, for image-generation models: prompt, size, steps and seed. Each run writes a new PNG to `~/Pictures/MLX Workbench`.

During rendering, **Cancel generation** stops that model's owned worker. The panel stays busy until the worker returns, and another model's panel cannot cancel it. Cancellation keeps any files already written and does not publish a late image as a completed result. After cleanup, Generate accepts a new request with a distinct output filename, including retries within the same second.

Actions: **Run model** opens the existing server preview flow; **Compare**
selects the model for comparison. Models needing conversion offer **Prepare
to run**. **Reveal in Finder** and **Copy Path** are in the model's action menu.

**Select for Compare** is available for ready chat, speech, music, image and video models. It opens the matching comparison mode and selects the model without starting a run. Run remains a chat-serving action. Runtime restrictions take precedence over task labels: Strata supports Chat only.

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
