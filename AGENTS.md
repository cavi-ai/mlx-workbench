This repository is `mlx-workbench`, a loopback-only web UI wrapper for
`mlx-agent` model lifecycle tasks on Apple Silicon. It shells out to the
vendored `mlx-agent` binary and renders results; there are no Python imports
from `mlx-agent` at runtime.

## Current truth docs

- `README.md` is the primary operator guide.
- `docs/mlx-workbench` contains versioned guide pages and documentation tests.
- `Makefile` defines the supported local command surface.
- `mlx_workbench/__init__.py` (`__version__`) is the single version source of
  truth; `CHANGELOG.md` records releases. Use `make version-bump V=x.y.z` to
  bump both plus the Swift `MARKETING_VERSION` and docs-test constants;
  `tests/test_version_sync.py` enforces the sync.

## Repository shape to keep in sync

- `vendor/mlx-agent` is a git submodule used as the execution engine.
- `scripts/mlx-workbench` is the launcher.
- `mlx_workbench/` is the application package. The web UI is scoped to the
  core loop (Models / Convert / Duplicates / Scout / Doctor / Serve /
  Training Studio / Compare Conversions / Model Arch / Jobs / Settings);
  Adopt, Wire, and the other lifecycle surfaces live in the native app.
  Serve presets are the web's named endpoint profiles
  (`mlx_workbench/serve_presets.py`, persisted in `serve-presets.json`
  beside the queue state file — deliberately separate from `config.json`
  so the native app's endpoint fleet and web presets never clobber each
  other).
- The shared `config.json` contract: `mlx_workbench/config.py` preserves keys
  it does not manage (e.g. the native app's premium toggles), and the web
  Settings save overlays posted fields onto the loaded config so a web save
  never strips native-app keys. Keep that invariant.
- `tests/fixtures/` is the shared contract-fixture set consumed by BOTH the
  Python suite (`tests/test_contract_fixtures.py`) and the XCTest suite
  (`ScanContractTests`, `WorkbenchAPISubprocessTests`, `ContractFixtureTests`).
  A fixture change must keep both suites green; see `tests/fixtures/README.md`.
- The web UI's durable convert queue (`convert-queue.json`, schema 1.1) has
  exactly one writer: the web server. The native app reads it read-only via
  `Services/WebConvertQueue.swift` and shows it in Activity as "Web Queue" with
  provenance, only when it holds items or a problem; schema and path resolution mirror
  `mlx_workbench/convert_queue.py` and are pinned by shared fixtures. Never
  write to that file from the native app.
- `tests/` contains unit and release-doc coverage.
- `mlx-mac/` is the native SwiftUI app (Xcode project, explicit file list in
  `project.pbxproj` — register new sources there). `make test-swift` runs its
  XCTest suite. Design specs for premium features live in
  `mlx-mac/docs/premium/`. The app icon master is
  `mlx-mac/assets/app-icon.svg`; `make dmg` packages a distribution Release
  build (`-DMLX_WORKBENCH_DISTRIBUTION`: no source path compiled in) as
  `MLX Workbench.app` on an `MLX Workbench` volume under `.release/` (ad-hoc
  signed; `DEVELOPER_TEAM=<team id>` archives, exports with Developer ID,
  notarizes through the Xcode account, and staples via `build-swift-devid`).
- `make accept-native-gguf RUNTIME_MANIFEST=/absolute/path/runtime.json` is the
  opt-in real-data native GGUF-to-Run acceptance surface. Its runner validates
  an explicit allowlisted local source and loopback config, selects only the
  existing golden-path UI test, and writes per-run evidence beneath the
  manifest's `evidence_root`. Never invoke it with an arbitrary local model.
- The Swift app gates conversions with a **Conversion Quality Gate**: after a
  fresh scan confirms a conversion output, `VerificationCoordinator` serves it
  on an ephemeral loopback port (via the existing serve preview/confirm
  boundary), runs the canary suite in `Models/VerificationModels.swift`, and
  only then marks the workflow `verified`. The gate attaches in `App.swift`;
  without an attached verifier the workflow behavior is unchanged.
- **Hugging Face Intake**: `IntakeCoordinator` + a single Add from Hugging Face window
  (`IntakeSheet`; Prepare field, ⌘V on the Library table and Prepare view, ⇧⌘V anywhere) over
  `mlx-agent intake resolve|fetch|status|port-analysis|port-plan` and
  `backend list|install|remove`. Repo conversions run through
  `ModelWorkflowCoordinator.inspect(intake:…)` with `ConversionWorkflow.sourceRepo/backend/modelType/subfolder/allowedBits` (`modelType` → `convert start --model-type`, which runs a port's own converter; `subfolder` → `--subfolder` and an `org/name/folder` fetch, for checkpoints below the repo root such as Laya's `multilingual`; `allowedBits` from intake's `q_bits` limits Prepare's bit picker, e.g. Laya is 8-bit only);
  the Quality Gate canary runs only for `ModelTaskType.hasCanary` types (chat models: served canary prompts; speech-to-text: a `say`-synthesized sentence transcribed through `mlx-agent convert transcribe`, passing at ≤25% word error; classification: `DecisionCanary`, a billing ticket answered through `mlx-agent convert decide` that must route to billing and read as a refund request; image generation: `ImageCanary`, a fixed prompt rendered at 512² through `mlx-agent convert generate` that must write a non-blank image), and Run/Compare refuse
  non-servable types, and Prepare/Activity do not offer Run for them. `config.outputDir` is scanned as an MLX root unless a root already contains it (by file identity).
  Prepare refreshes conversion status while a job is in flight and shows a progress ring (bytes
  written against the intake estimate; indeterminate while the converter loads) with the job log in a
  collapsible section; its bit picker re-targets repo
  destinations. The intake window shows the agent's header-based `estimated_output_bytes`. Model type and use cases come
  from the agent's `task` labels (`ModelTask`); `UseCase` stays the serving-role vocabulary.
  Architectures no pinned backend implements can ship as mlx-agent backend ports
  (`resources/ports/<backend>/`, e.g. mlx-audio `audio8_asr_infinite`, mlx-embeddings `laya`): the registry counts them
  and `convert start` copies them into the backend venv before the job; repos without a root `config.json` resolve
  through a port's file signature (Laya), diffusers repos through their `model_index.json` pipeline class, and curated
  recipe repos through their pinned base plus LoRA (mflux `qwen_image_21`: abenzerps/Qwen-Image-2.1-Uncensored-GGUF; the
  intake window shows "Built from"). Image-generation models get a Generate panel in the Library inspector
  (`ImageGenerationCoordinator` + `ImageGenerationPanel`: prompt, size, steps, seed → a new PNG in ~/Pictures/MLX Workbench).
  Speculative-decoding drafters (`ModelTaskType.speculativeDraft`: llama.cpp `dflash`/`eagle3` GGUFs, configs with
  `dspark_target_layer_ids`) borrow their target's embeddings and head, so they have no canary and are never servable;
  `ModelItem.draft` (scan's `draft`, or a converted output's `dspark_target_name`) names the target in Model Details.
  A DeepSeek-V4 DSpark `dflash` GGUF converts through mlx-agent's `deepseek_v4_dspark` port (`convert start --gguf`
  adds `--port`); other drafters are refused at plan time (`unsupported_draft`).
