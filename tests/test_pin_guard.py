"""Run the PR gates pin-guard step against pull requests in a scratch repository."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
COPIED = ("scripts/pin_guard.py", ".github/workflows/pr.yml", ".github/workflows/pin-engine.yml", ".gitmodules")
OLD, NEW = "d50e662bd207bc0a2beea845f0cdeddc85551b57", "063ee59" + "0" * 33
BOT = ("github-actions[bot]", "41898282+github-actions[bot]@users.noreply.github.com")
PERSON = ("Pin Test", "pin@example.invalid")


class PinGuardTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "gitconfig").write_text("[user]\n\tname = Pin Test\n\temail = pin@example.invalid\n")
        self.env = dict(os.environ, GIT_CONFIG_GLOBAL=str(self.root / "gitconfig"), GIT_CONFIG_NOSYSTEM="1")
        self.repo = self.root / "repo"
        for name in COPIED:
            (self.repo / name).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(ROOT / name, self.repo / name)
        self.git("init", "-q", "-b", "main")
        self.git("add", "-A")
        self.git("update-index", "--add", "--cacheinfo", f"160000,{OLD},vendor/mlx-agent")
        self.git("commit", "-q", "-m", "base")
        self.base = self.git("rev-parse", "HEAD")

    def git(self, *args, env=None):
        return subprocess.run(["git", *args], cwd=self.repo, env=env or self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def edit(self, name, old, new):
        path = self.repo / name
        text = path.read_text()
        self.assertIn(old, text)
        path.write_text(text.replace(old, new))

    def move_engine(self):
        self.git("update-index", "--cacheinfo", f"160000,{NEW},vendor/mlx-agent")

    def pull_request(self, branch, change, who=PERSON):
        self.git("checkout", "-q", "-b", branch, self.base)
        change()
        self.git("add", "-u", "--", ".", ":(exclude)vendor")
        name, email = who
        self.git("commit", "-q", "-m", "change", env=dict(
            self.env, GIT_AUTHOR_NAME=name, GIT_AUTHOR_EMAIL=email,
            GIT_COMMITTER_NAME=name, GIT_COMMITTER_EMAIL=email))
        workflow = (ROOT / ".github/workflows/pr.yml").read_text()
        block = workflow.split("  pin-guard:\n", 1)[1].split("        run: |\n", 1)[1].split("\n\n  ", 1)[0]
        script = "\n".join(line[10:] for line in block.splitlines())
        runner = self.root / "runner"
        runner.mkdir(exist_ok=True)
        return subprocess.run(["bash", "-e", "-c", script], cwd=self.repo, capture_output=True, text=True,
                              check=False, env=dict(self.env, BASE=self.base, HEAD=self.git("rev-parse", "HEAD"),
                                                    BRANCH=branch, RUNNER_TEMP=str(runner)))

    def test_hand_pin_fails(self):
        result = self.pull_request("chore/pin-engine", self.move_engine)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("::error file=vendor/mlx-agent::", result.stdout)

    def test_pin_bot_moves_the_pin(self):
        result = self.pull_request("bot/pin-engine-063ee59", self.move_engine, who=BOT)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_bot_branch_from_a_person_fails(self):
        result = self.pull_request("bot/pin-engine-063ee59", self.move_engine)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)

    def test_main_guard_judges_a_rewritten_guard(self):
        def disable_guard():
            (self.repo / "scripts/pin_guard.py").write_text("import sys\nsys.exit(0)\n")
            self.move_engine()
        result = self.pull_request("chore/pin-engine", disable_guard)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("::error file=scripts/pin_guard.py::", result.stdout)
        self.assertIn("::error file=vendor/mlx-agent::", result.stdout)

    def test_pin_workflow_and_merge_job_are_never_changed(self):
        def follow_a_branch():
            self.edit(".github/workflows/pin-engine.yml", "fetch -q origin main", "fetch -q origin dev")
            self.edit(".github/workflows/pr.yml", 'is not part of an engine pin"; exit 1',
                      'is not part of an engine pin"')
        result = self.pull_request("bot/pin-engine-063ee59", follow_a_branch, who=BOT)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("::error file=.github/workflows/pin-engine.yml::", result.stdout)
        self.assertIn("changes the merge-engine-pin job", result.stdout)

    def test_unrelated_change_passes(self):
        def tune_a_gate():
            self.edit(".github/workflows/pr.yml", "        run: make docs-test",
                      "        run: make docs-test\n        timeout-minutes: 20")
        result = self.pull_request("ci/docs-timeout", tune_a_gate)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
