import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
VERIFIER = REPOSITORY_ROOT / "Tools/verify/M1-007-test-targets.sh"
FIXTURE_SCHEMA = REPOSITORY_ROOT / "Tests/Fixtures/fixture-metadata.schema.json"
UNIT_TEST_SOURCE = REPOSITORY_ROOT / "Tests/Unit/UnitTargetTests.swift"
SYSTEM_TEST_SOURCE = REPOSITORY_ROOT / "Tests/SystemTests/SystemTargetTests.swift"


class M1007TestTargetTests(unittest.TestCase):
    def run_verifier(self, *arguments):
        return subprocess.run(
            [str(VERIFIER), *map(str, arguments)],
            cwd=REPOSITORY_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_test_target_verifier_passes(self):
        result = self.run_verifier()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("M1-007 test targets and fixtures OK", result.stdout)

    def test_fixture_roots_and_metadata_schema_exist(self):
        self.assertTrue(FIXTURE_SCHEMA.is_file())
        self.assertTrue((REPOSITORY_ROOT / "Tests/Fixtures/Barrier/README.md").is_file())
        self.assertTrue((REPOSITORY_ROOT / "Tests/Fixtures/Native/README.md").is_file())

    def test_fixture_schema_is_privacy_safe_and_versioned(self):
        schema = json.loads(FIXTURE_SCHEMA.read_text())

        self.assertEqual(schema["properties"]["schemaVersion"]["const"], 1)
        self.assertEqual(
            set(schema["properties"]["protocol"]["enum"]), {"barrier", "native"}
        )
        sanitization = schema["properties"]["sanitization"]
        self.assertIn("containsSensitiveData", sanitization["required"])
        self.assertFalse(
            sanitization["properties"]["containsSensitiveData"]["const"]
        )
        self.assertFalse(schema["additionalProperties"])

    def test_unit_target_source_has_no_permission_framework_import(self):
        source = UNIT_TEST_SOURCE.read_text()

        for framework in ("AppKit", "CoreGraphics", "IOKit", "Network", "Security"):
            with self.subTest(framework=framework):
                self.assertNotIn(f"import {framework}", source)

    def test_system_test_scaffold_is_explicitly_disabled(self):
        source = SYSTEM_TEST_SOURCE.read_text()

        self.assertIn(".disabled(", source)
        self.assertIn("explicit system-test opt-in", source)

    def test_missing_repository_root_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            missing_root = Path(temporary_directory) / "missing"
            result = self.run_verifier(missing_root)

        self.assertEqual(result.returncode, 66)
        self.assertIn("repository root does not exist", result.stderr)

    def test_too_many_arguments_fails_with_usage_exit(self):
        result = self.run_verifier(REPOSITORY_ROOT, REPOSITORY_ROOT)

        self.assertEqual(result.returncode, 64)
        self.assertIn("usage:", result.stderr)

    def test_schema_without_privacy_const_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            shutil.copy2(REPOSITORY_ROOT / "Package.swift", temporary_root / "Package.swift")
            shutil.copytree(REPOSITORY_ROOT / "Apps", temporary_root / "Apps")
            shutil.copytree(REPOSITORY_ROOT / "Packages", temporary_root / "Packages")
            shutil.copytree(REPOSITORY_ROOT / "Tests", temporary_root / "Tests")
            schema_path = temporary_root / "Tests/Fixtures/fixture-metadata.schema.json"
            schema = json.loads(schema_path.read_text())
            del schema["properties"]["sanitization"]["properties"][
                "containsSensitiveData"
            ]["const"]
            schema_path.write_text(json.dumps(schema))

            result = self.run_verifier(temporary_root)

        self.assertEqual(result.returncode, 1)
        self.assertIn("containsSensitiveData must be const false", result.stderr)

    def test_nested_unit_permission_framework_import_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            shutil.copy2(REPOSITORY_ROOT / "Package.swift", temporary_root / "Package.swift")
            shutil.copytree(REPOSITORY_ROOT / "Apps", temporary_root / "Apps")
            shutil.copytree(REPOSITORY_ROOT / "Packages", temporary_root / "Packages")
            shutil.copytree(REPOSITORY_ROOT / "Tests", temporary_root / "Tests")
            nested_source = temporary_root / "Tests/Unit/Nested/ForbiddenImport.swift"
            nested_source.parent.mkdir()
            nested_source.write_text("import AppKit\n")

            result = self.run_verifier(temporary_root)

        self.assertEqual(result.returncode, 1)
        self.assertIn("must not import OS permission framework AppKit", result.stderr)


if __name__ == "__main__":
    unittest.main()
