# Reclaim

**Disk space** frees disk space without guessing. **Models** shows this Mac's load, what to remove and why, and where the disk under your scan folders goes. **Quarantine & cleanup** holds suggestions, the quarantine, the Trash and cleanup history. Every move is previewed, rechecked at confirmation and reversible until you empty the Trash.

## Models

**This Mac** shows free memory, free space on the first scanned volume, processor load across its cores and swap in use, read again every ten seconds. Each loaded local model follows with the memory it holds: the MLX allocator's memory in use, cache and peak when its worker reports them, else the provider's figure, else its process memory. The MLX cache is memory a worker keeps for reuse after a request. **Release cache…** on an idle load-on-request task worker reviews the release, returns those buffers to the system and reads status afterwards; the model stays loaded. Runtimes without cache control do not offer it.

**Suggested removals** names what to remove, why, and the exact space each frees, identical copies first and then the largest saving:

| Suggestion | Evidence |
|---|---|
| Identical copies | The scan found the same weights in more than one place; the copy it keeps stays |
| Other versions | You chose a version to keep; review the other versions before removing them |
| Choose a version | Several versions need review; compare their capabilities and quality before choosing |

Usage age and file modification dates never affect removal suggestions. Serving, preferred and in-use models are protected. Discovery skips a historical registered service location that no longer exists; unavailable explicit or live locations still block removal until ownership can be checked. **Review…** opens the removal review for that suggestion.

The header counts every file under the scanned folders once: the total on disk, the part held by recognized models, and that part by store (folders, the Hugging Face cache and Ollama). Hard links and blobs shared between Ollama tags or cache revisions are counted once. The remainder is listed by the folders and files that hold it, largest first, with **Reveal** to open each in Finder. Those bytes belong to no model the scan recognizes; they can be unsupported model formats as well as leftovers.

The table has one row per model. Versions of a model share its architecture (layer count, hidden width and attention heads) and its name without format and quantization labels, across MLX folders, GGUF files, Hugging Face cache snapshots and Ollama tags. Fine-tunes and named variants of one base model are separate rows, and embedding and classification models are never grouped with generators of the same architecture. Every column sorts. **Show** narrows the table to models stored more than once, models not used recently, models with identical weights in two places, or every model (the default). **Not used recently** is an informational filter based on recorded Workbench use and **Stale after**; it does not suggest removal.

Expand a row to see its versions. A version is marked **Keep** only with evidence: one that is serving or preferred, or the one you mark with **Keep**. **Could free** is the space released by keeping that version, or the largest when none is marked, and removing the others: a file still used by a version that stays, such as an Ollama blob shared with another tag, is not counted. Serving, preferred and in-use versions show a lock and cannot be selected.

Select versions, or **Select extra versions**, then **Review removal…**. The review lists how each copy leaves the disk and skips copies a guard refuses, with the reason:

Before removal, Workbench checks current serving ownership. If a local source cannot be checked, the removal message names the source and its error; resolve it in Serving and retry. Disk inventory remains available while removal is paused.

| Copy | Removal |
|---|---|
| GGUF file | Its GGUF files, including split shards and projectors, move to quarantine; notes beside them stay |
| MLX folder | The folder moves to quarantine under the folder rules below |
| Hugging Face cache snapshot | The whole cache repository moves to the macOS Trash, with every revision in it |
| Ollama tag | The manifest and the blobs no other tag references move to quarantine together; **Put back** restores both |

Quarantined copies still occupy disk until you move them to the Trash and empty it. The bar under the table shows what quarantine holds and opens **Quarantine & cleanup**.

## Compare standalone model files

**Compare model files** reads independent same-size standalone files in full and groups matching SHA-256 digests. It may take time for large files; **Cancel comparison** stops the check and keeps the previous scan. Model-owned files, provider stores, symlinks, shard-pattern files and files with multiple hard links are excluded. Missing files, changed folders and incomplete checks remain visible; they do not establish that no other copies exist.

A verified group keeps the file named in the review. Choose **Keep** on another matching copy to retain it instead. **Review removal…** shows both the file to move and a retained match. Update other apps to use the kept path and confirm that you checked their model paths before removing the copy. Workbench cannot determine every external reference. Confirmation rechecks both files and their complete digests, and moves the selected file into same-volume Quarantine. It does not edit app configuration. The kept file remains in place, and **Put back** restores a quarantined file if its original location is free.

## What it suggests

**Analyze** ranks reclaim opportunities from evidence the app already holds:

The scan status and **Scan coverage** show the folders checked by the last successful scan. **Review scan folders…** opens Settings; add the shared model folder there and rescan if it is absent. Connecting Ollama, LM Studio, ComfyUI or another host does not add its server-side folders to the local disk scan. The scan inventories GGUF files, recognized MLX folders, Ollama stores and standalone `.safetensors` and `.ckpt` files beneath those roots. Standalone files are not compared until you choose **Compare model files** in Models.

Folder copies that need a separate review remain visible in the headline as an item count instead of zero bytes. **Review folder…** beside a matching local MLX copy opens its guarded preview. Scan-reported copy sizes are logical file sizes, not guaranteed physical disk savings; shared files and filesystem storage sharing can change the space released. Failed or missing scans are labeled, and retained results remain tied to their previous coverage and date.

