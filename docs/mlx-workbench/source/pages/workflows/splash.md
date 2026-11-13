# Splash

Splash is an optional text runtime that serves quantized MLX, GGUF and prepared Strata profile weights in place, decoding with a DFlash2 draft. Workbench runs it through MLX Agent's loopback serving, preview, receipt and stop operations. Models keep their own runtime unless you choose Splash.

## Install

Splash needs an Apple M3 or newer and macOS 26.4 or later. Install it with Homebrew:

```bash
brew install incoai/tap/splash
```

The engine finds `splash` through `MLX_AGENT_SPLASH`, `PATH`, Homebrew and `~/.local/bin`, and requires version 1.4.0 or later. Workbench never installs Splash or downloads weights.

Every model decodes with its family's DFlash2 draft. Keep the draft in the Hugging Face cache, for example:

```bash
hf download incoai/Qwen3.8-27B-DFlash2
```

Splash 1.6 serves the Qwen3.8-27B, Qwen3.6-35B-A3B, Qwen3.5-122B-A10B and Qwen3.8-Flash-Next families and their fine-tunes. MLX weights must be quantized (affine 2–8 bits, mxfp4 or nvfp4). Splash refuses to start without a matching draft.

## Serve

In the Library, select a quantized MLX text or vision model or a Strata profile and choose **Serve with Splash** under **Inference**; Run opens **Start now** with **Text · Splash** selected. From **Serving** directly, choose **Start now** and set **Runtime** to **Text · Splash**. Then select **Preview serve**. The preview checks the launcher, its version, the model and the draft, and the launch configuration lists the Splash version and served model ID. Confirm to start; startup waits up to 15 minutes for the model to load.

**Skip reasoning** sets the default reasoning effort to none. Output length belongs to the client. Splash does not load on request: it serves from **Start now**, and releases idle weights itself. Saved endpoints keep their automatic runtime.

## Compare runtimes

In Compare's Chat mode, select a model in two lanes and set one lane's **Runtime** to **Splash**:

- A text model offers **Automatic**, **MLX-LM** and **Splash**.
- A vision model offers **Automatic** and **Splash**.
- A prepared Strata model offers **Strata** and **Splash**, so the same profile runs on both runtimes.

Lanes run one at a time; each starts, measures and stops its own server. The results matrix names each lane's runtime, and the model details list `Splash · Metal` with its weight format. Runs with an explicitly chosen runtime are excluded from default recommendations and **Promote winner**. See [Compare](compare.md#runtime-lanes).

## Command line

```bash
.venv/bin/python vendor/mlx-agent/scripts/mlx-agent serve start \
  --path /absolute/path/to/model --runtime splash --json
```

Inspect the preview, then repeat the command with `--confirm --preview-hash HASH`. `--repo` serves a cached Hugging Face snapshot under its repository ID; `--path` serves under `local/<name>`. The default port is 8086.
