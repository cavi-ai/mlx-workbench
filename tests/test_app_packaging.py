"""App icon + DMG packaging contract tests. Skips gracefully off macOS."""

import plistlib
import re
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ICONSET = ROOT / "mlx-mac" / "mlx-mac" / "Assets.xcassets" / "AppIcon.appiconset"
MAKEFILE = (ROOT / "Makefile").read_text(encoding="utf-8")
INFO_PLIST = ROOT / "mlx-mac" / "mlx-mac" / "Info.plist"
SWIFT_SOURCES = ROOT / "mlx-mac" / "mlx-mac"
DISPLAY_NAME = "MLX Workbench"

REQUIRED_SIZES = {
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024,
}


def png_width(path):
    # PNG IHDR: width is bytes 16-20 big-endian.
    data = path.read_bytes()[:24]
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    return int.from_bytes(data[16:20], "big")


class AppIconTests(unittest.TestCase):
    def test_appiconset_carries_every_macos_size(self):
        for filename, size in REQUIRED_SIZES.items():
            with self.subTest(icon=filename):
                path = ICONSET / filename
                self.assertTrue(path.is_file(), f"missing {filename}")
                self.assertEqual(png_width(path), size, filename)

    def test_contents_json_references_all_files(self):
        contents = (ICONSET / "Contents.json").read_text(encoding="utf-8")
        for filename in REQUIRED_SIZES:
            self.assertIn(filename, contents)
        # No dangling references to files that do not exist.
        for match in re.findall(r'"filename"\s*:\s*"([^"]+)"', contents):
            self.assertTrue((ICONSET / match).is_file(), match)

    def test_icon_source_is_checked_in(self):
        svg = (ROOT / "mlx-mac" / "assets" / "app-icon.svg").read_text(encoding="utf-8")
        # The master is the squircle style: 824pt rounded rect on a 1024 canvas.
        self.assertIn('rx="185"', svg)
        self.assertIn("1024", svg)


