"""Single-version-source contract.

`mlx_workbench.__version__` is the only hand-edited version string. The
Swift app's MARKETING_VERSION, the release-docs test constants, and the
CHANGELOG headings must agree with it. Use `make version-bump V=x.y.z` to
move everything together.
"""

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
SEMVER = re.compile(r"^\d+\.\d+\.\d+$")


def package_version():
    source = (ROOT / "mlx_workbench" / "__init__.py").read_text()
    match = re.search(r'^__version__\s*=\s*["\']([^"\']+)["\']', source, re.M)
    assert match, "mlx_workbench.__version__ is required"
    return match.group(1)


class VersionSyncTests(unittest.TestCase):
    def test_package_version_is_semver(self):
        self.assertRegex(package_version(), SEMVER)

    def test_swift_marketing_version_matches_package(self):
        pbxproj = (
            ROOT / "mlx-mac" / "mlx-mac.xcodeproj" / "project.pbxproj"
        ).read_text()
        marketing = set(re.findall(r"MARKETING_VERSION = ([^;]+);", pbxproj))
        self.assertEqual(marketing, {package_version()})

    def test_info_plist_defers_to_build_settings(self):
        plist = (ROOT / "mlx-mac" / "mlx-mac" / "Info.plist").read_text()
        version = re.search(
            r"CFBundleShortVersionString</key>\s*<string>([^<]+)</string>", plist
        ).group(1)
        self.assertEqual(version, "$(MARKETING_VERSION)")

    def test_release_docs_constants_match_package(self):
        source = (ROOT / "tests" / "test_release_docs.py").read_text()
        version = re.search(r'^VERSION = "([^"]+)"', source, re.M).group(1)
        tag = re.search(r'^TAG = "([^"]+)"', source, re.M).group(1)
        self.assertEqual(version, package_version())
        self.assertEqual(tag, f"v{package_version()}")

    def test_changelog_documents_current_version(self):
        changelog = (ROOT / "CHANGELOG.md").read_text()
        version = package_version()
        self.assertIn(f"## [{version}]", changelog)
        self.assertIn("## [Unreleased]", changelog)


if __name__ == "__main__":
    unittest.main()
