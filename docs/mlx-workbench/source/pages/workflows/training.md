# Training and studies

Text LoRA training records local job receipts and adapter outputs. Controlled studies and retained training evaluations use the engine's experiment store, which needs `requirements-lab.txt`. `make install` installs the training runtime and study dependencies.

## Text LoRA training

**Training** fine-tunes a LoRA adapter on your own text.

**Check setup** inspects the local training executable, cached base architecture,
and both dataset splits independently. Each split shows its example count or an
actionable error, including the file and line for malformed records. A valid
split keeps its count when another check fails. **Fix field** returns to the
relevant input; a missing runtime offers **Open Health**.

Checking setup never downloads a model, splits data, creates an adapter or starts
training. It checks executable availability without loading the model; it does
not measure memory fit or guarantee that training will succeed. Editing the
request clears the report. **Preview Training** and confirmation still recheck
the inputs independently; inspection does not authorize a training run.

1. Choose a **Base model** from the cached language-model candidates or enter a **Custom repo id…**. Known speech, media, embedding and drafter entries are omitted from the picker; legacy entries without task metadata remain candidates. Preview checks the cached architecture against the MLX-LM registry, including supported aliases. Some vision-language bases have an MLX-LM text loader and remain candidates. Other backend loaders cannot be substituted for text LoRA. Training requires a local Hugging Face cache snapshot and the mlx-lm training runtime; it never downloads a model.
2. Choose a **Dataset path**: a directory containing both `train.jsonl` and `valid.jsonl`. Each line is one JSON object with nonempty `text` or a `messages` array of objects with string `role` and `content`. Blank lines are refused. Supply training and validation examples separately; the app does not split or duplicate your data.
3. Set **Iterations**, **Batch size** (1–64, default 4) and an optional output directory. Each dataset split must contain at least one full batch. Preview rejects missing validation data or too few examples before starting a job; reduce batch size or add examples, then preview again. Invalid fields offer **Fix field**.
4. **Preview Training** captures the request as a training plan. Review the reported adapter output directory, dataset example counts and cached base path. If the preview reports a missing base snapshot, confirmation is disabled: cache the model, then preview again. Older previews may not report these fields. Editing any input invalidates the preview.
5. **Confirm & Train** submits the job; it appears under **Training jobs** and in Activity.

Leave **Output** blank to use a fresh folder under
`~/Library/Application Support/mlx-workbench/trained-adapters/`. The preview shows
the chosen destination, and confirmation uses that path. An explicit output
path is preserved. Preview does not create the adapter folder or start training.

Each run pins the cached base model, copies the reviewed dataset bytes, records the actual process result and verifies the adapter content. **Open log** and **Inspect** show a job's details; failed jobs can be retried.

**Use in Run** stages a completed job's recorded base and adapter in
[Run](run.md#serve-a-trained-adapter). It does not start inference. Preview and
confirmation recheck the artifacts before starting an explicit adapter server.

**Compare with base** runs a matched evaluation of the base model against base plus the trained adapter on the same prompts. Results are retained under **Retained training evaluations** with their SHA-256. Evaluations are comparison evidence, not a quality verdict, and text LoRA results do not qualify media training.

Choose **Single prompt** and a token limit, or capture an existing chat prompt set.
Sets are managed in **Compare**, support 1–16 text-only prompts and 1–512 tokens
per prompt, and exclude tools, media and expected-word scoring. Prompt text,
order, identities and token limits are frozen for the evaluation; later edits to
the source set do not change it. Choose evaluation prompts kept separate from
training data; the app does not check that separation.

**Preview** captures the recipe before **Run comparison**. Editing an input
invalidates it and clears displayed outputs. Each variant loads once for the
suite, uses temperature zero, and resets seed 42 for every prompt. Results are
accepted only when every prompt has both outputs and the pinned inputs still
match. The prompt picker shows each recorded pair and its token limit.

Record **Base model**, **Trained adapter**, **Tie** or **Neither**, with optional
notes, then **Save review**. Each preference is tied to the retained report hash;
reviews do not rewrite the frozen generation report or mark an adapter verified.
Failed saves retain the outputs and draft. Prompt switches retain unsaved review
drafts; closing requires explicit discard when any remain. Setup changes and
generation are blocked until those drafts are saved. Requests lock dismissal.

History shows suite names and prompt counts for new evaluations. **Inspect**
verifies the retained artifact; **Review outputs** reopens its recorded pairs
and saved preferences without generating again. Legacy single-prompt evaluations
remain readable and reviewable when their recorded schema and identity support it.

## Controlled studies

**Studies**, in the Lab sidebar group, runs A/B experiments that change one variable at a time and reviews the outputs blind. **Compare → Open Studies** opens the same workspace. Returning to Studies refreshes its experiment and adaptive-study lists; navigating does not create or run an experiment.

1. **Install study tools** once. **Install video runtime** adds the optional Torch runtime for video generation.
2. **New experiment… → Cached model**: choose an existing cached revision of **Wan 2.1 T2V 1.3B (Diffusers/MPS)**, enter a prompt and baseline settings, then **Capture recipe**. The engine checks the cached pipeline, assets and weight shards and records content hashes, installed runtime versions and platform identity. Capture never downloads weights or loads a model. Missing weights or runtime dependencies block capture; **Refresh availability** checks again after setup. MLX video conversions are a different format and cannot substitute for these Diffusers weights.
3. Choose the variable to change (inference steps, guidance or seed) and its alternate value. **Validate pair**, then **Create experiment** queues two jobs. Editing a captured baseline requires another capture; editing the pair requires validation again. **Recipe file** preserves importing an existing frozen recipe. Model and runtime identities stay attached to both candidates.
4. Run the queued generation jobs explicitly. Captured recipes recheck model assets, weights, runtime versions and platform before loading and after generation. Changed identities require a new recipe. Artifacts are stored durably and integrity-checked. Capture and validation alone do not prove that generation will succeed or assess output quality.
5. **Blind review…** plays both clips with shared play, pause, seeking and frame controls, without showing which candidate is which. Scores and preferences become immutable receipts before the assignment is revealed.

Adaptive studies keep their progression and stopping evidence. **Recover interrupted jobs** reconciles jobs after a crash.

## Workspaces

Experiments live in `~/Library/Application Support/mlx-agent/lab` by default. **Workspace…** previews adopting the existing experiment database and artifact store into a new destination. Adoption preserves IDs, hashes, reviews and sealed assignments, refuses active work or an occupied destination, and leaves the source untouched. **Import workspace…** brings in an existing workspace.
