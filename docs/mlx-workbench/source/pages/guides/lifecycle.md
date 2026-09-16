# Model lifecycle

MLX Workbench groups the lifecycle into focused tabs while MLX Agent remains
the authority for discovery, conversion, serving, and job receipts.

| Tab | Purpose |
| --- | --- |
| **Models** | Scan configured roots for GGUF and MLX weights and select conversion inputs. |
| **Convert** | Preview a local GGUF or Hugging Face cache conversion before confirming it. |
| **Duplicates** | Compare exact and variant groups and move a selected GGUF into quarantine. |
| **Scout** | Discover Hugging Face Hub candidates for a role. |
| **Doctor** | Inspect model health and incomplete cache state. |
| **Serve** | Preview, start, inspect, and stop loopback MLX servers. |
| **Training Studio** | Preview and run LoRA training or fuse work. |
| **Compare Conversions** | Preview quantization plans for a local GGUF across target formats. |
| **Model Arch** | Show the scan-reported architecture metadata for one local GGUF. |
| **Jobs** | Inspect MLX Agent receipts, log tails, and the workbench conversion queue. |
| **Settings** | Configure paths, quantization, signatures, host, and port. |

Every conversion is previewed before confirmation. Confirmed conversions are
persisted before launch in `convert-queue.json`; only one is started at a time.
After launch, MLX Agent receipts are authoritative. A workbench restart reloads
queued items and reconciles launched work from those receipts.

Converting from the local Hugging Face cache does not download missing model
data. Discovery, doctor, and other Hub-backed commands can use the
network and may require Hugging Face Hub credentials.
