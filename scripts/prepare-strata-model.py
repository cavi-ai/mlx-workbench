#!/usr/bin/env python3
"""Prepare a local Strata model profile from an existing supported GGUF pair; never fetch weights."""

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "vendor/mlx-agent/src"))
from mlx_agent.strata_runtime import MODEL_MARKER, installed_runtime, read_model


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gguf", type=Path, required=True, help="first shard of a tested local Q2_0 or IQ3_S pair")
    parser.add_argument("--out", type=Path, required=True, help="model directory containing the GGUF pair")
    parser.add_argument("--mtp", type=Path, help="complete locally fetched MTP head beneath --out")
    args = parser.parse_args()
    root = args.out.expanduser().absolute()
    first = args.gguf.expanduser().absolute()
    if root.is_symlink() or first.is_symlink() or not first.resolve().is_relative_to(root.resolve()):
        parser.error("The existing GGUF pair must be inside the profile directory, without links")
    if (root / "config.json").exists() or (root / MODEL_MARKER).exists():
        parser.error("A model config already exists; preparation never overwrites an existing model")
    runtime = installed_runtime()
    if args.mtp:
        mtp = args.mtp.expanduser().absolute()
        if not mtp.resolve().is_relative_to(root.resolve()):
            parser.error("The MTP head must be inside the model directory")
        subprocess.run([runtime["python"], str(Path(runtime["root"]) / "engine/tools/mtp_fetch.py"), "verify", "--out", str(mtp)], check=True)
    else:
        mtp = None
    # Strata's Q2_0 blocks are not recognized by the generic gguf package.
    # Use the pinned engine's read-only metadata parser, without loading tensors.
    sys.path.insert(0, str(Path(runtime["root"]) / "engine"))
    from strata_mlx.gguf import GGUF
    reader = GGUF(str(first))
    metadata = reader.meta
    architecture = metadata["general.architecture"]
    if architecture != "qwen4exp":
        parser.error("Only Qwen3.8-Flash-Next is supported")
    vocabulary = metadata["tokenizer.ggml.tokens"]
    merges = metadata["tokenizer.ggml.merges"]
    types = metadata["tokenizer.ggml.token_type"]
    template = metadata["tokenizer.chat_template"]
    if len(vocabulary) != 248320 or len(types) != len(vocabulary) or len(set(vocabulary)) != len(vocabulary):
        parser.error("The GGUF tokenizer is incomplete or incompatible")
    tokenizer = root / "tokenizer"
    tokenizer.mkdir(exist_ok=False)
    profile = {"schema_version": 1, "gguf": str(first.relative_to(root)), "mtp": str(mtp.relative_to(root)) if mtp else None}
    created = []
    try:
        (tokenizer / "vocab.json").write_text(json.dumps({token: index for index, token in enumerate(vocabulary)}, ensure_ascii=False), encoding="utf-8")
        (tokenizer / "merges.txt").write_text("\n".join(merges), encoding="utf-8")
        (tokenizer / "token_type.json").write_text(json.dumps(types), encoding="utf-8")
        (tokenizer / "chat_template.jinja").write_text(template, encoding="utf-8")
        for name, value in (("config.json", {"model_type": "qwen4_exp", "serving_runtime": "strata"}), (MODEL_MARKER, profile)):
            with (root / name).open("x", encoding="utf-8") as handle:
                created.append(root / name)
                handle.write(json.dumps(value, indent=2) + "\n")
        result = read_model(root)
    except Exception:
        for location in created:
            location.unlink()
        shutil.rmtree(tokenizer)
        raise
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
