# Overview

MLX Workbench {{PRODUCT_VERSION}} is a native SwiftUI app for the local model lifecycle on Apple Silicon. It inventories the weights on your Mac, converts them to MLX, verifies the result, serves models on loopback ports, measures them against each other and wires them into local clients.

The app is the desktop front end for [MLX Agent](https://github.com/cavi-ai/mlx-agent). It runs the selected engine's `scripts/mlx-agent` with argv tokens and `--json`, and renders the result. The engine owns execution: conversion jobs and their queue, serving processes, classification and music tasks, experiments and training receipts. The app has no web server and no background UI service.

These pages describe release {{RELEASE_TAG}} from commit `{{RELEASE_COMMIT}}`.

## Choose a path

The workspace follows the system appearance, uses yellow primary actions and
a grouped sidebar, and opens on the Library. Warnings, failures and
verification states keep their own labels and symbols. The toolbar shows each
screen's title.

| You want to | Start with |
|---|---|
| Install the app and its engine | [Installation](installation.md) |
| Get one model converted, verified and serving | [Your first model](quickstart.md) |
| Bring in a model from Hugging Face Hub | [Add from Hugging Face](../workflows/hugging-face.md) |
| Keep a model serving for your coding tools | [Serving and Monitor](../workflows/run.md), then [Clients](../workflows/clients.md) |
| Decide between quantizations or models | [Compare](../workflows/compare.md) |
| Classify content or generate music with one model | [Library tasks](../workflows/library.md#local-inference-tasks) |
| Free disk space safely | [Reclaim](../workflows/reclaim.md) |
| Fine-tune on your own text | [Training and studies](../workflows/training.md) |
| Change paths, defaults or the engine | [Configuration](../reference/configuration.md) |

## Screens

The sidebar groups thirteen screens.

| Group | Screen | Purpose |
|---|---|---|
| Models | **Library** | Local weights, fit, details, task workspaces, lineage, deletion and LM Studio source |
| | **Model sources** | Inventories across local providers, connection setup and registered cache folders |
| | **Discover** | Browse Hugging Face Hub candidates or request a task recommendation |
| | **Prepare** | Preview and confirm conversions; follow verification |
| | **Reclaim** | Quarantine, Trash, source cleanup and restore |
| Workspaces | **Use** | Persistent conversations, selected model servers and typed task results |
| | **Compare** | Measured model comparisons with recorded prompts and outputs |
| | **Serving** | Model APIs, authentication, inference settings, memory and client connections |
| | **Monitor** | Live serving status, reported token usage and response throughput |
| | **Training** | Text LoRA training and base-versus-adapter evaluation |
| | **Studies** | Controlled experiments, generation jobs and blind review |
| System | **Overview** | Model budget for this Mac, one next-step action and the selected model's flight path |
| | **Activity** | Conversion, server, experiment and training jobs on one timeline |
| | **Clients** | Config wiring for local clients, with rollback |
| | **Health** | Runtime readiness, model health and the Setup Assistant |
| Settings | **Settings** | Engine, model locations, storage, defaults, advisors and updates |

Overview's flight path includes only stages supported by the selected model: verification requires an available canary, measurement requires a compatible comparison mode, and serving applies to chat and vision models. **Measured** requires a usable metric from a completed compatible comparison with the same path and a known matching model signature. Missing signatures remain unmeasured.

For a completed model, the next-step action uses its declared backend's installation status. Strata and declared backends have their own execution environments; the base-runtime warning does not establish their readiness. Run still previews the selected runtime and requires confirmation before serving.

The menu bar item shows endpoint status and starts or stops each endpoint. The toolbar's memory header shows estimated RAM use and headroom on every screen.

## How it works

1. **Preview.** Every change starts as a plan: the command, destination, output size, fit and a preview hash.
2. **Confirm.** Confirmation runs exactly the reviewed plan. A changed input invalidates the preview.
3. **Receipt.** Launched work leaves an engine receipt. Running state is recovered from receipts, so a restart of the app does not lose jobs or servers.
4. **Evidence.** Verification verdicts, measured comparisons and human ratings are recorded with model signatures and an environment fingerprint. When either changes, the evidence no longer counts as current.

## Boundaries

- Serving binds to loopback, such as `127.0.0.1`. Hugging Face Hub discovery and downloads contact the network; loopback binding is not a promise of network isolation.
- Downloads, conversions, client writes, cleanup and restore each have their own preview and confirmation.
- Repository runtime code from a model is never executed, and intake never passes `--trust-remote-code`.
- Speed does not establish quality. Measured speed and human task ratings stay separate everywhere.
