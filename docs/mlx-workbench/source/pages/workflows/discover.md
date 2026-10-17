# Discover

**Discover** offers **Browse candidates** and **Recommend for a task**. Both ask the engine about Hugging Face Hub candidates. Neither downloads weights; downloads go through [Add from Hugging Face](hugging-face.md). Switching modes preserves their current drafts and results without starting either operation.

## Browse candidates

**Discover** runs the engine's `discover` command for a role and lists ranked candidates from remote catalog metadata.

1. Pick a **Role**. The picker offers only the roles the engine accepts.
2. Set the number of candidates per role. **Fast** skips per-model enrichment and ranks by name heuristics only.
3. **Discover**.

Each candidate shows its license, a fit bar for this Mac and an **In Library** mark when it is already on disk. Actions: **Add from Hugging Face…**, **Open on Hugging Face**, **Copy repo id**.

Memory fit is an estimate, not a runtime check. **Add from Hugging Face…** opens
a separate review before downloading; use **Recommend for a task** to check
installed candidates through local runtimes.

The separate **Catalog metadata** section shows cached metadata. **Refresh Metadata** is disabled when no metadata provider is configured; its help explains why. Role-based discovery and cached entries remain available.

## Recommend for a task

This mode runs the engine's `adopt` flow for one role. It builds a shortlist and checks installed candidates through local runtimes, using generation and role probes where supported. Verification can load a model into RAM. A recommendation's evidence strength shows whether it came from runtime checks, metadata or heuristics; it is not a Workbench conversion verification verdict.

1. Pick the requested **Role**. **Fast** uses heuristic-only discovery enrichment; installed candidates still receive runtime verification prompts. **Offline metadata** uses cached discovery and makes no metadata network requests; local runtime probes still run.
2. **Verify and recommend** starts the checks. **Refresh** reads the recommendation's saved status.

**Stop checks** cancels Workbench's current verification request. Controls stay busy
until its process exits. Saved results are kept and may be partial or still say
`running`; **Refresh** reads that saved state, while **Verify and recommend** starts
a new workflow. A local runtime may finish an in-flight prompt and keep its model
loaded after Workbench stops checking.

The recommendation shows its fit on this Mac and a next step: **Run…** for a model you have, or **Add from Hugging Face…** for one you do not. Each request keeps its own state file, and a failed refresh keeps the last known result, labeled **Last known state**. Existing saved Adopt navigation opens this mode in Discover.
