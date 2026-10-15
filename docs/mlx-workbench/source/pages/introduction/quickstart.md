# Your first model

This walkthrough takes one model from Hugging Face Hub to a verified loopback endpoint that your coding tools use. It assumes [Installation](installation.md) is done.

## 1. Check Settings

Open **Settings** and confirm:

- **Engine → mlx-agent checkout** points at a checkout containing `scripts/mlx-agent`, and the engine status is ready. If the runtime needs setup, **Open Health** shows the fix.
- **Model locations** lists your GGUF roots and MLX roots. With none configured, the app discovers common folders such as the Hugging Face cache, `~/.lmstudio/models` and LM Studio's configured downloads folder.
- **Storage** sets the output directory for converted models and the quarantine directory.

## 2. Look at what you have

**Library** lists every model under your roots with its quantization, size, readiness and whether it fits in memory now (**Fits**, **Tight** or **Won't fit**). Select a model for its details and lineage. If a model you want is already here, skip to step 4.

## 3. Add a model from Hugging Face

Press ⇧⌘V with a Hugging Face model link on the clipboard, or paste it into Prepare. The intake window shows a verdict before anything downloads:

- **Convertible**: download, then convert in Prepare.
- **Convertible after install**: install the needed backend with one click first.
- **Already MLX**: download straight into your output directory.
- **GGUF repository**: pick one quant file to download.

The window also shows the estimated output size, whether it fits on this Mac and whether the model is already in your Library. Confirm the download. See [Add from Hugging Face](../workflows/hugging-face.md) for every verdict.

## 4. Convert and verify

In **Prepare**, choose the quantization width. Each tile shows the output size and fit. **Preview conversion** shows the exact command, destination and preview hash. **Confirm conversion** starts the job; a progress ring tracks bytes written and the job log is one click away. **Activity** shows the same job on its timeline.

When the output appears, the conversion quality gate runs. Chat models are served on a temporary loopback port and answer canary prompts; speech, classification and image models run their own canary. A model that passes is marked **verified**. A notification announces the result.

## 5. Serve it

Open **Run** and select the verified model. The memory runway shows what is loaded, what this model needs and whether it fits at the chosen context. **Preview serve**, then **Confirm and run**. The endpoint speaks the OpenAI chat API on `127.0.0.1`.

To keep it serving across app restarts, add it as an always-on endpoint in Run's **Endpoints** section. New endpoints load on request: the port stays open and the model loads on the first inference request. See [Run and endpoints](../workflows/run.md).

## 6. Wire a client

Open **Clients**, choose the running server, pick opencode, Continue, Zed or Aider, and **Preview client wiring**. The preview shows the exact config change. **Confirm client wiring** writes it with a backup; **Roll back last wiring** restores the previous file. See [Clients](../workflows/clients.md).

## Next

- [Compare](../workflows/compare.md) the model against another quantization on your own prompts before settling on it.
- [Reclaim](../workflows/reclaim.md) the source weights once the converted model is verified.
- Quit through the app menu. Endpoints keep their own Stop and Unload controls in Run and the menu bar.
