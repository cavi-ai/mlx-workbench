# Quickstart

Open **MLX Workbench** from Applications, or build and open the source
checkout with `make start`.

1. In **Settings**, confirm the engine checkout, model roots, output path,
   and quarantine path. Installed DMG builds need an explicit engine checkout;
   source builds can discover `vendor/mlx-agent`.
2. Inspect local GGUF and MLX weights in **Library**. **Discover** searches
   Hugging Face Hub. **Add from Hugging Face** previews downloads separately
   from conversion.
3. In **Prepare**, review the conversion plan, destination, and source-cleanup
   choice before confirming. **Activity** shows the job and log.
4. In **Run**, preview and start a compatible model's loopback endpoint.
   **Clients** previews configuration changes for local tools.
5. In **Compare**, choose compatible models and a prompt set, run a measured
   comparison, and review recorded outputs. Speed alone is not a quality
   verdict or permission to remove another model.

Conversions with a supported canary must pass verification before being
marked verified. Other tasks retain their own behavior; speculative
drafters are never served.

Quit through the application menu. Running model endpoints have their own
Stop controls; inspect Run and Activity before leaving work active.
