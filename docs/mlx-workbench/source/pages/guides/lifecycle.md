# Model lifecycle

MLX Workbench groups the lifecycle into focused tabs while MLX Agent remains
the authority for discovery, conversion, serving, wiring, and job receipts.

| Tab | Purpose |
| --- | --- |
| **Models** | Scan configured roots for GGUF and MLX weights and select conversion inputs. |
| **Convert** | Preview a local GGUF or Hugging Face cache conversion before confirming it. |
| **Duplicates** | Compare exact and variant groups and move a selected GGUF into quarantine. |
| **Scout** | Discover Hugging Face Hub candidates for a role. |
| **Adopt** | Run the durable discover, verify, and recommend handoff. |
| **Wire** | Preview and apply an MLX routing configuration transaction. |
| **Doctor** | Inspect model health and incomplete cache state. |
| **Serve** | Preview, start, inspect, and stop loopback MLX servers. |
| **Train** | Preview and run LoRA training or fuse work. |
| **Jobs** | Inspect MLX Agent receipts, log tails, and the workbench conversion queue. |
| **Advanced** | Send explicit argv tokens to `scripts/mlx-agent`; the workbench adds `--json`. |
| **Settings** | Configure paths, quantization, signatures, host, and port. |

Every conversion is previewed before confirmation. Confirmed conversions are
persisted before launch in `convert-queue.json`; only one is started at a time.
After launch, MLX Agent receipts are authoritative. A workbench restart reloads
queued items and reconciles launched work from those receipts.

Converting from the local Hugging Face cache does not download missing model
data. Discovery, adoption, doctor, and other Hub-backed commands can use the
network and may require Hugging Face Hub credentials.
