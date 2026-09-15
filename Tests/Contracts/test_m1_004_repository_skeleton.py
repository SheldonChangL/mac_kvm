import subprocess
import tempfile
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
VERIFIER = REPOSITORY_ROOT / "Tools/verify/M1-004-repository-skeleton.sh"
APP_SHELL = REPOSITORY_ROOT / "Apps/macOS/MacKVM/MacKVMApplication.swift"


class M1004RepositorySkeletonTests(unittest.TestCase):
    def run_verifier(self, *arguments, cwd=None):
        return subprocess.run(
            [str(VERIFIER), *map(str, arguments)],
            cwd=cwd or REPOSITORY_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_repository_skeleton_verifies_from_repository_root(self):
        result = self.run_verifier()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("M1-004 repository skeleton OK", result.stdout)

    def test_explicit_repository_root_works_from_another_directory(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            result = self.run_verifier(REPOSITORY_ROOT, cwd=temporary_directory)

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_repository_root_fails_with_typed_exit(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            missing_root = Path(temporary_directory) / "missing"
            result = self.run_verifier(missing_root)

        self.assertEqual(result.returncode, 66)
        self.assertIn("repository root does not exist", result.stderr)

    def test_too_many_arguments_fails_with_usage_exit(self):
        result = self.run_verifier("one", "two")

        self.assertEqual(result.returncode, 64)
        self.assertIn("usage:", result.stderr)

    def test_application_shell_has_no_feature_or_dependency(self):
        source = APP_SHELL.read_text()

        self.assertEqual(
            source,
            "@main\nstruct MacKVMApplication {\n  static func main() {}\n}\n",
        )
        self.assertNotIn("import ", source)


if __name__ == "__main__":
    unittest.main()
