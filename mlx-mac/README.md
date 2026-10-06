# mlx-mac — native macOS app

Native SwiftUI front end for the mlx-agent model lifecycle on Apple Silicon.
It talks to the same pinned `vendor/mlx-agent` CLI as the web workbench —
argv tokens, preview/confirm hashes, receipts as the process authority — and
adds a lifecycle layer on top (verification, measurement, wiring, hygiene).

## Requirements

- macOS on Apple Silicon, Xcode installed
- The Python runtime from the repo root: `make install` (conversion and
  serving packages live in the project `.venv`)

## Build, run, test

```bash
make build-swift    # Release build into $(MLX_SWIFT_DD) (default /tmp/mlx-mac-build)
make run-swift      # build + open the app
make test-swift     # XCTest unit suite
```

`MLX_SWIFT_DD` overrides the derived-data path. UI tests that exercise real
local models live behind the `mlx-workbench-real-data-e2e` scheme and require
runtime values (`TASK6_*` environment or manifest) — they are not part of the
default test action.

## Opt-in GGUF-to-Run acceptance

The existing native real-data harness can be launched through one guarded
Make target:

```bash
make accept-native-gguf RUNTIME_MANIFEST=/absolute/path/to/runtime.json
```

`RUNTIME_MANIFEST` is mandatory and must be an absolute path. The target runs
only `GGUFToRunRealDataUITests.testRealGGUFToRunningMLXGoldenPath`; neither
`make test` nor `make test-swift` selects it. The harness may convert the named
GGUF, reuse an equivalent existing MLX output, and briefly start a local model
server. Use a deliberately selected disposable or otherwise approved source,
not an arbitrary model library entry.

The manifest is a strict JSON object with these fields and no additional
keys:

```json
{
  "source_path": "/absolute/path/to/models/example-Q4_K_M.gguf",
  "model_query": "example-Q4_K_M",
  "agent_home": "/absolute/path/to/mlx-agent",
  "config_path": "/absolute/path/to/mlx-workbench-config.json",
  "evidence_root": "/absolute/path/to/acceptance-evidence"
}
```

Prerequisites and preflight constraints:

- Apple Silicon macOS with Xcode's `xcodebuild` on `PATH`.
- The repository's conversion/serving runtime installed with `make install`.
- `source_path` is an existing regular `.gguf` smaller than 29 GB and resolves
  beneath one of the config's explicit, non-empty `gguf_roots` entries.
- `agent_home/scripts/mlx-agent` exists and is executable.
- If the config sets `mlx_agent_path`, it resolves to the same checkout as
  `agent_home`; divergent runtime identities are rejected before Xcode starts.
- `config_path` contains a JSON object whose `host` is `127.0.0.1`,
  `localhost`, or `::1` (an omitted or empty host uses `127.0.0.1`).
- `evidence_root` is absolute and outside every configured GGUF root.

The runner creates and prints a unique
`<evidence_root>/native-gguf-<UTC timestamp>-<pid>/` directory before invoking
Xcode. It contains `xcodebuild.log`, `result.xcresult` when Xcode produces one,
`DerivedData/`, screenshots and `ui-observations.log` from the harness, and an
atomic `outcome.json` summary. Existing evidence directories are never reused.

Failure classification:

| Exit | Classification | Meaning and evidence |
| --- | --- | --- |
| 2 | `manifest-invalid` | The manifest or referenced local inputs failed preflight. No run directory is promised because `evidence_root` was not trusted. |
| 3 | `prerequisite-unavailable` | The validated runtime cannot launch on this host. `outcome.json` records the reason. |
| 4 | `acceptance-failed` | Xcode launched but its test action failed. Use `xcodebuild.log` and `result.xcresult` to distinguish a product assertion, local model/runtime failure, or Xcode/build infrastructure failure. |
| 0 | `passed` | This manifest's configured real-data path passed; it does not certify other local models. |

The wrapper does not call conversion or serve commands itself. The UI harness
still previews each conversion and serve plan, confirms with the returned
preview hash, reconciles process state from mlx-agent receipts, binds serving
to loopback through the native app, and stops only the exact server receipt it
created. It does not delete or quarantine model data.

## Feature map

