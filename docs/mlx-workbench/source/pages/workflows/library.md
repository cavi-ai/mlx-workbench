# Library and Overview

## Overview

**Overview** is the landing screen. It leads with a **Model budget** instrument for this Mac, offers one **Next step** action and shows the **Flight path** of the model chosen in Library: how far it has come from source to ready. **Watch alerts** appear here; see [Health and alerts](health.md).

## Library

**Library** lists the GGUF and MLX models under your configured roots. The output directory is scanned as an MLX root unless another root already reaches it. Models are grouped by family, with a heading and a count per family.

| Column | Meaning |
|---|---|
| Quantization | Declared bits or quant type |
| Size | Bytes on disk, with a relative size bar |
| Fits now | **Fits**, **Tight** or **Won't fit** at the selected context, against current available memory |
| Status | Shown for models that are not ready |
| Modified | Last change on disk |

Columns collapse as the window narrows. Filters narrow the list by quantization and readiness. **Refresh** rescans; a failed scan offers **Retry scan**.

### Model details

Select a model to open the inspector. It shows the model's details and runtime, and for a speculative-decoding drafter, its target model. It also holds:

- **Lineage**: a provenance timeline of source, converted, verified, benchmarked, served, wired and quarantined events, built from the records the app already keeps. Events whose model signature no longer matches are dimmed. Export it as Markdown or JSON.
- **Performance**: throughput and first-token latency aggregated from past comparisons.
- **Generate**, for image-generation models: prompt, size, steps and seed. Each run writes a new PNG to `~/Pictures/MLX Workbench`.

During rendering, **Cancel generation** stops that model's owned worker. The panel stays busy until the worker returns, and another model's panel cannot cancel it. Cancellation keeps any files already written and does not publish a late image as a completed result. After cleanup, Generate accepts a new request with a distinct output filename, including retries within the same second.

Actions: **Select for Run**, **Select for Compare**, **Prepare to run**, **Reveal in Finder**, **Copy Path**.

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

## LM Studio

**LM Studio** lists the models in LM Studio's downloads folder from the last Library scan; it does not scan on its own. The folder comes from `downloadsFolder` in `~/.lmstudio/settings.json`. The screen states, per format, whether the last scan reaches that folder.

Two lanes are ranked by fit:

- **MLX**: models that run as they are; **Run…** opens Run.
- **GGUF**: files that need converting; **Prepare…** opens Prepare, or **Run…** when a converted output already exists. Split GGUF files are summed; vision projector files appear as tags.

The screen never writes configuration. When the scan does not reach the folder, add it to your roots in Settings.
