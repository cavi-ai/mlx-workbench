"""Build and verify the source payload used by guided runtime setup."""

import argparse
import ast
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import tempfile


REQUIRED = {"Makefile", "requirements.txt", "LICENSE", "mlx_workbench/__init__.py",
            "mlx_workbench/config.py", "mlx_workbench/deps.py", "vendor/mlx-agent/LICENSE",
            "vendor/mlx-agent/scripts/mlx-agent", "vendor/mlx-agent/src/mlx_agent/__init__.py"}


def safe_path(root, name):
    if not isinstance(name, str):
        raise ValueError("Invalid bundle path")
    parts = PurePosixPath(name).parts
    if not parts or name != "/".join(parts) or any(p.startswith(".") for p in parts) or "\\" in name:
        raise ValueError("Invalid bundle path")
    if PurePosixPath(name).is_absolute():
        raise ValueError("Absolute bundle path")
    path = Path(root)
    if path.is_symlink():
        raise ValueError("Bundle directory is a symbolic link")
    for part in parts:
        path = path / part
        if path.is_symlink():
            raise ValueError("Bundle contains a symbolic link")
    return path


def manifest_data(root):
    path = safe_path(root, "manifest.json")
    if not path.is_file() or path.stat().st_size > 4 * 1024 * 1024:
        raise ValueError("Runtime bundle manifest is missing or too large")
    data = path.read_bytes()
    manifest = json.loads(data)
    if manifest.get("schema") != 1 or not re.fullmatch(r"[0-9a-f]{40}", manifest.get("engine_revision", "")):
        raise ValueError("Unsupported runtime bundle identity")
    files = manifest.get("files")
    if not isinstance(files, list) or not 1 <= len(files) <= 10000:
        raise ValueError("Invalid runtime bundle file list")
    names = [f.get("path") for f in files if isinstance(f, dict)]
    if len(names) != len(files) or not all(isinstance(n, str) for n in names) or len(set(names)) != len(names):
        raise ValueError("Invalid or duplicate runtime bundle paths")
    if not REQUIRED.issubset(names):
        raise ValueError("Runtime bundle is missing required sources")
    total = 0
    for record in files:
        safe_path(root, record["path"])
        if not re.fullmatch(r"[0-9a-f]{64}", record.get("sha256", "")):
            raise ValueError("Invalid runtime source digest")
        size = record.get("size")
        if type(size) is not int or not 0 <= size <= 128 * 1024 * 1024 or type(record.get("executable")) is not bool:
            raise ValueError("Invalid runtime source metadata")
        total += size
    if total > 256 * 1024 * 1024:
        raise ValueError("Runtime source bundle is too large")
    return manifest, data


def verify_bundle(root):
    manifest, _ = manifest_data(root)
    for record in manifest["files"]:
        path = safe_path(root, record["path"])
        if not path.is_file() or path.stat().st_size != record["size"]:
            raise ValueError("Runtime source is missing or changed: " + record["path"])
        if hashlib.sha256(path.read_bytes()).hexdigest() != record["sha256"]:
            raise ValueError("Runtime source digest differs: " + record["path"])
    return manifest


def resolve_bundle(root):
    root = Path(root)
    if (root / "manifest.json").is_file():
        verify_bundle(root)
        return root
    pointer = json.loads(safe_path(root, "current.json").read_text())
    identity = pointer.get("identity", "")
    if pointer.get("schema") != 1 or not re.fullmatch(r"[0-9a-f]{64}", identity):
        raise ValueError("Invalid runtime bundle pointer")
    selected = safe_path(root, identity)
    verify_bundle(selected)
    if hashlib.sha256((selected / "manifest.json").read_bytes()).hexdigest() != identity:
        raise ValueError("Runtime bundle identity differs")
    return selected


def create_bundle(root, output, files, engine_revision):
    root, output = Path(root), Path(output)
    paths = sorted(set(files))
    if not REQUIRED.issubset(paths):
        raise ValueError("Runtime bundle is missing required sources")
    entries = []
    for name in paths:
        source = safe_path(root, name)
        if not source.is_file():
            raise ValueError("Runtime source is missing: " + name)
        if source.stat().st_size > 128 * 1024 * 1024:
            raise ValueError("Runtime source is too large: " + name)
        entries.append({"path": name, "sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                        "size": source.stat().st_size, "executable": bool(source.stat().st_mode & stat.S_IXUSR)})
    version = None
    for node in ast.parse((root / "mlx_workbench/__init__.py").read_text()).body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "__version__" for t in node.targets):
            version = ast.literal_eval(node.value)
    if not isinstance(version, str) or not version:
        raise ValueError("Workbench version is missing")
    data = (json.dumps({"schema": 1, "engine_revision": engine_revision, "workbench_version": version,
                        "files": entries}, indent=2, sort_keys=True) + "\n").encode()
    identity = hashlib.sha256(data).hexdigest()
    if output.is_symlink():
        raise ValueError("Runtime bundle output is a symbolic link")
    output.mkdir(parents=True, exist_ok=True)
    target = output / identity
    if target.exists() or target.is_symlink():
        verify_bundle(target)
        if (target / "manifest.json").read_bytes() != data:
            raise ValueError("Existing runtime bundle differs")
    else:
        with tempfile.TemporaryDirectory(prefix="runtime-", dir=output) as temporary:
            stage = Path(temporary) / "payload"
            stage.mkdir()
            for entry in entries:
                destination = stage / entry["path"]
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(safe_path(root, entry["path"]), destination)
                destination.chmod(0o755 if entry["executable"] else 0o644)
            (stage / "manifest.json").write_bytes(data)
            verify_bundle(stage)
            stage.rename(target)
    with tempfile.NamedTemporaryFile(mode="w", dir=output, delete=False) as handle:
        json.dump({"schema": 1, "identity": identity}, handle)
        pointer = Path(handle.name)
    try:
        os.replace(pointer, output / "current.json")
    finally:
        pointer.unlink(missing_ok=True)
    return target


def tracked_sources(root):
    def git(path, *args):
        return subprocess.check_output(["git", "-C", str(path), *args])
    engine = root / "vendor/mlx-agent"
    revision = git(engine, "rev-parse", "HEAD").decode().strip()
    indexed = git(root, "ls-files", "--stage", "vendor/mlx-agent").decode().split()
    if len(indexed) < 2 or indexed[1] != revision:
        raise ValueError("The engine checkout does not match the pinned submodule")
    scopes = ["src", "scripts/mlx-agent", "requirements-lab.txt", "requirements-lab-inference.txt", "LICENSE"]
    subprocess.run(["git", "-C", str(engine), "diff", "--exit-code", "HEAD", "--", *scopes], check=True)
    outer = git(root, "ls-files", "-z", "Makefile", "requirements.txt", "LICENSE", "mlx_workbench")
    inner = git(engine, "ls-files", "-z", *scopes)
    files = [os.fsdecode(p) for p in outer.split(b"\0") if p]
    files += ["vendor/mlx-agent/" + os.fsdecode(p) for p in inner.split(b"\0") if p]
    return files, revision


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("create", "copy"))
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--source", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.operation == "create":
        files, revision = tracked_sources(args.repo)
        print(create_bundle(args.repo, args.output, files, revision))
        (args.output / "inputs.xcfilelist").write_text(str(args.output.resolve()) + "\n")
    else:
        source = resolve_bundle(args.source)
        if args.output.exists():
            verify_bundle(args.output)
            shutil.rmtree(args.output)
        shutil.copytree(source, args.output)
        verify_bundle(args.output)


if __name__ == "__main__":
    main()
