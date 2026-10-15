# Overview

MLX Workbench {{PRODUCT_VERSION}} is a native SwiftUI app for the local model lifecycle on Apple Silicon. It inventories the weights on your Mac, converts them to MLX, verifies the result, serves models on loopback ports, measures them against each other and wires them into local clients.

The app is the desktop front end for [MLX Agent](https://github.com/cavi-ai/mlx-agent). It runs the selected engine's `scripts/mlx-agent` with argv tokens and `--json`, and renders the result. The engine owns execution: conversion jobs and their queue, serving processes, experiments and training receipts. The app has no web server and no background UI service.

These pages describe release {{RELEASE_TAG}} from commit `{{RELEASE_COMMIT}}`.

## Choose a path

The workspace uses dark surfaces, yellow primary actions and a grouped
sidebar. Warnings, failures and verification states keep their own labels
and symbols. Each screen opens with its title and a short description.

| You want to | Start with |
|---|---|
| Install the app and its engine | [Installation](installation.md) |
| Get one model converted, verified and serving | [Your first model](quickstart.md) |
| Bring in a model from Hugging Face Hub | [Add from Hugging Face](../workflows/hugging-face.md) |
| Keep a model serving for your coding tools | [Run and endpoints](../workflows/run.md), then [Clients](../workflows/clients.md) |
| Decide between quantizations or models | [Compare](../workflows/compare.md) |
| Free disk space safely | [Reclaim](../workflows/reclaim.md) |
| Fine-tune on your own text | [Training and studies](../workflows/training.md) |
| Change paths, defaults or the engine | [Configuration](../reference/configuration.md) |

## Screens

The sidebar groups fifteen screens.

| Group | Screen | Purpose |
|---|---|---|
| Workbench | **Overview** | Model budget for this Mac, one next-step action and the selected model's flight path |
| | **Library** | Local GGUF and MLX weights, fit now, details, lineage and deletion |
| Lifecycle | **Prepare** | Preview and confirm conversions; follow verification |
| | **Compare** | Measured model comparisons with recorded prompts and outputs |
| | **Run** | Loopback servers, memory runway, always-on endpoints and serving profiles |
| Operations | **Activity** | Conversion, server, experiment and training jobs on one timeline |
| | **Reclaim** | Quarantine, Trash, source cleanup and restore |
| | **Clients** | Config wiring for local clients, with rollback |
| | **Health** | Runtime readiness, model health and the Setup Assistant |
| Lab | **Discover** | Hugging Face Hub candidates with fit for this Mac |
| | **LM Studio** | Models in LM Studio's downloads folder, ready to run or prepare |
| | **Studies** | Controlled experiments, generation jobs and blind review |
| | **Training** | Text LoRA training and base-versus-adapter evaluation |
| | **Adopt** | A role recommendation from the available evidence |
| Settings | **Settings** | Engine, model locations, storage, defaults, advisors and updates |

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