| Opportunity | Evidence |
|---|---|
| Superseded | A replacement with comparable reviewed task quality and no worse speed, latency, estimated memory or disk use |
| Duplicate | The same GGUF file, or an MLX model folder with identical weights, in more than one place |

**Duplicate groups** at the end of the page list every group from the latest scan, including one model kept at several quantizations (GGUF quantizations or MLX bit widths). Those groups are informational: choosing which copy to keep is yours. When one identical MLX copy is in the Hugging Face cache, that copy is kept and the other is reviewed with **Review model folder…**. Models in an Ollama store under your scan roots are included; these suggestions always keep the Ollama copy, and **Models** removes Ollama tags.

Quantization bits alone never establish that one model supersedes another. Replacement chains pick a keeper within one reviewed comparison or matched conversion cohort; suggestions stay advisory and keepers remain protected.

## Review related variants

**Which variants should I keep?** groups related model names for review, including
quantizations and named tuning variants. These groups suggest candidates to
compare; they do not prove identical weights or interchangeable behavior.

**Copy model review JSON** copies the current inventory, protections and available assessed comparison evidence for review. Missing ratings or measurements remain unknown. The export does not start inference or remove models.

Expand a group to see each variant's size, quantization, serving selection,
preferred roles and current task-specific replacement evidence. **Keep for a
purpose…** records why a model deserves a place, such as abliterated writing, a
coding fine-tune or a lower-memory fallback. Saved purposes protect models from
cleanup, including after their identity changes. **Edit keep reason…** updates or
clears that protection. Purpose-bearing single models remain listed; saved reasons
for models absent from the current scan can also be cleared. Unreadable purpose
storage blocks cleanup, and purpose changes wait for active cleanup to finish.

Select two to four ready variants and choose **Prepare showdown…**. Compare opens
with those exact models; selecting them starts no inference. Choose prompts that
exercise the intended use, run the comparison and rate each model's task quality.
For larger groups, compare a retained contender against the remaining variants in
another explicit run. Separate runs do not become one combined ranking.

After a completed chat showdown, the family review shows the latest completed
run for each prompt set. Each card keeps that run's task ratings, recorded median
decode rates, first-token times and model sizes together. Quality and speed leaders
are separate, and ties stay shared. Different leaders can explain keeping one
variant for quality and another for speed. Variants absent from that run remain
explicitly untested there; results from separate runs are never combined into a
single ranking. Model size comes from the current Library scan and does not
establish memory use or physical space freed.

Every entrant needs current identity and environment evidence, finished outputs
and a task-quality rating before leaders are named. A changed or missing prompt
set makes the verdict unavailable. Missing per-prompt timing withholds a speed
leader or replacement advice; estimated rates retain their label. **Rate quality
in Compare…** or **Review saved outputs…** opens the named saved run, including
when Compare was left in a media mode. This reads saved results and starts no
inference. Active work or an open editor keeps the navigation request pending.

Replacement advice requires current model and environment identities, the same
complete prompt cohort, timing for every prompt and reviewed quality for every entrant. Truncated or reasoning-only answers
cannot support chat replacement advice. A model can remain useful for another
task even when a peer beats it here. **Review removal…** on an evidenced candidate
opens Library's existing removal preview; confirmation moves it to macOS Trash.
For a Hugging Face cache entry, that preview names the entire repository and all
included revisions. No showdown automatically removes model files.

## Quarantine

**Preview reclaim** lists the files a batch would move and their total size. **Confirm quarantine** moves them into the quarantine directory (**Settings → Storage**). **Put back** restores a quarantined item to its original path.

Batch quarantine shows progress while filesystem work runs in the background. A move is successful only after its recovery record is saved; if that write fails, Workbench puts the model back and reports the failure. If the original location cannot be restored, the error includes the quarantine path for recovery.

GGUF files can be quarantined directly. A local MLX folder needs **Review model folder…** first: the preview freezes the folder's path, file count, size and a tree fingerprint, and confirmation rechecks all of them. Folders must hold a recognized MLX config and weights, sit on the same volume as quarantine, and contain only independent regular files. These are refused:

- Folders with symbolic links, hard-linked or shared files, or a Hugging Face cache layout
- Configured roots themselves
- Active or preferred models, duplicate keepers and replacement-chain keepers

## Trash

**Move to Trash** sends a quarantined item to the macOS Trash after its own preview. Confirmation rechecks file identity, size, timestamps, ledger membership and the quarantine fence. Links are refused, and there is never a fallback to permanent deletion. The ledger keeps the history. Disk space is freed only when you empty the Trash in Finder.

## Original sources after verification

After a conversion is verified, its source can go to the Trash. **Review originals** lists eligible items from verified receipts: receipt-owned GGUF files, or Hugging Face cache repositories with a single revision. Changed outputs, active or preferred models, other revisions and blobs still shared with another model across your roots are protected. **Move originals to Trash** moves only what the review showed, and **Cleanup history** records each batch.

**Restore originals** previews the exact original destinations, rechecks the Trash and your configured roots, and refuses conflicts or drift. Existing files are never overwritten. Cache blobs are restored before cache folders.

## Hugging Face cache

**Check HF cache** runs the engine's read-only model doctor scan and lists incomplete Hugging Face cache entries with their size. **Preview prune** asks the engine for a prune plan and its preview hash; **Confirm prune** runs that plan only while the hash still matches.
