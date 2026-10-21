# Reclaim

**Reclaim** frees disk space without guessing. It leads with a ledger of space to review, space in quarantine and space in the Trash, with unknown sizes labeled. Every move is previewed, rechecked at confirmation and reversible until you empty the Trash.

## What it suggests

**Analyze** ranks reclaim opportunities from evidence the app already holds:

The scan status and **Scan coverage** show the folders checked by the last successful scan. **Review scan folders…** opens Settings; add the shared model folder there and rescan if it is absent. Connecting Ollama, LM Studio, ComfyUI or another host does not add its server-side folders to the local disk scan. The scan compares GGUF files and recognized MLX folders, and includes Ollama stores beneath those roots. Standalone model assets, including ComfyUI checkpoints, are not compared.

Folder copies that need a separate review remain visible in the headline as an item count instead of zero bytes. **Review folder…** beside a matching local MLX copy opens its guarded preview. Scan-reported copy sizes are logical file sizes, not guaranteed physical disk savings; shared files and filesystem storage sharing can change the space released. Failed or missing scans are labeled, and retained results remain tied to their previous coverage and date.

| Opportunity | Evidence |
|---|---|
| Stale | No recorded use for the **Stale after** period (default 60 days, **Settings → Advisors**) |
| Superseded | A replacement with comparable reviewed task quality and no worse speed, latency, estimated memory or disk use |
| Duplicate | The same GGUF file, or an MLX model folder with identical weights, in more than one place |

**Duplicate groups** at the end of the page list every group from the latest scan, including one model kept at several quantizations (GGUF quantizations or MLX bit widths). Those groups are informational: choosing which copy to keep is yours. When one identical MLX copy is in the Hugging Face cache, that copy is kept and the other is reviewed with **Review model folder…**. Models in an Ollama store under your scan roots are included; an Ollama copy is always the one kept, since only Ollama removes its files.

Quantization bits alone never establish that one model supersedes another. Replacement chains pick a keeper within one reviewed comparison or matched conversion cohort; suggestions stay advisory and keepers are protected from stale-file advice. Intentional serving counts as use; verification and benchmark runs do not.

## Quarantine

**Preview reclaim** lists the files a batch would move and their total size. **Confirm quarantine** moves them into the quarantine directory (**Settings → Storage**). **Put back** restores a quarantined item to its original path.

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
