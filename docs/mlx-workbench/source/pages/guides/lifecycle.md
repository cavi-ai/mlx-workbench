# Model lifecycle

MLX Agent owns discovery, conversion, serving, shared jobs, and experiment
execution. The native app presents plans, confirmations, and results.

| Screen | Purpose |
| --- | --- |
| **Library** | Inspect local GGUF and MLX weights, readiness, and details. |
| **Prepare** | Preview conversion, confirm its destination, and follow verification. |
| **Run** | Preview and manage loopback endpoints and memory policies. |
| **Compare** | Measure models, inspect text and media outputs, or author controlled studies. |
| **Activity** | Inspect conversion, server, experiment, and training jobs. |
| **Reclaim** | Preview quarantine, recovery, source cleanup, and Trash actions. |
| **Clients** | Preview client configuration writes and guarded rollback. |
| **Discover** | Find Hugging Face Hub candidates and review intake. |
| **Health** | Inspect runtime readiness, model health, and remediation. |
| **Training** | Validate text datasets, preview LoRA jobs, and evaluate completed adapters. |
| **Settings** | Configure paths, runtime, behavior, and updates. |

Every conversion is previewed before confirmation. Engine receipts record
launched work. Imported conversions retain reviewed plans; **Run next**
reconciles receipts and starts one pending item when compute is available.
Retry reuses its plan; queue reordering does not approve a new conversion.

Measured comparisons preserve prompts, settings, identities, outputs, and
reviews. Explicit prompt-set saves retain owned copies of user-picked inputs.
Historical evidence remains separate from current availability, and speed
alone never establishes quality or justifies reclaim.

Controlled studies freeze recipes before generation and retain artifacts
and blind reviews before authorized reveal. Training pins the cached base
model and reviewed dataset bytes, records the process outcome, and verifies
adapter content. Completed text LoRA jobs can run a matched base-versus-adapter
evaluation; this does not qualify media training.

Downloads, client writes, cleanup, and restore keep their own preview and
confirmation boundaries. Editing drafts does not alter historical runs.
