# Training and studies

Training and controlled studies run on the engine's shared experiment store, which needs the engine's `requirements-lab.txt`. `make install` installs it.

## Text LoRA training

**Training** fine-tunes a LoRA adapter on your own text.

1. Choose a **Base model** from your cached models or enter a **Custom repo id…**.
2. Choose a **Dataset**: a complete, bounded JSONL file. The dataset is validated before a plan is offered.
3. Set **Iterations** and an optional output directory. Invalid fields offer **Fix field**.
4. **Preview** captures the exact request as a training plan. Editing any input invalidates the preview.
5. **Confirm & Train** submits the job; it appears under **Training jobs** and in Activity.

Each run pins the cached base model, copies the reviewed dataset bytes, records the actual process result and verifies the adapter content. **Open log** and **Inspect** show a job's details; failed jobs can be retried.

**Compare with base** runs a matched evaluation of the base model against base plus the trained adapter on the same prompts. Results are retained under **Retained training evaluations** with their SHA-256. Evaluations are comparison evidence, not a quality verdict, and text LoRA results do not qualify media training.

## Controlled studies

**Compare → Controlled studies** runs A/B experiments that change one variable at a time and reviews the outputs blind.

1. **Install study tools** once. **Install video runtime** adds the optional Torch runtime for video generation.
2. **New experiment…**: start from a frozen recipe from the engine and choose the variable to change (inference steps, guidance or seed). **Validate pair**, then **Create experiment**. Model and runtime identities stay attached to both candidates.
3. Run the queued generation jobs. Artifacts are stored durably and integrity-checked.
4. **Blind review…** plays both clips with shared play, pause, seeking and frame controls, without showing which candidate is which. Scores and preferences become immutable receipts before the assignment is revealed.

Adaptive studies keep their progression and stopping evidence. **Recover interrupted jobs** reconciles jobs after a crash.

## Workspaces

Experiments live in `~/Library/Application Support/mlx-agent/lab` by default. **Workspace…** previews adopting the existing experiment database and artifact store into a new destination. Adoption preserves IDs, hashes, reviews and sealed assignments, refuses active work or an occupied destination, and leaves the source untouched. **Import workspace…** brings in an existing workspace.
