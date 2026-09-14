import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
PACKAGE_MANIFEST = REPOSITORY_ROOT / "Package.swift"
VERIFIER = REPOSITORY_ROOT / "Tools/verify/M1-005-mac-arm64-build.sh"
BUILD_DOCUMENT = REPOSITORY_ROOT / "docs/build/M1-005-mac-arm64-build.md"


class M1005MacArm64BuildTests(unittest.TestCase):
    def run_verifier(self, *arguments, environment=None):
        return subprocess.run(
            [str(VERIFIER), *map(str, arguments)],
            cwd=REPOSITORY_ROOT,
            capture_output=True,
            text=True,
            check=False,
            env=environment,
        )

    def environment_with_stub(self, directory, command, output):
        stub = Path(directory) / command
        stub.write_text(f"#!/bin/sh\nprintf '%s\\n' '{output}'\n")
        stub.chmod(0o755)
        environment = os.environ.copy()
        environment["PATH"] = f"{directory}:{environment['PATH']}"
        return environment

    def test_manifest_declares_macos_14(self):
        manifest = PACKAGE_MANIFEST.read_text()

        self.assertIn("platforms: [.macOS(.v14)]", manifest)

    def test_verifier_builds_native_arm64_binary(self):
        result = self.run_verifier()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("M1-005 macOS 14 arm64 build OK", result.stdout)

    def test_missing_repository_root_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            missing_root = Path(temporary_directory) / "missing"
            result = self.run_verifier(missing_root)

        self.assertEqual(result.returncode, 66)
        self.assertIn("repository root does not exist", result.stderr)

    def test_non_arm64_host_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            environment = self.environment_with_stub(
                temporary_directory,
                "uname",
                "x86_64",
            )
            result = self.run_verifier(environment=environment)

        self.assertEqual(result.returncode, 1)
        self.assertIn("native Apple Silicon host required", result.stderr)

    def test_rosetta_translation_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            environment = self.environment_with_stub(
                temporary_directory,
                "sysctl",
                "1",
            )
            result = self.run_verifier(environment=environment)

        self.assertEqual(result.returncode, 1)
        self.assertIn("Rosetta-translated execution is not allowed", result.stderr)

    def test_verifier_checks_rosetta_manifest_and_binary_architecture(self):
        verifier = VERIFIER.read_text()

        for required_check in (
            "sysctl.proc_translated",
            '[[ "$(uname -m)" != "arm64" ]]',
            "swift package",
            "swift build",
            "lipo -archs",
            "otool -l",
        ):
            with self.subTest(required_check=required_check):
                self.assertIn(required_check, verifier)
        self.assertTrue(BUILD_DOCUMENT.is_file())


if __name__ == "__main__":
    unittest.main()