- Native serving, verification, chat comparisons and endpoints use `--runtime auto`:
  the agent reads local model metadata, selects a declared serving backend and
  binds an optional backend's isolated executable into eager and JIT previews.
  Already-MLX intake retains backend/install readiness. Prism's published 2-bit
  packs use the pinned MLX-VLM Hadamard adapter without executing repository
  runtime code. GGUF projector/companion files are refused before conversion.
- Serve accepts HF repo ids or local directories (`serve start --path`,
  upstream ≥ the local-path serve change). `WorkbenchAPI.serveModelArguments`
  preserves every local directory, including HF-cache snapshots, through
  `--path`; status comparisons normalize through
  `ServerInfo.modelIdentity` (repo id or path, whichever the agent reports).
  Intake checks current ready inventory and matching conversion history before
  fetching. Downloaded conversion directories are passed through `--source-path`
  and persisted as `ConversionWorkflow.localSourcePath`; converter workers run
  offline. Confirm conversion captures the visible source-cleanup choice.
  After verification, `ConvertedSourceCleanup` reclaims receipt-owned GGUF files
  or single-revision cache repositories to macOS Trash. It protects changed
  outputs, active/preferred paths, other revisions and surviving shared-blob
  references across configured roots. Recovery locations live in
  `source-cleanup.json`; old workflows require an explicit cleanup preview.
  Duplicates lists eligible originals from verified receipts and journal-backed
  cleanup history. New moves record batch, workflow, bytes, time and Trash
  metadata identity. Restore previews exact original destinations, rechecks
  native Trash and configured-root fences, refuses conflicts and drift, restores
  blobs before cache folders, and records each result. Legacy history has no
  historical identity; its explicit restore preview binds the current Trash item.
