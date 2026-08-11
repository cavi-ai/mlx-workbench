import hashlib
import json
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
VERSION = "0.1.0"
TAG = "v0.1.0"
SLUG = "mlx-workbench"
REPOSITORY = "cavi-ai/mlx-workbench"
COMMIT = "0123456789abcdef0123456789abcdef01234567"
EPOCH = "1700000000"


def run_node(script, *arguments, check=True):
    return subprocess.run(
        ["node", str(ROOT / script), *map(str, arguments)],
        cwd=ROOT,
        check=check,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def tree_digest(root):
    digest = hashlib.sha256()
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        relative = path.relative_to(root).as_posix()
        digest.update(relative.encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def content_digest(root):
    digest = hashlib.sha256()
    for path in sorted(
        item for item in root.rglob("*")
        if item.is_file() and item.name != "manifest.json"
    ):
        relative = path.relative_to(root).as_posix()
        digest.update(relative.encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


class ReleaseDocsContractTests(unittest.TestCase):
    def test_portable_path_order_is_not_locale_sensitive(self):
        program = """
          import { comparePortablePaths } from './scripts/docs/lib.mjs';
          const values = ['z.md', 'ä.md', 'Z.md', 'a.md'];
          process.stdout.write(JSON.stringify(values.sort(comparePortablePaths)));
        """
        result = subprocess.run(
            ["node", "--input-type=module", "--eval", program],
            cwd=ROOT,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertEqual(json.loads(result.stdout), ["Z.md", "a.md", "z.md", "ä.md"])

    def test_documentation_make_targets_are_phony(self):
        result = subprocess.run(
            ["make", "-pRrn", "-f", str(ROOT / "Makefile"), "help"],
            cwd=ROOT,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        declaration = next(
            line for line in result.stdout.splitlines() if line.startswith(".PHONY:")
        )
        targets = set(declaration.split(":", 1)[1].split())
        self.assertTrue(
            {"docs-test", "docs-build", "docs-verify", "docs-release"} <= targets
        )

    def test_release_identity_comes_from_package_version(self):
        program = """
          import {
            DOCUMENTED_VERSION, PRODUCT_ID, RELEASE_REPOSITORY,
            resolveReleaseIdentity
          } from './scripts/docs/lib.mjs';
          const release = resolveReleaseIdentity({
            version: '0.1.0', tag: 'v0.1.0',
            commit: '0123456789abcdef0123456789abcdef01234567',
            sourceDateEpoch: 1700000000
          });
          process.stdout.write(JSON.stringify({
            version: DOCUMENTED_VERSION, slug: PRODUCT_ID,
            repository: RELEASE_REPOSITORY, tag: release.tag
          }));
        """
        result = subprocess.run(
            ["node", "--input-type=module", "--eval", program],
            cwd=ROOT,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertEqual(
            json.loads(result.stdout),
            {
                "version": VERSION,
                "tag": TAG,
                "slug": SLUG,
                "repository": REPOSITORY,
            },
        )

    def test_navigation_references_existing_source_pages(self):
        source = ROOT / "docs" / SLUG / "source"
        navigation = json.loads((source / "navigation.json").read_text())
        paths = [
            page["path"]
            for section in navigation["sections"]
            for page in section["pages"]
        ]
        self.assertEqual(len(paths), 8)
        self.assertEqual(len(paths), len(set(paths)))
        self.assertTrue(all((source / "pages" / path).is_file() for path in paths))

    def test_build_is_stamped_complete_and_byte_reproducible(self):
        with tempfile.TemporaryDirectory() as temporary:
            first = Path(temporary) / "first"
            second = Path(temporary) / "second"
            arguments = (
                "--version", VERSION,
                "--tag", TAG,
                "--commit", COMMIT,
                "--source-date-epoch", EPOCH,
            )
            run_node("scripts/docs/build.mjs", "--output", first, *arguments)
            run_node("scripts/docs/build.mjs", "--output", second, *arguments)

            self.assertEqual(tree_digest(first), tree_digest(second))
            manifest = json.loads((first / "manifest.json").read_text())
            self.assertEqual(manifest["schemaVersion"], 2)
            self.assertEqual(manifest["package"], SLUG)
            self.assertEqual(manifest["product"], SLUG)
            self.assertEqual(manifest["version"], VERSION)
            self.assertEqual(manifest["release"], {"tag": TAG, "commit": COMMIT})
            self.assertEqual(manifest["contentSha256"], content_digest(first))
            for path in first.rglob("*"):
                if path.is_file():
                    self.assertIsNone(
                        re.search(r"\{\{[A-Z][A-Z0-9_]*\}\}", path.read_text()),
                        path,
                    )

    def test_build_rejects_inconsistent_identity_and_dirty_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "docs"
            common = (
                "--tag", TAG,
                "--commit", COMMIT,
                "--source-date-epoch", EPOCH,
                "--output", output,
            )
            mismatch = run_node(
                "scripts/docs/build.mjs", "--version", "0.1.1", *common,
                check=False,
            )
            self.assertNotEqual(mismatch.returncode, 0)
            self.assertIn("release version must be 0.1.0", mismatch.stderr)

            run_node("scripts/docs/build.mjs", "--version", VERSION, *common)
            (output / "navigation.json").write_text("dirty\n")
            dirty = run_node(
                "scripts/docs/build.mjs", "--version", VERSION, *common,
                check=False,
            )
            self.assertNotEqual(dirty.returncode, 0)
            self.assertIn("dirty output", dirty.stderr)

    def test_archive_and_envelope_are_deterministic_and_consistent(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            docs = root / "docs"
            build_args = (
                "--output", docs,
                "--version", VERSION,
                "--tag", TAG,
                "--commit", COMMIT,
                "--source-date-epoch", EPOCH,
            )
            run_node("scripts/docs/build.mjs", *build_args)
            envelopes = []
            archives = []
            for name in ("one", "two"):
                output = root / name
                result = run_node(
                    "scripts/docs/release-artifact.mjs",
                    "--docs-root", docs,
                    "--output", output,
                    "--version", VERSION,
                    "--tag", TAG,
                    "--repository", REPOSITORY,
                    "--commit", COMMIT,
                    "--source-date-epoch", EPOCH,
                )
                envelope = json.loads(result.stdout)
                archive = output / f"{SLUG}-docs-{TAG}.tar.gz"
                envelopes.append(envelope)
                archives.append(archive)

            self.assertEqual(archives[0].read_bytes(), archives[1].read_bytes())
            archive_digest = hashlib.sha256(archives[0].read_bytes()).hexdigest()
            self.assertEqual(envelopes[0], envelopes[1])
            self.assertEqual(envelopes[0]["schemaVersion"], 1)
            self.assertEqual(envelopes[0]["kind"], "product-docs")
            self.assertEqual(envelopes[0]["artifact"]["sha256"], archive_digest)
            self.assertEqual(envelopes[0]["artifact"]["format"], "tar.gz")
            self.assertEqual(
                envelopes[0]["artifact"]["url"],
                "https://github.com/cavi-ai/mlx-workbench/releases/download/"
                "v0.1.0/mlx-workbench-docs-v0.1.0.tar.gz",
            )
            checksum = Path(str(archives[0]) + ".sha256").read_text()
            self.assertEqual(
                checksum,
                f"{archive_digest}  mlx-workbench-docs-v0.1.0.tar.gz\n",
            )

            with tarfile.open(archives[0], "r:gz") as archive:
                members = archive.getmembers()
                self.assertTrue(all(member.isfile() for member in members))
                self.assertTrue(
                    all(
                        member.name == "cavi-release.json"
                        or member.name.startswith("docs/mlx-workbench/v0.1.0/")
                        for member in members
                    )
                )
                release = json.load(archive.extractfile("cavi-release.json"))
            self.assertEqual(release["schemaVersion"], 1)
            self.assertEqual(release["slug"], SLUG)
            self.assertEqual(release["repository"], REPOSITORY)
            self.assertEqual(release["commit"], COMMIT)

    def test_archive_rejects_docs_built_for_another_commit(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            docs = root / "docs"
            run_node(
                "scripts/docs/build.mjs",
                "--output", docs,
                "--version", VERSION,
                "--tag", TAG,
                "--commit", COMMIT,
                "--source-date-epoch", EPOCH,
            )
            result = run_node(
                "scripts/docs/release-artifact.mjs",
                "--docs-root", docs,
                "--output", root / "release",
                "--version", VERSION,
                "--tag", TAG,
                "--repository", REPOSITORY,
                "--commit", "a" * 40,
                "--source-date-epoch", EPOCH,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("manifest is inconsistent", result.stderr)

    def test_documentation_covers_runtime_security_and_recovery_contracts(self):
        pages = ROOT / "docs" / SLUG / "source" / "pages"
        text = "\n".join(path.read_text() for path in sorted(pages.rglob("*.md")))
        required = (
            "Apple Silicon",
            "Python 3.12",
            "make install",
            "make start",
            "make status",
            "make stop",
            "scripts/mlx-agent",
            "--json",
            "127.0.0.1",
            "same-origin",
            "session token",
            "quarantine",
            "Hugging Face Hub",
            "convert-queue.json",
            "not a promise of network isolation",
        )
        for phrase in required:
            self.assertIn(phrase, text)

    def test_release_workflow_runs_full_gate_and_dispatches_after_publication(self):
        workflow = (ROOT / ".github" / "workflows" / "publish-docs.yml").read_text()
        required = (
            "release:",
            "types: [published]",
            "make test",
            "python3 -m unittest tests.test_release_docs -v",
            "node scripts/docs/build.mjs",
            "node scripts/docs/verify.mjs",
            "mlx-workbench-docs-${TAG}.tar.gz",
            "$DIRECTORY/$ARTIFACT.sha256",
            "CONSUMER_DISPATCH_TOKEN",
        )
        for phrase in required:
            self.assertIn(phrase, workflow)
        self.assertIn("GITHUB_SHA: ${{ github.sha }}", workflow)
        self.assertIn('commit="$GITHUB_SHA"', workflow)
        self.assertIn("tag_commit", workflow)
        self.assertGreaterEqual(workflow.count("gh release download"), 2)
        action_refs = re.findall(r"uses: actions/(?:checkout|setup-node)@([^\s]+)", workflow)
        self.assertEqual(len(action_refs), 2)
        self.assertTrue(all(re.fullmatch(r"[a-f0-9]{40}", ref) for ref in action_refs))


if __name__ == "__main__":
    unittest.main()
