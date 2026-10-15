# Discover and Adopt

Both screens ask the engine about Hugging Face Hub candidates. Neither downloads weights; downloads go through [Add from Hugging Face](hugging-face.md).

## Discover

**Discover** runs the engine's `discover` command for a role and lists ranked candidates from remote catalog metadata.

1. Pick a **Role**. The picker offers only the roles the engine accepts.
2. Set the number of candidates per role. **Fast** skips per-model enrichment and ranks by name heuristics only.
3. **Discover**.

Each candidate shows its license, a fit bar for this Mac and an **In Library** mark when it is already on disk. Actions: **Add from Hugging Face…**, **Open on Hugging Face**, **Copy repo id**.

## Adopt

**Adopt** runs the engine's `adopt` flow for one role. The engine verifies candidates with deterministic role probes against your local runtime before it recommends one; see the MLX Agent [Adopt](https://cavi-ai.xyz/docs/mlx-agent) documentation.

1. Pick the requested **Role**. **Fast** uses heuristic-only discovery enrichment; **Offline** uses cached discovery and makes no metadata network requests.
2. **Start**. **Refresh** reads the adoption's current status.

The recommendation shows its fit on this Mac and a next step: **Run…** for a model you have, or **Add from Hugging Face…** for one you do not. Each adoption keeps its own state file, and a failed refresh keeps the last known result, labeled **Last known state**.
