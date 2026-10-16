# Training and studies

Text LoRA training records local job receipts and adapter outputs. Controlled studies and retained training evaluations use the engine's experiment store, which needs `requirements-lab.txt`. `make install` installs the training runtime and study dependencies.

## Text LoRA training

**Training** fine-tunes a LoRA adapter on your own text.

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

Preview the evaluation prompt before **Run comparison**. Editing it invalidates the preview and clears the displayed outputs. A new preview clears older confirmation and results before the request begins, including when the new request fails. The prompt and dismissal controls are locked while a request runs. Only paired outputs with a retained report hash are displayed as a completed comparison; failed requests remain retryable.

## Controlled studies

**Studies**, in the Lab sidebar group, runs A/B experiments that change one variable at a time and reviews the outputs blind. **Compare → Open Studies** opens the same workspace. Returning to Studies refreshes its experiment and adaptive-study lists; navigating does not create or run an experiment.

1. **Install study tools** once. **Install video runtime** adds the optional Torch runtime for video generation.
2. **New experiment…**: start from a frozen recipe from the engine and choose the variable to change (inference steps, guidance or seed). **Validate pair**, then **Create experiment**. Model and runtime identities stay attached to both candidates.
3. Run the queued generation jobs. Artifacts are stored durably and integrity-checked.
4. **Blind review…** plays both clips with shared play, pause, seeking and frame controls, without showing which candidate is which. Scores and preferences become immutable receipts before the assignment is revealed.

Adaptive studies keep their progression and stopping evidence. **Recover interrupted jobs** reconciles jobs after a crash.

## Workspaces

Experiments live in `~/Library/Application Support/mlx-agent/lab` by default. **Workspace…** previews adopting the existing experiment database and artifact store into a new destination. Adoption preserves IDs, hashes, reviews and sealed assignments, refuses active work or an occupied destination, and leaves the source untouched. **Import workspace…** brings in an existing workspace.
