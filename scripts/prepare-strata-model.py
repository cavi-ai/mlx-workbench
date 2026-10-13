#!/usr/bin/env python3
"""Prepare a local Strata model profile from an existing supported GGUF pair; never fetch weights."""

import argparse
import json
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "vendor/mlx-agent/src"))
from mlx_agent.strata_runtime import MODEL_MARKER, installed_runtime, read_model


def values(field):
    return [field.parts[index] for index in field.data]


def strings(field):
    return [part.tobytes().decode("utf-8") for part in values(field)]


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
    from gguf import GGUFReader
    reader = GGUFReader(str(first), "r")
    architecture = strings(reader.fields["general.architecture"])[0]
    if architecture != "qwen4exp":
        parser.error("Only Qwen3.8-Flash-Next is supported")
    vocabulary = strings(reader.fields["tokenizer.ggml.tokens"])
    merges = strings(reader.fields["tokenizer.ggml.merges"])
    types = [int(part.item()) for part in values(reader.fields["tokenizer.ggml.token_type"])]
    template = strings(reader.fields["tokenizer.chat_template"])[0]
    if len(vocabulary) != 248320 or len(types) != len(vocabulary) or len(set(vocabulary)) != len(vocabulary):
        parser.error("The GGUF tokenizer is incomplete or incompatible")
    tokenizer = root / "tokenizer"
    tokenizer.mkdir(exist_ok=False)
    (tokenizer / "vocab.json").write_text(json.dumps({token: index for index, token in enumerate(vocabulary)}, ensure_ascii=False), encoding="utf-8")
    (tokenizer / "merges.txt").write_text("\n".join(merges) + "\n", encoding="utf-8")
    (tokenizer / "token_type.json").write_text(json.dumps(types), encoding="utf-8")
    (tokenizer / "chat_template.jinja").write_text(template, encoding="utf-8")
    profile = {"schema_version": 1, "gguf": str(first.relative_to(root)), "mtp": str(mtp.relative_to(root)) if mtp else None}
    (root / MODEL_MARKER).write_text(json.dumps(profile, indent=2) + "\n", encoding="utf-8")
    (root / "config.json").write_text(json.dumps({"model_type": "qwen4_exp", "serving_runtime": "strata"}, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(read_model(root), indent=2))


if __name__ == "__main__":
    main()
