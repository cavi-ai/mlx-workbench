# Strata inference

Strata is an optional, text-only runtime for Qwen3.8-Flash-Next on Apple Silicon. Workbench uses the pinned [Strata-MLX engine](https://github.com/yibie/strata-mlx) and [Strata HTTP frontend](https://github.com/Niko1221/Strata) behind mlx-agent's existing loopback serving, preview, receipt and stop operations. Ordinary MLX models keep their existing runtime selection.

## Install

Run `make install-strata` from the checkout with its initialized mlx-agent submodule. This requires `uv`, installs frozen dependencies in `~/.cache/mlx-agent/strata`, and downloads no model weights. It leaves the standard Workbench Python environment unchanged. `MLX_AGENT_STRATA_ROOT` can select another installation directory.

The engine and frontend revisions are pinned in `vendor/mlx-agent/src/mlx_agent/strata_runtime.py`. Serving checks their installed source fingerprint and the prepared model's file identities against the preview before launching. Installation refuses incompatible or modified source checkouts.

## Prepare existing files

Only the tested Qwen3.8-Flash-Next GSQ-RCO **Q2_0** and **IQ3_S** two-shard GGUF packs are supported. Reuse an existing compatible pair. MLX safetensors, VQ packs, other quantizations and companion/projector files cannot be used by this engine. A different supported GGUF pack is necessary when existing weights have one of those formats; Workbench never downloads it automatically.

Place both shards under one model directory. An optional complete MTP draft head must also be beneath that directory. The pinned engine's `tools/mtp_fetch.py` can fetch that head independently of the original model checkpoint; preparation verifies its manifest. Without MTP, suffix speculation remains available.

Use Strata's isolated Python to prepare the profile:

```bash
"$HOME/.cache/mlx-agent/strata/engine/.venv/bin/python" scripts/prepare-strata-model.py \
  --out /absolute/path/to/model \
  --gguf /absolute/path/to/model/Q2_0/Qwen3.8-Flash-Next-GSQ-RCO-Q2_0-00001-of-00002.gguf \
  --mtp /absolute/path/to/model/mtp
```

Omit `--mtp` when no draft head is present. Preparation exports the tokenizer from the same GGUF, writes a bounded `strata-model.json` profile and a runtime marker in `config.json`, and leaves weights unchanged. It refuses existing configs and symbolic links; a failed final validation removes its new metadata. Add this directory to the native app's model roots, then refresh the Library. Details labels the runtime **Strata (text only)**. Run and chat Compare use the existing serving flow; vision requests and LoRA adapters are unsupported.

## Serve and compare speculation

```bash
.venv/bin/python vendor/mlx-agent/scripts/mlx-agent serve start \
  --path /absolute/path/to/model --runtime auto --port 8084 --json
```

Inspect the preview, then repeat it with `--confirm --preview-hash HASH`. Prepared profiles resolve `auto` to Strata; explicit `--runtime strata` works too. Speculation defaults off. Add `--strata-speculation on` to both preview and confirmation to opt into draft-and-verify decoding. Compare throughput and first-token latency against ordinary decoding with the same GGUF weights before choosing it; draft overhead can make it slower. Add `--strata-expert-memory-gb 2 --strata-context-tokens 8192` to both commands to cap resident expert weights and context capacity. Expert budgets accept 0.5–64 decimal GB; context accepts 512–131,072 tokens. Omit the budget for automatic allocation. A smaller budget pages more weights from disk and can reduce speed. JIT serving supports the same profile and controls. The endpoint binds only to `127.0.0.1`, serves the OpenAI chat API, and preserves the local model path as its identity. Stop it through `serve stop --port 8084` so the receipt-owned process group is released.

Startup can take several minutes; Strata gets a bounded 900-second readiness window. Existing JIT memory admission and unload controls remain in effect. Performance depends on prompt length, draft acceptance, available memory and expert paging. Measure completion throughput and first-token latency separately. Quantization and floating-point execution can change responses; a faster run does not establish equivalent model quality. Workbench makes no universal speedup guarantee.

## Compare with an existing MLX model

Select the prepared Strata profile and an existing ready MLX model in chat Compare, then select one prompt set and run the comparison. Workbench warms each variant on the same endpoint used for its measured prompts and stops it before serving the next variant. Warm-up output is excluded from results. Server startup time is recorded separately from measured first-token latency.

For each selected Strata model, expand **Strata settings** in Compare to choose speculation, expert memory and context capacity. Settings apply only to that model and are preserved by **Reuse setup**. To compare two configurations of the same model, run the same prompt set separately with each configuration. Runs using custom settings keep their measured results but are excluded from default recommendations, aggregated model performance and winner promotion.

New result cards retain the runtime, weight format and declared quantization from the confirmed serving preview. Strata results also retain its model and runtime fingerprints and draft-and-verify setting, expert budget and context capacity. Historical runs without this evidence show **Runtime not recorded**. Strata keeps the original GGUF quantized blocks and Metal execution path; comparison does not convert or download weights. Comparing a GSQ-RCO GGUF with an MLX VQ pack measures two model variants, so evaluate their recorded responses alongside speed before selecting a winner.

Strata memory admission excludes the disk-backed n-gram companion from resident weights. Automatic allocation estimates the first shard with a 20% expansion allowance. Explicit expert budgets instead read bounded GGUF tensor metadata and count capped expert weights, dense expansion and float prompt copies. Both include the full local MTP files, 5 GB of working memory and 30 KB per token at the selected context capacity. Eager serving retains 2 GB of headroom; JIT uses its selected headroom policy. Unknown tensor layouts, unavailable memory measurements or insufficient headroom block loading. These are admission estimates, not measured peak memory.