| Surface | What it does |
| --- | --- |
| **Home** | One concrete next action derived from workflow state, library evidence, watch alerts, and disk pressure |
| **Library** | Scanned GGUF/MLX inventory with readiness, signatures, and per-model details (verification status, lineage) |
| **Discover** | Hub candidates by role via the agent's scout |
| **Prepare** | Preview/confirm conversion; completed outputs pass through the **Conversion Quality Gate** (canary suite on an ephemeral loopback server) before they are marked verified |
| **Run** | Preview/confirm serving with a live **memory-fit verdict** (fits/tight/won't-fit + suggested context); hosts the **Always-on Endpoint** card |
| **Compare** | Start with the last served model and nearby alternatives; compare task outcomes, speed, latency, disk size, and estimated memory fit. Replay built-in or personal prompt sets, review outputs, import local workflow reports, and export agent-readable evidence. Using the fastest variant remains a reviewed preference/endpoint action; speed alone does not establish quality or justify reclaim. |
| **Activity** | Conversion receipts, log tails, server table |
| **Duplicates** | Duplicate groups plus the **Disk Pressure Advisor** (stale / superseded / cross-root reclaim via batched quarantine; HF-cache prune via doctor) |
| **Wire** | mlx-agent wiring plus **cross-client wiring** (opencode, Continue, Zed, Aider — atomic writes with backup and rollback; LM Studio/Ollama advisory) |
| **Menu bar** | Endpoint state and start/stop at a glance |

## Compare decisions and workflow evidence

Charts lead the Compare tab; outputs and machine/workflow details start collapsed.
The compact **Champions** trophy menu links to task-specific speed, reviewed-quality,
and first-token winners from the latest complete comparison cohort. Every entrant
must still be available with its measured model signature and this Mac's environment;
ties share the award, and incomplete quality reviews do not establish a quality champion.

Search and the Family/Disk size filters narrow the model menus. Family uses
readable name-based series labels (not architecture classifications); disk size
uses the scanned file footprint in decimal GB, not runtime memory. Group by can
organize choices by family, reported parameter size,
disk footprint (decimal GB), or name. Unknown sizes stay explicit. Selections
outside the filters remain available in their own menu section; Clear restores
all choices, and changing comparison mode resets the filters.

Compare starts with the most recently **intentionally served** compatible
model. Verification and benchmark runs do not change that default. When
that model is unavailable, Compare uses the Library selection, a previous
comparison model, or a deterministic available model. Alternatives with
comparable local measurements are suggested first; family and disk-size
fallbacks are labeled unmeasured. Manual choices survive inventory updates.
Changing modes selects models eligible for the new mode. The workload picker
starts from an available recent comparison set; benchmark proximity refers
to the selected workload.

The decision panel separates measured speed and latency from human task
reviews and estimated memory fit. Choose a context size and refresh the
memory capture to evaluate current headroom with the configured safety
reserve. The chat-serving estimator does not model image, speech, or video
pipelines; their fit stays unknown, with recorded peak memory shown as dated
evidence when available. Unified-memory fit is an estimate, not a measurement
of GPU load or a guarantee against swapping. A task review uses this explicit rubric:
1 unusable, 2 major corrections, 3 usable with corrections, 4 minor
corrections, 5 meets the task without corrections. Unreviewed stays unknown;
tool-call argument validation is a limited check, not general answer quality.

Use **Workflow reports and agent evidence** to get a capture request,
explicitly import a local report, or export agent evidence. Choose Claude,
OpenClaw, OpenCode or Custom and a ready local model, then copy or save the
request for your agent. Requests contain known model and environment identities
at capture time; unavailable identities and required measurements remain null. The producer
must establish that the task used those exact identities, fill `reportDraft`
from its measured receipts, establish unknown identities from the actual run,
and save that object as the report JSON. Unconfirmed identity remains explicit
at import and cannot establish current replacement advice. The
request itself is not importable evidence, and its context must never be used
to relabel an older run. Missing metrics remain unknown.

Import reads and validates the report off the main actor, then previews new
records, identical duplicates, dates, timings, source and model/environment
identity status before saving. Historical or unmatched observations can be
saved for reference; they cannot establish current replacement advice. A
conflicting record ID or changed saved evidence blocks the import. Cancel
leaves the evidence store untouched. The interchange supports reports
produced for Claude, OpenClaw, OpenCode, and custom workflows; it does not
automatically inspect those clients' session logs. **Import OpenCode prompts**
remains a separate read-only import for replaying your actual prompts.

Workflow JSON uses an object with `schemaVersion: 1` and a `records` array.
Each record requires:

| Field | Meaning |
| --- | --- |
| `id` | UUID identifying the observation; repeating an identical record is harmless, conflicting reuse is rejected |
| `harness` | `claude`, `openclaw`, `opencode`, or `custom` |
| `workloadID` | Stable identity of the task being measured |
| `modelPath`, `modelSignature` | Absolute model path and exact recorded model signature |
| `environmentFingerprint` | Environment recorded when the measurement happened |
| `measuredAt` | ISO-8601 timestamp |
| `sampleCount` | Positive number of observations represented |
| `totalSeconds` | Positive total elapsed duration in seconds |
| `source` | Receipt or session identifier establishing provenance; omit secrets and transcripts |

Optional fields are `useCase` (`coding`, `general_chat`, `reasoning`, or
`vision`), `inferenceSeconds`, `toolSeconds`, `queueSeconds`,
`timeToFirstTokenSeconds`, `tokensPerSecond`, `qualityScore` (1–5),
`rubricID`, `configurationFingerprint`, `peakMemoryBytes`, and
`availableMemoryBytes`. Quality requires a rubric shared by the compared
records. A configuration fingerprint identifies the exact workload and
settings, including prompts, tools, context, and generation parameters;
records without matching configuration fingerprints cannot establish
supersession. All durations are seconds and memory quantities are bytes.
Inference, tool, and queue durations must be disjoint additive components
whose sum does not exceed the total. When all three are supplied, the
remainder is labeled unattributed time; it does not identify a GPU, disk,
or client bottleneck. Missing fields remain unknown.

Imports are bounded to 4 MiB and the saved store to 2,000 records. Invalid
metrics or conflicting observation IDs reject the import without replacing
the saved evidence. Timestamps may include fractional seconds.

Copy identity and environment values from an evidence export only for new
measurements performed against that exact model and environment. Never
replace an old observation's fingerprint with the current one. The saved
template contains no measurements. Imports stay local in a separate
`workflow-evidence.json` store beside the other native evidence stores;
they do not modify shared `config.json` or client configurations.

Agent exports provide local model identity, machine and memory context,
recorded comparison/workflow evidence, task reviews, and advisory reclaim
reasons. An agent must treat missing or stale evidence as a reason to
measure or review, rather than infer a quality winner. Task-scoped reclaim
suggestions require matching evidence with no worse reviewed quality,
speed, latency, estimated memory, or disk requirements and a concrete
advantage. They remain review-only because a model may still serve another
task. Active, endpoint-configured, and preferred models are protected;
existing file moves retain their preview/confirm flow.

Replacement chains group reviewed alternatives under a terminal keeper from
one complete comparison or a matching harness/workload/configuration/rubric
cohort. They never bridge separate tasks, and the newest evidence for a task
supersedes older advice. The cards show quality, speed, first-token latency and
disk size; agent exports include structured `replacementChains`. A retained
keeper is excluded from generic stale-file advice. Exact duplicate advice
requires a named keeper and authoritative redundant paths; variant groups
remain informational.

Quarantine lists current files with **Put back** and **Move to Trash** actions,
including older entries via **Show all files**. Trash confirmation previews
the selected file and its current size, then rechecks file identity, timestamps,
ledger membership and the quarantine directory before using native macOS
Trash. Symlinks, directories, the ledger and files outside quarantine are
refused; there is no permanent-delete fallback. The ledger retains the record
with `deleted_at`, matching the web contract. Space is freed when Trash is
emptied in Finder, not when a file enters quarantine.

## Design rules

- Everything mutating is previewed, hashed, and confirmed; intent drift
  between preview and confirm is refused.
- mlx-agent receipts are the authority for process state; app-side state
  reconciles against them.
- Verification reports and benchmark evidence are keyed to exact file
  signatures — stale evidence is marked, never silently trusted.
- Quarantine moves; nothing deletes.
- The endpoint and probes bind loopback only.

Feature specs and the packaging rationale live in `docs/premium/`.