class DmgTargetTests(unittest.TestCase):
    def test_makefile_has_dmg_target_wired_to_release_build(self):
        for phrase in (
            "dmg: $(if $(DEVELOPER_TEAM),build-swift-devid,build-swift-dist)",
            "hdiutil create",
            "-format UDZO",
            "DMG_VOLUME",
            "DEVELOPER_TEAM",
        ):
            self.assertIn(phrase, MAKEFILE)

    def test_dmg_app_is_compiled_without_the_source_path(self):
        for name in ("build-swift-dist", "build-swift-devid"):
            target = MAKEFILE.split(f"\n{name}:", 1)[1].split("\n\n", 1)[0]
            self.assertIn("-configuration Release", target)
            self.assertIn("-DMLX_WORKBENCH_DISTRIBUTION", target)
            self.assertIn("arm64", target)
        self.assertIn('ditto "$(MLX_DIST_APP)"', MAKEFILE)

    def test_developer_id_dmg_ships_the_notarized_stapled_export(self):
        target = MAKEFILE.split("\nbuild-swift-devid:", 1)[1].split("\n\n", 1)[0]
        for phrase in (
            "DEVELOPMENT_TEAM=$(DEVELOPER_TEAM) CODE_SIGN_STYLE=Automatic",
            "-allowProvisioningUpdates",
            "method -string developer-id",
            'teamID -string "$(DEVELOPER_TEAM)"',
            "destination -string upload",
            "-exportArchive",
            "-exportNotarizedApp",
            'xcrun stapler validate "$(MLX_DIST_NOTARIZED)"',
        ):
            self.assertIn(phrase, target)
        recipe = MAKEFILE.split("\ndmg: ", 1)[1].split("\n\n", 1)[0]
        notarized_branch = recipe.split('if [ -n "$(DEVELOPER_TEAM)" ]; then', 1)[1].split("else", 1)[0]
        self.assertIn('ditto "$(MLX_DIST_NOTARIZED)"', notarized_branch)
        # Re-signing would invalidate the notarization ticket.
        self.assertNotIn("codesign", notarized_branch)

    def test_distribution_builds_stamp_the_identity_the_updater_compares(self):
        with INFO_PLIST.open("rb") as handle:
            info = plistlib.load(handle)
        self.assertEqual(info["MLXWorkbenchCommit"], "$(MLX_WORKBENCH_COMMIT)")
        self.assertEqual(info["MLXWorkbenchChannel"], "$(MLX_WORKBENCH_CHANNEL)")
        self.assertIn(
            "DIST_IDENTITY  = MLX_WORKBENCH_COMMIT=$(DIST_COMMIT) MLX_WORKBENCH_CHANNEL=$(DMG_CHANNEL)",
            MAKEFILE,
        )
        for name in ("build-swift-dist", "build-swift-devid"):
            target = MAKEFILE.split(f"\n{name}:", 1)[1].split("\n\n", 1)[0]
            self.assertIn("$(DIST_IDENTITY)", target)
        # The updater matches nightly assets by name and commit.
        self.assertIn("mlx-workbench-nightly-$(DIST_COMMIT)", MAKEFILE)

    def test_ci_signs_with_an_api_key_on_every_xcodebuild_step(self):
        target = MAKEFILE.split("\nbuild-swift-devid:", 1)[1].split("\n\n", 1)[0]
        self.assertEqual(target.count("$(XCODE_AUTH)"), 3)
        self.assertIn('-authenticationKeyPath "$(ASC_KEY_PATH)"', MAKEFILE)

    def test_signed_dmg_workflow_publishes_what_the_updater_reads(self):
        workflow = (ROOT / ".github" / "workflows" / "signed-dmg.yml").read_text(encoding="utf-8")
        for phrase in (
            "types: [published]",
            "workflow_dispatch:",
            "permissions: {}",
            "secrets.ASC_KEY_P8",
            "secrets.ASC_KEY_ID",
            "secrets.ASC_ISSUER_ID",
            'make dmg DEVELOPER_TEAM="$DEVELOPER_TEAM" DMG_CHANNEL="$CHANNEL"',
            'certificate leaf[subject.OU] = "\'"$DEVELOPER_TEAM"\'" and notarized',
            'xcrun stapler validate "$app"',
            "gh release create nightly",
            "--prerelease",
            'gh release upload "$TAG" "$DMG" --clobber',
            'capture("^mlx-workbench-nightly-(?<c>[0-9a-f]+)[.]dmg$")',
        ):
            self.assertIn(phrase, workflow)
        # The key file never outlives the job.
        cleanup = workflow.split("- name: Remove the API key", 1)[1]
        self.assertIn("if: always()", cleanup)
        self.assertIn('rm -f "$RUNNER_TEMP/AuthKey.p8"', cleanup)
        self.assertIn("DEVELOPER_TEAM: Y76GMV87GM", workflow)

    def test_nightly_builds_only_on_demand_and_only_for_app_changes(self):
        workflow = (ROOT / ".github" / "workflows" / "signed-dmg.yml").read_text(encoding="utf-8")
        triggers = workflow.split("\non:", 1)[1].split("\npermissions:", 1)[0]
        self.assertNotIn("schedule:", triggers)
        self.assertNotIn("push:", triggers)
        self.assertIn(
            'git diff --quiet "$published" HEAD -- mlx-mac vendor/mlx-agent Makefile', workflow
        )

    def test_source_path_literal_is_compiled_out_of_distribution_builds(self):
        hits = []
        for path in sorted(SWIFT_SOURCES.rglob("*.swift")):
            text = path.read_text(encoding="utf-8")
            if re.search(r"#file(Path)?\b", text):
                hits.append(path.relative_to(ROOT).as_posix())
        self.assertEqual(hits, ["mlx-mac/mlx-mac/Services/WorkbenchPython.swift"])
        source = (SWIFT_SOURCES / "Services" / "WorkbenchPython.swift").read_text(encoding="utf-8")
        self.assertEqual(len(re.findall(r"#file(Path)?\b", source)), 1)
        guarded = re.search(
            r"#if MLX_WORKBENCH_DISTRIBUTION\n(.*?)#else\n(.*?)#endif", source, re.S
        )
        self.assertIsNotNone(guarded)
        self.assertNotIn("#file", guarded.group(1))
        self.assertIn("#file", guarded.group(2))

    def test_dmg_target_is_declared_phony(self):
        lines = MAKEFILE.splitlines()
        phony = ""
        for index, line in enumerate(lines):
            if line.startswith(".PHONY:"):
                phony = line
                while phony.rstrip().endswith("\\"):
                    phony = phony.rstrip()[:-1]
                    index += 1
                    phony += " " + lines[index]
                break
        self.assertRegex(phony, r"\bdmg\b")

    def test_dmg_output_is_gitignored(self):
        entries = (ROOT / ".gitignore").read_text(encoding="utf-8").splitlines()
        self.assertIn("/.release/", entries)

    def test_dmg_ships_the_app_under_the_display_name(self):
        self.assertRegex(MAKEFILE, r"(?m)^DMG_VOLUME\s*:=\s*MLX Workbench\s*$")
        self.assertRegex(MAKEFILE, r"(?m)^DMG_APP\s*:=\s*MLX Workbench\.app\s*$")
        self.assertIn('"$(DMG_DIR)/stage/$(DMG_APP)"', MAKEFILE)
        self.assertNotIn("stage/mlx-workbench.app", MAKEFILE)


class AppNameTests(unittest.TestCase):
    def test_bundle_names_are_the_display_name(self):
        with INFO_PLIST.open("rb") as handle:
            info = plistlib.load(handle)
        self.assertEqual(info["CFBundleName"], DISPLAY_NAME)
        self.assertEqual(info["CFBundleDisplayName"], DISPLAY_NAME)
        # Executable and bundle id stay put: defaults, login items and the
        # updater's relaunch of Bundle.main.bundleURL depend on them.
        self.assertEqual(info["CFBundleExecutable"], "mlx-workbench")
        self.assertEqual(info["CFBundleIdentifier"], "com.cavi.mlxworkbench")

    def test_ui_labels_use_the_display_name(self):
        label = re.compile(
            r'(?:Button|Text|Label|MenuBarExtra|Window|WindowGroup)\(\s*"([^"]*)"'
            r'|messageText\s*=\s*"([^"]*)"'
        )
        offenders = []
        for path in sorted(SWIFT_SOURCES.rglob("*.swift")):
            lines = path.read_text(encoding="utf-8").splitlines()
            for number, line in enumerate(lines, 1):
                for match in label.finditer(line):
                    text = match.group(1) or match.group(2) or ""
                    # "the mlx-workbench checkout" names the repository.
                    if "mlx-workbench" in text.replace("mlx-workbench checkout", ""):
                        offenders.append(f"{path.relative_to(ROOT)}:{number}: {text}")
        self.assertEqual(offenders, [])


if __name__ == "__main__":
    unittest.main()