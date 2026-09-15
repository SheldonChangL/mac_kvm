import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
PACKAGE_MANIFEST = REPOSITORY_ROOT / "Package.swift"
VERIFIER = REPOSITORY_ROOT / "Tools/verify/M1-006-package-boundaries.sh"
MODULE_NAMES = (
    "KVMContracts",
    "KVMCore",
    "BarrierCompatibility",
    "MacPlatform",
    "NativeProtocol",
)


class M1006PackageBoundaryTests(unittest.TestCase):
    def run_verifier(self, *arguments):
        return subprocess.run(
            [str(VERIFIER), *map(str, arguments)],
            cwd=REPOSITORY_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )

    def copy_package_fixture(self, temporary_root):
        shutil.copy2(PACKAGE_MANIFEST, temporary_root / "Package.swift")
        shutil.copytree(REPOSITORY_ROOT / "Apps", temporary_root / "Apps")
        shutil.copytree(REPOSITORY_ROOT / "Packages", temporary_root / "Packages")
        shutil.copytree(REPOSITORY_ROOT / "Tests", temporary_root / "Tests")

    def replace_manifest_once(self, temporary_root, original, replacement):
        manifest_path = temporary_root / "Package.swift"
        manifest = manifest_path.read_text()
        self.assertEqual(manifest.count(original), 1)
        manifest_path.write_text(manifest.replace(original, replacement, 1))

    def test_package_boundary_verifier_passes(self):
        result = self.run_verifier()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("M1-006 package boundaries OK", result.stdout)

    def test_required_module_source_roots_exist(self):
        for module_name in MODULE_NAMES:
            with self.subTest(module_name=module_name):
                source = (
                    REPOSITORY_ROOT
                    / f"Packages/{module_name}/Sources/{module_name}/{module_name}.swift"
                )
                self.assertTrue(source.is_file())

    def test_scaffold_modules_define_no_public_contract_or_behavior(self):
        for module_name in MODULE_NAMES:
            with self.subTest(module_name=module_name):
                source = (
                    REPOSITORY_ROOT
                    / f"Packages/{module_name}/Sources/{module_name}/{module_name}.swift"
                ).read_text()
                self.assertNotIn("public ", source)
                self.assertNotIn("import ", source)
                self.assertNotIn("DKDN", source)
                self.assertNotIn("DMMV", source)
                self.assertNotIn("CINN", source)

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

    def test_kvm_core_protocol_dependency_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            self.copy_package_fixture(temporary_root)
            self.replace_manifest_once(
                temporary_root,
                'name: "KVMCore",\n      dependencies: ["KVMContracts"]',
                'name: "KVMCore",\n      dependencies: ["KVMContracts", "BarrierCompatibility"]',
            )

            result = self.run_verifier(temporary_root)

        self.assertEqual(result.returncode, 1)
        self.assertIn("invalid dependencies for KVMCore", result.stderr)

    def test_extra_app_dependency_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            self.copy_package_fixture(temporary_root)
            self.replace_manifest_once(
                temporary_root,
                '"MacPlatform",\n        "NativeProtocol",\n      ],\n      path: "Apps/macOS/MacKVM"',
                '"MacPlatform",\n        "NativeProtocol",\n        "KVMContracts",\n      ],\n      path: "Apps/macOS/MacKVM"',
            )

            result = self.run_verifier(temporary_root)

        self.assertEqual(result.returncode, 1)
        self.assertIn("invalid dependencies for MacKVM", result.stderr)

    def test_manifest_names_all_module_targets(self):
        manifest = PACKAGE_MANIFEST.read_text()

        for module_name in MODULE_NAMES:
            with self.subTest(module_name=module_name):
                self.assertIn(f'name: "{module_name}"', manifest)


if __name__ == "__main__":
    unittest.main()
