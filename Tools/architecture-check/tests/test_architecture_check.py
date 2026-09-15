import importlib.util
import signal
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
MODULE_PATH = REPOSITORY_ROOT / "Tools/architecture-check/architecture-check.py"

spec = importlib.util.spec_from_file_location("architecture_check", MODULE_PATH)
architecture_check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(architecture_check)


class ArchitectureCheckTests(unittest.TestCase):
    def make_repository(self, temporary_directory):
        root = Path(temporary_directory)
        (root / "Packages/KVMCore/Sources/KVMCore").mkdir(parents=True)
        (root / "Packages/BarrierCompatibility/Sources/BarrierCompatibility").mkdir(
            parents=True
        )
        (root / "Packages/KVMCore/Sources/KVMCore/Core.swift").write_text(
            "import Foundation\n"
        )
        return root

    def test_current_repository_passes(self):
        self.assertEqual(architecture_check.scan_repository(REPOSITORY_ROOT), [])

    def test_kvmcore_barrier_import_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.make_repository(temporary_directory)
            source = root / "Packages/KVMCore/Sources/KVMCore/Core.swift"
            source.write_text("import BarrierCompatibility\n")

            violations = architecture_check.scan_repository(root)

        self.assertEqual(len(violations), 1)
        self.assertEqual(violations[0].rule, "kvmcore-forbidden-import")
        self.assertEqual(violations[0].line, 1)

    def test_attributed_kvmcore_barrier_import_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.make_repository(temporary_directory)
            source = root / "Packages/KVMCore/Sources/KVMCore/Core.swift"
            source.write_text("@testable import BarrierCompatibility\n")

            violations = architecture_check.scan_repository(root)

        self.assertEqual(len(violations), 1)
        self.assertEqual(violations[0].rule, "kvmcore-forbidden-import")

    def test_other_kvmcore_forbidden_imports_are_rejected(self):
        for module in ("NativeProtocol", "AppKit", "CoreGraphics", "ApplicationServices"):
            with self.subTest(module=module), tempfile.TemporaryDirectory() as temporary_directory:
                root = self.make_repository(temporary_directory)
                source = root / "Packages/KVMCore/Sources/KVMCore/Core.swift"
                source.write_text(f"import {module}\n")

                violations = architecture_check.scan_repository(root)

            self.assertEqual(len(violations), 1)
            self.assertEqual(violations[0].rule, "kvmcore-forbidden-import")

    def test_barrier_tokens_outside_adapter_are_rejected(self):
        for token in ("DKDN", "DMMV", "CINN", "COUT"):
            with self.subTest(token=token), tempfile.TemporaryDirectory() as temporary_directory:
                root = self.make_repository(temporary_directory)
                source = root / "Packages/KVMCore/Sources/KVMCore/Core.swift"
                source.write_text(f'let message = "{token}"\n')

                violations = architecture_check.scan_repository(root)

            self.assertEqual(len(violations), 1)
            self.assertEqual(violations[0].rule, "barrier-token-outside-adapter")

    def test_barrier_adapter_is_the_explicit_token_allowlist(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.make_repository(temporary_directory)
            source = (
                root
                / "Packages/BarrierCompatibility/Sources/BarrierCompatibility/Codec.swift"
            )
            source.write_text('let message = "DKDN"\n')

            violations = architecture_check.scan_repository(root)

        self.assertEqual(violations, [])
        self.assertEqual(
            architecture_check.BARRIER_TOKEN_ALLOWED_ROOTS,
            ("Packages/BarrierCompatibility",),
        )

    def test_token_matching_requires_a_word_boundary(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.make_repository(temporary_directory)
            source = root / "Packages/KVMCore/Sources/KVMCore/Core.swift"
            source.write_text("let DKDNextState = 1\n")

            violations = architecture_check.scan_repository(root)

        self.assertEqual(violations, [])

    def test_unreadable_utf8_source_fails_closed_without_content(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.make_repository(temporary_directory)
            source = root / "Packages/KVMCore/Sources/KVMCore/Invalid.swift"
            source.write_bytes(b"\xff\xfe")

            violations = architecture_check.scan_repository(root)

        self.assertEqual(len(violations), 1)
        self.assertEqual(violations[0].rule, "source-read-error")
        self.assertNotIn("ff", architecture_check.format_violation(violations[0]))

    def test_symlinked_swift_source_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.make_repository(temporary_directory)
            target = root / "outside.swift"
            target.write_text("import Foundation\n")
            link = root / "Packages/KVMCore/Sources/KVMCore/Linked.swift"
            link.symlink_to(target)

            violations = architecture_check.scan_repository(root)

        self.assertEqual(len(violations), 1)
        self.assertEqual(violations[0].rule, "source-symlink")

    def test_symlinked_source_directory_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = self.make_repository(temporary_directory)
            outside = root / "outside"
            outside.mkdir()
            (outside / "Escaped.swift").write_text('let message = "DKDN"\n')
            link = root / "Packages/KVMCore/Sources/KVMCore/Linked"
            link.symlink_to(outside, target_is_directory=True)

            violations = architecture_check.scan_repository(root)

        self.assertEqual(len(violations), 1)
        self.assertEqual(violations[0].rule, "source-symlink")

    def test_missing_root_returns_typed_exit(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            missing = Path(temporary_directory) / "missing"
            self.assertEqual(
                architecture_check.main(["--repository-root", str(missing)]), 66
            )

    def test_missing_kvmcore_root_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            violations = architecture_check.scan_repository(
                Path(temporary_directory)
            )

        self.assertEqual(len(violations), 1)
        self.assertEqual(violations[0].rule, "required-root-missing")

    def test_main_handles_cancellation_and_restores_sigterm(self):
        previous_handler = object()

        with mock.patch.object(
            architecture_check.signal,
            "signal",
            side_effect=[previous_handler, previous_handler],
        ) as install_handler, mock.patch.object(
            architecture_check, "scan_repository", side_effect=KeyboardInterrupt
        ):
            exit_code = architecture_check.main(
                ["--repository-root", str(REPOSITORY_ROOT)]
            )

        self.assertEqual(exit_code, 130)
        self.assertEqual(
            install_handler.call_args_list,
            [
                mock.call(
                    signal.SIGTERM, architecture_check.handle_termination_signal
                ),
                mock.call(signal.SIGTERM, previous_handler),
            ],
        )

    def test_make_and_ci_expose_the_canonical_architecture_check(self):
        makefile = (REPOSITORY_ROOT / "Makefile").read_text()
        ci_gate = (REPOSITORY_ROOT / "Tools/cigates/cigates.py").read_text()

        self.assertIn("architecture-check:", makefile)
        self.assertIn("Tools/architecture-check/architecture-check.py", makefile)
        self.assertIn('"architecture-check"', ci_gate)
        self.assertIn(
            '("python3", "Tools/architecture-check/architecture-check.py")',
            ci_gate,
        )
        self.assertIn('"architecture-check-unit-tests"', ci_gate)
        self.assertIn('"code-quality-unit-tests"', ci_gate)
        self.assertIn('"Tools/architecture-check/tests"', ci_gate)
        self.assertIn('"Tools/code-quality/tests"', ci_gate)


if __name__ == "__main__":
    unittest.main()
