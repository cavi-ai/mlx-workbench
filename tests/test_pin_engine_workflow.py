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

    def run_sync(self, pinned):
        engine = self.root / "engine"
        engine.mkdir()
        self.git("init", "-q", "-b", "main", cwd=engine)
        commits = []
        for name in ("first", "second"):
            (engine / name).write_text(name)
            self.git("add", name, cwd=engine)
            self.git("commit", "-q", "-m", name, cwd=engine)
            commits.append(self.git("rev-parse", "HEAD", cwd=engine))
        consumer = self.root / "consumer"
        (consumer / "vendor").mkdir(parents=True)
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
        return commits, output.read_text(), self.git("rev-parse", "HEAD", cwd=consumer / "vendor/mlx-agent")

    def test_sync_moves_the_engine_to_main_and_names_the_pin(self):
        commits, output, head = self.run_sync(pinned=0)
        self.assertEqual(head, commits[1])
        self.assertEqual(output, f"branch=bot/pin-engine-{commits[1][:7]}\n"
                                 f"body=- mlx-agent {commits[0][:7]} -> {commits[1][:7]}\n")

    def test_sync_proposes_nothing_when_the_engine_is_on_main(self):
        commits, output, head = self.run_sync(pinned=1)
        self.assertEqual(head, commits[1])
        self.assertEqual(output, "")


if __name__ == "__main__":
    unittest.main()
