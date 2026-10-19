# Compare

**Compare** measures ready models against the same prompts on this Mac and keeps every output, so you judge quality from what the models produced and speed from what was measured. **Open Studies** opens the separate [controlled studies](training.md#controlled-studies) workspace in the Lab sidebar group.

When the selected mode has no results, setup comes first, followed by compact history and empty-state guidance. Existing results remain above setup when a run is available.

## Run a comparison

1. Choose a mode. The picker is segmented when it fits and a menu otherwise.
2. Fill up to four model slots. Each slot lists only ready models whose task type and runtime support the mode.
3. Choose a prompt set.
4. **Run comparison**. A setup message names whatever blocks the run: a pending prompt-set save, a missing or empty prompt set, no model selected, or the first unavailable slot.

Models run one at a time. Chat serves each model on a loopback server, warms it up, replays the prompts and stops it before the next model; warm-up output is excluded from results. Other modes run each model per prompt through the engine's `convert describe`, `transcribe`, `speak`, `music`, `generate` or `video` commands.

From **Library**, **Select for Compare** opens the model's supported mode with that model in lane A. Lane B waits for your selection; **Run comparison** starts the work. Vision-language models open Chat by default; choose Vision or Video understanding for media input. Strata is text-only and is excluded from both media-input modes. If a comparison, save, editor or profile verification is in progress, finish it and choose **Use selected Library model** to apply the pending selection.

### Cancel and recover cleanup

**Cancel comparison** stops the run's owned chat request/server or media subprocess group, retains recorded samples and skips remaining prompts and models. Run stays blocked until the worker and cleanup return. Server startup may need to finish before its receipt can be stopped. Failed server cleanup offers **Retry cleanup**.

**Activity** also shows the active comparison's prompt set, mode and progress, with the same **Cancel comparison** or **Retry cleanup** action. **Open Compare** returns to its setup and recorded results. Unavailable saved comparison state appears there with its storage error; settled comparisons leave no empty card.

Confirmed chat-server ownership is saved before warm-up or measured prompts. Unresolved cleanup survives restart and blocks new comparisons until explicit **Retry cleanup** checks the original server's receipt and process identity. Changed ownership is not stopped; an already-exited original needs no signal. The cleanup record clears only after a successful durable save. Unreadable comparison state blocks new runs, and failed ownership saves stop before inference.

Cancelled runs and runs interrupted by an app restart remain explicit in history and do not supply completed-run recommendations, champions or winner promotion. An interrupted run with no recorded completion time keeps that time unavailable.

## Modes

| Mode | Accepts | Input | Output | Lane metric |
|---|---|---|---|---|
| Chat | Text LLM, vision-language | Text | Text | Decode speed (tok/s) |
| Vision | Vision-language | Image | Text | Generation speed (tok/s) |
| Video understanding | Vision-language | Video | Text | Generation speed (tok/s) |
| Speech to text | Speech-to-text | Audio | Text, scored by word error rate | Real-time factor |
| Text to speech | Text-to-speech | Text | Audio | Real-time factor |
| Music generation | Music generation | Caption, lyrics, duration, steps, seed | Audio | Real-time factor |
| Image generation | Image generation | Prompt, size, steps, seed | Image | Seconds per step |
| Video generation | Video generation | Prompt, size, frames, frame rate, steps, seed | Video | Seconds per frame |

Prompts can carry an expected-words check (all must appear, case-insensitive; `a|b` accepts either). Speech to text scores against a reference transcript. Built-in media inputs are generated at run time: images and video with CoreGraphics and AVFoundation, speech with `say`. The repository holds no binary fixtures.

## Results

Chat results use a model-by-prompt outcome matrix beside a reading inspector. Each cell records **Finished**, **Token limit**, **Incomplete**, **Blocked**, **Unknown**, **Not recorded** or **Waiting** from the saved evidence. Missing finish reasons remain unknown even when text is available. Median decode speed stays secondary and includes recorded incomplete outputs; completion does not establish answer quality. A model’s information button retains runtime, startup, prefill estimates and profile actions.

Select a prompt heading or an outcome cell to inspect its recorded outputs. Selecting another model replaces the first inspected model; a model already in the pair keeps its position. Each output heading can change its model, swapping the pair when necessary to keep distinct identities. The inspector separates the current prompt outcome from whole-run coverage and retains recorded lane letters, full text, original-output copying and bounded line differences. Previous/Next changes only the inspected prompt. Wide windows stack both outputs; narrow windows collapse the matrix behind **Models in this run** and offer **Read left** / **Read right** for one readable output. Quality ratings remain human judgments across the entire run.

Fenced code uses monospaced formatting. Reasoning, including recorded inline `<think>` sections, and available measurements sit behind **Reasoning and measurements**. Copy copies the original text and differences compare that original text. Reading, selecting or switching never rewrites a saved run.

**Reasoning and measurements** retains per-prompt speed, first token, answer-start timing, duration, tokens and tool-call counts when recorded. First token may include reasoning. Answer-start timing is unavailable when inline reasoning makes that boundary ambiguous. Missing completion and timing evidence stays unknown. Tool-only prompts require a recorded tool-call finish and valid arguments for every emitted call to count as finished.

Media results retain one lettered lane per model, with the mode’s primary metric and a relative bar, followed by one row per prompt and one column per lane for text, images, audio or video.

New streamed inline reasoning is separated before recording. Decode speed is omitted when tokens arrive in a single burst, since arrival timing cannot establish generation speed.

## Inspect outputs side by side

| Completed run | Inspector |
|---|---|
| Chat | Visible A/B reader with prompt navigation, full recorded responses and line differences |
| Vision, video understanding, speech to text | **Compare text · A/B**: read two models' recorded responses for one prompt, or highlight line differences |
| Music, text to speech | A/B listening: one player, pause and scrub; switching models keeps the elapsed time |
| Image generation | **Inspect images**: two outputs with linked zoom and pan; arrow keys pan the focused image |
| Video generation | **Inspect videos**: two clips on one elapsed-time control; audio off by default, one clip at a time when on |

Shorter clips hold at their end. Missing outputs are excluded and labeled.

## Rate quality

Each lane has a **Rate quality** menu with a 1–5 task-outcome rating; music lanes carry a 1–5 listening rating instead. Ratings are human judgments, stored separately from speed and automated checks. A new rating needs a completed run with every output available; saved ratings stay visible after media is pruned and can be cleared.

A quality champion needs every model in the run reviewed under the same rubric; ties are shared. A current champion also needs matching model identities and environment.

## Prompt sets

The prompt-set picker opens a searchable list grouped into temporary setups, saved sets and built-ins, with prompt counts. Searching matches names, prompt text and tool names and never changes the selection. The menu beside it holds:

- **New set…** and **Edit…**: per-prompt cards with the mode's settings, Add prompt, Duplicate, Move up and Move down, Revert prompt and a confirmed remove. A warning inside each card names invalid values, and **Fix prompt N** jumps to the first one. Save stays disabled until the draft is valid and changed.
- **Customize copy…**: a new, independent set from any built-in or saved set.
- **Rename…** and **Remove…**: saved user sets only. Removal changes no past run.
- **Import OpenCode prompts**: imported prompts become selectable once the set is saved.

Cancel on an edited draft offers **Keep editing** or **Discard changes**. Saving copies picked input files into the set's own storage, so a saved set survives output pruning and never changes your original files.

**Reuse setup** on a completed run copies its prompts, settings and model selections into a temporary editor. **Use setup** restores them to Compare; **Save as prompt set…** saves an independent copy. Models no longer available stay selected and block the run until replaced or removed.

## Storage and retention

Outputs are saved to `~/Library/Application Support/mlx-workbench/comparison-outputs/<run-id>/`. New media runs first save one copy of each input. When a media run starts, the output folders of all but the 10 newest media runs are removed; run records are kept and a missing file shows as **output pruned**. History is a searchable popover grouped by mode.

[Library music tasks](library.md#classification-and-music-tasks) generate audio
with one model and retain their inputs and outputs in the engine's task store.
Their Recent tasks list is separate from comparison history and its ten-run
media retention. Task completion supplies no listening rating or comparison
winner; use Compare to judge models against matching prompts.

## Act on the result

- **Use model A…** (using the eligible model’s lane letter) requires a completed chat run, a positive finite speed and a finished outcome for every recorded prompt in the selected model’s cohort. Legacy runs without recorded prompt coverage cannot qualify. The action saves the winner as the preferred model for its use case and can enable or swap the always-on endpoint, keeping verified gating. Wiring and reclaim keep their own previews.
- Measured chat speed feeds the recommendation engine as local benchmark evidence. Media runs do not.
- Measurements count as current only when the selected prompt set still matches the recorded prompts exactly.

## Workflow evidence

**Import workflow report…** reads `WorkflowReport` JSON files (schema 1) recorded by an external harness. Imports preview new and duplicate observations and model and environment status before you confirm. Charts above the setup show runtime, timing breakdown, task quality and recorded peak memory for comparable observations; a **Quality vs runtime** scatter pairs score and runtime from the same report. Missing timings show as **Breakdown unknown**, never inferred.

From the charts, **Compare these models** loads the cohort's ready models into the current mode without starting a run, and **Use model…** opens a review of the role preference and optional endpoint change. Exports carry the measurements and machine context for an agent; they are advisory.

## Strata lanes

A prepared Strata model can run in two lanes with different speculation, expert-memory and context settings, and **Find best settings…** prepares a four-lane settings search. See [Strata](strata.md).