- The Compare tab runs **Measured Comparisons**: `ComparisonCoordinator`
  replays a prompt set against selected ready variants (one at a time, via
  the shared `ServeProbe` harness), persists runs, and feeds measured
  tok/s/TTFT into the RecommendationEngine as local benchmark evidence.
  **Promote winner** (on a completed run) chains the verdict:
  `AppHost.setPreferredModel` persists the winner as the use-case preference
  (`recommendation-preferences.json`), optionally enables/swaps the
  Always-on Endpoint (verified gating kept), and links onward to the Wire
  and Duplicates tabs — wiring and reclaim keep their own preview/confirm
  flows.
  Samples also capture `prompt_tokens` (prefill speed = prompt tokens over
  TTFT, always labeled an estimate) and tool calls (builtin "Tool calling"
  set offers `PromptToolSpec`s; streamed `tool_calls` are counted and their
  arguments validated against the schema's required keys). Past runs are
  browsable in a searchable history popover; `ModelPerformanceProfile` aggregates
  per-model stats into Model Details.
  **Compare modes**: a picker above the variant slots (segmented when it fits, otherwise a menu; `ComparisonMode`:
  chat, vision, video understanding, speech to text, text to speech, image
  generation, video generation, music generation); slots list only models whose `ModelTaskType`
  the mode accepts (`ComparisonViewLogic.candidates(from:mode:)`). Chat keeps
  the ServeProbe path above unchanged. Every other mode runs per variant, per
  prompt, sequentially through an injectable `ComparisonMediaRunner` (live:
  `convert describe|transcribe|speak|music|generate|video` on the `WorkbenchAPI`
  actor, never the main actor). Blocking CLI execution runs on a dispatch
  worker through a throwing continuation, so long media jobs hold neither
  the API actor nor a Swift cooperative worker. Prompts carry optional media input
  (`PromptEntry.inputKind` + `inputPath`, or a `builtinInput` generated at run
  time into `<run>/inputs/` by `ComparisonMediaFixtures`: CoreGraphics PNGs, an
  AVAssetWriter MP4, `say`-synthesized WAVs; no binary assets in the repo) and
  optional `expectedKeywords` (contains-all, case-insensitive; `a|b` means
  either). Speech-to-text is scored with `SpeechCanary.wordErrorRate`; built-in
  speech clips are transcribed with `--language en` (`MediaRunRequest.language`),
  user-picked clips with no language. Outputs
  are saved to `<Application Support>/mlx-workbench/comparison-outputs/<run-id>/<variant-index>-<prompt-id>.<txt|png|wav|mp4>`
  (`ComparisonOutputStore`); `ComparisonSample` carries `artifact` and the
  per-mode metrics, `ComparisonRun.mode` (nil = chat). When a media run starts,
  output folders of all but the 10 newest media runs are deleted (only
  directories directly under `comparison-outputs/` named by a run UUID; links
  are never followed); run JSON is kept and a missing artifact renders as
  "output pruned". A sample's `artifact` containing `/`, `..` or a leading dot
  is refused. New input-media runs save user-picked files off the main actor before
  replaying any model; built-in inputs are generated once, captured under unique
  basenames and their temporary generated files removed. `ComparisonRun.inputArtifacts`
  records the saved input per prompt inside the run's `inputs/` folder before replay.
  Sources and saved files must be readable regular files; symbolic links and symlinked
  store directories are refused. User-picked originals are never changed or removed.
  Input copies follow the existing ten-run output retention. Results preview saved
  inputs, label older user-picked originals as unsaved, and never substitute an original
  when a recorded copy is unavailable. Speech input text is labeled as a reference
  transcript; keyword checks describe case-insensitive presence and alternatives.
  The text A/B editor uses the same input-evidence resolver and offers a Finder
  reveal action that rechecks availability before opening the saved or labeled
  legacy original file. It shows the recorded reference and expected-word checks.
  The coordinator only touches an output store it was handed
  (`outputStore`, wired in `AppHost`). The results grid leads with one lettered
  lane (A–D, run order) per variant carrying the mode's primary metric as its
  largest numerals and a relative bar: tok/s, real-time factor, seconds per
  step, seconds per frame. Below the lanes is one row per prompt, one column per
  lane (text, image thumbnail with larger sheet, audio play/stop, video player).
  Completed text-output runs (chat, vision, video understanding, speech to text) offer
  `TextComparisonPanel` below the charts: two model outputs for one recorded prompt,
  selectable reading or bounded line differences, with existing task-quality ratings.
  `ComparisonDiff` prefers full recorded output, labels older excerpt-only samples,
  excludes failed/unpaired samples and limits the quadratic differ to 20,000 characters
  and 500 lines per output without truncating the reading view. New chat samples persist
  `fullOutput`; old runs are not rewritten. Promote winner stays chat-only; media runs do not feed the
  RecommendationEngine.
  Music generation accepts `music_generation` models and uses the audio backend's
  dedicated music loader. Prompt snapshots preserve caption, lyrics, requested
  duration, steps and seed; built-ins request 15-second instrumental clips.
  WAV playback and real-time factor use the existing audio results path, with
  no automatic quality score. Generation is offline from an absolute local
  directory. Already-exported quantized MiniMax Music 3 sources use the engine's
  local music requantizer, preserving tokenizer/scheduler assets while rebuilding
  weights; raw component checkpoints keep the backend's original converter.
  Music generation requires the real root or nested tokenizer and uses the pinned
  backend's official prompt encoder; synthetic tiny-model fallback tokens are refused.
  Completed music and text-to-speech runs show A/B listening below the lettered-lane grid
  through `ComparisonListeningPanel`. One shared
  `AudioClipPlayer` owns input/output playback, pause/resume and seeking;
  switching models preserves elapsed time and clamps to a shorter clip's end.
  Run changes, leaving results and deactivating the Compare route stop playback.
  Missing clips are excluded; speech notes that words may not align at the same elapsed time.
  Speech retains `task-outcome-v1` ratings. Each music lane header carries its
  model's listening rating control; explicit 1–5 ratings persist
  as `music-listening-v1` reviews, separately from speed; quality champions
  require a complete, current cohort with every model reviewed under that rubric.
  Completed image-generation runs offer **Inspect images** and open generated-output
  thumbnails in `ImageComparisonSheet` (input thumbnails retain the single-image preview).
  Both panes select available outputs for one recorded prompt and share an
  `ImageInspectionViewport`: fit-relative zoom and normalized pan, clamped separately
  for each aspect ratio. Prompt changes reset the viewport; model switches retain it.
  Keyboard arrows pan the focused image. The viewer reuses `TaskQualityRating` and
  surfaces the coordinator's persistence error without changing review storage.
  Completed video-generation outputs open `VideoComparisonSheet`, with a single
  `VideoComparisonPlayer` owning both native AVPlayers. Loading validates duration,
  video tracks and readiness before shared playback can start. One host-clock start
  and elapsed-time seek align the clips; shorter clips clamp at their end, and
  generated motion need not match. Audio defaults off and can select only one clip.
  Prompt changes stop/reset; model changes preserve time and playback state.
  Dismissal releases players and observers, with generation guards fencing late
  async load/seek completion. Completed-output previews have no separate transport;
  video-understanding inputs retain their existing inline player. Ratings and
  persistence errors reuse the existing comparison flow.
  Run history uses a searchable popover grouped by mode, newest
  first within each group; selecting a row keeps the existing results behavior.
  Completed music runs with prompt snapshots offer **Reuse setup** beside history.
  `MusicComparisonSetup` copies recorded inputs into a temporary per-prompt editor;
  applying it never writes a preset or starts generation. The existing Run button
  starts fresh results with current model signatures and no copied quality reviews.
  Missing recorded models stay selected and block Run until explicitly replaced
  or removed; inventory refreshes must not silently clear a reused cohort.
  The reuse editor's **Save as prompt set…** writes a newly identified user prompt
  set through the existing prompt store, preserving per-prompt settings without
  model selections. Save failures keep the editor open and leave published prompt
  sets unchanged; saving never starts generation or overwrites the source preset.
  Saved user-created music prompt sets have a compact Edit/Rename/Remove menu beside
  the picker. Both actions recheck the persisted set and use `JSONStore.update`
  under its mutation lock; publication follows a successful atomic write.
  Built-in IDs, other modes, temporary setups and active comparisons are refused.
  Removal requires confirmation and changes only the prompt store; run snapshots,
  audio and quality reviews remain intact. Removing the selected set falls back
  to an available prompt set.
  `MusicPromptSetEdit` is a value-only draft of a saved set; shared `MusicPromptFields`
  and the reuse editor's validation preserve optional settings and unedited fields.
  Explicit Save keeps the set and prompt identities, checks the original snapshot
  against the current persisted set, and publishes only after a successful write.
  Opening or reopening an editor loads the current persisted set through the
  coordinator's explicit Edit action, outside view evaluation.
  Invalid, stale or failed edits keep the editor open; Cancel and opening an editor
  never write or generate audio. Historical snapshots and output files are untouched.
  **New set…** in music mode uses `MusicPromptSetDraft` and `MusicPromptFields`
  for the same per-prompt caption, lyrics, duration, steps and seed controls.
  New prompts start with explicit 15-second/30-step/seed-42 instrumental settings;
  clearing settings uses the existing optional-default semantics. Add/remove is
  draft-only, keeps stable prompt identities, and retains at least one prompt.
  Explicit Save validates all inputs and selects the set only after the existing
  prompt store accepts it. Invalid or failed saves keep the draft open; Cancel
  never writes or generates.
  Other modes use `ComparisonPromptSetDraft` + `ComparisonPromptSetEditor` for
  per-prompt text, input attachments, expected words and requested output tokens
  where supported, square image size/steps/seed, and video dimensions/frames/fps/
  steps/seed. Add/remove retains stable surviving prompt IDs and at least one
  prompt. All modes, including music creation, saved-set edits and run reuse,
  share the card action menu. It duplicates the current draft immediately after
  its source with a new UUID, preserving edited fields and hidden metadata.
  Move up/down reorders existing identities within bounds; neither operation
  writes state or starts generation. Explicit Save/Use applies that order;
  historical snapshots remain unchanged. Music saved-set validation accepts
  reordered and newly duplicated prompts, but rejects empty or repeated IDs;
  the durable original-snapshot check still rejects concurrent edits. A shared
  `PromptEntry` copy operation preserves hidden metadata under a new identity.
  Music Add/Remove controls also work in saved-set and reuse editors, through
  the same array operations as creation. Removal retains at least one prompt;
  new entries share the existing instrumental/15-second/30-step/seed-42
  defaults and require a valid caption before Save/Use. Reuse revalidates
  nonempty unique prompt identities after draft changes. Draft mutations never
  save state or generate audio, and surviving entries retain their identities.
  Drafts preserve unedited tool schemas, legacy mode/use-case metadata,
  optional fields and effective generation defaults; unreadable input files and
  invalid runtime parameter ranges are rejected at Save. Model-specific video
  alignment/frame grouping remain the engine's authority. The shared saved-set
  menu offers Edit/Rename/Remove in every mode, with built-in and active-run guards.
  Non-music draft validation also supplies a concise inline warning within each
  prompt card and disables Save/Use for invalid values in new, edited, copied
  and reused setups. View-time validation shares the entry rules but performs
  no file availability probes; Save/Use still recheck readable inputs. File
  availability warnings remain in the input section without duplicate warnings.
  Music uses the same card-level feedback through `MusicComparisonSetup.Prompt`
  entry validation. A shared music array validator rejects invalid identities
  and labels prompt errors by current position for creation, saved edits and
  reuse; draft errors do not also appear in a global banner. Name checks share
  the save rules, and creation/copy Save is disabled until the draft is valid.
  Both shared prompt field views use `ComparisonPromptList` to reveal newly
  inserted prompt identities after Add/Duplicate. Initial rendering and
  unchanged, reordered or removed identities do not request a scroll; normal
  draft editing remains value-only, with no saves or generation side effects.
  Customize copy opens `ComparisonPromptSetDraft(copying:)` or
  `MusicPromptSetDraft(copying:)` for the selected built-in/saved/temporary set,
  with a fresh set identity, copied use case and recorded prompt fields. Opening
  never writes; explicit Save uses existing creation paths and selects the new
  set only on success. Non-music media uses independent durable input copies;
  source-set ownership metadata is not inherited. Built-ins remain immutable,
  and the copy action is disabled during active comparisons or input saves.
  `ComparisonPromptSetPicker` replaces the flat set menu with a bounded popover
  over the existing mode-filtered sets. `ComparisonPromptSetPickerLogic` groups
  explicit temporary IDs first, then user-created sets and built-ins, retaining
  source order and distinct identities even for duplicate names. Search matches
  names, prompt text and tool names locally; rows show prompt counts and current
  selection. Search/clear/open never selects, writes or starts a comparison;
  only an explicit row action changes the selection and closes the popover.
  `createPromptSet`, `preparePromptSetEdit` and `savePromptSetEdits` use the existing
  prompt store and action-scoped errors. Edits recheck the original durable
  snapshot under `JSONStore.update` before publication; failure retains the draft.
  Current measurements, task tradeoffs and measured alternative selection require
  exact equality with the selected set's recorded prompt entries, not just its ID.
  Past runs, quality reviews and output artifacts remain historical evidence.
  **Reuse setup** in other modes uses `ComparisonRunSetup` and
  `ComparisonRunSetupSheet`, sharing `ComparisonPromptFields` with the regular
  editor. Only completed runs with valid recorded prompt/model identities can
  open it. Snapshots supply the prompts, per-prompt settings, use case and model
  paths; the current serving limits still apply. Runs with `inputArtifacts` use
  only their fenced saved inputs from the injected output store; unavailable
  copies require explicit replacement before Use/Save, never fallback to original
  files or fixture regeneration. Legacy runs retain current original paths or
  deferred built-in generation. Saved built-in speech copies preserve their
  language hint; replacing the input clears it. Run copies inputs before pruning
  the ten-run cache so reusing its oldest run does not delete the source first.
  Save creates an independent
  prompt-set identity through `createPromptSet`; failure retains the draft.
  Use restores a temporary set and model paths without writing or running.
  Missing models remain selected and block Run until replaced/removed. New runs
  capture current signatures and evidence; original results/reviews stay intact.
  Reuse-sheet Save runs `createPromptSetWithInputCopies` asynchronously. It copies
  explicit input files into `prompt-set-inputs/<uuid>/inputs/` beside the prompt-set
  JSON, then publishes the set only after its atomic JSON save succeeds.
  `PromptSet.inputStorageID` is optional for legacy compatibility; existing sets
  are not migrated. Built-in fixture IDs are preserved without generation, and
  file copies stay off the main actor. Copy/save failures discard only their new
  owned folder. The sheet blocks edits/dismissal during Save; the coordinator
  blocks Run and edit/rename/remove during copying. Successful removal considers
  only the removed set's owned/referenced UUID folders, retains other saved-set
  references from saved sets and an authoritative run-store read, and never sweeps staging
  folders or original files. Failed/unknown stores keep copies conservatively.
  Temporary setups retain the ten-run cache; newly saved copies are independent.
  New-set and saved-set editors use the same asynchronous input ownership path.
  `savePromptSetEditsWithInputCopies` keeps unchanged owned inputs, copies only
  external/replacement inputs, then checks `edit.original` against the durable
  set under `JSONStore.update` before publication. Failed/conflicting saves discard
  only their new folder. Successful edits reclaim old folders only when no saved
  set or legacy run references them. Settings-only edits do not copy owned files.
  Existing path-based sets are preserved on load and get owned copies when saved
  explicitly in the editor. Save blocks editor changes/dismissal until it finishes;
  built-in fixtures remain deferred and original source files stay untouched.
  `PromptEntry.inputName` optionally records a display-only source filename before
  owned copies change its path. Names survive save/reuse chains and settings-only
  edits; replacing the path clears the old name before the new copy captures it.
  Prompt cards, result-grid input labels and text A/B use `inputDisplayName`.
  Invalid names are ignored; legacy records fall back to their recorded path's
  basename without inventing an earlier name. Names never resolve paths or enter
  argv; missing saved copies remain unavailable even when their name is known.
  Shared prompt cards offer a collapsed `ComparisonPromptInputPreview` only for
  readable regular input files. Image previews reuse the thumbnail/larger sheet;
  audio previews share one `AudioClipPlayer` per editor with seek controls;
  video previews reuse `ClipVideoView` without autoplay. Collapsed previews do
  not instantiate media views, and no built-in fixtures are generated by editing.
  Collapse, replacement and removal stop the affected audio; editor dismissal
  stops its shared player, and video teardown pauses the native player.
  Non-music result lanes expose `TaskQualityRating`, a compact menu over the
  existing `task-outcome-v1` human rating scale. Per-mode guidance lives in help
  text; ratings never derive from speed, keywords or word-error rate.
  `ComparisonViewLogic.qualityReviewUnavailableReason` requires a completed,
  successful full prompt cohort and readable media outputs for new judgments.
  Saved ratings stay visible and clearable after media is pruned. Rating changes
  use `reviewQuality` without altering measured samples or prompt snapshots;
  failed writes retain published reviews and successful retries clear the error.
  Quality awards retain the existing all-entrants-reviewed, same-rubric,
  current-identity/environment guards and share ties.
- Python resolution is centralized in `Services/WorkbenchPython.swift`
  (env override → repo `.venv` → PATH) and shared by `CLIProcess`,
  `RuntimeChecker`, `LaunchAgentManager`, and the watch fingerprint probe.
  The repo is the build checkout (`#file`, compiled out of distribution
  builds) or, for installed builds, the checkout whose `vendor/mlx-agent` is
  the configured agent path. `RuntimeInstaller` runs `make install` in-app
  when the runtime is missing; `UpdateCoordinator` acts only on the build
  checkout.
  `CLIProcess` drains stdout/stderr on dedicated threads: blocking pipe reads
  must not depend on shared dispatch workers while a CLI caller waits for EOF.
  Each agent child leads its own process group (media backends stay in it);
  on timeout and on `NSApplication.willTerminateNotification`
  (`CLIProcessRegistry` tracks live children) the whole group gets SIGTERM,
  then SIGKILL after a 2 s grace, matching `bridge._kill_process_group`.
  Agent-detached work (`convert start` jobs, `serve`) uses its own session and
  is not stopped.
- **Never spawn a process synchronously inside view evaluation.** A
  `Process.waitUntilExit` reached from a view body/layout crashes the app
  (AttributeGraph precondition via re-entrant layout). The watch
  fingerprint probe answers from a prewarmed cache and degrades to
  "unknown" on the main thread instead of probing. Keep this invariant.
- **Hosted unit tests never start live services or touch real state.**
  `make test-swift` runs inside the app (TEST_HOST = mlx-workbench.app).
  `AppHost.startLiveServices()` (WindowGroup `onAppear`)
  owns all launch-time live work: quality-gate attach, watch and endpoint
  supervision, resource sampling, and the first scan with workflow
  reconciliation. It returns early when `XCTestConfigurationFilePath` is set,
  so the suite never starts or stops real servers. UI tests launch a separate
  app process without that variable and keep live behavior. Keep new
  launch-time live work behind this method. Default state locations resolve
  through `Services/WorkbenchStatePaths.swift`: in a hosted unit-test process
  Application Support, `config.json` and the web queue live under
  `WorkbenchStatePaths.hostedTestRoot`, which the test bundle's principal
  class (`HostedTestStateRoot`) replaces with a fresh temporary directory per
  test. New default state paths go through it.
- The Wire tab also does **Cross-client Wiring**: `WiringCoordinator` detects
  installed clients (opencode/Continue/Zed/Aider writable; LM Studio/Ollama
  advisory-only) and previews/confirms atomic writes to each client's own
  config with per-file backups, drift re-checks, and rollback. Client write
  targets are a fixed allowlist of well-known config paths.
  Model guidance's **Wire into clients** hands off a one-shot model/port
  request. Clients preselects only a matching running endpoint, supports repo
  and local-path identities, and preserves the complete served identity in
  generated client configs. Preview binds server identity; confirmation reads
  fresh authoritative status before any file write and refuses stopped,
  replaced or ambiguous servers. Existing config drift and rollback guards
  remain unchanged. Server refreshes run asynchronously on route activation.
- The Run tab hosts the **Always-on Endpoint**: `EndpointSupervisor` keeps a
  chosen verified model serving on a stable loopback port by reconciling
  desired state against authoritative serve status (crash-loop guarded;
  enable/swap require verified models unless explicitly overridden).
  Internally it is fleet-shaped (spec 09 P1): `EndpointFleetConfig` slots in
  `endpoint-fleet.json` (migrated one-time from the legacy
  `endpoint-config.json`, which stays read-only), one reconcile pass over
  all enabled slots, per-slot crash guards. The single-slot API is a shim
  over slot 0. The Run tab's **Endpoints** section (spec 09 P2) lists the
  slots with per-slot status/restarts/fit chip, enable/disable, role picker,
  remove,   and an "Add endpoint" flow (suggested next-free port, verified
  gating with explicit unverified override, cap 4). The menu bar aggregates
  ("N of M endpoints running", worst-state icon, per-slot start/stop).
  The **fleet memory budget** (spec 09 P3): `FleetFitAdvisor` sums
  FitAdvisor estimates over enabled slots that are not already resident
  against the shared monitor's `MemorySnapshot` (per-slot runtime overhead;
  unknown model sizes or unavailable memory make the verdict unknown, never
  fabricated). The section shows the summed verdict; enabling a slot that
  tips the fleet past won't-fit needs an explicit inline override.
  The **role router** (spec 09 P4): "Wire roles…" in the Endpoints section
  maps roles onto running slots via `mlx-agent fleet render/apply` with
  `--port-map` (mlx-agent ≥ the port-map change, cavi-ai/mlx-agent#41;
  the vendored pin includes it).
  Only running slots with HF-cache repo ids are assigned — everything else
  is reported skipped, never pointed at a dead port. The router config is
  written exclusively through `fleet apply` (preview/confirm + receipt), so
  the target file stays fleet-managed.
  `LaunchAgentManager` optionally installs a RunAtLoad login item (no
  KeepAlive — the app's supervisor reconciles; receipts stay authoritative).
- The Duplicates tab hosts the **Disk Pressure Advisor**: `ReclaimAdvisor`
  ranks reclaim opportunities (stale per `UsageTracker` evidence, superseded
  by comparable reviewed task evidence, cross-root duplicates) and `ReclaimCoordinator`
  applies them as batched quarantine moves via `Services/Quarantine.swift`
  (GGUF parity with `mlx_workbench/quarantine.py`, plus explicitly reviewed
  local MLX directories in the native app). Folder previews run off the main
  actor and freeze file identity, metadata, total bytes and a tree fingerprint.
  Confirm rechecks configured MLX roots, active/preferred paths and chain
  keepers. Folders require recognized MLX config/weights, no symlinks,
  hard-linked/shared files or HF cache layout, and same-volume quarantine.
  Configured roots themselves cannot move. Folder ledger records carry optional
  `kind: "mlxDirectory"`; legacy GGUF records omit it. The web keeps folder
  records visible but delegates restore/Trash to the native app. Task-scoped replacement chains
  select a terminal keeper within one reviewed comparison or matched workflow
  cohort; they remain advisory and protect their keepers from stale-file advice.
  Quarantine offers native macOS Trash after preview; confirm rechecks file
  identity, size, timestamps, ledger membership and the configured quarantine
  fence. It refuses links and never falls back to permanent deletion. Successful
  Trash moves preserve ledger history with the web-compatible `deleted_at`
  field. Quarantine and Trash retain disk usage until Trash is emptied.
- Compare defaults distinguish intentional serving (`UsageStamp.lastServedAt`)
  from verification/benchmark activity. New comparison runs snapshot prompts
  and can persist explicit human task-outcome reviews. Current recommendations
  require matching model signatures and environment fingerprints; task-scoped
  supersession additionally needs comparable reviewed quality and no adverse
  speed, latency, estimated-memory or disk trade-off. Quantization bits alone
  never establish supersession, and task-scoped suggestions are review-only.
- Workflow evidence is an explicit local JSON interchange (`WorkflowReport`,
  schema 1), persisted separately in `workflow-evidence.json`. It is not an
  automatic Claude/OpenClaw/OpenCode log reader. Native Compare can copy/save
  a `WorkflowCaptureRequest` for a selected harness and ready local model;
  it captures identity context only, with null required run measurements in
  `reportDraft`. After successful client wiring, `WiredWorkflowCapture` rechecks
  the reviewed server and matches one ready local model before prefilling the
  request with loopback endpoint and successful client IDs. Rolled-back or
  unwritten transactions and ambiguous local revisions are refused. This is
  config-write context, never proof a task used the endpoint; wiring time/ID
  never substitute for measurement time/run source. The Clients handoff opens
  Compare's shared import review through a one-shot route intent consumed only
  when Compare is active. A request cannot import as evidence. Report files are read and
  decoded off the main actor; imports preview exact new/duplicate observations
  and model/environment status before confirmation. Confirmation refuses
  changed saved evidence and preserves historical observations without
  relabeling them. Preserve producer provenance,
  timestamps, model/environment/configuration identity, seconds/bytes units,
  and unknown metrics. Never stamp imported observations as current or attribute
  unattributed time to GPU/disk without measurements. Resource captures run
  outside view evaluation; exports preserve their capture time and context.
  Native Compare shows workflow runtime, timing-breakdown, task-quality and
  recorded peak-memory charts above setup through a compact metric menu,
  using `AgentTaskAdvisor` identity/cohort checks. The latest observation per model
  is charted only when comparable; missing components render a total-duration
  "Breakdown unknown" bar, never inferred GPU/disk time. Zero measured durations
  remain zero; unattributed time is derived only from complete additive timings.
  Quality requires a shared cohort rubric. Metric values bind to the exact
  selected report ID and context; unknown scores/memory are labeled rather than
  charted as zero. Peak memory uses recorded bytes in decimal GB and shows the
  report's capture date, never live fit estimates or an older-report fallback.
  The Quality vs runtime scatter plot pairs score and total runtime from that
  same report and rubric. Point selection (or the model menu for overlapping
  points) shows recorded memory/date. Use model opens the existing role/endpoint
  review with fresh identity, evidence and headroom checks; selection never applies it.
  "Compare these models" re-checks the cohort against current identities and
  inventory at click time, loads only ready models for the selected mode, and
  keeps the prompt set. It never starts a run or replays the external harness.
  Active comparisons and cohorts above the existing four-slot limit block the
  action; there is no silent truncation or unmeasured model fallback.
  `AgentTaskAdvisor` adds optional structured `taskGuidance` to schema-1
  agent exports (old exports decode without it). It ranks only within the
  newest complete comparison run or matched harness/workload/configuration/
  sample-count workflow cohort, with shared rubrics required for quality.
  Quality, performance, latency and estimated fit stay separate and ties stay
  shared. A newer unreviewed or mismatched observation never falls back to an
  older winner. Quality-first fit choices exclude tight/unknown fits; the
  native guidance sheet and export refresh headroom outside view evaluation.
  Exports remain advisory. The native **Use model** action reviews a serving
  model's role preference and optional slot-0 endpoint change, refreshing
  inventory, environment and headroom at review and confirm. Changed model
  identity or cohort evidence blocks the action; ties remain explicit choices.
  Preferences persist before in-memory publication. Endpoint changes require
  verification and an estimated fit, retain the reviewed port, and reuse the
  supervisor's serve boundary. Context is an estimate only; wiring and reclaim
  remain separate actions. Endpoint errors after a saved preference are
  reported as partial outcomes.
- `ModelDetailsView` hosts the **Model Lineage**: `LineageIndexer` assembles
  a read-only provenance timeline per model (source, converted, verified,
  benchmarked, served, wired, quarantined) from the stores the app already
  keeps, with signature-based staleness dimming and Markdown/JSON export.
- `WatchCoordinator` provides **Watch & Regression Alerts**: upstream
  `mlx-agent watch diff` digests (baseline established silently on first
  check; network failures stay silent) and macOS/MLX environment-drift
  alerts offering one-click re-verification of stale verified models.
  Alerts dedupe by fingerprint and persist snooze/mute state.
- **Completion notifications**: `ModelWorkflowCoordinator.onTerminalState`
  fires once when a workflow enters a terminal state (completed / verified /
  verificationFailed / failed) and AppHost wires it to `AlertNotifier`
  (Notification Center; silent when permission is denied). Restores and
  launch-loads never notify — only live transitions.
- `SetupCoordinator` provides the **first-launch Setup Assistant**: a guided
  sheet over the app's existing probes (agent health, runtime report,
  discovered roots) with the RuntimeInstaller for one-click runtime setup.
  Persisted via UserDefaults once completed; re-openable from Health.
