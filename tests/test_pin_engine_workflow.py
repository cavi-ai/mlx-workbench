"""Execute the engine pin step against local repositories."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class EnginePinTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "gitconfig").write_text("[user]\n\tname = Pin Test\n\temail = pin@example.invalid\n")
        self.env = dict(os.environ, GIT_CONFIG_GLOBAL=str(self.root / "gitconfig"), GIT_CONFIG_NOSYSTEM="1")

    def git(self, *args, cwd):
        return subprocess.run(["git", *args], cwd=cwd, env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def engine(self):
        engine = self.root / "engine"
        engine.mkdir()
        self.git("init", "-q", "-b", "main", cwd=engine)
        commits = []
        for version in ("0.11.0", "0.12.0"):
            (engine / "plugin.json").write_text(f'{{"name": "mlx-agent", "version": "{version}"}}\n')
            self.git("add", "plugin.json", cwd=engine)
            self.git("commit", "-q", "-m", version, cwd=engine)
            commits.append(self.git("rev-parse", "HEAD", cwd=engine))
        return engine, commits

    def run_sync(self, pinned, changelog=lambda commits: "# Changelog\n\n## [Unreleased]\n"):
        engine, commits = self.engine()
        consumer = self.root / "consumer"
        (consumer / "vendor").mkdir(parents=True)
        (consumer / "scripts").mkdir()
        (consumer / "scripts/pin_engine_changelog.py").write_text((ROOT / "scripts/pin_engine_changelog.py").read_text())
        (consumer / "CHANGELOG.md").write_text(changelog(commits))
        self.git("clone", "-q", str(engine), str(consumer / "vendor/mlx-agent"), cwd=self.root)
        self.git("checkout", "-q", commits[pinned], cwd=consumer / "vendor/mlx-agent")
        workflow = (ROOT / ".github/workflows/pin-engine.yml").read_text()
        block = workflow.split("      - id: sync\n", 1)[1].split("        run: |\n", 1)[1].split("\n      - ", 1)[0]
        script = "\n".join(line[10:] for line in block.splitlines())
        output = self.root / "output"
        output.touch()
        result = subprocess.run(["bash", "-e", "-c", script], cwd=consumer, capture_output=True, text=True,
                                env=dict(self.env, GITHUB_OUTPUT=str(output)), check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.changelog = (consumer / "CHANGELOG.md").read_text()
        return commits, output.read_text(), self.git("rev-parse", "HEAD", cwd=consumer / "vendor/mlx-agent")

    def test_sync_moves_the_engine_to_main_and_names_the_pin(self):
        commits, output, head = self.run_sync(pinned=0)
        self.assertEqual(head, commits[1])
        self.assertEqual(output, f"branch=bot/pin-engine-{commits[1][:7]}\n"
                                 f"body=- mlx-agent {commits[0][:7]} -> {commits[1][:7]}\n")

    def test_sync_records_the_new_pin_on_the_unreleased_engine_line(self):
        released = "## [0.7.1] - 2026-10-22\n\n### Changed\n\n- Engine: `mlx-agent` moves to 0.10.0 at `abc1234`, older.\n"
        commits, _, _ = self.run_sync(pinned=0, changelog=lambda commits: (
            "# Changelog\n\n## [Unreleased]\n### Added\n\n- Discover: search.\n\n### Changed\n\n"
            f"- Engine: `mlx-agent` moves to 0.11.0 at `{commits[0][:7]}`, which ranks discovery.\n"
            f"- Compare: 512.\n\n{released}"))
        self.assertEqual(self.changelog,
                         "# Changelog\n\n## [Unreleased]\n### Added\n\n- Discover: search.\n\n### Changed\n\n"
                         f"- Engine: `mlx-agent` moves to 0.12.0 at `{commits[1][:7]}`, which ranks discovery.\n"
                         f"- Compare: 512.\n\n{released}")

    def test_sync_adds_an_engine_line_when_the_unreleased_section_has_none(self):
        released = "## [0.7.1] - 2026-10-22\n\n### Changed\n\n- Engine: `mlx-agent` moves to 0.10.0 at `abc1234`, older.\n"
        cases = {
            "### Added\n\n- Discover: search.\n\n":
                "### Added\n\n- Discover: search.\n\n### Changed\n\n- Engine: `mlx-agent` moves to 0.12.0 at `{pin}`.\n\n",
            "### Changed\n\n- Compare: 512.\n\n":
                "### Changed\n\n- Engine: `mlx-agent` moves to 0.12.0 at `{pin}`.\n- Compare: 512.\n\n",
        }
        for before, after in cases.items():
            with self.subTest(before=before):
                self.setUp()
                commits, _, _ = self.run_sync(pinned=0, changelog=lambda commits: (
                    f"# Changelog\n\n## [Unreleased]\n{before}{released}"))
                self.assertEqual(self.changelog, "# Changelog\n\n## [Unreleased]\n"
                                 f"{after.format(pin=commits[1][:7])}{released}")

    def test_sync_proposes_nothing_when_the_engine_is_on_main(self):
        commits, output, head = self.run_sync(pinned=1)
        self.assertEqual(head, commits[1])
        self.assertEqual(output, "")
        self.assertEqual(self.changelog, "# Changelog\n\n## [Unreleased]\n")


if __name__ == "__main__":
    unittest.main()
