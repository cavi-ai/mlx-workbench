# Strata

Strata is an optional, text-only runtime for Qwen3.8-Flash-Next on Apple Silicon. Workbench uses the pinned [Strata-MLX engine](https://github.com/yibie/strata-mlx) and [Strata HTTP frontend](https://github.com/Niko1221/Strata) behind MLX Agent's loopback serving, preview, receipt and stop operations. Ordinary MLX models keep their existing runtime selection.

## Install

Run `make install-strata` in the checkout with its initialized engine submodule. It requires `uv`, installs frozen dependencies in `~/.cache/mlx-agent/strata` and downloads no model weights. The standard Workbench Python environment is unchanged. `MLX_AGENT_STRATA_ROOT` selects another installation directory.

The engine and frontend revisions are pinned in `vendor/mlx-agent/src/mlx_agent/strata_runtime.py`. Installation refuses incompatible or modified source checkouts, and serving checks the installed source fingerprint and the prepared model's file identities against the preview before launching.

## Prepare a model

Only the tested Qwen3.8-Flash-Next GSQ-RCO **Q2_0** and **IQ3_S** two-shard GGUF packs are supported. MLX safetensors, VQ packs, other quantizations and companion or projector files cannot be used. Workbench never downloads a pack automatically.

Place both shards under one model directory. An optional complete MTP draft head must also sit beneath it; the pinned engine's `tools/mtp_fetch.py` fetches it independently and preparation verifies its manifest. Without MTP, suffix speculation remains available.

Prepare the profile with Strata's isolated Python:

```bash
"$HOME/.cache/mlx-agent/strata/engine/.venv/bin/python" scripts/prepare-strata-model.py \
  --out /absolute/path/to/model \
  --gguf /absolute/path/to/model/Q2_0/Qwen3.8-Flash-Next-GSQ-RCO-Q2_0-00001-of-00002.gguf \
  --mtp /absolute/path/to/model/mtp
```

Omit `--mtp` without a draft head. Preparation exports the tokenizer from the same GGUF, writes a bounded `strata-model.json` profile and a runtime marker in `config.json`, and leaves the weights unchanged. It refuses existing configs and symbolic links, and removes its new metadata if final validation fails.

Add the directory to your MLX roots and refresh Library. Details labels the runtime **Strata (text only)**. Run and chat Compare use the normal serving flow; vision requests and LoRA adapters are unsupported.

## Serve

From the app, select the model in Run as usual. From the command line:

```bash
.venv/bin/python vendor/mlx-agent/scripts/mlx-agent serve start \
  --path /absolute/path/to/model --runtime auto --port 8084 --json
```

Inspect the preview, then repeat the command with `--confirm --preview-hash HASH`. Prepared profiles resolve `auto` to Strata; `--runtime strata` works too. Add the same options to both the preview and the confirmation:

| Option | Effect |
|---|---|
| `--strata-speculation on` | Draft-and-verify decoding; off by default. Draft overhead can slow decoding down. |
| `--strata-expert-memory-gb N` | Caps resident expert weights, 0.5–64 decimal GB. Omit for automatic allocation. Smaller budgets page more from disk. |
| `--strata-context-tokens N` | Context capacity, 512–131,072 tokens |

Load on request supports the same profile and options. The endpoint binds only to `127.0.0.1`, serves the OpenAI chat API and keeps the local model path as its identity. Stop it with `serve stop --port 8084` so the receipt-owned process group is released.

Startup can take several minutes; Strata gets a 900-second readiness window. Performance depends on prompt length, draft acceptance, available memory and expert paging. Quantization and floating-point execution can change responses. A faster run does not establish equal quality, and there is no universal speedup.

### Memory admission

Admission excludes the disk-backed n-gram companion from resident weights. Automatic allocation estimates the first shard with a 20% expansion allowance. Explicit expert budgets read bounded GGUF tensor metadata and count capped expert weights, dense expansion and float prompt copies. Both add the full local MTP files, 5 GB of working memory and 30 KB per token of context. Eager serving keeps 2 GB of headroom; load on request uses its headroom policy. Unknown tensor layouts, unavailable memory readings or insufficient headroom block loading. These are admission estimates, not measured peaks.

## Compare

Select the prepared model and an existing MLX model in chat Compare and run a prompt set. Each model warms up on the endpoint used for its measured prompts and stops before the next starts. Warm-up output is excluded; server startup time is recorded separately from first-token latency.

Select the same Strata model in two lanes and expand **Strata settings** in each to compare speculation, expert memory and context independently. Both lanes replay the same prompts sequentially without copying or converting weights. Runs with custom settings or repeated model paths are excluded from default recommendations, aggregated performance and winner promotion.

Strata result cards also record:

- Runtime, weight format, declared quantization, model and runtime fingerprints, speculation setting, expert budget and context. Older runs show **Runtime not recorded**.
- Draft tokens offered and accepted, with the acceptance percentage, when the server reports both counts.
- New and cached input tokens and server prompt-processing time, shown apart from client first-token latency.
- System headroom before loading, its lowest sample during the run (every half second) and before cleanup. Headroom includes other apps and file caching; it is not model-only RAM.

**Memory and answer latency** plots each lane's lowest sampled headroom against its median time to first answer. **Paired speculation observations** compares a speculation-off and a speculation-on lane with the same model, budget and context; a summary appears only when prompts, fingerprints, finished answers, generation counts and cache work all match. Neither selects a winner or changes serving.

### Find best settings

**Find best settings…** prepares four lanes for one model: two explicit expert budgets, each with speculation off and on, at one context, an observed-headroom target and a latency objective. **First answer** minimizes request-to-first-answer time; **Completed response** minimizes request-to-stream-completion time, including reasoning and answer delivery, with server startup and warm-up excluded. **Use setup** only changes the comparison; **Run comparison** measures it.

A lane is suggested only when all four lanes completed with matching fingerprints, recorded settings, valid memory evidence, task reviews and identical server-reported cache work per prompt. Eligible lanes need a quality score of 4 or 5, a complete timed answer for every prompt and headroom meeting the target. For **Completed response**, completion timing must be positive, finite and no earlier than the first answer for every prompt; missing timing or unfinished answers exclude the lane. The suggestion is the eligible lane with the lowest median for the chosen objective: an observed comparison, not a guaranteed optimum. Older searches without an objective keep first-answer ranking. The panel names the first unmet requirement.

## Serving profiles

A serving profile saves a lane's settings for serving.

1. On a completed lane, **Save serving profile…**, or **Save and verify suggestion…** on a suggested lane.
2. In Run, select the model and the profile, then **Verify profile**. Verification runs the canary prompts with up to 1,024 generated tokens each; missing or unfinished answers fail. The verdict binds the settings, canary version and model and runtime fingerprints.
3. **Preview serve** and **Confirm and run** carry the profile through the normal confirmation. **Use profile for endpoint** applies it to the first always-on endpoint with an explicit port and mode.

Serving rechecks the profile's verification against a fresh plan; changed settings, files or runtime sources block serving until it passes again. Profiles are stored in `serving-profiles.json`, separately from configuration.

Run's **Manage profile** menu offers **Rename…**, **Remove…** (refused while any endpoint references the profile), **Customize copy…** (a new, unverified profile) and **Compare profiles…** (two profiles of one model in lanes A and B). In Run, **Review profiles…** lists each profile's canary status and source measurements, with a **Check memory** action that previews the runtime's memory estimate against current RAM without loading anything; **Comparison evidence…** shows the recorded run behind the selected profile. A completed profile lane in Compare offers **Verify measured profile…** to attach that comparison and rerun the canaries.

Apart from verification, which serves the model for its canaries, none of these actions start inference. None change model files or rewrite past comparisons.