- `UpdateCoordinator` provides **in-app updates** for checkout-run installs:
  Official channel checks out the newest `v*` tag, Beta fast-forwards to
  `origin/main`; both refuse a dirty tree, sync submodules, and finish with a
  streamed `make build-swift` rebuild-and-relaunch. Git runs as argv tokens
  through an injectable runner; the apply path is integration-tested against
  a throwaway git repo. Installed builds (no checkout) update from GitHub
  releases instead (`Services/ReleaseUpdater.swift`): Releases reads
  `releases/latest` (`mlx-workbench-<version>.dmg`), Nightly reads the rolling
  `nightly` prerelease (`mlx-workbench-nightly-<commit>.dmg`), compared with
  Info.plist `MLXWorkbenchCommit`/`MLXWorkbenchChannel`. Install requires the
  GitHub sha256 digest, a read-only mount, and the code requirement
  `identifier com.cavi.mlxworkbench`, team `Y76GMV87GM`, `notarized`; the
  swap is `replaceItemAt` beside the bundle and the old bundle goes to the
  Trash. Translocated, disk-image and unwritable locations are refused.
  Nightlies build only on manual dispatch and skip when `mlx-mac/`,
  `vendor/mlx-agent` and the `Makefile` are unchanged since the published one.
  `.github/workflows/signed-dmg.yml` publishes both DMGs with an App Store
  Connect API key (`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` secrets).
