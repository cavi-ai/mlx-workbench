# Splash

Splash is an optional text runtime that serves quantized MLX, GGUF and prepared Strata profile weights in place, decoding with a DFlash2 draft. Workbench runs it through MLX Agent's loopback serving, preview, receipt and stop operations. Models keep their own runtime unless you choose Splash.

## Install

Splash needs an Apple M3 or newer and macOS 26.4 or later. Install it with Homebrew:

```bash
brew install incoai/tap/splash
```

The engine finds `splash` through `MLX_AGENT_SPLASH`, `PATH`, Homebrew and `~/.local/bin`, and requires version 1.7.0 or later; upgrade an older launcher with `brew upgrade incoai/tap/splash`. Persistent caches written by 1.6 start cold once after the upgrade. Workbench never installs Splash or downloads weights.

Every model decodes with its family's DFlash2 draft. Keep the draft in the Hugging Face cache, for example:

```bash
hf download incoai/Qwen3.8-27B-DFlash2
```

Splash serves the Qwen3.8-27B, Qwen3.6-35B-A3B, Qwen3.5-122B-A10B and Qwen3.8-Flash-Next families and their fine-tunes. MLX weights must be quantized (affine 2–8 bits, mxfp4 or nvfp4). Splash refuses to start without a matching draft.

## Serve

The Library scan asks Splash's engine which family each quantized MLX model's configuration describes, and offers Splash only for those it serves. In the Library, select such a model or a Strata profile and choose **Serve with Splash** under **Inference**; Run opens **Start now** with **Text · Splash** selected. From **Serving** directly, choose **Start now** and set **Runtime** to **Text · Splash**. Then select **Preview serve**. The preview checks the launcher, its version, the model and the draft, and the launch configuration lists the Splash version and served model ID. Confirm to start; startup waits up to 15 minutes for the model to load.

**Skip reasoning** sets the default reasoning effort to none. Output length belongs to the client. For a compatible model, **Save as endpoint** can select or create a named Splash preset and use **Load on request**. The endpoint reviews the preset's settings before launch. For a running Splash endpoint, review a replacement preset and retry when the endpoint is idle; active requests are not interrupted by this action. If the gateway started before the engine update, wait for active requests to finish and restart it before applying a preset.

## Presets

Presets are saved by the engine. **New preset…** opens the editor; every value left at **Splash default** or empty keeps Splash's own default. **Start from** fills the tuning, which stays editable:

| Start from | Sets |
|---|---|
| **Balanced** | Nothing: adaptive verification, int8 caches, and each request sets its own effort |
| **Agent sessions** | Reasoning effort none, thinking budget 0, and the SSD prompt cache kept across restarts |
| **Repeatable output** | Every draft row verified and exact cached states, so greedy and seeded outputs repeat |
| **Quick answers** | Reasoning effort none for every request |

| Group | Setting | Effect |
|---|---|---|
| Decoding | **Verify draft rows** | **Adaptive, faster** lets each decode cycle pick its rows; **Every row, repeatable** verifies every draft row |
| Decoding | **Reasoning effort** | Overrides the effort of every request; **None, thinking off** turns thinking off |
| Decoding | **Thinking budget** | Thinking tokens for a request that sets no budget, 0 to 1,010,000 |
| Cache | **KV cache** | int8 storage, or bf16 at about twice the KV memory |
| Cache | **Cached states** | int8 codes, or exact states |
| Cache | **Keep the SSD cache across restarts** | Keeps cached prefixes across restarts; needs an SSD cache quota above 0 |
| Cache | **SSD cache quota** | Gigabytes for cached KV pages and states, 0 to 4,096; 0 turns the SSD cache off |
| Limits | **Maximum memory**, **Maximum context tokens** | Splash's memory and context limits |
| Residency | **Headroom reserve**, **Idle timeout**, **Execution wait**, **Keep loaded**, **Unload under memory pressure** | When the load-on-request endpoint loads, queues for host compute (0–3,600 s), and unloads the model |

A preset needs at least one limit or Splash setting; with none, choose **Default settings**. The preset's summary under the picker and in the review lists each value it sets.

### Context and SSD cache observability

When serving with Splash 1.7, **Serving** reports both the server's **Effective context** (`splash_effective_context_tokens`) and **Configured context** (`splash_configured_context_tokens`) in the Connection tab and header badges, alongside active preset tuning for **Cached states** (`int8` or `exact`), **Persistent SSD cache**, **SSD cache quota**, and **Execution wait**.

## Compare runtimes

In Compare's Chat mode, select a model in two lanes and set one lane's **Runtime** to **Splash**:

- A text model of a family Splash serves offers **Automatic**, **MLX-LM** and **Splash**.
- A vision model of such a family offers **Automatic** and **Splash**.
- A prepared Strata model offers **Strata** and **Splash**, so the same profile runs on both runtimes.

Lanes run one at a time; each starts, measures and stops its own server. The results matrix names each lane's runtime, and the model details list `Splash · Metal` with its weight format. Runs with an explicitly chosen runtime are excluded from default recommendations and **Promote winner**. See [Compare](compare.md#runtime-lanes).

## Command line

```bash
.venv/bin/python vendor/mlx-agent/scripts/mlx-agent serve start \
  --path /absolute/path/to/model --runtime splash --json
```

Inspect the preview, then repeat the command with `--confirm --preview-hash HASH`. `--repo` serves a cached Hugging Face snapshot under its repository ID; `--path` serves under `local/<name>`. The default port is 8086.
