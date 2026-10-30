# Add from Hugging Face

The **Add from Hugging Face** window resolves a Hugging Face Hub repository before anything downloads. Open it three ways:

- ⇧⌘V anywhere with a model link on the clipboard
- ⌘V on the Library table or the Prepare view
- Paste into the field in Prepare, or choose **Add from Hugging Face…** in Discover or Adopt

## Verdicts

| Verdict | What happens |
|---|---|
| Convertible | Download, then the usual Prepare preview and confirmation |
| Convertible after install | One click installs the backend (mlx-vlm or mlx-audio) into its own environment first |
| Already MLX | Install its declared backend if needed, then download into the output directory |
| GGUF repository | Pick a quant file; it downloads into your first GGUF root and opens in Prepare |
| No MLX converter | Shows which parts already exist in MLX and which are missing; a locally served model can draft a porting plan |
| Blocked or Hub unreachable | Gated, private or offline; nothing is downloaded |

The window shows the verdict once, with key figures: estimated output size from the repository's headers, fit on this Mac for that output or for the selected GGUF file, and an **In Library** mark when a matching model is already on disk. Model type and use cases come from the engine's task labels. When intake allows only some quantization widths, Prepare offers only those.

Before fetching, intake checks your current ready models and matching conversion history, so a model you already have is not downloaded again. When the Hugging Face cache already holds every file the download would fetch, the verdict says it is already downloaded and the download size reads **Already cached**.

## Downloads and conversion

A download is its own confirmed step, separate from conversion. Downloaded directories are passed to the converter as a local source, and converter workers run offline.

Prefer original floating-point weights when a repository offers them. Conversion cannot recover precision removed by an earlier quantization.

Some repositories need more than a plain conversion:

- **Subfolders.** Checkpoints below the repository root, such as Laya's `multilingual` folder, resolve as `org/name/folder`.
- **Backend ports.** Architectures the pinned backends lack can ship as MLX Agent ports; their links resolve as convertible and the port runs its own converter. Edge0/Audio8-ASR-Infinite (streaming English and Chinese speech recognition) converts through mlx-audio this way.
- **Diffusers pipelines.** Image-generation repositories resolve through their `model_index.json` pipeline class.
- **Recipes.** Curated recipe repositories resolve through their pinned base plus a LoRA; the window shows **Built from**.
- **Qwen3.5 GGUFs.** Qwen3.5-family GGUFs, including Qwen3.6 and Qwen3.8 checkpoints, convert through an MLX Agent port. When the GGUF's folder holds exactly one matching Qwen3-VL projector (`mmproj`), the plan names it and the output is the vision-language model.
- **Drafters.** A DeepSeek-V4 DSpark `dflash` GGUF converts through its port. Other speculative-decoding drafters, including GGUFs that hold only a multi-token-prediction block, are refused at plan time.

GGUF projector and companion files are never converted on their own.

## Runtime selection

Run, verification, chat comparisons and endpoints read the local model's architecture and select its serving backend automatically (`--runtime auto`). Optional backends run from their isolated environments, including models already published in MLX format. Prism's published 2-bit packs use the pinned MLX-VLM adapter; their weights stay in the published format.

Unsupported loaders are refused. Repository runtime code is never executed, and intake never passes `--trust-remote-code`.