- The Run view shows a **Memory-fit Advisor** verdict before serving as a
  memory runway: `FitAdvisor` estimates weights + KV cache + runtime overhead
  against the shared monitor's live available memory, with resident models
  drawn inside the in-use span, yielding fits/tight/won't-fit with a suggested
  max context (the toolbar's context option). Image, speech and other
  non-servable models get no verdict and no serve actions; unavailable memory
  is unknown. Run's refresh only reads `serve status`. Verdicts are derived,
  never persisted.
- The native toolbar shares `SystemResourceMonitor`: Mach memory estimates
  refresh off-main every five seconds; unavailable readings remain unknown.
  Its popover fetches authoritative serving status while open and exposes
  Unload through `EndpointSupervisor.unloadServer`. JIT unload checks fresh
  process identity, refuses active requests, releases the owned worker, and
  confirms the same gateway remains running with an unloaded model. Desired
  endpoint state stays enabled. Eager Stop server persists disabled desired
  state before stopping; save/stop failures remain visible. Comparison and
  verification models are protected. The context selector feeds workflow
  model-fit reviews, not server configuration.
- **Load on request**: new native endpoint slots default to JIT; old slots
  lacking `loadOnRequest` retain eager behavior. Changing mode explicitly
  restarts the endpoint. The vendored agent's `serve start --jit` launches a
  loopback gateway with an authenticated control channel and one owned worker.
  `/v1/models` stays reachable while unloaded; inference starts the worker
  against the confirmed absolute local model path with offline HF settings.
  File identity is checked before and after loading; changed files require a
  fresh plan. Concurrent cold requests share one load; streamed responses hold
  an active lease that blocks unload. `serve unload --expected-pid` retains
  the gateway, while `serve stop` terminates its owned process group. Status
  exposes model residency separately from gateway liveness. JIT with direct
  `--launchd` is refused; native supervision owns the lifecycle. Comparison
  and verification continue to use eager serving.
- **JIT memory management**: `EndpointSlot.memoryPolicy` is optional for legacy
  fleets. New JIT slots use a 600-second idle timeout and a 2 GB reserve;
  legacy slots preserve their old policy until explicitly configured. Run's
  compact controls apply receipt/PID-bound `serve policy` updates without
  restarting the gateway. Desired policy saves before live application; failures
  remain visible and reconciliation retries the desired policy. The engine owns
  the idle timer, so it works for harness requests without the app open. Idle
  time starts when the final inference lease ends; keep-loaded prevents automatic
  unload after use but permits manual unload. Cold-load admission uses fresh
  OS headroom against local weight bytes × 1.10 + 1.5 GB runtime allowance +
  configured reserve (decimal GB). Unknown headroom/weights blocks a guarded
  load. This is an estimate, not a reservation across endpoints or a bound on
  subsequent KV growth. Policies persist atomically in private gateway config;
  invalid updates and save failures leave the active policy unchanged.
- `.run/`, `.venv/`, and `convert-queue.json` are generated/runtime state and
  are not source of truth.

## Fast onboarding (for a new agent)

- `make install` installs the required Python 3.12 environment and converter libs.
- `make start` runs the UI on `127.0.0.1:8765` and writes PID/logs to `.run/`.
- `make run` runs foreground.
- `make status`, `make stop`, `make open` are standard operations.
- `make test` and `python3 -m unittest discover -s tests -t .` run unit tests.
- `make accept-native-gguf` is excluded from normal tests and requires an
  explicit runtime manifest because it may perform a real conversion.
- `make docs-test` and `make docs-verify` run documentation contract checks.

## Ingest/pipeline behavior to respect

- Conversion plans are always previewed first.
- Only one conversion runs at a time.
- Confirmed jobs are written to a durable queue before launch.
- Queue entries are FIFO and auto-drain; they resume on restart.
- Actual running state is recovered from mlx-agent receipts (queue state is never the
  only authority).
- Queue state defaults to `$XDG_STATE_HOME/mlx-workbench/convert-queue.json`
  with fallback to `~/.local/state/mlx-workbench/convert-queue.json`.

## Security and boundaries

- UI binds loopback only; non-loopback hosts are rejected.
- Job arguments are argv tokens (no shell string execution).
- Quarantine operations are constrained to configured model roots: `.gguf`
  files in both interfaces, explicitly previewed independent MLX folders in
  the native app. The web UI can also purge quarantined GGUF files to the macOS Trash
  (`quarantine.purge`: fenced to existing files inside the quarantine dir,
  ledger entries marked `deleted_at`, never the ledger itself, symlink
  refused, audited as `quarantine.delete`).
- Hardened response surface: CSP with `frame-ancestors 'none'`, `form-action`,
  `base-uri`, `X-Frame-Options: DENY`, and a `Server:` header without the
  Python version (`mlx_workbench/server.py`). Concurrent requests are capped
  by a bounded semaphore (503 when exhausted); see `test_hardening.py`.
- Durable state files (`config.json`, `convert-queue.json`) are written via
  `mlx_workbench/atomicio.py`: fsync-before-replace plus directory fsync, and
  every write refuses symbolic links at the target or temp path. The
  quarantine guard additionally refuses symlinked sources and symlinked
  quarantine directories; the Swift `WiringCoordinator` refuses symlinked
  client configs, backup paths, and restore targets, `JSONStore` refuses a
  symlinked store file, and Swift `Quarantine` mirrors the Python guards
  (source, quarantine dir, and restore target).
- Agent subprocesses run with `start_new_session=True`; on timeout the whole
  process group is terminated then killed (`bridge._kill_process_group`), and
  the child environment is an allowlist (`bridge.agent_environment`), never
  the web server's full environment. Malformed request bodies (type-confused
  JSON, control characters in path fields, oversized/undecodable payloads)
  are refused with classified 4xx envelopes (`tests/test_hardening.py`
  adversarial route tests); oversized bodies are drained so clients can read
  the reply.
