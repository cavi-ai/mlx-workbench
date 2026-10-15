# Prepare and verify

**Prepare** turns local source weights into an MLX model. Every conversion is previewed before it runs, and supported task types are verified before they are marked ready.

## Preview a conversion

1. Choose a source: from Library (**Prepare to run**), LM Studio, the Add from Hugging Face window, or **Choose in Library**.
2. Pick a quantization width. Each tile shows the output size and fit on this Mac above a Source-to-Ready pipeline track. The default width comes from **Settings → Conversion defaults**.
3. **Preview conversion** asks the engine for a plan: the exact command, output path and a preview hash. Choosing a different width re-targets the destination.
4. Choose whether to move the original source to the Trash after verification. The choice you see is the one recorded.
5. **Confirm conversion** runs exactly the reviewed plan.

Prepare follows the job while it runs: a progress ring tracks bytes written against the intake estimate (indeterminate while the converter loads), and the job log sits in a collapsible section. Only one conversion runs at a time.

## The quality gate

After a fresh scan confirms the output, the conversion quality gate runs the canary for the model's task type:

| Task type | Canary |
|---|---|
| Text LLM, vision-language | Served on a temporary loopback port; answers canary prompts |
| Speech-to-text | Transcribes a sentence synthesized with `say`; passes at 25% word error or less |
| Classification | Answers a billing ticket that must route to billing and read as a refund request |
| Image generation | Renders a fixed prompt at 512×512 and must write a non-blank image |

A pass marks the workflow **verified** only after its report is saved; a failure marks it **verification failed**. If the report cannot be saved, the output remains complete but unverified, the storage error is shown and no new verdict is published. Resolve the storage problem before retrying verification. **Keep anyway** also requires its override to be saved before changing the workflow. Task types without a canary complete without one. Turn the gate off in **Settings → Advisors → Verify conversions**.

A notification announces each terminal state: completed, verified, verification failed or failed. Restoring state at launch never notifies.

## Activity

**Activity** shows conversion, server, experiment and training jobs on a timeline grouped by day. Each conversion has a stage track, its state and one action.

- Confirmed conversions are written to a durable queue before launch and drain first in, first out.
- Actual running state comes from engine receipts, never from the queue alone.
- **Run next** reconciles receipts and starts one pending item when compute is free.
- **Retry** reuses the reviewed plan. Moving a queued item with ↑ and ↓ does not approve a new plan.
- Failed launches keep their error and remediation.

The engine owns the shared conversion queue. **Import existing queue** adopts a `convert-queue.json` from an earlier Workbench installation; stop the former server first. Import preserves the source file and an exact backup, and refuses invalid state.

## Clean up the source

A verified conversion can reclaim the files it was made from. Prepare's **Preview source cleanup** and Reclaim's **Original sources after verification** list eligible originals: receipt-owned GGUF files, or Hugging Face cache repositories with a single revision. Changed outputs, active or preferred models, other revisions and blobs shared with other models are protected. **Move originals to Trash** moves only what the preview showed. See [Reclaim](reclaim.md) for restore.

## Run from Prepare

A verified chat or vision-language model offers **Run model**. Choosing it opens Run with that model selected and leaves the conversion record unchanged. Non-servable task types do not offer Run.
