import os
import re
import subprocess
import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parents[1]

# Stands in for the venv interpreter: reports the pinned pip-audit and fails any audit of a lock named vulnerable*.
STUB = """#!{python}
import os
import sys

args = sys.argv[1:]
if args[:1] == ["-c"]:
    if "import pip_audit" not in args[1]:
        exec(compile(args[1], "-c", "exec"))
    sys.exit(0)
if "--version" in args:
    print("pip-audit " + os.environ["STUB_PIP_AUDIT_VERSION"])
    sys.exit(0)
audited = [args[index + 1] for index, value in enumerate(args) if value == "-r"]
if any(os.path.basename(path).startswith("vulnerable") for path in audited):
    print("Found 1 known vulnerability in 1 package")
    sys.exit(1)
print("No known vulnerabilities found")
"""


class PipAuditTargetTests(unittest.TestCase):
    def test_every_backend_lock_is_audited_after_a_failure(self):
        pin = re.search(r"^pip-audit==(\S+)$", (ROOT / "requirements.txt").read_text(), re.MULTILINE).group(1)
        with TemporaryDirectory() as directory:
            root = Path(directory)
            locks = [root / "vulnerable.lock", root / "clean.lock"]
            for lock in locks:
                lock.write_text("")
            stub = root / "python"
            stub.write_text(STUB.format(python=sys.executable))
            stub.chmod(0o755)
            result = subprocess.run(
                ["make", "--no-print-directory", "pip-audit", f"VENV_PY={stub}",
                 "BACKEND_LOCKS=" + " ".join(str(lock) for lock in locks)],
                cwd=ROOT, env=dict(os.environ, STUB_PIP_AUDIT_VERSION=pin),
                capture_output=True, text=True, timeout=60,
            )
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(f"pip-audit {locks[0]}\nFound 1 known vulnerability", result.stdout)
        self.assertIn(f"pip-audit {locks[1]}\nNo known vulnerabilities found", result.stdout)


if __name__ == "__main__":
    unittest.main()