- The config key universe is closed (`config._ALLOWED_KEYS` = known web
  fields + `config._FOREIGN_KEYS` native premium keys): unknown keys are
  rejected on load and refused on save, so neither frontend can smuggle
  arbitrary fields into the shared `config.json`.
- Every state-changing web operation (config save, convert submit, queue
  cancel/clear/retry/move, serve start/stop, quarantine move) appends a line
  to a local audit trail via `mlx_workbench/audit.py`
  (`$XDG_STATE_HOME/mlx-workbench/audit.jsonl`, bounded, best-effort —
  durable stores stay authoritative).
- `/api/scan` is served through a stale-while-revalidate cache
  (`Application.cached_scan`): the first scan populates it, later calls
  return the snapshot instantly with `cached`/`stale` flags and refresh in
  the background; `?refresh=1` scans synchronously. The web UI additionally
  keeps the last inventory in `localStorage` so reloads never render empty.
- Convert/serve Python deps are pinned in `requirements.txt` (exact
  versions); `make install` installs from it and `make pip-audit` checks the
  runtime against the OSV database — both in local runs and as PR gates
  (`.github/workflows/pr.yml`). The transformers 4.x pin is required by
  mlx-lm's GGUF→HF path and is a tracked, accepted risk (known advisories
  without a 4.x fix; see `PIP_AUDIT_IGNORES` in the Makefile).
- Optional converter backends (mlx-vlm, mlx-audio) are isolated venvs created by mlx-agent from
  hash-locked requirement files; `make pip-audit` audits every lock. Intake never executes a
  repository's custom code and never passes `--trust-remote-code`.

## Review/build guidance for an agent

- Prefer project-local inspection first, keep edits scoped.
- Update this file when execution/integration behavior changes so it continues to
  match the README and docs.
- Do not invent cross-repo semantics for conversion/receipt behavior; state
  comes from observed implementation and tests.
